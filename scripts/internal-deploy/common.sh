#!/bin/bash
# Shared helpers for OSRS Wiki internal deployment scripts.

set -euo pipefail

INTERNAL_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$INTERNAL_DEPLOY_DIR/../.." && pwd)"
CONFIG_DIR="${OSRSWIKI_CONFIG_DIR:-$HOME/.config/osrswiki}"
# shellcheck source=../shared/local-artifact-root.sh
source "$REPO_ROOT/scripts/shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

if [[ -n "${OSRSWIKI_INTERNAL_DEPLOY_ENV:-}" ]]; then
    ENV_FILE="$OSRSWIKI_INTERNAL_DEPLOY_ENV"
elif [[ -f "$INTERNAL_DEPLOY_DIR/.env" ]]; then
    ENV_FILE="$INTERNAL_DEPLOY_DIR/.env"
elif [[ -f "$CONFIG_DIR/internal-deploy.env" ]]; then
    ENV_FILE="$CONFIG_DIR/internal-deploy.env"
elif [[ -f "$CONFIG_DIR/beta.env" ]]; then
    ENV_FILE="$CONFIG_DIR/beta.env"
else
    ENV_FILE="$CONFIG_DIR/internal-deploy.env"
fi

EVIDENCE_ROOT="${OSRSWIKI_INTERNAL_DEPLOY_EVIDENCE_ROOT:-$(osrs_session_artifact_dir internal-deploy)}"
EVIDENCE_ROOT="$(osrs_assert_artifact_path "$EVIDENCE_ROOT")"
PYTHON_BIN="${OSRSWIKI_INTERNAL_DEPLOY_PYTHON:-$REPO_ROOT/tools/.pixi/envs/default/bin/python}"

ANDROID_PLATFORM_DIR="$REPO_ROOT/platforms/android"
ANDROID_BUILD_GRADLE="$ANDROID_PLATFORM_DIR/app/build.gradle.kts"
ANDROID_PACKAGE_NAME="com.omiyawaki.osrswiki"

IOS_PLATFORM_DIR="$REPO_ROOT/platforms/ios"
IOS_PROJECT="$IOS_PLATFORM_DIR/osrswiki.xcodeproj"
IOS_SCHEME="osrswiki"
IOS_BUNDLE_ID="omiyawaki.osrswiki"

APP_VERSION_MANIFEST="$REPO_ROOT/shared/manifests/app-version.json"

COLOR_SCRIPT="$REPO_ROOT/scripts/shared/color-utils.sh"
if [[ -f "$COLOR_SCRIPT" ]]; then
    # shellcheck disable=SC1090
    source "$COLOR_SCRIPT"
else
    print_header() { echo "$1"; }
    print_phase() { echo "$1"; }
    print_success() { echo "OK: $1"; }
    print_warning() { echo "WARN: $1"; }
    print_error() { echo "ERROR: $1" >&2; }
    print_info() { echo "INFO: $1"; }
fi

load_internal_deploy_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
    CONFIG_DIR="${OSRSWIKI_CONFIG_DIR:-$CONFIG_DIR}"
    PYTHON_BIN="${OSRSWIKI_INTERNAL_DEPLOY_PYTHON:-$PYTHON_BIN}"
}

require_command() {
    local cmd="$1"
    local install_hint="${2:-Install $cmd and retry.}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "Required command not found: $cmd"
        echo "$install_hint"
        return 1
    fi
}

read_android_version_code() {
    grep -E 'versionCode = ' "$ANDROID_BUILD_GRADLE" | head -1 | sed -E 's/.*versionCode = ([0-9]+).*/\1/'
}

read_android_version_name() {
    grep -E 'versionName = ' "$ANDROID_BUILD_GRADLE" | head -1 | sed -E 's/.*versionName = "([^"]+)".*/\1/'
}

write_android_version_code() {
    local new_code="$1"
    perl -0pi -e "s/versionCode = \\d+/versionCode = $new_code/" "$ANDROID_BUILD_GRADLE"
}

write_android_version_name() {
    local new_name="$1"
    perl -0pi -e "s/versionName = \"[^\"]+\"/versionName = \"$new_name\"/" "$ANDROID_BUILD_GRADLE"
}

read_ios_build_number() {
    grep -m1 'CURRENT_PROJECT_VERSION = ' "$IOS_PROJECT/project.pbxproj" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);/\1/'
}

read_ios_marketing_version() {
    grep -m1 'MARKETING_VERSION = ' "$IOS_PROJECT/project.pbxproj" | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/'
}

write_ios_build_number() {
    local new_build="$1"
    perl -pi -e "s/CURRENT_PROJECT_VERSION = \\d+;/CURRENT_PROJECT_VERSION = $new_build;/g" "$IOS_PROJECT/project.pbxproj"
}

write_ios_marketing_version() {
    local new_version="$1"
    perl -pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $new_version;/g" "$IOS_PROJECT/project.pbxproj"
}

read_marketing_version_from_manifest() {
    if [[ ! -f "$APP_VERSION_MANIFEST" ]]; then
        print_error "Marketing version manifest not found: $APP_VERSION_MANIFEST"
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r '.marketing_version' "$APP_VERSION_MANIFEST"
    else
        grep -m1 '"marketing_version"' "$APP_VERSION_MANIFEST" | sed -E 's/.*"marketing_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi
}

write_marketing_version_to_manifest() {
    local new_version="$1"
    if [[ ! -f "$APP_VERSION_MANIFEST" ]]; then
        print_error "Marketing version manifest not found: $APP_VERSION_MANIFEST"
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        jq --arg v "$new_version" '.marketing_version = $v' "$APP_VERSION_MANIFEST" > "$tmp" && mv "$tmp" "$APP_VERSION_MANIFEST"
    else
        perl -pi -e "s/(\"marketing_version\"[[:space:]]*:[[:space:]]*\")[^\"]+/\${1}$new_version/" "$APP_VERSION_MANIFEST"
    fi
}

bump_marketing_version() {
    local mode="$1"
    local current new
    current="$(read_marketing_version_from_manifest)"
    if [[ -z "$current" ]]; then
        print_error "Could not read current marketing version"
        return 1
    fi
    case "$mode" in
        major)
            new="$(echo "$current" | awk -F. '{print ($1+1)".0.0"}')"
            ;;
        minor)
            new="$(echo "$current" | awk -F. '{print $1"."($2+1)".0"}')"
            ;;
        patch)
            new="$(echo "$current" | awk -F. '{print $1"."$2"."($3+1)}')"
            ;;
        none)
            new="$current"
            ;;
        *)
            print_error "Invalid bump mode: $mode (expected major|minor|patch|none)"
            return 1
            ;;
    esac
    echo "$new"
}

apply_marketing_version_to_platforms() {
    local version="$1"
    write_android_version_name "$version"
    write_ios_marketing_version "$version"
}

android_signing_file() {
    echo "${OSRSWIKI_ANDROID_SIGNING_PROPERTIES:-$CONFIG_DIR/android-signing.properties}"
}

android_signing_configured() {
    local signing_file
    signing_file="$(android_signing_file)"
    if [[ -f "$signing_file" ]]; then
        local required_keys=(storeFile storePassword keyAlias keyPassword)
        local key value
        for key in "${required_keys[@]}"; do
            value="$(grep -E "^${key}=" "$signing_file" | head -1 | cut -d= -f2- || true)"
            if [[ -z "$value" || "$value" == REPLACE_WITH_* ]]; then
                return 1
            fi
        done
        return 0
    fi
    if [[ -n "${OSRSWIKI_ANDROID_KEYSTORE:-}" && -n "${OSRSWIKI_ANDROID_KEYSTORE_PASSWORD:-}" && -n "${OSRSWIKI_ANDROID_KEY_ALIAS:-}" && -n "${OSRSWIKI_ANDROID_KEY_PASSWORD:-}" ]]; then
        if [[ "$OSRSWIKI_ANDROID_KEYSTORE_PASSWORD" == REPLACE_WITH_* || "$OSRSWIKI_ANDROID_KEY_ALIAS" == REPLACE_WITH_* || "$OSRSWIKI_ANDROID_KEY_PASSWORD" == REPLACE_WITH_* ]]; then
            return 1
        fi
        return 0
    fi
    return 1
}

android_play_credentials_configured() {
    [[ -n "${PLAY_SERVICE_ACCOUNT_JSON:-}" && -f "${PLAY_SERVICE_ACCOUNT_JSON:-/nonexistent}" ]]
}

android_play_python_configured() {
    command -v "$PYTHON_BIN" >/dev/null 2>&1 && "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import google.oauth2.service_account
import googleapiclient.discovery
PY
}

ios_api_credentials_configured() {
    [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" && -n "${ASC_API_KEY_PATH:-}" && -f "${ASC_API_KEY_PATH:-/nonexistent}" ]]
}

print_android_signing_setup() {
    print_error "Android release signing is not configured."
    cat <<EOF
Create a local signing file, never committed:
  mkdir -p "$CONFIG_DIR"
  cp "$INTERNAL_DEPLOY_DIR/config/android-signing.properties.example" "$(android_signing_file)"
  # Fill in storeFile, storePassword, keyAlias, and keyPassword.

Alternative: set OSRSWIKI_ANDROID_KEYSTORE, OSRSWIKI_ANDROID_KEYSTORE_PASSWORD,
OSRSWIKI_ANDROID_KEY_ALIAS, and OSRSWIKI_ANDROID_KEY_PASSWORD in "$ENV_FILE".
EOF
}

print_android_play_setup() {
    print_error "Google Play upload credentials are not configured."
    cat <<EOF
Create a local env file, never committed:
  mkdir -p "$CONFIG_DIR"
  cp "$INTERNAL_DEPLOY_DIR/.env.example" "$CONFIG_DIR/internal-deploy.env"

Then set PLAY_SERVICE_ACCOUNT_JSON to a local Google Play Android Publisher
service-account JSON key with access to package $ANDROID_PACKAGE_NAME.
EOF
}

print_ios_testflight_setup() {
    print_error "App Store Connect API credentials are not configured."
    cat <<EOF
Create a local env file, never committed:
  mkdir -p "$CONFIG_DIR"
  cp "$INTERNAL_DEPLOY_DIR/.env.example" "$CONFIG_DIR/internal-deploy.env"

Then set ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH to a local
App Store Connect API key that can upload TestFlight builds for $IOS_BUNDLE_ID.
EOF
}

init_evidence_dir() {
    local label="${1:-internal}"
    if [[ -z "${EVIDENCE_DIR:-}" ]]; then
        EVIDENCE_DIR="$EVIDENCE_ROOT/$(date +%Y%m%d-%H%M%S)-$label"
    fi
    mkdir -p "$EVIDENCE_DIR"
    LOG_FILE="$EVIDENCE_DIR/run.log"
    if [[ -z "${INTERNAL_DEPLOY_LOGGING_STARTED:-}" ]]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
        export INTERNAL_DEPLOY_LOGGING_STARTED=1
    fi
    print_info "Evidence directory: $EVIDENCE_DIR"
}

record_inventory_snapshot() {
    local out="$EVIDENCE_DIR/inventory.txt"
    {
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host=$(hostname)"
        echo "repo_root=$REPO_ROOT"
        echo "git_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)"
        echo "git_commit=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "android_version_code=$(read_android_version_code)"
        echo "android_version_name=$(read_android_version_name)"
        echo "ios_build_number=$(read_ios_build_number)"
        echo "ios_marketing_version=$(read_ios_marketing_version)"
        echo "android_signing_configured=$(android_signing_configured && echo yes || echo no)"
        echo "android_play_credentials=$(android_play_credentials_configured && echo yes || echo no)"
        echo "ios_api_credentials=$(ios_api_credentials_configured && echo yes || echo no)"
    } >"$out"
    print_success "Wrote inventory snapshot: $out"
}
