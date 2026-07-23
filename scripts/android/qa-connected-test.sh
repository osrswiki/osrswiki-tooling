#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/platforms/android"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-connected-test)}"

usage() {
    cat <<'USAGE'
Usage: scripts/android/qa-connected-test.sh [options] [-- gradle-args...]

Runs Android connected tests on the selected ADB device and captures final UI evidence.

Options:
  --class NAME      Restrict instrumentation to one test class.
  --output-dir DIR  Evidence directory. Must be under the verified local root.
  -h, --help        Show this help.
USAGE
}

CLASS_FILTER=""
GRADLE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --class)
            CLASS_FILTER="$2"
            shift 2
            ;;
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            GRADLE_ARGS+=("$@")
            break
            ;;
        *)
            GRADLE_ARGS+=("$1")
            shift
            ;;
    esac
done

EVIDENCE_DIR="$(osrs_assert_artifact_path "$EVIDENCE_DIR")"
mkdir -p "$EVIDENCE_DIR"

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "ANDROID_SERIAL not set" >&2
    exit 2
fi

run_gradle() {
    local log_file="$1"
    shift
    (cd "$ANDROID_DIR" && ./gradlew --no-daemon "$@") >"$log_file" 2>&1
}

collect_artifacts() {
    local appid
    appid="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"

    adb -s "$ANDROID_SERIAL" exec-out screencap -p >"$EVIDENCE_DIR/final-device-screenshot.png" 2>/dev/null || true
    adb -s "$ANDROID_SERIAL" shell uiautomator dump /dev/stdout >"$EVIDENCE_DIR/final-ui.xml" 2>/dev/null || true
    adb -s "$ANDROID_SERIAL" shell dumpsys window displays >"$EVIDENCE_DIR/final-window-focus.txt" 2>&1 || true
    adb -s "$ANDROID_SERIAL" pull \
        /sdcard/Download/osrswiki-expanded-map-screenshot.png \
        "$EVIDENCE_DIR/expanded-map-screenshot.png" >/dev/null 2>&1 || true
    adb -s "$ANDROID_SERIAL" shell rm \
        /sdcard/Download/osrswiki-expanded-map-screenshot.png >/dev/null 2>&1 || true

    if [[ -n "$appid" ]] &&
        adb -s "$ANDROID_SERIAL" shell run-as "$appid" test -f cache/expanded-map-screenshot.png >/dev/null 2>&1; then
        adb -s "$ANDROID_SERIAL" exec-out run-as "$appid" cat cache/expanded-map-screenshot.png \
            >"$EVIDENCE_DIR/expanded-map-screenshot.png" 2>/dev/null || true
    fi
}

is_stale_build_failure() {
    local log_file="$1"
    grep -E 'parseDebugLocalResources|NullPointerException|resource|Type .* is defined multiple times| [0-9]+\.dex| [0-9]+\.xml' "$log_file" >/dev/null
}

TASK_ARGS=()
if [[ -n "$CLASS_FILTER" ]]; then
    TASK_ARGS+=("-Pandroid.testInstrumentationRunnerArguments.class=$CLASS_FILTER")
fi
if [[ ${#GRADLE_ARGS[@]} -gt 0 ]]; then
    TASK_ARGS+=("${GRADLE_ARGS[@]}")
fi
TASK_ARGS+=(":app:connectedDebugAndroidTest")

if run_gradle "$EVIDENCE_DIR/gradle-connected-test.log" "${TASK_ARGS[@]}"; then
    collect_artifacts
    echo "Connected test succeeded. Evidence: $EVIDENCE_DIR"
    exit 0
fi

collect_artifacts

if is_stale_build_failure "$EVIDENCE_DIR/gradle-connected-test.log"; then
    echo "Initial connected test failed with a stale build-output signature; retrying with clean."
    if run_gradle "$EVIDENCE_DIR/gradle-clean-connected-test.log" clean "${TASK_ARGS[@]}"; then
        collect_artifacts
        echo "Clean retry succeeded. Evidence: $EVIDENCE_DIR"
        exit 0
    fi
    collect_artifacts
    echo "Clean retry failed. Evidence: $EVIDENCE_DIR" >&2
    exit 1
fi

echo "Connected test failed. Evidence: $EVIDENCE_DIR" >&2
exit 1
