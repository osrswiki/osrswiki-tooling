#!/usr/bin/env python3
"""Fail-closed host-path validation for portable release trees and archives.

Build inputs and private command logs may retain exact host paths.  Public
release artifacts may not: they use release-relative paths, logical input/tool
references, URLs, and content hashes instead.  This module deliberately scans
JSON keys and values are scanned recursively; binary/text artifacts are scanned
for printable ASCII and UTF-16 strings.  Common nested-serialization escapes
are normalized so escaping a path cannot bypass the publication gate.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import copy
import gzip
import hashlib
import html
import io
import json
import re
import struct
import sys
import urllib.parse
import zipfile
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


OSRS_PATH_HYGIENE_SCHEMA_VERSION = 1
OSRS_PATH_NORMALIZATION_PASSES = 4


@dataclass(frozen=True)
class osrsPathScanLimits:
    """Hard resource limits for recursive public-artifact inspection.

    The defaults comfortably cover the complete underground-realm release and
    APK while placing deterministic upper bounds on untrusted nested input.
    Tests may supply smaller values to exercise every fail-closed limit.
    """

    max_container_depth: int = 6
    max_container_members: int = 100_000
    max_container_count: int = 10_000
    max_expanded_bytes: int = 2 * 1024 * 1024 * 1024
    max_single_member_bytes: int = 512 * 1024 * 1024
    max_compression_ratio: float = 1_000.0
    max_reference_count: int = 100_000
    max_encoded_token_bytes: int = 64 * 1024
    max_raw_container_bytes: int = 1024 * 1024 * 1024
    max_raw_region_count: int = 1_000_000
    max_raw_scanned_bytes: int = 2 * 1024 * 1024 * 1024


OSRS_DEFAULT_PATH_SCAN_LIMITS = osrsPathScanLimits()


class osrsPublicPathError(RuntimeError):
    """A release-blocking host-path hygiene error."""


_OSRS_BOUNDARY = r"(?:^|[\s\"'=>(\[\{,])"
_OSRS_FILE_URI_BOUNDARY = r"(?:^|[\s\"'=>(\[\{,:;])"
_OSRS_POSIX_ABSOLUTE = re.compile(_OSRS_BOUNDARY + r"/(?!/)[^\s\"'<>|]+")
_OSRS_WINDOWS_DRIVE = re.compile(
    _OSRS_BOUNDARY + r"(?:\\\\\?\\)?[A-Za-z]:[\\/]"
)
_OSRS_WINDOWS_UNC = re.compile(
    _OSRS_BOUNDARY
    + r"(?:\\\\(?:\?\\|\.\\)?|//)[^\\/\s\"'<>]+[\\/][^\\/\s\"'<>]+"
)
_OSRS_WINDOWS_ROOTED = re.compile(
    _OSRS_BOUNDARY + r"\\(?!\\)[^\\/\s\"'<>]+[\\/]"
)
_OSRS_FILE_URI = re.compile(
    _OSRS_FILE_URI_BOUNDARY + r"file:(?:(?:/{1,3})|(?:\\{1,3}))", re.IGNORECASE
)
_OSRS_LITERAL_UNICODE_SLASH = re.compile(r"\\u(?:002f|2215)", re.IGNORECASE)
_OSRS_LITERAL_UNICODE_BACKSLASH = re.compile(r"\\u(?:005c|29f5)", re.IGNORECASE)
_OSRS_LITERAL_UNICODE_DOT = re.compile(r"\\u(?:002e)", re.IGNORECASE)
_OSRS_LITERAL_HEX_SLASH = re.compile(r"\\x2f", re.IGNORECASE)
_OSRS_LITERAL_HEX_BACKSLASH = re.compile(r"\\x5c", re.IGNORECASE)
_OSRS_LITERAL_HEX_DOT = re.compile(r"\\x2e", re.IGNORECASE)
_OSRS_BUILD_HOST_POSIX_ROOT = re.compile(
    r"(?:^|[\s\"'=>(\[\{,])/(?:"
    r"Users|home|root|Volumes|workspace|workspaces|build|builds|mnt|opt|tmp|srv|"
    r"__w|github/workspace|agent|runner|private/(?:tmp|var)|var/folders|"
    r"Library/Developer|Applications/Xcode"
    r")(?:/|$)",
    re.IGNORECASE,
)
_OSRS_ASCII_PRINTABLE_RUN = re.compile(rb"[\x20-\x7e]{5,}")
_OSRS_UTF16LE_PRINTABLE_RUN = re.compile(rb"(?:[\x20-\x7e]\x00){5,}")
_OSRS_UTF16BE_PRINTABLE_RUN = re.compile(rb"(?:\x00[\x20-\x7e]){5,}")
_OSRS_BINARY_TILDE_PATH_BYTES = re.compile(
    rb"~[A-Za-z0-9._-]+[\\/][A-Za-z0-9][A-Za-z0-9._+@ \-]{0,254}"
    rb"(?:[\\/][A-Za-z0-9._+@ \-]{1,255})*[.,;:!?\)\]\}>]?"
)
_OSRS_HEX_TOKEN = re.compile(r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}){5,}(?![0-9A-Fa-f])")
_OSRS_BASE64_TOKEN = re.compile(
    r"(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{12,}={0,2}(?![A-Za-z0-9_+/-])"
)
_OSRS_ARCHIVE_POSIX_PATH = re.compile(
    _OSRS_BOUNDARY + r"(?P<path>/(?!/)[^\s\"'<>|]+)"
)
_OSRS_ARCHIVE_WINDOWS_DRIVE_PATH = re.compile(
    _OSRS_BOUNDARY
    + r"(?P<path>(?:\\\\\?\\)?[A-Za-z]:[\\/][^\s\"'<>|]+)"
)
_OSRS_ARCHIVE_WINDOWS_UNC_PATH = re.compile(
    _OSRS_BOUNDARY
    + r"(?P<path>(?:\\\\(?:\?\\|\.\\)?|//)[^\s\"'<>|]+)"
)
_OSRS_ARCHIVE_WINDOWS_ROOTED_PATH = re.compile(
    _OSRS_BOUNDARY + r"(?P<path>\\(?!\\)[^\s\"'<>|]+)"
)
_OSRS_ARCHIVE_FILE_URI_PATH = re.compile(
    _OSRS_FILE_URI_BOUNDARY
    + r"(?P<path>file:(?:(?:/{1,3})|(?:\\{1,3}))[^\s\"'<>|]+)",
    re.IGNORECASE,
)
_OSRS_WINDOWS_ROOT_COMPONENTS = {
    "agent",
    "build",
    "build-root",
    "builds",
    "ci",
    "home",
    "runner",
    "users",
    "workspace",
    "workspaces",
}
_OSRS_PLAIN_PATH_COMPONENT = re.compile(r"^[A-Za-z0-9._+@ -]{1,255}$")
_OSRS_CONTAINER_SUFFIXES = {".aar", ".apk", ".jar", ".zip"}
_OSRS_GZIP_SUFFIXES = {".gz", ".gzip"}
_OSRS_TEXT_LIKE_SUFFIXES = {
    ".css",
    ".csv",
    ".html",
    ".js",
    ".jsonl",
    ".log",
    ".md",
    ".properties",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}
_OSRS_BINARY_PATH_DELIMITER_BYTES = frozenset(b"\0\r\n\t \"'=,;:()[]{}")
_OSRS_REFERENCE_FIELD_NAMES = {
    "artifact",
    "artifact_path",
    "file",
    "file_path",
    "log",
    "log_path",
    "path",
    "report",
    "report_path",
}
_OSRS_REFERENCE_COLLECTION_NAMES = {
    "artifacts",
    "evidence",
    "files",
    "logs",
    "outputs",
    "reports",
}


@dataclass
class _osrsPathScanState:
    root: Path | None
    limits: osrsPathScanLimits
    on_json: Callable[[Any, str, Path | None], None] | None = None
    scanned_artifacts: list[str] = field(default_factory=list)
    json_artifact_count: int = 0
    non_json_artifact_count: int = 0
    native_library_count: int = 0
    printable_string_count: int = 0
    container_count: int = 0
    container_member_count: int = 0
    zip_payload_member_inspected_count: int = 0
    zip_empty_directory_member_validated_count: int = 0
    expanded_bytes: int = 0
    referenced_artifact_count: int = 0
    zip_container_bytes: int = 0
    zip_classified_bytes: int = 0
    zip_member_payload_bytes: int = 0
    zip_compressed_payload_bytes: int = 0
    zip_scanned_raw_bytes: int = 0
    zip_raw_region_count: int = 0
    zip_unclassified_bytes: int = 0
    findings: list[dict[str, Any]] = field(default_factory=list)

    def consume_expanded(self, count: int, provenance: str) -> None:
        if count < 0 or count > self.limits.max_single_member_bytes:
            raise osrsPublicPathError(
                f"artifact member exceeds the {self.limits.max_single_member_bytes}-byte "
                f"limit: {provenance}"
            )
        if self.expanded_bytes + count > self.limits.max_expanded_bytes:
            raise osrsPublicPathError(
                f"recursive artifact expansion exceeds the "
                f"{self.limits.max_expanded_bytes}-byte limit at {provenance}"
            )
        self.expanded_bytes += count


@dataclass(frozen=True)
class _osrsZipByteRegion:
    start: int
    end: int
    kind: str
    provenance: str
    scan_raw: bool = True
    compressed_payload: bool = False

    @property
    def size(self) -> int:
        return self.end - self.start


class _osrsArchiveHostPathScanContext(Enum):
    SEMANTIC_TEXT = "semantic_text"
    ARCHIVE_MEMBER_NAME = "archive_member_name"
    BINARY_PRINTABLE_ISLAND = "binary_printable_island"
    DESCRIPTOR_ONLY_JAVA_DALVIK_OBJECT = "descriptor_only_java_dalvik_object"


@dataclass(frozen=True)
class _osrsTildeHomeCandidate:
    path: str
    start_index: int
    end_index: int

    def group(self, name: str) -> str:
        if name != "path":
            raise IndexError(name)
        return self.path

    def start(self, name: str = "path") -> int:
        if name != "path":
            raise IndexError(name)
        return self.start_index

    def end(self, name: str = "path") -> int:
        if name != "path":
            raise IndexError(name)
        return self.end_index


def _osrs_ascii_alpha(value: str) -> bool:
    return "A" <= value <= "Z" or "a" <= value <= "z"


def _osrs_ascii_digit(value: str) -> bool:
    return "0" <= value <= "9"


def _osrs_tilde_home_user_char(value: str) -> bool:
    return _osrs_ascii_alpha(value) or _osrs_ascii_digit(value) or value in "._-"


def _osrs_tilde_home_component_char(value: str) -> bool:
    return _osrs_ascii_alpha(value) or _osrs_ascii_digit(value) or value in "._+@-"


def _osrs_tilde_home_path_body_char(value: str) -> bool:
    return _osrs_tilde_home_component_char(value) or value in "/\\"


def _osrs_tilde_home_candidate_scan_views(value: str) -> Iterable[str]:
    yield value
    slash_normalized = value.replace("\\", "/")
    if slash_normalized != value:
        yield slash_normalized


def _osrs_raw_tilde_home_candidates(value: str) -> Iterable[_osrsTildeHomeCandidate]:
    for start, character in enumerate(value):
        if character != "~":
            continue
        cursor = start + 1
        while cursor < len(value) and _osrs_tilde_home_user_char(value[cursor]):
            cursor += 1
        if cursor >= len(value) or value[cursor] not in "/\\":
            continue
        cursor += 1
        while cursor < len(value) and _osrs_tilde_home_path_body_char(value[cursor]):
            cursor += 1
        yield _osrsTildeHomeCandidate(value[start:cursor], start, cursor)


def _osrs_decoded_unit_tilde_home_candidates(
    value: str,
) -> Iterable[_osrsTildeHomeCandidate]:
    """Yield home-path candidates from one decoded string unit.

    The extractor scans every tilde in the decoded unit instead of depending on
    a left-boundary regex.  Punctuation and archive-member separators terminate
    the candidate so adjacent tokens such as ``~user/project;/more`` are still
    evaluated as the real ``~user/project`` home reference.  Raw and
    slash-normalized views are both scanned; normalization can add evidence, but
    it never suppresses a raw home-path candidate.
    """

    for scan_view in _osrs_tilde_home_candidate_scan_views(value):
        yield from _osrs_raw_tilde_home_candidates(scan_view)


def osrs_host_absolute_path_kinds(value: str) -> tuple[str, ...]:
    """Return every host-path class found after bounded escape normalization."""

    kinds: set[str] = set()
    kinds.update(
        _osrs_archive_host_path_kinds(
            value, context=_osrsArchiveHostPathScanContext.SEMANTIC_TEXT
        )
    )
    for variant in _osrs_serialization_variants(value):
        if _OSRS_FILE_URI.search(variant):
            kinds.add("file_uri")
        if _OSRS_WINDOWS_DRIVE.search(variant):
            kinds.add("windows_drive_absolute")
        if _OSRS_WINDOWS_UNC.search(variant):
            kinds.add("windows_unc_absolute")
        if _OSRS_WINDOWS_ROOTED.search(variant):
            kinds.add("windows_rooted_absolute")
        if _OSRS_POSIX_ABSOLUTE.search(variant):
            kinds.add("posix_absolute")
    return tuple(sorted(kinds))


def osrs_find_host_absolute_paths(value: Any) -> list[dict[str, Any]]:
    """Recursively find host paths in all JSON-compatible keys and values.

    Findings intentionally omit the offending string.  A failed scan can be
    retained without copying the private host path into another artifact.
    """

    findings: list[dict[str, Any]] = []

    def visit(current: Any, pointer: str) -> None:
        if isinstance(current, Mapping):
            for key, child in current.items():
                key_text = str(key)
                key_kinds = osrs_host_absolute_path_kinds(key_text)
                child_pointer = f"{pointer}/{_osrs_json_pointer_token(key_text)}"
                if key_kinds:
                    findings.append(
                        {
                            "json_pointer": child_pointer,
                            "location": "key",
                            "kinds": list(key_kinds),
                        }
                    )
                visit(child, child_pointer)
        elif isinstance(current, (list, tuple)):
            for index, child in enumerate(current):
                visit(child, f"{pointer}/{index}")
        elif isinstance(current, str):
            kinds = osrs_host_absolute_path_kinds(current)
            if kinds:
                findings.append(
                    {
                        "json_pointer": pointer,
                        "location": "value",
                        "kinds": list(kinds),
                    }
                )

    visit(value, "")
    return findings


def osrs_assert_public_json_portable(value: Any, artifact: str = "public JSON") -> None:
    """Raise when a JSON value contains a host-absolute path."""

    findings = osrs_find_host_absolute_paths(value)
    if findings:
        summary = ", ".join(
            f"{item['json_pointer'] or '/'} ({'+'.join(item['kinds'])})"
            for item in findings[:8]
        )
        remainder = len(findings) - min(8, len(findings))
        if remainder:
            summary += f", plus {remainder} more"
        raise osrsPublicPathError(
            f"{artifact} contains {len(findings)} host-absolute path string(s): "
            f"{summary}"
        )


def osrs_assert_public_binary_portable(
    data: bytes,
    artifact: str = "public binary",
) -> None:
    """Apply the release scanner's printable-island rules to one binary payload."""

    if not isinstance(data, bytes):
        raise TypeError("public binary payload must be bytes")
    state = _osrsPathScanState(root=None, limits=OSRS_DEFAULT_PATH_SCAN_LIMITS)
    _osrs_scan_leaf(data, artifact, ".bin", state, disk_path=None)
    _osrs_raise_binary_findings(state, artifact)


def osrs_portabilize_source_snapshot(value: Any) -> Any:
    """Copy a pinned source snapshot while replacing only location fields.

    Acquisition revisions, hashes, timestamps, projection numbers, and the
    historical acquisition candidate remain unchanged.  A whole-string host
    location in a path-like field becomes a stable logical reference derived
    solely from its JSON pointer.  Host paths embedded in prose or other fields
    fail closed instead of being silently redacted.
    """

    result = copy.deepcopy(value)

    def visit(current: Any, tokens: tuple[str, ...], field_name: str | None) -> Any:
        if isinstance(current, Mapping):
            replaced: dict[Any, Any] = {}
            for key, child in current.items():
                key_text = str(key)
                if osrs_host_absolute_path_kinds(key_text):
                    raise osrsPublicPathError(
                        "source snapshot contains a host-absolute JSON key at "
                        f"/{'/'.join(tokens + (key_text,))}"
                    )
                replaced[key] = visit(child, tokens + (key_text,), key_text)
            return replaced
        if isinstance(current, list):
            return [
                visit(child, tokens + (str(index),), field_name)
                for index, child in enumerate(current)
            ]
        if isinstance(current, tuple):
            return tuple(
                visit(child, tokens + (str(index),), field_name)
                for index, child in enumerate(current)
            )
        if not isinstance(current, str):
            return current

        kinds = osrs_host_absolute_path_kinds(current)
        if not kinds:
            return current
        if field_name is None or not _osrs_path_field_name(field_name):
            pointer = "/" + "/".join(tokens)
            raise osrsPublicPathError(
                "source snapshot contains a host path outside a path-like field at "
                f"{pointer} ({'+'.join(kinds)})"
            )
        if not _osrs_is_standalone_host_location(current):
            pointer = "/" + "/".join(tokens)
            raise osrsPublicPathError(
                "source snapshot contains an embedded host path that cannot be "
                f"portabilized safely at {pointer} ({'+'.join(kinds)})"
            )
        logical_tokens = [_osrs_logical_token(token) for token in tokens]
        return "input://source-snapshot/" + "/".join(logical_tokens)

    portable = visit(result, (), None)
    osrs_assert_public_json_portable(portable, "portable source snapshot")
    return portable


def osrs_validate_public_json_tree(
    root: Path, *, limits: osrsPathScanLimits = OSRS_DEFAULT_PATH_SCAN_LIMITS
) -> dict[str, Any]:
    """Validate every JSON file and every local artifact it indexes.

    Indexed references are followed regardless of extension.  A missing,
    ambiguous, symlinked, or out-of-root reference fails publication.
    """

    return _osrs_validate_public_tree(
        root, json_only=True, scope="public_release_json_and_reference_closure", limits=limits
    )


def osrs_validate_public_release_tree(
    root: Path, *, limits: osrsPathScanLimits = OSRS_DEFAULT_PATH_SCAN_LIMITS
) -> dict[str, Any]:
    """Validate every file and recursively decoded container below ``root``."""

    return _osrs_validate_public_tree(
        root, json_only=False, scope="public_release_all_files", limits=limits
    )


def osrs_validate_public_artifact_closure(
    root: Path, *, limits: osrsPathScanLimits = OSRS_DEFAULT_PATH_SCAN_LIMITS
) -> dict[str, Any]:
    """Validate a complete retained release/evidence/index closure."""

    return _osrs_validate_public_tree(
        root, json_only=False, scope="public_artifact_and_index_closure", limits=limits
    )


def osrs_validate_public_archive(
    path: Path, *, limits: osrsPathScanLimits = OSRS_DEFAULT_PATH_SCAN_LIMITS
) -> dict[str, Any]:
    """Validate every member and nested ZIP/gzip payload in an APK/archive."""

    if not path.is_file():
        raise osrsPublicPathError(f"public archive is not a file: {path.name}")
    state = _osrsPathScanState(root=None, limits=limits)
    try:
        data = path.read_bytes()
    except OSError as error:
        raise osrsPublicPathError(
            f"public archive is unreadable: {path.name}: {error}"
        ) from error
    _osrs_scan_payload(
        data,
        path.name,
        path.suffix.casefold(),
        state,
        depth=0,
        record_top_level_members=True,
    )
    _osrs_raise_binary_findings(state, "assembled archive")
    report = _osrs_scan_report(state, scope="assembled_archive_all_members")
    report["native_library_count"] = state.native_library_count
    report["policy"]["archive_scope"] = (
        "every regular decompressed member plus every validated empty directory and every "
        "structurally classified raw ZIP/JAR/AAR/APK metadata, signing-block, gap, and "
        "trailer region plus recursively decoded gzip members under hard expansion limits"
    )
    report["checks"]["all_archive_members_scanned"] = report["checks"][
        "all_zip_members_inspected_or_validated_empty_directories"
    ]
    return report


def _osrs_validate_public_tree(
    root: Path,
    *,
    json_only: bool,
    scope: str,
    limits: osrsPathScanLimits,
) -> dict[str, Any]:
    resolved_root = root.resolve()
    if not resolved_root.is_dir():
        raise osrsPublicPathError(f"public artifact root is not a directory: {root}")

    root_entries = list(resolved_root.rglob("*"))
    for entry in root_entries:
        if entry.is_symlink():
            raise osrsPublicPathError(
                "public artifact closure contains a symlink: "
                f"{entry.relative_to(resolved_root).as_posix()}"
            )
        if not entry.is_file() and not entry.is_dir():
            raise osrsPublicPathError(
                "public artifact closure contains a non-regular entry: "
                f"{entry.relative_to(resolved_root).as_posix()}"
            )
    initial_paths = sorted(
        (
            path
            for path in root_entries
            if path.is_file() and (not json_only or path.suffix.casefold() == ".json")
        ),
        key=lambda path: path.relative_to(resolved_root).as_posix(),
    )
    state = _osrsPathScanState(root=resolved_root, limits=limits)
    queue = list(initial_paths)
    seen: set[Path] = set()
    reference_records: list[tuple[Path, str, str, str | None]] = []

    def on_json(value: Any, provenance: str, disk_path: Path | None) -> None:
        osrs_assert_public_json_portable(value, provenance)
        if disk_path is None or not _osrs_json_is_reference_index(
            provenance, value
        ):
            return
        for reference, pointer, expected_sha256 in _osrs_local_json_references(value):
            reference_records.append(
                (disk_path, reference, pointer, expected_sha256)
            )

    state.on_json = on_json
    queue_index = 0
    while queue_index < len(queue):
        path = queue[queue_index]
        queue_index += 1
        if path.is_symlink():
            raise osrsPublicPathError(
                "public artifact closure contains a symlink: "
                f"{path.relative_to(resolved_root).as_posix()}"
            )
        resolved_path = path.resolve()
        _osrs_require_within_root(resolved_path, resolved_root, "artifact")
        if resolved_path in seen:
            continue
        seen.add(resolved_path)
        relative = resolved_path.relative_to(resolved_root).as_posix()
        name_kinds = _osrs_archive_host_path_kinds(
            relative,
            context=_osrsArchiveHostPathScanContext.ARCHIVE_MEMBER_NAME,
        )
        if name_kinds:
            state.findings.append(
                {
                    "artifact": relative,
                    "encoding": "relative_file_name",
                    "kinds": list(name_kinds),
                }
            )
        try:
            data = resolved_path.read_bytes()
        except OSError as error:
            raise osrsPublicPathError(
                f"public artifact is unreadable: {relative}: {error}"
            ) from error
        state.scanned_artifacts.append(relative)
        state.consume_expanded(len(data), relative)
        _osrs_scan_payload(
            data,
            relative,
            resolved_path.suffix.casefold(),
            state,
            depth=0,
            disk_path=resolved_path,
        )

        while reference_records:
            source_path, reference, pointer, expected_sha256 = reference_records.pop(0)
            state.referenced_artifact_count += 1
            if state.referenced_artifact_count > limits.max_reference_count:
                raise osrsPublicPathError(
                    "public artifact reference count exceeds the "
                    f"{limits.max_reference_count}-reference limit at "
                    f"{source_path.relative_to(resolved_root).as_posix()}{pointer}"
                )
            target = _osrs_resolve_local_reference(
                resolved_root, source_path, reference, pointer
            )
            if target.is_symlink():
                raise osrsPublicPathError(
                    "public artifact reference resolves to a symlink: "
                    f"{source_path.relative_to(resolved_root).as_posix()}{pointer}"
                )
            if target.is_dir():
                queue.extend(
                    sorted(
                        (child for child in target.rglob("*") if child.is_file()),
                        key=lambda child: child.relative_to(resolved_root).as_posix(),
                    )
                )
            else:
                if expected_sha256 is not None:
                    actual_sha256 = hashlib.sha256(target.read_bytes()).hexdigest()
                    if actual_sha256 != expected_sha256:
                        raise osrsPublicPathError(
                            "indexed artifact SHA-256 mismatch at "
                            f"{source_path.relative_to(resolved_root).as_posix()}{pointer}"
                        )
                queue.append(target)

    _osrs_raise_binary_findings(state, "public artifact closure")
    state.scanned_artifacts.sort()
    report = _osrs_scan_report(state, scope=scope)
    report["policy"]["release_tree_scope"] = (
        "every selected regular file, every recursively decoded regular ZIP/gzip member, "
        "every validated empty ZIP directory, and every resolved local artifact reference "
        "regardless of extension"
    )
    report["checks"]["all_public_release_files_scanned"] = not json_only
    report["checks"]["all_indexed_artifacts_resolved_and_scanned"] = True
    return report


def _osrs_scan_payload(
    data: bytes,
    provenance: str,
    suffix: str,
    state: _osrsPathScanState,
    *,
    depth: int,
    disk_path: Path | None = None,
    record_top_level_members: bool = False,
) -> None:
    zip_magic = data.startswith((b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"))
    gzip_magic = data.startswith(b"\x1f\x8b")
    if zip_magic or suffix in _OSRS_CONTAINER_SUFFIXES:
        if not zip_magic:
            raise osrsPublicPathError(
                f"declared ZIP/JAR/AAR/APK payload is invalid: {provenance}"
            )
        _osrs_scan_zip_bytes(
            data,
            provenance,
            state,
            depth=depth,
            record_top_level_members=record_top_level_members,
        )
        return
    if gzip_magic or suffix in _OSRS_GZIP_SUFFIXES:
        if not gzip_magic:
            raise osrsPublicPathError(f"declared gzip payload is invalid: {provenance}")
        _osrs_scan_gzip_bytes(data, provenance, state, depth=depth)
        return
    _osrs_scan_leaf(data, provenance, suffix, state, disk_path=disk_path)


def _osrs_structural_zip_regions(
    data: bytes,
    archive: zipfile.ZipFile,
    provenance: str,
) -> list[_osrsZipByteRegion]:
    """Return a complete, non-overlapping structural partition of a ZIP/APK.

    Regular member payload regions are recursively inspected through ``ZipFile``;
    directory members are accepted only when their decoded, compressed, and CRC
    payload metadata are all empty. Every other raw region is printable-scanned
    directly, including bytes not exposed by ``ZipInfo`` such as local-only extras,
    APK Signing Blocks, and trailers.
    """

    central_start = archive.start_dir
    if central_start < 0 or central_start > len(data):
        raise osrsPublicPathError(
            f"ZIP central directory is outside the container: {provenance}"
        )
    eocd_start, eocd_end, eocd = _osrs_find_zip_eocd(
        data, archive, provenance, central_start
    )
    declared_entries = eocd[3]
    declared_central_size = eocd[4]
    zip64_required = declared_entries == 0xFFFF or declared_central_size == 0xFFFFFFFF
    members_in_central_order = archive.infolist()
    if not zip64_required and declared_entries != len(members_in_central_order):
        raise osrsPublicPathError(
            f"ZIP EOCD member count disagrees with the parsed directory: {provenance}"
        )

    central_records_end, central_regions = _osrs_parse_zip_central_directory(
        data,
        central_start,
        members_in_central_order,
        provenance,
    )
    if zip64_required:
        central_end = central_records_end
    else:
        central_end = central_start + declared_central_size
        if central_end < central_records_end or central_end > eocd_start:
            raise osrsPublicPathError(
                f"ZIP central-directory size is inconsistent: {provenance}"
            )
    central_tail_regions = _osrs_parse_zip_central_tail(
        data, central_records_end, central_end, provenance
    )

    signing_start, signing_regions = _osrs_parse_apk_signing_block(
        data, central_start, provenance
    )
    local_limit = signing_start if signing_start is not None else central_start
    members_by_offset = sorted(
        members_in_central_order, key=lambda member: member.header_offset
    )
    local_regions: list[_osrsZipByteRegion] = []
    cursor = 0
    for index, member in enumerate(members_by_offset):
        header_start = member.header_offset
        next_header = (
            members_by_offset[index + 1].header_offset
            if index + 1 < len(members_by_offset)
            else local_limit
        )
        if header_start < cursor or header_start >= local_limit or next_header > local_limit:
            raise osrsPublicPathError(
                f"ZIP local-header offsets overlap or escape their region: {provenance}"
            )
        if cursor < header_start:
            kind = "zip-prefix" if cursor == 0 else "local-record-gap"
            _osrs_append_zip_region(
                local_regions,
                cursor,
                header_start,
                kind,
                f"{provenance}!/{kind}@{cursor}:{header_start}",
            )
        member_provenance = f"{provenance}!/{member.filename}"
        local_header_end, payload_end, method, flags = _osrs_parse_zip_local_header(
            data, member, header_start, next_header, member_provenance
        )
        _osrs_append_zip_region(
            local_regions,
            header_start,
            local_header_end,
            "local-header-name-extra",
            f"{member_provenance}:local-header@{header_start}:{local_header_end}",
        )
        _osrs_append_zip_region(
            local_regions,
            local_header_end,
            payload_end,
            "member-payload",
            f"{member_provenance}:payload@{local_header_end}:{payload_end}",
            scan_raw=False,
            compressed_payload=method != zipfile.ZIP_STORED,
        )
        descriptor_end = payload_end
        if flags & 0x08:
            descriptor_end = _osrs_parse_zip_data_descriptor(
                data, payload_end, next_header, member, member_provenance
            )
            _osrs_append_zip_region(
                local_regions,
                payload_end,
                descriptor_end,
                "data-descriptor",
                f"{member_provenance}:descriptor@{payload_end}:{descriptor_end}",
            )
        if descriptor_end > next_header:
            raise osrsPublicPathError(
                f"ZIP member overlaps its following record: {member_provenance}"
            )
        cursor = descriptor_end
    if cursor < local_limit:
        kind = "zip-prefix-or-local-gap" if not members_by_offset else "local-record-gap"
        _osrs_append_zip_region(
            local_regions,
            cursor,
            local_limit,
            kind,
            f"{provenance}!/{kind}@{cursor}:{local_limit}",
        )
    elif cursor > local_limit:
        raise osrsPublicPathError(
            f"ZIP local records overlap the central metadata: {provenance}"
        )

    post_central_regions = _osrs_parse_zip64_and_gap(
        data,
        central_end,
        eocd_start,
        eocd,
        central_start,
        provenance,
        zip64_required,
    )
    eocd_regions: list[_osrsZipByteRegion] = []
    _osrs_append_zip_region(
        eocd_regions,
        eocd_start,
        eocd_end,
        "end-of-central-directory",
        f"{provenance}!/EOCD@{eocd_start}:{eocd_end}",
    )
    if eocd_end < len(data):
        _osrs_append_zip_region(
            eocd_regions,
            eocd_end,
            len(data),
            "zip-trailer",
            f"{provenance}!/TRAILER@{eocd_end}:{len(data)}",
        )

    regions = (
        local_regions
        + signing_regions
        + central_regions
        + central_tail_regions
        + post_central_regions
        + eocd_regions
    )
    _osrs_validate_zip_partition(regions, len(data), provenance)
    return sorted(regions, key=lambda region: region.start)


def _osrs_find_zip_eocd(
    data: bytes,
    archive: zipfile.ZipFile,
    provenance: str,
    central_start: int,
) -> tuple[int, int, tuple[int, int, int, int, int, int, int]]:
    signature = b"PK\x05\x06"
    search_end = len(data)
    while True:
        offset = data.rfind(signature, 0, search_end)
        if offset < 0:
            break
        search_end = offset
        if offset + 22 > len(data):
            continue
        unpacked = struct.unpack_from("<4s4H2IH", data, offset)
        disk_number, central_disk, entries_disk, entries_total = unpacked[1:5]
        central_size, central_offset, comment_size = unpacked[5:8]
        end = offset + 22 + comment_size
        if end > len(data):
            continue
        if data[offset + 22 : end] != archive.comment:
            continue
        if disk_number != 0 or central_disk != 0 or entries_disk != entries_total:
            continue
        if central_size != 0xFFFFFFFF and central_start + central_size > offset:
            continue
        return (
            offset,
            end,
            (
                disk_number,
                central_disk,
                entries_disk,
                entries_total,
                central_size,
                central_offset,
                comment_size,
            ),
        )
    raise osrsPublicPathError(f"ZIP EOCD is missing or malformed: {provenance}")


def _osrs_parse_zip_central_directory(
    data: bytes,
    start: int,
    members: Sequence[zipfile.ZipInfo],
    provenance: str,
) -> tuple[int, list[_osrsZipByteRegion]]:
    regions: list[_osrsZipByteRegion] = []
    cursor = start
    for index, member in enumerate(members):
        if cursor + 46 > len(data) or data[cursor : cursor + 4] != b"PK\x01\x02":
            raise osrsPublicPathError(
                f"ZIP central record {index} is missing or truncated: {provenance}"
            )
        fields = struct.unpack_from("<4s6H3I5H2I", data, cursor)
        name_size, extra_size, comment_size = fields[10:13]
        record_end = cursor + 46 + name_size + extra_size + comment_size
        if record_end > len(data):
            raise osrsPublicPathError(
                f"ZIP central record {index} escapes the container: {provenance}"
            )
        _osrs_append_zip_region(
            regions,
            cursor,
            record_end,
            "central-directory-record",
            f"{provenance}!/{member.filename}:central@{cursor}:{record_end}",
        )
        cursor = record_end
    return cursor, regions


def _osrs_parse_zip_central_tail(
    data: bytes,
    start: int,
    end: int,
    provenance: str,
) -> list[_osrsZipByteRegion]:
    regions: list[_osrsZipByteRegion] = []
    cursor = start
    while cursor < end:
        signature = data[cursor : cursor + 4]
        if signature == b"PK\x05\x05":
            if cursor + 6 > end:
                raise osrsPublicPathError(
                    f"ZIP central digital signature is truncated: {provenance}"
                )
            size = struct.unpack_from("<H", data, cursor + 4)[0]
            record_end = cursor + 6 + size
            kind = "central-digital-signature"
        elif signature == b"PK\x06\x08":
            if cursor + 8 > end:
                raise osrsPublicPathError(
                    f"ZIP archive-extra record is truncated: {provenance}"
                )
            size = struct.unpack_from("<I", data, cursor + 4)[0]
            record_end = cursor + 8 + size
            kind = "archive-extra-data"
        else:
            raise osrsPublicPathError(
                f"ZIP central directory contains an unrecognized record at byte {cursor}: "
                f"{provenance}"
            )
        if record_end > end:
            raise osrsPublicPathError(
                f"ZIP {kind} record exceeds the declared central directory: {provenance}"
            )
        _osrs_append_zip_region(
            regions,
            cursor,
            record_end,
            kind,
            f"{provenance}!/{kind}@{cursor}:{record_end}",
        )
        cursor = record_end
    return regions


def _osrs_parse_zip_local_header(
    data: bytes,
    member: zipfile.ZipInfo,
    start: int,
    limit: int,
    provenance: str,
) -> tuple[int, int, int, int]:
    if start + 30 > limit or data[start : start + 4] != b"PK\x03\x04":
        raise osrsPublicPathError(f"ZIP local header is missing or truncated: {provenance}")
    fields = struct.unpack_from("<4s5H3I2H", data, start)
    flags, method = fields[2], fields[3]
    compressed_size, uncompressed_size = fields[7], fields[8]
    name_size, extra_size = fields[9], fields[10]
    header_end = start + 30 + name_size + extra_size
    payload_end = header_end + member.compress_size
    if header_end > limit or payload_end > limit:
        raise osrsPublicPathError(f"ZIP local record escapes its region: {provenance}")
    if flags != member.flag_bits or method != member.compress_type:
        raise osrsPublicPathError(
            f"ZIP local and central compression metadata disagree: {provenance}"
        )
    if not flags & 0x08:
        if compressed_size not in (member.compress_size, 0xFFFFFFFF):
            raise osrsPublicPathError(
                f"ZIP local compressed size disagrees with its central record: {provenance}"
            )
        if uncompressed_size not in (member.file_size, 0xFFFFFFFF):
            raise osrsPublicPathError(
                f"ZIP local expanded size disagrees with its central record: {provenance}"
            )
    return header_end, payload_end, method, flags


def _osrs_parse_zip_data_descriptor(
    data: bytes,
    start: int,
    limit: int,
    member: zipfile.ZipInfo,
    provenance: str,
) -> int:
    cursor = start
    if data[cursor : cursor + 4] == b"PK\x07\x08":
        cursor += 4
    if cursor + 12 > limit:
        raise osrsPublicPathError(f"ZIP data descriptor is truncated: {provenance}")
    crc = struct.unpack_from("<I", data, cursor)[0]
    if crc != member.CRC:
        raise osrsPublicPathError(f"ZIP data descriptor CRC is inconsistent: {provenance}")
    standard_compressed, standard_expanded = struct.unpack_from("<II", data, cursor + 4)
    if standard_compressed == member.compress_size and standard_expanded == member.file_size:
        return cursor + 12
    if cursor + 20 <= limit:
        zip64_compressed, zip64_expanded = struct.unpack_from("<QQ", data, cursor + 4)
        if zip64_compressed == member.compress_size and zip64_expanded == member.file_size:
            return cursor + 20
    raise osrsPublicPathError(f"ZIP data descriptor sizes are inconsistent: {provenance}")


def _osrs_parse_apk_signing_block(
    data: bytes,
    central_start: int,
    provenance: str,
) -> tuple[int | None, list[_osrsZipByteRegion]]:
    magic = b"APK Sig Block 42"
    if central_start < 24 or data[central_start - 16 : central_start] != magic:
        return None, []
    trailing_size = struct.unpack_from("<Q", data, central_start - 24)[0]
    if trailing_size < 24 or trailing_size > central_start - 8:
        raise osrsPublicPathError(f"APK Signing Block size is invalid: {provenance}")
    start = central_start - trailing_size - 8
    leading_size = struct.unpack_from("<Q", data, start)[0]
    if leading_size != trailing_size:
        raise osrsPublicPathError(
            f"APK Signing Block leading and trailing sizes disagree: {provenance}"
        )
    regions: list[_osrsZipByteRegion] = []
    _osrs_append_zip_region(
        regions,
        start,
        start + 8,
        "apk-signing-block-size",
        f"{provenance}!/APK-SIGNING-BLOCK:size@{start}:{start + 8}",
    )
    cursor = start + 8
    pairs_end = central_start - 24
    pair_index = 0
    while cursor < pairs_end:
        if cursor + 12 > pairs_end:
            raise osrsPublicPathError(
                f"APK Signing Block pair header is truncated: {provenance}"
            )
        pair_size = struct.unpack_from("<Q", data, cursor)[0]
        if pair_size < 4 or pair_size > pairs_end - cursor - 8:
            raise osrsPublicPathError(
                f"APK Signing Block pair size is invalid: {provenance}"
            )
        pair_end = cursor + 8 + pair_size
        pair_id = struct.unpack_from("<I", data, cursor + 8)[0]
        pair_label = f"pair-{pair_index}-0x{pair_id:08x}"
        _osrs_append_zip_region(
            regions,
            cursor,
            cursor + 12,
            "apk-signing-pair-header",
            f"{provenance}!/APK-SIGNING-BLOCK:{pair_label}:header@{cursor}:{cursor + 12}",
        )
        _osrs_append_zip_region(
            regions,
            cursor + 12,
            pair_end,
            "apk-signing-pair-value",
            f"{provenance}!/APK-SIGNING-BLOCK:{pair_label}:value@{cursor + 12}:{pair_end}",
        )
        cursor = pair_end
        pair_index += 1
    if cursor != pairs_end or pair_index == 0:
        raise osrsPublicPathError(f"APK Signing Block pair table is invalid: {provenance}")
    _osrs_append_zip_region(
        regions,
        pairs_end,
        central_start,
        "apk-signing-block-footer",
        f"{provenance}!/APK-SIGNING-BLOCK:footer@{pairs_end}:{central_start}",
    )
    return start, regions


def _osrs_parse_zip64_and_gap(
    data: bytes,
    start: int,
    eocd_start: int,
    eocd: tuple[int, int, int, int, int, int, int],
    central_start: int,
    provenance: str,
    required: bool,
) -> list[_osrsZipByteRegion]:
    if start > eocd_start:
        raise osrsPublicPathError(f"ZIP central records overlap the EOCD: {provenance}")
    regions: list[_osrsZipByteRegion] = []
    cursor = start
    zip64_start: int | None = None
    if data[cursor : cursor + 4] == b"PK\x06\x06":
        if cursor + 12 > eocd_start:
            raise osrsPublicPathError(f"ZIP64 EOCD is truncated: {provenance}")
        record_size = struct.unpack_from("<Q", data, cursor + 4)[0]
        record_end = cursor + 12 + record_size
        if record_size < 44 or record_end > eocd_start:
            raise osrsPublicPathError(f"ZIP64 EOCD size is invalid: {provenance}")
        zip64_start = cursor
        _osrs_append_zip_region(
            regions,
            cursor,
            record_end,
            "zip64-end-of-central-directory",
            f"{provenance}!/ZIP64-EOCD@{cursor}:{record_end}",
        )
        cursor = record_end
    locator_seen = False
    if data[cursor : cursor + 4] == b"PK\x06\x07":
        if cursor + 20 > eocd_start:
            raise osrsPublicPathError(f"ZIP64 locator is truncated: {provenance}")
        disk, recorded_offset, disk_count = struct.unpack_from("<IQI", data, cursor + 4)
        if disk != 0 or disk_count != 1:
            raise osrsPublicPathError(f"multi-disk ZIP64 is unsupported: {provenance}")
        if zip64_start is None:
            raise osrsPublicPathError(
                f"ZIP64 locator has no preceding ZIP64 EOCD: {provenance}"
            )
        concatenated_prefix = central_start - eocd[5] if eocd[5] != 0xFFFFFFFF else 0
        if recorded_offset + concatenated_prefix != zip64_start:
            raise osrsPublicPathError(f"ZIP64 locator offset is inconsistent: {provenance}")
        _osrs_append_zip_region(
            regions,
            cursor,
            cursor + 20,
            "zip64-locator",
            f"{provenance}!/ZIP64-LOCATOR@{cursor}:{cursor + 20}",
        )
        cursor += 20
        locator_seen = True
    if required and (zip64_start is None or not locator_seen):
        raise osrsPublicPathError(f"required ZIP64 metadata is missing: {provenance}")
    if cursor < eocd_start:
        _osrs_append_zip_region(
            regions,
            cursor,
            eocd_start,
            "central-to-eocd-gap",
            f"{provenance}!/CENTRAL-EOCD-GAP@{cursor}:{eocd_start}",
        )
    return regions


def _osrs_append_zip_region(
    regions: list[_osrsZipByteRegion],
    start: int,
    end: int,
    kind: str,
    provenance: str,
    *,
    scan_raw: bool = True,
    compressed_payload: bool = False,
) -> None:
    if start == end:
        return
    if start < 0 or end < start:
        raise osrsPublicPathError(f"invalid ZIP byte range for {provenance}")
    regions.append(
        _osrsZipByteRegion(
            start=start,
            end=end,
            kind=kind,
            provenance=provenance,
            scan_raw=scan_raw,
            compressed_payload=compressed_payload,
        )
    )


def _osrs_validate_zip_partition(
    regions: Sequence[_osrsZipByteRegion],
    total_size: int,
    provenance: str,
) -> None:
    cursor = 0
    for region in sorted(regions, key=lambda item: (item.start, item.end)):
        if region.start != cursor or region.end > total_size:
            relation = "overlap" if region.start < cursor else "unclassified gap"
            raise osrsPublicPathError(
                f"ZIP structural partition has an {relation} at byte {cursor}: {provenance}"
            )
        cursor = region.end
    if cursor != total_size:
        raise osrsPublicPathError(
            f"ZIP structural partition leaves bytes {cursor}:{total_size} unclassified: "
            f"{provenance}"
        )


def _osrs_account_and_scan_zip_regions(
    data: bytes,
    regions: Sequence[_osrsZipByteRegion],
    state: _osrsPathScanState,
) -> None:
    classified = sum(region.size for region in regions)
    unclassified = len(data) - classified
    raw_scanned = sum(region.size for region in regions if region.scan_raw)
    if len(data) > state.limits.max_raw_container_bytes:
        raise osrsPublicPathError(
            "raw ZIP/APK container exceeds the "
            f"{state.limits.max_raw_container_bytes}-byte limit"
        )
    if state.zip_raw_region_count + len(regions) > state.limits.max_raw_region_count:
        raise osrsPublicPathError(
            "raw ZIP/APK region count exceeds the "
            f"{state.limits.max_raw_region_count}-region limit"
        )
    if state.zip_scanned_raw_bytes + raw_scanned > state.limits.max_raw_scanned_bytes:
        raise osrsPublicPathError(
            "raw ZIP/APK metadata scan exceeds the "
            f"{state.limits.max_raw_scanned_bytes}-byte limit"
        )
    state.zip_container_bytes += len(data)
    state.zip_classified_bytes += classified
    state.zip_unclassified_bytes += unclassified
    state.zip_raw_region_count += len(regions)
    for region in regions:
        if region.kind == "member-payload":
            state.zip_member_payload_bytes += region.size
            if region.compressed_payload:
                state.zip_compressed_payload_bytes += region.size
        if region.scan_raw:
            state.zip_scanned_raw_bytes += region.size
            _osrs_scan_printable_bytes(
                data[region.start : region.end], region.provenance, "", state
            )
    if unclassified != 0:
        raise osrsPublicPathError("ZIP raw-byte accounting is incomplete")


def _osrs_scan_zip_bytes(
    data: bytes,
    provenance: str,
    state: _osrsPathScanState,
    *,
    depth: int,
    record_top_level_members: bool,
) -> None:
    _osrs_enter_container(state, provenance, depth)
    if len(data) > state.limits.max_raw_container_bytes:
        raise osrsPublicPathError(
            "raw ZIP/APK container exceeds the "
            f"{state.limits.max_raw_container_bytes}-byte limit: {provenance}"
        )
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except (OSError, zipfile.BadZipFile) as error:
        raise osrsPublicPathError(
            f"recursive ZIP container is unreadable: {provenance}: {error}"
        ) from error
    with archive:
        members = sorted(archive.infolist(), key=lambda member: member.filename)
        names = [member.filename for member in members]
        if len(names) != len(set(names)):
            raise osrsPublicPathError(
                f"recursive ZIP container has duplicate member names: {provenance}"
            )
        state.container_member_count += len(members)
        if state.container_member_count > state.limits.max_container_members:
            raise osrsPublicPathError(
                "recursive archive member count exceeds the "
                f"{state.limits.max_container_members}-member limit at {provenance}"
            )
        regions = _osrs_structural_zip_regions(data, archive, provenance)
        _osrs_account_and_scan_zip_regions(data, regions, state)
        accounted_members = 0
        for member in members:
            member_provenance = f"{provenance}!/{member.filename}"
            _osrs_validate_archive_member_name(member, member_provenance)
            if record_top_level_members and not member.is_dir():
                state.scanned_artifacts.append(member.filename)
            member_kinds = _osrs_archive_host_path_kinds(
                member.filename,
                context=_osrsArchiveHostPathScanContext.ARCHIVE_MEMBER_NAME,
            )
            if member_kinds:
                state.findings.append(
                    {
                        "artifact": member_provenance,
                        "encoding": "zip_member_name",
                        "kinds": list(member_kinds),
                    }
                )
            if member.flag_bits & 0x1:
                raise osrsPublicPathError(
                    f"encrypted archive member cannot be inspected: {member_provenance}"
                )
            if member.is_dir():
                if (
                    member.file_size != 0
                    or member.compress_size != 0
                    or member.CRC != 0
                ):
                    raise osrsPublicPathError(
                        "directory archive member has non-empty or inconsistent payload "
                        f"metadata: {member_provenance} "
                        f"(decoded={member.file_size}, compressed={member.compress_size}, "
                        f"crc32={member.CRC:08x})"
                    )
                _osrs_check_compression_limits(
                    member.file_size,
                    member.compress_size,
                    member_provenance,
                    state.limits,
                )
                state.consume_expanded(member.file_size, member_provenance)
                try:
                    with archive.open(member) as member_file:
                        directory_data = member_file.read(1)
                except (
                    OSError,
                    RuntimeError,
                    NotImplementedError,
                    zipfile.BadZipFile,
                ) as error:
                    raise osrsPublicPathError(
                        f"empty directory archive member is unreadable: "
                        f"{member_provenance}: {error}"
                    ) from error
                if directory_data:
                    raise osrsPublicPathError(
                        "directory archive member decoded unexpected payload bytes: "
                        f"{member_provenance}"
                    )
                state.zip_empty_directory_member_validated_count += 1
                accounted_members += 1
                continue
            _osrs_check_compression_limits(
                member.file_size,
                member.compress_size,
                member_provenance,
                state.limits,
            )
            state.consume_expanded(member.file_size, member_provenance)
            try:
                with archive.open(member) as member_file:
                    member_data = member_file.read(member.file_size + 1)
            except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                raise osrsPublicPathError(
                    f"archive member is unreadable: {member_provenance}: {error}"
                ) from error
            if len(member_data) != member.file_size:
                raise osrsPublicPathError(
                    f"archive member size changed while reading: {member_provenance}"
                )
            if member.filename.casefold().endswith(".so"):
                state.native_library_count += 1
            _osrs_scan_payload(
                member_data,
                member_provenance,
                Path(member.filename).suffix.casefold(),
                state,
                depth=depth + 1,
            )
            state.zip_payload_member_inspected_count += 1
            accounted_members += 1
        if accounted_members != len(members):
            raise osrsPublicPathError(
                "ZIP member inspection accounting is incomplete: "
                f"{provenance} ({accounted_members}/{len(members)} members accounted)"
            )


def _osrs_scan_gzip_bytes(
    data: bytes,
    provenance: str,
    state: _osrsPathScanState,
    *,
    depth: int,
) -> None:
    _osrs_enter_container(state, provenance, depth)
    _osrs_scan_printable_bytes(data, f"{provenance}:gzip-header", "", state)
    remaining = min(
        state.limits.max_single_member_bytes,
        state.limits.max_expanded_bytes - state.expanded_bytes,
    )
    if remaining < 0:
        remaining = 0
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as stream:
            expanded = stream.read(remaining + 1)
    except (OSError, EOFError) as error:
        raise osrsPublicPathError(
            f"recursive gzip container is unreadable: {provenance}: {error}"
        ) from error
    if len(expanded) > remaining:
        raise osrsPublicPathError(
            f"gzip expansion exceeds a configured byte limit: {provenance}"
        )
    _osrs_check_compression_limits(len(expanded), len(data), provenance, state.limits)
    state.consume_expanded(len(expanded), f"{provenance}!/gzip-payload")
    inner_suffix = Path(Path(provenance.split("!/")[-1]).stem).suffix.casefold()
    _osrs_scan_payload(
        expanded,
        f"{provenance}!/gzip-payload",
        inner_suffix,
        state,
        depth=depth + 1,
    )


def _osrs_scan_leaf(
    data: bytes,
    provenance: str,
    suffix: str,
    state: _osrsPathScanState,
    *,
    disk_path: Path | None,
) -> None:
    if suffix == ".json":
        state.json_artifact_count += 1
        try:
            value = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise osrsPublicPathError(
                f"public JSON artifact is invalid: {provenance}: {error}"
            ) from error
        if state.on_json is not None:
            state.on_json(value, provenance, disk_path)
        else:
            osrs_assert_public_json_portable(value, provenance)
        return
    state.non_json_artifact_count += 1
    _osrs_scan_printable_bytes(data, provenance, suffix, state)


def _osrs_scan_printable_bytes(
    data: bytes, provenance: str, suffix: str, state: _osrsPathScanState
) -> None:
    binary_leaf = suffix not in _OSRS_TEXT_LIKE_SUFFIXES
    context = (
        _osrsArchiveHostPathScanContext.BINARY_PRINTABLE_ISLAND
        if binary_leaf
        else _osrsArchiveHostPathScanContext.SEMANTIC_TEXT
    )
    if binary_leaf:
        _osrs_scan_binary_tilde_home_bytes(data, provenance, state)
    for encoding, text, start, end in _osrs_printable_string_spans(data):
        state.printable_string_count += 1
        kinds = _osrs_archive_host_path_kinds(text, context=context)
        if (
            binary_leaf
            and kinds == ("host_home_reference",)
            and not _osrs_binary_tilde_home_has_path_token_boundary(
                text,
                data[start - 1] if start > 0 else None,
                data[end] if end < len(data) else None,
            )
        ):
            continue
        if kinds:
            state.findings.append(
                {
                    "artifact": provenance,
                    "encoding": encoding,
                    "kinds": list(kinds),
                }
            )


def _osrs_scan_binary_tilde_home_bytes(
    data: bytes, provenance: str, state: _osrsPathScanState
) -> None:
    for match in _OSRS_BINARY_TILDE_PATH_BYTES.finditer(data):
        before = data[match.start() - 1] if match.start() > 0 else None
        after = data[match.end()] if match.end() < len(data) else None
        if not (
            _osrs_byte_is_binary_path_delimiter(before)
            and _osrs_byte_is_binary_path_delimiter(after)
        ):
            continue
        text = match.group().decode("ascii")
        kinds = _osrs_archive_host_path_kinds(
            text,
            context=_osrsArchiveHostPathScanContext.BINARY_PRINTABLE_ISLAND,
        )
        if kinds:
            state.findings.append(
                {
                    "artifact": provenance,
                    "encoding": "ascii-bounded",
                    "kinds": list(kinds),
                }
            )


def _osrs_enter_container(
    state: _osrsPathScanState, provenance: str, depth: int
) -> None:
    if depth > state.limits.max_container_depth:
        raise osrsPublicPathError(
            "recursive container depth exceeds the "
            f"{state.limits.max_container_depth}-level limit at {provenance}"
        )
    state.container_count += 1
    if state.container_count > state.limits.max_container_count:
        raise osrsPublicPathError(
            "recursive container count exceeds the "
            f"{state.limits.max_container_count}-container limit at {provenance}"
        )


def _osrs_check_compression_limits(
    expanded_size: int,
    compressed_size: int,
    provenance: str,
    limits: osrsPathScanLimits,
) -> None:
    if expanded_size > limits.max_single_member_bytes:
        raise osrsPublicPathError(
            f"artifact member exceeds the {limits.max_single_member_bytes}-byte "
            f"limit: {provenance}"
        )
    ratio = expanded_size / max(compressed_size, 1)
    if ratio > limits.max_compression_ratio:
        raise osrsPublicPathError(
            "artifact compression ratio exceeds the "
            f"{limits.max_compression_ratio:g}:1 limit at {provenance}"
        )


def _osrs_validate_archive_member_name(
    member: zipfile.ZipInfo, provenance: str
) -> None:
    normalized = member.filename.replace("\\", "/")
    components = [component for component in normalized.split("/") if component]
    if (
        normalized.startswith("/")
        or any(component == ".." for component in components)
        or re.match(r"^[A-Za-z]:/", normalized)
    ):
        raise osrsPublicPathError(
            f"archive member name escapes its container: {provenance}"
        )
    unix_mode = (member.external_attr >> 16) & 0o170000
    if unix_mode == 0o120000:
        raise osrsPublicPathError(
            f"archive member is a symlink and cannot be published: {provenance}"
        )


def _osrs_raise_binary_findings(state: _osrsPathScanState, scope: str) -> None:
    if not state.findings:
        return
    summary = ", ".join(
        f"{item['artifact']} ({'+'.join(item['kinds'])})"
        for item in state.findings[:8]
    )
    remainder = len(state.findings) - min(8, len(state.findings))
    if remainder:
        summary += f", plus {remainder} more"
    raise osrsPublicPathError(
        f"{scope} contains {len(state.findings)} build-host path string(s): {summary}"
    )


def _osrs_scan_report(state: _osrsPathScanState, *, scope: str) -> dict[str, Any]:
    artifacts = sorted(state.scanned_artifacts)
    report = _osrs_pass_report([], scope=scope)
    report["scanned_artifact_count"] = len(artifacts)
    report["scanned_artifacts"] = []
    report["scanned_artifact_names_sha256"] = _osrs_name_list_sha256(artifacts)
    report["json_artifact_count"] = state.json_artifact_count
    report["non_json_artifact_count"] = state.non_json_artifact_count
    report["printable_string_count"] = state.printable_string_count
    report["container_count"] = state.container_count
    report["container_member_count"] = state.container_member_count
    accounted_members = (
        state.zip_payload_member_inspected_count
        + state.zip_empty_directory_member_validated_count
    )
    uninspected_members = state.container_member_count - accounted_members
    if uninspected_members != 0:
        raise osrsPublicPathError(
            "accepted ZIP member inspection accounting is incomplete: "
            f"{accounted_members}/{state.container_member_count} members accounted"
        )
    report["zip_member_inspection_accounting"] = {
        "parsed_members": state.container_member_count,
        "payload_members_inspected": state.zip_payload_member_inspected_count,
        "empty_directory_members_validated": (
            state.zip_empty_directory_member_validated_count
        ),
        "accounted_members": accounted_members,
        "uninspected_members": uninspected_members,
        "uninspected_nonzero_payload_members": uninspected_members,
    }
    report["expanded_bytes"] = state.expanded_bytes
    report["referenced_artifact_count"] = state.referenced_artifact_count
    report["zip_raw_byte_accounting"] = {
        "container_bytes": state.zip_container_bytes,
        "classified_bytes": state.zip_classified_bytes,
        "member_payload_bytes": state.zip_member_payload_bytes,
        "compressed_payload_bytes": state.zip_compressed_payload_bytes,
        "scanned_raw_metadata_bytes": state.zip_scanned_raw_bytes,
        "raw_region_count": state.zip_raw_region_count,
        "unclassified_bytes": state.zip_unclassified_bytes,
    }
    report["policy"]["container_limits"] = {
        "max_depth": state.limits.max_container_depth,
        "max_members": state.limits.max_container_members,
        "max_containers": state.limits.max_container_count,
        "max_expanded_bytes": state.limits.max_expanded_bytes,
        "max_single_member_bytes": state.limits.max_single_member_bytes,
        "max_compression_ratio": state.limits.max_compression_ratio,
        "max_references": state.limits.max_reference_count,
        "max_raw_container_bytes": state.limits.max_raw_container_bytes,
        "max_raw_regions": state.limits.max_raw_region_count,
        "max_raw_scanned_bytes": state.limits.max_raw_scanned_bytes,
    }
    report["checks"]["recursive_container_limits_enforced"] = True
    report["checks"]["zero_unresolved_or_escaping_references"] = True
    report["checks"][
        "all_zip_members_inspected_or_validated_empty_directories"
    ] = (
        uninspected_members == 0
        and accounted_members == state.container_member_count
    )
    report["checks"]["all_zip_apk_raw_bytes_structurally_accounted"] = (
        state.zip_container_bytes == state.zip_classified_bytes
        and state.zip_unclassified_bytes == 0
    )
    report["checks"]["zero_unclassified_zip_apk_bytes"] = (
        state.zip_unclassified_bytes == 0
    )
    return report


def _osrs_local_json_references(
    value: Any,
) -> list[tuple[str, str, str | None]]:
    """Return local artifact references, JSON pointers, and adjacent hashes."""

    references: list[tuple[str, str, str | None]] = []

    def add(reference: str, pointer: str, expected_sha256: str | None) -> None:
        stripped = reference.strip()
        if not _osrs_is_local_artifact_reference(stripped):
            return
        record = (stripped, pointer, expected_sha256)
        if record not in references:
            references.append(record)

    def visit(current: Any, pointer: str, collection: str | None = None) -> None:
        if isinstance(current, Mapping):
            expected_sha256 = current.get("sha256")
            if not (
                isinstance(expected_sha256, str)
                and re.fullmatch(r"[0-9a-f]{64}", expected_sha256)
            ):
                expected_sha256 = None
            for key, child in current.items():
                key_text = str(key)
                lowered = key_text.casefold()
                child_pointer = f"{pointer}/{_osrs_json_pointer_token(key_text)}"
                if isinstance(child, str) and (
                    lowered in _OSRS_REFERENCE_FIELD_NAMES
                    or lowered.endswith("_path")
                    or lowered.endswith("_file")
                ):
                    add(child, child_pointer, expected_sha256)
                if (
                    collection in _OSRS_REFERENCE_COLLECTION_NAMES
                    and _osrs_looks_like_artifact_name(key_text)
                ):
                    add(key_text, child_pointer, expected_sha256)
                visit(
                    child,
                    child_pointer,
                    lowered if lowered in _OSRS_REFERENCE_COLLECTION_NAMES else None,
                )
        elif isinstance(current, (list, tuple)):
            for index, child in enumerate(current):
                child_pointer = f"{pointer}/{index}"
                if (
                    collection in _OSRS_REFERENCE_COLLECTION_NAMES
                    and isinstance(child, str)
                    and _osrs_looks_like_artifact_name(child)
                ):
                    add(child, child_pointer, None)
                visit(child, child_pointer, collection)

    visit(value, "")
    return references


def _osrs_json_is_reference_index(provenance: str, value: Any) -> bool:
    name = Path(provenance.split("!/")[-1]).name.casefold()
    if "index" in name or name in {
        "test-results.json",
        "artifact-results.json",
        "evidence-results.json",
    }:
        return True
    return isinstance(value, Mapping) and any(
        key in value for key in ("artifact_index", "artifacts", "files")
    )


def _osrs_is_local_artifact_reference(value: str) -> bool:
    if not value or "\x00" in value:
        return False
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", value):
        return False
    return _osrs_looks_like_artifact_name(value)


def _osrs_looks_like_artifact_name(value: str) -> bool:
    stripped = value.strip()
    return bool(
        stripped
        and (
            "/" in stripped
            or "\\" in stripped
            or stripped.startswith(".")
            or bool(Path(stripped).suffix)
        )
    )


def _osrs_resolve_local_reference(
    root: Path,
    source_path: Path,
    reference: str,
    pointer: str,
) -> Path:
    normalized_reference = reference.replace("\\", "/")
    source_relative = source_path.relative_to(root).as_posix()
    lexical_candidates = (
        root / normalized_reference,
        source_path.parent / normalized_reference,
    )
    if any(_osrs_path_contains_symlink(candidate, root) for candidate in lexical_candidates):
        raise osrsPublicPathError(
            f"public artifact reference resolves through a symlink at "
            f"{source_relative}{pointer}"
        )
    root_candidate, document_candidate = (
        candidate.resolve() for candidate in lexical_candidates
    )
    for candidate in {root_candidate, document_candidate}:
        _osrs_require_within_root(
            candidate,
            root,
            f"reference from {source_relative}{pointer}",
        )
    existing = sorted(
        {candidate for candidate in (root_candidate, document_candidate) if candidate.exists()},
        key=lambda candidate: candidate.as_posix(),
    )
    if not existing:
        raise osrsPublicPathError(
            f"indexed artifact is unresolved at {source_relative}{pointer}"
        )
    if len(existing) > 1:
        raise osrsPublicPathError(
            f"indexed artifact reference is ambiguous at {source_relative}{pointer}"
        )
    target = existing[0]
    if not target.is_file() and not target.is_dir():
        raise osrsPublicPathError(
            f"indexed artifact is not a regular file or directory at "
            f"{source_relative}{pointer}"
        )
    return target


def _osrs_require_within_root(candidate: Path, root: Path, kind: str) -> None:
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise osrsPublicPathError(
            f"public artifact {kind} escapes the declared root"
        ) from error


def _osrs_path_contains_symlink(candidate: Path, root: Path) -> bool:
    try:
        relative = candidate.relative_to(root)
    except ValueError:
        return False
    current = root
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            return True
    return False


def _osrs_pass_report(artifacts: Iterable[str], scope: str) -> dict[str, Any]:
    artifact_list = list(artifacts)
    return {
        "schema_version": OSRS_PATH_HYGIENE_SCHEMA_VERSION,
        "scope": scope,
        "policy": {
            "recursive_json_keys_and_values": True,
            "normalization_passes": OSRS_PATH_NORMALIZATION_PASSES,
            "detected_classes": [
                "posix_absolute",
                "windows_drive_absolute",
                "windows_unc_absolute",
                "windows_rooted_absolute",
                "file_uri",
                "host_home_reference",
            ],
            "serialization_variants": [
                "json_escaped_slashes",
                "doubled_backslashes",
                "literal_unicode_and_hex_escapes",
                "nested_json_strings",
                "percent_encoding",
                "html_character_references",
                "hex_encoded_utf8",
                "base64_and_base64url_encoded_utf8",
                "ascii_utf16le_and_utf16be_printable_runs",
            ],
        },
        "scanned_artifact_count": len(artifact_list),
        "scanned_artifacts": artifact_list,
        "findings_count": 0,
        "checks": {
            "all_json_parsed": True,
            "zero_host_absolute_path_strings": True,
            "release_ready": True,
        },
    }


def _osrs_serialization_variants(value: str) -> tuple[str, ...]:
    variants = {value}
    frontier = {value}
    for _ in range(OSRS_PATH_NORMALIZATION_PASSES):
        next_frontier: set[str] = set()
        for item in frontier:
            transformed = {
                item.replace(r"\/", "/"),
                item.replace(r"\\", "\\"),
                _OSRS_LITERAL_UNICODE_SLASH.sub("/", item),
                _OSRS_LITERAL_UNICODE_BACKSLASH.sub(r"\\", item),
                _OSRS_LITERAL_UNICODE_DOT.sub(".", item),
                _OSRS_LITERAL_HEX_SLASH.sub("/", item),
                _OSRS_LITERAL_HEX_BACKSLASH.sub(r"\\", item),
                _OSRS_LITERAL_HEX_DOT.sub(".", item),
                urllib.parse.unquote(item),
                html.unescape(item),
            }
            transformed.update(_osrs_decode_embedded_tokens(item))
            if len(item) >= 2 and item[0] == '"' and item[-1] == '"':
                try:
                    decoded = json.loads(item)
                except json.JSONDecodeError:
                    pass
                else:
                    if isinstance(decoded, str):
                        transformed.add(decoded)
            for candidate in transformed:
                if candidate not in variants:
                    variants.add(candidate)
                    next_frontier.add(candidate)
        frontier = next_frontier
        if not frontier:
            break
    return tuple(sorted(variants))


def _osrs_decode_embedded_tokens(value: str) -> set[str]:
    decoded: set[str] = set()
    for match in _OSRS_HEX_TOKEN.finditer(value):
        token = match.group()
        if len(token) // 2 > OSRS_DEFAULT_PATH_SCAN_LIMITS.max_encoded_token_bytes:
            continue
        try:
            candidate = bytes.fromhex(token).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        if _osrs_decoded_token_may_contain_path(candidate):
            decoded.add(candidate)
    for match in _OSRS_BASE64_TOKEN.finditer(value):
        token = match.group()
        if len(token) > OSRS_DEFAULT_PATH_SCAN_LIMITS.max_encoded_token_bytes * 2:
            continue
        normalized = token.replace("-", "+").replace("_", "/")
        normalized += "=" * (-len(normalized) % 4)
        try:
            raw = base64.b64decode(normalized, validate=True)
            candidate = raw.decode("utf-8")
        except (binascii.Error, UnicodeDecodeError):
            continue
        if _osrs_decoded_token_may_contain_path(candidate):
            decoded.add(candidate)
    return decoded


def _osrs_decoded_token_may_contain_path(value: str) -> bool:
    return (
        len(value) <= OSRS_DEFAULT_PATH_SCAN_LIMITS.max_encoded_token_bytes
        and all(character in "\r\n\t" or 0x20 <= ord(character) <= 0x7E for character in value)
        and ("/" in value or "\\" in value or "file:" in value.casefold())
    )


_OSRS_JAVA_DESCRIPTOR_IDENTIFIER = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
_OSRS_JAVA_DESCRIPTOR_TERMINATORS = frozenset("\0\r\n\t \"'=,)]}")
_OSRS_COMPACT_TILDE_L_NOISE = re.compile(r"~L[A-Za-z0-9_$]{1,64}")
_OSRS_COMPACT_TILDE_HOME_NOISE = re.compile(r"~/[A-Za-z0-9]")


class _osrsJavaDescriptorParser:
    def __init__(self, value: str):
        self.value = value

    def parse_object_type(self, index: int) -> int | None:
        if index >= len(self.value) or self.value[index] != "L":
            return None
        index += 1
        index = self._parse_class_name(index)
        if index is None:
            return None
        index = self._parse_optional_type_arguments(index)
        if index < 0:
            return None
        while index < len(self.value) and self.value[index] == ".":
            index = self._parse_identifier(index + 1)
            if index is None:
                return None
            index = self._parse_optional_type_arguments(index)
            if index < 0:
                return None
        if index >= len(self.value) or self.value[index] != ";":
            return None
        return index + 1

    def _parse_class_name(self, index: int) -> int | None:
        index = self._parse_identifier(index)
        if index is None:
            return None
        while index < len(self.value) and self.value[index] == "/":
            index = self._parse_identifier(index + 1)
            if index is None:
                return None
        return index

    def _parse_identifier(self, index: int) -> int | None:
        match = _OSRS_JAVA_DESCRIPTOR_IDENTIFIER.match(self.value, index)
        return match.end() if match else None

    def _parse_optional_type_arguments(self, index: int) -> int:
        if index >= len(self.value) or self.value[index] != "<":
            return index
        index += 1
        parsed_argument = False
        while index < len(self.value) and self.value[index] != ">":
            if self.value[index] == "*":
                index += 1
                parsed_argument = True
                continue
            if self.value[index] in "+-":
                index += 1
            next_index = self._parse_type_argument(index)
            if next_index is None:
                return -1
            index = next_index
            parsed_argument = True
        if not parsed_argument or index >= len(self.value) or self.value[index] != ">":
            return -1
        return index + 1

    def _parse_type_argument(self, index: int) -> int | None:
        if index >= len(self.value):
            return None
        marker = self.value[index]
        if marker == "L":
            return self.parse_object_type(index)
        if marker == "T":
            end = self._parse_identifier(index + 1)
            if end is None or end >= len(self.value) or self.value[end] != ";":
                return None
            return end + 1
        while index < len(self.value) and self.value[index] == "[":
            index += 1
        if index >= len(self.value):
            return None
        if self.value[index] == "L":
            return self.parse_object_type(index)
        if self.value[index] in "BCDFIJSZ":
            return index + 1
        return None


def _osrs_archive_tilde_path_complete_java_descriptor_end(
    value: str, start: int
) -> int | None:
    """Return the end of one complete ``~L...;`` Java/Dalvik descriptor token.

    The leading tilde is a DEX/signature-adjacent byte token, not a home
    directory marker, only when the following object descriptor parses fully and
    terminates before any path-like suffix.  Malformed descriptor-shaped strings
    stay fail-closed as host-home references.
    """

    if not value.startswith("~L", start):
        return None
    end = _osrsJavaDescriptorParser(value).parse_object_type(start + 1)
    if end is None or end <= start + 2:
        return None
    if end == len(value) or value[end] in _OSRS_JAVA_DESCRIPTOR_TERMINATORS:
        return end
    return None


def _osrs_archive_tilde_path_is_complete_java_descriptor(value: str, start: int) -> bool:
    return _osrs_archive_tilde_path_complete_java_descriptor_end(value, start) is not None


def _osrs_archive_malformed_tilde_java_descriptor_is_path_like(path: str) -> bool:
    """Fail descriptor-shaped bypass probes without flagging arbitrary binary runs."""

    if not path.startswith("~L"):
        return False
    descriptor_tail = path[2:]
    if not descriptor_tail:
        return False
    separators = ("/", "\\")
    components = re.split(r"[\\/]", descriptor_tail)
    if len(components) < 2:
        return False
    first = components[0].casefold()
    if first in {"java", "javax", "kotlin", "android", "com", "org", "net", "io"}:
        return True
    if path.startswith(("~Ljava/", "~Ljava\\")):
        return True
    if any("." in component for component in components[1:]):
        return True
    return False


def _osrs_archive_tilde_l_noise_is_confidently_non_path_like(path: str) -> bool:
    """Allow only compact ``~L`` binary fragments that do not resemble homes."""

    if not path.startswith("~L"):
        return False
    if path.split("?", 1)[0].split("#", 1)[0].endswith(";"):
        return False
    token = _osrs_trim_path_terminal_punctuation(
        path.split("?", 1)[0].split("#", 1)[0]
    )
    return _OSRS_COMPACT_TILDE_L_NOISE.fullmatch(token) is not None


def _osrs_archive_tilde_home_noise_is_confidently_non_path_like(path: str) -> bool:
    """Allow the historical one-byte ``~/x`` binary control, not real homes."""

    token = _osrs_trim_path_terminal_punctuation(
        path.split("?", 1)[0].split("#", 1)[0]
    ).replace("\\", "/")
    return _OSRS_COMPACT_TILDE_HOME_NOISE.fullmatch(token) is not None


def _osrs_archive_compact_tilde_noise_allowed(
    path: str, context: _osrsArchiveHostPathScanContext
) -> bool:
    if context is not _osrsArchiveHostPathScanContext.BINARY_PRINTABLE_ISLAND:
        return False
    return _osrs_archive_tilde_home_noise_is_confidently_non_path_like(
        path
    ) or _osrs_archive_tilde_l_noise_is_confidently_non_path_like(path)


def _osrs_archive_tilde_home_reference_is_path_like(
    path: str, *, context: _osrsArchiveHostPathScanContext
) -> bool:
    """Return true for archive tilde-home paths, including one-component homes."""

    path_without_query = path.split("?", 1)[0].split("#", 1)[0]
    normalized = _osrs_trim_path_terminal_punctuation(path_without_query).replace(
        "\\", "/"
    )
    match = re.fullmatch(
        r"~(?P<user>[A-Za-z0-9._-]+)?/(?P<body>[^?#]*)",
        normalized,
    )
    if match is None:
        return False
    if _osrs_archive_compact_tilde_noise_allowed(path, context):
        return False
    components = match.group("body").split("/")
    if components == [""]:
        return True
    if not all(
        item in {"", ".", ".."} or _OSRS_PLAIN_PATH_COMPONENT.fullmatch(item)
        for item in components
    ):
        return False
    return True


def _osrs_archive_tilde_home_candidate_matches(
    value: str,
) -> Iterable[_osrsTildeHomeCandidate]:
    """Yield audited tilde-home candidates from one decoded scanner unit."""

    return _osrs_decoded_unit_tilde_home_candidates(value)


def _osrs_archive_descriptor_has_non_home_type_syntax_suffix(
    value: str, match: _osrsTildeHomeCandidate, descriptor_end: int | None
) -> bool:
    if descriptor_end is None or descriptor_end <= match.end("path"):
        return False
    return value[match.end("path")] in "<$"


def _osrs_archive_host_path_kinds(
    value: str,
    *,
    context: _osrsArchiveHostPathScanContext = (
        _osrsArchiveHostPathScanContext.SEMANTIC_TEXT
    ),
) -> tuple[str, ...]:
    """Find build-host locations without treating binary syntax as a path.

    Arbitrary DEX, SQLite, PNG, and native-library bytes routinely contain
    printable runs such as regular expressions, JNI descriptors, ``K:/K``,
    and ``~\\q``.  Those are not host locations.  Archive scans therefore
    require a recognizable host root and a structurally plausible multi-part
    filesystem path.  Recursive JSON scans remain deliberately stricter and
    reject every absolute-path class.
    """

    kinds: set[str] = set()
    descriptor_only = (
        context
        is _osrsArchiveHostPathScanContext.DESCRIPTOR_ONLY_JAVA_DALVIK_OBJECT
    )
    for variant in _osrs_serialization_variants(value):
        for match in _OSRS_ARCHIVE_POSIX_PATH.finditer(variant):
            if _osrs_is_build_host_posix_path(match.group("path")):
                kinds.add("posix_absolute")
        for match in _OSRS_ARCHIVE_WINDOWS_DRIVE_PATH.finditer(variant):
            if _osrs_is_plausible_windows_drive_host_path(match.group("path")):
                kinds.add("windows_drive_absolute")
        for match in _OSRS_ARCHIVE_WINDOWS_UNC_PATH.finditer(variant):
            if _osrs_is_plausible_windows_unc_host_path(match.group("path")):
                kinds.add("windows_unc_absolute")
        for match in _OSRS_ARCHIVE_WINDOWS_ROOTED_PATH.finditer(variant):
            path = match.group("path")
            components = _osrs_windows_path_components(path)
            if (
                len(components) >= 1
                and components[0].casefold() in _OSRS_WINDOWS_ROOT_COMPONENTS
                and all(_OSRS_PLAIN_PATH_COMPONENT.fullmatch(item) for item in components)
            ):
                kinds.add("windows_rooted_absolute")
        for match in _osrs_archive_tilde_home_candidate_matches(variant):
            path = match.group("path")
            descriptor_end = (
                _osrs_archive_tilde_path_complete_java_descriptor_end(
                    variant, match.start("path")
                )
                if path.startswith("~L")
                else None
            )
            complete_descriptor = descriptor_end is not None
            descriptor_has_non_home_type_syntax_suffix = (
                _osrs_archive_descriptor_has_non_home_type_syntax_suffix(
                    variant, match, descriptor_end
                )
            )
            if _osrs_archive_tilde_home_reference_is_path_like(
                path, context=context
            ):
                if descriptor_only and complete_descriptor:
                    continue
                if descriptor_has_non_home_type_syntax_suffix:
                    continue
                kinds.add("host_home_reference")
                continue
            if path.startswith("~L"):
                if complete_descriptor:
                    continue
                if _osrs_archive_malformed_tilde_java_descriptor_is_path_like(path):
                    kinds.add("host_home_reference")
                continue
        for match in _OSRS_ARCHIVE_FILE_URI_PATH.finditer(variant):
            path = re.sub(r"^file:", "", match.group("path"), flags=re.IGNORECASE)
            decoded_path = urllib.parse.unquote(path)
            if (
                _osrs_is_build_host_posix_path(decoded_path)
                or _osrs_is_plausible_windows_drive_host_path(
                    decoded_path.lstrip("/")
                )
                or _osrs_is_plausible_windows_host_path(
                    decoded_path, minimum_components=2
                )
            ):
                kinds.add("file_uri")
    return tuple(sorted(kinds))


def _osrs_archive_descriptor_only_host_path_kinds(value: str) -> tuple[str, ...]:
    """Scan one descriptor-aware extractor token with descriptor-only provenance."""

    return _osrs_archive_host_path_kinds(
        value,
        context=_osrsArchiveHostPathScanContext.DESCRIPTOR_ONLY_JAVA_DALVIK_OBJECT,
    )


def _osrs_is_build_host_posix_path(value: str) -> bool:
    path = _osrs_trim_path_terminal_punctuation(
        value.split("?", 1)[0].split("#", 1)[0]
    )
    components = [item for item in path.split("/") if item]
    if not components or not all(
        _OSRS_PLAIN_PATH_COMPONENT.fullmatch(item) for item in components
    ):
        return False
    lowered = [item.casefold() for item in components]
    root = lowered[0]
    required_component_count = {
        "users": 1,
        "home": 2,
        "root": 2,
        "volumes": 2,
        "workspace": 2,
        "workspaces": 2,
        "build": 2,
        "builds": 2,
        "mnt": 2,
        "opt": 2,
        "tmp": 2,
        "srv": 2,
        "__w": 2,
        "agent": 2,
        "runner": 2,
    }
    if root in required_component_count:
        return len(components) >= required_component_count[root]
    compound_roots = {
        ("github", "workspace"): 2,
        ("private", "tmp"): 2,
        ("private", "var"): 2,
        ("var", "folders"): 2,
        ("library", "developer"): 2,
        ("applications", "xcode.app"): 2,
    }
    return any(
        tuple(lowered[: len(prefix)]) == prefix and len(components) >= minimum
        for prefix, minimum in compound_roots.items()
    )


def _osrs_windows_path_components(value: str) -> list[str]:
    normalized = _osrs_trim_path_terminal_punctuation(value).replace("\\", "/")
    normalized = re.sub(r"^(?://\?/)?[A-Za-z]:/", "", normalized)
    normalized = normalized.lstrip("/")
    return [item for item in normalized.split("/") if item]


def _osrs_is_plausible_windows_host_path(
    value: str, *, minimum_components: int
) -> bool:
    components = _osrs_windows_path_components(value)
    return len(components) >= minimum_components and all(
        _OSRS_PLAIN_PATH_COMPONENT.fullmatch(item) for item in components
    )


def _osrs_is_plausible_windows_drive_host_path(value: str) -> bool:
    components = _osrs_windows_path_components(value)
    if not components or not all(
        _OSRS_PLAIN_PATH_COMPONENT.fullmatch(item) for item in components
    ):
        return False
    return len(components) >= 2 or components[0].casefold() in (
        _OSRS_WINDOWS_ROOT_COMPONENTS | {"tmp"}
    )


def _osrs_is_plausible_windows_unc_host_path(value: str) -> bool:
    components = _osrs_windows_path_components(value)
    if len(components) < 2 or not all(
        _OSRS_PLAIN_PATH_COMPONENT.fullmatch(item) for item in components
    ):
        return False
    if value.startswith("//") and components[0].casefold() in {
        "assets",
        "data",
        "dev",
        "lib",
        "meta-inf",
        "proc",
        "res",
        "system",
    }:
        return False
    return True


def _osrs_trim_path_terminal_punctuation(value: str) -> str:
    return value.rstrip(".,;:!?)]}>")


def _osrs_byte_is_binary_path_delimiter(value: int | None) -> bool:
    return value is None or value in _OSRS_BINARY_PATH_DELIMITER_BYTES


def _osrs_binary_tilde_home_has_path_token_boundary(
    value: str, before: int | None, after: int | None
) -> bool:
    if not (
        _osrs_byte_is_binary_path_delimiter(before)
        and _osrs_byte_is_binary_path_delimiter(after)
    ):
        return False
    for variant in _osrs_serialization_variants(value):
        for match in _osrs_archive_tilde_home_candidate_matches(variant):
            path = match.group("path")
            descriptor_end = (
                _osrs_archive_tilde_path_complete_java_descriptor_end(
                    variant, match.start("path")
                )
                if path.startswith("~L")
                else None
            )
            if _osrs_archive_tilde_home_reference_is_path_like(
                path,
                context=_osrsArchiveHostPathScanContext.SEMANTIC_TEXT,
            ):
                if _osrs_archive_descriptor_has_non_home_type_syntax_suffix(
                    variant, match, descriptor_end
                ):
                    continue
                return True
            if descriptor_end is not None:
                continue
            if path.startswith("~L") and _osrs_archive_malformed_tilde_java_descriptor_is_path_like(
                path
            ):
                return True
    return False


def _osrs_printable_string_spans(data: bytes) -> Iterable[tuple[str, str, int, int]]:
    for match in _OSRS_ASCII_PRINTABLE_RUN.finditer(data):
        yield "ascii", match.group().decode("ascii"), match.start(), match.end()
    for match in _OSRS_UTF16LE_PRINTABLE_RUN.finditer(data):
        yield "utf-16le", match.group().decode("utf-16le"), match.start(), match.end()
    for match in _OSRS_UTF16BE_PRINTABLE_RUN.finditer(data):
        yield "utf-16be", match.group().decode("utf-16be"), match.start(), match.end()


def _osrs_printable_strings(data: bytes) -> Iterable[tuple[str, str]]:
    for encoding, value, _, _ in _osrs_printable_string_spans(data):
        yield encoding, value


def _osrs_name_list_sha256(values: Sequence[str]) -> str:
    return hashlib.sha256(("\n".join(values) + "\n").encode("utf-8")).hexdigest()


def _osrs_path_field_name(value: str) -> bool:
    lowered = value.casefold()
    return (
        lowered in {"path", "directory", "worktree", "root"}
        or lowered.endswith("_path")
        or lowered.endswith("_directory")
        or lowered.endswith("_root")
    )


def _osrs_is_standalone_host_location(value: str) -> bool:
    for variant in _osrs_serialization_variants(value):
        stripped = variant.strip().strip('"\'')
        if (
            (stripped.startswith("/") and not stripped.startswith("//"))
            or stripped.startswith("//")
            or stripped.startswith("\\")
            or re.match(r"^(?:\\\\\?\\)?[A-Za-z]:[\\/]", stripped)
            or re.match(r"^file:(?:(?:/{1,3})|(?:\\{1,3}))", stripped, re.IGNORECASE)
            or re.match(r"^~(?:[A-Za-z0-9._-]+)?[\\/]", stripped)
        ) and osrs_host_absolute_path_kinds(stripped):
            return True
    return False


def _osrs_json_pointer_token(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def _osrs_logical_token(value: str) -> str:
    result = re.sub(r"[^a-z0-9._-]+", "-", value.casefold()).strip("-")
    return result or "item"


def _osrs_parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-tree", type=Path, action="append", default=[])
    parser.add_argument("--public-tree", type=Path, action="append", default=[])
    parser.add_argument("--artifact-root", type=Path, action="append", default=[])
    parser.add_argument("--archive", type=Path, action="append", default=[])
    args = parser.parse_args(argv)
    if not (args.json_tree or args.public_tree or args.artifact_root or args.archive):
        parser.error(
            "at least one --json-tree, --public-tree, --artifact-root, or --archive "
            "target is required"
        )
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = _osrs_parse_args(argv)
    try:
        reports: list[dict[str, Any]] = []
        reports.extend(osrs_validate_public_json_tree(path) for path in args.json_tree)
        reports.extend(
            osrs_validate_public_release_tree(path) for path in args.public_tree
        )
        reports.extend(
            osrs_validate_public_artifact_closure(path) for path in args.artifact_root
        )
        reports.extend(osrs_validate_public_archive(path) for path in args.archive)
    except osrsPublicPathError as error:
        print(str(error), file=sys.stderr)
        return 1
    if len(reports) == 1:
        report = reports[0]
    else:
        report = {
            "schema_version": OSRS_PATH_HYGIENE_SCHEMA_VERSION,
            "scope": "combined_publication_gate",
            "target_count": len(reports),
            "reports": reports,
            "findings_count": 0,
            "checks": {
                "all_targets_scanned": True,
                "zero_host_absolute_path_strings": True,
                "release_ready": True,
            },
        }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
