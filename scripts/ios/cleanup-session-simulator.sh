#!/bin/bash
set -euo pipefail

# Release the iOS Simulator lease for this session.
# The lifecycle helper performs exact-UDID, owner-scoped release and only
# applies a UDID-scoped shutdown when no other live lease remains.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

echo "🧹 Releasing iOS Simulator session..."

if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS development requires macOS. Current platform: $(uname)"
    exit 1
fi

if [[ $# -eq 2 ]]; then
    SIMULATOR_NAME="$1"
    IOS_SIMULATOR_UDID="$2"
    export SIMULATOR_NAME IOS_SIMULATOR_UDID
    echo "📱 Using provided simulator:"
    echo "   • Simulator: $SIMULATOR_NAME"
    echo "   • UDID: $IOS_SIMULATOR_UDID"
else
    ios_load_session_env || true
fi

if [[ -z "${IOS_SIMULATOR_UDID:-}" ]]; then
    echo "✅ No session simulator metadata found"
    echo "   This is normal if no iOS simulator was created for this session."
    exit 0
fi

SIMULATOR_NAME="${SIMULATOR_NAME:-$(ios_simulator_name "$IOS_SIMULATOR_UDID" || true)}"
OWNER_ID="$(ios_lifecycle_owner_id)"

if [[ -n "$SIMULATOR_NAME" ]]; then
    echo "📱 Session simulator: $SIMULATOR_NAME ($IOS_SIMULATOR_UDID)"
else
    echo "📱 Session simulator UDID: $IOS_SIMULATOR_UDID"
fi
echo "👤 Lease owner: $OWNER_ID"

echo "📝 Releasing lifecycle lease..."
RELEASE_JSON="$(ios_lifecycle_release "$IOS_SIMULATOR_UDID" "$OWNER_ID" true)"
printf '%s\n' "$RELEASE_JSON"

RELEASED="$(printf '%s\n' "$RELEASE_JSON" | ios_json_value released 2>/dev/null || printf 'false')"
SHUTDOWN_ALLOWED="$(printf '%s\n' "$RELEASE_JSON" | ios_json_value plan.shutdown_allowed 2>/dev/null || printf 'false')"

if [[ "$RELEASED" != "True" && "$RELEASED" != "true" ]]; then
    echo "❌ No matching unreleased lifecycle lease was found for this owner and UDID." >&2
    echo "   Metadata was left in place for inspection." >&2
    exit 1
fi

if [[ "$SHUTDOWN_ALLOWED" == "True" || "$SHUTDOWN_ALLOWED" == "true" ]]; then
    echo "✅ Lease released and exact simulator shutdown was allowed by lifecycle policy."
else
    echo "✅ Lease released. Simulator shutdown was skipped because another live lease may remain or shutdown was not allowed."
fi

echo "🧹 Cleaning local session metadata..."
files_to_remove=(
    "$OSRS_IOS_LEASE_FILE"
    "$OSRS_IOS_ENV_FILE"
    "$OSRS_IOS_LEGACY_SESSION_FILE"
    "$OSRS_IOS_LEGACY_UDID_FILE"
    "$OSRS_IOS_LEGACY_NAME_FILE"
    "$OSRS_IOS_LEGACY_BUNDLE_FILE"
    "$OSRS_IOS_LEGACY_ENV_FILE"
)

for file in "${files_to_remove[@]}"; do
    if [[ -f "$file" ]]; then
        rm "$file"
        echo "   • Removed $(basename "$file")"
    fi
done

SCREENSHOTS_DIR="$(osrs_session_artifact_dir screenshots)"
if [[ -d "$SCREENSHOTS_DIR" && -n "$(ls -A "$SCREENSHOTS_DIR" 2>/dev/null)" ]]; then
    echo "📸 Screenshots were preserved at $SCREENSHOTS_DIR"
fi

echo ""
echo "✅ iOS Simulator session release complete!"
echo "💡 Verify with: ./scripts/ios/verify-simulator-cleanup.sh"
