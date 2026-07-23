#!/bin/bash
set -euo pipefail

# iOS Simulator screenshot capture - equivalent to Android take-screenshot.sh
# Usage: ./scripts/ios/take-screenshot.sh [description]
# Example: ./scripts/ios/take-screenshot.sh "search-results"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

# Check for required environment variable
if ! ios_select_simulator; then
    echo "❌ IOS_SIMULATOR_UDID not set. Please run: source .ios-env" >&2
    exit 1
fi

# Ensure we're on macOS (required for iOS development)
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS development requires macOS. Current platform: $(uname)" >&2
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

# Check if simulator is running
SIMULATOR_STATUS=$(xcrun simctl list devices | grep -F "$IOS_SIMULATOR_UDID" | grep -o "Booted\|Shutdown" || echo "Unknown")
if [[ "$SIMULATOR_STATUS" != "Booted" ]]; then
    echo "❌ Simulator not running. Status: $SIMULATOR_STATUS" >&2
    echo "💡 Boot simulator with: xcrun simctl boot $IOS_SIMULATOR_UDID" >&2
    exit 1
fi

# Take screenshot using xcrun simctl
echo "📸 Taking screenshot on iOS Simulator: ${SIMULATOR_NAME:-$IOS_SIMULATOR_UDID}"
if xcrun simctl io "$IOS_SIMULATOR_UDID" screenshot "$FILEPATH"; then
    echo "✅ Screenshot saved: $FILEPATH"
    echo "$FILEPATH"  # Return path for scripting
else
    echo "❌ Failed to take screenshot" >&2
    exit 1
fi

# Optional: Create metadata file for session tracking
METADATA_FILE="${SCREENSHOTS_DIR}/.metadata"
if [[ ! -f "$METADATA_FILE" ]]; then
    echo "# iOS Screenshot session metadata" > "$METADATA_FILE"
    echo "session_start=$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$METADATA_FILE"
    echo "worktree=$(pwd)" >> "$METADATA_FILE"
    echo "simulator=${SIMULATOR_NAME:-$IOS_SIMULATOR_UDID}" >> "$METADATA_FILE"
    echo "device_udid=$IOS_SIMULATOR_UDID" >> "$METADATA_FILE"
fi

# Log screenshot
echo "$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ) $FILENAME $DESCRIPTION" >> "$METADATA_FILE"

# Optional: Open the screenshot for quick viewing (can be disabled for automated scripts)
if [[ "${OPEN_SCREENSHOT:-}" == "true" ]]; then
    open "$FILEPATH"
fi
