#!/bin/bash
set -euo pipefail

# OSRS Wiki Git-Based Privacy Policy Deployment Script
# Updates the verified host-local osrswiki-privacy-policy deployment checkout
# with the public landing README only. Does not wipe privacy-policy.html,
# index.html, or .github Pages workflow content.

# Source color utilities (auto-detects Claude Code environment)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/color-utils.sh"
source "$SCRIPT_DIR/find-git-repo.sh"

# Error handling function for better debugging
handle_error() {
    local exit_code=$?
    local line_number=$1
    print_error "🚨 Script failed at line $line_number with exit code $exit_code"
    echo "Command that failed: ${BASH_COMMAND}"
    echo "Working directory: $(pwd)"
    echo "Script phase: $CURRENT_PHASE"
    exit $exit_code
}

# Set up error trap
trap 'handle_error $LINENO' ERR

# Initialize phase tracking
CURRENT_PHASE="Initialization"

print_header "🔒 OSRS Wiki Git-Based Privacy Policy Deployment"
echo "Date: $(date)"
echo ""

# Resolve the active Fleet Sync checkout or an assigned worktree.
CURRENT_PHASE="Directory Structure Validation"
if ! GIT_ROOT="$(find_git_repo "$(pwd)")" || [[ ! -f "$GIT_ROOT/AGENTS.md" ]]; then
    print_error "Must run from an OSRS Wiki Fleet Sync checkout or assigned worktree"
    echo "Current directory: $(pwd)"
    exit 1
fi
PROJECT_ROOT="$GIT_ROOT"
print_success "Using source checkout: $GIT_ROOT"

if [[ ! -f "$GIT_ROOT/docs/public-landing/README.privacy-policy.md" ]]; then
    print_error "Privacy landing template missing: docs/public-landing/README.privacy-policy.md"
    exit 1
fi

# Phase 1: Setup deployment environment
CURRENT_PHASE="Deployment Environment Setup"
print_phase "🏗️  Phase 1: Deployment Environment Setup"
echo "-------------------------------------"

DEPLOY_ROOT="$(osrs_init_local_deployment_root)"
DEPLOY_PRIVACY="$DEPLOY_ROOT/osrswiki-privacy-policy"
MONOREPO_ROOT="$PROJECT_ROOT"

# Ensure deployment directory exists
if [[ ! -d "$DEPLOY_PRIVACY" ]]; then
    print_info "📁 Creating deployment repository..."
    mkdir -p "$(dirname "$DEPLOY_PRIVACY")"
    cd "$(dirname "$DEPLOY_PRIVACY")"
    git clone --depth 1 --branch main --single-branch https://github.com/osrswiki/osrswiki-privacy-policy.git
    cd "$PROJECT_ROOT"
fi

# Validate deployment repo
if [[ ! -d "$DEPLOY_PRIVACY/.git" ]]; then
    print_error "Deployment repository is not a valid git repo: $DEPLOY_PRIVACY"
    exit 1
fi

print_success "Deployment environment ready"

# Phase 2: Update deployment repository content (README only)
CURRENT_PHASE="Update Deployment Content"
print_phase "📦 Phase 2: Update Deployment Content"
echo "-----------------------------------"

cd "$DEPLOY_PRIVACY"
print_info "Working in deployment repository: $DEPLOY_PRIVACY"

# Fetch latest changes to ensure we're up to date
print_info "Fetching latest remote changes..."
git fetch origin main
git reset --hard origin/main

# Create deployment branch for safety
DEPLOY_BRANCH="deploy-$(date +%Y%m%d-%H%M%S)"
print_info "Creating deployment branch: $DEPLOY_BRANCH"
git checkout -b "$DEPLOY_BRANCH"

# Preserve Pages / HTML content: do NOT clear the tree. Only install landing README.
print_info "Installing public landing README for privacy-policy (preserving HTML/Pages)..."
"$GIT_ROOT/scripts/shared/osrs-public-landing.sh" install \
  --target privacy-policy \
  --dest "$PWD" \
  --landing-root "$GIT_ROOT/docs/public-landing"

# Guard: Pages sources must still exist after install
for required in privacy-policy.html index.html .github; do
    if [[ ! -e "$required" ]]; then
        print_error "Required privacy Pages path missing after landing install: $required"
        print_error "Refusing to commit a broken privacy-policy tree."
        exit 1
    fi
done

# Landing helper must not emit LICENSE for privacy-policy
if [[ -f LICENSE ]]; then
    print_warning "Unexpected LICENSE present in privacy-policy tree; leaving as-is (helper should not add one)"
fi

# Stage all changes (README.md only expected)
git add -A

# Create deployment commit if there are changes
if ! git diff --cached --quiet; then
    DEPLOY_COMMIT_MSG="Merge deployment: privacy-policy landing README
- Public pointer README for privacy Pages repo
- Preserves privacy-policy.html / index.html / .github Pages workflow"

    git commit -m "$DEPLOY_COMMIT_MSG"
    print_success "Deployment commit created"

    print_phase "📋 Deployment Summary:"
    git show --stat HEAD
else
    print_info "ℹ️  No changes to deploy"
    git checkout main
    git branch -d "$DEPLOY_BRANCH"
    cd "$PROJECT_ROOT"
    exit 0
fi

# Phase 3: Push to remote (same flattened merge style as sibling projectors)
CURRENT_PHASE="Push to Remote"
print_phase "🚀 Phase 3: Push to Remote"
echo "------------------------"

DEPLOY_COMMITS=$(git rev-list --count HEAD)
if [[ "$DEPLOY_COMMITS" -lt 1 ]]; then
    print_error "🚨 CRITICAL SAFETY CHECK FAILED"
    echo "Deployment repository has no commits"
    echo "This suggests a serious error in deployment preparation."
    exit 1
fi

print_success "Safety check passed: $DEPLOY_COMMITS commits"

print_info "Pushing to remote..."
if git push origin "$DEPLOY_BRANCH" --force-with-lease; then
    print_success "Deployment branch pushed successfully"

    # Flatten onto main via ff-only merge (same as android/ios/tooling)
    git checkout main
    git merge "$DEPLOY_BRANCH" --ff-only
    git push origin main

    # Clean up deployment branch
    git branch -d "$DEPLOY_BRANCH"
    git push origin --delete "$DEPLOY_BRANCH"

    print_success "🎉 Privacy-policy deployment completed successfully!"
else
    print_error "Push failed - remote may have been updated"
    echo "Fix conflicts and try again"
    exit 1
fi

# Phase 4: Final validation
print_phase "✅ Phase 4: Post-deployment Validation"
echo "--------------------------------"

REMOTE_COMMITS=$(git ls-remote origin main | cut -f1)
LOCAL_COMMITS=$(git rev-parse HEAD)

if [[ "$REMOTE_COMMITS" == "$LOCAL_COMMITS" ]]; then
    print_success "Remote and local are synchronized"
else
    print_warning " Remote and local commits differ"
    echo "This may indicate a deployment issue - investigate"
fi

cd "$PROJECT_ROOT"

echo ""
print_success "🎊 Git-Based Privacy Policy Deployment Complete!"
echo "================================================="
echo "Deployment repository: $DEPLOY_PRIVACY"
echo "Remote commits: $DEPLOY_COMMITS"
echo ""
print_phase "Deployed components:"
echo "- ✅ README.md from docs/public-landing (pointer landing)"
echo "- ✅ privacy-policy.html / index.html preserved"
echo "- ✅ .github Pages workflow preserved"
echo "- ❌ LICENSE not published (privacy Pages repo; not GPL code tree)"
echo ""
print_phase "Next steps:"
echo "- Verify deployment at: https://github.com/osrswiki/osrswiki-privacy-policy"
echo "- Confirm Pages still serves: https://osrswiki.github.io/osrswiki-privacy-policy/"

exit 0
