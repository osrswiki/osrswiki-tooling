#!/bin/bash

# Measure appearance settings image loading latency
# This script quantifies the performance impact of appearance settings preloading

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/color-utils.sh"

# Auto-source environment
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    if [[ -f .claude-env ]]; then
        source .claude-env
    elif [[ -f "${SCRIPT_DIR}/../../.claude-env" ]]; then
        source "${SCRIPT_DIR}/../../.claude-env"
    fi
fi

if [[ -z "$ANDROID_SERIAL" ]]; then
    echo "❌ ANDROID_SERIAL not set. Run: source .claude-env"
    exit 1
fi

echo "🔬 Measuring appearance settings image loading latency"
echo "📱 Device: $ANDROID_SERIAL"
echo ""
echo "📦 Ensuring debug app is installed..."
"$SCRIPT_DIR/qa-build-install.sh" >/dev/null
echo ""

TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
APPID=""
MAIN_ACTIVITY=""

ms_now() {
    python3 -c "import time; print(int(time.time() * 1000))"
}

resolve_app_targets() {
    APPID="$("$SCRIPT_DIR/get-app-id.sh" 2>/dev/null || true)"
    if [[ -z "$APPID" ]]; then
        echo "Could not resolve Android application id." >&2
        return 1
    fi

    MAIN_ACTIVITY="$(adb -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief \
        -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER \
        -p "$APPID" 2>/dev/null | tail -n1 | tr -d '\r' || true)"
    if [[ -z "$MAIN_ACTIVITY" || "$MAIN_ACTIVITY" != "$APPID"* ]]; then
        echo "Could not resolve Android launcher activity for $APPID." >&2
        return 1
    fi

}

wait_for_appearance_previews() {
    local timeout=5000
    local deadline
    deadline=$(($(ms_now) + timeout))

    while [[ $(ms_now) -lt $deadline ]]; do
        local ui_ready
        local dump_status=0
        if [[ -n "$TIMEOUT_CMD" ]]; then
            "$TIMEOUT_CMD" 3 adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/osrswiki-window.xml >/dev/null 2>&1 || dump_status=$?
        else
            adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/osrswiki-window.xml >/dev/null 2>&1 || dump_status=$?
        fi
        if [[ $dump_status -eq 0 ]]; then
            ui_ready="$(adb -s "$ANDROID_SERIAL" shell cat /sdcard/osrswiki-window.xml 2>/dev/null |
                grep -Eo "Clean and bright interface|Easy on the eyes in low light" |
                wc -l | tr -d ' ' || true)"
        else
            ui_ready=0
        fi
        ui_ready="${ui_ready//$'\r'/}"
        ui_ready="$(printf '%s\n' "$ui_ready" | tail -n1)"
        if [[ -z "$ui_ready" || ! "$ui_ready" =~ ^[0-9]+$ ]]; then
            ui_ready=0
        fi

        if [[ $ui_ready -ge 2 ]]; then
            return 0
        fi

        sleep 0.05
    done

    return 1
}

tap_appearance_and_get_display_time() {
    local dump_status=0
    local bounds
    local left
    local top
    local right
    local bottom
    local x
    local y
    local start_time
    local end_time
    local focus_time
    local displayed_time=""

    if [[ -n "$TIMEOUT_CMD" ]]; then
        "$TIMEOUT_CMD" 3 adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/osrswiki-window.xml >/dev/null 2>&1 || dump_status=$?
    else
        adb -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/osrswiki-window.xml >/dev/null 2>&1 || dump_status=$?
    fi
    if [[ $dump_status -ne 0 ]]; then
        echo "Could not dump More screen UI hierarchy before measuring Appearance tap." >&2
        return 1
    fi

    adb -s "$ANDROID_SERIAL" shell cat /sdcard/osrswiki-window.xml > /tmp/osrswiki-appearance-more.xml
    bounds="$(xmllint --xpath "(//*[@text='Appearance'])[1]/@bounds" /tmp/osrswiki-appearance-more.xml 2>/dev/null | sed 's/bounds="//; s/"$//' || true)"
    bounds="${bounds## }"
    if [[ -z "$bounds" ]]; then
        echo "Could not find Appearance row bounds on More screen." >&2
        return 1
    fi

    left="$(echo "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\1/')"
    top="$(echo "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\2/')"
    right="$(echo "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\3/')"
    bottom="$(echo "$bounds" | sed 's/\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]/\4/')"
    x=$(( (left + right) / 2 ))
    y=$(( (top + bottom) / 2 ))

    adb -s "$ANDROID_SERIAL" logcat -c
    start_time="$(ms_now)"
    adb -s "$ANDROID_SERIAL" shell input tap "$x" "$y"

    for _ in $(seq 1 100); do
        if adb -s "$ANDROID_SERIAL" shell dumpsys window 2>/dev/null | grep -q "AppearanceSettingsActivity"; then
            end_time="$(ms_now)"
            focus_time=$((end_time - start_time))
            break
        fi
        sleep 0.05
    done

    sleep 0.2
    displayed_time="$(adb -s "$ANDROID_SERIAL" logcat -d 2>/dev/null |
        grep "Displayed com.omiyawaki.osrswiki/.settings.AppearanceSettingsActivity" |
        tail -n1 |
        sed -E 's/.*\+([0-9]+)ms.*/\1/' || true)"

    if [[ -n "$displayed_time" && "$displayed_time" =~ ^[0-9]+$ ]]; then
        echo "$displayed_time"
        return 0
    fi
    if [[ -n "${focus_time:-}" && "$focus_time" =~ ^[0-9]+$ ]]; then
        echo "$focus_time"
        return 0
    fi

    echo "Could not measure Appearance display time." >&2
    return 1
}

# Function to measure time between navigation and image display
measure_appearance_load_time() {
    local test_name="$1"
    local launch_mode="$2"

    echo "📊 Test: $test_name" >&2

    # Clear logcat to get clean timing
    adb -s "$ANDROID_SERIAL" logcat -c

    case "$launch_mode" in
        cold)
            adb -s "$ANDROID_SERIAL" shell am force-stop "$APPID"
            ;;
        warm|repeated)
            ;;
        *)
            echo "Unknown launch mode: $launch_mode" >&2
            return 1
            ;;
    esac

    adb -s "$ANDROID_SERIAL" shell am start -W -n "$MAIN_ACTIVITY" >/dev/null
    sleep 0.5
    "$SCRIPT_DIR/ui-click.sh" --text "More" >/dev/null 2>&1
    sleep 0.2

    local start_time
    local verify_time
    local load_duration
    local images_loaded=false

    start_time="$(ms_now)"
    load_duration="$(tap_appearance_and_get_display_time)"
    if wait_for_appearance_previews; then
        images_loaded=true
    fi
    verify_time=$(($(ms_now) - start_time))
    
    # Check for cache hits in logs
    local cache_hit
    cache_hit="$(adb -s "$ANDROID_SERIAL" logcat -d | grep -c "Valid cache found, skipping generation" || true)"
    cache_hit="${cache_hit//$'\r'/}"
    cache_hit="$(printf '%s\n' "$cache_hit" | tail -n1)"
    if [[ -z "$cache_hit" || ! "$cache_hit" =~ ^[0-9]+$ ]]; then
        cache_hit=0
    fi
    local cache_status="MISS"
    if [[ $cache_hit -gt 0 ]]; then
        cache_status="HIT"
    fi
    
    echo "  ⏱️  Tap-to-display time: ${load_duration}ms" >&2
    echo "  ⏱️  Verification time: ${verify_time}ms" >&2
    echo "  💾 Cache status: $cache_status" >&2
    echo "  ✅ Images loaded: $images_loaded" >&2
    echo "" >&2
    
    # Return the load duration for comparison
    echo "$load_duration"
}

# Test 1: First navigation (cold start)
echo "🧪 Test 1: Cold start navigation"
resolve_app_targets
load_time_1=$(measure_appearance_load_time "Cold start" "cold")

# Test 2: Return navigation (cache should be warm)
echo "🧪 Test 2: Warm cache navigation"
load_time_2=$(measure_appearance_load_time "Warm cache" "warm")

# Test 3: Repeated navigation (optimal cache performance)
echo "🧪 Test 3: Repeated navigation"
load_time_3=$(measure_appearance_load_time "Repeated access" "repeated")

# Analysis
echo "📈 Performance Analysis:"
echo "  Cold start activity:      ${load_time_1}ms"
echo "  Warm cache activity:      ${load_time_2}ms"
echo "  Repeated access activity: ${load_time_3}ms"
echo ""

# Calculate improvement
if [[ $load_time_1 -gt 0 ]]; then
    improvement_pct=$(( (load_time_1 - load_time_3) * 100 / load_time_1 ))
    echo "📊 Cache improvement: ${improvement_pct}% faster"
fi

# Check for performance targets
target_load_time=500  # 500ms target for good UX
echo ""
echo "🎯 Performance targets (< ${target_load_time}ms for good UX):"
test_names=("Cold start" "Warm cache" "Repeated access")
for i in 1 2 3; do
    load_time_var="load_time_$i"
    load_time=${!load_time_var}
    test_name="${test_names[$((i-1))]}"
    
    if [[ $load_time -lt $target_load_time ]]; then
        echo "  ✅ $test_name: ${load_time}ms (GOOD)"
    else
        echo "  ⚠️  $test_name: ${load_time}ms (SLOW)"
    fi
done

echo ""
echo "✅ Appearance settings latency measurement complete"
