from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class PublicDeploymentContractTests(unittest.TestCase):
    def read_script(self, name: str) -> str:
        return (ROOT / "scripts" / "shared" / name).read_text(encoding="utf-8")

    def test_android_and_ios_publish_pinned_map_contract(self) -> None:
        for name in ("deploy-android.sh", "deploy-ios.sh"):
            with self.subTest(script=name):
                script = self.read_script(name)
                self.assertIn("fetch-map-release-assets.sh", script)
                self.assertIn("osrs_map_release_bundle.py", script)
                self.assertIn("osrs-map-assets-v1.json", script)
                self.assertIn("validate-public-deployment-tree.sh", script)
                self.assertIn("OSRS_MAP_ASSET_SOURCE_DIR=", script)

    def test_android_and_ios_do_not_hand_upload_map_bundle(self) -> None:
        for name in ("deploy-android.sh", "deploy-ios.sh", "deploy-tooling.sh"):
            with self.subTest(script=name):
                script = self.read_script(name)
                self.assertNotIn("gh release upload", script)

    def test_android_publishes_underground_fetch_recipe_without_materializing(self) -> None:
        script = self.read_script("deploy-android.sh")
        self.assertIn("fetch-underground-release-assets.sh", script)
        self.assertIn("osrs-underground-assets-v1.json", script)
        self.assertIn("underground-release-assets.md", script)
        self.assertIn("scripts/fetch-underground-assets.sh", script)
        self.assertNotIn("OSRS_UNDERGROUND_ASSET_SOURCE_DIR=", script)
        self.assertIn("UNDERGROUND_ASSETS.md", script)

    def test_every_public_deployment_runs_the_tree_guard(self) -> None:
        for platform in ("android", "ios", "tooling"):
            name = f"deploy-{platform}.sh"
            with self.subTest(script=name):
                script = self.read_script(name)
                expected = (
                    f'validate-public-deployment-tree.sh" {platform} '
                    f'"$DEPLOY_{platform.upper()}"'
                )
                self.assertIn(expected, script)
                self.assertIn("if ! DEPLOY_COMMIT_MSG=", script)

    def test_public_origins_are_canonical(self) -> None:
        expected_repositories = {
            "deploy-android.sh": "https://github.com/osrswiki/osrswiki-android.git",
            "deploy-ios.sh": "https://github.com/osrswiki/osrswiki-ios.git",
            "deploy-tooling.sh": "https://github.com/osrswiki/osrswiki-tooling.git",
        }
        for name, repository in expected_repositories.items():
            with self.subTest(script=name):
                self.assertIn(repository, self.read_script(name))

    def test_pixi_exposes_publish_map_bundle(self) -> None:
        pixi = (ROOT / "tools" / "pixi.toml").read_text(encoding="utf-8")
        self.assertIn("publish-map-bundle", pixi)
        self.assertIn("publish-map-release-bundle.sh", pixi)


if __name__ == "__main__":
    unittest.main()
