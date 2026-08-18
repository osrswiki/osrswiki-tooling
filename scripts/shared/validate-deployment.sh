#!/bin/bash
set -euo pipefail

# OSRS Wiki Deployment Validation Script
# Comprehensive checks before any deployment operation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=find-git-repo.sh
source "$SCRIPT_DIR/find-git-repo.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PLATFORM="${1:-}"
if [[ -z "$PLATFORM" ]]; then
    echo -e "${RED}❌ Usage: $0 <platform>${NC}"
    echo "  Platforms: android, ios, tooling"
    exit 1
fi

echo -e "${BLUE}🔍 OSRS Wiki Deployment Validation for: $PLATFORM${NC}"
echo "=================================================="

# Resolve the active Fleet Sync checkout or an assigned worktree.
if ! GIT_ROOT="$(find_git_repo "$(pwd)")" || [[ ! -f "$GIT_ROOT/AGENTS.md" ]]; then
    echo -e "${RED}❌ Error: Must run from an OSRS Wiki Fleet Sync checkout or assigned worktree${NC}"
    echo "Current directory: $(pwd)"
    exit 1
fi
PROJECT_ROOT="$GIT_ROOT"

VALIDATION_ERRORS=0

# Function to report validation error
validation_error() {
    echo -e "${RED}❌ VALIDATION ERROR: $1${NC}"
    ((++VALIDATION_ERRORS))
}

# Function to report validation warning
validation_warning() {
    echo -e "${YELLOW}⚠️  VALIDATION WARNING: $1${NC}"
}

# Function to report validation success
validation_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

echo -e "${YELLOW}📋 Phase 1: Repository Structure Validation${NC}"
echo "-------------------------------------------"

# Change to git root for git operations
cd "$GIT_ROOT"

# Check that we're not inside a worktree
if [[ -f ".git" ]] && grep -q "gitdir:" ".git" 2>/dev/null; then
    validation_error "Cannot deploy from inside a git worktree"
    echo "Run deployment from the primary Fleet Sync checkout"
fi

# Check for clean working directory
if ! git diff --quiet || ! git diff --cached --quiet; then
    validation_error "Working directory is not clean"
    echo "Commit or stash your changes before deployment"
    echo "Run from: $GIT_ROOT"
fi

# Check that we're on main branch for deployment
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    validation_warning "Not on main branch (currently on: $CURRENT_BRANCH)"
    echo "Consider switching to main branch for stable deployments"
fi

# Platform-specific validations
echo -e "${YELLOW}📋 Phase 2: Platform-Specific Validation${NC}"
echo "----------------------------------------"

case "$PLATFORM" in
    "android")
        # Check Android platform directory exists (we're now in git root)
        if [[ ! -d "platforms/android" ]]; then
            validation_error "Android platform directory not found at $GIT_ROOT/platforms/android"
        else
            validation_success "Android platform directory found"
        fi
        
        # Check for Android build files
        if [[ ! -f "platforms/android/build.gradle.kts" && ! -f "platforms/android/build.gradle" ]]; then
            validation_error "Android build configuration not found (looking for build.gradle.kts or build.gradle)"
        else
            validation_success "Android build configuration found"
        fi
        
        # Check for important Android files that should be included
        if [[ ! -f "platforms/android/app/src/main/AndroidManifest.xml" ]]; then
            validation_error "Android manifest not found"
        else
            validation_success "Android manifest found"
        fi
        ;;
        
    "ios")
        # Check iOS platform directory exists (we're now in git root)
        if [[ ! -d "platforms/ios" ]]; then
            validation_error "iOS platform directory not found at $GIT_ROOT/platforms/ios"
        else
            validation_success "iOS platform directory found"
        fi
        
        # Check for iOS project files
        if [[ ! -f "platforms/ios/osrswiki.xcodeproj/project.pbxproj" ]]; then
            validation_warning "iOS Xcode project may not be properly configured"
        else
            validation_success "iOS Xcode project found"
        fi
        
        # iOS build validation (quality gate)
        echo -e "${BLUE}ℹ️  Validating iOS build capability...${NC}"
        cd platforms/ios
        if xcodebuild -project osrswiki.xcodeproj -scheme osrswiki -sdk iphonesimulator -quiet build >/dev/null 2>&1; then
            validation_success "iOS project builds successfully for simulator"
            echo "  💡 Non-hanging build validation approach used"
        else
            validation_warning "iOS project build failed - check for compilation errors"
            echo "  🔧 Fix compilation errors before deployment"
            echo "  💡 For enhanced testing: ./scripts/ios/test-non-hanging.sh"
        fi
        cd "$GIT_ROOT"
        ;;
        
    "tooling")
        # For tooling, we deploy the entire repo, so check key components
        if [[ ! -d "tools" ]]; then
            validation_warning "Tools directory not found at $GIT_ROOT/tools - tooling deployment may be incomplete"
        else
            validation_success "Tools directory found"
        fi
        
        if [[ ! -d "scripts" ]]; then
            validation_error "Scripts directory not found at $GIT_ROOT/scripts - critical for tooling deployment"
        else
            validation_success "Scripts directory found"
        fi
        ;;
        
    *)
        validation_error "Unknown platform: $PLATFORM"
        echo "Supported platforms: android, ios, tooling"
        ;;
esac

# Check shared components that should be integrated (we're in git root)
echo -e "${YELLOW}📋 Phase 3: Shared Components Validation${NC}"
echo "---------------------------------------"

if [[ -d "shared" ]]; then
    validation_success "Shared components directory found at $GIT_ROOT/shared"
    
    # Check for important shared components
    for component in css js README.md asset-mapping.json; do
        if [[ -d "shared/$component" || -f "shared/$component" ]]; then
            validation_success "Shared $component found"
        else
            validation_warning "Shared $component not found"
        fi
    done
else
    validation_warning "Shared components directory not found at $GIT_ROOT/shared"
fi

MAP_ASSET_MANIFEST="shared/manifests/osrs-map-assets-v1.json"
MAP_ASSET_FETCHER="scripts/shared/fetch-map-release-assets.sh"
PUBLIC_TREE_VALIDATOR="scripts/shared/validate-public-deployment-tree.sh"

if [[ -x "$MAP_ASSET_FETCHER" ]]; then
    validation_success "Map release downloader/verifier is executable"
else
    validation_error "Map release downloader/verifier is missing or not executable: $MAP_ASSET_FETCHER"
fi

if [[ -f "$MAP_ASSET_MANIFEST" && -x "$MAP_ASSET_FETCHER" ]]; then
    if "$MAP_ASSET_FETCHER" validate-manifest "$MAP_ASSET_MANIFEST" >/dev/null; then
        validation_success "Immutable map release manifest is valid"
    else
        validation_error "Immutable map release manifest is invalid: $MAP_ASSET_MANIFEST"
    fi
elif [[ ! -f "$MAP_ASSET_MANIFEST" ]]; then
    validation_error "Immutable map release manifest not found: $MAP_ASSET_MANIFEST"
fi

if [[ -x "$PUBLIC_TREE_VALIDATOR" ]]; then
    validation_success "Public deployment tree guard is executable"
else
    validation_error "Public deployment tree guard is missing or not executable: $PUBLIC_TREE_VALIDATOR"
fi

# Git remote validation
echo -e "${YELLOW}📋 Phase 4: Security Architecture Validation${NC}"
echo "----------------------------------------"

# The source checkout must use only the private Fleet Sync authority. Public
# deployment remotes belong only to the separate deployment checkouts.
DEPLOYMENT_REMOTES=("android" "ios" "tooling")
FOUND_DEPLOYMENT_REMOTES=()

for remote in "${DEPLOYMENT_REMOTES[@]}"; do
    if git remote | grep -q "^${remote}$"; then
        FOUND_DEPLOYMENT_REMOTES+=("$remote")
    fi
done

if [[ ${#FOUND_DEPLOYMENT_REMOTES[@]} -gt 0 ]]; then
    validation_error "Security violation: deployment remotes found in main monorepo"
    echo "Found remotes: ${FOUND_DEPLOYMENT_REMOTES[*]}"
    echo "Remove with: git remote remove <remote-name>"
    echo "AGENTS.md requires zero-access deployment architecture"
else
    validation_success "No public deployment remotes are configured on the source checkout"
fi

EXPECTED_SOURCE_REMOTE="https://github.com/omiyawaki/osrswiki-fleet.git"
SOURCE_REMOTE="$(git remote get-url origin 2>/dev/null || true)"
if [[ "$SOURCE_REMOTE" == "$EXPECTED_SOURCE_REMOTE" ]]; then
    validation_success "Private Fleet Sync source authority is configured"
else
    validation_error "Source origin must be $EXPECTED_SOURCE_REMOTE (found: ${SOURCE_REMOTE:-none})"
fi

DEPLOY_ROOT="$(osrs_init_local_deployment_root)"
validation_success "Verified host-local deployment root: $DEPLOY_ROOT"

# Check for potential contamination
echo -e "${YELLOW}📋 Phase 5: Repository Contamination Check${NC}"
echo "-----------------------------------------"

# Look for session-related files that shouldn't be committed
SESSION_FILES=$(git ls-files | grep -E "^\.claude-|claude-[0-9]{8}" || true)
if [[ -n "$SESSION_FILES" ]]; then
    validation_warning "Found session-related files in git history:"
    echo "$SESSION_FILES" | sed 's/^/  /'
    echo "These should typically be in .gitignore"
fi

# Check for worktree directories that shouldn't be there
WORKTREE_DIRS=$(find . -maxdepth 1 -type d \( -name "claude-*" -o -name "codex-*" -o -name "job-*" -o -name "agent-*" \) | grep -v "/.git/" || true)
if [[ -n "$WORKTREE_DIRS" ]]; then
    validation_error "Found worktree directories in main repository:"
    echo "$WORKTREE_DIRS" | sed 's/^/  /'
    echo "These should be moved to the verified machine-local sessions root"
fi

# Deployment directory structure check
echo -e "${YELLOW}📋 Phase 6: Deployment Environment Check${NC}"
echo "--------------------------------------"

DEPLOY_REPO="$DEPLOY_ROOT/osrswiki-$PLATFORM"
if [[ -d "$DEPLOY_REPO" ]]; then
    validation_success "Platform deployment repository found at $DEPLOY_REPO"
else
    validation_warning "Platform deployment repository not found at $DEPLOY_REPO"
    echo "It will be created during deployment if needed"
fi

# Return to project root
cd "$PROJECT_ROOT"

# Final validation summary
echo -e "${BLUE}=================================================="
echo -e "📊 VALIDATION SUMMARY"
echo -e "==================================================${NC}"

if [[ "$VALIDATION_ERRORS" -eq 0 ]]; then
    validation_success "All critical validations passed"
    echo -e "${GREEN}🚀 Deployment is safe to proceed${NC}"
    exit 0
else
    echo -e "${RED}❌ $VALIDATION_ERRORS validation errors found${NC}"
    echo -e "${RED}🛑 Deployment should NOT proceed until errors are resolved${NC}"
    exit 1
fi
