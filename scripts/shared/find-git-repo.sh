#!/bin/bash
# Repository Discovery Utility
# Finds the actual git repository location regardless of current working directory
# Works from both main/ and sessions/session-name/ contexts

set -euo pipefail

FIND_GIT_REPO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-artifact-root.sh
source "$FIND_GIT_REPO_SCRIPT_DIR/local-artifact-root.sh"

# Find the workspace boundary. For a Fleet Sync checkout this is the primary
# repository itself. For the frozen legacy layout it is the outer umbrella.
find_monorepo_root() {
    local start_dir="${1:-$(pwd)}"
    local current_dir
    current_dir="$(cd "$start_dir" 2>/dev/null && pwd -P)" || return 1

    # A linked worktree may live outside either layout. Its common Git
    # directory identifies the primary repository without path guessing.
    if (cd "$current_dir" && git rev-parse --git-dir >/dev/null 2>&1); then
        local common_dir common_dir_real common_repo candidate_monorepo
        common_dir="$(cd "$current_dir" && git rev-parse --git-common-dir)"
        common_dir_real="$(cd "$current_dir" && cd "$common_dir" && pwd -P)"
        common_repo="$(dirname "$common_dir_real")"
        candidate_monorepo="$(dirname "$common_repo")"
        if [[ "$(basename "$common_repo")" == "main" && -d "$candidate_monorepo/main/.git" ]]; then
            echo "$candidate_monorepo"
            return 0
        fi
        if [[ -f "$common_repo/AGENTS.md" ]]; then
            echo "$common_repo"
            return 0
        fi
    fi

    local max_depth=10
    local depth=0

    while [[ $depth -lt $max_depth ]]; do
        if [[ -d "$current_dir/cache" ]]; then
            echo "$current_dir"
            return 0
        fi

        local parent_dir
        parent_dir="$(dirname "$current_dir")"

        # Stop if we've reached the root
        if [[ "$parent_dir" == "$current_dir" ]]; then
            break
        fi

        current_dir="$parent_dir"
        ((depth++))
    done

    return 1
}

# Find the primary checkout that owns the common Git directory.
find_primary_repo() {
    local start_dir="${1:-$(pwd)}"
    local current_dir
    current_dir="$(cd "$start_dir" 2>/dev/null && pwd -P)" || return 1

    if (cd "$current_dir" && git rev-parse --git-dir >/dev/null 2>&1); then
        local common_dir common_dir_real
        common_dir="$(cd "$current_dir" && git rev-parse --git-common-dir)"
        common_dir_real="$(cd "$current_dir" && cd "$common_dir" && pwd -P)"
        dirname "$common_dir_real"
        return 0
    fi

    local workspace
    workspace="$(find_monorepo_root "$current_dir")" || return 1
    if [[ -d "$workspace/main/.git" ]]; then
        printf '%s\n' "$workspace/main"
    elif [[ -d "$workspace/.git" ]]; then
        printf '%s\n' "$workspace"
    else
        return 1
    fi
}

# Function to find git repository root
find_git_repo() {
    local search_dir="${1:-$(pwd)}"

    # First, check whether the requested search directory is inside a git repo.
    if (cd "$search_dir" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1); then
        (cd "$search_dir" && git rev-parse --show-toplevel)
        return 0
    fi

    # Try to find monorepo root first, then look for main/
    local monorepo_root
    if monorepo_root=$(find_monorepo_root "$search_dir"); then
        if [[ -d "$monorepo_root/main/.git" ]]; then
            echo "$monorepo_root/main"
            return 0
        fi
    fi

    # Search relative paths from current location
    local search_paths=(
        "$search_dir"
        "$search_dir/main"
        "$search_dir/../main"
        "$search_dir/../../main"
    )

    for path in "${search_paths[@]}"; do
        if [[ -d "$path/.git" ]]; then
            echo "$(cd "$path" && pwd -P)"
            return 0
        fi
    done

    # Do not recursively enumerate an umbrella or cloud-managed tree. Session
    # worktrees resolve through Git's common directory; non-Git callers must use
    # one of the fixed candidates above.
    return 1
}

# Function to find osrswiki parent directory (alias for find_monorepo_root for backward compatibility)
find_osrswiki_parent() {
    find_monorepo_root "${1:-$(pwd)}"
}

# Function to get cache directory path
get_cache_dir() {
    osrs_local_cache_dir
}

# Function to get sessions directory path
get_sessions_dir() {
    osrs_local_sessions_dir
}

# Function to validate repository context
validate_repo_context() {
    local repo_root
    local monorepo_root
    local primary_repo_root

    if ! repo_root=$(find_git_repo); then
        echo "ERROR: Cannot find git repository" >&2
        echo "Searched common locations but no .git directory found" >&2
        return 1
    fi

    if ! monorepo_root=$(find_monorepo_root); then
        echo "ERROR: Cannot find workspace root" >&2
        return 1
    fi

    if ! primary_repo_root=$(find_primary_repo); then
        echo "ERROR: Cannot find primary repository" >&2
        return 1
    fi

    echo "REPO_ROOT=$repo_root"
    echo "PRIMARY_REPO_ROOT=$primary_repo_root"
    echo "MONOREPO_ROOT=$monorepo_root"
    echo "PARENT_DIR=$monorepo_root"
    echo "LOCAL_ARTIFACT_ROOT=$(osrs_assert_local_artifact_root)"
    echo "CACHE_DIR=$(get_cache_dir)"
    echo "SESSIONS_DIR=$(get_sessions_dir)"
    return 0
}

# Main function for command line usage
main() {
    case "${1:-validate}" in
        "repo")
            find_git_repo
            ;;
        "monorepo"|"parent")
            find_monorepo_root
            ;;
        "primary")
            find_primary_repo
            ;;
        "cache")
            get_cache_dir
            ;;
        "sessions")
            get_sessions_dir
            ;;
        "validate")
            validate_repo_context
            ;;
        *)
            echo "Usage: $0 [repo|primary|monorepo|parent|cache|sessions|validate]"
            echo "  repo      - Find git repository root"
            echo "  primary   - Find the checkout that owns the common Git directory"
            echo "  monorepo  - Find the Fleet Sync checkout or legacy umbrella"
            echo "  parent    - Alias for monorepo (backward compatibility)"
            echo "  cache     - Get cache directory path"
            echo "  sessions  - Get sessions directory path"
            echo "  validate  - Validate and show all locations"
            exit 1
            ;;
    esac
}

# Only run main if script is executed directly
if [[ -n "${BASH_SOURCE:-}" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
