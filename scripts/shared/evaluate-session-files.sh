#!/bin/bash

# Session File Evaluator Script
# Helps identify session-specific files that should be cleaned up before merge

set -euo pipefail

# Source color utilities if available
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/color-utils.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/color-utils.sh"
else
    # Fallback color definitions
    print_header() { echo "🔍 $1"; }
    print_info() { echo "ℹ️  $1"; }
    print_success() { echo "✅ $1"; }
    print_error() { echo "❌ $1"; }
    print_warning() { echo "⚠️  $1"; }
fi

# Function to check if we're in a session directory
check_session_directory() {
    local current_dir=$(basename "$(pwd)")
    if [[ ! "$current_dir" =~ ^claude-[0-9]{8}-[0-9]{6}-.* ]]; then
        print_error "Must be run from a session worktree directory"
        print_info "Current directory: $(pwd)"
        print_info "Expected pattern: claude-YYYYMMDD-HHMMSS-<topic>"
        exit 1
    fi
}

# Function to find session-specific files for deletion
find_session_files() {
    print_header "Session File Evaluation"
    echo
    
    # Find root-level session files
    local root_session_files=()
    while IFS= read -r -d '' file; do
        root_session_files+=("$file")
    done < <(find . -maxdepth 1 -type f \( \
        -name "*.md" -o \
        -name "*.txt" -o \
        -name "*.rst" -o \
        -name "SESSION-CLAUDE.md" -o \
        -name "AGENTS.md" -o \
        -name "*.log" -o \
        -name "*.out" -o \
        -name "emulator.out" -o \
        -name ".claude-*" -o \
        -name "*DEBUG*" -o \
        -name "*TEST*" -o \
        -name "*ANALYSIS*" -o \
        -name "*SUMMARY*" -o \
        -name "setup-session*" -o \
        -name "cleanup-session*" \
    \) -print0 2>/dev/null)
    
    # Find platform-level session files
    local platform_session_files=()
    while IFS= read -r -d '' file; do
        platform_session_files+=("$file")
    done < <(find platforms/android platforms/ios -maxdepth 1 -type f \( \
        -name "*.md" -o \
        -name "*.txt" -o \
        -name "*.rst" -o \
        -name "*SETUP*" -o \
        -name "*SESSION*" -o \
        -name "*DEBUG*" -o \
        -name "*TEST*" -o \
        -name "*ANALYSIS*" -o \
        -name "organize-*" -o \
        -name "setup-*" -o \
        -name "cleanup-*" -o \
        -name "test-*.png" -o \
        -name "test-*.jpg" -o \
        -name "debug.*" \
    \) -print0 2>/dev/null)
    
    # Report findings
    if [[ ${#root_session_files[@]} -gt 0 ]]; then
        print_warning "🗑️  Root-level session files (SHOULD DELETE):"
        for file in "${root_session_files[@]}"; do
            print_warning "   $file"
        done
        echo
    fi
    
    if [[ ${#platform_session_files[@]} -gt 0 ]]; then
        print_warning "🗑️  Platform-level session files (SHOULD DELETE):"
        for file in "${platform_session_files[@]}"; do
            print_warning "   $file"
        done
        echo
    fi
    
    # Check for potentially ambiguous files (excluding documentation which is always deleted)
    local ambiguous_files=()
    while IFS= read -r -d '' file; do
        ambiguous_files+=("$file")
    done < <(find . platforms/android platforms/ios -type f \( \
        -name "*.sh" -o \
        -name "*.py" \
    \) ! \( \
        -name "*SETUP*" -o \
        -name "*DEBUG*" -o \
        -name "*TEST*" -o \
        -name "setup-*" -o \
        -name "organize-*" -o \
        -name "cleanup-*" \
    \) -print0 2>/dev/null)
    
    if [[ ${#ambiguous_files[@]} -gt 0 ]]; then
        print_info "❓ Files requiring evaluation (REVIEW NEEDED):"
        for file in "${ambiguous_files[@]}"; do
            print_info "   $file - $(get_file_guidance "$file")"
        done
        echo
    fi
    
    # Generate cleanup commands
    if [[ ${#root_session_files[@]} -gt 0 ]] || [[ ${#platform_session_files[@]} -gt 0 ]]; then
        print_header "Recommended Cleanup Commands"
        echo "# Copy and run these commands to clean up session files:"
        echo
        
        for file in "${root_session_files[@]}" "${platform_session_files[@]}"; do
            echo "rm -f \"$file\""
        done
        
        echo
        echo "# Commit cleanup:"
        echo "git add -A"
        echo "git commit -m \"chore: remove session-specific temporary files before merge"
        echo ""
        echo "Why: Clean up debugging and session files that shouldn't be in repository"
        echo "Tests: none\""
        echo
        
        return 1  # Indicate files need cleanup
    else
        print_success "✅ No session-specific files found requiring cleanup"
        return 0
    fi
}

# Function to provide guidance for specific file types
get_file_guidance() {
    local file="$1"
    case "$file" in
        *.md|*.txt|*.rst)
            echo "BLOCKED - no documentation files allowed at root/platform level"
            ;;
        *.sh)
            if [[ "$file" =~ (deploy|build|test) ]]; then
                echo "might be permanent tool"
            else
                echo "likely session-specific script"
            fi
            ;;
        *.py)
            echo "likely permanent tool or script"
            ;;
        *)
            echo "evaluate purpose"
            ;;
    esac
}

# Function to show help
show_help() {
    echo "Session File Evaluator"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --help, -h     Show this help message"
    echo "  --dry-run      Show what would be cleaned up without making changes"
    echo
    echo "Description:"
    echo "  Identifies session-specific temporary files that should be removed"
    echo "  before merging to prevent repository contamination."
    echo
    echo "Exit codes:"
    echo "  0  No session files need cleanup"
    echo "  1  Session files found that need cleanup"
    echo "  2  Invalid arguments or not in session directory"
}

# Main execution
main() {
    # Check arguments
    if [[ $# -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_help
        exit 0
    fi
    
    # Validate environment
    check_session_directory
    
    # Find and report session files
    find_session_files
}

# Run main function
main "$@"
