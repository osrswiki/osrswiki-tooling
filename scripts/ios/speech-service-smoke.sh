#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(ios_local_evidence_path ios-speech-smoke)}"

usage() {
    cat <<'USAGE'
Usage: scripts/ios/speech-service-smoke.sh [options]

Records iOS speech/microphone readiness evidence for voice-search testing.
Simulator privacy control exposes microphone but not Speech Recognition on this
Xcode version, so speech authorization remains covered by deterministic XCTest.

Options:
  --output-dir DIR  Evidence directory.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
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
SUMMARY="$EVIDENCE_DIR/speech-smoke-summary.properties"
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

if plutil -extract NSMicrophoneUsageDescription raw "$OSRS_IOS_DIR/osrswiki/Info.plist" >/dev/null 2>&1; then
    fact "microphone_usage_description" "present"
else
    fact "microphone_usage_description" "missing"
    exit 1
fi

if plutil -extract NSSpeechRecognitionUsageDescription raw "$OSRS_IOS_DIR/osrswiki/Info.plist" >/dev/null 2>&1; then
    fact "speech_usage_description" "present"
else
    fact "speech_usage_description" "missing"
    exit 1
fi

ios_run_capture "$EVIDENCE_DIR/simctl-privacy-help.txt" xcrun simctl privacy "$IOS_SIMULATOR_UDID" || true

if xcrun simctl privacy "$IOS_SIMULATOR_UDID" grant microphone "$BUNDLE_ID" >/dev/null 2>&1; then
    fact "microphone_privacy_grant" "pass"
else
    fact "microphone_privacy_grant" "fail"
fi

if xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" app >/dev/null 2>&1; then
    xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    ios_run_capture "$EVIDENCE_DIR/search-launch.log" \
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" \
            -disableBackgroundPreloading \
            -screenshotMode \
            -startTab search || true
    sleep 3
    xcrun simctl io "$IOS_SIMULATOR_UDID" screenshot "$EVIDENCE_DIR/search-tab-speech-readiness.png" >/dev/null 2>&1 || true
    fact "search_tab_launch" "attempted"
else
    fact "search_tab_launch" "skipped_app_not_installed"
fi

fact "speech_recognition_privacy_note" "simctl privacy does not list speech-recognition on this Xcode runtime"
fact "finished_utc" "$(ios_utc_now)"
echo "iOS speech service smoke complete. Evidence: $EVIDENCE_DIR"
