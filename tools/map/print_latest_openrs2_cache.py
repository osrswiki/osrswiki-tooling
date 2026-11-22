#!/usr/bin/env python3
"""Print the latest map-usable live OpenRS2 cache as JSON."""

from __future__ import annotations

import json
import sys

import requests

from openrs2_cache import (
    select_latest_live_osrs_cache,
    select_latest_xtea_source_cache,
    summarize_openrs2_cache,
)


def main() -> int:
    response = requests.get("https://archive.openrs2.org/caches.json", timeout=30)
    response.raise_for_status()
    caches = response.json()
    cache = select_latest_live_osrs_cache(caches, require_valid_keys=False)
    xtea_source = cache
    if int(cache.get("valid_keys") or 0) <= 0:
        xtea_source = select_latest_xtea_source_cache(caches)
    summary = summarize_openrs2_cache(cache, xtea_source=xtea_source)
    print(
        "selected OpenRS2 cache "
        f"id={summary['id']} timestamp={summary['timestamp']} "
        f"build={summary['build']} keys={summary['valid_keys']}/{summary['keys']} "
        f"xtea_cache_id={summary['xtea_cache_id']}",
        file=sys.stderr,
    )
    json.dump(summary, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
