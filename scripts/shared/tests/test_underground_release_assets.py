from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "shared" / "fetch-underground-release-assets.sh"
PINNED_MANIFEST = ROOT / "shared" / "manifests" / "osrs-underground-assets-v1.json"


class UndergroundReleaseAssetsTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> tuple[Path, Path]:
        source = root / "source"
        nested = source / "assets" / "cache-world-map-fixture"
        nested.mkdir(parents=True)
        catalog = b'{"candidate":"fixture-catalog"}\n'
        tiles = b"fixture-mbtiles\n"
        files = [
            ("underground-realms.json", catalog),
            ("assets/cache-world-map-fixture/plane-0.mbtiles", tiles),
        ]
        assets = []
        for relative, payload in files:
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            name = relative.replace("/", "__")
            assets.append({
                "path": relative,
                "name": name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "bytes": len(payload),
                "url": (
                    "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                    f"underground-assets-v1-0123456789ab/{name}"
                ),
            })
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({
            "schema_version": 1,
            "asset_set_id": "osrs-underground-realms-0123456789ab",
            "repository": "osrswiki/osrswiki-tooling",
            "release_tag": "underground-assets-v1-0123456789ab",
            "assets": assets,
            "provenance": {
                "source_authority": "https://example.invalid/source.git#main",
                "generator": "fixture",
                "artifact_class": "immutable-reproducible-release",
                "generated_intermediates": "host-local-only",
            },
        }), encoding="utf-8")
        return manifest, source

    def run_script(
        self, *arguments: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_pinned_manifest_is_valid(self) -> None:
        result = self.run_script("validate-manifest", str(PINNED_MANIFEST))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(PINNED_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(data["repository"], "osrswiki/osrswiki-tooling")
        self.assertTrue(data["release_tag"].startswith("underground-assets-v1-"))
        paths = [asset["path"] for asset in data["assets"]]
        self.assertIn("underground-realms.json", paths)
        self.assertGreaterEqual(len(data["assets"]), 2)
        for asset in data["assets"]:
            self.assertEqual(asset["name"], asset["path"].replace("/", "__"))
            self.assertTrue(asset["url"].endswith("/" + asset["name"]))

    def test_materialize_from_verified_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            destination = root / "destination"
            env = dict(os.environ)
            env["OSRS_UNDERGROUND_ASSET_SOURCE_DIR"] = str(source)
            result = self.run_script(
                "materialize", str(manifest), str(destination), env=env
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            verify = self.run_script("verify", str(manifest), str(destination))
            self.assertEqual(verify.returncode, 0, verify.stderr)
            self.assertTrue((destination / "underground-realms.json").is_file())
            self.assertTrue(
                (destination / "assets/cache-world-map-fixture/plane-0.mbtiles").is_file()
            )

    def test_verify_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            (source / "assets/cache-world-map-fixture/plane-0.mbtiles").write_text(
                "tampered", encoding="utf-8"
            )
            result = self.run_script("verify", str(manifest), str(source))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)

    def test_verify_rejects_size_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["assets"][1]["bytes"] = data["assets"][1]["bytes"] + 1
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("verify", str(manifest), str(source))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("size mismatch", result.stderr)

    def test_manifest_rejects_an_unexpected_asset_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["assets"][0]["path"] = "../underground-realms.json"
            data["assets"][0]["name"] = "..__underground-realms.json"
            data["assets"][0]["url"] = (
                "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                "underground-assets-v1-0123456789ab/..__underground-realms.json"
            )
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)

    def test_manifest_rejects_a_different_release_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["repository"] = "someone-else/untrusted-assets"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)

    def test_manifest_rejects_a_url_off_the_pinned_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["assets"][0]["url"] = "https://example.invalid/underground-realms.json"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)

    def test_manifest_requires_matching_asset_and_release_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["release_tag"] = "underground-assets-v1-ffffffffffff"
            for asset in data["assets"]:
                asset["url"] = (
                    "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                    f"{data['release_tag']}/{asset['name']}"
                )
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
