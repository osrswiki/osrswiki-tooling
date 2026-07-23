#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-billing-smoke)}"

TIMEOUT=25
SKIP_INSTALL=false

usage() {
    cat <<'USAGE'
Usage: scripts/android/billing-service-smoke.sh [options]

Launches the Donate screen and records Play Billing setup evidence without
starting a purchase. This gate passes when products are queryable or when it
records a clear Play setup prerequisite failure.

Options:
  --timeout SEC     Maximum wait time for billing logs or UI state. Default 25.
  --output-dir DIR  Evidence directory.
  --skip-install    Do not install the debug app before launching.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --skip-install)
            SKIP_INSTALL=true
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
LOG_FILE="$EVIDENCE_DIR/billing-service-smoke.log"
: > "$LOG_FILE"

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

run_capture() {
    local name="$1"
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@" 2>&1
    } > "$EVIDENCE_DIR/$name.txt" || true
}

tap_bounds() {
    local bounds="$1"
    local left top right bottom center_x center_y
    left="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\1/')"
    top="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\2/')"
    right="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\3/')"
    bottom="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\4/')"

    if [[ -z "$left" || -z "$top" || -z "$right" || -z "$bottom" ]]; then
        return 1
    fi

    center_x=$(( (left + right) / 2 ))
    center_y=$(( (top + bottom) / 2 ))
    adb -s "$ANDROID_SERIAL" shell input tap "$center_x" "$center_y" >/dev/null
}

dismiss_system_error_dialogs() {
    local attempt remote xml_file bounds
    for attempt in $(seq 1 3); do
        remote="/sdcard/osrs-billing-dismiss-error.xml"
        xml_file="$EVIDENCE_DIR/dismiss-system-error-$attempt.xml"
        if ! adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 ||
           ! adb -s "$ANDROID_SERIAL" pull "$remote" "$xml_file" >/dev/null 2>&1 ||
           ! xmllint --noout "$xml_file" >/dev/null 2>&1; then
            break
        fi

        bounds="$(xmllint --xpath "string(//*[@resource-id='android:id/aerr_close'][1]/@bounds)" "$xml_file" 2>/dev/null || true)"
        if [[ -n "$bounds" ]] && tap_bounds "$bounds"; then
            log "Dismissed stale system error dialog: $bounds"
            sleep 1
        else
            break
        fi
    done
}

require_device() {
    if [[ -z "${ANDROID_SERIAL:-}" ]]; then
        log "ANDROID_SERIAL is not set"
        exit 2
    fi
    if ! adb -s "$ANDROID_SERIAL" get-state >/dev/null 2>&1; then
        log "Device $ANDROID_SERIAL is unavailable"
        exit 2
    fi
}

package_exists() {
    local package_name="$1"
    adb -s "$ANDROID_SERIAL" shell pm path "$package_name" >/dev/null 2>&1
}

capture_billing_environment() {
    run_capture "adb-devices" adb devices -l
    run_capture "packages-play" adb -s "$ANDROID_SERIAL" shell sh -c "pm list packages | grep -E 'vending|gms|googlequicksearchbox|chrome'"
    run_capture "billing-service-query" adb -s "$ANDROID_SERIAL" shell cmd package query-services -a com.android.vending.billing.InAppBillingService.BIND
    run_capture "play-store-package" adb -s "$ANDROID_SERIAL" shell dumpsys package com.android.vending
    run_capture "gms-package" adb -s "$ANDROID_SERIAL" shell dumpsys package com.google.android.gms

    local google_account_count="0"
    google_account_count="$(adb -s "$ANDROID_SERIAL" shell dumpsys account 2>/dev/null |
        tr -d '\r' |
        grep -c 'type=com.google' || true)"
    printf 'google_account_type_count=%s\n' "$google_account_count" > "$EVIDENCE_DIR/google-account-count.txt"
}

resolve_app_targets() {
    APPID="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"
    if [[ -z "$APPID" ]]; then
        log "Could not resolve Android application id"
        exit 2
    fi

    MAIN_ACTIVITY="$(adb -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief \
        -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER \
        -p "$APPID" 2>/dev/null | tail -n1 | tr -d '\r' || true)"
    if [[ -z "$MAIN_ACTIVITY" || "$MAIN_ACTIVITY" != "$APPID"* ]]; then
        log "Could not resolve Android launcher activity for $APPID"
        exit 2
    fi
}

dump_ui() {
    local name="$1"
    local remote="/sdcard/osrs-billing-smoke.xml"
    local local_file="$EVIDENCE_DIR/$name.xml"
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 &&
       adb -s "$ANDROID_SERIAL" pull "$remote" "$local_file" >/dev/null 2>&1 &&
       xmllint --noout "$local_file" >/dev/null 2>&1; then
        printf '%s\n' "$local_file"
        return 0
    fi
    return 1
}

wait_for_text() {
    local text="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    local xml_file

    while (( SECONDS <= deadline )); do
        xml_file="$(dump_ui "wait-${text//[^[:alnum:]]/-}")" || true
        if [[ -n "${xml_file:-}" ]] && grep -F "text=\"$text\"" "$xml_file" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

launch_donate_screen() {
    dismiss_system_error_dialogs
    adb -s "$ANDROID_SERIAL" shell am force-stop "$APPID" >/dev/null 2>&1 || true
    adb -s "$ANDROID_SERIAL" logcat -c
    adb -s "$ANDROID_SERIAL" shell am start -W -n "$MAIN_ACTIVITY" > "$EVIDENCE_DIR/main-start.txt" 2>&1
    sleep 1

    "$SCRIPT_DIR/ui-click.sh" --text "More" > "$EVIDENCE_DIR/click-more.log" 2>&1
    sleep 1
    "$SCRIPT_DIR/ui-click.sh" --text "Donate" > "$EVIDENCE_DIR/click-donate.log" 2>&1

    if ! wait_for_text "Support OSRS Wiki App" 10; then
        log "Could not open Donate screen"
        capture_final_evidence
        exit 1
    fi
}

capture_final_evidence() {
    local raw_logcat="$EVIDENCE_DIR/logcat-raw.txt"
    run_capture "window-focus" adb -s "$ANDROID_SERIAL" shell dumpsys window displays
    run_capture "activity-top" adb -s "$ANDROID_SERIAL" shell dumpsys activity top
    run_capture "app-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID"
    adb -s "$ANDROID_SERIAL" logcat -d > "$raw_logcat" 2>&1 || true
    sed -E 's/\[[A-Za-z0-9_=-]{8,}\]/[redacted]/g' "$raw_logcat" |
        grep -v 'Billing preferred account via installer' > "$EVIDENCE_DIR/logcat.txt" 2>/dev/null || true
    rm -f "$raw_logcat"
    grep -E 'DonateFragment|BillingClient|Play Billing|In-app billing|Product' \
        "$EVIDENCE_DIR/logcat.txt" > "$EVIDENCE_DIR/billing-logcat.txt" 2>/dev/null || true
    dump_ui "billing-final-ui" >/dev/null || true
    adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$EVIDENCE_DIR/billing-final.png" || true
}

product_count_from_logs() {
    if [[ ! -f "$EVIDENCE_DIR/billing-logcat.txt" ]]; then
        return 1
    fi
    grep -E 'DonateFragment: Found [0-9]+ available products' "$EVIDENCE_DIR/billing-logcat.txt" |
        tail -n1 |
        sed -E 's/.*Found ([0-9]+) available products.*/\1/' || true
}

donate_button_enabled() {
    local ui_file="$EVIDENCE_DIR/billing-final-ui.xml"
    [[ -f "$ui_file" ]] || return 1
    xmllint --xpath "string(//*[@resource-id='${APPID}:id/donate_button'][1]/@enabled)" "$ui_file" 2>/dev/null
}

diagnose_result() {
    local product_count
    local enabled_state
    product_count="$(product_count_from_logs)"
    product_count="${product_count//$'\r'/}"
    enabled_state="$(donate_button_enabled || true)"

    if grep -E 'CalledFromWrongThreadException|Accessibility content change on non-UI thread' \
        "$EVIDENCE_DIR/logcat.txt" >/dev/null 2>&1; then
        log "Result: FAIL"
        log "Reason: Billing callback touched Donate UI from a non-UI thread."
        return 1
    fi

    if [[ "$product_count" =~ ^[1-9][0-9]*$ ]]; then
        log "Result: PRODUCT_QUERY_OK"
        log "Queried products: $product_count"
        log "Donate button enabled before purchase launch: ${enabled_state:-unknown}"
        return 0
    fi

    if [[ "$product_count" == "0" ]]; then
        log "Result: DIAGNOSED_SETUP_FAILURE"
        log "Reason: Play Billing returned zero configured donation products for this install/account."
        return 0
    fi

    if grep -F 'Unable to connect to billing service' "$EVIDENCE_DIR/billing-final-ui.xml" >/dev/null 2>&1 ||
       grep -F 'Billing setup failed' "$EVIDENCE_DIR/billing-logcat.txt" >/dev/null 2>&1; then
        log "Result: DIAGNOSED_SETUP_FAILURE"
        log "Reason: DonateFragment reported Billing setup failure."
        return 0
    fi

    if ! package_exists "com.android.vending"; then
        log "Result: DIAGNOSED_SETUP_FAILURE"
        log "Reason: Play Store package com.android.vending is not installed."
        return 0
    fi

    if [[ ! -s "$EVIDENCE_DIR/billing-service-query.txt" ]] ||
       grep -F 'No services found' "$EVIDENCE_DIR/billing-service-query.txt" >/dev/null 2>&1; then
        log "Result: DIAGNOSED_SETUP_FAILURE"
        log "Reason: Play Billing service could not be resolved on this device."
        return 0
    fi

    log "Result: FAIL"
    log "Reason: Donate screen opened, but no product query or diagnosable setup failure was observed."
    return 1
}

require_device

log "Android Play Billing service smoke"
log "Evidence: $EVIDENCE_DIR"
log "Device: $ANDROID_SERIAL"
log "Timeout: ${TIMEOUT}s"

capture_billing_environment

if [[ "$SKIP_INSTALL" != true ]]; then
    "$SCRIPT_DIR/qa-build-install.sh" > "$EVIDENCE_DIR/qa-build-install.log" 2>&1
else
    log "Skipping app install by request"
fi

resolve_app_targets
run_capture "app-installer" adb -s "$ANDROID_SERIAL" shell pm list packages -i "$APPID"

launch_donate_screen

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS <= deadline )); do
    capture_final_evidence
    if product_count_from_logs | grep -Eq '^[0-9]+$'; then
        break
    fi
    if grep -F 'Unable to connect to billing service' "$EVIDENCE_DIR/billing-final-ui.xml" >/dev/null 2>&1 ||
       grep -F 'Billing setup failed' "$EVIDENCE_DIR/billing-logcat.txt" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

capture_final_evidence
diagnose_result
