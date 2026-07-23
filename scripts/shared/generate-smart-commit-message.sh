#!/bin/bash
# Smart Commit Message Generator for OSRS Wiki Deployments
# Analyzes changes and generates intelligent commit messages based on actual content

set -euo pipefail

# Source color utilities
source "$(dirname "${BASH_SOURCE[0]}")/color-utils.sh"

# Function to analyze git changes and generate intelligent commit message
generate_smart_commit_message() {
    local platform="$1"
    local git_root="$2"
    local deploy_dir="$3"
    
    # The generated message is captured from stdout by the deployment scripts.
    # Keep progress output on stderr so it cannot become part of the commit.
    print_info "🧠 Analyzing changes for intelligent commit message..." >&2
    
    # Analyze file changes in the staging area
    local staged_files
    staged_files=$(git diff --cached --name-only 2>/dev/null || echo "")
    
    if [[ -z "$staged_files" ]]; then
        echo "deploy($platform): sync from monorepo (no changes detected)"
        return
    fi
    
    # Count changes by type
    local added_files deleted_files modified_files
    added_files=$(git diff --cached --name-status | awk '$1 == "A" { count++ } END { print count + 0 }')
    deleted_files=$(git diff --cached --name-status | awk '$1 == "D" { count++ } END { print count + 0 }')
    modified_files=$(git diff --cached --name-status | awk '$1 == "M" { count++ } END { print count + 0 }')
    
    # Analyze file types and components
    local ui_changes=0 build_changes=0 config_changes=0 asset_changes=0 
    local test_changes=0 docs_changes=0 api_changes=0 shared_changes=0
    
    while IFS= read -r file; do
        case "$file" in
            # UI/Layout files
            *.swift|*.kt|*.java|*Layout*.xml|*View*.kt|*View*.swift|*ViewController*.swift)
                ((++ui_changes))
                ;;
            # Build system files
            *.gradle|*.gradle.kts|Podfile|*.podspec|CMakeLists.txt|Makefile)
                ((++build_changes))
                ;;
            # Configuration files
            *.json|*.xml|*.plist|*.properties|*.yaml|*.yml|*.toml)
                ((++config_changes))
                ;;
            # Assets and resources
            *.css|*.js|*.mbtiles|*.png|*.jpg|*.svg|*assets*|*resources*)
                ((++asset_changes))
                ;;
            # Tests
            *Test*.kt|*Test*.swift|*test*|*Test*)
                ((++test_changes))
                ;;
            # Documentation
            *.md|*.txt|README*|CHANGELOG*|LICENSE*)
                ((++docs_changes))
                ;;
            # API/Network related
            *api*|*network*|*http*|*Api*.kt|*Api*.swift)
                ((++api_changes))
                ;;
            # Shared components
            *shared*|*common*|*bridge*)
                ((++shared_changes))
                ;;
        esac
    done <<< "$staged_files"
    
    # Get recent monorepo changes for context
    local recent_commits
    recent_commits=$(cd "$git_root" && git log --oneline --no-merges --max-count=10 main 2>/dev/null || echo "")
    
    # Analyze commit types from recent changes
    local feat_commits fix_commits refactor_commits build_commits
    feat_commits=$(awk '/^[a-f0-9]+ feat/ { count++ } END { print count + 0 }' <<< "$recent_commits")
    fix_commits=$(awk '/^[a-f0-9]+ fix/ { count++ } END { print count + 0 }' <<< "$recent_commits")
    refactor_commits=$(awk '/^[a-f0-9]+ refactor/ { count++ } END { print count + 0 }' <<< "$recent_commits")
    build_commits=$(awk '/^[a-f0-9]+ (build|chore)/ { count++ } END { print count + 0 }' <<< "$recent_commits")
    
    # Generate commit type and summary
    local commit_type="deploy"
    local commit_scope="$platform"
    local commit_summary=""
    local commit_details=""
    
    # Determine primary change type
    if [[ $ui_changes -gt 0 ]]; then
        if [[ $feat_commits -gt $fix_commits ]]; then
            commit_type="feat"
            commit_summary="enhance $platform UI components"
        else
            commit_type="fix"
            commit_summary="improve $platform UI functionality"
        fi
        commit_details="- Updated $ui_changes UI component(s)"
    elif [[ $build_changes -gt 0 ]]; then
        commit_type="build"
        commit_summary="update $platform build configuration"
        commit_details="- Modified $build_changes build file(s)"
    elif [[ $asset_changes -gt 0 ]]; then
        commit_type="feat"
        commit_summary="update $platform assets and resources"
        commit_details="- Updated $asset_changes asset file(s)"
    elif [[ $api_changes -gt 0 ]]; then
        commit_type="feat"
        commit_summary="update $platform API integration"
        commit_details="- Modified $api_changes API component(s)"
    elif [[ $shared_changes -gt 0 ]]; then
        commit_type="feat"
        commit_summary="sync $platform with shared components"
        commit_details="- Updated $shared_changes shared component(s)"
    elif [[ $test_changes -gt 0 ]]; then
        commit_type="test"
        commit_summary="update $platform tests"
        commit_details="- Modified $test_changes test file(s)"
    elif [[ $docs_changes -gt 0 ]]; then
        commit_type="docs"
        commit_summary="update $platform documentation"
        commit_details="- Updated $docs_changes documentation file(s)"
    else
        # Fallback based on recent commit patterns
        if [[ $feat_commits -gt $((fix_commits + refactor_commits)) ]]; then
            commit_type="feat"
            commit_summary="add new $platform features"
        elif [[ $fix_commits -gt $refactor_commits ]]; then
            commit_type="fix"
            commit_summary="resolve $platform issues"
        else
            commit_type="refactor"
            commit_summary="improve $platform codebase"
        fi
        commit_details="- Synchronized with monorepo changes"
    fi
    
    # Add change statistics
    local change_stats=""
    if [[ $added_files -gt 0 ]]; then
        change_stats+="- Added: $added_files file(s)"$'\n'
    fi
    if [[ $modified_files -gt 0 ]]; then
        change_stats+="- Modified: $modified_files file(s)"$'\n'
    fi
    if [[ $deleted_files -gt 0 ]]; then
        change_stats+="- Deleted: $deleted_files file(s)"$'\n'
    fi
    
    # Platform-specific details
    local platform_details=""
    case "$platform" in
        android)
            platform_details="- Build system: Gradle with dual-mode configuration
- Asset structure: Organized for Android WebView integration
- Shared components: Copied to proper Android asset directories"
            ;;
        ios)
            platform_details="- Build system: Xcode project with native Swift
- Shared components: Swift bridge implementations created
- Platform optimization: iOS-specific implementations"
            ;;
        tooling)
            platform_details="- Public repository: Development tools and scripts
- Cross-platform: Shared components and utilities
- Platforms excluded: Android/iOS deployed separately"
            ;;
    esac
    
    # Get meaningful recent commits (not just grep patterns)
    local meaningful_commits=""
    if [[ -n "$recent_commits" ]]; then
        meaningful_commits=$(echo "$recent_commits" | head -5 | sed 's/^[a-f0-9]* /- /')
    else
        meaningful_commits="- Recent changes from monorepo main branch"
    fi
    
    # Generate complete commit message
    cat << EOF
$commit_type($commit_scope): $commit_summary

$commit_details

Recent changes from monorepo:
$meaningful_commits

Change summary:
$change_stats
Deployment details:
$platform_details
- Source: $git_root
- Target: $deploy_dir
- Date: $(date '+%Y-%m-%dT%H:%M:%S%z')
- Total files: $(echo "$staged_files" | wc -l)

Component analysis:
- UI components: $ui_changes
- Build files: $build_changes  
- Configuration: $config_changes
- Assets/Resources: $asset_changes
- API components: $api_changes
- Shared components: $shared_changes
- Tests: $test_changes
- Documentation: $docs_changes
EOF
}

# Function to generate platform-specific deployment commit message
generate_deployment_commit_message() {
    local platform="$1"
    local git_root="$2"
    local deploy_dir="$3"
    
    # Generate the smart commit message
    generate_smart_commit_message "$platform" "$git_root" "$deploy_dir"
}

# Allow script to be sourced or called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Called directly - demonstrate usage
    if [[ $# -lt 3 ]]; then
        echo "Usage: $0 <platform> <git_root> <deploy_dir>"
        echo "Example: $0 android /path/to/git/root /path/to/deploy/dir"
        exit 1
    fi
    
    generate_deployment_commit_message "$1" "$2" "$3"
fi
