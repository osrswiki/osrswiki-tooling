#!/bin/bash

# Directory Contamination Protection Script
# Validates that merge operations don't pollute root or platform directories with temporary files

set -euo pipefail

# Import repository detection utility
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -f "$SCRIPT_DIR/find-git-repo.sh" ]]; then
    source "$SCRIPT_DIR/find-git-repo.sh"
else
    echo "ERROR: Cannot find find-git-repo.sh at $SCRIPT_DIR/find-git-repo.sh" >&2
    exit 1
fi

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

# Function to validate branch exists (runs in git repository)
validate_branch() {
    local repo_root="$1"
    local branch_name="$2"
    if ! (cd "$repo_root" && git rev-parse --verify "$branch_name" >/dev/null 2>&1); then
        print_error "Branch '$branch_name' does not exist"
        exit 1
    fi
}

# Function to get files that would be added to root (runs in git repository)
get_root_additions() {
    local repo_root="$1"
    local target_branch="$2"
    local base_branch="${3:-main}"
    
    # Get files that would be added to root directory (not in subdirectories)
    (cd "$repo_root" && git diff --name-only --diff-filter=A "$base_branch...$target_branch") | \
        grep -E '^[^/]+$' | \
        grep -v -E '^(\.gitignore|CLAUDE\.md)$' || true
}

# Function to get files that would be modified in root (runs in git repository)
get_root_modifications() {
    local repo_root="$1"
    local target_branch="$2" 
    local base_branch="${3:-main}"
    
    # Get files that would be modified in root directory
    (cd "$repo_root" && git diff --name-only --diff-filter=M "$base_branch...$target_branch") | \
        grep -E '^[^/]+$' || true
}

# Function to categorize files by extension/type
categorize_files() {
    local files=("$@")
    
    # Use regular variables instead of associative arrays for compatibility
    local debug_files=""
    local test_files=""
    local screenshot_files=""
    local analysis_files=""
    local script_files=""
    local other_files=""
    
    for file in "${files[@]}"; do
        case "$file" in
            # Debug/analysis documentation
            *ANALYSIS* | *DEBUG* | *TEST_* | *TESTING* | *MANUAL_TEST* | *RESULTS* | *SUMMARY*)
                analysis_files+="$file "
                ;;
            # Test scripts and files
            test_* | *_test.* | test.* | *Test.* | demonstration.* | demo.*)
                test_files+="$file "
                ;;  
            # Screenshots
            *.png | *.jpg | *.jpeg | *.gif | after-* | current-* | final-* | ios_* | app-*)
                screenshot_files+="$file "
                ;;
            # Debug logs
            *.log | *.out | *_logs.* | debug_* | emulator.*)
                debug_files+="$file "
                ;;
            # Scripts
            *.sh | *.py | *.js | *.swift | click_* | navigate_* | tap_*)
                script_files+="$file "
                ;;
            *)
                other_files+="$file "
                ;;
        esac
    done
    
    # Print categorization
    [[ -n "${debug_files// }" ]] && print_warning "🔍 Debug files: $debug_files"
    [[ -n "${test_files// }" ]] && print_warning "🧪 Test files: $test_files"
    [[ -n "${screenshot_files// }" ]] && print_warning "📸 Screenshots: $screenshot_files"
    [[ -n "${analysis_files// }" ]] && print_warning "📊 Analysis docs: $analysis_files"
    [[ -n "${script_files// }" ]] && print_warning "📜 Scripts: $script_files"
    [[ -n "${other_files// }" ]] && print_warning "❓ Other files: $other_files"
}

# Function to check directories being added (runs in git repository)
get_root_directories() {
    local repo_root="$1"
    local target_branch="$2"
    local base_branch="${3:-main}"
    
    # Get directories that would be added to root, excluding essential ones
    (cd "$repo_root" && git diff --name-only --diff-filter=A "$base_branch...$target_branch") | \
        grep -E '^[^/]+/' | \
        sed 's|/.*||' | \
        sort -u | \
        grep -v -E '^(platforms|shared|scripts|tools|cloud|screenshots)$' || true
}

# Function to check for platform-specific contamination (runs in git repository)
get_platform_contamination() {
    local repo_root="$1"
    local target_branch="$2"
    local base_branch="${3:-main}"
    
    # Check for problematic files being added to platform directories
    (cd "$repo_root" && git diff --name-only --diff-filter=A "$base_branch...$target_branch") | \
        grep -E '^platforms/(android|ios)/[^/]+\.(md|txt|log|png|jpg|jpeg|sh)$' || true
}

# Function to categorize platform contamination files
categorize_platform_files() {
    local files=("$@")
    local session_docs=""
    local debug_files=""
    local scripts=""
    local screenshots=""
    local other_files=""
    
    for file in "${files[@]}"; do
        case "$file" in
            *.md)
                if [[ "$file" =~ (SESSION|SETUP|README|ANALYSIS|SUMMARY|TEST) ]]; then
                    session_docs+="$file "
                else
                    other_files+="$file "
                fi
                ;;
            *.sh)
                if [[ "$file" =~ (setup|cleanup|organize|session) ]]; then
                    scripts+="$file "
                else
                    other_files+="$file "
                fi
                ;;
            *.png|*.jpg|*.jpeg)
                screenshots+="$file "
                ;;
            *.log|*.txt)
                debug_files+="$file "
                ;;
            *)
                other_files+="$file "
                ;;
        esac
    done
    
    # Print categorization
    [[ -n "${session_docs// }" ]] && print_warning "📝 Session docs: $session_docs"
    [[ -n "${debug_files// }" ]] && print_warning "🔍 Debug files: $debug_files"
    [[ -n "${scripts// }" ]] && print_warning "📜 Session scripts: $scripts"
    [[ -n "${screenshots// }" ]] && print_warning "📸 Screenshots: $screenshots"
    [[ -n "${other_files// }" ]] && print_warning "❓ Other files: $other_files"
}

# Main validation function
validate_root_directory() {
    local repo_root="$1"
    local target_branch="$2"
    local base_branch="${3:-main}"
    
    print_header "Directory Contamination Protection Check"
    print_info "Repository: $repo_root"
    print_info "Checking branch: $target_branch"
    print_info "Against base: $base_branch"
    echo
    
    # Get additions (using portable array assignment)
    local root_additions_text
    root_additions_text=$(get_root_additions "$repo_root" "$target_branch" "$base_branch")
    local root_additions=()
    if [[ -n "$root_additions_text" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && root_additions+=("$line")
        done <<< "$root_additions_text"
    fi
    
    local root_directories_text
    root_directories_text=$(get_root_directories "$repo_root" "$target_branch" "$base_branch")
    local root_directories=()
    if [[ -n "$root_directories_text" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && root_directories+=("$line")
        done <<< "$root_directories_text"
    fi
    
    local root_modifications_text  
    root_modifications_text=$(get_root_modifications "$repo_root" "$target_branch" "$base_branch")
    local root_modifications=()
    if [[ -n "$root_modifications_text" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && root_modifications+=("$line")
        done <<< "$root_modifications_text"
    fi
    
    # Check for platform contamination
    local platform_contamination_text
    platform_contamination_text=$(get_platform_contamination "$repo_root" "$target_branch" "$base_branch")
    local platform_contamination=()
    if [[ -n "$platform_contamination_text" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && platform_contamination+=("$line")
        done <<< "$platform_contamination_text"
    fi
    
    # Check if there are any problematic additions
    if [[ ${#root_additions[@]} -gt 0 ]] || [[ ${#root_directories[@]} -gt 0 ]] || [[ ${#platform_contamination[@]} -gt 0 ]]; then
        print_error "🚨 MERGE BLOCKED: Directory Contamination Detected!"
        echo
        
        if [[ ${#root_additions[@]} -gt 0 ]]; then
            print_warning "📄 Files being added to root directory:"
            categorize_files "${root_additions[@]}"
            echo
        fi
        
        if [[ ${#root_directories[@]} -gt 0 ]]; then
            print_warning "📁 Directories being added to root:"
            for dir in "${root_directories[@]}"; do
                print_warning "   $dir/"
            done
            echo
        fi
        
        if [[ ${#platform_contamination[@]} -gt 0 ]]; then
            print_warning "📱 Platform directory contamination detected:"
            categorize_platform_files "${platform_contamination[@]}"
            echo
            print_warning "🚨 Platform directories should only contain source code and legitimate assets!"
            print_warning "   Problematic: session docs, debug files, temporary scripts, test screenshots"
            print_warning "   Examples of contamination: platforms/ios/SETUP.md, platforms/android/debug.log"
            echo
        fi
        
        print_error "🎯 REQUIRED ACTION:"
        echo "You must decide for each file/directory:"
        echo
        echo "1. 📁 KEEP & ORGANIZE: If useful for general purposes or app functionality"
        echo "   → Move to appropriate subdirectory (tools/, shared/, etc.)"
        echo "   → Examples: privacy-policy.html → shared/legal/"
        echo
        echo "2. 📦 ROUTE LOCALLY: If temporary, reproducible, or heavyweight"
        echo "   → Use scripts/shared/local-artifact-root.sh; deletion requires separate authorization"
        echo
        echo "3. 💡 COMMON PATTERNS:"
        echo "   → Debug/analysis output → verified local artifact root"
        echo "   → Reusable test scripts → move to tools/testing/"
        echo "   → Screenshots → verified local artifact root"
        echo "   → Privacy/legal docs → shared/legal/"
        echo
        echo "After cleanup/organization, run /merge again."
        echo
        print_warning "🚫 Root directory should only contain essential directories:"
        print_warning "   platforms/, shared/, scripts/, tools/, cloud/"
        
        return 1
    fi
    
    # Show allowed modifications if any
    if [[ ${#root_modifications[@]} -gt 0 ]]; then
        print_info "✅ Allowed modifications to existing root files:"
        for file in "${root_modifications[@]}"; do
            print_info "   $file"
        done
        echo
    fi
    
    print_success "✅ Directory contamination protection check passed!"
    print_info "No problematic files detected in root or platform directories."
    
    return 0
}

# Function to show help
show_help() {
    echo "Directory Contamination Protection Validator"
    echo
    echo "Usage: $0 <target-branch> [base-branch]"
    echo
    echo "Arguments:"
    echo "  target-branch    Branch to validate (e.g., claude/20250820-feature)"
    echo "  base-branch      Base branch to compare against (default: main)"
    echo
    echo "Examples:"
    echo "  $0 claude/20250820-090701-js-modules-cleanup"
    echo "  $0 feature-branch main"
    echo
    echo "Exit codes:"
    echo "  0  No directory contamination detected"
    echo "  1  Directory contamination detected - merge should be blocked"
    echo "  2  Invalid arguments or repository state"
}

# Main execution
main() {
    # Check arguments
    if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_help
        exit 2
    fi
    
    local target_branch="$1"
    local base_branch="${2:-main}"
    
    # Get repository context using smart detection
    print_info "🔍 Detecting repository structure..."
    local context_output
    if ! context_output=$(validate_repo_context 2>&1); then
        print_error "Repository detection failed:"
        echo "$context_output"
        exit 2
    fi
    
    # Parse the output to get paths
    local repo_root parent_dir
    repo_root=$(echo "$context_output" | grep "^REPO_ROOT=" | cut -d'=' -f2)
    parent_dir=$(echo "$context_output" | grep "^PARENT_DIR=" | cut -d'=' -f2)
    
    print_success "Repository detected:"
    print_info "   Git repository: $repo_root"
    print_info "   Parent directory: $parent_dir"
    echo
    
    # Validate branches exist in git repository
    validate_branch "$repo_root" "$target_branch"
    validate_branch "$repo_root" "$base_branch"
    
    # Perform validation
    validate_root_directory "$repo_root" "$target_branch" "$base_branch"
}

# Run main function
main "$@"
