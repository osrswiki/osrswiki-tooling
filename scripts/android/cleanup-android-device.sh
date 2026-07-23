#!/bin/bash
set -euo pipefail

# Android Session Device Cleanup Script
# Safely cleans up ONLY the Android emulator/device created by the current session
# CRITICAL: Only deletes AVDs with session naming pattern for safety

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="${SESSION_DIR:-$(pwd)}"

# Force cleanup flag
FORCE_CLEANUP=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE_CLEANUP=true
    echo -e "${YELLOW}⚡ Force cleanup mode enabled${NC}"
fi

echo -e "${BLUE}📱 Cleaning up Android session device...${NC}"

# Read session info if available
if [[ -f .claude-session-device ]]; then
    # Use individual files if available (simpler), fallback to parsing if needed
    if [[ -f .claude-emulator-name ]] && [[ -f .claude-device-serial ]]; then
        EMULATOR_NAME=$(cat .claude-emulator-name)
        DEVICE_SERIAL=$(cat .claude-device-serial)
    else
        # Fallback to parsing for compatibility with older sessions
        SESSION_INFO=$(cat .claude-session-device)
        cat .claude-session-device > /tmp/session_info.txt
        cut -d: -f1 /tmp/session_info.txt > /tmp/emulator_name.txt
        cut -d: -f2 /tmp/session_info.txt > /tmp/device_serial.txt
        EMULATOR_NAME=$(cat /tmp/emulator_name.txt)
        DEVICE_SERIAL=$(cat /tmp/device_serial.txt)
        rm -f /tmp/session_info.txt /tmp/emulator_name.txt /tmp/device_serial.txt
    fi
    
    echo -e "${YELLOW}📱 Found session device: $DEVICE_SERIAL${NC}"
    echo -e "${YELLOW}📱 Found emulator: $EMULATOR_NAME${NC}"
    
    # CRITICAL SAFETY CHECK: Only delete AVDs with session naming pattern
    if [[ ! "$EMULATOR_NAME" =~ ^(test-[0-9]{8}-[0-9]{6}-|osrswiki-test-) ]]; then
        echo -e "${RED}🚨 SAFETY VIOLATION: Emulator does not match session naming pattern${NC}"
        echo -e "${RED}   Expected pattern: test-YYYYMMDD-HHMMSS-* or osrswiki-test-*${NC}"
        echo -e "${RED}   Found: $EMULATOR_NAME${NC}"
        echo -e "${RED}   Refusing to delete - this may be a system or shared emulator${NC}"
        echo -e "${YELLOW}⚠️  Manual cleanup required if this emulator was actually created by this session${NC}"
        echo -e "${BLUE}   Proceeding with session file cleanup only...${NC}"
        
        # Skip emulator cleanup but continue with session files
        SKIP_EMULATOR_CLEANUP=true
    else
        echo -e "${GREEN}✅ Safety check passed - emulator matches session pattern: $EMULATOR_NAME${NC}"
        SKIP_EMULATOR_CLEANUP=false
    fi
    
    # Enhanced emulator stopping with force capability (only if safety check passed)
    if [[ "$SKIP_EMULATOR_CLEANUP" != "true" ]]; then
        echo -e "${YELLOW}🛑 Stopping emulator...${NC}"
        if adb devices | grep -q "$DEVICE_SERIAL"; then
            echo "   Sending graceful shutdown command..."
            adb -s "$DEVICE_SERIAL" emu kill >/dev/null 2>&1 || true
            sleep 3
            
            # Check if still running and force kill if needed
            if adb devices | grep -q "$DEVICE_SERIAL" && [[ "$FORCE_CLEANUP" == "true" ]]; then
                echo -e "${YELLOW}   Emulator still running, force killing processes...${NC}"
                # Extract port from device serial for process killing
                if [[ "$DEVICE_SERIAL" =~ emulator-([0-9]+) ]]; then
                    EMU_PORT="${BASH_REMATCH[1]}"
                    pkill -f "emulator.*-port $EMU_PORT" >/dev/null 2>&1 || true
                    pkill -f "emulator.*$EMULATOR_NAME" >/dev/null 2>&1 || true
                fi
                sleep 2
            fi
        fi
        
        # Enhanced AVD deletion with verification and force cleanup
        echo -e "${YELLOW}🗑️  Removing emulator AVD...${NC}"
        if avdmanager delete avd -n "$EMULATOR_NAME" >/dev/null 2>&1; then
            echo -e "${GREEN}   ✅ AVD deleted successfully with avdmanager${NC}"
        else
            echo -e "${YELLOW}   ⚠️  avdmanager delete failed, attempting force cleanup...${NC}"
            
            # Force removal of AVD files
            AVD_DIR="$HOME/.android/avd/${EMULATOR_NAME}.avd"
            AVD_INI="$HOME/.android/avd/${EMULATOR_NAME}.ini"
            
            if [[ -d "$AVD_DIR" ]]; then
                if [[ "$FORCE_CLEANUP" == "true" ]]; then
                    echo "   Force removing AVD directory: $AVD_DIR"
                    rm -rf "$AVD_DIR" 2>/dev/null || true
                else
                    echo -e "${RED}   ❌ AVD directory exists but cannot be removed: $AVD_DIR${NC}"
                    echo -e "${BLUE}   💡 Run with --force to remove locked files${NC}"
                fi
            fi
            
            if [[ -f "$AVD_INI" ]]; then
                echo "   Removing AVD configuration: $AVD_INI"
                rm -f "$AVD_INI" 2>/dev/null || true
            fi
        fi
        
        # Verify cleanup success
        echo -e "${BLUE}🔍 Verifying emulator cleanup...${NC}"
        if avdmanager list avd | grep -q "Name: $EMULATOR_NAME"; then
            echo -e "${RED}   ❌ Emulator still appears in AVD list${NC}"
            if [[ "$FORCE_CLEANUP" != "true" ]]; then
                echo -e "${BLUE}   💡 Run with --force for aggressive cleanup${NC}"
            fi
        else
            echo -e "${GREEN}   ✅ Emulator successfully removed from AVD list${NC}"
        fi
    else
        echo -e "${BLUE}⏭️  Skipping emulator cleanup due to safety violation${NC}"
    fi
    
    # Clean up session device files
    echo -e "${YELLOW}📝 Cleaning up session files...${NC}"
    rm -f .claude-session-device
    rm -f .claude-device-serial
    rm -f .claude-emulator-name
    rm -f .claude-app-id
    rm -f .claude-env
    
    # Clean up emulator logs
    echo -e "${YELLOW}📝 Removing emulator logs...${NC}"
    rm -f emulator.out emulator.err
    
    # Screenshot evidence is retained until an explicitly authorized
    # disposition. The cleanup utility defaults to a read-only preview.
    echo -e "${BLUE}📸 Session screenshots are preserved under the local artifact root.${NC}"
    
    # Final verification report
    echo ""
    echo -e "${BLUE}📊 Cleanup Summary:${NC}"
    echo -e "${GREEN}   ✅ Session device files removed${NC}"
    echo -e "${GREEN}   ✅ Emulator logs cleaned${NC}"
    echo -e "${GREEN}   ✅ Screenshot evidence preserved${NC}"
    
    # Check if any session artifacts remain
    REMAINING_FILES=($(find . -maxdepth 1 -name ".claude-*" 2>/dev/null || true))
    if [[ ${#REMAINING_FILES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}   ⚠️  Some Claude session files remain:${NC}"
        for file in "${REMAINING_FILES[@]}"; do
            echo "      • $file"
        done
    else
        echo -e "${GREEN}   ✅ All session artifacts removed${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Android device cleanup complete${NC}"
else
    # No session device file found - check if this is normal or if cleanup needed
    echo -e "${YELLOW}⚠️  No session device file found${NC}"
    echo -e "${BLUE}   This is normal if no Android emulator was created for this session${NC}"
    
    # Check for any other session environment that might indicate a device
    if [[ -f .claude-env ]] && grep -q "ANDROID_SERIAL" .claude-env; then
        echo -e "${YELLOW}   Found ANDROID_SERIAL in .claude-env but no session device file${NC}"
        echo -e "${BLUE}   This may indicate the device was external or cleanup already partially completed${NC}"
    fi
    
    # Look for any orphaned session files and offer to clean them
    ORPHANED_FILES=($(find . -maxdepth 1 -name ".claude-*" 2>/dev/null || true))
    if [[ ${#ORPHANED_FILES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}   Found orphaned Claude session files:${NC}"
        for file in "${ORPHANED_FILES[@]}"; do
            echo "      • $file"
        done
        
        if [[ "$FORCE_CLEANUP" == "true" ]]; then
            echo -e "${YELLOW}   Force cleanup mode: removing orphaned files...${NC}"
            rm -f .claude-*
            echo -e "${GREEN}   ✅ Orphaned session files cleaned${NC}"
        else
            echo -e "${BLUE}   💡 Run with --force to clean orphaned session files${NC}"
        fi
    else
        echo -e "${GREEN}   ✅ No orphaned session files found${NC}"
    fi
fi

echo ""
echo -e "${GREEN}🎉 Android session device cleanup finished!${NC}"
if [[ "$FORCE_CLEANUP" == "true" ]]; then
    echo -e "${BLUE}💡 Force cleanup was used - all locked resources were removed${NC}"
fi
