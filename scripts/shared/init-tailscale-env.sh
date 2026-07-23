#!/bin/bash
# Initialize Tailscale environment variables for session
# Adds Tailscale configuration to .claude-env

set -e

echo "Initializing Tailscale environment..."

# Check if .claude-env exists
if [ ! -f .claude-env ]; then
    echo "Creating .claude-env file..."
    touch .claude-env
fi

# Check if Tailscale config already exists
if grep -q "TS_SOCKET" .claude-env 2>/dev/null; then
    echo "✓ Tailscale environment already configured in .claude-env"
else
    echo "Adding Tailscale configuration to .claude-env..."
    
    cat >> .claude-env << 'EOF'

# Tailscale configuration (sudo-free)
export TS_SOCKET=/home/vscode/.tailscale/tailscaled.sock
export TS_STATE_DIR=/home/vscode/.tailscale

# Tailscale aliases for convenience
alias tailscale="tailscale --socket=$TS_SOCKET"
alias ts-status="~/tailscale-info.sh"
alias ts-start="~/start-tailscale.sh"
alias ts-stop="~/stop-tailscale.sh"
alias ts-ip="tailscale --socket=$TS_SOCKET ip"

# Mobile development aliases  
alias mobile="./scripts/shared/mobile-session.sh"
alias setup-mobile="./scripts/shared/setup-mobile-access.sh"
EOF
    
    echo "✓ Tailscale configuration added to .claude-env"
fi

# Source the environment to make it available immediately
echo "Loading Tailscale environment..."
source .claude-env

echo ""
echo "✅ Tailscale environment initialized!"
echo ""
echo "Available commands:"
echo "  ts-start        - Start Tailscale daemon"
echo "  ts-status       - Show connection status" 
echo "  ts-ip           - Show Tailscale IP addresses"
echo "  setup-mobile    - Setup mobile access"
echo "  mobile          - Start mobile session"
echo ""
echo "To use in future sessions:"
echo "  source .claude-env"