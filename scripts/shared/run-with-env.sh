#!/bin/bash
# Wrapper script to run commands with session environment variables automatically loaded
# Usage: ./run-with-env.sh adb install app.apk
#    or: ./run-with-env.sh gradle build
#    or: ./run-with-env.sh echo "Device: $ANDROID_SERIAL"

# Source session environments if they exist
if [[ -f .ios-env ]]; then
    source .ios-env
fi

if [[ -f .claude-env ]]; then
    source .claude-env
else
    # Fallback to reading individual files if they exist
    if [[ -f .claude-device-serial ]]; then
        export ANDROID_SERIAL=$(cat .claude-device-serial)
    fi
    if [[ -f .claude-emulator-name ]]; then
        export EMULATOR_NAME=$(cat .claude-emulator-name)
    fi
    if [[ -f .claude-app-id ]]; then
        export APPID=$(cat .claude-app-id)
    fi
fi

# Execute the provided command with the loaded environment
exec "$@"
