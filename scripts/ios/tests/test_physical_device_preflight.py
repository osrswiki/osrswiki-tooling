import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "physical_device_preflight.py"


def load_module():
    spec = importlib.util.spec_from_file_location("physical_device_preflight", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class IosPhysicalDevicePreflightTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_distinguishes_paired_local_network_from_active_tunnel(self):
        fixture = {
            "result": {
                "devices": [
                    {
                        "identifier": "00008150-00113DC03A38401C",
                        "visibilityClass": "default",
                        "hardwareProperties": {
                            "reality": "physical",
                            "platform": "iOS",
                            "marketingName": "iPhone Air",
                        },
                        "deviceProperties": {
                            "name": "ip",
                            "ddiServicesAvailable": False,
                        },
                        "connectionProperties": {
                            "pairingState": "paired",
                            "transportType": "localNetwork",
                            "tunnelState": "disconnected",
                            "potentialHostnames": ["ip.coredevice.local"],
                        },
                    }
                ]
            }
        }

        devices = self.module.parse_devices(fixture)

        self.assertEqual(len(devices), 1)
        self.assertTrue(devices[0].is_paired)
        self.assertTrue(devices[0].is_local_network_known)
        self.assertFalse(devices[0].has_active_developer_tunnel)
        self.assertFalse(devices[0].can_try_install_launch)

    def test_active_tunnel_is_ready_for_install_launch(self):
        fixture = {
            "result": {
                "devices": [
                    {
                        "identifier": "A3D9CD27-58F4-57F7-A477-11A7100CE1A9",
                        "hardwareProperties": {
                            "reality": "physical",
                            "platform": "iOS",
                            "marketingName": "iPhone Air",
                        },
                        "deviceProperties": {
                            "name": "ip",
                            "ddiServicesAvailable": True,
                        },
                        "connectionProperties": {
                            "pairingState": "paired",
                            "transportType": "localNetwork",
                            "tunnelState": "connected",
                            "potentialHostnames": [
                                "ip.coredevice.local",
                                "A3D9CD27-58F4-57F7-A477-11A7100CE1A9.coredevice.local",
                            ],
                            "networkAddress": "192.168.10.42",
                        },
                    }
                ]
            }
        }

        device = self.module.parse_devices(fixture)[0]

        self.assertTrue(device.has_active_developer_tunnel)
        self.assertTrue(device.can_try_install_launch)
        self.assertIn("192.168.10.42", device.devicectl_addresses)
        self.assertIn("ip.coredevice.local", device.devicectl_addresses)

    def test_filters_out_simulators(self):
        fixture = {
            "result": {
                "devices": [
                    {
                        "identifier": "SIM-1",
                        "hardwareProperties": {"reality": "simulated", "platform": "iOS"},
                        "deviceProperties": {"name": "iPhone Simulator"},
                        "connectionProperties": {"pairingState": "paired"},
                    }
                ]
            }
        }

        self.assertEqual(self.module.parse_devices(fixture), [])

    def test_command_path_uses_devicectl_install_and_launch(self):
        commands = self.module.build_install_launch_commands(
            pathlib.Path("/repo"),
            "00008150-00113DC03A38401C",
            "/Users/test/Developer/osrswiki-local-artifacts/derived-data",
        )
        joined = "\n".join(commands)

        self.assertIn('IOS_PHYSICAL_DEVICE_ID="00008150-00113DC03A38401C"', joined)
        self.assertIn("-sdk iphoneos", joined)
        self.assertIn("-destination 'generic/platform=iOS'", joined)
        self.assertIn('source "$REPO_ROOT/scripts/shared/local-artifact-root.sh"', joined)
        self.assertIn('osrs_assert_artifact_path "$DERIVED_DATA_PATH"', joined)
        self.assertIn('xcrun devicectl device install app --device "$IOS_PHYSICAL_DEVICE_ID" "$APP_PATH"', joined)
        self.assertIn(
            'xcrun devicectl device process launch --device "$IOS_PHYSICAL_DEVICE_ID" --terminate-existing "$BUNDLE_ID"',
            joined,
        )


if __name__ == "__main__":
    unittest.main()
