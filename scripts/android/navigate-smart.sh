#!/bin/bash
# Smart Android navigation with self-healing and multiple fallback strategies
# Usage: ./navigate-smart.sh [options] TARGET
#   --timeout SECONDS       Set timeout (default: 30)
#   --validate              Validate navigation success
#   --max-attempts N        Maximum navigation attempts (default: 3)
#   --recovery              Enable automatic recovery
#   --path-optimization     Use shortest path navigation
#   --log-navigation        Log navigation events
#   --context CONTEXT       Navigation context (search|home|settings|back)

set -euo pipefail

# Auto-source session environment
if [[ -f .claude-env ]]; then
    source .claude-env
fi

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

# Ensure we have device serial
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "❌ ANDROID_SERIAL not set. Run from a session or use ./run-with-env.sh"
    exit 1
fi

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

# Get current activity
get_current_activity() {
    adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
        grep "ResumedActivity" | head -1 | awk '{print $4}' | cut -d'/' -f2 || echo ""
}

# Get current fragment (if possible from logs)
get_current_fragment() {
    adb -s "$ANDROID_SERIAL" logcat -d | \
        grep -E "${APPID:-}.*Fragment" | tail -1 | \
        grep -o "Fragment[^[:space:]]*" | tail -1 || echo ""
}

# Log navigation event
log_navigation_event() {
    if [[ "$LOG_NAVIGATION" == false ]]; then
        return 0
    fi
    
    local event="$1"
    local from_activity="$2"
    local to_activity="$3"
    
    log_nav "Navigation event: $event"
    log_info "From: $from_activity"
    log_info "To: $to_activity"
    
    # Log to file for analysis
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $event: $from_activity -> $to_activity" >> navigation_log.txt
}

# Wait for activity change
wait_for_activity_change() {
    local expected_activity="$1"
    local timeout="${2:-10}"
    local start_activity="$3"
    
    local start_time=$(date +%s)
    
    while [[ $(($(date +%s) - start_time)) -lt $timeout ]]; do
        local current_activity=$(get_current_activity)
        
        if [[ -n "$expected_activity" && "$current_activity" == *"$expected_activity"* ]]; then
            log_success "Activity changed to: $current_activity"
            log_navigation_event "Activity change" "$start_activity" "$current_activity"
            return 0
        elif [[ -n "$start_activity" && "$current_activity" != "$start_activity" ]]; then
            log_success "Activity changed from $start_activity to: $current_activity"
            log_navigation_event "Activity change" "$start_activity" "$current_activity"
            return 0
        fi
        
        sleep 1
    done
    
    log_warning "No activity change detected within ${timeout}s"
    return 1
}

# Validate navigation success
validate_navigation_success() {
    local target="$1"
    
    if [[ "$VALIDATE_SUCCESS" == false ]]; then
        return 0
    fi
    
    log_info "Validating navigation to: $target"
    
    # Strategy 1: Check if target element is now visible
    if ./scripts/android/wait-for-element.sh --timeout 5 "$target"; then
        log_success "Navigation validated: target element found"
        return 0
    fi
    
    # Strategy 2: Check activity change
    local current_activity=$(get_current_activity)
    if [[ "$current_activity" == *"$target"* ]]; then
        log_success "Navigation validated: activity contains target name"
        return 0
    fi
    
    # Strategy 3: Check for expected UI patterns
    case "$target" in
        "search"|"Search")
            if ./scripts/android/wait-for-element.sh --timeout 5 --context search "EditText"; then
                log_success "Navigation validated: search input field found"
                return 0
            fi
            ;;
        "home"|"Home")
            if ./scripts/android/wait-for-element.sh --timeout 5 --context navigation "Home"; then
                log_success "Navigation validated: home elements found"
                return 0
            fi
            ;;
        "settings"|"Settings")
            if ./scripts/android/wait-for-element.sh --timeout 5 --context navigation "Settings"; then
                log_success "Navigation validated: settings elements found"
                return 0
            fi
            ;;
    esac
    
    # Strategy 4: Check logs for navigation events
    local recent_logs=$(adb -s "$ANDROID_SERIAL" logcat -T 5 | \
        grep -E "Activity|Fragment|Navigation" | \
        grep -i "$target" | tail -3)
    
    if [[ -n "$recent_logs" ]]; then
        log_success "Navigation validated: target found in logs"
        log_info "Log evidence:"
        echo "$recent_logs" | while IFS= read -r line; do
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
    
    local start_activity=$(get_current_activity)
    log_info "Starting from activity: $start_activity"
    
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
    
    # Strategy 1: Look for search button/tab
    if ./scripts/android/ui-click.sh --desc "Search" 2>/dev/null || \
       ./scripts/android/ui-click.sh --text "Search" 2>/dev/null; then
        log_success "Clicked search element"
        wait_for_activity_change "" 5 "$(get_current_activity)"
        return 0
    fi
    
    # Strategy 2: Look for search icon
    if ./scripts/android/ui-click.sh --desc "Search icon" 2>/dev/null || \
       ./scripts/android/ui-click.sh --desc "Search button" 2>/dev/null; then
        log_success "Clicked search icon"
        wait_for_activity_change "" 5 "$(get_current_activity)"
        return 0
    fi
    
    # Strategy 3: Look for floating action button or search FAB
    if ./scripts/android/ui-click.sh --class "android.widget.ImageButton" --index 0 2>/dev/null; then
        log_success "Clicked potential search button"
        sleep 2
        if ./scripts/android/wait-for-element.sh --timeout 3 --context search "EditText"; then
            log_success "Search input field appeared"
            return 0
        fi
    fi
    
    # Strategy 4: Try menu navigation
    if navigate_via_menu "Search"; then
        return 0
    fi
    
    log_error "Could not navigate to search"
    return 1
}

# Navigate to home
navigate_to_home() {
    local context="$1"
    
    log_nav "Navigating to home..."
    
    # Strategy 1: Press home key (returns to app's main activity)
    adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_HOME
    sleep 1
    if [[ -n "${MAIN:-}" ]]; then
        adb -s "$ANDROID_SERIAL" shell am start -n "$MAIN"
        wait_for_activity_change "" 5 "$(get_current_activity)"
        return 0
    fi
    
    # Strategy 2: Look for home button/tab
    if ./scripts/android/ui-click.sh --desc "Home" 2>/dev/null || \
       ./scripts/android/ui-click.sh --text "Home" 2>/dev/null; then
        log_success "Clicked home element"
        wait_for_activity_change "" 5 "$(get_current_activity)"
        return 0
    fi
    
    # Strategy 3: Navigate back to root
    local back_attempts=0
    while [[ $back_attempts -lt 5 ]]; do
        adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK
        sleep 1
        back_attempts=$((back_attempts + 1))
        
        local current_activity=$(get_current_activity)
        if [[ "$current_activity" == *"MainActivity"* || "$current_activity" == *"HomeActivity"* ]]; then
            log_success "Reached home via back navigation"
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
    
    # Strategy 1: Look for settings button
    if ./scripts/android/ui-click.sh --desc "Settings" 2>/dev/null || \
       ./scripts/android/ui-click.sh --text "Settings" 2>/dev/null; then
        log_success "Clicked settings element"
        wait_for_activity_change "Settings" 5 "$(get_current_activity)"
        return 0
    fi
    
    # Strategy 2: Look for overflow menu and then settings
    if ./scripts/android/ui-click.sh --desc "More options" 2>/dev/null || \
       ./scripts/android/ui-click.sh --desc "Overflow menu" 2>/dev/null; then
        sleep 1
        if ./scripts/android/ui-click.sh --text "Settings" 2>/dev/null; then
            log_success "Found settings in overflow menu"
            wait_for_activity_change "Settings" 5 "$(get_current_activity)"
            return 0
        fi
    fi
    
    # Strategy 3: Try menu navigation
    if navigate_via_menu "Settings"; then
        return 0
    fi
    
    log_error "Could not navigate to settings"
    return 1
}

# Navigate back
navigate_back() {
    local context="$1"
    
    log_nav "Navigating back..."
    
    local start_activity=$(get_current_activity)
    
    # Strategy 1: Use back button
    adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK
    
    if wait_for_activity_change "" 3 "$start_activity"; then
        log_success "Back navigation completed"
        return 0
    fi
    
    # Strategy 2: Look for up/back button in UI
    if ./scripts/android/ui-click.sh --desc "Navigate up" 2>/dev/null || \
       ./scripts/android/ui-click.sh --desc "Back" 2>/dev/null; then
        log_success "Clicked back/up button"
        wait_for_activity_change "" 3 "$start_activity"
        return 0
    fi
    
    log_warning "Back navigation may not have changed activities"
    return 0  # Back navigation might not always change activities
}

# Navigate to menu
navigate_to_menu() {
    local context="$1"
    
    log_nav "Navigating to menu..."
    
    # Strategy 1: Look for hamburger menu
    if ./scripts/android/ui-click.sh --desc "Open navigation drawer" 2>/dev/null || \
       ./scripts/android/ui-click.sh --desc "Navigation drawer" 2>/dev/null; then
        log_success "Opened navigation drawer"
        sleep 1
        return 0
    fi
    
    # Strategy 2: Look for menu button
    if ./scripts/android/ui-click.sh --desc "Menu" 2>/dev/null || \
       ./scripts/android/ui-click.sh --text "Menu" 2>/dev/null; then
        log_success "Clicked menu element"
        sleep 1
        return 0
    fi
    
    # Strategy 3: Try overflow menu
    if ./scripts/android/ui-click.sh --desc "More options" 2>/dev/null; then
        log_success "Opened overflow menu"
        sleep 1
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
        if ./scripts/android/ui-click.sh --text "$target" 2>/dev/null || \
           ./scripts/android/ui-click.sh --desc "$target" 2>/dev/null; then
            log_success "Found $target in menu"
            wait_for_activity_change "$target" 5 "$(get_current_activity)"
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
    
    # Strategy 1: Direct click on target element
    if ./scripts/android/wait-for-element.sh --timeout 5 "$target"; then
        if ./scripts/android/ui-click.sh --text "$target" 2>/dev/null || \
           ./scripts/android/ui-click.sh --desc "$target" 2>/dev/null; then
            log_success "Clicked target element directly"
            wait_for_activity_change "$target" 5 "$(get_current_activity)"
            return 0
        fi
    fi
    
    # Strategy 2: Search for target in current UI
    if [[ -n "$context" ]]; then
        if ./scripts/android/wait-for-element.sh --timeout 5 --context "$context" "$target"; then
            if ./scripts/android/ui-click.sh --text "$target" 2>/dev/null; then
                log_success "Found and clicked target with context"
                wait_for_activity_change "$target" 5 "$(get_current_activity)"
                return 0
            fi
        fi
    fi
    
    # Strategy 3: Try menu navigation
    if navigate_via_menu "$target"; then
        return 0
    fi
    
    # Strategy 4: Try tab navigation
    if ./scripts/android/ui-click.sh --desc "$target tab" 2>/dev/null || \
       ./scripts/android/ui-click.sh --text "$target" 2>/dev/null; then
        log_success "Clicked target tab"
        wait_for_activity_change "$target" 5 "$(get_current_activity)"
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
    
    log_warning "Attempting navigation recovery..."
    
    # Recovery 1: Return to known good state (home)
    log_info "Recovery step 1: Return to home"
    if navigate_to_home ""; then
        log_success "Returned to home successfully"
        return 0
    fi
    
    # Recovery 2: Restart app
    if [[ -n "${APPID:-}" && -n "${MAIN:-}" ]]; then
        log_info "Recovery step 2: Restart app"
        adb -s "$ANDROID_SERIAL" shell am force-stop "$APPID"
        sleep 2
        adb -s "$ANDROID_SERIAL" shell am start -n "$MAIN"
        sleep 5
        log_success "App restarted"
        return 0
    fi
    
    # Recovery 3: Clear app state
    if [[ -n "${APPID:-}" && -n "${MAIN:-}" ]]; then
        log_info "Recovery step 3: Clear app state"
        adb -s "$ANDROID_SERIAL" shell pm clear "$APPID"
        sleep 2
        adb -s "$ANDROID_SERIAL" shell am start -n "$MAIN"
        sleep 5
        log_success "App state cleared and restarted"
        return 0
    fi
    
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
                adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK
                sleep 1
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
    echo "🧭 Smart Android Navigation"
    echo "========================="
    echo "Target: $TARGET"
    echo "Device: $ANDROID_SERIAL"
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