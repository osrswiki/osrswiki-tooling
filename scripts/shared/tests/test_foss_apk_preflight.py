from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SHARED = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[3]
if str(SHARED) not in sys.path:
    sys.path.insert(0, str(SHARED))

from foss_apk_preflight import (  # noqa: E402
    ALLOWED_SIGNER_SHA256,
    assets_assets_entries,
    check_fixture_underground_json,
    check_source_tree,
    compare_unsigned_zip_contents,
)
from test_inspect_apk_signing_block import (  # noqa: E402
    V2_ID,
    build_zip_bytes,
    insert_signing_block,
)


FIXTURE_JSON = json.loads(
    (
        ROOT
        / "platforms"
        / "android"
        / "undergroundmaps"
        / "src"
        / "fixtureAssets"
        / "underground-realms.json"
    ).read_text(encoding="utf-8")
)
PUBLISH_SCRIPT = ROOT / "scripts" / "shared" / "publish-foss-apk.sh"


class FossApkPreflightTests(unittest.TestCase):
    def test_fixture_catalog_passes(self) -> None:
        self.assertEqual(check_fixture_underground_json(FIXTURE_JSON), [])

    def test_full_catalog_candidate_fails(self) -> None:
        payload = dict(FIXTURE_JSON)
        payload["candidate"] = "010"
        errors = check_fixture_underground_json(payload)
        self.assertTrue(any("candidate" in error for error in errors))

    def test_named_non_surface_entries_fail(self) -> None:
        payload = json.loads(json.dumps(FIXTURE_JSON))
        payload["realms"].append(
            {
                "id": "named_non_surface_realm:keldagrim",
                "is_surface": False,
            }
        )
        errors = check_fixture_underground_json(payload)
        self.assertTrue(any("named_non_surface" in error for error in errors))

    def test_assets_assets_entries_are_rejected(self) -> None:
        names = [
            "assets/map_floor_0.mbtiles",
            "assets/underground-realms.json",
            "assets/assets/cache-world-map-keldagrim/plane-0.mbtiles",
        ]
        leaked = assets_assets_entries(names)
        self.assertEqual(
            leaked,
            ["assets/assets/cache-world-map-keldagrim/plane-0.mbtiles"],
        )

    def test_source_tree_rejects_materialized_underground_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            gradle = tree / "app" / "build.gradle.kts"
            gradle.parent.mkdir(parents=True)
            gradle.write_text(
                "vcsInfo { include = false }\n"
                "dependenciesInfo { includeInApk = false; includeInBundle = false }\n",
                encoding="utf-8",
            )
            leaked = tree / "app" / "src" / "main" / "assets" / "assets"
            leaked.mkdir(parents=True)
            (leaked / "cache-world-map-keldagrim").mkdir()
            errors = check_source_tree(tree)
            self.assertTrue(any("assets/assets" in error for error in errors))

    def test_source_tree_rejects_underground_json_in_app_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            gradle = tree / "app" / "build.gradle.kts"
            gradle.parent.mkdir(parents=True)
            gradle.write_text(
                "vcsInfo { include = false }\n"
                "dependenciesInfo { includeInApk = false; includeInBundle = false }\n",
                encoding="utf-8",
            )
            assets = tree / "app" / "src" / "main" / "assets"
            assets.mkdir(parents=True)
            (assets / "underground-realms.json").write_text("{}", encoding="utf-8")
            errors = check_source_tree(tree)
            self.assertTrue(any("underground-realms.json" in error for error in errors))

    def test_source_tree_rejects_opt_in_env(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            gradle = tree / "app" / "build.gradle.kts"
            gradle.parent.mkdir(parents=True)
            gradle.write_text(
                "vcsInfo { include = false }\n"
                "dependenciesInfo { includeInApk = false; includeInBundle = false }\n",
                encoding="utf-8",
            )
            previous = os.environ.get("OSRS_UNDERGROUND_ASSETS_DIR")
            os.environ["OSRS_UNDERGROUND_ASSETS_DIR"] = "/tmp/leaked-cache"
            try:
                errors = check_source_tree(tree)
            finally:
                if previous is None:
                    os.environ.pop("OSRS_UNDERGROUND_ASSETS_DIR", None)
                else:
                    os.environ["OSRS_UNDERGROUND_ASSETS_DIR"] = previous
            self.assertTrue(
                any("OSRS_UNDERGROUND_ASSETS_DIR" in error for error in errors)
            )

    def test_zip_content_compare_detects_extra_member(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            left = root / "left.apk"
            right = root / "right.apk"
            left.write_bytes(
                build_zip_bytes(
                    {
                        "assets/map_floor_0.mbtiles": b"floor0",
                        "assets/underground-realms.json": b"{}",
                    }
                )
            )
            right.write_bytes(
                build_zip_bytes(
                    {
                        "assets/map_floor_0.mbtiles": b"floor0",
                        "assets/underground-realms.json": b"{}",
                        "assets/assets/cache.mbtiles": b"leak",
                    }
                )
            )
            errors = compare_unsigned_zip_contents(left, right)
            self.assertTrue(any("assets/assets/cache.mbtiles" in error for error in errors))

    def test_allowed_signer_matches_fdroid_metadata(self) -> None:
        metadata = (ROOT / "docs" / "fdroid" / "com.omiyawaki.osrswiki.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(ALLOWED_SIGNER_SHA256, metadata)

    def test_synthetic_v2_apk_has_no_assets_assets(self) -> None:
        payload = insert_signing_block(
            build_zip_bytes(
                {
                    "assets/map_floor_0.mbtiles": b"0",
                    "assets/underground-realms.json": json.dumps(FIXTURE_JSON).encode(),
                    "assets/fixture/surface.mbtiles": b"fixture",
                }
            ),
            [(V2_ID, b"v2")],
        )
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            apk.write_bytes(payload)
            with zipfile.ZipFile(apk) as archive:
                leaked = assets_assets_entries(archive.namelist())
            self.assertEqual(leaked, [])

    def test_publish_script_is_fail_closed(self) -> None:
        script = PUBLISH_SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(PUBLISH_SCRIPT.is_file())
        self.assertTrue(PUBLISH_SCRIPT.stat().st_mode & stat.S_IXUSR)
        self.assertIn("unzip -o -j", script)
        self.assertIn("assembleFossRelease", script)
        self.assertIn("missing-signing.properties", script)
        self.assertIn("sign_apk_v2_only.py", script)
        self.assertNotIn("apksigner sign", script)
        self.assertIn("apksigcopier", script)
        self.assertIn("foss_apk_preflight.py", script)
        self.assertIn("FOSS_APK_ALLOW_GITHUB_UPLOAD=1", script)
        self.assertNotIn("fetch-underground", script)
        self.assertNotIn("osrsUndergroundAssetsDir=", script)
        self.assertIn("OSRS_UNDERGROUND_ASSETS_DIR", script)
        self.assertIn("git clone", script)
        self.assertIn("osrswiki/osrswiki-android", script)
        self.assertNotIn("fleet-sync/deploy/osrswiki-android", script)


if __name__ == "__main__":
    unittest.main()
