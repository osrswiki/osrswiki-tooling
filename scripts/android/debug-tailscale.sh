#!/bin/bash
# Debug Tailscale state issues

echo "🔍 Debugging Tailscale State"
echo "============================"

export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock

echo "1. Check if daemon is running:"
pgrep tailscaled && echo "✅ Daemon running" || echo "❌ Daemon not running"

echo ""
echo "2. Check socket file:"
ls -la "$TS_SOCKET" 2>/dev/null && echo "✅ Socket exists" || echo "❌ Socket missing"

echo ""
echo "3. Check state file:"
ls -la ~/.tailscale/tailscaled.state 2>/dev/null && echo "✅ State file exists" || echo "❌ State file missing"

echo ""
echo "4. Check log file:"
if [ -f ~/.tailscale/tailscaled.log ]; then
    echo "✅ Log file exists - last 10 lines:"
    tail -10 ~/.tailscale/tailscaled.log
else
    echo "❌ Log file missing"
fi

echo ""
echo "5. Try status command directly:"
/usr/bin/tailscale --socket="$TS_SOCKET" status 2>&1

echo ""
echo "6. Process details:"
ps aux | grep tailscale | grep -v grep