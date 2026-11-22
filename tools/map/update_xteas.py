#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Fetches the latest OSRS XTEA keys from the OpenRS2 Archive API.
"""

import json
import os

import requests

from openrs2_cache import (
    cache_build_major,
    parse_cache_timestamp,
    select_latest_live_osrs_cache,
    select_latest_xtea_source_cache,
)

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

        # 2. Find the most recent live OSRS cache (XTEAs may live on an older id).
        latest_cache = select_latest_live_osrs_cache(all_caches, require_valid_keys=False)
        latest_timestamp = parse_cache_timestamp(latest_cache)
        xtea_cache = latest_cache
        if int(latest_cache.get("valid_keys") or 0) <= 0:
            xtea_cache = select_latest_xtea_source_cache(all_caches)

        cache_id = latest_cache["id"]
        cache_scope = latest_cache["scope"]
        xtea_id = xtea_cache["id"]
        xtea_scope = xtea_cache.get("scope") or cache_scope
        build = cache_build_major(latest_cache)
        print(
            f"Found latest map-usable live cache: ID={cache_id}, Scope='{cache_scope}', "
            f"Timestamp={latest_timestamp.isoformat() if latest_timestamp else None}, "
            f"Build={build}, "
            f"Keys={latest_cache.get('valid_keys')}/{latest_cache.get('keys')}"
        )
        if xtea_id != cache_id:
            print(
                f"OpenRS2 no longer publishes XTEAs on cache {cache_id}; "
                f"using keys from cache {xtea_id} "
                f"({xtea_cache.get('valid_keys')}/{xtea_cache.get('keys')})"
            )

        # 3. Construct the URL for the keys and download the file
        keys_url = f"https://archive.openrs2.org/caches/{xtea_scope}/{xtea_id}/keys.json"
        print(f"Downloading keys from: {keys_url}")
        
        keys_response = requests.get(keys_url, timeout=15)
        keys_response.raise_for_status()
        keys_payload = keys_response.json()
        if not keys_payload:
            raise RuntimeError(f"XTEA key list from cache {xtea_id} is empty")
        
        # 4. Save the keys to the map-dumper's xtea.json
        script_dir = os.path.dirname(os.path.abspath(__file__))
        output_path = os.path.join(script_dir, "map-dumper", "xtea.json")

        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(keys_payload, f)
            
        print(f"\nSuccessfully updated '{os.path.abspath(output_path)}'.")

    except requests.RequestException as e:
        print(f"\nAn error occurred while downloading the files: {e}")
    except Exception as e:
        print(f"\nAn unexpected error occurred: {e}")

if __name__ == "__main__":
    main()
