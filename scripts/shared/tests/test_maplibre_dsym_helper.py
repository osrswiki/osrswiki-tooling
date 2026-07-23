import json
import os
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
HELPER = REPO_ROOT / "scripts" / "internal-deploy" / "maplibre-dsym.sh"
MATCHING_UUID = "79A37C95-BDDC-3DAC-9E89-DA9929FD306E"


def run_helper(script, env=None, cwd=None):
    command = f"source {shlex.quote(str(HELPER))}; {script}"
    return subprocess.run(
        ["bash", "-c", command],
        cwd=cwd or REPO_ROOT,
        env={**os.environ, **(env or {})},
        text=True,
        capture_output=True,
        check=False,
    )


class MapLibreDsymHelperTests(unittest.TestCase):
    def test_parses_maplibre_version_from_swiftpm_package_resolved_v2(self):
        with tempfile.TemporaryDirectory() as tmp:
            package_resolved = Path(tmp) / "Package.resolved"
            package_resolved.write_text(
                json.dumps(
                    {
                        "pins": [
                            {
                                "identity": "maplibre-gl-native-distribution",
                                "kind": "remoteSourceControl",
                                "location": "https://github.com/maplibre/maplibre-gl-native-distribution",
                                "state": {"revision": "abc123", "version": "6.18.0"},
                            }
                        ],
                        "version": 2,
                    }
                ),
                encoding="utf-8",
            )

            result = run_helper(
                "maplibre_version_from_package_resolved_file "
                f"{shlex.quote(str(package_resolved))}"
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "6.18.0")

    def test_parses_maplibre_version_from_xcode_archive_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive_log = Path(tmp) / "ios-archive.log"
            archive_log.write_text(
                textwrap.dedent(
                    """
                    Resolve Package Graph
                    Checking out 6.18.0 of package 'maplibre-gl-native-distribution'
                    Resolved source packages:
                      MapLibre Native: https://github.com/maplibre/maplibre-gl-native-distribution @ 6.18.0
                    """
                ),
                encoding="utf-8",
            )

            result = run_helper(
                "maplibre_version_from_archive_log " f"{shlex.quote(str(archive_log))}"
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "6.18.0")

    def test_constructs_release_asset_url_from_detected_version(self):
        result = run_helper("maplibre_dsym_url 6.18.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "https://github.com/maplibre/maplibre-native/releases/download/"
            "ios-v6.18.0/MapLibre_ios_device.framework.dSYM.zip",
        )

    def test_injects_local_override_dsym_when_uuid_matches_without_calling_curl(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            archive = self._fake_archive(tmp_path)
            archive_log = self._archive_log(tmp_path, "6.18.0")
            zip_path = self._fake_dsym_zip(tmp_path)
            fake_bin = self._fake_tools(
                tmp_path,
                framework_uuid=MATCHING_UUID,
                dsym_uuid=MATCHING_UUID,
                curl_exits=True,
            )
            evidence = tmp_path / "evidence"

            result = run_helper(
                "maplibre_inject_dsym_into_archive "
                f"{shlex.quote(str(archive))} "
                f"{shlex.quote(str(archive_log))} "
                f"{shlex.quote(str(evidence))}",
                env={
                    "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                    "OSRSWIKI_MAPLIBRE_DSYM_ZIP": str(zip_path),
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            injected = archive / "dSYMs" / "MapLibre.framework.dSYM"
            self.assertTrue(injected.is_dir())
            manifest = json.loads((evidence / "maplibre-dsym-manifest.json").read_text())
            self.assertEqual(manifest["maplibre_version"], "6.18.0")
            self.assertEqual(manifest["framework_uuids"], [MATCHING_UUID])
            self.assertEqual(manifest["dsym_uuids"], [MATCHING_UUID])
            self.assertEqual(manifest["source"], "local_override")

    def test_rejects_candidate_dsym_when_uuid_does_not_match_archive_framework(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            archive = self._fake_archive(tmp_path)
            archive_log = self._archive_log(tmp_path, "6.18.0")
            zip_path = self._fake_dsym_zip(tmp_path)
            fake_bin = self._fake_tools(
                tmp_path,
                framework_uuid=MATCHING_UUID,
                dsym_uuid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            )
            evidence = tmp_path / "evidence"

            result = run_helper(
                "maplibre_inject_dsym_into_archive "
                f"{shlex.quote(str(archive))} "
                f"{shlex.quote(str(archive_log))} "
                f"{shlex.quote(str(evidence))}",
                env={
                    "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                    "OSRSWIKI_MAPLIBRE_DSYM_ZIP": str(zip_path),
                },
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("UUID mismatch", result.stderr + result.stdout)
            self.assertFalse((archive / "dSYMs" / "MapLibre.framework.dSYM").exists())

    def _fake_archive(self, tmp_path):
        framework_dir = (
            tmp_path
            / "osrswiki.xcarchive"
            / "Products"
            / "Applications"
            / "osrswiki.app"
            / "Frameworks"
            / "MapLibre.framework"
        )
        framework_dir.mkdir(parents=True)
        (framework_dir / "MapLibre").write_text("fake framework", encoding="utf-8")
        return tmp_path / "osrswiki.xcarchive"

    def _archive_log(self, tmp_path, version):
        archive_log = tmp_path / "ios-archive.log"
        archive_log.write_text(
            f"MapLibre Native: https://github.com/maplibre/maplibre-gl-native-distribution @ {version}\n",
            encoding="utf-8",
        )
        return archive_log

    def _fake_dsym_zip(self, tmp_path):
        dsym_root = tmp_path / "dsym-src" / "MapLibre_ios_device.framework.dSYM"
        dwarf_dir = dsym_root / "Contents" / "Resources" / "DWARF"
        dwarf_dir.mkdir(parents=True)
        (dwarf_dir / "MapLibre_ios_device").write_text("fake dsym", encoding="utf-8")
        zip_path = tmp_path / "MapLibre_ios_device.framework.dSYM.zip"
        with zipfile.ZipFile(zip_path, "w") as archive:
            for path in dsym_root.rglob("*"):
                archive.write(path, path.relative_to(dsym_root.parent))
        return zip_path

    def _fake_tools(self, tmp_path, framework_uuid, dsym_uuid, curl_exits=False):
        fake_bin = tmp_path / "bin"
        fake_bin.mkdir()
        dwarfdump = fake_bin / "dwarfdump"
        dwarfdump.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/bash
                target="${{!#}}"
                case "$target" in
                    *MapLibre.framework/MapLibre)
                        echo "UUID: {framework_uuid} (arm64) $target"
                        ;;
                    *MapLibre*.framework.dSYM*)
                        echo "UUID: {dsym_uuid} (arm64) $target/Contents/Resources/DWARF/MapLibre_ios_device"
                        ;;
                    *)
                        echo "unexpected dwarfdump path: $target" >&2
                        exit 2
                        ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        dwarfdump.chmod(0o755)

        curl = fake_bin / "curl"
        curl.write_text(
            "#!/bin/bash\n"
            + ("echo curl should not be called >&2\nexit 99\n" if curl_exits else "exit 0\n"),
            encoding="utf-8",
        )
        curl.chmod(0o755)
        return fake_bin


if __name__ == "__main__":
    sys.exit(unittest.main())
