#!/bin/bash
set -euo pipefail

# iOS Screenshots cleanup - equivalent to Android clean-screenshots.sh
# Manages screenshot lifecycle with conservative cleanup and listing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

SCREENSHOTS_DIR="${OSRS_SCREENSHOTS_DIR:-$(osrs_session_artifact_dir screenshots)}"
DEFAULT_MAX_AGE_HOURS=24

# Parse command line arguments
SHOW_LIST=false
DRY_RUN=true
MAX_AGE_HOURS=$DEFAULT_MAX_AGE_HOURS

while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            SHOW_LIST=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delete)
            DRY_RUN=false
            shift
            ;;
        --max-age)
            MAX_AGE_HOURS="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "OPTIONS:"
            echo "  --list          Show all screenshots with details"
            echo "  --dry-run       Preview what would be cleaned (default)"
            echo "  --delete        Delete only with OSRS_ARTIFACT_CLEANUP_AUTHORIZED=1"
            echo "  --max-age N     Clean screenshots older than N hours (default: $DEFAULT_MAX_AGE_HOURS)"
            echo "  --help          Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                    # Preview screenshots older than 24 hours"
            echo "  $0 --max-age 8       # Preview screenshots older than 8 hours"
            echo "  $0 --list            # Show all screenshots with details"
            echo "  $0 --dry-run         # Preview what would be cleaned"
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1"
            echo "💡 Use --help for usage information"
            exit 1
            ;;
    esac
done

SCREENSHOTS_DIR="$(osrs_assert_artifact_path "$SCREENSHOTS_DIR")"

if [[ "$DRY_RUN" == "false" && "${OSRS_ARTIFACT_CLEANUP_AUTHORIZED:-}" != "1" ]]; then
    echo "ERROR: Deletion requires separate authorization and OSRS_ARTIFACT_CLEANUP_AUTHORIZED=1" >&2
    exit 2
fi

# Check if screenshots directory exists
if [[ ! -d "$SCREENSHOTS_DIR" ]]; then
    echo "📸 No screenshots directory found"
    exit 0
fi

# Show list if requested
if [[ "$SHOW_LIST" == "true" ]]; then
    echo "📸 iOS Screenshots in $SCREENSHOTS_DIR:"
    echo ""
    
    if [[ -z "$(ls -A "$SCREENSHOTS_DIR" 2>/dev/null)" ]]; then
        echo "   (no screenshots found)"
        exit 0
    fi
    
    # Show screenshots with details
    find "$SCREENSHOTS_DIR" -name "*.png" -type f | sort | while read -r screenshot; do
        if [[ -f "$screenshot" ]]; then
            # Get file info
            size=$(ls -lh "$screenshot" | awk '{print $5}')
            
            # Get modification time (cross-platform)
            if command -v stat >/dev/null 2>&1; then
                if [[ "$(uname)" == "Darwin" ]]; then
                    # macOS
                    mod_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$screenshot")
                else
                    # Linux
                    mod_time=$(stat -c "%y" "$screenshot" | cut -d. -f1)
                fi
            else
                mod_time="unknown"
            fi
            
            basename_file=$(basename "$screenshot")
            echo "   $basename_file"
            echo "     Size: $size, Modified: $mod_time"
        fi
    done
    
    # Show metadata if exists
    if [[ -f "$SCREENSHOTS_DIR/.metadata" ]]; then
        echo ""
        echo "📋 Session metadata:"
        while read -r line; do
            if [[ ! "$line" =~ ^# ]]; then
                echo "   $line"
            fi
        done < "$SCREENSHOTS_DIR/.metadata" | tail -5
    fi
    
    exit 0
fi

# Clean old screenshots
echo "🧹 Cleaning iOS screenshots older than $MAX_AGE_HOURS hours..."

if [[ -z "$(ls -A "$SCREENSHOTS_DIR" 2>/dev/null)" ]]; then
    echo "   (no screenshots found)"
    exit 0
fi

# Calculate cutoff time (hours ago)
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    cutoff_time=$(date -v-"${MAX_AGE_HOURS}H" +%s)
else
    # Linux
    cutoff_time=$(date -d "$MAX_AGE_HOURS hours ago" +%s)
fi

cleaned_count=0
total_size=0

find "$SCREENSHOTS_DIR" -name "*.png" -type f | while read -r screenshot; do
    if [[ -f "$screenshot" ]]; then
        # Get file modification time
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS
            file_time=$(stat -f "%m" "$screenshot")
        else
            # Linux  
            file_time=$(stat -c "%Y" "$screenshot")
        fi
        
        if [[ "$file_time" -lt "$cutoff_time" ]]; then
            file_size=$(ls -l "$screenshot" | awk '{print $5}')
            basename_file=$(basename "$screenshot")
            
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "   [DRY RUN] Would delete: $basename_file ($(ls -lh "$screenshot" | awk '{print $5}'))"
            else
                echo "   Deleting: $basename_file ($(ls -lh "$screenshot" | awk '{print $5}'))"
                rm "$screenshot"
            fi
            
            cleaned_count=$((cleaned_count + 1))
            total_size=$((total_size + file_size))
        fi
    fi
done

# Convert total size to human readable
if command -v numfmt >/dev/null 2>&1; then
    total_size_human=$(numfmt --to=iec --suffix=B $total_size)
else
    total_size_human="${total_size} bytes"
fi

if [[ "$cleaned_count" -eq 0 ]]; then
    echo "   ✅ No screenshots older than $MAX_AGE_HOURS hours found"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "   📋 Would clean $cleaned_count screenshots ($total_size_human)"
        echo "   💡 Run without --dry-run to actually delete files"
    else
        echo "   ✅ Cleaned $cleaned_count screenshots ($total_size_human)"
    fi
fi

# Clean up metadata if no screenshots remain
if [[ "$DRY_RUN" != "true" ]] && [[ -z "$(find "$SCREENSHOTS_DIR" -name "*.png" -type f)" ]]; then
    if [[ -f "$SCREENSHOTS_DIR/.metadata" ]]; then
        rm "$SCREENSHOTS_DIR/.metadata"
        echo "   • Cleaned metadata file"
    fi
    
    if [[ -f "$SCREENSHOTS_DIR/.gitkeep" ]]; then
        # Keep .gitkeep but update it
        echo "# Screenshot session metadata" > "$SCREENSHOTS_DIR/.gitkeep"
        echo "# All screenshots cleaned $(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SCREENSHOTS_DIR/.gitkeep"
    fi
fi

echo ""
echo "💡 Tips:"
echo "   • Use --list to see all screenshots"
echo "   • Use --dry-run to preview cleanup"
echo "   • Use --max-age N to change age threshold"
