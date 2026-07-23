#!/bin/bash
# Smart element waiting with multiple fallback strategies for iOS
# Usage: ./wait-for-element.sh [options] ELEMENT
#   --timeout SECONDS       Set timeout (default: 30)
#   --method METHOD         Preferred search method (accessibility|label|text)
#   --polling-interval SEC  Polling interval in seconds (default: 1)
#   --validate-state        Validate app state while waiting
#   --log-events            Log navigation events during wait
#   --recovery              Enable automatic recovery on timeout
#   --context CONTEXT       Provide semantic context for intelligent search

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

# Configuration
ELEMENT=""
TIMEOUT=30
PREFERRED_METHOD=""
POLLING_INTERVAL=1
VALIDATE_STATE=false
LOG_EVENTS=false
ENABLE_RECOVERY=false
SEMANTIC_CONTEXT=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

show_usage() {
    echo "Usage: $0 [OPTIONS] ELEMENT"
    echo ""
    echo "Options:"
    echo "  --timeout SECONDS       Set timeout (default: 30)"
    echo "  --method METHOD         Preferred search method (accessibility|label|text)"
    echo "  --polling-interval SEC  Polling interval in seconds (default: 1)"
    echo "  --validate-state        Validate app state while waiting"
    echo "  --log-events            Log navigation events during wait"
    echo "  --recovery              Enable automatic recovery on timeout"
    echo "  --context CONTEXT       Provide semantic context (search|navigation|input|button)"
    echo ""
    echo "Examples:"
    echo "  $0 'Search'                           # Wait for Search element"
    echo "  $0 --method accessibility 'SearchButton' # Wait by accessibility ID"
    echo "  $0 --context navigation 'Menu'        # Wait for Menu with navigation context"
    echo "  $0 --timeout 60 --recovery 'Results'  # Wait 60s with recovery enabled"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --method)
            PREFERRED_METHOD="$2"
            shift 2
            ;;
        --polling-interval)
            POLLING_INTERVAL="$2"
            shift 2
            ;;
        --validate-state)
            VALIDATE_STATE=true
            shift
            ;;
        --log-events)
            LOG_EVENTS=true
            shift
            ;;
        --recovery)
            ENABLE_RECOVERY=true
            shift
            ;;
        --context)
            SEMANTIC_CONTEXT="$2"
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
            ELEMENT="$1"
            shift
            ;;
    esac
done

if [[ -z "$ELEMENT" ]]; then
    echo "❌ No element specified"
    show_usage
    exit 1
fi

# Check for macOS environment
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS element waiting requires macOS environment"
    exit 1
fi

# Ensure we have simulator UDID
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

log_check() {
    echo -e "${CYAN}🔍 $1${NC}"
}

# Check if simulator is accessible
check_simulator_status() {
    if ! xcrun simctl list devices | grep "$IOS_SIMULATOR_UDID" | grep -q "Booted"; then
        log_warning "Simulator not booted, attempting to boot..."
        xcrun simctl boot "$IOS_SIMULATOR_UDID"
        sleep 5
    fi
}

# Search for element using accessibility information
find_element_via_accessibility() {
    local element="$1"
    local context="${2:-}"
    
    # Check recent accessibility logs for the element
    local accessibility_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5s --predicate 'category contains "UIAccessibility"' | \
        grep -i "$element" | head -3)
    
    if [[ -n "$accessibility_logs" ]]; then
        log_info "Found accessibility references to '$element':"
        echo "$accessibility_logs" | while IFS= read -r line; do
            echo "  ♿ $line"
        done
        return 0
    fi
    
    return 1
}

# Search for element using UI logs
find_element_via_ui_logs() {
    local element="$1"
    local context="${2:-}"
    
    # Check recent UIKit logs for element references
    local ui_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5s --predicate 'category contains "UIKit" OR subsystem contains "UIKit"' | \
        grep -i "$element" | head -3)
    
    if [[ -n "$ui_logs" ]]; then
        log_info "Found UI references to '$element':"
        echo "$ui_logs" | while IFS= read -r line; do
            echo "  📱 $line"
        done
        return 0
    fi
    
    return 1
}

# Search for element using view controller logs
find_element_via_vc_logs() {
    local element="$1"
    local context="${2:-}"
    
    # Check for view controller transitions that might indicate the element is available
    local vc_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 10s --predicate 'category contains "UIKit"' | \
        grep -E "viewDidLoad|viewWillAppear|viewDidAppear" | \
        grep -i "$element" | head -3)
    
    if [[ -n "$vc_logs" ]]; then
        log_info "Found view controller references to '$element':"
        echo "$vc_logs" | while IFS= read -r line; do
            echo "  🎭 $line"
        done
        return 0
    fi
    
    return 1
}

# Search for element using multiple strategies
find_element_adaptive() {
    local element="$1"
    local context="${2:-}"
    
    # Strategy 1: Accessibility-based search
    case "$PREFERRED_METHOD" in
        "accessibility")
            find_element_via_accessibility "$element" "$context" && return 0
            ;;
        "label")
            find_element_via_ui_logs "$element" "$context" && return 0
            ;;
        "text")
            find_element_via_vc_logs "$element" "$context" && return 0
            ;;
        *)
            # Try all methods in order of reliability
            find_element_via_accessibility "$element" "$context" && return 0
            find_element_via_ui_logs "$element" "$context" && return 0
            find_element_via_vc_logs "$element" "$context" && return 0
            ;;
    esac
    
    # Strategy 2: Semantic search based on context
    if [[ -n "$context" ]]; then
        case "$context" in
            "search")
                # Look for search-related activity
                local search_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 5s --predicate 'category contains "UIKit"' | \
                    grep -i "search\|textfield\|searchbar" | head -3)
                
                if [[ -n "$search_logs" ]]; then
                    log_info "Found search-related activity:"
                    echo "$search_logs" | while IFS= read -r line; do
                        echo "  🔍 $line"
                    done
                    return 0
                fi
                ;;
            "navigation")
                # Look for navigation-related activity
                local nav_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 5s --predicate 'category contains "UIKit"' | \
                    grep -i "navigation\|viewcontroller\|segue" | head -3)
                
                if [[ -n "$nav_logs" ]]; then
                    log_info "Found navigation activity:"
                    echo "$nav_logs" | while IFS= read -r line; do
                        echo "  🧭 $line"
                    done
                    return 0
                fi
                ;;
            "input")
                # Look for input-related activity
                local input_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 5s --predicate 'category contains "UIKit"' | \
                    grep -i "textfield\|textview\|keyboard" | head -3)
                
                if [[ -n "$input_logs" ]]; then
                    log_info "Found input activity:"
                    echo "$input_logs" | while IFS= read -r line; do
                        echo "  ⌨️ $line"
                    done
                    return 0
                fi
                ;;
            "button")
                # Look for button-related activity
                local button_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 5s --predicate 'category contains "UIKit"' | \
                    grep -i "button\|tap\|touch" | head -3)
                
                if [[ -n "$button_logs" ]]; then
                    log_info "Found button activity:"
                    echo "$button_logs" | while IFS= read -r line; do
                        echo "  👆 $line"
                    done
                    return 0
                fi
                ;;
        esac
    fi
    
    # Strategy 3: Look for app-specific logs if bundle ID is available
    if [[ -n "$BUNDLE_ID" ]]; then
        local app_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            log show --last 5s --predicate 'subsystem contains "'"$BUNDLE_ID"'"' | \
            grep -i "$element" | head -3)
        
        if [[ -n "$app_logs" ]]; then
            log_info "Found app-specific references to '$element':"
            echo "$app_logs" | while IFS= read -r line; do
                echo "  📱 $line"
            done
            return 0
        fi
    fi
    
    # Strategy 4: Fuzzy matching for common UI patterns
    case "$element" in
        *"search"*|*"Search"*)
            local search_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 5s --predicate 'category contains "UIKit"' | \
                grep -i "search" | head -1)
            
            if [[ -n "$search_activity" ]]; then
                log_info "Found search-related activity"
                return 0
            fi
            ;;
        *"back"*|*"Back"*)
            local nav_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 5s --predicate 'category contains "UIKit"' | \
                grep -i "navigation\|back" | head -1)
            
            if [[ -n "$nav_activity" ]]; then
                log_info "Found navigation activity"
                return 0
            fi
            ;;
        *"home"*|*"Home"*)
            local home_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 5s --predicate 'category contains "UIKit"' | \
                grep -i "home\|main" | head -1)
            
            if [[ -n "$home_activity" ]]; then
                log_info "Found home-related activity"
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Monitor app state during wait
monitor_app_state() {
    if [[ "$VALIDATE_STATE" == false ]]; then
        return 0
    fi
    
    # Check if app is still active by looking for recent activity
    local recent_activity=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 3s --predicate 'category contains "UIKit"' | \
        head -5)
    
    if [[ -z "$recent_activity" ]]; then
        log_warning "No recent app activity detected"
        return 1
    fi
    
    # Check for app-specific activity if bundle ID available
    if [[ -n "$BUNDLE_ID" ]]; then
        local app_activity=$(echo "$recent_activity" | grep "$BUNDLE_ID" || echo "")
        if [[ -z "$app_activity" ]]; then
            log_warning "No recent activity for app: $BUNDLE_ID"
            return 1
        fi
    fi
    
    return 0
}

# Monitor navigation events in logs
monitor_navigation_logs() {
    if [[ "$LOG_EVENTS" == false ]]; then
        return 0
    fi
    
    # Get recent navigation-related log entries
    local nav_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 3s --predicate 'category contains "UIKit"' | \
        grep -E "viewDidLoad|viewWillAppear|viewDidAppear|Navigation" | tail -3)
    
    if [[ -n "$nav_logs" ]]; then
        log_info "Recent navigation events:"
        echo "$nav_logs" | while IFS= read -r line; do
            echo "  🧭 $line"
        done
    fi
}

# Attempt recovery if element not found
attempt_recovery() {
    if [[ "$ENABLE_RECOVERY" == false ]]; then
        return 1
    fi
    
    log_warning "Attempting iOS recovery..."
    
    # Recovery strategy 1: Simulate home button and relaunch
    if [[ -n "$BUNDLE_ID" ]]; then
        log_info "Recovery attempt 1: Relaunch app"
        xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            osascript -e 'tell application "iOS Simulator" to activate'
        sleep 1
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID"
        sleep 5
        
        if find_element_adaptive "$ELEMENT" "$SEMANTIC_CONTEXT"; then
            log_success "Recovery successful: element found after app relaunch"
            return 0
        fi
    fi
    
    # Recovery strategy 2: Reset simulator and restart app
    log_info "Recovery attempt 2: Terminate and restart app"
    if [[ -n "$BUNDLE_ID" ]]; then
        xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true
        sleep 2
        xcrun simctl launch "$IOS_SIMULATOR_UDID" "$BUNDLE_ID"
        sleep 5
        
        if find_element_adaptive "$ELEMENT" "$SEMANTIC_CONTEXT"; then
            log_success "Recovery successful: element found after restart"
            return 0
        fi
    fi
    
    # Recovery strategy 3: Uninstall and reinstall app (not implemented - too destructive)
    log_warning "Advanced recovery options not implemented"
    
    log_error "All recovery attempts failed"
    return 1
}

# Main waiting loop
wait_for_element() {
    local element="$1"
    local timeout="$2"
    local context="$3"
    
    log_check "Waiting for iOS element: '$element'"
    if [[ -n "$context" ]]; then
        log_info "Using semantic context: $context"
    fi
    if [[ -n "$PREFERRED_METHOD" ]]; then
        log_info "Preferred search method: $PREFERRED_METHOD"
    fi
    log_info "Timeout: ${timeout}s, Polling interval: ${POLLING_INTERVAL}s"
    
    # Ensure simulator is ready
    check_simulator_status
    
    local start_time=$(date +%s)
    local attempts=0
    
    while [[ $(($(date +%s) - start_time)) -lt $timeout ]]; do
        attempts=$((attempts + 1))
        
        # Monitor app state if requested
        if ! monitor_app_state; then
            log_warning "App state validation failed on attempt $attempts"
        fi
        
        # Look for the element
        if find_element_adaptive "$element" "$context"; then
            log_success "Element found after $attempts attempts ($(( $(date +%s) - start_time ))s)"
            return 0
        fi
        
        # Log navigation events if requested
        monitor_navigation_logs
        
        # Show progress every 10 attempts
        if [[ $((attempts % 10)) -eq 0 ]]; then
            log_info "Attempt $attempts: Still waiting for '$element'..."
        fi
        
        sleep "$POLLING_INTERVAL"
    done
    
    log_error "Timeout after ${timeout}s waiting for iOS element: '$element'"
    
    # Attempt recovery if enabled
    if attempt_recovery; then
        return 0
    fi
    
    return 1
}

# Provide detailed information about why element wasn't found
analyze_failure() {
    log_info "Analyzing why iOS element '$ELEMENT' was not found..."
    
    # Check recent iOS logs for any relevant activity
    local recent_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 30s --predicate 'category contains "UIKit" OR category contains "UIAccessibility"' | \
        tail -10)
    
    if [[ -n "$recent_logs" ]]; then
        log_info "Recent iOS activity:"
        echo "$recent_logs" | while IFS= read -r line; do
            echo "  📱 $line"
        done
    else
        log_warning "No recent iOS activity detected - app may not be active"
    fi
    
    # Check current app state
    if [[ -n "$BUNDLE_ID" ]]; then
        local app_state=$(xcrun simctl listapps "$IOS_SIMULATOR_UDID" | grep "$BUNDLE_ID" || echo "")
        if [[ -n "$app_state" ]]; then
            log_info "App is installed: $BUNDLE_ID"
        else
            log_error "App not found: $BUNDLE_ID"
        fi
        
        # Check if app is running
        local app_processes=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" ps aux | grep "$BUNDLE_ID" || echo "")
        if [[ -n "$app_processes" ]]; then
            log_info "App appears to be running"
        else
            log_warning "App may not be running"
        fi
    fi
    
    # Suggest using XCUITest for more detailed element inspection
    log_info "💡 For detailed element inspection, consider using XCUITest framework"
    log_info "💡 Check accessibility identifiers in your iOS app for more reliable element finding"
}

# Main execution
main() {
    if wait_for_element "$ELEMENT" "$TIMEOUT" "$SEMANTIC_CONTEXT"; then
        exit 0
    else
        analyze_failure
        exit 1
    fi
}

# Run main function
main
