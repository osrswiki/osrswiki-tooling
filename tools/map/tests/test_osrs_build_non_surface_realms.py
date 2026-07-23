import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

import numpy as np
from PIL import Image


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from build_osrs_non_surface_realms import osrs_build_release  # noqa: E402
from osrs_public_path_hygiene import (  # noqa: E402
    osrs_assert_public_json_portable,
    osrs_validate_public_release_tree,
)


def _osrs_write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")


def _osrs_piece(index, source, display):
    return {
        "piece_index": index,
        "normalized": {
            "source_bounds": {
                "min_x": source[0],
                "min_y": source[1],
                "max_x": source[2],
                "max_y": source[3],
                "plane_min": 0,
                "plane_max": 0,
            },
            "display_bounds": {
                "min_x": display[0],
                "min_y": display[1],
                "max_x": display[2],
                "max_y": display[3],
                "plane_min": 0,
                "plane_max": 0,
            },
        },
    }


def _osrs_definition(file_id, safe_name, name, is_surface, piece):
    return {
        "file_id": file_id,
        "safe_name": safe_name,
        "name": name,
        "is_surface": is_surface,
        "position": {"x": piece["normalized"]["source_bounds"]["min_x"], "y": 0, "plane": 0},
        "composite": {"present": True, "map_squares": [piece], "zones": []},
    }


class osrsReleasePathReproducibilityTests(unittest.TestCase):
    def test_distinct_output_directories_emit_byte_identical_manifests_and_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture"
            fixture.mkdir()
            source_dir = fixture / "source"
            provenance_dir = fixture / "provenance"
            source_dir.mkdir()
            provenance_dir.mkdir()

            source = Image.fromarray(
                np.array([[[10, 20, 30], [40, 50, 60]]], dtype=np.uint8)
            )
            source.save(source_dir / "img-0.png")
            source.save(provenance_dir / "img-0.png")
            Image.fromarray(np.array([[1, 2]], dtype=np.uint16)).save(
                provenance_dir / "img-0-provenance.png"
            )

            surface_piece = _osrs_piece(0, (0, 0, 1, 1), (0, 0, 1, 1))
            instance_piece = _osrs_piece(0, (1, 0, 2, 1), (10, 0, 11, 1))
            inventory = fixture / "inventory.json"
            _osrs_write_json(
                inventory,
                {
                    "definitions": [
                        _osrs_definition(0, "main", "Gielinor Surface", True, surface_piece),
                        _osrs_definition(36, "island", "Island Instance", False, instance_piece),
                    ]
                },
            )
            basemaps = fixture / "basemaps.json"
            _osrs_write_json(
                basemaps,
                [
                    {"mapId": 0, "name": "Gielinor Surface", "bounds": [[0, 0], [1, 1]], "center": [0, 0]},
                    {"mapId": 36, "name": "Island Instance", "bounds": [[1, 0], [2, 1]], "center": [1, 0]},
                ],
            )
            alignment = fixture / "alignment.json"
            _osrs_write_json(alignment, {"intermap_links": []})
            metadata = fixture / "metadata.json"
            _osrs_write_json(
                metadata,
                {
                    "gameBounds": {"minX": 0, "minY": 0, "maxX": 2, "maxY": 1},
                    "gameCoordScale": 1,
                    "sourceImage": {"width": 2, "height": 1},
                },
            )
            snapshots = fixture / "snapshots.json"
            _osrs_write_json(
                snapshots,
                {
                    "candidate": "001",
                    "cache": {
                        "cache_id": 123,
                        "cache_directory": str(fixture / "private-cache"),
                    },
                    "raster": {
                        "path": str(source_dir / "img-0.png"),
                        "metadata_path": str(metadata),
                        "game_bounds": {
                            "min_x": 0,
                            "min_y": 0,
                            "max_x": 2,
                            "max_y": 1,
                        },
                        "game_coord_scale": 1,
                        "width": 2,
                        "height": 1,
                    },
                    "repository": {"worktree": str(fixture)},
                },
            )
            ledger = {
                "schema_version": 1,
                "generator": "test fixture",
                "encoding": {"mode": "uint16_last_writer"},
                "image": {"rendered_plane": 0},
                "projection": {"game_coord_scale": 1},
                "statistics": {"cross_owner_overwrites": []},
                "invariants": {"fixture": True},
                "codebook": [
                    {
                        "code": 1,
                        "kind": "native_composite",
                        "realm_file_id": 0,
                        "source_region_id": None,
                        "source_plane": 0,
                        "source_to_display_dx": 0,
                        "source_to_display_dy": 0,
                    },
                    {
                        "code": 2,
                        "kind": "native_composite",
                        "realm_file_id": 36,
                        "source_region_id": None,
                        "source_plane": 0,
                        "source_to_display_dx": 9,
                        "source_to_display_dy": 0,
                    },
                ],
            }
            _osrs_write_json(provenance_dir / "img-0-provenance.json", ledger)

            helper = fixture / "accounting-helper.py"
            helper.write_text(
                """#!/usr/bin/env python3
import json
import sys
from pathlib import Path

output = Path(sys.argv[sys.argv.index('--output') + 1])
value = {
    'schema_version': 1,
    'width': 2,
    'height': 1,
    'source_pixels': 2,
    'content_bearing_pixels': 2,
    'exact_black_pixels': 0,
    'unresolved_content_bearing_pixels': 0,
    'legitimate_unowned_exact_black_pixels': 0,
    'owned_exact_black_pixels': 0,
    'background_predicate': 'r == 0 and g == 0 and b == 0',
    'near_black_tolerance': 0,
    'owner_counts': [
        {'code': 1, 'total_pixels': 1, 'content_bearing_pixels': 1, 'pixel_bounds': [0, 0, 1, 1]},
        {'code': 2, 'total_pixels': 1, 'content_bearing_pixels': 1, 'pixel_bounds': [1, 0, 2, 1]},
    ],
    'checks': {
        'category_sum_matches_source': True,
        'zero_unresolved_content_bearing_pixels': True,
        'release_ready': True,
    },
}
output.write_text(json.dumps(value, sort_keys=True), encoding='utf-8')
""",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            outputs = [Path(directory) / "release-one", Path(directory) / "release-two"]
            results = []
            for output in outputs:
                results.append(
                    osrs_build_release(
                        argparse.Namespace(
                            inventory=inventory,
                            basemaps=basemaps,
                            alignment=alignment,
                            source_metadata=metadata,
                            source_image_dir=source_dir,
                            provenance_dir=provenance_dir,
                            accounting_helper=helper,
                            source_snapshots=snapshots,
                            output=output,
                            candidate="001",
                            planes=(0,),
                            prior_manifest=None,
                            accounting_only=False,
                        )
                    )
                )

            compared_paths = (
                "underground-realms.json",
                "manifests/underground-realms.json",
                "reports/source-accounting.json",
                "reports/source-accounting-plane-0-command.json",
            )
            for relative in compared_paths:
                self.assertEqual(
                    (outputs[0] / relative).read_bytes(),
                    (outputs[1] / relative).read_bytes(),
                    relative,
                )
            for output in outputs:
                self.assertEqual(
                    (output / "underground-realms.json").read_bytes(),
                    (output / "manifests/underground-realms.json").read_bytes(),
                )
                manifest = json.loads((output / "underground-realms.json").read_text())
                accounting = json.loads(
                    (output / "reports/source-accounting.json").read_text()
                )
                command_report = json.loads(
                    (output / "reports/source-accounting-plane-0-command.json").read_text()
                )
                path_hygiene = json.loads(
                    (output / "reports/public-path-hygiene.json").read_text()
                )
                self.assertTrue(
                    path_hygiene["checks"]["zero_host_absolute_path_strings"]
                )
                self.assertTrue(
                    path_hygiene["checks"]["report_self_validation_passed"]
                )
                tree_report = osrs_validate_public_release_tree(output)
                self.assertEqual(
                    path_hygiene["scanned_artifact_count"],
                    tree_report["scanned_artifact_count"],
                )
                self.assertEqual(
                    path_hygiene["scanned_artifact_names_sha256"],
                    tree_report["scanned_artifact_names_sha256"],
                )
                osrs_assert_public_json_portable(manifest)
                snapshots_public = manifest["inputs"]["source_snapshots"]
                self.assertEqual("001", snapshots_public["candidate"])
                self.assertEqual(
                    {
                        "min_x": 0,
                        "min_y": 0,
                        "max_x": 2,
                        "max_y": 1,
                    },
                    snapshots_public["raster"]["game_bounds"],
                )
                self.assertEqual(1, snapshots_public["raster"]["game_coord_scale"])
                self.assertEqual(
                    "input://source-snapshot/cache/cache_directory",
                    snapshots_public["cache"]["cache_directory"],
                )
                self.assertEqual(
                    "input://source-snapshot/raster/path",
                    snapshots_public["raster"]["path"],
                )
                self.assertEqual(
                    "input://source-snapshot/repository/worktree",
                    snapshots_public["repository"]["worktree"],
                )
                asset_validation = json.loads(
                    (output / "reports/realm-asset-validation.json").read_text()
                )
                special_ownership = asset_validation[
                    "cache_special_region_ownership"
                ]
                self.assertEqual(
                    "one_backing_owner_per_used_cache_source_region",
                    special_ownership["identity_model"],
                )
                self.assertFalse(
                    special_ownership["wiki_bounds_used_for_pixel_ownership"]
                )
                self.assertTrue(
                    special_ownership["checks"]["no_cache_regions_coalesced"]
                )
                self.assertTrue(
                    asset_validation["checks"][
                        "special_region_ownership_exact_and_unmerged"
                    ]
                )
                streaming_path = "reports/source-accounting-plane-0-streaming.json"
                self.assertEqual(
                    streaming_path,
                    accounting["streaming_accounting"]["path"],
                )
                self.assertEqual(
                    streaming_path,
                    accounting["source"]["streaming_accounting_path"],
                )
                output_argument = command_report["command"].index("--output") + 1
                self.assertEqual(streaming_path, command_report["command"][output_argument])
                self.assertEqual(
                    "tool://osrs-source-accounting", command_report["command"][0]
                )
                self.assertEqual(
                    "input://renderer-provenance/plane-0/source-rgb.png",
                    command_report["command"][
                        command_report["command"].index("--source") + 1
                    ],
                )
                self.assertEqual(
                    "input://renderer-provenance/plane-0/owner-codes.png",
                    command_report["command"][
                        command_report["command"].index("--owners") + 1
                    ],
                )
                self.assertEqual(
                    streaming_path,
                    manifest["inputs"]["renderer_provenance_by_rendered_plane"]["0"][
                        "streaming_accounting_path"
                    ],
                )
                for realm in manifest["realms"]:
                    self.assertEqual(
                        streaming_path,
                        realm["source_revisions"][
                            "renderer_provenance_by_rendered_plane"
                        ]["0"]["streaming_accounting_path"],
                    )
                    for asset in realm["assets"]:
                        self.assertFalse(PurePosixPath(asset["mbtiles_path"]).is_absolute())
                        self.assertEqual("assets", PurePosixPath(asset["mbtiles_path"]).parts[0])
                        self.assertFalse(PurePosixPath(asset["mask_path"]).is_absolute())
                        self.assertEqual("masks", PurePosixPath(asset["mask_path"]).parts[0])
            self.assertEqual(
                {
                    "manifest_path": "underground-realms.json",
                    "evidence_manifest_path": "manifests/underground-realms.json",
                    "schema_path": "manifests/underground-realms.schema.json",
                    "accounting_path": "reports/source-accounting.json",
                    "asset_validation_path": "reports/realm-asset-validation.json",
                    "release_diff_path": "manifests/release-diff.json",
                    "path_hygiene_path": "reports/public-path-hygiene.json",
                },
                {
                    key: results[0][key]
                    for key in (
                        "manifest_path",
                        "evidence_manifest_path",
                        "schema_path",
                        "accounting_path",
                        "asset_validation_path",
                        "release_diff_path",
                        "path_hygiene_path",
                    )
                },
            )

            previous_manifest = outputs[0] / "underground-realms.json"
            updated_inventory = json.loads(inventory.read_text(encoding="utf-8"))
            updated_inventory["definitions"][1]["name"] = "Renamed Island Instance"
            _osrs_write_json(inventory, updated_inventory)
            updated_basemaps = json.loads(basemaps.read_text(encoding="utf-8"))
            updated_basemaps[1]["name"] = "Renamed Island Instance"
            updated_basemaps[1]["bounds"] = [[0, 0], [2, 1]]
            _osrs_write_json(basemaps, updated_basemaps)
            renamed_output = Path(directory) / "release-renamed"
            osrs_build_release(
                argparse.Namespace(
                    inventory=inventory,
                    basemaps=basemaps,
                    alignment=alignment,
                    source_metadata=metadata,
                    source_image_dir=source_dir,
                    provenance_dir=provenance_dir,
                    accounting_helper=helper,
                    source_snapshots=snapshots,
                    output=renamed_output,
                    candidate="002",
                    planes=(0,),
                    prior_manifest=previous_manifest,
                    accounting_only=False,
                )
            )
            renamed_manifest = json.loads(
                (renamed_output / "underground-realms.json").read_text()
            )
            renamed_realm = next(
                realm
                for realm in renamed_manifest["realms"]
                if realm["id"] == "cache-world-map:island"
            )
            self.assertEqual("Renamed Island Instance", renamed_realm["canonical_name"])
            self.assertIn("Island Instance", renamed_realm["aliases"])
            release_diff = json.loads(
                (renamed_output / "manifests/release-diff.json").read_text()
            )
            self.assertEqual(
                [
                    {
                        "id": "cache-world-map:island",
                        "from": "Island Instance",
                        "to": "Renamed Island Instance",
                    }
                ],
                release_diff["renamed"],
            )
            self.assertEqual("rename", release_diff["migrations"][0]["kind"])
            self.assertIn("cache-world-map:island", release_diff["changed"])

    def test_cache_only_special_region_is_selectable_and_exactly_accounted(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture"
            fixture.mkdir()
            source_dir = fixture / "source"
            provenance_dir = fixture / "provenance"
            source_dir.mkdir()
            provenance_dir.mkdir()

            source = Image.fromarray(
                np.array([[[10, 20, 30], [1, 2, 3]]], dtype=np.uint8)
            )
            source.save(source_dir / "img-0.png")
            source.save(provenance_dir / "img-0.png")
            Image.fromarray(np.array([[1, 2]], dtype=np.uint16)).save(
                provenance_dir / "img-0-provenance.png"
            )

            surface_piece = _osrs_piece(0, (0, 0, 1, 1), (0, 0, 1, 1))
            inventory = fixture / "inventory.json"
            _osrs_write_json(
                inventory,
                {
                    "definitions": [
                        _osrs_definition(
                            0, "main", "Gielinor Surface", True, surface_piece
                        )
                    ]
                },
            )
            basemaps = fixture / "basemaps.json"
            _osrs_write_json(
                basemaps,
                [
                    {
                        "mapId": 0,
                        "name": "Gielinor Surface",
                        "bounds": [[0, 0], [1, 1]],
                        "center": [0, 0],
                    }
                ],
            )
            alignment = fixture / "alignment.json"
            _osrs_write_json(alignment, {"intermap_links": []})
            metadata = fixture / "metadata.json"
            _osrs_write_json(
                metadata,
                {
                    "gameBounds": {
                        "minX": 0,
                        "minY": 0,
                        "maxX": 2,
                        "maxY": 1,
                    },
                    "gameCoordScale": 1,
                    "sourceImage": {"width": 2, "height": 1},
                },
            )
            snapshots = fixture / "snapshots.json"
            _osrs_write_json(snapshots, {"cache": {"cache_id": 123}})
            _osrs_write_json(
                provenance_dir / "img-0-provenance.json",
                {
                    "schema_version": 1,
                    "generator": "test fixture",
                    "encoding": {"mode": "uint16_last_writer"},
                    "image": {"rendered_plane": 0},
                    "projection": {"game_coord_scale": 1},
                    "statistics": {"cross_owner_overwrites": []},
                    "invariants": {"fixture": True},
                    "codebook": [
                        {
                            "code": 1,
                            "kind": "native_composite",
                            "realm_file_id": 0,
                            "source_region_id": None,
                            "source_plane": 0,
                            "source_to_display_dx": 0,
                            "source_to_display_dy": 0,
                        },
                        {
                            "code": 2,
                            "kind": "cache_loaded_special_region",
                            "realm_file_id": None,
                            "source_region_id": (1 << 8) | 2,
                            "source_plane": 0,
                            "source_to_display_dx": 0,
                            "source_to_display_dy": 0,
                        },
                    ],
                },
            )

            helper = fixture / "accounting-helper.py"
            helper.write_text(
                """#!/usr/bin/env python3
import json
import sys
from pathlib import Path

output = Path(sys.argv[sys.argv.index('--output') + 1])
value = {
    'schema_version': 1,
    'width': 2,
    'height': 1,
    'source_pixels': 2,
    'content_bearing_pixels': 2,
    'exact_black_pixels': 0,
    'unresolved_content_bearing_pixels': 0,
    'legitimate_unowned_exact_black_pixels': 0,
    'owned_exact_black_pixels': 0,
    'background_predicate': 'r == 0 and g == 0 and b == 0',
    'near_black_tolerance': 0,
    'owner_counts': [
        {'code': 1, 'total_pixels': 1, 'content_bearing_pixels': 1, 'pixel_bounds': [0, 0, 1, 1]},
        {'code': 2, 'total_pixels': 1, 'content_bearing_pixels': 1, 'pixel_bounds': [1, 0, 2, 1]},
    ],
    'checks': {
        'category_sum_matches_source': True,
        'zero_unresolved_content_bearing_pixels': True,
        'release_ready': True,
    },
}
output.write_text(json.dumps(value, sort_keys=True), encoding='utf-8')
""",
                encoding="utf-8",
            )
            helper.chmod(0o755)
            output = Path(directory) / "release"
            result = osrs_build_release(
                argparse.Namespace(
                    inventory=inventory,
                    basemaps=basemaps,
                    alignment=alignment,
                    source_metadata=metadata,
                    source_image_dir=source_dir,
                    provenance_dir=provenance_dir,
                    accounting_helper=helper,
                    source_snapshots=snapshots,
                    output=output,
                    candidate="001",
                    planes=(0,),
                    prior_manifest=None,
                    accounting_only=False,
                )
            )
            self.assertEqual(1, result["cache_special_realm_count"])
            manifest = json.loads((output / "underground-realms.json").read_text())
            special = next(
                realm
                for realm in manifest["realms"]
                if realm["id"] == "cache-special-region:1-2"
            )
            self.assertEqual("Cache region 1, 2", special["canonical_name"])
            self.assertEqual([], special["candidate_wiki_map_ids"])
            self.assertEqual([258], special["cache_region_ids"])
            self.assertEqual(1, special["accounting_pixel_count"])
            self.assertIn(special["id"], manifest["selector"]["entry_ids"])
            validation = json.loads(
                (output / "reports/realm-asset-validation.json").read_text()
            )["cache_special_region_ownership"]
            self.assertEqual(1, validation["cache_region_count"])
            self.assertEqual(1, validation["plane_zero_accounting_pixel_count"])
            self.assertTrue(validation["checks"]["all_record_invariants_hold"])


if __name__ == "__main__":
    unittest.main()
