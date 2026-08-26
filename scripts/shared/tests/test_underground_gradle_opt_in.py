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
STAGED_FIXTURE = MODULE / "build" / "generated" / "realmAssets" / "fixture" / "underground-realms.json"
STAGED_OPT_IN = MODULE / "build" / "generated" / "realmAssets" / "optIn" / "underground-realms.json"
STAGED_OPT_IN_ROOT = MODULE / "build" / "generated" / "realmAssets" / "optIn"
FIXTURE = MODULE / "src" / "fixtureAssets" / "underground-realms.json"
ROOT_RELATIVE_DIRNAME = "underground-realms-release"
PROBE_CANDIDATE = "root-relative-opt-in-probe"
PLAY_MATERIALIZE = ROOT / "scripts" / "shared" / "materialize-play-underground-assets.sh"
DEPLOY_INTERNAL = ROOT / "scripts" / "shared" / "deploy-internal.sh"
QUICK_TEST = ROOT / "scripts" / "android" / "quick-test.sh"
QA_BUILD_INSTALL = ROOT / "scripts" / "android" / "qa-build-install.sh"
UNDERGROUND_GRADLE = MODULE / "build.gradle.kts"
IOS_STAGE = ROOT / "scripts" / "ios" / "stage-underground-realm-assets.sh"


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

    def staged_catalog(self, path: Path) -> dict:
        self.assertTrue(path.is_file(), f"missing staged catalog: {path}")
        return json.loads(path.read_text(encoding="utf-8"))

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
            staged = self.staged_catalog(STAGED_OPT_IN)
            self.assertEqual(staged["candidate"], PROBE_CANDIDATE)
            staged_tiles = MODULE / "build" / "generated" / "realmAssets" / "optIn" / "probe.mbtiles"
            self.assertEqual(staged_tiles.read_bytes(), b"probe-mbtiles\n")
        finally:
            shutil.rmtree(probe_dir, ignore_errors=True)

    def test_default_prepare_still_stages_fixture_stub(self) -> None:
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        staged = self.staged_catalog(STAGED_FIXTURE)
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.assertEqual(staged["candidate"], "fixture")
        self.assertEqual(staged, fixture)

    def test_gradle_and_ios_scripts_still_omit_implicit_home_cache_glob(self) -> None:
        gradle = UNDERGROUND_GRADLE.read_text(encoding="utf-8")
        self.assertIn("src/fixtureAssets", gradle)
        self.assertIn("osrsUndergroundAssetsDir", gradle)
        self.assertNotIn("binary-assets/underground-realms", gradle)
        self.assertNotIn("osrswiki-local-artifacts/cache", gradle)
        ios = IOS_STAGE.read_text(encoding="utf-8")
        self.assertIn("binary-assets/underground-realms", ios)

    def test_play_debug_entrypoint_explicitly_materializes_pinned_underground_assets(self) -> None:
        self.assertTrue(PLAY_MATERIALIZE.is_file(), f"missing {PLAY_MATERIALIZE}")
        helper = PLAY_MATERIALIZE.read_text(encoding="utf-8")
        self.assertIn("fetch-underground-release-assets.sh", helper)
        self.assertIn("osrs-underground-assets-v1.json", helper)
        self.assertIn("materialize", helper)
        self.assertIn("verify", helper)
        for script_path in (DEPLOY_INTERNAL, QUICK_TEST, QA_BUILD_INSTALL):
            with self.subTest(script=str(script_path.relative_to(ROOT))):
                script = script_path.read_text(encoding="utf-8")
                self.assertIn("materialize-play-underground-assets.sh", script)
                self.assertIn("-PosrsUndergroundAssetsDir=", script)
                if script_path == QUICK_TEST:
                    self.assertIn("assemblePlayDebug", script)
                    self.assertIn("app-play-debug.apk", script)
                if script_path == QA_BUILD_INSTALL:
                    self.assertIn(":app:assemblePlayDebug", script)
                    self.assertIn(":app:installPlayDebug", script)

    def test_play_debug_prepare_stages_real_gielinor_surface_not_fixture(self) -> None:
        env = dict(os.environ)
        env.pop("OSRS_UNDERGROUND_ASSETS_DIR", None)
        env.pop("OSRS_EXPECTED_UNDERGROUND_MANIFEST_SHA256", None)
        materialize = subprocess.run(
            [str(PLAY_MATERIALIZE)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(materialize.returncode, 0, materialize.stderr + materialize.stdout)
        asset_dir = materialize.stdout.strip().splitlines()[-1]
        self.assertTrue(Path(asset_dir).is_dir(), materialize.stdout)
        result = self.run_prepare(f"-PosrsUndergroundAssetsDir={asset_dir}")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        staged = self.staged_catalog(STAGED_OPT_IN)
        self.assertNotEqual(staged.get("candidate"), "fixture")
        surface_paths: list[str] = []
        for realm in staged.get("realms", []):
            if not realm.get("is_surface"):
                continue
            for asset in realm.get("assets", []):
                path = asset.get("mbtiles_path")
                self.assertIsInstance(path, str)
                self.assertNotEqual(path, "fixture/surface.mbtiles")
                self.assertFalse(str(path).startswith("fixture/"))
                tiles = STAGED_OPT_IN_ROOT / path
                self.assertTrue(tiles.is_file(), f"missing staged surface tiles: {tiles}")
                self.assertGreater(tiles.stat().st_size, 1024)
                surface_paths.append(path)
        self.assertTrue(surface_paths, "Play/debug staged catalog has no Gielinor Surface tiles")
        self.assertTrue(
            any("surface-gielinor" in path or "map_floor_" in path for path in surface_paths)
        )

    def test_default_prepare_does_not_clobber_play_opt_in_catalog(self) -> None:
        env = dict(os.environ)
        env.pop("OSRS_UNDERGROUND_ASSETS_DIR", None)
        env.pop("OSRS_UNDERGROUND_ASSET_SOURCE_DIR", None)
        materialize = subprocess.run(
            [str(PLAY_MATERIALIZE)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(materialize.returncode, 0, materialize.stderr + materialize.stdout)
        asset_dir = materialize.stdout.strip().splitlines()[-1]
        play = self.run_prepare(f"-PosrsUndergroundAssetsDir={asset_dir}")
        self.assertEqual(play.returncode, 0, play.stderr + play.stdout)
        default = self.run_prepare()
        self.assertEqual(default.returncode, 0, default.stderr + default.stdout)
        fixture_staged = self.staged_catalog(STAGED_FIXTURE)
        play_staged = self.staged_catalog(STAGED_OPT_IN)
        self.assertEqual(fixture_staged["candidate"], "fixture")
        self.assertNotEqual(play_staged.get("candidate"), "fixture")
        self.assertNotEqual(
            play_staged["realms"][0]["assets"][0]["mbtiles_path"],
            "fixture/surface.mbtiles",
        )


if __name__ == "__main__":
    unittest.main()
