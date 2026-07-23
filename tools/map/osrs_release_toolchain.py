#!/usr/bin/env python3
"""Fail-closed toolchain and exact-tree gates for non-surface releases."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import sqlite3
import sys
import zlib
from pathlib import Path
from typing import Any, Mapping, Sequence


OSRS_TOOLCHAIN_CONTRACT = Path(__file__).with_name(
    "osrs_release_toolchain.lock.json"
)
OSRS_LOCKED_WRAPPER_ENV = "OSRS_LOCKED_RELEASE_WRAPPER"
OSRS_INVOCATION_REPORT_ENV = "OSRS_LOCKED_RELEASE_INVOCATION_REPORT"

_OSRS_PACKAGE_FIELDS = (
    "name",
    "version",
    "build",
    "build_number",
    "subdir",
    "sha256",
)
_OSRS_GENERATOR_SOURCES = (
    "map/build_osrs_non_surface_realms_locked.py",
    "map/build_osrs_non_surface_realms.py",
    "map/osrs_release_toolchain.py",
    "map/osrs_non_surface_assets.py",
    "map/osrs_non_surface_realms.py",
    "map/osrs_provenance_assets.py",
    "map/osrs_public_path_hygiene.py",
)


class osrsToolchainError(RuntimeError):
    """Raised before publication when the locked serializer contract drifts."""


def osrs_canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def osrs_sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def osrs_sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def osrs_load_release_toolchain_contract() -> dict[str, Any]:
    try:
        value = json.loads(OSRS_TOOLCHAIN_CONTRACT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise osrsToolchainError("release toolchain contract is unreadable") from error
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise osrsToolchainError("release toolchain contract schema is unsupported")
    return value


def _osrs_installed_package_records(prefix: Path) -> list[dict[str, Any]]:
    metadata_root = prefix / "conda-meta"
    records: list[dict[str, Any]] = []
    try:
        paths = sorted(metadata_root.glob("*.json"), key=lambda value: value.name)
    except OSError as error:
        raise osrsToolchainError("Pixi package metadata is unreadable") from error
    if not paths:
        raise osrsToolchainError("Pixi package metadata is missing")
    for path in paths:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise osrsToolchainError("Pixi package metadata is malformed") from error
        if not isinstance(value, Mapping):
            raise osrsToolchainError("Pixi package metadata is not an object")
        record = {field: value.get(field) for field in _OSRS_PACKAGE_FIELDS}
        if not all(record.get(field) is not None for field in _OSRS_PACKAGE_FIELDS):
            raise osrsToolchainError("Pixi package metadata lacks content identity")
        records.append(record)
    return sorted(records, key=lambda value: str(value["name"]))


def _osrs_sqlite_version_number() -> int:
    major, minor, patch = sqlite3.sqlite_version_info
    return major * 1_000_000 + minor * 1_000 + patch


def _osrs_observed_runtime() -> dict[str, Any]:
    import numpy as np
    from PIL import Image

    return {
        "numpy_version": np.__version__,
        "pillow_version": Image.__version__,
        "python_implementation": platform.python_implementation(),
        "python_version": platform.python_version(),
        "sqlite_version": sqlite3.sqlite_version,
        "sqlite_version_number": _osrs_sqlite_version_number(),
        "zlib_compile_version": zlib.ZLIB_VERSION,
        "zlib_runtime_version": zlib.ZLIB_RUNTIME_VERSION,
    }


def _osrs_runtime_file_records(prefix: Path) -> list[dict[str, Any]]:
    import _sqlite3
    import zlib as zlib_module
    from PIL import _imaging

    values = (
        ("python-executable", Path(sys.executable)),
        ("python-sqlite-extension", Path(str(_sqlite3.__file__))),
        ("python-zlib-extension", Path(str(zlib_module.__file__))),
        ("pillow-imaging-extension", Path(str(_imaging.__file__))),
    )
    records: list[dict[str, Any]] = []
    resolved_prefix = prefix.resolve()
    for logical_id, path in values:
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(resolved_prefix)
        except (OSError, ValueError) as error:
            raise osrsToolchainError(
                f"runtime file is outside the locked Pixi environment: {logical_id}"
            ) from error
        records.append(
            {
                "logical_id": logical_id,
                "sha256": osrs_sha256_path(resolved),
            }
        )
    return records


def _osrs_generator_source_records(tools_root: Path) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for relative in _OSRS_GENERATOR_SOURCES:
        path = tools_root / relative
        if not path.is_file():
            raise osrsToolchainError(f"generator source is missing: {relative}")
        records.append({"path": relative, "sha256": osrs_sha256_path(path)})
    return records


def _osrs_assert_equal(
    failures: list[str], field: str, observed: Any, expected: Any
) -> None:
    if observed != expected:
        failures.append(field)


def osrs_collect_locked_release_toolchain(
    *, require_wrapper: bool = True
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return stable public provenance and relocation-sensitive invocation proof."""

    contract = osrs_load_release_toolchain_contract()
    tools_root = Path(__file__).resolve().parents[1]
    manifest_path = tools_root / str(contract["pixi"]["manifest_path"])
    lock_path = tools_root / str(contract["pixi"]["lock_path"])
    prefix = Path(sys.prefix).resolve()
    expected_prefix = (tools_root / ".pixi" / "envs" / "default").resolve()

    package_records = _osrs_installed_package_records(prefix)
    package_record_bytes = osrs_canonical_json_bytes(package_records)
    package_by_name = {str(value["name"]): value for value in package_records}
    observed_runtime = _osrs_observed_runtime()
    selected_expected = contract["selected_packages"]
    selected_observed = {
        name: package_by_name.get(name) for name in sorted(selected_expected)
    }

    observed = {
        "contract_id": contract["contract_id"],
        "platform": {
            "machine": platform.machine(),
            "pixi_platform": os.environ.get("CONDA_SUBDIR", "osx-arm64"),
            "sys_platform": sys.platform,
        },
        "pixi": {
            "environment": os.environ.get("PIXI_ENVIRONMENT_NAME"),
            "executable_sha256": _osrs_environment_file_hash(
                os.environ.get("PIXI_EXE"), "Pixi executable"
            ),
            "lock_sha256": osrs_sha256_path(lock_path) if lock_path.is_file() else None,
            "manifest_sha256": (
                osrs_sha256_path(manifest_path) if manifest_path.is_file() else None
            ),
            "project_name": os.environ.get("PIXI_PROJECT_NAME"),
        },
        "installed_package_set": {
            "canonical_record_count": len(package_records),
            "canonical_record_sha256": osrs_sha256_bytes(package_record_bytes),
        },
        "runtime": observed_runtime,
        "selected_packages": selected_observed,
    }

    failures: list[str] = []
    if require_wrapper:
        _osrs_assert_equal(
            failures,
            "locked_wrapper_marker",
            os.environ.get(OSRS_LOCKED_WRAPPER_ENV),
            contract["contract_id"],
        )
    _osrs_assert_equal(failures, "canonical_platform", observed["platform"], contract["canonical_platform"])
    for field in (
        "environment",
        "executable_sha256",
        "lock_sha256",
        "manifest_sha256",
        "project_name",
    ):
        _osrs_assert_equal(
            failures,
            f"pixi.{field}",
            observed["pixi"][field],
            contract["pixi"][field],
        )
    _osrs_assert_equal(
        failures,
        "installed_package_set",
        observed["installed_package_set"],
        contract["installed_package_set"],
    )
    _osrs_assert_equal(failures, "runtime", observed_runtime, contract["runtime"])
    _osrs_assert_equal(
        failures, "selected_packages", selected_observed, selected_expected
    )
    _osrs_assert_equal(failures, "python_prefix", prefix, expected_prefix)
    _osrs_assert_equal(
        failures,
        "pixi_manifest_identity",
        _osrs_normalized_environment_path(os.environ.get("PIXI_PROJECT_MANIFEST")),
        manifest_path.resolve(),
    )
    if failures:
        raise osrsToolchainError(
            "locked release toolchain mismatch: " + ", ".join(sorted(failures))
        )

    contract_sha256 = osrs_sha256_path(OSRS_TOOLCHAIN_CONTRACT)
    generator_sources = _osrs_generator_source_records(tools_root)
    public_report = {
        "schema_version": 1,
        "status": "LOCKED_TOOLCHAIN_VERIFIED",
        "contract_id": contract["contract_id"],
        "contract_path": "toolchain://osrs-release-toolchain-contract",
        "contract_sha256": contract_sha256,
        "entrypoint": contract["entrypoint"],
        "canonical_platform": contract["canonical_platform"],
        "pixi": {
            "cli_version": contract["pixi"]["cli_version"],
            "environment": contract["pixi"]["environment"],
            "executable_sha256": contract["pixi"]["executable_sha256"],
            "invocation_policy": "outer_wrapper_always_executes_pixi_run_locked",
            "lock_path": "toolchain://pixi.lock",
            "lock_sha256": contract["pixi"]["lock_sha256"],
            "manifest_path": "toolchain://pixi.toml",
            "manifest_sha256": contract["pixi"]["manifest_sha256"],
            "project_name": contract["pixi"]["project_name"],
        },
        "installed_package_set": contract["installed_package_set"],
        "runtime": contract["runtime"],
        "selected_packages": contract["selected_packages"],
        "serialization": contract["serialization"],
        "generator_sources": generator_sources,
        "checks": {
            "canonical_platform_exact": True,
            "generator_sources_retained": True,
            "installed_package_set_exact": True,
            "locked_wrapper_marker_exact": True,
            "pixi_cli_version_exact": True,
            "pixi_executable_hash_exact": True,
            "pixi_lock_hash_exact": True,
            "pixi_manifest_hash_exact": True,
            "runtime_versions_exact": True,
            "selected_package_artifacts_exact": True,
        },
    }
    public_report_sha256 = osrs_sha256_bytes(
        osrs_canonical_json_bytes(public_report)
    )
    invocation_report = {
        "schema_version": 1,
        "status": "LOCKED_TOOLCHAIN_INVOCATION_VERIFIED",
        "contract_id": contract["contract_id"],
        "public_toolchain_report_sha256": public_report_sha256,
        "runtime_files": _osrs_runtime_file_records(prefix),
        "runtime_file_hash_policy": (
            "Installed runtime-file hashes are retained in build evidence because "
            "the relocated Python executable hash depends on the environment prefix; "
            "content-addressed package hashes govern the stable public release."
        ),
        "checks": {
            "all_runtime_files_inside_locked_environment": True,
            "all_runtime_file_hashes_recorded": True,
            "public_report_is_prefix_independent": True,
        },
    }
    return public_report, invocation_report


def _osrs_normalized_environment_path(value: str | None) -> Path | None:
    if value is None:
        return None
    try:
        return Path(value).resolve()
    except OSError:
        return None


def _osrs_environment_file_hash(value: str | None, logical_id: str) -> str:
    if value is None:
        raise osrsToolchainError(f"{logical_id} identity is unavailable")
    try:
        path = Path(value).resolve(strict=True)
    except OSError as error:
        raise osrsToolchainError(f"{logical_id} identity is unreadable") from error
    if not path.is_file():
        raise osrsToolchainError(f"{logical_id} identity is not a file")
    return osrs_sha256_path(path)


def osrs_write_invocation_report(report: Mapping[str, Any]) -> None:
    value = os.environ.get(OSRS_INVOCATION_REPORT_ENV)
    if not value:
        return
    path = Path(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(osrs_canonical_json_bytes(report))


def osrs_sqlite_file_header_version(path: Path) -> int:
    try:
        with path.open("rb") as source:
            header = source.read(100)
    except OSError as error:
        raise osrsToolchainError("MBTiles file is unreadable") from error
    if len(header) < 100 or header[:16] != b"SQLite format 3\x00":
        raise osrsToolchainError("MBTiles file lacks a valid SQLite header")
    return int.from_bytes(header[96:100], byteorder="big", signed=False)


def osrs_release_tree_snapshot(root: Path) -> dict[str, Any]:
    if not root.is_dir():
        raise osrsToolchainError("release tree is missing")
    entries: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
        if path.is_symlink():
            raise osrsToolchainError(
                f"release tree contains a symbolic link: {path.relative_to(root).as_posix()}"
            )
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        entries.append(
            {
                "path": relative,
                "sha256": osrs_sha256_path(path),
                "bytes": path.stat().st_size,
            }
        )
    name_stream = "".join(f"{value['path']}\n" for value in entries).encode("utf-8")
    hash_stream = "".join(
        f"{value['sha256']}  {value['path']}\n" for value in entries
    ).encode("utf-8")
    return {
        "file_count": len(entries),
        "total_bytes": sum(int(value["bytes"]) for value in entries),
        "file_name_sha256": osrs_sha256_bytes(name_stream),
        "file_hash_stream_sha256": osrs_sha256_bytes(hash_stream),
        "entries": entries,
    }


def osrs_verify_release_toolchain(root: Path) -> dict[str, Any]:
    contract = osrs_load_release_toolchain_contract()
    tools_root = Path(__file__).resolve().parents[1]
    report_path = root / "reports" / "toolchain-provenance.json"
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise osrsToolchainError("release toolchain provenance is missing") from error
    if not isinstance(report, Mapping):
        raise osrsToolchainError("release toolchain provenance is malformed")
    failures: list[str] = []
    _osrs_assert_equal(
        failures, "toolchain.status", report.get("status"), "LOCKED_TOOLCHAIN_VERIFIED"
    )
    _osrs_assert_equal(
        failures, "toolchain.contract_id", report.get("contract_id"), contract["contract_id"]
    )
    _osrs_assert_equal(
        failures,
        "toolchain.contract_sha256",
        report.get("contract_sha256"),
        osrs_sha256_path(OSRS_TOOLCHAIN_CONTRACT),
    )
    _osrs_assert_equal(
        failures, "toolchain.runtime", report.get("runtime"), contract["runtime"]
    )
    _osrs_assert_equal(
        failures,
        "toolchain.package_set",
        report.get("installed_package_set"),
        contract["installed_package_set"],
    )
    _osrs_assert_equal(
        failures,
        "toolchain.selected_packages",
        report.get("selected_packages"),
        contract["selected_packages"],
    )
    expected_pixi = {
        "cli_version": contract["pixi"]["cli_version"],
        "environment": contract["pixi"]["environment"],
        "executable_sha256": contract["pixi"]["executable_sha256"],
        "invocation_policy": "outer_wrapper_always_executes_pixi_run_locked",
        "lock_path": "toolchain://pixi.lock",
        "lock_sha256": contract["pixi"]["lock_sha256"],
        "manifest_path": "toolchain://pixi.toml",
        "manifest_sha256": contract["pixi"]["manifest_sha256"],
        "project_name": contract["pixi"]["project_name"],
    }
    _osrs_assert_equal(failures, "toolchain.pixi", report.get("pixi"), expected_pixi)
    _osrs_assert_equal(
        failures,
        "toolchain.generator_sources",
        report.get("generator_sources"),
        _osrs_generator_source_records(tools_root),
    )
    checks = report.get("checks")
    if not isinstance(checks, Mapping) or not checks or not all(checks.values()):
        failures.append("toolchain.checks")
    content_inputs = report.get("content_addressed_inputs")
    helper = (
        content_inputs.get("accounting_helper")
        if isinstance(content_inputs, Mapping)
        else None
    )
    if (
        not isinstance(helper, Mapping)
        or helper.get("logical_id") != "tool://osrs-source-accounting"
        or not _osrs_is_sha256(helper.get("sha256"))
    ):
        failures.append("toolchain.accounting_helper")

    expected_sqlite = int(contract["runtime"]["sqlite_version_number"])
    mbtiles_paths = sorted(root.rglob("*.mbtiles"))
    sqlite_mismatches: list[str] = []
    for path in mbtiles_paths:
        observed_version = osrs_sqlite_file_header_version(path)
        if observed_version != expected_sqlite:
            sqlite_mismatches.append(path.relative_to(root).as_posix())
    if sqlite_mismatches:
        failures.append("mbtiles.sqlite_file_header_version")
    manifest_path = root / "underground-realms.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise osrsToolchainError("release manifest is missing") from error
    release_toolchain = (
        manifest.get("inputs", {}).get("release_toolchain")
        if isinstance(manifest, Mapping)
        else None
    )
    expected_report_sha = osrs_sha256_path(report_path)
    if (
        not isinstance(release_toolchain, Mapping)
        or release_toolchain.get("path") != "reports/toolchain-provenance.json"
        or release_toolchain.get("sha256") != expected_report_sha
        or release_toolchain.get("contract_id") != contract["contract_id"]
        or release_toolchain.get("sqlite_version")
        != contract["runtime"]["sqlite_version"]
        or release_toolchain.get("sqlite_version_number") != expected_sqlite
    ):
        failures.append("manifest.release_toolchain")
    declared_assets: dict[str, int] = {}
    realms = manifest.get("realms") if isinstance(manifest, Mapping) else None
    if isinstance(realms, list):
        for realm in realms:
            if not isinstance(realm, Mapping):
                failures.append("manifest.realm_assets")
                continue
            assets = realm.get("assets")
            if not isinstance(assets, list):
                failures.append("manifest.realm_assets")
                continue
            for asset in assets:
                if not isinstance(asset, Mapping):
                    failures.append("manifest.realm_assets")
                    continue
                relative = asset.get("mbtiles_path")
                version = asset.get("sqlite_version_number")
                if not isinstance(relative, str) or relative in declared_assets:
                    failures.append("manifest.realm_assets")
                    continue
                declared_assets[relative] = version
    else:
        failures.append("manifest.realms")
    actual_assets = {
        path.relative_to(root).as_posix(): expected_sqlite for path in mbtiles_paths
    }
    if declared_assets != actual_assets:
        failures.append("manifest.mbtiles_sqlite_versions")
    if failures:
        raise osrsToolchainError(
            "release toolchain provenance mismatch: " + ", ".join(sorted(failures))
        )
    return {
        "status": "PASS",
        "contract_id": contract["contract_id"],
        "toolchain_report_sha256": expected_report_sha,
        "mbtiles_count": len(mbtiles_paths),
        "sqlite_file_header_version_number": expected_sqlite,
        "sqlite_version_mismatch_count": 0,
    }


def _osrs_is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(
        character in "0123456789abcdef" for character in value
    )


def osrs_verify_distinct_locked_invocations(
    report_paths: Sequence[Path], *, expected_count: int,
    expected_public_toolchain_report_sha256: str
) -> dict[str, Any]:
    contract = osrs_load_release_toolchain_contract()
    if len(report_paths) != expected_count:
        raise osrsToolchainError(
            "locked invocation report count does not match release tree count"
        )
    identities: list[str] = []
    report_hashes: list[str] = []
    public_report_hashes: list[str] = []
    for path in report_paths:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise osrsToolchainError("locked invocation proof is unreadable") from error
        if not isinstance(value, Mapping):
            raise osrsToolchainError("locked invocation proof is malformed")
        outer = value.get("outer_wrapper")
        checks = value.get("checks")
        runtime_files = value.get("runtime_files")
        if (
            value.get("status") != "LOCKED_TOOLCHAIN_INVOCATION_VERIFIED"
            or value.get("contract_id") != contract["contract_id"]
            or not isinstance(outer, Mapping)
            or outer.get("spawn_policy") != "pixi run --locked"
            or outer.get("pixi_version") != contract["pixi"]["cli_version"]
            or outer.get("pixi_executable_sha256")
            != contract["pixi"]["executable_sha256"]
            or not isinstance(checks, Mapping)
            or not all(checks.values())
            or not isinstance(runtime_files, list)
            or len(runtime_files) < 4
        ):
            raise osrsToolchainError("locked invocation proof does not satisfy contract")
        identity = outer.get("environment_prefix_identity_sha256")
        if not isinstance(identity, str) or len(identity) != 64 or any(
            value not in "0123456789abcdef" for value in identity
        ):
            raise osrsToolchainError("locked environment identity is invalid")
        for runtime_file in runtime_files:
            if not isinstance(runtime_file, Mapping):
                raise osrsToolchainError("runtime-file proof is invalid")
            digest = runtime_file.get("sha256")
            if not isinstance(digest, str) or len(digest) != 64:
                raise osrsToolchainError("runtime-file hash is invalid")
        public_hash = value.get("public_toolchain_report_sha256")
        if not isinstance(public_hash, str) or len(public_hash) != 64:
            raise osrsToolchainError("public toolchain report hash is invalid")
        identities.append(identity)
        public_report_hashes.append(public_hash)
        report_hashes.append(osrs_sha256_path(path))
    if len(set(identities)) != expected_count:
        raise osrsToolchainError(
            "locked builds did not use distinct isolated Pixi environments"
        )
    if len(set(public_report_hashes)) != 1:
        raise osrsToolchainError(
            "isolated environments disagree on path-independent toolchain provenance"
        )
    if public_report_hashes[0] != expected_public_toolchain_report_sha256:
        raise osrsToolchainError(
            "invocation proof does not hash the retained public toolchain report"
        )
    return {
        "status": "PASS",
        "invocation_count": expected_count,
        "distinct_environment_identity_count": len(set(identities)),
        "environment_prefix_identity_sha256": identities,
        "invocation_report_sha256": report_hashes,
        "path_independent_public_toolchain_report_sha256": public_report_hashes[0],
        "checks": {
            "all_invocations_used_outer_locked_wrapper": True,
            "all_runtime_file_hashes_retained": True,
            "environment_prefix_identities_distinct": True,
            "public_toolchain_provenance_identical": True,
            "retained_public_toolchain_report_hash_exact": True,
        },
    }


def osrs_compare_release_trees(
    canonical: Path, replays: Sequence[Path]
) -> dict[str, Any]:
    if not replays:
        raise osrsToolchainError("at least one replay release is required")
    roots = (canonical, *tuple(replays))
    labels = ["canonical", *[f"replay-{index}" for index in range(1, len(roots))]]
    snapshots = [osrs_release_tree_snapshot(root) for root in roots]
    toolchains = [osrs_verify_release_toolchain(root) for root in roots]
    canonical_entries = {
        str(value["path"]): (str(value["sha256"]), int(value["bytes"]))
        for value in snapshots[0]["entries"]
    }
    comparisons: list[dict[str, Any]] = []
    all_match = True
    for label, snapshot in zip(labels[1:], snapshots[1:]):
        replay_entries = {
            str(value["path"]): (str(value["sha256"]), int(value["bytes"]))
            for value in snapshot["entries"]
        }
        added = sorted(set(replay_entries) - set(canonical_entries))
        removed = sorted(set(canonical_entries) - set(replay_entries))
        changed = sorted(
            path
            for path in set(canonical_entries) & set(replay_entries)
            if canonical_entries[path] != replay_entries[path]
        )
        match = not added and not removed and not changed
        all_match = all_match and match
        comparisons.append(
            {
                "replay": label,
                "byte_identical": match,
                "added_count": len(added),
                "removed_count": len(removed),
                "changed_count": len(changed),
                "first_differences": (added + removed + changed)[:200],
            }
        )
    return {
        "schema_version": 1,
        "status": "PASS" if all_match else "FAIL_EXACT_RELEASE_MISMATCH",
        "canonical": {
            key: value
            for key, value in snapshots[0].items()
            if key != "entries"
        },
        "replays": [
            {
                "label": label,
                **{key: value for key, value in snapshot.items() if key != "entries"},
            }
            for label, snapshot in zip(labels[1:], snapshots[1:])
        ],
        "comparisons": comparisons,
        "toolchain_gates": [
            {"label": label, **toolchain}
            for label, toolchain in zip(labels, toolchains)
        ],
        "checks": {
            "all_file_names_identical": all_match,
            "all_file_bytes_identical": all_match,
            "all_sqlite_headers_match_contract": True,
            "all_toolchain_reports_match_contract": True,
            "retained_canonical_reproduced": all_match,
        },
    }
