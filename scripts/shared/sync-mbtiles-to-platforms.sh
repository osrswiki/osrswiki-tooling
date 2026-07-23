#!/bin/bash
set -euo pipefail

# Sync MBTiles from cache to platform directories
# Run this after generating new mbtiles with slice_tiles.py

# Source the repository discovery utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/find-git-repo.sh"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}🗺️  MBTiles Sync - Copying map assets to platforms${NC}"

# Find paths dynamically
if ! MAIN_REPO=$(find_primary_repo); then
    echo -e "${RED}❌ Could not find primary Fleet Sync checkout${NC}" >&2
    exit 1
fi

CACHE_BASE="$(get_cache_dir)"
CACHE_MBTILES="$CACHE_BASE/binary-assets/mbtiles"

# Determine if we're in main or a session
CURRENT_DIR=$(pwd)
if [[ "$CURRENT_DIR" == *"/sessions/"* ]]; then
    # In a session - use session's platform directories
    REPO_ROOT="$CURRENT_DIR"
    echo "Running from session: $(basename "$CURRENT_DIR")"
else
    # In main or elsewhere - use main repo
    REPO_ROOT="$MAIN_REPO"
    echo "Running from main repository"
fi

IOS_ASSETS="$REPO_ROOT/platforms/ios/osrswiki"
ANDROID_ASSETS="$REPO_ROOT/platforms/android/app/src/main/assets"
MAP_DEFAULT_VIEW="$REPO_ROOT/shared/map-default-view.json"
STAMP_MAP_DEFAULT_VIEW="$SCRIPT_DIR/stamp-map-default-view.py"
MAP_METADATA_CANDIDATES=(
    "$CACHE_MBTILES/map-metadata.json"
    "$CACHE_BASE/binary-assets/map-images/output/map-metadata.json"
)

stamp_default_map_view() {
    # Generates platforms/ios/osrswiki/Models/osrsMapDefaultView.swift and
    # platforms/android/app/src/main/java/com/omiyawaki/osrswiki/ui/map/osrsMapDefaultView.kt.
    if [[ ! -f "$MAP_DEFAULT_VIEW" ]]; then
        echo -e "${RED}❌ Map default view manifest not found: $MAP_DEFAULT_VIEW${NC}" >&2
        exit 1
    fi

    if [[ ! -x "$STAMP_MAP_DEFAULT_VIEW" ]]; then
        echo -e "${RED}❌ Map default view stamping helper not executable: $STAMP_MAP_DEFAULT_VIEW${NC}" >&2
        exit 1
    fi

    metadata_args=()
    for metadata_path in "${MAP_METADATA_CANDIDATES[@]}"; do
        if [[ -f "$metadata_path" ]]; then
            metadata_args=(--metadata "$metadata_path")
            echo -e "${BLUE}Using map metadata: $metadata_path${NC}"
            break
        fi
    done

    if [[ ${#metadata_args[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  map-metadata.json not found; falling back to projection in shared/map-default-view.json${NC}"
    fi

    echo -e "${YELLOW}📍 Stamping default map view from shared manifest...${NC}"
    python3 "$STAMP_MAP_DEFAULT_VIEW" \
        --repo-root "$REPO_ROOT" \
        --manifest "$MAP_DEFAULT_VIEW" \
        "${metadata_args[@]}"
}

# Check if cache has mbtiles
if [[ ! -d "$CACHE_MBTILES" ]]; then
    echo -e "${RED}❌ Cache mbtiles directory not found: $CACHE_MBTILES${NC}"
    echo "Run slice_tiles.py first to generate mbtiles"
    exit 1
fi

mbtiles_count=$(find "$CACHE_MBTILES" -name "*.mbtiles" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$mbtiles_count" -eq 0 ]]; then
    echo -e "${RED}❌ No mbtiles files found in cache${NC}"
    echo "Run slice_tiles.py first to generate mbtiles"
    exit 1
fi

echo -e "${BLUE}Source: $CACHE_MBTILES ($mbtiles_count files)${NC}"
echo ""

stamp_default_map_view

echo ""

# Sync to iOS
if [[ -d "$IOS_ASSETS" ]]; then
    echo -e "${YELLOW}📱 Syncing to iOS...${NC}"

    synced=0
    for mbtiles in "$CACHE_MBTILES"/*.mbtiles; do
        filename=$(basename "$mbtiles")
        target="$IOS_ASSETS/$filename"

        # Check if file needs updating (cache is newer or target doesn't exist)
        if [[ ! -f "$target" ]] || [[ "$mbtiles" -nt "$target" ]]; then
            cp "$mbtiles" "$target"
            echo "  ✓ $filename"
            ((synced++))
        fi
    done

    if [[ $synced -eq 0 ]]; then
        echo -e "  ${GREEN}Already up-to-date${NC}"
    else
        echo -e "  ${GREEN}Synced $synced file(s)${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  iOS assets directory not found: $IOS_ASSETS${NC}"
fi

echo ""

# Sync to Android
if [[ -d "$ANDROID_ASSETS" ]]; then
    echo -e "${YELLOW}🤖 Syncing to Android...${NC}"

    synced=0
    for mbtiles in "$CACHE_MBTILES"/*.mbtiles; do
        filename=$(basename "$mbtiles")
        target="$ANDROID_ASSETS/$filename"

        # Check if file needs updating (cache is newer or target doesn't exist)
        if [[ ! -f "$target" ]] || [[ "$mbtiles" -nt "$target" ]]; then
            cp "$mbtiles" "$target"
            echo "  ✓ $filename"
            ((synced++))
        fi
    done

    if [[ $synced -eq 0 ]]; then
        echo -e "  ${GREEN}Already up-to-date${NC}"
    else
        echo -e "  ${GREEN}Synced $synced file(s)${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Android assets directory not found: $ANDROID_ASSETS${NC}"
fi

echo ""
echo -e "${GREEN}✅ MBTiles sync complete${NC}"
echo ""
echo -e "${BLUE}💡 Next steps:${NC}"
echo "   • iOS: Rebuild the app to include new mbtiles"
echo "   • Android: The build will pick up new assets automatically"
echo "   • Verify default view: iOS MapDefaultCenterUITests, Android ExpandedAndroidEnvironmentTest"
