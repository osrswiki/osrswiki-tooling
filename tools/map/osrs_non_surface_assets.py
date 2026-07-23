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


Image.MAX_IMAGE_PIXELS = None
OSRS_TILE_SIZE = 512
OSRS_MAX_MERCATOR_LATITUDE = 85.0511287798066


@dataclass(frozen=True)
class osrsRenderedRealm:
    rgba: np.ndarray
    mask: np.ndarray
    source_bounds: tuple[osrsRect, ...]
    display_bounds: osrsRect
    plane: int
    assigned_source_pixel_count: int
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

    return osrsRenderedRealm(
        rgba=rgba,
        mask=mask,
        source_bounds=tuple(sorted({source for source, _ in records})),
        display_bounds=display_bounds,
        plane=plane,
        assigned_source_pixel_count=sum(
            projection.game_to_pixel_rect(source).area for source, _ in records
        ),
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
    rgba[..., 3] = 255
    return osrsRenderedRealm(
        rgba=rgba,
        mask=np.ones((pixel_bounds.height, pixel_bounds.width), dtype=np.bool_),
        source_bounds=(game_bounds,),
        display_bounds=game_bounds,
        plane=plane,
        assigned_source_pixel_count=pixel_bounds.area,
    )


def osrs_save_mask_png(mask: np.ndarray, path: Path) -> str:
    image = Image.fromarray(np.where(mask, 255, 0).astype(np.uint8))
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)
    return osrs_sha256_file(path)


def osrs_save_owner_codes_png(owner_codes: np.ndarray, path: Path) -> str:
    codes = np.asarray(owner_codes)
    if codes.size and int(codes.max()) >= 65535:
        raise osrsPipelineError("owner-code PNG supports at most 65,534 owners")
    image = Image.fromarray(codes.astype(np.uint16))
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)
    return osrs_sha256_file(path)


def osrs_write_mbtiles(
    rgba: np.ndarray,
    output_path: Path,
    name: str,
    tile_size: int = OSRS_TILE_SIZE,
    *,
    release_root: Path | None = None,
) -> dict[str, Any]:
    """Write a byte-reproducible, local full-world raster tile pyramid."""

    image_array = np.asarray(rgba)
    if image_array.ndim != 3 or image_array.shape[2] != 4:
        raise osrsPipelineError(f"MBTiles source must be RGBA, got {image_array.shape}")
    height, width = image_array.shape[:2]
    if width <= 0 or height <= 0:
        raise osrsPipelineError("MBTiles source cannot be empty")
    if tile_size <= 0 or tile_size & (tile_size - 1):
        raise osrsPipelineError("tile size must be a positive power of two")
    native_zoom = max(0, math.ceil(math.log2(max(width, height) / tile_size)))
    canvas_size = tile_size * (2**native_zoom)
    content_image = Image.fromarray(image_array)
    padded = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    padded.paste(content_image, (0, 0))

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
        content_bounds = _osrs_content_latlon_bounds(width, height, canvas_size)
        metadata = {
            "bounds": "-180.0,-85.0511287798066,180.0,85.0511287798066",
            "description": "Cache-and-Wiki-derived OSRS realm-local raster",
            "format": "png",
            "maxzoom": str(native_zoom),
            "minzoom": "0",
            "name": name,
            "osrs_content_bounds": ",".join(_osrs_format_number(v) for v in content_bounds),
            "osrs_content_pixel_bounds": f"0,0,{width},{height}",
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
        "content_pixel_bounds": [0, 0, width, height],
        "content_latlon_bounds": list(content_bounds),
        "sqlite_version_number": sqlite_version_number,
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
                                    "width",
                                    "height",
                                    "assigned_pixel_count",
                                    "display_pixel_count",
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
                                    "width": {"type": "integer", "minimum": 1},
                                    "height": {"type": "integer", "minimum": 1},
                                    "assigned_pixel_count": {"type": "integer", "minimum": 1},
                                    "display_pixel_count": {"type": "integer", "minimum": 1},
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
            mbtiles_path = osrs_validate_release_relative_path(
                str(asset_value.get("mbtiles_path", "")),
                "realms[].assets[].mbtiles_path",
            )
            mask_path = osrs_validate_release_relative_path(
                str(asset_value.get("mask_path", "")),
                "realms[].assets[].mask_path",
            )
            if PurePosixPath(mbtiles_path).parts[0] != "assets":
                raise osrsPipelineError("MBTiles path must be under assets/")
            if PurePosixPath(mask_path).parts[0] != "masks":
                raise osrsPipelineError("mask path must be under masks/")


def _osrs_png_bytes(image: Image.Image) -> bytes:
    payload = io.BytesIO()
    image.save(payload, format="PNG", optimize=False, compress_level=9)
    return payload.getvalue()


def _osrs_content_latlon_bounds(
    width: int, height: int, canvas_size: int
) -> tuple[float, float, float, float]:
    east = -180.0 + 360.0 * width / canvas_size
    south = _osrs_pixel_fraction_to_latitude(height / canvas_size)
    return (-180.0, south, east, OSRS_MAX_MERCATOR_LATITUDE)


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
