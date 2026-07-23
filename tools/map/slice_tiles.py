#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Generates one MBTiles file per map floor in parallel.
This version dynamically calculates zoom levels and uses nearest-neighbor
resampling to preserve a pixelated art style.

Pipeline:
1. Check for source images in map-dumper/output/ (primary) and cache (secondary)
2. If map-dumper has newer images, auto-copy them to cache
3. Generate mbtiles from the cache images
"""

import os
import shutil
import sqlite3
import numpy as np
import math
import json
from datetime import datetime
from PIL import Image
from concurrent.futures import ProcessPoolExecutor
from cache_paths import find_cache_base, validate_local_artifact_path

Image.MAX_IMAGE_PIXELS = None

# --- Configuration ---
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

def _find_cache_dir():
    """Resolve the verified machine-local cache directory."""
    return str(find_cache_base(PROJECT_ROOT))

def _sync_source_images():
    """Sync source images from map-dumper output to cache if newer.

    The map-dumper outputs to: tools/map/map-dumper/output/
    The slice_tiles.py reads from: cache/binary-assets/map-images/output/

    This function checks if map-dumper has newer images and copies them to cache.
    """
    dumper_output = os.path.join(PROJECT_ROOT, 'tools', 'map', 'map-dumper', 'output')
    cache_images_dir = os.path.join(CACHE_DIR, 'binary-assets', 'map-images', 'output')

    # Ensure cache directory exists
    os.makedirs(cache_images_dir, exist_ok=True)

    images_synced = 0
    for i in range(4):
        image_name = f'img-{i}.png'
        dumper_path = os.path.join(dumper_output, image_name)
        cache_path = os.path.join(cache_images_dir, image_name)

        if not os.path.exists(dumper_path):
            continue

        # Check if dumper image is newer than cache image (or cache doesn't exist)
        dumper_mtime = os.path.getmtime(dumper_path)
        cache_mtime = os.path.getmtime(cache_path) if os.path.exists(cache_path) else 0

        if dumper_mtime > cache_mtime:
            log_time(f"Syncing {image_name} from map-dumper to cache (dumper is newer)")
            shutil.copy2(dumper_path, cache_path)
            images_synced += 1

    if images_synced > 0:
        log_time(f"Synced {images_synced} image(s) from map-dumper/output/ to cache")
    else:
        log_time("Source images in cache are up-to-date")

    dumper_metadata_path = os.path.join(dumper_output, 'map-metadata.json')
    cache_metadata_path = os.path.join(cache_images_dir, 'map-metadata.json')
    if os.path.exists(dumper_metadata_path):
        dumper_mtime = os.path.getmtime(dumper_metadata_path)
        cache_mtime = os.path.getmtime(cache_metadata_path) if os.path.exists(cache_metadata_path) else 0

        if dumper_mtime > cache_mtime:
            log_time("Syncing map-metadata.json from map-dumper to cache (dumper is newer)")
            shutil.copy2(dumper_metadata_path, cache_metadata_path)

    return images_synced

CACHE_DIR = _find_cache_dir()
SOURCE_DIR = os.path.join(CACHE_DIR, 'binary-assets', 'map-images', 'output')
SOURCE_IMAGES = [f'img-{i}.png' for i in range(4)]
MAP_METADATA_FILENAME = 'map-metadata.json'
if not os.environ.get('OSRS_MAP_TILE_TEMP_DIR'):
    lane_id = os.environ.get('OSRS_LANE_ID', 'manual').replace('/', '-')
    run_id = os.environ.get('OSRS_ARTIFACT_RUN_ID') or datetime.utcnow().strftime('%Y%m%dT%H%M%SZ') + f'-{os.getpid()}'
    os.environ['OSRS_MAP_TILE_TEMP_DIR'] = os.path.join(
        CACHE_DIR, 'scratch', 'map-tiles', lane_id, run_id
    )
TEMP_OUTPUT_DIR = str(validate_local_artifact_path(os.environ['OSRS_MAP_TILE_TEMP_DIR']))
ASSETS_DIR = os.path.join(CACHE_DIR, 'binary-assets', 'mbtiles')

# --- Tile Generation Settings ---
# Set the desired tile size. 1024px to reduce memory usage.
TILE_SIZE = 1024
# Generate a complete tile pyramid down to a single tile.
MIN_ZOOM = 0
# Adjusted MAX_ZOOM for 1024px tiles to fit source image (12800x45568)
# Need canvas ≥ 45568px: 2^6 * 1024 = 65536px ✓
MAX_ZOOM = 6


def log_time(message):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [PID:{os.getpid()}] {message}")


def read_json_file(path):
    with open(path, 'r', encoding='utf-8') as file:
        return json.load(file)


def source_image_dimensions():
    for image_name in SOURCE_IMAGES:
        image_path = os.path.join(SOURCE_DIR, image_name)
        if os.path.exists(image_path):
            with Image.open(image_path) as image:
                return image.size
    raise RuntimeError(f"No source images found in {SOURCE_DIR}")


def load_manifest_projection():
    manifest_path = os.path.join(PROJECT_ROOT, 'shared', 'map-default-view.json')
    if not os.path.exists(manifest_path):
        return {}
    return read_json_file(manifest_path).get('projection', {})


def build_map_metadata():
    source_metadata_path = os.path.join(SOURCE_DIR, MAP_METADATA_FILENAME)
    source_metadata = read_json_file(source_metadata_path) if os.path.exists(source_metadata_path) else {}
    manifest_projection = load_manifest_projection()
    source_width, source_height = source_image_dimensions()

    game_coord_scale = float(source_metadata.get(
        'gameCoordScale',
        manifest_projection.get('gameCoordScale', 4.0)
    ))
    source_bounds = source_metadata.get('gameBounds', {})

    min_x = source_bounds.get('minX', manifest_projection.get('gameMinX'))
    max_y = source_bounds.get('maxY', manifest_projection.get('gameMaxY'))
    if min_x is None or max_y is None:
        raise RuntimeError(
            "Map metadata needs gameBounds.minX/gameBounds.maxY from map-dumper "
            "or projection.gameMinX/projection.gameMaxY from shared/map-default-view.json"
        )

    min_x = float(min_x)
    max_y = float(max_y)
    max_x = float(source_bounds.get('maxX', manifest_projection.get('gameMaxX', min_x + source_width / game_coord_scale)))
    min_y = float(source_bounds.get('minY', manifest_projection.get('gameMinY', max_y - source_height / game_coord_scale)))
    canvas_size = float((2 ** MAX_ZOOM) * TILE_SIZE)

    metadata = {
        'version': 1,
        'generator': 'tools/map/slice_tiles.py',
        'gameCoordScale': game_coord_scale,
        'gameBounds': {
            'minX': min_x,
            'maxX': max_x,
            'minY': min_y,
            'maxY': max_y,
        },
        'sourceImage': {
            'width': float(source_width),
            'height': float(source_height),
        },
        'tilePyramid': {
            'tileSize': float(TILE_SIZE),
            'minZoom': MIN_ZOOM,
            'maxZoom': MAX_ZOOM,
            'canvasSize': canvas_size,
        },
    }

    if source_metadata.get('generator'):
        metadata['sourceGenerator'] = source_metadata['generator']

    return metadata


def write_map_metadata():
    metadata = build_map_metadata()
    os.makedirs(ASSETS_DIR, exist_ok=True)
    metadata_path = os.path.join(ASSETS_DIR, MAP_METADATA_FILENAME)
    with open(metadata_path, 'w', encoding='utf-8') as file:
        json.dump(metadata, file, indent=2)
        file.write('\n')
    log_time(f"Wrote map metadata to {metadata_path}")
    return metadata


def make_background_transparent(img):
    """
    Uses NumPy to make the black background of an image transparent.
    This is significantly faster than ImageDraw.floodfill.
    """
    data = np.array(img)
    r, g, b, a = data.T
    black_areas = (r == 0) & (g == 0) & (b == 0)
    data[..., -1][black_areas.T] = 0
    return Image.fromarray(data)


def is_tile_empty(tile_image, floor):
    """Checks if a tile is entirely black (for floor 0) or transparent."""
    extrema = tile_image.getextrema()
    if floor == 0:
        # For floor 0, the background is solid black.
        is_black_r, is_black_g, is_black_b = extrema[0] == (0, 0), extrema[1] == (0, 0), extrema[2] == (0, 0)
        return is_black_r and is_black_g and is_black_b
    else:
        # For other floors, the background is transparent.
        # An all-zero alpha channel indicates an empty tile.
        return extrema[3] == (0, 0) if len(extrema) > 3 else True


def generate_base_tiles(padded_image, floor, native_zoom):
    """Generates the highest-resolution tiles from the source image."""
    log_time(f"Floor {floor}: Generating base tiles for zoom level {native_zoom}...")
    zoom_dir = os.path.join(TEMP_OUTPUT_DIR, str(floor), str(native_zoom))
    os.makedirs(zoom_dir, exist_ok=True)

    for x in range(2**native_zoom):
        col_dir = os.path.join(zoom_dir, str(x))
        for y in range(2**native_zoom):
            tms_y = (2**native_zoom - 1) - y
            box = (x * TILE_SIZE, y * TILE_SIZE, (x + 1) * TILE_SIZE, (y + 1) * TILE_SIZE)
            tile = padded_image.crop(box)
            if not is_tile_empty(tile, floor):
                if not os.path.exists(col_dir):
                    os.makedirs(col_dir)
                tile.save(os.path.join(col_dir, f"{tms_y}.png"), 'PNG')


def generate_overview_tiles(floor, native_zoom):
    """Generates downsampled overview tiles for lower zoom levels."""
    log_time(f"Floor {floor}: Generating overview tiles...")
    floor_dir = os.path.join(TEMP_OUTPUT_DIR, str(floor))
    blank_tile = Image.new('RGBA', (TILE_SIZE, TILE_SIZE), (0, 0, 0, 0 if floor > 0 else 255))

    for zoom in range(native_zoom - 1, MIN_ZOOM - 1, -1):
        source_zoom_dir = os.path.join(floor_dir, str(zoom + 1))
        zoom_dir = os.path.join(floor_dir, str(zoom))
        os.makedirs(zoom_dir, exist_ok=True)

        for x in range(2**zoom):
            col_dir = os.path.join(zoom_dir, str(x))
            for y in range(2**zoom):
                parent_tms_y = (2**zoom - 1) - y
                child_x1, child_x2 = 2 * x, 2 * x + 1
                child_cartesian_y1, child_cartesian_y2 = 2 * y, 2 * y + 1
                child_tms_y1 = (2**(zoom + 1) - 1) - child_cartesian_y1
                child_tms_y2 = (2**(zoom + 1) - 1) - child_cartesian_y2

                combined_image = Image.new('RGBA', (TILE_SIZE * 2, TILE_SIZE * 2))
                child_paths = [
                    os.path.join(source_zoom_dir, str(child_x1), f"{child_tms_y1}.png"),
                    os.path.join(source_zoom_dir, str(child_x2), f"{child_tms_y1}.png"),
                    os.path.join(source_zoom_dir, str(child_x1), f"{child_tms_y2}.png"),
                    os.path.join(source_zoom_dir, str(child_x2), f"{child_tms_y2}.png")
                ]
                paste_positions = [(0, 0), (TILE_SIZE, 0), (0, TILE_SIZE), (TILE_SIZE, TILE_SIZE)]

                has_content = False
                for i, path in enumerate(child_paths):
                    try:
                        with Image.open(path) as img:
                            combined_image.paste(img, paste_positions[i])
                            has_content = True
                    except FileNotFoundError:
                        combined_image.paste(blank_tile, paste_positions[i])

                if has_content:
                    # Use NEAREST resampling to maintain sharp, pixelated style.
                    overview_tile = combined_image.resize((TILE_SIZE, TILE_SIZE), Image.Resampling.NEAREST)
                    if not is_tile_empty(overview_tile, floor):
                        if not os.path.exists(col_dir):
                            os.makedirs(col_dir)
                        overview_tile.save(os.path.join(col_dir, f"{parent_tms_y}.png"), 'PNG')


def create_mbtiles_for_floor(floor_num, native_zoom):
    """Packages all generated tiles for a floor into a single .mbtiles file."""
    mbtiles_filename = f'map_floor_{floor_num}.mbtiles'
    mbtiles_filepath = os.path.join(ASSETS_DIR, mbtiles_filename)
    source_layer_dir = os.path.join(TEMP_OUTPUT_DIR, str(floor_num))

    log_time(f"Floor {floor_num}: Creating '{mbtiles_filename}'...")
    if os.path.exists(mbtiles_filepath):
        os.remove(mbtiles_filepath)

    db = sqlite3.connect(mbtiles_filepath)
    cursor = db.cursor()
    cursor.execute('CREATE TABLE metadata (name text, value text);')
    cursor.execute('CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob);')
    cursor.execute('CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);')

    metadata = [
        ('name', f'OSRS Map - Floor {floor_num}'), ('format', 'png'),
        ('bounds', '-180.0,-85.0,180.0,85.0'), ('type', 'overlay'), ('version', '1.4'),
        ('description', f'Tiles for OSRS floor {floor_num}'), ('minzoom', str(MIN_ZOOM)),
        ('maxzoom', str(native_zoom)),
    ]
    cursor.executemany('INSERT INTO metadata (name, value) VALUES (?, ?)', metadata)

    tiles_to_insert = []
    for zoom_str in os.listdir(source_layer_dir):
        zoom_dir = os.path.join(source_layer_dir, zoom_str)
        for x_str in os.listdir(zoom_dir):
            x_dir = os.path.join(zoom_dir, x_str)
            for y_filename in os.listdir(x_dir):
                if y_filename.endswith('.png'):
                    with open(os.path.join(x_dir, y_filename), 'rb') as f:
                        tile_data = f.read()
                    tiles_to_insert.append((int(zoom_str), int(x_str), int(os.path.splitext(y_filename)[0]), tile_data))

    log_time(f"Floor {floor_num}: Inserting {len(tiles_to_insert)} tiles into the database...")
    cursor.executemany('INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)', tiles_to_insert)
    db.commit()
    db.close()
    log_time(f"Floor {floor_num}: Finished creating '{mbtiles_filename}'.")


def process_floor(floor):
    """The main processing pipeline for a single map floor."""
    try:
        log_time(f"--- Processing Floor {floor} ---")
        image_name = SOURCE_IMAGES[floor]
        source_image_path = os.path.join(SOURCE_DIR, image_name)
        if not os.path.exists(source_image_path):
            log_time(f"FATAL: Source image not found at '{source_image_path}'")
            return

        with Image.open(source_image_path) as source_image:
            source_image = source_image.convert('RGBA')
            if floor > 0:
                log_time(f"Floor {floor}: Making background transparent...")
                source_image = make_background_transparent(source_image)
            
            # Use fixed maximum zoom level for MapLibre compatibility
            source_width, source_height = source_image.size
            native_zoom = MAX_ZOOM  # Use fixed zoom level for consistent MapLibre support
            canvas_size = (2**native_zoom) * TILE_SIZE
            log_time(f"Floor {floor}: Source Dims={source_width}x{source_height}, Tile Size={TILE_SIZE}px, Native Zoom={native_zoom}, Canvas={canvas_size}px")
            
            padded_canvas = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
            padded_canvas.paste(source_image, (0, 0))

        generate_base_tiles(padded_canvas, floor, native_zoom)
        generate_overview_tiles(floor, native_zoom)
        create_mbtiles_for_floor(floor, native_zoom)
        
        return f"Floor {floor} processed successfully."
    except Exception as e:
        log_time(f"Floor {floor} FAILED with error: {e}")
        import traceback
        traceback.print_exc()
        raise


def main():
    log_time("Starting parallel map tile generation process.")

    # Auto-sync source images from map-dumper if newer
    _sync_source_images()
    write_map_metadata()

    if os.path.exists(TEMP_OUTPUT_DIR):
        shutil.rmtree(TEMP_OUTPUT_DIR)
    os.makedirs(TEMP_OUTPUT_DIR)

    # Clean up old mbtiles files before starting
    for floor_num in range(len(SOURCE_IMAGES)):
        mbtiles_filepath = os.path.join(ASSETS_DIR, f'map_floor_{floor_num}.mbtiles')
        if os.path.exists(mbtiles_filepath):
            os.remove(mbtiles_filepath)

    with ProcessPoolExecutor() as executor:
        results = executor.map(process_floor, range(len(SOURCE_IMAGES)))
        for result in results:
            log_time(result)

    log_time("Cleaning up temporary tile directory...")
    shutil.rmtree(TEMP_OUTPUT_DIR)
    log_time("Process finished. All .mbtiles files have been created.")


if __name__ == "__main__":
    main()
