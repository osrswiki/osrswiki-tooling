#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path ios-full-rc)}"
SKIP_UI_SMOKE=false
SKIP_SERVICE_SMOKES=false
ALLOW_MISSING_SIMULATOR=false

usage() {
    cat <<'USAGE'
Usage: scripts/ios/full-rc-test.sh [options]

Runs the iOS release-candidate test gate and writes logs/evidence to one
directory.

Options:
  --allow-missing-simulator  Record simulator-backed gates as skipped.
  --skip-ui-smoke            Skip the stable XCUITest and simctl tab smoke.
  --skip-service-smokes      Skip speech and donation service readiness smokes.
  -h, --help                 Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-missing-simulator)
            ALLOW_MISSING_SIMULATOR=true
            shift
            ;;
        --skip-ui-smoke)
            SKIP_UI_SMOKE=true
            shift
            ;;
        --skip-service-smokes)
            SKIP_SERVICE_SMOKES=true
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
DERIVED_DATA_ROOT="${OSRS_IOS_QA_DERIVED_DATA_ROOT:-$(ios_make_derived_data_path full-rc)}"
DERIVED_DATA_ROOT="$(osrs_assert_artifact_path "$DERIVED_DATA_ROOT")"
mkdir -p "$DERIVED_DATA_ROOT"
SUMMARY="$EVIDENCE_DIR/summary.md"
: > "$SUMMARY"

log_summary() {
    printf '%s\n' "$*" | tee -a "$SUMMARY"
}

record_skip() {
    local name="$1"
    local reason="$2"
    printf '%s\n' "$reason" > "$EVIDENCE_DIR/SKIPPED-$name.txt"
    log_summary "- SKIP $name: $reason"
}

run_step() {
    local name="$1"
    shift
    local log_file="$EVIDENCE_DIR/$name.log"
    local command_string

    command_string="$(ios_command_string "$@")"
    command_string="${command_string% }"
    log_summary "- RUN $name: \`$command_string\`"

    if "$@" > "$log_file" 2>&1; then
        log_summary "  PASS $name"
        return 0
    fi

    log_summary "  FAIL $name. See \`$log_file\`."
    return 1
}

run_xcodebuild_test() {
    local name="$1"
    local only_testing="$2"
    local derived_data="$DERIVED_DATA_ROOT/DerivedData-$name"

    run_step "$name" \
        xcodebuild test \
            -project "$OSRS_XCODE_PROJECT" \
            -scheme "$OSRS_XCODE_SCHEME" \
            -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
            -derivedDataPath "$derived_data" \
            -only-testing:"$only_testing"
}

run_spec_conformance_test() {
    local name="ui-spec-conformance"
    local derived_data="$DERIVED_DATA_ROOT/DerivedData-$name"
    local output_dir="$EVIDENCE_DIR/spec-conformance"
    local log_file="$EVIDENCE_DIR/$name.log"
    local stamp="$output_dir/.started"
    local command_string

    mkdir -p "$output_dir"
    : > "$stamp"

    command_string="$(ios_command_string \
        env \
            OSRS_SPEC_CONFORMANCE_OUTPUT_DIR="$output_dir" \
            OSRS_SCREEN_CONTRACT_PATH="$OSRS_REPO_ROOT/docs/internal/ui-screen-contracts.json" \
        xcodebuild test \
            -project "$OSRS_XCODE_PROJECT" \
            -scheme "$OSRS_XCODE_SCHEME" \
            -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
            -derivedDataPath "$derived_data" \
            -only-testing:osrswikiUITests/SpecConformanceUITests)"
    command_string="${command_string% }"
    log_summary "- RUN $name: \`$command_string\`"

    if env \
        OSRS_SPEC_CONFORMANCE_OUTPUT_DIR="$output_dir" \
        OSRS_SCREEN_CONTRACT_PATH="$OSRS_REPO_ROOT/docs/internal/ui-screen-contracts.json" \
        xcodebuild test \
            -project "$OSRS_XCODE_PROJECT" \
            -scheme "$OSRS_XCODE_SCHEME" \
            -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
            -derivedDataPath "$derived_data" \
            -only-testing:osrswikiUITests/SpecConformanceUITests > "$log_file" 2>&1; then
        copy_spec_conformance_artifacts "$output_dir" "$stamp"
        log_summary "  PASS $name"
        return 0
    fi

    copy_spec_conformance_artifacts "$output_dir" "$stamp"
    log_summary "  FAIL $name. See \`$log_file\`."
    return 1
}

copy_spec_conformance_artifacts() {
    local output_dir="$1"
    local stamp="$2"
    local container_root="$HOME/Library/Developer/CoreSimulator/Devices/$IOS_SIMULATOR_UDID/data/Containers/Data/Application"
    local latest_report
    local latest_dir

    latest_report="$(find "$container_root" \
        -path '*/tmp/osrswiki-ios-spec-conformance-*/spec-conformance-report.json' \
        -newer "$stamp" \
        -exec stat -f '%m %N' {} \; 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"

    if [[ -z "$latest_report" ]]; then
        printf '%s\n' "No simulator spec conformance artifact directory was found." > "$output_dir/ARTIFACT-COPY-WARNING.txt"
        return 0
    fi

    latest_dir="$(dirname "$latest_report")"
    cp -R "$latest_dir"/. "$output_dir"/
}

log_summary "# iOS RC Test Evidence"
log_summary ""
log_summary "- Evidence: \`$EVIDENCE_DIR\`"
log_summary "- DerivedData root: \`$DERIVED_DATA_ROOT\`"
log_summary "- Repo: \`$OSRS_REPO_ROOT\`"
log_summary "- iOS project: \`$OSRS_IOS_DIR\`"
log_summary "- Started: \`$(ios_utc_now)\`"

if ! ios_require_macos; then
    log_summary ""
    log_summary "Result: FAIL. iOS RC testing requires macOS."
    exit 2
fi

if ! ios_select_simulator; then
    if [[ "$ALLOW_MISSING_SIMULATOR" == true ]]; then
        record_skip "simulator-gates" "No available iPhone simulator was found."
        log_summary ""
        log_summary "Result: PARTIAL PASS. Simulator-backed RC gates were skipped."
        exit 0
    fi

    log_summary ""
    log_summary "Result: FAIL. An available iPhone simulator is required."
    exit 2
fi

ios_boot_selected_simulator
BUNDLE_ID="$(ios_resolve_bundle_id)"
export BUNDLE_ID

log_summary "- Simulator: \`${SIMULATOR_NAME:-$(ios_simulator_name "$IOS_SIMULATOR_UDID")} ($IOS_SIMULATOR_UDID)\`"
log_summary "- Bundle ID: \`$BUNDLE_ID\`"
log_summary ""

run_step "git-status" git -C "$OSRS_REPO_ROOT" status --short --branch
run_step "environment-check" "$SCRIPT_DIR/qa-environment-check.sh" --output-dir "$EVIDENCE_DIR/environment"
run_step "build-install" "$SCRIPT_DIR/qa-build-install.sh" --output-dir "$EVIDENCE_DIR/build-install" --derived-data-path "$DERIVED_DATA_ROOT/DerivedData-build-install"

run_xcodebuild_test "unit-local-http-cache" "osrswikiTests/LocalHTTPResponseCacheTests"
run_xcodebuild_test "unit-expanded-deterministic" "osrswikiTests/ExpandedDeterministicStateTests"
run_xcodebuild_test "unit-spec-conformance-fixtures" "osrswikiTests/SpecConformanceFixtureTests"

if [[ "$SKIP_UI_SMOKE" == true ]]; then
    record_skip "ui-smoke" "Skipped by --skip-ui-smoke."
else
    run_xcodebuild_test "ui-expanded-smoke" "osrswikiUITests/ExpandedAppSmokeUITests"
    run_spec_conformance_test
    run_step "simctl-tab-smoke" "$SCRIPT_DIR/app-tab-smoke.sh" --output-dir "$EVIDENCE_DIR/tab-smoke"
fi

if [[ "$SKIP_SERVICE_SMOKES" == true ]]; then
    record_skip "service-smokes" "Skipped by --skip-service-smokes."
else
    run_step "speech-service-smoke" "$SCRIPT_DIR/speech-service-smoke.sh" --output-dir "$EVIDENCE_DIR/speech-smoke"
    run_step "donation-service-smoke" "$SCRIPT_DIR/donation-service-smoke.sh" --output-dir "$EVIDENCE_DIR/donation-smoke"
fi

log_summary ""
log_summary "- Finished: \`$(ios_utc_now)\`"
log_summary "Result: PASS"
echo "iOS RC test gate complete. Evidence: $EVIDENCE_DIR"
