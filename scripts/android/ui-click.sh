#!/bin/bash
# Robust UI automation using UIAutomator dump to find and click elements.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
OUTPUT_DIR="${QA_EVIDENCE_DIR:-$(osrs_new_run_artifact_path android-ui-click)}"
TIMEOUT=15
INTERVAL=1
KEEP_IME=false

if [[ -z "${ANDROID_SERIAL:-}" && -f "$REPO_ROOT/.claude-env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.claude-env"
fi

show_usage() {
    cat <<'USAGE'
Usage: scripts/android/ui-click.sh [OPTIONS]

Options:
  --text TEXT        Find element by text content.
  --id ID            Find element by resource-id.
  --desc DESC        Find element by content description.
  --class CLASS      Find element by class name, optionally with --index.
  --index N          Use Nth element when multiple matches, default 0.
  --timeout SEC      Maximum wait time for stable matching XML, default 15.
  --interval SEC     Poll interval, default 1.
  --keep-ime         Do not hide the keyboard before dumping.
  --output-dir DIR   Evidence directory. Must be under the verified local root.
  --dump-only        Only dump a stable UI hierarchy to ./ui-dump.xml.
  --help             Show this help.
USAGE
}

SEARCH_TYPE=""
SEARCH_VALUE=""
ELEMENT_INDEX=0
DUMP_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --text)
            SEARCH_TYPE="text"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --id)
            SEARCH_TYPE="resource-id"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --desc)
            SEARCH_TYPE="content-desc"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --class)
            SEARCH_TYPE="class"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --index)
            ELEMENT_INDEX="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --keep-ime)
            KEEP_IME=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --dump-only)
            DUMP_ONLY=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "ANDROID_SERIAL not set. Run from a session or export it explicitly." >&2
    exit 2
fi

if ! command -v xmllint >/dev/null 2>&1; then
    echo "xmllint is required for UIAutomator XML parsing." >&2
    exit 2
fi

if [[ ! "$ELEMENT_INDEX" =~ ^[0-9]+$ ]]; then
    echo "--index must be a non-negative integer." >&2
    exit 2
fi

OUTPUT_DIR="$(osrs_assert_artifact_path "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_DIR"
LOG_FILE="$OUTPUT_DIR/ui-click.log"
: > "$LOG_FILE"

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE" >&2
}

run_capture() {
    local name="$1"
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@" 2>&1
    } > "$OUTPUT_DIR/$name.txt" || true
}

xpath_literal() {
    local value="$1"
    if [[ "$value" != *"'"* ]]; then
        printf "'%s'" "$value"
        return
    fi
    if [[ "$value" != *'"'* ]]; then
        printf '"%s"' "$value"
        return
    fi

    local rest="$value"
    local first=true
    printf 'concat('
    while [[ "$rest" == *"'"* ]]; do
        local part="${rest%%\'*}"
        if [[ "$first" == false ]]; then
            printf ','
        fi
        printf "'%s',\"'\"" "$part"
        first=false
        rest="${rest#*\'}"
    done
    if [[ -n "$rest" ]]; then
        printf ",'%s'" "$rest"
    fi
    printf ')'
}

hide_ime_if_needed() {
    if [[ "$KEEP_IME" == true ]]; then
        return
    fi
    run_capture "input-method-before" adb -s "$ANDROID_SERIAL" shell dumpsys input_method
    if grep -E 'mInputShown=true|mShowRequested=true' "$OUTPUT_DIR/input-method-before.txt" >/dev/null 2>&1; then
        log "IME appears visible; hiding it before UI dump."
        adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
        sleep 1
    fi
}

dump_ui_once() {
    local remote="/sdcard/osrs-ui-click.xml"
    local local_file="$OUTPUT_DIR/ui-dump.xml"
    adb -s "$ANDROID_SERIAL" shell uiautomator dump "$remote" >/dev/null 2>&1 &&
        adb -s "$ANDROID_SERIAL" pull "$remote" "$local_file" >/dev/null 2>&1 &&
        xmllint --noout "$local_file" >/dev/null 2>&1
}

current_dump_hash() {
    shasum -a 256 "$OUTPUT_DIR/ui-dump.xml" | awk '{print $1}'
}

matching_bounds() {
    local literal
    literal="$(xpath_literal "$SEARCH_VALUE")"
    xmllint --xpath \
        "string((//*[@${SEARCH_TYPE}=${literal}])[$((ELEMENT_INDEX + 1))]/@bounds)" \
        "$OUTPUT_DIR/ui-dump.xml" 2>/dev/null || true
}

copy_legacy_dump() {
    cp "$OUTPUT_DIR/ui-dump.xml" ./ui-dump.xml
}

capture_evidence() {
    run_capture "window-focus" adb -s "$ANDROID_SERIAL" shell dumpsys window displays
    adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$OUTPUT_DIR/ui-click-screenshot.png" 2>/dev/null || true

    local appid
    appid="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"
    if [[ -n "$appid" ]]; then
        run_capture "app-package" adb -s "$ANDROID_SERIAL" shell dumpsys package "$appid"
    fi
}

print_available_values() {
    log "Available $SEARCH_TYPE values from final dump:"
    xmllint --xpath "//*[@${SEARCH_TYPE}]/@${SEARCH_TYPE}" "$OUTPUT_DIR/ui-dump.xml" 2>/dev/null |
        grep -o "${SEARCH_TYPE}=\"[^\"]*\"" |
        head -20 |
        tee -a "$LOG_FILE" || log "  None found"
}

wait_for_stable_match() {
    local deadline=$((SECONDS + TIMEOUT))
    local previous_hash=""
    local current_hash=""
    local pending_bounds=""
    local attempt=0

    while (( SECONDS <= deadline )); do
        attempt=$((attempt + 1))
        if dump_ui_once; then
            current_hash="$(current_dump_hash)"

            if [[ "$DUMP_ONLY" == true ]]; then
                if [[ -n "$current_hash" && "$current_hash" == "$previous_hash" ]]; then
                    log "Stable UI dump after $attempt attempts: $OUTPUT_DIR/ui-dump.xml"
                    copy_legacy_dump
                    capture_evidence
                    return 0
                fi
            else
                pending_bounds="$(matching_bounds)"
                if [[ -n "$pending_bounds" && "$current_hash" == "$previous_hash" ]]; then
                    log "Found stable $SEARCH_TYPE='$SEARCH_VALUE' at index $ELEMENT_INDEX after $attempt attempts."
                    log "Matching XML: $OUTPUT_DIR/ui-dump.xml"
                    printf '%s\n' "$pending_bounds"
                    capture_evidence
                    return 0
                fi
                if [[ -n "$pending_bounds" ]]; then
                    log "Matched $SEARCH_TYPE='$SEARCH_VALUE' on attempt $attempt; waiting for stable XML."
                fi
            fi
            previous_hash="$current_hash"
        fi
        sleep "$INTERVAL"
    done

    capture_evidence
    return 1
}

parse_and_tap_bounds() {
    local bounds="$1"
    local left top right bottom center_x center_y
    left="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\1/')"
    top="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\2/')"
    right="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\3/')"
    bottom="$(printf '%s' "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\4/')"

    if [[ -z "$left" || -z "$top" || -z "$right" || -z "$bottom" ]]; then
        log "Could not parse bounds: $bounds"
        return 1
    fi

    center_x=$(( (left + right) / 2 ))
    center_y=$(( (top + bottom) / 2 ))
    log "Clicking center of bounds $bounds at ($center_x, $center_y)."
    adb -s "$ANDROID_SERIAL" shell input tap "$center_x" "$center_y"
}

log "Android UI click helper"
log "Evidence: $OUTPUT_DIR"
log "Device: $ANDROID_SERIAL"

hide_ime_if_needed

if [[ "$DUMP_ONLY" == false && -z "$SEARCH_TYPE" ]]; then
    echo "No search criteria specified. Use --text, --id, --desc, or --class." >&2
    show_usage >&2
    exit 1
fi

if bounds="$(wait_for_stable_match)"; then
    if [[ "$DUMP_ONLY" == true ]]; then
        log "UI hierarchy dumped to ./ui-dump.xml"
        exit 0
    fi

    if parse_and_tap_bounds "$bounds"; then
        log "Successfully clicked element."
        exit 0
    fi
fi

if [[ "$DUMP_ONLY" == true ]]; then
    log "Timed out waiting for stable UI dump. Evidence: $OUTPUT_DIR"
else
    log "Timed out waiting for stable $SEARCH_TYPE='$SEARCH_VALUE' at index $ELEMENT_INDEX. Evidence: $OUTPUT_DIR"
    if [[ -f "$OUTPUT_DIR/ui-dump.xml" ]]; then
        print_available_values
    fi
fi
exit 1
