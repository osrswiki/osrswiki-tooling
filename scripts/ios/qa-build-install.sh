#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path ios-build-install)}"
DERIVED_DATA_PATH=""
LAUNCH_AFTER=false

usage() {
    cat <<'USAGE'
Usage: scripts/ios/qa-build-install.sh [options]

Builds the iOS app into a controlled DerivedData path and installs it on the
selected simulator.

Options:
  --output-dir DIR       Evidence directory.
  --derived-data-path DIR  Override DerivedData path.
  --launch              Launch the app after install.
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --derived-data-path)
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --launch)
            LAUNCH_AFTER=true
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
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(ios_make_derived_data_path build-install)}"
DERIVED_DATA_PATH="$(osrs_assert_artifact_path "$DERIVED_DATA_PATH")"
SUMMARY="$EVIDENCE_DIR/build-install-summary.properties"
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
fact "derived_data_path" "$DERIVED_DATA_PATH"
fact "ios_simulator_udid" "$IOS_SIMULATOR_UDID"
fact "bundle_id" "$BUNDLE_ID"

mkdir -p "$DERIVED_DATA_PATH"

if ios_run_capture "$EVIDENCE_DIR/xcodebuild-build.log" \
    xcodebuild \
        -project "$OSRS_XCODE_PROJECT" \
        -scheme "$OSRS_XCODE_SCHEME" \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        build; then
    fact "build" "pass"
else
    fact "build" "fail"
    echo "Build failed. Evidence: $EVIDENCE_DIR" >&2
    exit 1
fi

APP_PATH="$(ios_app_path_from_derived_data "$DERIVED_DATA_PATH")"
fact "app_path" "$APP_PATH"

if [[ ! -d "$APP_PATH" ]]; then
    fact "app_path_exists" "false"
    echo "Built app not found at $APP_PATH" >&2
    exit 1
fi
fact "app_path_exists" "true"

if ios_run_capture "$EVIDENCE_DIR/simctl-install.log" xcrun simctl install "$IOS_SIMULATOR_UDID" "$APP_PATH"; then
    fact "install" "pass"
else
    fact "install" "fail"
    echo "Install failed. Evidence: $EVIDENCE_DIR" >&2
    exit 1
fi

if [[ "$LAUNCH_AFTER" == true ]]; then
    xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if ios_run_capture "$EVIDENCE_DIR/simctl-launch.log" xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" -disableBackgroundPreloading -screenshotMode; then
        fact "launch" "pass"
    else
        fact "launch" "fail"
        echo "Launch failed. Evidence: $EVIDENCE_DIR" >&2
        exit 1
    fi
else
    fact "launch" "skipped"
fi

fact "finished_utc" "$(ios_utc_now)"
echo "iOS build/install complete. Evidence: $EVIDENCE_DIR"
