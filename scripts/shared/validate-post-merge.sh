#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔍 Validating post-merge state...${NC}"

# The merge may be followed by a narrow reviewed fixer commit. Validate the
# newest merge reachable from HEAD rather than requiring HEAD itself to merge.
VALIDATED_MERGE_COMMIT=""

find_validated_merge() {
    VALIDATED_MERGE_COMMIT=$(git rev-list --merges -1 HEAD)
    if [[ -z "$VALIDATED_MERGE_COMMIT" ]]; then
        echo -e "${RED}❌ No merge commit is reachable from HEAD${NC}"
        return 1
    fi
}

# Function to check that the relevant operation was actually a merge.
check_merge_operation() {
    find_validated_merge || return 1

    local parent_count
    parent_count=$(git cat-file -p "$VALIDATED_MERGE_COMMIT" | grep "^parent" | wc -l)
    
    if [[ "$parent_count" -lt 2 ]]; then
        echo -e "${RED}❌ Latest merge is not a valid merge commit${NC}"
        echo "Expected: merge commit with 2+ parents"
        echo "Actual: regular commit with $parent_count parent(s)"
        return 1
    fi
    
    echo -e "${GREEN}✅ Latest merge is valid: ${VALIDATED_MERGE_COMMIT:0:8}${NC}"
    return 0
}

# Function to verify we're still on main branch
check_branch() {
    local current_branch
    current_branch=$(git branch --show-current)
    
    if [[ "$current_branch" != "main" ]]; then
        echo -e "${RED}❌ Not on main branch after merge (on: $current_branch)${NC}"
        echo "This indicates the merge operation failed"
        return 1
    fi
    
    echo -e "${GREEN}✅ Still on main branch${NC}"
    return 0
}

# Function to check that working directory is still clean
check_working_directory() {
    local status_output
    status_output=$(git status --porcelain)
    
    if [[ -n "$status_output" ]]; then
        echo -e "${YELLOW}⚠️  Working directory has changes after merge${NC}"
        echo "This may be normal if merge created conflicts that were resolved"
        git status --short
        return 0
    fi
    
    echo -e "${GREEN}✅ Working directory clean${NC}"
    return 0
}

# Function to verify no accidental resets occurred
check_no_reset() {
    local reflog_entry
    reflog_entry=$(git reflog -1 --format="%gd %gs")
    
    if echo "$reflog_entry" | grep -q "reset:"; then
        echo -e "${RED}❌ Last operation was a reset, not a merge${NC}"
        echo "This indicates the merge was immediately undone"
        echo "Last reflog entry: $reflog_entry"
        return 1
    fi
    
    echo -e "${GREEN}✅ No reset detected after merge${NC}"
    return 0
}

# Function to check for improper files in the merge
check_merge_content() {
    local merge_files
    merge_files=$(git diff --name-only "${VALIDATED_MERGE_COMMIT}^1" "$VALIDATED_MERGE_COMMIT" 2>/dev/null || echo "")
    
    # Check for agent files, session files, and root-level changes
    local improper_files=""
    
    # Agent files pattern
    improper_files+=$(echo "$merge_files" | grep "\.claude/agents/.*\.md$\|ANDROID_UI_TESTER_USAGE\.md$" || true)
    
    # Session files pattern  
    improper_files+=$(echo "$merge_files" | grep "^\.claude-.*$" || true)
    
    # Root-level files are generally disallowed, except for the repository-wide
    # policy and provenance files that are explicitly maintained at the root.
    local allowed_root_files='^(AGENTS\.md|\.gitignore|\.prose-files\.json)$'
    improper_files+=$(echo "$merge_files" | grep -v "^platforms/\|^scripts/\|^shared/\|^tools/\|^cloud/" | grep "^[^/]*$" | grep -Ev "$allowed_root_files" || true)
    
    if [[ -n "$improper_files" ]]; then
        echo -e "${RED}❌ Improper files included in merge${NC}"
        echo "Worktree changes should only modify files within: platforms/, scripts/, shared/, tools/, cloud/, or the approved root policy files"
        echo "These files should not be part of feature commits:"
        echo "$improper_files" | sort | uniq
        echo -e "${YELLOW}Consider amending the commit to remove these files${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ No improper files in merge${NC}"
    return 0
}

# Function to show merge summary
show_merge_summary() {
    echo ""
    echo -e "${BLUE}📋 Merge Summary:${NC}"
    
    local merge_commit
    merge_commit="$VALIDATED_MERGE_COMMIT"
    
    echo -e "${BLUE}Commit: ${merge_commit:0:8}${NC}"
    echo -e "${BLUE}Message:${NC}"
    git log --format="   %s" -1 "$merge_commit"
    echo ""
    
    echo -e "${BLUE}Files changed:${NC}"
    git diff --name-only "${merge_commit}^1" "$merge_commit" | sed 's/^/   /'
    echo ""
    
    echo -e "${BLUE}Commit stats:${NC}"
    git diff --stat "${merge_commit}^1" "$merge_commit" | sed 's/^/   /'
}

# Main validation function
main() {
    echo -e "${BLUE}Validating last git operation...${NC}"
    echo ""
    
    # Run all validations
    local validation_failed=0
    
    check_branch || validation_failed=1
    check_merge_operation || validation_failed=1
    check_no_reset || validation_failed=1
    check_working_directory || validation_failed=1
    check_merge_content || validation_failed=1
    
    if [[ "$validation_failed" -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}🎉 Post-merge validation passed!${NC}"
        show_merge_summary
    else
        echo ""
        echo -e "${RED}❌ Post-merge validation failed!${NC}"
        echo -e "${YELLOW}Review the issues above before proceeding${NC}"
        exit 1
    fi
}

main "$@"
