#!/bin/bash
set -euo pipefail

# Build, pin, and upload the deterministic map_floors.zip for the surface map
# set. This is the only supported way to create or refresh that GitHub Release
# asset. Do not `gh release upload` the zip by hand.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch-map-release-assets.sh"
BUNDLE_HELPER="$SCRIPT_DIR/osrs_map_release_bundle.py"

usage() {
    cat >&2 <<'EOF'
usage:
  publish-map-release-bundle.sh [--dry-run] [--clobber]
      [--manifest PATH] [--source-dir PATH] [--output PATH]

Builds a deterministic map_floors.zip from the four verified mbtiles, updates
the fleet manifest bundle sha256/bytes, and uploads the zip to the tooling
GitHub Release named by the manifest (osrswiki/osrswiki-tooling).

  --dry-run     Build and pin locally; do not call gh / upload
  --clobber     Rewrite manifest pins and replace a differing remote zip
  --manifest    Default: <repo>/shared/manifests/osrs-map-assets-v1.json
  --source-dir  Default: $OSRS_MAP_ASSET_SOURCE_DIR or the host mbtiles cache
  --output      Optional path for the built zip (otherwise a temp file)

Skip upload when the remote asset size already matches the local digest.
Pass --clobber to replace a present-but-different remote zip.

Do not create or upload map_floors.zip outside this script.
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

ensure_bundle_object() {
    local manifest="$1"
    local tmp

    if jq -e '.bundle.name == "map_floors.zip"
            and (.bundle.members | type == "array")' "$manifest" >/dev/null; then
        return 0
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/osrs-map-bundle-manifest.XXXXXX")"
    jq '
        .bundle = {
            "name": "map_floors.zip",
            "sha256": ("0" * 64),
            "bytes": 1,
            "members": [.assets[].name]
        }
    ' "$manifest" > "$tmp"
    mv -f "$tmp" "$manifest"
}

write_bundle_pins() {
    local manifest="$1"
    local sha="$2"
    local bytes="$3"
    local tmp

    tmp="$(mktemp "${TMPDIR:-/tmp}/osrs-map-bundle-manifest.XXXXXX")"
    jq --arg sha "$sha" --argjson bytes "$bytes" '
        .bundle.name = "map_floors.zip"
        | .bundle.sha256 = $sha
        | .bundle.bytes = $bytes
        | .bundle.members = [.assets[].name]
        | {
            schema_version,
            asset_set_id,
            repository,
            release_tag,
            bundle,
            assets,
            provenance
          }
    ' "$manifest" > "$tmp"
    mv -f "$tmp" "$manifest"
}

remote_bundle_size() {
    local repository="$1"
    local release_tag="$2"
    local bundle_name="$3"

    gh release view "$release_tag" --repo "$repository" --json assets \
        | jq -r --arg name "$bundle_name" \
            '.assets[] | select(.name == $name) | .size' 2>/dev/null || true
}

dry_run=0
clobber=0
manifest=""
source_dir=""
output=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        --clobber)
            clobber=1
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
        --output)
            [[ $# -ge 2 ]] || usage
            output="$2"
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
    echo "ERROR: map fetch script is missing or not executable: $FETCH_SCRIPT" >&2
    exit 2
fi
if [[ ! -f "$BUNDLE_HELPER" ]]; then
    echo "ERROR: map bundle helper not found: $BUNDLE_HELPER" >&2
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
    manifest="${manifest:-$GIT_ROOT/shared/manifests/osrs-map-assets-v1.json}"
    if [[ -z "$source_dir" ]]; then
        source_dir="${OSRS_MAP_ASSET_SOURCE_DIR:-$(get_cache_dir)/binary-assets/mbtiles}"
    fi
fi

[[ -f "$manifest" ]] || {
    echo "ERROR: map asset manifest not found: $manifest" >&2
    exit 1
}
[[ -d "$source_dir" ]] || {
    echo "ERROR: map asset directory not found: $source_dir" >&2
    exit 1
}

ensure_bundle_object "$manifest"

temporary_zip=""
cleanup() {
    if [[ -n "$temporary_zip" ]]; then
        rm -f -- "$temporary_zip"
    fi
}
trap cleanup EXIT

if [[ -n "$output" ]]; then
    zip_file="$output"
else
    temporary_zip="$(mktemp "${TMPDIR:-/tmp}/osrs-map-floors.XXXXXX.zip")"
    zip_file="$temporary_zip"
fi

"$FETCH_SCRIPT" build-bundle "$manifest" "$source_dir" "$zip_file"
digest_line="$(python3 "$BUNDLE_HELPER" digest "$zip_file")"
local_sha="${digest_line%%$'\t'*}"
local_bytes="${digest_line#*$'\t'}"
current_sha="$(jq -r '.bundle.sha256' "$manifest")"
current_bytes="$(jq -r '.bundle.bytes' "$manifest")"

if [[ "$current_sha" == "$local_sha" && "$current_bytes" == "$local_bytes" ]]; then
    echo "Map bundle digest already pinned: $local_sha ($local_bytes bytes)"
    if [[ "$clobber" -eq 1 ]]; then
        write_bundle_pins "$manifest" "$local_sha" "$local_bytes"
    fi
else
    if [[ "$clobber" -ne 1 ]]; then
        echo "ERROR: built map_floors.zip digest differs from the manifest pin" >&2
        echo "  manifest: $current_sha ($current_bytes bytes)" >&2
        echo "  built:    $local_sha ($local_bytes bytes)" >&2
        echo "Re-run with --clobber to update the fleet manifest from this zip." >&2
        exit 1
    fi
    write_bundle_pins "$manifest" "$local_sha" "$local_bytes"
    echo "Updated manifest bundle pin: $local_sha ($local_bytes bytes)"
fi

"$FETCH_SCRIPT" validate-manifest "$manifest"
echo "map_floors.zip sha256=$local_sha"
echo "map_floors.zip bytes=$local_bytes"

if [[ "$dry_run" -eq 1 ]]; then
    echo "Dry run: skipped GitHub Release upload"
    exit 0
fi

require_command gh
repository="$(jq -r '.repository' "$manifest")"
release_tag="$(jq -r '.release_tag' "$manifest")"
bundle_name="$(jq -r '.bundle.name' "$manifest")"
remote_size="$(remote_bundle_size "$repository" "$release_tag" "$bundle_name" | tail -n1 || true)"

if [[ "$remote_size" == "$local_bytes" && "$clobber" -ne 1 ]]; then
    echo "Remote $bundle_name already present on $release_tag with matching size; skipped upload"
    exit 0
fi

if [[ -n "$remote_size" && "$remote_size" != "$local_bytes" && "$clobber" -ne 1 ]]; then
    echo "ERROR: remote $bundle_name size is $remote_size, local built zip is $local_bytes" >&2
    echo "Re-run with --clobber to replace the GitHub Release asset." >&2
    exit 1
fi

upload_args=(release upload "$release_tag" "$zip_file#$bundle_name" --repo "$repository")
if [[ "$clobber" -eq 1 ]]; then
    upload_args+=(--clobber)
fi
gh "${upload_args[@]}"
echo "Uploaded $bundle_name to $repository $release_tag"
