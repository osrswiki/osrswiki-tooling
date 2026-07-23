#!/bin/bash
# Quick Tailscale authentication helper

echo "🔗 Tailscale Authentication"
echo "=========================="

export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock

# Run authentication and capture output
echo "Running authentication command..."
AUTH_OUTPUT=$(/usr/bin/tailscale --socket="$TS_SOCKET" up --ssh --hostname="osrs-wiki-dev" 2>&1)
echo ""
echo "Full output:"
echo "$AUTH_OUTPUT"
echo ""

# Extract authentication URL
AUTH_URL=$(echo "$AUTH_OUTPUT" | grep -o 'https://login\.tailscale\.com/a/[a-zA-Z0-9]*')

if [ -n "$AUTH_URL" ]; then
    echo "🔗 AUTHENTICATION URL FOUND:"
    echo "$AUTH_URL"
    echo ""
    echo "👆 Click this URL to authenticate your device"
else
    echo "⚠️ No authentication URL found in output"
    echo "Check if authentication completed successfully or if there's an error"
fi

echo ""
echo "After clicking the URL, run 'm' again to check connection status."