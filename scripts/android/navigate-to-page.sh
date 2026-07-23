#!/bin/bash
# Navigate directly to a specific wiki page
# Usage: ./navigate-to-page.sh "Page_Name"
#    or: ./navigate-to-page.sh "Abyssal_whip"

set -euo pipefail

# Auto-source session environment
if [[ -f .claude-env ]]; then
    source .claude-env
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 'Page_Name'"
    echo "Example: $0 'Abyssal_whip'"
    echo "Example: $0 'Grand_Exchange'"
    exit 1
fi

PAGE_NAME="$1"

# Ensure we have app ID
if [[ -z "${APPID:-}" ]]; then
    echo "❌ APPID not set. Run from a session or use ./run-with-env.sh"
    exit 1
fi

echo "🌐 Navigating to wiki page: $PAGE_NAME"

# Method 1: Try using intent with custom scheme (if app supports it)
echo "📱 Attempting direct navigation via intent..."
if adb -s "${ANDROID_SERIAL}" shell am start -W -a android.intent.action.VIEW -d "https://oldschool.runescape.wiki/w/$PAGE_NAME" "$APPID" 2>/dev/null; then
    echo "✅ Direct navigation successful"
    exit 0
fi

# Method 2: Use search functionality as fallback
echo "🔍 Fallback: Using search to navigate to page..."
./scripts/android/search-wiki.sh "$PAGE_NAME"

sleep 3

# Try to click on the first result that matches our page name
echo "🎯 Looking for page in search results..."
if ./scripts/android/ui-click.sh --text "$PAGE_NAME" 2>/dev/null; then
    echo "✅ Successfully navigated to $PAGE_NAME"
else
    echo "⚠️ Could not find exact match. Available results:"
    ./scripts/android/ui-click.sh --dump-only >/dev/null 2>&1
    echo "💡 Use ./scripts/android/ui-click.sh --text 'Result Name' to click a specific result"
fi