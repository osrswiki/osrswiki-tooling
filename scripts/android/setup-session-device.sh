#!/bin/bash
set -euo pipefail

# Source the repository discovery utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/find-git-repo.sh"

# Environment and display detection
echo "🔍 Detecting runtime environment..."

# Detect container environment
IS_CONTAINER_ENV=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${IS_CONTAINER:-}" ]; then
    IS_CONTAINER_ENV=true
    echo "🐳 Container environment detected"
else
    echo "💻 Host environment detected"
fi

# Detect display availability for GUI
HAS_DISPLAY=false
if [ -n "${DISPLAY:-}" ] && command -v xset >/dev/null 2>&1 && xset q >/dev/null 2>&1; then
    HAS_DISPLAY=true
    echo "✅ Display available - GUI emulator will show on host"
elif [ "$IS_CONTAINER_ENV" = true ]; then
    echo "📱 No display available - running headless emulator"
else
    echo "🖥️  Running native emulator with display"
    HAS_DISPLAY=true
fi

# Android SDK path detection
if ! command -v avdmanager >/dev/null 2>&1; then
    echo "⚠️  avdmanager not found in PATH, searching for Android SDK..."
    ANDROID_PATHS=(
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
        echo "   Or set ANDROID_HOME/ANDROID_SDK_ROOT environment variable"
        exit 1
    fi
fi

# Android emulator path detection
if ! command -v emulator >/dev/null 2>&1; then
    echo "⚠️  emulator not found in PATH, searching for Android emulator..."
    EMULATOR_PATHS=(
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
        echo "   Or ensure emulator is in PATH or ANDROID_HOME/emulator directory"
        exit 1
    fi
fi

# Check for orphaned emulators before creating new session
echo "🔍 Checking for orphaned session emulators..."
if command -v avdmanager >/dev/null 2>&1; then
    ORPHANED_EMULATORS=($(avdmanager list avd | grep "Name: test-claude-" | sed 's/^.*Name: //' || true))
    SESSIONS_DIR=$(get_sessions_dir 2>/dev/null || echo "")
    ACTIVE_SESSIONS=()
    if [[ -n "$SESSIONS_DIR" && -d "$SESSIONS_DIR" ]]; then
        ACTIVE_SESSIONS=($(find "$SESSIONS_DIR" -maxdepth 1 -type d \( -name "claude-*" -o -name "codex-*" \) -exec basename {} \; 2>/dev/null || true))
    fi
    
    # Count truly orphaned emulators
    TRULY_ORPHANED=0
    if [[ ${#ORPHANED_EMULATORS[@]} -gt 0 ]]; then
        for emulator in "${ORPHANED_EMULATORS[@]}"; do
        session_name="${emulator#test-}"
        is_orphaned=true
        if [[ ${#ACTIVE_SESSIONS[@]} -gt 0 ]]; then
            for active_session in "${ACTIVE_SESSIONS[@]}"; do
                if [[ "$session_name" == "$active_session" ]]; then
                    is_orphaned=false
                    break
                fi
            done
        fi
        if [[ "$is_orphaned" == "true" ]]; then
            ((TRULY_ORPHANED++))
        fi
        done
    fi
    
    if [[ $TRULY_ORPHANED -gt 0 ]]; then
        echo "⚠️  Found $TRULY_ORPHANED orphaned emulators from previous sessions"
        echo "💡 Consider running: ./scripts/shared/cleanup-orphaned-emulators.sh"
        echo "   This will clean up orphaned emulators and improve Android Studio performance"
        echo ""
    else
        echo "✅ No orphaned emulators detected"
    fi
else
    echo "⚠️  avdmanager not available, skipping orphan check"
fi
echo ""

# Architecture and system image detection
if [ "$IS_CONTAINER_ENV" = true ]; then
    # Containers are typically x86_64 regardless of host architecture
    IMG="system-images;android-34;google_apis;x86_64"
    echo "📦 Using x86_64 system image for container"
elif [[ $(uname -m) == "arm64" ]]; then
    IMG="system-images;android-34;google_apis;arm64-v8a"
    echo "🍎 Using arm64-v8a system image for Apple Silicon"
else
    IMG="system-images;android-34;google_apis;x86_64"
    echo "🖥️  Using x86_64 system image for Intel/AMD"
fi

# Detect if we're in a session directory or create new session name
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

# Port allocation strategy
if [ "$IS_CONTAINER_ENV" = true ]; then
    # Container environment: use fixed ports (matching devcontainer.json forwarding)
    EMU_PORT=5554
    ADB_PORT=5037
    echo "🐳 Using fixed ports for container: emulator=$EMU_PORT, adb=$ADB_PORT"
else
    # Host environment: use dynamic port allocation
    pick_port() {
      for p in $(seq 5554 2 5584); do
        if ! (adb devices | grep -q "emulator-$p"); then
          echo $p; return
        fi
      done
      echo "No free emulator port" >&2; exit 1
    }
    
    EMU_PORT=$(pick_port)
    # Generate random ADB server port (macOS compatible)
    ADB_PORT=$((5037 + RANDOM % 1000))
    echo "💻 Using dynamic ports for host: emulator=$EMU_PORT, adb=$ADB_PORT"
fi

export ADB_SERVER_PORT=$ADB_PORT

echo "Starting emulator on port: $EMU_PORT"
echo "ADB server port: $ADB_SERVER_PORT"

# Start ADB server for this session
adb start-server

# Prepare emulator startup flags
EMULATOR_FLAGS="-avd $EMULATOR_NAME -port $EMU_PORT -no-snapshot-save -no-boot-anim -noaudio -wipe-data"

if [ "$IS_CONTAINER_ENV" = true ]; then
    if [ "$HAS_DISPLAY" = true ]; then
        # Container with display forwarding
        EMULATOR_FLAGS="$EMULATOR_FLAGS -gpu swiftshader_indirect"
        echo "🖥️  Starting GUI emulator in container (display forwarded to host)..."
    else
        # Container without display (headless)
        EMULATOR_FLAGS="$EMULATOR_FLAGS -gpu swiftshader_indirect -no-window -no-qt"
        echo "📱 Starting headless emulator in container..."
    fi
else
    # Native host environment
    echo "🚀 Starting native emulator with GPU acceleration..."
fi

# Start emulator
echo "Starting emulator (logs: emulator.out, emulator.err)..."
nohup emulator $EMULATOR_FLAGS >emulator.out 2>emulator.err < /dev/null &
EMULATOR_PID=$!
disown "$EMULATOR_PID" 2>/dev/null || true
echo "Emulator process: $EMULATOR_PID"

# Wait and set target
export ANDROID_SERIAL="emulator-$EMU_PORT"

# Environment-specific boot waiting
if [ "$IS_CONTAINER_ENV" = true ]; then
    echo "Waiting for container emulator to boot (this may take 2-3 minutes)..."
    BOOT_TIMEOUT=180  # Extended timeout for containers
    DEVICE_TIMEOUT=240  # Even longer for device detection
else
    echo "Waiting for emulator to boot completely..."
    BOOT_TIMEOUT=120
    DEVICE_TIMEOUT=120
fi

# Wait for device to appear and be ready
echo "Waiting for device to be detected..."
timeout=$DEVICE_TIMEOUT
while [ $timeout -gt 0 ]; do
    if adb devices | grep -q "emulator-$EMU_PORT"; then
        echo "✅ Device detected by ADB"
        break
    fi
    echo "Waiting for emulator to appear in ADB... ($timeout seconds remaining)"
    sleep 5
    timeout=$((timeout - 5))
done

if [ $timeout -le 0 ]; then
    echo "❌ Emulator failed to appear in ADB devices within timeout"
    echo "📋 Debug info:"
    adb devices
    exit 1
fi

# Wait for device to be responsive
adb -s "$ANDROID_SERIAL" wait-for-device

# Wait for system services to be ready
echo "Waiting for Android system to be ready..."
timeout=$BOOT_TIMEOUT
while [ $timeout -gt 0 ]; do
    if adb -s "$ANDROID_SERIAL" shell service list | grep -q "package" && \
       adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | grep -q "1"; then
        echo "✅ Android boot completed"
        break
    fi
    echo "Waiting for Android to finish booting... ($timeout seconds remaining)"
    sleep 3
    timeout=$((timeout - 3))
done

if [ $timeout -le 0 ]; then
    echo "⚠️  Boot timeout reached, but device may still be functional"
fi

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

echo "Device ready: $ANDROID_SERIAL"
echo "To use this device, run: export ANDROID_SERIAL=$ANDROID_SERIAL"
echo "To clean up, run: ./scripts/shared/cleanup-session-device.sh $EMULATOR_NAME $ANDROID_SERIAL"

# Save session info for cleanup
echo "$EMULATOR_NAME:$ANDROID_SERIAL" > .claude-session-device

# Save individual values for easy access (avoids complex command substitution)
echo "$ANDROID_SERIAL" > .claude-device-serial
echo "$EMULATOR_NAME" > .claude-emulator-name
echo "$ADB_SERVER_PORT" > .claude-adb-server-port

# Save app ID for easy access
./scripts/android/get-app-id.sh > .claude-app-id

# Create session environment file to eliminate command substitution completely
echo "# Claude Code session environment - source this file instead of using exports with command substitution" > .claude-env
echo "export ANDROID_SERIAL=\"$ANDROID_SERIAL\"" >> .claude-env
echo "export ADB_SERVER_PORT=\"$ADB_SERVER_PORT\"" >> .claude-env
echo "export EMULATOR_NAME=\"$EMULATOR_NAME\"" >> .claude-env
echo "export APPID=\"$(./scripts/android/get-app-id.sh)\"" >> .claude-env
echo "export IS_CONTAINER_ENV=\"$IS_CONTAINER_ENV\"" >> .claude-env
echo "export HAS_DISPLAY=\"$HAS_DISPLAY\"" >> .claude-env
echo "# Session created: $(date)" >> .claude-env

echo ""
echo "📝 Session environment saved to .claude-env"
echo "💡 Scripts can now use: source .claude-env (instead of complex exports)"
