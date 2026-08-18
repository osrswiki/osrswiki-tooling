#!/usr/bin/env python3
"""Create the deterministic OSRS MapLibre AAR used by the standalone map."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path
from typing import NamedTuple, Sequence


OSRS_MAPLIBRE_HOST_PREFIX = b"/home/runner/work/maplibre-native/maplibre-native/"
OSRS_MAPLIBRE_LOGICAL_PREFIX = b"third_party/maplibre-native/source_tree/upstream_/"

if len(OSRS_MAPLIBRE_HOST_PREFIX) != len(OSRS_MAPLIBRE_LOGICAL_PREFIX):
    raise RuntimeError("MapLibre path replacement must preserve native binary size")


class osrsMapLibreBinaryPatch(NamedTuple):
    entry: str
    offset: int
    expected: bytes
    replacement: bytes


# MapLibre Native Android 11.12.1 hard-codes MapOptions::withConstrainMode(
# ConstrainMode::HeightOnly) in NativeMapView's constructor. That mode keeps the Web Mercator
# world's north/south edges inside the visible rectangle, even after the public target-bounds API
# is cleared. The standalone atlas needs MapLibre's already-supported ConstrainMode::None so an
# active asset edge can be the drawable camera center. These fixed-width patches change only the
# pinned constructor's enum argument from 1 (HeightOnly) to 0 (None).
#
# The whole source AAR is hash-pinned by the caller. Each patch also verifies its exact original
# instruction bytes at the exact ABI-specific file offset before changing anything.
OSRS_MAPLIBRE_CONSTRAIN_MODE_PATCHES = (
    osrsMapLibreBinaryPatch(
        entry="jni/arm64-v8a/libmaplibre.so",
        offset=0x515A10,
        expected=bytes.fromhex("21 00 80 52"),
        replacement=bytes.fromhex("01 00 80 52"),
    ),
    osrsMapLibreBinaryPatch(
        entry="jni/armeabi-v7a/libmaplibre.so",
        offset=0x3ABAA4,
        expected=bytes.fromhex("01 21"),
        replacement=bytes.fromhex("00 21"),
    ),
    osrsMapLibreBinaryPatch(
        entry="jni/x86/libmaplibre.so",
        offset=0x482B11,
        expected=bytes.fromhex("01 00 00 00"),
        replacement=bytes.fromhex("00 00 00 00"),
    ),
    osrsMapLibreBinaryPatch(
        entry="jni/x86_64/libmaplibre.so",
        offset=0x4E07FE,
        expected=bytes.fromhex("01 00 00 00"),
        replacement=bytes.fromhex("00 00 00 00"),
    ),
)


class osrsMapLibreSanitizationError(RuntimeError):
    """Raised when the pinned AAR cannot be sanitized exactly."""


def osrs_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def osrs_sanitize_maplibre_aar(
    source: Path,
    output: Path,
    *,
    expected_source_sha256: str,
    expected_replacements: int,
    expected_constrain_patches: int,
    constrain_patches: Sequence[
        osrsMapLibreBinaryPatch
    ] = OSRS_MAPLIBRE_CONSTRAIN_MODE_PATCHES,
) -> dict[str, object]:
    if not source.is_file():
        raise osrsMapLibreSanitizationError(f"missing MapLibre AAR: {source}")
    source_sha256 = osrs_sha256(source)
    if source_sha256 != expected_source_sha256:
        raise osrsMapLibreSanitizationError(
            "MapLibre AAR hash mismatch: "
            f"expected {expected_source_sha256}, found {source_sha256}"
        )
    if expected_replacements <= 0:
        raise osrsMapLibreSanitizationError("expected replacements must be positive")
    if expected_constrain_patches != len(constrain_patches):
        raise osrsMapLibreSanitizationError(
            "MapLibre constrain-mode patch count mismatch: "
            f"expected {expected_constrain_patches}, configured {len(constrain_patches)}"
        )
    for patch in constrain_patches:
        if patch.offset < 0:
            raise osrsMapLibreSanitizationError(
                f"negative MapLibre binary patch offset for {patch.entry}"
            )
        if not patch.expected or len(patch.expected) != len(patch.replacement):
            raise osrsMapLibreSanitizationError(
                f"MapLibre binary patch must be nonempty and fixed-width: {patch.entry}"
            )
    patches_by_entry: dict[str, list[osrsMapLibreBinaryPatch]] = {}
    for patch in constrain_patches:
        patches_by_entry.setdefault(patch.entry, []).append(patch)

    output.parent.mkdir(parents=True, exist_ok=True)
    replacement_count = 0
    modified_entries: list[str] = []
    applied_constrain_patches: list[dict[str, object]] = []
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=f".{output.name}.", suffix=".tmp", dir=output.parent, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
        with zipfile.ZipFile(source, "r") as archive, zipfile.ZipFile(
            temporary_path, "w", allowZip64=True
        ) as sanitized:
            sanitized.comment = archive.comment
            for info in archive.infolist():
                payload = archive.read(info.filename)
                original_size = len(payload)
                occurrences = payload.count(OSRS_MAPLIBRE_HOST_PREFIX)
                if occurrences:
                    payload = payload.replace(
                        OSRS_MAPLIBRE_HOST_PREFIX, OSRS_MAPLIBRE_LOGICAL_PREFIX
                    )
                    replacement_count += occurrences
                    if info.filename not in modified_entries:
                        modified_entries.append(info.filename)
                for patch in patches_by_entry.get(info.filename, []):
                    end = patch.offset + len(patch.expected)
                    actual = payload[patch.offset:end]
                    if actual != patch.expected:
                        raise osrsMapLibreSanitizationError(
                            "MapLibre constrain-mode instruction mismatch for "
                            f"{patch.entry} at 0x{patch.offset:x}: expected "
                            f"{patch.expected.hex()}, found {actual.hex() or '<out-of-range>'}"
                        )
                    payload = (
                        payload[: patch.offset]
                        + patch.replacement
                        + payload[end:]
                    )
                    applied_constrain_patches.append(
                        {
                            "entry": patch.entry,
                            "offset": patch.offset,
                            "expected_hex": patch.expected.hex(),
                            "replacement_hex": patch.replacement.hex(),
                        }
                    )
                    if info.filename not in modified_entries:
                        modified_entries.append(info.filename)
                if len(payload) != original_size:
                    raise osrsMapLibreSanitizationError(
                        f"MapLibre native binary size changed for {info.filename}"
                    )
                sanitized.writestr(
                    info,
                    payload,
                    compress_type=info.compress_type,
                    compresslevel=9 if info.compress_type == zipfile.ZIP_DEFLATED else None,
                )

        if replacement_count != expected_replacements:
            raise osrsMapLibreSanitizationError(
                "MapLibre host-path replacement count mismatch: "
                f"expected {expected_replacements}, found {replacement_count}"
            )
        if len(applied_constrain_patches) != expected_constrain_patches:
            raise osrsMapLibreSanitizationError(
                "MapLibre applied constrain-mode patch count mismatch: "
                f"expected {expected_constrain_patches}, "
                f"found {len(applied_constrain_patches)}"
            )
        with zipfile.ZipFile(temporary_path, "r") as sanitized:
            residual = sum(
                sanitized.read(info.filename).count(OSRS_MAPLIBRE_HOST_PREFIX)
                for info in sanitized.infolist()
            )
            for patch in constrain_patches:
                payload = sanitized.read(patch.entry)
                actual = payload[
                    patch.offset : patch.offset + len(patch.replacement)
                ]
                if actual != patch.replacement:
                    raise osrsMapLibreSanitizationError(
                        "sanitized MapLibre AAR does not retain the expected "
                        f"ConstrainMode::None bytes for {patch.entry}"
                    )
        if residual:
            raise osrsMapLibreSanitizationError(
                f"sanitized MapLibre AAR retains {residual} upstream host paths"
            )
        os.replace(temporary_path, output)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)

    return {
        "schema_version": 1,
        "status": "PASS",
        "source_sha256": source_sha256,
        "output_sha256": osrs_sha256(output),
        "replacement_count": replacement_count,
        "constrain_mode": "none",
        "constrain_patch_count": len(applied_constrain_patches),
        "constrain_patches": applied_constrain_patches,
        "modified_entries": modified_entries,
        "replacement": OSRS_MAPLIBRE_LOGICAL_PREFIX.decode("ascii"),
    }


def _osrs_parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-source-sha256", required=True)
    parser.add_argument("--expected-replacements", required=True, type=int)
    parser.add_argument("--expected-constrain-patches", required=True, type=int)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _osrs_parse_args(argv)
    try:
        report = osrs_sanitize_maplibre_aar(
            args.input,
            args.output,
            expected_source_sha256=args.expected_source_sha256,
            expected_replacements=args.expected_replacements,
            expected_constrain_patches=args.expected_constrain_patches,
        )
    except (OSError, zipfile.BadZipFile, osrsMapLibreSanitizationError) as error:
        print(f"MapLibre sanitization failed: {error}", file=__import__("sys").stderr)
        return 2
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
