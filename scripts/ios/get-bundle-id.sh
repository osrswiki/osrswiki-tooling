#!/bin/bash
set -euo pipefail

# iOS Bundle ID extraction - equivalent to Android get-app-id.sh
# Extracts the bundle identifier from the Xcode project configuration

# Ensure we're on macOS (required for iOS development)
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS development requires macOS. Current platform: $(uname)" >&2
    exit 1
fi

# Check for required tools
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "❌ xcodebuild not found. Please install Xcode Command Line Tools." >&2
    exit 1
fi

# Find the iOS project directory
IOS_PROJECT_DIR=""

# Check if we're in the iOS project directory
if [[ -f "osrswiki.xcodeproj/project.pbxproj" ]]; then
    IOS_PROJECT_DIR="."
elif [[ -f "platforms/ios/osrswiki.xcodeproj/project.pbxproj" ]]; then
    IOS_PROJECT_DIR="platforms/ios"
else
    echo "❌ Could not find osrswiki.xcodeproj" >&2
    echo "💡 Run this script from project root or iOS project directory" >&2
    exit 1
fi

# Change to iOS project directory
cd "$IOS_PROJECT_DIR"

# Method 1: Try to extract from xcodebuild project settings
BUNDLE_ID=$(xcodebuild -project osrswiki.xcodeproj -target osrswiki -showBuildSettings 2>/dev/null | \
    grep "^ *PRODUCT_BUNDLE_IDENTIFIER = " | \
    head -1 | \
    sed 's/.*= //' | \
    tr -d ' ' || echo "")

# Method 2: If that fails, try to extract from project.pbxproj directly
if [[ -z "$BUNDLE_ID" ]]; then
    BUNDLE_ID=$(grep -E "PRODUCT_BUNDLE_IDENTIFIER.*=" osrswiki.xcodeproj/project.pbxproj | \
        head -1 | \
        sed 's/.*= //' | \
        sed 's/;//' | \
        tr -d ' ' || echo "")
fi

# Method 3: If still empty, try Info.plist (though it usually contains variables)
if [[ -z "$BUNDLE_ID" ]]; then
    if [[ -f "osrswiki/osrswiki-Info.plist" ]]; then
        BUNDLE_ID=$(defaults read "$(pwd)/osrswiki/osrswiki-Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
    fi
fi

# Method 4: Fall back to hardcoded value from our project setup
if [[ -z "$BUNDLE_ID" ]] || [[ "$BUNDLE_ID" == "\$(PRODUCT_BUNDLE_IDENTIFIER)" ]]; then
    BUNDLE_ID="omiyawaki.osrswiki"
fi

# Clean up the bundle ID (remove quotes and variables)
BUNDLE_ID=$(echo "$BUNDLE_ID" | sed 's/"//g' | sed 's/\$(.*)/omiyawaki.osrswiki/')

if [[ -z "$BUNDLE_ID" ]]; then
    echo "❌ Could not determine bundle identifier" >&2
    echo "💡 Check Xcode project configuration" >&2
    exit 1
fi

echo "$BUNDLE_ID"