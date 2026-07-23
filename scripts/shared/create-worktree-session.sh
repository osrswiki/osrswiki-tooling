#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Use find-git-repo.sh for robust repository discovery
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/find-git-repo.sh"

# Discover repository locations
if ! REPO_CONTEXT=$(validate_repo_context); then
    echo -e "${RED}❌ Repository discovery failed${NC}"
    echo "$REPO_CONTEXT"
    echo "Run this script from within the osrswiki project structure"
    exit 1
fi

# Parse repository context
eval "$REPO_CONTEXT"
GIT_ROOT="$REPO_ROOT"
MONOREPO_ROOT="${MONOREPO_ROOT:-$PARENT_DIR}"
PROJECT_ROOT="$MONOREPO_ROOT"

echo -e "${GREEN}✅ Repository discovered:${NC}"
echo "   Git root: $GIT_ROOT"
echo "   Project root: $PROJECT_ROOT"

# Safety check: ensure we're not creating a worktree from another linked worktree
if [[ "$(cd "$GIT_ROOT" && git rev-parse --git-dir)" != "$(cd "$GIT_ROOT" && git rev-parse --git-common-dir)" ]]; then
    echo -e "${RED}❌ Cannot create worktree from inside another worktree${NC}"
    echo "Run this script from the primary Fleet Sync checkout"
    exit 1
fi

TOPIC="${1:-development}"
SESSION_NAME="codex-$(date +%Y%m%d-%H%M%S)-$TOPIC"
BRANCH_NAME="codex/$(date +%Y%m%d-%H%M%S)-$TOPIC"

# New worktrees and heavyweight artifacts are machine-local. The resolver
# verifies the configured root before returning either path.
SESSION_PARENT="$(get_sessions_dir)"
WORKTREE_DIR="$SESSION_PARENT/$SESSION_NAME"
SESSION_ARTIFACT_DIR="$(osrs_prepare_artifact_dir active "$SESSION_NAME")"
STARTING_HEAD="$(git -C "$GIT_ROOT" rev-parse HEAD)"
AVAILABLE_KIB="$(osrs_local_storage_status | awk -F= '$1 == "available_kib" { print $2 }')"

# Ensure sessions directory exists
if [[ ! -d "$SESSION_PARENT" ]]; then
    echo -e "${YELLOW}📁 Creating sessions directory: $SESSION_PARENT${NC}"
    mkdir -p "$SESSION_PARENT"
fi

echo -e "${BLUE}🌿 Creating worktree session: $SESSION_NAME${NC}"
echo -e "${BLUE}📁 Directory: $WORKTREE_DIR${NC}" 
echo -e "${BLUE}🌿 Branch: $BRANCH_NAME${NC}"
echo -e "${BLUE}💽 Local free space (advisory): ${AVAILABLE_KIB} KiB${NC}"

# Safety check: ensure directory doesn't already exist
if [[ -d "$WORKTREE_DIR" ]]; then
    echo -e "${RED}❌ Session directory already exists: $WORKTREE_DIR${NC}"
    echo "Choose a different topic name or remove the existing directory"
    exit 1
fi

# Create worktree with new branch (from git repo)
echo -e "${YELLOW}🔨 Creating git worktree...${NC}"
cd "$GIT_ROOT" && git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"

# Set up shared scripts in worktree
cd "$WORKTREE_DIR"

# Verify platforms directory is present (should be included since it's tracked in git)
if [[ ! -d "platforms/android" || ! -d "platforms/ios" ]]; then
    echo -e "${RED}⚠️  Warning: platforms/ directory missing from worktree${NC}"
    echo "This may indicate an issue with git tracking. Platforms should be available for development."
else
    echo -e "${GREEN}✅ Platforms directory verified in worktree${NC}"
fi

# Copy essential untracked files from main repo
MAIN_REPO_PATH="$GIT_ROOT"
CACHE_BASE="$(get_cache_dir)"
echo -e "${YELLOW}📁 Copying essential untracked files...${NC}"

# Copy Android local.properties if it exists (contains SDK path)
if [[ -f "$MAIN_REPO_PATH/platforms/android/local.properties" ]]; then
    cp "$MAIN_REPO_PATH/platforms/android/local.properties" platforms/android/
    echo -e "${GREEN}✅ Copied platforms/android/local.properties${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: local.properties not found in main repo${NC}"
fi

# Copy asset-mapping.json if it exists (for asset management)
if [[ -f "$MAIN_REPO_PATH/shared/asset-mapping.json" ]]; then
    cp "$MAIN_REPO_PATH/shared/asset-mapping.json" shared/
    echo -e "${GREEN}✅ Copied shared/asset-mapping.json${NC}"
else
    echo -e "${YELLOW}⚠️  asset-mapping.json not found in main repo${NC}"
fi

# Check machine-local cache availability without traversing it.
echo -e "${YELLOW}📦 Checking machine-local asset cache...${NC}"
if [[ -d "$CACHE_BASE/binary-assets/mbtiles" ]]; then
    echo -e "${GREEN}✅ Machine-local map cache found: $CACHE_BASE${NC}"
else
    echo -e "${YELLOW}⚠️  Machine-local map cache is not populated: $CACHE_BASE${NC}"
    echo -e "${YELLOW}   • Binary assets (.mbtiles) may be missing${NC}"
    echo -e "${YELLOW}   • Generate required assets locally; do not copy the legacy synced cache during an incident hold${NC}"
fi

# Create required empty directories that git doesn't track
echo -e "${YELLOW}📁 Creating required empty directories...${NC}"
mkdir -p platforms/android/app/src/main/assets
echo -e "${GREEN}✅ Created platforms/android/app/src/main/assets${NC}"

# Persist machine-local routing for scripts launched from this worktree.
cat > .osrs-artifacts.env <<EOF
export OSRS_LOCAL_ARTIFACT_ROOT=$(printf '%q' "$OSRS_LOCAL_ARTIFACT_ROOT")
export OSRS_ARTIFACT_HOST_ID=$(printf '%q' "$OSRS_ARTIFACT_HOST_ID")
export OSRS_LANE_ID=$(printf '%q' "$SESSION_NAME")
export OSRS_SESSION_ARTIFACT_DIR=$(printf '%q' "$SESSION_ARTIFACT_DIR")
export OSRS_CACHE_ROOT=$(printf '%q' "$CACHE_BASE")
EOF
chmod 600 .osrs-artifacts.env
mkdir -p "$SESSION_ARTIFACT_DIR/screenshots"

SESSION_ARTIFACT_URI="$(osrs_artifact_reference "$SESSION_ARTIFACT_DIR")"
SESSION_WORKTREE_URI="$(osrs_artifact_reference "$WORKTREE_DIR")"
SESSION_RELATIVE_PATH="${SESSION_ARTIFACT_DIR#"$OSRS_LOCAL_ARTIFACT_ROOT/"}"
OSRS_MANIFEST_ARTIFACT_URI="$SESSION_ARTIFACT_URI" \
OSRS_MANIFEST_WORKTREE_URI="$SESSION_WORKTREE_URI" \
OSRS_MANIFEST_HOST_ID="$OSRS_ARTIFACT_HOST_ID" \
OSRS_MANIFEST_RELATIVE_PATH="$SESSION_RELATIVE_PATH" \
OSRS_MANIFEST_LANE_ID="$SESSION_NAME" \
OSRS_MANIFEST_THREAD_ID="${OSRS_THREAD_ID:-}" \
OSRS_MANIFEST_BRANCH="$BRANCH_NAME" \
OSRS_MANIFEST_STARTING_HEAD="$STARTING_HEAD" \
python3 - "$SESSION_ARTIFACT_DIR/manifest.json" <<'PY'
import datetime
import json
import os
import pathlib
import sys

owner = {
    "lane_id": os.environ["OSRS_MANIFEST_LANE_ID"],
    "branch": os.environ["OSRS_MANIFEST_BRANCH"],
}
if os.environ.get("OSRS_MANIFEST_THREAD_ID"):
    owner["thread_id"] = os.environ["OSRS_MANIFEST_THREAD_ID"]

manifest = {
    "version": 1,
    "artifact_uri": os.environ["OSRS_MANIFEST_ARTIFACT_URI"],
    "worktree_uri": os.environ["OSRS_MANIFEST_WORKTREE_URI"],
    "host_id": os.environ["OSRS_MANIFEST_HOST_ID"],
    "relative_path": os.environ["OSRS_MANIFEST_RELATIVE_PATH"],
    "state": "active",
    "owner": owner,
    "reproducible": False,
    "source_identity": {
        "starting_head": os.environ["OSRS_MANIFEST_STARTING_HEAD"],
        "branch": os.environ["OSRS_MANIFEST_BRANCH"],
    },
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
chmod 600 "$SESSION_ARTIFACT_DIR/manifest.json"

cat >> .osrs-artifacts.env <<EOF
export OSRS_SESSION_ARTIFACT_URI=$(printf '%q' "$SESSION_ARTIFACT_URI")
export OSRS_SESSION_WORKTREE_URI=$(printf '%q' "$SESSION_WORKTREE_URI")
EOF

echo -e "${GREEN}✅ Worktree session ready!${NC}"
echo -e "${GREEN}✅ Local artifacts: $SESSION_ARTIFACT_DIR${NC}"
echo -e "${GREEN}✅ Artifact reference: $SESSION_ARTIFACT_URI${NC}"
echo ""
echo -e "${BLUE}💡 To use this session:${NC}"
echo "   cd $WORKTREE_DIR"
echo "   source .osrs-artifacts.env"
echo ""
echo -e "${YELLOW}   # Android Development:${NC}"
echo "   ./scripts/android/setup-session-device.sh     # Start Android emulator (15s)"
echo "   ./scripts/android/setup-container-device.sh   # Container-optimized Android setup"
echo "   source .claude-env                             # Load Android environment variables"
echo "   ./scripts/android/quick-test.sh               # Build and deploy Android app (5s)"
echo "   ./scripts/android/take-screenshot.sh          # Take Android screenshot"
echo ""
echo -e "${YELLOW}   # iOS Development (macOS only):${NC}"
echo "   📖 REQUIRED: Read ./scripts/ios/XCTest-GUIDE.md first!"
echo "   ./scripts/ios/setup-session-simulator.sh      # Start iOS Simulator"
echo "   source .ios-env                                # Load iOS environment variables"
echo "   ./scripts/ios/quick-test.sh                   # Build and deploy iOS app"
echo "   ./scripts/ios/automate-app-testing.sh write-test ui MyFeature # WRITE tests first"
echo "   ./scripts/ios/automate-app-testing.sh quick-map # Test with XCTest framework"
echo "   ./scripts/ios/get-bundle-id.sh                # Get iOS bundle identifier"
echo ""
echo "   # ... develop ..."
echo "   ./scripts/shared/end-session.sh               # Release owned runtime resources"
echo ""
echo -e "${BLUE}💡 Retention:${NC}"
echo "   Preserve this worktree and its artifact directory until ownership is released, provenance is verified, and cleanup is separately authorized."
