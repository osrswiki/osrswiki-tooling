#!/bin/bash
# Android app state validation without screenshots
# Usage: ./validate-state.sh [options]
#   --activity          Check current activity
#   --fragments         Check active fragments
#   --services          Check running services
#   --connectivity      Check network connectivity
#   --permissions       Check app permissions
#   --storage           Check storage and database state
#   --ui-elements       Check for specific UI elements
#   --app-state         Check overall app state
#   --performance       Check performance metrics
#   --all               Run all validations
#   --wait-for ELEMENT  Wait for specific element or state
#   --timeout SECONDS   Set timeout for wait operations (default: 30)

set -euo pipefail

# Auto-source session environment
if [[ -f .claude-env ]]; then
    source .claude-env
fi

# Configuration
CHECK_ACTIVITY=false
CHECK_FRAGMENTS=false
CHECK_SERVICES=false
CHECK_CONNECTIVITY=false
CHECK_PERMISSIONS=false
CHECK_STORAGE=false
CHECK_UI_ELEMENTS=false
CHECK_APP_STATE=false
CHECK_PERFORMANCE=false
CHECK_ALL=false
WAIT_FOR=""
TIMEOUT=30

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --activity          Check current activity"
    echo "  --fragments         Check active fragments"
    echo "  --services          Check running services"
    echo "  --connectivity      Check network connectivity"
    echo "  --permissions       Check app permissions"
    echo "  --storage           Check storage and database state"
    echo "  --ui-elements       Check for specific UI elements"
    echo "  --app-state         Check overall app state"
    echo "  --performance       Check performance metrics"
    echo "  --all               Run all validations"
    echo "  --wait-for ELEMENT  Wait for specific element or state"
    echo "  --timeout SECONDS   Set timeout for wait operations (default: 30)"
    echo "  --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --activity                        # Check current activity"
    echo "  $0 --all                            # Run all state checks"
    echo "  $0 --wait-for 'MainActivity'        # Wait for MainActivity"
    echo "  $0 --ui-elements --timeout 10       # Check UI elements with 10s timeout"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --activity)
            CHECK_ACTIVITY=true
            shift
            ;;
        --fragments)
            CHECK_FRAGMENTS=true
            shift
            ;;
        --services)
            CHECK_SERVICES=true
            shift
            ;;
        --connectivity)
            CHECK_CONNECTIVITY=true
            shift
            ;;
        --permissions)
            CHECK_PERMISSIONS=true
            shift
            ;;
        --storage)
            CHECK_STORAGE=true
            shift
            ;;
        --ui-elements)
            CHECK_UI_ELEMENTS=true
            shift
            ;;
        --app-state)
            CHECK_APP_STATE=true
            shift
            ;;
        --performance)
            CHECK_PERFORMANCE=true
            shift
            ;;
        --all)
            CHECK_ALL=true
            shift
            ;;
        --wait-for)
            WAIT_FOR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Ensure we have device serial and app ID
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "❌ ANDROID_SERIAL not set. Run from a session or use ./run-with-env.sh"
    exit 1
fi

if [[ -z "${APPID:-}" ]]; then
    echo "❌ APPID not set. Run from a session or use ./run-with-env.sh"
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

# Check current activity
check_activity() {
    log_check "Checking current activity..."
    
    local current_activity=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
        grep "ResumedActivity" | head -1 | awk '{print $4}' | cut -d'/' -f1)
    
    if [[ -n "$current_activity" ]]; then
        if [[ "$current_activity" == "$APPID" ]]; then
            log_success "App is in foreground: $current_activity"
            
            # Get detailed activity info
            local activity_details=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
                grep -A 10 "ResumedActivity.*$APPID")
            
            local activity_name=$(echo "$activity_details" | grep "ResumedActivity" | \
                awk '{print $4}' | cut -d'/' -f2)
            
            log_info "Current activity: $activity_name"
            
            # Check activity state
            local activity_state=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
                grep -A 5 "ResumedActivity.*$APPID" | grep -E "state=|mResumed=")
            
            if [[ -n "$activity_state" ]]; then
                log_info "Activity state: $activity_state"
            fi
            
            return 0
        else
            log_warning "Different app in foreground: $current_activity"
            return 1
        fi
    else
        log_error "No activity in foreground"
        return 1
    fi
}

# Check active fragments
check_fragments() {
    log_check "Checking active fragments..."
    
    # This requires app-specific logging or debugging tools
    # We'll check for fragment-related logs
    local fragment_logs=$(adb -s "$ANDROID_SERIAL" logcat -d | \
        grep -E "$APPID.*Fragment" | tail -10)
    
    if [[ -n "$fragment_logs" ]]; then
        log_info "Recent fragment activity:"
        echo "$fragment_logs" | while IFS= read -r line; do
            echo "  $line"
        done
        log_success "Fragment logs found"
    else
        log_warning "No recent fragment activity in logs"
    fi
}

# Check running services
check_services() {
    log_check "Checking running services..."
    
    local running_services=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity services | \
        grep -E "ServiceRecord.*$APPID" | head -10)
    
    if [[ -n "$running_services" ]]; then
        log_info "Running services:"
        echo "$running_services" | while IFS= read -r line; do
            local service_name=$(echo "$line" | awk '{print $2}' | cut -d'/' -f2)
            echo "  📋 $service_name"
        done
        log_success "Services are running"
    else
        log_info "No services currently running"
    fi
}

# Check network connectivity
check_connectivity() {
    log_check "Checking network connectivity..."
    
    # Check if device has network connectivity
    local connectivity=$(adb -s "$ANDROID_SERIAL" shell dumpsys connectivity | \
        grep -E "NetworkAgentInfo.*CONNECTED" | head -1)
    
    if [[ -n "$connectivity" ]]; then
        log_success "Device has network connectivity"
        
        # Check app network permissions
        local network_perms=$(adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID" | \
            grep -E "android.permission.INTERNET|android.permission.ACCESS_NETWORK_STATE")
        
        if [[ -n "$network_perms" ]]; then
            log_success "App has network permissions"
            log_info "Network permissions: $network_perms"
        else
            log_warning "App may not have network permissions"
        fi
        
        # Test network connectivity from app perspective
        local network_test=$(adb -s "$ANDROID_SERIAL" shell ping -c 1 8.8.8.8 2>/dev/null | \
            grep "1 packets transmitted" || echo "")
        
        if [[ -n "$network_test" ]]; then
            log_success "Network connectivity test passed"
        else
            log_warning "Network connectivity test failed"
        fi
    else
        log_error "Device has no network connectivity"
        return 1
    fi
}

# Check app permissions
check_permissions() {
    log_check "Checking app permissions..."
    
    local granted_perms=$(adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID" | \
        grep -A 1 "granted=true" | grep "android.permission" | sort | uniq)
    
    local denied_perms=$(adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID" | \
        grep -A 1 "granted=false" | grep "android.permission" | sort | uniq)
    
    if [[ -n "$granted_perms" ]]; then
        log_success "Granted permissions:"
        echo "$granted_perms" | while IFS= read -r perm; do
            echo "  ✅ $perm"
        done
    fi
    
    if [[ -n "$denied_perms" ]]; then
        log_warning "Denied permissions:"
        echo "$denied_perms" | while IFS= read -r perm; do
            echo "  ❌ $perm"
        done
    fi
    
    # Check for runtime permissions
    local runtime_perms=$(adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID" | \
        grep -A 5 "runtime permissions")
    
    if [[ -n "$runtime_perms" ]]; then
        log_info "Runtime permissions status:"
        echo "$runtime_perms"
    fi
}

# Check storage and database state
check_storage() {
    log_check "Checking storage and database state..."
    
    # Check app data directory
    local app_data=$(adb -s "$ANDROID_SERIAL" shell du -sh "/data/data/$APPID" 2>/dev/null || echo "")
    
    if [[ -n "$app_data" ]]; then
        log_success "App data directory exists: $app_data"
    else
        log_warning "Cannot access app data directory (may require root)"
    fi
    
    # Check external storage usage
    local external_storage=$(adb -s "$ANDROID_SERIAL" shell du -sh "/sdcard/Android/data/$APPID" 2>/dev/null || echo "")
    
    if [[ -n "$external_storage" ]]; then
        log_info "External storage usage: $external_storage"
    else
        log_info "No external storage usage found"
    fi
    
    # Check for database-related logs
    local db_logs=$(adb -s "$ANDROID_SERIAL" logcat -d | \
        grep -E "$APPID.*(database|sqlite|Database|SQLite)" | tail -5)
    
    if [[ -n "$db_logs" ]]; then
        log_info "Recent database activity:"
        echo "$db_logs" | while IFS= read -r line; do
            echo "  🗄️ $line"
        done
    else
        log_info "No recent database activity in logs"
    fi
}

# Check for specific UI elements
check_ui_elements() {
    log_check "Checking UI elements..."
    
    # Dump UI hierarchy
    if adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/ui-dump.xml 2>/dev/null && \
       adb -s "$ANDROID_SERIAL" pull /sdcard/ui-dump.xml ./ui-dump.xml >/dev/null 2>&1; then
        
        log_success "UI hierarchy dumped successfully"
        
        # Analyze UI elements
        local total_elements=$(xmllint --xpath "count(//*)" ./ui-dump.xml 2>/dev/null || echo "0")
        local clickable_elements=$(xmllint --xpath "count(//*[@clickable='true'])" ./ui-dump.xml 2>/dev/null || echo "0")
        local text_elements=$(xmllint --xpath "count(//*[@text!=''])" ./ui-dump.xml 2>/dev/null || echo "0")
        local input_elements=$(xmllint --xpath "count(//android.widget.EditText)" ./ui-dump.xml 2>/dev/null || echo "0")
        
        log_info "UI Elements Summary:"
        echo "  📊 Total elements: $total_elements"
        echo "  👆 Clickable elements: $clickable_elements"
        echo "  📝 Text elements: $text_elements"
        echo "  ⌨️ Input elements: $input_elements"
        
        # Check for common UI patterns
        if xmllint --xpath "//*[contains(@text, 'Search') or contains(@content-desc, 'Search')]" ./ui-dump.xml >/dev/null 2>&1; then
            log_success "Search functionality detected"
        fi
        
        if xmllint --xpath "//android.widget.RecyclerView | //android.widget.ListView" ./ui-dump.xml >/dev/null 2>&1; then
            log_success "List/RecyclerView detected"
        fi
        
        if xmllint --xpath "//*[contains(@content-desc, 'Navigate up') or contains(@content-desc, 'Back')]" ./ui-dump.xml >/dev/null 2>&1; then
            log_success "Navigation elements detected"
        fi
        
        # Clean up
        rm -f ./ui-dump.xml
    else
        log_error "Failed to dump UI hierarchy"
        return 1
    fi
}

# Check overall app state
check_app_state() {
    log_check "Checking overall app state..."
    
    # Check if app is installed
    local app_installed=$(adb -s "$ANDROID_SERIAL" shell pm list packages | grep "$APPID" || echo "")
    
    if [[ -n "$app_installed" ]]; then
        log_success "App is installed: $app_installed"
    else
        log_error "App is not installed"
        return 1
    fi
    
    # Check if app is running
    local app_pid=$(adb -s "$ANDROID_SERIAL" shell pidof "$APPID" 2>/dev/null || echo "")
    
    if [[ -n "$app_pid" ]]; then
        log_success "App is running (PID: $app_pid)"
        
        # Check app's memory usage
        local memory_info=$(adb -s "$ANDROID_SERIAL" shell dumpsys meminfo "$APPID" | \
            grep "TOTAL" | head -1)
        
        if [[ -n "$memory_info" ]]; then
            log_info "Memory usage: $memory_info"
        fi
    else
        log_warning "App is not currently running"
    fi
    
    # Check app version
    local app_version=$(adb -s "$ANDROID_SERIAL" shell dumpsys package "$APPID" | \
        grep -E "versionName|versionCode" | head -2)
    
    if [[ -n "$app_version" ]]; then
        log_info "App version info:"
        echo "$app_version" | while IFS= read -r line; do
            echo "  📱 $line"
        done
    fi
}

# Check performance metrics
check_performance() {
    log_check "Checking performance metrics..."
    
    if [[ -z "${APPID:-}" ]]; then
        log_warning "Cannot check performance metrics without APPID"
        return 1
    fi
    
    # Check if app is running first
    local app_pid=$(adb -s "$ANDROID_SERIAL" shell pidof "$APPID" 2>/dev/null || echo "")
    
    if [[ -z "$app_pid" ]]; then
        log_warning "App is not running, cannot check performance"
        return 1
    fi
    
    # Memory usage
    local memory_stats=$(adb -s "$ANDROID_SERIAL" shell dumpsys meminfo "$APPID" | \
        grep -E "TOTAL|Native Heap|Dalvik Heap")
    
    if [[ -n "$memory_stats" ]]; then
        log_info "Memory statistics:"
        echo "$memory_stats" | while IFS= read -r line; do
            echo "  🧠 $line"
        done
    fi
    
    # CPU usage (approximate)
    local cpu_stats=$(adb -s "$ANDROID_SERIAL" shell top -p "$app_pid" -n 1 | tail -1)
    
    if [[ -n "$cpu_stats" ]]; then
        log_info "CPU usage: $cpu_stats"
    fi
    
    # Check for ANR or performance issues in logs
    local anr_logs=$(adb -s "$ANDROID_SERIAL" logcat -d | \
        grep -E "$APPID.*(ANR|Application Not Responding|Slow)" | tail -3)
    
    if [[ -n "$anr_logs" ]]; then
        log_warning "Performance issues detected in logs:"
        echo "$anr_logs" | while IFS= read -r line; do
            echo "  ⚠️ $line"
        done
    else
        log_success "No performance issues detected in logs"
    fi
}

# Wait for specific element or state
wait_for_state() {
    local target="$1"
    local timeout="${2:-$TIMEOUT}"
    
    log_check "Waiting for: $target (timeout: ${timeout}s)"
    
    local start_time=$(date +%s)
    
    while [[ $(($(date +%s) - start_time)) -lt $timeout ]]; do
        case "$target" in
            *"Activity"*|*"activity"*)
                if check_activity >/dev/null 2>&1; then
                    local current_activity=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
                        grep "ResumedActivity" | awk '{print $4}' | cut -d'/' -f2)
                    if [[ "$current_activity" == *"$target"* ]]; then
                        log_success "Found activity: $current_activity"
                        return 0
                    fi
                fi
                ;;
            *"MainActivity"*|*"SearchActivity"*|*"SettingsActivity"*)
                local current_activity=$(adb -s "$ANDROID_SERIAL" shell dumpsys activity activities | \
                    grep "ResumedActivity" | awk '{print $4}' | cut -d'/' -f2)
                if [[ "$current_activity" == *"$target"* ]]; then
                    log_success "Found activity: $current_activity"
                    return 0
                fi
                ;;
            *)
                # Try to find UI element
                if adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/ui-dump.xml 2>/dev/null && \
                   adb -s "$ANDROID_SERIAL" pull /sdcard/ui-dump.xml ./ui-dump.xml >/dev/null 2>&1; then
                    
                    if xmllint --xpath "//*[@text='$target' or @content-desc='$target' or contains(@resource-id, '$target')]" ./ui-dump.xml >/dev/null 2>&1; then
                        log_success "Found UI element: $target"
                        rm -f ./ui-dump.xml
                        return 0
                    fi
                    rm -f ./ui-dump.xml
                fi
                ;;
        esac
        
        sleep 1
    done
    
    log_error "Timeout waiting for: $target"
    return 1
}

# Main execution
main() {
    echo "🔍 Android State Validation"
    echo "==========================="
    echo "Device: $ANDROID_SERIAL"
    echo "App: $APPID"
    echo "Timestamp: $(date)"
    echo ""
    
    local exit_code=0
    
    # Handle wait-for option
    if [[ -n "$WAIT_FOR" ]]; then
        wait_for_state "$WAIT_FOR" "$TIMEOUT"
        exit $?
    fi
    
    # Run requested checks
    if [[ "$CHECK_ALL" == true ]]; then
        check_activity || exit_code=1
        echo ""
        check_fragments || exit_code=1
        echo ""
        check_services || exit_code=1
        echo ""
        check_connectivity || exit_code=1
        echo ""
        check_permissions || exit_code=1
        echo ""
        check_storage || exit_code=1
        echo ""
        check_ui_elements || exit_code=1
        echo ""
        check_app_state || exit_code=1
        echo ""
        check_performance || exit_code=1
    else
        if [[ "$CHECK_ACTIVITY" == true ]]; then
            check_activity || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_FRAGMENTS" == true ]]; then
            check_fragments || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_SERVICES" == true ]]; then
            check_services || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_CONNECTIVITY" == true ]]; then
            check_connectivity || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_PERMISSIONS" == true ]]; then
            check_permissions || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_STORAGE" == true ]]; then
            check_storage || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_UI_ELEMENTS" == true ]]; then
            check_ui_elements || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_APP_STATE" == true ]]; then
            check_app_state || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_PERFORMANCE" == true ]]; then
            check_performance || exit_code=1
            echo ""
        fi
    fi
    
    # If no specific checks requested, run basic state check
    if [[ "$CHECK_ACTIVITY" == false && "$CHECK_FRAGMENTS" == false && "$CHECK_SERVICES" == false && \
          "$CHECK_CONNECTIVITY" == false && "$CHECK_PERMISSIONS" == false && "$CHECK_STORAGE" == false && \
          "$CHECK_UI_ELEMENTS" == false && "$CHECK_APP_STATE" == false && "$CHECK_PERFORMANCE" == false && \
          "$CHECK_ALL" == false ]]; then
        check_activity || exit_code=1
        echo ""
        check_app_state || exit_code=1
    fi
    
    echo "🏁 State validation completed"
    if [[ $exit_code -eq 0 ]]; then
        log_success "All checks passed"
    else
        log_warning "Some checks failed or returned warnings"
    fi
    
    exit $exit_code
}

# Run main function
main