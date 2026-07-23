#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-browser-smoke)}"

URL="https://www.patreon.com/runescapewiki"
BROWSER_PACKAGE="${BROWSER_PACKAGE:-}"
TIMEOUT=20
PREPARE_BROWSER=true

usage() {
    cat <<'USAGE'
Usage: scripts/android/browser-url-smoke.sh [options]

Launches an external URL through the device browser and records evidence that
the prepared browser profile received the URL without blocking on first-run UI.

Options:
  --url URL              URL to launch. Defaults to the OSRS Wiki Patreon URL.
  --browser-package PKG  Browser package to target. Defaults to Chrome when present.
  --timeout SEC          Maximum time for browser focus/URL evidence. Default 20.
  --output-dir DIR       Evidence directory.
  --no-prepare           Do not dismiss common browser first-run prompts.
  -h, --help             Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            URL="$2"
            shift 2
            ;;
        --browser-package)
            BROWSER_PACKAGE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --no-prepare)
            PREPARE_BROWSER=false
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
LOG_FILE="$EVIDENCE_DIR/browser-url-smoke.log"
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

cleanup_browser_state() {
    if [[ -z "${BROWSER_PACKAGE:-}" ]]; then
        return
    fi

    {
        printf '$ adb -s %q shell am force-stop %q\n' "$ANDROID_SERIAL" "$BROWSER_PACKAGE"
        adb -s "$ANDROID_SERIAL" shell am force-stop "$BROWSER_PACKAGE" 2>&1
    } > "$EVIDENCE_DIR/browser-cleanup.txt" || true
}

package_exists() {
    local package_name="$1"
    adb -s "$ANDROID_SERIAL" shell pm path "$package_name" >/dev/null 2>&1
}

choose_browser_package() {
    if [[ -n "$BROWSER_PACKAGE" ]]; then
        return
    fi

    local candidates=(
        "com.android.chrome"
        "com.chrome.beta"
        "org.mozilla.firefox"
        "com.android.browser"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if package_exists "$candidate"; then
            BROWSER_PACKAGE="$candidate"
            return
        fi
    done
}

xml_attr_value() {
    local xml_file="$1"
    local text_value="$2"
    xmllint --xpath "string(//*[@text='${text_value}'][1]/@bounds)" "$xml_file" 2>/dev/null || true
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

dump_ui() {
    local name="$1"
    local remote="/sdcard/osrs-browser-smoke.xml"
    local local_file="$EVIDENCE_DIR/$name.xml"
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 &&
       adb -s "$ANDROID_SERIAL" pull "$remote" "$local_file" >/dev/null 2>&1 &&
       xmllint --noout "$local_file" >/dev/null 2>&1; then
        printf '%s\n' "$local_file"
        return 0
    fi
    return 1
}

tap_text_if_present() {
    local text_value="$1"
    local xml_file bounds
    xml_file="$(dump_ui "browser-first-run-$(echo "$text_value" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')")" || return 1
    bounds="$(xml_attr_value "$xml_file" "$text_value")"
    if [[ -z "$bounds" ]]; then
        return 1
    fi
    log "Dismissing browser prompt: $text_value"
    tap_bounds "$bounds"
}

dismiss_first_run_prompts() {
    local attempt
    local prompt
    local prompts=(
        "Accept & continue"
        "Accept and continue"
        "Use without an account"
        "No thanks"
        "Not now"
        "Got it"
        "Skip"
    )

    for attempt in $(seq 1 8); do
        local dismissed=false
        for prompt in "${prompts[@]}"; do
            if tap_text_if_present "$prompt"; then
                dismissed=true
                sleep 2
                break
            fi
        done
        if [[ "$dismissed" == false ]]; then
            break
        fi
    done
}

launch_url() {
    local command=(adb -s "$ANDROID_SERIAL" shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$URL")
    if [[ -n "$BROWSER_PACKAGE" ]]; then
        command+=(-p "$BROWSER_PACKAGE")
    fi
    run_capture "am-start-url" "${command[@]}"
}

capture_final_evidence() {
    run_capture "window-focus" adb -s "$ANDROID_SERIAL" shell dumpsys window displays
    run_capture "activity-activities" adb -s "$ANDROID_SERIAL" shell dumpsys activity activities
    run_capture "activity-top" adb -s "$ANDROID_SERIAL" shell dumpsys activity top
    run_capture "browser-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$BROWSER_PACKAGE"
    adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$EVIDENCE_DIR/browser-final.png" || true
    dump_ui "browser-final-ui" >/dev/null || true
}

has_browser_focus() {
    grep -F "$BROWSER_PACKAGE" "$EVIDENCE_DIR/window-focus.txt" >/dev/null 2>&1 ||
        grep -F "$BROWSER_PACKAGE" "$EVIDENCE_DIR/activity-top.txt" >/dev/null 2>&1
}

has_url_evidence() {
    grep -F "$URL" "$EVIDENCE_DIR/activity-activities.txt" >/dev/null 2>&1 ||
        grep -F "$URL" "$EVIDENCE_DIR/activity-top.txt" >/dev/null 2>&1 ||
        grep -F "$(printf '%s' "$URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#')" "$EVIDENCE_DIR/browser-final-ui.xml" >/dev/null 2>&1
}

has_blocking_first_run_prompt() {
    if [[ ! -f "$EVIDENCE_DIR/browser-final-ui.xml" ]]; then
        return 1
    fi
    grep -E 'Accept (&amp;|&) continue|Accept and continue|Use without an account|No thanks|Make it yours' \
        "$EVIDENCE_DIR/browser-final-ui.xml" >/dev/null 2>&1
}

require_device

log "Android browser URL smoke"
log "Evidence: $EVIDENCE_DIR"
log "Device: $ANDROID_SERIAL"
log "URL: $URL"

run_capture "adb-devices" adb devices -l
run_capture "packages-browser" adb -s "$ANDROID_SERIAL" shell sh -c "pm list packages | grep -E 'chrome|browser|firefox|webview'"

choose_browser_package
if [[ -z "$BROWSER_PACKAGE" ]]; then
    log "No supported browser package found. See packages-browser.txt."
    exit 3
fi
if ! package_exists "$BROWSER_PACKAGE"; then
    log "Requested browser package is not installed: $BROWSER_PACKAGE"
    exit 3
fi
log "Browser package: $BROWSER_PACKAGE"
trap cleanup_browser_state EXIT

adb -s "$ANDROID_SERIAL" shell am force-stop "$BROWSER_PACKAGE" >/dev/null 2>&1 || true
launch_url
sleep 3

if [[ "$PREPARE_BROWSER" == true ]]; then
    dismiss_first_run_prompts
fi

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS <= deadline )); do
    capture_final_evidence
    if has_browser_focus && has_url_evidence && ! has_blocking_first_run_prompt; then
        log "PASS browser URL smoke"
        log "Browser focus: true"
        log "URL evidence: true"
        log "Blocking first-run prompt: false"
        exit 0
    fi
    sleep 2
done

capture_final_evidence
log "FAIL browser URL smoke"
if has_browser_focus; then
    log "Browser focus: true"
else
    log "Browser focus: false"
fi
if has_url_evidence; then
    log "URL evidence: true"
else
    log "URL evidence: false"
fi
if has_blocking_first_run_prompt; then
    log "Blocking first-run prompt: true"
else
    log "Blocking first-run prompt: false"
fi
exit 1
