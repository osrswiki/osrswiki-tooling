import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "local-artifact-root.sh"
REPO_ROOT = SCRIPT.parents[2]


class LocalArtifactRootTests(unittest.TestCase):
    def run_helper(self, home: pathlib.Path, root: pathlib.Path, *args: str):
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "OSRS_LOCAL_ARTIFACT_ROOT": str(root),
                "OSRS_DEPLOY_ROOT": str(home / "Developer" / "fleet-sync" / "deploy"),
                "OSRS_ARTIFACT_HOST_ID": "test-home",
                "OSRS_LOCAL_STORAGE_CONFIG": str(home / "missing-storage.env"),
            }
        )
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_initializes_expected_machine_local_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"

            result = self.run_helper(home, root, "init")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(root.resolve()))
            self.assertTrue((root / "sessions" / "active").is_dir())
            self.assertTrue((root / "artifacts" / "completed").is_dir())
            self.assertTrue((root / "artifacts" / "superseded").is_dir())
            self.assertTrue((root / "artifacts" / "reproducible").is_dir())
            self.assertTrue((root / "cache").is_dir())

    def test_rejects_documents_and_cloudstorage_roots(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            for relative in ("Documents/osrs", "Library/CloudStorage/osrs"):
                with self.subTest(relative=relative):
                    result = self.run_helper(home, home / relative, "init")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("cloud-managed location", result.stderr)

    def test_initializes_verified_machine_local_deployment_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            artifact_root = home / "Developer" / "osrswiki-local-artifacts"
            deploy_root = home / "Developer" / "fleet-sync" / "deploy"

            result = self.run_helper(home, artifact_root, "init-deploy-root")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(deploy_root.resolve()))
            self.assertTrue(deploy_root.is_dir())

    def test_rejects_cloud_managed_deployment_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            artifact_root = home / "Developer" / "osrswiki-local-artifacts"
            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "OSRS_LOCAL_ARTIFACT_ROOT": str(artifact_root),
                    "OSRS_DEPLOY_ROOT": str(home / "Documents" / "Deploy"),
                    "OSRS_ARTIFACT_HOST_ID": "test-home",
                    "OSRS_LOCAL_STORAGE_CONFIG": str(home / "missing-storage.env"),
                }
            )

            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "init-deploy-root"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cloud-managed location", result.stderr)

    def test_deployment_workflows_use_verified_non_icloud_root(self):
        scripts = (
            REPO_ROOT / "scripts" / "shared" / "deploy-android.sh",
            REPO_ROOT / "scripts" / "shared" / "deploy-ios.sh",
            REPO_ROOT / "scripts" / "shared" / "deploy-tooling.sh",
            REPO_ROOT / "scripts" / "shared" / "validate-deployment.sh",
            REPO_ROOT / "scripts" / "shared" / "validate-repository-health.sh",
        )

        for script in scripts:
            with self.subTest(script=script.name):
                content = script.read_text(encoding="utf-8")
                self.assertIn("osrs_init_local_deployment_root", content)
                self.assertNotIn("Documents/Deploy", content)
                self.assertNotIn("$PROJECT_ROOT/main", content)
                self.assertNotIn("$MONOREPO_ROOT/main", content)

    def test_source_health_checks_require_private_fleet_authority(self):
        validators = (
            REPO_ROOT / "scripts" / "shared" / "validate-deployment.sh",
            REPO_ROOT / "scripts" / "shared" / "validate-repository-health.sh",
        )

        for validator in validators:
            with self.subTest(validator=validator.name):
                content = validator.read_text(encoding="utf-8")
                self.assertIn(
                    "https://github.com/omiyawaki/osrswiki-fleet.git",
                    content,
                )
                self.assertNotIn("pure local repository", content)

    def test_builds_portable_reference_without_absolute_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"
            self.assertEqual(self.run_helper(home, root, "init").returncode, 0)

            prepared = self.run_helper(
                home, root, "prepare", "active", "lane-123", "screenshots"
            )
            self.assertEqual(prepared.returncode, 0, prepared.stderr)
            artifact_dir = pathlib.Path(prepared.stdout.strip())
            reference = self.run_helper(home, root, "reference", str(artifact_dir))

            self.assertEqual(reference.returncode, 0, reference.stderr)
            self.assertEqual(
                reference.stdout.strip(),
                "osrs-artifact://test-home/artifacts/active/lane-123/screenshots",
            )
            self.assertNotIn(str(home), reference.stdout)

            artifact_file = artifact_dir / "manifest.json"
            artifact_file.write_text("{}\n")
            file_reference = self.run_helper(home, root, "reference", str(artifact_file))
            self.assertEqual(file_reference.returncode, 0, file_reference.stderr)
            self.assertEqual(
                file_reference.stdout.strip(),
                "osrs-artifact://test-home/artifacts/active/lane-123/screenshots/manifest.json",
            )

    def test_rejects_parent_traversal_in_manifest_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"
            self.assertEqual(self.run_helper(home, root, "init").returncode, 0)

            result = self.run_helper(
                home, root, "path", "active", "lane-123", "../outside"
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid artifact subpath", result.stderr)

    def test_rejects_output_override_outside_local_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"
            outside = home / "Documents" / "qa-evidence"
            self.assertEqual(self.run_helper(home, root, "init").returncode, 0)

            result = self.run_helper(home, root, "validate-path", str(outside))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside the configured local root", result.stderr)

    def test_prepare_rejects_symlink_that_escapes_verified_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"
            outside = home / "Documents" / "escaped-artifact"
            outside.mkdir(parents=True)
            self.assertEqual(self.run_helper(home, root, "init").returncode, 0)
            (root / "artifacts" / "active" / "lane-escape").symlink_to(
                outside, target_is_directory=True
            )

            result = self.run_helper(
                home, root, "prepare", "active", "lane-escape", "screenshots"
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes the verified local root", result.stderr)
            self.assertFalse((outside / "screenshots").exists())

    def test_new_run_directory_rejects_symlink_that_escapes_verified_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"
            outside = home / "Documents" / "escaped-run"
            outside.mkdir(parents=True)
            self.assertEqual(self.run_helper(home, root, "init").returncode, 0)
            (root / "artifacts" / "active" / "main").symlink_to(
                outside, target_is_directory=True
            )
            env = os.environ.copy()
            env["OSRS_LANE_ID"] = "main"
            result = subprocess.run(
                ["/bin/bash", "-c", f"source '{SCRIPT}'; osrs_new_run_artifact_dir symlink-review"],
                capture_output=True, text=True,
                env={**env, "HOME": str(home), "OSRS_LOCAL_ARTIFACT_ROOT": str(root),
                     "OSRS_ARTIFACT_HOST_ID": "test-home", "OSRS_LOCAL_STORAGE_CONFIG": str(home / "missing-storage.env")},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes the verified local root", result.stderr)

    def test_screenshot_cleanup_requires_separate_authorization(self):
        cleanup_scripts = (
            REPO_ROOT / "scripts" / "android" / "clean-screenshots.sh",
            REPO_ROOT / "scripts" / "ios" / "clean-screenshots.sh",
        )
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary) / "home"
            home.mkdir()
            root = home / "Developer" / "osrswiki-local-artifacts"
            self.assertEqual(self.run_helper(home, root, "init").returncode, 0)

            for index, cleanup_script in enumerate(cleanup_scripts):
                with self.subTest(script=cleanup_script.name):
                    screenshots = root / "artifacts" / "active" / f"lane-{index}" / "screenshots"
                    screenshots.mkdir(parents=True)
                    screenshot = screenshots / "preserve.png"
                    screenshot.write_bytes(b"preserve")
                    env = os.environ.copy()
                    env.update(
                        {
                            "HOME": str(home),
                            "OSRS_LOCAL_ARTIFACT_ROOT": str(root),
                            "OSRS_ARTIFACT_HOST_ID": "test-home",
                            "OSRS_LOCAL_STORAGE_CONFIG": str(home / "missing-storage.env"),
                            "OSRS_SCREENSHOTS_DIR": str(screenshots),
                        }
                    )
                    env.pop("OSRS_ARTIFACT_CLEANUP_AUTHORIZED", None)

                    result = subprocess.run(
                        ["/bin/bash", str(cleanup_script), "--delete", "--max-age", "0"],
                        check=False,
                        capture_output=True,
                        text=True,
                        env=env,
                    )

                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertTrue(screenshot.exists())
                    self.assertIn("requires separate authorization", result.stderr)


if __name__ == "__main__":
    unittest.main()
