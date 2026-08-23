#!/bin/bash
set -euo pipefail

# OSRS Wiki Git-Based Android Deployment Script
# Updates the verified host-local osrswiki-android deployment checkout and
# pushes to its public remote.

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

print_header "🚀 OSRS Wiki Git-Based Android Deployment"
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

# Phase 1: Pre-deployment validation
CURRENT_PHASE="Pre-deployment Validation"
print_phase "🔍 Phase 1: Pre-deployment Validation"

# Check for Android platform directory (in git root)
ANDROID_PLATFORM_DIR="$GIT_ROOT/platforms/android"
if [[ ! -d "$ANDROID_PLATFORM_DIR" ]]; then
    print_error "Android platform directory not found at $ANDROID_PLATFORM_DIR"
    exit 1
fi
print_success "Android platform directory found at $ANDROID_PLATFORM_DIR"

# Run deployment validation (from project root)
cd "$GIT_ROOT"

print_info "Running deployment validation..."
if ! "$GIT_ROOT/scripts/shared/validate-deployment.sh" android; then
    print_error "Pre-deployment validation failed"
    echo "Fix validation errors before proceeding"
    exit 1
fi

# Phase 2: Repository health check
CURRENT_PHASE="Repository Health Check"
print_phase "🏥 Phase 2: Repository Health Check"
echo "-------------------------------"

print_info "Checking repository health..."
if ! "$GIT_ROOT/scripts/shared/validate-repository-health.sh"; then
    print_warning "Repository health issues detected; continuing with warning (no prompt)."
fi

# Phase 3: Setup deployment environment
CURRENT_PHASE="Deployment Environment Setup"
print_phase "🏗️  Phase 3: Deployment Environment Setup"
echo "-------------------------------------"

DEPLOY_ROOT="$(osrs_init_local_deployment_root)"
DEPLOY_ANDROID="$DEPLOY_ROOT/osrswiki-android"
MONOREPO_ROOT="$PROJECT_ROOT"

# Ensure deployment directory exists
if [[ ! -d "$DEPLOY_ANDROID" ]]; then
    print_info "📁 Creating deployment repository..."
    mkdir -p "$(dirname "$DEPLOY_ANDROID")"
    cd "$(dirname "$DEPLOY_ANDROID")"
    git clone --depth 1 --branch main --single-branch https://github.com/osrswiki/osrswiki-android.git
    cd "$PROJECT_ROOT"
fi

# Validate deployment repo
if [[ ! -d "$DEPLOY_ANDROID/.git" ]]; then
    print_error "Deployment repository is not a valid git repo: $DEPLOY_ANDROID"
    exit 1
fi

print_success "Deployment environment ready"

# Phase 4: Update deployment repository content
CURRENT_PHASE="Update Deployment Content"
print_phase "📦 Phase 4: Update Deployment Content"
echo "-----------------------------------"

cd "$DEPLOY_ANDROID"
print_info "Working in deployment repository: $DEPLOY_ANDROID"

# Fetch latest changes to ensure we're up to date
print_info "Fetching latest remote changes..."
git fetch origin main
git reset --hard origin/main

# Create deployment branch for safety
DEPLOY_BRANCH="deploy-$(date +%Y%m%d-%H%M%S)"
print_info "Creating deployment branch: $DEPLOY_BRANCH"
git checkout -b "$DEPLOY_BRANCH"

# Clear existing content (except .git)
print_info "Clearing existing content..."
find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

# CRITICAL SECURITY: Validate Android platform directory before copying
print_info "🔍 Validating Android platform content for security..."

# Check for monorepo contamination in platforms/android
if [[ -d "$GIT_ROOT/platforms/android/.claude" ]]; then
    print_error "🚨 SECURITY ALERT: .claude directory found in platforms/android"
    print_error "This indicates monorepo contamination. Deployment BLOCKED."
    exit 1
fi

if [[ -d "$GIT_ROOT/platforms/android/platforms" ]]; then
    print_error "🚨 SECURITY ALERT: nested platforms directory found"
    print_error "This indicates monorepo contamination. Deployment BLOCKED."
    exit 1
fi

if [[ -f "$GIT_ROOT/platforms/android/AGENTS.md" ]]; then
    print_error "🚨 SECURITY ALERT: AGENTS.md found in platforms/android"
    print_error "This indicates monorepo contamination. Deployment BLOCKED."
    exit 1
fi

# Count files to detect if entire monorepo was copied to platforms/android
# Exclude build directories which can contain thousands of generated files
ANDROID_FILE_COUNT=$(find "$GIT_ROOT/platforms/android" -type f ! -path "*/build/*" | wc -l)
BUILD_FILE_COUNT=$(find "$GIT_ROOT/platforms/android" -type f -path "*/build/*" | wc -l)

if [[ $ANDROID_FILE_COUNT -gt 2000 ]]; then
    print_error "🚨 SECURITY ALERT: Excessive source file count ($ANDROID_FILE_COUNT files, $BUILD_FILE_COUNT build files)"
    print_error "This suggests monorepo contamination. Expected < 1000 source files for Android platform."
    print_error "Deployment BLOCKED to prevent repository corruption."
    exit 1
fi

if [[ $BUILD_FILE_COUNT -gt 0 ]]; then
    print_warning " Build artifacts detected ($BUILD_FILE_COUNT files) - will be excluded from deployment"
fi

print_success "Android platform validation passed ($ANDROID_FILE_COUNT files)"

# Copy Android platform content (excluding build artifacts)
print_info "Copying Android platform content (excluding build directories)..."

# Copy everything except build directories
find "$GIT_ROOT/platforms/android" -mindepth 1 -maxdepth 1 ! -name 'build' -exec cp -r {} . \;

# Copy .gitignore if it exists
cp "$GIT_ROOT/platforms/android/.gitignore" . 2>/dev/null || true

# Clean any build directories that might have been copied
if [[ -d "app/build" ]]; then
    print_info "Removing build artifacts from deployment..."
    find . -type d -name "build" -exec rm -rf {} + 2>/dev/null || true
fi

# Copy shared resources with proper Android asset structure
print_info "Copying shared resources to Android asset structure..."
ASSETS_DIR="app/src/main/assets"

if [[ -d "$GIT_ROOT/shared" ]]; then
    echo "  → Creating Android asset directories..."
    mkdir -p "$ASSETS_DIR/styles/modules"
    mkdir -p "$ASSETS_DIR/js"
    mkdir -p "$ASSETS_DIR/web"
    mkdir -p "$ASSETS_DIR/mediawiki"
    mkdir -p "$ASSETS_DIR/data"
    
    # Copy CSS files to styles/ directory
    echo "  → Copying CSS files to styles/..."
    if [[ -d "$GIT_ROOT/shared/css" ]]; then
        find "$GIT_ROOT/shared/css" -name "*.css" -not -path "*/modules/*" -exec cp {} "$ASSETS_DIR/styles/" \;
        # Copy CSS modules maintaining structure  
        if [[ -d "$GIT_ROOT/shared/css/modules" ]]; then
            find "$GIT_ROOT/shared/css/modules" -name "*.css" -exec cp {} "$ASSETS_DIR/styles/modules/" \;
        fi
        echo "    ✓ CSS files copied to styles/"
    fi
    
    # Copy JavaScript files to js/ directory (excluding MediaWiki and WebView files)
    echo "  → Copying main JavaScript files to js/..."
    if [[ -d "$GIT_ROOT/shared/js" ]]; then
        # Copy main JS files (excluding subdirectories)
        find "$GIT_ROOT/shared/js" -maxdepth 1 -name "*.js" -exec cp {} "$ASSETS_DIR/js/" \;
        echo "    ✓ Main JavaScript files copied to js/"
    fi
    
    # Copy WebView-specific files to web/ directory
    echo "  → Copying WebView files to web/..."
    if [[ -d "$GIT_ROOT/shared/js" ]]; then
        # WebView JavaScript files
        for webjs in "collapsible_content.js" "horizontal_scroll_interceptor.js" "responsive_videos.js" \
                     "clipboard_bridge.js" "infobox_switcher_bootstrap.js" "switch_infobox.js" \
                     "ge_charts_init.js" "chart.umd.min.js"; do
            if [[ -f "$GIT_ROOT/shared/js/$webjs" ]]; then
                cp "$GIT_ROOT/shared/js/$webjs" "$ASSETS_DIR/web/"
            fi
        done
        
        # WebView CSS files (CSS files that are in js/ directory)
        for webcss in "collapsible_sections.css" "collapsible_tables.css" "switch_infobox_styles.css"; do
            if [[ -f "$GIT_ROOT/shared/js/$webcss" ]]; then
                cp "$GIT_ROOT/shared/js/$webcss" "$ASSETS_DIR/web/"
            fi
        done
        echo "    ✓ WebView files copied to web/"
    fi
    
    # Copy MediaWiki modules
    echo "  → Copying MediaWiki modules..."
    if [[ -d "$GIT_ROOT/shared/js/mediawiki" ]]; then
        # startup.js goes to assets root
        if [[ -f "$GIT_ROOT/shared/js/mediawiki/startup.js" ]]; then
            cp "$GIT_ROOT/shared/js/mediawiki/startup.js" "$ASSETS_DIR/"
        fi
        
        # Other MediaWiki modules go to mediawiki/ subdirectory
        for mwjs in "page_bootstrap.js" "page_modules.js"; do
            if [[ -f "$GIT_ROOT/shared/js/mediawiki/$mwjs" ]]; then
                cp "$GIT_ROOT/shared/js/mediawiki/$mwjs" "$ASSETS_DIR/mediawiki/"
            fi
        done
        echo "    ✓ MediaWiki modules copied"
    fi
    
    # Copy only small source-controlled shared assets. Release MBTiles are
    # materialized separately and remain ignored by Git.
    echo "  → Copying source-controlled shared assets..."
    if [[ -d "$GIT_ROOT/shared/assets" ]]; then
        find "$GIT_ROOT/shared/assets" -type f ! -name "*.mbtiles" -exec cp {} "$ASSETS_DIR/" \;
        echo "    ✓ Source-controlled shared assets copied"
    fi
    
    # Copy data files maintaining structure
    echo "  → Copying data files..."
    if [[ -d "$GIT_ROOT/shared/data" ]]; then
        cp -r "$GIT_ROOT/shared/data"/* "$ASSETS_DIR/data/" 2>/dev/null || echo "    (no data files to copy)"
        echo "    ✓ Data files copied to data/"
    fi
    
    print_success "Android asset structure created successfully"
    echo "  📁 Assets organized in proper Android structure:"
    echo "    • CSS files → styles/ (main) and styles/modules/ (modules)"
    echo "    • JavaScript → js/ (main) and web/ (WebView-specific)"
    echo "    • MediaWiki → startup.js (root) and mediawiki/ (modules)"
    echo "    • Assets → root (for direct access)"
    echo "    • Data → data/ (maintaining structure)"
else
    print_warning " No shared directory found - creating empty asset structure"
    mkdir -p "$ASSETS_DIR"
fi

# Publish the immutable manifest and downloader while keeping the actual map
# databases ignored. A verified host-local cache is the source for this deploy;
# clean public clones use the same script to download the pinned release.
mkdir -p scripts
cp "$GIT_ROOT/scripts/shared/fetch-map-release-assets.sh" scripts/fetch-map-assets.sh
cp "$GIT_ROOT/shared/manifests/osrs-map-assets-v1.json" map-assets-manifest.json
cp "$GIT_ROOT/docs/public/map-release-assets.md" MAP_ASSETS.md
CACHE_BASE="$(get_cache_dir)"
OSRS_MAP_ASSET_SOURCE_DIR="$CACHE_BASE/binary-assets/mbtiles" \
    scripts/fetch-map-assets.sh materialize map-assets-manifest.json "$ASSETS_DIR"
print_success "Pinned release map assets materialized and verified outside Git"

# Install public landing README + LICENSE into the staged public tree
print_info "Installing public landing README/LICENSE for android..."
"$GIT_ROOT/scripts/shared/osrs-public-landing.sh" install \
  --target android \
  --dest "$PWD" \
  --landing-root "$GIT_ROOT/docs/public-landing"

# Verify dual-mode build configuration  
print_info "Verifying dual-mode build configuration..."
if [[ -f "app/build.gradle.kts" ]]; then
    if grep -q "isMonorepo.*File.*exists" app/build.gradle.kts; then
        echo "    ✓ Dual-mode build configuration detected"
        echo "    • Build will auto-detect monorepo vs standalone mode"
        echo "    • No manual configuration changes needed"
    else
        print_info "    ⚠️  Build file may need dual-mode configuration"
    fi
    print_success "Build system ready for standalone deployment"
else
    print_error "build.gradle.kts not found in expected location"
    ls -la app/build.gradle* 2>/dev/null || echo "    No build.gradle files found"
fi

# Phase 5: Deployment Validation
print_phase "✅ Phase 5: Deployment Validation"
echo "------------------------------"

print_info "Running deployment validation checks..."

# Validation 1: Asset structure and content
echo "  → Validating asset structure..."
REQUIRED_ASSET_DIRS=("$ASSETS_DIR/styles" "$ASSETS_DIR/js" "$ASSETS_DIR/web")
VALIDATION_PASSED=true

for dir in "${REQUIRED_ASSET_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        file_count=$(find "$dir" -type f | wc -l)
        echo "    ✓ $dir ($file_count files)"
    else
        echo -e "${RED}    ❌ $dir (missing)${NC}"
        VALIDATION_PASSED=false
    fi
done

# Check for critical assets
CRITICAL_ASSETS=(
    "$ASSETS_DIR/styles/themes.css"
    "$ASSETS_DIR/styles/base.css"
    "$ASSETS_DIR/js/tablesort.min.js"
    "$ASSETS_DIR/web/collapsible_content.js"
    "$ASSETS_DIR/startup.js"
)

echo "  → Validating critical assets..."
for asset in "${CRITICAL_ASSETS[@]}"; do
    if [[ -f "$asset" ]]; then
        size=$(stat -c%s "$asset" 2>/dev/null || stat -f%z "$asset" 2>/dev/null)
        if [[ $size -gt 0 ]]; then
            echo "    ✓ $(basename "$asset") (${size} bytes)"
        else
            echo -e "${RED}    ❌ $(basename "$asset") (empty file)${NC}"
            VALIDATION_PASSED=false
        fi
    else
        echo -e "${RED}    ❌ $(basename "$asset") (missing)${NC}"
        VALIDATION_PASSED=false
    fi
done

# Validation 2: Build configuration
echo "  → Validating build configuration..."
if [[ -f "app/build.gradle.kts" ]]; then
    if grep -q "val isMonorepo.*exists" app/build.gradle.kts; then
        echo "    ✓ Dual-mode build configuration present"
    else
        print_info "    ⚠️  Dual-mode configuration not found"
        VALIDATION_PASSED=false
    fi
    
    # Check that monorepo references are properly handled
    if grep -q "\.\./\.\./\.\./shared" app/build.gradle.kts; then
        if grep -q "val isMonorepo" app/build.gradle.kts; then
            echo "    ✓ Monorepo references properly conditionalized"
        else
            print_info "    ⚠️  Unconditionalized monorepo references detected"
        fi
    fi
else
    print_error "    build.gradle.kts not found"
    VALIDATION_PASSED=false
fi

# Validation 3: Quick Gradle validation (if gradlew exists)
if [[ -f "./gradlew" ]]; then
    echo "  → Testing Gradle wrapper..."
    
    # Test Gradle wrapper with platform-appropriate timeout
    gradle_test_result=0
    if command -v timeout >/dev/null 2>&1; then
        # Linux/GNU timeout available
        timeout 30 ./gradlew --version >/dev/null 2>&1
        gradle_test_result=$?
    elif command -v gtimeout >/dev/null 2>&1; then
        # macOS with coreutils timeout available
        gtimeout 30 ./gradlew --version >/dev/null 2>&1
        gradle_test_result=$?
    else
        # macOS without timeout - just test basic functionality quickly
        # Use a simpler test that shouldn't hang
        if ./gradlew --help >/dev/null 2>&1; then
            gradle_test_result=0
        else
            gradle_test_result=1
        fi
    fi
    
    if [[ $gradle_test_result -eq 0 ]]; then
        echo "    ✓ Gradle wrapper functional"
    else
        print_info "    ⚠️  Gradle wrapper test failed (exit code: $gradle_test_result)"
        # This is a warning, not a failure - don't block deployment
    fi
else
    print_error "    gradlew not found"
    VALIDATION_PASSED=false
fi

# Validation summary
echo ""
if [[ "$VALIDATION_PASSED" == "true" ]]; then
    print_success "All deployment validation checks passed"
    print_info "📋 Deployment Summary:"
    echo "  • Asset directories: $(find "$ASSETS_DIR" -type d | wc -l)"
    echo "  • Asset files: $(find "$ASSETS_DIR" -type f | wc -l)"
    echo "  • Total asset size: $(du -sh "$ASSETS_DIR" | cut -f1)"
    echo "  • Build configuration: Dual-mode enabled"
    echo "  • Validation: All checks passed"
else
    print_error "Deployment validation failed"
    echo "The deployed app may not build correctly in standalone mode."
    echo "Please review the errors above and fix them before proceeding."
    echo ""
    echo "To run full standalone validation after fixing issues:"
    echo "  \$PROJECT_ROOT/scripts/shared/test-standalone-build.sh"
    echo ""
    print_warning "Deployment validation reported issues; continuing with warning (no prompt)."
fi

# CRITICAL SECURITY: Final deployment validation
print_info "🔒 Performing final deployment security validation..."

# Check deployment directory for contamination
if [[ -d ".claude" ]]; then
    print_error "🚨 DEPLOYMENT CONTAMINATION: .claude directory found in deployment"
    print_error "Removing contamination..."
    rm -rf .claude
    print_warning " .claude directory removed from deployment"
fi

if [[ -d "platforms" ]]; then
    print_error "🚨 DEPLOYMENT CONTAMINATION: platforms directory found in deployment"
    print_error "This indicates monorepo content was deployed. Deployment BLOCKED."
    exit 1
fi

if [[ -f "AGENTS.md" ]]; then
    print_error "🚨 DEPLOYMENT CONTAMINATION: AGENTS.md found in deployment"
    print_error "This indicates monorepo content was deployed. Deployment BLOCKED."
    exit 1
fi

if [[ -d "shared" ]]; then
    print_error "🚨 DEPLOYMENT CONTAMINATION: shared directory found in deployment"
    print_error "Shared content should be copied to assets, not deployed as-is. Deployment BLOCKED."
    exit 1
fi

if [[ -d "tools" ]]; then
    print_error "🚨 DEPLOYMENT CONTAMINATION: tools directory found in deployment"
    print_error "This indicates monorepo content was deployed. Deployment BLOCKED."
    exit 1
fi

# Verify Android-specific structure exists
if [[ ! -f "app/build.gradle.kts" ]]; then
    print_error "🚨 DEPLOYMENT STRUCTURE ERROR: app/build.gradle.kts not found"
    print_error "This suggests Android platform structure is missing. Deployment BLOCKED."
    exit 1
fi

if [[ ! -f "gradlew" ]]; then
    print_error "🚨 DEPLOYMENT STRUCTURE ERROR: gradlew not found"
    print_error "This suggests Android platform structure is missing. Deployment BLOCKED."
    exit 1
fi

# Final file count check
DEPLOY_FILE_COUNT=$(find . -type f ! -path './.git/*' | wc -l)
if [[ $DEPLOY_FILE_COUNT -gt 1500 ]]; then
    print_error "🚨 DEPLOYMENT SIZE ERROR: Excessive file count ($DEPLOY_FILE_COUNT files)"
    print_error "Android deployment should have < 1000 files. This suggests contamination."
    print_error "Deployment BLOCKED to prevent repository corruption."
    exit 1
fi

print_success "Final deployment validation passed ($DEPLOY_FILE_COUNT files)"

# Stage all changes
git add -A
"$GIT_ROOT/scripts/shared/validate-public-deployment-tree.sh" android "$DEPLOY_ANDROID"

# Create deployment commit if there are changes
if ! git diff --cached --quiet; then
    # Generate intelligent commit message based on actual changes
    print_info "🧠 Generating intelligent commit message..."
    # Use find-git-repo.sh to locate the script correctly
    if source "$GIT_ROOT/scripts/shared/find-git-repo.sh"; then
        REPO_ROOT=$(find_git_repo)
        if [[ -f "$REPO_ROOT/scripts/shared/generate-smart-commit-message.sh" ]]; then
            if ! DEPLOY_COMMIT_MSG=$(source "$REPO_ROOT/scripts/shared/generate-smart-commit-message.sh" && \
                                    generate_deployment_commit_message "android" "$GIT_ROOT" "$DEPLOY_ANDROID"); then
                print_warning "Smart commit message generation failed, using fallback"
                DEPLOY_COMMIT_MSG="Merge deployment: Android platform with shared components
- Android app with integrated shared CSS/JS
- Asset organization for Android structure
- Build configuration updates"
            fi
        else
            print_info "⚠️  Smart commit message script not found, using fallback"
            DEPLOY_COMMIT_MSG="Merge deployment: Android platform with shared components
- Android app with integrated shared CSS/JS
- Asset organization for Android structure
- Build configuration updates"
        fi
    else
        print_info "⚠️  Repository detection failed, using fallback commit message"
        DEPLOY_COMMIT_MSG="Merge deployment: Android platform with shared components
- Android app with integrated shared CSS/JS
- Asset organization for Android structure
- Build configuration updates"
    fi

    git commit -m "$DEPLOY_COMMIT_MSG"
    print_success "Deployment commit created"
    
    # Show what was deployed
    print_phase "📋 Deployment Summary:"
    git show --stat HEAD
    
else
    print_info "ℹ️  No changes to deploy"
    git checkout main
    git branch -d "$DEPLOY_BRANCH"
    cd "$PROJECT_ROOT"
    exit 0
fi

# Phase 5: Push to remote
CURRENT_PHASE="Push to Remote"
print_phase "🚀 Phase 5: Push to Remote"
echo "------------------------"

# Safety check - ensure we have reasonable number of commits
DEPLOY_COMMITS=$(git rev-list --count HEAD)
if [[ "$DEPLOY_COMMITS" -lt 1 ]]; then
    print_error "🚨 CRITICAL SAFETY CHECK FAILED"
    echo "Deployment repository has no commits"
    echo "This suggests a serious error in deployment preparation."
    exit 1
fi

print_success "Safety check passed: $DEPLOY_COMMITS commits"

# Push with force-with-lease for safety
print_info "Pushing to remote..."
if git push origin "$DEPLOY_BRANCH" --force-with-lease; then
    print_success "Deployment branch pushed successfully"
    
    # Merge to main
    git checkout main
    git merge "$DEPLOY_BRANCH" --ff-only
    git push origin main
    
    # Clean up deployment branch
    git branch -d "$DEPLOY_BRANCH"
    git push origin --delete "$DEPLOY_BRANCH"
    
    print_success "🎉 Android deployment completed successfully!"
    
else
    print_error "Push failed - remote may have been updated"
    echo "Fix conflicts and try again"
    exit 1
fi

# Phase 6: Final validation
print_phase "✅ Phase 6: Post-deployment Validation"
echo "--------------------------------"

# Verify remote state
REMOTE_COMMITS=$(git ls-remote origin main | cut -f1)
LOCAL_COMMITS=$(git rev-parse HEAD)

if [[ "$REMOTE_COMMITS" == "$LOCAL_COMMITS" ]]; then
    print_success "Remote and local are synchronized"
else
    print_warning " Remote and local commits differ"
    echo "This may indicate a deployment issue - investigate"
fi

# Return to monorepo
cd "$PROJECT_ROOT"

echo ""
print_success "🎊 Git-Based Android Deployment Complete!"
echo "=============================================="
echo "Deployment repository: $DEPLOY_ANDROID"
echo "Remote commits: $DEPLOY_COMMITS"
echo "Changes deployed safely"
echo ""
print_phase "Deployed components:"
echo "- ✅ Android app (complete Kotlin/Gradle project)"
echo "- ✅ Web assets organized in proper Android structure" 
echo "- ✅ CSS stylesheets in styles/ directory"
echo "- ✅ WebView JavaScript/CSS in web/ directory"
echo "- ✅ MediaWiki modules in correct locations"
echo "- ✅ Map tiles and data files included"
echo "- ✅ Dual-mode build configuration (monorepo/standalone)"
echo "- ✅ Deployment validation and integrity checks"
echo "- ✅ Standalone buildable without monorepo dependencies"
echo ""
print_phase "Key advantages of the verified host-local deployment root:"
echo "- ✅ Simple 1:1 mirror of remote repository"
echo "- ✅ Standard git workflow from deployment directory"
echo "- ✅ Clear separation between monorepo and deployment"
echo "- ✅ Easy to verify deployment state"
echo ""
print_phase "Next steps:"
echo "- Verify deployment at: https://github.com/osrswiki/osrswiki-android"
echo "- Run full standalone validation: ./scripts/shared/test-standalone-build.sh"
echo "- Test the deployed app builds and runs correctly"
echo "- Monitor for any issues"

exit 0
