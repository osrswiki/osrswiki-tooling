#!/usr/bin/env python3
"""Derive the 50-realm runtime publication from a fully accounted canonical release.

The upstream release intentionally accounts for every cache-owned special region and every pinned
Wiki-authored view. The product contract is narrower: one surface plus the 49 named native cache
world maps. This transformation preserves the broad accounting reports while copying only the
canonical manifest records, MBTiles, and masks into a fresh output tree.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any, Mapping

from jsonschema import Draft202012Validator

from build_osrs_non_surface_realms import (
    _osrs_assert_public_json,
    _osrs_write_path_hygiene_report,
)
from osrs_non_surface_assets import (
    osrs_boundary_provenance_report,
    osrs_manifest_schema,
    osrs_release_relative_path,
    osrs_sha256_file,
    osrs_validate_manifest,
)
from osrs_non_surface_realms import (
    OSRS_SCHEMA_VERSION,
    osrs_release_diff,
    osrs_write_json,
    osrsPipelineError,
)


OSRS_RUNTIME_GROUPS = frozenset({"surface", "realms"})


def osrs_prune_canonical_runtime_release(
    source: Path,
    output: Path,
) -> dict[str, Any]:
    source = source.resolve()
    output = output.resolve()
    if source == output or source in output.parents:
        raise osrsPipelineError("runtime output must be a distinct sibling tree")
    if not (source / "underground-realms.json").is_file():
        raise osrsPipelineError("source release has no underground-realms.json")
    if output.exists() and any(output.iterdir()):
        raise osrsPipelineError("runtime output must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    (output / "assets").mkdir()
    (output / "masks").mkdir()
    (output / "manifests").mkdir()
    (output / "reports").mkdir()

    full_manifest = _osrs_read_json(source / "underground-realms.json")
    full_records = full_manifest.get("realms")
    if not isinstance(full_records, list) or not full_records:
        raise osrsPipelineError("source manifest has no realms")
    published = [
        record for record in full_records if str(record.get("group")) in OSRS_RUNTIME_GROUPS
    ]
    excluded = [
        record for record in full_records if str(record.get("group")) not in OSRS_RUNTIME_GROUPS
    ]
    if len(published) != 50:
        raise osrsPipelineError(
            f"expected one surface plus 49 named native realms, got {len(published)}"
        )
    if sum(record.get("group") == "surface" for record in published) != 1:
        raise osrsPipelineError("runtime publication must contain exactly one surface")

    copied_asset_count = 0
    for record in published:
        for asset in record.get("assets", []):
            for path_key, hash_key in (
                ("mbtiles_path", "mbtiles_sha256"),
                ("mask_path", "mask_sha256"),
                ("ownership_mask_path", "ownership_mask_sha256"),
            ):
                relative = Path(str(asset[path_key]))
                _osrs_copy_hashed_file(
                    source / relative,
                    output / relative,
                    str(asset[hash_key]),
                )
            copied_asset_count += 1

    overwritten_reports = {
        "boundary-provenance.json",
        "public-path-hygiene.json",
        "runtime-publication-policy.json",
        "wiki-view-publication.json",
    }
    for path in sorted((source / "reports").glob("*")):
        if path.is_file() and path.name not in overwritten_reports:
            destination = output / "reports" / path.name
            shutil.copy2(path, destination)

    runtime_policy = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "policy": "surface-plus-named-native-cache-realms-only",
        "published_groups": sorted(OSRS_RUNTIME_GROUPS),
        "published_realm_count": len(published),
        "published_asset_count": copied_asset_count,
        "excluded_realm_count": len(excluded),
        "excluded_group_counts": {
            group: sum(str(record.get("group")) == group for record in excluded)
            for group in sorted({str(record.get("group")) for record in excluded})
        },
        "excluded_records": [
            {
                "id": str(record["id"]),
                "canonical_name": str(record["canonical_name"]),
                "group": str(record["group"]),
                "map_id": record.get("map_id"),
                "asset_sha256": [
                    str(asset["mbtiles_sha256"])
                    for asset in sorted(
                        record.get("assets", []),
                        key=lambda value: int(value["plane"]),
                    )
                ],
            }
            for record in excluded
        ],
        "checks": {
            "source_release_accounting_ready": bool(
                full_manifest.get("accounting", {}).get("checks", {}).get("release_ready")
            ),
            "runtime_contains_only_canonical_groups": all(
                record.get("group") in OSRS_RUNTIME_GROUPS for record in published
            ),
            "runtime_realm_count_is_50": len(published) == 50,
            "all_published_assets_copied_and_hash_verified": True,
        },
    }
    _osrs_assert_public_json(runtime_policy, "reports/runtime-publication-policy.json")
    runtime_policy_path = output / "reports" / "runtime-publication-policy.json"
    runtime_policy_sha = osrs_write_json(runtime_policy_path, runtime_policy)

    prior_wiki_report = _osrs_read_json(source / "reports" / "wiki-view-publication.json")
    wiki_report = {
        "schema_version": OSRS_SCHEMA_VERSION,
        "published_structured_wiki_view_count": 0,
        "excluded_blank_views": prior_wiki_report.get("excluded_blank_views", []),
        "excluded_noncanonical_view_count": sum(
            record.get("group") == "other_maps" and record.get("map_id") is not None
            for record in excluded
        ),
        "checks": {
            "all_published_views_nonblank": True,
            "no_wiki_authored_view_is_runtime_published": True,
        },
    }
    _osrs_assert_public_json(wiki_report, "reports/wiki-view-publication.json")
    osrs_write_json(output / "reports" / "wiki-view-publication.json", wiki_report)

    boundary = osrs_boundary_provenance_report(published, full_records)
    boundary_path = output / "reports" / "boundary-provenance.json"
    boundary_sha = osrs_write_json(boundary_path, boundary)

    manifest = dict(full_manifest)
    manifest["realms"] = published
    manifest["selector"] = {
        "entry_ids": [str(record["id"]) for record in published],
        "entry_count": len(published),
        "realm_count": len(published),
        "bijection": True,
    }
    inputs = dict(manifest.get("inputs", {}))
    inputs["boundary_provenance"] = {
        "path": osrs_release_relative_path(boundary_path, output),
        "sha256": boundary_sha,
        "policy": (
            "finite-content-envelope; four-sided-center-edge-overbound; "
            "horizontal-wrap-disabled"
        ),
    }
    inputs["runtime_publication_policy"] = {
        "path": osrs_release_relative_path(runtime_policy_path, output),
        "sha256": runtime_policy_sha,
        "policy": "surface-plus-named-native-cache-realms-only",
        "published_realm_count": len(published),
        "excluded_realm_count": len(excluded),
    }
    manifest["inputs"] = inputs
    _osrs_assert_public_json(manifest, "manifests/underground-realms.json")
    osrs_validate_manifest(manifest)
    schema = osrs_manifest_schema()
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(manifest)
    root_manifest_sha = osrs_write_json(output / "underground-realms.json", manifest)
    evidence_manifest_sha = osrs_write_json(
        output / "manifests" / "underground-realms.json",
        manifest,
    )
    if root_manifest_sha != evidence_manifest_sha:
        raise osrsPipelineError("root and evidence manifests differ")
    schema_sha = osrs_write_json(
        output / "manifests" / "underground-realms.schema.json",
        schema,
    )
    release_diff_sha = osrs_write_json(
        output / "manifests" / "release-diff.json",
        osrs_release_diff(full_manifest, published),
    )
    path_hygiene_path, path_hygiene_sha = _osrs_write_path_hygiene_report(output)

    actual_mbtiles = sorted((output / "assets").rglob("*.mbtiles"))
    actual_masks = sorted((output / "masks").rglob("*.png"))
    if len(actual_mbtiles) != copied_asset_count or len(actual_masks) != copied_asset_count * 2:
        raise osrsPipelineError("published asset/mask file counts do not match manifest")
    return {
        "status": "RUNTIME_PUBLICATION_READY",
        "manifest_sha256": root_manifest_sha,
        "schema_sha256": schema_sha,
        "release_diff_sha256": release_diff_sha,
        "boundary_provenance_sha256": boundary_sha,
        "runtime_publication_policy_sha256": runtime_policy_sha,
        "path_hygiene_path": osrs_release_relative_path(path_hygiene_path, output),
        "path_hygiene_sha256": path_hygiene_sha,
        "realm_count": len(published),
        "asset_count": copied_asset_count,
        "excluded_realm_count": len(excluded),
    }


def _osrs_copy_hashed_file(source: Path, output: Path, expected_sha256: str) -> None:
    if not source.is_file():
        raise osrsPipelineError(f"missing source release file: {source}")
    if osrs_sha256_file(source) != expected_sha256:
        raise osrsPipelineError(f"source release hash mismatch: {source}")
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, output)
    if osrs_sha256_file(output) != expected_sha256:
        raise osrsPipelineError(f"copied release hash mismatch: {output}")


def _osrs_read_json(path: Path) -> Mapping[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, Mapping):
        raise osrsPipelineError(f"expected JSON object: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(
        json.dumps(
            osrs_prune_canonical_runtime_release(args.source, args.output),
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
