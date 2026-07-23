#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-speech-smoke)}"

TIMEOUT=25
SKIP_INSTALL=false

usage() {
    cat <<'USAGE'
Usage: scripts/android/speech-service-smoke.sh [options]

Launches the app, grants microphone permission, taps a real Voice search entry
point, and records whether the target device has a usable recognizer service.
Successful audio transcription is intentionally outside this emulator smoke.

Options:
  --timeout SEC     Maximum wait time for recognizer logs or UI state. Default 25.
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
LOG_FILE="$EVIDENCE_DIR/speech-service-smoke.log"
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
        remote="/sdcard/osrs-speech-dismiss-error.xml"
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

capture_speech_environment() {
    run_capture "adb-devices" adb devices -l
    run_capture "packages-speech" adb -s "$ANDROID_SERIAL" shell sh -c "pm list packages | grep -E 'googlequicksearchbox|gms|speech|tts|latin|inputmethod'"
    run_capture "audio-features" adb -s "$ANDROID_SERIAL" shell sh -c "pm list features | grep -E 'audio|microphone|speech'"
    run_capture "speech-recognition-services" adb -s "$ANDROID_SERIAL" shell cmd package query-services -a android.speech.RecognitionService
    run_capture "recognize-speech-activities" adb -s "$ANDROID_SERIAL" shell cmd package query-activities -a android.speech.action.RECOGNIZE_SPEECH
    run_capture "voice-web-search-activities" adb -s "$ANDROID_SERIAL" shell cmd package query-activities -a android.speech.action.WEB_SEARCH
}

dump_ui() {
    local name="$1"
    local remote="/sdcard/osrs-speech-smoke.xml"
    local local_file="$EVIDENCE_DIR/$name.xml"
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 &&
       adb -s "$ANDROID_SERIAL" pull "$remote" "$local_file" >/dev/null 2>&1 &&
       xmllint --noout "$local_file" >/dev/null 2>&1; then
        printf '%s\n' "$local_file"
        return 0
    fi
    return 1
}

capture_final_evidence() {
    local raw_logcat="$EVIDENCE_DIR/logcat-raw.txt"
    local sanitized_logcat="$EVIDENCE_DIR/logcat-sanitized.tmp"
    run_capture "window-focus" adb -s "$ANDROID_SERIAL" shell dumpsys window displays
    run_capture "activity-top" adb -s "$ANDROID_SERIAL" shell dumpsys activity top
    run_capture "app-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID"
    adb -s "$ANDROID_SERIAL" logcat -d > "$raw_logcat" 2>&1 || true
    sed -E \
        -e "s/(Final result: ')[^']*'/\\1[redacted]'/" \
        -e "s/(Partial result: ')[^']*'/\\1[redacted]'/" \
        -e 's/Recognition results: .*/Recognition results: [redacted]/' \
        "$raw_logcat" > "$sanitized_logcat" 2>/dev/null || true
    grep -E 'SpeechRecognitionManager|SpeechRecognizer|RecognitionService|RecognizerIntent|Voice search|RECORD_AUDIO' \
        "$sanitized_logcat" > "$EVIDENCE_DIR/speech-logcat.txt" 2>/dev/null || true
    cp "$EVIDENCE_DIR/speech-logcat.txt" "$EVIDENCE_DIR/logcat.txt" 2>/dev/null || true
    rm -f "$raw_logcat" "$sanitized_logcat"
    dump_ui "speech-final-ui" >/dev/null || true
    adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$EVIDENCE_DIR/speech-final.png" || true
}

launch_and_start_voice() {
    dismiss_system_error_dialogs
    adb -s "$ANDROID_SERIAL" shell am force-stop "$APPID" >/dev/null 2>&1 || true
    adb -s "$ANDROID_SERIAL" shell pm grant "$APPID" android.permission.RECORD_AUDIO > "$EVIDENCE_DIR/grant-record-audio.txt" 2>&1 || true
    adb -s "$ANDROID_SERIAL" logcat -c
    adb -s "$ANDROID_SERIAL" shell am start -W -n "$MAIN_ACTIVITY" > "$EVIDENCE_DIR/main-start.txt" 2>&1

    "$SCRIPT_DIR/ui-wait.sh" --desc "Voice search" --timeout 15 --output-dir "$EVIDENCE_DIR" \
        > "$EVIDENCE_DIR/wait-voice.log" 2>&1
    "$SCRIPT_DIR/ui-click.sh" --desc "Voice search" > "$EVIDENCE_DIR/click-voice.log" 2>&1
}

has_speech_service() {
    [[ -s "$EVIDENCE_DIR/speech-recognition-services.txt" ]] &&
        ! grep -E 'No services found|0 services' "$EVIDENCE_DIR/speech-recognition-services.txt" >/dev/null 2>&1
}

diagnose_result() {
    local logcat_file="$EVIDENCE_DIR/speech-logcat.txt"

    if grep -F 'Speech recognition not available on this device' "$logcat_file" >/dev/null 2>&1; then
        log "Result: DIAGNOSED_UNAVAILABLE"
        log "Reason: app-level SpeechRecognizer availability returned false."
        return 0
    fi

    if grep -F 'SpeechRecognizer created successfully' "$logcat_file" >/dev/null 2>&1 &&
       grep -F 'State changed to LISTENING' "$logcat_file" >/dev/null 2>&1; then
        log "Result: RECOGNIZER_STARTED"
        log "Reason: real voice entry point created a SpeechRecognizer and reached LISTENING."
        return 0
    fi

    if grep -F 'Fallback intent launched successfully' "$logcat_file" >/dev/null 2>&1; then
        log "Result: FALLBACK_INTENT_STARTED"
        log "Reason: in-process recognizer was unavailable, but RecognizerIntent fallback launched."
        return 0
    fi

    if has_speech_service; then
        log "Result: FAIL"
        log "Reason: package manager reported a speech service, but the app did not start or diagnose voice recognition."
        return 1
    else
        log "Result: DIAGNOSED_UNAVAILABLE"
        log "Reason: package manager did not report a recognition service."
        return 0
    fi
}

require_device

log "Android speech recognizer smoke"
log "Evidence: $EVIDENCE_DIR"
log "Device: $ANDROID_SERIAL"
log "Timeout: ${TIMEOUT}s"

capture_speech_environment

if [[ "$SKIP_INSTALL" != true ]]; then
    "$SCRIPT_DIR/qa-build-install.sh" > "$EVIDENCE_DIR/qa-build-install.log" 2>&1
else
    log "Skipping app install by request"
fi

resolve_app_targets
run_capture "app-installer" adb -s "$ANDROID_SERIAL" shell pm list packages -i "$APPID"

launch_and_start_voice

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS <= deadline )); do
    capture_final_evidence
    if grep -E 'SpeechRecognizer created successfully|Speech recognition not available on this device|Fallback intent launched successfully|SpeechRecognitionManager: ERROR_' \
        "$EVIDENCE_DIR/speech-logcat.txt" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

capture_final_evidence
diagnose_result
