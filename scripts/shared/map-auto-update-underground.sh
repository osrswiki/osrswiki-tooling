#!/bin/bash
set -euo pipefail

# Best-effort underground rebuild from the live OpenRS2 cache.
# Assembles dumper metadata, optional provenance rasters, wiki basemaps, and
# the locked non-surface builder. Exit 1 when a publishable tree cannot be
# produced; the caller then compares against the current pin.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git_root=""
cache_base=""
live_cache=""
output=""
prior_manifest=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --git-root) git_root="$2"; shift 2 ;;
        --cache-base) cache_base="$2"; shift 2 ;;
        --live-cache) live_cache="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --prior-manifest) prior_manifest="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$git_root" && -n "$cache_base" && -n "$live_cache" && -n "$output" ]] || {
    echo "ERROR: --git-root, --cache-base, --live-cache, and --output are required" >&2
    exit 2
}

DUMPER="$git_root/tools/map/run_dumper.sh"
DUMPER_OUTPUT="$cache_base/binary-assets/map-images/output"
STATE_DIR="$cache_base/map-auto-update"
INPUTS="$STATE_DIR/underground-inputs"
PIXI_MANIFEST="$git_root/tools/pixi.toml"
CACHE_DIR="$cache_base/game-data/openrs2_cache/cache"
LIVE_ID="$(jq -r '.id' "$live_cache")"
LIVE_DATE="$(jq -r '.timestamp // empty' "$live_cache" | cut -c1-10)"

mkdir -p "$DUMPER_OUTPUT" "$INPUTS" "$STATE_DIR/bin"
chmod 0755 "$DUMPER"

echo "Exporting cache-native world-map inventory"
"$DUMPER" --non-surface-inventory-only
echo "Exporting underground alignment"
"$DUMPER" --underground-alignment-only

INVENTORY="$DUMPER_OUTPUT/world_map_details_inventory.json"
ALIGNMENT="$DUMPER_OUTPUT/underground_alignment_manifest.json"
METADATA="$DUMPER_OUTPUT/map-metadata.json"
if [[ ! -f "$METADATA" ]]; then
    METADATA="$cache_base/binary-assets/mbtiles/map-metadata.json"
fi
[[ -f "$INVENTORY" ]] || { echo "ERROR: inventory export missing: $INVENTORY" >&2; exit 1; }
[[ -f "$ALIGNMENT" ]] || { echo "ERROR: alignment export missing: $ALIGNMENT" >&2; exit 1; }
[[ -f "$METADATA" ]] || { echo "ERROR: map metadata missing: $METADATA" >&2; exit 1; }

cp "$INVENTORY" "$INPUTS/world_map_details_inventory.json"
cp "$ALIGNMENT" "$INPUTS/underground_alignment_manifest.json"
cp "$METADATA" "$INPUTS/map-metadata.json"

BASEMAPS="$INPUTS/basemaps.json"
basemap_urls=()
if [[ -n "${OSRS_WIKI_BASEMAPS_URL:-}" ]]; then
    basemap_urls+=("$OSRS_WIKI_BASEMAPS_URL")
fi
basemap_urls+=(
    "https://maps.runescape.wiki/osrs/latest/basemaps.json"
)
if [[ "$LIVE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    basemap_urls+=(
        "https://maps.runescape.wiki/osrs/versions/${LIVE_DATE}_a/basemaps.json"
        "https://maps.runescape.wiki/osrs/versions/${LIVE_DATE}_b/basemaps.json"
    )
fi
basemap_urls+=(
    "https://maps.runescape.wiki/osrs/versions/2026-03-04_a/basemaps.json"
)
fetched_basemaps=0
for basemap_url in "${basemap_urls[@]}"; do
    echo "Fetching wiki basemaps from $basemap_url"
    if curl --fail --location --retry 1 --retry-delay 1 \
        -A "osrswiki-map-auto-update" \
        --output "$BASEMAPS" "$basemap_url" \
        && jq -e 'type == "array" or type == "object"' "$BASEMAPS" >/dev/null; then
        echo "Using wiki basemaps from $basemap_url"
        fetched_basemaps=1
        break
    fi
done
if [[ "$fetched_basemaps" -ne 1 ]]; then
    echo "ERROR: could not fetch wiki basemaps from: ${basemap_urls[*]}" >&2
    exit 1
fi

PROVENANCE_OK=1
for plane in 0 1 2 3; do
    if [[ ! -f "$DUMPER_OUTPUT/img-${plane}.png" \
        || ! -f "$DUMPER_OUTPUT/img-${plane}-provenance.png" ]]; then
        PROVENANCE_OK=0
    fi
done
if [[ "$PROVENANCE_OK" -ne 1 ]]; then
    echo "ERROR: provenance rasters are missing; dump with --render-provenance to rebuild underground" >&2
    exit 1
fi

HELPER_SRC="$git_root/tools/map/osrs_source_accounting.c"
HELPER_BIN="$STATE_DIR/bin/osrs_source_accounting"
if [[ ! -x "$HELPER_BIN" || "$HELPER_SRC" -nt "$HELPER_BIN" ]]; then
    echo "Compiling source-accounting helper"
    cc -std=c11 -O2 -Wall -Wextra -Werror \
        $(pkg-config --cflags libpng) "$HELPER_SRC" \
        $(pkg-config --libs libpng) -o "$HELPER_BIN"
fi
HELPER_SHA="$(shasum -a 256 "$HELPER_BIN" | awk '{print $1}')"

PRIOR_TREE="$STATE_DIR/prior-underground"
PRIOR_JSON="$PRIOR_TREE/underground-realms.json"
if [[ -n "$prior_manifest" && -f "$prior_manifest" ]]; then
    mkdir -p "$PRIOR_TREE"
    if [[ ! -f "$PRIOR_JSON" ]]; then
        "$SCRIPT_DIR/fetch-underground-release-assets.sh" materialize \
            "$prior_manifest" "$PRIOR_TREE"
    fi
fi

SNAPSHOTS="$INPUTS/source-snapshots.json"
python3 - "$SNAPSHOTS" "$LIVE_ID" "$CACHE_DIR" "$DUMPER_OUTPUT/img-0.png" "$METADATA" "$git_root" <<'PY'
import json, sys
from pathlib import Path
out, cache_id, cache_dir, raster, metadata, worktree = sys.argv[1:]
meta = json.loads(Path(metadata).read_text(encoding="utf-8"))
bounds = meta.get("gameBounds") or meta.get("game_bounds") or {}
image = meta.get("sourceImage") or meta.get("source_image") or {}
payload = {
    "candidate": "010",
    "cache": {"cache_id": int(cache_id), "cache_directory": cache_dir},
    "raster": {
        "path": raster,
        "metadata_path": metadata,
        "game_bounds": {
            "min_x": bounds.get("minX", bounds.get("min_x")),
            "min_y": bounds.get("minY", bounds.get("min_y")),
            "max_x": bounds.get("maxX", bounds.get("max_x")),
            "max_y": bounds.get("maxY", bounds.get("max_y")),
        },
        "game_coord_scale": meta.get("gameCoordScale", meta.get("game_coord_scale")),
        "width": image.get("width"),
        "height": image.get("height"),
    },
    "repository": {"worktree": worktree},
}
Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

BUILD_OUT="$STATE_DIR/underground-build-$LIVE_ID"
INVOCATION="$STATE_DIR/underground-invocation-$LIVE_ID.json"
rm -rf "$BUILD_OUT"
mkdir -p "$BUILD_OUT"

builder_args=(
    --osrs-invocation-report "$INVOCATION"
    --inventory "$INPUTS/world_map_details_inventory.json"
    --basemaps "$BASEMAPS"
    --alignment "$INPUTS/underground_alignment_manifest.json"
    --source-metadata "$INPUTS/map-metadata.json"
    --source-image-dir "$DUMPER_OUTPUT"
    --provenance-dir "$DUMPER_OUTPUT"
    --accounting-helper "$HELPER_BIN"
    --accounting-helper-sha256 "$HELPER_SHA"
    --source-snapshots "$SNAPSHOTS"
    --candidate 010
    --output "$BUILD_OUT"
)
if [[ -f "$PRIOR_JSON" ]]; then
    builder_args+=(--prior-manifest "$PRIOR_JSON")
fi

echo "Running locked non-surface builder"
pixi run --manifest-path "$PIXI_MANIFEST" --locked -- python \
    "$git_root/tools/map/build_osrs_non_surface_realms_locked.py" \
    "${builder_args[@]}"

RUNTIME_OUT="$STATE_DIR/underground-runtime-$LIVE_ID"
rm -rf "$RUNTIME_OUT"
if pixi run --manifest-path "$PIXI_MANIFEST" --locked -- python \
    "$git_root/tools/map/prune_osrs_canonical_runtime_release.py" \
    --source "$BUILD_OUT" --output "$RUNTIME_OUT"; then
    SOURCE_TREE="$RUNTIME_OUT"
else
    echo "Runtime prune failed; using the canonical builder tree"
    SOURCE_TREE="$BUILD_OUT"
fi

rm -rf "$output"
mkdir -p "$output"
cp "$SOURCE_TREE/underground-realms.json" "$output/underground-realms.json"
if [[ -d "$SOURCE_TREE/assets" ]]; then
    cp -R "$SOURCE_TREE/assets" "$output/assets"
fi
[[ -f "$output/underground-realms.json" ]] || {
    echo "ERROR: underground rebuild produced no catalog" >&2
    exit 1
}
if [[ -z "$(find "$output/assets" -name '*.mbtiles' -type f -print -quit 2>/dev/null)" ]]; then
    echo "ERROR: underground rebuild produced no mbtiles" >&2
    exit 1
fi
echo "Underground rebuild ready: $output"
