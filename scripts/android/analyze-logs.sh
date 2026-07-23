#!/bin/bash
# Advanced Android logcat analysis with pattern matching and real-time monitoring
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

# Auto-source session environment
if [[ -f .claude-env ]]; then
    source .claude-env
fi

# Configuration
DEFAULT_BUFFER_SIZE=1000
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
    echo "  $0 --navigation --pattern 'Fragment'       # Show navigation with Fragment pattern"
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

# Ensure we have device serial
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    echo "❌ ANDROID_SERIAL not set. Run from a session or use ./run-with-env.sh"
    exit 1
fi

# Get app package name if available
APPID="${APPID:-}"

# Build logcat command
build_logcat_command() {
    local cmd="adb -s \"$ANDROID_SERIAL\" logcat"
    
    # Add time options
    if [[ -n "$SINCE_TIME" ]]; then
        cmd="$cmd -T \"$SINCE_TIME\""
    elif [[ "$MONITOR_MODE" == true ]]; then
        cmd="$cmd -T 1"  # Start from now for monitoring
    fi
    
    # Add buffer size for better performance
    cmd="$cmd -b main,system,events"
    
    echo "$cmd"
}

# Apply filters to log stream
apply_filters() {
    local filter_chain="cat"
    
    # App-specific filtering
    if [[ "$APP_ONLY" == true && -n "$APPID" ]]; then
        filter_chain="$filter_chain | grep -E \"$APPID|$(echo "$APPID" | cut -d. -f3)\""
    fi
    
    # Error filtering
    if [[ "$ERRORS_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \" E/| W/|ERROR|WARN|Exception|Error\""
    fi
    
    # Navigation filtering
    if [[ "$NAVIGATION_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"Activity|Fragment|Navigation|Intent|onCreate|onResume|onPause|onDestroy\""
    fi
    
    # Performance filtering
    if [[ "$PERFORMANCE_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"Choreographer|fps|frame|memory|GC|ANR|Watchdog|Performance\""
    fi
    
    # Test markers filtering
    if [[ "$TEST_MARKERS_ONLY" == true ]]; then
        filter_chain="$filter_chain | grep -E \"TestRunner|Test|@Test|JUnit|Espresso|UI Automator\""
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
        -e "s/.* E\/.*/$(printf "$RED")&$(printf "$NC")/g" \
        -e "s/.* W\/.*/$(printf "$YELLOW")&$(printf "$NC")/g" \
        -e "s/.* I\/.*/$(printf "$GREEN")&$(printf "$NC")/g" \
        -e "s/.* D\/.*/$(printf "$BLUE")&$(printf "$NC")/g" \
        -e "s/.* V\/.*/$(printf "$PURPLE")&$(printf "$NC")/g" \
        -e "s/(Activity|Fragment|onCreate|onResume)/$(printf "$CYAN")\\1$(printf "$NC")/g" \
        -e "s/(ERROR|Exception|Error)/$(printf "$RED")\\1$(printf "$NC")/g" \
        -e "s/(Test|@Test|TestRunner)/$(printf "$GREEN")\\1$(printf "$NC")/g"
}

# Parse and analyze log entries
analyze_log_entry() {
    local log_line="$1"
    
    # Extract timestamp, log level, tag, and message
    if [[ "$log_line" =~ ^([0-9-]+\ [0-9:\.]+)\ +([EWIVD])/([^:]+):\ +(.*)$ ]]; then
        local timestamp="${BASH_REMATCH[1]}"
        local level="${BASH_REMATCH[2]}"
        local tag="${BASH_REMATCH[3]}"
        local message="${BASH_REMATCH[4]}"
        
        # Analyze specific patterns
        case "$message" in
            *"Activity"*"onCreate"*)
                echo "📱 Activity lifecycle: $message" >&2
                ;;
            *"Fragment"*"onCreateView"*)
                echo "🧩 Fragment lifecycle: $message" >&2
                ;;
            *"Navigation"*|*"navigate"*)
                echo "🧭 Navigation event: $message" >&2
                ;;
            *"Exception"*|*"Error"*|*"ERROR"*)
                echo "❌ Error detected: $message" >&2
                ;;
            *"Test"*"started"*|*"Test"*"finished"*)
                echo "🧪 Test event: $message" >&2
                ;;
            *"GC"*|*"memory"*)
                echo "🧠 Memory event: $message" >&2
                ;;
        esac
    fi
    
    echo "$log_line"
}

# Monitor logs in real-time with analysis
monitor_logs() {
    echo "📱 Starting real-time log monitoring for device: $ANDROID_SERIAL"
    if [[ -n "$APPID" ]]; then
        echo "📦 Filtering for app: $APPID"
    fi
    echo "🔍 Filters active: app-only=$APP_ONLY, errors=$ERRORS_ONLY, navigation=$NAVIGATION_ONLY, performance=$PERFORMANCE_ONLY"
    echo "⏹️  Press Ctrl+C to stop monitoring"
    echo "----------------------------------------"
    
    local cmd=$(build_logcat_command)
    local filters=$(apply_filters)
    
    # Start monitoring with proper cleanup
    trap 'echo "🛑 Stopping log monitoring..."; exit 0' INT TERM
    
    eval "$cmd" | eval "$filters" | while IFS= read -r line; do
        if [[ "$MONITOR_MODE" == true ]]; then
            analyze_log_entry "$line"
        else
            echo "$line"
        fi
    done | colorize_logs | if [[ -n "$LOG_FILE" ]]; then
        tee "$LOG_FILE"
    else
        cat
    fi
}

# Extract specific information from logs
extract_app_info() {
    echo "📊 Extracting app information from logs..."
    
    local cmd=$(build_logcat_command)
    local app_filter=""
    
    if [[ -n "$APPID" ]]; then
        app_filter="grep -E \"$APPID\""
    else
        app_filter="cat"
    fi
    
    # Get recent app events
    echo "🚀 Recent app lifecycle events:"
    eval "$cmd" | eval "$app_filter" | grep -E "Activity|Fragment|Service" | tail -20
    
    echo ""
    echo "❌ Recent errors and warnings:"
    eval "$cmd" | eval "$app_filter" | grep -E " E/| W/" | tail -10
    
    echo ""
    echo "🧭 Recent navigation events:"
    eval "$cmd" | eval "$app_filter" | grep -E "Intent|Navigation|navigate" | tail -10
    
    echo ""
    echo "🧠 Memory and performance events:"
    eval "$cmd" | eval "$app_filter" | grep -E "GC|memory|performance|ANR" | tail -10
}

# Check for specific error patterns
check_error_patterns() {
    echo "🔍 Checking for common error patterns..."
    
    local cmd=$(build_logcat_command)
    local recent_logs=""
    
    if [[ -n "$TAIL_LINES" ]]; then
        recent_logs=$(eval "$cmd" | tail -n "$TAIL_LINES")
    else
        recent_logs=$(eval "$cmd" | tail -n 500)
    fi
    
    # Check for common issues
    echo "$recent_logs" | grep -E "OutOfMemoryError|ANR|DEADLOCK" && echo "🚨 Critical errors found!" || echo "✅ No critical errors detected"
    echo "$recent_logs" | grep -E "Activity.*not responding|Application.*not responding" && echo "🐌 ANR detected!" || echo "✅ No ANR issues"
    echo "$recent_logs" | grep -E "NetworkOnMainThreadException|StrictMode" && echo "⚠️ Threading violations detected!" || echo "✅ No threading issues"
    echo "$recent_logs" | grep -E "SQLiteException|Database" && echo "🗄️ Database issues detected!" || echo "✅ No database issues"
    echo "$recent_logs" | grep -E "Permission.*denied|SecurityException" && echo "🔒 Permission issues detected!" || echo "✅ No permission issues"
}

# Generate log summary
generate_summary() {
    echo "📋 Log Analysis Summary"
    echo "======================"
    echo "Device: $ANDROID_SERIAL"
    if [[ -n "$APPID" ]]; then
        echo "App: $APPID"
    fi
    echo "Analysis time: $(date)"
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
            local cmd=$(build_logcat_command)
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