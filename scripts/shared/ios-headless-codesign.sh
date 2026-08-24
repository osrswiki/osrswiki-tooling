#!/usr/bin/env bash
# Prepare a dedicated signing keychain so xcodebuild/codesign work over SSH
# without GUI password prompts (avoids errSecInternalComponent on login.keychain).
#
# Secrets (never commit):
#   ~/.config/osrswiki/signing-keychain.pass
#   ~/.config/osrswiki/ios-development.p12 (+ .pass)
#   ~/.config/osrswiki/ios-distribution.p12 (+ .pass)
#
# Important: this keychain must NOT stay first (or even present) in the default
# user keychain search list. Otherwise Glean/xcodebuild/other codesign work pops
# "codesign wants to use the 'osrswiki-signing' keychain" whenever it locks.
# prepare = unlock + never-lock + temporarily prepend for this shell's deploy.
# restore = put login(+system) only back as the search list.
#
# Usage:
#   source scripts/shared/ios-headless-codesign.sh
#   ios_headless_codesign_prepare
#   ... archive/export ...
#   ios_headless_codesign_restore
# Or: scripts/shared/ios-headless-codesign.sh prepare|restore

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

_ios_hc_login_kc() {
    echo "$HOME/Library/Keychains/login.keychain-db"
}

_ios_hc_system_kc() {
    echo "/Library/Keychains/System.keychain"
}

# Drop signing keychain from the default search list so background codesign
# (Glean, simulator xcodebuild, etc.) never prompts for it.
ios_headless_codesign_restore() {
    local login_kc system_kc
    login_kc="$(_ios_hc_login_kc)"
    system_kc="$(_ios_hc_system_kc)"
    if [[ -f "$login_kc" ]]; then
        security list-keychains -d user -s "$login_kc" "$system_kc"
    else
        security list-keychains -d user -s "$system_kc"
    fi
    echo "✅ Restored user keychain search list (signing keychain not in default list)"
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
    login_kc="$(_ios_hc_login_kc)"
    system_kc="$(_ios_hc_system_kc)"

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

    # Unlock, then disable lock-on-sleep and idle timeout so GUI never asks again
    # for this keychain after a successful unlock (man security: no -l/-u = never lock).
    security unlock-keychain -p "$kpass" "$kc"
    security set-keychain-settings "$kc" >/dev/null 2>&1 || true

    # Temporarily put signing keychain first ONLY for this deploy session.
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

    security import "$dev_p12" -k "$kc" -P "$dev_pass" -f pkcs12 -A >/dev/null 2>&1 || true
    security import "$dist_p12" -k "$kc" -P "$dist_pass" -f pkcs12 -A >/dev/null 2>&1 || true

    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kpass" "$kc" >/dev/null

    if ! security find-identity -v -p codesigning "$kc" | grep -q "Apple Distribution"; then
        echo "❌ Apple Distribution identity missing from $kc after import" >&2
        security find-identity -v -p codesigning "$kc" >&2 || true
        ios_headless_codesign_restore || true
        return 1
    fi

    echo "✅ Headless iOS codesign keychain ready (temporary search-list prepend): $kc"
    echo "   Call ios_headless_codesign_restore when archive/export finishes."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-prepare}" in
        prepare) ios_headless_codesign_prepare ;;
        restore) ios_headless_codesign_restore ;;
        *)
            echo "Usage: $0 prepare|restore" >&2
            exit 2
            ;;
    esac
fi
