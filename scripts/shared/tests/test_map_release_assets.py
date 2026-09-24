from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "shared" / "fetch-map-release-assets.sh"
PUBLISH_SCRIPT = ROOT / "scripts" / "shared" / "publish-map-release-bundle.sh"
BUNDLE_MEMBERS = [
    "map_floor_0.mbtiles",
    "map_floor_1.mbtiles",
    "map_floor_2.mbtiles",
    "map_floor_3.mbtiles",
]
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)


class MapReleaseAssetsTests(unittest.TestCase):
    def pack_bundle(self, source: Path, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with ZipFile(
            destination, "w", compression=ZIP_DEFLATED, compresslevel=9
        ) as archive:
            for name in BUNDLE_MEMBERS:
                info = ZipInfo(filename=name, date_time=ZIP_EPOCH)
                info.compress_type = ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o644 << 16
                archive.writestr(info, (source / name).read_bytes())

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
        bundle_path = root / "map_floors.zip"
        self.pack_bundle(source, bundle_path)
        bundle_bytes = bundle_path.read_bytes()
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({
            "schema_version": 1,
            "asset_set_id": "osrs-surface-maps-0123456789ab",
            "repository": "osrswiki/osrswiki-tooling",
            "release_tag": "map-assets-v1-0123456789ab",
            "bundle": {
                "name": "map_floors.zip",
                "sha256": hashlib.sha256(bundle_bytes).hexdigest(),
                "bytes": len(bundle_bytes),
                "members": list(BUNDLE_MEMBERS),
            },
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

    def install_fake_curl(self, root: Path, payloads: dict[str, Path]) -> Path:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        mapping = bin_dir / "curl-map.tsv"
        mapping.write_text(
            "".join(f"{url}\t{path}\n" for url, path in payloads.items()),
            encoding="utf-8",
        )
        log_path = bin_dir / "curl.log"
        curl = bin_dir / "curl"
        curl.write_text(
            f"""#!/bin/bash
set -euo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        --fail|--location|--retry-all-errors)
            shift
            ;;
        --retry)
            shift 2
            ;;
        --*)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
printf '%s\\t%s\\n' "$url" "$output" >> "{log_path}"
mapped="$(awk -F '\\t' -v url="$url" '$1 == url {{ print $2; exit }}' "{mapping}")"
if [[ -z "$mapped" || ! -f "$mapped" ]]; then
    echo "curl: fake 404 for $url" >&2
    exit 22
fi
cp "$mapped" "$output"
""",
            encoding="utf-8",
        )
        curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
        return bin_dir

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

    def test_manifest_requires_bundle_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            del data["bundle"]
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)

    def test_manifest_requires_bundle_members_to_match_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["bundle"]["members"][0] = "map_floor_9.mbtiles"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            result = self.run_script("validate-manifest", str(manifest))
            self.assertNotEqual(result.returncode, 0)

    def test_materialize_downloads_one_zip_then_verifies_members(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            bundle_path = root / "map_floors.zip"
            url = (
                "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                f"{data['release_tag']}/map_floors.zip"
            )
            bin_dir = self.install_fake_curl(root, {url: bundle_path})
            destination = root / "destination"
            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env.pop("OSRS_MAP_ASSET_SOURCE_DIR", None)
            result = self.run_script(
                "materialize", str(manifest), str(destination), env=env
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            log = (bin_dir / "curl.log").read_text(encoding="utf-8").strip().splitlines()
            self.assertEqual(len(log), 1, log)
            self.assertIn("map_floors.zip", log[0])
            self.assertNotIn("map_floor_0.mbtiles", log[0])
            verify = self.run_script("verify", str(manifest), str(destination))
            self.assertEqual(verify.returncode, 0, verify.stderr)
            for name in BUNDLE_MEMBERS:
                self.assertEqual(
                    (destination / name).read_bytes(),
                    (source / name).read_bytes(),
                )

    def test_materialize_rejects_bundle_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _ = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["bundle"]["sha256"] = "ab" * 32
            manifest.write_text(json.dumps(data), encoding="utf-8")
            bundle_path = root / "map_floors.zip"
            url = (
                "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                f"{data['release_tag']}/map_floors.zip"
            )
            bin_dir = self.install_fake_curl(root, {url: bundle_path})
            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env.pop("OSRS_MAP_ASSET_SOURCE_DIR", None)
            result = self.run_script(
                "materialize", str(manifest), str(root / "destination"), env=env
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)

    def test_build_bundle_is_deterministic_across_mtimes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            first = root / "first.zip"
            second = root / "second.zip"
            os.utime(source / "map_floor_0.mbtiles", (1_700_000_000, 1_700_000_000))
            first_result = self.run_script(
                "build-bundle", str(manifest), str(source), str(first)
            )
            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            os.utime(source / "map_floor_0.mbtiles", (1_600_000_000, 1_600_000_000))
            second_result = self.run_script(
                "build-bundle", str(manifest), str(source), str(second)
            )
            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            expected = hashlib.sha256((root / "map_floors.zip").read_bytes()).hexdigest()
            actual = hashlib.sha256(first.read_bytes()).hexdigest()
            self.assertEqual(actual, expected)

    def test_publish_dry_run_writes_bundle_pins_without_uploading(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, source = self.make_fixture(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["bundle"]["sha256"] = "00" * 32
            data["bundle"]["bytes"] = 1
            manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            env = dict(os.environ)
            env["PATH"] = f"{root / 'empty-bin'}{os.pathsep}{env['PATH']}"
            (root / "empty-bin").mkdir()
            gh = root / "empty-bin" / "gh"
            gh.write_text("#!/bin/bash\necho 'gh should not run in dry-run' >&2\nexit 90\n")
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            result = subprocess.run(
                [
                    str(PUBLISH_SCRIPT),
                    "--dry-run",
                    "--clobber",
                    "--manifest",
                    str(manifest),
                    "--source-dir",
                    str(source),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            updated = json.loads(manifest.read_text(encoding="utf-8"))
            expected_zip = root / "map_floors.zip"
            expected_sha = hashlib.sha256(expected_zip.read_bytes()).hexdigest()
            self.assertEqual(updated["bundle"]["sha256"], expected_sha)
            self.assertEqual(updated["bundle"]["bytes"], expected_zip.stat().st_size)
            self.assertIn(expected_sha, result.stdout)
            self.assertNotIn("gh should not run", result.stderr)

    def test_committed_manifest_includes_the_zip_bundle_pin(self) -> None:
        result = self.run_script(
            "validate-manifest",
            str(ROOT / "shared" / "manifests" / "osrs-map-assets-v1.json"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
