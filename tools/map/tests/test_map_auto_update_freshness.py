import sys
import unittest
from pathlib import Path


MAP_DIR = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(MAP_DIR))
sys.path.insert(0, str(ROOT / "scripts" / "shared"))

from openrs2_cache import select_latest_live_osrs_cache  # noqa: E402
from osrs_map_auto_update import (  # noqa: E402
    cache_is_newer_than_pin,
    decide_plan,
    fingerprint_from_records,
    pinned_cache_id,
)


def _surface_record(floor: int, payload: bytes) -> dict:
    import hashlib

    name = f"map_floor_{floor}.mbtiles"
    return {
        "name": name,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "bytes": len(payload),
    }


class MapAutoUpdateFreshnessTests(unittest.TestCase):
    def test_live_cache_newer_than_missing_pin_provenance_requires_generation(self) -> None:
        caches = [
            {
                "id": 2615,
                "game": "oldschool",
                "environment": "live",
                "timestamp": "2026-06-30T11:15:04.779183Z",
                "valid_keys": 12,
                "keys": 12,
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
        live = select_latest_live_osrs_cache(caches, require_valid_keys=False)
        self.assertEqual(2615, live["id"])
        self.assertTrue(cache_is_newer_than_pin(live["id"], None))
        self.assertFalse(cache_is_newer_than_pin(live["id"], 2615))

    def test_decide_skips_generation_when_both_pins_already_record_the_live_cache(self) -> None:
        records = [_surface_record(floor, b"x") for floor in range(4)]
        underground = [
            {
                "name": "underground-realms.json",
                "path": "underground-realms.json",
                "sha256": "ab" * 32,
                "bytes": 2,
            },
            {
                "name": "assets__r__plane-0.mbtiles",
                "path": "assets/r/plane-0.mbtiles",
                "sha256": "cd" * 32,
                "bytes": 4,
            },
        ]
        live = {
            "id": 2615,
            "timestamp": "2026-06-30T11:15:04.779183Z",
            "scope": "runescape",
        }
        from osrs_map_auto_update import (
            surface_release_names,
            underground_release_names,
        )

        surface_fp = fingerprint_from_records(records)
        underground_fp = fingerprint_from_records(underground)
        surface_names = surface_release_names(surface_fp)
        underground_names = underground_release_names(underground_fp)
        surface_manifest = {
            "schema_version": 1,
            "asset_set_id": surface_names["asset_set_id"],
            "repository": "osrswiki/osrswiki-tooling",
            "release_tag": surface_names["release_tag"],
            "bundle": {
                "name": "map_floors.zip",
                "sha256": "11" * 32,
                "bytes": 1,
                "members": [item["name"] for item in records],
            },
            "assets": records,
            "provenance": {
                "artifact_class": "immutable-reproducible-release",
                "generated_intermediates": "host-local-only",
                "openrs2_cache_id": 2615,
            },
        }
        underground_manifest = {
            "schema_version": 1,
            "asset_set_id": underground_names["asset_set_id"],
            "repository": "osrswiki/osrswiki-tooling",
            "release_tag": underground_names["release_tag"],
            "assets": underground,
            "provenance": {
                "artifact_class": "immutable-reproducible-release",
                "generated_intermediates": "host-local-only",
                "openrs2_cache_id": 2615,
            },
        }
        plan = decide_plan(
            live_cache=live,
            surface_manifest=surface_manifest,
            underground_manifest=underground_manifest,
            generated_surface=None,
            generated_underground=None,
            surface_bundle=None,
        )
        self.assertFalse(plan["need_generate"])
        self.assertEqual(2615, pinned_cache_id(surface_manifest))
        self.assertEqual("skip", plan["surface"]["action"])


if __name__ == "__main__":
    unittest.main()
