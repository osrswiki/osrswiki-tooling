#!/bin/bash
set -euo pipefail

# Source the repository discovery utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/find-git-repo.sh"

CURRENT_DIR=$(pwd)
SESSION_NAME=$(basename "$CURRENT_DIR")
DELETE_REQUESTED=false
if [[ "${1:-}" == "--delete" ]]; then
    DELETE_REQUESTED=true
fi

if [[ ! "$SESSION_NAME" =~ ^(claude|codex|job)-[0-9]{8}-[0-9]{6} ]]; then
    echo "⚠️ Not in a recognized session directory; preserving worktree"
    echo "Current directory: $CURRENT_DIR"
    exit 0
fi

if [[ "$DELETE_REQUESTED" != "true" ]]; then
    echo "✅ Worktree preserved: $CURRENT_DIR"
    echo "Deletion requires verified owner release, provenance, separate authorization,"
    echo "OSRS_ARTIFACT_CLEANUP_AUTHORIZED=1, and an explicit --delete invocation."
    exit 0
fi

if [[ "${OSRS_ARTIFACT_CLEANUP_AUTHORIZED:-}" != "1" ]]; then
    echo "ERROR: Worktree deletion is not authorized" >&2
    exit 2
fi

SESSIONS_DIR="$(get_sessions_dir)"
if ! osrs_path_is_within "$(cd "$CURRENT_DIR" && pwd -P)" "$SESSIONS_DIR"; then
    echo "ERROR: Refusing to remove a worktree outside the verified local sessions root" >&2
    exit 2
fi

if [[ -n "$(git -C "$CURRENT_DIR" status --porcelain)" ]]; then
    echo "ERROR: Refusing to remove a dirty worktree: $CURRENT_DIR" >&2
    exit 2
fi

MAIN_REPO="$(find_primary_repo)"
git -C "$MAIN_REPO" worktree remove "$CURRENT_DIR"
echo "✅ Authorized clean worktree removal complete: $SESSION_NAME"
echo "The corresponding artifact directory was preserved for separate disposition."
