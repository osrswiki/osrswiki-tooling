#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Source the repository discovery utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/find-git-repo.sh"

echo -e "${BLUE}🧹 Releasing session runtime resources...${NC}"

# Force cleanup flag
FORCE_CLEANUP=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE_CLEANUP=true
    echo -e "${YELLOW}⚡ Force cleanup mode enabled${NC}"
fi

# Detect session type and clean up appropriately
session_cleaned=false

# Clean up Android device if we're in an Android session
if [[ -f .claude-session-device ]]; then
    echo -e "${YELLOW}📱 Detected Android session, cleaning up device...${NC}"
    if [[ "$FORCE_CLEANUP" == "true" ]]; then
        ./scripts/android/cleanup-android-device.sh --force
    else
        ./scripts/android/cleanup-android-device.sh
    fi
    session_cleaned=true
fi

# Clean up iOS simulator if we're in an iOS session
if [[ -f .simulator-lease.json || -f .ios-env || -f .claude-session-simulator ]]; then
    echo -e "${YELLOW}📱 Detected iOS session, cleaning up simulator...${NC}"
    if [[ "$FORCE_CLEANUP" == "true" ]]; then
        ./scripts/ios/cleanup-session-simulator.sh --force 2>/dev/null || ./scripts/ios/cleanup-session-simulator.sh
    else
        ./scripts/ios/cleanup-session-simulator.sh
    fi
    session_cleaned=true
fi

# Check for orphaned session files if no specific session was detected
if [[ "$session_cleaned" == "false" ]]; then
    echo -e "${YELLOW}🔍 No active session detected, checking for orphaned files...${NC}"
    
    ORPHANED_FILES=($(find . -maxdepth 1 \( -name ".claude-*" -o -name ".ios-env" -o -name ".simulator-lease.json" \) 2>/dev/null || true))
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

# Preserve the worktree unless a separately authorized disposition explicitly
# invokes cleanup-worktree.sh --delete.
echo -e "${YELLOW}🌿 Preserving worktree and local evidence...${NC}"
./scripts/shared/cleanup-worktree.sh

# Optional: Check for system-wide orphaned emulators
echo ""
echo -e "${BLUE}🔍 Checking for system-wide orphaned emulators...${NC}"
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
        echo -e "${YELLOW}   ⚠️  Found $TRULY_ORPHANED orphaned emulators system-wide${NC}"
        echo -e "${BLUE}   💡 Run: ./scripts/shared/cleanup-orphaned-emulators.sh${NC}"
    else
        echo -e "${GREEN}   ✅ No orphaned emulators found system-wide${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠️  avdmanager not available, skipping emulator check${NC}"
fi

echo ""
echo -e "${GREEN}✅ Session runtime resources released; worktree and evidence preserved${NC}"
if [[ "$FORCE_CLEANUP" == "true" ]]; then
    echo -e "${BLUE}💡 Force cleanup was used - all locked resources were removed${NC}"
fi
