#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Fetches the latest OSRS XTEA keys from the OpenRS2 Archive API.
"""

import requests
import os

from openrs2_cache import parse_cache_timestamp, select_latest_live_osrs_cache

def main():
    """
    Finds the latest live OSRS cache and downloads its corresponding XTEA key file.
    """
    print("Fetching cache list from OpenRS2...")
    try:
        # 1. Fetch the list of all caches
        caches_url = "https://archive.openrs2.org/caches.json"
        response = requests.get(caches_url, timeout=15)
        response.raise_for_status()
        all_caches = response.json()

        # 2. Find the most recent live OSRS cache that has map keys.
        latest_cache = select_latest_live_osrs_cache(all_caches, require_valid_keys=True)
        latest_timestamp = parse_cache_timestamp(latest_cache)

        cache_id = latest_cache["id"]
        cache_scope = latest_cache["scope"]
        print(
            f"Found latest map-usable live cache: ID={cache_id}, Scope='{cache_scope}', "
            f"Timestamp={latest_timestamp.isoformat()}, "
            f"Keys={latest_cache.get('valid_keys')}/{latest_cache.get('keys')}"
        )

        # 3. Construct the URL for the keys and download the file
        keys_url = f"https://archive.openrs2.org/caches/{cache_scope}/{cache_id}/keys.json"
        print(f"Downloading keys from: {keys_url}")
        
        keys_response = requests.get(keys_url, timeout=15)
        keys_response.raise_for_status()
        
        # 4. Save the keys to the map-dumper's xtea.json
        script_dir = os.path.dirname(os.path.abspath(__file__))
        output_path = os.path.join(script_dir, "map-dumper", "xtea.json")

        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(keys_response.text)
            
        print(f"\nSuccessfully updated '{os.path.abspath(output_path)}'.")

    except requests.RequestException as e:
        print(f"\nAn error occurred while downloading the files: {e}")
    except Exception as e:
        print(f"\nAn unexpected error occurred: {e}")

if __name__ == "__main__":
    main()
