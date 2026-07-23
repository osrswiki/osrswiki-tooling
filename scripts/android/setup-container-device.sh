#!/bin/bash
set -euo pipefail

# Container-optimized Android emulator setup
# Uses fixed ports matching devcontainer.json port forwarding
# No random port allocation for predictable container networking

echo "🐳 Setting up Android emulator for container environment..."

# Android SDK path detection
if ! command -v avdmanager >/dev/null 2>&1; then
    echo "⚠️  avdmanager not found in PATH, searching for Android SDK..."
    ANDROID_PATHS=(
        "/opt/android-sdk/cmdline-tools/latest/bin"
        "$HOME/Library/Android/sdk/cmdline-tools/latest/bin"
        "$HOME/Android/Sdk/cmdline-tools/latest/bin"
        "/usr/local/share/android-sdk/cmdline-tools/latest/bin"
    )
    for path in "${ANDROID_PATHS[@]}"; do
        if [[ -f "$path/avdmanager" ]]; then
            echo "✅ Found Android SDK at: $path"
            export PATH="$path:$PATH"
            break
        fi
    done
    if ! command -v avdmanager >/dev/null 2>&1; then
        echo "❌ Android SDK not found. Please install Android SDK and add avdmanager to PATH"
        exit 1
    fi
fi

# Android emulator path detection
if ! command -v emulator >/dev/null 2>&1; then
    echo "⚠️  emulator not found in PATH, searching for Android emulator..."
    EMULATOR_PATHS=(
        "/opt/android-sdk/emulator"
        "$HOME/Library/Android/sdk/emulator"
        "$HOME/Android/Sdk/emulator"
        "/usr/local/share/android-sdk/emulator"
    )
    for path in "${EMULATOR_PATHS[@]}"; do
        if [[ -f "$path/emulator" ]]; then
            echo "✅ Found Android emulator at: $path"
            export PATH="$path:$PATH"
            break
        fi
    done
    if ! command -v emulator >/dev/null 2>&1; then
        echo "❌ Android emulator not found. Please install Android SDK emulator"
        exit 1
    fi
fi

# Container environment: Use x86_64 system image (containers are typically x86_64)
IMG="system-images;android-34;google_apis;x86_64"

# Detect session name from current directory
CURRENT_DIR=$(basename "$(pwd)")
if [[ "$CURRENT_DIR" =~ ^claude-[0-9]{8}-[0-9]{6} ]]; then
    SESSION_NAME="$CURRENT_DIR"
    echo "📁 Using existing session: $SESSION_NAME"
else
    SESSION_NAME="claude-$(date +%Y%m%d-%H%M%S)"
    echo "📁 Creating new session: $SESSION_NAME"
fi
EMULATOR_NAME="test-$SESSION_NAME"

echo "Creating emulator: $EMULATOR_NAME"
avdmanager create avd -n "$EMULATOR_NAME" -k "$IMG" -d "pixel_4" -f

# Container environment: Use fixed ports (matching devcontainer.json forwarding)
EMU_PORT=5554  # Fixed port for container
ADB_PORT=5037  # Standard ADB port (also forwarded in devcontainer.json)

echo "Using fixed emulator port: $EMU_PORT (container environment)"
echo "Using standard ADB port: $ADB_PORT"

# Set ADB server port
export ADB_SERVER_PORT=$ADB_PORT

# Kill any existing ADB server to ensure clean state
adb kill-server 2>/dev/null || true

# Start ADB server for this session
adb start-server

# Start emulator with container-optimized settings
echo "Starting emulator (logs: emulator.out, emulator.err)..."
emulator -avd "$EMULATOR_NAME" -port "$EMU_PORT" \
  -no-snapshot-save -no-boot-anim -noaudio -wipe-data \
  -gpu swiftshader_indirect -no-window -verbose >emulator.out 2>emulator.err &
disown

# Set target device
export ANDROID_SERIAL="emulator-$EMU_PORT"

echo "Waiting for emulator to start (this may take 2-3 minutes in container)..."

# Wait for device to appear in adb devices
timeout=180  # Extended timeout for containers
while [ $timeout -gt 0 ]; do
    if adb devices | grep -q "emulator-$EMU_PORT"; then
        echo "Emulator detected by ADB"
        break
    fi
    echo "Waiting for emulator to appear in ADB... ($timeout seconds remaining)"
    sleep 5
    timeout=$((timeout - 5))
done

if [ $timeout -le 0 ]; then
    echo "❌ Emulator failed to appear in ADB devices within timeout"
    echo "📋 Debug info:"
    echo "ADB devices:"
    adb devices
    echo "Emulator processes:"
    ps aux | grep emulator || true
    exit 1
fi

# Wait for device to be ready
echo "Waiting for device to be ready..."
adb -s "$ANDROID_SERIAL" wait-for-device

# Wait for system services to be ready
timeout=120
while [ $timeout -gt 0 ]; do
    if adb -s "$ANDROID_SERIAL" shell service list | grep -q "package" && \
       adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | grep -q "1"; then
        echo "Android boot completed"
        break
    fi
    echo "Waiting for Android to finish booting... ($timeout seconds remaining)"
    sleep 3
    timeout=$((timeout - 3))
done

# Additional wait for package manager
echo "Waiting for package manager to be ready..."
timeout=60
while [ $timeout -gt 0 ]; do
    if adb -s "$ANDROID_SERIAL" shell pm list packages >/dev/null 2>&1; then
        echo "Package manager ready"
        break
    fi
    echo "Waiting for package manager... ($timeout seconds remaining)"
    sleep 2
    timeout=$((timeout - 2))
done

echo "✅ Container device ready: $ANDROID_SERIAL"
echo "To use this device, run: export ANDROID_SERIAL=$ANDROID_SERIAL"
echo "To clean up, run: ./cleanup-session-device.sh $EMULATOR_NAME $ANDROID_SERIAL"

# Save session info for cleanup
echo "$EMULATOR_NAME:$ANDROID_SERIAL" > .claude-session-device

# Save individual values for easy access
echo "$ANDROID_SERIAL" > .claude-device-serial
echo "$EMULATOR_NAME" > .claude-emulator-name

# Save app ID for easy access
./scripts/android/get-app-id.sh > .claude-app-id

# Create session environment file
echo "# Claude Code container session environment" > .claude-env
echo "export ANDROID_SERIAL=\"$ANDROID_SERIAL\"" >> .claude-env
echo "export EMULATOR_NAME=\"$EMULATOR_NAME\"" >> .claude-env
echo "export APPID=\"$(./scripts/android/get-app-id.sh)\"" >> .claude-env
echo "export IS_CONTAINER=true" >> .claude-env
echo "# Container session created: $(date)" >> .claude-env

echo ""
echo "📝 Container session environment saved to .claude-env"
echo "💡 Use: source .claude-env to load environment variables"
echo "🐳 Container-optimized setup complete!"