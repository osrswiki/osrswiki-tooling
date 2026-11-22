#!/bin/bash
set -euo pipefail

# Publish a versioned underground-realms GitHub Release from a generated tree.
# Auto-update is the supported caller. Never clobber or delete a tag that an
# existing pin, shipped build, or F-Droid metadata may still download.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch-underground-release-assets.sh"
HELPER="$SCRIPT_DIR/osrs_map_auto_update.py"

usage() {
    cat >&2 <<'EOF'
usage:
  publish-underground-release-assets.sh [--dry-run] [--create-release]
      [--manifest PATH] [--source-dir PATH] [--release-notes PATH]

Verifies the generated underground tree against the fleet manifest and uploads
each file to the osrswiki/osrswiki-tooling GitHub Release named by the
manifest. Nested paths are flattened with / -> __ for GitHub asset names.
GitHub CLI 2.87 treats ``file#text`` as a display label, not a rename, so
uploads are staged under those flattened basenames.

  --dry-run         Verify only; do not call gh / upload
  --create-release  Create the manifest tag if missing. Never clobbers a
                    different existing release.
  --manifest        Default: <repo>/shared/manifests/osrs-underground-assets-v1.json
  --source-dir      Generated underground tree (underground-realms.json + **/*.mbtiles)
  --release-notes   Optional notes file used with --create-release

Do not gh release upload underground assets by hand.
EOF
    exit 2
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command is unavailable: $1" >&2
        exit 2
    fi
}

file_size() {
    if stat -f '%z' "$1" >/dev/null 2>&1; then
        stat -f '%z' "$1"
    else
        stat -c '%s' "$1"
    fi
}

remote_asset_size() {
    local repository="$1"
    local release_tag="$2"
    local asset_name="$3"

    gh release view "$release_tag" --repo "$repository" --json assets \
        | jq -r --arg name "$asset_name" \
            '.assets[] | select(.name == $name) | .size' 2>/dev/null || true
}

dry_run=0
create_release=0
manifest=""
source_dir=""
release_notes=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        --create-release)
            create_release=1
            shift
            ;;
        --manifest)
            [[ $# -ge 2 ]] || usage
            manifest="$2"
            shift 2
            ;;
        --source-dir)
            [[ $# -ge 2 ]] || usage
            source_dir="$2"
            shift 2
            ;;
        --release-notes)
            [[ $# -ge 2 ]] || usage
            release_notes="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [[ ! -x "$FETCH_SCRIPT" ]]; then
    echo "ERROR: underground fetch script is missing or not executable: $FETCH_SCRIPT" >&2
    exit 2
fi
if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: map auto-update helper not found: $HELPER" >&2
    exit 2
fi
require_command jq
require_command python3

if [[ -z "$manifest" || -z "$source_dir" ]]; then
    # shellcheck source=find-git-repo.sh
    source "$SCRIPT_DIR/find-git-repo.sh"
    osrs_load_local_storage_config
    if ! GIT_ROOT="$(find_git_repo "$(pwd)")" || [[ ! -f "$GIT_ROOT/AGENTS.md" ]]; then
        echo "ERROR: must run from an OSRS Wiki Fleet Sync checkout or assigned worktree" >&2
        exit 2
    fi
    manifest="${manifest:-$GIT_ROOT/shared/manifests/osrs-underground-assets-v1.json}"
    if [[ -z "$source_dir" ]]; then
        source_dir="${OSRS_UNDERGROUND_ASSET_SOURCE_DIR:-$(get_cache_dir)/binary-assets/underground-realms}"
    fi
fi

[[ -f "$manifest" ]] || {
    echo "ERROR: underground asset manifest not found: $manifest" >&2
    exit 1
}
[[ -d "$source_dir" ]] || {
    echo "ERROR: underground asset directory not found: $source_dir" >&2
    exit 1
}

"$FETCH_SCRIPT" validate-manifest "$manifest"
"$FETCH_SCRIPT" verify "$manifest" "$source_dir"
echo "Underground tree matches $manifest"

if [[ "$dry_run" -eq 1 ]]; then
    echo "Dry run: skipped GitHub Release upload"
    exit 0
fi

require_command gh
repository="$(jq -r '.repository' "$manifest")"
release_tag="$(jq -r '.release_tag' "$manifest")"
remote_view="$(gh release view "$release_tag" --repo "$repository" --json tagName,assets 2>/dev/null || true)"
if [[ -z "$remote_view" ]]; then
    if [[ "$create_release" -ne 1 ]]; then
        echo "ERROR: tooling release $release_tag is missing; pass --create-release for a new versioned tag" >&2
        exit 1
    fi
    create_args=(release create "$release_tag" --repo "$repository"
        --title "OSRS underground realm assets v1 (${release_tag#underground-assets-v1-})")
    if [[ -n "$release_notes" ]]; then
        create_args+=(--notes-file "$release_notes")
    else
        create_args+=(--notes "Immutable underground realm assets. Do not delete; older pins keep using this tag.")
    fi
    gh "${create_args[@]}"
    echo "Created tooling release $release_tag"
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/osrs-underground-upload.XXXXXX")"
cleanup_staging() {
    rm -rf "$staging"
}
trap cleanup_staging EXIT

upload_list=()
mismatch=0
while IFS=$'\t' read -r path name expected_bytes; do
    local_file="$source_dir/$path"
    actual_bytes="$(file_size "$local_file")"
    if [[ "$actual_bytes" != "$expected_bytes" ]]; then
        echo "ERROR: local $path is $actual_bytes bytes, manifest expects $expected_bytes" >&2
        exit 1
    fi
    remote_size="$(remote_asset_size "$repository" "$release_tag" "$name" | tail -n1 || true)"
    if [[ "$remote_size" == "$expected_bytes" ]]; then
        echo "Remote $name already present on $release_tag with matching size; skipped"
        continue
    fi
    if [[ -n "$remote_size" && "$remote_size" != "$expected_bytes" ]]; then
        echo "ERROR: remote $name size is $remote_size, local is $expected_bytes" >&2
        mismatch=1
        continue
    fi
    staged="$staging/$name"
    if ! ln "$local_file" "$staged" 2>/dev/null; then
        cp "$local_file" "$staged"
    fi
    upload_list+=("$staged")
done < <(jq -r '.assets[] | [.path, .name, (.bytes | tostring)] | @tsv' "$manifest")

if [[ "$mismatch" -ne 0 ]]; then
    echo "Refusing to clobber an existing tooling release. Create a new versioned tag instead." >&2
    exit 1
fi

if [[ ${#upload_list[@]} -eq 0 ]]; then
    echo "All underground assets already present on $release_tag with matching sizes"
    exit 0
fi

# Upload in batches so a later duplicate basename cannot abort the whole set.
batch_size=25
batch_start=0
uploaded=0
while [[ "$batch_start" -lt "${#upload_list[@]}" ]]; do
    batch=("${upload_list[@]:$batch_start:$batch_size}")
    gh release upload "$release_tag" "${batch[@]}" --repo "$repository"
    uploaded=$((uploaded + ${#batch[@]}))
    batch_start=$((batch_start + batch_size))
done
echo "Uploaded $uploaded underground assets to $repository $release_tag"
