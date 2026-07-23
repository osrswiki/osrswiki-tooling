#!/bin/bash
set -euo pipefail

# Session device cleanup wrapper script
# This script wraps the actual Android device cleanup for consistency with session workflow

echo "🔄 Redirecting to Android device cleanup script..."

# Check if we're in a worktree session directory
if [[ ! -f .claude-session-device ]] && [[ ! -f .claude-env ]]; then
    echo "❌ Error: This doesn't appear to be a session directory"
    echo "Expected to find .claude-session-device or .claude-env file"
    exit 1
fi

# Call the actual Android cleanup script with any passed arguments
exec ../android/cleanup-android-device.sh "$@"