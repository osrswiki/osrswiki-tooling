#!/usr/bin/env python3
"""Build a deterministic OSRS non-surface realm release from pinned inputs."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np
from jsonschema import Draft202012Validator
from PIL import Image

from osrs_non_surface_assets import (
    osrs_assert_mbtiles_alpha_matches_mask,
    osrs_asset_stem,
    osrs_boundary_provenance_report,
    osrs_build_manifest_records,
    osrs_manifest_schema,
    osrs_reconcile_intermap_links,
    osrs_release_relative_path,
    osrs_render_wiki_view,
    osrs_save_mask_png,
    osrs_shared_realm_canvas_layout,
    osrs_sha256_file,
    osrs_validate_manifest,
    osrs_write_mbtiles,
)
from osrs_non_surface_realms import (
    OSRS_SCHEMA_VERSION,
    osrs_account_provenance_summary,
    osrs_canonical_json_bytes,
    osrs_other_map_id,
    osrs_preserve_previous_aliases,
    osrs_release_diff,
    osrs_stable_native_realm_id,
    osrs_write_json,
    osrsPipelineError,
    osrsProjection,
    osrsRect,
)
from osrs_provenance_assets import (
    osrs_add_special_region_records,
    osrs_build_special_region_index,
    osrs_iter_rendered_provenance_realms,
    osrs_parse_provenance_components,
    osrs_special_region_accounting_report,
    osrsProvenanceComponent,
)
from osrs_public_path_hygiene import (
    osrs_assert_public_json_portable,
    osrs_portabilize_source_snapshot,
    osrs_validate_public_release_tree,
    osrsPublicPathError,
)
from osrs_release_toolchain import (
    osrs_collect_locked_release_toolchain,
    osrs_write_invocation_report,
    osrsToolchainError,
)


Image.MAX_IMAGE_PIXELS = None


def osrs_build_release(
    args: argparse.Namespace,
    *,
    toolchain_provenance: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    inventory = _osrs_read_json(args.inventory)
    basemaps = _osrs_read_json(args.basemaps)
    alignment = _osrs_read_json(args.alignment)
    source_metadata = _osrs_read_json(args.source_metadata)
    source_snapshots = _osrs_read_json(args.source_snapshots)
    if not isinstance(inventory, Mapping):
        raise osrsPipelineError("inventory must be an object")
    if not isinstance(basemaps, list):
        raise osrsPipelineError("basemaps must be an array")
    if not isinstance(alignment, Mapping):
        raise osrsPipelineError("alignment must be an object")
    if not isinstance(source_metadata, Mapping):
        raise osrsPipelineError("source metadata must be an object")
    if not isinstance(source_snapshots, Mapping):
        raise osrsPipelineError("source snapshots must be an object")
    try:
        public_source_snapshots = osrs_portabilize_source_snapshot(source_snapshots)
    except osrsPublicPathError as error:
        raise osrsPipelineError(f"source snapshot path hygiene failed: {error}") from error
    prior = _osrs_read_json(args.prior_manifest) if args.prior_manifest else None
    if prior is not None and not isinstance(prior, Mapping):
        raise osrsPipelineError("prior manifest must be an object")
    prior_asset_planes = _osrs_prior_asset_planes_by_realm(prior)
    raw_definitions = inventory.get("definitions")
    if not isinstance(raw_definitions, list):
        raise osrsPipelineError("inventory.definitions must be an array")
    definitions = [
        _osrs_mapping(value, "inventory.definitions[]")
        for value in raw_definitions
    ]

    output = args.output.resolve()
    reports_dir = output / "reports"
    manifests_dir = output / "manifests"
    assets_dir = output / "assets"
    masks_dir = output / "masks"
    reports_dir.mkdir(parents=True, exist_ok=True)
    manifests_dir.mkdir(parents=True, exist_ok=True)

    toolchain_path: Path | None = None
    toolchain_sha: str | None = None
    if toolchain_provenance is not None:
        expected_helper_sha = str(args.accounting_helper_sha256)
        toolchain_value = dict(toolchain_provenance)
        toolchain_value["content_addressed_inputs"] = {
            "accounting_helper": {
                "logical_id": "tool://osrs-source-accounting",
                "sha256": expected_helper_sha,
            }
        }
        toolchain_path = reports_dir / "toolchain-provenance.json"
        toolchain_sha = osrs_write_json(toolchain_path, toolchain_value)

    projection = osrsProjection.from_metadata(source_metadata)
    plane_states: dict[int, dict[str, Any]] = {}
    for plane in args.planes:
        plane_states[plane] = _osrs_load_plane_state(
            args, plane, projection, reports_dir
        )
    if 0 not in plane_states:
        raise osrsPipelineError("floor 0 is mandatory for source conservation")

    plane_zero = plane_states[0]
    accounting_json = osrs_account_provenance_summary(
        plane_zero["streaming"], plane_zero["ledger"], definitions
    )
    accounting_json["candidate"] = args.candidate
    accounting_json["acceptance_scope"] = "monolithic_plane_0_base_raster"
    accounting_json["source"] = _osrs_plane_input_record(plane_zero, output)
    accounting_json["streaming_accounting"] = {
        "path": osrs_release_relative_path(plane_zero["streaming_path"], output),
        "sha256": osrs_sha256_file(plane_zero["streaming_path"]),
        "helper_path": "tool://osrs-source-accounting",
        "helper_sha256": osrs_sha256_file(args.accounting_helper),
    }
    _osrs_assert_public_json(accounting_json, "reports/source-accounting.json")
    accounting_path = reports_dir / "source-accounting.json"
    accounting_sha = osrs_write_json(accounting_path, accounting_json)
    if not accounting_json["checks"]["release_ready"]:
        failure = {
            "schema_version": OSRS_SCHEMA_VERSION,
            "candidate": args.candidate,
            "status": "FAILED_SOURCE_CONSERVATION",
            "accounting_path": osrs_release_relative_path(accounting_path, output),
            "accounting_sha256": accounting_sha,
            "checks": accounting_json["checks"],
            "required_action": (
                "Resolve every content-bearing residual from authoritative cache or "
                "pinned Wiki evidence; do not discard or threshold it."
            ),
        }
        _osrs_assert_public_json(
            failure, "reports/source-accounting-failure.json"
        )
        osrs_write_json(reports_dir / "source-accounting-failure.json", failure)
        raise osrsPipelineError(
            "candidate generation stopped because source conservation is not "
            f"release-ready; see {accounting_path}"
        )

    if args.accounting_only:
        return {
            "status": "ACCOUNTING_READY",
            "accounting_path": osrs_release_relative_path(accounting_path, output),
            "accounting_sha256": accounting_sha,
            "unresolved_content_bearing_residual_pixels": 0,
        }

    records = osrs_build_manifest_records(
        inventory, basemaps, available_planes=tuple(sorted(plane_states))
    )
    components_by_plane = {
        plane: state["components"] for plane, state in plane_states.items()
    }
    special_region_index = osrs_build_special_region_index(components_by_plane)
    special_records = osrs_add_special_region_records(
        records, components_by_plane, basemaps, special_region_index
    )
    _osrs_apply_provenance_geometry(
        records, components_by_plane, definitions, special_region_index
    )
    link_summary = osrs_reconcile_intermap_links(records, inventory, alignment)

    records_by_id = {str(record["id"]): record for record in records}
    wiki_by_id = {int(value["mapId"]): value for value in basemaps}
    assets_by_realm: dict[str, list[dict[str, Any]]] = {
        realm_id: [] for realm_id in records_by_id
    }

    rendered_geometry_by_realm: dict[str, list[dict[str, Any]]] = {
        realm_id: [] for realm_id in records_by_id
    }
    for realm_id, record, rendered in _osrs_iter_release_rendered_assets(
        plane_states=plane_states,
        projection=projection,
        definitions=definitions,
        special_region_index=special_region_index,
        records=records,
        records_by_id=records_by_id,
        wiki_by_id=wiki_by_id,
        prior_asset_planes=prior_asset_planes,
    ):
        coordinates = np.argwhere(np.asarray(rendered.mask))
        if coordinates.size == 0:
            raise osrsPipelineError(
                f"rendered geometry unexpectedly blank: {realm_id} floor {rendered.plane}"
            )
        min_y, min_x = coordinates.min(axis=0)
        max_y, max_x = coordinates.max(axis=0)
        rendered_geometry_by_realm[realm_id].append(
            {
                "plane": int(rendered.plane),
                "width": int(rendered.rgba.shape[1]),
                "height": int(rendered.rgba.shape[0]),
                "content_pixel_bounds": [
                    int(min_x),
                    int(min_y),
                    int(max_x) + 1,
                    int(max_y) + 1,
                ],
            }
        )

    canvas_layout_by_realm = {
        realm_id: osrs_shared_realm_canvas_layout(
            geometry,
            is_surface=bool(records_by_id[realm_id].get("is_surface", False)),
        )
        for realm_id, geometry in rendered_geometry_by_realm.items()
        if geometry
    }

    for realm_id, record, rendered in _osrs_iter_release_rendered_assets(
        plane_states=plane_states,
        projection=projection,
        definitions=definitions,
        special_region_index=special_region_index,
        records=records,
        records_by_id=records_by_id,
        wiki_by_id=wiki_by_id,
        prior_asset_planes=prior_asset_planes,
    ):
        assets_by_realm[realm_id].append(
            _osrs_write_rendered_asset(
                rendered,
                record,
                assets_dir,
                masks_dir,
                output,
                canvas_layout=canvas_layout_by_realm[realm_id],
            )
        )

    inventory_sha = osrs_sha256_file(args.inventory)
    basemaps_sha = osrs_sha256_file(args.basemaps)
    alignment_sha = osrs_sha256_file(args.alignment)
    provenance_revisions = {
        str(plane): _osrs_plane_input_record(state, output)
        for plane, state in sorted(plane_states.items())
    }
    excluded_blank_wiki_views = [
        {
            "id": str(record["id"]),
            "map_id": int(record["map_id"]),
            "canonical_name": str(record["canonical_name"]),
            "reason": "no_content_bearing_pixels_on_rendered_floors_0_through_3",
        }
        for record in records
        if record["group"] == "other_maps"
        and record.get("map_id") is not None
        and not assets_by_realm[str(record["id"])]
    ]
    excluded_ids = {value["id"] for value in excluded_blank_wiki_views}
    if excluded_ids:
        records = [record for record in records if str(record["id"]) not in excluded_ids]
    for record in records:
        realm_id = str(record["id"])
        assets = sorted(
            assets_by_realm[realm_id], key=lambda value: value["plane"]
        )
        if not assets:
            raise osrsPipelineError(f"published realm has no generated asset: {realm_id}")
        published_planes = [int(asset["plane"]) for asset in assets]
        if len(published_planes) != len(set(published_planes)):
            raise osrsPipelineError(f"realm has duplicate plane assets: {realm_id}")
        record["assets"] = assets
        record["planes"] = published_planes
        if record["default_plane"] not in published_planes:
            record["default_plane"] = published_planes[0]
        record["source_revisions"] = {
            "cache_id": int(source_snapshots.get("cache", {}).get("cache_id", 2499)),
            "world_map_inventory_sha256": inventory_sha,
            "wiki_basemaps_sha256": basemaps_sha,
            "alignment_sha256": alignment_sha,
            "renderer_provenance_by_rendered_plane": provenance_revisions,
        }

    # Source conservation is intentionally broader than product publication. Validate every
    # authoritative cache owner and Wiki-defined source view before removing noncanonical runtime
    # records; the evidence remains available without shipping those 1,047 user-defined/special
    # map entries or their raster payloads in either app.
    accounting_records = records
    validation = _osrs_asset_validation(
        accounting_records, accounting_json, components_by_plane
    )
    validation_path = reports_dir / "realm-asset-validation.json"
    validation_sha = osrs_write_json(validation_path, validation)

    excluded_runtime_records = [
        record for record in accounting_records if record["group"] not in {"surface", "realms"}
    ]
    records = [
        record for record in accounting_records if record["group"] in {"surface", "realms"}
    ]
    expected_runtime_realm_count = sum(
        record["group"] in {"surface", "realms"} for record in accounting_records
    )
    expected_surface_count = sum(
        record["group"] == "surface" for record in accounting_records
    )
    if (
        len(records) != expected_runtime_realm_count
        or sum(record["group"] == "surface" for record in records) != expected_surface_count
    ):
        raise osrsPipelineError(
            "canonical runtime publication must preserve every source surface and named native realm"
        )
    runtime_exclusion_report = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "policy": "surface-plus-named-native-cache-realms-only",
        "published_groups": ["surface", "realms"],
        "published_realm_count": len(records),
        "excluded_realm_count": len(excluded_runtime_records),
        "excluded_group_counts": {
            group: sum(record["group"] == group for record in excluded_runtime_records)
            for group in sorted({str(record["group"]) for record in excluded_runtime_records})
        },
        "excluded_records": [
            {
                "id": str(record["id"]),
                "canonical_name": str(record["canonical_name"]),
                "group": str(record["group"]),
                "map_id": record.get("map_id"),
                "asset_sha256": [
                    str(asset["mbtiles_sha256"])
                    for asset in sorted(record.get("assets", []), key=lambda value: value["plane"])
                ],
            }
            for record in excluded_runtime_records
        ],
        "checks": {
            "source_accounting_completed_before_exclusion": validation["checks"]["release_ready"],
            "runtime_contains_only_canonical_groups": all(
                record["group"] in {"surface", "realms"} for record in records
            ),
            "runtime_realm_count_matches_canonical_source": (
                len(records) == expected_runtime_realm_count
            ),
        },
    }
    _osrs_assert_public_json(runtime_exclusion_report, "reports/runtime-publication-policy.json")
    runtime_exclusion_path = reports_dir / "runtime-publication-policy.json"
    runtime_exclusion_sha = osrs_write_json(
        runtime_exclusion_path,
        runtime_exclusion_report,
    )
    for record in excluded_runtime_records:
        stem = osrs_asset_stem(str(record["id"]))
        shutil.rmtree(assets_dir / stem, ignore_errors=True)
        shutil.rmtree(masks_dir / stem, ignore_errors=True)
    expected_asset_paths = {
        str(asset["mbtiles_path"])
        for record in records
        for asset in record.get("assets", [])
    }
    expected_mask_paths = {
        str(asset[path_key])
        for record in records
        for asset in record.get("assets", [])
        for path_key in ("mask_path", "ownership_mask_path")
    }
    actual_asset_paths = {
        osrs_release_relative_path(path, output)
        for path in assets_dir.rglob("*.mbtiles")
    }
    actual_mask_paths = {
        osrs_release_relative_path(path, output)
        for path in masks_dir.rglob("*.png")
    }
    if actual_asset_paths != expected_asset_paths or actual_mask_paths != expected_mask_paths:
        raise osrsPipelineError(
            "runtime publication tree contains missing or noncanonical asset payloads"
        )

    osrs_write_json(
        reports_dir / "wiki-view-publication.json",
        {
            "schema_version": OSRS_SCHEMA_VERSION,
            "published_structured_wiki_view_count": 0,
            "excluded_blank_views": excluded_blank_wiki_views,
            "excluded_noncanonical_view_count": sum(
                record["group"] == "other_maps" and record.get("map_id") is not None
                for record in excluded_runtime_records
            ),
            "checks": {
                "all_published_views_nonblank": True,
                "no_wiki_authored_view_is_runtime_published": True,
            },
        },
    )

    osrs_preserve_previous_aliases(prior, records)
    release_diff = osrs_release_diff(prior, records)

    boundary_provenance = osrs_boundary_provenance_report(
        records,
        prior.get("realms", []) if isinstance(prior, Mapping) else (),
    )
    boundary_provenance_path = reports_dir / "boundary-provenance.json"
    boundary_provenance_sha = osrs_write_json(
        boundary_provenance_path,
        boundary_provenance,
    )

    selector_ids = [str(record["id"]) for record in records]
    manifest = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "candidate": args.candidate,
        "product": {
            "label": "OSRS Underground Maps",
            "application_id": "com.omiyawaki.osrswiki.undergroundmaps",
        },
        "inputs": {
            "source_snapshots": public_source_snapshots,
            **(
                {
                    "release_toolchain": {
                        "path": osrs_release_relative_path(toolchain_path, output),
                        "sha256": toolchain_sha,
                        "contract_id": toolchain_provenance["contract_id"],
                        "sqlite_version": toolchain_provenance["runtime"][
                            "sqlite_version"
                        ],
                        "sqlite_version_number": toolchain_provenance["runtime"][
                            "sqlite_version_number"
                        ],
                    }
                }
                if toolchain_path is not None
                and toolchain_sha is not None
                and toolchain_provenance is not None
                else {}
            ),
            "world_map_inventory": {
                "path": "input://cache/world-map-inventory",
                "sha256": inventory_sha,
            },
            "wiki_basemaps": {
                "path": "input://wiki/versioned-basemaps",
                "sha256": basemaps_sha,
            },
            "renderer_provenance_by_rendered_plane": provenance_revisions,
            "boundary_provenance": {
                "path": osrs_release_relative_path(boundary_provenance_path, output),
                "sha256": boundary_provenance_sha,
                "policy": (
                    "finite-content-envelope; four-sided-center-edge-overbound; "
                    "horizontal-wrap-disabled"
                ),
            },
            "runtime_publication_policy": {
                "path": osrs_release_relative_path(runtime_exclusion_path, output),
                "sha256": runtime_exclusion_sha,
                "policy": "surface-plus-named-native-cache-realms-only",
                "published_realm_count": len(records),
                "excluded_realm_count": len(excluded_runtime_records),
            },
        },
        "accounting": accounting_json,
        "realms": records,
        "selector": {
            "entry_ids": selector_ids,
            "entry_count": len(selector_ids),
            "realm_count": len(records),
            "bijection": True,
        },
        "intermap_links": link_summary,
    }
    _osrs_assert_public_json(manifest, "manifests/underground-realms.json")
    osrs_validate_manifest(manifest)
    schema = osrs_manifest_schema()
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(manifest)
    manifest_path = manifests_dir / "underground-realms.json"
    manifest_sha = osrs_write_json(manifest_path, manifest)
    root_manifest_path = output / "underground-realms.json"
    root_manifest_sha = osrs_write_json(root_manifest_path, manifest)
    if root_manifest_sha != manifest_sha:
        raise osrsPipelineError("root and evidence manifests are not byte-identical")
    schema_path = manifests_dir / "underground-realms.schema.json"
    schema_sha = osrs_write_json(schema_path, schema)
    release_diff_path = manifests_dir / "release-diff.json"
    release_diff_sha = osrs_write_json(release_diff_path, release_diff)
    path_hygiene_path, path_hygiene_sha = _osrs_write_path_hygiene_report(output)
    return {
        "status": "RELEASE_READY",
        "manifest_path": osrs_release_relative_path(root_manifest_path, output),
        "manifest_sha256": manifest_sha,
        "evidence_manifest_path": osrs_release_relative_path(manifest_path, output),
        "schema_path": osrs_release_relative_path(schema_path, output),
        "schema_sha256": schema_sha,
        "accounting_path": osrs_release_relative_path(accounting_path, output),
        "accounting_sha256": accounting_sha,
        "asset_validation_path": osrs_release_relative_path(validation_path, output),
        "asset_validation_sha256": validation_sha,
        "boundary_provenance_path": osrs_release_relative_path(
            boundary_provenance_path, output
        ),
        "boundary_provenance_sha256": boundary_provenance_sha,
        "runtime_publication_policy_path": osrs_release_relative_path(
            runtime_exclusion_path, output
        ),
        "runtime_publication_policy_sha256": runtime_exclusion_sha,
        "release_diff_path": osrs_release_relative_path(release_diff_path, output),
        "release_diff_sha256": release_diff_sha,
        "path_hygiene_path": osrs_release_relative_path(path_hygiene_path, output),
        "path_hygiene_sha256": path_hygiene_sha,
        "toolchain_provenance_path": (
            osrs_release_relative_path(toolchain_path, output)
            if toolchain_path is not None
            else None
        ),
        "toolchain_provenance_sha256": toolchain_sha,
        "realm_count": len(records),
        "native_non_surface_realm_count": sum(
            record["group"] == "realms" for record in records
        ),
        "wiki_other_map_count": sum(
            record["group"] == "other_maps" and record.get("map_id") is not None
            for record in records
        ),
        "cache_special_realm_count": sum(
            str(record["id"]).startswith("cache-special-region:") for record in records
        ),
        "source_accounting_cache_special_realm_count": len(special_records),
        "excluded_runtime_realm_count": len(excluded_runtime_records),
        "asset_count": sum(len(record.get("assets", [])) for record in records),
        "unresolved_content_bearing_residual_pixels": 0,
    }


def _osrs_load_plane_state(
    args: argparse.Namespace,
    plane: int,
    projection: osrsProjection,
    reports_dir: Path,
) -> dict[str, Any]:
    release_root = reports_dir.parent
    source_path = (args.provenance_dir / f"img-{plane}.png").resolve()
    provenance_path = (args.provenance_dir / f"img-{plane}-provenance.png").resolve()
    coverage_path = (args.provenance_dir / f"img-{plane}-provenance-coverage.png").resolve()
    ledger_path = (args.provenance_dir / f"img-{plane}-provenance.json").resolve()
    reference_source = (args.source_image_dir / f"img-{plane}.png").resolve()
    for path in (source_path, provenance_path, coverage_path, ledger_path, reference_source):
        if not path.is_file():
            raise osrsPipelineError(f"missing rendered-floor provenance input: {path}")
    _osrs_verify_source_dimensions(source_path, projection)
    _osrs_verify_source_dimensions(reference_source, projection)
    if osrs_sha256_file(source_path) != osrs_sha256_file(reference_source):
        raise osrsPipelineError(
            f"provenance render floor {plane} does not exactly match the pinned source"
        )
    with Image.open(provenance_path) as image:
        if image.size != (projection.width, projection.height):
            raise osrsPipelineError(
                f"provenance raster floor {plane} has size {image.size}, expected "
                f"{projection.width}x{projection.height}"
            )
    ledger = _osrs_read_json(ledger_path)
    if not isinstance(ledger, Mapping):
        raise osrsPipelineError(f"provenance ledger must be an object: {ledger_path}")
    ledger_plane = ledger.get("image", {}).get("rendered_plane")
    if ledger_plane != plane:
        raise osrsPipelineError(
            f"provenance ledger {ledger_path} declares rendered plane {ledger_plane}"
        )
    coverage_image = ledger.get("coverage_image")
    if not isinstance(coverage_image, Mapping):
        raise osrsPipelineError(f"provenance ledger {ledger_path} lacks coverage_image")
    if (
        coverage_image.get("path") != coverage_path.name
        or coverage_image.get("width") != projection.width
        or coverage_image.get("height") != projection.height
        or coverage_image.get("rendered_plane") != plane
    ):
        raise osrsPipelineError(
            f"provenance ledger {ledger_path} coverage_image does not match coverage raster"
        )

    streaming_path = reports_dir / f"source-accounting-plane-{plane}-streaming.json"
    execution_command = [
        str(args.accounting_helper.resolve()),
        "--source",
        str(source_path),
        "--owners",
        str(provenance_path),
        "--output",
        osrs_release_relative_path(streaming_path, release_root),
        "--require-zero",
    ]
    completed = subprocess.run(
        execution_command,
        cwd=release_root,
        capture_output=True,
        text=True,
        check=False,
    )
    command_report = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "rendered_plane": plane,
        "path_resolution": "release_root_working_directory",
        "command": [
            "tool://osrs-source-accounting",
            "--source",
            f"input://renderer-provenance/plane-{plane}/source-rgb.png",
            "--owners",
            f"input://renderer-provenance/plane-{plane}/owner-codes.png",
            "--output",
            osrs_release_relative_path(streaming_path, release_root),
            "--require-zero",
        ],
        "execution_command_disposition": "private_build_log_only",
        "return_code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }
    _osrs_assert_public_json(
        command_report, f"reports/source-accounting-plane-{plane}-command.json"
    )
    osrs_write_json(
        reports_dir / f"source-accounting-plane-{plane}-command.json",
        command_report,
    )
    if completed.returncode != 0:
        raise osrsPipelineError(
            f"streaming source accounting failed for floor {plane}: "
            f"{completed.stderr.strip()}"
        )
    streaming = _osrs_read_json(streaming_path)
    if not isinstance(streaming, Mapping):
        raise osrsPipelineError(f"streaming accounting is not an object: {streaming_path}")
    if streaming.get("checks", {}).get("release_ready") is not True:
        raise osrsPipelineError(f"floor {plane} streaming accounting is not release-ready")
    components = osrs_parse_provenance_components(ledger, streaming)
    return {
        "rendered_plane": plane,
        "source_path": source_path,
        "reference_source_path": reference_source,
        "provenance_path": provenance_path,
        "coverage_path": coverage_path,
        "ledger_path": ledger_path,
        "streaming_path": streaming_path,
        "ledger": ledger,
        "streaming": streaming,
        "components": components,
    }


def _osrs_plane_input_record(
    state: Mapping[str, Any], release_root: Path
) -> dict[str, Any]:
    return {
        "rendered_plane": int(state["rendered_plane"]),
        "source_path": (
            f"input://renderer-provenance/plane-{int(state['rendered_plane'])}/"
            "source-rgb.png"
        ),
        "source_sha256": osrs_sha256_file(state["source_path"]),
        "provenance_path": (
            f"input://renderer-provenance/plane-{int(state['rendered_plane'])}/"
            "owner-codes.png"
        ),
        "provenance_sha256": osrs_sha256_file(state["provenance_path"]),
        "coverage_path": (
            f"input://renderer-provenance/plane-{int(state['rendered_plane'])}/"
            "actual-write-coverage.png"
        ),
        "coverage_sha256": osrs_sha256_file(state["coverage_path"]),
        "ledger_path": (
            f"input://renderer-provenance/plane-{int(state['rendered_plane'])}/"
            "owner-ledger.json"
        ),
        "ledger_sha256": osrs_sha256_file(state["ledger_path"]),
        "streaming_accounting_path": osrs_release_relative_path(
            state["streaming_path"], release_root
        ),
        "streaming_accounting_sha256": osrs_sha256_file(state["streaming_path"]),
    }


def _osrs_apply_provenance_geometry(
    records: Sequence[dict[str, Any]],
    components_by_plane: Mapping[int, Sequence[osrsProvenanceComponent]],
    definitions: Sequence[Mapping[str, Any]],
    special_region_index: Mapping[int, str],
) -> None:
    native_ids = {
        int(definition["file_id"]): osrs_stable_native_realm_id(definition)
        for definition in definitions
    }
    by_realm: dict[str, list[osrsProvenanceComponent]] = {}
    for plane, components in sorted(components_by_plane.items()):
        for component in components:
            if component.rendered_plane != plane:
                raise osrsPipelineError("component/rendered-plane mismatch")
            if component.kind == "native_composite":
                if component.realm_file_id not in native_ids:
                    raise osrsPipelineError(
                        f"unknown native file ID {component.realm_file_id}"
                    )
                realm_id = native_ids[int(component.realm_file_id)]
            elif component.kind == "cache_loaded_special_region":
                if component.source_region_id is None:
                    raise osrsPipelineError("special component has no source region")
                realm_id = special_region_index.get(component.source_region_id)
                if realm_id is None:
                    raise osrsPipelineError(
                        f"special region {component.source_region_id} is not indexed"
                    )
            else:
                raise osrsPipelineError(f"unknown provenance kind {component.kind}")
            by_realm.setdefault(realm_id, []).append(component)

    for record in records:
        realm_id = str(record["id"])
        components = sorted(
            by_realm.get(realm_id, []),
            key=lambda value: (value.rendered_plane, value.code),
        )
        if not components:
            continue
        by_plane: dict[str, dict[str, Any]] = {}
        component_rows: list[dict[str, Any]] = []
        for plane in sorted({value.rendered_plane for value in components}):
            values = [value for value in components if value.rendered_plane == plane]
            by_plane[str(plane)] = {
                "codes": [value.code for value in values],
                "source_pixel_bounds": [
                    value.source_pixel_bounds.to_json() for value in values
                ],
                "display_pixel_bounds": [
                    value.display_pixel_bounds.to_json() for value in values
                ],
            }
            component_rows.extend(
                {
                    "component_index": index,
                    "rendered_plane": value.rendered_plane,
                    "source_plane": value.source_plane,
                    "provenance_code": value.code,
                    "source_pixel_bounds": value.source_pixel_bounds.to_json(),
                    "display_pixel_bounds": value.display_pixel_bounds.to_json(),
                    "source_to_display_dx_pixels": value.dx,
                    "source_to_display_dy_pixels": value.dy,
                    "pixel_count": value.pixel_count,
                    "content_bearing_pixel_count": value.content_bearing_pixel_count,
                }
                for index, value in enumerate(values, start=len(component_rows))
            )
        source_mask = {
            "type": "renderer_provenance_code_union",
            "coordinate_space": "source_pixels",
            "by_rendered_plane": by_plane,
        }
        source_mask["sha256"] = _osrs_json_sha(source_mask)
        display_mask = {
            "type": "renderer_provenance_code_union",
            "coordinate_space": "realm_local_display_pixels",
            "by_rendered_plane": by_plane,
        }
        display_mask["sha256"] = _osrs_json_sha(display_mask)
        record["source_mask"] = source_mask
        record["display_mask"] = display_mask
        record["components"] = component_rows
        plane_zero_pixels = sum(
            value.pixel_count for value in components if value.rendered_plane == 0
        )
        record["accounting_owner_realm_id"] = realm_id if plane_zero_pixels else None
        record["accounting_pixel_count"] = plane_zero_pixels

    for record in records:
        if "accounting_pixel_count" not in record:
            record["accounting_pixel_count"] = 0


def _osrs_load_coverage_mask(path: Path, projection: osrsProjection) -> np.ndarray:
    if not path.is_file():
        raise osrsPipelineError(f"missing actual-write coverage raster: {path}")
    with Image.open(path) as image:
        if image.size != (projection.width, projection.height):
            raise osrsPipelineError(
                f"coverage raster {path} has size {image.size}, expected "
                f"{projection.width}x{projection.height}"
            )
        if image.mode == "1":
            return np.asarray(image, dtype=np.bool_)
        if len(image.getbands()) != 1:
            raise osrsPipelineError(f"coverage raster must have one channel: {path}")
        values = np.asarray(image)
    if values.ndim != 2:
        raise osrsPipelineError(f"coverage raster must be two-dimensional: {path}")
    unique_values = set(int(value) for value in np.unique(values))
    if not unique_values.issubset({0, 255}):
        raise osrsPipelineError(
            f"coverage raster must be binary 0/255 values, got {sorted(unique_values)[:8]}"
        )
    return values != 0


def _osrs_validate_coverage_against_owner_and_ledger(
    coverage: np.ndarray,
    owner_codes: np.ndarray,
    ledger: Mapping[str, Any],
    plane: int,
) -> None:
    owners = np.asarray(owner_codes)
    if coverage.shape != owners.shape or coverage.dtype != np.bool_:
        raise osrsPipelineError(f"coverage raster floor {plane} does not match owner raster")
    if owners.dtype.kind not in {"u", "i"}:
        raise osrsPipelineError(f"owner raster floor {plane} is not an integer raster")
    if np.any(coverage & (owners == 0)):
        raise osrsPipelineError(f"coverage raster floor {plane} has writes without final owners")
    coverage_encoding = ledger.get("coverage_encoding")
    if not isinstance(coverage_encoding, Mapping):
        raise osrsPipelineError(f"provenance ledger floor {plane} lacks coverage_encoding")
    if (
        coverage_encoding.get("sample_type") != "binary"
        or coverage_encoding.get("zero_code") != 0
        or coverage_encoding.get("write_code") != 1
        or coverage_encoding.get("nonzero_semantics") != "actual_renderer_write"
    ):
        raise osrsPipelineError(f"provenance ledger floor {plane} coverage encoding is invalid")
    statistics = ledger.get("statistics")
    if not isinstance(statistics, Mapping):
        raise osrsPipelineError(f"provenance ledger floor {plane} lacks statistics")
    expected_coverage = statistics.get("actual_covered_pixel_count")
    actual_writes = statistics.get("actual_write_count")
    if not isinstance(expected_coverage, int) or isinstance(expected_coverage, bool):
        raise osrsPipelineError(f"provenance ledger floor {plane} lacks covered-pixel count")
    if not isinstance(actual_writes, int) or isinstance(actual_writes, bool):
        raise osrsPipelineError(f"provenance ledger floor {plane} lacks actual write count")
    observed_coverage = int(np.count_nonzero(coverage))
    if observed_coverage != expected_coverage:
        raise osrsPipelineError(
            f"coverage raster floor {plane} count {observed_coverage} does not match "
            f"ledger {expected_coverage}"
        )
    if observed_coverage > actual_writes:
        raise osrsPipelineError(f"coverage raster floor {plane} has more pixels than writes")


def _osrs_asset_validation(
    records: Sequence[Mapping[str, Any]],
    accounting: Mapping[str, Any],
    components_by_plane: Mapping[int, Sequence[osrsProvenanceComponent]],
) -> dict[str, Any]:
    owner_assets = [
        asset
        for record in records
        if record.get("accounting_owner_realm_id") == record.get("id")
        for asset in record.get("assets", [])
        if asset.get("plane") == 0
    ]
    owner_source_pixels = sum(
        int(record.get("accounting_pixel_count", 0))
        for record in records
        if record.get("accounting_owner_realm_id") == record.get("id")
    )
    expected = sum(
        int(accounting["categories"][key])
        for key in (
            "true_surface",
            "named_non_surface_realm",
            "known_special_or_custom_area",
        )
    )
    assigned_asset_pixels = sum(int(asset["assigned_pixel_count"]) for asset in owner_assets)
    ownership_asset_pixels = sum(
        int(asset.get("ownership_pixel_count", asset["assigned_pixel_count"]))
        for asset in owner_assets
    )
    all_assets = [asset for record in records for asset in record.get("assets", [])]
    total_display_pixels = sum(int(asset["display_pixel_count"]) for asset in all_assets)
    total_ownership_pixels = sum(
        int(asset.get("ownership_pixel_count", asset["assigned_pixel_count"]))
        for asset in all_assets
    )
    total_transparent_owned_pixels = sum(
        int(asset.get("transparent_owned_pixel_count", 0)) for asset in all_assets
    )
    total_visible_exact_black_pixels = sum(
        int(asset.get("visible_exact_black_pixel_count", 0)) for asset in all_assets
    )
    all_asset_masks_consistent = all(
        int(asset.get("ownership_pixel_count", asset["assigned_pixel_count"]))
        >= int(asset["display_pixel_count"])
        and int(asset.get("transparent_owned_pixel_count", 0))
        == int(asset.get("ownership_pixel_count", asset["assigned_pixel_count"]))
        - int(asset["display_pixel_count"])
        for asset in all_assets
    )
    floor_zero_display_uses_complete_ownership = all(
        int(asset["display_pixel_count"])
        == int(asset.get("ownership_pixel_count", asset["assigned_pixel_count"]))
        for asset in all_assets
        if int(asset.get("plane", -1)) == 0
    )
    special_region_ownership = osrs_special_region_accounting_report(
        records,
        components_by_plane,
        int(accounting["categories"]["known_special_or_custom_area"]),
    )
    special_region_ready = all(special_region_ownership["checks"].values())
    result = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "accounting_owner_realm_count": sum(
            record.get("accounting_owner_realm_id") == record.get("id")
            for record in records
        ),
        "floor_zero_owner_asset_count": len(owner_assets),
        "expected_owned_source_pixels": expected,
        "manifest_accounting_owner_pixels": owner_source_pixels,
        "floor_zero_owner_asset_assigned_pixels": assigned_asset_pixels,
        "floor_zero_owner_asset_ownership_pixels": ownership_asset_pixels,
        "total_asset_ownership_pixels": total_ownership_pixels,
        "total_asset_display_pixels": total_display_pixels,
        "total_transparent_owned_pixels": total_transparent_owned_pixels,
        "total_visible_exact_black_pixels": total_visible_exact_black_pixels,
        "all_assets_nonblank": all(
            asset.get("nonblank") is True
            for record in records
            for asset in record.get("assets", [])
        ),
        "selector_realm_bijection": True,
        "exact_source_rgb_preserved_without_resampling": True,
        "cache_special_region_ownership": special_region_ownership,
        "checks": {
            "manifest_owner_sum_matches_source_accounting": owner_source_pixels == expected,
            "asset_pixel_sum_matches_source_accounting": (
                assigned_asset_pixels == expected
                and ownership_asset_pixels == expected
            ),
            "asset_ownership_display_counts_consistent": all_asset_masks_consistent,
            "floor_zero_display_uses_complete_ownership": (
                floor_zero_display_uses_complete_ownership
            ),
            "special_region_ownership_exact_and_unmerged": special_region_ready,
            "release_ready": (
                owner_source_pixels == expected
                and assigned_asset_pixels == expected
                and ownership_asset_pixels == expected
                and all_asset_masks_consistent
                and floor_zero_display_uses_complete_ownership
                and special_region_ready
            ),
        },
    }
    if not result["checks"]["release_ready"]:
        raise osrsPipelineError(
            "realm asset pixel conservation failed: "
            f"manifest={owner_source_pixels}, assets={assigned_asset_pixels}, expected={expected}"
        )
    return result


def _osrs_iter_release_rendered_assets(
    *,
    plane_states: Mapping[int, Mapping[str, Any]],
    projection: osrsProjection,
    definitions: Sequence[Mapping[str, Any]],
    special_region_index: Mapping[str, Any],
    records: Sequence[Mapping[str, Any]],
    records_by_id: Mapping[str, Mapping[str, Any]],
    wiki_by_id: Mapping[int, Mapping[str, Any]],
    prior_asset_planes: Mapping[str, set[int]],
):
    """Yield the deterministic release assets for both geometry and write passes."""

    for plane, state in sorted(plane_states.items()):
        with (
            Image.open(state["source_path"]) as source_image,
            Image.open(state["provenance_path"]) as owner_image,
        ):
            source_rgb = np.asarray(source_image)
            owner_codes = np.asarray(owner_image)
            coverage_mask = _osrs_load_coverage_mask(
                state["coverage_path"], projection
            )
            _osrs_validate_coverage_against_owner_and_ledger(
                coverage_mask, owner_codes, state["ledger"], plane
            )
            for realm_id, rendered in osrs_iter_rendered_provenance_realms(
                source_rgb,
                owner_codes,
                projection,
                state["components"],
                definitions,
                special_region_index,
                coverage_mask=coverage_mask,
            ):
                if not _osrs_rendered_has_content(rendered):
                    continue
                if not _osrs_prior_allows_asset_plane(
                    prior_asset_planes, realm_id, plane
                ):
                    continue
                record = records_by_id.get(realm_id)
                if record is None:
                    raise osrsPipelineError(
                        f"provenance produced unpublished realm {realm_id}"
                    )
                yield realm_id, record, rendered

            for record in records:
                map_id = record.get("map_id")
                if (
                    record["group"] != "other_maps"
                    or map_id is None
                    or int(map_id) < 10000
                ):
                    continue
                wiki = wiki_by_id[int(map_id)]
                rendered = osrs_render_wiki_view(
                    source_rgb,
                    projection,
                    _osrs_wiki_bounds(wiki),
                    plane=plane,
                    coverage_mask=coverage_mask,
                )
                if not _osrs_rendered_has_content(rendered):
                    continue
                realm_id = str(record["id"])
                if not _osrs_prior_allows_asset_plane(
                    prior_asset_planes, realm_id, plane
                ):
                    continue
                yield realm_id, record, rendered


def _osrs_write_rendered_asset(
    rendered: Any,
    record: Mapping[str, Any],
    assets_dir: Path,
    masks_dir: Path,
    release_root: Path,
    *,
    canvas_layout: Mapping[str, int],
) -> dict[str, Any]:
    stem = osrs_asset_stem(str(record["id"]))
    plane = int(rendered.plane)
    realm_asset_dir = assets_dir / stem
    realm_mask_dir = masks_dir / stem
    mbtiles_path = realm_asset_dir / f"plane-{plane}.mbtiles"
    mask_path = realm_mask_dir / f"plane-{plane}.png"
    ownership_mask_path = realm_mask_dir / f"plane-{plane}-ownership.png"
    display_mask = np.asarray(rendered.mask)
    ownership_mask = (
        np.asarray(rendered.ownership_mask)
        if getattr(rendered, "ownership_mask", None) is not None
        else display_mask
    )
    if display_mask.shape != ownership_mask.shape:
        raise osrsPipelineError(
            f"asset mask dimensions disagree for {record['id']} floor {plane}"
        )
    if display_mask.dtype != np.bool_ or ownership_mask.dtype != np.bool_:
        raise osrsPipelineError(
            f"asset masks must be boolean for {record['id']} floor {plane}"
        )
    if np.any(display_mask & ~ownership_mask):
        raise osrsPipelineError(
            f"display mask exceeds ownership mask for {record['id']} floor {plane}"
        )
    mbtiles = osrs_write_mbtiles(
        rendered.rgba,
        mbtiles_path,
        f"{record['canonical_name']} - Floor {plane}",
        canvas_size=int(canvas_layout["canvas_size"]),
        canvas_origin=(
            int(canvas_layout["origin_x"]),
            int(canvas_layout["origin_y"]),
        ),
        release_root=release_root,
    )
    osrs_assert_mbtiles_alpha_matches_mask(mbtiles_path, display_mask, mbtiles)
    mask_sha = osrs_save_mask_png(display_mask, mask_path)
    ownership_mask_sha = osrs_save_mask_png(ownership_mask, ownership_mask_path)
    display_pixels = int(np.count_nonzero(display_mask))
    ownership_pixels = int(np.count_nonzero(ownership_mask))
    transparent_owned_pixels = ownership_pixels - display_pixels
    assigned = int(rendered.assigned_source_pixel_count)
    collision_count = int(rendered.identical_rgb_display_collision_count)
    if assigned != ownership_pixels + collision_count:
        raise osrsPipelineError(
            f"asset source/ownership accounting mismatch for {record['id']} floor {plane}: "
            f"assigned={assigned}, ownership={ownership_pixels}, collisions={collision_count}"
        )
    if transparent_owned_pixels < 0:
        raise osrsPipelineError(
            f"asset has more display pixels than owned pixels for {record['id']} floor {plane}"
        )
    if plane == 0 and transparent_owned_pixels != 0:
        raise osrsPipelineError(
            f"floor 0 display alpha must match ownership for {record['id']}"
        )
    content = int(
        np.count_nonzero(
            display_mask & np.any(rendered.rgba[..., :3] != 0, axis=2)
        )
    )
    visible_black = int(
        np.count_nonzero(display_mask & np.all(rendered.rgba[..., :3] == 0, axis=2))
    )
    return {
        "plane": plane,
        "mbtiles_path": osrs_release_relative_path(mbtiles_path, release_root),
        "mbtiles_sha256": mbtiles["sha256"],
        "mbtiles_bytes": mbtiles["bytes"],
        "mask_path": osrs_release_relative_path(mask_path, release_root),
        "mask_sha256": mask_sha,
        "ownership_mask_path": osrs_release_relative_path(
            ownership_mask_path, release_root
        ),
        "ownership_mask_sha256": ownership_mask_sha,
        "width": int(rendered.rgba.shape[1]),
        "height": int(rendered.rgba.shape[0]),
        "assigned_pixel_count": assigned,
        "ownership_pixel_count": ownership_pixels,
        "display_pixel_count": display_pixels,
        "transparent_owned_pixel_count": transparent_owned_pixels,
        "visible_exact_black_pixel_count": visible_black,
        "identical_rgb_display_collision_count": collision_count,
        "layout_components": _osrs_shift_layout_components(
            rendered.layout_components,
            dx=int(canvas_layout["origin_x"]),
            dy=int(canvas_layout["origin_y"]),
        ),
        "content_bearing_pixel_count": content,
        "nonblank": display_pixels > 0,
        "tile_size": mbtiles["tile_size"],
        "min_zoom": mbtiles["min_zoom"],
        "max_zoom": mbtiles["max_zoom"],
        "tile_count": mbtiles["tile_count"],
        "sqlite_version_number": mbtiles["sqlite_version_number"],
        "canvas_size": mbtiles["canvas_size"],
        "canvas_origin": mbtiles["canvas_origin"],
        "content_pixel_bounds": mbtiles["content_pixel_bounds"],
        "content_latlon_bounds": mbtiles["content_latlon_bounds"],
        "source_bounds": [rect.to_json() for rect in rendered.source_bounds],
        "display_bounds": rendered.display_bounds.to_json(),
    }


def _osrs_shift_layout_components(
    components: Sequence[Mapping[str, Any]],
    *,
    dx: int,
    dy: int,
) -> list[dict[str, Any]]:
    """Translate one realm's source-to-display accounting into its shared canvas."""

    shifted: list[dict[str, Any]] = []
    for component in components:
        row = dict(component)
        bounds = component.get("asset_pixel_bounds")
        if not isinstance(bounds, Mapping):
            raise osrsPipelineError("layout component lacks asset pixel bounds")
        row["asset_pixel_bounds"] = {
            "min_x": int(bounds["min_x"]) + dx,
            "min_y": int(bounds["min_y"]) + dy,
            "max_x": int(bounds["max_x"]) + dx,
            "max_y": int(bounds["max_y"]) + dy,
        }
        row["source_to_display_dx_pixels"] = (
            int(component.get("source_to_display_dx_pixels", 0)) + dx
        )
        row["source_to_display_dy_pixels"] = (
            int(component.get("source_to_display_dy_pixels", 0)) + dy
        )
        shifted.append(row)
    return shifted


def _osrs_verify_source_dimensions(path: Path, projection: osrsProjection) -> None:
    if not path.is_file():
        raise osrsPipelineError(f"missing source raster: {path}")
    with Image.open(path) as image:
        if image.mode != "RGB" or image.size != (projection.width, projection.height):
            raise osrsPipelineError(
                f"unexpected source raster {path}: mode={image.mode}, size={image.size}"
            )


def _osrs_rendered_has_content(rendered: Any) -> bool:
    return bool(np.any(rendered.mask))


def _osrs_wiki_bounds(value: Mapping[str, Any]) -> osrsRect:
    bounds = value.get("bounds")
    if (
        not isinstance(bounds, list)
        or len(bounds) != 2
        or not all(isinstance(point, list) and len(point) == 2 for point in bounds)
    ):
        raise osrsPipelineError(f"mapID {value.get('mapId')} has invalid bounds")
    return osrsRect(
        int(bounds[0][0]), int(bounds[0][1]), int(bounds[1][0]), int(bounds[1][1])
    )


def _osrs_json_sha(value: Any) -> str:
    import hashlib

    return hashlib.sha256(osrs_canonical_json_bytes(value)).hexdigest()


def _osrs_assert_public_json(value: Any, artifact: str) -> None:
    try:
        osrs_assert_public_json_portable(value, artifact)
    except osrsPublicPathError as error:
        raise osrsPipelineError(f"public artifact path hygiene failed: {error}") from error


def _osrs_write_path_hygiene_report(output: Path) -> tuple[Path, str]:
    report_path = output / "reports" / "public-path-hygiene.json"
    placeholder = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "scope": "public_release_json_tree",
        "status": "VALIDATION_PENDING",
    }
    _osrs_assert_public_json(placeholder, "reports/public-path-hygiene.json")
    osrs_write_json(report_path, placeholder)
    try:
        report = osrs_validate_public_release_tree(output)
    except osrsPublicPathError as error:
        raise osrsPipelineError(f"public release path hygiene failed: {error}") from error
    report["checks"]["report_self_validation_passed"] = True
    report_sha = osrs_write_json(report_path, report)
    try:
        verified = osrs_validate_public_release_tree(output)
    except osrsPublicPathError as error:
        raise osrsPipelineError(
            f"public path-hygiene report self-validation failed: {error}"
        ) from error
    if (
        verified["scanned_artifact_count"] != report["scanned_artifact_count"]
        or verified["scanned_artifact_names_sha256"]
        != report["scanned_artifact_names_sha256"]
        or verified["json_artifact_count"] != report["json_artifact_count"]
        or verified["non_json_artifact_count"] != report["non_json_artifact_count"]
        or verified["printable_string_count"] != report["printable_string_count"]
    ):
        raise osrsPipelineError(
            "public JSON artifact set changed while writing the path-hygiene report"
        )
    return report_path, report_sha


def _osrs_mapping(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise osrsPipelineError(f"{field} must be an object")
    return value


def _osrs_prior_asset_planes_by_realm(
    prior: Mapping[str, Any] | None,
) -> dict[str, set[int]] | None:
    if prior is None:
        return None
    realms = prior.get("realms")
    if not isinstance(realms, list):
        raise osrsPipelineError("prior manifest realms[] must be an array")
    result: dict[str, set[int]] = {}
    for index, value in enumerate(realms):
        realm = _osrs_mapping(value, f"prior.realms[{index}]")
        realm_id = str(realm.get("id", "")).strip()
        if not realm_id:
            raise osrsPipelineError(f"prior.realms[{index}].id is required")
        assets = realm.get("assets")
        if not isinstance(assets, list):
            raise osrsPipelineError(f"prior realm {realm_id} assets[] must be an array")
        planes: set[int] = set()
        for asset_index, asset_value in enumerate(assets):
            asset = _osrs_mapping(
                asset_value, f"prior realm {realm_id} assets[{asset_index}]"
            )
            plane = asset.get("plane")
            if not isinstance(plane, int) or plane < 0 or plane > 3:
                raise osrsPipelineError(
                    f"prior realm {realm_id} asset plane is malformed"
                )
            if plane in planes:
                raise osrsPipelineError(
                    f"prior realm {realm_id} declares duplicate plane {plane}"
                )
            planes.add(plane)
        result[realm_id] = planes
    return result


def _osrs_prior_allows_asset_plane(
    prior_asset_planes: dict[str, set[int]] | None,
    realm_id: str,
    plane: int,
) -> bool:
    if prior_asset_planes is None:
        return True
    planes = prior_asset_planes.get(str(realm_id))
    return planes is not None and plane in planes


def _osrs_read_json(path: Path | None) -> Any:
    if path is None:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise osrsPipelineError(f"cannot read JSON {path}: {error}") from error


def _osrs_parse_planes(value: str) -> tuple[int, ...]:
    try:
        planes = tuple(sorted({int(item) for item in value.split(",")}))
    except ValueError as error:
        raise argparse.ArgumentTypeError("planes must be comma-separated integers") from error
    if not planes or any(plane < 0 or plane > 3 for plane in planes):
        raise argparse.ArgumentTypeError("planes must be a nonempty subset of 0,1,2,3")
    return planes


def _osrs_parse_sha256(value: str) -> str:
    normalized = value.strip().lower()
    if len(normalized) != 64 or any(
        character not in "0123456789abcdef" for character in normalized
    ):
        raise argparse.ArgumentTypeError("value must be a lowercase SHA-256 digest")
    return normalized


def _osrs_parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--basemaps", required=True, type=Path)
    parser.add_argument("--alignment", required=True, type=Path)
    parser.add_argument("--source-metadata", required=True, type=Path)
    parser.add_argument("--source-image-dir", required=True, type=Path)
    parser.add_argument("--provenance-dir", required=True, type=Path)
    parser.add_argument("--accounting-helper", required=True, type=Path)
    parser.add_argument(
        "--accounting-helper-sha256", required=True, type=_osrs_parse_sha256
    )
    parser.add_argument("--source-snapshots", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--candidate",
        default="001",
        choices=[f"{value:03d}" for value in range(1, 1000)],
    )
    parser.add_argument("--planes", type=_osrs_parse_planes, default=(0, 1, 2, 3))
    parser.add_argument("--prior-manifest", type=Path)
    parser.add_argument("--accounting-only", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _osrs_parse_args(sys.argv[1:] if argv is None else argv)
    toolchain_provenance, invocation_provenance = (
        osrs_collect_locked_release_toolchain()
    )
    osrs_write_invocation_report(invocation_provenance)
    observed_helper_sha = osrs_sha256_file(args.accounting_helper)
    if observed_helper_sha != args.accounting_helper_sha256:
        raise osrsPipelineError(
            "accounting helper hash does not match the content-addressed input"
        )
    result = osrs_build_release(args, toolchain_provenance=toolchain_provenance)
    final_toolchain, final_invocation = osrs_collect_locked_release_toolchain()
    if osrs_canonical_json_bytes(final_toolchain) != osrs_canonical_json_bytes(
        toolchain_provenance
    ):
        raise osrsPipelineError("release toolchain changed during generation")
    final_invocation["public_toolchain_report_sha256"] = result[
        "toolchain_provenance_sha256"
    ]
    final_invocation["checks"][
        "retained_public_toolchain_report_hash_recorded"
    ] = True
    osrs_write_invocation_report(final_invocation)
    print(osrs_canonical_json_bytes(result).decode("utf-8"), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (osrsPipelineError, osrsToolchainError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
