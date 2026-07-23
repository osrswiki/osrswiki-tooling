#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

# Enhanced iOS Testing with Provisioning Profile Error Handling
# Automatically falls back to simulator when device provisioning fails
# Provides clear error messages and recovery suggestions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# macOS requirement check
if [[ "$(uname)" != "Darwin" ]]; then
    error "iOS testing requires macOS. Current platform: $(uname)"
    exit 1
fi

# Change to iOS project directory
cd "$PROJECT_ROOT"
if [[ ! -d "platforms/ios" ]]; then
    error "iOS platform directory not found. Are you in the correct project root?"
    exit 1
fi
cd platforms/ios

PROJECT_NAME="osrswiki"
SCHEME_NAME="osrswiki"
PROJECT_FILE="${PROJECT_NAME}.xcodeproj"

# Verify project exists
if [[ ! -d "$PROJECT_FILE" ]]; then
    error "Xcode project '$PROJECT_FILE' not found in $(pwd)"
    exit 1
fi

log "Enhanced iOS Testing with Provisioning Fallback"
echo "================================================="

# Function to attempt device testing
test_on_device() {
    log "Attempting to run tests on physical device..."
    
    # Try to run tests on any connected iOS device (with timeout)
    if timeout 60 xcodebuild test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME_NAME" \
        -destination "platform=iOS,name=Any iOS Device" \
        -quiet 2>/dev/null; then
        success "Device tests completed successfully"
        return 0
    else
        warn "Device testing failed (likely provisioning profile issues)"
        return 1
    fi
}

# Function to test on simulator
test_on_simulator() {
    log "Running tests on iOS Simulator..."
    
    if ! ios_select_simulator; then
        error "No leased or explicit simulator available. Run setup-session-simulator.sh or source .ios-env."
        return 1
    fi
    
    log "Using simulator: ${SIMULATOR_NAME:-unknown} ($IOS_SIMULATOR_UDID)"
    
    # Run tests on simulator (with timeout)
    if timeout 60 xcodebuild test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME_NAME" \
        -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" \
        -quiet; then
        success "Simulator tests completed successfully"
        return 0
    else
        error "Simulator tests failed"
        return 1
    fi
}

# Function to build for simulator (fallback for testing)
build_for_simulator() {
    log "Building for iOS Simulator as fallback..."
    
    if timeout 60 xcodebuild build \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME_NAME" \
        -sdk iphonesimulator \
        -quiet; then
        success "Simulator build completed successfully"
        return 0
    else
        error "Simulator build failed"
        return 1
    fi
}

# Function to detect provisioning errors
detect_provisioning_error() {
    local build_log="$1"
    
    if echo "$build_log" | grep -q "Provisioning profile"; then
        return 0  # Provisioning error detected
    elif echo "$build_log" | grep -q "Code signing"; then
        return 0  # Code signing error detected
    elif echo "$build_log" | grep -q "development team"; then
        return 0  # Team error detected
    else
        return 1  # No provisioning error
    fi
}

# Main testing workflow
main() {
    local device_success=false
    local simulator_success=false
    
    # Step 1: Try device testing first
    log "Phase 1: Attempting device testing..."
    
    # Capture device test output to detect provisioning issues
    local device_output
    if device_output=$(timeout 60 xcodebuild test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME_NAME" \
        -destination "platform=iOS,name=Any iOS Device" 2>&1); then
        success "Device tests passed!"
        device_success=true
    else
        warn "Device testing failed"
        
        # Check if it's a provisioning issue
        if detect_provisioning_error "$device_output"; then
            warn "Detected provisioning profile or code signing issues:"
            echo "$device_output" | grep -E "(Provisioning profile|Code signing|development team)" | head -3
            log "Falling back to simulator testing..."
        else
            warn "Device testing failed for unknown reasons"
            echo "$device_output" | tail -5
        fi
    fi
    
    # Step 2: If device failed, try simulator
    if [[ "$device_success" == "false" ]]; then
        log "Phase 2: Attempting simulator testing..."
        
        if test_on_simulator; then
            simulator_success=true
        else
            # If simulator tests also fail, try just building
            warn "Simulator tests failed, attempting build-only verification..."
            if build_for_simulator; then
                warn "Build successful but tests failed - check test code"
            fi
        fi
    fi
    
    # Step 3: Report results
    echo ""
    log "Testing Results Summary"
    echo "======================"
    
    if [[ "$device_success" == "true" ]]; then
        success "✓ Device testing: PASSED"
        echo "🎉 All tests completed successfully on physical device"
    elif [[ "$simulator_success" == "true" ]]; then
        warn "✗ Device testing: FAILED (provisioning issues)"
        success "✓ Simulator testing: PASSED"
        echo ""
        echo "💡 Recommendations:"
        echo "   • Fix provisioning profile for device testing"
        echo "   • Update development team settings in Xcode"
        echo "   • Verify Apple Developer account status"
        echo "   • For now, simulator testing is working correctly"
    else
        error "✗ Both device and simulator testing failed"
        echo ""
        echo "🔧 Troubleshooting steps:"
        echo "   1. Open Xcode and verify project builds manually"
        echo "   2. Check provisioning profiles in Xcode settings"
        echo "   3. Verify iOS Simulator installation"
        echo "   4. Review test code for issues"
        
        return 1
    fi
    
    return 0
}

# Run main function
main "$@"
