#!/bin/bash
set -euo pipefail

# Screenshot cleanup utility for Android development sessions
# Usage: ./scripts/android/clean-screenshots.sh [--max-age HOURS] [--dry-run|--delete] [--list]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=../shared/local-artifact-root.sh
source "$SCRIPT_DIR/../shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

# Default settings
MAX_AGE_HOURS=24
DRY_RUN=true
LIST_ONLY=false
SCREENSHOTS_DIR="${OSRS_SCREENSHOTS_DIR:-$(osrs_session_artifact_dir screenshots)}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-age)
            MAX_AGE_HOURS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delete)
            DRY_RUN=false
            shift
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--max-age HOURS] [--dry-run|--delete] [--list]"
            echo ""
            echo "Options:"
            echo "  --max-age HOURS  Delete screenshots older than N hours (default: 24)"
            echo "  --dry-run        Show what would be deleted (default)"
            echo "  --delete         Delete only with OSRS_ARTIFACT_CLEANUP_AUTHORIZED=1"
            echo "  --list           List all screenshots with timestamps and sizes"
            echo "  --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                     # Preview screenshots older than 24 hours"
            echo "  $0 --max-age 8        # Preview screenshots older than 8 hours"
            echo "  OSRS_ARTIFACT_CLEANUP_AUTHORIZED=1 $0 --delete --max-age 24"
            echo "  $0 --list             # List all screenshots"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
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
    echo "📁 No screenshots directory found - nothing to clean"
    exit 0
fi

# List screenshots
if [[ "$LIST_ONLY" == "true" ]]; then
    echo "📸 Screenshots in current session:"
    echo ""
    if [[ -z "$(ls -A "$SCREENSHOTS_DIR")" ]]; then
        echo "   (no screenshots found)"
    else
        # Show detailed listing with human-readable sizes
        ls -lah "$SCREENSHOTS_DIR"/*.png 2>/dev/null | \
            awk '{printf "   %s %s %s %s\n", $6, $7, $8, $9}' || \
            echo "   (no .png files found)"
    fi
    
    # Show metadata if available
    if [[ -f "$SCREENSHOTS_DIR/.metadata" ]]; then
        echo ""
        echo "📋 Session metadata:"
        grep -E "^(session_start|worktree|device)" "$SCREENSHOTS_DIR/.metadata" 2>/dev/null | \
            sed 's/^/   /' || true
        
        echo ""
        echo "📊 Screenshot log:"
        grep -v "^#" "$SCREENSHOTS_DIR/.metadata" 2>/dev/null | \
            tail -n 10 | \
            sed 's/^/   /' || echo "   (no screenshot log found)"
    fi
    
    exit 0
fi

# Calculate cutoff time (current time minus max age in hours)
CUTOFF_TIME=$(date -d "${MAX_AGE_HOURS} hours ago" +%s 2>/dev/null || \
              date -v-"${MAX_AGE_HOURS}H" +%s 2>/dev/null || \
              echo "0")

if [[ "$CUTOFF_TIME" == "0" ]]; then
    echo "❌ Failed to calculate cutoff time - unsupported date command" >&2
    exit 1
fi

echo "🧹 Cleaning screenshots older than ${MAX_AGE_HOURS} hours"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔍 DRY RUN - no files will be deleted"
fi

FOUND_FILES=0
DELETED_FILES=0
TOTAL_SIZE=0

# Find and process old screenshot files
while IFS= read -r -d '' file; do
    FOUND_FILES=$((FOUND_FILES + 1))
    
    # Get file modification time
    FILE_TIME=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0")
    
    if [[ "$FILE_TIME" -lt "$CUTOFF_TIME" ]]; then
        # Get file size for reporting
        FILE_SIZE=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo "0")
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "   Would delete: $(basename "$file") ($(numfmt --to=iec "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes"))"
        else
            echo "   Deleting: $(basename "$file") ($(numfmt --to=iec "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes"))"
            if rm "$file"; then
                DELETED_FILES=$((DELETED_FILES + 1))
            else
                echo "   ❌ Failed to delete: $(basename "$file")" >&2
            fi
        fi
    fi
done < <(find "$SCREENSHOTS_DIR" -name "*.png" -type f -print0 2>/dev/null || true)

# Clean up empty metadata if no screenshots remain
if [[ "$DRY_RUN" == "false" && "$DELETED_FILES" -gt 0 ]]; then
    if [[ -z "$(ls -A "$SCREENSHOTS_DIR"/*.png 2>/dev/null || true)" ]]; then
        # No PNG files remain, clean up metadata but keep .gitkeep
        if [[ -f "$SCREENSHOTS_DIR/.metadata" ]]; then
            echo "🗑️  Removing metadata file (no screenshots remain)"
            rm "$SCREENSHOTS_DIR/.metadata"
        fi
    fi
fi

# Report results
if [[ "$FOUND_FILES" -eq 0 ]]; then
    echo "📁 No screenshot files found"
elif [[ "$DRY_RUN" == "true" ]]; then
    TOTAL_SIZE_HUMAN=$(numfmt --to=iec "$TOTAL_SIZE" 2>/dev/null || echo "${TOTAL_SIZE} bytes")
    echo "🔍 Would clean up $DELETED_FILES of $FOUND_FILES screenshots (${TOTAL_SIZE_HUMAN})"
else
    if [[ "$DELETED_FILES" -gt 0 ]]; then
        TOTAL_SIZE_HUMAN=$(numfmt --to=iec "$TOTAL_SIZE" 2>/dev/null || echo "${TOTAL_SIZE} bytes")
        echo "✅ Cleaned up $DELETED_FILES of $FOUND_FILES screenshots (${TOTAL_SIZE_HUMAN})"
    else
        echo "📸 All $FOUND_FILES screenshots are newer than ${MAX_AGE_HOURS} hours"
    fi
fi
