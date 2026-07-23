#!/usr/bin/env python3
"""Run and collect the Android deep navigation stack audit.

The live stack audit itself runs inside Android instrumentation so it can launch
unexported PageActivity instances and observe activity lifecycle state. This
host runner keeps the Gradle/adb commands reproducible and pulls the raw JSONL
manifest back into the repo evidence directory.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


APP_ID = "com.omiyawaki.osrswiki"
RUNNER = "androidx.test.runner.AndroidJUnitRunner"
TEST_CLASS = "com.omiyawaki.osrswiki.page.AndroidDeepNavigationStackAuditTest"
FIXTURE_TEST_CLASS = "com.omiyawaki.osrswiki.page.AndroidDeepNavigationFixtureAuditTest"
STORAGE_HELPER = Path(__file__).resolve().parents[1] / "shared" / "local-artifact-root.sh"
DEFAULT_SEED = 20260709
DEFAULT_START_COUNT = 10_000
DEFAULT_DEPTH = 100
DEVICE_OUTPUT_DIR = "android-deep-navigation-stack-audit-2026-07-09"
FIXTURE_DEVICE_OUTPUT_DIR = "android-deep-navigation-harness-parity-2026-07-09"


def default_evidence_dir() -> Path:
    lane_id = os.environ.get("OSRS_LANE_ID", "android-deep-navigation-stack-audit")
    output = subprocess.check_output(
        [str(STORAGE_HELPER), "path", "active", lane_id, "audit-output"],
        text=True,
        env=os.environ,
    )
    return Path(output.strip())


def validated_evidence_dir(path: Path) -> Path:
    output = subprocess.check_output(
        [str(STORAGE_HELPER), "validate-path", str(path.resolve())],
        text=True,
        env=os.environ,
    )
    return Path(output.strip())


def run(cmd: list[str], *, cwd: Path, log_path: Path, env: dict[str, str], check: bool = True) -> subprocess.CompletedProcess[str]:
    started = time.time()
    completed = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    elapsed = time.time() - started
    log_path.parent.mkdir(parents=True, exist_ok=True)
    stdout_lines = [line.rstrip() for line in completed.stdout.splitlines()]
    while stdout_lines and stdout_lines[-1] == "":
        stdout_lines.pop()
    stdout = "\n".join(stdout_lines)
    log_text = (
        "$ " + " ".join(cmd) + "\n"
        + f"# elapsed_seconds={elapsed:.3f}\n"
        + f"# exit_code={completed.returncode}\n"
    )
    if stdout:
        log_text += "\n" + stdout + "\n"
    log_path.write_text(log_text, encoding="utf-8")
    if check and completed.returncode != 0:
        raise subprocess.CalledProcessError(completed.returncode, cmd, completed.stdout)
    return completed


def adb(serial: str, args: list[str]) -> list[str]:
    return ["adb", "-s", serial, *args]


def summarize_manifest(evidence_dir: Path) -> dict[str, object]:
    summary_path = evidence_dir / "device-files" / "summary.json"
    manifest_path = evidence_dir / "device-files" / "stack-manifest.jsonl"
    mismatches_path = evidence_dir / "device-files" / "mismatches.jsonl"
    summary: dict[str, object] = {}
    if summary_path.is_file():
        summary.update(json.loads(summary_path.read_text(encoding="utf-8")))
    if manifest_path.is_file():
        lines = [line for line in manifest_path.read_text(encoding="utf-8").splitlines() if line.strip()]
        summary["manifest_line_count"] = len(lines)
        summary["sample_plan_count"] = sum(1 for line in lines if '"event":"sample_plan"' in line)
    if mismatches_path.is_file():
        summary["mismatch_line_count"] = len([line for line in mismatches_path.read_text(encoding="utf-8").splitlines() if line.strip()])
    return summary


def require_summary_passed(summary: dict[str, object], args: argparse.Namespace) -> None:
    errors: list[str] = []

    def require_equal(key: str, expected: object) -> None:
        actual = summary.get(key)
        if actual != expected:
            errors.append(f"{key} expected {expected!r}, got {actual!r}")

    if args.deterministic_fixture:
        require_equal("result", "pass")
        require_equal("start_count", args.start_count)
        require_equal("target_depth", args.depth)
        require_equal("completed_starts", args.start_count)
        require_equal("completed_samples", args.start_count)
        require_equal("forward_transitions", args.start_count * args.depth)
        require_equal("forward_pages", args.start_count * args.depth)
        require_equal("back_transitions", args.start_count * args.depth)
        require_equal("back_checks", args.start_count * args.depth)
        require_equal("render_timeouts", 0)
    else:
        require_equal("completed_samples", args.start_count)
        require_equal("forward_pages", args.start_count * args.depth)
        require_equal("back_checks", args.start_count * args.depth)

    require_equal("mismatch_count", 0)
    require_equal("sample_aborts", 0)

    if errors:
        raise SystemExit("Android deep-navigation audit did not satisfy requested criteria:\n- " + "\n- ".join(errors))


def require_emulator(serial: str, *, repo_root: Path, logs_dir: Path, env: dict[str, str]) -> None:
    qemu = run(
        adb(serial, ["shell", "getprop", "ro.kernel.qemu"]),
        cwd=repo_root,
        log_path=logs_dir / "adb-emulator-check.txt",
        env=env,
        check=False,
    )
    if qemu.stdout.strip() != "1":
        raise SystemExit(
            f"Device {serial} is not an Android emulator (ro.kernel.qemu={qemu.stdout.strip()!r}). "
            "Android deep-navigation audits must run on an emulator."
        )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", type=Path, default=default_evidence_dir())
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL", ""))
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--start-count", type=int, default=DEFAULT_START_COUNT)
    parser.add_argument("--depth", type=int, default=DEFAULT_DEPTH)
    parser.add_argument("--render-timeout-ms", type=int, default=30_000)
    parser.add_argument("--wait-for-render", choices=("true", "false"), default="true")
    parser.add_argument("--max-runtime-ms", type=int, default=0, help="0 means no instrumentation-side runtime cap.")
    parser.add_argument("--skip-build-install", action="store_true")
    parser.add_argument("--deterministic-fixture", action="store_true", help="Run the DEBUG/test-gated native-stack fixture proof instead of the rendered WebView audit.")
    parser.add_argument("--fixture-batch-size", type=int, default=100, help="Starts per main-thread batch for --deterministic-fixture.")
    args = parser.parse_args(argv)

    repo_root = Path.cwd()
    android_root = repo_root / "platforms" / "android"
    evidence_dir = validated_evidence_dir(args.evidence_dir)
    logs_dir = evidence_dir / "logs"
    device_files_dir = evidence_dir / "device-files"
    shutil.rmtree(device_files_dir, ignore_errors=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    device_files_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    if args.serial:
        env["ANDROID_SERIAL"] = args.serial

    run_metadata = {
        "seed": args.seed,
        "start_index": args.start_index,
        "start_count": args.start_count,
        "depth": args.depth,
        "render_timeout_ms": args.render_timeout_ms,
        "wait_for_render": args.wait_for_render,
        "max_runtime_ms": args.max_runtime_ms,
        "serial": args.serial,
        "test_class": FIXTURE_TEST_CLASS if args.deterministic_fixture else TEST_CLASS,
        "deterministic_fixture": args.deterministic_fixture,
        "fixture_batch_size": args.fixture_batch_size if args.deterministic_fixture else None,
    }
    (evidence_dir / "run-arguments.json").write_text(json.dumps(run_metadata, indent=2, sort_keys=True), encoding="utf-8")

    devices = run(["adb", "devices", "-l"], cwd=repo_root, log_path=logs_dir / "adb-devices-before.txt", env=env, check=False)
    if not args.serial:
        raise SystemExit("ANDROID_SERIAL/--serial is required. adb devices output captured in logs/adb-devices-before.txt")
    if args.serial not in devices.stdout:
        raise SystemExit(f"Device {args.serial} is not present. adb devices output captured in logs/adb-devices-before.txt")
    require_emulator(args.serial, repo_root=repo_root, logs_dir=logs_dir, env=env)

    if not args.skip_build_install:
        run(["./gradlew", ":app:installDebug", ":app:installDebugAndroidTest", "--console=plain"], cwd=android_root, log_path=logs_dir / "gradle-install-debug-and-test.txt", env=env)

    remote_output_dir = FIXTURE_DEVICE_OUTPUT_DIR if args.deterministic_fixture else DEVICE_OUTPUT_DIR
    remote_base = f"/sdcard/Android/data/{APP_ID}/files/{remote_output_dir}"
    run(adb(args.serial, ["shell", "rm", "-rf", remote_base]), cwd=repo_root, log_path=logs_dir / "adb-clear-device-output.txt", env=env, check=False)
    run(adb(args.serial, ["logcat", "-c"]), cwd=repo_root, log_path=logs_dir / "adb-logcat-clear.txt", env=env, check=False)

    if args.deterministic_fixture:
        instrument_args = [
            "shell",
            "am",
            "instrument",
            "-w",
            "-e",
            "class",
            FIXTURE_TEST_CLASS,
            "-e",
            "fixtureOutputDir",
            FIXTURE_DEVICE_OUTPUT_DIR,
            "-e",
            "fixtureSeed",
            str(args.seed),
            "-e",
            "fixtureStartOffset",
            str(args.start_index),
            "-e",
            "fixtureStartCount",
            str(args.start_count),
            "-e",
            "fixtureDepth",
            str(args.depth),
            "-e",
            "fixtureBatchSize",
            str(args.fixture_batch_size),
        ]
    else:
        instrument_args = [
            "shell",
            "am",
            "instrument",
            "-w",
            "-e",
            "class",
            TEST_CLASS,
            "-e",
            "auditOutputDir",
            DEVICE_OUTPUT_DIR,
            "-e",
            "auditSeed",
            str(args.seed),
            "-e",
            "auditStartIndex",
            str(args.start_index),
            "-e",
            "auditStartCount",
            str(args.start_count),
            "-e",
            "auditDepth",
            str(args.depth),
            "-e",
            "auditRenderTimeoutMs",
            str(args.render_timeout_ms),
            "-e",
            "auditWaitForRender",
            args.wait_for_render,
        ]
        if args.max_runtime_ms > 0:
            instrument_args.extend(["-e", "auditMaxRuntimeMs", str(args.max_runtime_ms)])
    instrument_args.append(f"{APP_ID}.test/{RUNNER}")

    instrumentation = run(adb(args.serial, instrument_args), cwd=repo_root, log_path=logs_dir / "adb-instrumentation.txt", env=env, check=False)
    pull = run(adb(args.serial, ["pull", remote_base + "/.", str(device_files_dir)]), cwd=repo_root, log_path=logs_dir / "adb-pull-device-files.txt", env=env, check=False)
    run(adb(args.serial, ["logcat", "-d", "-t", "1000"]), cwd=repo_root, log_path=logs_dir / "adb-logcat-tail.txt", env=env, check=False)

    summary = summarize_manifest(evidence_dir)
    (evidence_dir / "host-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    if instrumentation.returncode != 0:
        raise SystemExit(f"Android instrumentation failed; see {logs_dir / 'adb-instrumentation.txt'}")
    if pull.returncode != 0:
        raise SystemExit(f"Could not pull Android audit device files; see {logs_dir / 'adb-pull-device-files.txt'}")
    require_summary_passed(summary, args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
