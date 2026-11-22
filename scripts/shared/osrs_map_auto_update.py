#!/usr/bin/env python3
"""Versioned map-pin naming, content comparison, and manifest updates.

Stdlib-only helper used by ``scripts/shared/map-auto-update.sh``. Do not
upload, clobber, or delete GitHub Releases from this module; the shell
orchestrator is the only caller that talks to ``gh``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


SURFACE_MEMBERS = (
    "map_floor_0.mbtiles",
    "map_floor_1.mbtiles",
    "map_floor_2.mbtiles",
    "map_floor_3.mbtiles",
)
SURFACE_BUNDLE_NAME = "map_floors.zip"
SURFACE_TAG_PREFIX = "map-assets-v1-"
SURFACE_SET_PREFIX = "osrs-surface-maps-"
UNDERGROUND_TAG_PREFIX = "underground-assets-v1-"
UNDERGROUND_SET_PREFIX = "osrs-underground-realms-"
TOOLING_REPOSITORY = "osrswiki/osrswiki-tooling"
SOURCE_AUTHORITY = "https://github.com/omiyawaki/osrswiki-fleet.git#main"
FINGERPRINT_LENGTH = 12
CHUNK_SIZE = 1024 * 1024
DEFAULT_TERRAIN_ONLY_FALLBACK_MAX = 8
REGION_STATS_REQUIRED_KEYS = (
    "regions_loaded",
    "locations_loaded",
    "terrain_only_fallback",
    "unnamed_xtea_applied",
)


class MapAutoUpdateError(RuntimeError):
    """Fail-closed error for pin naming or manifest updates."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def fingerprint_from_records(records: Sequence[Mapping[str, Any]]) -> str:
    """Return a 12-hex content identity for a pin set.

    The identity is the leading SHA-256 of the canonical JSON of sorted
    ``(key, sha256, bytes)`` tuples, so a cache bump that does not change
    asset bytes yields the same fingerprint.
    """
    payload = []
    for record in records:
        key = str(record.get("path") or record.get("name") or "")
        digest = str(record.get("sha256", ""))
        size = int(record.get("bytes", 0))
        if not key or len(digest) != 64:
            raise MapAutoUpdateError("asset record is missing path/name or sha256")
        payload.append({"key": key, "sha256": digest, "bytes": size})
    payload.sort(key=lambda item: item["key"])
    digest = hashlib.sha256(canonical_json_bytes(payload)).hexdigest()
    return digest[:FINGERPRINT_LENGTH]


def surface_release_names(fingerprint: str) -> dict[str, str]:
    _assert_fingerprint(fingerprint)
    return {
        "asset_set_id": SURFACE_SET_PREFIX + fingerprint,
        "release_tag": SURFACE_TAG_PREFIX + fingerprint,
    }


def underground_release_names(fingerprint: str) -> dict[str, str]:
    _assert_fingerprint(fingerprint)
    return {
        "asset_set_id": UNDERGROUND_SET_PREFIX + fingerprint,
        "release_tag": UNDERGROUND_TAG_PREFIX + fingerprint,
    }


def github_name_from_path(path: str) -> str:
    return path.replace("/", "__")


def release_asset_url(repository: str, release_tag: str, name: str) -> str:
    return f"https://github.com/{repository}/releases/download/{release_tag}/{name}"


def mbtiles_payload_fingerprint(path: Path) -> str:
    """Hash MBTiles metadata plus tile PNG blobs, ignoring SQLite wrapper bytes.

    ``slice_tiles.py`` inserts tiles in directory-listing order, so two
    dumps of the same map can produce identical tile payloads and
    different ``.mbtiles`` file hashes. Freshness compares this digest.
    """
    uri = f"file:{path.resolve().as_posix()}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as error:
        raise MapAutoUpdateError(f"cannot open mbtiles {path}: {error}") from error
    try:
        try:
            metadata = [
                {"name": str(name), "value": str(value)}
                for name, value in connection.execute(
                    "SELECT name, value FROM metadata ORDER BY name"
                )
            ]
            tiles = []
            for zoom, column, row, blob in connection.execute(
                "SELECT zoom_level, tile_column, tile_row, tile_data "
                "FROM tiles ORDER BY zoom_level, tile_column, tile_row"
            ):
                data = bytes(blob or b"")
                tiles.append(
                    {
                        "zoom": int(zoom),
                        "column": int(column),
                        "row": int(row),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "bytes": len(data),
                    }
                )
        except sqlite3.Error as error:
            raise MapAutoUpdateError(f"cannot query mbtiles {path}: {error}") from error
    finally:
        connection.close()
    if not tiles:
        raise MapAutoUpdateError(f"mbtiles has no tiles: {path}")
    return hashlib.sha256(
        canonical_json_bytes({"metadata": metadata, "tiles": tiles})
    ).hexdigest()


def maybe_mbtiles_payload_fingerprint(path: Path) -> str | None:
    if path.suffix != ".mbtiles":
        return None
    try:
        return mbtiles_payload_fingerprint(path)
    except MapAutoUpdateError:
        return None


def record_for_file(path: Path, *, name: str | None = None) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise MapAutoUpdateError(f"required regular asset is missing: {path}")
    record = {
        "name": name or path.name,
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
    }
    payload = maybe_mbtiles_payload_fingerprint(path)
    if payload:
        record["payload_sha256"] = payload
    return record


def attach_mbtiles_payloads(
    records: Sequence[Mapping[str, Any]],
    source_dir: Path,
    *,
    key: str,
) -> list[dict[str, Any]]:
    attached = []
    for record in records:
        item = dict(record)
        relative = str(item.get(key) or item.get("path") or item.get("name") or "")
        if relative:
            payload = maybe_mbtiles_payload_fingerprint(source_dir / relative)
            if payload:
                item["payload_sha256"] = payload
        attached.append(item)
    return attached


def content_digest(record: Mapping[str, Any]) -> str:
    payload = record.get("payload_sha256")
    if isinstance(payload, str) and len(payload) == 64:
        return payload
    digest = str(record.get("sha256", ""))
    if len(digest) != 64:
        raise MapAutoUpdateError("asset record is missing sha256/payload_sha256")
    return digest


def surface_records_from_directory(source_dir: Path) -> list[dict[str, Any]]:
    records = []
    for name in SURFACE_MEMBERS:
        records.append(record_for_file(source_dir / name, name=name))
    return records


def discover_underground_paths(source_dir: Path) -> list[str]:
    if not source_dir.is_dir():
        raise MapAutoUpdateError(f"underground asset directory not found: {source_dir}")
    paths: list[str] = []
    catalog = source_dir / "underground-realms.json"
    if catalog.is_file() and not catalog.is_symlink():
        paths.append("underground-realms.json")
    for mbtiles in sorted(source_dir.rglob("*.mbtiles")):
        if mbtiles.is_symlink() or not mbtiles.is_file():
            continue
        relative = mbtiles.relative_to(source_dir).as_posix()
        if relative != "underground-realms.json":
            paths.append(relative)
    if "underground-realms.json" not in paths:
        raise MapAutoUpdateError("underground tree is missing underground-realms.json")
    if len(paths) < 2:
        raise MapAutoUpdateError("underground tree has no mbtiles members")
    return paths


def underground_records_from_directory(source_dir: Path) -> list[dict[str, Any]]:
    records = []
    for relative in discover_underground_paths(source_dir):
        path = source_dir / relative
        info = record_for_file(path, name=github_name_from_path(relative))
        info["path"] = relative
        records.append(info)
    return records


def compare_records(
    generated: Sequence[Mapping[str, Any]],
    pinned: Sequence[Mapping[str, Any]],
    *,
    key: str,
) -> dict[str, list[str]]:
    generated_by_key = {str(item[key]): item for item in generated}
    pinned_by_key = {str(item[key]): item for item in pinned}
    added = sorted(set(generated_by_key) - set(pinned_by_key))
    removed = sorted(set(pinned_by_key) - set(generated_by_key))
    changed = []
    unchanged = []
    for name in sorted(set(generated_by_key) & set(pinned_by_key)):
        gen = generated_by_key[name]
        pin = pinned_by_key[name]
        if content_digest(gen) != content_digest(pin):
            changed.append(name)
        else:
            unchanged.append(name)
    return {
        "added": added,
        "removed": removed,
        "changed": changed,
        "unchanged": unchanged,
    }


def content_changed(comparison: Mapping[str, Sequence[str]]) -> bool:
    return bool(comparison.get("added") or comparison.get("removed") or comparison.get("changed"))


def pin_directory_matches_manifest(
    manifest: Mapping[str, Any],
    source_dir: Path,
    *,
    key: str,
) -> bool:
    """True when every pinned asset is present with matching size and sha256.

    A leftover comparison tree from an older pin must not be reused: payload
    comparison against stale bytes looks like a content change while the
    generated fingerprint still matches the current tag.
    """
    assets = manifest.get("assets")
    if not isinstance(assets, list) or not assets:
        return False
    if not source_dir.is_dir():
        return False
    for item in assets:
        if not isinstance(item, Mapping):
            return False
        relative = str(item.get(key) or item.get("path") or item.get("name") or "")
        expected = str(item.get("sha256") or "")
        try:
            expected_bytes = int(item.get("bytes") or 0)
        except (TypeError, ValueError):
            return False
        if not relative or len(expected) != 64 or expected_bytes <= 0:
            return False
        path = source_dir / relative
        if not path.is_file() or path.is_symlink():
            return False
        if path.stat().st_size != expected_bytes:
            return False
        if sha256_file(path) != expected:
            return False
    return True


def pinned_cache_id(manifest: Mapping[str, Any]) -> int | None:
    provenance = manifest.get("provenance")
    if not isinstance(provenance, Mapping):
        return None
    value = provenance.get("openrs2_cache_id")
    if value is None:
        return None
    try:
        cache_id = int(value)
    except (TypeError, ValueError) as error:
        raise MapAutoUpdateError("provenance.openrs2_cache_id is not an integer") from error
    if cache_id <= 0:
        raise MapAutoUpdateError("provenance.openrs2_cache_id must be positive")
    return cache_id


def cache_is_newer_than_pin(live_cache_id: int, pinned_id: int | None) -> bool:
    """True when generation should run.

    Missing pin provenance is treated as unknown, so a live cache always
    needs a comparison against shipped bytes.
    """
    if pinned_id is None:
        return True
    return int(live_cache_id) != int(pinned_id)


def classify_release_tag(
    *,
    old_tag: str,
    new_tag: str,
    content_changed_flag: bool,
    remote_present: bool,
    remote_matches: bool,
) -> str:
    """Return create, skip, reuse, or raise on a clobber/conflict.

    Existing pins, shipped builds, and F-Droid metadata keep downloading the
    old tag. This helper never returns an instruction to overwrite it.
    """
    if not content_changed_flag:
        return "skip"
    if new_tag == old_tag:
        raise MapAutoUpdateError(
            f"refusing to reuse pin tag {old_tag} for different content"
        )
    if remote_present and not remote_matches:
        raise MapAutoUpdateError(
            f"refusing to clobber existing tooling release {new_tag}"
        )
    if remote_present and remote_matches:
        return "reuse"
    return "create"


def openrs2_provenance(live_cache: Mapping[str, Any]) -> dict[str, Any]:
    cache_id = int(live_cache["id"])
    timestamp = live_cache.get("timestamp")
    scope = live_cache.get("scope")
    if cache_id <= 0:
        raise MapAutoUpdateError("OpenRS2 cache id must be positive")
    provenance = {
        "source_authority": SOURCE_AUTHORITY,
        "artifact_class": "immutable-reproducible-release",
        "generated_intermediates": "host-local-only",
        "openrs2_cache_id": cache_id,
    }
    if timestamp:
        provenance["openrs2_cache_timestamp"] = str(timestamp)
    if scope:
        provenance["openrs2_cache_scope"] = str(scope)
    build = live_cache.get("build")
    if build is not None and str(build).strip() != "":
        try:
            provenance["openrs2_cache_build"] = int(build)
        except (TypeError, ValueError):
            provenance["openrs2_cache_build"] = build
    xtea_id = live_cache.get("xtea_cache_id")
    if xtea_id is not None and int(xtea_id) != cache_id:
        provenance["openrs2_xtea_cache_id"] = int(xtea_id)
    return provenance


def build_surface_manifest(
    *,
    assets: Sequence[Mapping[str, Any]],
    bundle_sha256: str,
    bundle_bytes: int,
    live_cache: Mapping[str, Any],
    previous: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if [item["name"] for item in assets] != list(SURFACE_MEMBERS):
        raise MapAutoUpdateError("surface assets must be map_floor_0..3.mbtiles")
    fingerprint = fingerprint_from_records(assets)
    names = surface_release_names(fingerprint)
    provenance = openrs2_provenance(live_cache)
    provenance["generator"] = "scripts/shared/map-auto-update.sh"
    if isinstance(previous, Mapping):
        previous_prov = previous.get("provenance")
        if isinstance(previous_prov, Mapping):
            for key in ("candidate",):
                if key in previous_prov and key not in provenance:
                    provenance[key] = previous_prov[key]
    return {
        "schema_version": 1,
        "asset_set_id": names["asset_set_id"],
        "repository": TOOLING_REPOSITORY,
        "release_tag": names["release_tag"],
        "bundle": {
            "name": SURFACE_BUNDLE_NAME,
            "sha256": bundle_sha256,
            "bytes": int(bundle_bytes),
            "members": list(SURFACE_MEMBERS),
        },
        "assets": [
            {
                "name": item["name"],
                "sha256": item["sha256"],
                "bytes": int(item["bytes"]),
                **(
                    {"payload_sha256": item["payload_sha256"]}
                    if item.get("payload_sha256")
                    else {}
                ),
            }
            for item in assets
        ],
        "provenance": provenance,
    }


def build_underground_manifest(
    *,
    assets: Sequence[Mapping[str, Any]],
    live_cache: Mapping[str, Any],
    previous: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    fingerprint = fingerprint_from_records(assets)
    names = underground_release_names(fingerprint)
    tag = names["release_tag"]
    provenance = openrs2_provenance(live_cache)
    provenance["generator"] = "scripts/shared/map-auto-update.sh"
    if isinstance(previous, Mapping):
        previous_prov = previous.get("provenance")
        if isinstance(previous_prov, Mapping) and "candidate" in previous_prov:
            provenance["candidate"] = previous_prov["candidate"]
    records = []
    for item in assets:
        path = str(item["path"])
        name = github_name_from_path(path)
        record = {
            "path": path,
            "name": name,
            "sha256": item["sha256"],
            "bytes": int(item["bytes"]),
            "url": release_asset_url(TOOLING_REPOSITORY, tag, name),
        }
        if item.get("payload_sha256"):
            record["payload_sha256"] = item["payload_sha256"]
        records.append(record)
    return {
        "schema_version": 1,
        "asset_set_id": names["asset_set_id"],
        "repository": TOOLING_REPOSITORY,
        "release_tag": tag,
        "assets": records,
        "provenance": provenance,
    }


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MapAutoUpdateError(f"cannot read JSON {path}: {error}") from error


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json_bytes(value))


def evaluate_region_load_stats(
    stats: Mapping[str, Any],
    *,
    max_fallback: int = DEFAULT_TERRAIN_ONLY_FALLBACK_MAX,
) -> dict[str, Any]:
    """Return whether MAPS location coverage is safe to publish.

    ``terrain_only_fallback`` is the count of regions whose terrain loaded
    but file-1 (locations) threw. Those maps would silently drop buildings.
    A future encrypted cache must fail closed instead of shipping that.
    """
    if max_fallback < 0:
        raise MapAutoUpdateError("max terrain-only fallback must be >= 0")
    missing = [key for key in REGION_STATS_REQUIRED_KEYS if key not in stats]
    if missing:
        raise MapAutoUpdateError(
            "region-load-stats.json is missing keys: " + ", ".join(missing)
        )
    try:
        regions_loaded = int(stats["regions_loaded"])
        locations_loaded = int(stats["locations_loaded"])
        terrain_only_fallback = int(stats["terrain_only_fallback"])
        unnamed_xtea_applied = int(stats["unnamed_xtea_applied"])
    except (TypeError, ValueError) as error:
        raise MapAutoUpdateError(
            f"region-load-stats.json has non-integer counts: {error}"
        ) from error
    if regions_loaded <= 0:
        raise MapAutoUpdateError("region-load-stats.json loaded 0 regions")
    fallback_ids = stats.get("fallback_region_ids") or []
    if not isinstance(fallback_ids, list):
        fallback_ids = []
    ok = terrain_only_fallback <= max_fallback
    return {
        "ok": ok,
        "max_fallback": max_fallback,
        "regions_loaded": regions_loaded,
        "locations_loaded": locations_loaded,
        "terrain_only_fallback": terrain_only_fallback,
        "unnamed_xtea_applied": unnamed_xtea_applied,
        "unnamed_xtea_keys_available": int(stats.get("unnamed_xtea_keys_available") or 0),
        "fallback_region_ids": [int(item) for item in fallback_ids[:32]],
    }


def decide_plan(
    *,
    live_cache: Mapping[str, Any],
    surface_manifest: Mapping[str, Any],
    underground_manifest: Mapping[str, Any],
    generated_surface: Sequence[Mapping[str, Any]] | None,
    generated_underground: Sequence[Mapping[str, Any]] | None,
    surface_bundle: Mapping[str, Any] | None,
    existing_surface_tag: bool = False,
    existing_surface_matches: bool = False,
    existing_underground_tag: bool = False,
    existing_underground_matches: bool = False,
    force_generate: bool = False,
    pinned_surface_dir: Path | None = None,
    pinned_underground_dir: Path | None = None,
) -> dict[str, Any]:
    live_id = int(live_cache["id"])
    live_timestamp = str(live_cache.get("timestamp") or "")
    surface_pin_id = pinned_cache_id(surface_manifest)
    underground_pin_id = pinned_cache_id(underground_manifest)
    need_generate = force_generate or cache_is_newer_than_pin(live_id, surface_pin_id)
    if cache_is_newer_than_pin(live_id, underground_pin_id):
        need_generate = True

    plan: dict[str, Any] = {
        "live_cache_id": live_id,
        "live_cache_timestamp": live_timestamp,
        "surface_pinned_cache_id": surface_pin_id,
        "underground_pinned_cache_id": underground_pin_id,
        "need_generate": need_generate,
        "surface": {"action": "pending_generation"},
        "underground": {"action": "pending_generation"},
        "open_pr": False,
        "pr_title": "",
        "pr_body": "",
    }

    if generated_surface is None or generated_underground is None:
        if not need_generate:
            plan["surface"] = {"action": "skip", "reason": "pin already records this OpenRS2 cache"}
            plan["underground"] = {
                "action": "skip",
                "reason": "pin already records this OpenRS2 cache",
            }
            plan["need_generate"] = False
        return plan

    pinned_surface_assets: Sequence[Mapping[str, Any]] = list(
        surface_manifest["assets"]
    )
    pinned_underground_assets: Sequence[Mapping[str, Any]] = list(
        underground_manifest["assets"]
    )
    if pinned_surface_dir is not None:
        pinned_surface_assets = attach_mbtiles_payloads(
            pinned_surface_assets, pinned_surface_dir, key="name"
        )
    if pinned_underground_dir is not None:
        pinned_underground_assets = attach_mbtiles_payloads(
            pinned_underground_assets, pinned_underground_dir, key="path"
        )
    surface_comparison = compare_records(
        generated_surface, pinned_surface_assets, key="name"
    )
    underground_comparison = compare_records(
        generated_underground, pinned_underground_assets, key="path"
    )
    surface_changed = content_changed(surface_comparison)
    underground_changed = content_changed(underground_comparison)
    surface_fp = fingerprint_from_records(generated_surface)
    underground_fp = fingerprint_from_records(generated_underground)
    surface_names = surface_release_names(surface_fp)
    underground_names = underground_release_names(underground_fp)

    surface_action = classify_release_tag(
        old_tag=str(surface_manifest["release_tag"]),
        new_tag=surface_names["release_tag"],
        content_changed_flag=surface_changed,
        remote_present=existing_surface_tag,
        remote_matches=existing_surface_matches,
    )
    underground_action = classify_release_tag(
        old_tag=str(underground_manifest["release_tag"]),
        new_tag=underground_names["release_tag"],
        content_changed_flag=underground_changed,
        remote_present=existing_underground_tag,
        remote_matches=existing_underground_matches,
    )

    plan["surface"] = {
        "action": surface_action,
        "fingerprint": surface_fp,
        "release_tag": surface_names["release_tag"],
        "asset_set_id": surface_names["asset_set_id"],
        "comparison": surface_comparison,
        "old_release_tag": surface_manifest["release_tag"],
    }
    plan["underground"] = {
        "action": underground_action,
        "fingerprint": underground_fp,
        "release_tag": underground_names["release_tag"],
        "asset_set_id": underground_names["asset_set_id"],
        "comparison": underground_comparison,
        "old_release_tag": underground_manifest["release_tag"],
    }

    if surface_changed:
        if surface_bundle is None:
            raise MapAutoUpdateError("surface content changed but bundle digest is missing")
        plan["surface_manifest"] = build_surface_manifest(
            assets=generated_surface,
            bundle_sha256=str(surface_bundle["sha256"]),
            bundle_bytes=int(surface_bundle["bytes"]),
            live_cache=live_cache,
            previous=surface_manifest,
        )
    if underground_changed:
        plan["underground_manifest"] = build_underground_manifest(
            assets=generated_underground,
            live_cache=live_cache,
            previous=underground_manifest,
        )

    plan["open_pr"] = surface_changed or underground_changed
    if plan["open_pr"]:
        plan["pr_title"] = build_pr_title(plan)
        plan["pr_body"] = build_pr_body(plan)
    return plan


def changed_names(comparison: Mapping[str, Sequence[str]]) -> list[str]:
    names: list[str] = []
    for bucket, prefix in (("changed", ""), ("added", "+"), ("removed", "-")):
        for name in comparison.get(bucket, []):
            names.append(f"{prefix}{name}" if prefix else str(name))
    return names


def build_pr_title(plan: Mapping[str, Any]) -> str:
    live_id = plan.get("live_cache_id")
    parts = []
    if plan.get("surface", {}).get("action") in {"create", "reuse"}:
        parts.append("surface")
    if plan.get("underground", {}).get("action") in {"create", "reuse"}:
        parts.append("underground")
    label = " and ".join(parts) if parts else "map"
    return f"chore(map): pin {label} assets from OpenRS2 cache {live_id}"


def build_pr_body(plan: Mapping[str, Any]) -> str:
    live_id = plan.get("live_cache_id")
    timestamp = plan.get("live_cache_timestamp") or "unknown"
    lines = [
        "Automated map-asset pin bump. New maps ride the next app release;",
        "this PR does not ship TestFlight, Play, or F-Droid.",
        "",
        f"- OpenRS2 cache id: `{live_id}`",
        f"- OpenRS2 cache timestamp: `{timestamp}`",
        "",
    ]
    for kind in ("surface", "underground"):
        block = plan.get(kind) or {}
        action = block.get("action")
        lines.append(f"## {kind}")
        if action == "skip":
            lines.append("No content change versus the current pin.")
            lines.append("")
            continue
        lines.append(f"- action: `{action}`")
        lines.append(f"- new tag: `{block.get('release_tag')}`")
        lines.append(f"- previous tag (kept downloadable): `{block.get('old_release_tag')}`")
        changed = changed_names(block.get("comparison") or {})
        if changed:
            lines.append("- changed members:")
            for name in changed:
                lines.append(f"  - `{name}`")
        else:
            lines.append("- changed members: none")
        lines.append("")
    lines.extend(
        [
            "## Still manual",
            "",
            "- F-Droid `fdroiddata` zip pin updates at FOSS release time.",
            "- App Store / Play / TestFlight uploads are unchanged.",
            "- In-app runtime map download remains out of scope.",
            "",
        ]
    )
    return "\n".join(lines)


def _assert_fingerprint(fingerprint: str) -> None:
    if len(fingerprint) != FINGERPRINT_LENGTH or any(
        character not in "0123456789abcdef" for character in fingerprint
    ):
        raise MapAutoUpdateError("fingerprint must be 12 lowercase hex characters")


def _read_optional_json(path: str | None) -> Any | None:
    if not path:
        return None
    return load_json(Path(path))


def _cmd_fingerprint(args: argparse.Namespace) -> int:
    records = load_json(Path(args.records))
    if not isinstance(records, list):
        raise MapAutoUpdateError("records JSON must be an array")
    print(fingerprint_from_records(records))
    return 0


def _cmd_compare(args: argparse.Namespace) -> int:
    generated = load_json(Path(args.generated))
    pinned = load_json(Path(args.pinned))
    comparison = compare_records(generated, pinned, key=args.key)
    sys.stdout.write(canonical_json_bytes(comparison).decode("utf-8"))
    return 0


def _cmd_decide(args: argparse.Namespace) -> int:
    live_cache = load_json(Path(args.live_cache))
    surface_manifest = load_json(Path(args.surface_manifest))
    underground_manifest = load_json(Path(args.underground_manifest))
    generated_surface = None
    generated_underground = None
    surface_bundle = None
    if args.surface_dir:
        generated_surface = surface_records_from_directory(Path(args.surface_dir))
    if args.underground_dir:
        generated_underground = underground_records_from_directory(
            Path(args.underground_dir)
        )
    if args.surface_bundle:
        surface_bundle = load_json(Path(args.surface_bundle))
    pinned_surface_dir = Path(args.pinned_surface_dir) if args.pinned_surface_dir else None
    pinned_underground_dir = (
        Path(args.pinned_underground_dir) if args.pinned_underground_dir else None
    )
    plan = decide_plan(
        live_cache=live_cache,
        surface_manifest=surface_manifest,
        underground_manifest=underground_manifest,
        generated_surface=generated_surface,
        generated_underground=generated_underground,
        surface_bundle=surface_bundle,
        existing_surface_tag=bool(args.existing_surface_tag),
        existing_surface_matches=bool(args.existing_surface_matches),
        existing_underground_tag=bool(args.existing_underground_tag),
        existing_underground_matches=bool(args.existing_underground_matches),
        force_generate=bool(args.force),
        pinned_surface_dir=pinned_surface_dir,
        pinned_underground_dir=pinned_underground_dir,
    )
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "plan.json", plan)
    if "surface_manifest" in plan:
        write_json(output / "osrs-map-assets-v1.json", plan["surface_manifest"])
    if "underground_manifest" in plan:
        write_json(
            output / "osrs-underground-assets-v1.json", plan["underground_manifest"]
        )
    if plan.get("pr_body"):
        (output / "pr-body.md").write_text(plan["pr_body"], encoding="utf-8")
    sys.stdout.write(canonical_json_bytes(plan).decode("utf-8"))
    return 0


def _cmd_region_stats(args: argparse.Namespace) -> int:
    stats = load_json(Path(args.stats))
    if not isinstance(stats, Mapping):
        raise MapAutoUpdateError("region-load-stats.json must be an object")
    evaluation = evaluate_region_load_stats(stats, max_fallback=args.max_fallback)
    sys.stdout.write(canonical_json_bytes(evaluation).decode("utf-8"))
    return 0 if evaluation["ok"] else 2


def _cmd_records(args: argparse.Namespace) -> int:
    source = Path(args.source_dir)
    if args.kind == "surface":
        records = surface_records_from_directory(source)
    else:
        records = underground_records_from_directory(source)
    sys.stdout.write(canonical_json_bytes(records).decode("utf-8"))
    return 0


def _cmd_pin_dir(args: argparse.Namespace) -> int:
    manifest = load_json(Path(args.manifest))
    if not isinstance(manifest, Mapping):
        raise MapAutoUpdateError("manifest JSON must be an object")
    matched = pin_directory_matches_manifest(
        manifest, Path(args.source_dir), key=args.key
    )
    sys.stdout.write(canonical_json_bytes({"ok": matched}).decode("utf-8"))
    return 0 if matched else 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fingerprint_parser = subparsers.add_parser("fingerprint")
    fingerprint_parser.add_argument("--records", required=True)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--generated", required=True)
    compare_parser.add_argument("--pinned", required=True)
    compare_parser.add_argument("--key", choices=("name", "path"), default="name")

    records_parser = subparsers.add_parser("records")
    records_parser.add_argument("--kind", choices=("surface", "underground"), required=True)
    records_parser.add_argument("--source-dir", required=True)

    pin_dir_parser = subparsers.add_parser("pin-dir")
    pin_dir_parser.add_argument("--manifest", required=True)
    pin_dir_parser.add_argument("--source-dir", required=True)
    pin_dir_parser.add_argument("--key", choices=("name", "path"), default="name")

    decide_parser = subparsers.add_parser("decide")
    decide_parser.add_argument("--live-cache", required=True)
    decide_parser.add_argument("--surface-manifest", required=True)
    decide_parser.add_argument("--underground-manifest", required=True)
    decide_parser.add_argument("--surface-dir")
    decide_parser.add_argument("--underground-dir")
    decide_parser.add_argument("--surface-bundle")
    decide_parser.add_argument("--pinned-surface-dir")
    decide_parser.add_argument("--pinned-underground-dir")
    decide_parser.add_argument("--output", required=True)
    decide_parser.add_argument("--existing-surface-tag", action="store_true")
    decide_parser.add_argument("--existing-surface-matches", action="store_true")
    decide_parser.add_argument("--existing-underground-tag", action="store_true")
    decide_parser.add_argument("--existing-underground-matches", action="store_true")
    decide_parser.add_argument("--force", action="store_true")

    region_stats_parser = subparsers.add_parser("region-stats")
    region_stats_parser.add_argument("--stats", required=True)
    region_stats_parser.add_argument(
        "--max-fallback",
        type=int,
        default=DEFAULT_TERRAIN_ONLY_FALLBACK_MAX,
    )

    args = parser.parse_args(argv)
    commands = {
        "fingerprint": _cmd_fingerprint,
        "compare": _cmd_compare,
        "records": _cmd_records,
        "pin-dir": _cmd_pin_dir,
        "decide": _cmd_decide,
        "region-stats": _cmd_region_stats,
    }
    command = commands.get(args.command)
    if command is None:
        raise MapAutoUpdateError(f"unknown command: {args.command}")
    try:
        return command(args)
    except MapAutoUpdateError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
