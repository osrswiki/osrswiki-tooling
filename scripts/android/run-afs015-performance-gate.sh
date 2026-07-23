#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/platforms/android"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-afs015-performance-gate)}"
ITERATIONS="${AFS015_ITERATIONS:-3}"
CLASS_FILTER="com.omiyawaki.osrswiki.macrobenchmark.Afs015PerformanceBenchmark"

usage() {
    cat <<'USAGE'
Usage: scripts/android/run-afs015-performance-gate.sh [options]

Runs the AFS-015 Android Macrobenchmark performance gate on the selected emulator.

Options:
  --output-dir DIR  Evidence directory. Defaults to the verified local artifact root.
  --iterations N    Macrobenchmark iterations per flow. Defaults to AFS015_ITERATIONS or 3.
  --class NAME      Instrumentation class or class#method filter.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        --class)
            CLASS_FILTER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

EVIDENCE_DIR="$(osrs_assert_artifact_path "$EVIDENCE_DIR")"
if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "ANDROID_SERIAL not set" >&2
    exit 2
fi

if [[ ! "$ITERATIONS" =~ ^[0-9]+$ || "$ITERATIONS" -lt 1 ]]; then
    echo "--iterations must be a positive integer" >&2
    exit 2
fi

mkdir -p "$EVIDENCE_DIR/logs" "$EVIDENCE_DIR/preflight"
COMMAND_FILE="$EVIDENCE_DIR/command.txt"
APPID="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"

{
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo_root=%s\n' "$REPO_ROOT"
    printf 'android_serial=%s\n' "$ANDROID_SERIAL"
    printf 'class_filter=%s\n' "$CLASS_FILTER"
    printf 'iterations=%s\n' "$ITERATIONS"
    printf 'app_id=%s\n' "${APPID:-unresolved}"
    printf 'gradle_task=%s\n' ':macrobenchmark:connectedBenchmarkAndroidTest'
} > "$COMMAND_FILE"

run_capture() {
    local name="$1"
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } > "$EVIDENCE_DIR/logs/$name.txt" 2>&1 || true
}

run_preflight_capture() {
    local name="$1"
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } > "$EVIDENCE_DIR/preflight/$name.txt" 2>&1 || true
}

capture_preflight() {
    local device_count
    device_count="$(adb devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }')"

    {
        printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'android_serial=%s\n' "$ANDROID_SERIAL"
        printf 'connected_adb_device_count=%s\n' "$device_count"
        printf 'app_id=%s\n' "${APPID:-unresolved}"
        if [[ "$device_count" -gt 1 ]]; then
            printf 'contention_warning=%s\n' "multiple adb devices/emulators are connected; use this run as baseline-quality only when the selected serial and host are otherwise quiet"
        fi
    } > "$EVIDENCE_DIR/preflight/preflight.properties"

    run_preflight_capture "host-date" date -u
    run_preflight_capture "host-uptime" uptime
    run_preflight_capture "host-uname" uname -a
    run_preflight_capture "host-emulator-processes" bash -lc "ps -axo pid,pcpu,pmem,command | grep -E 'emulator|qemu-system|adb|gradle|java' | grep -v grep"
    run_preflight_capture "host-top-cpu" bash -lc "ps -axo pid,pcpu,pmem,command | sort -nr -k2 | head -40"
    run_preflight_capture "adb-devices" adb devices -l
    run_preflight_capture "device-build-fingerprint" adb -s "$ANDROID_SERIAL" shell getprop ro.build.fingerprint
    run_preflight_capture "device-sdk" adb -s "$ANDROID_SERIAL" shell getprop ro.build.version.sdk
    run_preflight_capture "device-battery" adb -s "$ANDROID_SERIAL" shell dumpsys battery
    run_preflight_capture "device-orientation" adb -s "$ANDROID_SERIAL" shell sh -c "settings get system accelerometer_rotation; settings get system user_rotation; dumpsys input | grep -E 'SurfaceOrientation|orientation'"
    run_preflight_capture "device-network" adb -s "$ANDROID_SERIAL" shell sh -c "settings get global airplane_mode_on; dumpsys connectivity | head -160"
    run_preflight_capture "device-focused-window" adb -s "$ANDROID_SERIAL" shell dumpsys window
    run_preflight_capture "device-activities" adb -s "$ANDROID_SERIAL" shell dumpsys activity activities
    run_preflight_capture "device-processes" adb -s "$ANDROID_SERIAL" shell sh -c "ps -A | grep -E 'instrumentation|uiautomator|com.omiyawaki.osrswiki|androidx.test|am instrument' || true"
    run_preflight_capture "device-instrumentations" adb -s "$ANDROID_SERIAL" shell cmd package list instrumentation
    run_preflight_capture "device-osrs-packages" adb -s "$ANDROID_SERIAL" shell pm list packages com.omiyawaki.osrswiki
    if [[ -n "$APPID" ]]; then
        run_preflight_capture "device-target-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID"
    fi
}

copy_benchmark_outputs() {
    local build_dir="$ANDROID_DIR/macrobenchmark/build"
    local output_root="$EVIDENCE_DIR/macrobenchmark-build"
    rm -rf "$output_root"
    mkdir -p "$output_root"
    for dir in outputs reports test-results; do
        if [[ -d "$build_dir/$dir" ]]; then
            mkdir -p "$output_root/$dir"
            cp -R "$build_dir/$dir/." "$output_root/$dir/"
        fi
    done
}

clear_previous_benchmark_outputs() {
    local build_dir="$ANDROID_DIR/macrobenchmark/build"
    rm -rf \
        "$build_dir/outputs/androidTest-results" \
        "$build_dir/outputs/connected_android_test_additional_output" \
        "$build_dir/reports/androidTests/connected" \
        "$build_dir/test-results"
}

annotate_failed_run_summary() {
    if [[ ! -f "$EVIDENCE_DIR/summary.md" ]]; then
        return
    fi

    local tmp_summary="$EVIDENCE_DIR/summary.md.tmp"
    {
        printf '# AFS-015 Android Performance Gate Summary\n\n'
        printf -- '- Gate status: FAILED\n'
        printf -- '- Gradle status: %s\n' "$GRADLE_STATUS"
        printf -- '- Metrics parser status: %s\n' "$SUMMARY_STATUS"
        printf -- '- Note: Partial metrics below are preserved for triage, but this run did not complete every target flow.\n'
        tail -n +2 "$EVIDENCE_DIR/summary.md"
    } > "$tmp_summary"
    mv "$tmp_summary" "$EVIDENCE_DIR/summary.md"
}

capture_preflight

run_capture "adb-devices" adb devices -l
run_capture "device-build" adb -s "$ANDROID_SERIAL" shell getprop ro.build.fingerprint
run_capture "device-sdk" adb -s "$ANDROID_SERIAL" shell getprop ro.build.version.sdk

if [[ -n "$APPID" ]]; then
    # Avoid signature mismatch with a previously installed debug/play build.
    adb -s "$ANDROID_SERIAL" uninstall "$APPID" > "$EVIDENCE_DIR/logs/uninstall-app.txt" 2>&1 || true
fi
adb -s "$ANDROID_SERIAL" uninstall com.omiyawaki.osrswiki.macrobenchmark \
    > "$EVIDENCE_DIR/logs/uninstall-macrobenchmark.txt" 2>&1 || true

clear_previous_benchmark_outputs

GRADLE_ARGS=(
    --no-daemon
    :macrobenchmark:connectedBenchmarkAndroidTest
    "-Pandroid.testInstrumentationRunnerArguments.class=$CLASS_FILTER"
    "-Pandroid.testInstrumentationRunnerArguments.afs015.iterations=$ITERATIONS"
    --console=plain
)

set +e
(
    cd "$ANDROID_DIR"
    ./gradlew "${GRADLE_ARGS[@]}"
) > "$EVIDENCE_DIR/logs/gradle-macrobenchmark.log" 2>&1
GRADLE_STATUS=$?
set -e

copy_benchmark_outputs

if [[ -n "$APPID" ]]; then
    ANDROID_SERIAL="$ANDROID_SERIAL" "$SCRIPT_DIR/qa-environment-check.sh" \
        --output-dir "$EVIDENCE_DIR/env-check" \
        --package "$APPID" > "$EVIDENCE_DIR/logs/qa-environment-check.log" 2>&1 || true
fi

set +e
python3 "$SCRIPT_DIR/afs015_benchmark_summary.py" \
    --input-dir "$EVIDENCE_DIR/macrobenchmark-build/outputs" \
    --summary "$EVIDENCE_DIR/summary.md" \
    --csv "$EVIDENCE_DIR/metrics.csv" \
    > "$EVIDENCE_DIR/logs/benchmark-summary.log" 2>&1
SUMMARY_STATUS=$?
set -e

printf 'gradle_status=%s\nsummary_status=%s\n' "$GRADLE_STATUS" "$SUMMARY_STATUS" \
    > "$EVIDENCE_DIR/result.properties"

if [[ "$GRADLE_STATUS" -ne 0 ]]; then
    annotate_failed_run_summary
fi

if [[ "$GRADLE_STATUS" -ne 0 ]]; then
    echo "AFS-015 Macrobenchmark run failed. Evidence: $EVIDENCE_DIR" >&2
    exit "$GRADLE_STATUS"
fi

if [[ "$SUMMARY_STATUS" -ne 0 ]]; then
    echo "AFS-015 performance gate failed. Evidence: $EVIDENCE_DIR" >&2
    exit "$SUMMARY_STATUS"
fi

echo "AFS-015 performance gate passed. Evidence: $EVIDENCE_DIR"
