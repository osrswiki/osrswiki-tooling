#!/bin/bash

# Shared resolver for OSRS Wiki machine-local worktrees and heavyweight
# artifacts. This file is sourced by other scripts, so it intentionally does
# not change the caller's shell options.

osrs_storage_config_path() {
    printf '%s\n' "${OSRS_LOCAL_STORAGE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/osrswiki/storage.env}"
}

osrs_load_local_storage_config() {
    if [[ "${OSRS_LOCAL_STORAGE_CONFIG_LOADED:-}" == "1" ]]; then
        return 0
    fi

    local config_path
    config_path="$(osrs_storage_config_path)"
    if [[ -f "$config_path" ]]; then
        # shellcheck source=/dev/null
        source "$config_path"
    fi

    OSRS_LOCAL_ARTIFACT_ROOT="${OSRS_LOCAL_ARTIFACT_ROOT:-$HOME/Developer/osrswiki-local-artifacts}"
    OSRS_DEPLOY_ROOT="${OSRS_DEPLOY_ROOT:-$HOME/Developer/fleet-sync/deploy}"
    if [[ -z "${OSRS_ARTIFACT_HOST_ID:-}" ]]; then
        OSRS_ARTIFACT_HOST_ID="$(hostname -s 2>/dev/null || hostname)"
        OSRS_ARTIFACT_HOST_ID="$(printf '%s' "$OSRS_ARTIFACT_HOST_ID" | tr -cs 'A-Za-z0-9._-' '-')"
        OSRS_ARTIFACT_HOST_ID="${OSRS_ARTIFACT_HOST_ID%-}"
        OSRS_ARTIFACT_HOST_ID="${OSRS_ARTIFACT_HOST_ID:-unknown-host}"
    fi

    OSRS_LOCAL_STORAGE_CONFIG_LOADED=1
    export OSRS_LOCAL_ARTIFACT_ROOT OSRS_DEPLOY_ROOT OSRS_ARTIFACT_HOST_ID OSRS_LOCAL_STORAGE_CONFIG_LOADED
}

osrs_path_is_within() {
    local path="$1"
    local parent="$2"
    [[ "$path" == "$parent" || "$path" == "$parent/"* ]]
}

osrs_reject_known_cloud_path() {
    local path="$1"
    local candidate

    for candidate in \
        "$HOME/Documents" \
        "$HOME/Desktop" \
        "$HOME/Library/Mobile Documents" \
        "$HOME/Library/CloudStorage"; do
        if osrs_path_is_within "$path" "$candidate"; then
            echo "ERROR: Local artifact root resolves inside a cloud-managed location: $path" >&2
            return 1
        fi
    done
}

osrs_nearest_existing_ancestor() {
    local path="$1"
    while [[ ! -e "$path" ]]; do
        if [[ "$path" == "/" ]]; then
            return 1
        fi
        path="$(dirname "$path")"
    done
    printf '%s\n' "$path"
}

osrs_ancestor_has_file_provider_attribute() {
    local path="$1"
    local attributes

    while [[ "$path" != "/" ]]; do
        attributes="$(xattr "$path" 2>/dev/null || true)"
        if printf '%s\n' "$attributes" | grep -Eq '^com\.apple\.(file-provider-domain-id|fileprovider)'; then
            echo "ERROR: File Provider metadata found on $path" >&2
            return 0
        fi
        path="$(dirname "$path")"
    done
    return 1
}

osrs_validate_root_candidate() {
    local root="$1"
    local ancestor ancestor_real suffix candidate_real

    if [[ "$root" != /* ]]; then
        echo "ERROR: OSRS_LOCAL_ARTIFACT_ROOT must be absolute: $root" >&2
        return 1
    fi
    if [[ "/$root/" == *"/../"* || "/$root/" == *"/./"* ]]; then
        echo "ERROR: OSRS_LOCAL_ARTIFACT_ROOT must not contain dot path components: $root" >&2
        return 1
    fi

    osrs_reject_known_cloud_path "$root" || return 1
    ancestor="$(osrs_nearest_existing_ancestor "$root")" || return 1
    ancestor_real="$(cd "$ancestor" && pwd -P)" || return 1
    suffix="${root#$ancestor}"
    candidate_real="$ancestor_real$suffix"
    osrs_reject_known_cloud_path "$candidate_real" || return 1

    if osrs_ancestor_has_file_provider_attribute "$ancestor_real"; then
        return 1
    fi
}

osrs_canonical_candidate_path() {
    local path="$1"
    local ancestor ancestor_real suffix

    if [[ "$path" != /* ]]; then
        echo "ERROR: Artifact path must be absolute: $path" >&2
        return 1
    fi
    if [[ "/$path/" == *"/../"* || "/$path/" == *"/./"* ]]; then
        echo "ERROR: Artifact path must not contain dot path components: $path" >&2
        return 1
    fi

    if [[ -e "$path" ]]; then
        realpath "$path"
        return
    fi

    ancestor="$(osrs_nearest_existing_ancestor "$path")" || return 1
    if [[ ! -d "$ancestor" ]]; then
        echo "ERROR: Artifact path descends from a non-directory: $ancestor" >&2
        return 1
    fi
    ancestor_real="$(cd "$ancestor" && pwd -P)" || return 1
    suffix="${path#$ancestor}"
    printf '%s\n' "$ancestor_real$suffix"
}

osrs_assert_local_artifact_root() {
    osrs_load_local_storage_config
    osrs_validate_root_candidate "$OSRS_LOCAL_ARTIFACT_ROOT" || return 1

    if [[ ! -d "$OSRS_LOCAL_ARTIFACT_ROOT" ]]; then
        echo "ERROR: Local artifact root does not exist: $OSRS_LOCAL_ARTIFACT_ROOT" >&2
        echo "Run: scripts/shared/local-artifact-root.sh init" >&2
        return 1
    fi

    local resolved
    resolved="$(cd "$OSRS_LOCAL_ARTIFACT_ROOT" && pwd -P)" || return 1
    osrs_reject_known_cloud_path "$resolved" || return 1
    if osrs_ancestor_has_file_provider_attribute "$resolved"; then
        return 1
    fi
    printf '%s\n' "$resolved"
}

osrs_init_local_artifact_root() {
    osrs_load_local_storage_config
    osrs_validate_root_candidate "$OSRS_LOCAL_ARTIFACT_ROOT" || return 1

    (
        umask 077
        mkdir -p \
            "$OSRS_LOCAL_ARTIFACT_ROOT/sessions/active" \
            "$OSRS_LOCAL_ARTIFACT_ROOT/artifacts/active" \
            "$OSRS_LOCAL_ARTIFACT_ROOT/artifacts/completed" \
            "$OSRS_LOCAL_ARTIFACT_ROOT/artifacts/superseded" \
            "$OSRS_LOCAL_ARTIFACT_ROOT/artifacts/reproducible" \
            "$OSRS_LOCAL_ARTIFACT_ROOT/cache" \
            "$OSRS_LOCAL_ARTIFACT_ROOT/manifests"
    )
    chmod 700 "$OSRS_LOCAL_ARTIFACT_ROOT"
    osrs_assert_local_artifact_root
}

osrs_assert_local_deployment_root() {
    osrs_load_local_storage_config
    osrs_validate_root_candidate "$OSRS_DEPLOY_ROOT" || return 1

    if [[ ! -d "$OSRS_DEPLOY_ROOT" ]]; then
        echo "ERROR: Local deployment root does not exist: $OSRS_DEPLOY_ROOT" >&2
        echo "Run: scripts/shared/local-artifact-root.sh init-deploy-root" >&2
        return 1
    fi

    local resolved
    resolved="$(cd "$OSRS_DEPLOY_ROOT" && pwd -P)" || return 1
    osrs_reject_known_cloud_path "$resolved" || return 1
    if osrs_ancestor_has_file_provider_attribute "$resolved"; then
        return 1
    fi
    printf '%s\n' "$resolved"
}

osrs_init_local_deployment_root() {
    osrs_load_local_storage_config
    osrs_validate_root_candidate "$OSRS_DEPLOY_ROOT" || return 1

    (
        umask 077
        mkdir -p "$OSRS_DEPLOY_ROOT"
    )
    chmod 700 "$OSRS_DEPLOY_ROOT"
    osrs_assert_local_deployment_root
}

osrs_local_sessions_dir() {
    local root
    root="$(osrs_init_local_artifact_root)" || return 1
    printf '%s\n' "$root/sessions/active"
}

osrs_local_cache_dir() {
    local root
    root="$(osrs_init_local_artifact_root)" || return 1
    printf '%s\n' "$root/cache"
}

osrs_validate_artifact_state() {
    case "$1" in
        active|completed|superseded|reproducible)
            return 0
            ;;
        *)
            echo "ERROR: Artifact state must be active, completed, superseded, or reproducible: $1" >&2
            return 1
            ;;
    esac
}

osrs_validate_relative_component() {
    local value="$1"
    local label="$2"
    if [[ -z "$value" || "$value" == /* || "/$value/" == *"/../"* || "/$value/" == *"/./"* ]]; then
        echo "ERROR: Invalid $label: $value" >&2
        return 1
    fi
}

osrs_artifact_path() {
    local state="$1"
    local lane_id="$2"
    local relative_path="${3:-}"
    local root

    osrs_validate_artifact_state "$state" || return 1
    osrs_validate_relative_component "$lane_id" "lane id" || return 1
    if [[ -n "$relative_path" ]]; then
        osrs_validate_relative_component "$relative_path" "artifact subpath" || return 1
    fi

    root="$(osrs_assert_local_artifact_root)" || return 1
    if [[ -n "$relative_path" ]]; then
        printf '%s\n' "$root/artifacts/$state/$lane_id/$relative_path"
    else
        printf '%s\n' "$root/artifacts/$state/$lane_id"
    fi
}

osrs_prepare_artifact_dir() {
    local path root relative component current candidate resolved
    path="$(osrs_artifact_path "$@")" || return 1
    root="$(osrs_assert_local_artifact_root)" || return 1
    relative="${path#"$root/"}"
    current="$root"

    # mkdir -p follows existing symlinks. Validate each component physically
    # before creating the next one so an untrusted/pre-existing symlink cannot
    # redirect artifact output outside the verified local root.
    while IFS= read -r component; do
        [[ -n "$component" ]] || continue
        candidate="$current/$component"
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            if [[ ! -d "$candidate" ]]; then
                echo "ERROR: Artifact path component is not a directory: $candidate" >&2
                return 1
            fi
        else
            mkdir "$candidate" || return 1
        fi

        resolved="$(cd "$candidate" && pwd -P)" || return 1
        if ! osrs_path_is_within "$resolved" "$root"; then
            echo "ERROR: Artifact path escapes the verified local root: $candidate" >&2
            return 1
        fi
        current="$resolved"
    done < <(printf '%s\n' "$relative" | tr '/' '\n')

    printf '%s\n' "$current"
}

osrs_assert_artifact_path() {
    local path="$1"
    local root resolved

    root="$(osrs_assert_local_artifact_root)" || return 1
    resolved="$(osrs_canonical_candidate_path "$path")" || return 1
    if ! osrs_path_is_within "$resolved" "$root"; then
        echo "ERROR: Artifact path is outside the configured local root: $resolved" >&2
        return 1
    fi
    printf '%s\n' "$resolved"
}

osrs_current_lane_id() {
    if [[ -n "${OSRS_LANE_ID:-}" ]]; then
        osrs_validate_relative_component "$OSRS_LANE_ID" "lane id" || return 1
        printf '%s\n' "$OSRS_LANE_ID"
        return 0
    fi

    local repo_root lane_id
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
    lane_id="$(basename "$repo_root" | tr -cs 'A-Za-z0-9._-' '-')"
    lane_id="${lane_id%-}"
    printf '%s\n' "${lane_id:-manual}"
}

osrs_session_artifact_dir() {
    local category="$1"
    local lane_id
    lane_id="$(osrs_current_lane_id)" || return 1
    osrs_prepare_artifact_dir active "$lane_id" "$category"
}

osrs_new_run_artifact_path() {
    local category="$1"
    local lane_id run_id
    lane_id="$(osrs_current_lane_id)" || return 1
    run_id="${OSRS_ARTIFACT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
    osrs_artifact_path active "$lane_id" "runs/$run_id-$category"
}

osrs_new_run_artifact_dir() {
    local category="$1"
    local lane_id run_id
    lane_id="$(osrs_current_lane_id)" || return 1
    run_id="${OSRS_ARTIFACT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
    osrs_prepare_artifact_dir active "$lane_id" "runs/$run_id-$category"
}

osrs_artifact_reference() {
    local path="$1"
    local root relative

    osrs_load_local_storage_config
    root="$(osrs_assert_local_artifact_root)" || return 1
    path="$(osrs_assert_artifact_path "$path")" || return 1
    relative="${path#$root/}"
    printf 'osrs-artifact://%s/%s\n' "$OSRS_ARTIFACT_HOST_ID" "$relative"
}

osrs_local_storage_status() {
    local root available_kib
    osrs_load_local_storage_config
    root="$(osrs_assert_local_artifact_root)" || return 1
    available_kib="$(df -Pk "$root" | awk 'NR == 2 { print $4 }')"
    printf 'root=%s\n' "$root"
    printf 'host_id=%s\n' "$OSRS_ARTIFACT_HOST_ID"
    printf 'file_provider=outside\n'
    printf 'available_kib=%s\n' "$available_kib"
}

osrs_local_artifact_usage() {
    cat <<'USAGE'
Usage: scripts/shared/local-artifact-root.sh COMMAND [ARGUMENTS]

Commands:
  init                         Verify and initialize the local layout.
  check                        Verify that the configured root is outside File Provider.
  root                         Print the verified root.
  init-deploy-root             Verify and initialize the local deployment root.
  deploy-root                  Print the verified local deployment root.
  sessions                     Print the active session-worktree directory.
  cache                        Print the reproducible cache directory.
  path STATE LANE [SUBPATH]    Print a local artifact path without creating it.
  prepare STATE LANE [SUBPATH] Create and print a local artifact directory.
  validate-path PATH           Verify that a path is beneath the local root.
  reference PATH               Print a portable osrs-artifact:// reference.
  status                       Print root identity and advisory free-space data.
USAGE
}

osrs_local_artifact_main() {
    case "${1:-}" in
        init)
            osrs_init_local_artifact_root
            ;;
        check|root)
            osrs_assert_local_artifact_root
            ;;
        init-deploy-root)
            osrs_init_local_deployment_root
            ;;
        deploy-root)
            osrs_assert_local_deployment_root
            ;;
        sessions)
            osrs_local_sessions_dir
            ;;
        cache)
            osrs_local_cache_dir
            ;;
        path)
            [[ $# -ge 3 ]] || { osrs_local_artifact_usage >&2; return 2; }
            osrs_artifact_path "$2" "$3" "${4:-}"
            ;;
        prepare)
            [[ $# -ge 3 ]] || { osrs_local_artifact_usage >&2; return 2; }
            osrs_prepare_artifact_dir "$2" "$3" "${4:-}"
            ;;
        validate-path)
            [[ $# -eq 2 ]] || { osrs_local_artifact_usage >&2; return 2; }
            osrs_assert_artifact_path "$2"
            ;;
        reference)
            [[ $# -eq 2 ]] || { osrs_local_artifact_usage >&2; return 2; }
            osrs_artifact_reference "$2"
            ;;
        status)
            osrs_local_storage_status
            ;;
        -h|--help|help)
            osrs_local_artifact_usage
            ;;
        *)
            osrs_local_artifact_usage >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    osrs_local_artifact_main "$@"
fi
