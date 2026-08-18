import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from osrs_native_realm_downstream import (  # noqa: E402
    OSRS_CAPTURE_BROKER_PROTOCOL,
    OSRS_DEFAULT_ZOOM_PROFILE,
    osrs_adapter_canonical_json_bytes,
    osrs_assemble_native_release_inputs,
    osrs_build_native_sandbox_worklist,
    osrs_build_native_worklist,
    osrs_native_selector_profile,
    osrs_reconcile_native_sandbox_coverage,
    osrs_reconcile_native_coverage,
    osrs_transform_native_sandbox_crops,
    osrs_work_item_id,
    osrsPipelineError,
)
from osrs_non_surface_realms import (  # noqa: E402
    osrs_canonical_json_bytes,
    osrs_sha256_bytes,
)


def _realm(realm_id, name, group, index, *, assets=False):
    record = {
        "id": realm_id,
        "canonical_name": name,
        "aliases": [],
        "group": group,
        "is_surface": group == "surface",
        "native_file_id": index if group != "other_maps" else None,
        "map_id": index,
    }
    if assets:
        record["assets"] = [
            {
                "plane": 0,
                "mbtiles_path": f"assets/{realm_id}/plane-0.mbtiles",
                "mbtiles_sha256": f"{index % 16:x}" * 64,
                "mask_path": f"masks/{realm_id}/plane-0.png",
                "mask_sha256": f"{(index + 1) % 16:x}" * 64,
            }
        ]
    return record


def _manifest(*, assets=False):
    realms = [_realm("surface-gielinor", "Gielinor Surface", "surface", 0, assets=assets)]
    producer_only = {
        47: ("cache-world-map:ghorrock-prison", "Ghorrock Prison"),
        48: ("cache-world-map:tutorial-2", "Tutorial 2"),
        49: ("cache-world-map:lassar-undercity", "Lassar Undercity"),
    }
    realms.extend(
        _realm(
            producer_only.get(index, (f"cache-world-map:realm-{index:02d}", ""))[0],
            producer_only.get(index, ("", f"Realm {index:02d}"))[1],
            "realms",
            index,
            assets=assets,
        )
        for index in range(1, 50)
    )
    realms.extend(
        _realm(
            f"other-map-{10000 + index}",
            f"Other Map {index:04d}",
            "other_maps",
            10000 + index,
            assets=assets,
        )
        for index in range(1047)
    )
    return {"schema_version": 1, "candidate": "999", "realms": realms}


def _head(sequence, fill):
    return {"sequence": sequence, "commit_sha256": fill if len(fill) == 64 else fill * 64}


def _hex_key(seed):
    return f"{seed:064x}"


def _accepted(
    sequence,
    predecessor_fill,
    commit_fill,
    selector_name,
    zoom,
    criterion,
    *,
    idempotency_fill="a",
    fingerprint_fill="b",
):
    predecessor = _head(sequence - 1, predecessor_fill)
    commit_identity = _head(sequence, commit_fill)
    idempotency_key = (
        idempotency_fill if len(idempotency_fill) == 64 else idempotency_fill * 64
    )
    request_fingerprint = (
        fingerprint_fill if len(fingerprint_fill) == 64 else fingerprint_fill * 64
    )
    metadata = {
        "surface": selector_name,
        "true_zoom_percent": zoom,
        "criterion_family_key": f"{selector_name}|{zoom}|{criterion}",
        "map_crop": {
            "path": f"/immutable/crop-{sequence}.png",
            "sha256": "c" * 64,
            "bytes": 64,
        },
        "broker_protocol": {
            "protocol": OSRS_CAPTURE_BROKER_PROTOCOL,
            "idempotency_key": idempotency_key,
            "expected_predecessor": predecessor,
            "request_fingerprint": request_fingerprint,
        },
    }
    return {
        "schema_version": 1,
        "record_type": "EXPLORER_V4_ACCEPTED_COMMIT_TERMINAL_STATE",
        "immutable": True,
        "stable_idempotency_key": idempotency_key,
        "exact_commit_identity": {
            "sequence": sequence,
            "commit_sha256": commit_identity["commit_sha256"],
            "previous_commit_sha256": predecessor["commit_sha256"],
            "idempotency_key": idempotency_key,
            "request_fingerprint": request_fingerprint,
        },
        "accepted_head": commit_identity,
        "verified_accepted_envelope": {
            "protocol": OSRS_CAPTURE_BROKER_PROTOCOL,
            "ok": True,
            "idempotency_key": idempotency_key,
            "expected_predecessor": predecessor,
            "head": commit_identity,
            "metadata": metadata,
            "commit": {
                **commit_identity,
                "previous_commit_sha256": predecessor["commit_sha256"],
                "broker_protocol": metadata["broker_protocol"],
                "request": {"metadata": metadata},
            },
            "raw_broker_response": {
                "protocol": OSRS_CAPTURE_BROKER_PROTOCOL,
                "ok": True,
                "idempotency_key": idempotency_key,
                "request_fingerprint": request_fingerprint,
                "expected_predecessor": predecessor,
                "accepted_predecessor": predecessor,
                "commit": commit_identity,
            },
        },
    }


def _complete_coverage(profile):
    captures = []
    predecessor_fill = "0"
    for index, entry in enumerate(profile["entries"]):
        for zoom_index, zoom_row in enumerate(OSRS_DEFAULT_ZOOM_PROFILE):
            sequence = index * len(OSRS_DEFAULT_ZOOM_PROFILE) + zoom_index + 1
            commit_fill = _hex_key(sequence)
            captures.append(
                _accepted(
                    sequence,
                    predecessor_fill,
                    commit_fill,
                    entry["selector_name"],
                    zoom_row["zoom_percent"],
                    zoom_row["criterion_family"],
                    idempotency_fill=_hex_key(1000 + sequence),
                    fingerprint_fill=_hex_key(2000 + sequence),
                )
            )
            predecessor_fill = commit_fill
    return osrs_reconcile_native_coverage(
        profile,
        captures,
        journal_head=_head(len(captures), predecessor_fill),
    )


def _sandbox_queue():
    items = []
    for zoom_row in OSRS_DEFAULT_ZOOM_PROFILE:
        zoom = zoom_row["zoom_percent"]
        zoom_key = str(zoom).replace(".", "p")
        item = {
            "id": f"native-test-surface-gielinor-z{zoom_key}-r000-c000",
            "kind": "semantic_map_capture",
            "catalog_version": "native-selector-catalog-v3",
            "planner_version": "native-realm-coverage-planner-v11",
            "realm_id": "surface-gielinor",
            "selector_index": 0,
            "surface": "Gielinor Surface",
            "zoom_percent": zoom,
            "criterion_family": "center_detail",
            "restore_after_capture": False,
            "capture_center": {"x": 50, "y": 50},
            "coverage_cell": {
                "row": 0,
                "column": 0,
                "realm_bounds": {"min_x": 0, "min_y": 0, "max_x": 100, "max_y": 100},
                "capture_bounds": {"min_x": -5, "min_y": -5, "max_x": 105, "max_y": 105},
                "viewport": {
                    "width": 110,
                    "height": 110,
                    "zoom_percent": zoom,
                    "overlap_fraction": 0.2,
                },
                "coverage_plane": 0,
                "reset_center": {"x": 50, "y": 50},
            },
        }
        item["item_sha256"] = osrs_sha256_bytes(osrs_adapter_canonical_json_bytes(item))
        items.append(item)
    return {
        "schema_version": 2,
        "execution_profile": "semantic_map_capture_v1",
        "generation_id": "native-test-generation",
        "items": items,
    }


def _transform_queue():
    queue = _sandbox_queue()
    items = []
    for zoom_row in OSRS_DEFAULT_ZOOM_PROFILE:
        zoom = zoom_row["zoom_percent"]
        scale = zoom / 100
        zoom_key = str(zoom).replace(".", "p")
        for column, center_x in enumerate((5 / scale, 10 / scale)):
            item = {
                "id": f"native-transform-surface-gielinor-z{zoom_key}-r000-c00{column}",
                "kind": "semantic_map_capture",
                "catalog_version": "native-selector-catalog-v3",
                "planner_version": "native-realm-coverage-planner-v11",
                "realm_id": "surface-gielinor",
                "selector_index": 0,
                "surface": "Gielinor Surface",
                "zoom_percent": zoom,
                "criterion_family": "center_detail",
                "restore_after_capture": False,
                "capture_center": {"x": center_x, "y": 5 / scale},
                "coverage_cell": {
                    "row": 0,
                    "column": column,
                    "realm_bounds": {
                        "min_x": 0,
                        "min_y": 0,
                        "max_x": 15 / scale,
                        "max_y": 10 / scale,
                    },
                    "capture_bounds": {
                        "min_x": column * 5 / scale,
                        "min_y": 0,
                        "max_x": (column * 5 + 10) / scale,
                        "max_y": 10 / scale,
                    },
                    "viewport": {
                        "width": 10 / scale,
                        "height": 10 / scale,
                        "zoom_percent": zoom,
                        "overlap_fraction": 0.5,
                    },
                    "coverage_plane": 0,
                    "reset_center": {"x": center_x, "y": 5 / scale},
                },
            }
            item["item_sha256"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(item)
            )
            items.append(item)
    queue["items"] = items
    return queue


def _fake_png(width=10, height=10):
    return (
        b"\x89PNG\r\n\x1a\n"
        + (13).to_bytes(4, "big")
        + b"IHDR"
        + width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + b"\x08\x06\x00\x00\x00"
    )


def _sandbox_result(item, crop_path, generation_id="native-test-generation"):
    crop_bytes = crop_path.read_bytes()
    result = {
        "schema_version": 2,
        "execution_profile": "semantic_map_capture_v1",
        "generation_id": generation_id,
        "item_id": item["id"],
        "item_sha256": item["item_sha256"],
        "target_identity": {"bundle_identifier": "com.jagex.osclient"},
        "requested_work": {
            key: copy.deepcopy(item[key])
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
        },
        "surface_proof": {
            "ready_gate": {
                "passed": True,
                "requested_surface": item["surface"],
                "observed_surface": item["surface"],
                "nonblack": True,
            }
        },
        "zoom_proof": {
            "requested_zoom_percent": item["zoom_percent"],
            "observed_zoom_percent": item["zoom_percent"],
        },
        "coverage_navigation": {
            "source_center": copy.deepcopy(item["coverage_cell"]["reset_center"]),
            "target_center": copy.deepcopy(item["capture_center"]),
            "target_cell": {
                "row": item["coverage_cell"]["row"],
                "column": item["coverage_cell"]["column"],
            },
            "reference_delta": {"dx": 0, "dy": 0},
            "delivered_reference_delta": {"dx": 0, "dy": 0},
            "target_tolerance_reference_pixels": 10,
            "movement": {"action_count": 0, "transitions": []},
        },
        "map_crop": {
            "path": str(crop_path),
            "sha256": osrs_sha256_bytes(crop_bytes),
            "bytes": len(crop_bytes),
            "width": 10,
            "height": 10,
        },
        "performance": {
            "elapsed_milliseconds": 1000,
            "hard_deadline_milliseconds": 120000,
        },
        "evidence": [{"kind": "semantic_qualification"}],
        "completed_at": "2026-08-11T00:00:01Z",
    }
    result["result_digest"] = osrs_sha256_bytes(osrs_adapter_canonical_json_bytes(result))
    return result


class osrsNativeRealmDownstreamTests(unittest.TestCase):
    def test_adapter_canonical_json_matches_javascript_number_boundaries(self):
        self.assertEqual(
            b'{"large":100000000000000000000,"negativeZero":0,"small":0.0000625,'
            b'"smaller":1e-7,"threshold":0.000001,"veryLarge":1e+21}',
            osrs_adapter_canonical_json_bytes({
                "small": 6.25e-5,
                "threshold": 1e-6,
                "smaller": 1e-7,
                "large": 1e20,
                "veryLarge": 1e21,
                "negativeZero": -0.0,
            }),
        )

    def test_profile_projects_47_entries_and_excludes_non_selector_records(self):
        manifest = _manifest()
        before = osrs_canonical_json_bytes(manifest)
        profile = osrs_native_selector_profile(manifest)
        self.assertEqual(47, profile["projection"]["included_count"])
        self.assertEqual(1047, profile["projection"]["excluded_other_map_count"])
        self.assertEqual(1097, profile["source_manifest"]["full_record_count"])
        self.assertEqual(
            ["surface", "realms"], profile["projection"]["included_groups"]
        )
        self.assertEqual(
            ["other_maps"], profile["projection"]["excluded_groups"]
        )
        self.assertFalse(
            profile["normal_operation_dependencies"]["llm_or_openai_required"]
        )
        self.assertEqual(before, osrs_canonical_json_bytes(manifest))
        self.assertNotIn(
            "other-map-10000",
            [entry["realm_id"] for entry in profile["entries"]],
        )
        included_realm_ids = [entry["realm_id"] for entry in profile["entries"]]
        for realm_id in (
            "cache-world-map:ghorrock-prison",
            "cache-world-map:lassar-undercity",
            "cache-world-map:tutorial-2",
        ):
            self.assertNotIn(realm_id, included_realm_ids)
        self.assertEqual(
            [
                "cache-world-map:ghorrock-prison",
                "cache-world-map:lassar-undercity",
                "cache-world-map:tutorial-2",
            ],
            profile["projection"]["excluded_producer_only_realm_ids"],
        )

    def test_profile_fails_closed_when_other_map_count_drifts(self):
        manifest = _manifest()
        manifest["realms"].pop()
        with self.assertRaisesRegex(osrsPipelineError, "other_maps exclusion count"):
            osrs_native_selector_profile(manifest)

    def test_reconcile_validates_exact_lineage_and_duplicate_replay(self):
        profile = osrs_native_selector_profile(_manifest())
        first = _accepted(
            10,
            "0",
            "1",
            "Gielinor Surface",
            37.5,
            "eastward_topology",
        )
        coverage = osrs_reconcile_native_coverage(
            profile,
            [first, copy.deepcopy(first)],
            journal_head=_head(10, "1"),
        )
        self.assertEqual(1, coverage["lineage"]["accepted_commit_count"])
        self.assertEqual(1, coverage["lineage"]["duplicate_replay_count"])
        self.assertEqual(234, coverage["coverage_summary"]["missing_count"])
        self.assertEqual(
            "surface-gielinor",
            coverage["accepted_captures"][0]["realm_id"],
        )

    def test_reconcile_fails_on_journal_divergence_or_uncertain_acceptance(self):
        profile = osrs_native_selector_profile(_manifest())
        first = _accepted(10, "0", "1", "Gielinor Surface", 37.5, "eastward_topology")
        second = _accepted(
            11,
            "2",
            "3",
            "Realm 01",
            50,
            "southward_topology",
            idempotency_fill="d",
            fingerprint_fill="e",
        )
        with self.assertRaisesRegex(osrsPipelineError, "lineage diverged"):
            osrs_reconcile_native_coverage(profile, [first, second])
        uncertain = copy.deepcopy(first)
        uncertain["verified_accepted_envelope"]["raw_broker_response"]["ok"] = False
        with self.assertRaisesRegex(osrsPipelineError, "uncertain or rejected"):
            osrs_reconcile_native_coverage(profile, [uncertain])

    def test_reconcile_fails_on_overlapping_realm_zoom_capture(self):
        profile = osrs_native_selector_profile(_manifest())
        first = _accepted(10, "0", "1", "Gielinor Surface", 37.5, "eastward_topology")
        overlap = _accepted(
            11,
            "1",
            "2",
            "Gielinor Surface",
            37.5,
            "eastward_topology",
            idempotency_fill="d",
            fingerprint_fill="e",
        )
        with self.assertRaisesRegex(osrsPipelineError, "coverage overlap"):
            osrs_reconcile_native_coverage(profile, [first, overlap])

    def test_worklist_emits_stable_order_and_ids_for_gaps(self):
        profile = osrs_native_selector_profile(_manifest())
        first = _accepted(10, "0", "1", "Gielinor Surface", 37.5, "eastward_topology")
        coverage = osrs_reconcile_native_coverage(profile, [first])
        worklist = osrs_build_native_worklist(profile, coverage)
        self.assertEqual("WORK_REMAINING", worklist["status"])
        self.assertEqual(234, worklist["item_count"])
        self.assertEqual(
            osrs_work_item_id("surface-gielinor", 50),
            worklist["items"][0]["id"],
        )
        self.assertEqual("Gielinor Surface", worklist["items"][0]["surface"])
        self.assertEqual(50, worklist["items"][0]["zoom_percent"])
        self.assertEqual(
            osrs_canonical_json_bytes(worklist),
            osrs_canonical_json_bytes(osrs_build_native_worklist(profile, coverage)),
        )

    def test_restart_resume_keeps_prior_accepted_coverage(self):
        profile = osrs_native_selector_profile(_manifest())
        first = _accepted(10, "0", "1", "Gielinor Surface", 37.5, "eastward_topology")
        prior = osrs_reconcile_native_coverage(profile, [first])
        second = _accepted(
            11,
            "1",
            "2",
            "Realm 01",
            50,
            "southward_topology",
            idempotency_fill="d",
            fingerprint_fill="e",
        )
        resumed = osrs_reconcile_native_coverage(
            profile,
            [second],
            previous_coverage=prior,
            journal_head=_head(11, "2"),
        )
        self.assertEqual(2, resumed["coverage_summary"]["accepted_count"])
        self.assertEqual(_head(11, "2"), resumed["lineage"]["head"])

    def test_release_input_assembly_blocks_incomplete_and_missing_asset_transform(self):
        profile = osrs_native_selector_profile(_manifest())
        empty = osrs_reconcile_native_coverage(profile, [])
        incomplete = osrs_assemble_native_release_inputs(profile, empty)
        self.assertEqual("INCOMPLETE_NATIVE_COVERAGE", incomplete["status"])

        complete = _complete_coverage(profile)
        blocked = osrs_assemble_native_release_inputs(profile, complete)
        self.assertEqual("BLOCKED_RAW_SCREENSHOT_TRANSFORM_REQUIRED", blocked["status"])

        ready = osrs_assemble_native_release_inputs(
            profile,
            complete,
            release_manifest=_manifest(assets=True),
        )
        self.assertEqual("RELEASE_INPUTS_READY", ready["status"])
        self.assertEqual(47, len(ready["release_inputs"]))

    def test_release_input_assembly_blocks_zero_row_coverage_with_assets(self):
        profile = osrs_native_selector_profile(_manifest())
        zero_row_ledger = {
            "contract": profile["coverage_contract"]["contract"],
            "profile_id": profile["profile_id"],
            "profile_sha256": profile["profile_sha256"],
            "coverage": [],
        }

        result = osrs_assemble_native_release_inputs(
            profile,
            zero_row_ledger,
            release_manifest=_manifest(assets=True),
        )

        self.assertEqual("INCOMPLETE_NATIVE_COVERAGE", result["status"])
        self.assertEqual([], result["release_inputs"])
        self.assertEqual(235, result["blockers"][0]["missing_capture_count"])

    def test_release_input_assembly_blocks_partial_accepted_key_set_with_assets(self):
        profile = osrs_native_selector_profile(_manifest())
        partial_ledger = copy.deepcopy(_complete_coverage(profile))
        partial_ledger["coverage"] = partial_ledger["coverage"][:1]

        result = osrs_assemble_native_release_inputs(
            profile,
            partial_ledger,
            release_manifest=_manifest(assets=True),
        )

        self.assertEqual("INCOMPLETE_NATIVE_COVERAGE", result["status"])
        self.assertEqual([], result["release_inputs"])
        self.assertEqual(234, result["blockers"][0]["missing_capture_count"])

    def test_sandbox_coverage_binds_exact_position_and_immutable_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            crop_path = root / "map.png"
            crop_path.write_bytes(_fake_png())
            crop_path.chmod(0o444)
            queue = _sandbox_queue()
            result = _sandbox_result(queue["items"][0], crop_path)
            result_path = root / "result.json"
            result_path.write_bytes(osrs_canonical_json_bytes(result))
            result_path.chmod(0o444)

            coverage = osrs_reconcile_native_sandbox_coverage(
                queue,
                [result, copy.deepcopy(result)],
                source_paths=[str(result_path), str(result_path)],
            )

            self.assertEqual(1, coverage["coverage_summary"]["accepted_count"])
            self.assertEqual(4, coverage["coverage_summary"]["missing_count"])
            self.assertEqual(1, coverage["coverage_summary"]["duplicate_replay_count"])
            self.assertFalse(coverage["coverage_summary"]["complete"])
            self.assertFalse(coverage["canonical_export"]["attempted"])
            accepted = coverage["coverage"][0]["result"]
            self.assertEqual(result["result_digest"], accepted["result_digest"])
            self.assertEqual(
                osrs_sha256_bytes(result_path.read_bytes()), accepted["source_sha256"]
            )
            worklist = osrs_build_native_sandbox_worklist(queue, coverage)
            self.assertEqual("WORK_REMAINING", worklist["status"])
            self.assertEqual(4, worklist["item_count"])
            self.assertEqual(queue["items"][1]["id"], worklist["items"][0]["id"])

    def test_sandbox_coverage_rejects_position_drift_and_divergent_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            crop_path = Path(directory) / "map.png"
            crop_path.write_bytes(_fake_png())
            queue = _sandbox_queue()
            result = _sandbox_result(queue["items"][0], crop_path)

            drifted = copy.deepcopy(result)
            drifted["requested_work"]["capture_center"]["x"] = 51
            drifted_without_digest = copy.deepcopy(drifted)
            drifted_without_digest.pop("result_digest")
            drifted["result_digest"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(drifted_without_digest)
            )
            with self.assertRaisesRegex(osrsPipelineError, "requested work diverges"):
                osrs_reconcile_native_sandbox_coverage(
                    queue,
                    [drifted],
                    verify_files=False,
                )

            divergent = copy.deepcopy(result)
            divergent["completed_at"] = "2026-08-11T00:00:02Z"
            divergent_without_digest = copy.deepcopy(divergent)
            divergent_without_digest.pop("result_digest")
            divergent["result_digest"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(divergent_without_digest)
            )
            with self.assertRaisesRegex(osrsPipelineError, "replay diverged"):
                osrs_reconcile_native_sandbox_coverage(
                    queue,
                    [result, divergent],
                    verify_files=False,
                )

    def test_sandbox_coverage_rejects_noop_or_missing_production_movement_proof(self):
        queue = _sandbox_queue()
        item = copy.deepcopy(queue["items"][0])
        item["capture_center"] = {"x": 42, "y": 159.3333333333}
        item["coverage_cell"]["reset_center"] = {"x": 650, "y": 50}
        item["coverage_cell"]["realm_bounds"] = {
            "min_x": 0,
            "min_y": 0,
            "max_x": 1000,
            "max_y": 1000,
        }
        item["coverage_cell"]["capture_bounds"] = {
            "min_x": 0,
            "min_y": 0,
            "max_x": 1000,
            "max_y": 1000,
        }
        item_without_digest = copy.deepcopy(item)
        item_without_digest.pop("item_sha256")
        item["item_sha256"] = osrs_sha256_bytes(
            osrs_adapter_canonical_json_bytes(item_without_digest)
        )
        queue["items"][0] = item
        with tempfile.TemporaryDirectory() as directory:
            crop_path = Path(directory) / "map.png"
            crop_path.write_bytes(_fake_png())
            result = _sandbox_result(item, crop_path)
            result["coverage_navigation"].update({
                "reference_delta": {"dx": 228, "dy": 41},
                "delivered_reference_delta": {"dx": 228, "dy": 41},
                "movement": {
                    "action_count": 1,
                    "transitions": [{
                        "ordinal": 1,
                        "mean_abs_difference": 0.5,
                        "vector": {
                            "reference_delta": {"dx": 228, "dy": 41},
                            "reference": {
                                "from": {"x": 190, "y": 47},
                                "to": {"x": 418, "y": 88},
                            },
                        },
                    }],
                },
            })
            result_without_digest = copy.deepcopy(result)
            result_without_digest.pop("result_digest")
            result["result_digest"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(result_without_digest)
            )
            with self.assertRaisesRegex(osrsPipelineError, "movement was a no-op"):
                osrs_reconcile_native_sandbox_coverage(
                    queue,
                    [result],
                    verify_files=False,
                )

    def test_sandbox_coverage_binds_v14_movement_and_result_to_item_crop(self):
        queue = _sandbox_queue()
        for queued_item in queue["items"]:
            queued_item["planner_version"] = "native-realm-coverage-planner-v14"
            queued_without_digest = copy.deepcopy(queued_item)
            queued_without_digest.pop("item_sha256")
            queued_item["item_sha256"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(queued_without_digest)
            )
        item = copy.deepcopy(queue["items"][0])
        item["capture_center"] = {"x": 42, "y": 159.3333333333}
        item["coverage_cell"].update({
            "reset_center": {"x": 650, "y": 50},
            "realm_bounds": {"min_x": 0, "min_y": 0, "max_x": 1000, "max_y": 1000},
            "capture_bounds": {"min_x": 0, "min_y": 0, "max_x": 1000, "max_y": 1000},
            "coverage_crop": {"left": 178, "top": 70, "width": 338, "height": 550},
        })
        item_without_digest = copy.deepcopy(item)
        item_without_digest.pop("item_sha256")
        item["item_sha256"] = osrs_sha256_bytes(
            osrs_adapter_canonical_json_bytes(item_without_digest)
        )
        queue["items"][0] = item
        with tempfile.TemporaryDirectory() as directory:
            crop_path = Path(directory) / "map.png"
            crop_path.write_bytes(_fake_png(338, 550))
            result = _sandbox_result(item, crop_path)
            result["map_crop"].update({
                "source_crop": copy.deepcopy(item["coverage_cell"]["coverage_crop"]),
                "width": 338,
                "height": 550,
            })
            result["coverage_navigation"].update({
                "reference_delta": {"dx": 228, "dy": 41},
                "delivered_reference_delta": {"dx": 228, "dy": 41},
                "movement": {
                    "action_count": 1,
                    "transitions": [{
                        "ordinal": 1,
                        "mean_abs_difference": 3,
                        "vector": {
                            "reference_delta": {"dx": 228, "dy": 41},
                            "reference": {
                                "from": {"x": 190, "y": 82},
                                "to": {"x": 418, "y": 123},
                            },
                        },
                        "displacement_proof": {
                            "passed": True,
                            "evidence_mode": "native_crop_expected_neighborhood",
                            "expected_reference_delta": {"dx": 228, "dy": 41},
                            "delivered_reference_delta": {"dx": 228, "dy": 41},
                            "tolerance_reference_pixels": 10,
                            "mean_abs_difference": 3,
                            "aligned_mean_abs": 1,
                            "informative_coverage": 1,
                        },
                    }],
                },
            })
            result_without_digest = copy.deepcopy(result)
            result_without_digest.pop("result_digest")
            result["result_digest"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(result_without_digest)
            )

            coverage = osrs_reconcile_native_sandbox_coverage(
                queue, [result], verify_files=False
            )
            self.assertEqual(1, coverage["coverage_summary"]["accepted_count"])

            escaped = copy.deepcopy(result)
            escaped["coverage_navigation"]["movement"]["transitions"][0]["vector"][
                "reference"
            ] = {"from": {"x": 170, "y": 82}, "to": {"x": 398, "y": 123}}
            escaped_without_digest = copy.deepcopy(escaped)
            escaped_without_digest.pop("result_digest")
            escaped["result_digest"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(escaped_without_digest)
            )
            with self.assertRaisesRegex(osrsPipelineError, "escaped map crop"):
                osrs_reconcile_native_sandbox_coverage(
                    queue, [escaped], verify_files=False
                )

            mismatched_crop = copy.deepcopy(result)
            mismatched_crop["map_crop"]["source_crop"]["left"] += 1
            mismatched_without_digest = copy.deepcopy(mismatched_crop)
            mismatched_without_digest.pop("result_digest")
            mismatched_crop["result_digest"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(mismatched_without_digest)
            )
            with self.assertRaisesRegex(osrsPipelineError, "map crop geometry diverges"):
                osrs_reconcile_native_sandbox_coverage(
                    queue, [mismatched_crop], verify_files=False
                )

    def test_sandbox_coverage_cli_discovers_results_and_completes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = _sandbox_queue()
            queue_path = root / "queue.json"
            queue_path.write_bytes(osrs_canonical_json_bytes(queue))
            results_root = root / "results"
            results_root.mkdir()
            for index, item in enumerate(queue["items"]):
                crop_path = results_root / f"map-{index}.png"
                crop_path.write_bytes(_fake_png())
                crop_path.chmod(0o444)
                result = _sandbox_result(item, crop_path)
                result_path = results_root / f"result-{index}.json"
                result_path.write_bytes(osrs_canonical_json_bytes(result))
                result_path.chmod(0o444)
            coverage_path = root / "coverage.json"
            worklist_path = root / "worklist.json"
            from osrs_native_realm_downstream import main

            self.assertEqual(
                0,
                main(
                    [
                        "sandbox-coverage",
                        "--queue",
                        str(queue_path),
                        "--result-directory",
                        str(results_root),
                        "--output",
                        str(coverage_path),
                    ]
                ),
            )
            coverage = json.loads(coverage_path.read_text(encoding="utf-8"))
            self.assertTrue(coverage["coverage_summary"]["complete"])
            self.assertEqual(5, coverage["coverage_summary"]["accepted_count"])
            self.assertEqual(
                0,
                main(
                    [
                        "sandbox-worklist",
                        "--queue",
                        str(queue_path),
                        "--coverage",
                        str(coverage_path),
                        "--output",
                        str(worklist_path),
                    ]
                ),
            )
            worklist = json.loads(worklist_path.read_text(encoding="utf-8"))
            self.assertEqual("COMPLETE", worklist["status"])
            self.assertEqual(0, worklist["item_count"])

    def test_sandbox_coverage_combines_explicit_equivalent_restart_generations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = _sandbox_queue()
            successor = copy.deepcopy(queue)
            successor["generation_id"] = "native-test-successor"
            queue_path = root / "queue.json"
            successor_path = root / "successor.json"
            queue_path.write_bytes(osrs_canonical_json_bytes(queue))
            successor_path.write_bytes(osrs_canonical_json_bytes(successor))
            results_root = root / "results"
            results_root.mkdir()
            for index, item in enumerate(queue["items"]):
                crop_path = results_root / f"map-{index}.png"
                crop_path.write_bytes(_fake_png())
                crop_path.chmod(0o444)
                generation_id = (
                    queue["generation_id"] if index < 2 else successor["generation_id"]
                )
                result = _sandbox_result(item, crop_path, generation_id=generation_id)
                result_path = results_root / f"result-{index}.json"
                result_path.write_bytes(osrs_canonical_json_bytes(result))
                result_path.chmod(0o444)

            coverage_path = root / "coverage.json"
            from osrs_native_realm_downstream import main

            self.assertEqual(
                0,
                main(
                    [
                        "sandbox-coverage",
                        "--queue",
                        str(queue_path),
                        "--equivalent-queue",
                        str(successor_path),
                        "--result-directory",
                        str(results_root),
                        "--output",
                        str(coverage_path),
                    ]
                ),
            )
            coverage = json.loads(coverage_path.read_text(encoding="utf-8"))
            self.assertTrue(coverage["coverage_summary"]["complete"])
            self.assertEqual(
                ["native-test-generation", "native-test-successor"],
                coverage["accepted_generation_ids"],
            )

    def test_sandbox_coverage_rejects_divergent_equivalent_queue(self):
        queue = _sandbox_queue()
        successor = copy.deepcopy(queue)
        successor["generation_id"] = "native-test-successor"
        successor["items"][0]["capture_center"]["x"] = 51
        successor_item = successor["items"][0]
        successor_item_without_digest = dict(successor_item)
        successor_item_without_digest.pop("item_sha256")
        successor_item["item_sha256"] = osrs_sha256_bytes(
            osrs_adapter_canonical_json_bytes(successor_item_without_digest)
        )
        with self.assertRaisesRegex(
            osrsPipelineError,
            "equivalent sandbox queue item identities diverge",
        ):
            osrs_reconcile_native_sandbox_coverage(
                queue,
                [],
                equivalent_queues=[successor],
                verify_files=False,
            )

    def test_sandbox_coverage_combines_carried_and_successor_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = _sandbox_queue()
            carried_item = queue["items"][0]
            successor = copy.deepcopy(queue)
            successor["generation_id"] = "native-test-successor"
            successor["items"] = successor["items"][1:]

            carried_crop = root / "carried-map.png"
            carried_crop.write_bytes(_fake_png())
            carried_crop.chmod(0o444)
            source_item = copy.deepcopy(carried_item)
            source_item["id"] = "native-realm-production-v11-source-item"
            source_without_digest = copy.deepcopy(source_item)
            source_without_digest.pop("item_sha256")
            source_item["item_sha256"] = osrs_sha256_bytes(
                osrs_adapter_canonical_json_bytes(source_without_digest)
            )
            source_result = _sandbox_result(
                source_item,
                carried_crop,
                generation_id="native-test-source",
            )
            source_result_path = root / "carried-result.json"
            source_result_path.write_bytes(osrs_adapter_canonical_json_bytes(source_result))
            source_result_path.chmod(0o444)
            commit = {
                "schema_version": 1,
                "sandbox_only": True,
                "sequence": 10,
                "generation_id": source_result["generation_id"],
                "item_id": source_result["item_id"],
                "item_sha256": source_result["item_sha256"],
                "result_digest": source_result["result_digest"],
                "result_file_sha256": osrs_sha256_bytes(source_result_path.read_bytes()),
                "result_path": str(source_result_path),
                "broker_protocol": {"protocol": OSRS_CAPTURE_BROKER_PROTOCOL},
            }
            commit_path = root / "carried-commit.json"
            commit_path.write_bytes(osrs_adapter_canonical_json_bytes(commit))
            commit_path.chmod(0o444)
            proof_paths = []
            for index in range(3):
                proof_path = root / f"proof-{index}.png"
                proof_path.write_bytes(_fake_png(width=10 + index, height=10))
                proof_path.chmod(0o444)
                proof_paths.append(proof_path)
            carry = {
                "schema_version": 1,
                "carry_profile": "native-realm-v10-v11-v12-to-v12-exact-identity-v3",
                "full_queue_generation_id": queue["generation_id"],
                "full_queue_policy_digest": "full-policy",
                "successor_generation_id": successor["generation_id"],
                "successor_queue_policy_digest": "successor-policy",
                "expected_item_count": len(queue["items"]),
                "carried_item_count": 1,
                "pending_item_count": len(successor["items"]),
                "rejected_acceptance_count": 0,
                "rejected": [],
                "pending": copy.deepcopy(successor["items"]),
                "carried": [{
                    "target_item_id": carried_item["id"],
                    "target_item_sha256": carried_item["item_sha256"],
                    "source_commit_sequence": commit["sequence"],
                    "source_commit_path": str(commit_path),
                    "source_commit_sha256": osrs_sha256_bytes(commit_path.read_bytes()),
                    "source_generation_id": source_result["generation_id"],
                    "source_item_id": source_result["item_id"],
                    "source_item_sha256": source_result["item_sha256"],
                    "source_result_path": str(source_result_path),
                    "source_result_file_sha256": osrs_sha256_bytes(
                        source_result_path.read_bytes()
                    ),
                    "source_result_digest": source_result["result_digest"],
                    "requested_work": copy.deepcopy(source_result["requested_work"]),
                    "capture_proofs": [
                        {
                            "role": role,
                            "path": str(proof_path),
                            "sha256": osrs_sha256_bytes(proof_path.read_bytes()),
                            "observed_surface": carried_item["surface"],
                            "normalized_correlation": 0.9,
                            "correlation_separation": 0.2,
                        }
                        for role, proof_path in zip(
                            ("surface_ready", "coverage_target", "coverage_fresh"),
                            proof_paths,
                        )
                    ],
                    "map_crop": copy.deepcopy(source_result["map_crop"]),
                }],
            }
            queue["policy_digest"] = "full-policy"
            successor["policy_digest"] = "successor-policy"

            successor_results = []
            successor_result_paths = []
            for index, item in enumerate(successor["items"]):
                crop_path = root / f"successor-map-{index}.png"
                crop_path.write_bytes(_fake_png())
                crop_path.chmod(0o444)
                result = _sandbox_result(
                    item,
                    crop_path,
                    generation_id=successor["generation_id"],
                )
                result_path = root / f"successor-result-{index}.json"
                result_path.write_bytes(osrs_adapter_canonical_json_bytes(result))
                result_path.chmod(0o444)
                successor_results.append(result)
                successor_result_paths.append(str(result_path))

            coverage = osrs_reconcile_native_sandbox_coverage(
                queue,
                successor_results,
                carry_forward=carry,
                successor_queue=successor,
                source_paths=successor_result_paths,
            )

            self.assertTrue(coverage["coverage_summary"]["complete"])
            self.assertEqual(5, coverage["coverage_summary"]["accepted_count"])
            self.assertEqual(1, coverage["coverage_summary"]["carried_count"])
            self.assertEqual(
                source_result["result_digest"], coverage["coverage"][0]["result"]["result_digest"]
            )

            v13_carry = copy.deepcopy(carry)
            v13_carry["carry_profile"] = (
                "native-realm-v10-v11-v12-v13-to-v13-exact-identity-v4"
            )
            v13_coverage = osrs_reconcile_native_sandbox_coverage(
                queue,
                successor_results,
                carry_forward=v13_carry,
                successor_queue=successor,
                source_paths=successor_result_paths,
            )
            self.assertTrue(v13_coverage["coverage_summary"]["complete"])
            self.assertEqual(1, v13_coverage["coverage_summary"]["carried_count"])

            unknown_carry = copy.deepcopy(carry)
            unknown_carry["carry_profile"] = "native-realm-unreviewed-carry-v999"
            with self.assertRaisesRegex(osrsPipelineError, "carry-forward profile mismatch"):
                osrs_reconcile_native_sandbox_coverage(
                    queue,
                    [],
                    carry_forward=unknown_carry,
                    successor_queue=successor,
                )

            drifted = copy.deepcopy(carry)
            drifted["carried"][0]["map_crop"]["sha256"] = "f" * 64
            with self.assertRaisesRegex(osrsPipelineError, "map crop mismatch"):
                osrs_reconcile_native_sandbox_coverage(
                    queue,
                    [],
                    carry_forward=drifted,
                    successor_queue=successor,
                )

    def test_sandbox_transform_assembles_complete_reproducible_mosaics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = _transform_queue()
            results = []
            result_paths = []
            for index, item in enumerate(queue["items"]):
                crop_path = root / f"crop-{index}.png"
                color = (240, 20, 20, 255) if item["coverage_cell"]["column"] == 0 else (
                    20,
                    40,
                    240,
                    255,
                )
                Image.new("RGBA", (10, 10), color).save(
                    crop_path, format="PNG", optimize=False, compress_level=9
                )
                crop_path.chmod(0o444)
                result = _sandbox_result(item, crop_path)
                result_path = root / f"result-{index}.json"
                result_path.write_bytes(osrs_canonical_json_bytes(result))
                result_path.chmod(0o444)
                results.append(result)
                result_paths.append(str(result_path))
            coverage = osrs_reconcile_native_sandbox_coverage(
                queue,
                results,
                source_paths=result_paths,
            )

            first_root = root / "transform-a"
            second_root = root / "transform-b"
            first = osrs_transform_native_sandbox_crops(queue, coverage, first_root)
            second = osrs_transform_native_sandbox_crops(queue, coverage, second_root)

            self.assertEqual(first["transform_sha256"], second["transform_sha256"])
            self.assertEqual(5, first["summary"]["realm_zoom_asset_count"])
            self.assertEqual(10, first["summary"]["source_capture_count"])
            for asset in first["assets"]:
                self.assertEqual(15, asset["width"])
                self.assertEqual(10, asset["height"])
                self.assertEqual(50, asset["overlap_pixel_count"])
                self.assertEqual(0, asset["uncovered_pixel_count"])
                self.assertEqual("0444", asset["mode"])
                image = Image.open(first_root / asset["path"]).convert("RGBA")
                self.assertEqual((240, 20, 20, 255), image.getpixel((7, 5)))
                self.assertEqual((20, 40, 240, 255), image.getpixel((8, 5)))
                self.assertEqual(0, (first_root / asset["path"]).stat().st_mode & 0o222)

    def test_sandbox_transform_rejects_incomplete_coverage_or_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = _transform_queue()
            incomplete = osrs_reconcile_native_sandbox_coverage(queue, [])
            with self.assertRaisesRegex(osrsPipelineError, "requires complete"):
                osrs_transform_native_sandbox_crops(queue, incomplete, root / "incomplete")

            existing = root / "existing"
            existing.mkdir()
            incomplete["coverage_summary"]["complete"] = True
            without_digest = copy.deepcopy(incomplete)
            without_digest.pop("coverage_sha256")
            incomplete["coverage_sha256"] = osrs_sha256_bytes(
                osrs_canonical_json_bytes(without_digest)
            )
            with self.assertRaisesRegex(osrsPipelineError, "output already exists"):
                osrs_transform_native_sandbox_crops(queue, incomplete, existing)

    def test_cli_round_trip_is_reproducible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            profile_path = root / "profile.json"
            coverage_path = root / "coverage.json"
            worklist_path = root / "worklist.json"
            accepted_path = root / "accepted.json"
            manifest_path.write_bytes(osrs_canonical_json_bytes(_manifest()))
            accepted_path.write_bytes(
                osrs_canonical_json_bytes(
                    _accepted(10, "0", "1", "Gielinor Surface", 37.5, "eastward_topology")
                )
            )
            from osrs_native_realm_downstream import main

            self.assertEqual(
                0,
                main(["profile", "--manifest", str(manifest_path), "--output", str(profile_path)]),
            )
            self.assertEqual(
                0,
                main(
                    [
                        "coverage",
                        "--profile",
                        str(profile_path),
                        "--accepted",
                        str(accepted_path),
                        "--output",
                        str(coverage_path),
                    ]
                ),
            )
            self.assertEqual(
                0,
                main(
                    [
                        "worklist",
                        "--profile",
                        str(profile_path),
                        "--coverage",
                        str(coverage_path),
                        "--output",
                        str(worklist_path),
                    ]
                ),
            )
            first_profile = profile_path.read_bytes()
            first_worklist = worklist_path.read_bytes()
            self.assertEqual(
                0,
                main(["profile", "--manifest", str(manifest_path), "--output", str(profile_path)]),
            )
            self.assertEqual(
                0,
                main(
                    [
                        "worklist",
                        "--profile",
                        str(profile_path),
                        "--coverage",
                        str(coverage_path),
                        "--output",
                        str(worklist_path),
                    ]
                ),
            )
            self.assertEqual(first_profile, profile_path.read_bytes())
            self.assertEqual(first_worklist, worklist_path.read_bytes())
            json.loads(worklist_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
