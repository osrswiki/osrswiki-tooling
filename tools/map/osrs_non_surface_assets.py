#!/usr/bin/env python3
"""Lossless realm layouts and deterministic MBTiles for OSRS map assets."""

from __future__ import annotations

import hashlib
import io
import json
import math
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, MutableMapping, Sequence

import numpy as np
from PIL import Image

from osrs_non_surface_realms import (
    OSRS_SCHEMA_VERSION,
    OSRS_SURFACE_REALM_ID,
    osrs_canonical_json_bytes,
    osrs_other_map_id,
    osrsPipelineError,
    osrsProjection,
    osrsRect,
    osrs_rect_from_json,
    osrs_sha256_bytes,
    osrs_stable_native_realm_id,
)
from osrs_public_path_hygiene import (
    osrs_assert_public_binary_portable,
    osrsPublicPathError,
)


Image.MAX_IMAGE_PIXELS = None
OSRS_TILE_SIZE = 512
OSRS_MAX_MERCATOR_LATITUDE = 85.0511287798066
# The established pre-selector Surface camera renders every source pixel at this
# scale, independent of the producer's power-of-two Web Mercator canvas size.
OSRS_DEFAULT_CAMERA_RELATIVE_ZOOM = 0.3414426741929
# Cover the largest supported phone viewport in MapLibre rendered pixels while
# retaining the established four-sided half-viewport overbound at the default scale.
OSRS_DEFAULT_CAMERA_MAX_VIEWPORT_EXTENT_PIXELS = 2560
OSRS_DEFAULT_CAMERA_EDGE_PADDING_PIXELS = math.ceil(
    OSRS_DEFAULT_CAMERA_MAX_VIEWPORT_EXTENT_PIXELS
    / (2 * (2**OSRS_DEFAULT_CAMERA_RELATIVE_ZOOM))
)


@dataclass(frozen=True)
class osrsRenderedRealm:
    rgba: np.ndarray
    mask: np.ndarray
    ownership_mask: np.ndarray | None
    source_bounds: tuple[osrsRect, ...]
    display_bounds: osrsRect
    plane: int
    assigned_source_pixel_count: int
    ownership_pixel_count: int = 0
    display_pixel_count: int = 0
    transparent_owned_pixel_count: int = 0
    visible_exact_black_pixel_count: int = 0
    identical_rgb_display_collision_count: int = 0
    layout_components: tuple[dict[str, Any], ...] = ()


def osrs_sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def osrs_validate_release_relative_path(value: str, field: str) -> str:
    """Validate one portable path resolved from the release root."""

    if not value or value == ".":
        raise osrsPipelineError(f"{field} must name a release-owned file")
    if "\\" in value or value.startswith("/") or re.match(r"^[A-Za-z]:/", value):
        raise osrsPipelineError(f"{field} must be a POSIX path relative to release root")
    path = PurePosixPath(value)
    if ".." in path.parts:
        raise osrsPipelineError(f"{field} must not escape the release root")
    normalized = path.as_posix()
    if normalized != value:
        raise osrsPipelineError(f"{field} is not a normalized release-relative path")
    return normalized


def osrs_release_relative_path(path: Path, release_root: Path) -> str:
    """Serialize a release-owned path without depending on the output directory."""

    resolved_root = release_root.resolve()
    resolved_path = path.resolve()
    try:
        relative = resolved_path.relative_to(resolved_root)
    except ValueError as error:
        raise osrsPipelineError(
            f"release-owned path is outside release root: {resolved_path}"
        ) from error
    return osrs_validate_release_relative_path(relative.as_posix(), "release path")


def osrs_asset_stem(realm_id: str) -> str:
    stem = re.sub(r"[^a-z0-9]+", "-", realm_id.casefold()).strip("-")
    if not stem:
        raise osrsPipelineError(f"realm ID has no filename-safe characters: {realm_id!r}")
    return stem


def osrs_definition_pieces(
    definition: Mapping[str, Any], plane: int | None = None
) -> tuple[Mapping[str, Any], ...]:
    composite = definition.get("composite")
    if not isinstance(composite, Mapping):
        raise osrsPipelineError("definition.composite must be an object")
    pieces: list[Mapping[str, Any]] = []
    for key in ("map_squares", "zones"):
        values = composite.get(key, [])
        if not isinstance(values, list):
            raise osrsPipelineError(f"definition.composite.{key} must be an array")
        for value in values:
            if not isinstance(value, Mapping):
                raise osrsPipelineError(f"definition.composite.{key}[] must be an object")
            normalized = value.get("normalized")
            if not isinstance(normalized, Mapping):
                raise osrsPipelineError("piece.normalized must be an object")
            source = normalized.get("source_bounds")
            if not isinstance(source, Mapping):
                raise osrsPipelineError("piece.normalized.source_bounds must be an object")
            plane_min = _osrs_int(source.get("plane_min"), "plane_min")
            plane_max = _osrs_int(source.get("plane_max"), "plane_max")
            if plane is None or plane_min <= plane <= plane_max:
                pieces.append(value)
    return tuple(sorted(pieces, key=_osrs_piece_sort_key))


def osrs_definition_planes(definition: Mapping[str, Any]) -> tuple[int, ...]:
    planes: set[int] = set()
    for piece in osrs_definition_pieces(definition):
        source = piece["normalized"]["source_bounds"]
        planes.update(
            range(
                _osrs_int(source.get("plane_min"), "plane_min"),
                _osrs_int(source.get("plane_max"), "plane_max") + 1,
            )
        )
    return tuple(sorted(planes))


def osrs_render_native_realm(
    source_rgb: np.ndarray,
    projection: osrsProjection,
    definition: Mapping[str, Any],
    plane: int,
) -> osrsRenderedRealm:
    """Reassemble one cache definition in realm-local display coordinates."""

    image = np.asarray(source_rgb)
    if image.shape[:2] != (projection.height, projection.width) or image.shape[2] < 3:
        raise osrsPipelineError(
            f"source shape {image.shape} does not match "
            f"{projection.width}x{projection.height} RGB"
        )
    pieces = osrs_definition_pieces(definition, plane)
    if not pieces:
        raise osrsPipelineError(
            f"definition {definition.get('file_id')} has no pieces on plane {plane}"
        )
    records: list[tuple[osrsRect, osrsRect]] = []
    for piece in pieces:
        normalized = piece["normalized"]
        source_rect = osrs_rect_from_json(normalized["source_bounds"])
        display_rect = osrs_rect_from_json(normalized["display_bounds"])
        if source_rect.width != display_rect.width or source_rect.height != display_rect.height:
            raise osrsPipelineError(
                f"non-size-preserving piece in definition {definition.get('file_id')}: "
                f"{source_rect} -> {display_rect}"
            )
        records.append((source_rect, display_rect))

    display_bounds = _osrs_union_bounds(display for _, display in records)
    width = display_bounds.width * projection.scale
    height = display_bounds.height * projection.scale
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    mask = np.zeros((height, width), dtype=np.bool_)

    for source_rect, display_rect in records:
        source_pixels = projection.game_to_pixel_rect(source_rect)
        destination = osrsRect(
            min_x=(display_rect.min_x - display_bounds.min_x) * projection.scale,
            min_y=(display_bounds.max_y - display_rect.max_y) * projection.scale,
            max_x=(display_rect.max_x - display_bounds.min_x) * projection.scale,
            max_y=(display_bounds.max_y - display_rect.min_y) * projection.scale,
        )
        if source_pixels.width != destination.width or source_pixels.height != destination.height:
            raise osrsPipelineError("source/display pixel dimensions diverged")
        source = image[
            source_pixels.min_y : source_pixels.max_y,
            source_pixels.min_x : source_pixels.max_x,
            :3,
        ]
        target = rgba[
            destination.min_y : destination.max_y,
            destination.min_x : destination.max_x,
            :3,
        ]
        occupied = mask[
            destination.min_y : destination.max_y,
            destination.min_x : destination.max_x,
        ]
        conflict = occupied & np.any(target != source, axis=2)
        if np.any(conflict):
            raise osrsPipelineError(
                f"conflicting display transform pixels in definition "
                f"{definition.get('file_id')} plane {plane}: {int(np.count_nonzero(conflict))}"
            )
        target[~occupied] = source[~occupied]
        alpha = rgba[
            destination.min_y : destination.max_y,
            destination.min_x : destination.max_x,
            3,
        ]
        alpha[:] = 255
        occupied[:] = True

    display_pixels = int(np.count_nonzero(mask))
    visible_black = int(
        np.count_nonzero(mask & np.all(rgba[..., :3] == 0, axis=2))
    )
    return osrsRenderedRealm(
        rgba=rgba,
        mask=mask,
        ownership_mask=mask.copy(),
        source_bounds=tuple(sorted({source for source, _ in records})),
        display_bounds=display_bounds,
        plane=plane,
        assigned_source_pixel_count=sum(
            projection.game_to_pixel_rect(source).area for source, _ in records
        ),
        ownership_pixel_count=display_pixels,
        display_pixel_count=display_pixels,
        transparent_owned_pixel_count=0,
        visible_exact_black_pixel_count=visible_black,
        identical_rgb_display_collision_count=(
            sum(projection.game_to_pixel_rect(source).area for source, _ in records)
            - int(np.count_nonzero(mask))
        ),
    )


def osrs_render_wiki_view(
    source_rgb: np.ndarray,
    projection: osrsProjection,
    game_bounds: osrsRect,
    plane: int = 0,
    coverage_mask: np.ndarray | None = None,
) -> osrsRenderedRealm:
    pixel_bounds = projection.game_to_pixel_rect_clipped(game_bounds)
    if pixel_bounds is None:
        raise osrsPipelineError(f"Wiki view does not intersect source raster: {game_bounds}")
    crop = np.asarray(source_rgb)[
        pixel_bounds.min_y : pixel_bounds.max_y,
        pixel_bounds.min_x : pixel_bounds.max_x,
        :3,
    ]
    rgba = np.empty((pixel_bounds.height, pixel_bounds.width, 4), dtype=np.uint8)
    rgba[..., :3] = crop
    ownership_mask = np.ones((pixel_bounds.height, pixel_bounds.width), dtype=np.bool_)
    if coverage_mask is None or plane == 0:
        display_mask = ownership_mask.copy()
    else:
        coverage = np.asarray(coverage_mask)
        if coverage.shape != (projection.height, projection.width) or coverage.dtype != np.bool_:
            raise osrsPipelineError("coverage mask dimensions or dtype are invalid")
        display_mask = coverage[
            pixel_bounds.min_y : pixel_bounds.max_y,
            pixel_bounds.min_x : pixel_bounds.max_x,
        ].copy()
    rgba[..., 3] = np.where(display_mask, 255, 0).astype(np.uint8)
    display_pixels = int(np.count_nonzero(display_mask))
    visible_black = int(
        np.count_nonzero(display_mask & np.all(rgba[..., :3] == 0, axis=2))
    )
    return osrsRenderedRealm(
        rgba=rgba,
        mask=display_mask,
        ownership_mask=ownership_mask,
        source_bounds=(game_bounds,),
        display_bounds=game_bounds,
        plane=plane,
        assigned_source_pixel_count=pixel_bounds.area,
        ownership_pixel_count=pixel_bounds.area,
        display_pixel_count=display_pixels,
        transparent_owned_pixel_count=pixel_bounds.area - display_pixels,
        visible_exact_black_pixel_count=visible_black,
    )


def osrs_save_mask_png(mask: np.ndarray, path: Path) -> str:
    image = Image.fromarray(np.where(mask, 255, 0).astype(np.uint8))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_osrs_png_bytes(image))
    return osrs_sha256_file(path)


def osrs_save_owner_codes_png(owner_codes: np.ndarray, path: Path) -> str:
    codes = np.asarray(owner_codes)
    if codes.size and int(codes.max()) >= 65535:
        raise osrsPipelineError("owner-code PNG supports at most 65,534 owners")
    image = Image.fromarray(codes.astype(np.uint16))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_osrs_png_bytes(image))
    return osrs_sha256_file(path)


def osrs_write_mbtiles(
    rgba: np.ndarray,
    output_path: Path,
    name: str,
    tile_size: int = OSRS_TILE_SIZE,
    *,
    canvas_size: int | None = None,
    canvas_origin: tuple[int, int] = (0, 0),
    release_root: Path | None = None,
) -> dict[str, Any]:
    """Write a byte-reproducible, finite realm-local raster tile pyramid."""

    image_array = np.asarray(rgba)
    if image_array.ndim != 3 or image_array.shape[2] != 4:
        raise osrsPipelineError(f"MBTiles source must be RGBA, got {image_array.shape}")
    height, width = image_array.shape[:2]
    if width <= 0 or height <= 0:
        raise osrsPipelineError("MBTiles source cannot be empty")
    if tile_size <= 0 or tile_size & (tile_size - 1):
        raise osrsPipelineError("tile size must be a positive power of two")
    natural_zoom = max(0, math.ceil(math.log2(max(width, height) / tile_size)))
    natural_canvas_size = tile_size * (2**natural_zoom)
    if canvas_size is None:
        canvas_size = natural_canvas_size
    else:
        if canvas_size < natural_canvas_size or canvas_size % tile_size != 0:
            raise osrsPipelineError(
                "MBTiles canvas must be a tile-aligned square containing the rendered image"
            )
        tile_dimension = canvas_size // tile_size
        if tile_dimension & (tile_dimension - 1):
            raise osrsPipelineError(
                "MBTiles canvas tile dimension must be a power of two"
            )
    native_zoom = int(math.log2(canvas_size // tile_size))
    if (
        len(canvas_origin) != 2
        or any(not isinstance(value, int) for value in canvas_origin)
    ):
        raise osrsPipelineError("MBTiles canvas origin must contain two integers")
    origin_x, origin_y = canvas_origin
    if origin_x < 0 or origin_y < 0 or origin_x + width > canvas_size or origin_y + height > canvas_size:
        raise osrsPipelineError("MBTiles canvas origin does not contain the rendered image")
    content_image = Image.fromarray(image_array)
    padded = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    padded.paste(content_image, (origin_x, origin_y))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()
    connection = sqlite3.connect(output_path)
    try:
        connection.execute("PRAGMA page_size=4096")
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("PRAGMA synchronous=OFF")
        connection.execute("PRAGMA locking_mode=EXCLUSIVE")
        connection.execute("CREATE TABLE metadata (name TEXT NOT NULL, value TEXT NOT NULL)")
        connection.execute(
            "CREATE TABLE tiles (zoom_level INTEGER NOT NULL, "
            "tile_column INTEGER NOT NULL, tile_row INTEGER NOT NULL, tile_data BLOB NOT NULL)"
        )
        connection.execute(
            "CREATE UNIQUE INDEX tile_index ON tiles "
            "(zoom_level, tile_column, tile_row)"
        )
        source_content_bounds = _osrs_alpha_pixel_bounds(image_array)
        content_pixel_bounds = (
            source_content_bounds[0] + origin_x,
            source_content_bounds[1] + origin_y,
            source_content_bounds[2] + origin_x,
            source_content_bounds[3] + origin_y,
        )
        content_bounds = _osrs_content_latlon_bounds(
            content_pixel_bounds,
            canvas_size,
        )
        serialized_content_bounds = ",".join(
            _osrs_format_number(value) for value in content_bounds
        )
        metadata = {
            "bounds": serialized_content_bounds,
            "description": "Cache-and-Wiki-derived OSRS realm-local raster",
            "format": "png",
            "maxzoom": str(native_zoom),
            "minzoom": "0",
            "name": name,
            "osrs_content_bounds": serialized_content_bounds,
            "osrs_content_pixel_bounds": ",".join(
                str(value) for value in content_pixel_bounds
            ),
            "osrs_canvas_size": str(canvas_size),
            "osrs_canvas_origin_pixels": f"{origin_x},{origin_y}",
            "osrs_horizontal_padding_pixels": str(
                canvas_size - (content_pixel_bounds[2] - content_pixel_bounds[0])
            ),
            "osrs_vertical_padding_pixels": str(
                canvas_size - (content_pixel_bounds[3] - content_pixel_bounds[1])
            ),
            "osrs_wrap_policy": (
                "finite-content-envelope; four-sided-center-edge-overbound; "
                "horizontal-wrap-disabled"
            ),
            "osrs_tile_size": str(tile_size),
            "scheme": "tms",
            "type": "overlay",
            "version": "1",
        }
        connection.executemany(
            "INSERT INTO metadata(name, value) VALUES (?, ?)", sorted(metadata.items())
        )

        tile_count = 0
        for zoom in range(native_zoom + 1):
            size = tile_size * (2**zoom)
            zoom_image = (
                padded
                if zoom == native_zoom
                else padded.resize((size, size), Image.Resampling.NEAREST)
            )
            dimension = 2**zoom
            for tile_x in range(dimension):
                for tile_y in range(dimension):
                    box = (
                        tile_x * tile_size,
                        tile_y * tile_size,
                        (tile_x + 1) * tile_size,
                        (tile_y + 1) * tile_size,
                    )
                    tile = zoom_image.crop(box)
                    if tile.getchannel("A").getbbox() is None:
                        continue
                    tile_row = dimension - 1 - tile_y
                    connection.execute(
                        "INSERT INTO tiles(zoom_level, tile_column, tile_row, tile_data) "
                        "VALUES (?, ?, ?, ?)",
                        (zoom, tile_x, tile_row, _osrs_png_bytes(tile)),
                    )
                    tile_count += 1
        connection.commit()
        connection.execute("VACUUM")
        connection.commit()
    finally:
        connection.close()

    sqlite_version_number = (
        sqlite3.sqlite_version_info[0] * 1_000_000
        + sqlite3.sqlite_version_info[1] * 1_000
        + sqlite3.sqlite_version_info[2]
    )
    with output_path.open("rb") as source:
        sqlite_header = source.read(100)
    if (
        len(sqlite_header) < 100
        or sqlite_header[:16] != b"SQLite format 3\x00"
        or int.from_bytes(sqlite_header[96:100], "big") != sqlite_version_number
    ):
        raise osrsPipelineError(
            "MBTiles SQLite file-header serializer version does not match runtime"
        )

    return {
        "path": (
            str(output_path)
            if release_root is None
            else osrs_release_relative_path(output_path, release_root)
        ),
        "sha256": osrs_sha256_file(output_path),
        "bytes": output_path.stat().st_size,
        "tile_size": tile_size,
        "min_zoom": 0,
        "max_zoom": native_zoom,
        "tile_count": tile_count,
        "canvas_size": canvas_size,
        "canvas_origin": [origin_x, origin_y],
        "content_pixel_bounds": list(content_pixel_bounds),
        "content_latlon_bounds": list(content_bounds),
        "sqlite_version_number": sqlite_version_number,
    }


def osrs_shared_realm_canvas_size(
    rendered_assets: Sequence[Mapping[str, Any]],
    *,
    is_surface: bool,
    tile_size: int = OSRS_TILE_SIZE,
) -> int:
    """Choose one four-sided-padded canvas shared by every plane in a realm."""

    return int(
        osrs_shared_realm_canvas_layout(
            rendered_assets,
            is_surface=is_surface,
            tile_size=tile_size,
        )["canvas_size"]
    )


def osrs_shared_realm_canvas_layout(
    rendered_assets: Sequence[Mapping[str, Any]],
    *,
    is_surface: bool,
    tile_size: int = OSRS_TILE_SIZE,
) -> dict[str, int]:
    """Choose one shared canvas with finite overbound at a common source-pixel scale.

    `is_surface` remains part of the public producer interface so old callers cannot
    accidentally select a different geometry policy. Surface and underground realms
    intentionally use the same finite, non-periodic layout.
    """

    if not rendered_assets:
        raise osrsPipelineError("shared realm canvas requires at least one rendered asset")
    if tile_size <= 0 or tile_size & (tile_size - 1):
        raise osrsPipelineError("shared realm canvas tile size must be a power of two")

    maximum_width = 0
    maximum_height = 0
    for asset in rendered_assets:
        width = _osrs_int(asset.get("width"), "width")
        height = _osrs_int(asset.get("height"), "height")
        bounds = asset.get("content_pixel_bounds")
        if (
            width <= 0
            or height <= 0
            or not isinstance(bounds, Sequence)
            or isinstance(bounds, (str, bytes))
            or len(bounds) != 4
        ):
            raise osrsPipelineError("shared realm canvas has malformed rendered geometry")
        min_x, min_y, max_x, max_y = (
            _osrs_int(value, "content_pixel_bounds[]") for value in bounds
        )
        if not (0 <= min_x < max_x <= width and 0 <= min_y < max_y <= height):
            raise osrsPipelineError("shared realm canvas content bounds exceed rendered image")
        maximum_width = max(maximum_width, width)
        maximum_height = max(maximum_height, height)
    del is_surface
    required = max(
        2 * max(maximum_width, maximum_height),
        maximum_width + 2 * OSRS_DEFAULT_CAMERA_EDGE_PADDING_PIXELS,
        maximum_height + 2 * OSRS_DEFAULT_CAMERA_EDGE_PADDING_PIXELS,
    )
    native_zoom = max(0, math.ceil(math.log2(required / tile_size)))
    canvas_size = tile_size * (2**native_zoom)
    origin_x = (canvas_size - maximum_width) // 2
    origin_y = (canvas_size - maximum_height) // 2
    if origin_x < 0 or origin_y < 0:
        raise osrsPipelineError("finite realm canvas cannot contain rendered geometry")
    return {
        "canvas_size": canvas_size,
        "origin_x": origin_x,
        "origin_y": origin_y,
        "rendered_width": maximum_width,
        "rendered_height": maximum_height,
    }


def osrs_assert_mbtiles_alpha_matches_mask(
    mbtiles_path: Path,
    mask: np.ndarray,
    mbtiles: Mapping[str, Any],
) -> None:
    expected = np.asarray(mask)
    if expected.ndim != 2 or expected.dtype != np.bool_:
        raise osrsPipelineError("display mask must be a two-dimensional boolean array")
    tile_size = _osrs_int(mbtiles.get("tile_size"), "tile_size")
    max_zoom = _osrs_int(mbtiles.get("max_zoom"), "max_zoom")
    canvas_size = _osrs_int(mbtiles.get("canvas_size"), "canvas_size")
    canvas_origin = mbtiles.get("canvas_origin", [0, 0])
    if (
        not isinstance(canvas_origin, Sequence)
        or isinstance(canvas_origin, (str, bytes))
        or len(canvas_origin) != 2
    ):
        raise osrsPipelineError("MBTiles canvas origin metadata is malformed")
    origin_x, origin_y = (
        _osrs_int(value, "canvas_origin[]") for value in canvas_origin
    )
    if tile_size <= 0 or canvas_size != tile_size * (2**max_zoom):
        raise osrsPipelineError("MBTiles native zoom metadata is internally inconsistent")
    dimension = 2**max_zoom
    height, width = expected.shape
    if (
        origin_x < 0
        or origin_y < 0
        or origin_x + width > canvas_size
        or origin_y + height > canvas_size
    ):
        raise osrsPipelineError("display mask exceeds MBTiles canvas")

    expected_tiles: set[tuple[int, int]] = set()
    first_tile_x = origin_x // tile_size
    first_tile_y = origin_y // tile_size
    final_tile_x = math.ceil((origin_x + width) / tile_size)
    final_tile_y = math.ceil((origin_y + height) / tile_size)
    for tile_y in range(first_tile_y, final_tile_y):
        for tile_x in range(first_tile_x, final_tile_x):
            expected_tile = _osrs_mask_tile_at_canvas_position(
                expected,
                tile_x=tile_x,
                tile_y=tile_y,
                tile_size=tile_size,
                origin_x=origin_x,
                origin_y=origin_y,
            )
            if np.any(expected_tile):
                expected_tiles.add((tile_x, tile_y))

    seen_tiles: set[tuple[int, int]] = set()
    connection = sqlite3.connect(mbtiles_path)
    try:
        rows = connection.execute(
            "SELECT tile_column, tile_row, tile_data FROM tiles WHERE zoom_level = ?",
            (max_zoom,),
        )
        for tile_column, tile_row, tile_data in rows:
            tile_x = int(tile_column)
            tile_y = dimension - 1 - int(tile_row)
            if not (0 <= tile_x < dimension and 0 <= tile_y < dimension):
                raise osrsPipelineError("MBTiles native tile coordinate is outside pyramid bounds")
            with Image.open(io.BytesIO(tile_data)) as tile:
                if tile.size != (tile_size, tile_size):
                    raise osrsPipelineError("MBTiles native tile has unexpected dimensions")
                observed = np.asarray(tile.getchannel("A")) > 0
            expected_tile = _osrs_mask_tile_at_canvas_position(
                expected,
                tile_x=tile_x,
                tile_y=tile_y,
                tile_size=tile_size,
                origin_x=origin_x,
                origin_y=origin_y,
            )
            if not np.array_equal(observed, expected_tile):
                raise osrsPipelineError(
                    "MBTiles native alpha does not match the display mask at "
                    f"z={max_zoom}, x={tile_x}, y={tile_y}"
                )
            seen_tiles.add((tile_x, tile_y))
    finally:
        connection.close()
    missing_tiles = expected_tiles - seen_tiles
    if missing_tiles:
        raise osrsPipelineError(
            f"MBTiles omitted native tiles containing display alpha: {sorted(missing_tiles)[:8]}"
        )


def _osrs_mask_tile_at_canvas_position(
    mask: np.ndarray,
    *,
    tile_x: int,
    tile_y: int,
    tile_size: int,
    origin_x: int,
    origin_y: int,
) -> np.ndarray:
    expected_tile = np.zeros((tile_size, tile_size), dtype=np.bool_)
    height, width = mask.shape
    canvas_x0 = tile_x * tile_size
    canvas_y0 = tile_y * tile_size
    source_x0 = max(0, canvas_x0 - origin_x)
    source_y0 = max(0, canvas_y0 - origin_y)
    source_x1 = min(width, canvas_x0 + tile_size - origin_x)
    source_y1 = min(height, canvas_y0 + tile_size - origin_y)
    if source_x0 >= source_x1 or source_y0 >= source_y1:
        return expected_tile
    destination_x0 = origin_x + source_x0 - canvas_x0
    destination_y0 = origin_y + source_y0 - canvas_y0
    expected_tile[
        destination_y0 : destination_y0 + source_y1 - source_y0,
        destination_x0 : destination_x0 + source_x1 - source_x0,
    ] = mask[source_y0:source_y1, source_x0:source_x1]
    return expected_tile


def osrs_boundary_provenance_report(
    realms: Sequence[Mapping[str, Any]],
    prior_realms: Sequence[Mapping[str, Any]] = (),
) -> dict[str, Any]:
    """Describe the finite camera-boundary provenance for every published asset."""

    entries: list[dict[str, Any]] = []
    for realm in realms:
        realm_id = str(realm.get("id", ""))
        canonical_name = str(realm.get("canonical_name", ""))
        assets = realm.get("assets")
        if not isinstance(assets, list) or not assets:
            raise osrsPipelineError(f"boundary audit requires assets for {realm_id}")
        canvas_sizes = {asset.get("canvas_size") for asset in assets if isinstance(asset, Mapping)}
        if len(canvas_sizes) != 1:
            raise osrsPipelineError(
                f"boundary audit requires one shared canvas for every plane: {realm_id}"
            )
        shared_canvas_size = next(iter(canvas_sizes))
        if not isinstance(shared_canvas_size, int) or shared_canvas_size <= 0:
            raise osrsPipelineError(
                f"boundary audit has invalid shared canvas: {realm_id}"
            )
        realm_pixel_bounds = [
            asset.get("content_pixel_bounds")
            for asset in assets
            if isinstance(asset, Mapping)
        ]
        if any(not isinstance(bounds, list) or len(bounds) != 4 for bounds in realm_pixel_bounds):
            raise osrsPipelineError(
                f"boundary audit has malformed realm content bounds: {realm_id}"
            )
        realm_min_x = min(int(bounds[0]) for bounds in realm_pixel_bounds)
        realm_min_y = min(int(bounds[1]) for bounds in realm_pixel_bounds)
        realm_max_x = max(int(bounds[2]) for bounds in realm_pixel_bounds)
        realm_max_y = max(int(bounds[3]) for bounds in realm_pixel_bounds)
        realm_union_width = realm_max_x - realm_min_x
        realm_union_height = realm_max_y - realm_min_y
        realm_horizontal_padding = shared_canvas_size - realm_union_width
        realm_vertical_padding = shared_canvas_size - realm_union_height
        if realm_horizontal_padding < realm_union_width:
            raise osrsPipelineError(
                f"boundary audit requires one content-width of horizontal padding: {realm_id}"
            )
        if realm_vertical_padding < realm_union_height:
            raise osrsPipelineError(
                f"boundary audit requires one content-height of vertical padding: {realm_id}"
            )
        four_sided_padding = {
            "left": realm_min_x,
            "top": realm_min_y,
            "right": shared_canvas_size - realm_max_x,
            "bottom": shared_canvas_size - realm_max_y,
        }
        if min(four_sided_padding.values()) < OSRS_DEFAULT_CAMERA_EDGE_PADDING_PIXELS:
            raise osrsPipelineError(
                "boundary audit cannot preserve the common default source-pixel scale "
                f"and four-sided overbound: {realm_id}"
            )
        for asset in assets:
            if not isinstance(asset, Mapping):
                raise osrsPipelineError(f"boundary audit asset is not an object: {realm_id}")
            pixel_bounds = asset.get("content_pixel_bounds")
            latlon_bounds = asset.get("content_latlon_bounds")
            canvas_size = asset.get("canvas_size")
            if (
                not isinstance(pixel_bounds, list)
                or len(pixel_bounds) != 4
                or not all(isinstance(value, int) for value in pixel_bounds)
                or not isinstance(latlon_bounds, list)
                or len(latlon_bounds) != 4
                or not all(isinstance(value, (int, float)) for value in latlon_bounds)
                or not isinstance(canvas_size, int)
                or canvas_size <= 0
            ):
                raise osrsPipelineError(
                    f"boundary audit has malformed content bounds: {realm_id}"
                )
            min_x, min_y, max_x, max_y = pixel_bounds
            west, south, east, north = (float(value) for value in latlon_bounds)
            if not (
                0 <= min_x < max_x <= canvas_size
                and 0 <= min_y < max_y <= canvas_size
            ):
                raise osrsPipelineError(
                    f"boundary audit pixel bounds exceed canvas: {realm_id}"
                )
            if not (west < east and south < north):
                raise osrsPipelineError(
                    f"boundary audit longitude/latitude bounds are not finite: {realm_id}"
                )
            ownership_pixels = int(asset.get("ownership_pixel_count", 0))
            display_pixels = int(asset.get("display_pixel_count", 0))
            transparent_owned_pixels = int(
                asset.get("transparent_owned_pixel_count", 0)
            )
            content_bearing_pixels = int(asset.get("content_bearing_pixel_count", 0))
            if (
                ownership_pixels < 1
                or display_pixels < 1
                or transparent_owned_pixels < 0
                or content_bearing_pixels < 0
                or display_pixels + transparent_owned_pixels != ownership_pixels
            ):
                raise osrsPipelineError(
                    f"boundary audit has inconsistent alpha accounting: {realm_id}"
                )
            dateline_adjacent = min_x == 0 or max_x == canvas_size
            entries.append(
                {
                    "realm_id": realm_id,
                    "canonical_name": canonical_name,
                    "plane": int(asset.get("plane", -1)),
                    "mbtiles_path": str(asset.get("mbtiles_path", "")),
                    "mbtiles_declared_bounds": list(latlon_bounds),
                    "source_mbtiles_metadata": {
                        "bounds": ",".join(
                            _osrs_format_number(value) for value in latlon_bounds
                        ),
                        "content_pixel_bounds": list(pixel_bounds),
                        "content_latlon_bounds": list(latlon_bounds),
                        "canvas_size": canvas_size,
                        "alpha_is_display_mask": True,
                    },
                    "canvas_size": canvas_size,
                    "shared_realm_canvas_size": shared_canvas_size,
                    "content_pixel_bounds": list(pixel_bounds),
                    "content_latlon_bounds": list(latlon_bounds),
                    "realm_union_content_pixel_bounds": [
                        realm_min_x,
                        realm_min_y,
                        realm_max_x,
                        realm_max_y,
                    ],
                    "realm_union_content_width_pixels": realm_union_width,
                    "realm_union_content_height_pixels": realm_union_height,
                    "realm_horizontal_padding_pixels": realm_horizontal_padding,
                    "realm_vertical_padding_pixels": realm_vertical_padding,
                    "horizontal_padding_at_least_content_width": (
                        realm_horizontal_padding >= realm_union_width
                    ),
                    "vertical_padding_at_least_content_height": (
                        realm_vertical_padding >= realm_union_height
                    ),
                    "four_sided_padding_pixels": dict(four_sided_padding),
                    "default_camera": {
                        "relative_zoom_to_native": OSRS_DEFAULT_CAMERA_RELATIVE_ZOOM,
                        "source_pixel_scale": 2**OSRS_DEFAULT_CAMERA_RELATIVE_ZOOM,
                        "maximum_viewport_extent_pixels": (
                            OSRS_DEFAULT_CAMERA_MAX_VIEWPORT_EXTENT_PIXELS
                        ),
                        "required_edge_padding_pixels": (
                            OSRS_DEFAULT_CAMERA_EDGE_PADDING_PIXELS
                        ),
                        "common_source_pixel_scale_supported": True,
                    },
                    "alpha_accounting": {
                        "ownership_pixel_count": ownership_pixels,
                        "display_pixel_count": display_pixels,
                        "transparent_owned_pixel_count": transparent_owned_pixels,
                        "content_bearing_pixel_count": content_bearing_pixels,
                        "transparent_canvas_pixel_count": canvas_size * canvas_size
                        - display_pixels,
                    },
                    "source_bounds": asset.get("source_bounds", []),
                    "display_bounds": asset.get("display_bounds", {}),
                    "full_width_canvas": min_x == 0 and max_x == canvas_size,
                    "full_height_canvas": min_y == 0 and max_y == canvas_size,
                    "dateline_adjacent": dateline_adjacent,
                    "dateline_edge_evidence": (
                        "content_reaches_web_mercator_canvas_edge"
                        if dateline_adjacent
                        else "content_is_inset_from_canvas_edges"
                    ),
                    "horizontal_wrap_enabled": False,
                    "visible_composition_longitude_span_degrees": (
                        360.0 * realm_union_width / shared_canvas_size
                    ),
                    "derivation": "alpha-content-pixel-bounds-to-web-mercator",
                }
            )
    current_assets = {
        (str(realm.get("id", "")), int(asset.get("plane", -1))): asset
        for realm in realms
        for asset in realm.get("assets", [])
        if isinstance(asset, Mapping)
    }
    superseded_full_width: list[dict[str, Any]] = []
    for prior_realm in prior_realms:
        prior_realm_id = str(prior_realm.get("id", ""))
        for prior_asset in prior_realm.get("assets", []):
            if not isinstance(prior_asset, Mapping):
                continue
            prior_canvas = prior_asset.get("canvas_size")
            prior_bounds = prior_asset.get("content_pixel_bounds")
            if (
                not isinstance(prior_canvas, int)
                or not isinstance(prior_bounds, list)
                or len(prior_bounds) != 4
                or int(prior_bounds[0]) != 0
                or int(prior_bounds[2]) != prior_canvas
            ):
                continue
            plane = int(prior_asset.get("plane", -1))
            current = current_assets.get((prior_realm_id, plane))
            if current is None:
                raise osrsPipelineError(
                    f"prior full-width asset disappeared instead of closing: {prior_realm_id} floor {plane}"
                )
            current_canvas = _osrs_int(current.get("canvas_size"), "canvas_size")
            current_bounds = current.get("content_pixel_bounds")
            if not isinstance(current_bounds, list) or len(current_bounds) != 4:
                raise osrsPipelineError("current closure asset has malformed bounds")
            current_width = int(current_bounds[2]) - int(current_bounds[0])
            closed = current_width < current_canvas
            if not closed:
                raise osrsPipelineError(
                    f"prior full-width asset remains periodic: {prior_realm_id} floor {plane}"
                )
            superseded_full_width.append(
                {
                    "realm_id": prior_realm_id,
                    "plane": plane,
                    "prior_canvas_size": prior_canvas,
                    "prior_content_pixel_bounds": list(prior_bounds),
                    "current_canvas_size": current_canvas,
                    "current_content_pixel_bounds": list(current_bounds),
                    "current_horizontal_padding_pixels": current_canvas - current_width,
                    "closed": True,
                }
            )

    return {
        "schema_version": 1,
        "policy": "finite-content-envelope; four-sided-center-edge-overbound; horizontal-wrap-disabled; common-source-pixel-default-scale",
        "coordinate_origin": "shared-four-sided-padded-web-mercator-canvas",
        "asset_count": len(entries),
        "realm_count": len(realms),
        "superseded_full_width_closure": {
            "asset_count": len(superseded_full_width),
            "realm_count": len({row["realm_id"] for row in superseded_full_width}),
            "all_closed": all(row["closed"] for row in superseded_full_width),
            "rows": superseded_full_width,
        },
        "entries": entries,
    }


def osrs_build_manifest_records(
    inventory: Mapping[str, Any],
    basemaps: Sequence[Mapping[str, Any]],
    available_planes: Sequence[int] = (0, 1, 2, 3),
) -> list[dict[str, Any]]:
    """Reconcile all native definitions and Wiki custom views deterministically."""

    raw_definitions = inventory.get("definitions")
    if not isinstance(raw_definitions, list):
        raise osrsPipelineError("inventory.definitions must be an array")
    definitions = sorted(
        (_osrs_mapping(item, "definitions[]") for item in raw_definitions),
        key=lambda item: _osrs_int(item.get("file_id"), "file_id"),
    )
    wiki_by_id: dict[int, Mapping[str, Any]] = {}
    for item in basemaps:
        value = _osrs_mapping(item, "basemaps[]")
        map_id = _osrs_int(value.get("mapId"), "mapId")
        if map_id in wiki_by_id:
            raise osrsPipelineError(f"duplicate Wiki mapID: {map_id}")
        wiki_by_id[map_id] = value

    definition_ids = {
        _osrs_int(definition.get("file_id"), "file_id") for definition in definitions
    }
    wiki_native_ids = {map_id for map_id in wiki_by_id if 0 <= map_id < 10000}
    if definition_ids != wiki_native_ids:
        raise osrsPipelineError(
            "cache/Wiki native version mismatch: "
            f"missing_in_wiki={sorted(definition_ids - wiki_native_ids)}, "
            f"missing_in_cache={sorted(wiki_native_ids - definition_ids)}"
        )

    realms: list[dict[str, Any]] = []
    surface_count = 0
    for definition in definitions:
        file_id = _osrs_int(definition.get("file_id"), "file_id")
        is_surface = bool(definition.get("is_surface"))
        surface_count += int(is_surface)
        realm_id = osrs_stable_native_realm_id(definition)
        wiki = wiki_by_id.get(file_id)
        cache_name = str(definition.get("name", "")).strip()
        if not cache_name:
            raise osrsPipelineError(f"definition {file_id} has no display name")
        aliases: set[str] = {str(definition.get("safe_name", "")).strip()}
        if wiki is not None and str(wiki.get("name", "")).strip() != cache_name:
            aliases.add(str(wiki.get("name", "")).strip())
        aliases.discard("")
        aliases.discard(cache_name)
        all_pieces = osrs_definition_pieces(definition)
        source_rects = tuple(
            sorted(
                {
                    osrs_rect_from_json(piece["normalized"]["source_bounds"])
                    for piece in all_pieces
                }
            )
        )
        display_rects = tuple(
            sorted(
                {
                    osrs_rect_from_json(piece["normalized"]["display_bounds"])
                    for piece in all_pieces
                }
            )
        )
        if not source_rects or not display_rects:
            raise osrsPipelineError(f"definition {file_id} has no composite geometry")
        source_mask = _osrs_piece_mask_manifest(all_pieces, "source_bounds")
        display_mask = _osrs_piece_mask_manifest(all_pieces, "display_bounds")
        position = _osrs_mapping(definition.get("position"), "position")
        center = (
            list(wiki.get("center", []))
            if wiki is not None
            else [
                _osrs_int(position.get("x"), "position.x"),
                _osrs_int(position.get("y"), "position.y"),
            ]
        )
        if len(center) != 2:
            raise osrsPipelineError(f"mapID {file_id} center must have two coordinates")
        declared_planes = osrs_definition_planes(definition)
        planes = tuple(plane for plane in declared_planes if plane in available_planes)
        if not planes:
            raise osrsPipelineError(
                f"definition {file_id} has no plane in available source rasters"
            )
        default_plane = _osrs_int(position.get("plane"), "position.plane")
        if default_plane not in planes:
            default_plane = planes[0]
        realms.append(
            {
                "id": realm_id,
                "canonical_name": cache_name,
                "aliases": sorted(aliases, key=str.casefold),
                "group": "surface" if is_surface else "realms",
                "is_surface": is_surface,
                "native_file_id": file_id,
                "map_id": file_id if wiki is not None else None,
                "article": None,
                "center": [_osrs_int(center[0], "center.x"), _osrs_int(center[1], "center.y")],
                "default_plane": default_plane,
                "planes": list(planes),
                "cache_declared_planes": list(declared_planes),
                "source_mask": source_mask,
                "display_mask": display_mask,
                "components": _osrs_plane_components(all_pieces, "display_bounds"),
                "links": [],
                "source_revisions": {},
                "confidence": {
                    "classification": "authoritative_cache_is_surface",
                    "value": 1.0,
                },
                "ambiguity": {
                    "blocks_publication": False,
                    "reasons": [],
                    "unresolved_link_count": 0,
                },
                "accounting_owner_realm_id": realm_id,
                "assets": [],
            }
        )

    if surface_count != 1:
        raise osrsPipelineError(f"expected one surface definition, found {surface_count}")

    for map_id in sorted(key for key in wiki_by_id if key >= 10000):
        wiki = wiki_by_id[map_id]
        game_bounds = _osrs_wiki_bounds(wiki)
        mask = _osrs_mask_manifest((game_bounds,), plane=0)
        center = wiki.get("center")
        if not isinstance(center, list) or len(center) != 2:
            raise osrsPipelineError(f"mapID {map_id} center must have two coordinates")
        realms.append(
            {
                "id": osrs_other_map_id(map_id),
                "canonical_name": str(wiki.get("name", "")).strip(),
                "aliases": [],
                "group": "other_maps",
                "is_surface": False,
                "native_file_id": None,
                "map_id": map_id,
                "article": None,
                "center": [_osrs_int(center[0], "center.x"), _osrs_int(center[1], "center.y")],
                "default_plane": 0,
                "planes": [0],
                "cache_declared_planes": [],
                "source_mask": mask,
                "display_mask": mask,
                "components": [
                    {**component, "plane": 0}
                    for component in _osrs_components((game_bounds,))
                ],
                "links": [],
                "source_revisions": {},
                "confidence": {
                    "classification": "pinned_wiki_structured_view_bounds",
                    "value": 0.9,
                },
                "ambiguity": {
                    "blocks_publication": False,
                    "reasons": [],
                    "unresolved_link_count": 0,
                },
                "accounting_owner_realm_id": None,
                "assets": [],
            }
        )

    ids = [realm["id"] for realm in realms]
    if len(ids) != len(set(ids)):
        raise osrsPipelineError("reconciled manifest has duplicate stable IDs")
    realms.sort(
        key=lambda realm: (
            {"surface": 0, "realms": 1, "other_maps": 2}[realm["group"]],
            realm["canonical_name"].casefold(),
            realm["id"],
        )
    )
    return realms


def osrs_reconcile_intermap_links(
    records: Sequence[MutableMapping[str, Any]],
    inventory: Mapping[str, Any],
    alignment: Mapping[str, Any],
) -> dict[str, int]:
    """Attach exact cache-script links; unresolved endpoints stay unavailable."""

    definitions = inventory.get("definitions")
    links = alignment.get("intermap_links")
    if not isinstance(definitions, list) or not isinstance(links, list):
        raise osrsPipelineError("inventory definitions and alignment links must be arrays")
    zone_owners: dict[tuple[int, int, int], set[str]] = {}
    for raw_definition in definitions:
        definition = _osrs_mapping(raw_definition, "definitions[]")
        realm_id = osrs_stable_native_realm_id(definition)
        for piece in osrs_definition_pieces(definition):
            source = _osrs_mapping(
                _osrs_mapping(piece.get("normalized"), "piece.normalized").get(
                    "source_bounds"
                ),
                "source_bounds",
            )
            rect = osrs_rect_from_json(source)
            plane_min = _osrs_int(source.get("plane_min"), "plane_min")
            plane_max = _osrs_int(source.get("plane_max"), "plane_max")
            for plane in range(plane_min, plane_max + 1):
                for zone_x in range(rect.min_x // 8, rect.max_x // 8):
                    for zone_y in range(rect.min_y // 8, rect.max_y // 8):
                        zone_owners.setdefault((plane, zone_x, zone_y), set()).add(
                            realm_id
                        )

    records_by_id = {str(record["id"]): record for record in records}
    available = 0
    unavailable = 0
    cross_realm = 0
    for raw_link in sorted(
        links,
        key=lambda value: str(_osrs_mapping(value, "intermap_links[]").get("id")),
    ):
        link = _osrs_mapping(raw_link, "intermap_links[]")
        from_position = _osrs_mapping(link.get("from_position"), "from_position")
        to_position = _osrs_mapping(link.get("to_position"), "to_position")
        from_ids = _osrs_position_realm_ids(from_position, zone_owners)
        to_ids = _osrs_position_realm_ids(to_position, zone_owners)
        is_available = len(from_ids) == 1 and len(to_ids) == 1
        from_id = from_ids[0] if len(from_ids) == 1 else None
        to_id = to_ids[0] if len(to_ids) == 1 else None
        reasons: list[str] = []
        if len(from_ids) != 1:
            reasons.append(
                "from_endpoint_unowned"
                if not from_ids
                else "from_endpoint_has_multiple_native_owners"
            )
        if len(to_ids) != 1:
            reasons.append(
                "to_endpoint_unowned"
                if not to_ids
                else "to_endpoint_has_multiple_native_owners"
            )
        reconciled = {
            "id": str(link.get("id")),
            "from_realm_id": from_id,
            "to_realm_id": to_id,
            "from_position": dict(from_position),
            "to_position": dict(to_position),
            "direction": str(link.get("direction", "")),
            "availability": "available" if is_available else "unavailable",
            "authoritative": is_available,
            "confidence": 1.0 if is_available else 0.0,
            "evidence": (
                ["cache_client_script_1705_1706", "exact_cache_membership_endpoints"]
                if is_available
                else ["cache_client_script_1705_1706"]
            ),
            "unavailable_reasons": reasons,
        }
        attachment_ids = sorted(set(from_ids) | set(to_ids))
        for realm_id in attachment_ids:
            if realm_id in records_by_id:
                records_by_id[realm_id]["links"].append(reconciled)
        if is_available:
            available += 1
            cross_realm += int(from_id != to_id)
        else:
            unavailable += 1

    for record in records:
        record["links"].sort(key=lambda value: value["id"])
        unresolved_count = sum(
            link["availability"] == "unavailable" for link in record["links"]
        )
        record["ambiguity"]["unresolved_link_count"] = unresolved_count
        if unresolved_count:
            record["ambiguity"]["reasons"] = [
                "unresolved_intermap_links_are_unavailable"
            ]
    return {
        "total": len(links),
        "available": available,
        "unavailable": unavailable,
        "available_cross_realm": cross_realm,
    }


def osrs_manifest_schema() -> dict[str, Any]:
    """Return the strict public manifest schema emitted with every candidate."""

    from osrs_release_toolchain import osrs_load_release_toolchain_contract

    sqlite_version_number = int(
        osrs_load_release_toolchain_contract()["runtime"][
            "sqlite_version_number"
        ]
    )

    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://local.osrswiki/non-surface-realms/underground-realms.schema.json",
        "title": "OSRS underground and instanced realms manifest",
        "type": "object",
        "additionalProperties": False,
        "required": [
            "schema_version",
            "candidate",
            "product",
            "inputs",
            "accounting",
            "realms",
            "selector",
            "intermap_links",
        ],
        "properties": {
            "schema_version": {"const": OSRS_SCHEMA_VERSION},
            "candidate": {"type": "string", "pattern": "^[0-9]{3}$"},
            "product": {
                "type": "object",
                "additionalProperties": False,
                "required": ["label", "application_id"],
                "properties": {
                    "label": {"const": "OSRS Underground Maps"},
                    "application_id": {
                        "const": "com.omiyawaki.osrswiki.undergroundmaps"
                    },
                },
            },
            "inputs": {"type": "object"},
            "accounting": {"type": "object"},
            "realms": {
                "type": "array",
                "minItems": 1,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": [
                        "id",
                        "canonical_name",
                        "aliases",
                        "group",
                        "is_surface",
                        "native_file_id",
                        "map_id",
                        "article",
                        "center",
                        "default_plane",
                        "planes",
                        "cache_declared_planes",
                        "source_mask",
                        "display_mask",
                        "components",
                        "links",
                        "source_revisions",
                        "confidence",
                        "ambiguity",
                        "accounting_owner_realm_id",
                        "accounting_pixel_count",
                        "assets",
                    ],
                    "properties": {
                        "id": {"type": "string", "minLength": 1},
                        "canonical_name": {"type": "string", "minLength": 1},
                        "aliases": {"type": "array", "items": {"type": "string"}},
                        "group": {"enum": ["surface", "realms", "other_maps"]},
                        "is_surface": {"type": "boolean"},
                        "native_file_id": {"type": ["integer", "null"]},
                        "map_id": {"type": ["integer", "null"]},
                        "article": {"type": ["string", "null"]},
                        "center": {
                            "type": "array",
                            "prefixItems": [{"type": "integer"}, {"type": "integer"}],
                            "minItems": 2,
                            "maxItems": 2,
                        },
                        "default_plane": {"type": "integer"},
                        "planes": {
                            "type": "array",
                            "minItems": 1,
                            "items": {"type": "integer"},
                            "uniqueItems": True,
                        },
                        "cache_declared_planes": {
                            "type": "array",
                            "items": {"type": "integer"},
                            "uniqueItems": True,
                        },
                        "source_mask": {"type": "object"},
                        "display_mask": {"type": "object"},
                        "components": {"type": "array"},
                        "links": {"type": "array"},
                        "source_revisions": {"type": "object"},
                        "confidence": {"type": "object"},
                        "ambiguity": {"type": "object"},
                        "accounting_owner_realm_id": {"type": ["string", "null"]},
                        "accounting_pixel_count": {"type": "integer", "minimum": 0},
                        "pixel_ownership_status": {
                            "const": "authoritative_renderer_provenance"
                        },
                        "pixel_ownership_confidence": {"const": 1.0},
                        "semantic_identity_status": {
                            "const": "unresolved_generic_cache_region"
                        },
                        "semantic_identity_confidence": {"const": 0.0},
                        "candidate_wiki_map_ids": {
                            "type": "array",
                            "items": {"type": "integer", "minimum": 10000},
                            "uniqueItems": True,
                        },
                        "cache_region_ids": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 1,
                            "items": {
                                "type": "integer",
                                "minimum": 0,
                                "maximum": 65535,
                            },
                            "uniqueItems": True,
                        },
                        "accounting_provenance_codes_by_rendered_plane": {
                            "type": "object",
                            "minProperties": 1,
                            "additionalProperties": False,
                            "patternProperties": {
                                "^[0-3]$": {
                                    "type": "array",
                                    "minItems": 1,
                                    "items": {"type": "integer", "minimum": 1},
                                    "uniqueItems": True,
                                }
                            },
                        },
                        "assets": {
                            "type": "array",
                            "minItems": 1,
                            "items": {
                                "type": "object",
                                "additionalProperties": False,
                                "required": [
                                    "plane",
                                    "mbtiles_path",
                                    "mbtiles_sha256",
                                    "mbtiles_bytes",
                                    "mask_path",
                                    "mask_sha256",
                                    "ownership_mask_path",
                                    "ownership_mask_sha256",
                                    "width",
                                    "height",
                                    "assigned_pixel_count",
                                    "ownership_pixel_count",
                                    "display_pixel_count",
                                    "transparent_owned_pixel_count",
                                    "visible_exact_black_pixel_count",
                                    "identical_rgb_display_collision_count",
                                    "layout_components",
                                    "content_bearing_pixel_count",
                                    "nonblank",
                                    "tile_size",
                                    "min_zoom",
                                    "max_zoom",
                                    "tile_count",
                                    "sqlite_version_number",
                                    "canvas_size",
                                    "content_pixel_bounds",
                                    "content_latlon_bounds",
                                    "source_bounds",
                                    "display_bounds",
                                ],
                                "properties": {
                                    "plane": {"type": "integer"},
                                    "mbtiles_path": {
                                        "type": "string",
                                        "pattern": "^(?!/)(?![A-Za-z]:/)(?!.*(?:^|/)\\.\\.(?:/|$))[^\\\\]+$",
                                    },
                                    "mbtiles_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                                    "mbtiles_bytes": {"type": "integer", "minimum": 1},
                                    "mask_path": {
                                        "type": "string",
                                        "pattern": "^(?!/)(?![A-Za-z]:/)(?!.*(?:^|/)\\.\\.(?:/|$))[^\\\\]+$",
                                    },
                                    "mask_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                                    "ownership_mask_path": {
                                        "type": "string",
                                        "pattern": "^(?!/)(?![A-Za-z]:/)(?!.*(?:^|/)\\.\\.(?:/|$))[^\\\\]+$",
                                    },
                                    "ownership_mask_sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                                    "width": {"type": "integer", "minimum": 1},
                                    "height": {"type": "integer", "minimum": 1},
                                    "assigned_pixel_count": {"type": "integer", "minimum": 1},
                                    "ownership_pixel_count": {"type": "integer", "minimum": 1},
                                    "display_pixel_count": {"type": "integer", "minimum": 1},
                                    "transparent_owned_pixel_count": {
                                        "type": "integer",
                                        "minimum": 0,
                                    },
                                    "visible_exact_black_pixel_count": {
                                        "type": "integer",
                                        "minimum": 0,
                                    },
                                    "identical_rgb_display_collision_count": {
                                        "type": "integer",
                                        "minimum": 0,
                                    },
                                    "layout_components": {"type": "array"},
                                    "content_bearing_pixel_count": {"type": "integer", "minimum": 0},
                                    "nonblank": {"const": True},
                                    "tile_size": {"type": "integer", "minimum": 1},
                                    "min_zoom": {"type": "integer", "minimum": 0},
                                    "max_zoom": {"type": "integer", "minimum": 0},
                                    "tile_count": {"type": "integer", "minimum": 1},
                                    "sqlite_version_number": {
                                        "type": "integer",
                                        "const": sqlite_version_number,
                                    },
                                    "canvas_size": {"type": "integer", "minimum": 1},
                                    "canvas_origin": {
                                        "type": "array",
                                        "prefixItems": [
                                            {"type": "integer", "minimum": 0},
                                            {"type": "integer", "minimum": 0},
                                        ],
                                        "minItems": 2,
                                        "maxItems": 2,
                                    },
                                    "content_pixel_bounds": {"type": "array", "minItems": 4, "maxItems": 4},
                                    "content_latlon_bounds": {"type": "array", "minItems": 4, "maxItems": 4},
                                    "source_bounds": {"type": "array"},
                                    "display_bounds": {"type": "object"},
                                },
                            },
                        },
                    },
                    "allOf": [
                        {
                            "if": {
                                "required": ["id"],
                                "properties": {
                                    "id": {
                                        "type": "string",
                                        "pattern": "^cache-special-region:[0-9]+-[0-9]+$",
                                    }
                                },
                            },
                            "then": {
                                "required": [
                                    "pixel_ownership_status",
                                    "pixel_ownership_confidence",
                                    "semantic_identity_status",
                                    "semantic_identity_confidence",
                                    "candidate_wiki_map_ids",
                                    "cache_region_ids",
                                    "accounting_provenance_codes_by_rendered_plane",
                                ]
                            },
                        }
                    ],
                },
            },
            "selector": {
                "type": "object",
                "additionalProperties": False,
                "required": ["entry_ids", "entry_count", "realm_count", "bijection"],
                "properties": {
                    "entry_ids": {"type": "array", "items": {"type": "string"}},
                    "entry_count": {"type": "integer", "minimum": 1},
                    "realm_count": {"type": "integer", "minimum": 1},
                    "bijection": {"const": True},
                },
            },
            "intermap_links": {
                "type": "object",
                "additionalProperties": False,
                "required": ["total", "available", "unavailable", "available_cross_realm"],
                "properties": {
                    "total": {"type": "integer", "minimum": 0},
                    "available": {"type": "integer", "minimum": 0},
                    "unavailable": {"type": "integer", "minimum": 0},
                    "available_cross_realm": {"type": "integer", "minimum": 0},
                },
            },
        },
    }


def osrs_validate_manifest(manifest: Mapping[str, Any]) -> None:
    """Fail closed on the invariants the standalone app relies upon."""

    if manifest.get("schema_version") != OSRS_SCHEMA_VERSION:
        raise osrsPipelineError("unsupported manifest schema_version")
    product = _osrs_mapping(manifest.get("product"), "product")
    if product.get("label") != "OSRS Underground Maps":
        raise osrsPipelineError("manifest product label mismatch")
    if product.get("application_id") != "com.omiyawaki.osrswiki.undergroundmaps":
        raise osrsPipelineError("manifest application ID mismatch")
    realms = manifest.get("realms")
    if not isinstance(realms, list) or not realms:
        raise osrsPipelineError("manifest.realms must be a nonempty array")
    ids = [str(_osrs_mapping(realm, "realms[]").get("id")) for realm in realms]
    if len(ids) != len(set(ids)):
        raise osrsPipelineError("manifest realm IDs are not unique")
    if sum(realm_id == OSRS_SURFACE_REALM_ID for realm_id in ids) != 1:
        raise osrsPipelineError("manifest must contain exactly one surface-gielinor")
    selector = _osrs_mapping(manifest.get("selector"), "selector")
    selector_ids = selector.get("entry_ids")
    if not isinstance(selector_ids, list) or selector_ids != ids:
        raise osrsPipelineError("selector entries are not a realm-order bijection")
    if selector.get("entry_count") != len(ids) or selector.get("realm_count") != len(ids):
        raise osrsPipelineError("selector/realm counts disagree")
    if selector.get("bijection") is not True:
        raise osrsPipelineError("selector bijection proof is false")
    accounting = _osrs_mapping(manifest.get("accounting"), "accounting")
    checks = _osrs_mapping(accounting.get("checks"), "accounting.checks")
    if checks.get("release_ready") is not True:
        raise osrsPipelineError("manifest references non-release-ready source accounting")
    for realm in realms:
        value = _osrs_mapping(realm, "realms[]")
        realm_id = str(value.get("id", ""))
        if realm_id.startswith("cache-special-region:"):
            match = re.fullmatch(
                r"cache-special-region:([0-9]+)-([0-9]+)", realm_id
            )
            if match is None:
                raise osrsPipelineError(f"invalid special-region ID: {realm_id}")
            region_x, region_y = (int(match.group(1)), int(match.group(2)))
            if not (0 <= region_x <= 255 and 0 <= region_y <= 255):
                raise osrsPipelineError(
                    f"special-region coordinates are outside uint8: {realm_id}"
                )
            region_id = (region_x << 8) | region_y
            if value.get("cache_region_ids") != [region_id]:
                raise osrsPipelineError(
                    f"special backing owner must contain exactly region {region_id}: "
                    f"{realm_id}"
                )
            if value.get("canonical_name") != f"Cache region {region_x}, {region_y}":
                raise osrsPipelineError(
                    f"special backing-owner label is not stable: {realm_id}"
                )
            if value.get("aliases") != []:
                raise osrsPipelineError(
                    f"special backing owner must not guess Wiki aliases: {realm_id}"
                )
            if (
                value.get("group") != "other_maps"
                or value.get("map_id") is not None
                or value.get("pixel_ownership_status")
                != "authoritative_renderer_provenance"
                or value.get("pixel_ownership_confidence") != 1.0
                or value.get("semantic_identity_status")
                != "unresolved_generic_cache_region"
                or value.get("semantic_identity_confidence") != 0.0
            ):
                raise osrsPipelineError(
                    f"special backing-owner confidence fields are invalid: {realm_id}"
                )
            candidates = value.get("candidate_wiki_map_ids")
            if (
                not isinstance(candidates, list)
                or not all(
                    isinstance(candidate, int)
                    and not isinstance(candidate, bool)
                    and candidate >= 10000
                    for candidate in candidates
                )
                or candidates != sorted(set(candidates))
            ):
                raise osrsPipelineError(
                    f"special Wiki candidates are not canonical enrichment: {realm_id}"
                )
            accounting_codes = value.get(
                "accounting_provenance_codes_by_rendered_plane"
            )
            if not isinstance(accounting_codes, Mapping) or not accounting_codes:
                raise osrsPipelineError(
                    f"special backing owner has no accounting codes: {realm_id}"
                )
            for plane, codes in accounting_codes.items():
                if (
                    plane not in {"0", "1", "2", "3"}
                    or not isinstance(codes, list)
                    or not codes
                    or not all(
                        isinstance(code, int)
                        and not isinstance(code, bool)
                        and code > 0
                        for code in codes
                    )
                    or codes != sorted(set(codes))
                ):
                    raise osrsPipelineError(
                        f"special backing-owner accounting codes are invalid: {realm_id}"
                    )
        if value.get("ambiguity", {}).get("blocks_publication") is True:
            raise osrsPipelineError(f"realm {value.get('id')} has blocking ambiguity")
        assets = value.get("assets")
        if not isinstance(assets, list) or not assets:
            raise osrsPipelineError(f"realm {value.get('id')} has no assets")
        for asset in assets:
            asset_value = _osrs_mapping(asset, "realms[].assets[]")
            plane = _osrs_int(asset_value.get("plane"), "realms[].assets[].plane")
            assigned = _osrs_int(
                asset_value.get("assigned_pixel_count"),
                "realms[].assets[].assigned_pixel_count",
            )
            ownership = _osrs_int(
                asset_value.get("ownership_pixel_count"),
                "realms[].assets[].ownership_pixel_count",
            )
            display = _osrs_int(
                asset_value.get("display_pixel_count"),
                "realms[].assets[].display_pixel_count",
            )
            transparent_owned = _osrs_int(
                asset_value.get("transparent_owned_pixel_count"),
                "realms[].assets[].transparent_owned_pixel_count",
            )
            collisions = _osrs_int(
                asset_value.get("identical_rgb_display_collision_count"),
                "realms[].assets[].identical_rgb_display_collision_count",
            )
            if assigned != ownership + collisions:
                raise osrsPipelineError(
                    f"asset ownership accounting is inconsistent for {realm_id} floor {plane}"
                )
            if display > ownership or transparent_owned != ownership - display:
                raise osrsPipelineError(
                    f"asset display/ownership accounting is inconsistent for {realm_id} floor {plane}"
                )
            if plane == 0 and transparent_owned != 0:
                raise osrsPipelineError(f"floor 0 mask must expose all owned pixels for {realm_id}")
            mbtiles_path = osrs_validate_release_relative_path(
                str(asset_value.get("mbtiles_path", "")),
                "realms[].assets[].mbtiles_path",
            )
            mask_path = osrs_validate_release_relative_path(
                str(asset_value.get("mask_path", "")),
                "realms[].assets[].mask_path",
            )
            ownership_mask_path = osrs_validate_release_relative_path(
                str(asset_value.get("ownership_mask_path", "")),
                "realms[].assets[].ownership_mask_path",
            )
            if PurePosixPath(mbtiles_path).parts[0] != "assets":
                raise osrsPipelineError("MBTiles path must be under assets/")
            if PurePosixPath(mask_path).parts[0] != "masks":
                raise osrsPipelineError("mask path must be under masks/")
            if PurePosixPath(ownership_mask_path).parts[0] != "masks":
                raise osrsPipelineError("ownership mask path must be under masks/")


def _osrs_png_bytes(image: Image.Image) -> bytes:
    for compression_level in range(9, -1, -1):
        payload = io.BytesIO()
        image.save(
            payload,
            format="PNG",
            optimize=False,
            compress_level=compression_level,
        )
        value = payload.getvalue()
        try:
            osrs_assert_public_binary_portable(
                value,
                artifact=f"PNG compression level {compression_level}",
            )
        except osrsPublicPathError:
            continue
        return value
    raise osrsPipelineError(
        "PNG could not be serialized without a scanner-significant host-path byte island"
    )


def _osrs_alpha_pixel_bounds(image_array: np.ndarray) -> tuple[int, int, int, int]:
    alpha = np.asarray(image_array)[..., 3] > 0
    coordinates = np.argwhere(alpha)
    if coordinates.size == 0:
        raise osrsPipelineError("MBTiles source must contain content-bearing pixels")
    min_y, min_x = coordinates.min(axis=0)
    max_y, max_x = coordinates.max(axis=0)
    return (int(min_x), int(min_y), int(max_x) + 1, int(max_y) + 1)


def _osrs_content_latlon_bounds(
    pixel_bounds: tuple[int, int, int, int], canvas_size: int
) -> tuple[float, float, float, float]:
    min_x, min_y, max_x, max_y = pixel_bounds
    west = -180.0 + 360.0 * min_x / canvas_size
    east = -180.0 + 360.0 * max_x / canvas_size
    north = _osrs_pixel_fraction_to_latitude(min_y / canvas_size)
    south = _osrs_pixel_fraction_to_latitude(max_y / canvas_size)
    return (west, south, east, north)


def _osrs_pixel_fraction_to_latitude(fraction: float) -> float:
    mercator_y = math.pi * (1.0 - 2.0 * fraction)
    return math.degrees(math.atan(math.sinh(mercator_y)))


def _osrs_format_number(value: float) -> str:
    return format(value, ".15g")


def _osrs_piece_sort_key(piece: Mapping[str, Any]) -> tuple[Any, ...]:
    normalized = _osrs_mapping(piece.get("normalized"), "piece.normalized")
    source = _osrs_mapping(normalized.get("source_bounds"), "source_bounds")
    display = _osrs_mapping(normalized.get("display_bounds"), "display_bounds")
    return (
        _osrs_int(source.get("plane_min"), "plane_min"),
        _osrs_int(source.get("min_x"), "source.min_x"),
        _osrs_int(source.get("min_y"), "source.min_y"),
        _osrs_int(display.get("min_x"), "display.min_x"),
        _osrs_int(display.get("min_y"), "display.min_y"),
        _osrs_int(piece.get("piece_index"), "piece_index"),
    )


def _osrs_union_bounds(rects: Iterable[osrsRect]) -> osrsRect:
    values = tuple(rects)
    if not values:
        raise osrsPipelineError("cannot union an empty rectangle set")
    return osrsRect(
        min(rect.min_x for rect in values),
        min(rect.min_y for rect in values),
        max(rect.max_x for rect in values),
        max(rect.max_y for rect in values),
    )


def _osrs_mask_manifest(
    rects: Sequence[osrsRect], plane: int | None = None
) -> dict[str, Any]:
    rectangles = [
        {
            **rect.to_json(),
            **({"plane_min": plane, "plane_max": plane} if plane is not None else {}),
        }
        for rect in sorted(set(rects))
    ]
    payload = osrs_canonical_json_bytes(rectangles)
    return {
        "type": "half_open_rectangle_union",
        "bounds": _osrs_union_bounds(rects).to_json(),
        "rectangles": rectangles,
        "rectangle_count": len(rectangles),
        "sha256": osrs_sha256_bytes(payload),
    }


def _osrs_piece_mask_manifest(
    pieces: Sequence[Mapping[str, Any]], bounds_key: str
) -> dict[str, Any]:
    rectangles_by_key: dict[tuple[int, ...], dict[str, int]] = {}
    by_plane: dict[str, set[osrsRect]] = {}
    spatial_rects: set[osrsRect] = set()
    for piece in pieces:
        normalized = _osrs_mapping(piece.get("normalized"), "piece.normalized")
        bounds = _osrs_mapping(normalized.get(bounds_key), bounds_key)
        rect = osrs_rect_from_json(bounds)
        plane_min = _osrs_int(bounds.get("plane_min"), "plane_min")
        plane_max = _osrs_int(bounds.get("plane_max"), "plane_max")
        key = (
            rect.min_x,
            rect.min_y,
            rect.max_x,
            rect.max_y,
            plane_min,
            plane_max,
        )
        rectangles_by_key[key] = {
            **rect.to_json(),
            "plane_min": plane_min,
            "plane_max": plane_max,
        }
        spatial_rects.add(rect)
        for plane in range(plane_min, plane_max + 1):
            by_plane.setdefault(str(plane), set()).add(rect)
    rectangles = [rectangles_by_key[key] for key in sorted(rectangles_by_key)]
    payload = osrs_canonical_json_bytes(rectangles)
    return {
        "type": "half_open_rectangle_union",
        "bounds": _osrs_union_bounds(spatial_rects).to_json(),
        "rectangles": rectangles,
        "rectangle_count": len(rectangles),
        "by_plane": {
            plane: _osrs_mask_manifest(tuple(sorted(rects)), plane=int(plane))
            for plane, rects in sorted(by_plane.items(), key=lambda item: int(item[0]))
        },
        "sha256": osrs_sha256_bytes(payload),
    }


def _osrs_plane_components(
    pieces: Sequence[Mapping[str, Any]], bounds_key: str
) -> list[dict[str, Any]]:
    by_plane: dict[int, set[osrsRect]] = {}
    for piece in pieces:
        normalized = _osrs_mapping(piece.get("normalized"), "piece.normalized")
        bounds = _osrs_mapping(normalized.get(bounds_key), bounds_key)
        rect = osrs_rect_from_json(bounds)
        plane_min = _osrs_int(bounds.get("plane_min"), "plane_min")
        plane_max = _osrs_int(bounds.get("plane_max"), "plane_max")
        for plane in range(plane_min, plane_max + 1):
            by_plane.setdefault(plane, set()).add(rect)
    result: list[dict[str, Any]] = []
    component_index = 0
    for plane, rects in sorted(by_plane.items()):
        for component in _osrs_components(tuple(rects)):
            result.append(
                {
                    **component,
                    "component_index": component_index,
                    "plane": plane,
                }
            )
            component_index += 1
    return result


def _osrs_components(rects: Sequence[osrsRect]) -> list[dict[str, Any]]:
    remaining = set(rects)
    components: list[set[osrsRect]] = []
    while remaining:
        seed = min(remaining)
        remaining.remove(seed)
        component = {seed}
        frontier = [seed]
        while frontier:
            current = frontier.pop()
            touching = {
                candidate
                for candidate in remaining
                if _osrs_rects_touch_or_overlap(current, candidate)
            }
            remaining.difference_update(touching)
            component.update(touching)
            frontier.extend(touching)
        components.append(component)
    result = [
        {
            "component_index": index,
            "bounds": _osrs_union_bounds(component).to_json(),
            "rectangle_count": len(component),
        }
        for index, component in enumerate(
            sorted(components, key=lambda group: min(group)), start=0
        )
    ]
    return result


def _osrs_rects_touch_or_overlap(left: osrsRect, right: osrsRect) -> bool:
    return not (
        left.max_x < right.min_x
        or right.max_x < left.min_x
        or left.max_y < right.min_y
        or right.max_y < left.min_y
    )


def _osrs_wiki_bounds(value: Mapping[str, Any]) -> osrsRect:
    bounds = value.get("bounds")
    if (
        not isinstance(bounds, list)
        or len(bounds) != 2
        or not all(isinstance(point, list) and len(point) == 2 for point in bounds)
    ):
        raise osrsPipelineError(f"mapID {value.get('mapId')} has invalid bounds")
    return osrsRect(
        _osrs_int(bounds[0][0], "bounds.min_x"),
        _osrs_int(bounds[0][1], "bounds.min_y"),
        _osrs_int(bounds[1][0], "bounds.max_x"),
        _osrs_int(bounds[1][1], "bounds.max_y"),
    )


def _osrs_position_realm_ids(
    position: Mapping[str, Any],
    zone_owners: Mapping[tuple[int, int, int], set[str]],
) -> tuple[str, ...]:
    plane = _osrs_int(position.get("plane"), "position.plane")
    x = _osrs_int(position.get("x"), "position.x")
    y = _osrs_int(position.get("y"), "position.y")
    return tuple(sorted(zone_owners.get((plane, x // 8, y // 8), set())))


def _osrs_mapping(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise osrsPipelineError(f"{field} must be an object")
    return value


def _osrs_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise osrsPipelineError(f"{field} must be an integer")
    result = int(value)
    if result != value:
        raise osrsPipelineError(f"{field} must be an integer")
    return result
