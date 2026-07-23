#!/bin/bash
# Search for a term in the OSRS wiki app
# Usage: ./search-wiki.sh "Abyssal whip"

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 'search term'"
    echo "Example: $0 'Abyssal whip'"
    exit 1
fi

SEARCH_TERM="$1"

echo "🔍 Searching for: $SEARCH_TERM"

# Step 1: Click on search tab/icon
echo "📱 Clicking search tab..."
if ! ./scripts/android/ui-click.sh --desc "Search" 2>/dev/null; then
    # Fallback: try clicking by text
    if ! ./scripts/android/ui-click.sh --text "Search" 2>/dev/null; then
        echo "❌ Could not find search tab. Available elements:"
        ./scripts/android/ui-click.sh --dump-only
        exit 1
    fi
fi

sleep 1

# Step 2: Click on search input field
echo "🔍 Clicking search input field..."
if ! ./scripts/android/ui-click.sh --class "android.widget.EditText" 2>/dev/null; then
    echo "❌ Could not find search input field"
    exit 1
fi

sleep 1

# Step 3: Clear existing text and input search term
echo "⌨️ Entering search term: $SEARCH_TERM"
# Clear existing text
adb -s "${ANDROID_SERIAL}" shell input keyevent KEYCODE_CTRL_A
adb -s "${ANDROID_SERIAL}" shell input keyevent KEYCODE_DEL

# Type the search term (replace spaces with %s for adb)
SEARCH_ENCODED=$(echo "$SEARCH_TERM" | sed 's/ /%s/g')
adb -s "${ANDROID_SERIAL}" shell input text "$SEARCH_ENCODED"

sleep 1

# Step 4: Press enter or click search button
echo "🔍 Executing search..."
adb -s "${ANDROID_SERIAL}" shell input keyevent KEYCODE_ENTER

echo "✅ Search initiated for: $SEARCH_TERM"
echo "💡 Wait for results to load, then use ./scripts/android/ui-click.sh --text 'Result Name' to click specific results"