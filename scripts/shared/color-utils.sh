#!/bin/bash

# Shared color utilities for deployment scripts
# Automatically disables colors in Claude Code environment to prevent output confusion

# Detect Claude Code environment
# Claude Code typically runs scripts in environments that don't have proper TTY
# or have specific environment variables that indicate automated execution
is_claude_code() {
    # Check for Claude Code specific indicators
    [[ -n "${CLAUDE_CODE:-}" ]] ||
    [[ -n "${ANTHROPIC_CLAUDE:-}" ]] ||
    # Check if we're in a non-interactive environment (common in Claude Code)
    [[ ! -t 1 ]] ||
    # Check if TERM is unset or basic (often the case in automated environments)
    [[ -z "${TERM:-}" ]] ||
    [[ "${TERM:-}" == "dumb" ]]
}

# Color definitions - will be empty strings if in Claude Code
if is_claude_code; then
    # Disable all colors for Claude Code to prevent confusion
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
else
    # Enable colors for interactive terminals
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
fi

# Utility functions for consistent output
print_header() {
    local title="$1"
    local border="$(printf '=%.0s' $(seq 1 ${#title}))"
    echo "${BLUE}${title}${NC}"
    echo "${border}"
}

print_phase() {
    local phase="$1"
    echo "${BLUE}${phase}${NC}"
    echo "$(printf -- '-%.0s' $(seq 1 32))"
}

print_success() {
    echo "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo "${RED}❌ $1${NC}" >&2
}

print_info() {
    echo "${CYAN}ℹ️  $1${NC}"
}

# Export functions so they can be used by sourcing scripts
export -f print_header print_phase print_success print_warning print_error print_info