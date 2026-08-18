import sys
import unittest
from pathlib import Path

import numpy as np


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from osrs_provenance_assets import (  # noqa: E402
    osrs_add_special_region_records,
    osrs_build_special_region_index,
    osrs_iter_rendered_provenance_realms,
    osrs_parse_provenance_components,
    osrs_special_region_accounting_report,
    osrs_special_region_realm_id,
)
from osrs_non_surface_realms import osrsPipelineError, osrsProjection, osrsRect  # noqa: E402


def _special_component(code, region_x, region_y, *, plane=0, pixels=1):
    ledger = {
        "projection": {"game_coord_scale": 1},
        "image": {"rendered_plane": plane},
        "codebook": [
            {
                "code": code,
                "kind": "cache_loaded_special_region",
                "realm_file_id": None,
                "source_region_id": (region_x << 8) | region_y,
                "source_plane": plane,
                "source_to_display_dx": 0,
                "source_to_display_dy": 0,
            }
        ],
    }
    streaming = {
        "owner_counts": [
            {
                "code": code,
                "total_pixels": pixels,
                "content_bearing_pixels": pixels,
                "pixel_bounds": [0, 0, pixels, 1],
            }
        ]
    }
    return osrs_parse_provenance_components(ledger, streaming)[0]


class osrsProvenanceAssetTests(unittest.TestCase):
    def test_transform_aware_spill_pixels_land_in_realm_local_display(self):
        source = np.zeros((3, 4, 3), dtype=np.uint8)
        source[0, 0] = (10, 20, 30)
        source[2, 3] = (40, 50, 60)
        owners = np.zeros((3, 4), dtype=np.uint16)
        owners[0, 0] = 1
        owners[2, 3] = 2
        ledger = {
            "projection": {"game_coord_scale": 1},
            "image": {"rendered_plane": 0},
            "codebook": [
                {
                    "code": 1,
                    "kind": "native_composite",
                    "realm_file_id": 36,
                    "source_region_id": None,
                    "source_plane": 0,
                    "source_to_display_dx": 10,
                    "source_to_display_dy": 0,
                },
                {
                    "code": 2,
                    "kind": "native_composite",
                    "realm_file_id": 36,
                    "source_region_id": None,
                    "source_plane": 0,
                    "source_to_display_dx": 8,
                    "source_to_display_dy": 0,
                },
            ],
        }
        streaming = {
            "owner_counts": [
                {"code": 1, "total_pixels": 1, "content_bearing_pixels": 1, "pixel_bounds": [0, 0, 1, 1]},
                {"code": 2, "total_pixels": 1, "content_bearing_pixels": 1, "pixel_bounds": [3, 2, 4, 3]},
            ]
        }
        components = osrs_parse_provenance_components(ledger, streaming)
        definition = {"file_id": 36, "safe_name": "island", "is_surface": False}
        rendered = list(
            osrs_iter_rendered_provenance_realms(
                source,
                owners,
                osrsProjection(0, 3, 1, 4, 3),
                components,
                [definition],
            )
        )
        self.assertEqual(1, len(rendered))
        realm_id, image = rendered[0]
        self.assertEqual("cache-world-map:island", realm_id)
        self.assertEqual(2, int(image.mask.sum()))
        colors = {
            tuple(value)
            for value in image.rgba[..., :3][image.mask].tolist()
        }
        self.assertEqual({(10, 20, 30), (40, 50, 60)}, colors)
        self.assertEqual(2, len(image.layout_components))

    def test_special_regions_become_stable_other_map_records(self):
        component = _special_component(7, 50, 80, pixels=3)
        records = []
        added = osrs_add_special_region_records(
            records,
            {0: (component,)},
            [
                {
                    "mapId": 10000,
                    "name": "Named Wiki View",
                    "bounds": [[3200, 5120], [3264, 5184]],
                }
            ],
        )
        self.assertEqual(1, len(added))
        self.assertEqual("cache-special-region:50-80", added[0]["id"])
        self.assertEqual("Cache region 50, 80", added[0]["canonical_name"])
        self.assertEqual("other_maps", added[0]["group"])
        self.assertEqual([], added[0]["aliases"])
        self.assertEqual([10000], added[0]["candidate_wiki_map_ids"])
        self.assertEqual(1.0, added[0]["pixel_ownership_confidence"])
        self.assertEqual(0.0, added[0]["semantic_identity_confidence"])
        self.assertEqual(3, added[0]["accounting_pixel_count"])

    def test_special_region_id_validates_range(self):
        self.assertEqual("cache-special-region:1-2", osrs_special_region_realm_id(258))

    def test_adjacent_regions_with_distinct_map_ids_are_not_merged(self):
        values = (
            _special_component(1, 10, 10),
            _special_component(2, 10, 11),
        )
        index = osrs_build_special_region_index({0: values})
        first = (10 << 8) | 10
        second = (10 << 8) | 11
        self.assertNotEqual(index[first], index[second])
        records = []
        added = osrs_add_special_region_records(
            records,
            {0: values},
            [
                {
                    "mapId": 10000,
                    "name": "First view",
                    "bounds": [[640, 640], [704, 704]],
                },
                {
                    "mapId": 10001,
                    "name": "Second view",
                    "bounds": [[640, 704], [704, 768]],
                },
            ],
            index,
        )
        self.assertEqual(2, len(added))
        by_id = {record["id"]: record for record in added}
        self.assertEqual(
            [10000], by_id["cache-special-region:10-10"]["candidate_wiki_map_ids"]
        )
        self.assertEqual(
            [10001], by_id["cache-special-region:10-11"]["candidate_wiki_map_ids"]
        )
        with self.assertRaisesRegex(osrsPipelineError, "must map to"):
            osrs_add_special_region_records(
                [],
                {0: values},
                [],
                {first: index[first], second: index[first]},
            )

    def test_overlapping_wiki_views_leave_backing_owner_generic(self):
        component = _special_component(3, 20, 20)
        added = osrs_add_special_region_records(
            [],
            {0: (component,)},
            [
                {
                    "mapId": 10002,
                    "name": "Alpha identity guess",
                    "bounds": [[1280, 1280], [1344, 1344]],
                },
                {
                    "mapId": 10003,
                    "name": "Beta identity guess",
                    "bounds": [[1280, 1280], [1344, 1344]],
                },
            ],
        )
        self.assertEqual("Cache region 20, 20", added[0]["canonical_name"])
        self.assertEqual([], added[0]["aliases"])
        self.assertEqual([10002, 10003], added[0]["candidate_wiki_map_ids"])
        self.assertIn(
            "multiple_wiki_overlap_candidates", added[0]["ambiguity"]["reasons"]
        )

    def test_cache_only_region_is_stable_and_selectable(self):
        component = _special_component(4, 30, 40, pixels=5)
        added = osrs_add_special_region_records([], {0: (component,)}, [])
        self.assertEqual("cache-special-region:30-40", added[0]["id"])
        self.assertEqual("other_maps", added[0]["group"])
        self.assertEqual([], added[0]["candidate_wiki_map_ids"])
        self.assertEqual(5, added[0]["accounting_pixel_count"])

    def test_enrichment_order_and_names_cannot_change_owner_identity_or_geometry(self):
        component = _special_component(5, 40, 50, pixels=2)
        first_basemaps = [
            {
                "mapId": 10005,
                "name": "Zeta",
                "bounds": [[2560, 3200], [2624, 3264]],
            },
            {
                "mapId": 10004,
                "name": "Alpha",
                "bounds": [[2560, 3200], [2624, 3264]],
            },
        ]
        second_basemaps = [
            {**first_basemaps[1], "name": "Renamed candidate"},
            {**first_basemaps[0], "name": "Another rename"},
        ]
        first = osrs_add_special_region_records(
            [], {0: (component,)}, first_basemaps
        )[0]
        second = osrs_add_special_region_records(
            [], {0: (component,)}, second_basemaps
        )[0]
        invariant_fields = (
            "id",
            "canonical_name",
            "aliases",
            "center",
            "source_mask",
            "display_mask",
            "cache_region_ids",
            "accounting_provenance_codes_by_rendered_plane",
        )
        self.assertEqual(
            {field: first[field] for field in invariant_fields},
            {field: second[field] for field in invariant_fields},
        )
        self.assertEqual([10004, 10005], first["candidate_wiki_map_ids"])
        self.assertEqual(first["candidate_wiki_map_ids"], second["candidate_wiki_map_ids"])

    def test_special_region_accounting_sums_exactly_without_coalescing(self):
        region_a_floor_zero = _special_component(6, 50, 60, pixels=3)
        region_b_floor_zero = _special_component(7, 50, 61, pixels=4)
        region_a_floor_one = _special_component(6, 50, 60, plane=1, pixels=2)
        components = {
            0: (region_a_floor_zero, region_b_floor_zero),
            1: (region_a_floor_one,),
        }
        records = []
        osrs_add_special_region_records(records, components, [])
        report = osrs_special_region_accounting_report(records, components, 7)
        self.assertEqual(2, report["cache_region_count"])
        self.assertEqual(7, report["plane_zero_accounting_pixel_count"])
        self.assertTrue(report["checks"]["no_cache_regions_coalesced"])
        self.assertTrue(report["checks"]["manifest_sum_matches_source_accounting"])
        with self.assertRaisesRegex(osrsPipelineError, "component_sum_matches"):
            osrs_special_region_accounting_report(records, components, 8)

    def test_rendered_floor_is_not_confused_with_source_plane(self):
        source = np.zeros((1, 2, 3), dtype=np.uint8)
        source[0, 0] = (1, 2, 3)
        source[0, 1] = (4, 5, 6)
        owners = np.array([[1, 2]], dtype=np.uint16)
        ledger = {
            "projection": {"game_coord_scale": 1},
            "image": {"rendered_plane": 0},
            "codebook": [
                {
                    "code": code,
                    "kind": "native_composite",
                    "realm_file_id": 36,
                    "source_region_id": None,
                    "source_plane": source_plane,
                    "source_to_display_dx": 0,
                    "source_to_display_dy": 0,
                }
                for code, source_plane in ((1, 0), (2, 1))
            ],
        }
        streaming = {
            "owner_counts": [
                {
                    "code": code,
                    "total_pixels": 1,
                    "content_bearing_pixels": 1,
                    "pixel_bounds": [x, 0, x + 1, 1],
                }
                for code, x in ((1, 0), (2, 1))
            ]
        }
        components = osrs_parse_provenance_components(ledger, streaming)
        rendered = list(
            osrs_iter_rendered_provenance_realms(
                source,
                owners,
                osrsProjection(0, 1, 1, 2, 1),
                components,
                [{"file_id": 36, "safe_name": "bridge", "is_surface": False}],
            )
        )
        self.assertEqual(1, len(rendered))
        self.assertEqual(0, rendered[0][1].plane)
        self.assertEqual(2, int(rendered[0][1].mask.sum()))

    def test_upper_floor_seed_only_pixels_remain_owned_but_transparent(self):
        source = np.array([[[10, 20, 30], [40, 50, 60]]], dtype=np.uint8)
        owners = np.array([[1, 1]], dtype=np.uint16)
        coverage = np.array([[False, True]], dtype=np.bool_)
        ledger = {
            "projection": {"game_coord_scale": 1},
            "image": {"rendered_plane": 1},
            "codebook": [
                {
                    "code": 1,
                    "kind": "native_composite",
                    "realm_file_id": 36,
                    "source_region_id": None,
                    "source_plane": 1,
                    "source_to_display_dx": 0,
                    "source_to_display_dy": 0,
                }
            ],
        }
        streaming = {
            "owner_counts": [
                {
                    "code": 1,
                    "total_pixels": 2,
                    "content_bearing_pixels": 2,
                    "pixel_bounds": [0, 0, 2, 1],
                }
            ]
        }
        rendered = list(
            osrs_iter_rendered_provenance_realms(
                source,
                owners,
                osrsProjection(0, 1, 1, 2, 1),
                osrs_parse_provenance_components(ledger, streaming),
                [{"file_id": 36, "safe_name": "upper", "is_surface": False}],
                coverage_mask=coverage,
            )
        )[0][1]
        self.assertEqual(2, rendered.ownership_pixel_count)
        self.assertEqual(1, rendered.display_pixel_count)
        self.assertEqual(1, rendered.transparent_owned_pixel_count)
        self.assertTrue(rendered.ownership_mask[0, 0])
        self.assertFalse(rendered.mask[0, 0])
        self.assertEqual(0, rendered.rgba[0, 0, 3])
        self.assertEqual(255, rendered.rgba[0, 1, 3])

    def test_actual_exact_black_write_is_visible_when_coverage_is_present(self):
        source = np.array([[[0, 0, 0], [70, 80, 90]]], dtype=np.uint8)
        owners = np.array([[1, 1]], dtype=np.uint16)
        coverage = np.array([[True, False]], dtype=np.bool_)
        ledger = {
            "projection": {"game_coord_scale": 1},
            "image": {"rendered_plane": 2},
            "codebook": [
                {
                    "code": 1,
                    "kind": "native_composite",
                    "realm_file_id": 36,
                    "source_region_id": None,
                    "source_plane": 2,
                    "source_to_display_dx": 0,
                    "source_to_display_dy": 0,
                }
            ],
        }
        streaming = {
            "owner_counts": [
                {
                    "code": 1,
                    "total_pixels": 2,
                    "content_bearing_pixels": 1,
                    "pixel_bounds": [0, 0, 2, 1],
                }
            ]
        }
        rendered = list(
            osrs_iter_rendered_provenance_realms(
                source,
                owners,
                osrsProjection(0, 1, 1, 2, 1),
                osrs_parse_provenance_components(ledger, streaming),
                [{"file_id": 36, "safe_name": "black", "is_surface": False}],
                coverage_mask=coverage,
            )
        )[0][1]
        self.assertEqual(1, rendered.display_pixel_count)
        self.assertEqual(1, rendered.visible_exact_black_pixel_count)
        self.assertTrue(rendered.mask[0, 0])
        self.assertEqual([0, 0, 0, 255], rendered.rgba[0, 0].tolist())

    def test_coverage_without_final_owner_fails_closed(self):
        source = np.array([[[10, 20, 30], [40, 50, 60]]], dtype=np.uint8)
        owners = np.array([[0, 1]], dtype=np.uint16)
        coverage = np.array([[True, True]], dtype=np.bool_)
        ledger = {
            "projection": {"game_coord_scale": 1},
            "image": {"rendered_plane": 1},
            "codebook": [
                {
                    "code": 1,
                    "kind": "native_composite",
                    "realm_file_id": 36,
                    "source_region_id": None,
                    "source_plane": 1,
                    "source_to_display_dx": 0,
                    "source_to_display_dy": 0,
                }
            ],
        }
        streaming = {
            "owner_counts": [
                {
                    "code": 1,
                    "total_pixels": 1,
                    "content_bearing_pixels": 1,
                    "pixel_bounds": [1, 0, 2, 1],
                }
            ]
        }
        with self.assertRaisesRegex(osrsPipelineError, "without a final owner"):
            list(
                osrs_iter_rendered_provenance_realms(
                    source,
                    owners,
                    osrsProjection(0, 1, 1, 2, 1),
                    osrs_parse_provenance_components(ledger, streaming),
                    [{"file_id": 36, "safe_name": "gap", "is_surface": False}],
                    coverage_mask=coverage,
                )
            )


if __name__ == "__main__":
    unittest.main()
