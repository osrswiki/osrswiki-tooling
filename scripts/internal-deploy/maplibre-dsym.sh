#!/bin/bash
# MapLibre dSYM resolution and archive injection helpers for iOS internal deploys.

MAPLIBRE_DSYM_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPLIBRE_DSYM_REPO_ROOT="$(cd "$MAPLIBRE_DSYM_HELPER_DIR/../.." && pwd)"
# shellcheck source=../shared/local-artifact-root.sh
source "$MAPLIBRE_DSYM_REPO_ROOT/scripts/shared/local-artifact-root.sh"
[[ -f "$MAPLIBRE_DSYM_REPO_ROOT/.osrs-artifacts.env" ]] && source "$MAPLIBRE_DSYM_REPO_ROOT/.osrs-artifacts.env"
MAPLIBRE_DSYM_ASSET_NAME="MapLibre_ios_device.framework.dSYM.zip"
MAPLIBRE_DSYM_REPOSITORY_URL="https://github.com/maplibre/maplibre-native"

maplibre_dsym_python() {
    echo "${PYTHON_BIN:-python3}"
}

maplibre_dsym_asset_name() {
    echo "$MAPLIBRE_DSYM_ASSET_NAME"
}

maplibre_release_tag() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+([.][0-9]+)+([-+][A-Za-z0-9._-]+)?$ ]]; then
        echo "Invalid MapLibre version: $version" >&2
        return 1
    fi
    echo "ios-v$version"
}

maplibre_dsym_url() {
    local version="$1"
    local tag
    tag="$(maplibre_release_tag "$version")" || return 1
    echo "$MAPLIBRE_DSYM_REPOSITORY_URL/releases/download/$tag/$MAPLIBRE_DSYM_ASSET_NAME"
}

maplibre_version_from_package_resolved_file() {
    local package_resolved="$1"
    [[ -f "$package_resolved" ]] || return 1
    "$(maplibre_dsym_python)" - "$package_resolved" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(1)

pins = data.get("pins")
if pins is None:
    pins = data.get("object", {}).get("pins", [])

for pin in pins:
    state = pin.get("state", {})
    version = state.get("version")
    if not version:
        continue
    fields = [
        pin.get("identity", ""),
        pin.get("package", ""),
        pin.get("location", ""),
        pin.get("repositoryURL", ""),
    ]
    haystack = " ".join(str(field).lower() for field in fields)
    if (
        "maplibre-gl-native-distribution" in haystack
        or "maplibre native" in haystack
    ):
        print(version)
        sys.exit(0)

sys.exit(1)
PY
}

maplibre_version_from_archive_log() {
    local archive_log="$1"
    [[ -f "$archive_log" ]] || return 1
    "$(maplibre_dsym_python)" - "$archive_log" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
patterns = [
    r"MapLibre Native:\s+https://github\.com/maplibre/maplibre-gl-native-distribution\s+@\s+([0-9]+(?:\.[0-9]+)+(?:[-+][A-Za-z0-9._-]+)?)",
    r"Checking out\s+([0-9]+(?:\.[0-9]+)+(?:[-+][A-Za-z0-9._-]+)?)\s+of package\s+[‘']maplibre-gl-native-distribution[’']",
]

for pattern in patterns:
    match = re.search(pattern, text)
    if match:
        print(match.group(1))
        sys.exit(0)

sys.exit(1)
PY
}

maplibre_package_resolved_candidates() {
    local repo_root="${1:-$MAPLIBRE_DSYM_REPO_ROOT}"
    cat <<EOF
$repo_root/Package.resolved
$repo_root/platforms/ios/Package.resolved
$repo_root/platforms/ios/osrswiki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
$repo_root/platforms/ios/osrswiki.xcodeproj/xcshareddata/swiftpm/Package.resolved
EOF
}

maplibre_detect_version() {
    local archive_log="${1:-}"
    local repo_root="${REPO_ROOT:-$MAPLIBRE_DSYM_REPO_ROOT}"
    local package_resolved version

    if [[ -n "${OSRSWIKI_MAPLIBRE_VERSION:-}" ]]; then
        maplibre_release_tag "$OSRSWIKI_MAPLIBRE_VERSION" >/dev/null || return 1
        echo "$OSRSWIKI_MAPLIBRE_VERSION"
        return 0
    fi

    while IFS= read -r package_resolved; do
        if version="$(maplibre_version_from_package_resolved_file "$package_resolved" 2>/dev/null)"; then
            echo "$version"
            return 0
        fi
    done < <(maplibre_package_resolved_candidates "$repo_root")

    if [[ -n "$archive_log" ]] && version="$(maplibre_version_from_archive_log "$archive_log" 2>/dev/null)"; then
        echo "$version"
        return 0
    fi

    return 1
}

maplibre_detect_version_source() {
    local archive_log="${1:-}"
    local repo_root="${REPO_ROOT:-$MAPLIBRE_DSYM_REPO_ROOT}"
    local package_resolved

    if [[ -n "${OSRSWIKI_MAPLIBRE_VERSION:-}" ]]; then
        echo "env_override:OSRSWIKI_MAPLIBRE_VERSION"
        return 0
    fi

    while IFS= read -r package_resolved; do
        if maplibre_version_from_package_resolved_file "$package_resolved" >/dev/null 2>&1; then
            echo "package_resolved:$package_resolved"
            return 0
        fi
    done < <(maplibre_package_resolved_candidates "$repo_root")

    if [[ -n "$archive_log" ]] && maplibre_version_from_archive_log "$archive_log" >/dev/null 2>&1; then
        echo "archive_log:$archive_log"
        return 0
    fi

    echo "unresolved"
    return 1
}

maplibre_default_dsym_cache_dir() {
    echo "${OSRSWIKI_MAPLIBRE_DSYM_CACHE_DIR:-$HOME/Library/Caches/osrswiki/maplibre-dsyms}"
}

maplibre_resolve_dsym_zip() {
    local version="$1"
    local url cache_dir cache_zip tmp_zip
    url="$(maplibre_dsym_url "$version")" || return 1

    if [[ -n "${OSRSWIKI_MAPLIBRE_DSYM_ZIP:-}" ]]; then
        if [[ ! -f "$OSRSWIKI_MAPLIBRE_DSYM_ZIP" ]]; then
            echo "MapLibre dSYM local override not found: $OSRSWIKI_MAPLIBRE_DSYM_ZIP" >&2
            return 1
        fi
        printf 'local_override\n%s\n%s\n' "$OSRSWIKI_MAPLIBRE_DSYM_ZIP" "$url"
        return 0
    fi

    cache_dir="$(maplibre_default_dsym_cache_dir)/$(maplibre_release_tag "$version")"
    cache_zip="$cache_dir/$MAPLIBRE_DSYM_ASSET_NAME"
    if [[ -f "$cache_zip" ]]; then
        printf 'cache\n%s\n%s\n' "$cache_zip" "$url"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required to download $url; set OSRSWIKI_MAPLIBRE_DSYM_ZIP for offline use" >&2
        return 1
    fi

    mkdir -p "$cache_dir"
    tmp_zip="$cache_zip.tmp.$$"
    rm -f "$tmp_zip"
    if ! curl -fL --retry 3 --output "$tmp_zip" "$url"; then
        rm -f "$tmp_zip"
        echo "Failed to download MapLibre dSYM: $url" >&2
        return 1
    fi
    mv "$tmp_zip" "$cache_zip"
    printf 'download\n%s\n%s\n' "$cache_zip" "$url"
}

maplibre_archive_framework_binary() {
    local archive_path="$1"
    local framework_binary
    framework_binary="$(find "$archive_path/Products/Applications" -path '*/Frameworks/MapLibre.framework/MapLibre' -type f 2>/dev/null | head -1)"
    if [[ -z "$framework_binary" ]]; then
        echo "MapLibre.framework binary not found in archive: $archive_path" >&2
        return 1
    fi
    echo "$framework_binary"
}

maplibre_dwarfdump_uuid() {
    local target="$1"
    if command -v dwarfdump >/dev/null 2>&1; then
        dwarfdump --uuid "$target"
    elif command -v xcrun >/dev/null 2>&1; then
        xcrun dwarfdump --uuid "$target"
    else
        echo "dwarfdump not found; install Xcode command line tools" >&2
        return 1
    fi
}

maplibre_extract_uuids() {
    local target="$1"
    maplibre_dwarfdump_uuid "$target" \
        | awk '/UUID:/ { print toupper($2) }' \
        | sort -u
}

maplibre_find_dsym_in_dir() {
    local search_dir="$1"
    find "$search_dir" -name '*.framework.dSYM' -type d 2>/dev/null | head -1
}

maplibre_write_manifest() {
    local manifest_path="$1"
    MAPLIBRE_MANIFEST_PATH="$manifest_path" "$(maplibre_dsym_python)" - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

def split_lines(name):
    value = os.environ.get(name, "")
    return [line for line in value.splitlines() if line]

payload = {
    "timestamp_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "maplibre_version": os.environ["MAPLIBRE_VERSION"],
    "version_source": os.environ["MAPLIBRE_VERSION_SOURCE"],
    "release_tag": os.environ["MAPLIBRE_RELEASE_TAG"],
    "asset_url": os.environ["MAPLIBRE_DSYM_URL"],
    "source": os.environ["MAPLIBRE_DSYM_SOURCE"],
    "candidate_zip": os.environ["MAPLIBRE_DSYM_ZIP"],
    "archive_path": os.environ["MAPLIBRE_ARCHIVE_PATH"],
    "framework_binary": os.environ["MAPLIBRE_FRAMEWORK_BINARY"],
    "framework_uuids": split_lines("MAPLIBRE_FRAMEWORK_UUIDS"),
    "candidate_dsym": os.environ["MAPLIBRE_CANDIDATE_DSYM"],
    "dsym_uuids": split_lines("MAPLIBRE_DSYM_UUIDS"),
    "injected_dsym_path": os.environ["MAPLIBRE_INJECTED_DSYM"],
}

Path(os.environ["MAPLIBRE_MANIFEST_PATH"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

maplibre_inject_dsym_into_archive() {
    local archive_path="$1"
    local archive_log="${2:-}"
    local evidence_dir="${3:-$(pwd)}"
    local injection_log="$evidence_dir/maplibre-dsym-injection.txt"
    local manifest_path="$evidence_dir/maplibre-dsym-manifest.json"
    local version version_source url release_tag resolved source zip_path extract_root candidate_dsym
    local framework_binary framework_uuids dsym_uuids existing_dsym injected_dsym tmp_dir

    mkdir -p "$evidence_dir"
    : >"$injection_log"

    {
        echo "MapLibre dSYM injection preflight"
        echo "archive_path=$archive_path"
        echo "archive_log=${archive_log:-unavailable}"
    } | tee -a "$injection_log"

    if [[ ! -d "$archive_path" ]]; then
        echo "Archive not found: $archive_path" | tee -a "$injection_log" >&2
        return 1
    fi

    if ! version="$(maplibre_detect_version "$archive_log")"; then
        echo "Unable to determine resolved MapLibre version from SwiftPM Package.resolved or archive log" | tee -a "$injection_log" >&2
        return 1
    fi
    version_source="$(maplibre_detect_version_source "$archive_log" || echo unresolved)"
    release_tag="$(maplibre_release_tag "$version")" || return 1
    url="$(maplibre_dsym_url "$version")" || return 1
    framework_binary="$(maplibre_archive_framework_binary "$archive_path")" || {
        echo "MapLibre archive framework lookup failed" | tee -a "$injection_log" >&2
        return 1
    }
    framework_uuids="$(maplibre_extract_uuids "$framework_binary")" || {
        echo "Failed to read MapLibre.framework UUID with dwarfdump" | tee -a "$injection_log" >&2
        return 1
    }
    if [[ -z "$framework_uuids" ]]; then
        echo "No UUIDs found in archived MapLibre.framework" | tee -a "$injection_log" >&2
        return 1
    fi

    existing_dsym="$(maplibre_find_dsym_in_dir "$archive_path/dSYMs" || true)"
    if [[ -n "$existing_dsym" ]]; then
        dsym_uuids="$(maplibre_extract_uuids "$existing_dsym" || true)"
        if [[ "$framework_uuids" == "$dsym_uuids" ]]; then
            echo "Existing MapLibre dSYM already matches archived framework UUIDs" | tee -a "$injection_log"
            return 0
        fi
    fi

    resolved="$(maplibre_resolve_dsym_zip "$version")" || {
        echo "Unable to resolve MapLibre dSYM zip for version $version" | tee -a "$injection_log" >&2
        return 1
    }
    source="$(printf '%s\n' "$resolved" | sed -n '1p')"
    zip_path="$(printf '%s\n' "$resolved" | sed -n '2p')"

    local scratch_root
    scratch_root="$(osrs_local_cache_dir)/scratch/maplibre-dsym"
    scratch_root="$(osrs_assert_artifact_path "$scratch_root")"
    mkdir -p "$scratch_root"
    tmp_dir="$(mktemp -d "$scratch_root/maplibre-dsym.XXXXXX")"
    extract_root="$tmp_dir/extract"
    mkdir -p "$extract_root"
    if ! unzip -q "$zip_path" -d "$extract_root"; then
        rm -rf "$tmp_dir"
        echo "Failed to unzip MapLibre dSYM archive: $zip_path" | tee -a "$injection_log" >&2
        return 1
    fi
    candidate_dsym="$(maplibre_find_dsym_in_dir "$extract_root" || true)"
    if [[ -z "$candidate_dsym" ]]; then
        rm -rf "$tmp_dir"
        echo "No .framework.dSYM bundle found in $zip_path" | tee -a "$injection_log" >&2
        return 1
    fi

    dsym_uuids="$(maplibre_extract_uuids "$candidate_dsym")" || {
        rm -rf "$tmp_dir"
        echo "Failed to read candidate MapLibre dSYM UUID with dwarfdump" | tee -a "$injection_log" >&2
        return 1
    }
    if [[ -z "$dsym_uuids" ]]; then
        rm -rf "$tmp_dir"
        echo "No UUIDs found in candidate MapLibre dSYM" | tee -a "$injection_log" >&2
        return 1
    fi
    if [[ "$framework_uuids" != "$dsym_uuids" ]]; then
        {
            echo "UUID mismatch between archived MapLibre.framework and candidate dSYM"
            echo "framework_uuids=$(printf '%s' "$framework_uuids" | tr '\n' ' ')"
            echo "dsym_uuids=$(printf '%s' "$dsym_uuids" | tr '\n' ' ')"
            echo "candidate_zip=$zip_path"
            echo "asset_url=$url"
        } | tee -a "$injection_log" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$archive_path/dSYMs"
    injected_dsym="$archive_path/dSYMs/MapLibre.framework.dSYM"
    rm -rf "$injected_dsym"
    cp -R "$candidate_dsym" "$injected_dsym"

    MAPLIBRE_VERSION="$version" \
    MAPLIBRE_VERSION_SOURCE="$version_source" \
    MAPLIBRE_RELEASE_TAG="$release_tag" \
    MAPLIBRE_DSYM_URL="$url" \
    MAPLIBRE_DSYM_SOURCE="$source" \
    MAPLIBRE_DSYM_ZIP="$zip_path" \
    MAPLIBRE_ARCHIVE_PATH="$archive_path" \
    MAPLIBRE_FRAMEWORK_BINARY="$framework_binary" \
    MAPLIBRE_FRAMEWORK_UUIDS="$framework_uuids" \
    MAPLIBRE_CANDIDATE_DSYM="$candidate_dsym" \
    MAPLIBRE_DSYM_UUIDS="$dsym_uuids" \
    MAPLIBRE_INJECTED_DSYM="$injected_dsym" \
        maplibre_write_manifest "$manifest_path"

    {
        echo "maplibre_version=$version"
        echo "version_source=$version_source"
        echo "asset_url=$url"
        echo "source=$source"
        echo "candidate_zip=$zip_path"
        echo "framework_binary=$framework_binary"
        echo "framework_uuids=$(printf '%s' "$framework_uuids" | tr '\n' ' ')"
        echo "dsym_uuids=$(printf '%s' "$dsym_uuids" | tr '\n' ' ')"
        echo "injected_dsym=$injected_dsym"
        echo "manifest=$manifest_path"
        echo "MapLibre dSYM UUID parity verified and injected"
    } | tee -a "$injection_log"
    rm -rf "$tmp_dir"
}

maplibre_print_dsym_dry_run_plan() {
    local archive_path="$1"
    local archive_log="${2:-}"
    local version url

    echo "[dry-run] MapLibre dSYM injection runs after archive and before xcodebuild -exportArchive"
    echo "[dry-run] archive dSYM target: $archive_path/dSYMs/MapLibre.framework.dSYM"
    if version="$(maplibre_detect_version "$archive_log" 2>/dev/null)"; then
        url="$(maplibre_dsym_url "$version")"
        echo "[dry-run] resolved MapLibre version: $version"
        echo "[dry-run] MapLibre dSYM URL: $url"
    else
        echo "[dry-run] MapLibre version will be resolved from SwiftPM Package.resolved or archive log after archive"
    fi
    if [[ -n "${OSRSWIKI_MAPLIBRE_DSYM_ZIP:-}" ]]; then
        echo "[dry-run] local dSYM override: OSRSWIKI_MAPLIBRE_DSYM_ZIP=$OSRSWIKI_MAPLIBRE_DSYM_ZIP"
    else
        echo "[dry-run] dSYM cache dir: $(maplibre_default_dsym_cache_dir)"
    fi
    echo "[dry-run] UUID parity check: dwarfdump --uuid archived MapLibre.framework vs candidate dSYM"
}
