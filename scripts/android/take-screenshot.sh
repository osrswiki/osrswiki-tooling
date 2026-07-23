#!/bin/bash
set -euo pipefail

# Organized screenshot wrapper for Android development
# Usage: ./scripts/android/take-screenshot.sh [description]
# Example: ./scripts/android/take-screenshot.sh "search-results"

usage() {
    cat <<'USAGE'
Usage: scripts/android/take-screenshot.sh [description]

Captures a PNG screenshot from ANDROID_SERIAL into the verified local artifact
root. Set OSRS_SCREENSHOTS_DIR to override it with another verified local path.

Options:
  -h, --help  Show this help.
USAGE
}

iso_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"

# Auto-source machine-local routing and device environment if available.
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"
[[ -f "$REPO_ROOT/.claude-env" ]] && source "$REPO_ROOT/.claude-env"

# Check for required environment variable
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "❌ ANDROID_SERIAL not set. Please run: source .claude-env" >&2
    exit 1
fi

# Create description parameter with default
DESCRIPTION="${1:-screenshot}"

# Create screenshots directory if it doesn't exist
SCREENSHOTS_DIR="${OSRS_SCREENSHOTS_DIR:-$(osrs_session_artifact_dir screenshots)}"
SCREENSHOTS_DIR="$(osrs_assert_artifact_path "$SCREENSHOTS_DIR")"
mkdir -p "$SCREENSHOTS_DIR"

# Generate timestamp and filename
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FILENAME="${TIMESTAMP}-${DESCRIPTION}.png"
FILEPATH="${SCREENSHOTS_DIR}/${FILENAME}"

# Take screenshot
echo "📸 Taking screenshot on device: $ANDROID_SERIAL"
if adb -s "$ANDROID_SERIAL" shell screencap -p /sdcard/temp_screen.png; then
    if adb -s "$ANDROID_SERIAL" pull /sdcard/temp_screen.png "$FILEPATH"; then
        # Clean up temp file on device
        adb -s "$ANDROID_SERIAL" shell rm /sdcard/temp_screen.png
        
        echo "✅ Screenshot saved: $FILEPATH"
        echo "$FILEPATH"  # Return path for scripting
    else
        echo "❌ Failed to pull screenshot from device" >&2
        exit 1
    fi
else
    echo "❌ Failed to take screenshot on device" >&2
    exit 1
fi

# Optional: Create metadata file for session tracking
METADATA_FILE="${SCREENSHOTS_DIR}/.metadata"
if [[ ! -f "$METADATA_FILE" ]]; then
    echo "# Screenshot session metadata" > "$METADATA_FILE"
    echo "session_start=$(iso_now)" >> "$METADATA_FILE"
    echo "worktree=$(pwd)" >> "$METADATA_FILE"
    echo "device=${ANDROID_SERIAL}" >> "$METADATA_FILE"
fi

# Log screenshot
echo "$(iso_now) $FILENAME $DESCRIPTION" >> "$METADATA_FILE"
