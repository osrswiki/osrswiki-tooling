#!/bin/bash
set -euo pipefail

# Setup helper for OSRS Wiki internal deployment on any fleet Mac.
# Creates ~/.config/osrswiki, copies templates, optionally pulls from home,
# sets up Python venv, and validates with --validate-only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INTERNAL_DEPLOY_DIR="$REPO_ROOT/scripts/internal-deploy"
CONFIG_DIR="${OSRSWIKI_CONFIG_DIR:-$HOME/.config/osrswiki}"
HOME_HOST="${OSRSWIKI_HOME_HOST:-home}"

# Define print functions without requiring artifact root validation.
# These are the same fallback implementations from common.sh.
COLOR_SCRIPT="$REPO_ROOT/scripts/shared/color-utils.sh"
if [[ -f "$COLOR_SCRIPT" ]]; then
    # shellcheck disable=SC1090
    source "$COLOR_SCRIPT"
else
    print_header() { echo "$1"; }
    print_phase() { echo "$1"; }
    print_success() { echo "OK: $1"; }
    print_warning() { echo "WARN: $1"; }
    print_error() { echo "ERROR: $1" >&2; }
    print_info() { echo "INFO: $1"; }
fi

usage() {
    cat <<'EOF'
Usage:
  scripts/shared/setup-internal-deploy.sh [--pull-from-home] [--validate]

Setup internal deployment credentials and configuration for this Mac.

Options:
  --pull-from-home  Copy ~/.config/osrswiki from the 'home' host over SSH (BatchMode).
                    Requires Tailscale connection to home and SSH key auth.
  --validate        Run deploy-internal.sh --validate-only after setup.
  -h, --help        Show this help message.

What this does:
  1. Creates ~/.config/osrswiki if missing
  2. Copies committed template files if missing:
     - internal-deploy.env.example -> internal-deploy.env
     - android-signing.properties.example -> android-signing.properties
  3. If --pull-from-home: copies entire ~/.config/osrswiki from home host
  4. Creates Python venv with google-api-python-client and google-auth if needed
  5. If --validate: runs deploy-internal.sh --validate-only

Machine recipe:
    Headless/SSH iOS signing:
  Ensure ~/.config/osrswiki/ios-{development,distribution}.p12 (+ .pass) exist, then run:
    ./scripts/shared/ios-headless-codesign.sh prepare
  deploy-internal.sh calls prepare before archive and restore on EXIT
  (signing keychain is not left in the default search list).
  If a GUI codesign password dialog appears, Cancel and run:
    ./scripts/shared/ios-headless-codesign.sh restore

For complete Mac setup (Homebrew, Xcode, Tailscale, SSH keys, etc.),
  see ~/tools/bringup (not managed by this repo).

Never commit:
  - Populated .env files
  - Android keystores or signing.properties with real values
  - Google Play service-account JSON keys
  - App Store Connect .p8 keys
  - Any passwords or secrets
EOF
}

PULL_FROM_HOME=false
RUN_VALIDATE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull-from-home) PULL_FROM_HOME=true ;;
        --validate) RUN_VALIDATE=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

print_header "OSRS Wiki internal deployment setup"
echo "Config directory: $CONFIG_DIR"
echo "Repo: $REPO_ROOT"
echo ""

# Step 1: Create config directory
print_phase "Creating config directory"
if [[ -d "$CONFIG_DIR" ]]; then
    print_info "Config directory already exists: $CONFIG_DIR"
else
    mkdir -p "$CONFIG_DIR"
    print_success "Created config directory: $CONFIG_DIR"
fi

# Step 2: Copy templates if missing
print_phase "Checking template files"

if [[ ! -f "$CONFIG_DIR/internal-deploy.env" ]]; then
    cp "$INTERNAL_DEPLOY_DIR/.env.example" "$CONFIG_DIR/internal-deploy.env"
    print_success "Copied internal-deploy.env template"
    print_warning "Edit $CONFIG_DIR/internal-deploy.env and fill in credentials"
else
    print_info "internal-deploy.env already exists"
fi

if [[ ! -f "$CONFIG_DIR/android-signing.properties" ]]; then
    if [[ -f "$INTERNAL_DEPLOY_DIR/config/android-signing.properties.example" ]]; then
        cp "$INTERNAL_DEPLOY_DIR/config/android-signing.properties.example" "$CONFIG_DIR/android-signing.properties"
        print_success "Copied android-signing.properties template"
        print_warning "Edit $CONFIG_DIR/android-signing.properties and fill in signing credentials"
    else
        print_warning "android-signing.properties.example not found in repo"
    fi
else
    print_info "android-signing.properties already exists"
fi

# Step 3: Pull from home if requested
if [[ "$PULL_FROM_HOME" == true ]]; then
    print_phase "Pulling config from home host"
    
    CURRENT_HOST="$(hostname -s)"
    if [[ "$CURRENT_HOST" == "$HOME_HOST" ]]; then
        print_warning "Already on home host, skipping pull"
    else
        if ! command -v ssh >/dev/null 2>&1; then
            print_error "ssh command not found"
            exit 1
        fi
        
        print_info "Attempting to copy ~/.config/osrswiki from $HOME_HOST..."
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOME_HOST" "test -d ~/.config/osrswiki" 2>/dev/null; then
            # Preserve local storage.env before backup/rsync (machine-local artifact root config)
            local_storage_env=""
            if [[ -f "$CONFIG_DIR/storage.env" ]]; then
                local_storage_env="$(mktemp)"
                cp "$CONFIG_DIR/storage.env" "$local_storage_env"
                print_info "Preserved local storage.env"
            fi
            
            # Create backup if local config exists
            if [[ -d "$CONFIG_DIR" ]] && [[ "$(ls -A "$CONFIG_DIR" 2>/dev/null | wc -l)" -gt 0 ]]; then
                backup_dir="$CONFIG_DIR.backup-$(date +%Y%m%d-%H%M%S)"
                mv "$CONFIG_DIR" "$backup_dir"
                print_info "Backed up existing config to: $backup_dir"
            fi
            
            mkdir -p "$CONFIG_DIR"
            # Use rsync for reliable directory copy with permissions
            # Exclude storage.env: machine-local artifact root config must not be copied from home
            if command -v rsync >/dev/null 2>&1; then
                rsync -az --delete --exclude='storage.env' "$HOME_HOST:~/.config/osrswiki/" "$CONFIG_DIR/"
                print_success "Copied config from $HOME_HOST using rsync"
            else
                scp -r "$HOME_HOST:~/.config/osrswiki/"* "$CONFIG_DIR/"
                print_success "Copied config from $HOME_HOST using scp"
                # Remove storage.env if scp copied it
                if [[ -f "$CONFIG_DIR/storage.env" ]] && [[ -z "$local_storage_env" ]]; then
                    rm "$CONFIG_DIR/storage.env"
                    print_info "Removed storage.env copied via scp (machine-local config)"
                fi
            fi
            
            # Restore local storage.env if it existed
            if [[ -n "$local_storage_env" ]] && [[ -f "$local_storage_env" ]]; then
                cp "$local_storage_env" "$CONFIG_DIR/storage.env"
                rm "$local_storage_env"
                print_info "Restored local storage.env"
            fi
        else
            print_error "Cannot connect to $HOME_HOST or ~/.config/osrswiki does not exist there"
            print_info "Make sure Tailscale is running and SSH key authentication is configured"
            exit 1
        fi
    fi
fi

# Step 4: Setup Python venv if needed
print_phase "Checking Python environment"

VENV_DIR="$CONFIG_DIR/internal-deploy-venv"
VENV_PYTHON="$VENV_DIR/bin/python"

if [[ -f "$VENV_PYTHON" ]]; then
    print_info "Python venv already exists: $VENV_DIR"
    if "$VENV_PYTHON" -c "import google.oauth2.service_account, googleapiclient.discovery" 2>/dev/null; then
        print_success "Python venv has required packages"
    else
        print_warning "Python venv exists but missing required packages, reinstalling..."
        "$VENV_PYTHON" -m pip install -q google-api-python-client google-auth
        print_success "Installed google-api-python-client and google-auth"
    fi
else
    if ! command -v python3 >/dev/null 2>&1; then
        print_error "python3 not found. Install Python 3 and retry."
        exit 1
    fi
    
    print_info "Creating Python venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    print_success "Created Python venv"
    
    print_info "Installing google-api-python-client and google-auth..."
    "$VENV_PYTHON" -m pip install -q --upgrade pip
    "$VENV_PYTHON" -m pip install -q google-api-python-client google-auth
    print_success "Installed Python packages"
fi

# Update internal-deploy.env to point to venv if not already set
if [[ -f "$CONFIG_DIR/internal-deploy.env" ]]; then
    if ! grep -q "^OSRSWIKI_INTERNAL_DEPLOY_PYTHON=" "$CONFIG_DIR/internal-deploy.env"; then
        echo "" >> "$CONFIG_DIR/internal-deploy.env"
        echo "# Added by setup-internal-deploy.sh" >> "$CONFIG_DIR/internal-deploy.env"
        echo "OSRSWIKI_INTERNAL_DEPLOY_PYTHON=$VENV_PYTHON" >> "$CONFIG_DIR/internal-deploy.env"
        print_success "Set OSRSWIKI_INTERNAL_DEPLOY_PYTHON in internal-deploy.env"
    fi
fi

# Step 5: Print checklist
print_phase "Configuration checklist"
echo ""
echo "Required files and settings:"
echo ""

checklist_item() {
    local label="$1"
    local check_cmd="$2"
    local hint="$3"
    
    if eval "$check_cmd" 2>/dev/null; then
        print_success "$label: configured"
    else
        print_warning "$label: NOT configured"
        if [[ -n "$hint" ]]; then
            echo "  → $hint"
        fi
    fi
}

checklist_item "internal-deploy.env" \
    "[[ -f '$CONFIG_DIR/internal-deploy.env' ]]" \
    "Edit $CONFIG_DIR/internal-deploy.env"

checklist_item "Google Play service account JSON" \
    "source '$CONFIG_DIR/internal-deploy.env' 2>/dev/null && [[ -f \"\${PLAY_SERVICE_ACCOUNT_JSON:-}\" ]]" \
    "Set PLAY_SERVICE_ACCOUNT_JSON in internal-deploy.env"

checklist_item "Android signing properties" \
    "[[ -f '$CONFIG_DIR/android-signing.properties' ]] && ! grep -q REPLACE_WITH '$CONFIG_DIR/android-signing.properties'" \
    "Edit $CONFIG_DIR/android-signing.properties with real keystore path and passwords"

checklist_item "App Store Connect API key ID" \
    "source '$CONFIG_DIR/internal-deploy.env' 2>/dev/null && [[ -n \"\${ASC_API_KEY_ID:-}\" ]] && [[ \"\$ASC_API_KEY_ID\" != REPLACE_WITH* ]]" \
    "Set ASC_API_KEY_ID in internal-deploy.env"

checklist_item "App Store Connect API issuer ID" \
    "source '$CONFIG_DIR/internal-deploy.env' 2>/dev/null && [[ -n \"\${ASC_API_ISSUER_ID:-}\" ]] && [[ \"\$ASC_API_ISSUER_ID\" != REPLACE_WITH* ]]" \
    "Set ASC_API_ISSUER_ID in internal-deploy.env"

checklist_item "App Store Connect API key file" \
    "source '$CONFIG_DIR/internal-deploy.env' 2>/dev/null && [[ -f \"\${ASC_API_KEY_PATH:-}\" ]]" \
    "Set ASC_API_KEY_PATH in internal-deploy.env and place the .p8 file there"

checklist_item "Python environment with Google API packages" \
    "[[ -f '$VENV_PYTHON' ]] && '$VENV_PYTHON' -c 'import google.oauth2.service_account, googleapiclient.discovery' 2>/dev/null" \
    "Already configured by this script"

echo ""

# Step 6: Run validation if requested
if [[ "$RUN_VALIDATE" == true ]]; then
    print_phase "Running deploy validation"
    echo ""
    "$REPO_ROOT/scripts/shared/deploy-internal.sh" --validate-only
fi

print_success "Setup complete"
echo ""
echo "Next steps:"
echo "  1. Edit $CONFIG_DIR/internal-deploy.env with real credential paths and IDs"
echo "  2. Place actual secret files (keystore, JSON, .p8) in $CONFIG_DIR/"
echo "  3. Edit $CONFIG_DIR/android-signing.properties with real values"
echo "  4. Run: $REPO_ROOT/scripts/shared/deploy-internal.sh --validate-only"
echo "  5. Run: $REPO_ROOT/scripts/shared/deploy-internal.sh --dry-run --no-bump"
echo ""
echo "For complete Mac setup (Homebrew, Xcode, Tailscale, etc.), see ~/tools/bringup"
