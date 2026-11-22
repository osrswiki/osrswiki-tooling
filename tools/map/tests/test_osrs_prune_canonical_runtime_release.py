import sys
import unittest
from pathlib import Path


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from osrs_non_surface_realms import osrsPipelineError  # noqa: E402
from prune_osrs_canonical_runtime_release import (  # noqa: E402
    osrs_runtime_published_records,
)


def _record(realm_id, group):
    return {"id": realm_id, "group": group, "canonical_name": realm_id}


class osrsRuntimePruneCountTests(unittest.TestCase):
    def test_new_named_natives_are_not_frozen_at_march_count(self):
        records = [_record("surface-gielinor", "surface")]
        records.extend(
            _record(f"cache-world-map:realm-{index}", "realms")
            for index in range(51)
        )
        records.append(_record("cache-special-region:18-148", "other_maps"))
        published = osrs_runtime_published_records(records)
        self.assertEqual(52, len(published))
        self.assertEqual("surface-gielinor", published[0]["id"])
        self.assertEqual("cache-world-map:realm-50", published[-1]["id"])

    def test_missing_surface_or_natives_fails_closed(self):
        with self.assertRaisesRegex(osrsPipelineError, "exactly one surface"):
            osrs_runtime_published_records(
                [_record("cache-world-map:vampyrium", "realms")]
            )
        with self.assertRaisesRegex(osrsPipelineError, "at least one named native"):
            osrs_runtime_published_records(
                [_record("surface-gielinor", "surface")]
            )


if __name__ == "__main__":
    unittest.main()
