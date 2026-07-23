#!/usr/bin/env python3
"""Deterministic non-surface realm reconciliation and source accounting.

The user-facing product calls these maps "underground maps", but discovery is
deliberately based on the cache ``is_surface`` flag.  No name-based filtering
is permitted: islands, minigame instances, interiors, and other disconnected
spaces are first-class realms.

This module contains the input-independent accounting core used by the release
builder.  It keeps the exact-black background predicate intentionally small so
that a near-black antialiased edge can never disappear as no-data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, MutableMapping, Sequence, cast

try:
    import numpy as np
except ImportError as error:  # pragma: no cover - exercised by the CLI guard
    np = None  # type: ignore[assignment]
    _NUMPY_IMPORT_ERROR = error
else:
    _NUMPY_IMPORT_ERROR = None


OSRS_SCHEMA_VERSION = 1
OSRS_BACKGROUND_RGB = (0, 0, 0)
OSRS_SURFACE_REALM_ID = "surface-gielinor"
OSRS_NATIVE_REALM_PREFIX = "cache-world-map:"
OSRS_OTHER_MAP_PREFIX = "other-map-"


class osrsPipelineError(RuntimeError):
    """A deterministic, release-blocking pipeline error."""


@dataclass(frozen=True, order=True)
class osrsRect:
    """A half-open integer rectangle in game or pixel coordinates."""

    min_x: int
    min_y: int
    max_x: int
    max_y: int

    def __post_init__(self) -> None:
        if self.min_x >= self.max_x or self.min_y >= self.max_y:
            raise osrsPipelineError(f"invalid half-open rectangle: {self}")

    @property
    def width(self) -> int:
        return self.max_x - self.min_x

    @property
    def height(self) -> int:
        return self.max_y - self.min_y

    @property
    def area(self) -> int:
        return self.width * self.height

    def to_json(self) -> dict[str, int]:
        return {
            "min_x": self.min_x,
            "min_y": self.min_y,
            "max_x": self.max_x,
            "max_y": self.max_y,
        }


@dataclass(frozen=True)
class osrsProjection:
    """Pinned conversion between game coordinates and native raster pixels."""

    game_min_x: int
    game_max_y: int
    scale: int
    width: int
    height: int

    @classmethod
    def from_metadata(cls, value: Mapping[str, Any]) -> "osrsProjection":
        bounds = _osrs_require_mapping(value, "gameBounds")
        source_image = value.get("sourceImage")
        if source_image is None:
            source_image = value.get("source_image")
        source_image = _osrs_require_mapping_value(source_image, "sourceImage")
        scale = _osrs_int(value.get("gameCoordScale"), "gameCoordScale")
        projection = cls(
            game_min_x=_osrs_int(bounds.get("minX"), "gameBounds.minX"),
            game_max_y=_osrs_int(bounds.get("maxY"), "gameBounds.maxY"),
            scale=scale,
            width=_osrs_int(source_image.get("width"), "sourceImage.width"),
            height=_osrs_int(source_image.get("height"), "sourceImage.height"),
        )
        if projection.scale <= 0:
            raise osrsPipelineError("gameCoordScale must be positive")
        return projection

    def game_to_pixel_rect(self, rect: osrsRect) -> osrsRect:
        """Project a game rectangle without resampling.

        Game Y grows north while source pixel Y grows south.  Because the input
        rectangle is half-open, its north edge becomes the pixel rectangle's
        top edge and its south edge becomes the bottom edge.
        """

        projected = osrsRect(
            min_x=(rect.min_x - self.game_min_x) * self.scale,
            min_y=(self.game_max_y - rect.max_y) * self.scale,
            max_x=(rect.max_x - self.game_min_x) * self.scale,
            max_y=(self.game_max_y - rect.min_y) * self.scale,
        )
        if (
            projected.min_x < 0
            or projected.min_y < 0
            or projected.max_x > self.width
            or projected.max_y > self.height
        ):
            raise osrsPipelineError(
                f"game rectangle {rect} projects outside {self.width}x{self.height}: "
                f"{projected}"
            )
        return projected

    def game_to_pixel_rect_clipped(self, rect: osrsRect) -> osrsRect | None:
        """Project the intersection with the pinned source raster.

        This is used only for Wiki view bounds.  Cache-native ownership must be
        wholly inside the source and therefore uses ``game_to_pixel_rect``.
        """

        game_max_x = self.game_min_x + self.width // self.scale
        game_min_y = self.game_max_y - self.height // self.scale
        clipped_min_x = max(rect.min_x, self.game_min_x)
        clipped_min_y = max(rect.min_y, game_min_y)
        clipped_max_x = min(rect.max_x, game_max_x)
        clipped_max_y = min(rect.max_y, self.game_max_y)
        if clipped_min_x >= clipped_max_x or clipped_min_y >= clipped_max_y:
            return None
        return self.game_to_pixel_rect(
            osrsRect(clipped_min_x, clipped_min_y, clipped_max_x, clipped_max_y)
        )


@dataclass(frozen=True)
class osrsPixelOwner:
    """One unique source-accounting owner."""

    realm_id: str
    category: str
    pixel_rects: tuple[osrsRect, ...]

    def __post_init__(self) -> None:
        if self.category not in {
            "true_surface",
            "named_non_surface_realm",
        }:
            raise osrsPipelineError(f"invalid native owner category: {self.category}")
        if not self.pixel_rects:
            raise osrsPipelineError(f"owner {self.realm_id} has no plane-0 rectangles")


@dataclass(frozen=True)
class osrsSpecialView:
    """A Wiki view that may account for otherwise unowned visible content."""

    realm_id: str
    map_id: int
    pixel_bounds: osrsRect


@dataclass(frozen=True)
class osrsAccountingResult:
    """Exact accounting result; ``owner_codes`` is a uint16/uint32 raster."""

    owner_codes: Any
    owners_by_code: tuple[dict[str, Any], ...]
    source_pixels: int
    true_surface_pixels: int
    named_non_surface_realm_pixels: int
    known_special_or_custom_area_pixels: int
    legitimate_exact_black_background_pixels: int
    unresolved_content_bearing_residual_pixels: int
    overlap_pixels: int
    gap_pixels: int
    ambiguous_special_pixels: int

    @property
    def accounted_pixels(self) -> int:
        return (
            self.true_surface_pixels
            + self.named_non_surface_realm_pixels
            + self.known_special_or_custom_area_pixels
            + self.legitimate_exact_black_background_pixels
            + self.unresolved_content_bearing_residual_pixels
        )

    @property
    def release_ready(self) -> bool:
        return (
            self.accounted_pixels == self.source_pixels
            and self.unresolved_content_bearing_residual_pixels == 0
            and self.overlap_pixels == 0
            and self.gap_pixels == 0
            and self.ambiguous_special_pixels == 0
        )

    def assert_release_ready(self) -> None:
        if not self.release_ready:
            raise osrsPipelineError(
                "source conservation failed: "
                f"residual={self.unresolved_content_bearing_residual_pixels}, "
                f"overlap={self.overlap_pixels}, gap={self.gap_pixels}, "
                f"ambiguous_special={self.ambiguous_special_pixels}, "
                f"sum={self.accounted_pixels}/{self.source_pixels}"
            )

    def to_json(self) -> dict[str, Any]:
        return {
            "schema_version": OSRS_SCHEMA_VERSION,
            "background_classification": {
                "mode": "exact_rgb",
                "rgb": list(OSRS_BACKGROUND_RGB),
                "content_bearing_predicate": "r != 0 or g != 0 or b != 0",
                "near_black_tolerance": 0,
            },
            "source_pixels": self.source_pixels,
            "categories": {
                "true_surface": self.true_surface_pixels,
                "named_non_surface_realm": self.named_non_surface_realm_pixels,
                "known_special_or_custom_area": self.known_special_or_custom_area_pixels,
                "legitimate_exact_black_background": self.legitimate_exact_black_background_pixels,
                "unresolved_content_bearing_residual": self.unresolved_content_bearing_residual_pixels,
            },
            "checks": {
                "accounted_pixels": self.accounted_pixels,
                "sum_matches_source": self.accounted_pixels == self.source_pixels,
                "overlap_pixels": self.overlap_pixels,
                "gap_pixels": self.gap_pixels,
                "ambiguous_special_pixels": self.ambiguous_special_pixels,
                "zero_unresolved_content_bearing_residual": (
                    self.unresolved_content_bearing_residual_pixels == 0
                ),
                "release_ready": self.release_ready,
            },
            "owners": list(self.owners_by_code),
        }


def osrs_stable_native_realm_id(definition: Mapping[str, Any]) -> str:
    """Return a name-shift-resistant ID from the cache-native safe name."""

    if bool(definition.get("is_surface")):
        return OSRS_SURFACE_REALM_ID
    safe_name = str(definition.get("safe_name", "")).strip()
    if not safe_name:
        raise osrsPipelineError("cache definition is missing safe_name")
    slug = re.sub(r"[^a-z0-9]+", "-", safe_name.casefold()).strip("-")
    if not slug:
        raise osrsPipelineError(f"safe_name has no stable characters: {safe_name!r}")
    return f"{OSRS_NATIVE_REALM_PREFIX}{slug}"


def osrs_other_map_id(map_id: int) -> str:
    if map_id < 0:
        raise osrsPipelineError(f"custom map ID must be nonnegative: {map_id}")
    return f"{OSRS_OTHER_MAP_PREFIX}{map_id}"


def osrs_rect_from_json(value: Mapping[str, Any]) -> osrsRect:
    return osrsRect(
        min_x=_osrs_int(value.get("min_x"), "min_x"),
        min_y=_osrs_int(value.get("min_y"), "min_y"),
        max_x=_osrs_int(value.get("max_x"), "max_x"),
        max_y=_osrs_int(value.get("max_y"), "max_y"),
    )


def osrs_plane_rects(definition: Mapping[str, Any], plane: int) -> tuple[osrsRect, ...]:
    """Return canonical source rectangles from every composite piece on a plane."""

    composite = _osrs_require_mapping(definition, "composite")
    rects: set[osrsRect] = set()
    for key in ("map_squares", "zones"):
        pieces = composite.get(key, [])
        if not isinstance(pieces, list):
            raise osrsPipelineError(f"composite.{key} must be an array")
        for piece in pieces:
            piece = _osrs_require_mapping_value(piece, f"composite.{key}[]")
            normalized = _osrs_require_mapping(piece, "normalized")
            source_bounds = _osrs_require_mapping(normalized, "source_bounds")
            plane_min = _osrs_int(source_bounds.get("plane_min"), "plane_min")
            plane_max = _osrs_int(source_bounds.get("plane_max"), "plane_max")
            if plane_min <= plane <= plane_max:
                rects.add(osrs_rect_from_json(source_bounds))
    return tuple(sorted(rects))


def osrs_build_native_owners(
    inventory: Mapping[str, Any], projection: osrsProjection, plane: int = 0
) -> tuple[osrsPixelOwner, ...]:
    """Build every cache-native owner without using name predicates."""

    definitions = inventory.get("definitions")
    if not isinstance(definitions, list):
        raise osrsPipelineError("inventory.definitions must be an array")
    owners: list[osrsPixelOwner] = []
    seen_ids: set[str] = set()
    surface_count = 0
    for raw_definition in sorted(
        definitions,
        key=lambda value: _osrs_int(
            _osrs_require_mapping_value(value, "definitions[]").get("file_id"),
            "file_id",
        ),
    ):
        definition = _osrs_require_mapping_value(raw_definition, "definitions[]")
        realm_id = osrs_stable_native_realm_id(definition)
        if realm_id in seen_ids:
            raise osrsPipelineError(f"stable realm ID collision: {realm_id}")
        seen_ids.add(realm_id)
        is_surface = bool(definition.get("is_surface"))
        if is_surface:
            surface_count += 1
        game_rects = osrs_plane_rects(definition, plane)
        if not game_rects:
            continue
        owners.append(
            osrsPixelOwner(
                realm_id=realm_id,
                category=(
                    "true_surface" if is_surface else "named_non_surface_realm"
                ),
                pixel_rects=tuple(
                    sorted(projection.game_to_pixel_rect(rect) for rect in game_rects)
                ),
            )
        )
    if surface_count != 1:
        raise osrsPipelineError(
            f"expected exactly one cache-native surface definition, found {surface_count}"
        )
    return tuple(owners)


def osrs_build_special_views(
    basemaps: Mapping[str, Any] | Sequence[Any], projection: osrsProjection
) -> tuple[osrsSpecialView, ...]:
    """Build Wiki-only navigation views from structured pinned bounds."""

    values: Iterable[Any]
    if isinstance(basemaps, Mapping):
        values = basemaps.values()
    else:
        values = basemaps
    views: list[osrsSpecialView] = []
    for raw in values:
        value = _osrs_require_mapping_value(raw, "basemaps[]")
        map_id = _osrs_int(value.get("mapId"), "mapId")
        if map_id < 10000:
            continue
        bounds = value.get("bounds")
        if (
            not isinstance(bounds, list)
            or len(bounds) != 2
            or not all(isinstance(point, list) and len(point) == 2 for point in bounds)
        ):
            raise osrsPipelineError(f"mapID {map_id} has invalid bounds")
        game_bounds = osrsRect(
            min_x=_osrs_int(bounds[0][0], f"mapID {map_id} minX"),
            min_y=_osrs_int(bounds[0][1], f"mapID {map_id} minY"),
            max_x=_osrs_int(bounds[1][0], f"mapID {map_id} maxX"),
            max_y=_osrs_int(bounds[1][1], f"mapID {map_id} maxY"),
        )
        pixel_bounds = projection.game_to_pixel_rect_clipped(game_bounds)
        if pixel_bounds is None:
            continue
        views.append(
            osrsSpecialView(
                realm_id=osrs_other_map_id(map_id),
                map_id=map_id,
                pixel_bounds=pixel_bounds,
            )
        )
    return tuple(sorted(views, key=lambda view: view.map_id))


def osrs_account_source(
    rgb: Any,
    native_owners: Sequence[osrsPixelOwner],
    special_views: Sequence[osrsSpecialView] = (),
) -> osrsAccountingResult:
    """Partition every source pixel into the approved disjoint categories.

    Exact-black pixels inside a native membership rectangle remain owned.  A
    Wiki special view claims only otherwise-unowned *content-bearing* pixels.
    If two special views claim the same otherwise-unowned visible pixel, that
    ambiguity is retained and blocks release instead of being resolved by an
    arbitrary ordering.
    """

    _osrs_require_numpy()
    image = np.asarray(rgb)
    if image.ndim != 3 or image.shape[2] < 3:
        raise osrsPipelineError(
            f"source must have at least three channels, got shape {image.shape}"
        )
    height, width = image.shape[:2]
    content = np.any(image[..., :3] != 0, axis=2)
    max_codes = len(native_owners) + len(special_views)
    code_dtype = np.uint16 if max_codes < np.iinfo(np.uint16).max else np.uint32
    owner_codes = np.zeros((height, width), dtype=code_dtype)
    owner_rows: list[dict[str, Any]] = []
    overlap_mask = np.zeros((height, width), dtype=np.bool_)

    for code, owner in enumerate(native_owners, start=1):
        owner_rows.append(
            {
                "code": code,
                "realm_id": owner.realm_id,
                "category": owner.category,
            }
        )
        for rect in owner.pixel_rects:
            _osrs_validate_pixel_rect(rect, width, height, owner.realm_id)
            target = owner_codes[rect.min_y : rect.max_y, rect.min_x : rect.max_x]
            conflict = (target != 0) & (target != code)
            if np.any(conflict):
                overlap_mask[rect.min_y : rect.max_y, rect.min_x : rect.max_x] |= conflict
            target[target == 0] = code

    native_code_count = len(native_owners)
    ambiguous_special = np.zeros((height, width), dtype=np.bool_)
    for offset, view in enumerate(special_views, start=1):
        code = native_code_count + offset
        owner_rows.append(
            {
                "code": code,
                "realm_id": view.realm_id,
                "map_id": view.map_id,
                "category": "known_special_or_custom_area",
            }
        )
        rect = view.pixel_bounds
        _osrs_validate_pixel_rect(rect, width, height, view.realm_id)
        target = owner_codes[rect.min_y : rect.max_y, rect.min_x : rect.max_x]
        visible = content[rect.min_y : rect.max_y, rect.min_x : rect.max_x]
        prior_special = (target > native_code_count) & visible
        if np.any(prior_special):
            ambiguous_special[
                rect.min_y : rect.max_y, rect.min_x : rect.max_x
            ] |= prior_special
        claim = (target == 0) & visible
        target[claim] = code

    unresolved = content & (owner_codes == 0)
    background = (~content) & (owner_codes == 0)
    gap = ~(content | ~content)  # explicit all-pixel partition check; always empty

    native_categories = {
        row["code"]: row["category"] for row in owner_rows[:native_code_count]
    }
    counts = np.bincount(owner_codes.ravel(), minlength=max_codes + 1)
    surface_pixels = sum(
        int(counts[code])
        for code, category in native_categories.items()
        if category == "true_surface"
    )
    realm_pixels = sum(
        int(counts[code])
        for code, category in native_categories.items()
        if category == "named_non_surface_realm"
    )
    special_pixels = int(counts[native_code_count + 1 :].sum())

    for row in owner_rows:
        row["pixel_count"] = int(counts[row["code"]])

    return osrsAccountingResult(
        owner_codes=owner_codes,
        owners_by_code=tuple(owner_rows),
        source_pixels=width * height,
        true_surface_pixels=surface_pixels,
        named_non_surface_realm_pixels=realm_pixels,
        known_special_or_custom_area_pixels=special_pixels,
        legitimate_exact_black_background_pixels=int(np.count_nonzero(background)),
        unresolved_content_bearing_residual_pixels=int(np.count_nonzero(unresolved)),
        overlap_pixels=int(np.count_nonzero(overlap_mask)),
        gap_pixels=int(np.count_nonzero(gap)),
        ambiguous_special_pixels=int(np.count_nonzero(ambiguous_special)),
    )


def osrs_account_provenance_summary(
    streaming: Mapping[str, Any],
    ledger: Mapping[str, Any],
    definitions: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Classify an exact row-stream scan through the renderer code ledger."""

    definition_surface = {
        _osrs_int(definition.get("file_id"), "file_id"): bool(
            definition.get("is_surface")
        )
        for definition in definitions
    }
    codebook = ledger.get("codebook")
    owner_counts = streaming.get("owner_counts")
    if not isinstance(codebook, list) or not isinstance(owner_counts, list):
        raise osrsPipelineError("provenance codebook and streaming owner_counts must be arrays")
    entries_by_code: dict[int, Mapping[str, Any]] = {}
    for raw_entry in codebook:
        entry = _osrs_require_mapping_value(raw_entry, "codebook[]")
        code = _osrs_int(entry.get("code"), "codebook.code")
        if code <= 0 or code in entries_by_code:
            raise osrsPipelineError(f"invalid or duplicate provenance code: {code}")
        entries_by_code[code] = entry

    surface = 0
    non_surface = 0
    special = 0
    classified_owners: list[dict[str, Any]] = []
    for raw_count in owner_counts:
        count = _osrs_require_mapping_value(raw_count, "owner_counts[]")
        code = _osrs_int(count.get("code"), "owner_counts.code")
        total = _osrs_int(count.get("total_pixels"), "owner_counts.total_pixels")
        content_count = _osrs_int(
            count.get("content_bearing_pixels"),
            "owner_counts.content_bearing_pixels",
        )
        entry = entries_by_code.get(code)
        if entry is None:
            raise osrsPipelineError(f"owner raster uses code absent from ledger: {code}")
        kind = str(entry.get("kind"))
        realm_file_id = entry.get("realm_file_id")
        if kind == "native_composite":
            file_id = _osrs_int(realm_file_id, "realm_file_id")
            if file_id not in definition_surface:
                raise osrsPipelineError(
                    f"provenance references unknown native file ID: {file_id}"
                )
            category = (
                "true_surface"
                if definition_surface[file_id]
                else "named_non_surface_realm"
            )
            if definition_surface[file_id]:
                surface += total
            else:
                non_surface += total
        elif kind == "cache_loaded_special_region":
            category = "known_special_or_custom_area"
            special += total
        else:
            raise osrsPipelineError(f"unknown provenance kind for code {code}: {kind}")
        classified_owners.append(
            {
                **dict(entry),
                "category": category,
                "pixel_count": total,
                "content_bearing_pixel_count": content_count,
            }
        )

    source_pixels = _osrs_int(streaming.get("source_pixels"), "source_pixels")
    background = _osrs_int(
        streaming.get("legitimate_unowned_exact_black_pixels"),
        "legitimate_unowned_exact_black_pixels",
    )
    residual = _osrs_int(
        streaming.get("unresolved_content_bearing_pixels"),
        "unresolved_content_bearing_pixels",
    )
    accounted = surface + non_surface + special + background + residual
    cross_overwrites = (
        ledger.get("statistics", {}).get("cross_owner_overwrites", [])
        if isinstance(ledger.get("statistics"), Mapping)
        else []
    )
    if not isinstance(cross_overwrites, list):
        raise osrsPipelineError("statistics.cross_owner_overwrites must be an array")
    result = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "background_classification": {
            "mode": "exact_rgb",
            "rgb": list(OSRS_BACKGROUND_RGB),
            "content_bearing_predicate": "r != 0 or g != 0 or b != 0",
            "near_black_tolerance": 0,
        },
        "source_pixels": source_pixels,
        "categories": {
            "true_surface": surface,
            "named_non_surface_realm": non_surface,
            "known_special_or_custom_area": special,
            "legitimate_exact_black_background": background,
            "unresolved_content_bearing_residual": residual,
        },
        "checks": {
            "accounted_pixels": accounted,
            "sum_matches_source": accounted == source_pixels,
            "overlap_pixels": 0,
            "gap_pixels": 0 if accounted == source_pixels else abs(source_pixels - accounted),
            "zero_unresolved_content_bearing_residual": residual == 0,
            "renderer_cross_owner_overwrite_pixels": sum(
                _osrs_int(value.get("pixel_write_count"), "pixel_write_count")
                for value in cross_overwrites
                if isinstance(value, Mapping)
            ),
            "release_ready": accounted == source_pixels and residual == 0,
        },
        "owners": sorted(classified_owners, key=lambda value: value["code"]),
        "renderer_provenance": {
            "schema_version": ledger.get("schema_version"),
            "generator": ledger.get("generator"),
            "encoding": ledger.get("encoding"),
            "image": ledger.get("image"),
            "projection": ledger.get("projection"),
            "statistics": ledger.get("statistics"),
            "invariants": ledger.get("invariants"),
        },
    }
    if accounted != source_pixels:
        raise osrsPipelineError(
            f"provenance category sum is {accounted}, expected {source_pixels}"
        )
    return result


def osrs_extract_owned_crop(
    rgb: Any, owner_codes: Any, owner_code: int
) -> tuple[Any, osrsRect]:
    """Copy exact source RGB for one owner and preserve owned exact-black pixels."""

    _osrs_require_numpy()
    image = np.asarray(rgb)
    codes = np.asarray(owner_codes)
    mask = codes == owner_code
    points = np.argwhere(mask)
    if points.size == 0:
        raise osrsPipelineError(f"owner code {owner_code} has no pixels")
    min_y, min_x = points.min(axis=0)
    max_y, max_x = points.max(axis=0) + 1
    bounds = osrsRect(int(min_x), int(min_y), int(max_x), int(max_y))
    local_mask = mask[bounds.min_y : bounds.max_y, bounds.min_x : bounds.max_x]
    local_rgb = image[bounds.min_y : bounds.max_y, bounds.min_x : bounds.max_x, :3]
    rgba = np.zeros((bounds.height, bounds.width, 4), dtype=np.uint8)
    rgba[..., :3][local_mask] = local_rgb[local_mask]
    rgba[..., 3][local_mask] = 255
    return rgba, bounds


def osrs_preserve_previous_aliases(
    previous: Mapping[str, Any] | None,
    current_realms: Sequence[MutableMapping[str, Any]],
) -> None:
    """Retain the former canonical name when a stable realm ID is renamed."""

    old_by_id = _osrs_release_realms_by_id(
        _osrs_previous_release_realms(previous), "prior realms[]"
    )
    new_by_id = _osrs_release_realms_by_id(current_realms, "current realms[]")
    for realm_id in sorted(set(old_by_id) & set(new_by_id)):
        old_name = str(old_by_id[realm_id].get("canonical_name", "")).strip()
        new = cast(MutableMapping[str, Any], new_by_id[realm_id])
        new_name = str(new.get("canonical_name", "")).strip()
        if not old_name or old_name == new_name:
            continue
        aliases = new.get("aliases")
        if not isinstance(aliases, list) or not all(
            isinstance(alias, str) for alias in aliases
        ):
            raise osrsPipelineError(f"realm {realm_id} aliases must be a string array")
        retained = {alias.strip() for alias in aliases if alias.strip()}
        retained.add(old_name)
        retained.discard(new_name)
        new["aliases"] = sorted(retained, key=lambda value: (value.casefold(), value))


def osrs_release_diff(
    previous: Mapping[str, Any] | None, current_realms: Sequence[Mapping[str, Any]]
) -> dict[str, Any]:
    """Compute deterministic stable-ID changes and fail closed on ambiguous lineage."""

    old_by_id = _osrs_release_realms_by_id(
        _osrs_previous_release_realms(previous), "prior realms[]"
    )
    new_by_id = _osrs_release_realms_by_id(current_realms, "current realms[]")
    added = sorted(set(new_by_id) - set(old_by_id))
    removed = sorted(set(old_by_id) - set(new_by_id))
    renamed: list[dict[str, str]] = []
    changed: list[str] = []
    migrations: list[dict[str, Any]] = []
    for realm_id in sorted(set(old_by_id) & set(new_by_id)):
        old = old_by_id[realm_id]
        new = new_by_id[realm_id]
        if old.get("canonical_name") != new.get("canonical_name"):
            old_name = str(old.get("canonical_name", "")).strip()
            aliases = new.get("aliases", [])
            if not isinstance(aliases, list) or old_name not in aliases:
                raise osrsPipelineError(
                    f"renamed realm {realm_id} must retain {old_name!r} as an alias"
                )
            renamed.append(
                {
                    "id": realm_id,
                    "from": old_name,
                    "to": str(new.get("canonical_name", "")),
                }
            )
            migrations.append(
                {
                    "kind": "rename",
                    "from_ids": [realm_id],
                    "to_ids": [realm_id],
                    "aliases_added": [old_name],
                }
            )
        old_compare = dict(old)
        new_compare = dict(new)
        old_compare.pop("canonical_name", None)
        new_compare.pop("canonical_name", None)
        if old.get("canonical_name") != new.get("canonical_name"):
            old_aliases = old_compare.get("aliases", [])
            new_aliases = new_compare.get("aliases", [])
            if isinstance(old_aliases, list) and isinstance(new_aliases, list):
                old_compare["aliases"] = sorted(old_aliases)
                new_compare["aliases"] = sorted(
                    alias for alias in new_aliases if alias != old_name
                )
        if old_compare != new_compare:
            changed.append(realm_id)

    lineage_edges: dict[tuple[str, str], dict[str, Any]] = {}
    for old_id in removed:
        for new_id in added:
            evidence = _osrs_release_lineage_evidence(
                old_by_id[old_id], new_by_id[new_id]
            )
            if evidence is not None:
                lineage_edges[(old_id, new_id)] = evidence

    split: list[dict[str, Any]] = []
    merged: list[dict[str, Any]] = []
    visited_old: set[str] = set()
    for start_old in sorted(removed):
        if start_old in visited_old or not any(
            old_id == start_old for old_id, _ in lineage_edges
        ):
            continue
        component_old = {start_old}
        component_new: set[str] = set()
        frontier_old = [start_old]
        frontier_new: list[str] = []
        while frontier_old or frontier_new:
            while frontier_old:
                old_id = frontier_old.pop()
                for edge_old, new_id in sorted(lineage_edges):
                    if edge_old != old_id or new_id in component_new:
                        continue
                    component_new.add(new_id)
                    frontier_new.append(new_id)
            while frontier_new:
                new_id = frontier_new.pop()
                for old_id, edge_new in sorted(lineage_edges):
                    if edge_new != new_id or old_id in component_old:
                        continue
                    component_old.add(old_id)
                    frontier_old.append(old_id)
        visited_old.update(component_old)
        old_ids = sorted(component_old)
        new_ids = sorted(component_new)
        evidence = _osrs_release_component_evidence(
            old_ids, new_ids, lineage_edges
        )
        if len(old_ids) > 1 and len(new_ids) > 1:
            raise osrsPipelineError(
                "ambiguous many-to-many realm migration: "
                f"from_ids={old_ids}, to_ids={new_ids}"
            )
        if len(old_ids) == 1 and len(new_ids) == 1:
            migrations.append(
                {
                    "kind": "id_change",
                    "from_ids": old_ids,
                    "to_ids": new_ids,
                    "evidence": evidence,
                }
            )
        elif len(old_ids) == 1:
            record = {
                "from_id": old_ids[0],
                "to_ids": new_ids,
                "evidence": evidence,
            }
            split.append(record)
            migrations.append(
                {
                    "kind": "split",
                    "from_ids": old_ids,
                    "to_ids": new_ids,
                    "evidence": evidence,
                }
            )
        else:
            record = {
                "from_ids": old_ids,
                "to_id": new_ids[0],
                "evidence": evidence,
            }
            merged.append(record)
            migrations.append(
                {
                    "kind": "merge",
                    "from_ids": old_ids,
                    "to_ids": new_ids,
                    "evidence": evidence,
                }
            )

    for old_id in sorted(set(removed) - visited_old):
        migrations.append(
            {"kind": "removed", "from_ids": [old_id], "to_ids": []}
        )
    return {
        "schema_version": OSRS_SCHEMA_VERSION,
        "added": added,
        "changed": changed,
        "renamed": renamed,
        "split": split,
        "merged": merged,
        "removed": removed,
        "migrations": migrations,
    }


def _osrs_previous_release_realms(
    previous: Mapping[str, Any] | None,
) -> Sequence[Mapping[str, Any]]:
    previous_realms = [] if previous is None else previous.get("realms", [])
    if not isinstance(previous_realms, list):
        raise osrsPipelineError("prior manifest realms must be an array")
    return previous_realms


def _osrs_release_realms_by_id(
    realms: Sequence[Mapping[str, Any]], field: str
) -> dict[str, Mapping[str, Any]]:
    result: dict[str, Mapping[str, Any]] = {}
    for item in realms:
        realm = _osrs_require_mapping_value(item, field)
        realm_id = str(realm.get("id", "")).strip()
        if not realm_id:
            raise osrsPipelineError(f"{field} id must be non-empty")
        if realm_id in result:
            raise osrsPipelineError(f"duplicate realm ID in {field}: {realm_id}")
        result[realm_id] = realm
    return result


def _osrs_release_lineage_evidence(
    old: Mapping[str, Any], new: Mapping[str, Any]
) -> dict[str, Any] | None:
    old_tokens = _osrs_release_identity_tokens(old)
    new_tokens = _osrs_release_identity_tokens(new)
    shared_tokens = sorted(old_tokens & new_tokens)
    old_name_tokens = _osrs_release_name_tokens(old)
    new_name_tokens = _osrs_release_name_tokens(new)
    shared_name_tokens = sorted(old_name_tokens & new_name_tokens)
    overlap = _osrs_release_source_overlap(old, new)
    if not shared_tokens and (overlap == 0 or not shared_name_tokens):
        return None

    old_surface = old.get("is_surface")
    new_surface = new.get("is_surface")
    if isinstance(old_surface, bool) and isinstance(new_surface, bool):
        if old_surface != new_surface:
            raise osrsPipelineError(
                "realm lineage has contradictory surface classification: "
                f"{old.get('id')} -> {new.get('id')}"
            )
    old_group = old.get("group")
    new_group = new.get("group")
    if isinstance(old_group, str) and isinstance(new_group, str):
        if old_group != new_group:
            raise osrsPipelineError(
                "realm lineage crosses selector groups: "
                f"{old.get('id')} ({old_group}) -> {new.get('id')} ({new_group})"
            )
    return {
        "shared_identity_tokens": shared_tokens,
        "shared_normalized_name_alias_tokens": shared_name_tokens,
        "source_membership_overlap_area": overlap,
    }


def _osrs_release_identity_tokens(realm: Mapping[str, Any]) -> set[str]:
    result: set[str] = set()
    for field in ("native_file_id", "map_id"):
        value = realm.get(field)
        if value is not None:
            result.add(f"{field}:{value}")
    region_ids = realm.get("cache_region_ids", [])
    if not isinstance(region_ids, list):
        raise osrsPipelineError(
            f"realm {realm.get('id')} cache_region_ids must be an array"
        )
    result.update(f"cache_region_id:{value}" for value in region_ids)
    return result


def _osrs_release_name_tokens(realm: Mapping[str, Any]) -> set[str]:
    aliases = realm.get("aliases", [])
    if not isinstance(aliases, list) or not all(
        isinstance(alias, str) for alias in aliases
    ):
        raise osrsPipelineError(f"realm {realm.get('id')} aliases must be a string array")
    names = [str(realm.get("canonical_name", "")), *aliases]
    return {
        token
        for name in names
        for token in re.findall(r"[a-z0-9]+", name.casefold())
    }


def _osrs_release_source_overlap(
    old: Mapping[str, Any], new: Mapping[str, Any]
) -> int:
    old_rectangles = _osrs_release_source_rectangles(old)
    new_rectangles = _osrs_release_source_rectangles(new)
    overlap = 0
    for old_plane, old_rect in old_rectangles:
        for new_plane, new_rect in new_rectangles:
            if old_plane != new_plane:
                continue
            width = min(old_rect.max_x, new_rect.max_x) - max(
                old_rect.min_x, new_rect.min_x
            )
            height = min(old_rect.max_y, new_rect.max_y) - max(
                old_rect.min_y, new_rect.min_y
            )
            if width > 0 and height > 0:
                overlap += width * height
    return overlap


def _osrs_release_source_rectangles(
    realm: Mapping[str, Any],
) -> tuple[tuple[int, osrsRect], ...]:
    result: set[tuple[int, osrsRect]] = set()
    components = realm.get("components", [])
    if not isinstance(components, list):
        raise osrsPipelineError(f"realm {realm.get('id')} components must be an array")
    for raw_component in components:
        if not isinstance(raw_component, Mapping):
            raise osrsPipelineError(
                f"realm {realm.get('id')} component must be an object"
            )
        raw_bounds = raw_component.get("source_pixel_bounds")
        if raw_bounds is None:
            raw_bounds = raw_component.get("bounds")
        if not isinstance(raw_bounds, Mapping):
            continue
        rect = osrsRect(
            _osrs_int(raw_bounds.get("min_x"), "component.bounds.min_x"),
            _osrs_int(raw_bounds.get("min_y"), "component.bounds.min_y"),
            _osrs_int(raw_bounds.get("max_x"), "component.bounds.max_x"),
            _osrs_int(raw_bounds.get("max_y"), "component.bounds.max_y"),
        )
        raw_plane = raw_component.get("source_plane", raw_component.get("plane", 0))
        plane = _osrs_int(raw_plane, "component.source_plane")
        result.add((plane, rect))
    return tuple(sorted(result))


def _osrs_release_component_evidence(
    old_ids: Sequence[str],
    new_ids: Sequence[str],
    edges: Mapping[tuple[str, str], Mapping[str, Any]],
) -> dict[str, Any]:
    matching_edges = [
        {
            "from_id": old_id,
            "to_id": new_id,
            **dict(edges[(old_id, new_id)]),
        }
        for old_id in old_ids
        for new_id in new_ids
        if (old_id, new_id) in edges
    ]
    return {"matching_edges": matching_edges}


def osrs_canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            separators=(",", ": "),
        )
        + "\n"
    ).encode("utf-8")


def osrs_sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def osrs_write_json(path: Path, value: Any) -> str:
    payload = osrs_canonical_json_bytes(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return osrs_sha256_bytes(payload)


def _osrs_require_numpy() -> None:
    if np is None:
        raise osrsPipelineError(
            "NumPy is required; run this tool through `cd tools && pixi run python`"
        ) from _NUMPY_IMPORT_ERROR


def _osrs_validate_pixel_rect(
    rect: osrsRect, width: int, height: int, owner_id: str
) -> None:
    if (
        rect.min_x < 0
        or rect.min_y < 0
        or rect.max_x > width
        or rect.max_y > height
    ):
        raise osrsPipelineError(
            f"pixel rectangle for {owner_id} is outside {width}x{height}: {rect}"
        )


def _osrs_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise osrsPipelineError(f"{field} must be an integer")
    result = int(value)
    if result != value:
        raise osrsPipelineError(f"{field} must be an integer")
    return result


def _osrs_require_mapping(value: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    return _osrs_require_mapping_value(value.get(key), key)


def _osrs_require_mapping_value(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise osrsPipelineError(f"{field} must be an object")
    return value


def _osrs_parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="run a tiny exact-background conservation check",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _osrs_parse_args(sys.argv[1:] if argv is None else argv)
    if not args.self_check:
        raise osrsPipelineError("release CLI is not yet selected; use --self-check")
    _osrs_require_numpy()
    image = np.zeros((2, 2, 3), dtype=np.uint8)
    image[0, 0] = (0, 0, 1)
    result = osrs_account_source(
        image,
        [
            osrsPixelOwner(
                "cache-world-map:self-check",
                "named_non_surface_realm",
                (osrsRect(0, 0, 1, 1),),
            )
        ],
    )
    result.assert_release_ready()
    print(json.dumps(result.to_json(), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except osrsPipelineError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
