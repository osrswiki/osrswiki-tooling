from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "shared" / "fetch-map-release-assets.sh"


class MapReleaseAssetsTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> tuple[Path, Path]:
        source = root / "source"
        source.mkdir()
        assets = []
        for floor in range(4):
            payload = f"fixture-floor-{floor}\n".encode()
            name = f"map_floor_{floor}.mbtiles"
            (source / name).write_bytes(payload)
            assets.append({
                "name": name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "bytes": len(payload),
            })
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({
            "schema_version": 1,
            "asset_set_id": "osrs-surface-maps-0123456789ab",
            "repository": "osrswiki/osrswiki-tooling",
            "release_tag": "map-assets-v1-0123456789ab",
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

    def test_materialize_from_verified_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            destination = root / "destination"
            env = dict(os.environ)
            env["OSRS_MAP_ASSET_SOURCE_DIR"] = str(source)
            result = self.run_script(
                "materialize", str(manifest), str(destination), env=env
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            verify = self.run_script("verify", str(manifest), str(destination))
            self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_verify_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            (source / "map_floor_2.mbtiles").write_text("tampered", encoding="utf-8")
            result = self.run_script("verify", str(manifest), str(source))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)

    def test_manifest_rejects_an_unexpected_asset_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["assets"][0]["name"] = "../map_floor_0.mbtiles"
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

    def test_manifest_requires_matching_asset_and_release_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["release_tag"] = "map-assets-v1-ffffffffffff"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
