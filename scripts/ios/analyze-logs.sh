#!/bin/bash
# Advanced iOS console log analysis with pattern matching and real-time monitoring
# Usage: ./analyze-logs.sh [options]
#   --monitor           Start real-time monitoring
#   --pattern PATTERN   Filter logs by pattern
#   --app-only          Show only app-specific logs
#   --errors            Show only errors and warnings
#   --navigation        Show navigation-related logs
#   --performance       Show performance-related logs
#   --test-markers      Show test execution markers
#   --output FILE       Save output to file
#   --tail N           Show last N lines
#   --since TIME       Show logs since time (e.g., "1 minute ago")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa-lib.sh
source "$SCRIPT_DIR/qa-lib.sh"

# Configuration
LOG_FILE=""
MONITOR_MODE=false
PATTERN=""
APP_ONLY=false
ERRORS_ONLY=false
NAVIGATION_ONLY=false
PERFORMANCE_ONLY=false
TEST_MARKERS_ONLY=false
TAIL_LINES=""
SINCE_TIME=""

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
    echo "  --monitor           Start real-time log monitoring"
    echo "  --pattern PATTERN   Filter logs by pattern (grep-compatible)"
    echo "  --app-only          Show only app-specific logs"
    echo "  --errors            Show only errors and warnings"
    echo "  --navigation        Show navigation-related logs"
    echo "  --performance       Show performance-related logs"
    echo "  --test-markers      Show test execution markers"
    echo "  --output FILE       Save output to file"
    echo "  --tail N           Show last N lines"
    echo "  --since TIME       Show logs since time (e.g., '1 minute ago')"
    echo "  --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --monitor --app-only                    # Monitor app logs in real-time"
    echo "  $0 --errors --tail 100                     # Show last 100 error lines"
    echo "  $0 --navigation --pattern 'ViewController' # Show navigation with ViewController pattern"
    echo "  $0 --performance --since '5 minutes ago'   # Show recent performance logs"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --monitor)
            MONITOR_MODE=true
            shift
            ;;
        --pattern)
            PATTERN="$2"
            shift 2
            ;;
        --app-only)
            APP_ONLY=true
            shift
            ;;
        --errors)
            ERRORS_ONLY=true
            shift
            ;;
        --navigation)
            NAVIGATION_ONLY=true
            shift
            ;;
        --performance)
            PERFORMANCE_ONLY=true
            shift
            ;;
        --test-markers)
            TEST_MARKERS_ONLY=true
            shift
            ;;
        --output)
            LOG_FILE="$2"
            shift 2
            ;;
        --tail)
            TAIL_LINES="$2"
            shift 2
            ;;
        --since)
            SINCE_TIME="$2"
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
    echo "❌ iOS log analysis requires macOS environment"
    exit 1
fi

# Ensure we have an exact leased or explicit simulator UDID
if ! ios_select_simulator; then
    echo "❌ IOS_SIMULATOR_UDID not set. Run from an iOS session or source .ios-env."
    exit 1
fi

# Get bundle ID if available
BUNDLE_ID="${BUNDLE_ID:-}"

# Build log command for iOS
build_ios_log_command() {
    local cmd="xcrun simctl spawn \"$IOS_SIMULATOR_UDID\" log show"
    
    # Add time options
    if [[ -n "$SINCE_TIME" ]]; then
        cmd="$cmd --start \"$SINCE_TIME\""
    elif [[ "$MONITOR_MODE" == true ]]; then
        cmd="$cmd --last 1s"  # Start from recent for monitoring
    else
        cmd="$cmd --last 1h"  # Default to last hour
    fi
    
    # Add style options for better parsing
    cmd="$cmd --style syslog"
    
    echo "$cmd"
}

# Apply filters to log stream
apply_filters() {
    local filter_chain="cat"
    
    # App-specific filtering
    if [[ "$APP_ONLY" == true && -n "$BUNDLE_ID" ]]; then
        local app_name=$(echo "$BUNDLE_ID" | cut -d. -f3)
        filter_chain="$filter_chain | grep -E \"$BUNDLE_ID|$app_name\""
    fi
    
    # Error filtering
    if [[ "$ERRORS_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"Error|ERROR|Exception|Fault|fault|Critical|CRITICAL\""
    fi
    
    # Navigation filtering
    if [[ "$NAVIGATION_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"ViewController|Navigation|UINavigationController|segue|present|dismiss|viewDidLoad|viewWillAppear|viewDidAppear\""
    fi
    
    # Performance filtering
    if [[ "$PERFORMANCE_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"Memory|memory|Performance|fps|frame|Instruments|CPU|Battery|Energy|Leak\""
    fi
    
    # Test markers filtering
    if [[ "$TEST_MARKERS_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"XCTest|Test|XCUITest|test.*started|test.*finished|setUp|tearDown\""
    fi
    
    # Custom pattern filtering
    if [[ -n "$PATTERN" ]]; then
        filter_chain="$filter_chain | grep -E \"$PATTERN\""
    fi
    
    # Tail filtering
    if [[ -n "$TAIL_LINES" && "$MONITOR_MODE" == false ]]; then
        filter_chain="$filter_chain | tail -n $TAIL_LINES"
    fi
    
    echo "$filter_chain"
}

# Colorize log output
colorize_logs() {
    sed -E \
        -e "s/.*(Error|ERROR|Exception|Fault|fault|Critical|CRITICAL).*/$(printf "$RED")&$(printf "$NC")/g" \
        -e "s/.*(Warning|WARN|warning).*/$(printf "$YELLOW")&$(printf "$NC")/g" \
        -e "s/.*(Info|INFO|Notice).*/$(printf "$GREEN")&$(printf "$NC")/g" \
        -e "s/.*(Debug|DEBUG).*/$(printf "$BLUE")&$(printf "$NC")/g" \
        -e "s/.*(Default|default).*/$(printf "$PURPLE")&$(printf "$NC")/g" \
        -e "s/(ViewController|Navigation|viewDidLoad|viewWillAppear)/$(printf "$CYAN")\\1$(printf "$NC")/g" \
        -e "s/(Test|XCTest|test.*started|test.*finished)/$(printf "$GREEN")\\1$(printf "$NC")/g"
}

# Parse and analyze log entries
analyze_log_entry() {
    local log_line="$1"
    
    # Extract timestamp, process, log level, category, and message
    if [[ "$log_line" =~ ^([0-9-]+\ [0-9:\.]+).*\]\ ([^:]+):\ (.*)$ ]]; then
        local timestamp="${BASH_REMATCH[1]}"
        local process="${BASH_REMATCH[2]}"
        local message="${BASH_REMATCH[3]}"
        
        # Analyze specific patterns
        case "$message" in
            *"viewDidLoad"*|*"viewWillAppear"*|*"viewDidAppear"*)
                echo "📱 View lifecycle: $message" >&2
                ;;
            *"ViewController"*|*"Navigation"*|*"segue"*)
                echo "🧭 Navigation event: $message" >&2
                ;;
            *"Error"*|*"Exception"*|*"Fault"*|*"Critical"*)
                echo "❌ Error detected: $message" >&2
                ;;
            *"Test"*"started"*|*"Test"*"finished"*|*"XCTest"*)
                echo "🧪 Test event: $message" >&2
                ;;
            *"Memory"*|*"memory"*|*"Leak"*)
                echo "🧠 Memory event: $message" >&2
                ;;
            *"Performance"*|*"CPU"*|*"Energy"*)
                echo "⚡ Performance event: $message" >&2
                ;;
        esac
    fi
    
    echo "$log_line"
}

# Monitor logs in real-time with analysis
monitor_logs() {
    echo "📱 Starting real-time iOS log monitoring for simulator: $IOS_SIMULATOR_UDID"
    if [[ -n "$BUNDLE_ID" ]]; then
        echo "📦 Filtering for app: $BUNDLE_ID"
    fi
    echo "🔍 Filters active: app-only=$APP_ONLY, errors=$ERRORS_ONLY, navigation=$NAVIGATION_ONLY, performance=$PERFORMANCE_ONLY"
    echo "⏹️  Press Ctrl+C to stop monitoring"
    echo "----------------------------------------"
    
    # Check if simulator is running
    if ! xcrun simctl list devices | grep "$IOS_SIMULATOR_UDID" | grep -q "Booted"; then
        echo "🚀 Simulator not booted, starting it..."
        xcrun simctl boot "$IOS_SIMULATOR_UDID"
        sleep 5
    fi
    
    local filters=$(apply_filters)
    
    # Start monitoring with proper cleanup
    trap 'echo "🛑 Stopping iOS log monitoring..."; exit 0' INT TERM
    
    # For monitoring mode, we need to continuously poll logs
    local last_check=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_check))
        
        # Get logs from the last few seconds
        local recent_logs=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" log show --last "${time_diff}s" --style syslog)
        
        if [[ -n "$recent_logs" ]]; then
            echo "$recent_logs" | eval "$filters" | while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    if [[ "$MONITOR_MODE" == true ]]; then
                        analyze_log_entry "$line"
                    else
                        echo "$line"
                    fi
                fi
            done | colorize_logs | if [[ -n "$LOG_FILE" ]]; then
                tee -a "$LOG_FILE"
            else
                cat
            fi
        fi
        
        last_check=$current_time
        sleep 2  # Check every 2 seconds
    done
}

# Extract specific information from logs
extract_app_info() {
    echo "📊 Extracting iOS app information from logs..."
    
    local cmd=$(build_ios_log_command)
    local app_filter=""
    
    if [[ -n "$BUNDLE_ID" ]]; then
        local app_name=$(echo "$BUNDLE_ID" | cut -d. -f3)
        app_filter="grep -E \"$BUNDLE_ID|$app_name\""
    else
        app_filter="cat"
    fi
    
    # Get recent app events
    echo "🚀 Recent app lifecycle events:"
    eval "$cmd" | eval "$app_filter" | grep -E "viewDidLoad|viewWillAppear|viewDidAppear|applicationDidFinishLaunching" | tail -20
    
    echo ""
    echo "❌ Recent errors and warnings:"
    eval "$cmd" | eval "$app_filter" | grep -E "Error|ERROR|Exception|Fault|Critical" | tail -10
    
    echo ""
    echo "🧭 Recent navigation events:"
    eval "$cmd" | eval "$app_filter" | grep -E "ViewController|Navigation|segue|present|dismiss" | tail -10
    
    echo ""
    echo "🧠 Memory and performance events:"
    eval "$cmd" | eval "$app_filter" | grep -E "Memory|memory|Performance|CPU|Energy|Leak" | tail -10
}

# Check for specific error patterns
check_error_patterns() {
    echo "🔍 Checking for common iOS error patterns..."
    
    local cmd=$(build_ios_log_command)
    local recent_logs=""
    
    if [[ -n "$TAIL_LINES" ]]; then
        recent_logs=$(eval "$cmd" | tail -n "$TAIL_LINES")
    else
        recent_logs=$(eval "$cmd" | tail -n 500)
    fi
    
    # Check for common iOS issues
    echo "$recent_logs" | grep -E "EXC_BAD_ACCESS|SIGABRT|Terminated due to memory" && echo "🚨 Critical crashes found!" || echo "✅ No critical crashes detected"
    echo "$recent_logs" | grep -E "Memory pressure|didReceiveMemoryWarning" && echo "🧠 Memory pressure detected!" || echo "✅ No memory issues"
    echo "$recent_logs" | grep -E "Main Thread Checker|Threading violation" && echo "⚠️ Threading violations detected!" || echo "✅ No threading issues"
    echo "$recent_logs" | grep -E "CoreData.*error|SQLite.*error" && echo "🗄️ Database issues detected!" || echo "✅ No database issues"
    echo "$recent_logs" | grep -E "Network.*error|NSURLError" && echo "🌐 Network issues detected!" || echo "✅ No network issues"
    echo "$recent_logs" | grep -E "Constraint.*error|AutoLayout" && echo "📐 Layout constraint issues detected!" || echo "✅ No layout issues"
}

# Check simulator status
check_simulator_status() {
    echo "📱 Simulator Status"
    echo "=================="
    echo "Simulator UDID: $IOS_SIMULATOR_UDID"
    
    local sim_info=$(xcrun simctl list devices | grep "$IOS_SIMULATOR_UDID")
    echo "Status: $sim_info"
    
    if echo "$sim_info" | grep -q "Booted"; then
        echo "✅ Simulator is running"
        
        # Check if our app is installed and running
        if [[ -n "$BUNDLE_ID" ]]; then
            echo ""
            echo "📦 App Status for $BUNDLE_ID:"
            
            # Check if app is installed
            if xcrun simctl listapps "$IOS_SIMULATOR_UDID" | grep -q "$BUNDLE_ID"; then
                echo "✅ App is installed"
                
                # Try to get app state (this is approximate)
                local app_processes=$(xcrun simctl spawn "$IOS_SIMULATOR_UDID" ps aux | grep "$BUNDLE_ID" || echo "")
                if [[ -n "$app_processes" ]]; then
                    echo "✅ App appears to be running"
                    echo "Processes: $app_processes"
                else
                    echo "⚠️ App not currently running"
                fi
            else
                echo "❌ App is not installed"
            fi
        fi
    else
        echo "❌ Simulator is not running"
        echo "💡 Use: xcrun simctl boot \"$IOS_SIMULATOR_UDID\" to start it"
    fi
}

# Generate log summary
generate_summary() {
    echo "📋 iOS Log Analysis Summary"
    echo "=========================="
    echo "Simulator: $IOS_SIMULATOR_UDID"
    if [[ -n "$BUNDLE_ID" ]]; then
        echo "App: $BUNDLE_ID"
    fi
    echo "Analysis time: $(date)"
    echo ""
    
    check_simulator_status
    echo ""
    extract_app_info
    echo ""
    check_error_patterns
}

# Main execution
main() {
    if [[ "$MONITOR_MODE" == true ]]; then
        monitor_logs
    else
        if [[ "$ERRORS_ONLY" == true || "$NAVIGATION_ONLY" == true || "$PERFORMANCE_ONLY" == true || "$TEST_MARKERS_ONLY" == true || -n "$PATTERN" ]]; then
            # Filtered analysis
            local cmd=$(build_ios_log_command)
            local filters=$(apply_filters)
            eval "$cmd" | eval "$filters" | colorize_logs | if [[ -n "$LOG_FILE" ]]; then
                tee "$LOG_FILE"
            else
                cat
            fi
        else
            # General summary
            generate_summary | if [[ -n "$LOG_FILE" ]]; then
                tee "$LOG_FILE"
            else
                cat
            fi
        fi
    fi
}

# Run main function
main
