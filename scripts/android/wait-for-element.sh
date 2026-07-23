#!/bin/bash
# Smart element waiting with multiple fallback strategies for Android
# Usage: ./wait-for-element.sh [options] ELEMENT
#   --timeout SECONDS       Set timeout (default: 30)
#   --method METHOD         Preferred search method (text|id|desc|class)
#   --polling-interval SEC  Polling interval in seconds (default: 1)
#   --validate-state        Validate app state while waiting
#   --log-events            Log navigation events during wait
#   --recovery              Enable automatic recovery on timeout
#   --context CONTEXT       Provide semantic context for intelligent search

set -euo pipefail

# Auto-source session environment
if [[ -f .claude-env ]]; then
    source .claude-env
fi

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
    echo "  --method METHOD         Preferred search method (text|id|desc|class)"
    echo "  --polling-interval SEC  Polling interval in seconds (default: 1)"
    echo "  --validate-state        Validate app state while waiting"
    echo "  --log-events            Log navigation events during wait"
    echo "  --recovery              Enable automatic recovery on timeout"
    echo "  --context CONTEXT       Provide semantic context (search|navigation|input|button)"
    echo ""
    echo "Examples:"
    echo "  $0 'Search'                           # Wait for Search element"
    echo "  $0 --method id 'search_button'        # Wait for element by ID"
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

log_check() {
    echo -e "${CYAN}🔍 $1${NC}"
}

# Dump UI hierarchy
dump_ui_hierarchy() {
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/ui-dump.xml 2>/dev/null && \
       adb -s "$ANDROID_SERIAL" pull /sdcard/ui-dump.xml ./ui-dump.xml >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Search for element using multiple strategies
find_element_adaptive() {
    local element="$1"
    local context="${2:-}"
    
    if ! dump_ui_hierarchy; then
        return 1
    fi
    
    # Strategy 1: Exact match on preferred method or multiple methods
    case "$PREFERRED_METHOD" in
        "text")
            xmllint --xpath "//*[@text='$element']" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        "id")
            xmllint --xpath "//*[@resource-id='$element' or contains(@resource-id, '$element')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        "desc")
            xmllint --xpath "//*[@content-desc='$element']" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        "class")
            xmllint --xpath "//*[@class='$element']" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        *)
            # Try all methods in order of reliability
            # 1. Content description (accessibility)
            xmllint --xpath "//*[@content-desc='$element']" ./ui-dump.xml >/dev/null 2>&1 && return 0
            # 2. Resource ID
            xmllint --xpath "//*[@resource-id='$element' or contains(@resource-id, '$element')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
            # 3. Text content
            xmllint --xpath "//*[@text='$element']" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
    esac
    
    # Strategy 2: Partial match
    if xmllint --xpath "//*[contains(@content-desc, '$element') or contains(@text, '$element') or contains(@resource-id, '$element')]" ./ui-dump.xml >/dev/null 2>&1; then
        return 0
    fi
    
    # Strategy 3: Case-insensitive search
    local element_lower=$(echo "$element" | tr '[:upper:]' '[:lower:]')
    local element_upper=$(echo "$element" | tr '[:lower:]' '[:upper:]')
    
    if xmllint --xpath "//*[contains(translate(@text, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '$element_lower') or contains(translate(@content-desc, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '$element_lower')]" ./ui-dump.xml >/dev/null 2>&1; then
        return 0
    fi
    
    # Strategy 4: Semantic search based on context
    if [[ -n "$context" ]]; then
        case "$context" in
            "search")
                xmllint --xpath "//*[contains(@content-desc, 'search') or contains(@text, 'search') or contains(@resource-id, 'search')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
                xmllint --xpath "//android.widget.EditText" ./ui-dump.xml >/dev/null 2>&1 && return 0
                ;;
            "navigation")
                xmllint --xpath "//*[contains(@content-desc, 'navigate') or contains(@content-desc, 'menu') or contains(@content-desc, 'drawer')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
                ;;
            "input")
                xmllint --xpath "//android.widget.EditText" ./ui-dump.xml >/dev/null 2>&1 && return 0
                ;;
            "button")
                xmllint --xpath "//android.widget.Button[contains(@text, '$element') or contains(@content-desc, '$element')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
                ;;
        esac
    fi
    
    # Strategy 5: Fuzzy matching for common UI patterns
    case "$element" in
        *"search"*|*"Search"*)
            xmllint --xpath "//*[contains(@content-desc, 'search') or contains(@text, 'search')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
            xmllint --xpath "//android.widget.EditText" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        *"back"*|*"Back"*|*"up"*|*"Up"*)
            xmllint --xpath "//*[contains(@content-desc, 'up') or contains(@content-desc, 'back') or contains(@content-desc, 'navigate up')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        *"menu"*|*"Menu"*)
            xmllint --xpath "//*[contains(@content-desc, 'menu') or contains(@content-desc, 'drawer')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
        *"home"*|*"Home"*)
            xmllint --xpath "//*[contains(@content-desc, 'home') or contains(@text, 'home')]" ./ui-dump.xml >/dev/null 2>&1 && return 0
            ;;
    esac
    
    return 1
}

# Monitor app state during wait
monitor_app_state() {
    if [[ "$VALIDATE_STATE" == false ]]; then
        return 0
    fi
    
    # Quick check if app is still in foreground
    local current_activity=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
        grep "ResumedActivity" | head -1 | awk '{print $4}' | cut -d'/' -f1)
    
    if [[ -n "${APPID:-}" && "$current_activity" != "$APPID" ]]; then
        log_warning "App not in foreground: $current_activity"
        return 1
    fi
    
    return 0
}

# Monitor navigation events in logs
monitor_navigation_logs() {
    if [[ "$LOG_EVENTS" == false ]]; then
        return 0
    fi
    
    # Get recent navigation-related log entries
    local nav_logs=$(adb -s "$ANDROID_SERIAL" logcat -T 3 | \
        grep -E "Activity|Fragment|Navigation" | tail -3)
    
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
    
    log_warning "Attempting recovery..."
    
    # Recovery strategy 1: Go back and try again
    log_info "Recovery attempt 1: Navigate back"
    adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_BACK
    sleep 2
    
    if find_element_adaptive "$ELEMENT" "$SEMANTIC_CONTEXT"; then
        log_success "Recovery successful: element found after back navigation"
        return 0
    fi
    
    # Recovery strategy 2: Return to home screen and restart app
    if [[ -n "${APPID:-}" && -n "${MAIN:-}" ]]; then
        log_info "Recovery attempt 2: Restart app"
        adb -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_HOME
        sleep 2
        adb -s "$ANDROID_SERIAL" shell am start -n "$MAIN"
        sleep 5
        
        if find_element_adaptive "$ELEMENT" "$SEMANTIC_CONTEXT"; then
            log_success "Recovery successful: element found after app restart"
            return 0
        fi
    fi
    
    # Recovery strategy 3: Clear app data and restart
    if [[ -n "${APPID:-}" && -n "${MAIN:-}" ]]; then
        log_info "Recovery attempt 3: Clear app data and restart"
        adb -s "$ANDROID_SERIAL" shell pm clear "$APPID"
        sleep 2
        adb -s "$ANDROID_SERIAL" shell am start -n "$MAIN"
        sleep 5
        
        if find_element_adaptive "$ELEMENT" "$SEMANTIC_CONTEXT"; then
            log_success "Recovery successful: element found after data clear"
            return 0
        fi
    fi
    
    log_error "All recovery attempts failed"
    return 1
}

# Main waiting loop
wait_for_element() {
    local element="$1"
    local timeout="$2"
    local context="$3"
    
    log_check "Waiting for element: '$element'"
    if [[ -n "$context" ]]; then
        log_info "Using semantic context: $context"
    fi
    if [[ -n "$PREFERRED_METHOD" ]]; then
        log_info "Preferred search method: $PREFERRED_METHOD"
    fi
    log_info "Timeout: ${timeout}s, Polling interval: ${POLLING_INTERVAL}s"
    
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
            rm -f ./ui-dump.xml
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
    
    log_error "Timeout after ${timeout}s waiting for element: '$element'"
    
    # Clean up
    rm -f ./ui-dump.xml
    
    # Attempt recovery if enabled
    if attempt_recovery; then
        return 0
    fi
    
    return 1
}

# Provide detailed information about why element wasn't found
analyze_failure() {
    log_info "Analyzing why element '$ELEMENT' was not found..."
    
    if dump_ui_hierarchy; then
        local total_elements=$(xmllint --xpath "count(//*)" ./ui-dump.xml 2>/dev/null || echo "0")
        local clickable_elements=$(xmllint --xpath "count(//*[@clickable='true'])" ./ui-dump.xml 2>/dev/null || echo "0")
        local text_elements=$(xmllint --xpath "count(//*[@text!=''])" ./ui-dump.xml 2>/dev/null || echo "0")
        
        log_info "Current UI state:"
        echo "  📊 Total elements: $total_elements"
        echo "  👆 Clickable elements: $clickable_elements"
        echo "  📝 Text elements: $text_elements"
        
        # Show available similar elements
        log_info "Available elements that might be related:"
        
        # Find elements with similar text
        xmllint --xpath "//*[@text!='' and @text!=' ']/@text" ./ui-dump.xml 2>/dev/null | \
            grep -o 'text="[^"]*"' | sed 's/text="//g; s/"$//g' | \
            grep -i "$(echo "$ELEMENT" | cut -c1-3)" | head -5 | \
            while IFS= read -r text; do
                echo "  📝 Text: '$text'"
            done
        
        # Find elements with similar content descriptions
        xmllint --xpath "//*[@content-desc!='' and @content-desc!=' ']/@content-desc" ./ui-dump.xml 2>/dev/null | \
            grep -o 'content-desc="[^"]*"' | sed 's/content-desc="//g; s/"$//g' | \
            grep -i "$(echo "$ELEMENT" | cut -c1-3)" | head -5 | \
            while IFS= read -r desc; do
                echo "  ♿ Content-desc: '$desc'"
            done
        
        rm -f ./ui-dump.xml
    else
        log_error "Could not dump UI hierarchy for analysis"
    fi
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