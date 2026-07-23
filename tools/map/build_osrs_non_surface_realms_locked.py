#!/usr/bin/env python3
"""Launch the non-surface release builder only through ``pixi run --locked``."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence

from osrs_release_toolchain import (
    OSRS_INVOCATION_REPORT_ENV,
    OSRS_LOCKED_WRAPPER_ENV,
    osrs_canonical_json_bytes,
    osrs_load_release_toolchain_contract,
    osrs_sha256_path,
    osrsToolchainError,
)


def _osrs_extract_option(arguments: Sequence[str], option: str) -> str | None:
    for index, value in enumerate(arguments):
        if value == option:
            if index + 1 >= len(arguments):
                raise osrsToolchainError(f"{option} requires a value")
            return arguments[index + 1]
        prefix = option + "="
        if value.startswith(prefix):
            return value[len(prefix) :]
    return None


def _osrs_is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (OSError, ValueError):
        return False


def osrs_locked_pixi_command(
    pixi: Path, tools_root: Path, builder_arguments: Sequence[str]
) -> list[str]:
    return [
        str(pixi),
        "run",
        "--locked",
        "--manifest-path",
        str(tools_root / "pixi.toml"),
        "python",
        str(tools_root / "map" / "build_osrs_non_surface_realms.py"),
        *builder_arguments,
    ]


def _osrs_write_outer_invocation_proof(
    report_path: Path,
    *,
    pixi: Path,
    pixi_version: str,
    tools_root: Path,
) -> None:
    try:
        value = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise osrsToolchainError(
            "locked builder did not emit its invocation proof"
        ) from error
    if not isinstance(value, dict) or value.get("status") != (
        "LOCKED_TOOLCHAIN_INVOCATION_VERIFIED"
    ):
        raise osrsToolchainError("locked builder invocation proof is malformed")
    environment_prefix = tools_root / ".pixi" / "envs" / "default"
    value["outer_wrapper"] = {
        "entrypoint": "map/build_osrs_non_surface_realms_locked.py",
        "environment_prefix_identity_sha256": hashlib.sha256(
            str(environment_prefix.resolve()).encode("utf-8")
        ).hexdigest(),
        "environment_prefix_identity_policy": (
            "One-way identity retained only in external invocation evidence; never "
            "written to the canonical release tree. Distinct fresh source copies "
            "must have distinct prefix identities."
        ),
        "pixi_executable_sha256": osrs_sha256_path(pixi.resolve()),
        "pixi_version": pixi_version,
        "spawn_policy": "pixi run --locked",
    }
    value["checks"]["outer_wrapper_used_pixi_run_locked"] = True
    value["checks"]["pixi_cli_version_exact"] = True
    report_path.write_bytes(osrs_canonical_json_bytes(value))


def _osrs_parse_args(argv: Sequence[str]) -> tuple[Path, list[str]]:
    parser = argparse.ArgumentParser(
        description=__doc__,
        add_help=False,
        allow_abbrev=False,
    )
    parser.add_argument(
        "--osrs-invocation-report",
        required=True,
        type=Path,
        help="external evidence path for relocation-sensitive runtime hashes",
    )
    known, remaining = parser.parse_known_args(argv)
    if "--help" in remaining or "-h" in remaining:
        parser.print_help()
        print("\nAll remaining arguments are forwarded to build_osrs_non_surface_realms.py.")
        raise SystemExit(0)
    if not remaining:
        raise osrsToolchainError("release builder arguments are missing")
    return known.osrs_invocation_report, list(remaining)


def main(argv: Sequence[str] | None = None) -> int:
    invocation_report, builder_arguments = _osrs_parse_args(
        sys.argv[1:] if argv is None else argv
    )
    tools_root = Path(__file__).resolve().parents[1]
    contract = osrs_load_release_toolchain_contract()
    manifest = tools_root / str(contract["pixi"]["manifest_path"])
    lock = tools_root / str(contract["pixi"]["lock_path"])
    if osrs_sha256_path(manifest) != contract["pixi"]["manifest_sha256"]:
        raise osrsToolchainError("Pixi manifest hash does not match the release contract")
    if osrs_sha256_path(lock) != contract["pixi"]["lock_sha256"]:
        raise osrsToolchainError("Pixi lock hash does not match the release contract")

    output_value = _osrs_extract_option(builder_arguments, "--output")
    if output_value is None:
        raise osrsToolchainError("release builder --output is required")
    if _osrs_is_within(invocation_report, Path(output_value)):
        raise osrsToolchainError(
            "external invocation proof cannot be written inside the release tree"
        )

    pixi_value = shutil.which("pixi")
    if pixi_value is None:
        raise osrsToolchainError("the pinned Pixi launcher is unavailable")
    pixi = Path(pixi_value)
    if osrs_sha256_path(pixi.resolve()) != contract["pixi"]["executable_sha256"]:
        raise osrsToolchainError(
            "Pixi launcher hash does not match the release contract"
        )
    completed_version = subprocess.run(
        [str(pixi), "--version"],
        capture_output=True,
        text=True,
        check=False,
    )
    version_prefix = "pixi "
    version_output = completed_version.stdout.strip()
    if completed_version.returncode != 0 or not version_output.startswith(version_prefix):
        raise osrsToolchainError("the Pixi launcher version is unreadable")
    pixi_version = version_output[len(version_prefix) :]
    if pixi_version != contract["pixi"]["cli_version"]:
        raise osrsToolchainError("Pixi launcher version does not match the release contract")

    invocation_report.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment[OSRS_LOCKED_WRAPPER_ENV] = str(contract["contract_id"])
    environment[OSRS_INVOCATION_REPORT_ENV] = str(invocation_report.resolve())
    completed = subprocess.run(
        osrs_locked_pixi_command(pixi, tools_root, builder_arguments),
        env=environment,
        check=False,
    )
    if completed.returncode != 0:
        return completed.returncode
    _osrs_write_outer_invocation_proof(
        invocation_report,
        pixi=pixi,
        pixi_version=pixi_version,
        tools_root=tools_root,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except osrsToolchainError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
