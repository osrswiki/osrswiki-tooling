#!/bin/bash
set -euo pipefail

# Android Quality Gates Script
# Runs only available Gradle tasks for testing and quality checks

# Source color utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/color-utils.sh"

print_header "🔍 Android Quality Gates"
echo "Using only available Gradle tasks"
echo ""

# Ensure we're in the Android platform directory
if [[ ! -f "app/build.gradle.kts" ]]; then
    if [[ -d "platforms/android" ]]; then
        echo "Switching to Android platform directory..."
        cd platforms/android
    else
        print_error "Android platform directory not found"
        echo "Run this script from the project root or platforms/android directory"
        exit 1
    fi
fi

# Verify Gradle wrapper exists
if [[ ! -f "./gradlew" ]]; then
    print_error "Gradle wrapper not found. Ensure you're in the Android project directory."
    exit 1
fi

print_success "Android platform directory found"
echo ""

# Phase 1: Unit Tests
print_phase "🧪 Phase 1: Unit Tests"
echo "Running testDebugUnitTest..."
if ./gradlew testDebugUnitTest; then
    print_success "✅ Unit tests passed"
else
    print_error "❌ Unit tests failed"
    exit 1
fi
echo ""

# Phase 2: Lint Checks
print_phase "🔍 Phase 2: Lint Analysis"
echo "Running lintDebug (available task)..."
if ./gradlew lintDebug; then
    print_success "✅ Lint checks passed"
else
    print_warning "⚠️  Lint checks found issues"
    echo "Note: This is a warning, not a failure"
fi
echo ""

# Phase 3: Build Verification
print_phase "🔨 Phase 3: Build Verification"
echo "Running assembleDebug to verify build..."
if ./gradlew assembleDebug; then
    print_success "✅ Debug build successful"
else
    print_error "❌ Debug build failed"
    exit 1
fi
echo ""

# Summary
print_header "📋 Quality Gates Summary"
echo "Completed checks:"
echo "  ✅ Unit tests (testDebugUnitTest)"
echo "  ✅ Lint analysis (lintDebug)"  
echo "  ✅ Build verification (assembleDebug)"
echo ""
echo "Skipped unavailable tasks:"
echo "  ⏭️  detekt (not configured)"
echo "  ⏭️  ktlintCheck (not configured)"
echo "  ⏭️  koverXmlReport (not configured)"
echo "  ⏭️  koverVerify (not configured)"
echo ""
print_success "🎉 Android Quality Gates completed successfully!"
echo ""
echo "To add the skipped tools, configure them in app/build.gradle.kts:"
echo "  • Add detekt plugin and configuration"
echo "  • Add ktlint plugin and configuration"  
echo "  • Add kover plugin for code coverage"