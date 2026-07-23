#!/bin/bash
# 
# Comprehensive iOS App Testing Automation
# Solves the navigation bottleneck for agent development
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-}"
BUNDLE_ID="${BUNDLE_ID:-omiyawaki.osrswiki}"
EVIDENCE_DIR="${QA_EVIDENCE_DIR:-$(ios_local_evidence_path ios-automation)}"
DERIVED_DATA_PATH="${OSRS_IOS_AUTOMATION_DERIVED_DATA_PATH:-}"

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
    exit 1
}

warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Check if we're in a session and environment is loaded
check_environment() {
    ios_require_macos
    ios_select_simulator
    ios_boot_selected_simulator

    SIMULATOR_UDID="$IOS_SIMULATOR_UDID"
    BUNDLE_ID="$(ios_resolve_bundle_id)"
    export BUNDLE_ID

    EVIDENCE_DIR="$(ios_validate_evidence_dir "$EVIDENCE_DIR")"
    mkdir -p "$EVIDENCE_DIR"
    if [[ -z "$DERIVED_DATA_PATH" ]]; then
        DERIVED_DATA_PATH="$(ios_make_derived_data_path automation)"
    fi
    DERIVED_DATA_PATH="$(osrs_assert_artifact_path "$DERIVED_DATA_PATH")"
    mkdir -p "$DERIVED_DATA_PATH"

    log "Evidence directory: $EVIDENCE_DIR"
    log "DerivedData path: $DERIVED_DATA_PATH"
    success "Environment checks passed"
}

# Build the app
build_app() {
    log "Building iOS app..."
    cd "$PROJECT_ROOT/platforms/ios"
    
    xcodebuild -project osrswiki.xcodeproj \
               -scheme osrswiki \
               -configuration Debug \
               -sdk iphonesimulator \
               -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
               -derivedDataPath "$DERIVED_DATA_PATH" \
               build \
               -quiet
    
    success "App built successfully"
}

# Install and launch app
install_and_launch() {
    log "Installing and launching app..."
    
    local app_path
    app_path="$(ios_app_path_from_derived_data "$DERIVED_DATA_PATH")"
    if [[ ! -d "$app_path" ]]; then
        error "Built app not found at $app_path"
    fi
    
    # Install app
    xcrun simctl install "$SIMULATOR_UDID" "$app_path"
    
    # Launch app
    xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID"
    
    # Wait for app to be ready
    sleep 5
    
    success "App installed and launched"
}

# Launch app directly to a specific tab
launch_to_tab() {
    local tab="$1"
    log "Launching app directly to $tab tab..."
    
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" -startTab "$tab"
    
    sleep 3
    success "App launched to $tab tab"
}

# Take screenshot with descriptive name
take_screenshot() {
    local name="$1"
    local description="${2:-}"
    
    "$SCRIPT_DIR/take-screenshot.sh" "$name"
    
    if [[ -n "$description" ]]; then
        log "📸 $description"
    fi
}

# Run UI tests for comprehensive navigation
run_ui_tests() {
    log "Running comprehensive UI navigation tests..."
    run_xcodebuild_test "ui-tests" 1 -testPlan osrswikiUITests
    
    success "UI navigation tests completed"
}

run_xcodebuild_test() {
    local name="$1"
    local minimum_tests="$2"
    shift 2

    local log_file="$EVIDENCE_DIR/$name-xcodebuild.log"
    local result_bundle="$EVIDENCE_DIR/$name.xcresult"
    rm -rf "$result_bundle"

    cd "$PROJECT_ROOT/platforms/ios"
    xcodebuild test \
        -project osrswiki.xcodeproj \
        -scheme osrswiki \
        -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -resultBundlePath "$result_bundle" \
        "$@" \
        > "$log_file" 2>&1

    "$SCRIPT_DIR/assert-xcode-tests-ran.sh" "$log_file" "$minimum_tests"
    log "XCTest log: $log_file"
    log "XCTest result bundle: $result_bundle"
}

# Quick map verification (most common agent need)
quick_map_test() {
    log "Running quick map verification with XCTest..."
    run_xcodebuild_test "quick-map" 1 -only-testing:osrswikiUITests/SearchToMapNavigationTest/testQuickSearchToMapSwitching
    
    success "Quick map test completed"
}

# Comprehensive testing of all tabs
full_app_test() {
    log "Running comprehensive app testing with XCTest..."
    run_xcodebuild_test "full-test" 1 -only-testing:osrswikiUITests
    
    success "Comprehensive app testing completed"
}

# Run unit tests only
run_unit_tests() {
    log "Running unit tests with XCTest..."
    run_xcodebuild_test "unit-tests" 1 -only-testing:osrswikiTests
    
    success "Unit tests completed"
}

# Create new XCTest file with proper template
write_test_file() {
    local test_type="$1"
    local test_name="$2"
    
    if [[ -z "$test_type" || -z "$test_name" ]]; then
        error "Test type and name required. Usage: write-test [ui|unit] TestName"
    fi
    
    log "Creating new $test_type test: $test_name"
    
    case "$test_type" in
        "ui")
            local test_dir="$PROJECT_ROOT/platforms/ios/osrswikiUITests"
            local test_file="$test_dir/${test_name}Test.swift"
            
            cat > "$test_file" << 'EOF'
import XCTest

class TESTNAME_Test: XCTestCase {
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    func testTESTNAME_Functionality() {
        // TODO: Implement your UI test here
        // Example:
        // let button = app.buttons["YourButton"]
        // XCTAssertTrue(button.exists, "Button should exist")
        // button.tap()
        // 
        // let result = app.staticTexts["ExpectedResult"]
        // XCTAssertTrue(result.exists, "Expected result should appear")
    }
    
    func testTESTNAME_EdgeCase() {
        // TODO: Test edge cases and error conditions
        // Add more test methods as needed
    }
}
EOF
            # Replace TESTNAME placeholder
            sed -i '' "s/TESTNAME/$test_name/g" "$test_file"
            success "UI test created: $test_file"
            ;;
            
        "unit")
            local test_dir="$PROJECT_ROOT/platforms/ios/osrswikiTests"
            local test_file="$test_dir/${test_name}Tests.swift"
            
            cat > "$test_file" << 'EOF'
import XCTest
@testable import osrswiki

class TESTNAME_Tests: XCTestCase {
    
    override func setUpWithError() throws {
        // Setup code before each test method
    }
    
    override func tearDownWithError() throws {
        // Cleanup code after each test method
    }
    
    func testTESTNAME_BasicFunctionality() {
        // TODO: Implement your unit test here
        // Example:
        // let result = YourClass.yourMethod()
        // XCTAssertEqual(result, expectedValue, "Method should return expected value")
    }
    
    func testTESTNAME_EdgeCases() {
        // TODO: Test edge cases and error conditions
        // Example:
        // XCTAssertThrowsError(try YourClass.methodThatShouldThrow()) {
        //     error in
        //     XCTAssertEqual(error as? YourErrorType, .expectedError)
        // }
    }
    
    func testTESTNAME_Performance() {
        // TODO: Add performance tests if needed
        // self.measure {
        //     // Code to measure performance
        // }
    }
}
EOF
            # Replace TESTNAME placeholder
            sed -i '' "s/TESTNAME/$test_name/g" "$test_file"
            success "Unit test created: $test_file"
            ;;
            
        *)
            error "Invalid test type. Use 'ui' or 'unit'"
            ;;
    esac
    
    echo ""
    echo "📝 Next steps:"
    echo "1. Edit the test file to implement your specific test logic"
    echo "2. Build the app: $0 build"
    echo "3. Run tests: $0 ${test_type}-tests"
}

# Clean up screenshots older than specified hours
cleanup_screenshots() {
    local max_age_hours="${1:-24}"
    log "Requesting authorized screenshot cleanup for files older than $max_age_hours hours..."
    "$SCRIPT_DIR/clean-screenshots.sh" --delete --max-age "$max_age_hours"
    success "Authorized screenshot cleanup completed"
}

# Show usage information
show_usage() {
    cat << EOF
🤖 iOS App Testing Automation - XCTest Based

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    write-test [TYPE] [NAME] Create new XCTest file (REQUIRED before testing)
    build           Build the iOS app
    quick-map       Quick map tab verification using XCTest (most common)
    full-test       Test all tabs comprehensively using XCTest  
    ui-tests        Run XCTest UI automation tests
    unit-tests      Run XCTest unit tests
    launch [TAB]    Launch directly to specific tab
    screenshot [NAME] Take a single screenshot (for debugging only)
    cleanup [HOURS] Clean old screenshots (default: 24h)
    help            Show this help

TAB OPTIONS (for launch command):
    news, map, search, saved, more

TEST TYPES (for write-test command):
    ui          Create UI test (for user interactions)
    unit        Create unit test (for logic/functions)

EXAMPLES:
    $0 write-test ui MyFeature      # Create UI test FIRST (REQUIRED)
    $0 write-test unit MyLogic      # Create unit test FIRST (REQUIRED)
    $0 quick-map                    # Quick map verification with XCTest
    $0 full-test                    # Comprehensive XCTest suite
    $0 ui-tests                     # UI automation tests
    $0 unit-tests                   # Unit tests only
    $0 launch map                   # Launch to specific tab for debugging

RECOMMENDED AGENT WORKFLOW:
    1. $0 write-test ui MyFeature   # FIRST: Write tests for your changes
    2. $0 build                     # Build app
    3. $0 quick-map                 # Verify changes with automated tests
    4. $0 full-test                 # Run comprehensive test suite
    
TESTING APPROACH:
    ⚠️  CRITICAL: ALWAYS write tests BEFORE running XCTest commands
    • Primary: Use XCTest for automated verification (after writing tests)
    • Secondary: Screenshots only for debugging issues
    • Manual: Launch specific tabs for detailed inspection
    
⚠️  WARNING: XCTest commands will fail if no tests exist for your feature!
EOF
}

# Main execution
main() {
    case "${1:-help}" in
        "write-test")
            write_test_file "$2" "$3"
            ;;
        "build")
            check_environment
            build_app
            ;;
        "quick-map")
            check_environment
            build_app
            install_and_launch
            quick_map_test
            ;;
        "full-test")
            check_environment
            build_app
            install_and_launch
            full_app_test
            ;;
        "ui-tests")
            check_environment
            build_app
            install_and_launch
            run_ui_tests
            ;;
        "unit-tests")
            check_environment
            build_app
            run_unit_tests
            ;;
        "launch")
            check_environment
            if [[ -z "$2" ]]; then
                error "Tab name required. Options: news, map, search, saved, more"
            fi
            install_and_launch
            launch_to_tab "$2"
            ;;
        "screenshot")
            if [[ -z "$2" ]]; then
                error "Screenshot name required"
            fi
            take_screenshot "$2" "$3"
            ;;
        "cleanup")
            cleanup_screenshots "$2"
            ;;
        "help"|*)
            show_usage
            ;;
    esac
}

main "$@"
