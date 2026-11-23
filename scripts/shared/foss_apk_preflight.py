#!/usr/bin/env python3
"""Fail-closed FOSS APK gates for F-Droid reproducible builds.

Refuses a GitHub FOSS upload unless the APK matches a clean public-tree
assemble that used only the F-Droid map_floors.zip prebuild and the in-tree
underground fixture stub.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Iterable

from inspect_apk_signing_block import (
    SigningBlockError,
    format_report,
    parse_signing_block,
)

ALLOWED_SIGNER_SHA256 = (
    "27bd896eeefe8f1e831d3113ddb159c637af4f76fb9ef161caceba18d57f1f43"
)
VCSINFO_MEMBER = "META-INF/version-control-info.textproto"
SIGNATURE_SUFFIXES = (".SF", ".RSA", ".DSA", ".EC")
UNDERGROUND_ENV = (
    "OSRS_UNDERGROUND_ASSETS_DIR",
    "OSRS_UNDERGROUND_ASSET_SOURCE_DIR",
    "OSRS_UNDERGROUND_EVIDENCE_DIR",
    "OSRS_EXPECTED_UNDERGROUND_MANIFEST_SHA256",
    "OSRS_UNDERGROUND_GENERATED_DIR",
)


class PreflightError(Exception):
    """One FOSS preflight gate failed."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def zip_names(apk: Path) -> list[str]:
    with zipfile.ZipFile(apk) as archive:
        return archive.namelist()


def assets_assets_entries(names: Iterable[str]) -> list[str]:
    leaked: list[str] = []
    for name in names:
        if name == "assets/assets" or name.startswith("assets/assets/"):
            leaked.append(name)
    return leaked


def read_zip_text(apk: Path, member: str) -> str:
    with zipfile.ZipFile(apk) as archive:
        return archive.read(member).decode("utf-8")


def unsigned_entry_index(apk: Path) -> dict[str, tuple[int, int]]:
    index: dict[str, tuple[int, int]] = {}
    with zipfile.ZipFile(apk) as archive:
        for info in archive.infolist():
            name = info.filename
            if name.startswith("META-INF/"):
                upper = name.upper()
                if upper.endswith(SIGNATURE_SUFFIXES) or upper.endswith(
                    "MANIFEST.MF"
                ):
                    continue
            index[name] = (info.CRC, info.file_size)
    return index


def compare_unsigned_zip_contents(left: Path, right: Path) -> list[str]:
    left_index = unsigned_entry_index(left)
    right_index = unsigned_entry_index(right)
    errors: list[str] = []
    only_left = sorted(set(left_index) - set(right_index))
    only_right = sorted(set(right_index) - set(left_index))
    if only_left:
        errors.append("zip-content only in first APK: " + ", ".join(only_left[:20]))
    if only_right:
        errors.append(
            "zip-content only in second APK: " + ", ".join(only_right[:20])
        )
    for name in sorted(set(left_index) & set(right_index)):
        if left_index[name] != right_index[name]:
            errors.append(
                f"zip-content mismatch for {name}: "
                f"{left_index[name]} vs {right_index[name]}"
            )
    return errors


def check_fixture_underground_json(payload: dict) -> list[str]:
    errors: list[str] = []
    if payload.get("candidate") != "fixture":
        errors.append(
            "underground-realms.json candidate is "
            f"{payload.get('candidate')!r}, expected 'fixture'"
        )
    accounting = payload.get("accounting")
    if not isinstance(accounting, dict) or accounting.get("fixture") is not True:
        errors.append("underground-realms.json accounting.fixture is not true")
    dumped = json.dumps(payload)
    if "named_non_surface" in dumped:
        errors.append(
            "underground-realms.json contains named_non_surface entries "
            "(full catalog, not the fixture stub)"
        )
    realms = payload.get("realms")
    if not isinstance(realms, list) or len(realms) != 1:
        errors.append(
            "underground-realms.json realms must be the single fixture surface realm"
        )
    elif realms[0].get("is_surface") is not True:
        errors.append("fixture underground realm is_surface is not true")
    return errors


def check_source_tree(tree: Path) -> list[str]:
    errors: list[str] = []
    gradle = tree / "app" / "build.gradle.kts"
    if not gradle.is_file():
        return [f"missing {gradle}"]
    text = gradle.read_text(encoding="utf-8")
    if "vcsInfo" not in text or "include = false" not in text:
        errors.append("app/build.gradle.kts must set vcsInfo { include = false }")
    if "dependenciesInfo" not in text or "includeInApk = false" not in text:
        errors.append(
            "app/build.gradle.kts must set dependenciesInfo { includeInApk = false }"
        )
    properties = tree / "gradle.properties"
    if properties.is_file():
        props = properties.read_text(encoding="utf-8")
        if "osrsUndergroundAssetsDir" in props:
            errors.append("gradle.properties sets osrsUndergroundAssetsDir")
    assets = tree / "app" / "src" / "main" / "assets"
    leaked_dir = assets / "assets"
    if leaked_dir.exists():
        errors.append(f"refusing tree with {leaked_dir} (underground cache layout)")
    leaked_json = assets / "underground-realms.json"
    if leaked_json.exists():
        errors.append(
            f"refusing tree with {leaked_json} (must stay on the fixture stub)"
        )
    for env_name in UNDERGROUND_ENV:
        if os.environ.get(env_name):
            errors.append(f"refusing to assemble while {env_name} is set")
    return errors


def parse_apksigner_signer_digest(output: str) -> str | None:
    match = re.search(
        r"Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})",
        output,
    )
    if not match:
        return None
    return match.group(1).lower()


def run_checked(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )


def check_signed_apk(
    apk: Path,
    *,
    unsigned_apk: Path | None,
    reference_unsigned_apk: Path | None,
    apksigner: Path | None,
    apksigcopier: Path | None,
) -> tuple[list[str], list[str], dict[str, str]]:
    errors: list[str] = []
    report: list[str] = []
    facts: dict[str, str] = {
        "apk": str(apk),
        "apk_sha256": sha256_file(apk),
        "apk_bytes": str(apk.stat().st_size),
    }
    names = zip_names(apk)
    leaked = assets_assets_entries(names)
    facts["assets_assets_count"] = str(len(leaked))
    report.append(f"assets/assets entries: {len(leaked)}")
    if leaked:
        preview = "\n".join(f"  {name}" for name in leaked[:30])
        errors.append("APK contains assets/assets/ (underground cache leak):\n" + preview)
        report.append(preview)
    else:
        report.append("ASSETS_ASSETS_GATE=PASS")

    if VCSINFO_MEMBER in names:
        errors.append(f"APK contains {VCSINFO_MEMBER}")
        report.append("VCSINFO_ABSENT FAIL")
    else:
        report.append("VCSINFO_ABSENT PASS")

    json_members = [
        name for name in names if name.endswith("underground-realms.json")
    ]
    if "assets/underground-realms.json" not in json_members:
        errors.append("APK is missing assets/underground-realms.json")
    else:
        payload = json.loads(read_zip_text(apk, "assets/underground-realms.json"))
        facts["underground_candidate"] = str(payload.get("candidate"))
        json_errors = check_fixture_underground_json(payload)
        if json_errors:
            errors.extend(json_errors)
            report.append("UNDERGROUND_JSON_GATE=FAIL")
        else:
            report.append("UNDERGROUND_JSON_GATE=PASS candidate=fixture")

    floor_names = [
        f"assets/map_floor_{floor}.mbtiles" for floor in range(4)
    ]
    missing_floors = [name for name in floor_names if name not in names]
    if missing_floors:
        errors.append("APK missing F-Droid map floors: " + ", ".join(missing_floors))
    else:
        report.append("MAP_FLOORS_GATE=PASS")

    try:
        pairs = parse_signing_block(apk)
    except SigningBlockError as exc:
        errors.append(f"signing block: {exc}")
        report.append(f"SIGNING_BLOCKS_GATE=FAIL {exc}")
    else:
        block_report, extra = format_report(apk, pairs)
        report.append(block_report.rstrip())
        if extra:
            errors.append("APK Signing Block contains non-v2/v3 IDs")
        facts["signing_pair_count"] = str(len(pairs))

    if apksigner is None:
        errors.append("apksigner is required to verify the FOSS signer")
    else:
        verify = run_checked(
            [str(apksigner), "verify", "--verbose", "--print-certs", str(apk)]
        )
        report.append(verify.stdout.rstrip() or verify.stderr.rstrip())
        if verify.returncode != 0:
            errors.append("apksigner verify failed")
        digest = parse_apksigner_signer_digest(verify.stdout + verify.stderr)
        facts["signer_sha256"] = digest or ""
        if digest != ALLOWED_SIGNER_SHA256:
            errors.append(
                "signer SHA-256 is "
                f"{digest or 'missing'}, expected {ALLOWED_SIGNER_SHA256}"
            )
        else:
            report.append("SIGNER_GATE=PASS")
        combined = verify.stdout + verify.stderr
        if "Verified using v2 scheme (APK Signature Scheme v2): true" not in combined:
            errors.append("APK is not verified as v2-signed")
        for scheme, needle in (
            ("v1", "Verified using v1 scheme (JAR signing): true"),
            ("v3", "Verified using v3 scheme (APK Signature Scheme v3): true"),
            ("v3.1", "Verified using v3.1 scheme (APK Signature Scheme v3.1): true"),
            ("v4", "Verified using v4 scheme (APK Signature Scheme v4): true"),
        ):
            if needle in combined:
                errors.append(f"APK is signed with {scheme}; FOSS must be v2-only")

    compare_targets: list[tuple[str, Path]] = []
    if unsigned_apk is not None:
        compare_targets.append(("unsigned", unsigned_apk))
    if reference_unsigned_apk is not None:
        compare_targets.append(("reference-unsigned", reference_unsigned_apk))
        facts["reference_unsigned_sha256"] = sha256_file(reference_unsigned_apk)
    if unsigned_apk is not None:
        facts["unsigned_sha256"] = sha256_file(unsigned_apk)
    if unsigned_apk is not None and reference_unsigned_apk is not None:
        if facts["unsigned_sha256"] != facts["reference_unsigned_sha256"]:
            errors.append(
                "unsigned FOSS APK does not match the independent F-Droid-style rebuild"
            )
        else:
            report.append("UNSIGNED_SHA256_GATE=PASS")
        zip_errors = compare_unsigned_zip_contents(
            unsigned_apk, reference_unsigned_apk
        )
        if zip_errors:
            errors.extend(zip_errors)
            report.append("ZIP_CONTENT_GATE=FAIL")
        else:
            report.append("ZIP_CONTENT_GATE=PASS")

    if apksigcopier is None:
        errors.append("apksigcopier is required for the reproducible-build compare")
    else:
        compare_env = dict(os.environ)
        if apksigner is not None:
            compare_env["PATH"] = str(apksigner.parent) + os.pathsep + compare_env.get(
                "PATH", ""
            )
        for label, other in compare_targets:
            compare = subprocess.run(
                [str(apksigcopier), "compare", "--unsigned", str(apk), str(other)],
                check=False,
                capture_output=True,
                text=True,
                env=compare_env,
            )
            report.append(
                f"apksigcopier compare --unsigned ({label}) exit={compare.returncode}"
            )
            if compare.stdout.strip():
                report.append(compare.stdout.rstrip())
            if compare.stderr.strip():
                report.append(compare.stderr.rstrip())
            if compare.returncode != 0:
                errors.append(
                    f"apksigcopier compare --unsigned failed against {label}"
                )
            else:
                report.append(f"APKSIGCOPIER_{label.upper().replace('-', '_')}=PASS")

    return errors, report, facts


def render_report(
    errors: list[str],
    details: list[str],
    facts: dict[str, str],
) -> str:
    lines = ["FOSS APK preflight", "==================", ""]
    for key, value in facts.items():
        lines.append(f"{key}={value}")
    lines.append("")
    lines.extend(details)
    lines.append("")
    if errors:
        lines.append("PREFLIGHT=FAIL")
        for error in errors:
            lines.append(f"- {error}")
    else:
        lines.append("PREFLIGHT=PASS")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--unsigned-apk", type=Path)
    parser.add_argument("--reference-unsigned-apk", type=Path)
    parser.add_argument("--source-tree", type=Path)
    parser.add_argument("--apksigner", type=Path)
    parser.add_argument("--apksigcopier", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)

    errors: list[str] = []
    details: list[str] = []
    facts: dict[str, str] = {}
    if args.source_tree is not None:
        source_errors = check_source_tree(args.source_tree)
        errors.extend(source_errors)
        details.append(
            "SOURCE_TREE_GATE=" + ("FAIL" if source_errors else "PASS")
        )
    if args.apk.is_file():
        apk_errors, apk_details, facts = check_signed_apk(
            args.apk,
            unsigned_apk=args.unsigned_apk,
            reference_unsigned_apk=args.reference_unsigned_apk,
            apksigner=args.apksigner,
            apksigcopier=args.apksigcopier,
        )
        errors.extend(apk_errors)
        details.extend(apk_details)
    else:
        errors.append(f"missing APK: {args.apk}")

    text = render_report(errors, details, facts)
    sys.stdout.write(text)
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
