# OSRSWiki Asset Generation Tools

This directory contains a set of tools used to extract and process assets required for the OSRSWiki Android application's native map feature.

## Overview

The new native map system relies on pre-processed assets generated from the OSRS game cache. This toolchain is designed to be as automated and future-proof as possible.

The core asset generation workflow is a 4-step process:
1.  **Setup/Update Game Cache**: Automatically download the latest complete game cache from a public archive.
2.  **Fetch Decryption Keys**: Automatically download the latest map decryption keys (XTEAs).
3.  **Dump Complete Map Images**: Render the full game world from the cache.
4.  **Slice Map Tiles**: Process the map images into `.mbtiles` assets for use in the app.

---

## Environment Setup

All Python scripts in this directory run through the locked Pixi environment in `tools/pixi.toml`.

### Prerequisites

-   [Pixi](https://pixi.sh) must be installed.

### Creating the Environment

If you are setting up this project for the first time, install the committed lockfile.

1.  Navigate to the `tools/` directory in your terminal.
2.  Install the environment. This only needs to download packages once.
    ```bash
    pixi install --locked
    ```
3.  Run commands through Pixi; activation is optional.
    ```bash
    pixi run map-assets
    ```

### Updating Dependencies

Edit `pixi.toml`, run `pixi lock`, test the environment, and commit both `pixi.toml` and `pixi.lock`.

```bash
pixi lock
pixi install --locked
```

### Locked non-surface release publication

`map/build_osrs_non_surface_realms_locked.py` is the only supported publication
entry point for a non-surface realm release. The outer wrapper checks the
committed contract and Pixi CLI, then always starts the inner generator with
`pixi run --locked`. Calling `build_osrs_non_surface_realms.py` directly fails
before publication because it has no locked-wrapper marker.

The contract in `map/osrs_release_toolchain.lock.json` fixes the canonical
`osx-arm64` environment, Pixi manifest and lock hashes, the complete installed
package-set digest, selected Python/SQLite/Pillow/NumPy/zlib/image-library
package artifacts, runtime versions, and serializer settings. Every build also
records generator-source hashes and requires the compiled source-accounting
helper's SHA-256 as an explicit content identity. The generated release-owned
`reports/toolchain-provenance.json` contains only path-independent logical
identities. Relocation-sensitive executable hashes and a one-way environment
prefix identity go in the required external invocation report.

Compile or select the pinned accounting helper first and calculate its hash:

```bash
ACCOUNTING_HELPER_SHA256=$(shasum -a 256 <accounting-helper> | awk '{print $1}')
```

Then invoke the outer wrapper, passing the normal generator inputs plus the
helper hash and an evidence path outside the release tree:

```bash
cd tools
python3 map/build_osrs_non_surface_realms_locked.py \
  --osrs-invocation-report <evidence-root>/locked-invocation-a.json \
  --inventory <inputs>/world-map-details-inventory.json \
  --basemaps <inputs>/basemaps.json \
  --alignment <inputs>/underground-alignment-manifest.json \
  --source-metadata <inputs>/map-metadata.json \
  --source-image-dir <inputs>/rendered-planes \
  --provenance-dir <inputs>/rendered-planes \
  --accounting-helper <accounting-helper> \
  --accounting-helper-sha256 "$ACCOUNTING_HELPER_SHA256" \
  --source-snapshots <inputs>/source-snapshots.json \
  --prior-manifest <prior-release>/underground-realms.json \
  --candidate 003 \
  --output <candidate-root>/release-final-a
```

For acceptance, create three source copies from the same frozen candidate
commit. Do not share or copy `.pixi` between them. Run the wrapper once in each
copy so Pixi installs three distinct `tools/.pixi/envs/default` environments,
retain all three external invocation reports, and designate the first output as
the retained canonical release. The one-way environment identities in the
reports must be distinct, while their path-independent public-toolchain hashes
must match.

Finally, compare the retained canonical tree against both independent replays:

```bash
python3 map/verify_osrs_locked_release.py \
  --canonical <candidate-root>/release-final-a \
  --replay <candidate-root>/release-locked-b \
  --replay <candidate-root>/release-locked-c \
  --invocation-report <evidence-root>/locked-invocation-a.json \
  --invocation-report <evidence-root>/locked-invocation-b.json \
  --invocation-report <evidence-root>/locked-invocation-c.json \
  --report <evidence-root>/locked-release-reproducibility.json
```

The verifier fails unless every file name and byte matches the retained
canonical release, all release-owned toolchain reports match the committed
contract, every MBTiles SQLite header records the contracted serializer
version, and all three invocations prove distinct locked environments.

---

## The Asset Generation Pipeline

Follow these steps in order to generate a complete and up-to-date set of map assets.

### Prerequisites

- The locked Pixi environment must be installed.
- A Java Development Kit (JDK) version 11 or higher.

### Step 1: Setup or Update the Game Cache

The `setup_cache.py` script automatically finds and downloads the latest live OSRS game cache from the OpenRS2 Archive that has usable map XTEA keys. It is idempotent: it will only download the cache if it doesn't exist locally or if the local version is outdated.

**Run this script first to ensure you have the necessary game data.** The initial download is large and may take several minutes.

```bash
python3 setup_cache.py
```

### Step 2: Update XTEA Decryption Keys

The `update_xteas.py` script automatically fetches the XTEA keys that correspond to the selected map-usable cache from the OpenRS2 Archive.

**Run this script after setting up the cache to get the correct decryption keys.**

```bash
python3 update_xteas.py
```

### Step 3: Dump Complete Map Images

The `map-dumper/` directory contains a Java project that reads the game cache and renders the full game world. The `run_dumper.sh` script now automatically points to the cache downloaded by `setup_cache.py`.

**This step only needs to be re-run when there are significant changes to the game world.**

```bash
./run_dumper.sh
```
Source the session's `.osrs-artifacts.env` before running map generation. The
output images (`img-0.png`, `img-1.png`, etc.) and source map metadata are
written to `$OSRS_CACHE_ROOT/binary-assets/map-images/output/`, outside iCloud.

To export underground/source-display alignment metadata without rendering map images, run the dumper with `--underground-alignment-only`:

```bash
cd map-dumper
./gradlew run --args="--cachedir $OSRS_CACHE_ROOT/game-data/openrs2_cache/cache --xteapath xtea.json --outputdir $OSRS_CACHE_ROOT/binary-assets/map-images/output --underground-alignment-only"
```

This writes `underground_alignment_manifest.json`, `underground_alignment_manifest.schema.json`, and `underground_alignment_review_packet.md`. The export uses cache world-map composite source/display mappings plus intermap links, and does not relocate or regenerate raster tiles.

### Step 4: Slice Tiles into MBTiles

The `slice_tiles.py` script takes the high-resolution images from the central cache and processes them into the final `.mbtiles` assets used by the mobile apps.

```bash
python3 slice_tiles.py
```
This creates `map_floor_0.mbtiles`, `map_floor_1.mbtiles`, and the remaining
floors plus `map-metadata.json` under
`$OSRS_CACHE_ROOT/binary-assets/mbtiles/`. Run
`scripts/shared/sync-mbtiles-to-platforms.sh` from the session afterward to
copy only the curated platform assets and stamp the generated default-view
sources.

---

## Meta Asset Updater (Recommended)

For maximum convenience, use the unified meta wrapper that orchestrates all asset generation tools:

```bash
# Update all assets (maps, CSS, and JS discovery)
python3 asset-updater.py --all

# Update only map assets with force regeneration
python3 asset-updater.py --maps --force

# Update only CSS assets
python3 asset-updater.py --css

# Update only JS module discovery
python3 asset-updater.py --js-discovery

# Preview what would be updated (dry-run for maps)
python3 asset-updater.py --all --dry-run

# Verify all assets exist and are up to date
python3 asset-updater.py --all --verify

# Check freshness of map assets only
python3 asset-updater.py --maps --check-freshness
```

The meta updater:
- ✅ **Unified Interface**: Single command for all asset types
- ✅ **Automatic Environment**: Uses the locked Pixi environment
- ✅ **Smart Orchestration**: Coordinates map, CSS, and JS discovery tool execution
- ✅ **Pass-through Arguments**: Forwards options to underlying tools
- ✅ **Comprehensive Reporting**: Detailed progress and summary output
- ✅ **Error Handling**: Graceful failure handling with clear diagnostics

## Individual Tool Workflows

### Map Assets Only

For map-specific workflows, use the specialized map tool directly:

```bash
# Run the complete workflow automatically (only updates if needed)
python3 map/map-asset-generator.py

# Force regeneration even if assets are up to date  
python3 map/map-asset-generator.py --force

# Preview what would be done without executing
python3 map/map-asset-generator.py --dry-run

# Just verify that all assets exist
python3 map/map-asset-generator.py --verify

# Check if local assets are up to date with OpenRS2
python3 map/map-asset-generator.py --check-freshness
```

The automated tool:
- ✅ Checks OpenRS2 API for cache updates and only regenerates if needed
- ✅ Runs all 4 steps in sequence with proper error handling
- ✅ Validates dependencies (Java, Python packages, required scripts)
- ✅ Provides detailed progress reporting and colored output
- ✅ Verifies that all expected mbtiles files are created successfully

### CSS Assets Only

For CSS-specific workflows, use the CSS perfect sync tool:

```bash
# Achieve perfect CSS parity with reference
python3 css/css-perfect-sync.py
```

### JS Module Discovery Only

For JavaScript module discovery and tracking:

```bash
# Run discovery scan on sample pages
python3 js/update_discovery.py

# View current implementation status
python3 js/update_discovery.py --summary-only

# Generate comprehensive report
python3 js/generate_report.py

# Initialize masterlists from existing data (first time only)
python3 js/initialize_masterlists.py
```

The JS discovery system:
- ✅ Accumulative tracking of all discovered modules across scans
- ✅ Smart deduplication prevents data corruption
- ✅ Implementation mapping connects wiki modules to app code
- ✅ Priority scoring identifies high-impact unimplemented modules
- ✅ Overlap detection finds functional similarities between modules
- ✅ Comprehensive reporting shows implementation progress
