#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Fetches and sets up the latest OSRS cache from the OpenRS2 Archive,
only downloading if the local version is outdated.
"""

import requests
import os
import shutil
import zipfile
import io
from pathlib import Path

from cache_paths import find_cache_base
from openrs2_cache import select_latest_live_osrs_cache

def get_latest_osrs_cache_info():
    """Fetches metadata for the most recent live OSRS cache."""
    print("Fetching cache list from OpenRS2...")
    caches_url = "https://archive.openrs2.org/caches.json"
    response = requests.get(caches_url, timeout=30)
    response.raise_for_status()
    all_caches = response.json()

    return select_latest_live_osrs_cache(all_caches, require_valid_keys=True)

def main():
    """
    Checks the local cache version against the latest from OpenRS2 and
    downloads the new cache if necessary.
    Uses centralized cache location.
    """
    # Use centralized cache directory. Discover it from the repo/worktree
    # location instead of assuming a home-relative path.
    cache_base = find_cache_base(Path(__file__).resolve())
    cache_root_dir = cache_base / 'game-data' / 'openrs2_cache'
    version_file = cache_root_dir / "cache.version"
    
    # Ensure cache directory exists
    os.makedirs(cache_root_dir, exist_ok=True)
    
    try:
        print("Checking for latest cache version...")
        latest_cache_info = get_latest_osrs_cache_info()
        latest_id = latest_cache_info["id"]

        current_id = None
        if os.path.exists(version_file):
            with open(version_file, 'r') as f:
                current_id = int(f.read().strip())
        
        print(f"Latest available cache ID: {latest_id}")
        print(f"Currently installed cache ID: {current_id or 'None'}")

        if current_id == latest_id and os.path.exists(os.path.join(cache_root_dir, "cache")):
            print("Cache is up to date. Nothing to do.")
            return

        print("Local cache is outdated or missing. A new download is required.")
        
        # Remove old cache if it exists
        if os.path.exists(cache_root_dir):
            print(f"Removing old cache directory: {cache_root_dir}")
            shutil.rmtree(cache_root_dir)
        
        os.makedirs(cache_root_dir, exist_ok=True)

        # Download the new cache
        cache_scope = latest_cache_info["scope"]
        download_url = f"https://archive.openrs2.org/caches/{cache_scope}/{latest_id}/disk.zip"
        
        print(f"Downloading complete cache from: {download_url}")
        print("This may take several minutes...")

        r = requests.get(download_url, stream=True, timeout=600)
        r.raise_for_status()
        
        # Extract the zip file
        print("Download complete. Extracting cache...")
        with zipfile.ZipFile(io.BytesIO(r.content)) as z:
            z.extractall(cache_root_dir)
        
        # Write the new version file
        with open(version_file, 'w') as f:
            f.write(str(latest_id))
            
        print(f"\nSuccessfully set up cache version {latest_id} in '{os.path.abspath(cache_root_dir)}'.")

    except requests.RequestException as e:
        print(f"\nAn error occurred while downloading the files: {e}")
    except Exception as e:
        print(f"\nAn unexpected error occurred: {e}")

if __name__ == "__main__":
    main()
