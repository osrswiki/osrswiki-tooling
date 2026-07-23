#!/bin/bash
set -euo pipefail
echo "🚀 Starting Claude Code session..."
./setup-session-device.sh
export ANDROID_SERIAL=$(cat .claude-session-device | cut -d: -f2)
echo "✅ Session ready! Device: $ANDROID_SERIAL"
echo "💡 To use: export ANDROID_SERIAL=$ANDROID_SERIAL"