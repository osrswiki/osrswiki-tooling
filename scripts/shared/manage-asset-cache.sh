#!/bin/bash
set -euo pipefail

# OSRS Wiki Asset Cache Management Script
# Provides utilities for managing the centralized binary asset cache

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get script directory and source the repository discovery utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/find-git-repo.sh"

# Dynamically discover cache directory
if ! CACHE_BASE=$(get_cache_dir); then
    echo -e "${RED}ERROR: Could not find monorepo root (no cache/ directory found)${NC}" >&2
    echo "This script must be run from within the osrswiki monorepo structure." >&2
    exit 1
fi

MBTILES_CACHE="$CACHE_BASE/binary-assets/mbtiles"
MAP_IMAGES_CACHE="$CACHE_BASE/binary-assets/map-images"
GAME_DATA_CACHE="$CACHE_BASE/game-data"

# Commands
COMMAND="${1:-status}"

print_usage() {
    echo -e "${BLUE}OSRS Wiki Asset Cache Management${NC}"
    echo "=================================="
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  status          Show cache status and statistics"
    echo "  init            Initialize cache directory structure"
    echo "  clean           Clean up cache (interactive)"
    echo "  validate        Validate cache integrity"
    echo "  info            Show detailed cache information"
    echo "  size            Show cache size breakdown"
    echo "  list            List all cached files"
    echo ""
    echo "Examples:"
    echo "  $0 status       # Show cache overview"
    echo "  $0 init         # Create cache directories"
    echo "  $0 clean        # Interactively clean cache"
    echo "  $0 validate     # Check cache integrity"
}

print_separator() {
    echo "=================================================="
}

init_cache() {
    echo -e "${BLUE}🏗️  Initializing Asset Cache${NC}"
    print_separator
    
    echo "Creating cache directory structure..."
    mkdir -p "$MBTILES_CACHE"
    mkdir -p "$MAP_IMAGES_CACHE/output"
    mkdir -p "$GAME_DATA_CACHE"
    
    echo -e "${GREEN}✅ Created cache directories:${NC}"
    echo "  • $MBTILES_CACHE"
    echo "  • $MAP_IMAGES_CACHE"
    echo "  • $GAME_DATA_CACHE"
    
    echo ""
    echo -e "${YELLOW}💡 Next steps:${NC}"
    echo "1. Run asset generation to populate cache:"
    echo "   cd tools && pixi run map-assets"
    echo "2. Build system will automatically discover cached assets"
    echo "3. New worktrees will have immediate access to binary assets"
}

show_status() {
    echo -e "${BLUE}📊 Asset Cache Status${NC}"
    print_separator
    
    if [[ ! -d "$CACHE_BASE" ]]; then
        echo -e "${RED}❌ Cache not initialized${NC}"
        echo "Run: $0 init"
        return 1
    fi
    
    echo -e "${GREEN}✅ Cache location: $CACHE_BASE${NC}"
    
    # Binary assets
    echo ""
    echo -e "${YELLOW}📦 Binary Assets${NC}"
    echo "----------------"
    
    if [[ -d "$MBTILES_CACHE" ]]; then
        local mbtiles_count=$(find "$MBTILES_CACHE" -name "*.mbtiles" 2>/dev/null | wc -l)
        local mbtiles_size=$(du -sh "$MBTILES_CACHE" 2>/dev/null | cut -f1 || echo "0B")
        echo "• Map tiles (.mbtiles): $mbtiles_count files ($mbtiles_size)"
    else
        echo "• Map tiles (.mbtiles): No cache directory"
    fi
    
    if [[ -d "$MAP_IMAGES_CACHE" ]]; then
        local images_count=$(find "$MAP_IMAGES_CACHE" -name "*.png" 2>/dev/null | wc -l)
        local images_size=$(du -sh "$MAP_IMAGES_CACHE" 2>/dev/null | cut -f1 || echo "0B")
        echo "• Map images (.png): $images_count files ($images_size)"
    else
        echo "• Map images (.png): No cache directory"
    fi
    
    # Game data
    echo ""
    echo -e "${YELLOW}🎮 Game Data${NC}"
    echo "------------"
    
    if [[ -d "$GAME_DATA_CACHE/openrs2_cache" ]]; then
        local cache_size=$(du -sh "$GAME_DATA_CACHE/openrs2_cache" 2>/dev/null | cut -f1 || echo "0B")
        local cache_files=$(find "$GAME_DATA_CACHE/openrs2_cache" -type f 2>/dev/null | wc -l)
        echo "• OpenRS2 cache: $cache_files files ($cache_size)"
        
        if [[ -f "$GAME_DATA_CACHE/openrs2_cache/cache.version" ]]; then
            local version=$(cat "$GAME_DATA_CACHE/openrs2_cache/cache.version" 2>/dev/null || echo "unknown")
            echo "  Version: $version"
        fi
    else
        echo "• OpenRS2 cache: Not present"
    fi
    
    # Total cache size
    echo ""
    echo -e "${CYAN}📏 Total Cache Size${NC}"
    echo "-------------------"
    if [[ -d "$CACHE_BASE" ]]; then
        local total_size=$(du -sh "$CACHE_BASE" 2>/dev/null | cut -f1 || echo "0B")
        local total_files=$(find "$CACHE_BASE" -type f 2>/dev/null | wc -l)
        echo "• Total: $total_files files ($total_size)"
    fi
}

show_detailed_info() {
    echo -e "${BLUE}📋 Detailed Cache Information${NC}"
    print_separator
    
    show_status
    
    echo ""
    echo -e "${YELLOW}🔍 File Details${NC}"
    echo "---------------"
    
    if [[ -d "$MBTILES_CACHE" ]]; then
        echo ""
        echo "Map Tiles (.mbtiles):"
        find "$MBTILES_CACHE" -name "*.mbtiles" -exec ls -lh {} \; 2>/dev/null | \
            awk '{printf "  • %-20s %8s %s %s %s\n", $9, $5, $6, $7, $8}' || echo "  (none found)"
    fi
    
    if [[ -d "$MAP_IMAGES_CACHE/output" ]]; then
        echo ""
        echo "Map Images (.png):"
        find "$MAP_IMAGES_CACHE/output" -name "*.png" -exec ls -lh {} \; 2>/dev/null | \
            awk '{printf "  • %-20s %8s %s %s %s\n", $9, $5, $6, $7, $8}' || echo "  (none found)"
    fi
    
    if [[ -d "$GAME_DATA_CACHE/openrs2_cache" ]]; then
        echo ""
        echo "OpenRS2 Cache (top 10 largest files):"
        find "$GAME_DATA_CACHE/openrs2_cache" -type f -exec ls -lh {} \; 2>/dev/null | \
            sort -k5 -hr | head -10 | \
            awk '{printf "  • %-30s %8s\n", $9, $5}' || echo "  (none found)"
    fi
}

validate_cache() {
    echo -e "${BLUE}✅ Cache Validation${NC}"
    print_separator
    
    local errors=0
    
    # Check directory structure
    echo "Checking directory structure..."
    for dir in "$MBTILES_CACHE" "$MAP_IMAGES_CACHE" "$GAME_DATA_CACHE"; do
        if [[ -d "$dir" ]]; then
            echo -e "${GREEN}✅ $dir${NC}"
        else
            echo -e "${YELLOW}⚠️  $dir (missing)${NC}"
        fi
    done
    
    # Check expected .mbtiles files
    echo ""
    echo "Checking map tiles..."
    local expected_floors=(0 1 2 3)
    for floor in "${expected_floors[@]}"; do
        local mbtiles_file="$MBTILES_CACHE/map_floor_${floor}.mbtiles"
        if [[ -f "$mbtiles_file" ]]; then
            local size=$(stat -c%s "$mbtiles_file" 2>/dev/null || stat -f%z "$mbtiles_file" 2>/dev/null)
            if [[ $size -gt 0 ]]; then
                echo -e "${GREEN}✅ Floor $floor: $(basename "$mbtiles_file") (${size} bytes)${NC}"
            else
                echo -e "${RED}❌ Floor $floor: $(basename "$mbtiles_file") (empty file)${NC}"
                ((errors++))
            fi
        else
            echo -e "${YELLOW}⚠️  Floor $floor: map_floor_${floor}.mbtiles (missing)${NC}"
        fi
    done
    
    # Check OpenRS2 cache
    echo ""
    echo "Checking game data..."
    if [[ -d "$GAME_DATA_CACHE/openrs2_cache" ]]; then
        local cache_files=$(find "$GAME_DATA_CACHE/openrs2_cache" -name "main_file_cache.*" | wc -l)
        if [[ $cache_files -gt 0 ]]; then
            echo -e "${GREEN}✅ OpenRS2 cache: $cache_files files${NC}"
        else
            echo -e "${YELLOW}⚠️  OpenRS2 cache: No cache files found${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  OpenRS2 cache directory not found${NC}"
    fi
    
    echo ""
    if [[ $errors -eq 0 ]]; then
        echo -e "${GREEN}✅ Cache validation passed${NC}"
        return 0
    else
        echo -e "${RED}❌ Cache validation failed with $errors errors${NC}"
        echo ""
        echo "To regenerate missing assets, run:"
        echo "  cd tools && pixi run map-assets"
        return 1
    fi
}

clean_cache() {
    echo -e "${BLUE}🧹 Cache Cleanup${NC}"
    print_separator
    
    if [[ ! -d "$CACHE_BASE" ]]; then
        echo -e "${YELLOW}⚠️  Cache directory not found${NC}"
        return 0
    fi
    
    echo "Current cache usage:"
    show_status
    
    echo ""
    echo -e "${YELLOW}⚠️  Warning: This will permanently delete cached files${NC}"
    echo ""
    echo "What would you like to clean?"
    echo "1) All cache files (complete reset)"
    echo "2) Map tiles only (.mbtiles files)"
    echo "3) Map images only (.png files)" 
    echo "4) Game data only (OpenRS2 cache)"
    echo "5) Cancel"
    echo ""
    
    read -p "Enter your choice (1-5): " choice
    
    case $choice in
        1)
            echo ""
            echo -e "${RED}⚠️  This will delete ALL cached files${NC}"
            read -p "Type 'DELETE ALL' to confirm: " confirm
            if [[ "$confirm" == "DELETE ALL" ]]; then
                rm -rf "$CACHE_BASE"
                echo -e "${GREEN}✅ All cache files deleted${NC}"
                echo "Run '$0 init' to recreate cache structure"
            else
                echo "Cleanup cancelled"
            fi
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Deleting map tiles (.mbtiles)...${NC}"
            rm -f "$MBTILES_CACHE"/*.mbtiles 2>/dev/null || true
            echo -e "${GREEN}✅ Map tiles deleted${NC}"
            ;;
        3)
            echo ""
            echo -e "${YELLOW}Deleting map images (.png)...${NC}"
            rm -f "$MAP_IMAGES_CACHE/output"/*.png 2>/dev/null || true
            echo -e "${GREEN}✅ Map images deleted${NC}"
            ;;
        4)
            echo ""
            echo -e "${YELLOW}Deleting game data (OpenRS2 cache)...${NC}"
            rm -rf "$GAME_DATA_CACHE/openrs2_cache" 2>/dev/null || true
            echo -e "${GREEN}✅ Game data deleted${NC}"
            ;;
        5)
            echo "Cleanup cancelled"
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
}

list_files() {
    echo -e "${BLUE}📄 Cache File Listing${NC}"
    print_separator
    
    if [[ ! -d "$CACHE_BASE" ]]; then
        echo -e "${RED}❌ Cache not initialized${NC}"
        return 1
    fi
    
    echo "All cached files:"
    find "$CACHE_BASE" -type f -exec ls -lh {} \; | sort -k9 | \
        awk '{printf "  %-8s  %s %s %s  %s\n", $5, $6, $7, $8, $9}'
}

show_size_breakdown() {
    echo -e "${BLUE}📏 Cache Size Breakdown${NC}"
    print_separator
    
    if [[ ! -d "$CACHE_BASE" ]]; then
        echo -e "${RED}❌ Cache not initialized${NC}"
        return 1
    fi
    
    echo "Directory sizes:"
    du -sh "$CACHE_BASE"/* 2>/dev/null | sort -hr | while read size path; do
        echo "  $size  $(basename "$path")"
    done
    
    echo ""
    echo "File type breakdown:"
    
    # Count by file extension
    find "$CACHE_BASE" -type f -name "*.*" | sed 's/.*\.//' | sort | uniq -c | sort -nr | \
        while read count ext; do
            local total_size=$(find "$CACHE_BASE" -name "*.$ext" -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1 || echo "0")
            printf "  %6d files  %-10s  %s\n" "$count" ".$ext" "$total_size"
        done
}

# Main execution
case "$COMMAND" in
    "status"|"")
        show_status
        ;;
    "init")
        init_cache
        ;;
    "clean")
        clean_cache
        ;;
    "validate")
        validate_cache
        ;;
    "info")
        show_detailed_info
        ;;
    "size")
        show_size_breakdown
        ;;
    "list")
        list_files
        ;;
    "help"|"--help"|"-h")
        print_usage
        ;;
    *)
        echo -e "${RED}❌ Unknown command: $COMMAND${NC}"
        echo ""
        print_usage
        exit 1
        ;;
esac
