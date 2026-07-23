#!/bin/bash
#
# Quick Map Tab Testing - Solves Navigation Bottleneck
# One-command solution for agents to test map changes
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

if ! ios_select_simulator; then
    echo "❌ IOS_SIMULATOR_UDID not set. Run 'source .ios-env' first"
    exit 1
fi

echo "🚀 Quick Map Tab Test - One Command Solution"
echo "=================================================="

# Step 1: Build app (only if needed)
echo "📦 Building app..."
cd "$PROJECT_ROOT/platforms/ios"
DERIVED_DATA_PATH="${OSRS_IOS_QUICK_MAP_DERIVED_DATA_PATH:-$(ios_make_derived_data_path quick-map)}"
DERIVED_DATA_PATH="$(osrs_assert_artifact_path "$DERIVED_DATA_PATH")"
mkdir -p "$DERIVED_DATA_PATH"
xcodebuild \
    -project osrswiki.xcodeproj \
    -scheme osrswiki \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    -quiet

# Step 2: Install app
echo "📱 Installing app..."
APP_PATH="$(ios_app_path_from_derived_data "$DERIVED_DATA_PATH")"
if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ App bundle not found at $APP_PATH" >&2
    exit 1
fi
xcrun simctl install "$IOS_SIMULATOR_UDID" "$APP_PATH"

# Step 3: Launch directly to map tab using our new launch arguments
echo "🗺️  Launching directly to Map tab..."
xcrun simctl terminate "$IOS_SIMULATOR_UDID" "omiyawaki.osrswiki" 2>/dev/null || true
xcrun simctl launch "$IOS_SIMULATOR_UDID" "omiyawaki.osrswiki" -startTab map

# Step 4: Wait for app to be ready
sleep 4

# Step 5: Take screenshot
echo "📸 Taking screenshot of map tab..."
cd "$PROJECT_ROOT"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
"$SCRIPT_DIR/take-screenshot.sh" "map-tab-auto-${TIMESTAMP}"

echo ""
echo "✅ SUCCESS! Map tab is now open and screenshot taken."
echo ""
echo "🎯 What to verify:"
echo "   • No 'OSRS Map' title at the top"
echo "   • Floor selector positioned at top-left" 
echo "   • Compass positioned at top-right"
echo "   • Both controls aligned where title used to be"
echo ""
echo "📁 Screenshot saved in: $(osrs_session_artifact_dir screenshots)"
echo ""
echo "🤖 Agent Note: You can now visually inspect the map changes!"
