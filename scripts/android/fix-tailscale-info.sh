#!/bin/bash
# Fix the tailscale-info.sh script to use correct socket

echo "Fixing tailscale-info.sh script..."

export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock

# Recreate the tailscale-info.sh script with correct socket paths
cat > ~/tailscale-info.sh << 'EOF'
#!/bin/bash
# Get Tailscale connection info (no sudo needed)

export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock

if ! pgrep tailscaled > /dev/null; then
    echo "Tailscale daemon not running"
    echo "Start with: ~/start-tailscale.sh"
    exit 1
fi

if ! [ -S "$TS_SOCKET" ]; then
    echo "Tailscale socket not found at $TS_SOCKET"
    exit 1
fi

echo "========================================="
echo "Tailscale Status"
echo "========================================="
/usr/bin/tailscale --socket="$TS_SOCKET" status
echo ""
echo "Tailscale IP addresses:"
/usr/bin/tailscale --socket="$TS_SOCKET" ip
echo ""

# Get the main IPv4 address
TAILSCALE_IP=$(/usr/bin/tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null | head -n1)
HOSTNAME=$(hostname)

if [ -n "$TAILSCALE_IP" ]; then
    echo "Mobile SSH Connection Commands:"
    echo "  Direct IP:  ssh vscode@$TAILSCALE_IP"
    echo "  Hostname:   ssh vscode@$HOSTNAME"
    echo ""
    echo "For stable mobile connections (MOSH):"
    echo "  mosh --port=60000 vscode@$TAILSCALE_IP"
    echo ""
    echo "Container Details:"
    echo "  Android Serial: ${ANDROID_SERIAL:-<not set>}"
    echo "  SSH via Tailscale: Available"
else
    echo "Tailscale not authenticated yet"
    echo "Run: /usr/bin/tailscale --socket=$TS_SOCKET up --ssh --hostname=osrs-wiki-dev"
fi
echo "========================================="
EOF

chmod +x ~/tailscale-info.sh

echo "✅ Fixed ~/tailscale-info.sh script!"
echo "Now run 'm' again to see proper connection info."