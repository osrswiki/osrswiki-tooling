from __future__ import annotations

import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from sanitize_osrs_maplibre_aar import (
    OSRS_MAPLIBRE_HOST_PREFIX,
    OSRS_MAPLIBRE_LOGICAL_PREFIX,
    osrs_sanitize_maplibre_aar,
    osrsMapLibreSanitizationError,
)


class osrsMapLibreAarSanitizerTest(unittest.TestCase):
    def test_replaces_fixed_width_host_paths_without_changing_native_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.aar"
            output = root / "sanitized.aar"
            native = b"prefix\0" + OSRS_MAPLIBRE_HOST_PREFIX + b"src/file.cpp\0suffix"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("classes.jar", b"classes")
                archive.writestr("jni/arm64-v8a/libmaplibre.so", native)

            report = osrs_sanitize_maplibre_aar(
                source,
                output,
                expected_source_sha256=self.sha256(source),
                expected_replacements=1,
            )

            with zipfile.ZipFile(output) as archive:
                sanitized_native = archive.read("jni/arm64-v8a/libmaplibre.so")
                self.assertEqual(native.__len__(), sanitized_native.__len__())
                self.assertNotIn(OSRS_MAPLIBRE_HOST_PREFIX, sanitized_native)
                self.assertIn(OSRS_MAPLIBRE_LOGICAL_PREFIX, sanitized_native)
                self.assertEqual(b"classes", archive.read("classes.jar"))
            self.assertEqual(1, report["replacement_count"])

    def test_source_hash_and_replacement_count_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.aar"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("classes.jar", b"classes")

            with self.assertRaises(osrsMapLibreSanitizationError):
                osrs_sanitize_maplibre_aar(
                    source,
                    root / "bad-hash.aar",
                    expected_source_sha256="0" * 64,
                    expected_replacements=1,
                )
            with self.assertRaises(osrsMapLibreSanitizationError):
                osrs_sanitize_maplibre_aar(
                    source,
                    root / "bad-count.aar",
                    expected_source_sha256=self.sha256(source),
                    expected_replacements=1,
                )

    @staticmethod
    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
