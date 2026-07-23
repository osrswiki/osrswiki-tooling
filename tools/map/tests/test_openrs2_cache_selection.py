import unittest

from openrs2_cache import select_latest_live_osrs_cache


class OpenRS2CacheSelectionTests(unittest.TestCase):
    def test_selects_latest_live_oldschool_cache_with_valid_keys(self):
        caches = [
            {
                "id": 2615,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-06-30T11:15:04.779183Z",
                "valid_keys": 0,
                "keys": 0,
                "disk_store_valid": True,
            },
            {
                "id": 2499,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-03-18T11:45:07.375761Z",
                "valid_keys": 2678,
                "keys": 2868,
                "disk_store_valid": True,
            },
            {
                "id": 2263,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2025-08-20T10:45:05.966691Z",
                "valid_keys": 2344,
                "keys": 2383,
                "disk_store_valid": True,
            },
        ]

        self.assertEqual(2499, select_latest_live_osrs_cache(caches, require_valid_keys=True)["id"])

    def test_can_select_absolute_latest_when_key_requirement_is_disabled(self):
        caches = [
            {
                "id": 2615,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-06-30T11:15:04.779183Z",
                "valid_keys": 0,
                "keys": 0,
                "disk_store_valid": True,
            },
            {
                "id": 2499,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-03-18T11:45:07.375761Z",
                "valid_keys": 2678,
                "keys": 2868,
                "disk_store_valid": True,
            },
        ]

        self.assertEqual(2615, select_latest_live_osrs_cache(caches, require_valid_keys=False)["id"])


if __name__ == "__main__":
    unittest.main()
