#!/bin/bash
# This script runs the MapImageDumper from within its project directory.
# Usage: ./run_dumper.sh [floors]
# floors: Optional comma-separated list of floor numbers to generate (e.g., "3" or "1,2,3")

# Navigate to this script's directory to ensure relative paths work correctly.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DUMPER_DIR="$SCRIPT_DIR/map-dumper"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../../scripts/shared/local-artifact-root.sh
source "$REPO_ROOT/scripts/shared/local-artifact-root.sh"
[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"

if ! CACHE_BASE="$(osrs_local_cache_dir)"; then
    echo "Error: Could not resolve the verified machine-local cache directory."
    exit 1
fi

CACHE_DIR="$CACHE_BASE/game-data/openrs2_cache/cache" # The actual cache data is in a 'cache' subdirectory
OUTPUT_DIR="$CACHE_BASE/binary-assets/map-images/output"
mkdir -p "$OUTPUT_DIR"

if [ ! -d "$DUMPER_DIR" ]; then
    echo "Error: Map dumper project not found at $DUMPER_DIR"
    exit 1
fi

# CD into the dumper project so gradle can find its files.
cd "$DUMPER_DIR" || exit

# Check for the downloaded cache and xtea files before running.
if [ ! -d "$CACHE_DIR" ]; then
    echo "Error: 'openrs2_cache/cache' directory not found."
    echo "Please run 'python3 ../setup_cache.py' first."
    exit 1
fi

if [ ! -f "xtea.json" ]; then
    echo "Error: 'xtea.json' not found inside '$DUMPER_DIR'."
    echo "Please run 'python3 ../update_xteas.py' first."
    exit 1
fi

# Execute the gradle wrapper, pointing to the new cache directory.
FLOORS_ARG=""
if [ ! -z "$1" ]; then
    FLOORS_ARG="--floors \"$1\""
    echo "Running map dumper for floors: $1"
else
    echo "Running map dumper for all floors..."
fi

echo "Output will be in $OUTPUT_DIR/"

# Note the relative path to the cache from the dumper directory
if ./gradlew run --args="--cachedir \"$CACHE_DIR\" --xteapath \"xtea.json\" --outputdir \"$OUTPUT_DIR\" $FLOORS_ARG"; then
    echo "Map dumper finished successfully."
else
    echo "Map dumper failed. Please check the output above for errors."
    exit 1
fi
