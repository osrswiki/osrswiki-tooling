#!/bin/bash
# iOS app state validation without screenshots
# Usage: ./validate-state.sh [options]
#   --viewcontrollers   Check current view controllers
#   --app-state         Check overall app state
#   --simulator         Check iOS Simulator state
#   --connectivity      Check network connectivity
#   --permissions       Check app permissions and capabilities
#   --storage           Check app storage and data
#   --accessibility     Check accessibility elements
#   --performance       Check performance metrics
#   --all               Run all validations
#   --wait-for ELEMENT  Wait for specific element or state
#   --timeout SECONDS   Set timeout for wait operations (default: 30)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

# Configuration
CHECK_VIEWCONTROLLERS=false
CHECK_APP_STATE=false
CHECK_SIMULATOR=false
CHECK_CONNECTIVITY=false
CHECK_PERMISSIONS=false
CHECK_STORAGE=false
CHECK_ACCESSIBILITY=false
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
    echo "  --viewcontrollers   Check current view controllers"
    echo "  --app-state         Check overall app state"
    echo "  --simulator         Check iOS Simulator state"
    echo "  --connectivity      Check network connectivity"
    echo "  --permissions       Check app permissions and capabilities"
    echo "  --storage           Check app storage and data"
    echo "  --accessibility     Check accessibility elements"
    echo "  --performance       Check performance metrics"
    echo "  --all               Run all validations"
    echo "  --wait-for ELEMENT  Wait for specific element or state"
    echo "  --timeout SECONDS   Set timeout for wait operations (default: 30)"
    echo "  --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --viewcontrollers             # Check current view controllers"
    echo "  $0 --all                         # Run all state checks"
    echo "  $0 --wait-for 'SearchViewController' # Wait for SearchViewController"
    echo "  $0 --simulator --timeout 10      # Check simulator with 10s timeout"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --viewcontrollers)
            CHECK_VIEWCONTROLLERS=true
            shift
            ;;
        --app-state)
            CHECK_APP_STATE=true
            shift
            ;;
        --simulator)
            CHECK_SIMULATOR=true
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
        --accessibility)
            CHECK_ACCESSIBILITY=true
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

# Check for macOS environment
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ iOS state validation requires macOS environment"
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

# Check current view controllers
check_viewcontrollers() {
    log_check "Checking current view controllers..."
    
    if [[ -z "$BUNDLE_ID" ]]; then
        log_warning "Cannot check view controllers without BUNDLE_ID"
        return 1
    fi
    
    # Check recent view controller activity in logs
    local vc_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 30s --predicate 'category == "UIKit" OR subsystem contains "ViewController"' | \
        grep -i "viewcontroller\|viewdidload\|viewwillappear\|viewdidappear" | tail -10)
    
    if [[ -n "$vc_logs" ]]; then
        log_info "Recent view controller activity:"
        echo "$vc_logs" | while IFS= read -r line; do
            echo "  📱 $line"
        done
        log_success "View controller logs found"
    else
        log_warning "No recent view controller activity in logs"
    fi
    
    # Try to get the current view controller hierarchy using accessibility
    local accessibility_info=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5s --predicate 'category == "UIAccessibility"' | \
        grep -i "element\|view\|controller" | tail -5)
    
    if [[ -n "$accessibility_info" ]]; then
        log_info "Accessibility view hierarchy info:"
        echo "$accessibility_info" | while IFS= read -r line; do
            echo "  ♿ $line"
        done
    fi
}

# Check overall app state
check_app_state() {
    log_check "Checking overall iOS app state..."
    
    if [[ -z "$BUNDLE_ID" ]]; then
        log_warning "Cannot check app state without BUNDLE_ID"
        return 1
    fi
    
    # Check if app is installed
    local app_info=$(xcrun simctl listapps "$IOS_SIMULATOR_UDID" | grep "$BUNDLE_ID" || echo "")
    
    if [[ -n "$app_info" ]]; then
        log_success "App is installed"
        log_info "App info: $app_info"
        
        # Parse app info for version and state
        local app_version=$(echo "$app_info" | grep -o '"CFBundleVersion" = "[^"]*"' || echo "")
        local app_name=$(echo "$app_info" | grep -o '"CFBundleDisplayName" = "[^"]*"' || echo "")
        
        if [[ -n "$app_version" ]]; then
            log_info "App version: $app_version"
        fi
        
        if [[ -n "$app_name" ]]; then
            log_info "App display name: $app_name"
        fi
    else
        log_error "App is not installed on simulator"
        return 1
    fi
    
    # Check if app is currently running by looking for processes
    local app_processes=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" ps aux | grep "$BUNDLE_ID" || echo "")
    
    if [[ -n "$app_processes" ]]; then
        log_success "App appears to be running"
        log_info "App processes:"
        echo "$app_processes" | while IFS= read -r line; do
            echo "  🔄 $line"
        done
    else
        log_warning "App is not currently running"
    fi
    
    # Check recent app lifecycle events
    local lifecycle_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 1m --predicate 'subsystem contains "UIKit" OR category contains "Application"' | \
        grep -E "applicationDidFinishLaunching|applicationWillEnterForeground|applicationDidEnterBackground|applicationWillTerminate" | \
        tail -5)
    
    if [[ -n "$lifecycle_logs" ]]; then
        log_info "Recent app lifecycle events:"
        echo "$lifecycle_logs" | while IFS= read -r line; do
            echo "  🔄 $line"
        done
    fi
}

# Check iOS Simulator state
check_simulator() {
    log_check "Checking iOS Simulator state..."
    
    # Check simulator status
    local sim_status=$(xcrun simctl list devices | grep "$IOS_SIMULATOR_UDID")
    
    if [[ -n "$sim_status" ]]; then
        log_info "Simulator status: $sim_status"
        
        if echo "$sim_status" | grep -q "Booted"; then
            log_success "Simulator is booted and running"
            
            # Get simulator device info
            local device_info=$(xcrun simctl list devices | grep -B 1 "$IOS_SIMULATOR_UDID" | head -1)
            log_info "Device type: $device_info"
            
            # Check simulator uptime/boot time
            local boot_time=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                log show --last 1h --predicate 'category contains "Simulator"' | \
                grep -i "boot\|start" | head -1)
            
            if [[ -n "$boot_time" ]]; then
                log_info "Boot info: $boot_time"
            fi
            
        elif echo "$sim_status" | grep -q "Shutdown"; then
            log_warning "Simulator is shutdown"
            log_info "💡 Use: xcrun simctl boot \"$IOS_SIMULATOR_UDID\" to start it"
            return 1
        else
            log_warning "Simulator is in unknown state"
            return 1
        fi
    else
        log_error "Simulator not found with UDID: $IOS_SIMULATOR_UDID"
        return 1
    fi
    
    # Check simulator system resources
    local memory_pressure=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 30s --predicate 'category contains "Memory"' | \
        grep -i "pressure\|warning" | tail -3)
    
    if [[ -n "$memory_pressure" ]]; then
        log_warning "Memory pressure detected:"
        echo "$memory_pressure" | while IFS= read -r line; do
            echo "  🧠 $line"
        done
    else
        log_success "No memory pressure detected"
    fi
}

# Check network connectivity
check_connectivity() {
    log_check "Checking iOS network connectivity..."
    
    # Check simulator network status
    local network_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 30s --predicate 'subsystem contains "Network" OR category contains "Network"' | \
        tail -5)
    
    if [[ -n "$network_logs" ]]; then
        log_info "Recent network activity:"
        echo "$network_logs" | while IFS= read -r line; do
            echo "  🌐 $line"
        done
    fi
    
    # Test basic connectivity from simulator
    local connectivity_test=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        ping -c 1 8.8.8.8 2>/dev/null | grep "1 packets transmitted" || echo "")
    
    if [[ -n "$connectivity_test" ]]; then
        log_success "Network connectivity test passed"
    else
        log_warning "Network connectivity test failed"
    fi
    
    # Check for app-specific network activity
    if [[ -n "$BUNDLE_ID" ]]; then
        local app_network_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
            log show --last 1m --predicate 'subsystem contains "Network"' | \
            grep "$BUNDLE_ID" | tail -5)
        
        if [[ -n "$app_network_logs" ]]; then
            log_info "App network activity:"
            echo "$app_network_logs" | while IFS= read -r line; do
                echo "  📡 $line"
            done
        else
            log_info "No recent app network activity detected"
        fi
    fi
}

# Check app permissions and capabilities
check_permissions() {
    log_check "Checking iOS app permissions and capabilities..."
    
    if [[ -z "$BUNDLE_ID" ]]; then
        log_warning "Cannot check permissions without BUNDLE_ID"
        return 1
    fi
    
    # Check for permission-related logs
    local permission_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'category contains "Authorization" OR category contains "Permission"' | \
        grep "$BUNDLE_ID" | tail -10)
    
    if [[ -n "$permission_logs" ]]; then
        log_info "Recent permission activity:"
        echo "$permission_logs" | while IFS= read -r line; do
            echo "  🔐 $line"
        done
    else
        log_info "No recent permission activity detected"
    fi
    
    # Check for privacy-related logs (location, camera, etc.)
    local privacy_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'subsystem contains "TCC" OR category contains "Privacy"' | \
        grep "$BUNDLE_ID" | tail -5)
    
    if [[ -n "$privacy_logs" ]]; then
        log_info "Privacy/TCC activity:"
        echo "$privacy_logs" | while IFS= read -r line; do
            echo "  🛡️ $line"
        done
    fi
    
    # Check app capabilities from Info.plist (if accessible)
    log_info "App capabilities would be checked from Info.plist during installation"
}

# Check app storage and data
check_storage() {
    log_check "Checking iOS app storage and data..."
    
    if [[ -z "$BUNDLE_ID" ]]; then
        log_warning "Cannot check storage without BUNDLE_ID"
        return 1
    fi
    
    # Check for Core Data or database-related logs
    local storage_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'subsystem contains "CoreData" OR category contains "SQLite"' | \
        grep "$BUNDLE_ID" | tail -10)
    
    if [[ -n "$storage_logs" ]]; then
        log_info "Recent storage activity:"
        echo "$storage_logs" | while IFS= read -r line; do
            echo "  🗄️ $line"
        done
        log_success "Storage activity detected"
    else
        log_info "No recent storage activity detected"
    fi
    
    # Check for UserDefaults activity
    local userdefaults_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 2m --predicate 'category contains "UserDefaults"' | \
        grep "$BUNDLE_ID" | tail -5)
    
    if [[ -n "$userdefaults_logs" ]]; then
        log_info "UserDefaults activity:"
        echo "$userdefaults_logs" | while IFS= read -r line; do
            echo "  ⚙️ $line"
        done
    fi
    
    # Check for file system activity
    local filesystem_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 2m --predicate 'category contains "FileSystem" OR subsystem contains "com.apple.FileProvider"' | \
        grep "$BUNDLE_ID" | tail -5)
    
    if [[ -n "$filesystem_logs" ]]; then
        log_info "File system activity:"
        echo "$filesystem_logs" | while IFS= read -r line; do
            echo "  📁 $line"
        done
    fi
}

# Check accessibility elements
check_accessibility() {
    log_check "Checking iOS accessibility elements..."
    
    # Check for accessibility-related logs
    local accessibility_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 30s --predicate 'category contains "UIAccessibility" OR subsystem contains "Accessibility"' | \
        tail -10)
    
    if [[ -n "$accessibility_logs" ]]; then
        log_info "Recent accessibility activity:"
        echo "$accessibility_logs" | while IFS= read -r line; do
            echo "  ♿ $line"
        done
        log_success "Accessibility system is active"
    else
        log_info "No recent accessibility activity (normal for non-VoiceOver usage)"
    fi
    
    # Note: Full accessibility tree inspection would require XCUITest
    log_info "💡 For detailed accessibility tree inspection, use XCUITest framework"
}

# Check performance metrics
check_performance() {
    log_check "Checking iOS performance metrics..."
    
    if [[ -z "$BUNDLE_ID" ]]; then
        log_warning "Cannot check performance metrics without BUNDLE_ID"
        return 1
    fi
    
    # Check for memory warnings
    local memory_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'category contains "Memory" OR subsystem contains "MemoryPressure"' | \
        grep -E "$BUNDLE_ID|didReceiveMemoryWarning|Memory pressure" | tail -5)
    
    if [[ -n "$memory_logs" ]]; then
        log_warning "Memory-related events:"
        echo "$memory_logs" | while IFS= read -r line; do
            echo "  🧠 $line"
        done
    else
        log_success "No memory pressure warnings detected"
    fi
    
    # Check for performance issues
    local performance_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'category contains "Performance" OR subsystem contains "Instruments"' | \
        grep "$BUNDLE_ID" | tail -5)
    
    if [[ -n "$performance_logs" ]]; then
        log_info "Performance events:"
        echo "$performance_logs" | while IFS= read -r line; do
            echo "  ⚡ $line"
        done
    fi
    
    # Check for main thread violations
    local threading_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'category contains "MainThread" OR subsystem contains "Threading"' | \
        grep "$BUNDLE_ID" | tail -3)
    
    if [[ -n "$threading_logs" ]]; then
        log_warning "Threading violations detected:"
        echo "$threading_logs" | while IFS= read -r line; do
            echo "  ⚠️ $line"
        done
    else
        log_success "No threading violations detected"
    fi
    
    # Check for energy/battery impact
    local energy_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
        log show --last 5m --predicate 'category contains "Energy" OR subsystem contains "PowerLog"' | \
        grep "$BUNDLE_ID" | tail -3)
    
    if [[ -n "$energy_logs" ]]; then
        log_info "Energy/battery activity:"
        echo "$energy_logs" | while IFS= read -r line; do
            echo "  🔋 $line"
        done
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
            *"ViewController"*|*"viewcontroller"*)
                # Look for view controller in logs
                local vc_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 2s --predicate 'category == "UIKit"' | \
                    grep -i "$target")
                
                if [[ -n "$vc_logs" ]]; then
                    log_success "Found view controller activity: $target"
                    return 0
                fi
                ;;
            *"View"*|*"view"*)
                # Look for view-related activity
                local view_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 2s --predicate 'category == "UIKit"' | \
                    grep -i "$target")
                
                if [[ -n "$view_logs" ]]; then
                    log_success "Found view activity: $target"
                    return 0
                fi
                ;;
            *)
                # Generic search in accessibility logs
                local generic_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" \
                    log show --last 2s --predicate 'category contains "UIAccessibility"' | \
                    grep -i "$target")
                
                if [[ -n "$generic_logs" ]]; then
                    log_success "Found element in accessibility logs: $target"
                    return 0
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
    echo "🔍 iOS State Validation"
    echo "======================"
    echo "Simulator: $IOS_SIMULATOR_UDID"
    if [[ -n "$BUNDLE_ID" ]]; then
        echo "App: $BUNDLE_ID"
    fi
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
        check_simulator || exit_code=1
        echo ""
        check_app_state || exit_code=1
        echo ""
        check_viewcontrollers || exit_code=1
        echo ""
        check_connectivity || exit_code=1
        echo ""
        check_permissions || exit_code=1
        echo ""
        check_storage || exit_code=1
        echo ""
        check_accessibility || exit_code=1
        echo ""
        check_performance || exit_code=1
    else
        if [[ "$CHECK_SIMULATOR" == true ]]; then
            check_simulator || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_APP_STATE" == true ]]; then
            check_app_state || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_VIEWCONTROLLERS" == true ]]; then
            check_viewcontrollers || exit_code=1
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
        
        if [[ "$CHECK_ACCESSIBILITY" == true ]]; then
            check_accessibility || exit_code=1
            echo ""
        fi
        
        if [[ "$CHECK_PERFORMANCE" == true ]]; then
            check_performance || exit_code=1
            echo ""
        fi
    fi
    
    # If no specific checks requested, run basic state check
    if [[ "$CHECK_VIEWCONTROLLERS" == false && "$CHECK_APP_STATE" == false && "$CHECK_SIMULATOR" == false && \
          "$CHECK_CONNECTIVITY" == false && "$CHECK_PERMISSIONS" == false && "$CHECK_STORAGE" == false && \
          "$CHECK_ACCESSIBILITY" == false && "$CHECK_PERFORMANCE" == false && "$CHECK_ALL" == false ]]; then
        check_simulator || exit_code=1
        echo ""
        check_app_state || exit_code=1
    fi
    
    echo "🏁 iOS state validation completed"
    if [[ $exit_code -eq 0 ]]; then
        log_success "All checks passed"
    else
        log_warning "Some checks failed or returned warnings"
    fi
    
    exit $exit_code
}

# Run main function
main
