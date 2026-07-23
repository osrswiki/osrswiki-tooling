#!/bin/bash
# Test SSH alternatives and configurations

echo "Testing SSH Configuration & Alternatives"
echo "========================================"

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

# Test 1: Check SSH server status
echo "🔍 Test 1: SSH Server Status"
echo "=============================="
if pgrep sshd > /dev/null; then
    echo "✅ SSH daemon is running"
    echo "SSH processes:"
    ps aux | grep sshd | grep -v grep
else
    echo "❌ SSH daemon not running"
    echo "Starting SSH daemon..."
    sudo service ssh start || sudo /usr/sbin/sshd
fi

echo ""

# Test 2: Check SSH configuration
echo "🔍 Test 2: SSH Configuration"
echo "============================="
echo "SSH config relevant settings:"
grep -E "^(Port|ListenAddress|PasswordAuthentication|PermitRootLogin|PubkeyAuthentication)" /etc/ssh/sshd_config 2>/dev/null || echo "Could not read SSH config"

echo ""

# Test 3: Test local SSH connectivity
echo "🔍 Test 3: Local SSH Test"
echo "=========================="
echo "Testing SSH locally..."
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no vscode@localhost "echo 'Local SSH works'" 2>/dev/null && echo "✅ Local SSH accessible" || echo "❌ Local SSH failed"

echo ""

# Test 4: Test SSH via Tailscale IP locally
echo "🔍 Test 4: SSH via Tailscale IP (local)"
echo "========================================"
echo "Testing SSH via Tailscale IP from within container..."
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no vscode@$TAILSCALE_IP "echo 'Tailscale SSH works'" 2>/dev/null && echo "✅ Tailscale SSH accessible locally" || echo "❌ Tailscale SSH failed locally"

echo ""

# Test 5: Alternative ports for SSH
echo "🔍 Test 5: SSH on Alternative Port"
echo "==================================="
echo "Setting up SSH on port 2222..."

# Create alternative SSH config
sudo tee /etc/ssh/sshd_config.tailscale > /dev/null << EOF
Port 2222
ListenAddress 0.0.0.0
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Start SSH on alternative port
sudo /usr/sbin/sshd -f /etc/ssh/sshd_config.tailscale -D &
ALT_SSH_PID=$!

sleep 2

# Test alternative port locally
echo "Testing SSH on port 2222 locally..."
ssh -p 2222 -o ConnectTimeout=5 -o StrictHostKeyChecking=no vscode@localhost "echo 'Alt port SSH works'" 2>/dev/null && echo "✅ Alternative port SSH accessible" || echo "❌ Alternative port SSH failed"

# Expose via Tailscale serve
echo ""
echo "Exposing SSH port 2222 via Tailscale serve..."
timeout 10s tailscale --socket="$TS_SOCKET" serve --tcp 2222 tcp://localhost:2222 2>&1 &
SERVE_SSH_PID=$!

sleep 3

echo ""
echo "📱 SSH TEST INSTRUCTIONS:"
echo "========================="
echo "From your phone, try to connect using SSH on these options:"
echo ""
echo "Option 1 - Standard SSH port 22:"
echo "• ssh vscode@$TAILSCALE_IP"
echo "• ssh vscode@osrs-wiki-dev.tail5169ee.ts.net"
echo ""
echo "Option 2 - Alternative SSH port 2222:"
echo "• ssh -p 2222 vscode@$TAILSCALE_IP"
echo "• ssh -p 2222 vscode@osrs-wiki-dev.tail5169ee.ts.net"
echo ""
echo "Option 3 - Test with telnet to check port accessibility:"
echo "• telnet $TAILSCALE_IP 22"
echo "• telnet $TAILSCALE_IP 2222"
echo ""
echo "Password for vscode user: vscode"
echo ""
echo "Press Enter when you've tested from your phone..."
read -r

# Cleanup
echo ""
echo "🧹 Cleaning up..."
kill $ALT_SSH_PID 2>/dev/null || true
kill $SERVE_SSH_PID 2>/dev/null || true
tailscale --socket="$TS_SOCKET" serve --tcp 2222 off 2>/dev/null || true
sudo rm -f /etc/ssh/sshd_config.tailscale

echo ""
echo "Test complete. Report which options worked or failed."