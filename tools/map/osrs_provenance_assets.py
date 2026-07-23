#!/usr/bin/env python3
"""Transform renderer provenance components into exact realm-local rasters."""

from __future__ import annotations

import hashlib
from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Iterator, Mapping, Sequence

import numpy as np

from osrs_non_surface_assets import osrsRenderedRealm
from osrs_non_surface_realms import (
    osrs_canonical_json_bytes,
    osrsPipelineError,
    osrsProjection,
    osrsRect,
    osrs_stable_native_realm_id,
)


OSRS_SPECIAL_REGION_PREFIX = "cache-special-region:"


@dataclass(frozen=True)
class osrsProvenanceComponent:
    code: int
    kind: str
    realm_file_id: int | None
    source_region_id: int | None
    rendered_plane: int
    source_plane: int
    dx: int
    dy: int
    source_pixel_bounds: osrsRect
    pixel_count: int
    content_bearing_pixel_count: int

    @property
    def display_pixel_bounds(self) -> osrsRect:
        return osrsRect(
            self.source_pixel_bounds.min_x + self.dx,
            self.source_pixel_bounds.min_y - self.dy,
            self.source_pixel_bounds.max_x + self.dx,
            self.source_pixel_bounds.max_y - self.dy,
        )


def osrs_special_region_realm_id(region_id: int) -> str:
    if region_id < 0 or region_id > 0xFFFF:
        raise osrsPipelineError(f"source region ID is outside uint16: {region_id}")
    return f"{OSRS_SPECIAL_REGION_PREFIX}{region_id >> 8}-{region_id & 0xFF}"


def osrs_build_special_region_index(
    plane_components: Mapping[int, Sequence[osrsProvenanceComponent]],
) -> dict[int, str]:
    """Return the canonical one-owner-per-cache-region identity mapping.

    Region adjacency and Wiki-view overlap are not evidence that two renderer
    owners share a semantic identity. Keeping the cache region ID as the
    backing-owner identity prevents unrelated adjacent instances from being
    merged while structured Wiki maps remain independent selectable views.
    """

    region_ids: set[int] = set()
    for components in plane_components.values():
        for component in components:
            if component.kind != "cache_loaded_special_region":
                continue
            if component.source_region_id is None:
                raise osrsPipelineError(
                    f"special provenance code {component.code} lacks a region ID"
                )
            region_ids.add(int(component.source_region_id))
    return {
        region_id: osrs_special_region_realm_id(region_id)
        for region_id in sorted(region_ids)
    }


def osrs_parse_provenance_components(
    ledger: Mapping[str, Any], streaming: Mapping[str, Any]
) -> tuple[osrsProvenanceComponent, ...]:
    codebook = ledger.get("codebook")
    counts = streaming.get("owner_counts")
    if not isinstance(codebook, list) or not isinstance(counts, list):
        raise osrsPipelineError("provenance codebook and owner_counts must be arrays")
    by_code: dict[int, Mapping[str, Any]] = {}
    for raw in codebook:
        entry = _osrs_mapping(raw, "codebook[]")
        code = _osrs_int(entry.get("code"), "code")
        if code in by_code:
            raise osrsPipelineError(f"duplicate provenance code: {code}")
        by_code[code] = entry
    rendered_plane = _osrs_int(
        _osrs_mapping(ledger.get("image"), "image").get("rendered_plane"),
        "image.rendered_plane",
    )
    components: list[osrsProvenanceComponent] = []
    for raw in counts:
        count = _osrs_mapping(raw, "owner_counts[]")
        code = _osrs_int(count.get("code"), "code")
        entry = by_code.get(code)
        if entry is None:
            raise osrsPipelineError(f"streaming count uses unknown provenance code {code}")
        bounds = count.get("pixel_bounds")
        if not isinstance(bounds, list) or len(bounds) != 4:
            raise osrsPipelineError(f"code {code} has invalid pixel_bounds")
        scale = _osrs_int(
            _osrs_mapping(ledger.get("projection"), "projection").get(
                "game_coord_scale"
            ),
            "game_coord_scale",
        )
        components.append(
            osrsProvenanceComponent(
                code=code,
                kind=str(entry.get("kind")),
                realm_file_id=(
                    None
                    if entry.get("realm_file_id") is None
                    else _osrs_int(entry.get("realm_file_id"), "realm_file_id")
                ),
                source_region_id=(
                    None
                    if entry.get("source_region_id") is None
                    else _osrs_int(entry.get("source_region_id"), "source_region_id")
                ),
                rendered_plane=rendered_plane,
                source_plane=_osrs_int(entry.get("source_plane"), "source_plane"),
                dx=_osrs_int(entry.get("source_to_display_dx"), "source_to_display_dx")
                * scale,
                dy=_osrs_int(entry.get("source_to_display_dy"), "source_to_display_dy")
                * scale,
                source_pixel_bounds=osrsRect(*(_osrs_int(value, "pixel_bounds") for value in bounds)),
                pixel_count=_osrs_int(count.get("total_pixels"), "total_pixels"),
                content_bearing_pixel_count=_osrs_int(
                    count.get("content_bearing_pixels"), "content_bearing_pixels"
                ),
            )
        )
    return tuple(sorted(components, key=lambda component: component.code))


def osrs_add_special_region_records(
    records: list[dict[str, Any]],
    plane_components: Mapping[int, Sequence[osrsProvenanceComponent]],
    basemaps: Sequence[Mapping[str, Any]],
    special_region_index: Mapping[int, str] | None = None,
) -> list[dict[str, Any]]:
    """Publish exact cache-loaded backing components under Other maps."""

    region_index = (
        dict(special_region_index)
        if special_region_index is not None
        else osrs_build_special_region_index(plane_components)
    )
    by_realm: dict[str, list[osrsProvenanceComponent]] = defaultdict(list)
    for plane in sorted(plane_components):
        for component in plane_components[plane]:
            if component.rendered_plane != plane:
                raise osrsPipelineError(
                    f"provenance component {component.code} is filed under rendered "
                    f"plane {plane}, ledger declares {component.rendered_plane}"
                )
            if component.kind == "cache_loaded_special_region":
                if component.source_region_id is None:
                    raise osrsPipelineError(
                        f"special provenance code {component.code} lacks a region ID"
                    )
                realm_id = region_index.get(component.source_region_id)
                if realm_id is None:
                    raise osrsPipelineError(
                        f"special region {component.source_region_id} has no backing-owner ID"
                    )
                expected_id = osrs_special_region_realm_id(component.source_region_id)
                if realm_id != expected_id:
                    raise osrsPipelineError(
                        f"special region {component.source_region_id} must map to "
                        f"{expected_id}, got {realm_id}"
                    )
                by_realm[realm_id].append(component)
    existing_ids = {str(record["id"]) for record in records}
    added: list[dict[str, Any]] = []
    for realm_id, components in sorted(by_realm.items()):
        if realm_id in existing_ids:
            raise osrsPipelineError(f"special region stable-ID collision: {realm_id}")
        region_ids = sorted(
            {
                int(component.source_region_id)
                for component in components
                if component.source_region_id is not None
            }
        )
        region_coordinates = [(region_id >> 8, region_id & 0xFF) for region_id in region_ids]
        if len(region_coordinates) != 1:
            raise osrsPipelineError(
                f"special backing owner {realm_id} coalesces cache regions {region_ids}"
            )
        region_x, region_y = region_coordinates[0]
        game_bounds = osrsRect(
            region_x * 64,
            region_y * 64,
            (region_x + 1) * 64,
            (region_y + 1) * 64,
        )
        related = [
            value
            for value in basemaps
            if _osrs_int(value.get("mapId"), "mapId") >= 10000
            and _osrs_rects_overlap(game_bounds, _osrs_wiki_bounds(value))
        ]
        candidate_wiki_map_ids = sorted(
            {_osrs_int(value.get("mapId"), "mapId") for value in related}
        )
        planes = sorted({component.rendered_plane for component in components})
        plane_zero_pixels = sum(
            component.pixel_count
            for component in components
            if component.rendered_plane == 0
        )
        source_mask_value = {
            "type": "renderer_provenance_codes",
            "ownership_basis": "cache_renderer_provenance_only",
            "wiki_bounds_used_for_pixel_ownership": False,
            "bounds": game_bounds.to_json(),
            "by_plane": {
                str(plane): {
                    "codes": sorted(
                        component.code
                        for component in components
                        if component.rendered_plane == plane
                    ),
                    "pixel_bounds": [
                        component.source_pixel_bounds.to_json()
                        for component in components
                        if component.rendered_plane == plane
                    ],
                }
                for plane in planes
            },
        }
        source_mask_value["sha256"] = hashlib.sha256(
            osrs_canonical_json_bytes(source_mask_value)
        ).hexdigest()
        ambiguity_reasons = ["semantic_identity_unresolved_generic_cache_region"]
        if not candidate_wiki_map_ids:
            ambiguity_reasons.append("no_structured_wiki_overlap_candidate")
        else:
            ambiguity_reasons.append(
                "wiki_overlap_is_non_authoritative_semantic_enrichment"
            )
            if len(candidate_wiki_map_ids) > 1:
                ambiguity_reasons.append("multiple_wiki_overlap_candidates")
        accounting_codes_by_plane = {
            str(plane): sorted(
                {
                    component.code
                    for component in components
                    if component.rendered_plane == plane
                }
            )
            for plane in planes
        }
        added.append(
            {
                "id": realm_id,
                "canonical_name": f"Cache region {region_x}, {region_y}",
                "aliases": [],
                "group": "other_maps",
                "is_surface": False,
                "native_file_id": None,
                "map_id": None,
                "article": None,
                "center": [
                    (game_bounds.min_x + game_bounds.max_x) // 2,
                    (game_bounds.min_y + game_bounds.max_y) // 2,
                ],
                "default_plane": planes[0],
                "planes": planes,
                "cache_declared_planes": planes,
                "source_mask": source_mask_value,
                "display_mask": dict(source_mask_value),
                "components": [
                    {
                        "component_index": index,
                        "plane": plane,
                        "bounds": game_bounds.to_json(),
                        "provenance_codes": sorted(
                            component.code
                            for component in components
                            if component.rendered_plane == plane
                        ),
                    }
                    for index, plane in enumerate(planes)
                ],
                "links": [],
                "source_revisions": {},
                "confidence": {
                    "classification": (
                        "authoritative_renderer_provenance_per_cache_region"
                    ),
                    "pixel_ownership_value": 1.0,
                    "semantic_identity_value": 0.0,
                },
                "pixel_ownership_status": "authoritative_renderer_provenance",
                "pixel_ownership_confidence": 1.0,
                "semantic_identity_status": "unresolved_generic_cache_region",
                "semantic_identity_confidence": 0.0,
                "ambiguity": {
                    "blocks_publication": False,
                    "reasons": ambiguity_reasons,
                    "unresolved_link_count": 0,
                },
                "accounting_owner_realm_id": realm_id if plane_zero_pixels else None,
                "accounting_pixel_count": plane_zero_pixels,
                "candidate_wiki_map_ids": candidate_wiki_map_ids,
                "cache_region_ids": region_ids,
                "accounting_provenance_codes_by_rendered_plane": (
                    accounting_codes_by_plane
                ),
                "assets": [],
            }
        )
        existing_ids.add(realm_id)
    records.extend(added)
    records.sort(
        key=lambda record: (
            {"surface": 0, "realms": 1, "other_maps": 2}[record["group"]],
            str(record["canonical_name"]).casefold(),
            str(record["id"]),
        )
    )
    return added


def osrs_special_region_accounting_report(
    records: Sequence[Mapping[str, Any]],
    plane_components: Mapping[int, Sequence[osrsProvenanceComponent]],
    expected_plane_zero_pixels: int,
) -> dict[str, Any]:
    """Validate and summarize the one-to-one special-region ownership model."""

    components_by_region: dict[
        int, dict[int, list[osrsProvenanceComponent]]
    ] = defaultdict(lambda: defaultdict(list))
    for plane, components in sorted(plane_components.items()):
        for component in components:
            if component.kind != "cache_loaded_special_region":
                continue
            if component.rendered_plane != plane:
                raise osrsPipelineError(
                    f"special component {component.code} rendered-plane mismatch"
                )
            if component.source_region_id is None:
                raise osrsPipelineError(
                    f"special component {component.code} lacks source_region_id"
                )
            components_by_region[int(component.source_region_id)][plane].append(
                component
            )

    special_records = {
        str(record.get("id")): record
        for record in records
        if str(record.get("id", "")).startswith(OSRS_SPECIAL_REGION_PREFIX)
    }
    expected_ids = {
        osrs_special_region_realm_id(region_id)
        for region_id in components_by_region
    }
    false_checks: list[str] = []

    def check(name: str, condition: bool) -> None:
        if not condition:
            false_checks.append(name)

    check("one_manifest_record_per_used_cache_region", set(special_records) == expected_ids)
    seen_codes: set[tuple[int, int]] = set()
    duplicate_codes = False
    manifest_pixel_sum = 0
    candidate_counts = {"none": 0, "one": 0, "multiple": 0}
    for region_id, by_plane in sorted(components_by_region.items()):
        realm_id = osrs_special_region_realm_id(region_id)
        record = special_records.get(realm_id)
        if record is None:
            continue
        region_x, region_y = region_id >> 8, region_id & 0xFF
        check(
            f"{realm_id}:single_cache_region",
            record.get("cache_region_ids") == [region_id],
        )
        check(
            f"{realm_id}:stable_canonical_name",
            record.get("canonical_name") == f"Cache region {region_x}, {region_y}",
        )
        check(f"{realm_id}:no_semantic_alias_guess", record.get("aliases") == [])
        check(
            f"{realm_id}:pixel_ownership_status",
            record.get("pixel_ownership_status")
            == "authoritative_renderer_provenance"
            and record.get("pixel_ownership_confidence") == 1.0,
        )
        check(
            f"{realm_id}:semantic_identity_status",
            record.get("semantic_identity_status")
            == "unresolved_generic_cache_region"
            and record.get("semantic_identity_confidence") == 0.0,
        )
        candidates = record.get("candidate_wiki_map_ids")
        valid_candidates = (
            isinstance(candidates, list)
            and all(isinstance(value, int) and value >= 10000 for value in candidates)
            and candidates == sorted(set(candidates))
        )
        check(f"{realm_id}:candidate_wiki_ids_are_enrichment_only", valid_candidates)
        candidate_count = len(candidates) if isinstance(candidates, list) else 0
        candidate_counts[
            "none" if candidate_count == 0 else "one" if candidate_count == 1 else "multiple"
        ] += 1

        expected_codes = {
            str(plane): sorted({component.code for component in components})
            for plane, components in sorted(by_plane.items())
        }
        check(
            f"{realm_id}:accounting_codes",
            record.get("accounting_provenance_codes_by_rendered_plane")
            == expected_codes,
        )
        for plane, components in by_plane.items():
            for component in components:
                key = (plane, component.code)
                duplicate_codes = duplicate_codes or key in seen_codes
                seen_codes.add(key)

        plane_zero_pixels = sum(
            component.pixel_count for component in by_plane.get(0, [])
        )
        record_pixel_count = record.get("accounting_pixel_count")
        valid_record_pixel_count = (
            isinstance(record_pixel_count, int)
            and not isinstance(record_pixel_count, bool)
            and record_pixel_count >= 0
        )
        manifest_pixel_sum += record_pixel_count if valid_record_pixel_count else 0
        check(
            f"{realm_id}:plane_zero_pixel_count",
            valid_record_pixel_count and record_pixel_count == plane_zero_pixels,
        )
        check(
            f"{realm_id}:accounting_owner",
            record.get("accounting_owner_realm_id")
            == (realm_id if plane_zero_pixels else None),
        )

    component_pixel_sum = sum(
        value.pixel_count
        for by_plane in components_by_region.values()
        for value in by_plane.get(0, [])
    )
    check("no_provenance_code_shared_between_region_owners", not duplicate_codes)
    check(
        "component_sum_matches_source_accounting",
        component_pixel_sum == expected_plane_zero_pixels,
    )
    check(
        "manifest_sum_matches_source_accounting",
        manifest_pixel_sum == expected_plane_zero_pixels,
    )
    checks = {
        "one_manifest_record_per_used_cache_region": (
            "one_manifest_record_per_used_cache_region" not in false_checks
        ),
        "no_cache_regions_coalesced": all(
            not name.endswith(":single_cache_region") for name in false_checks
        ),
        "no_provenance_code_shared_between_region_owners": not duplicate_codes,
        "component_sum_matches_source_accounting": (
            component_pixel_sum == expected_plane_zero_pixels
        ),
        "manifest_sum_matches_source_accounting": (
            manifest_pixel_sum == expected_plane_zero_pixels
        ),
        "all_record_invariants_hold": not false_checks,
    }
    if false_checks:
        preview = ", ".join(false_checks[:8])
        if len(false_checks) > 8:
            preview += f", ... ({len(false_checks)} total)"
        raise osrsPipelineError(f"special-region accounting validation failed: {preview}")
    return {
        "identity_model": "one_backing_owner_per_used_cache_source_region",
        "pixel_ownership_source": "cache_renderer_provenance_only",
        "wiki_bounds_used_for_pixel_ownership": False,
        "semantic_identity_status": "unresolved_generic_cache_region",
        "cache_region_count": len(components_by_region),
        "manifest_backing_owner_count": len(special_records),
        "plane_zero_cache_region_count": sum(
            bool(by_plane.get(0)) for by_plane in components_by_region.values()
        ),
        "plane_zero_accounting_pixel_count": manifest_pixel_sum,
        "expected_plane_zero_accounting_pixel_count": expected_plane_zero_pixels,
        "accounting_provenance_code_count_by_rendered_plane": {
            str(plane): sum(
                len(components.get(plane, []))
                for components in components_by_region.values()
            )
            for plane in sorted(plane_components)
        },
        "candidate_wiki_map_id_counts": candidate_counts,
        "checks": checks,
    }


def osrs_iter_rendered_provenance_realms(
    source_rgb: np.ndarray,
    owner_codes: np.ndarray,
    projection: osrsProjection,
    components: Sequence[osrsProvenanceComponent],
    definitions: Sequence[Mapping[str, Any]],
    special_region_index: Mapping[int, str] | None = None,
) -> Iterator[tuple[str, osrsRenderedRealm]]:
    """Yield lossless, tightly packed source-component rasters.

    Components sharing a source-to-display transform retain their exact source
    coordinate relationship. Distinct transform groups are packed with a
    one-game-pixel transparent gutter. This avoids both large atlas margins and
    destructive display-coordinate collisions; the manifest separately keeps
    every authoritative source/display transform.
    """

    source = np.asarray(source_rgb)
    owners = np.asarray(owner_codes)
    if source.shape[:2] != owners.shape or owners.dtype.kind not in {"u", "i"}:
        raise osrsPipelineError("source RGB and owner-code raster dimensions differ")
    stable_id_by_file = {
        _osrs_int(definition.get("file_id"), "file_id"): osrs_stable_native_realm_id(
            definition
        )
        for definition in definitions
    }
    by_realm: dict[str, list[osrsProvenanceComponent]] = defaultdict(list)
    for component in components:
        if component.source_plane < 0 or component.rendered_plane < 0:
            raise osrsPipelineError("negative provenance source/rendered plane")
        if component.kind == "native_composite":
            if component.realm_file_id not in stable_id_by_file:
                raise osrsPipelineError(
                    f"provenance references unknown file ID {component.realm_file_id}"
                )
            realm_id = stable_id_by_file[int(component.realm_file_id)]
        elif component.kind == "cache_loaded_special_region":
            if component.source_region_id is None:
                raise osrsPipelineError("special component lacks source_region_id")
            realm_id = (
                special_region_index.get(component.source_region_id)
                if special_region_index is not None
                else osrs_special_region_realm_id(component.source_region_id)
            )
            if realm_id is None:
                raise osrsPipelineError(
                    f"special region {component.source_region_id} is not indexed"
                )
            expected_id = osrs_special_region_realm_id(component.source_region_id)
            if realm_id != expected_id:
                raise osrsPipelineError(
                    f"special region {component.source_region_id} must render as "
                    f"{expected_id}, got {realm_id}"
                )
        else:
            raise osrsPipelineError(f"unknown provenance kind: {component.kind}")
        by_realm[realm_id].append(component)

    for realm_id in sorted(by_realm):
        realm_components = sorted(by_realm[realm_id], key=lambda value: value.code)
        planes = {component.rendered_plane for component in realm_components}
        if len(planes) != 1:
            raise osrsPipelineError(
                f"render iterator received multiple rendered planes for {realm_id}: "
                f"{sorted(planes)}"
            )
        plane = next(iter(planes))
        groups: dict[tuple[int, int], list[osrsProvenanceComponent]] = defaultdict(list)
        for component in realm_components:
            groups[(component.dx, component.dy)].append(component)
        prepared: list[
            tuple[tuple[int, int], osrsRect, list[osrsProvenanceComponent]]
        ] = []
        for transform, values in sorted(groups.items()):
            raw_bounds = _osrs_union_bounds(
                component.source_pixel_bounds for component in values
            )
            aligned_bounds = osrsRect(
                _osrs_floor_multiple(raw_bounds.min_x, projection.scale),
                _osrs_floor_multiple(raw_bounds.min_y, projection.scale),
                _osrs_ceil_multiple(raw_bounds.max_x, projection.scale),
                _osrs_ceil_multiple(raw_bounds.max_y, projection.scale),
            )
            prepared.append((transform, aligned_bounds, sorted(values, key=lambda value: value.code)))

        gap = projection.scale
        total_area = sum(
            (bounds.width + gap) * (bounds.height + gap)
            for _, bounds, _ in prepared
        )
        target_width = max(
            max(bounds.width for _, bounds, _ in prepared),
            _osrs_ceil_multiple(int(np.ceil(np.sqrt(total_area))), projection.scale),
        )
        placements: list[
            tuple[tuple[int, int], osrsRect, list[osrsProvenanceComponent], osrsRect]
        ] = []
        cursor_x = 0
        cursor_y = 0
        row_height = 0
        packed_width = 0
        for transform, bounds, values in prepared:
            if cursor_x and cursor_x + bounds.width > target_width:
                cursor_x = 0
                cursor_y += row_height + gap
                row_height = 0
            destination = osrsRect(
                cursor_x,
                cursor_y,
                cursor_x + bounds.width,
                cursor_y + bounds.height,
            )
            placements.append((transform, bounds, values, destination))
            cursor_x += bounds.width + gap
            row_height = max(row_height, bounds.height)
            packed_width = max(packed_width, destination.max_x)
        packed_height = max(destination.max_y for *_, destination in placements)
        rgba = np.zeros((packed_height, packed_width, 4), dtype=np.uint8)
        mask = np.zeros((packed_height, packed_width), dtype=np.bool_)
        source_bounds: list[osrsRect] = []
        layout_rows: list[dict[str, Any]] = []
        for transform, group_bounds, values, destination in placements:
            for component in values:
                bounds = component.source_pixel_bounds
                source_crop = source[
                    bounds.min_y : bounds.max_y,
                    bounds.min_x : bounds.max_x,
                    :3,
                ]
                owner_crop = owners[
                    bounds.min_y : bounds.max_y,
                    bounds.min_x : bounds.max_x,
                ]
                local_y, local_x = np.nonzero(owner_crop == component.code)
                if local_x.size != component.pixel_count:
                    raise osrsPipelineError(
                        f"code {component.code} ledger count={component.pixel_count}, "
                        f"raster count={local_x.size}"
                    )
                destination_x = (
                    local_x + bounds.min_x - group_bounds.min_x + destination.min_x
                )
                destination_y = (
                    local_y + bounds.min_y - group_bounds.min_y + destination.min_y
                )
                if np.any(mask[destination_y, destination_x]):
                    raise osrsPipelineError(
                        f"source-coordinate owner collision in {realm_id} floor {plane}"
                    )
                colors = source_crop[local_y, local_x]
                rgba[destination_y, destination_x, :3] = colors
                rgba[destination_y, destination_x, 3] = 255
                mask[destination_y, destination_x] = True
                source_bounds.append(_osrs_pixel_bounds_to_game(bounds, projection))
            layout_rows.append(
                {
                    "source_to_display_dx_pixels": transform[0],
                    "source_to_display_dy_pixels": transform[1],
                    "provenance_codes": [component.code for component in values],
                    "source_pixel_bounds": group_bounds.to_json(),
                    "asset_pixel_bounds": destination.to_json(),
                    "assigned_source_pixel_count": sum(
                        component.pixel_count for component in values
                    ),
                }
            )
        display_game_bounds = osrsRect(
            0,
            0,
            packed_width // projection.scale,
            packed_height // projection.scale,
        )
        yield (
            realm_id,
            osrsRenderedRealm(
                rgba=rgba,
                mask=mask,
                source_bounds=tuple(sorted(set(source_bounds))),
                display_bounds=display_game_bounds,
                plane=plane,
                assigned_source_pixel_count=sum(
                    component.pixel_count for component in realm_components
                ),
                identical_rgb_display_collision_count=0,
                layout_components=tuple(layout_rows),
            ),
        )


def _osrs_pixel_bounds_to_game(rect: osrsRect, projection: osrsProjection) -> osrsRect:
    if any(value % projection.scale for value in (rect.min_x, rect.min_y, rect.max_x, rect.max_y)):
        rect = osrsRect(
            _osrs_floor_multiple(rect.min_x, projection.scale),
            _osrs_floor_multiple(rect.min_y, projection.scale),
            _osrs_ceil_multiple(rect.max_x, projection.scale),
            _osrs_ceil_multiple(rect.max_y, projection.scale),
        )
    return osrsRect(
        projection.game_min_x + rect.min_x // projection.scale,
        projection.game_max_y - rect.max_y // projection.scale,
        projection.game_min_x + rect.max_x // projection.scale,
        projection.game_max_y - rect.min_y // projection.scale,
    )


def _osrs_floor_multiple(value: int, multiple: int) -> int:
    return (value // multiple) * multiple


def _osrs_ceil_multiple(value: int, multiple: int) -> int:
    return -((-value // multiple) * multiple)


def _osrs_union_bounds(rects: Sequence[osrsRect] | Iterator[osrsRect]) -> osrsRect:
    values = tuple(rects)
    if not values:
        raise osrsPipelineError("cannot union empty provenance bounds")
    return osrsRect(
        min(value.min_x for value in values),
        min(value.min_y for value in values),
        max(value.max_x for value in values),
        max(value.max_y for value in values),
    )


def _osrs_wiki_bounds(value: Mapping[str, Any]) -> osrsRect:
    bounds = value.get("bounds")
    if not isinstance(bounds, list) or len(bounds) != 2:
        raise osrsPipelineError(f"mapID {value.get('mapId')} has invalid bounds")
    return osrsRect(
        _osrs_int(bounds[0][0], "bounds.min_x"),
        _osrs_int(bounds[0][1], "bounds.min_y"),
        _osrs_int(bounds[1][0], "bounds.max_x"),
        _osrs_int(bounds[1][1], "bounds.max_y"),
    )


def _osrs_rects_overlap(left: osrsRect, right: osrsRect) -> bool:
    return not (
        left.max_x <= right.min_x
        or right.max_x <= left.min_x
        or left.max_y <= right.min_y
        or right.max_y <= left.min_y
    )


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
