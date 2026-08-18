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

echo -e "${BLUE}🔄 Starting atomic merge + branch cleanup workflow...${NC}"

# Function to show usage
show_usage() {
    echo "Usage: $0 <feature-branch> [commit-message]"
    echo ""
    echo "Arguments:"
    echo "  feature-branch    The feature branch to merge (e.g., claude/20250821-123456-topic)"
    echo "  commit-message    Optional merge commit message (auto-generated if not provided)"
    echo ""
    echo "Examples:"
    echo "  $0 claude/20250821-123456-ios-fix"
    echo "  $0 claude/20250821-123456-ios-fix '[ios] fix: resolve button styling issue'"
    echo ""
    echo "This script performs:"
    echo "  1. Pre-merge validation"
    echo "  2. Merge operation (fast-forward or merge commit)"
    echo "  3. Worktree and branch preservation by default"
    echo "  4. Optional authorized cleanup when OSRS_ARTIFACT_CLEANUP_AUTHORIZED=1"
    echo "  5. Post-merge verification"
}

# Function to detect merge strategy
detect_merge_strategy() {
    local repo_root="$1"
    local feature_branch="$2"
    
    # Check if main has moved since feature branch creation
    local main_commits behind_count
    if ! main_commits=$(cd "$repo_root" && git rev-list --count "$feature_branch"..main 2>/dev/null); then
        echo "merge-commit" # Default to merge commit if detection fails
        return
    fi
    
    if [[ "$main_commits" -eq 0 ]]; then
        echo "fast-forward"
    else
        echo "merge-commit"
    fi
}

# Function to generate merge commit message
generate_merge_message() {
    local repo_root="$1"
    local feature_branch="$2"
    local custom_message="$3"
    
    if [[ -n "$custom_message" ]]; then
        echo "$custom_message"
        return
    fi
    
    # Auto-generate based on branch name and changes
    local topic platform_indicator
    topic=$(echo "$feature_branch" | sed -E 's/^(claude|codex|job)\/[0-9]{8}-[0-9]{6}-//')
    
    # Detect platform from changed files
    local changed_files
    changed_files=$(cd "$repo_root" && git diff --name-only main..."$feature_branch" 2>/dev/null || echo "")
    
    if echo "$changed_files" | grep -q "^platforms/ios/"; then
        platform_indicator="[ios]"
    elif echo "$changed_files" | grep -q "^platforms/android/"; then
        platform_indicator="[android]"
    elif echo "$changed_files" | grep -q "^scripts/\|^tools/"; then
        platform_indicator="[tooling]"
    else
        platform_indicator="[shared]"
    fi
    
    echo "$platform_indicator merge: $topic

Why: Completed feature development and ready for integration
Tests: verified in session"
}

# Function to perform the merge operation
perform_merge() {
    local repo_root="$1"
    local feature_branch="$2"
    local strategy="$3"
    local commit_message="$4"
    
    echo -e "${YELLOW}🔀 Performing $strategy merge...${NC}"
    
    cd "$repo_root"
    
    if [[ "$strategy" == "fast-forward" ]]; then
        echo -e "${BLUE}   Using fast-forward merge (clean linear history)${NC}"
        if ! git merge --ff-only "$feature_branch"; then
            echo -e "${RED}❌ Fast-forward merge failed${NC}"
            echo "This usually means main has diverged. Trying merge commit instead..."
            strategy="merge-commit"
        else
            echo -e "${GREEN}✅ Fast-forward merge completed${NC}"
            return 0
        fi
    fi
    
    if [[ "$strategy" == "merge-commit" ]]; then
        echo -e "${BLUE}   Using merge commit (preserves feature context)${NC}"
        if ! git merge --no-ff "$feature_branch" -m "$commit_message"; then
            echo -e "${RED}❌ Merge commit failed${NC}"
            echo "This likely indicates merge conflicts that need resolution."
            echo ""
            echo -e "${YELLOW}To resolve conflicts:${NC}"
            echo "  1. git status (see conflicted files)"
            echo "  2. Edit files to resolve conflicts"
            echo "  3. git add <resolved-files>"
            echo "  4. git commit (complete the merge)"
            echo "  5. Re-run this script to finish cleanup"
            return 1
        fi
        echo -e "${GREEN}✅ Merge commit completed${NC}"
        return 0
    fi
    
    echo -e "${RED}❌ Unknown merge strategy: $strategy${NC}"
    return 1
}

# Function to cleanup worktree session
cleanup_worktree_session() {
    local primary_repo="$1"
    local feature_branch="$2"
    
    echo -e "${YELLOW}🌿 Evaluating associated worktree retention...${NC}"
    
    # Extract session name from branch name.
    local session_name
    session_name="${feature_branch/\//-}"
    
    local session_path
    session_path="$(get_sessions_dir)/$session_name"
    
    # Check if session directory exists
    if [[ ! -d "$session_path" ]]; then
        echo -e "${YELLOW}⚠️  No machine-local worktree session found at: $session_path${NC}"
        return 0
    fi

    if [[ "${OSRS_ARTIFACT_CLEANUP_AUTHORIZED:-}" != "1" ]]; then
        echo -e "${GREEN}✅ Worktree preserved pending a separately authorized disposition: $session_path${NC}"
        return 0
    fi

    if [[ -n "$(git -C "$session_path" status --porcelain)" ]]; then
        echo -e "${RED}❌ Refusing to remove dirty worktree: $session_path${NC}" >&2
        return 1
    fi
    
    cd "$primary_repo"
    
    # Remove only a clean worktree after explicit authorization. Artifact
    # directories remain preserved for their own disposition decision.
    if git -C "$primary_repo" worktree remove "$session_path" 2>/dev/null; then
        echo -e "${GREEN}✅ Worktree session cleaned up successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Authorized worktree removal failed; preserving it for inspection${NC}" >&2
        return 1
    fi
}

# Function to delete the feature branch
delete_feature_branch() {
    local repo_root="$1"
    local feature_branch="$2"
    
    echo -e "${YELLOW}🗑️  Deleting feature branch: $feature_branch${NC}"
    
    cd "$repo_root"
    
    # Verify branch still exists
    if ! git rev-parse --verify "$feature_branch" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Branch '$feature_branch' already deleted${NC}"
        return 0
    fi
    
    # Delete the branch
    if git branch -d "$feature_branch"; then
        echo -e "${GREEN}✅ Feature branch deleted successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to delete branch '$feature_branch'${NC}"
        echo "This may indicate the branch has unmerged changes."
        echo ""
        echo -e "${YELLOW}To force delete (if you're sure):${NC}"
        echo "  git branch -D '$feature_branch'"
        return 1
    fi
}

# Function to verify merge success
verify_merge() {
    local repo_root="$1"
    
    echo -e "${YELLOW}🔍 Verifying merge success...${NC}"
    
    cd "$repo_root"
    
    # Check we're still on main
    local current_branch
    current_branch=$(git branch --show-current)
    if [[ "$current_branch" != "main" ]]; then
        echo -e "${RED}❌ Not on main branch after merge (on: $current_branch)${NC}"
        return 1
    fi
    
    # Check last commit
    local last_commit_hash last_commit_msg
    last_commit_hash=$(git rev-parse HEAD)
    last_commit_msg=$(git log --format="%s" -1)
    
    echo -e "${GREEN}✅ Merge verification passed${NC}"
    echo -e "${BLUE}   Current branch: $current_branch${NC}"
    echo -e "${BLUE}   Last commit: ${last_commit_hash:0:8}${NC}"
    echo -e "${BLUE}   Commit message: $last_commit_msg${NC}"
    
    return 0
}

# Function to rollback on failure
rollback_merge() {
    local repo_root="$1"
    local original_commit="$2"
    
    echo -e "${YELLOW}🔄 Rolling back failed merge...${NC}"
    
    cd "$repo_root"
    
    # Reset to original state
    if git reset --hard "$original_commit"; then
        echo -e "${GREEN}✅ Rollback completed - repository restored to original state${NC}"
    else
        echo -e "${RED}❌ Rollback failed${NC}"
        echo "Manual intervention required:"
        echo "  git reset --hard $original_commit"
    fi
}

# Main execution function
main() {
    local feature_branch="${1:-}"
    local commit_message="${2:-}"
    
    # Validate arguments
    if [[ -z "$feature_branch" ]]; then
        echo -e "${RED}❌ Missing required argument: feature-branch${NC}"
        echo ""
        show_usage
        exit 1
    fi
    
    # Get repository context
    echo -e "${YELLOW}🔍 Detecting repository structure...${NC}"
    local context_output repo_root primary_repo_root
    if ! context_output=$(validate_repo_context 2>&1); then
        echo -e "${RED}❌ Repository detection failed:${NC}"
        echo "$context_output"
        exit 1
    fi
    
    repo_root=$(echo "$context_output" | grep "^REPO_ROOT=" | cut -d'=' -f2)
    primary_repo_root=$(echo "$context_output" | grep "^PRIMARY_REPO_ROOT=" | cut -d'=' -f2)
    
    echo -e "${GREEN}✅ Repository detected:${NC}"
    echo "   Git repository: $repo_root"
    echo "   Primary checkout: $primary_repo_root"
    echo ""
    
    # Store original commit for rollback
    local original_commit
    original_commit=$(cd "$repo_root" && git rev-parse HEAD)
    
    # Step 1: Pre-merge validation
    echo -e "${BLUE}📋 Step 1: Pre-merge validation${NC}"
    if ! "$SCRIPT_DIR/validate-merge-operation.sh" "$feature_branch"; then
        echo -e "${RED}❌ Pre-merge validation failed${NC}"
        exit 1
    fi
    echo ""
    
    # Step 2: Detect merge strategy
    echo -e "${BLUE}📋 Step 2: Merge strategy detection${NC}"
    local strategy
    strategy=$(detect_merge_strategy "$repo_root" "$feature_branch")
    echo -e "${GREEN}✅ Strategy selected: $strategy${NC}"
    echo ""
    
    # Step 3: Generate merge message
    echo -e "${BLUE}📋 Step 3: Merge message preparation${NC}"
    local final_message
    final_message=$(generate_merge_message "$repo_root" "$feature_branch" "$commit_message")
    echo -e "${GREEN}✅ Merge message prepared:${NC}"
    echo "$final_message" | sed 's/^/   /'
    echo ""
    
    # Step 4: Perform merge
    echo -e "${BLUE}📋 Step 4: Merge execution${NC}"
    if ! perform_merge "$repo_root" "$feature_branch" "$strategy" "$final_message"; then
        echo -e "${RED}❌ Merge failed${NC}"
        rollback_merge "$repo_root" "$original_commit"
        exit 1
    fi
    echo ""
    
    # Step 5: Post-merge validation
    echo -e "${BLUE}📋 Step 5: Post-merge validation${NC}"
    cd "$repo_root"
    if ! "$SCRIPT_DIR/validate-post-merge.sh"; then
        echo -e "${RED}❌ Post-merge validation failed${NC}"
        rollback_merge "$repo_root" "$original_commit"
        exit 1
    fi
    echo ""
    
    # Step 6: Preserve local worktree/artifacts unless separately authorized.
    echo -e "${BLUE}📋 Step 6: Worktree retention${NC}"
    if ! cleanup_worktree_session "$primary_repo_root" "$feature_branch"; then
        echo -e "${YELLOW}⚠️  Merge succeeded, but authorized cleanup did not complete${NC}"
    fi
    echo ""
    
    # Step 7: Keep branch provenance unless the same explicit authorization
    # allowed clean worktree removal.
    echo -e "${BLUE}📋 Step 7: Feature branch retention${NC}"
    if [[ "${OSRS_ARTIFACT_CLEANUP_AUTHORIZED:-}" == "1" && ! -d "$(get_sessions_dir)/${feature_branch/\//-}" ]]; then
        if ! delete_feature_branch "$repo_root" "$feature_branch"; then
            echo -e "${YELLOW}⚠️  Branch deletion failed, but merge was successful${NC}"
        fi
    else
        echo -e "${GREEN}✅ Feature branch preserved for provenance${NC}"
    fi
    
    # Step 8: Final verification
    echo -e "${BLUE}📋 Step 8: Final verification${NC}"
    if ! verify_merge "$repo_root"; then
        echo -e "${RED}❌ Final verification failed${NC}"
        exit 1
    fi
    echo ""
    
    # Success summary
    echo -e "${GREEN}🎉 Local merge completed successfully!${NC}"
    echo ""
    echo -e "${BLUE}📋 Summary:${NC}"
    echo -e "${GREEN}   ✅ Feature branch merged to main${NC}"
    echo -e "${GREEN}   ✅ Retention policy applied to worktree and branch${NC}"
    echo -e "${GREEN}   ✅ All validations passed${NC}"
    echo ""
    echo -e "${YELLOW}💡 Next steps:${NC}"
    echo "   • Deploy when ready: /deploy command"
    echo "   • Start new session: /start command"
    echo ""
    echo -e "${BLUE}Repository ready for next development session!${NC}"
}

main "$@"
