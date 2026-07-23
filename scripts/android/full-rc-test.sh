#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/platforms/android"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-full-rc)}"

ALLOW_MISSING_DEVICE=false
SKIP_CONNECTED=false
SKIP_INSTALL=false
RUN_PERFORMANCE=false
RUN_BROWSER_SMOKE=false
RUN_BILLING_SMOKE=false
RUN_SPEECH_SMOKE=false
BROWSER_SMOKE_URL="https://www.patreon.com/runescapewiki"

usage() {
    cat <<'USAGE'
Usage: scripts/android/full-rc-test.sh [options]

Runs the Android release-candidate test gate and writes logs/evidence to one
directory. Device-backed gates require ANDROID_SERIAL unless explicitly skipped.

Options:
  --allow-missing-device  Run JVM/static gates and record device gates as skipped.
  --skip-connected       Skip connected instrumentation tests.
  --skip-install         Skip build/install/launch smoke.
  --performance          Run optional appearance latency measurement.
  --browser-smoke        Run optional prepared-browser external URL smoke.
  --browser-url URL      URL for --browser-smoke. Defaults to the Patreon URL.
  --billing-smoke        Run optional Play Billing diagnostic smoke.
  --speech-smoke         Run optional speech recognizer availability smoke.
  -h, --help             Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-missing-device)
            ALLOW_MISSING_DEVICE=true
            shift
            ;;
        --skip-connected)
            SKIP_CONNECTED=true
            shift
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --performance)
            RUN_PERFORMANCE=true
            shift
            ;;
        --browser-smoke)
            RUN_BROWSER_SMOKE=true
            shift
            ;;
        --browser-url)
            BROWSER_SMOKE_URL="$2"
            shift 2
            ;;
        --billing-smoke)
            RUN_BILLING_SMOKE=true
            shift
            ;;
        --speech-smoke)
            RUN_SPEECH_SMOKE=true
            shift
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
mkdir -p "$EVIDENCE_DIR"
SUMMARY="$EVIDENCE_DIR/summary.md"
: > "$SUMMARY"

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

log_summary() {
    printf '%s\n' "$*" | tee -a "$SUMMARY"
}

run_step() {
    local name="$1"
    shift
    local log_file="$EVIDENCE_DIR/${name}.log"
    local command_string

    printf -v command_string '%q ' "$@"
    command_string="${command_string% }"

    log_summary "- RUN $name: \`$command_string\`"
    if "$@" >"$log_file" 2>&1; then
        log_summary "  PASS $name"
        return 0
    fi

    log_summary "  FAIL $name. See \`$log_file\`."
    return 1
}

record_skip() {
    local name="$1"
    local reason="$2"
    printf '%s\n' "$reason" > "$EVIDENCE_DIR/SKIPPED-${name}.txt"
    log_summary "- SKIP $name: $reason"
}

run_gradle() {
    local name="$1"
    shift
    local log_file="$EVIDENCE_DIR/${name}.log"
    local command_string

    printf -v command_string '%q ' ./gradlew --no-daemon "$@"
    command_string="${command_string% }"
    log_summary "- RUN $name: \`cd $ANDROID_DIR && $command_string\`"

    if (cd "$ANDROID_DIR" && ./gradlew --no-daemon "$@") >"$log_file" 2>&1; then
        log_summary "  PASS $name"
        return 0
    fi

    log_summary "  FAIL $name. See \`$log_file\`."
    return 1
}

log_summary "# Android RC Test Evidence"
log_summary ""
log_summary "- Evidence: \`$EVIDENCE_DIR\`"
log_summary "- Repo: \`$REPO_ROOT\`"
log_summary "- Android project: \`$ANDROID_DIR\`"
log_summary "- ANDROID_SERIAL: \`${ANDROID_SERIAL:-unset}\`"
log_summary "- Started: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
log_summary ""

run_step "git-status" git -C "$REPO_ROOT" status --short --branch
run_gradle "unit-tests" ":app:testDebugUnitTest"
run_gradle "lint-debug" ":app:lintDebug"
run_gradle "assemble-debug" ":app:assembleDebug"

DEVICE_AVAILABLE=false
if [[ -n "${ANDROID_SERIAL:-}" ]] && adb -s "$ANDROID_SERIAL" get-state >/dev/null 2>&1; then
    DEVICE_AVAILABLE=true
fi

if [[ "$DEVICE_AVAILABLE" != true ]]; then
    if [[ "$ALLOW_MISSING_DEVICE" == true ]]; then
        record_skip "device-gates" "ANDROID_SERIAL is unset or unavailable; connected/install gates were not run."
        log_summary ""
        log_summary "Result: PARTIAL PASS. Device-backed RC gates were skipped."
        exit 0
    fi

    log_summary ""
    log_summary "Result: FAIL. ANDROID_SERIAL is required for a full RC run."
    echo "ANDROID_SERIAL is unset or unavailable. Evidence: $EVIDENCE_DIR" >&2
    exit 2
fi

run_step "environment-check" "$SCRIPT_DIR/qa-environment-check.sh"

if [[ "$SKIP_INSTALL" == true ]]; then
    record_skip "install-smoke" "Skipped by --skip-install."
else
    run_step "build-install" "$SCRIPT_DIR/qa-build-install.sh"

    APPID="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"
    if [[ -n "$APPID" ]]; then
        MAIN_ACTIVITY="$(adb -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief \
            -a android.intent.action.MAIN \
            -c android.intent.category.LAUNCHER \
            -p "$APPID" 2>/dev/null | tail -n1 | tr -d '\r' || true)"
        if [[ -n "$MAIN_ACTIVITY" && "$MAIN_ACTIVITY" == "$APPID"* ]]; then
            run_step "launch-smoke" adb -s "$ANDROID_SERIAL" shell am start -W -n "$MAIN_ACTIVITY"
        else
            record_skip "launch-smoke" "Could not resolve Android launcher activity for $APPID."
        fi
        sleep 2
        adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$EVIDENCE_DIR/launch-smoke.png" || true
        adb -s "$ANDROID_SERIAL" shell uiautomator dump /dev/stdout > "$EVIDENCE_DIR/launch-smoke-ui.xml" 2>/dev/null || true
    else
        record_skip "launch-smoke" "Could not resolve Android application id."
    fi
fi

if [[ "$SKIP_CONNECTED" == true ]]; then
    record_skip "connected-tests" "Skipped by --skip-connected."
else
    run_step "connected-tests" "$SCRIPT_DIR/qa-connected-test.sh"
fi

if [[ "$RUN_PERFORMANCE" == true ]]; then
    run_step "appearance-latency" "$SCRIPT_DIR/measure-appearance-latency.sh"
else
    record_skip "appearance-latency" "Optional performance measurement not requested. Re-run with --performance."
fi

if [[ "$RUN_BROWSER_SMOKE" == true ]]; then
    run_step "browser-url-smoke" "$SCRIPT_DIR/browser-url-smoke.sh" --url "$BROWSER_SMOKE_URL"
else
    record_skip "browser-url-smoke" "Optional prepared-browser URL smoke not requested. Re-run with --browser-smoke."
fi

if [[ "$RUN_BILLING_SMOKE" == true ]]; then
    billing_args=("$SCRIPT_DIR/billing-service-smoke.sh")
    if [[ "$SKIP_INSTALL" == true ]]; then
        billing_args+=("--skip-install")
    fi
    run_step "billing-service-smoke" "${billing_args[@]}"
else
    record_skip "billing-service-smoke" "Optional Play Billing diagnostic smoke not requested. Re-run with --billing-smoke."
fi

if [[ "$RUN_SPEECH_SMOKE" == true ]]; then
    speech_args=("$SCRIPT_DIR/speech-service-smoke.sh")
    if [[ "$SKIP_INSTALL" == true ]]; then
        speech_args+=("--skip-install")
    fi
    run_step "speech-service-smoke" "${speech_args[@]}"
else
    record_skip "speech-service-smoke" "Optional speech recognizer smoke not requested. Re-run with --speech-smoke."
fi

log_summary ""
log_summary "- Finished: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
log_summary "Result: PASS"
echo "Android RC test gate complete. Evidence: $EVIDENCE_DIR"
