#!/bin/bash
# Simple wrapper to click elements by their text content
# Usage: ./click-by-text.sh "Search"
#    or: ./click-by-text.sh "Navigate up"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 'Button Text'"
    echo "Example: $0 'Search'"
    exit 1
fi

# Use the ui-click script with text parameter
exec ./scripts/ui-click.sh --text "$1"