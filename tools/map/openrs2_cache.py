from datetime import datetime, timezone


def parse_cache_timestamp(cache):
    timestamp = cache.get("timestamp")
    if not timestamp:
        return None
    try:
        parsed = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def cache_build_major(cache):
    """Return the highest documented major build, or None if the cache has none."""
    builds = cache.get("builds")
    if isinstance(cache.get("build"), int) and cache.get("build") > 0:
        majors = [int(cache["build"])]
    else:
        majors = []
    if isinstance(builds, list):
        for item in builds:
            if isinstance(item, dict) and item.get("major") is not None:
                try:
                    majors.append(int(item["major"]))
                except (TypeError, ValueError):
                    continue
            elif isinstance(item, int):
                majors.append(item)
    if not majors:
        return None
    return max(majors)


def is_live_oldschool_cache(cache):
    if cache.get("game") != "oldschool" or cache.get("environment") != "live":
        return False
    if cache.get("hidden") is True:
        return False
    if cache.get("disk_store_valid") is False:
        return False
    return cache_build_major(cache) is not None


def _rank_live_cache(cache):
    """Sort key: dated caches first, then newest timestamp, more keys, higher id.

    Null timestamps are handled (ranked last) so they cannot beat a dated live
    cache. Same-day snapshots compare by timestamp, then valid_keys, then id.
    """
    timestamp = parse_cache_timestamp(cache)
    has_timestamp = timestamp is not None
    timestamp_value = timestamp or datetime.min.replace(tzinfo=timezone.utc)
    keys = int(cache.get("valid_keys") or 0)
    cache_id = int(cache.get("id") or 0)
    return (has_timestamp, timestamp_value, keys, cache_id)


def select_latest_live_osrs_cache(caches, require_valid_keys=False):
    """Pick the live oldschool cache the map dump should use.

    Newest by timestamp among ``game=oldschool``, ``environment=live``, with a
    valid build. OpenRS2 stopped attaching XTEAs after 2026-03, so
    ``valid_keys == 0`` is not a reason to skip a later cache. Pass
    ``require_valid_keys=True`` only when selecting an XTEA source.
    """
    candidates = [cache for cache in caches if is_live_oldschool_cache(cache)]
    if require_valid_keys:
        keyed = [
            cache for cache in candidates if int(cache.get("valid_keys") or 0) > 0
        ]
        if keyed:
            candidates = keyed
    if not candidates:
        key_requirement = " with valid keys" if require_valid_keys else ""
        raise RuntimeError(f"Could not find a valid live OSRS cache{key_requirement}")
    return max(candidates, key=_rank_live_cache)


def select_latest_xtea_source_cache(caches):
    """Newest live oldschool cache that still publishes map XTEAs."""
    return select_latest_live_osrs_cache(caches, require_valid_keys=True)


def summarize_openrs2_cache(cache, xtea_source=None):
    build = cache_build_major(cache)
    xtea = xtea_source or cache
    summary = {
        "id": int(cache["id"]),
        "timestamp": cache.get("timestamp"),
        "build": build,
        "scope": cache.get("scope"),
        "valid_keys": int(cache.get("valid_keys") or 0),
        "keys": int(cache.get("keys") or 0),
        "disk_store_valid": cache.get("disk_store_valid"),
        "xtea_cache_id": int(xtea["id"]),
        "xtea_cache_timestamp": xtea.get("timestamp"),
        "xtea_valid_keys": int(xtea.get("valid_keys") or 0),
        "xtea_keys": int(xtea.get("keys") or 0),
    }
    return summary
