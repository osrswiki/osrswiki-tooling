from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "shared" / "validate-public-deployment-tree.sh"


class PublicDeploymentTreeTests(unittest.TestCase):
    def make_repository(self, root: Path) -> None:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "config", "user.email", "fixture@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(root), "config", "user.name", "Fixture"],
            check=True,
        )

    def run_validator(self, platform: str, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), platform, str(root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_source_and_small_curated_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repository(root)
            (root / "src").mkdir()
            (root / "src" / "main.kt").write_text("fun main() = Unit\n", encoding="utf-8")
            source_cache = root / "app" / "src" / "main" / "java" / "example" / "cache"
            source_cache.mkdir(parents=True)
            (source_cache / "AssetCache.kt").write_text(
                "class AssetCache\n", encoding="utf-8"
            )
            (root / "app-icon-source.png").write_bytes(b"curated")
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
            result = self.run_validator("android", root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_generated_and_dependency_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repository(root)
            (root / "node_modules").mkdir()
            (root / "node_modules" / "dependency.js").write_text("generated", encoding="utf-8")
            (root / "tools" / ".pixi").mkdir(parents=True)
            (root / "tools" / ".pixi" / "environment.bin").write_bytes(b"generated")
            (root / "map_floor_0.mbtiles").write_bytes(b"generated")
            (root / "img-0.png").write_bytes(b"generated")
            subprocess.run(["git", "-C", str(root), "add", "-f", "-A"], check=True)
            result = self.run_validator("tooling", root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("node_modules", result.stderr)
            self.assertIn(".pixi", result.stderr)
            self.assertIn("map_floor_0.mbtiles", result.stderr)
            self.assertIn("img-0.png", result.stderr)

    def test_rejects_only_generated_cache_roots(self) -> None:
        for generated_path in ("cache/download.bin", "tools/cache/download.bin"):
            with self.subTest(path=generated_path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_repository(root)
                path = root / generated_path
                path.parent.mkdir(parents=True)
                path.write_bytes(b"generated")
                subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
                result = self.run_validator("tooling", root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(generated_path, result.stderr)


if __name__ == "__main__":
    unittest.main()
