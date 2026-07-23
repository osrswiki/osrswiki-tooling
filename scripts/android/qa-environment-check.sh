#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-expanded-qa)}"
CAPTURE_SCREENSHOT=true
HIDE_IME=true
PACKAGE_OVERRIDE=""

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

usage() {
    cat <<'USAGE'
Usage: scripts/android/qa-environment-check.sh [options]

Records Android QA environment facts and evidence for expanded UI testing.

Options:
  --output-dir DIR  Evidence directory. Must be under the verified local root.
  --package NAME    Package to inspect. Defaults to the app ID from Gradle.
  --keep-ime        Do not hide the keyboard before screenshot/XML evidence.
  --no-screenshot   Do not capture screenshots.
  -h, --help        Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --package)
            PACKAGE_OVERRIDE="$2"
            shift 2
            ;;
        --keep-ime)
            HIDE_IME=false
            shift
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

EVIDENCE_DIR="$(osrs_assert_artifact_path "$EVIDENCE_DIR")"
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

adb_shell() {
    adb -s "$ANDROID_SERIAL" shell "$@" 2>/dev/null | tr -d '\r'
}

command_exists() {
    local relative_path="$1"
    if [[ -x "$REPO_ROOT/$relative_path" || -f "$REPO_ROOT/$relative_path" ]]; then
        fact "helper.${relative_path//\//_}" "present"
    else
        fact "helper.${relative_path//\//_}" "missing"
    fi
}

extract_focus() {
    if [[ -f "$EVIDENCE_DIR/window-focus.txt" ]]; then
        grep -E 'mCurrentFocus|mFocusedApp|mFocusedWindow' "$EVIDENCE_DIR/window-focus.txt" |
            head -10 > "$EVIDENCE_DIR/focused-window-summary.txt" || true
    fi
}

extract_rotation() {
    if [[ -f "$EVIDENCE_DIR/display.txt" ]]; then
        grep -E 'mCurrentOrientation|rotation|orientation' "$EVIDENCE_DIR/display.txt" |
            head -20 > "$EVIDENCE_DIR/current-rotation.txt" || true
    fi
}

record_package_fact() {
    local package_name="$1"
    local fact_name="$2"
    if adb -s "$ANDROID_SERIAL" shell pm path "$package_name" >/dev/null 2>&1; then
        fact "$fact_name" "true"
    else
        fact "$fact_name" "false"
    fi
}

dump_ui_xml() {
    local remote="/sdcard/osrs-env-check-ui.xml"
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 &&
        adb -s "$ANDROID_SERIAL" pull "$remote" "$EVIDENCE_DIR/ui.xml" >/dev/null 2>&1 &&
        xmllint --noout "$EVIDENCE_DIR/ui.xml" >/dev/null 2>&1; then
        fact "ui_dump_parseable" "true"
    else
        fact "ui_dump_parseable" "false"
    fi
}

record_speech_facts() {
    run_capture "speech-recognition-services" \
        adb -s "$ANDROID_SERIAL" shell cmd package query-services -a android.speech.RecognitionService
    run_capture "recognize-speech-activities" \
        adb -s "$ANDROID_SERIAL" shell cmd package query-activities -a android.speech.action.RECOGNIZE_SPEECH

    if [[ -s "$EVIDENCE_DIR/speech-recognition-services.txt" ]] &&
        ! grep -E 'No services found|0 services' "$EVIDENCE_DIR/speech-recognition-services.txt" >/dev/null 2>&1; then
        fact "speech_recognition_service_available" "true"
    else
        fact "speech_recognition_service_available" "false"
    fi
}

record_git_state() {
    run_capture "git-status" git -C "$REPO_ROOT" status --short --branch
    run_capture "git-head" git -C "$REPO_ROOT" rev-parse HEAD
    run_capture "git-branch" git -C "$REPO_ROOT" branch --show-current
}

record_default_browser() {
    run_capture "default-browser-resolver" adb -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief \
        -a android.intent.action.VIEW \
        -c android.intent.category.BROWSABLE \
        -d https://oldschool.runescape.wiki/
    local resolved
    resolved="$(tail -n1 "$EVIDENCE_DIR/default-browser-resolver.txt" | tr -d '\r' || true)"
    fact "default_browser_resolver" "${resolved:-unavailable}"
}

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    log "ANDROID_SERIAL is not set"
    log "Evidence: $EVIDENCE_DIR"
    exit 2
fi

log "Android expanded QA environment check"
log "Evidence: $EVIDENCE_DIR"
log "Device: $ANDROID_SERIAL"

fact "evidence_dir" "$EVIDENCE_DIR"
fact "android_serial" "$ANDROID_SERIAL"
fact "started_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
record_git_state

run_capture "adb-devices" adb devices -l
if adb -s "$ANDROID_SERIAL" get-state >/dev/null 2>&1; then
    fact "adb_state" "$(adb -s "$ANDROID_SERIAL" get-state | tr -d '\r')"
else
    fact "adb_state" "unavailable"
    log "Device $ANDROID_SERIAL is unavailable"
    exit 2
fi

run_capture "getprop" adb -s "$ANDROID_SERIAL" shell getprop
fact "boot_completed" "$(adb_shell getprop sys.boot_completed || true)"
fact "dev_bootcomplete" "$(adb_shell getprop dev.bootcomplete || true)"
fact "api_level" "$(adb_shell getprop ro.build.version.sdk || true)"
fact "android_release" "$(adb_shell getprop ro.build.version.release || true)"
fact "image_abi" "$(adb_shell getprop ro.product.cpu.abi || true)"
fact "device_model" "$(adb_shell getprop ro.product.model || true)"
fact "build_fingerprint" "$(adb_shell getprop ro.build.fingerprint || true)"

if adb -s "$ANDROID_SERIAL" shell pm list packages >/dev/null 2>&1; then
    fact "package_manager_ready" "true"
else
    fact "package_manager_ready" "false"
fi

run_capture "display" adb -s "$ANDROID_SERIAL" shell dumpsys display
run_capture "window-focus" adb -s "$ANDROID_SERIAL" shell dumpsys window displays
run_capture "wm-size" adb -s "$ANDROID_SERIAL" shell wm size
run_capture "wm-density" adb -s "$ANDROID_SERIAL" shell wm density
run_capture "input-method" adb -s "$ANDROID_SERIAL" shell settings get secure default_input_method
run_capture "input-method-state-before" adb -s "$ANDROID_SERIAL" shell dumpsys input_method
run_capture "animation-scales" adb -s "$ANDROID_SERIAL" shell settings list global
run_capture "rotation-help" adb -s "$ANDROID_SERIAL" shell cmd window help
extract_focus
extract_rotation

fact "screen_size" "$(tail -n1 "$EVIDENCE_DIR/wm-size.txt" | tr -d '\r' || true)"
fact "screen_density" "$(tail -n1 "$EVIDENCE_DIR/wm-density.txt" | tr -d '\r' || true)"
fact "input_method" "$(tail -n1 "$EVIDENCE_DIR/input-method.txt" | tr -d '\r' || true)"
fact "current_rotation_summary_file" "current-rotation.txt"
fact "focused_window_summary_file" "focused-window-summary.txt"
fact "window_animation_scale" "$(adb_shell settings get global window_animation_scale || true)"
fact "transition_animation_scale" "$(adb_shell settings get global transition_animation_scale || true)"
fact "animator_duration_scale" "$(adb_shell settings get global animator_duration_scale || true)"

run_capture "packages-browser" adb -s "$ANDROID_SERIAL" shell sh -c \
    "pm list packages | grep -E 'chrome|browser|webview|vending|googlequicksearchbox'"
run_capture "current-webview-package" adb -s "$ANDROID_SERIAL" shell cmd webviewupdate get-current-webview-package
record_package_fact "com.android.chrome" "chrome_installed"
record_package_fact "com.android.vending" "play_store_installed"
record_package_fact "com.google.android.gms" "google_play_services_installed"
record_default_browser
record_speech_facts

command_exists "scripts/android/ui-click.sh"
command_exists "scripts/android/ui-wait.sh"
command_exists "scripts/android/rotation-lock.sh"
command_exists "scripts/android/take-screenshot.sh"
command_exists "scripts/android/quick-test.sh"

if [[ -n "$PACKAGE_OVERRIDE" ]]; then
    APPID="$PACKAGE_OVERRIDE"
else
    APPID="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"
fi
if [[ -n "$APPID" ]]; then
    fact "app_id" "$APPID"
    if adb -s "$ANDROID_SERIAL" shell pm path "$APPID" >/dev/null 2>&1; then
        fact "app_installed" "true"
        run_capture "app-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID"
        run_capture "app-gfxinfo" adb -s "$ANDROID_SERIAL" shell dumpsys gfxinfo "$APPID"
        run_capture "app-gfxinfo-framestats" adb -s "$ANDROID_SERIAL" shell dumpsys gfxinfo "$APPID" framestats
        fact "app_gfxinfo" "app-gfxinfo.txt"
        fact "app_gfxinfo_framestats" "app-gfxinfo-framestats.txt"
        APP_PID="$(adb_shell pidof "$APPID" || true)"
        fact "app_pid" "${APP_PID:-not_running}"
        if [[ "$APP_PID" =~ ^[0-9]+$ ]]; then
            run_capture "app-logcat-tail" adb -s "$ANDROID_SERIAL" logcat -d -t 300 --pid="$APP_PID"
        else
            run_capture "app-logcat-tail" adb -s "$ANDROID_SERIAL" logcat -d -t 300
        fi
    else
        fact "app_installed" "false"
        run_capture "app-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID"
    fi
else
    fact "app_id" "unavailable"
    fact "app_installed" "unknown"
fi

if [[ "$HIDE_IME" == true ]] &&
    grep -E 'mInputShown=true|mShowRequested=true' "$EVIDENCE_DIR/input-method-state-before.txt" >/dev/null 2>&1; then
    adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
    sleep 1
    fact "ime_hidden_before_evidence" "true"
else
    fact "ime_hidden_before_evidence" "false"
fi
run_capture "input-method-state-after" adb -s "$ANDROID_SERIAL" shell dumpsys input_method

dump_ui_xml
run_capture "logcat-tail" adb -s "$ANDROID_SERIAL" logcat -d -t 300
if [[ "$CAPTURE_SCREENSHOT" == true ]]; then
    adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$EVIDENCE_DIR/environment-screenshot.png" 2>/dev/null || true
    fact "environment_screenshot" "environment-screenshot.png"
else
    fact "environment_screenshot" "skipped"
fi

fact "finished_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Environment check complete"
