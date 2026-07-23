#!/bin/bash
# Setup permanent SSH on port 2222 for Tailscale access

echo "Setting up permanent SSH on port 2222..."
echo "========================================"

# Install OpenSSH server if not present
if ! command -v /usr/sbin/sshd &> /dev/null; then
    echo "Installing OpenSSH server..."
    sudo apt-get update
    sudo apt-get install -y openssh-server
    echo "✅ OpenSSH server installed"
fi

# Set password for vscode user (needed for SSH)
echo "Setting up vscode user password..."
echo "vscode:vscode" | sudo chpasswd
echo "✅ Password set for vscode user"
echo ""

# Create SSH config for port 2222
sudo tee /etc/ssh/sshd_config.port2222 > /dev/null << 'EOF'
# SSH configuration for port 2222 (Tailscale compatible)
Port 2222
ListenAddress 0.0.0.0

# Authentication
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
UsePAM yes

# Features
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*

# SFTP
Subsystem sftp /usr/lib/openssh/sftp-server

# Security
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

# Start SSH daemon on port 2222 directly (no systemd in container)
echo "Starting SSH daemon on port 2222..."

# Create required directories
sudo mkdir -p /run/sshd-port2222
sudo mkdir -p /run/sshd

# Test configuration
sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config.port2222

# Kill any existing SSH daemon on port 2222
sudo pkill -f "sshd.*port2222" 2>/dev/null || true

# Start SSH daemon in background
sudo /usr/sbin/sshd -f /etc/ssh/sshd_config.port2222

# Check if it's running
sleep 2
if pgrep -f "sshd.*port2222" > /dev/null; then
    echo "✅ SSH daemon started on port 2222"
    echo "Process: $(pgrep -f 'sshd.*port2222')"
else
    echo "❌ Failed to start SSH daemon on port 2222"
    echo "Checking logs..."
    sudo journalctl -u ssh --no-pager -l | tail -10 || echo "No systemd logs available"
fi

# Setup Tailscale serve for port 2222
echo ""
echo "Setting up Tailscale serve for port 2222..."

# Load environment
source .claude-env 2>/dev/null || true
export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock

# Stop any existing serves on this port
tailscale --socket="$TS_SOCKET" serve --tcp 2222 off 2>/dev/null || true

# Start Tailscale serve for SSH port 2222
tailscale --socket="$TS_SOCKET" serve --tcp 2222 tcp://localhost:2222

echo ""
echo "✅ SSH on port 2222 setup complete!"
echo ""
echo "📱 Mobile Connection:"
echo "===================="
TAILSCALE_IP=$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null | head -n1)
echo "• ssh -p 2222 vscode@$TAILSCALE_IP"
echo "• ssh -p 2222 vscode@osrs-wiki-dev.tail5169ee.ts.net"
echo "• Password: vscode"
echo ""
echo "This SSH service will start automatically with the container."