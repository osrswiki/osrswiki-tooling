import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]


UDID_ONE = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
UDID_TWO = "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"
AGENT_NAME = "agent-ios-osrswiki-thread-session-work-abcdef1234"


def write_executable(path, content):
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(0o755)
    return path


class IosSimulatorLifecycleIntegrationTests(unittest.TestCase):
    def make_env(self, tmp, devices=None, released=True, shutdown_allowed=True):
        tmp = Path(tmp)
        fake_bin = tmp / "bin"
        fake_bin.mkdir()
        xcrun_log = tmp / "xcrun.log"
        helper_log = tmp / "helper.log"
        devices_file = tmp / "devices.txt"
        devices_file.write_text(devices or "", encoding="utf-8")

        write_executable(
            fake_bin / "uname",
            """
            #!/bin/bash
            echo Darwin
            """,
        )
        write_executable(
            fake_bin / "xcodebuild",
            """
            #!/bin/bash
            if [[ "$*" == *"-showBuildSettings"* ]]; then
              echo "    PRODUCT_BUNDLE_IDENTIFIER = omiyawaki.osrswiki"
            fi
            exit 0
            """,
        )
        write_executable(
            fake_bin / "xcrun",
            f"""
            #!/bin/bash
            echo "$*" >> {xcrun_log}
            if [[ "$1" == "simctl" && "$2" == "list" && "$3" == "devices" ]]; then
              cat {devices_file}
              exit 0
            fi
            if [[ "$1" == "simctl" && "$2" == "list" && "$3" == "runtimes" ]]; then
              echo "iOS 18.0 (18.0 - 22A000) - com.apple.CoreSimulator.SimRuntime.iOS-18-0"
              exit 0
            fi
            if [[ "$1" == "simctl" && "$2" == "list" && "$3" == "devicetypes" ]]; then
              echo '    iPhone 15 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro)'
              exit 0
            fi
            if [[ "$1" == "simctl" && "$2" == "create" ]]; then
              echo CREATE-CALLED >> {xcrun_log}
              echo {UDID_TWO}
              exit 0
            fi
            if [[ "$1" == "simctl" && "$2" == "boot" ]]; then
              exit 0
            fi
            if [[ "$1" == "simctl" && "$2" == "bootstatus" ]]; then
              exit 0
            fi
            exit 0
            """,
        )

        helper = write_executable(
            tmp / "fake_ios_simulator_lifecycle.py",
            """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            log = os.environ["FAKE_HELPER_LOG"]
            with open(log, "a", encoding="utf-8") as handle:
                handle.write(" ".join(sys.argv[1:]) + "\\n")

            cmd = sys.argv[1]
            if cmd == "name":
                print(json.dumps({"name": os.environ.get("FAKE_SIM_NAME", "agent-ios-osrswiki-thread-session-work-abcdef1234")}))
            elif cmd == "heartbeat":
                print(json.dumps({"status": "ok", "updated": True}))
            elif cmd == "acquire":
                args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
                print(json.dumps({
                    "status": "ok",
                    "lease": {
                        "lease_id": args.get("--owner-id", "owner") + ":" + args.get("--udid", ""),
                        "udid": args.get("--udid", ""),
                        "device_name": args.get("--device-name", ""),
                        "owner_id": args.get("--owner-id", ""),
                        "state": "active",
                    },
                }))
            elif cmd == "release":
                released = os.environ.get("FAKE_RELEASED", "true") == "true"
                shutdown_allowed = os.environ.get("FAKE_SHUTDOWN_ALLOWED", "true") == "true"
                print(json.dumps({
                    "status": "ok" if released else "missing",
                    "released": released,
                    "applied": "--apply" in sys.argv,
                    "plan": {
                        "shutdown_allowed": shutdown_allowed,
                        "other_live_owner_ids": ["other-owner"] if not shutdown_allowed else [],
                    },
                }))
            else:
                print(json.dumps({"status": "ok"}))
            """,
        )

        state_dir = tmp / "state"
        env = dict(os.environ)
        for key in (
            "IOS_SIMULATOR_UDID",
            "SIMULATOR_NAME",
            "BUNDLE_ID",
            "DEVICE_TYPE",
            "IOS_RUNTIME",
            "OSRS_IOS_SIMULATOR_LEASE_FILE",
        ):
            env.pop(key, None)

        env.update({
            "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
            "IOS_SIMULATOR_LIFECYCLE_HELPER": str(helper),
            "FAKE_HELPER_LOG": str(helper_log),
            "FAKE_SIM_NAME": AGENT_NAME,
            "FAKE_RELEASED": "true" if released else "false",
            "FAKE_SHUTDOWN_ALLOWED": "true" if shutdown_allowed else "false",
            "OSRS_IOS_ENV_FILE": str(tmp / ".ios-env"),
            "OSRS_IOS_LEASE_FILE": str(tmp / ".simulator-lease.json"),
            "OSRS_IOS_LEGACY_ENV_FILE": str(tmp / ".claude-env"),
            "OSRS_IOS_LEGACY_SESSION_FILE": str(tmp / ".claude-session-simulator"),
            "OSRS_IOS_LEGACY_UDID_FILE": str(tmp / ".claude-simulator-udid"),
            "OSRS_IOS_LEGACY_NAME_FILE": str(tmp / ".claude-simulator-name"),
            "OSRS_IOS_LEGACY_BUNDLE_FILE": str(tmp / ".claude-bundle-id"),
            "OSRS_IOS_SIMULATOR_OWNER_ID": "owner-one",
            "AGENT_RECIPES_STATE_DIR": str(state_dir),
            "PYTHONPATH": "",
        })
        return env, xcrun_log, helper_log

    def run_bash(self, script, env, cwd=REPO_ROOT):
        return subprocess.run(
            ["bash", "-c", script],
            cwd=cwd,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_rejects_first_booted_simulator_without_explicit_or_owned_lease(self):
        devices = f"    iPhone 16 ({UDID_ONE}) (Booted)\n"
        with tempfile.TemporaryDirectory() as tmp:
            env, _, _ = self.make_env(tmp, devices=devices)
            result = self.run_bash(
                "unset IOS_SIMULATOR_UDID; source scripts/ios/qa-lib.sh; ios_select_simulator",
                env,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No iOS simulator lease or explicit IOS_SIMULATOR_UDID", result.stderr)

    def test_resolves_unique_provider_neutral_owned_simulator_and_heartbeats(self):
        devices = f"    {AGENT_NAME} ({UDID_ONE}) (Booted)\n"
        with tempfile.TemporaryDirectory() as tmp:
            env, _, helper_log = self.make_env(tmp, devices=devices)
            result = self.run_bash(
                "unset IOS_SIMULATOR_UDID; source scripts/ios/qa-lib.sh; "
                "ios_select_simulator && printf '%s|%s\\n' \"$IOS_SIMULATOR_UDID\" \"$SIMULATOR_NAME\"",
                env,
            )
            helper_calls = helper_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{UDID_ONE}|{AGENT_NAME}", result.stdout)
        self.assertIn(f"heartbeat --udid {UDID_ONE} --owner-id owner-one", helper_calls)

    def test_legacy_metadata_is_migrated_to_provider_neutral_files(self):
        devices = f"    osrswiki-claude-old-session ({UDID_ONE}) (Shutdown)\n"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env, _, helper_log = self.make_env(tmp, devices=devices)
            Path(env["OSRS_IOS_LEGACY_ENV_FILE"]).write_text(
                f'export IOS_SIMULATOR_UDID="{UDID_ONE}"\n'
                'export SIMULATOR_NAME="osrswiki-claude-old-session"\n'
                'export BUNDLE_ID="omiyawaki.osrswiki"\n',
                encoding="utf-8",
            )

            result = self.run_bash(
                "unset IOS_SIMULATOR_UDID; source scripts/ios/qa-lib.sh; "
                "ios_load_session_env && printf '%s\\n' \"$IOS_SIMULATOR_UDID\"",
                env,
            )

            lease = json.loads((tmp_path / ".simulator-lease.json").read_text(encoding="utf-8"))
            new_env = (tmp_path / ".ios-env").read_text(encoding="utf-8")
            helper_calls = helper_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(UDID_ONE, result.stdout)
        self.assertTrue(lease["migrated_from_legacy"])
        self.assertEqual(lease["udid"], UDID_ONE)
        self.assertIn("IOS_SIMULATOR_UDID", new_env)
        self.assertIn(f"acquire --udid {UDID_ONE}", helper_calls)

    def test_cleanup_releases_exact_udid_and_removes_metadata_without_direct_shutdown(self):
        devices = f"    {AGENT_NAME} ({UDID_ONE}) (Booted)\n"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env, xcrun_log, helper_log = self.make_env(tmp, devices=devices)
            (tmp_path / ".ios-env").write_text(
                f"export IOS_SIMULATOR_UDID={UDID_ONE}\n"
                f"export SIMULATOR_NAME={AGENT_NAME}\n"
                "export BUNDLE_ID=omiyawaki.osrswiki\n"
                "export OSRS_IOS_SIMULATOR_OWNER_ID=owner-one\n",
                encoding="utf-8",
            )
            (tmp_path / ".simulator-lease.json").write_text(
                json.dumps({"udid": UDID_ONE, "device_name": AGENT_NAME, "owner_id": "owner-one"}),
                encoding="utf-8",
            )

            result = self.run_bash("scripts/ios/cleanup-session-simulator.sh", env)
            helper_calls = helper_log.read_text(encoding="utf-8")
            xcrun_calls = xcrun_log.read_text(encoding="utf-8") if xcrun_log.exists() else ""
            env_exists_after_cleanup = (tmp_path / ".ios-env").exists()
            lease_exists_after_cleanup = (tmp_path / ".simulator-lease.json").exists()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"release --udid {UDID_ONE} --owner-id owner-one --shutdown --apply", helper_calls)
        self.assertNotIn("simctl shutdown", xcrun_calls)
        self.assertNotIn("simctl delete", xcrun_calls)
        self.assertFalse(env_exists_after_cleanup)
        self.assertFalse(lease_exists_after_cleanup)

    def test_cleanup_blocks_missing_lease_and_preserves_metadata(self):
        devices = f"    {AGENT_NAME} ({UDID_ONE}) (Booted)\n"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env, xcrun_log, _ = self.make_env(tmp, devices=devices, released=False)
            (tmp_path / ".ios-env").write_text(
                f"export IOS_SIMULATOR_UDID={UDID_ONE}\nexport OSRS_IOS_SIMULATOR_OWNER_ID=owner-one\n",
                encoding="utf-8",
            )
            (tmp_path / ".simulator-lease.json").write_text(
                json.dumps({"udid": UDID_ONE, "owner_id": "owner-one"}),
                encoding="utf-8",
            )

            result = self.run_bash("scripts/ios/cleanup-session-simulator.sh", env)
            xcrun_calls = xcrun_log.read_text(encoding="utf-8") if xcrun_log.exists() else ""
            env_exists_after_cleanup = (tmp_path / ".ios-env").exists()
            lease_exists_after_cleanup = (tmp_path / ".simulator-lease.json").exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No matching unreleased lifecycle lease", result.stderr)
        self.assertNotIn("simctl shutdown", xcrun_calls)
        self.assertTrue(env_exists_after_cleanup)
        self.assertTrue(lease_exists_after_cleanup)

    def test_cleanup_respects_concurrent_owner_refcount_plan(self):
        devices = f"    {AGENT_NAME} ({UDID_ONE}) (Booted)\n"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env, _, _ = self.make_env(tmp, devices=devices, shutdown_allowed=False)
            (tmp_path / ".ios-env").write_text(
                f"export IOS_SIMULATOR_UDID={UDID_ONE}\nexport OSRS_IOS_SIMULATOR_OWNER_ID=owner-one\n",
                encoding="utf-8",
            )
            (tmp_path / ".simulator-lease.json").write_text(
                json.dumps({"udid": UDID_ONE, "owner_id": "owner-one"}),
                encoding="utf-8",
            )

            result = self.run_bash("scripts/ios/cleanup-session-simulator.sh", env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shutdown was skipped", result.stdout)

    def test_verify_fails_when_exact_unreleased_lease_remains(self):
        devices = f"    {AGENT_NAME} ({UDID_ONE}) (Shutdown)\n"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env, _, _ = self.make_env(tmp, devices=devices)
            (tmp_path / ".ios-env").write_text(
                f"export IOS_SIMULATOR_UDID={UDID_ONE}\nexport OSRS_IOS_SIMULATOR_OWNER_ID=owner-one\n",
                encoding="utf-8",
            )
            state_dir = Path(env["AGENT_RECIPES_STATE_DIR"])
            state_dir.mkdir(parents=True)
            (state_dir / "ios-simulator-leases.json").write_text(
                json.dumps({"leases": [{"udid": UDID_ONE, "owner_id": "owner-one", "state": "active"}]}),
                encoding="utf-8",
            )

            result = self.run_bash("scripts/ios/verify-simulator-cleanup.sh", env)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreleased lease", result.stdout)

    def test_setup_reuses_existing_deterministic_name_idempotently(self):
        devices = f"    {AGENT_NAME} ({UDID_ONE}) (Shutdown)\n"
        with tempfile.TemporaryDirectory() as tmp:
            env, xcrun_log, helper_log = self.make_env(tmp, devices=devices)
            result = self.run_bash("scripts/ios/setup-session-simulator.sh", env)
            xcrun_calls = xcrun_log.read_text(encoding="utf-8") if xcrun_log.exists() else ""
            helper_calls = helper_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Reusing existing deterministic simulator: {UDID_ONE}", result.stdout)
        self.assertNotIn("CREATE-CALLED", xcrun_calls)
        self.assertIn(f"acquire --udid {UDID_ONE}", helper_calls)

    def test_static_contracts_for_safety_and_provider_neutrality(self):
        setup = (REPO_ROOT / "scripts/ios/setup-session-simulator.sh").read_text(encoding="utf-8")
        cleanup = (REPO_ROOT / "scripts/ios/cleanup-session-simulator.sh").read_text(encoding="utf-8")
        qa_lib = (REPO_ROOT / "scripts/ios/qa-lib.sh").read_text(encoding="utf-8")
        generator = (REPO_ROOT / "scripts/ios/generate-settings-preview-assets.sh").read_text(encoding="utf-8")

        self.assertNotIn("osrswiki-claude", setup)
        self.assertIn("ios_lifecycle_deterministic_name", setup)
        self.assertNotIn("ios_first_booted_simulator", qa_lib)
        self.assertNotIn("ios_first_available_simulator", qa_lib)
        self.assertNotIn("simctl list devices booted", generator)

        forbidden_cleanup = [
            "xcrun simctl shutdown",
            "xcrun simctl delete",
            "xcrun simctl erase",
            "killall",
            "open -a Simulator",
        ]
        for fragment in forbidden_cleanup:
            with self.subTest(fragment=fragment):
                self.assertNotIn(fragment, cleanup)


if __name__ == "__main__":
    unittest.main()
