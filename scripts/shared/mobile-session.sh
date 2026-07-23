#!/bin/bash
# Start mobile-optimized terminal session
# Optimized for SSH/MOSH connections from mobile devices

set -e

# Load environment if available
source .ios-env 2>/dev/null || true
source .claude-env 2>/dev/null || true

# Check if we're in an SSH session
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    echo "📱 Mobile session detected via SSH"
    SESSION_TYPE="mobile"
elif [ -n "$SSH_CONNECTION" ]; then
    echo "📱 Remote session detected"
    SESSION_TYPE="mobile"  
else
    echo "💻 Local session"
    SESSION_TYPE="local"
fi

echo "Starting optimized terminal session..."

# Function to setup mobile-friendly environment
setup_mobile_env() {
    # Set smaller terminal if not already configured
    export LINES=${LINES:-24}
    export COLUMNS=${COLUMNS:-80}
    
    # Mobile-friendly prompt
    export PS1='📱 \w $ '
    
    # Helpful aliases for mobile
    alias ll='ls -la'
    alias la='ls -la'
    alias c='clear'
    alias q='exit'
    alias ..='cd ..'
    alias ...='cd ../..'
    
    # Android development shortcuts
    alias adb-devices='adb devices'
    alias adb-log='adb logcat | head -n 20'
    alias gradle-test='./gradlew testDebugUnitTest'
    alias gradle-build='./gradlew assembleDebug'
    
    # Claude shortcuts
    alias claude-help='claude --help'
    
    echo "✓ Mobile environment configured"
    echo ""
    echo "📋 Quick Commands:"
    echo "  claude          - Start Claude Code"
    echo "  adb-devices     - Check Android devices" 
    echo "  gradle-build    - Build the app"
    echo "  gradle-test     - Run unit tests"
    echo "  ts-status       - Check Tailscale connection"
    echo "  c               - Clear screen"
    echo "  q               - Exit session"
}

# Try to start Zellij (terminal multiplexer)
if command -v zellij &> /dev/null; then
    echo "Starting Zellij session..."
    
    # Setup mobile environment before starting Zellij
    setup_mobile_env
    
    # Check if session exists
    if zellij list-sessions 2>/dev/null | grep -q "^$SESSION_TYPE"; then
        echo "Attaching to existing $SESSION_TYPE session..."
        zellij attach "$SESSION_TYPE"
    else
        echo "Creating new $SESSION_TYPE session..."
        # Create a compact layout for mobile
        if [ "$SESSION_TYPE" = "mobile" ]; then
            zellij --session "$SESSION_TYPE" --layout compact 2>/dev/null || \
            zellij --session "$SESSION_TYPE"
        else
            zellij --session "$SESSION_TYPE"
        fi
    fi
elif command -v tmux &> /dev/null; then
    echo "Zellij not available, using tmux..."
    setup_mobile_env
    
    # Start or attach to tmux session
    if tmux has-session -t "$SESSION_TYPE" 2>/dev/null; then
        echo "Attaching to existing tmux session..."
        tmux attach-session -t "$SESSION_TYPE"
    else
        echo "Creating new tmux session..."
        tmux new-session -s "$SESSION_TYPE"
    fi
else
    echo "No terminal multiplexer available, using direct shell..."
    setup_mobile_env
    
    # Start a subshell with the mobile configuration
    echo "✅ Mobile shell ready - type 'exit' to return"
    bash --rcfile <(echo "source ~/.bashrc; $(declare -f setup_mobile_env); setup_mobile_env")
fi
