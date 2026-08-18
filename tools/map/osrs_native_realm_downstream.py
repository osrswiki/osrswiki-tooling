#!/usr/bin/env python3
"""Deterministic downstream bridge for native OSRS realm capture coverage.

The release builder still materializes every preserved record.  This module is
the narrower production bridge for the in-game selector-visible inventory:
Gielinor Surface plus cache-native realms.  It deliberately excludes
``other_maps`` from capture worklists while retaining their source manifest
counts as compatibility evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import tempfile
import sys
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any, Mapping, MutableMapping, Sequence

import numpy as np
from PIL import Image

from osrs_non_surface_assets import osrs_asset_stem
from osrs_non_surface_realms import (
    osrs_canonical_json_bytes,
    osrs_sha256_bytes,
    osrs_write_json,
    osrsPipelineError,
)


OSRS_NATIVE_SELECTOR_PROFILE_SCHEMA_VERSION = 1
OSRS_NATIVE_SELECTOR_PROFILE_ID = "osrs-native-selector-production-v2"
OSRS_NATIVE_COVERAGE_SCHEMA_VERSION = 1
OSRS_NATIVE_COVERAGE_CONTRACT = "osrs-native-realm-production-coverage-v1"
OSRS_NATIVE_WORKLIST_SCHEMA_VERSION = 1
OSRS_NATIVE_WORKLIST_CONTRACT = "osrs-native-realm-production-worklist-v1"
OSRS_NATIVE_RELEASE_INPUT_SCHEMA_VERSION = 1
OSRS_NATIVE_RELEASE_INPUT_CONTRACT = "osrs-native-realm-release-inputs-v1"
OSRS_NATIVE_SANDBOX_COVERAGE_SCHEMA_VERSION = 1
OSRS_NATIVE_SANDBOX_COVERAGE_CONTRACT = "osrs-native-realm-sandbox-coverage-v1"
OSRS_NATIVE_SANDBOX_WORKLIST_SCHEMA_VERSION = 1
OSRS_NATIVE_SANDBOX_WORKLIST_CONTRACT = "osrs-native-realm-sandbox-worklist-v1"
OSRS_NATIVE_SCREENSHOT_TRANSFORM_SCHEMA_VERSION = 1
OSRS_NATIVE_SCREENSHOT_TRANSFORM_CONTRACT = "osrs-native-realm-screenshot-transform-v1"
OSRS_EXPECTED_NATIVE_PRODUCTION_COUNT = 47
OSRS_EXPECTED_OTHER_MAP_COUNT = 1047
OSRS_EXCLUDED_PRODUCER_ONLY_REALM_IDS = frozenset(
    {
        "cache-world-map:ghorrock-prison",
        "cache-world-map:lassar-undercity",
        "cache-world-map:tutorial-2",
    }
)
OSRS_CAPTURE_BROKER_PROTOCOL = "osrs-capture-broker-v4"
OSRS_SEMANTIC_CAPTURE_PROFILE = "semantic_map_capture_v1"
OSRS_REVIEWED_FRAME_WIDTH = 768
OSRS_REVIEWED_FRAME_HEIGHT = 839
OSRS_HISTORICAL_NATIVE_COVERAGE_CROP = {
    "left": 178,
    "top": 35,
    "width": 310,
    "height": 480,
}
OSRS_NATIVE_COVERAGE_ACTION_MARGIN = 6
OSRS_DEFAULT_ZOOM_PROFILE: tuple[dict[str, Any], ...] = (
    {"zoom_percent": 37.5, "criterion_family": "eastward_topology"},
    {"zoom_percent": 50, "criterion_family": "southward_topology"},
    {"zoom_percent": 75, "criterion_family": "westward_boundary"},
    {"zoom_percent": 100, "criterion_family": "northward_detail"},
    {"zoom_percent": 200, "criterion_family": "center_detail"},
)


@dataclass(frozen=True, order=True)
class osrsJournalIdentity:
    sequence: int
    commit_sha256: str

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any], field: str) -> "osrsJournalIdentity":
        sequence = _osrs_int(value.get("sequence"), f"{field}.sequence")
        commit_sha256 = str(value.get("commit_sha256", "")).strip()
        if sequence < 0 or not re.fullmatch(r"[a-f0-9]{64}", commit_sha256):
            raise osrsPipelineError(f"{field} is not a canonical journal identity")
        return cls(sequence=sequence, commit_sha256=commit_sha256)

    def to_json(self) -> dict[str, Any]:
        return {"sequence": self.sequence, "commit_sha256": self.commit_sha256}


@dataclass(frozen=True)
class osrsAcceptedCapture:
    source_path: str | None
    idempotency_key: str
    request_fingerprint: str | None
    predecessor: osrsJournalIdentity
    head: osrsJournalIdentity
    realm_id: str
    selector_name: str
    zoom_percent: int | float
    criterion_family: str
    map_crop: Mapping[str, Any] | None

    @property
    def work_key(self) -> tuple[str, str]:
        return (self.realm_id, osrs_zoom_key(self.zoom_percent))

    def to_capture_json(self) -> dict[str, Any]:
        return {
            "criterion_family": self.criterion_family,
            "head": self.head.to_json(),
            "idempotency_key": self.idempotency_key,
            "map_crop": dict(self.map_crop) if self.map_crop is not None else None,
            "predecessor": self.predecessor.to_json(),
            "realm_id": self.realm_id,
            "request_fingerprint": self.request_fingerprint,
            "selector_name": self.selector_name,
            "source_path": self.source_path,
            "work_key": {
                "realm_id": self.realm_id,
                "zoom_percent": self.zoom_percent,
            },
            "zoom_percent": self.zoom_percent,
        }


@dataclass(frozen=True)
class osrsSandboxCapture:
    source_path: str | None
    source_sha256: str | None
    source_bytes: int | None
    item_id: str
    item_sha256: str
    result_digest: str
    realm_id: str
    selector_name: str
    selector_index: int
    zoom_percent: int | float
    criterion_family: str
    capture_center: Mapping[str, Any]
    coverage_cell: Mapping[str, Any]
    map_crop: Mapping[str, Any]
    completed_at: str

    def to_capture_json(self) -> dict[str, Any]:
        return {
            "capture_center": dict(self.capture_center),
            "completed_at": self.completed_at,
            "coverage_cell": dict(self.coverage_cell),
            "criterion_family": self.criterion_family,
            "item_id": self.item_id,
            "item_sha256": self.item_sha256,
            "map_crop": dict(self.map_crop),
            "realm_id": self.realm_id,
            "result_digest": self.result_digest,
            "selector_index": self.selector_index,
            "selector_name": self.selector_name,
            "source_path": self.source_path,
            "source_sha256": self.source_sha256,
            "source_bytes": self.source_bytes,
            "zoom_percent": self.zoom_percent,
        }


def osrs_native_selector_profile(
    release_manifest: Mapping[str, Any],
    *,
    source_manifest_sha256: str | None = None,
    expected_native_count: int = OSRS_EXPECTED_NATIVE_PRODUCTION_COUNT,
    expected_other_map_count: int = OSRS_EXPECTED_OTHER_MAP_COUNT,
    zoom_profile: Sequence[Mapping[str, Any]] = OSRS_DEFAULT_ZOOM_PROFILE,
) -> dict[str, Any]:
    """Project exactly the selector-visible native production catalog.

    The input manifest is not mutated.  ``surface`` and ``realms`` are included
    because they are the current in-game selector groups; ``other_maps`` are
    retained only as excluded-count evidence.
    """

    realms = _osrs_release_realms(release_manifest)
    group_counts = {
        "surface": sum(1 for record in realms if record.get("group") == "surface"),
        "realms": sum(1 for record in realms if record.get("group") == "realms"),
        "other_maps": sum(1 for record in realms if record.get("group") == "other_maps"),
    }
    producer_native = [
        _osrs_mapping(record, "realms[]")
        for record in realms
        if record.get("group") in {"surface", "realms"}
    ]
    included = [
        record
        for record in producer_native
        if str(record.get("id")) not in OSRS_EXCLUDED_PRODUCER_ONLY_REALM_IDS
    ]
    excluded_producer_only = [
        record
        for record in producer_native
        if str(record.get("id")) in OSRS_EXCLUDED_PRODUCER_ONLY_REALM_IDS
    ]
    excluded_other_maps = [
        _osrs_mapping(record, "realms[]")
        for record in realms
        if record.get("group") == "other_maps"
    ]
    if group_counts["surface"] != 1:
        raise osrsPipelineError(
            f"native production profile requires exactly one surface, found {group_counts['surface']}"
        )
    if len(included) != expected_native_count:
        raise osrsPipelineError(
            "native production profile count mismatch: "
            f"expected {expected_native_count}, found {len(included)}"
        )
    if {
        str(record.get("id")) for record in excluded_producer_only
    } != OSRS_EXCLUDED_PRODUCER_ONLY_REALM_IDS:
        raise osrsPipelineError(
            "producer-only native exclusion mismatch: "
            f"expected {sorted(OSRS_EXCLUDED_PRODUCER_ONLY_REALM_IDS)}, "
            f"found {sorted(str(record.get('id')) for record in excluded_producer_only)}"
        )
    if len(excluded_other_maps) != expected_other_map_count:
        raise osrsPipelineError(
            "other_maps exclusion count mismatch: "
            f"expected {expected_other_map_count}, found {len(excluded_other_maps)}"
        )

    finalized_zooms = tuple(_osrs_normalize_zoom_row(row) for row in zoom_profile)
    entries: list[dict[str, Any]] = []
    label_keys: set[str] = set()
    for selector_index, record in enumerate(included):
        realm_id = _osrs_nonempty_str(record.get("id"), "realm.id")
        label = _osrs_nonempty_str(record.get("canonical_name"), f"{realm_id}.canonical_name")
        label_key = label.casefold()
        if label_key in label_keys:
            raise osrsPipelineError(f"duplicate selector label in native profile: {label}")
        label_keys.add(label_key)
        entries.append(
            {
                "selector_index": selector_index,
                "realm_id": realm_id,
                "selector_name": label,
                "group": str(record.get("group")),
                "is_surface": bool(record.get("is_surface")),
                "native_file_id": record.get("native_file_id"),
                "map_id": record.get("map_id"),
                "aliases": _osrs_string_list(record.get("aliases", []), f"{realm_id}.aliases"),
                "coverage_zooms": [dict(row) for row in finalized_zooms],
            }
        )

    profile = {
        "schema_version": OSRS_NATIVE_SELECTOR_PROFILE_SCHEMA_VERSION,
        "profile_id": OSRS_NATIVE_SELECTOR_PROFILE_ID,
        "producer": "tools/map/osrs_native_realm_downstream.py",
        "source_manifest": {
            "schema_version": release_manifest.get("schema_version"),
            "candidate": release_manifest.get("candidate"),
            "sha256": source_manifest_sha256,
            "full_record_count": len(realms),
            "group_counts": group_counts,
        },
        "projection": {
            "selector_source": "existing_release_manifest_group_field_plus_live_selector_exclusion",
            "included_groups": ["surface", "realms"],
            "excluded_groups": ["other_maps"],
            "included_count": len(entries),
            "excluded_other_map_count": len(excluded_other_maps),
            "excluded_producer_only_realm_ids": sorted(
                OSRS_EXCLUDED_PRODUCER_ONLY_REALM_IDS
            ),
            "hidden_records_preserved_in_source_manifest": True,
            "selection_policy": (
                "deterministic_group_filter_plus_reviewed_live_selector_exclusion_"
                "no_manual_or_llm_choice"
            ),
        },
        "normal_operation_dependencies": {
            "llm_or_openai_required": False,
            "manual_selection_required": False,
            "live_osrs_required": False,
            "canonical_journal_mutation_required": False,
        },
        "coverage_contract": {
            "contract": OSRS_NATIVE_COVERAGE_CONTRACT,
            "schema_version": OSRS_NATIVE_COVERAGE_SCHEMA_VERSION,
            "capture_protocol": OSRS_CAPTURE_BROKER_PROTOCOL,
            "work_key": ["realm_id", "zoom_percent"],
            "zoom_profile": [dict(row) for row in finalized_zooms],
            "target_count": len(entries) * len(finalized_zooms),
        },
        "entries": entries,
    }
    profile["profile_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(profile))
    return profile


def osrs_reconcile_native_sandbox_coverage(
    queue: Mapping[str, Any],
    result_records: Sequence[Mapping[str, Any]],
    *,
    equivalent_queues: Sequence[Mapping[str, Any]] = (),
    carry_forward: Mapping[str, Any] | None = None,
    successor_queue: Mapping[str, Any] | None = None,
    source_paths: Sequence[str | None] | None = None,
    verify_files: bool = True,
) -> dict[str, Any]:
    """Validate semantic sandbox results against every exact planned position.

    This is deliberately separate from canonical journal reconciliation.  It
    proves that the adapter produced one immutable semantic result and map crop
    for each queue item without exporting or mutating canonical state.
    """

    queue_items = _osrs_validate_native_sandbox_queue(queue)
    queue_by_id = {str(item["id"]): item for item in queue_items}
    generation_id = _osrs_nonempty_str(queue.get("generation_id"), "queue.generation_id")
    accepted_generation_ids = _osrs_equivalent_sandbox_generation_ids(
        queue,
        equivalent_queues,
    )
    carried_by_id: dict[str, osrsSandboxCapture] = {}
    carry_forward_sha256: str | None = None
    if carry_forward is not None:
        if successor_queue is None:
            raise osrsPipelineError("carry-forward reconciliation requires a successor queue")
        carried_by_id, successor_generation_id = _osrs_validate_native_carry_forward(
            queue,
            carry_forward,
            successor_queue,
            verify_files=verify_files,
        )
        accepted_generation_ids.add(successor_generation_id)
        carry_forward_sha256 = osrs_sha256_bytes(
            osrs_adapter_canonical_json_bytes(carry_forward)
        )
    elif successor_queue is not None:
        raise osrsPipelineError("successor queue requires a carry-forward manifest")
    parsed_paths = (
        list(source_paths)
        if source_paths is not None
        else [None for _ in result_records]
    )
    if len(parsed_paths) != len(result_records):
        raise osrsPipelineError("source_paths must match result_records length")

    accepted_by_id: dict[str, osrsSandboxCapture] = dict(carried_by_id)
    duplicate_count = 0
    for raw, source_path in zip(result_records, parsed_paths):
        item_id = _osrs_nonempty_str(raw.get("item_id"), "result.item_id")
        item = queue_by_id.get(item_id)
        if item is None:
            raise osrsPipelineError(f"sandbox result is outside the queue: {item_id}")
        capture = _osrs_parse_native_sandbox_result(
            raw,
            item,
            accepted_generation_ids=accepted_generation_ids,
            source_path=source_path,
            verify_files=verify_files,
        )
        existing = accepted_by_id.get(item_id)
        if existing is not None:
            if existing.result_digest != capture.result_digest:
                raise osrsPipelineError(f"sandbox result replay diverged: {item_id}")
            duplicate_count += 1
            continue
        accepted_by_id[item_id] = capture

    coverage_rows: list[dict[str, Any]] = []
    for item in queue_items:
        item_id = str(item["id"])
        capture = accepted_by_id.get(item_id)
        coverage_rows.append(
            {
                "capture_center": dict(_osrs_mapping(item["capture_center"], "capture_center")),
                "coverage_cell": dict(_osrs_mapping(item["coverage_cell"], "coverage_cell")),
                "criterion_family": item["criterion_family"],
                "item_id": item_id,
                "item_sha256": item["item_sha256"],
                "realm_id": item["realm_id"],
                "result": capture.to_capture_json() if capture is not None else None,
                "selector_index": item["selector_index"],
                "selector_name": item["surface"],
                "state": "ACCEPTED" if capture is not None else "MISSING",
                "zoom_percent": osrs_normalize_zoom(item["zoom_percent"]),
            }
        )

    accepted_count = len(accepted_by_id)
    group_keys = {
        (str(item["realm_id"]), osrs_zoom_key(item["zoom_percent"]))
        for item in queue_items
    }
    realm_ids = {str(item["realm_id"]) for item in queue_items}
    result = {
        "schema_version": OSRS_NATIVE_SANDBOX_COVERAGE_SCHEMA_VERSION,
        "contract": OSRS_NATIVE_SANDBOX_COVERAGE_CONTRACT,
        "execution_profile": OSRS_SEMANTIC_CAPTURE_PROFILE,
        "generation_id": generation_id,
        "accepted_generation_ids": sorted(accepted_generation_ids),
        "carry_forward_sha256": carry_forward_sha256,
        "queue_sha256": osrs_sha256_bytes(osrs_canonical_json_bytes(queue)),
        "catalog_version": queue_items[0]["catalog_version"],
        "planner_version": queue_items[0]["planner_version"],
        "coverage": coverage_rows,
        "coverage_summary": {
            "accepted_count": accepted_count,
            "carried_count": len(carried_by_id),
            "complete": accepted_count == len(queue_items),
            "duplicate_replay_count": duplicate_count,
            "missing_count": len(queue_items) - accepted_count,
            "position_count": len(queue_items),
            "realm_count": len(realm_ids),
            "realm_zoom_group_count": len(group_keys),
        },
        "canonical_export": {
            "attempted": False,
            "accepted_count": 0,
            "required_before_export": "sandbox coverage complete and separately reviewed",
        },
    }
    result["coverage_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(result))
    return result


def osrs_build_native_sandbox_worklist(
    queue: Mapping[str, Any],
    coverage_ledger: Mapping[str, Any],
) -> dict[str, Any]:
    """Emit exact missing queue items after sandbox evidence reconciliation."""

    queue_items = _osrs_validate_native_sandbox_queue(queue)
    generation_id = _osrs_nonempty_str(queue.get("generation_id"), "queue.generation_id")
    if coverage_ledger.get("contract") != OSRS_NATIVE_SANDBOX_COVERAGE_CONTRACT:
        raise osrsPipelineError("sandbox coverage ledger contract mismatch")
    if coverage_ledger.get("generation_id") != generation_id:
        raise osrsPipelineError("sandbox coverage ledger generation mismatch")
    expected_queue_sha = osrs_sha256_bytes(osrs_canonical_json_bytes(queue))
    if coverage_ledger.get("queue_sha256") != expected_queue_sha:
        raise osrsPipelineError("sandbox coverage ledger queue digest mismatch")

    rows = coverage_ledger.get("coverage")
    if not isinstance(rows, list):
        raise osrsPipelineError("sandbox coverage rows must be an array")
    rows_by_id: dict[str, Mapping[str, Any]] = {}
    valid_ids = {str(item["id"]) for item in queue_items}
    for raw in rows:
        row = _osrs_mapping(raw, "sandbox.coverage[]")
        item_id = _osrs_nonempty_str(row.get("item_id"), "sandbox.coverage.item_id")
        if item_id not in valid_ids:
            raise osrsPipelineError(f"sandbox coverage row is outside queue: {item_id}")
        if item_id in rows_by_id:
            raise osrsPipelineError(f"duplicate sandbox coverage row: {item_id}")
        rows_by_id[item_id] = row

    items = [
        dict(item)
        for item in queue_items
        if rows_by_id.get(str(item["id"]), {}).get("state") != "ACCEPTED"
    ]
    worklist = {
        "schema_version": OSRS_NATIVE_SANDBOX_WORKLIST_SCHEMA_VERSION,
        "contract": OSRS_NATIVE_SANDBOX_WORKLIST_CONTRACT,
        "generation_id": generation_id,
        "queue_sha256": expected_queue_sha,
        "coverage_sha256": osrs_sha256_bytes(osrs_canonical_json_bytes(coverage_ledger)),
        "status": "COMPLETE" if not items else "WORK_REMAINING",
        "item_count": len(items),
        "stable_order": "queue_item_order",
        "items": items,
    }
    worklist["worklist_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(worklist))
    return worklist


def osrs_transform_native_sandbox_crops(
    queue: Mapping[str, Any],
    coverage_ledger: Mapping[str, Any],
    output_root: Path,
) -> dict[str, Any]:
    """Assemble complete sandbox crops into deterministic realm/zoom mosaics.

    Overlap pixels are owned by the nearest planned capture center. Stable item
    order breaks exact-distance ties. This preserves one source pixel without
    averaging and makes output independent of filesystem discovery order.
    """

    if not output_root.is_absolute():
        raise osrsPipelineError("screenshot transform output root must be absolute")
    queue_items = _osrs_validate_native_sandbox_queue(queue)
    queue_sha256 = osrs_sha256_bytes(osrs_canonical_json_bytes(queue))
    if coverage_ledger.get("contract") != OSRS_NATIVE_SANDBOX_COVERAGE_CONTRACT:
        raise osrsPipelineError("screenshot transform coverage contract mismatch")
    if coverage_ledger.get("queue_sha256") != queue_sha256:
        raise osrsPipelineError("screenshot transform queue digest mismatch")
    _osrs_validate_sandbox_coverage_digest(coverage_ledger)
    if coverage_ledger.get("coverage_summary", {}).get("complete") is not True:
        raise osrsPipelineError("screenshot transform requires complete sandbox coverage")
    if output_root.exists():
        raise osrsPipelineError(f"screenshot transform output already exists: {output_root}")

    rows_by_id = _osrs_transform_rows_by_item(queue_items, coverage_ledger)
    grouped: dict[tuple[str, str], list[tuple[Mapping[str, Any], Mapping[str, Any]]]] = {}
    for item in queue_items:
        key = (str(item["realm_id"]), osrs_zoom_key(item["zoom_percent"]))
        grouped.setdefault(key, []).append((item, rows_by_id[str(item["id"])]))

    parent = output_root.parent
    parent.mkdir(parents=True, exist_ok=True)
    temporary_root = Path(tempfile.mkdtemp(prefix=f".{output_root.name}.", dir=parent))
    assets: list[dict[str, Any]] = []
    try:
        for (realm_id, zoom_key), members in sorted(
            grouped.items(), key=lambda entry: (
                int(entry[1][0][0]["selector_index"]),
                float(entry[1][0][0]["zoom_percent"]),
            )
        ):
            assets.append(
                _osrs_assemble_native_mosaic(
                    realm_id,
                    zoom_key,
                    sorted(members, key=lambda member: str(member[0]["id"])),
                    temporary_root,
                )
            )
        manifest = {
            "schema_version": OSRS_NATIVE_SCREENSHOT_TRANSFORM_SCHEMA_VERSION,
            "contract": OSRS_NATIVE_SCREENSHOT_TRANSFORM_CONTRACT,
            "queue_sha256": queue_sha256,
            "coverage_sha256": coverage_ledger["coverage_sha256"],
            "catalog_version": queue_items[0]["catalog_version"],
            "planner_version": queue_items[0]["planner_version"],
            "assembly_method": {
                "name": "nearest_planned_capture_center_v1",
                "overlap_blending": False,
                "exact_distance_tie_break": "lexicographically_first_item_id",
                "filesystem_order_dependency": False,
            },
            "summary": {
                "realm_count": len({item["realm_id"] for item in queue_items}),
                "realm_zoom_asset_count": len(assets),
                "source_capture_count": len(queue_items),
                "uncovered_output_pixel_count": 0,
            },
            "assets": assets,
        }
        manifest["transform_sha256"] = osrs_sha256_bytes(
            osrs_canonical_json_bytes(manifest)
        )
        manifest_path = temporary_root / "NATIVE_REALM_SCREENSHOT_TRANSFORM.json"
        osrs_write_json(manifest_path, manifest)
        manifest_path.chmod(0o444)
        temporary_root.rename(output_root)
        return manifest
    except BaseException:
        _osrs_remove_transform_temporary_root(temporary_root)
        raise


def osrs_reconcile_native_coverage(
    profile: Mapping[str, Any],
    accepted_records: Sequence[Mapping[str, Any]],
    *,
    journal_head: Mapping[str, Any] | None = None,
    previous_coverage: Mapping[str, Any] | None = None,
    source_paths: Sequence[str | None] | None = None,
) -> dict[str, Any]:
    """Reduce accepted broker envelopes into per-realm/per-zoom coverage.

    Replay is idempotent only for the same immutable idempotency key and commit
    identity.  Any contradictory replay, overlap, predecessor gap, or uncertain
    broker response raises ``osrsPipelineError``.
    """

    entries = _osrs_profile_entries(profile)
    profile_sha = _osrs_profile_digest(profile)
    zoom_rows = _osrs_profile_zoom_rows(profile)
    previous_captures: list[osrsAcceptedCapture] = []
    if previous_coverage is not None:
        _osrs_assert_matching_profile(previous_coverage, profile_sha)
        previous_captures = [
            _osrs_capture_from_ledger(item)
            for item in previous_coverage.get("accepted_captures", [])
        ]

    parsed_paths = (
        list(source_paths)
        if source_paths is not None
        else [None for _ in accepted_records]
    )
    if len(parsed_paths) != len(accepted_records):
        raise osrsPipelineError("source_paths must match accepted_records length")
    new_captures = [
        osrs_parse_accepted_capture(record, profile, source_path=source_path)
        for record, source_path in zip(accepted_records, parsed_paths)
    ]

    dedupe_by_key: dict[str, osrsAcceptedCapture] = {}
    captures_by_work_key: dict[tuple[str, str], osrsAcceptedCapture] = {}
    accepted: list[osrsAcceptedCapture] = []
    duplicate_count = 0
    current_head: osrsJournalIdentity | None = None
    origin: osrsJournalIdentity | None = None

    for capture in sorted(previous_captures, key=lambda item: item.head):
        _osrs_add_capture(
            capture,
            dedupe_by_key=dedupe_by_key,
            captures_by_work_key=captures_by_work_key,
            accepted=accepted,
            enforce_lineage=False,
        )
        if origin is None:
            origin = capture.predecessor
        if current_head is None or capture.head > current_head:
            current_head = capture.head

    for capture in sorted(new_captures, key=lambda item: (item.head.sequence, item.head.commit_sha256)):
        existing = dedupe_by_key.get(capture.idempotency_key)
        if existing is not None:
            if _osrs_capture_identity(existing) != _osrs_capture_identity(capture):
                raise osrsPipelineError(
                    f"idempotency key replay diverged: {capture.idempotency_key}"
                )
            duplicate_count += 1
            continue
        if current_head is None:
            origin = capture.predecessor
            current_head = capture.predecessor
        if capture.predecessor != current_head:
            raise osrsPipelineError(
                "canonical journal lineage diverged: "
                f"expected predecessor {current_head.to_json()}, got {capture.predecessor.to_json()}"
            )
        _osrs_add_capture(
            capture,
            dedupe_by_key=dedupe_by_key,
            captures_by_work_key=captures_by_work_key,
            accepted=accepted,
            enforce_lineage=True,
        )
        current_head = capture.head

    if journal_head is not None:
        required_head = osrsJournalIdentity.from_mapping(journal_head, "journal_head")
        if current_head is None:
            current_head = required_head
            origin = required_head
        elif required_head != current_head:
            raise osrsPipelineError(
                "canonical journal HEAD does not match accepted capture chain: "
                f"ledger_head={current_head.to_json()}, journal_head={required_head.to_json()}"
            )

    coverage_rows: list[dict[str, Any]] = []
    for entry in entries:
        for zoom_row in zoom_rows:
            work_key = (str(entry["realm_id"]), osrs_zoom_key(zoom_row["zoom_percent"]))
            capture = captures_by_work_key.get(work_key)
            coverage_rows.append(
                {
                    "realm_id": entry["realm_id"],
                    "selector_name": entry["selector_name"],
                    "selector_index": entry["selector_index"],
                    "zoom_percent": zoom_row["zoom_percent"],
                    "criterion_family": zoom_row["criterion_family"],
                    "state": "ACCEPTED" if capture is not None else "MISSING",
                    "accepted_commit": (
                        {
                            "commit_sha256": capture.head.commit_sha256,
                            "sequence": capture.head.sequence,
                            "idempotency_key": capture.idempotency_key,
                            "request_fingerprint": capture.request_fingerprint,
                        }
                        if capture is not None
                        else None
                    ),
                }
            )

    missing = [row for row in coverage_rows if row["state"] != "ACCEPTED"]
    ledger = {
        "schema_version": OSRS_NATIVE_COVERAGE_SCHEMA_VERSION,
        "contract": OSRS_NATIVE_COVERAGE_CONTRACT,
        "profile_id": str(profile.get("profile_id")),
        "profile_sha256": profile_sha,
        "capture_protocol": OSRS_CAPTURE_BROKER_PROTOCOL,
        "lineage": {
            "origin": origin.to_json() if origin is not None else None,
            "head": current_head.to_json() if current_head is not None else None,
            "accepted_commit_count": len(accepted),
            "duplicate_replay_count": duplicate_count,
            "exact_predecessor_lineage_verified": True,
            "uncertain_acceptance_count": 0,
        },
        "coverage": coverage_rows,
        "coverage_summary": {
            "target_count": len(coverage_rows),
            "accepted_count": len(coverage_rows) - len(missing),
            "missing_count": len(missing),
            "complete": not missing,
            "overlap_count": 0,
        },
        "accepted_captures": [
            capture.to_capture_json()
            for capture in sorted(accepted, key=lambda item: item.head)
        ],
    }
    ledger["coverage_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(ledger))
    return ledger


def osrs_parse_accepted_capture(
    value: Mapping[str, Any],
    profile: Mapping[str, Any],
    *,
    source_path: str | None = None,
) -> osrsAcceptedCapture:
    """Parse and validate one accepted canonical broker envelope."""

    if value.get("immutable") is False:
        raise osrsPipelineError("accepted terminal state is explicitly mutable")
    envelope = _osrs_verified_envelope(value)
    if envelope.get("protocol") != OSRS_CAPTURE_BROKER_PROTOCOL or envelope.get("ok") is not True:
        raise osrsPipelineError("accepted envelope is not an ok osrs-capture-broker-v4 response")
    response = _osrs_mapping(envelope.get("raw_broker_response"), "raw_broker_response")
    if response.get("protocol") != OSRS_CAPTURE_BROKER_PROTOCOL or response.get("ok") is not True:
        raise osrsPipelineError("raw broker response is uncertain or rejected")

    predecessor = _osrs_consistent_identity(
        "expected_predecessor",
        envelope.get("expected_predecessor"),
        response.get("expected_predecessor"),
        response.get("accepted_predecessor"),
        _osrs_nested(envelope, "commit", "broker_protocol", "expected_predecessor"),
        _osrs_nested(envelope, "metadata", "broker_protocol", "expected_predecessor"),
    )
    head = _osrs_consistent_identity(
        "accepted_head",
        envelope.get("head"),
        response.get("commit"),
        value.get("accepted_head"),
        envelope.get("commit"),
    )
    if head.sequence != predecessor.sequence + 1:
        raise osrsPipelineError(
            f"accepted commit sequence {head.sequence} does not follow predecessor {predecessor.sequence}"
        )

    commit = _osrs_mapping(envelope.get("commit"), "commit")
    exact_identity = value.get("exact_commit_identity")
    if isinstance(exact_identity, Mapping):
        exact_head = osrsJournalIdentity.from_mapping(
            exact_identity, "exact_commit_identity"
        )
        if exact_head != head:
            raise osrsPipelineError("terminal exact commit identity diverges from envelope head")
        exact_previous_sha = exact_identity.get("previous_commit_sha256")
        if (
            exact_previous_sha is not None
            and str(exact_previous_sha) != predecessor.commit_sha256
        ):
            raise osrsPipelineError("terminal exact commit identity predecessor diverges")
    previous_sha = commit.get("previous_commit_sha256")
    if previous_sha is not None and str(previous_sha) != predecessor.commit_sha256:
        raise osrsPipelineError("accepted commit previous sha does not match predecessor")

    idempotency_key = _osrs_consistent_hex(
        "idempotency_key",
        envelope.get("idempotency_key"),
        response.get("idempotency_key"),
        _osrs_nested(envelope, "commit", "broker_protocol", "idempotency_key"),
        _osrs_nested(envelope, "metadata", "broker_protocol", "idempotency_key"),
        value.get("stable_idempotency_key"),
        _osrs_nested(value, "exact_commit_identity", "idempotency_key"),
    )
    request_fingerprint = _osrs_optional_consistent_hex(
        "request_fingerprint",
        response.get("request_fingerprint"),
        _osrs_nested(envelope, "commit", "broker_protocol", "request_fingerprint"),
        _osrs_nested(envelope, "metadata", "broker_protocol", "request_fingerprint"),
        _osrs_nested(value, "exact_commit_identity", "request_fingerprint"),
    )
    if _osrs_nested(envelope, "commit", "broker_protocol", "protocol") not in {
        None,
        OSRS_CAPTURE_BROKER_PROTOCOL,
    }:
        raise osrsPipelineError("accepted commit broker protocol mismatch")

    metadata = _osrs_capture_metadata(envelope, value)
    selector_name = _osrs_nonempty_str(metadata.get("surface"), "accepted.surface")
    zoom_percent = osrs_normalize_zoom(
        metadata.get("true_zoom_percent", metadata.get("zoom", metadata.get("zoom_percent")))
    )
    criterion_family = _osrs_capture_criterion(metadata, selector_name, zoom_percent)

    profile_entry = _osrs_profile_entry_for_selector(profile, selector_name)
    zoom_row = _osrs_profile_zoom_by_value(profile, zoom_percent)
    if criterion_family != zoom_row["criterion_family"]:
        raise osrsPipelineError(
            "accepted capture criterion family does not match deterministic zoom profile: "
            f"{criterion_family} != {zoom_row['criterion_family']}"
        )

    return osrsAcceptedCapture(
        source_path=source_path,
        idempotency_key=idempotency_key,
        request_fingerprint=request_fingerprint,
        predecessor=predecessor,
        head=head,
        realm_id=str(profile_entry["realm_id"]),
        selector_name=str(profile_entry["selector_name"]),
        zoom_percent=zoom_row["zoom_percent"],
        criterion_family=criterion_family,
        map_crop=_osrs_optional_mapping(metadata.get("map_crop"), "map_crop"),
    )


def osrs_build_native_worklist(
    profile: Mapping[str, Any],
    coverage_ledger: Mapping[str, Any],
) -> dict[str, Any]:
    """Emit stable ordered remaining capture work for the adapter."""

    profile_sha = _osrs_profile_digest(profile)
    _osrs_assert_matching_profile(coverage_ledger, profile_sha)
    coverage_by_key = _osrs_index_coverage_rows(profile, coverage_ledger)
    items: list[dict[str, Any]] = []
    for entry in _osrs_profile_entries(profile):
        for zoom_row in _osrs_profile_zoom_rows(profile):
            work_key = (str(entry["realm_id"]), osrs_zoom_key(zoom_row["zoom_percent"]))
            row = coverage_by_key.get(work_key)
            if row is not None and row.get("state") == "ACCEPTED":
                continue
            items.append(
                {
                    "id": osrs_work_item_id(str(entry["realm_id"]), zoom_row["zoom_percent"]),
                    "kind": "semantic_map_capture",
                    "realm_id": entry["realm_id"],
                    "surface": entry["selector_name"],
                    "zoom_percent": zoom_row["zoom_percent"],
                    "criterion_family": zoom_row["criterion_family"],
                    "restore_after_capture": False,
                    "required_predecessor": coverage_ledger.get("lineage", {}).get("head"),
                    "next_eligible_condition": "accepted canonical journal HEAD matches required_predecessor",
                }
            )
    worklist = {
        "schema_version": OSRS_NATIVE_WORKLIST_SCHEMA_VERSION,
        "contract": OSRS_NATIVE_WORKLIST_CONTRACT,
        "profile_id": str(profile.get("profile_id")),
        "profile_sha256": profile_sha,
        "coverage_sha256": osrs_sha256_bytes(osrs_canonical_json_bytes(coverage_ledger)),
        "capture_protocol": OSRS_CAPTURE_BROKER_PROTOCOL,
        "status": "COMPLETE" if not items else "WORK_REMAINING",
        "item_count": len(items),
        "stable_order": ["selector_index", "zoom_profile_index"],
        "items": items,
    }
    worklist["worklist_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(worklist))
    return worklist


def osrs_assemble_native_release_inputs(
    profile: Mapping[str, Any],
    coverage_ledger: Mapping[str, Any],
    *,
    release_manifest: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Map complete native coverage to locked release assets, or block precisely."""

    profile_sha = _osrs_profile_digest(profile)
    _osrs_assert_matching_profile(coverage_ledger, profile_sha)
    coverage_by_key = _osrs_index_coverage_rows(profile, coverage_ledger)
    expected_keys = _osrs_expected_coverage_keys(profile)
    missing_key_count = len(expected_keys - set(coverage_by_key))
    missing = [
        row for row in _osrs_coverage_rows(coverage_ledger) if row.get("state") != "ACCEPTED"
    ]
    base = {
        "schema_version": OSRS_NATIVE_RELEASE_INPUT_SCHEMA_VERSION,
        "contract": OSRS_NATIVE_RELEASE_INPUT_CONTRACT,
        "profile_id": str(profile.get("profile_id")),
        "profile_sha256": profile_sha,
        "coverage_sha256": osrs_sha256_bytes(osrs_canonical_json_bytes(coverage_ledger)),
        "reused_tools": [
            "tools/map/build_osrs_non_surface_realms_locked.py",
            "tools/map/build_osrs_non_surface_realms.py",
            "tools/map/map-asset-generator.py",
            "tools/map/osrs_non_surface_assets.py",
            "tools/map/osrs_non_surface_realms.py",
        ],
        "normal_operation_dependencies": {
            "llm_or_openai_required": False,
            "manual_selection_required": False,
            "live_osrs_required": False,
        },
    }
    if missing_key_count or missing:
        result = {
            **base,
            "status": "INCOMPLETE_NATIVE_COVERAGE",
            "blockers": [
                {
                    "code": "NATIVE_REALM_COVERAGE_INCOMPLETE",
                    "owner": "adapter production capture lane",
                    "missing_capture_count": missing_key_count + len(missing),
                    "next_retry_condition": "coverage worklist returns zero remaining items",
                }
            ],
            "release_inputs": [],
        }
        result["release_input_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(result))
        return result

    if release_manifest is None:
        result = {
            **base,
            "status": "BLOCKED_RAW_SCREENSHOT_TRANSFORM_REQUIRED",
            "blockers": [
                {
                    "code": "NO_RELEASE_MANIFEST_OR_SCREENSHOT_TRANSFORM_CONTRACT",
                    "owner": "downstream integration between accepted map crops and locked asset builder",
                    "required_interface": "osrs-native-realm-screenshot-transform-v1",
                    "next_retry_condition": (
                        "provide a release manifest with locked MBTiles/mask assets or a "
                        "reviewed transform manifest that proves raw accepted screenshots "
                        "can be losslessly mapped into release inputs"
                    ),
                }
            ],
            "release_inputs": [],
        }
        result["release_input_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(result))
        return result

    records_by_id = {str(record.get("id")): record for record in _osrs_release_realms(release_manifest)}
    release_inputs: list[dict[str, Any]] = []
    missing_assets: list[str] = []
    for entry in _osrs_profile_entries(profile):
        record = records_by_id.get(str(entry["realm_id"]))
        assets = [] if record is None else record.get("assets", [])
        if not isinstance(assets, list) or not assets:
            missing_assets.append(str(entry["realm_id"]))
            continue
        release_inputs.append(
            {
                "realm_id": entry["realm_id"],
                "selector_name": entry["selector_name"],
                "group": entry["group"],
                "assets": [
                    {
                        "plane": asset.get("plane"),
                        "mbtiles_path": asset.get("mbtiles_path"),
                        "mbtiles_sha256": asset.get("mbtiles_sha256"),
                        "mask_path": asset.get("mask_path"),
                        "mask_sha256": asset.get("mask_sha256"),
                    }
                    for asset in assets
                ],
            }
        )

    if missing_assets:
        result = {
            **base,
            "status": "BLOCKED_RAW_SCREENSHOT_TRANSFORM_REQUIRED",
            "blockers": [
                {
                    "code": "LOCKED_NATIVE_REALM_ASSETS_MISSING",
                    "owner": "locked MBTiles/mask builder or future screenshot transform lane",
                    "missing_realm_ids": missing_assets,
                    "required_interface": "osrs-native-realm-screenshot-transform-v1",
                    "next_retry_condition": (
                        "locked builder emits native MBTiles/masks for every profile realm "
                        "or a reviewed screenshot transform produces equivalent release inputs"
                    ),
                }
            ],
            "release_inputs": [],
        }
        result["release_input_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(result))
        return result

    result = {
        **base,
        "status": "RELEASE_INPUTS_READY",
        "blockers": [],
        "release_inputs": release_inputs,
        "checks": {
            "coverage_complete": True,
            "all_native_profile_realms_have_release_assets": True,
            "other_maps_excluded_from_user_visible_release_worklist": True,
            "full_internal_manifest_preserved": True,
        },
    }
    result["release_input_sha256"] = osrs_sha256_bytes(osrs_canonical_json_bytes(result))
    return result


def osrs_work_item_id(realm_id: str, zoom_percent: int | float) -> str:
    return f"native-{osrs_asset_stem(realm_id)}-z{osrs_zoom_key(zoom_percent).replace('.', '_')}"


def osrs_normalize_zoom(value: Any) -> int | float:
    if isinstance(value, bool):
        raise osrsPipelineError("zoom must be numeric")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if not value.is_integer():
            return value
        return int(value)
    text = str(value).strip()
    if re.fullmatch(r"[0-9]+", text):
        return int(text)
    if re.fullmatch(r"[0-9]+\.[0-9]+", text):
        number = float(text)
        return int(number) if number.is_integer() else number
    raise osrsPipelineError(f"zoom must be a stable numeric value: {value!r}")


def osrs_zoom_key(value: int | float) -> str:
    normalized = osrs_normalize_zoom(value)
    if isinstance(normalized, int):
        return str(normalized)
    return ("%s" % normalized).rstrip("0").rstrip(".")


def osrs_adapter_canonical_json_bytes(value: Any) -> bytes:
    """Match the adapter worker's compact, recursively key-sorted JSON."""

    return _osrs_javascript_json(value).encode("utf-8")


def _osrs_javascript_json(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _osrs_javascript_number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(_osrs_javascript_json(item) for item in value) + "]"
    if isinstance(value, Mapping):
        return "{" + ",".join(
            f"{_osrs_javascript_json(str(key))}:{_osrs_javascript_json(value[key])}"
            for key in sorted(value)
        ) + "}"
    raise osrsPipelineError(
        f"adapter canonical JSON does not support {type(value).__name__}"
    )


def _osrs_javascript_number(value: float) -> str:
    if not math.isfinite(value):
        raise osrsPipelineError("adapter canonical JSON requires finite numbers")
    if value == 0:
        return "0"
    representation = repr(value).lower()
    magnitude = abs(value)
    if 1e-6 <= magnitude < 1e21:
        if "e" in representation:
            representation = format(Decimal(representation), "f")
        if representation.endswith(".0"):
            representation = representation[:-2]
        return representation
    if "e" not in representation:
        representation = format(value, ".15e")
    mantissa, exponent_text = representation.split("e", 1)
    mantissa = mantissa.rstrip("0").rstrip(".")
    exponent = int(exponent_text)
    sign = "+" if exponent >= 0 else ""
    return f"{mantissa}e{sign}{exponent}"


def _osrs_validate_native_sandbox_queue(
    queue: Mapping[str, Any],
) -> tuple[Mapping[str, Any], ...]:
    if queue.get("schema_version") != 2:
        raise osrsPipelineError("native sandbox queue must use schema version 2")
    if queue.get("execution_profile") != OSRS_SEMANTIC_CAPTURE_PROFILE:
        raise osrsPipelineError("native sandbox queue execution profile mismatch")
    _osrs_nonempty_str(queue.get("generation_id"), "queue.generation_id")
    raw_items = queue.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        raise osrsPipelineError("native sandbox queue items must be a non-empty array")

    items: list[Mapping[str, Any]] = []
    item_ids: set[str] = set()
    selector_rows: dict[str, tuple[int, str]] = {}
    selector_indices: dict[int, str] = {}
    group_cells: dict[tuple[str, str], set[tuple[int, int]]] = {}
    group_zooms: dict[str, set[str]] = {}
    catalog_versions: set[str] = set()
    planner_versions: set[str] = set()

    for raw in raw_items:
        item = _osrs_mapping(raw, "queue.items[]")
        item_id = _osrs_nonempty_str(item.get("id"), "queue.items[].id")
        if item_id in item_ids:
            raise osrsPipelineError(f"duplicate native sandbox queue item id: {item_id}")
        item_ids.add(item_id)
        if item.get("kind") != "semantic_map_capture":
            raise osrsPipelineError(f"native sandbox item kind mismatch: {item_id}")
        if item.get("restore_after_capture") is not False:
            raise osrsPipelineError(
                f"native production item must disable restoration: {item_id}"
            )

        item_sha256 = _osrs_consistent_hex("item_sha256", item.get("item_sha256"))
        without_digest = dict(item)
        without_digest.pop("item_sha256", None)
        if osrs_sha256_bytes(osrs_adapter_canonical_json_bytes(without_digest)) != item_sha256:
            raise osrsPipelineError(f"native sandbox item digest mismatch: {item_id}")

        realm_id = _osrs_nonempty_str(item.get("realm_id"), "queue.items[].realm_id")
        selector_name = _osrs_nonempty_str(item.get("surface"), "queue.items[].surface")
        selector_index = _osrs_int(item.get("selector_index"), "queue.items[].selector_index")
        if selector_index < 0:
            raise osrsPipelineError(f"negative selector index: {item_id}")
        prior_row = selector_rows.setdefault(realm_id, (selector_index, selector_name))
        if prior_row != (selector_index, selector_name):
            raise osrsPipelineError(f"realm selector identity drift: {realm_id}")
        prior_realm = selector_indices.setdefault(selector_index, realm_id)
        if prior_realm != realm_id:
            raise osrsPipelineError(f"selector index overlap: {selector_index}")

        zoom = osrs_normalize_zoom(item.get("zoom_percent"))
        group_key = (realm_id, osrs_zoom_key(zoom))
        group_zooms.setdefault(realm_id, set()).add(group_key[1])
        _osrs_nonempty_str(item.get("criterion_family"), "queue.items[].criterion_family")
        catalog_versions.add(
            _osrs_nonempty_str(item.get("catalog_version"), "queue.items[].catalog_version")
        )
        planner_versions.add(
            _osrs_nonempty_str(item.get("planner_version"), "queue.items[].planner_version")
        )

        center = _osrs_xy_mapping(item.get("capture_center"), "capture_center")
        cell = _osrs_mapping(item.get("coverage_cell"), "coverage_cell")
        row = _osrs_int(cell.get("row"), "coverage_cell.row")
        column = _osrs_int(cell.get("column"), "coverage_cell.column")
        if row < 0 or column < 0:
            raise osrsPipelineError(f"negative coverage cell: {item_id}")
        cell_key = (row, column)
        cells = group_cells.setdefault(group_key, set())
        if cell_key in cells:
            raise osrsPipelineError(f"duplicate coverage cell for {group_key}: {cell_key}")
        cells.add(cell_key)

        realm_bounds = _osrs_bounds_mapping(cell.get("realm_bounds"), "realm_bounds")
        _osrs_bounds_mapping(cell.get("capture_bounds"), "capture_bounds")
        _osrs_xy_mapping(cell.get("reset_center"), "reset_center")
        _osrs_native_coverage_crop(item, item_id)
        viewport = _osrs_mapping(cell.get("viewport"), "viewport")
        if osrs_zoom_key(viewport.get("zoom_percent")) != group_key[1]:
            raise osrsPipelineError(f"viewport zoom mismatch: {item_id}")
        _osrs_positive_number(viewport.get("width"), "viewport.width")
        _osrs_positive_number(viewport.get("height"), "viewport.height")
        if not (
            realm_bounds["min_x"] <= center["x"] <= realm_bounds["max_x"]
            and realm_bounds["min_y"] <= center["y"] <= realm_bounds["max_y"]
        ):
            raise osrsPipelineError(f"capture center is outside realm bounds: {item_id}")
        items.append(item)

    if len(catalog_versions) != 1 or len(planner_versions) != 1:
        raise osrsPipelineError("native sandbox queue catalog/planner version drift")
    expected_indices = set(range(len(selector_rows)))
    if set(selector_indices) != expected_indices:
        raise osrsPipelineError("native sandbox selector indices are not contiguous")
    expected_zooms = {osrs_zoom_key(row["zoom_percent"]) for row in OSRS_DEFAULT_ZOOM_PROFILE}
    for realm_id, zooms in group_zooms.items():
        if zooms != expected_zooms:
            raise osrsPipelineError(
                f"native sandbox realm zoom coverage mismatch for {realm_id}: {sorted(zooms)}"
            )
    return tuple(items)


def _osrs_parse_native_sandbox_result(
    value: Mapping[str, Any],
    item: Mapping[str, Any],
    *,
    accepted_generation_ids: set[str],
    source_path: str | None,
    verify_files: bool,
) -> osrsSandboxCapture:
    item_id = str(item["id"])
    if value.get("schema_version") != 2:
        raise osrsPipelineError(f"sandbox result schema mismatch: {item_id}")
    if value.get("execution_profile") != OSRS_SEMANTIC_CAPTURE_PROFILE:
        raise osrsPipelineError(f"sandbox result profile mismatch: {item_id}")
    if (
        value.get("generation_id") not in accepted_generation_ids
        or value.get("item_id") != item_id
    ):
        raise osrsPipelineError(f"sandbox result queue identity mismatch: {item_id}")
    if value.get("item_sha256") != item.get("item_sha256"):
        raise osrsPipelineError(f"sandbox result item digest mismatch: {item_id}")
    result_digest = _osrs_consistent_hex("result_digest", value.get("result_digest"))
    without_digest = dict(value)
    without_digest.pop("result_digest", None)
    if osrs_sha256_bytes(osrs_adapter_canonical_json_bytes(without_digest)) != result_digest:
        raise osrsPipelineError(f"sandbox result digest mismatch: {item_id}")

    expected_work = {
        key: item[key]
        for key in (
            "surface",
            "realm_id",
            "selector_index",
            "catalog_version",
            "planner_version",
            "capture_center",
            "coverage_cell",
            "zoom_percent",
            "criterion_family",
            "restore_after_capture",
        )
    }
    requested_work = _osrs_mapping(value.get("requested_work"), "requested_work")
    if osrs_canonical_json_bytes(requested_work) != osrs_canonical_json_bytes(expected_work):
        raise osrsPipelineError(f"sandbox requested work diverges from queue: {item_id}")

    surface_gate = _osrs_mapping(
        _osrs_nested(value, "surface_proof", "ready_gate"), "surface_proof.ready_gate"
    )
    if (
        surface_gate.get("passed") is not True
        or surface_gate.get("requested_surface") != item["surface"]
        or surface_gate.get("observed_surface") != item["surface"]
        or surface_gate.get("nonblack") is not True
    ):
        raise osrsPipelineError(f"sandbox surface proof failed: {item_id}")
    zoom_proof = _osrs_mapping(value.get("zoom_proof"), "zoom_proof")
    if (
        osrs_zoom_key(zoom_proof.get("requested_zoom_percent"))
        != osrs_zoom_key(item["zoom_percent"])
        or osrs_zoom_key(zoom_proof.get("observed_zoom_percent"))
        != osrs_zoom_key(item["zoom_percent"])
    ):
        raise osrsPipelineError(f"sandbox zoom proof failed: {item_id}")
    navigation = _osrs_mapping(value.get("coverage_navigation"), "coverage_navigation")
    if (
        osrs_canonical_json_bytes(navigation.get("target_center"))
        != osrs_canonical_json_bytes(item["capture_center"])
        or osrs_canonical_json_bytes(navigation.get("target_cell"))
        != osrs_canonical_json_bytes(
            {
                "row": item["coverage_cell"]["row"],
                "column": item["coverage_cell"]["column"],
            }
        )
    ):
        raise osrsPipelineError(f"sandbox coverage navigation proof failed: {item_id}")
    _osrs_validate_native_sandbox_movement(navigation, item, item_id)

    map_crop = _osrs_mapping(value.get("map_crop"), "map_crop")
    crop_path = Path(_osrs_nonempty_str(map_crop.get("path"), "map_crop.path"))
    crop_sha256 = _osrs_consistent_hex("map_crop.sha256", map_crop.get("sha256"))
    crop_bytes = _osrs_int(map_crop.get("bytes"), "map_crop.bytes")
    crop_width = _osrs_int(map_crop.get("width"), "map_crop.width")
    crop_height = _osrs_int(map_crop.get("height"), "map_crop.height")
    if crop_width <= 0 or crop_height <= 0:
        raise osrsPipelineError(f"sandbox map crop dimensions are invalid: {item_id}")
    coverage_crop = _osrs_native_coverage_crop(item, item_id)
    if item["coverage_cell"].get("coverage_crop") is not None and (
        osrs_canonical_json_bytes(map_crop.get("source_crop"))
        != osrs_canonical_json_bytes(coverage_crop)
        or crop_width != coverage_crop["width"]
        or crop_height != coverage_crop["height"]
    ):
        raise osrsPipelineError(f"sandbox map crop geometry diverges: {item_id}")
    source_sha256: str | None = None
    source_bytes: int | None = None
    if verify_files:
        _osrs_verify_immutable_file(crop_path, crop_sha256, crop_bytes, "map crop")
        if _osrs_png_dimensions(crop_path) != (crop_width, crop_height):
            raise osrsPipelineError(f"sandbox map crop dimensions diverge: {item_id}")
        if source_path is None:
            raise osrsPipelineError(f"sandbox result source path is required: {item_id}")
        result_path = Path(source_path)
        source_sha256, source_bytes = _osrs_verify_immutable_file(
            result_path,
            None,
            None,
            "sandbox result",
        )
        try:
            stored_result = json.loads(result_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise osrsPipelineError(
                f"sandbox result file is not canonical JSON: {result_path}"
            ) from error
        if osrs_adapter_canonical_json_bytes(stored_result) != osrs_adapter_canonical_json_bytes(value):
            raise osrsPipelineError(f"sandbox result file content diverges: {item_id}")

    performance = _osrs_mapping(value.get("performance"), "performance")
    elapsed = _osrs_positive_number(
        performance.get("elapsed_milliseconds"), "performance.elapsed_milliseconds"
    )
    hard_deadline = _osrs_positive_number(
        performance.get("hard_deadline_milliseconds"),
        "performance.hard_deadline_milliseconds",
    )
    if elapsed > hard_deadline:
        raise osrsPipelineError(f"sandbox result exceeded hard deadline: {item_id}")
    evidence = value.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        raise osrsPipelineError(f"sandbox result has no evidence chain: {item_id}")

    return osrsSandboxCapture(
        source_path=source_path,
        source_sha256=source_sha256,
        source_bytes=source_bytes,
        item_id=item_id,
        item_sha256=str(item["item_sha256"]),
        result_digest=result_digest,
        realm_id=str(item["realm_id"]),
        selector_name=str(item["surface"]),
        selector_index=int(item["selector_index"]),
        zoom_percent=osrs_normalize_zoom(item["zoom_percent"]),
        criterion_family=str(item["criterion_family"]),
        capture_center=dict(_osrs_mapping(item["capture_center"], "capture_center")),
        coverage_cell=dict(_osrs_mapping(item["coverage_cell"], "coverage_cell")),
        map_crop=dict(map_crop),
        completed_at=_osrs_nonempty_str(value.get("completed_at"), "completed_at"),
    )


def _osrs_validate_native_sandbox_movement(
    navigation: Mapping[str, Any],
    item: Mapping[str, Any],
    item_id: str,
) -> None:
    coverage_crop = _osrs_native_coverage_crop(item, item_id)
    minimum_x = coverage_crop["left"] + OSRS_NATIVE_COVERAGE_ACTION_MARGIN
    maximum_x = coverage_crop["left"] + coverage_crop["width"] - OSRS_NATIVE_COVERAGE_ACTION_MARGIN
    minimum_y = coverage_crop["top"] + OSRS_NATIVE_COVERAGE_ACTION_MARGIN
    maximum_y = coverage_crop["top"] + coverage_crop["height"] - OSRS_NATIVE_COVERAGE_ACTION_MARGIN
    reset_center = _osrs_mapping(
        _osrs_nested(item, "coverage_cell", "reset_center"),
        "coverage_cell.reset_center",
    )
    target_center = _osrs_mapping(item.get("capture_center"), "capture_center")
    zoom = _osrs_finite_number(item.get("zoom_percent"), "zoom_percent")
    expected_delta = {
        "dx": math.floor(
            (_osrs_finite_number(reset_center.get("x"), "reset_center.x")
             - _osrs_finite_number(target_center.get("x"), "capture_center.x"))
            * zoom / 100
            + 0.5
        ),
        "dy": math.floor(
            (_osrs_finite_number(target_center.get("y"), "capture_center.y")
             - _osrs_finite_number(reset_center.get("y"), "reset_center.y"))
            * zoom / 100
            + 0.5
        ),
    }
    if math.hypot(expected_delta["dx"], expected_delta["dy"]) < 10:
        expected_delta = {"dx": 0, "dy": 0}
    if osrs_canonical_json_bytes(navigation.get("source_center")) != osrs_canonical_json_bytes(
        reset_center
    ):
        raise osrsPipelineError(f"sandbox coverage source center diverges: {item_id}")
    if (
        osrs_canonical_json_bytes(navigation.get("reference_delta"))
        != osrs_canonical_json_bytes(expected_delta)
        or osrs_canonical_json_bytes(navigation.get("delivered_reference_delta"))
        != osrs_canonical_json_bytes(expected_delta)
        or _osrs_int(
            navigation.get("target_tolerance_reference_pixels"),
            "coverage_navigation.target_tolerance_reference_pixels",
        )
        != 10
    ):
        raise osrsPipelineError(f"sandbox coverage displacement summary failed: {item_id}")

    movement = _osrs_mapping(
        navigation.get("movement"), "coverage_navigation.movement"
    )
    transitions = movement.get("transitions")
    if not isinstance(transitions, list):
        raise osrsPipelineError(f"sandbox coverage movement transitions invalid: {item_id}")
    action_count = _osrs_int(
        movement.get("action_count"), "coverage_navigation.movement.action_count"
    )
    expected_count = 0 if expected_delta == {"dx": 0, "dy": 0} else max(
        math.ceil(abs(expected_delta["dx"]) / 240),
        math.ceil(abs(expected_delta["dy"]) / 400),
    )
    if action_count != expected_count or len(transitions) != expected_count:
        raise osrsPipelineError(f"sandbox coverage movement count failed: {item_id}")

    delivered_dx = 0
    delivered_dy = 0
    for index, raw_transition in enumerate(transitions):
        transition = _osrs_mapping(raw_transition, "coverage_navigation.movement.transitions[]")
        if _osrs_int(transition.get("ordinal"), "movement.ordinal") != index + 1:
            raise osrsPipelineError(f"sandbox coverage movement ordinal failed: {item_id}")
        difference = _osrs_finite_number(
            transition.get("mean_abs_difference"), "movement.mean_abs_difference"
        )
        if difference < 2.5:
            raise osrsPipelineError(f"sandbox coverage movement was a no-op: {item_id}")
        vector = _osrs_mapping(transition.get("vector"), "movement.vector")
        delta = _osrs_mapping(vector.get("reference_delta"), "movement.vector.reference_delta")
        dx = _osrs_int(delta.get("dx"), "movement.vector.reference_delta.dx")
        dy = _osrs_int(delta.get("dy"), "movement.vector.reference_delta.dy")
        if abs(dx) > 240 or abs(dy) > 400 or math.hypot(dx, dy) < 10:
            raise osrsPipelineError(f"sandbox coverage vector is invalid: {item_id}")
        reference = _osrs_mapping(vector.get("reference"), "movement.vector.reference")
        start = _osrs_mapping(reference.get("from"), "movement.vector.reference.from")
        end = _osrs_mapping(reference.get("to"), "movement.vector.reference.to")
        start_x = _osrs_int(start.get("x"), "movement.vector.reference.from.x")
        start_y = _osrs_int(start.get("y"), "movement.vector.reference.from.y")
        end_x = _osrs_int(end.get("x"), "movement.vector.reference.to.x")
        end_y = _osrs_int(end.get("y"), "movement.vector.reference.to.y")
        if (
            end_x - start_x != dx
            or end_y - start_y != dy
            or not (minimum_x <= start_x < maximum_x and minimum_y <= start_y < maximum_y)
            or not (minimum_x <= end_x < maximum_x and minimum_y <= end_y < maximum_y)
        ):
            raise osrsPipelineError(f"sandbox coverage vector escaped map crop: {item_id}")
        proof = _osrs_mapping(transition.get("displacement_proof"), "movement.displacement_proof")
        proof_expected = _osrs_mapping(
            proof.get("expected_reference_delta"), "movement.displacement_proof.expected"
        )
        proof_delivered = _osrs_mapping(
            proof.get("delivered_reference_delta"), "movement.displacement_proof.delivered"
        )
        measured_dx = _osrs_int(proof_delivered.get("dx"), "movement.displacement_proof.dx")
        measured_dy = _osrs_int(proof_delivered.get("dy"), "movement.displacement_proof.dy")
        if (
            proof.get("passed") is not True
            or proof.get("evidence_mode") != "native_crop_expected_neighborhood"
            or _osrs_int(proof_expected.get("dx"), "movement.displacement_proof.expected.dx") != dx
            or _osrs_int(proof_expected.get("dy"), "movement.displacement_proof.expected.dy") != dy
            or abs(measured_dx - dx) > 10
            or abs(measured_dy - dy) > 10
            or _osrs_int(
                proof.get("tolerance_reference_pixels"),
                "movement.displacement_proof.tolerance",
            )
            != 10
            or _osrs_finite_number(
                proof.get("mean_abs_difference"), "movement.displacement_proof.mean_abs"
            )
            != difference
            or _osrs_finite_number(
                proof.get("aligned_mean_abs"), "movement.displacement_proof.aligned_mean_abs"
            )
            > 25
            or _osrs_finite_number(
                proof.get("informative_coverage"),
                "movement.displacement_proof.informative_coverage",
            )
            < 0.6
        ):
            raise osrsPipelineError(f"sandbox coverage displacement proof failed: {item_id}")
        delivered_dx += dx
        delivered_dy += dy
    if delivered_dx != expected_delta["dx"] or delivered_dy != expected_delta["dy"]:
        raise osrsPipelineError(f"sandbox coverage movement sum failed: {item_id}")


def _osrs_native_coverage_crop(
    item: Mapping[str, Any], item_id: str
) -> dict[str, int]:
    cell = _osrs_mapping(item.get("coverage_cell"), "coverage_cell")
    raw_crop = cell.get("coverage_crop")
    if raw_crop is None:
        return dict(OSRS_HISTORICAL_NATIVE_COVERAGE_CROP)
    crop = _osrs_mapping(raw_crop, "coverage_cell.coverage_crop")
    parsed = {
        key: _osrs_int(crop.get(key), f"coverage_cell.coverage_crop.{key}")
        for key in ("left", "top", "width", "height")
    }
    if (
        parsed["left"] < 0
        or parsed["top"] < 0
        or parsed["width"] <= 0
        or parsed["height"] <= 0
        or parsed["left"] + parsed["width"] > OSRS_REVIEWED_FRAME_WIDTH
        or parsed["top"] + parsed["height"] > OSRS_REVIEWED_FRAME_HEIGHT
        or parsed["width"] <= OSRS_NATIVE_COVERAGE_ACTION_MARGIN * 2
        or parsed["height"] <= OSRS_NATIVE_COVERAGE_ACTION_MARGIN * 2
    ):
        raise osrsPipelineError(f"native sandbox coverage crop is invalid: {item_id}")
    return parsed


def _osrs_verify_immutable_file(
    path: Path,
    expected_sha256: str | None,
    expected_bytes: int | None,
    field: str,
) -> tuple[str, int]:
    if not path.is_absolute() or not path.is_file():
        raise osrsPipelineError(f"{field} path is not an existing absolute file: {path}")
    stat_result = path.stat()
    if stat_result.st_mode & 0o222:
        raise osrsPipelineError(f"{field} is writable: {path}")
    data_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
    if expected_sha256 is not None and data_sha256 != expected_sha256:
        raise osrsPipelineError(f"{field} sha256 mismatch: {path}")
    if expected_bytes is not None and stat_result.st_size != expected_bytes:
        raise osrsPipelineError(f"{field} byte count mismatch: {path}")
    return data_sha256, stat_result.st_size


def _osrs_validate_sandbox_coverage_digest(
    coverage_ledger: Mapping[str, Any],
) -> None:
    digest = _osrs_consistent_hex(
        "coverage_sha256", coverage_ledger.get("coverage_sha256")
    )
    without_digest = dict(coverage_ledger)
    without_digest.pop("coverage_sha256", None)
    if osrs_sha256_bytes(osrs_canonical_json_bytes(without_digest)) != digest:
        raise osrsPipelineError("screenshot transform coverage digest mismatch")


def _osrs_transform_rows_by_item(
    queue_items: Sequence[Mapping[str, Any]],
    coverage_ledger: Mapping[str, Any],
) -> dict[str, Mapping[str, Any]]:
    raw_rows = coverage_ledger.get("coverage")
    if not isinstance(raw_rows, list):
        raise osrsPipelineError("screenshot transform coverage rows must be an array")
    queue_by_id = {str(item["id"]): item for item in queue_items}
    rows_by_id: dict[str, Mapping[str, Any]] = {}
    for raw_row in raw_rows:
        row = _osrs_mapping(raw_row, "coverage[]")
        item_id = _osrs_nonempty_str(row.get("item_id"), "coverage.item_id")
        item = queue_by_id.get(item_id)
        if item is None or item_id in rows_by_id:
            raise osrsPipelineError(f"screenshot transform coverage identity invalid: {item_id}")
        expected_row = {
            "capture_center": item["capture_center"],
            "coverage_cell": item["coverage_cell"],
            "criterion_family": item["criterion_family"],
            "item_id": item_id,
            "item_sha256": item["item_sha256"],
            "realm_id": item["realm_id"],
            "selector_index": item["selector_index"],
            "selector_name": item["surface"],
            "state": "ACCEPTED",
            "zoom_percent": osrs_normalize_zoom(item["zoom_percent"]),
        }
        for key, expected in expected_row.items():
            if osrs_canonical_json_bytes(row.get(key)) != osrs_canonical_json_bytes(expected):
                raise osrsPipelineError(
                    f"screenshot transform coverage row diverges at {key}: {item_id}"
                )
        result = _osrs_mapping(row.get("result"), "coverage.result")
        if (
            result.get("item_id") != item_id
            or result.get("item_sha256") != item["item_sha256"]
            or result.get("result_digest") is None
            or osrs_canonical_json_bytes(result.get("capture_center"))
            != osrs_canonical_json_bytes(item["capture_center"])
            or osrs_canonical_json_bytes(result.get("coverage_cell"))
            != osrs_canonical_json_bytes(item["coverage_cell"])
        ):
            raise osrsPipelineError(
                f"screenshot transform accepted result diverges: {item_id}"
            )
        rows_by_id[item_id] = row
    if set(rows_by_id) != set(queue_by_id):
        raise osrsPipelineError("screenshot transform coverage item set is incomplete")
    return rows_by_id


def _osrs_assemble_native_mosaic(
    realm_id: str,
    zoom_key: str,
    members: Sequence[tuple[Mapping[str, Any], Mapping[str, Any]]],
    output_root: Path,
) -> dict[str, Any]:
    first_item = members[0][0]
    zoom = _osrs_finite_number(first_item["zoom_percent"], "zoom_percent")
    scale = zoom / 100
    realm_bounds = _osrs_bounds_mapping(
        _osrs_nested(first_item, "coverage_cell", "realm_bounds"), "realm_bounds"
    )
    output_width = math.ceil((realm_bounds["max_x"] - realm_bounds["min_x"]) * scale)
    output_height = math.ceil((realm_bounds["max_y"] - realm_bounds["min_y"]) * scale)
    if output_width <= 0 or output_height <= 0:
        raise osrsPipelineError(f"screenshot transform output is empty: {realm_id}@{zoom_key}")

    canvas = np.zeros((output_height, output_width, 4), dtype=np.uint8)
    best_distance = np.full((output_height, output_width), np.inf, dtype=np.float32)
    owner = np.full((output_height, output_width), -1, dtype=np.int16)
    coverage_count = np.zeros((output_height, output_width), dtype=np.uint8)
    source_records: list[dict[str, Any]] = []
    for owner_index, (item, row) in enumerate(members):
        member_bounds = _osrs_bounds_mapping(
            _osrs_nested(item, "coverage_cell", "realm_bounds"), "realm_bounds"
        )
        if member_bounds != realm_bounds or osrs_zoom_key(item["zoom_percent"]) != zoom_key:
            raise osrsPipelineError(f"screenshot transform group drift: {item['id']}")
        center = _osrs_xy_mapping(item["capture_center"], "capture_center")
        result = _osrs_mapping(row["result"], "coverage.result")
        crop = _osrs_mapping(result.get("map_crop"), "map_crop")
        crop_path = Path(_osrs_nonempty_str(crop.get("path"), "map_crop.path"))
        crop_sha, crop_bytes = _osrs_verify_immutable_file(
            crop_path,
            _osrs_consistent_hex("map_crop.sha256", crop.get("sha256")),
            _osrs_int(crop.get("bytes"), "map_crop.bytes"),
            "map_crop",
        )
        with Image.open(crop_path) as image:
            rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8)
        crop_height, crop_width = rgba.shape[:2]
        if (
            crop_width != _osrs_int(crop.get("width"), "map_crop.width")
            or crop_height != _osrs_int(crop.get("height"), "map_crop.height")
        ):
            raise osrsPipelineError(f"screenshot transform crop dimensions drift: {item['id']}")
        origin_x = math.floor(
            (center["x"] - realm_bounds["min_x"]) * scale - crop_width / 2 + 0.5
        )
        origin_y = math.floor(
            (center["y"] - realm_bounds["min_y"]) * scale - crop_height / 2 + 0.5
        )
        left = max(0, origin_x)
        top = max(0, origin_y)
        right = min(output_width, origin_x + crop_width)
        bottom = min(output_height, origin_y + crop_height)
        if left >= right or top >= bottom:
            raise osrsPipelineError(f"screenshot transform crop misses realm: {item['id']}")
        source = rgba[
            top - origin_y : bottom - origin_y,
            left - origin_x : right - origin_x,
        ]
        yy, xx = np.ogrid[top:bottom, left:right]
        center_x = (center["x"] - realm_bounds["min_x"]) * scale
        center_y = (center["y"] - realm_bounds["min_y"]) * scale
        distance = (xx + 0.5 - center_x) ** 2 + (yy + 0.5 - center_y) ** 2
        region_distance = best_distance[top:bottom, left:right]
        nearer = distance < region_distance
        canvas_region = canvas[top:bottom, left:right]
        canvas_region[nearer] = source[nearer]
        region_distance[nearer] = distance[nearer]
        owner_region = owner[top:bottom, left:right]
        owner_region[nearer] = owner_index
        coverage_count[top:bottom, left:right] += 1
        source_records.append(
            {
                "item_id": item["id"],
                "item_sha256": item["item_sha256"],
                "result_digest": result["result_digest"],
                "map_crop_sha256": crop_sha,
                "map_crop_bytes": crop_bytes,
                "origin": {"x": origin_x, "y": origin_y},
                "owned_pixel_count": 0,
            }
        )
    uncovered = int(np.count_nonzero(owner < 0))
    if uncovered:
        raise osrsPipelineError(
            f"screenshot transform has {uncovered} uncovered pixels: {realm_id}@{zoom_key}"
        )
    for owner_index, source_record in enumerate(source_records):
        source_record["owned_pixel_count"] = int(np.count_nonzero(owner == owner_index))

    relative_path = Path("assets") / osrs_asset_stem(realm_id) / f"zoom-{zoom_key}.png"
    output_path = output_root / relative_path
    output_path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(canvas).save(
        output_path, format="PNG", optimize=False, compress_level=9
    )
    output_path.chmod(0o444)
    return {
        "realm_id": realm_id,
        "selector_index": first_item["selector_index"],
        "selector_name": first_item["surface"],
        "zoom_percent": osrs_normalize_zoom(zoom),
        "scale_pixels_per_map_unit": scale,
        "path": relative_path.as_posix(),
        "sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
        "bytes": output_path.stat().st_size,
        "mode": "0444",
        "width": output_width,
        "height": output_height,
        "source_capture_count": len(members),
        "overlap_pixel_count": int(np.count_nonzero(coverage_count > 1)),
        "maximum_source_coverage": int(coverage_count.max()),
        "uncovered_pixel_count": 0,
        "sources": source_records,
    }


def _osrs_remove_transform_temporary_root(path: Path) -> None:
    if not path.exists():
        return
    for member in path.rglob("*"):
        if member.is_file():
            member.chmod(0o600)
    shutil.rmtree(path)


def _osrs_png_dimensions(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise osrsPipelineError(f"map crop is not a PNG with an IHDR header: {path}")
    return (
        int.from_bytes(header[16:20], "big"),
        int.from_bytes(header[20:24], "big"),
    )


def _osrs_xy_mapping(value: Any, field: str) -> dict[str, float]:
    mapping = _osrs_mapping(value, field)
    return {
        "x": _osrs_finite_number(mapping.get("x"), f"{field}.x"),
        "y": _osrs_finite_number(mapping.get("y"), f"{field}.y"),
    }


def _osrs_bounds_mapping(value: Any, field: str) -> dict[str, float]:
    mapping = _osrs_mapping(value, field)
    bounds = {
        key: _osrs_finite_number(mapping.get(key), f"{field}.{key}")
        for key in ("min_x", "min_y", "max_x", "max_y")
    }
    if bounds["min_x"] > bounds["max_x"] or bounds["min_y"] > bounds["max_y"]:
        raise osrsPipelineError(f"{field} is inverted")
    return bounds


def _osrs_finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise osrsPipelineError(f"{field} must be numeric")
    number = float(value)
    if not math.isfinite(number):
        raise osrsPipelineError(f"{field} must be finite")
    return number


def _osrs_positive_number(value: Any, field: str) -> float:
    number = _osrs_finite_number(value, field)
    if number <= 0:
        raise osrsPipelineError(f"{field} must be positive")
    return number


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    profile_parser = subparsers.add_parser("profile")
    profile_parser.add_argument("--manifest", required=True, type=Path)
    profile_parser.add_argument("--output", required=True, type=Path)

    coverage_parser = subparsers.add_parser("coverage")
    coverage_parser.add_argument("--profile", required=True, type=Path)
    coverage_parser.add_argument("--accepted", action="append", default=[], type=Path)
    coverage_parser.add_argument("--journal-head", type=Path)
    coverage_parser.add_argument("--previous-coverage", type=Path)
    coverage_parser.add_argument("--output", required=True, type=Path)

    worklist_parser = subparsers.add_parser("worklist")
    worklist_parser.add_argument("--profile", required=True, type=Path)
    worklist_parser.add_argument("--coverage", required=True, type=Path)
    worklist_parser.add_argument("--output", required=True, type=Path)

    assemble_parser = subparsers.add_parser("assemble-release-inputs")
    assemble_parser.add_argument("--profile", required=True, type=Path)
    assemble_parser.add_argument("--coverage", required=True, type=Path)
    assemble_parser.add_argument("--manifest", type=Path)
    assemble_parser.add_argument("--output", required=True, type=Path)

    sandbox_coverage_parser = subparsers.add_parser("sandbox-coverage")
    sandbox_coverage_parser.add_argument("--queue", required=True, type=Path)
    sandbox_coverage_parser.add_argument(
        "--equivalent-queue", action="append", default=[], type=Path
    )
    sandbox_coverage_parser.add_argument("--carry-forward", type=Path)
    sandbox_coverage_parser.add_argument("--successor-queue", type=Path)
    sandbox_coverage_parser.add_argument("--result", action="append", default=[], type=Path)
    sandbox_coverage_parser.add_argument(
        "--result-directory", action="append", default=[], type=Path
    )
    sandbox_coverage_parser.add_argument("--output", required=True, type=Path)

    sandbox_worklist_parser = subparsers.add_parser("sandbox-worklist")
    sandbox_worklist_parser.add_argument("--queue", required=True, type=Path)
    sandbox_worklist_parser.add_argument("--coverage", required=True, type=Path)
    sandbox_worklist_parser.add_argument("--output", required=True, type=Path)

    sandbox_transform_parser = subparsers.add_parser("sandbox-transform")
    sandbox_transform_parser.add_argument("--queue", required=True, type=Path)
    sandbox_transform_parser.add_argument("--coverage", required=True, type=Path)
    sandbox_transform_parser.add_argument("--output-root", required=True, type=Path)

    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "profile":
        manifest_bytes = args.manifest.read_bytes()
        profile = osrs_native_selector_profile(
            json.loads(manifest_bytes),
            source_manifest_sha256=osrs_sha256_bytes(manifest_bytes),
        )
        osrs_write_json(args.output, profile)
    elif args.command == "coverage":
        profile = _osrs_read_json(args.profile)
        accepted_paths = [str(path) for path in args.accepted]
        accepted = [_osrs_read_json(path) for path in args.accepted]
        previous = _osrs_read_json(args.previous_coverage) if args.previous_coverage else None
        journal_head = _osrs_read_json(args.journal_head) if args.journal_head else None
        coverage = osrs_reconcile_native_coverage(
            profile,
            accepted,
            previous_coverage=previous,
            journal_head=journal_head,
            source_paths=accepted_paths,
        )
        osrs_write_json(args.output, coverage)
    elif args.command == "worklist":
        worklist = osrs_build_native_worklist(
            _osrs_read_json(args.profile),
            _osrs_read_json(args.coverage),
        )
        osrs_write_json(args.output, worklist)
    elif args.command == "assemble-release-inputs":
        release_manifest = _osrs_read_json(args.manifest) if args.manifest else None
        assembly = osrs_assemble_native_release_inputs(
            _osrs_read_json(args.profile),
            _osrs_read_json(args.coverage),
            release_manifest=release_manifest,
        )
        osrs_write_json(args.output, assembly)
    elif args.command == "sandbox-coverage":
        queue = _osrs_read_json(args.queue)
        equivalent_queues = [_osrs_read_json(path) for path in args.equivalent_queue]
        carry_forward = _osrs_read_json(args.carry_forward) if args.carry_forward else None
        successor_queue = _osrs_read_json(args.successor_queue) if args.successor_queue else None
        accepted_generation_ids = _osrs_equivalent_sandbox_generation_ids(
            queue,
            equivalent_queues,
        )
        if carry_forward is not None:
            if successor_queue is None:
                raise osrsPipelineError(
                    "carry-forward reconciliation requires --successor-queue"
                )
            _, successor_generation_id = _osrs_validate_native_carry_forward(
                queue,
                carry_forward,
                successor_queue,
                verify_files=True,
            )
            accepted_generation_ids.add(successor_generation_id)
        elif successor_queue is not None:
            raise osrsPipelineError("--successor-queue requires --carry-forward")
        result_paths = list(args.result)
        for directory in args.result_directory:
            result_paths.extend(
                _osrs_sandbox_result_paths(
                    directory,
                    queue,
                    accepted_generation_ids=accepted_generation_ids,
                )
            )
        result_paths = sorted(set(result_paths), key=lambda path: str(path))
        coverage = osrs_reconcile_native_sandbox_coverage(
            queue,
            [_osrs_read_json(path) for path in result_paths],
            equivalent_queues=equivalent_queues,
            carry_forward=carry_forward,
            successor_queue=successor_queue,
            source_paths=[str(path) for path in result_paths],
        )
        osrs_write_json(args.output, coverage)
    elif args.command == "sandbox-worklist":
        worklist = osrs_build_native_sandbox_worklist(
            _osrs_read_json(args.queue),
            _osrs_read_json(args.coverage),
        )
        osrs_write_json(args.output, worklist)
    elif args.command == "sandbox-transform":
        osrs_transform_native_sandbox_crops(
            _osrs_read_json(args.queue),
            _osrs_read_json(args.coverage),
            args.output_root,
        )
    return 0


def _osrs_release_realms(release_manifest: Mapping[str, Any]) -> Sequence[Mapping[str, Any]]:
    realms = release_manifest.get("realms")
    if not isinstance(realms, list):
        raise osrsPipelineError("release manifest realms must be an array")
    return [_osrs_mapping(record, "realms[]") for record in realms]


def _osrs_normalize_zoom_row(value: Mapping[str, Any]) -> dict[str, Any]:
    zoom_percent = osrs_normalize_zoom(value.get("zoom_percent"))
    criterion_family = _osrs_nonempty_str(
        value.get("criterion_family"), "coverage_zooms.criterion_family"
    )
    return {"zoom_percent": zoom_percent, "criterion_family": criterion_family}


def _osrs_profile_entries(profile: Mapping[str, Any]) -> Sequence[Mapping[str, Any]]:
    entries = profile.get("entries")
    if not isinstance(entries, list):
        raise osrsPipelineError("native selector profile entries must be an array")
    return [_osrs_mapping(entry, "profile.entries[]") for entry in entries]


def _osrs_profile_zoom_rows(profile: Mapping[str, Any]) -> tuple[dict[str, Any], ...]:
    rows = _osrs_nested(profile, "coverage_contract", "zoom_profile")
    if not isinstance(rows, list) or not rows:
        raise osrsPipelineError("native selector profile has no zoom profile")
    return tuple(_osrs_normalize_zoom_row(_osrs_mapping(row, "zoom_profile[]")) for row in rows)


def _osrs_profile_zoom_by_value(profile: Mapping[str, Any], zoom: int | float) -> dict[str, Any]:
    key = osrs_zoom_key(zoom)
    for row in _osrs_profile_zoom_rows(profile):
        if osrs_zoom_key(row["zoom_percent"]) == key:
            return row
    raise osrsPipelineError(f"accepted zoom is outside native production profile: {zoom}")


def _osrs_profile_digest(profile: Mapping[str, Any]) -> str:
    value = str(profile.get("profile_sha256", "")).strip()
    if not re.fullmatch(r"[a-f0-9]{64}", value):
        raise osrsPipelineError("native selector profile has no canonical profile_sha256")
    return value


def _osrs_assert_matching_profile(value: Mapping[str, Any], profile_sha: str) -> None:
    if value.get("profile_sha256") != profile_sha:
        raise osrsPipelineError("coverage/worklist input does not match native selector profile")


def _osrs_profile_entry_for_selector(
    profile: Mapping[str, Any], selector_name: str
) -> Mapping[str, Any]:
    matches = [
        entry
        for entry in _osrs_profile_entries(profile)
        if str(entry.get("selector_name", "")).casefold() == selector_name.casefold()
    ]
    if len(matches) != 1:
        raise osrsPipelineError(
            f"accepted selector name is not a unique native production realm: {selector_name!r}"
        )
    return matches[0]


def _osrs_coverage_rows(coverage_ledger: Mapping[str, Any]) -> Sequence[Mapping[str, Any]]:
    if coverage_ledger.get("contract") != OSRS_NATIVE_COVERAGE_CONTRACT:
        raise osrsPipelineError("coverage ledger contract mismatch")
    rows = coverage_ledger.get("coverage")
    if not isinstance(rows, list):
        raise osrsPipelineError("coverage ledger coverage must be an array")
    return [_osrs_mapping(row, "coverage[]") for row in rows]


def _osrs_verified_envelope(value: Mapping[str, Any]) -> Mapping[str, Any]:
    envelope = value.get("verified_accepted_envelope")
    if envelope is None:
        envelope = value.get("accepted_envelope")
    if envelope is None and value.get("protocol") == OSRS_CAPTURE_BROKER_PROTOCOL:
        envelope = value
    if not isinstance(envelope, Mapping):
        raise osrsPipelineError("accepted record lacks a verified broker envelope")
    return envelope


def _osrs_consistent_identity(field: str, *values: Any) -> osrsJournalIdentity:
    identities: list[osrsJournalIdentity] = []
    for index, value in enumerate(values):
        if value is None:
            continue
        if not isinstance(value, Mapping):
            raise osrsPipelineError(f"{field} candidate {index} is not an object")
        identities.append(osrsJournalIdentity.from_mapping(value, f"{field}[{index}]"))
    if not identities:
        raise osrsPipelineError(f"{field} is missing")
    first = identities[0]
    for identity in identities[1:]:
        if identity != first:
            raise osrsPipelineError(
                f"{field} identities diverge: {first.to_json()} != {identity.to_json()}"
            )
    return first


def _osrs_index_coverage_rows(
    profile: Mapping[str, Any], coverage_ledger: Mapping[str, Any]
) -> dict[tuple[str, str], Mapping[str, Any]]:
    valid_keys = _osrs_expected_coverage_keys(profile)
    result: dict[tuple[str, str], Mapping[str, Any]] = {}
    for row in _osrs_coverage_rows(coverage_ledger):
        key = (str(row.get("realm_id")), osrs_zoom_key(row.get("zoom_percent")))
        if key not in valid_keys:
            raise osrsPipelineError(f"coverage row is outside native profile: {key}")
        if key in result:
            raise osrsPipelineError(f"duplicate coverage row for native profile key: {key}")
        result[key] = row
    return result


def _osrs_expected_coverage_keys(profile: Mapping[str, Any]) -> set[tuple[str, str]]:
    return {
        (str(entry["realm_id"]), osrs_zoom_key(zoom_row["zoom_percent"]))
        for entry in _osrs_profile_entries(profile)
        for zoom_row in _osrs_profile_zoom_rows(profile)
    }


def _osrs_consistent_hex(field: str, *values: Any) -> str:
    candidates = [str(value).strip() for value in values if value is not None]
    if not candidates:
        raise osrsPipelineError(f"{field} is missing")
    first = candidates[0]
    if not re.fullmatch(r"[a-f0-9]{64}", first):
        raise osrsPipelineError(f"{field} is not a 64-character lowercase sha256-like key")
    if any(candidate != first for candidate in candidates[1:]):
        raise osrsPipelineError(f"{field} values diverge")
    return first


def _osrs_optional_consistent_hex(field: str, *values: Any) -> str | None:
    candidates = [value for value in values if value is not None]
    if not candidates:
        return None
    return _osrs_consistent_hex(field, *candidates)


def _osrs_capture_metadata(
    envelope: Mapping[str, Any], top_level: Mapping[str, Any]
) -> Mapping[str, Any]:
    candidates: list[Mapping[str, Any]] = []
    for raw in (
        _osrs_nested(envelope, "commit", "request", "metadata"),
        _osrs_nested(envelope, "commit", "metadata"),
        _osrs_nested(envelope, "commit", "request"),
        top_level.get("last_commit"),
    ):
        if isinstance(raw, Mapping):
            candidates.append(raw)
    merged: dict[str, Any] = {}
    for candidate in reversed(candidates):
        merged.update(candidate)
    if "surface" not in merged:
        raise osrsPipelineError("accepted envelope does not name a captured surface")
    return merged


def _osrs_capture_criterion(
    metadata: Mapping[str, Any], selector_name: str, zoom_percent: int | float
) -> str:
    raw = metadata.get("criterion_family")
    if raw is None:
        key = metadata.get("criterion_family_key")
        if isinstance(key, str):
            parts = key.split("|")
            if len(parts) == 3:
                if (
                    parts[0] != selector_name
                    or osrs_zoom_key(osrs_normalize_zoom(parts[1]))
                    != osrs_zoom_key(zoom_percent)
                ):
                    raise osrsPipelineError("criterion_family_key does not match capture surface/zoom")
                raw = parts[2]
    return _osrs_nonempty_str(raw, "criterion_family")


def _osrs_add_capture(
    capture: osrsAcceptedCapture,
    *,
    dedupe_by_key: MutableMapping[str, osrsAcceptedCapture],
    captures_by_work_key: MutableMapping[tuple[str, str], osrsAcceptedCapture],
    accepted: list[osrsAcceptedCapture],
    enforce_lineage: bool,
) -> None:
    existing_work = captures_by_work_key.get(capture.work_key)
    if existing_work is not None:
        if _osrs_capture_identity(existing_work) == _osrs_capture_identity(capture):
            return
        raise osrsPipelineError(
            "coverage overlap for realm/zoom: "
            f"{capture.realm_id} z{osrs_zoom_key(capture.zoom_percent)}"
        )
    if enforce_lineage and capture.head.sequence != capture.predecessor.sequence + 1:
        raise osrsPipelineError("accepted capture does not advance by one journal sequence")
    dedupe_by_key[capture.idempotency_key] = capture
    captures_by_work_key[capture.work_key] = capture
    accepted.append(capture)


def _osrs_capture_identity(capture: osrsAcceptedCapture) -> tuple[Any, ...]:
    return (
        capture.idempotency_key,
        capture.predecessor,
        capture.head,
        capture.work_key,
        capture.request_fingerprint,
    )


def _osrs_capture_from_ledger(value: Any) -> osrsAcceptedCapture:
    item = _osrs_mapping(value, "accepted_captures[]")
    return osrsAcceptedCapture(
        source_path=item.get("source_path"),
        idempotency_key=_osrs_consistent_hex("idempotency_key", item.get("idempotency_key")),
        request_fingerprint=_osrs_optional_consistent_hex(
            "request_fingerprint", item.get("request_fingerprint")
        ),
        predecessor=osrsJournalIdentity.from_mapping(
            _osrs_mapping(item.get("predecessor"), "predecessor"), "predecessor"
        ),
        head=osrsJournalIdentity.from_mapping(_osrs_mapping(item.get("head"), "head"), "head"),
        realm_id=_osrs_nonempty_str(item.get("realm_id"), "realm_id"),
        selector_name=_osrs_nonempty_str(item.get("selector_name"), "selector_name"),
        zoom_percent=osrs_normalize_zoom(item.get("zoom_percent")),
        criterion_family=_osrs_nonempty_str(item.get("criterion_family"), "criterion_family"),
        map_crop=_osrs_optional_mapping(item.get("map_crop"), "map_crop"),
    )


def _osrs_nested(value: Any, *keys: str) -> Any:
    current = value
    for key in keys:
        if not isinstance(current, Mapping):
            return None
        current = current.get(key)
    return current


def _osrs_mapping(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise osrsPipelineError(f"{field} must be an object")
    return value


def _osrs_optional_mapping(value: Any, field: str) -> Mapping[str, Any] | None:
    if value is None:
        return None
    return _osrs_mapping(value, field)


def _osrs_nonempty_str(value: Any, field: str) -> str:
    text = str(value if value is not None else "").strip()
    if not text:
        raise osrsPipelineError(f"{field} must be a non-empty string")
    return text


def _osrs_string_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise osrsPipelineError(f"{field} must be a string array")
    return sorted(value, key=lambda item: (item.casefold(), item))


def _osrs_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise osrsPipelineError(f"{field} must be an integer")
    return value


def _osrs_read_json(path: Path | None) -> Any:
    if path is None:
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _osrs_sandbox_result_paths(
    directory: Path,
    queue: Mapping[str, Any],
    *,
    accepted_generation_ids: set[str] | None = None,
) -> list[Path]:
    if not directory.is_absolute() or not directory.is_dir():
        raise osrsPipelineError(
            f"sandbox result directory is not an existing absolute directory: {directory}"
        )
    generation_id = _osrs_nonempty_str(queue.get("generation_id"), "queue.generation_id")
    allowed_generations = accepted_generation_ids or {generation_id}
    valid_ids = {str(item["id"]) for item in _osrs_validate_native_sandbox_queue(queue)}
    matches: list[Path] = []
    for path in sorted(directory.rglob("*.json")):
        try:
            value = _osrs_read_json(path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(value, Mapping):
            continue
        if value.get("generation_id") not in allowed_generations:
            continue
        if value.get("item_id") not in valid_ids:
            continue
        if value.get("result_digest") is None:
            continue
        matches.append(path)
    return matches


def _osrs_validate_native_carry_forward(
    queue: Mapping[str, Any],
    carry: Mapping[str, Any],
    successor_queue: Mapping[str, Any],
    *,
    verify_files: bool,
) -> tuple[dict[str, osrsSandboxCapture], str]:
    queue_items = _osrs_validate_native_sandbox_queue(queue)
    queue_by_id = {str(item["id"]): item for item in queue_items}
    if (
        successor_queue.get("schema_version") != 2
        or successor_queue.get("execution_profile") != OSRS_SEMANTIC_CAPTURE_PROFILE
    ):
        raise osrsPipelineError("native carry-forward successor queue profile mismatch")
    raw_successor_items = successor_queue.get("items")
    if not isinstance(raw_successor_items, list) or not raw_successor_items:
        raise osrsPipelineError("native carry-forward successor queue is empty")
    successor_items: list[Mapping[str, Any]] = []
    successor_ids: set[str] = set()
    full_positions = {str(item["id"]): index for index, item in enumerate(queue_items)}
    previous_position = -1
    for raw_item in raw_successor_items:
        item = _osrs_mapping(raw_item, "successor_queue.items[]")
        item_id = _osrs_nonempty_str(item.get("id"), "successor_queue.items[].id")
        full_item = queue_by_id.get(item_id)
        position = full_positions.get(item_id)
        if (
            full_item is None
            or position is None
            or position <= previous_position
            or item_id in successor_ids
            or osrs_canonical_json_bytes(item) != osrs_canonical_json_bytes(full_item)
        ):
            raise osrsPipelineError(
                f"native carry-forward successor item diverges: {item_id}"
            )
        successor_items.append(item)
        successor_ids.add(item_id)
        previous_position = position
    successor_generation_id = _osrs_nonempty_str(
        successor_queue.get("generation_id"), "successor_queue.generation_id"
    )
    supported_carry_profiles = {
        "native-realm-v10-v11-v12-to-v12-exact-identity-v3",
        "native-realm-v10-v11-v12-v13-to-v13-exact-identity-v4",
    }
    if (
        carry.get("schema_version") != 1
        or carry.get("carry_profile") not in supported_carry_profiles
    ):
        raise osrsPipelineError("native carry-forward profile mismatch")
    if carry.get("full_queue_generation_id") != queue.get("generation_id"):
        raise osrsPipelineError("native carry-forward full queue generation mismatch")
    if carry.get("successor_generation_id") != successor_generation_id:
        raise osrsPipelineError("native carry-forward successor generation mismatch")
    if carry.get("full_queue_policy_digest") != queue.get("policy_digest"):
        raise osrsPipelineError("native carry-forward full queue policy mismatch")
    if carry.get("successor_queue_policy_digest") != successor_queue.get("policy_digest"):
        raise osrsPipelineError("native carry-forward successor policy mismatch")

    raw_carried = carry.get("carried")
    raw_pending = carry.get("pending")
    raw_rejected = carry.get("rejected")
    if not isinstance(raw_carried, list):
        raise osrsPipelineError("native carry-forward carried partition must be an array")
    if raw_pending is not None and not isinstance(raw_pending, list):
        raise osrsPipelineError("native carry-forward pending partition must be an array")
    if not isinstance(raw_rejected, list):
        raise osrsPipelineError("native carry-forward rejected evidence must be an array")
    if (
        carry.get("expected_item_count") != len(queue_items)
        or carry.get("carried_item_count") != len(raw_carried)
        or carry.get("pending_item_count") != len(successor_items)
        or carry.get("rejected_acceptance_count") != len(raw_rejected)
        or len(raw_carried) + len(successor_items) != len(queue_items)
    ):
        raise osrsPipelineError("native carry-forward counts diverge")
    if raw_pending is not None and [osrs_canonical_json_bytes(item) for item in raw_pending] != [
        osrs_canonical_json_bytes(item) for item in successor_items
    ]:
        raise osrsPipelineError("native carry-forward pending partition diverges")

    carried_by_id: dict[str, osrsSandboxCapture] = {}
    for raw_entry in raw_carried:
        entry = _osrs_mapping(raw_entry, "carry_forward.carried[]")
        target_item_id = _osrs_nonempty_str(
            entry.get("target_item_id"), "carry_forward.target_item_id"
        )
        target_item = queue_by_id.get(target_item_id)
        if target_item is None or target_item_id in carried_by_id:
            raise osrsPipelineError(
                f"native carry-forward target identity invalid: {target_item_id}"
            )
        if entry.get("target_item_sha256") != target_item.get("item_sha256"):
            raise osrsPipelineError(
                f"native carry-forward target digest mismatch: {target_item_id}"
            )
        carried_by_id[target_item_id] = _osrs_parse_native_carried_capture(
            entry,
            target_item,
            verify_files=verify_files,
        )

    expected_carried_ids = set(queue_by_id) - {
        str(item["id"]) for item in successor_items
    }
    if set(carried_by_id) != expected_carried_ids:
        raise osrsPipelineError("native carry-forward carried partition diverges")
    return carried_by_id, successor_generation_id


def _osrs_parse_native_carried_capture(
    entry: Mapping[str, Any],
    target_item: Mapping[str, Any],
    *,
    verify_files: bool,
) -> osrsSandboxCapture:
    item_id = str(target_item["id"])
    source_result_path = Path(
        _osrs_nonempty_str(entry.get("source_result_path"), "source_result_path")
    )
    if not verify_files:
        raise osrsPipelineError("native carry-forward requires immutable file verification")
    source_sha256, source_bytes = _osrs_verify_immutable_file(
        source_result_path,
        _osrs_consistent_hex(
            "source_result_file_sha256", entry.get("source_result_file_sha256")
        ),
        None,
        "carried source result",
    )
    try:
        source_result = json.loads(source_result_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise osrsPipelineError(
            f"carried source result is not JSON: {source_result_path}"
        ) from error
    source_result_digest = _osrs_consistent_hex(
        "source_result_digest",
        entry.get("source_result_digest"),
        source_result.get("result_digest"),
    )
    without_digest = dict(source_result)
    without_digest.pop("result_digest", None)
    if osrs_sha256_bytes(osrs_adapter_canonical_json_bytes(without_digest)) != source_result_digest:
        raise osrsPipelineError(f"carried source result digest mismatch: {item_id}")
    for field in ("source_generation_id", "source_item_id", "source_item_sha256"):
        result_field = field.removeprefix("source_")
        if entry.get(field) != source_result.get(result_field):
            raise osrsPipelineError(f"native carry-forward {field} mismatch: {item_id}")

    source_commit_path = Path(
        _osrs_nonempty_str(entry.get("source_commit_path"), "source_commit_path")
    )
    source_commit_sha256, _ = _osrs_verify_immutable_file(
        source_commit_path,
        _osrs_consistent_hex("source_commit_sha256", entry.get("source_commit_sha256")),
        None,
        "carried broker commit",
    )
    source_commit = _osrs_read_json(source_commit_path)
    if (
        source_commit.get("schema_version") != 1
        or source_commit.get("sandbox_only") is not True
        or source_commit.get("sequence") != entry.get("source_commit_sequence")
        or source_commit.get("generation_id") != entry.get("source_generation_id")
        or source_commit.get("item_id") != entry.get("source_item_id")
        or source_commit.get("item_sha256") != entry.get("source_item_sha256")
        or source_commit.get("result_digest") != source_result_digest
        or source_commit.get("result_file_sha256") != source_sha256
        or source_commit.get("result_path") != str(source_result_path)
        or source_commit.get("broker_protocol", {}).get("protocol")
        != OSRS_CAPTURE_BROKER_PROTOCOL
    ):
        raise osrsPipelineError(f"native carry-forward broker binding mismatch: {item_id}")
    if source_commit_sha256 != entry.get("source_commit_sha256"):
        raise osrsPipelineError(f"native carry-forward broker digest mismatch: {item_id}")

    requested_work = _osrs_mapping(source_result.get("requested_work"), "requested_work")
    if osrs_canonical_json_bytes(requested_work) != osrs_canonical_json_bytes(
        entry.get("requested_work")
    ):
        raise osrsPipelineError(f"native carry-forward requested work mismatch: {item_id}")
    target_work = {
        key: target_item[key]
        for key in (
            "surface",
            "realm_id",
            "selector_index",
            "capture_center",
            "coverage_cell",
            "zoom_percent",
            "criterion_family",
            "restore_after_capture",
        )
    }
    source_work = {key: requested_work.get(key) for key in target_work}
    if osrs_canonical_json_bytes(source_work) != osrs_canonical_json_bytes(target_work):
        raise osrsPipelineError(f"native carry-forward work identity mismatch: {item_id}")

    map_crop = _osrs_mapping(source_result.get("map_crop"), "map_crop")
    if osrs_canonical_json_bytes(map_crop) != osrs_canonical_json_bytes(entry.get("map_crop")):
        raise osrsPipelineError(f"native carry-forward map crop mismatch: {item_id}")
    crop_path = Path(_osrs_nonempty_str(map_crop.get("path"), "map_crop.path"))
    crop_sha256 = _osrs_consistent_hex("map_crop.sha256", map_crop.get("sha256"))
    crop_bytes = _osrs_int(map_crop.get("bytes"), "map_crop.bytes")
    crop_width = _osrs_int(map_crop.get("width"), "map_crop.width")
    crop_height = _osrs_int(map_crop.get("height"), "map_crop.height")
    _osrs_verify_immutable_file(crop_path, crop_sha256, crop_bytes, "carried map crop")
    if _osrs_png_dimensions(crop_path) != (crop_width, crop_height):
        raise osrsPipelineError(f"native carry-forward crop dimensions diverge: {item_id}")

    capture_proofs = entry.get("capture_proofs")
    if not isinstance(capture_proofs, list) or [
        proof.get("role") for proof in capture_proofs if isinstance(proof, Mapping)
    ] != ["surface_ready", "coverage_target", "coverage_fresh"]:
        raise osrsPipelineError(f"native carry-forward capture proof roles diverge: {item_id}")
    proof_digests: set[str] = set()
    for raw_proof in capture_proofs:
        proof = _osrs_mapping(raw_proof, "capture_proofs[]")
        proof_path = Path(_osrs_nonempty_str(proof.get("path"), "capture_proof.path"))
        proof_sha = _osrs_consistent_hex("capture_proof.sha256", proof.get("sha256"))
        _osrs_verify_immutable_file(proof_path, proof_sha, None, "carried capture proof")
        if proof.get("observed_surface") != target_item["surface"]:
            raise osrsPipelineError(f"native carry-forward surface proof diverges: {item_id}")
        if (
            _osrs_finite_number(proof.get("normalized_correlation"), "normalized_correlation")
            < 0.72
            or _osrs_finite_number(
                proof.get("correlation_separation"), "correlation_separation"
            )
            < 0.08
            or proof_sha in proof_digests
        ):
            raise osrsPipelineError(f"native carry-forward capture proof failed: {item_id}")
        proof_digests.add(proof_sha)

    return osrsSandboxCapture(
        source_path=str(source_result_path),
        source_sha256=source_sha256,
        source_bytes=source_bytes,
        item_id=item_id,
        item_sha256=str(target_item["item_sha256"]),
        result_digest=source_result_digest,
        realm_id=str(target_item["realm_id"]),
        selector_name=str(target_item["surface"]),
        selector_index=int(target_item["selector_index"]),
        zoom_percent=osrs_normalize_zoom(target_item["zoom_percent"]),
        criterion_family=str(target_item["criterion_family"]),
        capture_center=dict(_osrs_mapping(target_item["capture_center"], "capture_center")),
        coverage_cell=dict(_osrs_mapping(target_item["coverage_cell"], "coverage_cell")),
        map_crop=dict(map_crop),
        completed_at=_osrs_nonempty_str(source_result.get("completed_at"), "completed_at"),
    )


def _osrs_equivalent_sandbox_generation_ids(
    queue: Mapping[str, Any],
    equivalent_queues: Sequence[Mapping[str, Any]],
) -> set[str]:
    primary_items = _osrs_validate_native_sandbox_queue(queue)
    primary_identity = [
        (str(item["id"]), str(item["item_sha256"])) for item in primary_items
    ]
    generation_ids = {
        _osrs_nonempty_str(queue.get("generation_id"), "queue.generation_id")
    }
    for candidate in equivalent_queues:
        candidate_items = _osrs_validate_native_sandbox_queue(candidate)
        candidate_identity = [
            (str(item["id"]), str(item["item_sha256"])) for item in candidate_items
        ]
        if candidate_identity != primary_identity:
            raise osrsPipelineError(
                "equivalent sandbox queue item identities diverge from primary queue"
            )
        generation_id = _osrs_nonempty_str(
            candidate.get("generation_id"), "equivalent_queue.generation_id"
        )
        if generation_id in generation_ids:
            raise osrsPipelineError(f"duplicate equivalent sandbox generation: {generation_id}")
        generation_ids.add(generation_id)
    return generation_ids


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except osrsPipelineError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
