#!/bin/bash
set -euo pipefail

# Import repository detection utility
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -f "$SCRIPT_DIR/find-git-repo.sh" ]]; then
    source "$SCRIPT_DIR/find-git-repo.sh"
else
    echo "ERROR: Cannot find find-git-repo.sh at $SCRIPT_DIR/find-git-repo.sh" >&2
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔍 Validating merge operation (v2 - Smart Path Detection)...${NC}"

# Get repository context using smart detection
get_repo_context() {
    local context_output
    if ! context_output=$(validate_repo_context 2>&1); then
        echo -e "${RED}❌ Repository detection failed:${NC}"
        echo "$context_output"
        exit 1
    fi
    
    # Parse the output to get paths
    local repo_root monorepo_root parent_dir
    repo_root=$(echo "$context_output" | grep "^REPO_ROOT=" | cut -d'=' -f2)
    monorepo_root=$(echo "$context_output" | grep "^MONOREPO_ROOT=" | cut -d'=' -f2)
    parent_dir=$(echo "$context_output" | grep "^PARENT_DIR=" | cut -d'=' -f2)
    monorepo_root="${monorepo_root:-$parent_dir}"
    
    if [[ -z "$repo_root" ]] || [[ -z "$monorepo_root" ]]; then
        echo -e "${RED}❌ Failed to parse repository context${NC}"
        exit 1
    fi
    
    echo "REPO_ROOT=$repo_root"
    echo "MONOREPO_ROOT=$monorepo_root"
    echo "PARENT_DIR=$monorepo_root"
}

# Function to validate git status before merge (runs in git repository)
check_git_status() {
    local repo_root="$1"
    
    echo -e "${YELLOW}🔍 Checking git status in: $repo_root${NC}"
    
    # Change to git repository to run git commands
    local status_output
    if ! status_output=$(cd "$repo_root" && git status --porcelain 2>&1); then
        echo -e "${RED}❌ Git status failed${NC}"
        echo "$status_output"
        return 1
    fi
    
    if [[ -n "$status_output" ]]; then
        echo -e "${RED}❌ Working directory not clean${NC}"
        echo "Please commit or stash changes before merging:"
        (cd "$repo_root" && git status --short)
        return 1
    fi
    
    echo -e "${GREEN}✅ Working directory clean${NC}"
    return 0
}

# Function to validate that current branch is main (runs in git repository)
check_current_branch() {
    local repo_root="$1"
    
    echo -e "${YELLOW}🔍 Checking current branch in: $repo_root${NC}"
    
    local current_branch
    if ! current_branch=$(cd "$repo_root" && git branch --show-current 2>&1); then
        echo -e "${RED}❌ Failed to get current branch${NC}"
        echo "$current_branch"
        return 1
    fi
    
    if [[ "$current_branch" != "main" ]]; then
        echo -e "${RED}❌ Not on main branch (currently on: $current_branch)${NC}"
        echo "Switch to main branch before merging:"
        echo "  cd $repo_root && git checkout main"
        return 1
    fi
    
    echo -e "${GREEN}✅ On main branch${NC}"
    return 0
}

# Function to validate branch exists and has commits (runs in git repository)  
validate_branch() {
    local repo_root="$1"
    local branch="$2"
    
    echo -e "${YELLOW}🔍 Validating branch in: $repo_root${NC}"
    
    # Change to git repository to run git commands
    if ! (cd "$repo_root" && git rev-parse --verify "$branch" >/dev/null 2>&1); then
        echo -e "${RED}❌ Branch '$branch' does not exist${NC}"
        return 1
    fi
    
    # Check if branch has commits ahead of main
    local ahead_count
    if ! ahead_count=$(cd "$repo_root" && git rev-list --count main.."$branch" 2>/dev/null); then
        echo -e "${RED}❌ Failed to compare branch with main${NC}"
        return 1
    fi
    
    if [[ "$ahead_count" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  Branch '$branch' has no commits ahead of main${NC}"
        echo "Nothing to merge"
        return 1
    fi
    
    echo -e "${GREEN}✅ Branch '$branch' exists with $ahead_count commits ahead${NC}"
    return 0
}

# Main validation function
main() {
    local branch="${1:-}"
    
    if [[ -z "$branch" ]]; then
        echo "Usage: $0 <branch-to-merge>"
        echo "Example: $0 claude/20250815-123440-font-fix"
        exit 1
    fi
    
    echo -e "${BLUE}Validating merge of branch: $branch${NC}"
    echo ""
    
    # Get repository context using smart detection
    echo -e "${YELLOW}🔍 Detecting repository structure...${NC}"
    local context_output
    context_output=$(get_repo_context)
    local repo_root monorepo_root
    repo_root=$(echo "$context_output" | grep "^REPO_ROOT=" | cut -d'=' -f2)
    monorepo_root=$(echo "$context_output" | grep "^MONOREPO_ROOT=" | cut -d'=' -f2)
    
    echo -e "${GREEN}✅ Repository detected:${NC}"
    echo "   Git repository: $repo_root"
    echo "   Umbrella workspace: $monorepo_root"
    echo ""
    
    # Run all validations with proper context
    check_current_branch "$repo_root" || exit 1
    check_git_status "$repo_root" || exit 1
    validate_branch "$repo_root" "$branch" || exit 1
    
    echo ""
    echo -e "${GREEN}🎉 All validations passed!${NC}"
    echo -e "${GREEN}Ready to merge branch: $branch${NC}"
    echo ""
    echo -e "${YELLOW}To perform the merge:${NC}"
    echo "   cd $repo_root"
    echo "   git merge --no-ff '$branch'"
    echo ""
    echo -e "${YELLOW}After merging, validate with:${NC}"
    echo "   cd $repo_root"
    echo "   ./scripts/shared/validate-post-merge.sh"
}

main "$@"
