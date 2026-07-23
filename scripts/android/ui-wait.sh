#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

SEARCH_TYPE=""
SEARCH_VALUE=""
TIMEOUT=15
INTERVAL=1
KEEP_IME=false
OUTPUT_DIR="${QA_EVIDENCE_DIR:-.}"

usage() {
    cat <<'USAGE'
Usage: scripts/android/ui-wait.sh [--text TEXT|--id ID|--desc DESC|--class CLASS] [options]

Options:
  --timeout SEC       Maximum wait time, default 15.
  --interval SEC      Poll interval, default 1.
  --keep-ime          Do not hide the keyboard before dumps.
  --output-dir DIR    Directory for ui-wait.xml and failure screenshots.
  --dump-only         Wait for a parseable stable dump without matching an element.
USAGE
}

DUMP_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --text) SEARCH_TYPE="text"; SEARCH_VALUE="$2"; shift 2 ;;
        --id) SEARCH_TYPE="resource-id"; SEARCH_VALUE="$2"; shift 2 ;;
        --desc) SEARCH_TYPE="content-desc"; SEARCH_VALUE="$2"; shift 2 ;;
        --class) SEARCH_TYPE="class"; SEARCH_VALUE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --keep-ime) KEEP_IME=true; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --dump-only) DUMP_ONLY=true; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "ANDROID_SERIAL not set" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR"

if [[ "$KEEP_IME" == false ]] &&
   adb -s "$ANDROID_SERIAL" shell dumpsys input_method 2>/dev/null |
       grep -E 'mInputShown=true|mShowRequested=true' >/dev/null; then
    adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
    sleep 1
fi

deadline=$((SECONDS + TIMEOUT))
previous_hash=""
attempt=0
while (( SECONDS <= deadline )); do
    attempt=$((attempt + 1))
    remote="/sdcard/osrs-ui-wait.xml"
    local_file="$OUTPUT_DIR/ui-wait.xml"
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 &&
       adb -s "$ANDROID_SERIAL" pull "$remote" "$local_file" >/dev/null 2>&1 &&
       xmllint --noout "$local_file" >/dev/null 2>&1; then
        current_hash="$(shasum -a 256 "$local_file" | awk '{print $1}')"
        if [[ "$DUMP_ONLY" == true ]]; then
            if [[ "$current_hash" == "$previous_hash" && -n "$current_hash" ]]; then
                echo "Stable UI dump after $attempt attempts: $local_file"
                exit 0
            fi
        elif [[ -n "$SEARCH_TYPE" ]]; then
            if xmllint --xpath "//*[@${SEARCH_TYPE}='${SEARCH_VALUE}']" "$local_file" >/dev/null 2>&1; then
                echo "Found $SEARCH_TYPE='$SEARCH_VALUE' after $attempt attempts: $local_file"
                exit 0
            fi
        else
            echo "Parseable UI dump after $attempt attempts: $local_file"
            exit 0
        fi
        previous_hash="$current_hash"
    fi
    sleep "$INTERVAL"
done

adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$OUTPUT_DIR/ui-wait-failure.png" || true
adb -s "$ANDROID_SERIAL" shell dumpsys window displays > "$OUTPUT_DIR/ui-wait-window-focus.txt" 2>&1 || true
echo "Timed out waiting for UI state after $attempt attempts. Evidence: $OUTPUT_DIR" >&2
exit 1
