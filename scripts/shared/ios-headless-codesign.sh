#!/usr/bin/env bash
# Prepare a dedicated signing keychain so xcodebuild/codesign work over SSH
# (avoids errSecInternalComponent / "User interaction is not allowed" on login.keychain).
#
# Secrets (never commit):
#   ~/.config/osrswiki/signing-keychain.pass
#   ~/.config/osrswiki/ios-development.p12 (+ .pass)
#   ~/.config/osrswiki/ios-distribution.p12 (+ .pass)
#
# Usage:
#   source scripts/shared/ios-headless-codesign.sh
#   ios_headless_codesign_prepare
# Or: scripts/shared/ios-headless-codesign.sh prepare

set -euo pipefail

OSRSWIKI_CONFIG_DIR="${OSRSWIKI_CONFIG_DIR:-$HOME/.config/osrswiki}"
OSRSWIKI_SIGNING_KEYCHAIN="${OSRSWIKI_SIGNING_KEYCHAIN:-$OSRSWIKI_CONFIG_DIR/osrswiki-signing.keychain-db}"
OSRSWIKI_SIGNING_KEYCHAIN_PASS_FILE="${OSRSWIKI_SIGNING_KEYCHAIN_PASS_FILE:-$OSRSWIKI_CONFIG_DIR/signing-keychain.pass}"

_ios_hc_read_pass() {
    local file="$1"
    python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).read_text().strip())' "$file"
}

_ios_hc_require_file() {
    local file="$1" label="$2"
    if [[ ! -f "$file" ]]; then
        echo "❌ Missing $label: $file" >&2
        echo "   Run setup-internal-deploy / create the dedicated signing keychain material under ~/.config/osrswiki/" >&2
        return 1
    fi
}

ios_headless_codesign_prepare() {
    local kc pass_file kpass
    local dev_p12 dev_pass_file dist_p12 dist_pass_file
    local login_kc system_kc

    kc="$OSRSWIKI_SIGNING_KEYCHAIN"
    pass_file="$OSRSWIKI_SIGNING_KEYCHAIN_PASS_FILE"
    dev_p12="$OSRSWIKI_CONFIG_DIR/ios-development.p12"
    dev_pass_file="$OSRSWIKI_CONFIG_DIR/ios-development.p12.pass"
    dist_p12="$OSRSWIKI_CONFIG_DIR/ios-distribution.p12"
    dist_pass_file="$OSRSWIKI_CONFIG_DIR/ios-distribution.p12.pass"
    login_kc="$HOME/Library/Keychains/login.keychain-db"
    system_kc="/Library/Keychains/System.keychain"

    umask 077
    mkdir -p "$OSRSWIKI_CONFIG_DIR"

    if [[ ! -f "$pass_file" ]]; then
        /usr/bin/openssl rand -hex 16 > "$pass_file"
        chmod 600 "$pass_file"
        echo "ℹ️  Created $pass_file"
    fi

    _ios_hc_require_file "$pass_file" "signing keychain passphrase"
    _ios_hc_require_file "$dev_p12" "iOS development .p12"
    _ios_hc_require_file "$dev_pass_file" "iOS development .p12 passphrase"
    _ios_hc_require_file "$dist_p12" "iOS distribution .p12"
    _ios_hc_require_file "$dist_pass_file" "iOS distribution .p12 passphrase"

    kpass="$(_ios_hc_read_pass "$pass_file")"

    if [[ ! -f "$kc" ]]; then
        security create-keychain -p "$kpass" "$kc"
        echo "ℹ️  Created signing keychain: $kc"
    fi

    # Unlock first — set-keychain-settings fails with "User interaction is not
    # allowed" over SSH if the keychain is still locked.
    security unlock-keychain -p "$kpass" "$kc"
    # Best-effort lock timeout (non-fatal on headless sessions).
    security set-keychain-settings -lut 21600 "$kc" >/dev/null 2>&1 || true

    # Prefer signing keychain first so Automatic signing picks these identities.
    if [[ -f "$login_kc" ]]; then
        security list-keychains -d user -s "$kc" "$login_kc" "$system_kc"
    else
        security list-keychains -d user -s "$kc" "$system_kc"
    fi

    # -f pkcs12 is required: without it, security import can MAC-fail even when
    # openssl pkcs12 -passin file:... succeeds on the same files.
    local dev_pass dist_pass
    dev_pass="$(_ios_hc_read_pass "$dev_pass_file")"
    dist_pass="$(_ios_hc_read_pass "$dist_pass_file")"

    # Ignore "already exists" style failures on re-import.
    security import "$dev_p12" -k "$kc" -P "$dev_pass" -f pkcs12 -A >/dev/null 2>&1 || true
    security import "$dist_p12" -k "$kc" -P "$dist_pass" -f pkcs12 -A >/dev/null 2>&1 || true

    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kpass" "$kc" >/dev/null

    if ! security find-identity -v -p codesigning "$kc" | grep -q "Apple Distribution"; then
        echo "❌ Apple Distribution identity missing from $kc after import" >&2
        security find-identity -v -p codesigning "$kc" >&2 || true
        return 1
    fi

    echo "✅ Headless iOS codesign keychain ready: $kc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-prepare}" in
        prepare) ios_headless_codesign_prepare ;;
        *)
            echo "Usage: $0 prepare" >&2
            exit 2
            ;;
    esac
fi
