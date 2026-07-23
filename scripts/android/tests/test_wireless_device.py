import importlib.util
import contextlib
import io
import os
import pathlib
import stat
import sys
import tempfile
import textwrap
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "wireless_device.py"


def load_module():
    spec = importlib.util.spec_from_file_location("wireless_device", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class AndroidWirelessDeviceTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_parses_devices_and_mdns_xperia_connect_service(self):
        devices = self.module.parse_adb_devices(
            """
            List of devices attached
            192.168.1.25:37199 device product:XQ-DQ72 model:Xperia_1_V device:XQ-DQ72 transport_id:4
            ABC123 unauthorized usb:336592896X product:sunfish model:Pixel_4a device:sunfish
            """
        )
        services = self.module.parse_adb_mdns(
            """
            List of discovered mdns services
            Xperia 1 V _adb-tls-connect._tcp. 192.168.1.25:37199
            Xperia 1 V _adb-tls-pairing._tcp. 192.168.1.25:42111
            """
        )

        self.assertEqual(devices[0].serial, "192.168.1.25:37199")
        self.assertEqual(devices[0].model, "Xperia 1 V")
        self.assertTrue(devices[0].is_xperia)
        self.assertEqual(services[0].kind, "connect")
        self.assertEqual(services[0].endpoint, "192.168.1.25:37199")
        self.assertTrue(services[0].is_xperia)

    def test_resolves_adb_from_main_local_properties_when_path_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            session = root / "sessions" / "codex-wireless"
            main = root / "main"
            sdk = root / "android-sdk"
            adb = sdk / "platform-tools" / "adb"
            (main / "platforms/android").mkdir(parents=True)
            adb.parent.mkdir(parents=True)
            adb.write_text("#!/bin/sh\n", encoding="utf-8")
            adb.chmod(adb.stat().st_mode | stat.S_IXUSR)
            (main / "platforms/android/local.properties").write_text(f"sdk.dir={sdk}\n", encoding="utf-8")
            session.mkdir(parents=True)

            resolution = self.module.resolve_adb(session, env={"PATH": ""})

        self.assertEqual(resolution.adb, adb.resolve())
        self.assertIn("local.properties", resolution.source)

    def test_redacts_pairing_codes_from_logs_and_commands(self):
        secret = "123456"
        text = (
            "adb pair 192.168.1.25:42111 123456\n"
            "Pairing code: 123456\n"
            "--pair-code 123456\n"
            "ANDROID_ADB_PAIRING_CODE=123456\n"
        )

        scrubbed = self.module.redacted(text, [secret])
        command = self.module.printable_command(
            ["adb", "pair", "192.168.1.25:42111", secret],
            [secret],
        )

        self.assertNotIn(secret, scrubbed)
        self.assertNotIn(secret, command)
        self.assertIn("<redacted>", scrubbed)

    def test_stale_endpoint_is_reported_and_not_treated_as_current(self):
        env = {"ANDROID_SERIAL": "192.168.1.50:39999"}
        devices = [self.module.AdbDevice(serial="192.168.1.25:37199", state="device", properties={})]

        stale = self.module.detect_stale_env(env, devices)

        self.assertEqual(stale, "192.168.1.50:39999")

    def test_xperia_connected_wireless_device_counts_as_tls_pairing_evidence(self):
        resolution = self.module.AdbResolution(adb=pathlib.Path("/sdk/platform-tools/adb"), sdk_root=None, source="fixture")
        devices = [
            self.module.AdbDevice(
                serial="192.168.1.25:37199",
                state="device",
                properties={"model": "Xperia_1_V"},
            )
        ]

        summary = self.module.inventory_as_dict(resolution, devices, [], None, None)

        self.assertEqual(summary["xperia_tls_connect_endpoints"], ["192.168.1.25:37199"])

    def test_failed_connect_does_not_write_session_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            adb = root / "adb"
            adb.write_text(
                textwrap.dedent(
                    """
                    #!/bin/sh
                    if [ "$1" = "connect" ]; then
                      echo "failed to connect"
                      exit 1
                    fi
                    exit 0
                    """
                ).lstrip(),
                encoding="utf-8",
            )
            adb.chmod(0o755)

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                status = self.module.main(
                    [
                        "--repo-root",
                        str(root),
                        "--adb",
                        str(adb),
                        "connect",
                        "--connect",
                        "192.168.1.25:37199",
                    ]
                )
            env_exists = (root / ".claude-env").exists()

        self.assertEqual(status, 1)
        self.assertFalse(env_exists)
        self.assertIn("failed to connect", stderr.getvalue())

    def test_session_environment_written_only_by_explicit_writer_without_endpoint_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "scripts/android").mkdir(parents=True)
            (root / "platforms/android/app").mkdir(parents=True)
            (root / "scripts/android/get-app-id.sh").write_text(
                "#!/bin/sh\necho com.omiyawaki.osrswiki\n",
                encoding="utf-8",
            )
            os.chmod(root / "scripts/android/get-app-id.sh", 0o755)
            sdk = root / "sdk"
            adb = sdk / "platform-tools" / "adb"
            adb.parent.mkdir(parents=True)
            adb.write_text("#!/bin/sh\n", encoding="utf-8")
            os.chmod(adb, 0o755)
            resolution = self.module.AdbResolution(adb=adb, sdk_root=sdk, source="fixture")
            device = self.module.VerifiedDevice(
                serial="192.168.1.25:37199",
                stable_id="ZX1G22ABC",
                model="Xperia 1 V",
                manufacturer="Sony",
            )

            self.module.write_session_environment(root, resolution, device)
            env_text = (root / ".claude-env").read_text(encoding="utf-8")
            metadata = (root / ".claude-android-wireless-device").read_text(encoding="utf-8")

        self.assertIn("ANDROID_SERIAL='192.168.1.25:37199'", env_text)
        self.assertIn(f"export PATH='{sdk}/platform-tools':$PATH", env_text)
        self.assertIn("ANDROID_WIRELESS_DEVICE_STABLE_ID='ZX1G22ABC'", env_text)
        self.assertNotIn("42111", env_text)
        self.assertNotIn("pair", env_text.lower())
        self.assertNotIn("42111", metadata)


if __name__ == "__main__":
    unittest.main()
