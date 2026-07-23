#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

# iOS quick build and test - equivalent to Android quick-test.sh
# Builds the app and deploys to iOS Simulator for rapid development iterations

# Ensure we're on macOS (required for iOS development)
ios_require_macos
ios_select_simulator
ios_boot_selected_simulator
BUNDLE_ID="$(ios_resolve_bundle_id)"
export BUNDLE_ID

echo "🔨 Quick iOS build and test on simulator: $SIMULATOR_NAME"
echo "📱 Device UDID: $IOS_SIMULATOR_UDID"
echo ""
echo "💡 For UI testing and navigation, see:"
echo "   Apple XCTest Documentation: https://developer.apple.com/documentation/xctest"
echo "   UI Testing Guide: https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html"
echo ""

# Change to iOS project directory
cd "$OSRS_IOS_DIR"

# Create a controlled DerivedData directory outside the repo. Repo-local
# DerivedData has hit CodeSign detritus on repeated simulator builds.
DERIVED_DATA_PATH="${OSRS_IOS_QUICK_DERIVED_DATA_PATH:-$(ios_make_derived_data_path quick)}"
DERIVED_DATA_PATH="$(osrs_assert_artifact_path "$DERIVED_DATA_PATH")"
mkdir -p "$DERIVED_DATA_PATH"

# Build the iOS app for simulator with controlled build path
echo "⚙️  Building iOS app to controlled location..."
echo "📁 DerivedData path: $DERIVED_DATA_PATH"
xcodebuild \
    -project "osrswiki.xcodeproj" \
    -scheme "osrswiki" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,arch=arm64,id=$IOS_SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    -quiet

if [[ $? -ne 0 ]]; then
    echo "❌ Build failed!"
    echo "💡 Try opening Xcode and building manually to see detailed errors:"
    echo "   open 'platforms/ios/osrswiki.xcodeproj'"
    exit 1
fi

echo "✅ Build successful!"

# Use the exact app we just built (no search needed)
APP_PATH="$(ios_app_path_from_derived_data "$DERIVED_DATA_PATH")"
if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ Could not find built app at expected location: $APP_PATH"
    echo "💡 Build may have failed. Check Xcode for errors."
    exit 1
fi

echo "📦 Using app at: $APP_PATH"

# Install the app on simulator
echo "📲 Installing app on simulator..."
xcrun simctl install "$IOS_SIMULATOR_UDID" "$APP_PATH"

if [[ $? -ne 0 ]]; then
    echo "❌ Installation failed!"
    echo "💡 Check simulator status and try again"
    exit 1
fi

echo "✅ Installation successful!"

# Launch the app
echo "🚀 Launching app..."
xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID"

if [[ $? -ne 0 ]]; then
    echo "⚠️  Launch may have failed, but app is installed"
    echo "💡 Try launching manually from simulator home screen"
else
    echo "✅ App launched successfully!"
fi

# Return to original directory
cd - > /dev/null

echo ""
echo "🎉 Quick test completed!"
echo "📱 App should now be running on $SIMULATOR_NAME"
echo ""
echo "💡 Tips:"
echo "   📖 CRITICAL: Read ./scripts/ios/XCTest-GUIDE.md for testing instructions!"
echo "   • Use Simulator menu for device controls"
echo "   • Cmd+Shift+H for home screen"  
echo "   • FIRST: Write tests with: ./scripts/ios/automate-app-testing.sh write-test ui MyFeature"
echo "   • THEN: Run XCTests with: ./scripts/ios/automate-app-testing.sh quick-map"
echo "   • Check logs with: xcrun simctl spawn $IOS_SIMULATOR_UDID log stream"
