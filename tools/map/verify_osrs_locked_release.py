#!/usr/bin/env python3
"""Verify exact retained-canonical replay for locked non-surface releases."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

from osrs_release_toolchain import (
    osrs_canonical_json_bytes,
    osrs_compare_release_trees,
    osrs_verify_distinct_locked_invocations,
    osrsToolchainError,
)


def _osrs_parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canonical", required=True, type=Path)
    parser.add_argument("--replay", required=True, action="append", type=Path)
    parser.add_argument(
        "--invocation-report", required=True, action="append", type=Path
    )
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _osrs_parse_args(sys.argv[1:] if argv is None else argv)
    roots = [args.canonical, *args.replay]
    for invocation_report in args.invocation_report:
        if any(_osrs_is_within(invocation_report, root) for root in roots):
            raise osrsToolchainError(
                "locked invocation evidence must remain outside release trees"
            )
    report = osrs_compare_release_trees(args.canonical, args.replay)
    retained_toolchain_hashes = {
        value["toolchain_report_sha256"]
        for value in report["toolchain_gates"]
    }
    if len(retained_toolchain_hashes) != 1:
        raise osrsToolchainError(
            "release trees disagree on retained toolchain provenance"
        )
    report["isolated_locked_invocations"] = osrs_verify_distinct_locked_invocations(
        args.invocation_report,
        expected_count=len(roots),
        expected_public_toolchain_report_sha256=next(iter(retained_toolchain_hashes)),
    )
    report["checks"]["distinct_fresh_locked_environments"] = True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(osrs_canonical_json_bytes(report))
    if report["status"] != "PASS":
        raise osrsToolchainError("locked release replay is not byte-identical")
    print(osrs_canonical_json_bytes(report).decode("utf-8"), end="")
    return 0


def _osrs_is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except osrsToolchainError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
