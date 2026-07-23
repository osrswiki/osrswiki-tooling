from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "shared" / "generate-smart-commit-message.sh"


class SmartCommitMessageTests(unittest.TestCase):
    def test_generator_handles_zero_change_categories_under_errexit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(["git", "init", "-q", "-b", "main", str(repository)], check=True)
            subprocess.run(
                ["git", "-C", str(repository), "config", "user.name", "Fixture"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repository),
                    "config",
                    "user.email",
                    "fixture@example.invalid",
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repository), "commit", "--allow-empty", "-q", "-m", "seed"],
                check=True,
            )
            (repository / "config.json").write_text("{}\n", encoding="utf-8")
            (repository / "README.md").write_text("fixture\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repository), "add", "-A"], check=True)

            command = (
                f'source "{SCRIPT}"; '
                'generate_deployment_commit_message tooling "$1" "$1"'
            )
            result = subprocess.run(
                ["bash", "-c", command, "bash", str(repository)],
                cwd=repository,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith("docs(tooling):"))
            self.assertNotIn("\x1b", result.stdout)
            self.assertIn("Added: 2 file(s)", result.stdout)
            self.assertIn("Analyzing changes", result.stderr)


if __name__ == "__main__":
    unittest.main()
