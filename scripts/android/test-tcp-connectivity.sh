#!/bin/bash
# Test TCP connectivity through Tailscale userspace networking

echo "Testing TCP connectivity through Tailscale..."
echo "============================================="

# Load environment
source .claude-env 2>/dev/null || true
export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock

# Get Tailscale IP
TAILSCALE_IP=$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null | head -n1)

if [ -z "$TAILSCALE_IP" ]; then
    echo "❌ No Tailscale IP found. Make sure Tailscale is connected."
    exit 1
fi

echo "Tailscale IP: $TAILSCALE_IP"
echo ""

# Test 1: Simple HTTP server on port 8080
echo "🔍 Test 1: Starting simple HTTP server on port 8080..."
python3 -m http.server 8080 > /tmp/http-server.log 2>&1 &
HTTP_PID=$!

sleep 2

# Test local connectivity first
echo "Testing local connectivity (http://localhost:8080)..."
if curl -s --connect-timeout 5 http://localhost:8080 > /dev/null; then
    echo "✅ Local HTTP server accessible"
else
    echo "❌ Local HTTP server not accessible"
fi

# Expose via Tailscale serve
echo ""
echo "🔍 Test 2: Exposing HTTP server via Tailscale serve..."
timeout 10s tailscale --socket="$TS_SOCKET" serve --tcp 8080 tcp://localhost:8080 2>&1 &
SERVE_PID=$!

sleep 3

echo ""
echo "📱 CONNECTION TEST INSTRUCTIONS:"
echo "================================="
echo "From your phone, try to access:"
echo "• http://$TAILSCALE_IP:8080"
echo "• http://osrs-wiki-dev.tail5169ee.ts.net:8080"
echo ""
echo "You should see a directory listing (Python HTTP server)."
echo ""
echo "Press Enter when you've tested from your phone..."
read -r

# Cleanup
echo ""
echo "🧹 Cleaning up test services..."
kill $HTTP_PID 2>/dev/null || true
kill $SERVE_PID 2>/dev/null || true
tailscale --socket="$TS_SOCKET" serve --tcp 8080 off 2>/dev/null || true

echo ""
echo "Test complete. If HTTP worked but SSH doesn't, the issue is SSH-specific."
echo "If HTTP also failed, the issue is with TCP connectivity through Tailscale userspace networking."