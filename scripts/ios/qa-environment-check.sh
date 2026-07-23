#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(ios_local_evidence_path ios-expanded-qa)}"
CAPTURE_SCREENSHOT=true

usage() {
    cat <<'USAGE'
Usage: scripts/ios/qa-environment-check.sh [options]

Records iOS QA environment facts and evidence for expanded simulator testing.

Options:
  --output-dir DIR  Evidence directory. Must be under the verified local root.
  --no-screenshot   Do not capture a simulator screenshot.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --no-screenshot)
            CAPTURE_SCREENSHOT=false
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

EVIDENCE_DIR="$(ios_validate_evidence_dir "$EVIDENCE_DIR")"
mkdir -p "$EVIDENCE_DIR"
LOG_FILE="$EVIDENCE_DIR/environment-check.log"
FACTS_FILE="$EVIDENCE_DIR/environment-facts.properties"
: > "$LOG_FILE"
: > "$FACTS_FILE"

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

fact() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$value" | tee -a "$FACTS_FILE" >/dev/null
}

record_helper() {
    local relative_path="$1"
    if [[ -e "$OSRS_REPO_ROOT/$relative_path" ]]; then
        fact "helper.${relative_path//\//_}" "present"
    else
        fact "helper.${relative_path//\//_}" "missing"
    fi
}

ios_require_macos
ios_select_simulator
ios_boot_selected_simulator
BUNDLE_ID="$(ios_resolve_bundle_id)"
export BUNDLE_ID

log "iOS expanded QA environment check"
log "Evidence: $EVIDENCE_DIR"
log "Simulator: ${SIMULATOR_NAME:-unknown} ($IOS_SIMULATOR_UDID)"
log "Bundle ID: $BUNDLE_ID"

fact "evidence_dir" "$EVIDENCE_DIR"
fact "started_utc" "$(ios_utc_now)"
fact "repo_root" "$OSRS_REPO_ROOT"
fact "ios_project" "$OSRS_XCODE_PROJECT"
fact "bundle_id" "$BUNDLE_ID"
fact "ios_simulator_udid" "$IOS_SIMULATOR_UDID"
fact "simulator_name" "${SIMULATOR_NAME:-$(ios_simulator_name "$IOS_SIMULATOR_UDID")}"
fact "simulator_state" "$(ios_simulator_state "$IOS_SIMULATOR_UDID")"

ios_run_capture "$EVIDENCE_DIR/xcode-version.txt" xcodebuild -version || true
ios_run_capture "$EVIDENCE_DIR/xcode-sdks.txt" xcodebuild -showsdks || true
ios_run_capture "$EVIDENCE_DIR/simulators-available.txt" xcrun simctl list devices available || true
ios_run_capture "$EVIDENCE_DIR/project-list.txt" xcodebuild -project "$OSRS_XCODE_PROJECT" -list || true
ios_run_capture "$EVIDENCE_DIR/build-settings.txt" xcodebuild -project "$OSRS_XCODE_PROJECT" -scheme "$OSRS_XCODE_SCHEME" -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -showBuildSettings || true
ios_run_capture "$EVIDENCE_DIR/swift-files-ios-tests.txt" find "$OSRS_IOS_DIR/osrswikiTests" "$OSRS_IOS_DIR/osrswikiUITests" -maxdepth 1 -name '*.swift' -print || true

APP_CONTAINER=""
if APP_CONTAINER="$(xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" app 2>/dev/null)"; then
    fact "app_installed" "true"
    fact "app_container" "$APP_CONTAINER"
    ios_run_capture "$EVIDENCE_DIR/codesign-verify-installed-app.txt" codesign --verify --deep --strict "$APP_CONTAINER" || true
else
    fact "app_installed" "false"
    fact "app_container" "unavailable"
fi

ios_run_capture "$EVIDENCE_DIR/app-container-data.txt" xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" data || true
ios_run_capture "$EVIDENCE_DIR/app-info-plist.txt" plutil -p "$OSRS_IOS_DIR/osrswiki/Info.plist" || true
ios_run_capture "$EVIDENCE_DIR/xattrs-project.txt" xattr -lr "$OSRS_IOS_DIR/osrswiki.xcodeproj" "$OSRS_IOS_DIR/osrswiki" || true
ios_run_capture "$EVIDENCE_DIR/recent-app-log.txt" xcrun simctl spawn "$IOS_SIMULATOR_UDID" log show --last 5m --style compact --predicate 'process == "osrswiki"' || true

if [[ -s "$EVIDENCE_DIR/xattrs-project.txt" ]]; then
    fact "xattr_findings" "present"
else
    fact "xattr_findings" "none"
fi

record_helper "scripts/ios/XCTest-GUIDE.md"
record_helper "scripts/ios/quick-test.sh"
record_helper "scripts/ios/take-screenshot.sh"
record_helper "scripts/ios/automate-app-testing.sh"
record_helper "scripts/ios/qa-build-install.sh"
record_helper "scripts/ios/app-tab-smoke.sh"
record_helper "scripts/ios/full-rc-test.sh"
record_helper "scripts/ios/validate-state.sh"
record_helper "scripts/ios/wait-for-element.sh"

if [[ "$CAPTURE_SCREENSHOT" == true ]]; then
    if xcrun simctl io "$IOS_SIMULATOR_UDID" screenshot "$EVIDENCE_DIR/environment-screenshot.png" >/dev/null 2>&1; then
        fact "screenshot_capture" "true"
    else
        fact "screenshot_capture" "false"
    fi
else
    fact "screenshot_capture" "skipped"
fi

if xcodebuild -project "$OSRS_XCODE_PROJECT" -scheme "$OSRS_XCODE_SCHEME" -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" -showBuildSettings >/dev/null 2>&1; then
    fact "xcodebuild_destination_ready" "true"
else
    fact "xcodebuild_destination_ready" "false"
fi

if [[ -d "$OSRS_IOS_DIR/osrswikiUITests" ]]; then
    fact "xcuitest_target_sources" "present"
else
    fact "xcuitest_target_sources" "missing"
fi

log "Environment check complete."
log "Facts: $FACTS_FILE"
