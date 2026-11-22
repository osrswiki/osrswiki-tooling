import json
import sys
import unittest
from pathlib import Path

MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from openrs2_cache import (  # noqa: E402
    cache_build_major,
    select_latest_live_osrs_cache,
    select_latest_xtea_source_cache,
    summarize_openrs2_cache,
)


FIXTURE = Path(__file__).resolve().parent / "fixtures" / "openrs2-caches-2026-11.json"


def _load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class OpenRS2CacheSelectionTests(unittest.TestCase):
    def test_real_caches_json_shape_selects_november_2026_not_march(self):
        caches = _load_fixture()
        live = select_latest_live_osrs_cache(caches)
        self.assertEqual(2772, live["id"])
        self.assertEqual("2026-11-18T14:45:05.401534Z", live["timestamp"])
        self.assertEqual(242, cache_build_major(live))
        self.assertEqual(0, live["valid_keys"])
        xtea = select_latest_xtea_source_cache(caches)
        self.assertEqual(2499, xtea["id"])
        summary = summarize_openrs2_cache(live, xtea_source=xtea)
        self.assertEqual(2772, summary["id"])
        self.assertEqual(242, summary["build"])
        self.assertEqual(2499, summary["xtea_cache_id"])

    def test_same_day_prefers_later_timestamp_then_higher_id(self):
        caches = _load_fixture()
        live = select_latest_live_osrs_cache(caches)
        self.assertEqual(2772, live["id"])
        self.assertNotEqual(2771, live["id"])

    def test_null_timestamp_and_missing_builds_cannot_beat_dated_live_cache(self):
        caches = _load_fixture()
        live = select_latest_live_osrs_cache(caches)
        self.assertEqual(2772, live["id"])
        ids = {cache["id"] for cache in caches}
        self.assertIn(879, ids)
        self.assertIn(1423, ids)

    def test_rs3_and_oldschool_beta_are_ignored(self):
        caches = _load_fixture()
        live = select_latest_live_osrs_cache(caches)
        self.assertEqual("oldschool", live["game"])
        self.assertEqual("live", live["environment"])
        self.assertNotEqual(1033, live["id"])
        self.assertNotEqual(1551, live["id"])

    def test_xtea_source_still_requires_published_keys(self):
        caches = [
            {
                "id": 2615,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-06-30T11:15:04.779183Z",
                "valid_keys": 0,
                "keys": 0,
                "disk_store_valid": True,
                "builds": [{"major": 239, "minor": None}],
            },
            {
                "id": 2499,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-03-18T11:45:07.375761Z",
                "valid_keys": 2678,
                "keys": 2868,
                "disk_store_valid": True,
                "builds": [{"major": 236, "minor": None}],
            },
        ]
        self.assertEqual(2615, select_latest_live_osrs_cache(caches)["id"])
        self.assertEqual(2499, select_latest_xtea_source_cache(caches)["id"])

    def test_require_valid_keys_false_picks_newer_zero_key_cache(self):
        caches = [
            {
                "id": 2615,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-06-30T11:15:04.779183Z",
                "valid_keys": 0,
                "keys": 0,
                "disk_store_valid": True,
                "builds": [{"major": 239, "minor": None}],
            },
            {
                "id": 2499,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-03-18T11:45:07.375761Z",
                "valid_keys": 2678,
                "keys": 2868,
                "disk_store_valid": True,
                "builds": [{"major": 236, "minor": None}],
            },
        ]
        self.assertEqual(
            2615,
            select_latest_live_osrs_cache(caches, require_valid_keys=False)["id"],
        )


if __name__ == "__main__":
    unittest.main()
