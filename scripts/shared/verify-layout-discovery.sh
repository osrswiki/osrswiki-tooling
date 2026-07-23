#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/find-git-repo.sh"

assert_context() {
    local label="$1"
    local context_dir="$2"
    local expected_repo="$3"
    local expected_monorepo="$4"
    local expected_primary="$5"

    if [[ ! -d "$context_dir" ]]; then
        echo "SKIP $label: $context_dir does not exist"
        return 0
    fi

    local output repo_root primary_repo_root monorepo_root parent_dir sessions_dir cache_dir expected_sessions expected_cache
    output="$(cd "$context_dir" && validate_repo_context)"
    repo_root="$(printf '%s\n' "$output" | awk -F= '/^REPO_ROOT=/ {print $2; exit}')"
    primary_repo_root="$(printf '%s\n' "$output" | awk -F= '/^PRIMARY_REPO_ROOT=/ {print $2; exit}')"
    monorepo_root="$(printf '%s\n' "$output" | awk -F= '/^MONOREPO_ROOT=/ {print $2; exit}')"
    parent_dir="$(printf '%s\n' "$output" | awk -F= '/^PARENT_DIR=/ {print $2; exit}')"
    cache_dir="$(printf '%s\n' "$output" | awk -F= '/^CACHE_DIR=/ {print $2; exit}')"
    sessions_dir="$(printf '%s\n' "$output" | awk -F= '/^SESSIONS_DIR=/ {print $2; exit}')"
    expected_sessions="$(get_sessions_dir)"
    expected_cache="$(get_cache_dir)"

    [[ "$repo_root" == "$expected_repo" ]] || {
        echo "FAIL $label: REPO_ROOT was $repo_root, expected $expected_repo" >&2
        return 1
    }
    [[ "$primary_repo_root" == "$expected_primary" ]] || {
        echo "FAIL $label: PRIMARY_REPO_ROOT was $primary_repo_root, expected $expected_primary" >&2
        return 1
    }
    [[ "$monorepo_root" == "$expected_monorepo" ]] || {
        echo "FAIL $label: MONOREPO_ROOT was $monorepo_root, expected $expected_monorepo" >&2
        return 1
    }
    [[ "$parent_dir" == "$expected_monorepo" ]] || {
        echo "FAIL $label: PARENT_DIR was $parent_dir, expected $expected_monorepo" >&2
        return 1
    }
    [[ "$cache_dir" == "$expected_cache" ]] || {
        echo "FAIL $label: CACHE_DIR was $cache_dir, expected $expected_cache" >&2
        return 1
    }
    [[ "$sessions_dir" == "$expected_sessions" ]] || {
        echo "FAIL $label: SESSIONS_DIR was $sessions_dir, expected $expected_sessions" >&2
        return 1
    }

    echo "PASS $label"
}

current_repo="$(git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel)"
current_monorepo="$(find_monorepo_root "$current_repo")"
primary_repo="$(find_primary_repo "$current_repo")"

assert_context "current repository root" "$current_repo" "$current_repo" "$current_monorepo" "$primary_repo"
assert_context "current repository subdirectory" "$SCRIPT_DIR" "$current_repo" "$current_monorepo" "$primary_repo"
if [[ "$current_monorepo" != "$primary_repo" ]]; then
    assert_context "legacy umbrella workspace" "$current_monorepo" "$primary_repo" "$current_monorepo" "$primary_repo"
fi
assert_context "primary source checkout" "$primary_repo" "$primary_repo" "$current_monorepo" "$primary_repo"
