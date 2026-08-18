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

echo -e "${BLUE}🧹 OSRS Wiki - Orphaned Session Emulator Cleanup${NC}"
echo "This script removes all session emulators that are no longer connected to active worktree sessions."
echo ""

# Check if avdmanager is available
if ! command -v avdmanager >/dev/null 2>&1; then
    echo -e "${RED}❌ avdmanager not found in PATH${NC}"
    echo "Please ensure Android SDK is installed and avdmanager is in your PATH"
    exit 1
fi

# Dry run flag
DRY_RUN=false
FORCE_CLEANUP=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}🔍 DRY RUN MODE - No changes will be made${NC}"
    echo ""
elif [[ "${1:-}" == "--force" ]]; then
    FORCE_CLEANUP=true
    echo -e "${YELLOW}⚡ FORCE MODE - Will force-remove locked emulators${NC}"
    echo ""
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [--dry-run|--force|--help]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be cleaned without making changes"
    echo "  --force      Force removal of locked or problematic emulators"
    echo "  --help       Show this help message"
    echo ""
    echo "This script identifies and removes orphaned session emulators:"
    echo "  • Session emulators not connected to active worktree sessions"
    echo "  • AVD directories and configuration files"
    echo "  • Running emulator processes (with confirmation)"
    exit 0
fi

# Find all session emulators
echo -e "${BLUE}🔍 Scanning for session emulators...${NC}"
SESSION_EMULATORS=($(avdmanager list avd | grep "Name: test-claude-" | sed 's/^.*Name: //' || true))

if [[ ${#SESSION_EMULATORS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ No session emulators found - system is clean!${NC}"
    exit 0
fi

echo -e "${YELLOW}📱 Found ${#SESSION_EMULATORS[@]} session emulators:${NC}"
for emulator in "${SESSION_EMULATORS[@]}"; do
    echo "   • $emulator"
done
echo ""

# Find active worktree sessions (dynamically discover sessions directory)
SESSIONS_DIR=$(get_sessions_dir 2>/dev/null || echo "")
ACTIVE_SESSIONS=()
if [[ -n "$SESSIONS_DIR" && -d "$SESSIONS_DIR" ]]; then
    ACTIVE_SESSIONS=($(find "$SESSIONS_DIR" -maxdepth 1 -type d \( -name "claude-*" -o -name "codex-*" -o -name "job-*" -o -name "agent-*" \) -exec basename {} \; 2>/dev/null || true))
fi

echo -e "${BLUE}🌿 Active worktree sessions: ${#ACTIVE_SESSIONS[@]}${NC}"
if [[ ${#ACTIVE_SESSIONS[@]} -gt 0 ]]; then
    for session in "${ACTIVE_SESSIONS[@]}"; do
        echo "   • $session"
    done
fi
echo ""

# Identify orphaned emulators
ORPHANED_EMULATORS=()
PROTECTED_EMULATORS=()

for emulator in "${SESSION_EMULATORS[@]}"; do
    # Extract session name from emulator name (remove "test-" prefix)
    session_name="${emulator#test-}"
    
    # Check if corresponding worktree session exists
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
        ORPHANED_EMULATORS+=("$emulator")
    else
        PROTECTED_EMULATORS+=("$emulator")
    fi
done

echo -e "${GREEN}🛡️  Protected emulators (active sessions): ${#PROTECTED_EMULATORS[@]}${NC}"
if [[ ${#PROTECTED_EMULATORS[@]} -gt 0 ]]; then
    for emulator in "${PROTECTED_EMULATORS[@]}"; do
        echo "   • $emulator (session active)"
    done
fi

echo ""
echo -e "${YELLOW}🗑️  Orphaned emulators to remove: ${#ORPHANED_EMULATORS[@]}${NC}"
if [[ ${#ORPHANED_EMULATORS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ No orphaned emulators found - cleanup not needed!${NC}"
    exit 0
fi

for emulator in "${ORPHANED_EMULATORS[@]}"; do
    echo "   • $emulator"
done
echo ""

# Check for running orphaned emulators
echo -e "${BLUE}🔍 Checking for running emulator processes...${NC}"
RUNNING_EMULATORS=()
for emulator in "${ORPHANED_EMULATORS[@]}"; do
    # Check if emulator is running by looking for its process
    if adb devices | grep -q "emulator.*$emulator" || pgrep -f "emulator.*$emulator" >/dev/null 2>&1; then
        RUNNING_EMULATORS+=("$emulator")
    fi
done

if [[ ${#RUNNING_EMULATORS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  Found ${#RUNNING_EMULATORS[@]} running orphaned emulators:${NC}"
    for emulator in "${RUNNING_EMULATORS[@]}"; do
        echo "   • $emulator"
    done
    echo ""
fi

# Dry run summary
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}📋 DRY RUN SUMMARY:${NC}"
    echo "   • ${#ORPHANED_EMULATORS[@]} orphaned emulators would be removed"
    echo "   • ${#RUNNING_EMULATORS[@]} running emulators would be stopped"
    echo "   • ${#PROTECTED_EMULATORS[@]} active emulators would be preserved"
    echo ""
    echo -e "${BLUE}💡 Run without --dry-run to perform cleanup${NC}"
    exit 0
fi

# Confirm cleanup action
echo -e "${RED}⚠️  WARNING: This will permanently remove ${#ORPHANED_EMULATORS[@]} orphaned emulators${NC}"
echo "This action cannot be undone."
echo ""
if [[ ${#RUNNING_EMULATORS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Note: ${#RUNNING_EMULATORS[@]} running emulators will be stopped first.${NC}"
    echo ""
fi

read -p "Are you sure you want to proceed? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo -e "${YELLOW}🚫 Cleanup cancelled by user${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}🧹 Starting cleanup process...${NC}"

# Stop running emulators first
if [[ ${#RUNNING_EMULATORS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}🛑 Stopping running orphaned emulators...${NC}"
    for emulator in "${RUNNING_EMULATORS[@]}"; do
        echo "   Stopping $emulator..."
        
        # Try graceful shutdown first
        if adb devices | grep -q "emulator.*$emulator"; then
            adb -s "emulator-${emulator##*-}" emu kill >/dev/null 2>&1 || true
        fi
        
        # Force kill processes if needed
        if [[ "$FORCE_CLEANUP" == "true" ]]; then
            pkill -f "emulator.*$emulator" >/dev/null 2>&1 || true
        fi
        
        sleep 1
    done
    echo -e "${GREEN}✅ Stopped running emulators${NC}"
fi

# Remove orphaned emulators
echo -e "${YELLOW}🗑️  Removing orphaned emulators...${NC}"
CLEANUP_ERRORS=()
CLEANUP_SUCCESS=()

for emulator in "${ORPHANED_EMULATORS[@]}"; do
    echo "   Removing $emulator..."
    
    # Try to delete AVD using avdmanager
    if avdmanager delete avd -n "$emulator" >/dev/null 2>&1; then
        CLEANUP_SUCCESS+=("$emulator")
    else
        echo -e "${YELLOW}     ⚠️  avdmanager failed, trying force cleanup...${NC}"
        
        # Force removal of AVD directory and files
        AVD_DIR="$HOME/.android/avd/${emulator}.avd"
        AVD_INI="$HOME/.android/avd/${emulator}.ini"
        
        if [[ -d "$AVD_DIR" ]]; then
            if [[ "$FORCE_CLEANUP" == "true" ]]; then
                rm -rf "$AVD_DIR" 2>/dev/null || true
            else
                CLEANUP_ERRORS+=("$emulator (AVD directory locked)")
                continue
            fi
        fi
        
        if [[ -f "$AVD_INI" ]]; then
            rm -f "$AVD_INI" 2>/dev/null || true
        fi
        
        CLEANUP_SUCCESS+=("$emulator (force cleaned)")
    fi
done

echo ""
echo -e "${BLUE}📊 Cleanup Results:${NC}"
echo -e "${GREEN}✅ Successfully removed: ${#CLEANUP_SUCCESS[@]} emulators${NC}"
if [[ ${#CLEANUP_SUCCESS[@]} -gt 0 ]]; then
    for emulator in "${CLEANUP_SUCCESS[@]}"; do
        echo "   • $emulator"
    done
fi

if [[ ${#CLEANUP_ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}⚠️  Cleanup issues: ${#CLEANUP_ERRORS[@]} emulators${NC}"
    for error in "${CLEANUP_ERRORS[@]}"; do
        echo "   • $error"
    done
    echo ""
    echo -e "${BLUE}💡 Run with --force to remove locked emulators${NC}"
fi

# Verify cleanup
echo ""
echo -e "${BLUE}🔍 Verifying cleanup...${NC}"
REMAINING_SESSION_EMULATORS=($(avdmanager list avd | grep "Name: test-claude-" | sed 's/^.*Name: //' || true))

if [[ ${#REMAINING_SESSION_EMULATORS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ All session emulators removed successfully!${NC}"
elif [[ ${#REMAINING_SESSION_EMULATORS[@]} -eq ${#PROTECTED_EMULATORS[@]} ]]; then
    echo -e "${GREEN}✅ Only protected emulators remain (${#REMAINING_SESSION_EMULATORS[@]} active sessions)${NC}"
else
    echo -e "${YELLOW}⚠️  ${#REMAINING_SESSION_EMULATORS[@]} session emulators still present${NC}"
    echo "This may include protected emulators from active sessions:"
    for emulator in "${REMAINING_SESSION_EMULATORS[@]}"; do
        if [[ " ${PROTECTED_EMULATORS[@]} " =~ " $emulator " ]]; then
            echo "   • $emulator (protected - active session)"
        else
            echo "   • $emulator (cleanup may have failed)"
        fi
    done
fi

echo ""
echo -e "${GREEN}🎉 Orphaned emulator cleanup complete!${NC}"
echo ""
echo -e "${BLUE}💡 Future Prevention:${NC}"
echo "   • Use '/clean' or '/merge' commands to properly end sessions"
echo "   • Run this script periodically to maintain clean emulator list"
echo "   • Check the verified local sessions root with: scripts/shared/local-artifact-root.sh sessions"
