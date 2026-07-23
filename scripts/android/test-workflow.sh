#!/bin/bash
set -euo pipefail

echo "🚀 Testing Claude Code Workflow"
echo "📱 Starting session device..."
./scripts/android/setup-session-device.sh

export ANDROID_SERIAL=$(cat .claude-session-device | cut -d: -f2)
echo "📱 Using device: $ANDROID_SERIAL"

echo "🔨 Building app..."
(cd platforms/android && ./gradlew assembleDebug)

echo "📦 Installing app..."
APPID=$(scripts/android/get-app-id.sh)
adb -s "$ANDROID_SERIAL" install -r platforms/android/app/build/outputs/apk/debug/app-debug.apk

echo "🚀 Launching app..."
MAIN=$(adb -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$APPID" | tail -n1)

if [[ -n "$MAIN" && "$MAIN" != "No"* ]]; then
    adb -s "$ANDROID_SERIAL" shell am start -W -n "$MAIN"
    echo "✅ App launched successfully: $MAIN"
    
    adb -s "$ANDROID_SERIAL" shell screencap -p /sdcard/success.png
    adb -s "$ANDROID_SERIAL" pull /sdcard/success.png ./workflow_test_success.png
    echo "✅ Screenshot saved: workflow_test_success.png"
else
    echo "❌ Failed to launch app"
    exit 1
fi

echo "🧹 Cleaning up..."
./scripts/android/cleanup-android-device.sh && ./scripts/shared/cleanup-worktree.sh
echo "🎉 Workflow test completed successfully!"