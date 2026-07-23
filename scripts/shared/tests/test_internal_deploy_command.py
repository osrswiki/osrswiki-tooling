import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
ENTRYPOINT = REPO_ROOT / "scripts" / "shared" / "deploy-internal.sh"
INTERNAL_DIR = REPO_ROOT / "scripts" / "internal-deploy"
ANDROID_UPLOADER = INTERNAL_DIR / "upload-android-play.py"
ENV_EXAMPLE = INTERNAL_DIR / ".env.example"
ANDROID_SIGNING_EXAMPLE = INTERNAL_DIR / "config" / "android-signing.properties.example"


class InternalDeployCommandTests(unittest.TestCase):
    def test_entrypoint_documents_internal_android_and_ios_targets(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("Google Play internal testing", script)
        self.assertIn("TestFlight", script)
        self.assertIn("--dry-run", script)
        self.assertIn("--validate-only", script)

    def test_entrypoint_avoids_destructive_git_and_deployment_repo_operations(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        forbidden_fragments = [
            "git push",
            "git reset",
            "git clean",
            "--no-verify",
            "Documents/Deploy",
            "osrswiki-android",
            "osrswiki-ios",
        ]

        for fragment in forbidden_fragments:
            with self.subTest(fragment=fragment):
                self.assertNotIn(fragment, script)

    def test_ios_upload_uses_xcodebuild_auth_and_does_not_double_upload(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("archive_cmd+=(", script)
        self.assertIn("export_cmd+=(", script)
        self.assertIn("-authenticationKeyPath \"$ASC_API_KEY_PATH\"", script)
        self.assertIn("Upload delegated to xcodebuild -exportArchive", script)
        self.assertIn("removed_after_successful_upload", script)
        self.assertNotIn("xcrun altool --upload-app", script)

    def test_ios_archive_injects_maplibre_dsym_before_export_with_symbols_enabled(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        export_options = (INTERNAL_DIR / "ExportOptions.plist").read_text(encoding="utf-8")

        archive_index = script.index('"${archive_cmd[@]}"')
        injection_index = script.index("maplibre_inject_dsym_into_archive")
        export_index = script.index('"${export_cmd[@]}"', injection_index)

        self.assertLess(archive_index, injection_index)
        self.assertLess(injection_index, export_index)
        self.assertIn("<key>uploadSymbols</key>", export_options)
        self.assertIn("<true/>", export_options)

    def test_env_examples_are_templates_not_credentials(self):
        env_example = ENV_EXAMPLE.read_text(encoding="utf-8")
        signing_example = ANDROID_SIGNING_EXAMPLE.read_text(encoding="utf-8")

        self.assertIn("PLAY_SERVICE_ACCOUNT_JSON=", env_example)
        self.assertIn("ASC_API_KEY_ID=", env_example)
        self.assertIn("ASC_API_ISSUER_ID=", env_example)
        self.assertIn("ASC_API_KEY_PATH=", env_example)
        self.assertIn("REPLACE_WITH_KEYSTORE_PASSWORD", signing_example)
        self.assertNotIn("BEGIN PRIVATE KEY", env_example)
        self.assertNotIn('"private_key"', env_example)
        self.assertNotIn(".p8\n", env_example)

    def test_android_uploader_dry_run_writes_evidence_without_google_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            aab = tmp_path / "app-release.aab"
            service_account = tmp_path / "play-service-account.json"
            evidence = tmp_path / "evidence"
            aab.write_bytes(b"fake-aab")
            service_account.write_text("{}", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(ANDROID_UPLOADER),
                    "--aab",
                    str(aab),
                    "--package-name",
                    "com.omiyawaki.osrswiki",
                    "--service-account-json",
                    str(service_account),
                    "--track",
                    "internal",
                    "--version-code",
                    "123",
                    "--evidence-dir",
                    str(evidence),
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                env={**os.environ, "PYTHONPATH": ""},
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads((evidence / "android-upload-result.json").read_text(encoding="utf-8"))
            self.assertTrue(payload["dry_run"])
            self.assertEqual(payload["track"], "internal")
            self.assertEqual(payload["release_name"], "internal-123")


if __name__ == "__main__":
    unittest.main()
