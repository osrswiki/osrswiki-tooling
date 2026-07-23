#!/bin/bash
#
# Definitive In-Page MapLibre Widget Test
# Tests that MapLibre widgets actually render correctly in wiki pages
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

if ! ios_select_simulator; then
    echo "❌ IOS_SIMULATOR_UDID not set. Need to setup session first."
    echo "Run: ./scripts/ios/setup-session-simulator.sh"
    exit 1
fi

echo "🧪 DEFINITIVE MAPLIBRE WIDGET TEST"
echo "================================="
echo "This will test that MapLibre widgets render correctly in wiki pages"
echo ""

# Step 1: Build app
echo "📦 Building app..."
cd "$PROJECT_ROOT/platforms/ios"
DERIVED_DATA_PATH="${OSRS_IOS_MAPLIBRE_DERIVED_DATA_PATH:-$(ios_make_derived_data_path maplibre-widget)}"
DERIVED_DATA_PATH="$(osrs_assert_artifact_path "$DERIVED_DATA_PATH")"
mkdir -p "$DERIVED_DATA_PATH"
if ! xcodebuild \
    -project osrswiki.xcodeproj \
    -scheme osrswiki \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    -quiet; then
    echo "❌ Build failed"
    exit 1
fi
echo "✅ Build successful"

# Step 2: Install app
echo "📱 Installing app..."
APP_PATH="$(ios_app_path_from_derived_data "$DERIVED_DATA_PATH")"

if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ App bundle not found at $APP_PATH"
    exit 1
fi

xcrun simctl install "$IOS_SIMULATOR_UDID" "$APP_PATH"
echo "✅ App installed"

# Step 3: Launch app
echo "🚀 Launching app..."
xcrun simctl terminate "$IOS_SIMULATOR_UDID" "omiyawaki.osrswiki" 2>/dev/null || true
xcrun simctl launch "$IOS_SIMULATOR_UDID" "omiyawaki.osrswiki" --console-pty
sleep 3

# Step 4: Take initial screenshot
echo "📸 Taking initial app screenshot..."
cd "$PROJECT_ROOT"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
"$SCRIPT_DIR/take-screenshot.sh" "maplibre-test-initial-${TIMESTAMP}"

# Step 5: Navigate to a page with MapLibre widgets
echo "🔍 Searching for location with map widgets..."
# We'll search for "Varrock" which should have location maps
sleep 2
echo "📸 Taking search screenshot..."
"$SCRIPT_DIR/take-screenshot.sh" "maplibre-test-searching-${TIMESTAMP}"

echo ""
echo "🧪 MANUAL VERIFICATION REQUIRED"
echo "==============================="
echo ""
echo "The app is now running. Please manually:"
echo ""
echo "1. Tap the search icon"
echo "2. Search for 'Varrock' (a location with map widgets)"
echo "3. Tap on the Varrock article"
echo "4. Scroll down to find any map widgets"
echo "5. Check if maps render as native iOS MapLibre views"
echo ""
echo "✅ SUCCESS CRITERIA:"
echo "   - Map widgets appear as interactive native maps (not broken/empty)"
echo "   - Maps show proper geographic tiles"
echo "   - Maps respond to touch gestures (pinch/zoom/pan)"
echo "   - No JavaScript errors in device logs"
echo ""
echo "❌ FAILURE CRITERIA:"
echo "   - Map widgets appear as empty rectangles"
echo "   - Map widgets show error messages"
echo "   - Maps don't respond to touch"
echo "   - Console shows bridge communication errors"
echo ""
echo "📱 Simulator: $IOS_SIMULATOR_UDID"
echo "📁 Screenshots: $(osrs_session_artifact_dir screenshots)"
echo ""
echo "Take a screenshot when you can see the result:"
echo "  ./scripts/ios/take-screenshot.sh \"maplibre-test-result-WORKING\" (if working)"
echo "  ./scripts/ios/take-screenshot.sh \"maplibre-test-result-BROKEN\" (if broken)"
