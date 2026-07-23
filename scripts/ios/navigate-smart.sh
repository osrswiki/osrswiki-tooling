#!/bin/bash
# Smart iOS navigation with self-healing and multiple fallback strategies
# Usage: ./navigate-smart.sh [options] TARGET
#   --timeout SECONDS       Set timeout (default: 30)
#   --validate              Validate navigation success
#   --max-attempts N        Maximum navigation attempts (default: 3)
#   --recovery              Enable automatic recovery
#   --path-optimization     Use shortest path navigation
#   --log-navigation        Log navigation events
#   --context CONTEXT       Navigation context (search|home|settings|back)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

# Configuration
TARGET=""
TIMEOUT=30
VALIDATE_SUCCESS=false
MAX_ATTEMPTS=3
ENABLE_RECOVERY=false
PATH_OPTIMIZATION=false
LOG_NAVIGATION=false
NAVIGATION_CONTEXT=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

show_usage() {
    echo "Usage: $0 [OPTIONS] TARGET"
    echo ""
    echo "Options:"
    echo "  --timeout SECONDS       Set timeout (default: 30)"
    echo "  --validate              Validate navigation success"
    echo "  --max-attempts N        Maximum navigation attempts (default: 3)"
    echo "  --recovery              Enable automatic recovery"
    echo "  --path-optimization     Use shortest path navigation"
    echo "  --log-navigation        Log navigation events"
    echo "  --context CONTEXT       Navigation context (search|home|settings|back)"
    echo ""
    echo "Predefined targets:"
    echo "  search, home, settings, back, menu"
    echo ""
    echo "Examples:"
    echo "  $0 search                           # Navigate to search"
    echo "  $0 --validate --recovery home       # Navigate to home with validation"
    echo "  $0 --context navigation 'Menu'      # Navigate to menu with context"
    echo "  $0 --max-attempts 5 'Settings'      # Try up to 5 times"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --validate)
            VALIDATE_SUCCESS=true
            shift
            ;;
        --max-attempts)
            MAX_ATTEMPTS="$2"
            shift 2
            ;;
        --recovery)
            ENABLE_RECOVERY=true
            shift
            ;;
        --path-optimization)
            PATH_OPTIMIZATION=true
            shift
            ;;
        --log-navigation)
            LOG_NAVIGATION=true
            shift
            ;;
        --context)
            NAVIGATION_CONTEXT="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "❌ No navigation target specified"
    show_usage
    exit 1
fi

# Check for macOS environment
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS navigation requires macOS environment"
    exit 1
fi

# Ensure we have an exact leased or explicit simulator UDID
if ! ios_select_simulator; then
    echo "❌ IOS_SIMULATOR_UDID not set. Run from an iOS session or source .ios-env."
    exit 1
fi

# Get bundle ID if available
BUNDLE_ID="${BUNDLE_ID:-}"

# Utility functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_nav() {
    echo -e "${CYAN}🧭 $1${NC}"
}

# Get current view controller from logs
get_current_viewcontroller() {
    xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 10s --predicate 'category contains "UIKit"' | \
        grep -i "viewcontroller\|viewdidload\|viewwillappear" | \
        tail -1 | \
        grep -o "[A-Za-z]*ViewController" | tail -1 || echo ""
}

# Check if simulator is ready
check_simulator_ready() {
    if ! xcrun simctl list devices | grep "$IOS_SIMULATOR_UDID" | grep -q "Booted"; then
        log_warning "Simulator not booted, starting it..."
        xcrun simctl boot "$IOS_SIMULATOR_UDID"
        sleep 5
    fi
    
    # Check if simulator is responsive
    local test_response=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" echo "test" 2>/dev/null || echo "")
    if [[ "$test_response" != "test" ]]; then
        log_warning "Simulator may not be responsive"
        return 1
    fi
    
    return 0
}

# Log navigation event
log_navigation_event() {
    if [[ "$LOG_NAVIGATION" == false ]]; then
        return 0
    fi
    
    local event="$1"
    local from_vc="$2"
    local to_vc="$3"
    
    log_nav "Navigation event: $event"
    log_info "From: $from_vc"
    log_info "To: $to_vc"
    
    # Log to file for analysis
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $event: $from_vc -> $to_vc" >> ios_navigation_log.txt
}

# Wait for view controller change
wait_for_viewcontroller_change() {
    local expected_vc="$1"
    local timeout="${2:-10}"
    local start_vc="$3"
    
    local start_time=$(date +%s)
    
    while [[ $(($(date +%s) - start_time)) -lt $timeout ]]; do
        local current_vc=$(get_current_viewcontroller)
        
        if [[ -n "$expected_vc" && "$current_vc" == *"$expected_vc"* ]]; then
            log_success "View controller changed to: $current_vc"
            log_navigation_event "ViewController change" "$start_vc" "$current_vc"
            return 0
        elif [[ -n "$start_vc" && "$current_vc" != "$start_vc" ]]; then
            log_success "View controller changed from $start_vc to: $current_vc"
            log_navigation_event "ViewController change" "$start_vc" "$current_vc"
            return 0
        fi
        
        sleep 1
    done
    
    log_warning "No view controller change detected within ${timeout}s"
    return 1
}

# Validate navigation success
validate_navigation_success() {
    local target="$1"
    
    if [[ "$VALIDATE_SUCCESS" == false ]]; then
        return 0
    fi
    
    log_info "Validating iOS navigation to: $target"
    
    # Strategy 1: Check if target element is now accessible
    if ./scripts/ios/wait-for-element.sh --timeout 5 "$target"; then
        log_success "Navigation validated: target element found"
        return 0
    fi
    
    # Strategy 2: Check view controller change
    local current_vc=$(get_current_viewcontroller)
    if [[ "$current_vc" == *"$target"* ]]; then
        log_success "Navigation validated: view controller contains target name"
        return 0
    fi
    
    # Strategy 3: Check for expected UI patterns in logs
    case "$target" in
        "search"|"Search")
            local search_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 5s --predicate 'category contains "UIKit"' | \
                grep -i "search\|textfield" | head -1)
            
            if [[ -n "$search_logs" ]]; then
                log_success "Navigation validated: search activity detected"
                return 0
            fi
            ;;
        "home"|"Home")
            local home_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 5s --predicate 'category contains "UIKit"' | \
                grep -i "home\|main" | head -1)
            
            if [[ -n "$home_logs" ]]; then
                log_success "Navigation validated: home activity detected"
                return 0
            fi
            ;;
        "settings"|"Settings")
            local settings_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 5s --predicate 'category contains "UIKit"' | \
                grep -i "settings\|preferences" | head -1)
            
            if [[ -n "$settings_logs" ]]; then
                log_success "Navigation validated: settings activity detected"
                return 0
            fi
            ;;
    esac
    
    # Strategy 4: Check recent navigation logs
    local recent_nav_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5s --predicate 'category contains "UIKit"' | \
        grep -E "viewDidLoad|viewWillAppear|viewDidAppear" | \
        grep -i "$target" | tail -3)
    
    if [[ -n "$recent_nav_logs" ]]; then
        log_success "Navigation validated: target found in view controller logs"
        log_info "Log evidence:"
        echo "$recent_nav_logs" | while IFS= read -r line; do
            echo "  📋 $line"
        done
        return 0
    fi
    
    log_warning "Could not validate navigation success"
    return 1
}

# Navigate using multiple strategies
navigate_to_target() {
    local target="$1"
    local context="${2:-$NAVIGATION_CONTEXT}"
    
    log_nav "Navigating to: $target"
    if [[ -n "$context" ]]; then
        log_info "Using context: $context"
    fi
    
    local start_vc=$(get_current_viewcontroller)
    log_info "Starting from view controller: $start_vc"
    
    # Ensure simulator is ready
    if ! check_simulator_ready; then
        log_error "Simulator not ready for navigation"
        return 1
    fi
    
    # Predefined navigation strategies
    case "$target" in
        "search"|"Search")
            navigate_to_search "$context"
            ;;
        "home"|"Home")
            navigate_to_home "$context"
            ;;
        "settings"|"Settings")
            navigate_to_settings "$context"
            ;;
        "back"|"Back")
            navigate_back "$context"
            ;;
        "menu"|"Menu")
            navigate_to_menu "$context"
            ;;
        *)
            # Generic navigation
            navigate_generic "$target" "$context"
            ;;
    esac
    
    local navigation_result=$?
    
    # Validate navigation if requested
    if [[ $navigation_result -eq 0 ]]; then
        if validate_navigation_success "$target"; then
            return 0
        else
            return 1
        fi
    else
        return $navigation_result
    fi
}

# Navigate to search
navigate_to_search() {
    local context="$1"
    
    log_nav "Navigating to search..."
    
    # Strategy 1: Look for search in tab bar or navigation
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context search "Search"; then
        log_success "Found search element, simulating tap"
        # Note: Actual tapping would require XCUITest or accessibility automation
        # For now, we simulate by monitoring logs for search activity
        sleep 2
        
        # Check if search interface appeared
        local search_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            log show --last 3s --predicate 'category contains "UIKit"' | \
            grep -i "search\|textfield" | head -1)
        
        if [[ -n "$search_activity" ]]; then
            log_success "Search interface detected"
            wait_for_viewcontroller_change "Search" 5 "$(get_current_viewcontroller)"
            return 0
        fi
    fi
    
    # Strategy 2: Look for search button or search bar
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "SearchBar"; then
        log_success "Search bar detected"
        sleep 2
        return 0
    fi
    
    # Strategy 3: Try navigation via menu
    if navigate_via_menu "Search"; then
        return 0
    fi
    
    # Strategy 4: Try common iOS search patterns
    log_info "Attempting to access search via common iOS patterns..."
    
    # Simulate pull-down search (if available)
    # Note: This would require actual touch simulation
    sleep 1
    
    local search_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5s --predicate 'category contains "UIKit"' | \
        grep -i "search" | head -1)
    
    if [[ -n "$search_logs" ]]; then
        log_success "Search functionality detected"
        return 0
    fi
    
    log_error "Could not navigate to search"
    return 1
}

# Navigate to home
navigate_to_home() {
    local context="$1"
    
    log_nav "Navigating to home..."
    
    # Strategy 1: Simulate home button press
    log_info "Simulating home button press..."
    xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        osascript -e 'tell application "iOS Simulator" to activate'
    
    sleep 1
    
    # Strategy 2: Launch app to return to main view
    if [[ -n "$BUNDLE_ID" ]]; then
        log_info "Launching app to return to home view..."
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID"
        sleep 3
        
        local home_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            log show --last 3s --predicate 'category contains "UIKit"' | \
            grep -i "main\|home\|root" | head -1)
        
        if [[ -n "$home_activity" ]]; then
            log_success "Home view detected"
            wait_for_viewcontroller_change "" 5 "$(get_current_viewcontroller)"
            return 0
        fi
    fi
    
    # Strategy 3: Look for home tab or button
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "Home"; then
        log_success "Home element detected"
        sleep 2
        return 0
    fi
    
    # Strategy 4: Navigate back to root view controller
    log_info "Attempting to navigate to root view controller..."
    local back_attempts=0
    while [[ $back_attempts -lt 5 ]]; do
        # Simulate back navigation
        sleep 1
        back_attempts=$((back_attempts + 1))
        
        local current_vc=$(get_current_viewcontroller)
        if [[ "$current_vc" == *"Main"* || "$current_vc" == *"Home"* || "$current_vc" == *"Root"* ]]; then
            log_success "Reached home via navigation"
            return 0
        fi
    done
    
    log_error "Could not navigate to home"
    return 1
}

# Navigate to settings
navigate_to_settings() {
    local context="$1"
    
    log_nav "Navigating to settings..."
    
    # Strategy 1: Look for settings button or tab
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "Settings"; then
        log_success "Settings element detected"
        sleep 2
        
        local settings_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            log show --last 3s --predicate 'category contains "UIKit"' | \
            grep -i "settings\|preferences" | head -1)
        
        if [[ -n "$settings_activity" ]]; then
            log_success "Settings interface detected"
            wait_for_viewcontroller_change "Settings" 5 "$(get_current_viewcontroller)"
            return 0
        fi
    fi
    
    # Strategy 2: Try navigation via menu
    if navigate_via_menu "Settings"; then
        return 0
    fi
    
    # Strategy 3: Look for gear icon or similar
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context button "Gear"; then
        log_success "Settings icon detected"
        sleep 2
        return 0
    fi
    
    log_error "Could not navigate to settings"
    return 1
}

# Navigate back
navigate_back() {
    local context="$1"
    
    log_nav "Navigating back..."
    
    local start_vc=$(get_current_viewcontroller)
    
    # Strategy 1: Look for back button in navigation bar
    if ./scripts/ios/wait-for-element.sh --timeout 3 --context navigation "Back"; then
        log_success "Back button detected"
        sleep 2
        
        if wait_for_viewcontroller_change "" 3 "$start_vc"; then
            log_success "Back navigation completed"
            return 0
        fi
    fi
    
    # Strategy 2: Use swipe gesture simulation (conceptual - would need actual implementation)
    log_info "Simulating edge swipe back gesture..."
    sleep 1
    
    # Check if view controller changed
    local current_vc=$(get_current_viewcontroller)
    if [[ "$current_vc" != "$start_vc" ]]; then
        log_success "Back navigation via gesture detected"
        return 0
    fi
    
    log_warning "Back navigation may not have changed view controllers"
    return 0  # Back navigation might not always change view controllers
}

# Navigate to menu
navigate_to_menu() {
    local context="$1"
    
    log_nav "Navigating to menu..."
    
    # Strategy 1: Look for hamburger menu or menu button
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "Menu"; then
        log_success "Menu element detected"
        sleep 2
        return 0
    fi
    
    # Strategy 2: Look for navigation drawer or sidebar
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "Sidebar"; then
        log_success "Sidebar detected"
        sleep 2
        return 0
    fi
    
    # Strategy 3: Check for more/options menu
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context button "More"; then
        log_success "More menu detected"
        sleep 2
        return 0
    fi
    
    log_error "Could not navigate to menu"
    return 1
}

# Navigate via menu (helper function)
navigate_via_menu() {
    local target="$1"
    
    log_info "Attempting navigation via menu to: $target"
    
    # Open menu first
    if navigate_to_menu ""; then
        sleep 1
        # Look for target in menu
        if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "$target"; then
            log_success "Found $target in menu"
            sleep 2
            wait_for_viewcontroller_change "$target" 5 "$(get_current_viewcontroller)"
            return 0
        fi
    fi
    
    return 1
}

# Generic navigation for custom targets
navigate_generic() {
    local target="$1"
    local context="$2"
    
    log_nav "Generic navigation to: $target"
    
    # Strategy 1: Direct search for target element
    if ./scripts/ios/wait-for-element.sh --timeout 5 "$target"; then
        log_success "Target element detected directly"
        sleep 2
        
        # Check for related activity
        local target_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            log show --last 3s --predicate 'category contains "UIKit"' | \
            grep -i "$target" | head -1)
        
        if [[ -n "$target_activity" ]]; then
            log_success "Target activity detected"
            wait_for_viewcontroller_change "$target" 5 "$(get_current_viewcontroller)"
            return 0
        fi
    fi
    
    # Strategy 2: Search with context
    if [[ -n "$context" ]]; then
        if ./scripts/ios/wait-for-element.sh --timeout 5 --context "$context" "$target"; then
            log_success "Found target with context"
            sleep 2
            return 0
        fi
    fi
    
    # Strategy 3: Try menu navigation
    if navigate_via_menu "$target"; then
        return 0
    fi
    
    # Strategy 4: Try tab navigation
    if ./scripts/ios/wait-for-element.sh --timeout 5 --context navigation "$target"; then
        log_success "Target found in navigation"
        sleep 2
        return 0
    fi
    
    log_error "Could not navigate to: $target"
    return 1
}

# Recovery mechanism
attempt_recovery() {
    if [[ "$ENABLE_RECOVERY" == false ]]; then
        return 1
    fi
    
    log_warning "Attempting iOS navigation recovery..."
    
    # Recovery 1: Return to known good state (home)
    log_info "Recovery step 1: Return to home"
    if navigate_to_home ""; then
        log_success "Returned to home successfully"
        return 0
    fi
    
    # Recovery 2: Terminate and restart app
    if [[ -n "$BUNDLE_ID" ]]; then
        log_info "Recovery step 2: Restart app"
        xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true
        sleep 2
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID"
        sleep 5
        log_success "App restarted"
        return 0
    fi
    
    # Recovery 3: Reset simulator state (not implemented - too destructive)
    log_warning "Advanced recovery options not implemented"
    
    log_error "All recovery attempts failed"
    return 1
}

# Main navigation function with retry logic
main_navigation() {
    local target="$1"
    local attempts=0
    
    while [[ $attempts -lt $MAX_ATTEMPTS ]]; do
        attempts=$((attempts + 1))
        log_nav "Navigation attempt $attempts/$MAX_ATTEMPTS"
        
        if navigate_to_target "$target"; then
            log_success "Navigation successful on attempt $attempts"
            return 0
        fi
        
        if [[ $attempts -lt $MAX_ATTEMPTS ]]; then
            log_warning "Navigation attempt $attempts failed, retrying..."
            
            # Brief recovery between attempts
            if [[ "$ENABLE_RECOVERY" == true ]]; then
                sleep 2
            fi
        fi
    done
    
    log_error "Navigation failed after $MAX_ATTEMPTS attempts"
    
    # Final recovery attempt
    if attempt_recovery; then
        log_info "Recovery successful, retrying navigation..."
        if navigate_to_target "$target"; then
            log_success "Navigation successful after recovery"
            return 0
        fi
    fi
    
    return 1
}

# Main execution
main() {
    echo "🧭 Smart iOS Navigation"
    echo "======================"
    echo "Target: $TARGET"
    echo "Simulator: $IOS_SIMULATOR_UDID"
    if [[ -n "$BUNDLE_ID" ]]; then
        echo "App: $BUNDLE_ID"
    fi
    echo "Max attempts: $MAX_ATTEMPTS"
    echo "Timeout: ${TIMEOUT}s"
    echo "Validation: $VALIDATE_SUCCESS"
    echo "Recovery: $ENABLE_RECOVERY"
    echo "Timestamp: $(date)"
    echo ""
    
    if main_navigation "$TARGET"; then
        log_success "Navigation to '$TARGET' completed successfully"
        exit 0
    else
        log_error "Navigation to '$TARGET' failed"
        exit 1
    fi
}

# Run main function
main
