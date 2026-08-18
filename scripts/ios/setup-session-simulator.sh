#!/bin/bash
set -euo pipefail

# iOS Simulator session setup for OSRS wiki development sessions.
# Uses the provider-neutral lifecycle helper for deterministic naming and leases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=simulator-lifecycle-lib.sh
source "$SCRIPT_DIR/simulator-lifecycle-lib.sh"

echo "🍎 Setting up iOS Simulator session..."

echo "🔍 Detecting runtime environment..."
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS development requires macOS. Current platform: $(uname)"
    exit 1
fi

IS_CONTAINER_ENV=false
if [[ -n "${IS_CONTAINER:-}" || -f /.dockerenv || -f /run/.containerenv ]]; then
    IS_CONTAINER_ENV=true
    echo "🐳 Container environment detected (unusual for iOS development)"
else
    echo "💻 macOS host environment detected"
fi

echo "🔧 Checking iOS development tools..."
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "❌ Xcode Command Line Tools not found"
    echo "💡 Install with: xcode-select --install"
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "❌ xcrun not found (part of Xcode Command Line Tools)"
    exit 1
fi

if ! xcrun simctl list devices >/dev/null 2>&1; then
    echo "❌ iOS Simulator not available"
    echo "💡 Install Xcode from the App Store or developer.apple.com"
    exit 1
fi

if ! ios_lifecycle_helper_path >/dev/null 2>&1; then
    echo "❌ iOS simulator lifecycle helper not found"
    echo "💡 Set IOS_SIMULATOR_LIFECYCLE_HELPER or install the accepted agent-recipes hook"
    exit 1
fi

echo "✅ iOS development tools found"

BUNDLE_ID="${BUNDLE_ID:-$("$SCRIPT_DIR/get-bundle-id.sh" 2>/dev/null || echo "omiyawaki.osrswiki")}"
OWNER_ID="$(ios_lifecycle_owner_id)"

reuse_loaded_session=false
if ios_load_session_env && [[ -n "${IOS_SIMULATOR_UDID:-}" ]] && ios_simulator_exists "$IOS_SIMULATOR_UDID"; then
    reuse_loaded_session=true
    SIMULATOR_NAME="${SIMULATOR_NAME:-$(ios_simulator_name "$IOS_SIMULATOR_UDID")}"
    echo "📁 Reusing existing session simulator metadata"
    echo "   • Name: $SIMULATOR_NAME"
    echo "   • UDID: $IOS_SIMULATOR_UDID"
fi

if [[ "$reuse_loaded_session" != true ]]; then
    echo "🔍 Detecting available iOS runtimes and devices..."

    LATEST_IOS_RUNTIME="$(xcrun simctl list runtimes | grep "iOS" | tail -1 | sed 's/.*iOS \([0-9.]*\).*/\1/' || echo "17.0")"
    echo "📱 Using iOS runtime: $LATEST_IOS_RUNTIME"

    DEVICE_TYPES=(
        "iPhone 15 Pro"
        "iPhone 14 Pro"
        "iPhone 13 Pro"
        "iPhone 12 Pro"
        "iPhone 11"
    )

    DEVICE_TYPE=""
    for device in "${DEVICE_TYPES[@]}"; do
        if xcrun simctl list devicetypes | grep -q "\"$device\""; then
            DEVICE_TYPE="$device"
            echo "📱 Selected device: $DEVICE_TYPE"
            break
        fi
    done

    if [[ -z "$DEVICE_TYPE" ]]; then
        DEVICE_TYPE="$(xcrun simctl list devicetypes | grep iPhone | head -1 | sed 's/.*(\(.*\))/\1/' || echo "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro")"
        echo "📱 Using fallback device type: $DEVICE_TYPE"
    fi

    SIMULATOR_NAME="$(ios_lifecycle_deterministic_name)"
    echo "📱 Target simulator: $SIMULATOR_NAME"

    existing_udids=()
    while IFS= read -r udid; do
        [[ -n "$udid" ]] && existing_udids+=("$udid")
    done < <(ios_simulator_udids_by_name "$SIMULATOR_NAME" || true)

    if [[ ${#existing_udids[@]} -gt 1 ]]; then
        echo "❌ Multiple simulators match deterministic session name: $SIMULATOR_NAME" >&2
        printf '   • %s\n' "${existing_udids[@]}" >&2
        echo "💡 Resolve duplicate devices manually before continuing." >&2
        exit 2
    elif [[ ${#existing_udids[@]} -eq 1 ]]; then
        IOS_SIMULATOR_UDID="${existing_udids[0]}"
        echo "✅ Reusing existing deterministic simulator: $IOS_SIMULATOR_UDID"
    else
        echo "📱 Creating simulator: $SIMULATOR_NAME"
        IOS_SIMULATOR_UDID="$(xcrun simctl create "$SIMULATOR_NAME" "$DEVICE_TYPE" "iOS$LATEST_IOS_RUNTIME" 2>/dev/null || echo "")"

        if [[ -z "$IOS_SIMULATOR_UDID" ]]; then
            echo "⚠️  Failed to create simulator with latest runtime, trying without version..."
            IOS_SIMULATOR_UDID="$(xcrun simctl create "$SIMULATOR_NAME" "$DEVICE_TYPE" | grep -E "[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}" || echo "")"
        fi

        if [[ -z "$IOS_SIMULATOR_UDID" ]]; then
            echo "❌ Failed to create iOS Simulator"
            echo "💡 Available device types:"
            xcrun simctl list devicetypes | grep iPhone | head -5
            echo "💡 Available runtimes:"
            xcrun simctl list runtimes | grep iOS | head -3
            exit 1
        fi

        echo "✅ Simulator created with UDID: $IOS_SIMULATOR_UDID"
    fi
else
    DEVICE_TYPE="${DEVICE_TYPE:-}"
    LATEST_IOS_RUNTIME="${IOS_RUNTIME:-}"
fi

export IOS_SIMULATOR_UDID SIMULATOR_NAME BUNDLE_ID

echo "📝 Acquiring lifecycle lease..."
ACQUIRE_JSON="$(ios_lifecycle_acquire "$IOS_SIMULATOR_UDID" "$SIMULATOR_NAME" "$OWNER_ID" "$(ios_lifecycle_purpose)")"

echo "🚀 Booting iOS Simulator..."
xcrun simctl boot "$IOS_SIMULATOR_UDID" >/dev/null 2>&1 || true

echo "⏳ Waiting for simulator to boot..."
if xcrun simctl bootstatus "$IOS_SIMULATOR_UDID" -b >/dev/null 2>&1; then
    echo "✅ Simulator booted successfully"
else
    echo "⚠️  Simulator bootstatus timed out, but device may still be functional"
fi

echo "💾 Saving session information..."
ios_write_session_lease_metadata \
    "$IOS_SIMULATOR_UDID" \
    "$SIMULATOR_NAME" \
    "$BUNDLE_ID" \
    "${DEVICE_TYPE:-}" \
    "${LATEST_IOS_RUNTIME:-}" \
    "$OWNER_ID" \
    "$ACQUIRE_JSON" \
    false

ios_write_session_env \
    "$IOS_SIMULATOR_UDID" \
    "$SIMULATOR_NAME" \
    "$BUNDLE_ID" \
    "$IS_CONTAINER_ENV" \
    "${DEVICE_TYPE:-}" \
    "${LATEST_IOS_RUNTIME:-}" \
    "$OWNER_ID"

echo ""
echo "✅ iOS Simulator session ready!"
echo ""
echo "📱 Device Details:"
echo "   • Name: $SIMULATOR_NAME"
echo "   • UDID: $IOS_SIMULATOR_UDID"
echo "   • Type: ${DEVICE_TYPE:-unknown}"
echo "   • iOS: ${LATEST_IOS_RUNTIME:-unknown}"
echo "   • Owner: $OWNER_ID"
echo ""
echo "💡 Usage:"
echo "   📖 CRITICAL: Read ./scripts/ios/XCTest-GUIDE.md first!"
echo "   source .ios-env                       # Load environment variables"
echo "   ./scripts/ios/quick-test.sh           # Build and deploy app"
echo "   ./scripts/ios/automate-app-testing.sh quick-map"
echo "   ./scripts/ios/automate-app-testing.sh unit-tests"
echo ""
echo "🧹 To release this session simulator:"
echo "   ./scripts/ios/cleanup-session-simulator.sh"
echo ""

if xcrun simctl list devices | grep -F "$IOS_SIMULATOR_UDID" | grep -q "Booted"; then
    echo "🎉 Session setup complete! Simulator is ready for development."
else
    echo "⚠️  Session setup complete, but simulator may still be booting."
fi
