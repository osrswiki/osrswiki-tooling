#!/bin/bash
set -euo pipefail

# Verifies exact session simulator cleanup state without broad device actions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=simulator-lifecycle-lib.sh
source "$SCRIPT_DIR/simulator-lifecycle-lib.sh"

echo "🔍 Verifying iOS simulator cleanup..."

if [[ "$(uname)" != "Darwin" ]]; then
    echo "✅ iOS verification skipped - not on macOS"
    exit 0
fi

EXPECTED_SIMULATOR_UDID=""
EXPECTED_SIMULATOR_NAME=""
EXPECTED_OWNER_ID=""

if ios_load_session_env; then
    EXPECTED_SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-}"
    EXPECTED_SIMULATOR_NAME="${SIMULATOR_NAME:-}"
    EXPECTED_OWNER_ID="$(ios_lifecycle_owner_id)"
fi

if [[ -n "$EXPECTED_SIMULATOR_UDID" ]]; then
    echo "⚠️  Found session simulator metadata:"
    echo "   • Simulator: ${EXPECTED_SIMULATOR_NAME:-unknown}"
    echo "   • UDID: $EXPECTED_SIMULATOR_UDID"
    echo "   • Owner: $EXPECTED_OWNER_ID"

    if ios_registry_has_unreleased_owner_lease "$EXPECTED_SIMULATOR_UDID" "$EXPECTED_OWNER_ID"; then
        echo "❌ CLEANUP FAILED: lifecycle registry still has an unreleased lease for this owner and UDID"
        echo "🛠️  To fix this issue:"
        echo "   ./scripts/ios/cleanup-session-simulator.sh"
        exit 1
    fi

    SIMULATOR_INFO="$(ios_simctl_device_line_for_udid "$EXPECTED_SIMULATOR_UDID")"
    if [[ "$SIMULATOR_INFO" == *"(Booted)"* ]]; then
        echo "❌ CLEANUP FAILED: exact session simulator is still booted"
        echo "   $SIMULATOR_INFO"
        echo "🛠️  To fix this issue:"
        echo "   ./scripts/ios/cleanup-session-simulator.sh"
        exit 1
    fi

    echo "✅ Exact session simulator has no unreleased owner lease and is not booted"
else
    echo "✅ No session simulator configuration found"
fi

echo "🔍 Checking session file cleanup..."
session_files=(
    "$OSRS_IOS_LEASE_FILE"
    "$OSRS_IOS_ENV_FILE"
    "$OSRS_IOS_LEGACY_SESSION_FILE"
    "$OSRS_IOS_LEGACY_UDID_FILE"
    "$OSRS_IOS_LEGACY_NAME_FILE"
)

SESSION_FILES_REMAINING=()
for file in "${session_files[@]}"; do
    if [[ -f "$file" ]]; then
        SESSION_FILES_REMAINING+=("$(basename "$file")")
    fi
done

if [[ ${#SESSION_FILES_REMAINING[@]} -gt 0 ]]; then
    echo "❌ Session files not cleaned up:"
    for file in "${SESSION_FILES_REMAINING[@]}"; do
        echo "   • $file"
    done
    echo ""
    echo "🛠️  To fix this issue:"
    echo "   ./scripts/ios/cleanup-session-simulator.sh"
    exit 1
fi

echo "🔍 Checking for provider-neutral agent-owned simulators without taking action..."
AGENT_SIMS="$(xcrun simctl list devices | grep -E "agent-ios-|osrswiki-(codex|ios|agent|claude)-" || true)"
if [[ -n "$AGENT_SIMS" ]]; then
    echo "⚠️  Found agent-named simulators. These may belong to other active sessions:"
    echo "$AGENT_SIMS"
else
    echo "✅ No agent-named simulators found in device list"
fi

echo ""
echo "🎉 iOS simulator cleanup verification passed!"
echo "   • No exact session lease remains"
echo "   • Session configuration files cleaned"
echo "   • No broad simulator cleanup actions were used"
