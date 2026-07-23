#!/bin/bash

if [[ -n "${OSRS_IOS_QA_LIB_SOURCED:-}" ]]; then
    return 0
fi
OSRS_IOS_QA_LIB_SOURCED=1

OSRS_IOS_QA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSRS_REPO_ROOT="$(cd "$OSRS_IOS_QA_SCRIPT_DIR/../.." && pwd)"
OSRS_IOS_DIR="$OSRS_REPO_ROOT/platforms/ios"
OSRS_XCODE_PROJECT="$OSRS_IOS_DIR/osrswiki.xcodeproj"
OSRS_XCODE_SCHEME="${OSRS_XCODE_SCHEME:-osrswiki}"

# shellcheck source=../shared/local-artifact-root.sh
source "$OSRS_REPO_ROOT/scripts/shared/local-artifact-root.sh"
[[ -f "$OSRS_REPO_ROOT/.osrs-artifacts.env" ]] && source "$OSRS_REPO_ROOT/.osrs-artifacts.env"

# shellcheck source=simulator-lifecycle-lib.sh
source "$OSRS_IOS_QA_SCRIPT_DIR/simulator-lifecycle-lib.sh"

ios_utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

ios_require_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "iOS QA requires macOS. Current platform: $(uname)" >&2
        return 2
    fi
}

ios_resolve_bundle_id() {
    if [[ -n "${BUNDLE_ID:-}" ]]; then
        printf '%s\n' "$BUNDLE_ID"
    else
        (cd "$OSRS_REPO_ROOT" && "$OSRS_IOS_QA_SCRIPT_DIR/get-bundle-id.sh")
    fi
}

ios_simulator_state() {
    local udid="$1"
    local line
    line="$(xcrun simctl list devices available | grep -F "$udid" | head -n 1 || true)"

    case "$line" in
        *"(Booted)"*)
            printf '%s\n' "Booted"
            ;;
        *"(Shutdown)"*)
            printf '%s\n' "Shutdown"
            ;;
    esac
}

ios_simulator_name() {
    local udid="$1"
    xcrun simctl list devices available |
        grep -F "$udid" |
        sed 's/^[[:space:]]*//' |
        sed 's/ ([-A-F0-9][A-F0-9-]*).*//' |
        head -n 1
}

ios_select_simulator() {
    ios_load_session_env || true
    local selected="${IOS_SIMULATOR_UDID:-}"

    if [[ -n "$selected" ]]; then
        if ! ios_simulator_exists "$selected"; then
            echo "Configured iOS simulator UDID is not available: $selected" >&2
            return 2
        fi
        IOS_SIMULATOR_UDID="$selected"
        SIMULATOR_NAME="${SIMULATOR_NAME:-$(ios_simulator_name "$selected")}"
        export IOS_SIMULATOR_UDID SIMULATOR_NAME
        ios_lifecycle_heartbeat "$IOS_SIMULATOR_UDID" >/dev/null 2>&1 || true
        return 0
    fi

    if ios_resolve_unique_owned_simulator; then
        ios_lifecycle_heartbeat "$IOS_SIMULATOR_UDID" >/dev/null 2>&1 || true
        return 0
    fi

    echo "No iOS simulator lease or explicit IOS_SIMULATOR_UDID was found." >&2
    echo "Run ./scripts/ios/setup-session-simulator.sh, source .ios-env, or pass an explicit UDID." >&2
    return 2
}

ios_boot_selected_simulator() {
    local state
    state="$(ios_simulator_state "$IOS_SIMULATOR_UDID")"
    if [[ "$state" == "Booted" ]]; then
        return 0
    fi

    xcrun simctl boot "$IOS_SIMULATOR_UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$IOS_SIMULATOR_UDID" -b >/dev/null 2>&1 || sleep 5
}

ios_run_capture() {
    local output_file="$1"
    shift

    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } > "$output_file" 2>&1
}

ios_command_string() {
    printf '%q ' "$@"
}

ios_local_evidence_path() {
    osrs_new_run_artifact_path "$1"
}

ios_validate_evidence_dir() {
    osrs_assert_artifact_path "$1"
}

ios_derived_data_parent() {
    local parent="${OSRS_IOS_QA_DERIVED_DATA_ROOT:-}"
    if [[ -z "$parent" ]]; then
        parent="$(osrs_session_artifact_dir derived-data)"
    fi

    parent="$(osrs_assert_artifact_path "$parent")"
    mkdir -p "$parent"
    printf '%s\n' "$parent"
}

ios_make_derived_data_path() {
    local name="$1"
    local parent

    parent="$(ios_derived_data_parent)"
    mktemp -d "$parent/$name.XXXXXX"
}

ios_app_path_from_derived_data() {
    local derived_data_path="$1"
    printf '%s\n' "$derived_data_path/Build/Products/Debug-iphonesimulator/osrswiki.app"
}
