import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


MAP_DIR = Path(__file__).resolve().parents[1]


class osrsStreamingSourceAccountingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("pkg-config") is None or shutil.which("cc") is None:
            raise unittest.SkipTest("C compiler and pkg-config are required")
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "libpng"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        cls.directory = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.directory.name) / "osrs_source_accounting"
        subprocess.run(
            [
                "cc",
                "-std=c11",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(MAP_DIR / "osrs_source_accounting.c"),
                *flags,
                "-o",
                str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "directory"):
            cls.directory.cleanup()

    def _run(self, rgb, owners, require_zero=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "source.png"
            owners_path = root / "owners.png"
            output_path = root / "accounting.json"
            Image.fromarray(rgb.astype(np.uint8)).save(source_path)
            Image.fromarray(owners.astype(np.uint16)).save(owners_path)
            command = [
                str(self.binary),
                "--source",
                str(source_path),
                "--owners",
                str(owners_path),
                "--output",
                str(output_path),
            ]
            if require_zero:
                command.append("--require-zero")
            result = subprocess.run(command, capture_output=True, text=True)
            value = json.loads(output_path.read_text())
            return result, value

    def test_exact_black_and_owned_black_are_distinct(self):
        rgb = np.zeros((1, 3, 3), dtype=np.uint8)
        rgb[0, 1] = (0, 0, 1)
        owners = np.array([[1, 1, 0]], dtype=np.uint16)
        result, value = self._run(rgb, owners)
        self.assertEqual(0, result.returncode)
        self.assertEqual(1, value["content_bearing_pixels"])
        self.assertEqual(1, value["owned_exact_black_pixels"])
        self.assertEqual(1, value["legitimate_unowned_exact_black_pixels"])
        self.assertTrue(value["checks"]["release_ready"])

    def test_unowned_near_black_pixel_fails(self):
        rgb = np.array([[[0, 0, 1]]], dtype=np.uint8)
        owners = np.zeros((1, 1), dtype=np.uint16)
        result, value = self._run(rgb, owners)
        self.assertEqual(2, result.returncode)
        self.assertEqual(1, value["unresolved_content_bearing_pixels"])
        self.assertFalse(value["checks"]["release_ready"])

    def test_counts_sum_to_complete_source(self):
        rgb = np.zeros((2, 2, 3), dtype=np.uint8)
        rgb[0, 0] = (1, 2, 3)
        owners = np.array([[4, 0], [0, 0]], dtype=np.uint16)
        result, value = self._run(rgb, owners)
        self.assertEqual(0, result.returncode)
        self.assertEqual(4, value["source_pixels"])
        self.assertEqual(
            4, value["content_bearing_pixels"] + value["exact_black_pixels"]
        )
        self.assertEqual(4, value["owner_counts"][0]["code"])
        self.assertEqual([0, 0, 1, 1], value["owner_counts"][0]["pixel_bounds"])


if __name__ == "__main__":
    unittest.main()
