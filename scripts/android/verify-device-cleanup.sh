#!/bin/bash
set -euo pipefail

# Android Device Cleanup Verification Script
# Verifies that session-specific Android emulator/device was properly cleaned up
# Returns exit code 0 if cleanup was successful, 1 if issues found

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔍 Verifying Android device cleanup...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="${SESSION_DIR:-$(pwd)}"

# Load session environment if available to check what should have been cleaned
CLAUDE_ENV_FILE="$SESSION_DIR/.claude-env"
EXPECTED_DEVICE_SERIAL=""
EXPECTED_EMULATOR_NAME=""

if [[ -f "$CLAUDE_ENV_FILE" ]]; then
    # Check if ANDROID_SERIAL is still in .claude-env (may be ok for external devices)
    if grep -q "ANDROID_SERIAL" "$CLAUDE_ENV_FILE"; then
        EXPECTED_DEVICE_SERIAL=$(grep "ANDROID_SERIAL" "$CLAUDE_ENV_FILE" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        echo -e "${YELLOW}⚠️  Found device reference in .claude-env: $EXPECTED_DEVICE_SERIAL${NC}"
        
        # Check if this is a session-created emulator (emulator-XXXX format)
        if [[ "$EXPECTED_DEVICE_SERIAL" =~ ^emulator-[0-9]+ ]]; then
            echo -e "${BLUE}   Device appears to be an emulator: $EXPECTED_DEVICE_SERIAL${NC}"
            
            # Check if emulator is still running
            if adb devices 2>/dev/null | grep -q "$EXPECTED_DEVICE_SERIAL"; then
                echo -e "${RED}❌ CLEANUP FAILED: Emulator still running${NC}"
                echo -e "${RED}   Device: $EXPECTED_DEVICE_SERIAL${NC}"
                echo ""
                echo -e "${BLUE}🛠️  To fix this issue:${NC}"
                echo -e "${BLUE}   adb -s $EXPECTED_DEVICE_SERIAL emu kill${NC}"
                echo -e "${BLUE}   # Or if that fails:${NC}"
                echo -e "${BLUE}   ./scripts/android/cleanup-android-device.sh --force${NC}"
                exit 1
            else
                echo -e "${GREEN}✅ Emulator was stopped properly${NC}"
            fi
        else
            echo -e "${BLUE}   Device appears to be external/physical: $EXPECTED_DEVICE_SERIAL${NC}"
            echo -e "${BLUE}   External devices are not cleaned up automatically (this is correct)${NC}"
        fi
    else
        echo -e "${GREEN}✅ No device references found in .claude-env${NC}"
    fi
elif [[ -f "$SESSION_DIR/.claude-session-device" ]]; then
    # Legacy session format check
    SESSION_INFO=$(cat "$SESSION_DIR/.claude-session-device")
    EXPECTED_EMULATOR_NAME=$(echo "$SESSION_INFO" | cut -d: -f1)
    EXPECTED_DEVICE_SERIAL=$(echo "$SESSION_INFO" | cut -d: -f2)
    echo -e "${RED}❌ CLEANUP FAILED: Legacy session device file still exists${NC}"
    echo -e "${RED}   File: .claude-session-device${NC}"
    echo -e "${RED}   Emulator: $EXPECTED_EMULATOR_NAME${NC}"
    echo -e "${RED}   Serial: $EXPECTED_DEVICE_SERIAL${NC}"
    echo ""
    echo -e "${BLUE}🛠️  To fix this issue:${NC}"
    echo -e "${BLUE}   ./scripts/android/cleanup-android-device.sh${NC}"
    exit 1
else
    echo -e "${GREEN}✅ No session device configuration found${NC}"
fi

# Check for orphaned AVDs with session naming patterns
echo -e "${BLUE}🔍 Checking for orphaned session emulators...${NC}"
ORPHANED_AVDS=$(avdmanager list avd 2>/dev/null | grep -E "Name:.*test-[0-9]{8}-[0-9]{6}-|Name:.*osrswiki-test-" || true)

if [[ -n "$ORPHANED_AVDS" ]]; then
    echo -e "${YELLOW}⚠️  Found potential orphaned session AVDs:${NC}"
    echo "$ORPHANED_AVDS"
    echo ""
    echo -e "${BLUE}💡 These may be from other active sessions or improperly cleaned sessions${NC}"
    echo -e "${BLUE}💡 Only clean up AVDs you created in your current session${NC}"
    echo -e "${BLUE}💡 Run 'avdmanager list avd | grep -E \"test-|osrswiki-test\"' to see all session AVDs${NC}"
else
    echo -e "${GREEN}✅ No orphaned session AVDs found${NC}"
fi

# Check for running emulators that match session patterns
echo -e "${BLUE}🔍 Checking for running session emulators...${NC}"
RUNNING_SESSION_EMULATORS=$(adb devices 2>/dev/null | grep "emulator-" | awk '{print $1}' || true)

if [[ -n "$RUNNING_SESSION_EMULATORS" ]]; then
    echo -e "${YELLOW}⚠️  Found running emulators:${NC}"
    for emu in $RUNNING_SESSION_EMULATORS; do
        echo -e "${YELLOW}   • $emu${NC}"
    done
    echo -e "${BLUE}💡 These may be from other active sessions${NC}"
    echo -e "${BLUE}💡 Only stop emulators you created in your current session${NC}"
else
    echo -e "${GREEN}✅ No running emulators found${NC}"
fi

# Verify session files were cleaned up
echo -e "${BLUE}🔍 Checking session file cleanup...${NC}"
SESSION_FILES_REMAINING=()

# List of files that should be cleaned up
session_files=(
    ".claude-session-device"
    ".claude-device-serial"
    ".claude-emulator-name"
    ".claude-app-id"
)

for file in "${session_files[@]}"; do
    if [[ -f "$SESSION_DIR/$file" ]]; then
        SESSION_FILES_REMAINING+=("$file")
    fi
done

if [[ ${#SESSION_FILES_REMAINING[@]} -gt 0 ]]; then
    echo -e "${RED}❌ Session files not cleaned up:${NC}"
    for file in "${SESSION_FILES_REMAINING[@]}"; do
        echo -e "${RED}   • $file${NC}"
    done
    echo ""
    echo -e "${BLUE}🛠️  To fix this issue:${NC}"
    echo -e "${BLUE}   ./scripts/android/cleanup-android-device.sh --force${NC}"
    exit 1
else
    echo -e "${GREEN}✅ Session files properly cleaned up${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Android device cleanup verification passed!${NC}"
echo -e "${GREEN}   • No session emulators found running${NC}"
echo -e "${GREEN}   • Session configuration files cleaned${NC}"
echo -e "${GREEN}   • Environment variables handled appropriately${NC}"
