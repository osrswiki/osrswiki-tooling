import json
import sys
import unittest
from pathlib import Path

import numpy as np


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from osrs_non_surface_realms import (  # noqa: E402
    OSRS_SURFACE_REALM_ID,
    osrs_account_source,
    osrs_account_provenance_summary,
    osrs_build_native_owners,
    osrs_extract_owned_crop,
    osrs_other_map_id,
    osrsPipelineError,
    osrsPixelOwner,
    osrs_preserve_previous_aliases,
    osrsProjection,
    osrsRect,
    osrs_release_diff,
    osrsSpecialView,
    osrs_stable_native_realm_id,
)


def _piece(min_x, min_y, max_x, max_y, plane_min=0, plane_max=0):
    return {
        "normalized": {
            "source_bounds": {
                "min_x": min_x,
                "min_y": min_y,
                "max_x": max_x,
                "max_y": max_y,
                "plane_min": plane_min,
                "plane_max": plane_max,
            },
            "display_bounds": {
                "min_x": min_x,
                "min_y": min_y,
                "max_x": max_x,
                "max_y": max_y,
                "plane_min": plane_min,
                "plane_max": plane_max,
            },
        }
    }


def _release_realm(realm_id, name, rectangles):
    return {
        "id": realm_id,
        "canonical_name": name,
        "aliases": [],
        "group": "realms",
        "is_surface": False,
        "components": [
            {
                "source_plane": 0,
                "source_pixel_bounds": {
                    "min_x": min_x,
                    "min_y": min_y,
                    "max_x": max_x,
                    "max_y": max_y,
                },
            }
            for min_x, min_y, max_x, max_y in rectangles
        ],
    }


class osrsNonSurfaceRealmTests(unittest.TestCase):
    def test_missing_realm_leaves_visible_residual_and_fails(self):
        image = np.zeros((2, 3, 3), dtype=np.uint8)
        image[0, 0] = (40, 20, 10)
        image[1, 2] = (80, 60, 20)
        result = osrs_account_source(
            image,
            [
                osrsPixelOwner(
                    "surface-gielinor", "true_surface", (osrsRect(0, 0, 1, 1),)
                )
            ],
        )
        self.assertEqual(1, result.unresolved_content_bearing_residual_pixels)
        with self.assertRaisesRegex(osrsPipelineError, "residual=1"):
            result.assert_release_ready()

    def test_instanced_but_not_underground_definition_is_retained(self):
        inventory = {
            "definitions": [
                {
                    "file_id": 0,
                    "safe_name": "main",
                    "name": "Gielinor Surface",
                    "is_surface": True,
                    "composite": {
                        "map_squares": [_piece(0, 1, 1, 2)],
                        "zones": [],
                    },
                },
                {
                    "file_id": 36,
                    "safe_name": "last_man_standing_desert_island",
                    "name": "Last Man Standing Desert Island",
                    "is_surface": False,
                    "composite": {
                        "map_squares": [_piece(1, 1, 2, 2)],
                        "zones": [],
                    },
                },
            ]
        }
        projection = osrsProjection(0, 2, 1, 2, 2)
        owners = osrs_build_native_owners(inventory, projection)
        self.assertEqual(
            [
                OSRS_SURFACE_REALM_ID,
                "cache-world-map:last-man-standing-desert-island",
            ],
            [owner.realm_id for owner in owners],
        )
        self.assertEqual("named_non_surface_realm", owners[1].category)

    def test_near_black_antialiased_edge_is_not_background(self):
        image = np.zeros((1, 1, 3), dtype=np.uint8)
        image[0, 0] = (0, 0, 1)
        result = osrs_account_source(image, [])
        self.assertEqual(1, result.unresolved_content_bearing_residual_pixels)
        self.assertEqual(0, result.legitimate_exact_black_background_pixels)

    def test_complete_accounting_sums_to_monolithic_input(self):
        image = np.zeros((2, 4, 3), dtype=np.uint8)
        image[0, 0] = (1, 0, 0)
        image[0, 1] = (0, 1, 0)
        image[0, 2] = (0, 0, 1)
        owners = [
            osrsPixelOwner("surface-gielinor", "true_surface", (osrsRect(0, 0, 1, 1),)),
            osrsPixelOwner(
                "cache-world-map:instance",
                "named_non_surface_realm",
                (osrsRect(1, 0, 2, 1),),
            ),
        ]
        result = osrs_account_source(
            image,
            owners,
            [osrsSpecialView("other-map-10000", 10000, osrsRect(2, 0, 3, 1))],
        )
        self.assertEqual(8, result.source_pixels)
        self.assertEqual(8, result.accounted_pixels)
        self.assertEqual(1, result.true_surface_pixels)
        self.assertEqual(1, result.named_non_surface_realm_pixels)
        self.assertEqual(1, result.known_special_or_custom_area_pixels)
        self.assertEqual(5, result.legitimate_exact_black_background_pixels)
        self.assertTrue(result.release_ready)

    def test_overlapping_native_owners_fail_closed(self):
        image = np.zeros((2, 2, 3), dtype=np.uint8)
        owners = [
            osrsPixelOwner("surface-gielinor", "true_surface", (osrsRect(0, 0, 2, 2),)),
            osrsPixelOwner(
                "cache-world-map:overlap",
                "named_non_surface_realm",
                (osrsRect(1, 1, 2, 2),),
            ),
        ]
        result = osrs_account_source(image, owners)
        self.assertEqual(1, result.overlap_pixels)
        with self.assertRaisesRegex(osrsPipelineError, "overlap=1"):
            result.assert_release_ready()

    def test_overlapping_special_claims_fail_closed(self):
        image = np.ones((1, 1, 3), dtype=np.uint8)
        views = [
            osrsSpecialView("other-map-10000", 10000, osrsRect(0, 0, 1, 1)),
            osrsSpecialView("other-map-10001", 10001, osrsRect(0, 0, 1, 1)),
        ]
        result = osrs_account_source(image, [], views)
        self.assertEqual(1, result.ambiguous_special_pixels)
        with self.assertRaisesRegex(osrsPipelineError, "ambiguous_special=1"):
            result.assert_release_ready()

    def test_exact_black_inside_owner_is_preserved_as_opaque(self):
        image = np.zeros((1, 2, 3), dtype=np.uint8)
        image[0, 1] = (20, 30, 40)
        result = osrs_account_source(
            image,
            [
                osrsPixelOwner(
                    "cache-world-map:black-room",
                    "named_non_surface_realm",
                    (osrsRect(0, 0, 2, 1),),
                )
            ],
        )
        rgba, bounds = osrs_extract_owned_crop(image, result.owner_codes, 1)
        self.assertEqual(osrsRect(0, 0, 2, 1), bounds)
        self.assertEqual([0, 0, 0, 255], rgba[0, 0].tolist())
        self.assertEqual([20, 30, 40, 255], rgba[0, 1].tolist())

    def test_stable_id_survives_name_and_bound_shift(self):
        old = {
            "safe_name": "lms_desert_island",
            "name": "Old Name",
            "is_surface": False,
        }
        new = {
            "safe_name": "lms_desert_island",
            "name": "New Name",
            "is_surface": False,
        }
        self.assertEqual(osrs_stable_native_realm_id(old), osrs_stable_native_realm_id(new))

    def test_new_release_diff_discovers_addition_and_rename(self):
        prior = {"realms": [{"id": "one", "canonical_name": "Old", "bounds": [1, 2]}]}
        current = [
            {
                "id": "one",
                "canonical_name": "New",
                "aliases": [],
                "bounds": [1, 2],
            },
            {
                "id": "two",
                "canonical_name": "Instance",
                "aliases": [],
                "bounds": [2, 3],
            },
        ]
        osrs_preserve_previous_aliases(prior, current)
        diff = osrs_release_diff(prior, current)
        self.assertEqual(["two"], diff["added"])
        self.assertEqual(["Old"], current[0]["aliases"])
        self.assertEqual(
            [{"id": "one", "from": "Old", "to": "New"}], diff["renamed"]
        )
        self.assertEqual([], diff["changed"])
        self.assertEqual(
            [
                {
                    "kind": "rename",
                    "from_ids": ["one"],
                    "to_ids": ["one"],
                    "aliases_added": ["Old"],
                }
            ],
            diff["migrations"],
        )

    def test_release_diff_detects_split_from_source_membership(self):
        prior = {
            "realms": [
                _release_realm("old", "Old Realm", [(0, 0, 20, 10)])
            ]
        }
        current = [
            _release_realm("west", "West Realm", [(0, 0, 10, 10)]),
            _release_realm("east", "East Realm", [(10, 0, 20, 10)]),
        ]
        diff = osrs_release_diff(prior, current)
        self.assertEqual(1, len(diff["split"]))
        self.assertEqual("old", diff["split"][0]["from_id"])
        self.assertEqual(["east", "west"], diff["split"][0]["to_ids"])
        self.assertEqual("split", diff["migrations"][0]["kind"])

    def test_release_diff_detects_merge_from_source_membership(self):
        prior = {
            "realms": [
                _release_realm("west", "West Realm", [(0, 0, 10, 10)]),
                _release_realm("east", "East Realm", [(10, 0, 20, 10)]),
            ]
        }
        current = [
            _release_realm("combined", "Combined Realm", [(0, 0, 20, 10)])
        ]
        diff = osrs_release_diff(prior, current)
        self.assertEqual(1, len(diff["merged"]))
        self.assertEqual(["east", "west"], diff["merged"][0]["from_ids"])
        self.assertEqual("combined", diff["merged"][0]["to_id"])
        self.assertEqual("merge", diff["migrations"][0]["kind"])

    def test_release_diff_emits_id_change_and_removal_migrations(self):
        prior = {
            "realms": [
                _release_realm("legacy", "Realm", [(0, 0, 10, 10)]),
                _release_realm("retired", "Retired", [(20, 0, 30, 10)]),
            ]
        }
        current = [_release_realm("replacement", "Realm", [(0, 0, 10, 10)])]
        diff = osrs_release_diff(prior, current)
        self.assertEqual(
            ["id_change", "removed"],
            [migration["kind"] for migration in diff["migrations"]],
        )
        self.assertEqual(["legacy"], diff["migrations"][0]["from_ids"])
        self.assertEqual(["replacement"], diff["migrations"][0]["to_ids"])
        self.assertEqual(["retired"], diff["migrations"][1]["from_ids"])
        self.assertEqual([], diff["migrations"][1]["to_ids"])

    def test_release_diff_does_not_guess_from_geometry_without_name_corroboration(self):
        prior = {
            "realms": [
                _release_realm("retired", "Retired Dungeon", [(0, 0, 10, 10)])
            ]
        }
        current = [_release_realm("new", "Festival Island", [(0, 0, 10, 10)])]
        diff = osrs_release_diff(prior, current)
        self.assertEqual(["removed"], [item["kind"] for item in diff["migrations"]])

    def test_release_diff_uses_immutable_identity_across_geometry_shift(self):
        old = _release_realm("old", "Old Label", [(0, 0, 10, 10)])
        new = _release_realm("new", "New Label", [(20, 0, 30, 10)])
        old["native_file_id"] = 42
        new["native_file_id"] = 42
        diff = osrs_release_diff({"realms": [old]}, [new])
        self.assertEqual(["id_change"], [item["kind"] for item in diff["migrations"]])
        evidence = diff["migrations"][0]["evidence"]["matching_edges"][0]
        self.assertEqual(["native_file_id:42"], evidence["shared_identity_tokens"])

    def test_release_diff_fails_closed_on_many_to_many_lineage(self):
        prior = {
            "realms": [
                _release_realm("old-a", "Realm Old A", [(0, 0, 20, 10)]),
                _release_realm("old-b", "Realm Old B", [(0, 0, 20, 10)]),
            ]
        }
        current = [
            _release_realm("new-a", "Realm New A", [(0, 0, 10, 10)]),
            _release_realm("new-b", "Realm New B", [(10, 0, 20, 10)]),
        ]
        with self.assertRaisesRegex(osrsPipelineError, "many-to-many"):
            osrs_release_diff(prior, current)

    def test_other_map_id_is_namespaced(self):
        self.assertEqual("other-map-10000", osrs_other_map_id(10000))

    def test_wiki_view_bounds_can_be_clipped_without_widening_background(self):
        projection = osrsProjection(10, 20, 2, 20, 20)
        clipped = projection.game_to_pixel_rect_clipped(osrsRect(9, 9, 12, 12))
        self.assertEqual(osrsRect(0, 16, 4, 20), clipped)

    def test_streaming_provenance_classifies_native_and_special_owners(self):
        definitions = [
            {"file_id": 0, "is_surface": True},
            {"file_id": 36, "is_surface": False},
        ]
        ledger = {
            "schema_version": 1,
            "generator": "fixture",
            "encoding": {},
            "image": {},
            "projection": {},
            "codebook": [
                {"code": 1, "kind": "native_composite", "realm_file_id": 0},
                {"code": 2, "kind": "native_composite", "realm_file_id": 36},
                {"code": 3, "kind": "cache_loaded_special_region", "source_region_id": 999},
            ],
            "statistics": {
                "cross_owner_overwrites": [
                    {"previous_code": 1, "replacement_code": 2, "pixel_write_count": 4}
                ]
            },
            "invariants": ["last_writer_wins"],
        }
        streaming = {
            "source_pixels": 10,
            "legitimate_unowned_exact_black_pixels": 2,
            "unresolved_content_bearing_pixels": 0,
            "owner_counts": [
                {"code": 1, "total_pixels": 3, "content_bearing_pixels": 3},
                {"code": 2, "total_pixels": 4, "content_bearing_pixels": 2},
                {"code": 3, "total_pixels": 1, "content_bearing_pixels": 1},
            ],
        }
        result = osrs_account_provenance_summary(streaming, ledger, definitions)
        self.assertEqual(
            {
                "true_surface": 3,
                "named_non_surface_realm": 4,
                "known_special_or_custom_area": 1,
                "legitimate_exact_black_background": 2,
                "unresolved_content_bearing_residual": 0,
            },
            result["categories"],
        )
        self.assertEqual(4, result["checks"]["renderer_cross_owner_overwrite_pixels"])
        self.assertTrue(result["checks"]["release_ready"])

    def test_streaming_provenance_rejects_unknown_owner_code(self):
        with self.assertRaisesRegex(osrsPipelineError, "absent from ledger"):
            osrs_account_provenance_summary(
                {
                    "source_pixels": 1,
                    "legitimate_unowned_exact_black_pixels": 0,
                    "unresolved_content_bearing_pixels": 0,
                    "owner_counts": [
                        {"code": 9, "total_pixels": 1, "content_bearing_pixels": 1}
                    ],
                },
                {"codebook": [], "statistics": {"cross_owner_overwrites": []}},
                [{"file_id": 0, "is_surface": True}],
            )


if __name__ == "__main__":
    unittest.main()
