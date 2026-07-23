#!/bin/bash
set -euo pipefail

# Auto-source session environment to avoid command substitution and permission dialogs
if [[ -f .claude-env ]]; then
    source .claude-env
elif [[ -f .claude-session-device ]]; then
    echo "❌ Old session format. Please recreate session to use improved environment handling."
    exit 1
else
    echo "❌ No active session. Run ./scripts/create-worktree-session.sh first"
    exit 1
fi

echo "🔨 Quick build and test on device: $ANDROID_SERIAL"

(cd platforms/android && ./gradlew assembleDebug)
adb -s "$ANDROID_SERIAL" install -r platforms/android/app/build/outputs/apk/debug/app-debug.apk
MAIN=$(adb -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$APPID" | tail -n1)
adb -s "$ANDROID_SERIAL" shell am start -W -n "$MAIN"
echo "✅ Quick test completed!"