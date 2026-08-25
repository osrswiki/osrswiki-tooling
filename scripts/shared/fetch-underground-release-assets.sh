#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage:
  fetch-underground-release-assets.sh validate-manifest <manifest.json>
  fetch-underground-release-assets.sh verify <manifest.json> <asset-directory>
  fetch-underground-release-assets.sh materialize <manifest.json> <asset-directory>
  fetch-underground-release-assets.sh release-tag <manifest.json>

materialize uses OSRS_UNDERGROUND_ASSET_SOURCE_DIR when set; otherwise it
downloads the immutable assets from the GitHub release named by the manifest.
GitHub asset names are flat; the destination restores the nested Gradle layout
(underground-realms.json plus **/*.mbtiles).
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

file_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "ERROR: shasum or sha256sum is required" >&2
        exit 2
    fi
}

github_name_from_path() {
    local path="$1"
    printf '%s\n' "${path//\//__}"
}

validate_manifest() {
    local manifest="$1"
    [[ -f "$manifest" ]] || {
        echo "ERROR: underground asset manifest not found: $manifest" >&2
        return 1
    }
    require_command jq

    jq -e '
        .schema_version == 1
        and (.asset_set_id | type == "string" and test("^osrs-underground-realms-[0-9a-f]{12}$"))
        and (.repository == "osrswiki/osrswiki-tooling")
        and (.release_tag | type == "string" and test("^underground-assets-v1-[0-9a-f]{12}$"))
        and (
            (.asset_set_id | sub("^osrs-underground-realms-"; ""))
            == (.release_tag | sub("^underground-assets-v1-"; ""))
        )
        and (.assets | type == "array" and length >= 2)
        and (any(.assets[]; .path == "underground-realms.json"))
        and (([.assets[].path] | unique | length) == (.assets | length))
        and (([.assets[].name] | unique | length) == (.assets | length))
        and (.release_tag as $tag |
            all(.assets[];
                (.path | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$"))
                and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
                and (.name == (.path | gsub("/"; "__")))
                and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
                and (.bytes | type == "number" and . > 0 and floor == .)
                and (.url | type == "string")
                and (.url == (
                    "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                    + $tag + "/" + .name
                ))
            )
        )
        and (all(.assets[] | select(.path != "underground-realms.json");
            (.path | endswith(".mbtiles"))
        ))
        and (.provenance.artifact_class == "immutable-reproducible-release")
        and (.provenance.generated_intermediates == "host-local-only")
    ' "$manifest" >/dev/null
}

verify_assets() {
    local manifest="$1"
    local asset_dir="$2"
    local path expected_sha expected_bytes asset_file actual_sha actual_bytes

    validate_manifest "$manifest"
    [[ -d "$asset_dir" ]] || {
        echo "ERROR: underground asset directory not found: $asset_dir" >&2
        return 1
    }

    while IFS=$'\t' read -r path expected_sha expected_bytes; do
        asset_file="$asset_dir/$path"
        if [[ ! -f "$asset_file" || -L "$asset_file" ]]; then
            echo "ERROR: required regular underground asset is missing: $asset_file" >&2
            return 1
        fi
        actual_bytes="$(file_size "$asset_file")"
        actual_sha="$(file_sha256 "$asset_file")"
        if [[ "$actual_bytes" != "$expected_bytes" ]]; then
            echo "ERROR: underground asset size mismatch for $path: expected $expected_bytes, got $actual_bytes" >&2
            return 1
        fi
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            echo "ERROR: underground asset checksum mismatch for $path" >&2
            return 1
        fi
    done < <(jq -r '.assets[] | [.path, .sha256, (.bytes | tostring)] | @tsv' "$manifest")
}

copy_verified_assets() {
    local manifest="$1"
    local source_dir="$2"
    local destination_dir="$3"
    local path parent temporary_file

    verify_assets "$manifest" "$source_dir"
    mkdir -p "$destination_dir"
    while IFS= read -r path; do
        parent="$(dirname "$path")"
        mkdir -p "$destination_dir/$parent"
        temporary_file="$destination_dir/${path}.fleet-sync-tmp.$$"
        mkdir -p "$(dirname "$temporary_file")"
        cp "$source_dir/$path" "$temporary_file"
        chmod 0644 "$temporary_file"
        mv -f "$temporary_file" "$destination_dir/$path"
    done < <(jq -r '.assets[].path' "$manifest")
    verify_assets "$manifest" "$destination_dir"
}

download_assets() {
    local manifest="$1"
    local destination_dir="$2"
    local path name download_url parent

    require_command curl
    mkdir -p "$destination_dir"

    while IFS=$'\t' read -r path name download_url; do
        if [[ "$(github_name_from_path "$path")" != "$name" ]]; then
            echo "ERROR: underground asset name does not match flattened path: $path" >&2
            return 1
        fi
        parent="$(dirname "$path")"
        mkdir -p "$destination_dir/$parent"
        curl --fail --location --retry 3 --retry-all-errors \
            --output "$destination_dir/$path" "$download_url"
    done < <(jq -r '.assets[] | [.path, .name, .url] | @tsv' "$manifest")
    verify_assets "$manifest" "$destination_dir"
}

materialize_assets() {
    local manifest="$1"
    local destination_dir="$2"
    local temporary_dir

    validate_manifest "$manifest"
    if [[ -n "${OSRS_UNDERGROUND_ASSET_SOURCE_DIR:-}" ]]; then
        copy_verified_assets "$manifest" "$OSRS_UNDERGROUND_ASSET_SOURCE_DIR" "$destination_dir"
        return
    fi

    temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/osrs-underground-release.XXXXXX")"
    download_assets "$manifest" "$temporary_dir"
    copy_verified_assets "$manifest" "$temporary_dir" "$destination_dir"
    rm -rf -- "$temporary_dir"
}

[[ $# -ge 2 ]] || usage
command_name="$1"
manifest_path="$2"

case "$command_name" in
    validate-manifest)
        [[ $# -eq 2 ]] || usage
        validate_manifest "$manifest_path"
        ;;
    verify)
        [[ $# -eq 3 ]] || usage
        verify_assets "$manifest_path" "$3"
        ;;
    materialize)
        [[ $# -eq 3 ]] || usage
        materialize_assets "$manifest_path" "$3"
        ;;
    release-tag)
        [[ $# -eq 2 ]] || usage
        validate_manifest "$manifest_path"
        jq -r '.release_tag' "$manifest_path"
        ;;
    *)
        usage
        ;;
esac
