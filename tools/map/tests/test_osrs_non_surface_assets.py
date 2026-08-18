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
    osrs_assert_mbtiles_alpha_matches_mask,
    osrs_build_manifest_records,
    osrs_boundary_provenance_report,
    osrs_definition_planes,
    osrs_reconcile_intermap_links,
    osrs_manifest_schema,
    osrs_shared_realm_canvas_layout,
    osrs_shared_realm_canvas_size,
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
        self.assertIn("ownership_mask_path", asset_schema["required"])
        self.assertIn("transparent_owned_pixel_count", asset_schema["required"])
        self.assertIn("visible_exact_black_pixel_count", asset_schema["required"])
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

    def test_upper_wiki_view_uses_coverage_for_display_alpha(self):
        source = np.array(
            [
                [[0, 0, 0], [10, 20, 30]],
                [[40, 50, 60], [70, 80, 90]],
            ],
            dtype=np.uint8,
        )
        coverage = np.array([[True, False], [False, True]], dtype=np.bool_)
        rendered = osrs_render_wiki_view(
            source,
            osrsProjection(0, 2, 1, 2, 2),
            osrsRect(0, 0, 2, 2),
            plane=2,
            coverage_mask=coverage,
        )
        self.assertEqual(4, rendered.ownership_pixel_count)
        self.assertEqual(2, rendered.display_pixel_count)
        self.assertEqual(2, rendered.transparent_owned_pixel_count)
        self.assertEqual(1, rendered.visible_exact_black_pixel_count)
        self.assertEqual([[255, 0], [0, 255]], rendered.rgba[..., 3].tolist())

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
            osrs_assert_mbtiles_alpha_matches_mask(
                first,
                rgba[..., 3] > 0,
                one,
            )
            with self.assertRaisesRegex(Exception, "does not match"):
                wrong_mask = np.ones((3, 5), dtype=np.bool_)
                osrs_assert_mbtiles_alpha_matches_mask(first, wrong_mask, one)

    def test_mbtiles_bounds_use_alpha_content_extent_not_rendered_rectangle(self):
        rgba = np.zeros((6, 8, 4), dtype=np.uint8)
        rgba[2:5, 3:7] = (10, 20, 30, 255)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "content.mbtiles"
            result = osrs_write_mbtiles(rgba, path, "Content", tile_size=8)
            self.assertEqual([3, 2, 7, 5], result["content_pixel_bounds"])
            self.assertEqual(-45.0, result["content_latlon_bounds"][0])
            self.assertAlmostEqual(-40.980, result["content_latlon_bounds"][1], places=3)
            self.assertEqual(135.0, result["content_latlon_bounds"][2])
            self.assertAlmostEqual(66.513, result["content_latlon_bounds"][3], places=3)
            with sqlite3.connect(path) as database:
                metadata = dict(database.execute("SELECT name, value FROM metadata"))
            self.assertEqual("3,2,7,5", metadata["osrs_content_pixel_bounds"])
            self.assertEqual("8", metadata["osrs_canvas_size"])
            self.assertTrue(metadata["osrs_content_bounds"].startswith("-45,-40.979898"))
            self.assertEqual(metadata["osrs_content_bounds"], metadata["bounds"])
            self.assertEqual(
                "finite-content-envelope; four-sided-center-edge-overbound; horizontal-wrap-disabled",
                metadata["osrs_wrap_policy"],
            )

    def test_mbtiles_canvas_origin_shifts_pixels_without_changing_native_rgba(self):
        rgba = np.zeros((3, 5, 4), dtype=np.uint8)
        rgba[1:3, 1:4] = (10, 20, 30, 255)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "shifted.mbtiles"
            result = osrs_write_mbtiles(
                rgba,
                path,
                "Shifted",
                tile_size=4,
                canvas_size=16,
                canvas_origin=(5, 6),
            )
            self.assertEqual([5, 6], result["canvas_origin"])
            self.assertEqual([6, 7, 9, 9], result["content_pixel_bounds"])
            with sqlite3.connect(path) as database:
                metadata = dict(database.execute("SELECT name, value FROM metadata"))
            self.assertEqual("5,6", metadata["osrs_canvas_origin_pixels"])
            osrs_assert_mbtiles_alpha_matches_mask(path, rgba[..., 3] > 0, result)

    def test_shared_realm_canvas_is_common_and_has_four_sided_padding(self):
        geometry = [
            {
                "plane": 0,
                "width": 512,
                "height": 356,
                "content_pixel_bounds": [0, 0, 512, 356],
            },
            {
                "plane": 2,
                "width": 512,
                "height": 708,
                "content_pixel_bounds": [0, 0, 512, 708],
            },
        ]
        self.assertEqual(
            4096,
            osrs_shared_realm_canvas_size(geometry, is_surface=False),
        )
        self.assertEqual(
            4096,
            osrs_shared_realm_canvas_size(geometry, is_surface=True),
        )
        wide = [dict(geometry[0], width=1024, content_pixel_bounds=[0, 0, 1024, 356])]
        self.assertEqual(
            4096,
            osrs_shared_realm_canvas_size(wide, is_surface=False),
        )
        self.assertEqual(
            4096,
            osrs_shared_realm_canvas_size(wide, is_surface=True),
        )
        self.assertEqual(
            {
                "canvas_size": 4096,
                "origin_x": 1792,
                "origin_y": 1694,
                "rendered_width": 512,
                "rendered_height": 708,
            },
            osrs_shared_realm_canvas_layout(geometry, is_surface=False),
        )

    def test_boundary_provenance_report_declares_finite_no_wrap_policy(self):
        report = osrs_boundary_provenance_report(
            [
                {
                    "id": "realm-a",
                    "canonical_name": "Realm A",
                    "assets": [
                        {
                            "plane": 0,
                            "mbtiles_path": "assets/realm-a/plane-0.mbtiles",
                            "canvas_size": 4096,
                            "content_pixel_bounds": [2046, 2045, 2050, 2050],
                            "content_latlon_bounds": [
                                -0.17578125,
                                -0.17578097424708533,
                                0.17578125,
                                0.26367094433665017,
                            ],
                            "ownership_pixel_count": 20,
                            "display_pixel_count": 18,
                            "transparent_owned_pixel_count": 2,
                            "content_bearing_pixel_count": 18,
                            "source_bounds": [],
                            "display_bounds": {},
                        }
                    ],
                }
            ]
        )
        self.assertEqual(
            "finite-content-envelope; four-sided-center-edge-overbound; horizontal-wrap-disabled; common-source-pixel-default-scale",
            report["policy"],
        )
        self.assertEqual(1, report["asset_count"])
        self.assertFalse(report["entries"][0]["horizontal_wrap_enabled"])
        self.assertFalse(report["entries"][0]["full_width_canvas"])
        self.assertFalse(report["entries"][0]["dateline_adjacent"])
        self.assertEqual(
            "-0.17578125,-0.175780974247085,0.17578125,0.26367094433665",
            report["entries"][0]["source_mbtiles_metadata"]["bounds"],
        )
        self.assertEqual(
            [
                -0.17578125,
                -0.17578097424708533,
                0.17578125,
                0.26367094433665017,
            ],
            report["entries"][0]["mbtiles_declared_bounds"],
        )
        self.assertEqual(4096, report["entries"][0]["shared_realm_canvas_size"])
        self.assertEqual(4092, report["entries"][0]["realm_horizontal_padding_pixels"])
        self.assertEqual(4091, report["entries"][0]["realm_vertical_padding_pixels"])
        self.assertTrue(report["entries"][0]["vertical_padding_at_least_content_height"])
        self.assertTrue(
            report["entries"][0]["default_camera"]["common_source_pixel_scale_supported"]
        )
        self.assertEqual(
            1011,
            report["entries"][0]["default_camera"]["required_edge_padding_pixels"],
        )
        self.assertEqual(
            4096 * 4096 - 18,
            report["entries"][0]["alpha_accounting"]["transparent_canvas_pixel_count"],
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
