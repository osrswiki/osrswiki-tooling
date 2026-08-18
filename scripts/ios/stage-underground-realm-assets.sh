#!/bin/bash

set -euo pipefail

# Xcode script phases sanitize PATH to BSD rsync, which rejects --chmod.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

asset_root="${OSRS_UNDERGROUND_ASSETS_DIR:-}"
expected_manifest_sha="${OSRS_EXPECTED_UNDERGROUND_MANIFEST_SHA256:-}"
require_assets="${OSRS_REQUIRE_UNDERGROUND_ASSETS:-0}"

if [[ -z "$asset_root" ]]; then
    default_cache_root="${OSRS_CACHE_ROOT:-$HOME/Developer/osrswiki-local-artifacts/cache}"
    default_asset_root="$default_cache_root/binary-assets/underground-realms"
    if [[ -f "$default_asset_root/underground-realms.json" && -d "$default_asset_root/assets" ]]; then
        asset_root="$default_asset_root"
    fi
fi

if [[ -z "$asset_root" ]]; then
    if [[ "$require_assets" == "1" ]]; then
        echo "error: OSRS_UNDERGROUND_ASSETS_DIR is required for this build" >&2
        exit 1
    fi
    echo "warning: underground realm assets were not supplied; the Map tab will show an asset error"
    exit 0
fi

manifest="$asset_root/underground-realms.json"
assets="$asset_root/assets"
if [[ ! -f "$manifest" || ! -d "$assets" ]]; then
    echo "error: expected underground-realms.json and assets/ below $asset_root" >&2
    exit 1
fi

actual_manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
if [[ -n "$expected_manifest_sha" && "$actual_manifest_sha" != "$expected_manifest_sha" ]]; then
    echo "error: underground manifest SHA-256 mismatch" >&2
    echo "error: expected $expected_manifest_sha" >&2
    echo "error: actual   $actual_manifest_sha" >&2
    exit 1
fi

destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/UndergroundRealms"
mkdir -p "$destination"
rsync -a --delete --chmod=D755,F644 "$assets/" "$destination/assets/"
install -m 0644 "$manifest" "$destination/underground-realms.json"

staged_manifest_sha="$(shasum -a 256 "$destination/underground-realms.json" | awk '{print $1}')"
if [[ "$staged_manifest_sha" != "$actual_manifest_sha" ]]; then
    echo "error: staged underground manifest did not preserve its SHA-256" >&2
    exit 1
fi

echo "Staged reviewed underground realms: manifest=$staged_manifest_sha destination=$destination"
