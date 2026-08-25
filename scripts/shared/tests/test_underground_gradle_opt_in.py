from __future__ import annotations

import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
ANDROID = ROOT / "platforms" / "android"
GRADLEW = ANDROID / "gradlew"
MODULE = ANDROID / "undergroundmaps"
STAGED = MODULE / "build" / "generated" / "realmAssets" / "main" / "underground-realms.json"
FIXTURE = MODULE / "src" / "fixtureAssets" / "underground-realms.json"
ROOT_RELATIVE_DIRNAME = "underground-realms-release"
PROBE_CANDIDATE = "root-relative-opt-in-probe"


class UndergroundGradleOptInTests(unittest.TestCase):
    def run_prepare(self, *extra: str) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env.pop("OSRS_UNDERGROUND_ASSETS_DIR", None)
        env.pop("OSRS_UNDERGROUND_ASSET_SOURCE_DIR", None)
        env.pop("OSRS_EXPECTED_UNDERGROUND_MANIFEST_SHA256", None)
        return subprocess.run(
            [
                str(GRADLEW),
                "--console=plain",
                ":undergroundmaps:prepareUndergroundRealmAssets",
                *extra,
            ],
            cwd=ANDROID,
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def staged_catalog(self) -> dict:
        self.assertTrue(STAGED.is_file(), f"missing staged catalog: {STAGED}")
        return json.loads(STAGED.read_text(encoding="utf-8"))

    def test_root_relative_opt_in_stages_android_root_tree(self) -> None:
        probe_dir = ANDROID / ROOT_RELATIVE_DIRNAME
        if probe_dir.exists():
            shutil.rmtree(probe_dir)
        probe_dir.mkdir()
        try:
            payload = {
                "schema_version": 1,
                "candidate": PROBE_CANDIDATE,
                "product": {"label": "probe"},
                "realms": [],
            }
            (probe_dir / "underground-realms.json").write_text(
                json.dumps(payload), encoding="utf-8"
            )
            (probe_dir / "probe.mbtiles").write_bytes(b"probe-mbtiles\n")
            result = self.run_prepare(f"-PosrsUndergroundAssetsDir={ROOT_RELATIVE_DIRNAME}")
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            staged = self.staged_catalog()
            self.assertEqual(staged["candidate"], PROBE_CANDIDATE)
            staged_tiles = MODULE / "build" / "generated" / "realmAssets" / "main" / "probe.mbtiles"
            self.assertEqual(staged_tiles.read_bytes(), b"probe-mbtiles\n")
        finally:
            shutil.rmtree(probe_dir, ignore_errors=True)

    def test_default_prepare_still_stages_fixture_stub(self) -> None:
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        staged = self.staged_catalog()
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.assertEqual(staged["candidate"], "fixture")
        self.assertEqual(staged, fixture)


if __name__ == "__main__":
    unittest.main()
