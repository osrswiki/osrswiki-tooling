#!/bin/bash
set -euo pipefail

# Session simulator cleanup wrapper script
# This script wraps the actual iOS simulator cleanup for consistency with session workflow

echo "🔄 Redirecting to iOS simulator cleanup script..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check if we're in a worktree session directory. Legacy .claude-* files are
# still accepted so older sessions can be migrated and released safely.
if [[ ! -f "$REPO_ROOT/.simulator-lease.json" ]] &&
   [[ ! -f "$REPO_ROOT/.ios-env" ]] &&
   [[ ! -f "$REPO_ROOT/.claude-session-simulator" ]] &&
   [[ ! -f "$REPO_ROOT/.claude-env" ]]; then
    echo "❌ Error: This doesn't appear to be a session directory"
    echo "Expected to find .simulator-lease.json, .ios-env, or legacy .claude-* metadata"
    exit 1
fi

# Call the actual iOS cleanup script with any passed arguments
exec "$REPO_ROOT/scripts/ios/cleanup-session-simulator.sh" "$@"
