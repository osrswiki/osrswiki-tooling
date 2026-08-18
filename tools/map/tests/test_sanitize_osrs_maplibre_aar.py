from __future__ import annotations

import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from sanitize_osrs_maplibre_aar import (
    OSRS_MAPLIBRE_HOST_PREFIX,
    OSRS_MAPLIBRE_LOGICAL_PREFIX,
    osrsMapLibreBinaryPatch,
    osrs_sanitize_maplibre_aar,
    osrsMapLibreSanitizationError,
)


class osrsMapLibreAarSanitizerTest(unittest.TestCase):
    def test_replaces_fixed_width_host_paths_without_changing_native_size(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.aar"
            output = root / "sanitized.aar"
            constrain_offset = 4
            native = (
                b"head"
                + b"\x01\x00\x00\x00"
                + OSRS_MAPLIBRE_HOST_PREFIX
                + b"src/file.cpp\0suffix"
            )
            patches = (
                osrsMapLibreBinaryPatch(
                    entry="jni/arm64-v8a/libmaplibre.so",
                    offset=constrain_offset,
                    expected=b"\x01\x00\x00\x00",
                    replacement=b"\x00\x00\x00\x00",
                ),
            )
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("classes.jar", b"classes")
                archive.writestr("jni/arm64-v8a/libmaplibre.so", native)

            report = osrs_sanitize_maplibre_aar(
                source,
                output,
                expected_source_sha256=self.sha256(source),
                expected_replacements=1,
                expected_constrain_patches=1,
                constrain_patches=patches,
            )

            with zipfile.ZipFile(output) as archive:
                sanitized_native = archive.read("jni/arm64-v8a/libmaplibre.so")
                self.assertEqual(native.__len__(), sanitized_native.__len__())
                self.assertNotIn(OSRS_MAPLIBRE_HOST_PREFIX, sanitized_native)
                self.assertIn(OSRS_MAPLIBRE_LOGICAL_PREFIX, sanitized_native)
                self.assertEqual(
                    b"\x00\x00\x00\x00",
                    sanitized_native[constrain_offset : constrain_offset + 4],
                )
                self.assertEqual(b"classes", archive.read("classes.jar"))
            self.assertEqual(1, report["replacement_count"])
            self.assertEqual(1, report["constrain_patch_count"])
            self.assertEqual("none", report["constrain_mode"])

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
                    expected_constrain_patches=0,
                    constrain_patches=(),
                )
            with self.assertRaises(osrsMapLibreSanitizationError):
                osrs_sanitize_maplibre_aar(
                    source,
                    root / "bad-count.aar",
                    expected_source_sha256=self.sha256(source),
                    expected_replacements=1,
                    expected_constrain_patches=0,
                    constrain_patches=(),
                )

    def test_constrain_patch_instruction_and_count_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.aar"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(
                    "jni/arm64-v8a/libmaplibre.so",
                    b"prefix" + OSRS_MAPLIBRE_HOST_PREFIX,
                )
            wrong_instruction = (
                osrsMapLibreBinaryPatch(
                    entry="jni/arm64-v8a/libmaplibre.so",
                    offset=0,
                    expected=b"\x01",
                    replacement=b"\x00",
                ),
            )

            with self.assertRaises(osrsMapLibreSanitizationError):
                osrs_sanitize_maplibre_aar(
                    source,
                    root / "bad-instruction.aar",
                    expected_source_sha256=self.sha256(source),
                    expected_replacements=1,
                    expected_constrain_patches=1,
                    constrain_patches=wrong_instruction,
                )
            with self.assertRaises(osrsMapLibreSanitizationError):
                osrs_sanitize_maplibre_aar(
                    source,
                    root / "bad-patch-count.aar",
                    expected_source_sha256=self.sha256(source),
                    expected_replacements=1,
                    expected_constrain_patches=0,
                    constrain_patches=wrong_instruction,
                )

    @staticmethod
    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
