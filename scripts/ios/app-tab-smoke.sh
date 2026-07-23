#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(ios_local_evidence_path ios-tab-smoke)}"
WAIT_SECONDS=3

usage() {
    cat <<'USAGE'
Usage: scripts/ios/app-tab-smoke.sh [options]

Launches the installed app directly into each main tab and captures simulator
screenshots/logs without relying on global keyboard or click coordinates.

Options:
  --output-dir DIR  Evidence directory.
  --wait SECONDS    Seconds to wait after each launch. Default: 3.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --wait)
            WAIT_SECONDS="$2"
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

EVIDENCE_DIR="$(ios_validate_evidence_dir "$EVIDENCE_DIR")"
mkdir -p "$EVIDENCE_DIR"
SUMMARY="$EVIDENCE_DIR/tab-smoke-summary.properties"
: > "$SUMMARY"

fact() {
    printf '%s=%s\n' "$1" "$2" | tee -a "$SUMMARY" >/dev/null
}

ios_require_macos
ios_select_simulator
ios_boot_selected_simulator
BUNDLE_ID="$(ios_resolve_bundle_id)"
export BUNDLE_ID

fact "started_utc" "$(ios_utc_now)"
fact "evidence_dir" "$EVIDENCE_DIR"
fact "ios_simulator_udid" "$IOS_SIMULATOR_UDID"
fact "bundle_id" "$BUNDLE_ID"

if ! xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" app >/dev/null 2>&1; then
    fact "app_installed" "false"
    echo "App $BUNDLE_ID is not installed on $IOS_SIMULATOR_UDID. Run scripts/ios/qa-build-install.sh first." >&2
    exit 2
fi
fact "app_installed" "true"

for tab in news map search saved more; do
    launch_log="$EVIDENCE_DIR/launch-$tab.log"
    screenshot="$EVIDENCE_DIR/tab-$tab.png"

    xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if ios_run_capture "$launch_log" \
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" \
            -disableBackgroundPreloading \
            -screenshotMode \
            -resetSavedPagesForUITests \
            -seedSavedPagesForUITests \
            -startTab "$tab"; then
        fact "launch_$tab" "pass"
    else
        fact "launch_$tab" "fail"
        exit 1
    fi

    sleep "$WAIT_SECONDS"

    if xcrun simctl io "$IOS_SIMULATOR_UDID" screenshot "$screenshot" >/dev/null 2>&1; then
        fact "screenshot_$tab" "$screenshot"
    else
        fact "screenshot_$tab" "failed"
        exit 1
    fi
done

ios_run_capture "$EVIDENCE_DIR/recent-app-log.txt" xcrun simctl spawn "$IOS_SIMULATOR_UDID" log show --last 5m --style compact --predicate 'process == "osrswiki"' || true
fact "finished_utc" "$(ios_utc_now)"
echo "iOS tab smoke complete. Evidence: $EVIDENCE_DIR"
