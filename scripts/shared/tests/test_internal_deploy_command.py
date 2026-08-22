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
        self.assertIn("--also-assign-track alpha", script)
        self.assertIn("Closed testing Alpha", script)
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
            self.assertEqual(payload["also_assign_tracks"], [])
            self.assertEqual(payload["assigned_tracks"], ["internal"])

    def test_android_uploader_dry_run_records_alpha_assignment_without_google_dependencies(self):
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
                    "--also-assign-track",
                    "alpha",
                    "--version-code",
                    "16",
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
            self.assertFalse(payload["assign_only"])
            self.assertEqual(payload["track"], "internal")
            self.assertEqual(payload["also_assign_tracks"], ["alpha"])
            self.assertEqual(payload["assigned_tracks"], ["internal", "alpha"])
            self.assertEqual(payload["release_name"], "internal-16")
            self.assertNotIn("releaseNotes", json.dumps(payload))

    def test_android_uploader_assign_only_dry_run_does_not_need_aab(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            service_account = tmp_path / "play-service-account.json"
            evidence = tmp_path / "evidence"
            service_account.write_text("{}", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(ANDROID_UPLOADER),
                    "--assign-only",
                    "--package-name",
                    "com.omiyawaki.osrswiki",
                    "--service-account-json",
                    str(service_account),
                    "--track",
                    "alpha",
                    "--version-code",
                    "16",
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
            self.assertTrue(payload["assign_only"])
            self.assertIsNone(payload["aab"])
            self.assertEqual(payload["track"], "alpha")
            self.assertEqual(payload["assigned_tracks"], ["alpha"])
            self.assertEqual(payload["release_name"], "internal-16")

    def test_android_uploader_rejects_production_and_beta_assignment(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            service_account = tmp_path / "play-service-account.json"
            service_account.write_text("{}", encoding="utf-8")

            for forbidden in ("production", "beta"):
                with self.subTest(track=forbidden):
                    extra = subprocess.run(
                        [
                            sys.executable,
                            str(ANDROID_UPLOADER),
                            "--assign-only",
                            "--package-name",
                            "com.omiyawaki.osrswiki",
                            "--service-account-json",
                            str(service_account),
                            "--track",
                            "internal",
                            "--also-assign-track",
                            forbidden,
                            "--version-code",
                            "16",
                            "--dry-run",
                        ],
                        cwd=REPO_ROOT,
                        env={**os.environ, "PYTHONPATH": ""},
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertNotEqual(extra.returncode, 0, extra.stdout)
                    self.assertIn("out of scope", extra.stderr)

                    primary = subprocess.run(
                        [
                            sys.executable,
                            str(ANDROID_UPLOADER),
                            "--assign-only",
                            "--package-name",
                            "com.omiyawaki.osrswiki",
                            "--service-account-json",
                            str(service_account),
                            "--track",
                            forbidden,
                            "--version-code",
                            "16",
                            "--dry-run",
                        ],
                        cwd=REPO_ROOT,
                        env={**os.environ, "PYTHONPATH": ""},
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertNotEqual(primary.returncode, 0, primary.stdout)
                    self.assertIn("out of scope", primary.stderr)

    def test_marketing_version_manifest_exists_and_is_valid_json(self):
        manifest_path = REPO_ROOT / "shared" / "manifests" / "app-version.json"
        self.assertTrue(manifest_path.is_file(), f"Marketing version manifest missing: {manifest_path}")
        
        content = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertIn("schema_version", content)
        self.assertIn("marketing_version", content)
        self.assertIsInstance(content["marketing_version"], str)
        self.assertRegex(content["marketing_version"], r'^\d+\.\d+\.\d+$')

    def test_common_sh_defines_marketing_version_helpers(self):
        common_sh = (INTERNAL_DIR / "common.sh").read_text(encoding="utf-8")
        
        required_functions = [
            "read_marketing_version_from_manifest",
            "write_marketing_version_to_manifest",
            "bump_marketing_version",
            "apply_marketing_version_to_platforms",
            "write_android_version_name",
            "write_ios_marketing_version",
        ]
        
        for func in required_functions:
            with self.subTest(function=func):
                self.assertIn(f"{func}()", common_sh)
        
        self.assertIn("APP_VERSION_MANIFEST=", common_sh)

    def test_deploy_internal_sh_documents_bump_marketing_flag(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        
        self.assertIn("--bump-marketing", script)
        self.assertIn("patch", script)
        self.assertIn("minor", script)
        self.assertIn("major", script)
        self.assertIn("BUMP_MARKETING", script)

    def test_deploy_internal_sh_applies_marketing_version_to_both_platforms(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        
        self.assertIn("bump_and_apply_marketing_version", script)
        self.assertIn("MARKETING_VERSION=", script)

    def test_real_deploy_requires_explicit_bump_marketing_flag(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        
        # Script must check for explicit flag before real deploys
        self.assertIn("BUMP_MARKETING_EXPLICIT", script)
        self.assertIn("Real internal deploys require an explicit --bump-marketing flag", script)
        
        # Script must track whether flag was explicitly provided
        self.assertIn('BUMP_MARKETING_EXPLICIT=true', script)
        self.assertIn('BUMP_MARKETING_EXPLICIT=false', script)
        
        # Script must reject real deploys without explicit flag
        self.assertIn('if [[ "$DRY_RUN" == false && "$VALIDATE_ONLY" == false && "$BUMP_MARKETING_EXPLICIT" == false ]]; then', script)

    def test_dry_run_and_validate_only_allow_omitted_bump_marketing(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        
        # Script must default to none when flag is omitted for dry-run/validate
        self.assertIn('if [[ "$BUMP_MARKETING_EXPLICIT" == false ]]; then', script)
        self.assertIn('BUMP_MARKETING="none"', script)

    def test_usage_documents_required_bump_marketing_for_real_deploys(self):
        script = ENTRYPOINT.read_text(encoding="utf-8")
        
        # Usage must indicate --bump-marketing is required for real deploys
        self.assertIn("REQUIRED for real deploys", script)
        self.assertIn("Optional for --dry-run and --validate-only", script)


if __name__ == "__main__":
    unittest.main()
