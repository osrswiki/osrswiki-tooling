#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-rotation)}"
TIMEOUT=10
RESTORE=false
CAPTURE_SCREENSHOT=true

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

usage() {
    cat <<'USAGE'
Usage: scripts/android/rotation-lock.sh [orientation] [options]

Orientations:
  portrait | 0
  landscape | 1
  reverse-portrait | 2
  reverse-landscape | 3
  unlock

Options:
  --output-dir DIR  Evidence directory. Must be under the verified local root.
  --timeout SEC     Seconds to wait for observed rotation, default 10.
  --restore         Restore the previous rotation setting after verification.
  --no-screenshot   Do not capture screenshots.
  -h, --help        Show this help.
USAGE
}

ORIENTATION="${1:-portrait}"
if [[ $# -gt 0 && "$1" != --* ]]; then
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --restore)
            RESTORE=true
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

case "$ORIENTATION" in
    portrait|0) ROTATION=0 ;;
    landscape|1) ROTATION=1 ;;
    reverse-portrait|2) ROTATION=2 ;;
    reverse-landscape|3) ROTATION=3 ;;
    unlock) ROTATION="" ;;
    *) echo "Unknown orientation: $ORIENTATION" >&2; usage >&2; exit 2 ;;
esac

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "ANDROID_SERIAL not set" >&2
    exit 2
fi

EVIDENCE_DIR="$(osrs_assert_artifact_path "$EVIDENCE_DIR")"
mkdir -p "$EVIDENCE_DIR"
LOG_FILE="$EVIDENCE_DIR/rotation-lock.log"
: > "$LOG_FILE"

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

run_adb() {
    adb -s "$ANDROID_SERIAL" "$@"
}

capture_state() {
    local prefix="$1"
    run_capture "${prefix}-display" adb -s "$ANDROID_SERIAL" shell dumpsys display
    run_capture "${prefix}-window-displays" adb -s "$ANDROID_SERIAL" shell dumpsys window displays
    run_capture "${prefix}-wm-size" adb -s "$ANDROID_SERIAL" shell wm size
    run_capture "${prefix}-settings-accelerometer" adb -s "$ANDROID_SERIAL" shell settings get system accelerometer_rotation
    run_capture "${prefix}-settings-user-rotation" adb -s "$ANDROID_SERIAL" shell settings get system user_rotation
    if [[ "$CAPTURE_SCREENSHOT" == true ]]; then
        adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$EVIDENCE_DIR/${prefix}-screenshot.png" 2>/dev/null || true
    fi
}

observed_rotation_lines() {
    cat "$EVIDENCE_DIR/current-display.txt" "$EVIDENCE_DIR/current-window-displays.txt" 2>/dev/null |
        grep -E 'mCurrentOrientation|mDisplayRotation|mRotation=|rotation=|orientation=' || true
}

observed_rotation_matches() {
    local expected="$1"
    observed_rotation_lines |
        grep -E "ROTATION_${expected}|mCurrentOrientation=${expected}|mCurrentOrientation: ${expected}|rotation=${expected}|orientation=${expected}" \
        >/dev/null 2>&1
}

wait_for_rotation() {
    local expected="$1"
    local deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS <= deadline )); do
        capture_state "current"
        if observed_rotation_matches "$expected"; then
            observed_rotation_lines > "$EVIDENCE_DIR/observed-rotation.txt"
            return 0
        fi
        sleep 1
    done

    observed_rotation_lines > "$EVIDENCE_DIR/observed-rotation.txt"
    return 1
}

record_working_command() {
    printf '%s\n' "$*" >> "$EVIDENCE_DIR/rotation-commands.txt"
    if [[ ! -f "$EVIDENCE_DIR/working-rotation-command.txt" ]]; then
        printf '%s\n' "$*" > "$EVIDENCE_DIR/working-rotation-command.txt"
    else
        printf '%s\n' "$*" > "$EVIDENCE_DIR/last-rotation-command.txt"
    fi
    log "Working command: $*"
}

lock_rotation() {
    local rotation="$1"
    run_capture "fixed-to-user-rotation-enable" adb -s "$ANDROID_SERIAL" shell cmd window fixed-to-user-rotation enabled

    if run_adb shell cmd window user-rotation lock "$rotation" >/dev/null 2>&1; then
        record_working_command "adb -s $ANDROID_SERIAL shell cmd window user-rotation lock $rotation"
        return 0
    fi

    if run_adb shell cmd window set-user-rotation lock "$rotation" >/dev/null 2>&1; then
        record_working_command "adb -s $ANDROID_SERIAL shell cmd window set-user-rotation lock $rotation"
        return 0
    fi

    run_adb shell settings put system accelerometer_rotation 0
    run_adb shell settings put system user_rotation "$rotation"
    record_working_command \
        "adb -s $ANDROID_SERIAL shell settings put system accelerometer_rotation 0; adb -s $ANDROID_SERIAL shell settings put system user_rotation $rotation"
}

unlock_rotation() {
    if run_adb shell cmd window user-rotation free >/dev/null 2>&1; then
        record_working_command "adb -s $ANDROID_SERIAL shell cmd window user-rotation free"
    elif run_adb shell cmd window set-user-rotation free >/dev/null 2>&1; then
        record_working_command "adb -s $ANDROID_SERIAL shell cmd window set-user-rotation free"
    else
        run_adb shell settings put system accelerometer_rotation 1
        record_working_command "adb -s $ANDROID_SERIAL shell settings put system accelerometer_rotation 1"
    fi
    run_capture "fixed-to-user-rotation-default" adb -s "$ANDROID_SERIAL" shell cmd window fixed-to-user-rotation default
}

restore_initial_rotation() {
    local initial_accelerometer
    local initial_user_rotation
    initial_accelerometer="$(tail -n1 "$EVIDENCE_DIR/initial-settings-accelerometer.txt" | tr -d '\r' || true)"
    initial_user_rotation="$(tail -n1 "$EVIDENCE_DIR/initial-settings-user-rotation.txt" | tr -d '\r' || true)"

    if [[ "$initial_accelerometer" == "1" ]]; then
        unlock_rotation
        printf 'unlock\n' > "$EVIDENCE_DIR/restore-command.txt"
    elif [[ "$initial_user_rotation" =~ ^[0-3]$ ]]; then
        lock_rotation "$initial_user_rotation"
        printf 'lock %s\n' "$initial_user_rotation" > "$EVIDENCE_DIR/restore-command.txt"
    else
        unlock_rotation
        printf 'unlock-fallback\n' > "$EVIDENCE_DIR/restore-command.txt"
    fi

    sleep 1
    capture_state "restored"
}

log "Android rotation helper"
log "Evidence: $EVIDENCE_DIR"
log "Device: $ANDROID_SERIAL"
log "Requested orientation: $ORIENTATION"

run_capture "adb-devices" adb devices -l
run_capture "window-help" adb -s "$ANDROID_SERIAL" shell cmd window help
capture_state "initial"

if [[ "$ORIENTATION" == "unlock" ]]; then
    unlock_rotation
    sleep 1
    capture_state "current"
    observed_rotation_lines > "$EVIDENCE_DIR/observed-rotation.txt"
    log "Rotation unlocked. Observed state recorded."
else
    lock_rotation "$ROTATION"
    if wait_for_rotation "$ROTATION"; then
        log "Observed requested rotation $ROTATION."
    else
        log "Timed out waiting for requested rotation $ROTATION. Evidence: $EVIDENCE_DIR"
        exit 1
    fi
fi

if [[ "$RESTORE" == true ]]; then
    restore_initial_rotation
    log "Initial rotation setting restored."
fi

log "Rotation helper complete"
