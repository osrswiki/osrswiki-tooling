from datetime import datetime


def parse_cache_timestamp(cache):
    timestamp = cache.get("timestamp")
    if not timestamp:
        return None
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00"))


def select_latest_live_osrs_cache(caches, require_valid_keys=True):
    latest_cache = None
    latest_timestamp = None

    for cache in caches:
        if cache.get("game") != "oldschool" or cache.get("environment") != "live":
            continue
        if cache.get("disk_store_valid") is False:
            continue
        if require_valid_keys and int(cache.get("valid_keys") or 0) <= 0:
            continue

        timestamp = parse_cache_timestamp(cache)
        if timestamp is None:
            continue

        if latest_cache is None or timestamp > latest_timestamp:
            latest_cache = cache
            latest_timestamp = timestamp

    if latest_cache is None:
        key_requirement = " with valid keys" if require_valid_keys else ""
        raise RuntimeError(f"Could not find a valid live OSRS cache{key_requirement}")

    return latest_cache
