#!/usr/bin/env python3
"""Create a deterministic MapLibre AAR without upstream CI host paths."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path
from typing import Sequence


OSRS_MAPLIBRE_HOST_PREFIX = b"/home/runner/work/maplibre-native/maplibre-native/"
OSRS_MAPLIBRE_LOGICAL_PREFIX = b"third_party/maplibre-native/source_tree/upstream_/"

if len(OSRS_MAPLIBRE_HOST_PREFIX) != len(OSRS_MAPLIBRE_LOGICAL_PREFIX):
    raise RuntimeError("MapLibre path replacement must preserve native binary size")


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

    output.parent.mkdir(parents=True, exist_ok=True)
    replacement_count = 0
    modified_entries: list[str] = []
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
                occurrences = payload.count(OSRS_MAPLIBRE_HOST_PREFIX)
                if occurrences:
                    payload = payload.replace(
                        OSRS_MAPLIBRE_HOST_PREFIX, OSRS_MAPLIBRE_LOGICAL_PREFIX
                    )
                    replacement_count += occurrences
                    modified_entries.append(info.filename)
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
        with zipfile.ZipFile(temporary_path, "r") as sanitized:
            residual = sum(
                sanitized.read(info.filename).count(OSRS_MAPLIBRE_HOST_PREFIX)
                for info in sanitized.infolist()
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
        "modified_entries": modified_entries,
        "replacement": OSRS_MAPLIBRE_LOGICAL_PREFIX.decode("ascii"),
    }


def _osrs_parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-source-sha256", required=True)
    parser.add_argument("--expected-replacements", required=True, type=int)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _osrs_parse_args(argv)
    try:
        report = osrs_sanitize_maplibre_aar(
            args.input,
            args.output,
            expected_source_sha256=args.expected_source_sha256,
            expected_replacements=args.expected_replacements,
        )
    except (OSError, zipfile.BadZipFile, osrsMapLibreSanitizationError) as error:
        print(f"MapLibre sanitization failed: {error}", file=__import__("sys").stderr)
        return 2
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
