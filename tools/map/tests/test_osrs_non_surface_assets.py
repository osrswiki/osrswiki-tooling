import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from jsonschema import Draft202012Validator


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from osrs_non_surface_assets import (  # noqa: E402
    osrs_build_manifest_records,
    osrs_definition_planes,
    osrs_reconcile_intermap_links,
    osrs_manifest_schema,
    osrs_release_relative_path,
    osrs_render_native_realm,
    osrs_render_wiki_view,
    osrs_sha256_file,
    osrs_validate_release_relative_path,
    osrs_write_mbtiles,
)
from osrs_non_surface_realms import osrsProjection, osrsRect  # noqa: E402


def _piece(index, source, display, plane_min=0, plane_max=0):
    return {
        "piece_index": index,
        "normalized": {
            "source_bounds": {
                "min_x": source[0],
                "min_y": source[1],
                "max_x": source[2],
                "max_y": source[3],
                "plane_min": plane_min,
                "plane_max": plane_max,
            },
            "display_bounds": {
                "min_x": display[0],
                "min_y": display[1],
                "max_x": display[2],
                "max_y": display[3],
                "plane_min": plane_min,
                "plane_max": plane_max,
            },
        },
    }


def _definition(file_id, safe_name, name, is_surface, pieces, plane=0):
    return {
        "file_id": file_id,
        "safe_name": safe_name,
        "name": name,
        "is_surface": is_surface,
        "position": {"x": 0, "y": 0, "plane": plane},
        "composite": {"present": True, "map_squares": pieces, "zones": []},
    }


class osrsNonSurfaceAssetTests(unittest.TestCase):
    def test_public_manifest_schema_is_valid_draft_2020_12(self):
        schema = osrs_manifest_schema()
        Draft202012Validator.check_schema(schema)
        asset_schema = schema["properties"]["realms"]["items"]["properties"][
            "assets"
        ]["items"]
        self.assertIn("sqlite_version_number", asset_schema["required"])
        expected = (
            sqlite3.sqlite_version_info[0] * 1_000_000
            + sqlite3.sqlite_version_info[1] * 1_000
            + sqlite3.sqlite_version_info[2]
        )
        self.assertEqual(
            expected,
            asset_schema["properties"]["sqlite_version_number"]["const"],
        )

    def test_release_owned_paths_are_normalized_relative_posix_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "release"
            self.assertEqual(
                "assets/example/plane-0.mbtiles",
                osrs_release_relative_path(
                    root / "assets" / "example" / "plane-0.mbtiles", root
                ),
            )
            with self.assertRaisesRegex(Exception, "outside release root"):
                osrs_release_relative_path(Path(directory) / "outside.json", root)
        for invalid in (
            "/absolute/file",
            "C:/absolute/file",
            "reports/../outside.json",
            "masks\\realm\\plane-0.png",
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaises(Exception):
                    osrs_validate_release_relative_path(invalid, "fixture")

    def test_display_transform_builds_tight_local_realm_without_resampling(self):
        source = np.zeros((2, 4, 3), dtype=np.uint8)
        source[:, 0:2] = (10, 20, 30)
        source[:, 2:4] = (40, 50, 60)
        projection = osrsProjection(0, 2, 1, 4, 2)
        definition = _definition(
            4,
            "island_instance",
            "Island Instance",
            False,
            [
                _piece(0, (0, 0, 2, 2), (100, 100, 102, 102)),
                _piece(1, (2, 0, 4, 2), (102, 100, 104, 102)),
            ],
        )
        rendered = osrs_render_native_realm(source, projection, definition, 0)
        self.assertEqual((2, 4, 4), rendered.rgba.shape)
        self.assertTrue(np.all(rendered.rgba[:, :2, :3] == (10, 20, 30)))
        self.assertTrue(np.all(rendered.rgba[:, 2:, :3] == (40, 50, 60)))
        self.assertTrue(np.all(rendered.rgba[..., 3] == 255))
        self.assertEqual(osrsRect(100, 100, 104, 102), rendered.display_bounds)

    def test_wiki_view_retains_rendered_floor_identity(self):
        source = np.ones((2, 2, 3), dtype=np.uint8)
        rendered = osrs_render_wiki_view(
            source,
            osrsProjection(0, 2, 1, 2, 2),
            osrsRect(0, 0, 2, 2),
            plane=2,
        )
        self.assertEqual(2, rendered.plane)

    def test_plane_inventory_is_not_forced_to_zero(self):
        definition = _definition(
            8,
            "prison",
            "Prison",
            False,
            [_piece(0, (0, 0, 1, 1), (0, 0, 1, 1), 2, 2)],
            plane=2,
        )
        self.assertEqual((2,), osrs_definition_planes(definition))

    def test_mbtiles_bytes_are_reproducible_and_use_nearest_pyramid(self):
        rgba = np.zeros((3, 5, 4), dtype=np.uint8)
        rgba[:, :2] = (10, 20, 30, 255)
        rgba[:, 4] = (40, 50, 60, 255)
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.mbtiles"
            second = Path(directory) / "second.mbtiles"
            one = osrs_write_mbtiles(rgba, first, "Fixture", tile_size=4)
            two = osrs_write_mbtiles(
                rgba,
                second,
                "Fixture",
                tile_size=4,
                release_root=Path(directory),
            )
            self.assertEqual(one["sha256"], two["sha256"])
            self.assertEqual(
                sqlite3.sqlite_version_info[0] * 1_000_000
                + sqlite3.sqlite_version_info[1] * 1_000
                + sqlite3.sqlite_version_info[2],
                one["sqlite_version_number"],
            )
            self.assertEqual("second.mbtiles", two["path"])
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with sqlite3.connect(first) as database:
                self.assertEqual(
                    [("osrs_tile_size", "4")],
                    database.execute(
                        "SELECT name, value FROM metadata WHERE name='osrs_tile_size'"
                    ).fetchall(),
                )
                self.assertGreater(
                    database.execute("SELECT COUNT(*) FROM tiles").fetchone()[0], 0
                )

    def test_manifest_discovers_non_underground_instance_and_custom_view(self):
        inventory = {
            "definitions": [
                _definition(
                    0,
                    "main",
                    "Gielinor Surface",
                    True,
                    [_piece(0, (0, 0, 1, 1), (0, 0, 1, 1), 0, 3)],
                ),
                _definition(
                    36,
                    "lms_desert_island",
                    "LMS Desert Island",
                    False,
                    [_piece(0, (1, 0, 2, 1), (10, 10, 11, 11))],
                ),
            ]
        }
        basemaps = [
            {
                "mapId": 0,
                "name": "Gielinor Surface",
                "bounds": [[0, 0], [1, 1]],
                "center": [0, 0],
            },
            {
                "mapId": 36,
                "name": "Last Man Standing Desert Island",
                "bounds": [[1, 0], [2, 1]],
                "center": [1, 0],
            },
            {
                "mapId": 10000,
                "name": "Special Interior",
                "bounds": [[2, 0], [3, 1]],
                "center": [2, 0],
            },
        ]
        realms = osrs_build_manifest_records(inventory, basemaps)
        self.assertEqual(3, len(realms))
        self.assertIn(
            "cache-world-map:lms-desert-island", [realm["id"] for realm in realms]
        )
        self.assertIn("other-map-10000", [realm["id"] for realm in realms])
        lms = next(realm for realm in realms if realm["native_file_id"] == 36)
        self.assertEqual("realms", lms["group"])
        self.assertIn("Last Man Standing Desert Island", lms["aliases"])

    def test_intermap_links_enable_only_exact_cache_membership_endpoints(self):
        inventory = {
            "definitions": [
                _definition(
                    0,
                    "main",
                    "Gielinor Surface",
                    True,
                    [_piece(0, (0, 0, 8, 8), (0, 0, 8, 8))],
                ),
                _definition(
                    36,
                    "island",
                    "Island",
                    False,
                    [_piece(0, (8, 0, 16, 8), (80, 0, 88, 8))],
                ),
            ]
        }
        basemaps = [
            {"mapId": 0, "name": "Gielinor Surface", "bounds": [[0, 0], [8, 8]], "center": [1, 1]},
            {"mapId": 36, "name": "Island", "bounds": [[8, 0], [16, 8]], "center": [9, 1]},
        ]
        records = osrs_build_manifest_records(inventory, basemaps)
        summary = osrs_reconcile_intermap_links(
            records,
            inventory,
            {
                "intermap_links": [
                    {
                        "id": "intermap-0001",
                        "from_position": {"x": 1, "y": 1, "plane": 0},
                        "to_position": {"x": 9, "y": 1, "plane": 0},
                        "direction": "fixture",
                    },
                    {
                        "id": "intermap-0002",
                        "from_position": {"x": 9, "y": 1, "plane": 0},
                        "to_position": {"x": 99, "y": 99, "plane": 0},
                        "direction": "fixture",
                    },
                ]
            },
        )
        self.assertEqual(
            {"total": 2, "available": 1, "unavailable": 1, "available_cross_realm": 1},
            summary,
        )
        island = next(record for record in records if record["native_file_id"] == 36)
        self.assertEqual(["available", "unavailable"], [link["availability"] for link in island["links"]])
        self.assertEqual(1, island["ambiguity"]["unresolved_link_count"])

    def test_cache_and_wiki_native_version_mismatch_fails_closed(self):
        inventory = {
            "definitions": [
                _definition(
                    0,
                    "main",
                    "Gielinor Surface",
                    True,
                    [_piece(0, (0, 0, 8, 8), (0, 0, 8, 8))],
                )
            ]
        }
        basemaps = [
            {"mapId": 0, "name": "Gielinor Surface", "bounds": [[0, 0], [8, 8]], "center": [1, 1]},
            {"mapId": 52, "name": "New Cache Realm", "bounds": [[8, 0], [16, 8]], "center": [9, 1]},
        ]
        with self.assertRaisesRegex(Exception, "native version mismatch"):
            osrs_build_manifest_records(inventory, basemaps)


if __name__ == "__main__":
    unittest.main()
