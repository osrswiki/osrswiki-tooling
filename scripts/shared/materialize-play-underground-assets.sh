#!/bin/bash
set -euo pipefail

# Explicit Play/debug materialize of the pinned underground-realms catalog.
# This is the same contract as -PosrsUndergroundAssetsDir: checksummed copy
# of the GitHub release (or a verified host source). It does not make Gradle
# auto-pick ~/Developer/osrswiki-local-artifacts/cache/binary-assets/underground-realms.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=find-git-repo.sh
source "$SCRIPT_DIR/find-git-repo.sh"
osrs_load_local_storage_config

if ! REPO_CONTEXT=$(validate_repo_context); then
    echo "ERROR: repository discovery failed" >&2
    echo "$REPO_CONTEXT" >&2
    exit 1
fi
eval "$REPO_CONTEXT"

ROOT="${REPO_ROOT:-$GIT_ROOT}"
MANIFEST="$ROOT/shared/manifests/osrs-underground-assets-v1.json"
FETCH="$ROOT/scripts/shared/fetch-underground-release-assets.sh"
CACHE_BASE="$(get_cache_dir)"
DESTINATION="${OSRS_PLAY_UNDERGROUND_ASSETS_DIR:-$CACHE_BASE/binary-assets/play-underground-realms-release}"
CACHE_CANDIDATE="$CACHE_BASE/binary-assets/underground-realms"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: pinned underground manifest missing: $MANIFEST" >&2
    exit 1
fi
if [[ ! -x "$FETCH" ]]; then
    echo "ERROR: underground fetch script missing or not executable: $FETCH" >&2
    exit 1
fi

if "$FETCH" verify "$MANIFEST" "$DESTINATION" >/dev/null 2>&1; then
    printf '%s\n' "$DESTINATION"
    exit 0
fi

materialize_env=()
if [[ -n "${OSRS_UNDERGROUND_ASSET_SOURCE_DIR:-}" ]]; then
    materialize_env+=(OSRS_UNDERGROUND_ASSET_SOURCE_DIR="$OSRS_UNDERGROUND_ASSET_SOURCE_DIR")
elif [[ -d "$CACHE_CANDIDATE" ]] && "$FETCH" verify "$MANIFEST" "$CACHE_CANDIDATE" >/dev/null 2>&1; then
    materialize_env+=(OSRS_UNDERGROUND_ASSET_SOURCE_DIR="$CACHE_CANDIDATE")
fi

mkdir -p "$DESTINATION"
if ((${#materialize_env[@]})); then
    env "${materialize_env[@]}" "$FETCH" materialize "$MANIFEST" "$DESTINATION"
else
    "$FETCH" materialize "$MANIFEST" "$DESTINATION"
fi

printf '%s\n' "$DESTINATION"
