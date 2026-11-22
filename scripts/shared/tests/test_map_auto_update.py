from __future__ import annotations

import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
import sys

sys.path.insert(0, str(ROOT / "scripts" / "shared"))

from osrs_map_auto_update import (  # noqa: E402
    MapAutoUpdateError,
    build_surface_manifest,
    build_underground_manifest,
    cache_is_newer_than_pin,
    classify_release_tag,
    compare_records,
    content_changed,
    decide_plan,
    evaluate_region_load_stats,
    fingerprint_from_records,
    github_name_from_path,
    mbtiles_payload_fingerprint,
    pin_directory_matches_manifest,
    pinned_cache_id,
    surface_records_from_directory,
    surface_release_names,
    underground_records_from_directory,
    underground_release_names,
)


def _record(name: str, payload: bytes, path: str | None = None) -> dict:
    item = {
        "name": name,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "bytes": len(payload),
    }
    if path is not None:
        item["path"] = path
    return item


def _surface_records(suffix: bytes = b"a") -> list[dict]:
    return [
        _record(f"map_floor_{floor}.mbtiles", b"floor-%d-%s" % (floor, suffix))
        for floor in range(4)
    ]


def _underground_records(suffix: bytes = b"a") -> list[dict]:
    return [
        _record(
            "underground-realms.json",
            b'{"candidate":"%s"}\n' % suffix,
            path="underground-realms.json",
        ),
        _record(
            "assets__cache-world-map-fixture__plane-0.mbtiles",
            b"tiles-%s\n" % suffix,
            path="assets/cache-world-map-fixture/plane-0.mbtiles",
        ),
    ]


def _surface_manifest(records: list[dict], cache_id: int | None = 100) -> dict:
    fingerprint = fingerprint_from_records(records)
    names = surface_release_names(fingerprint)
    provenance = {
        "source_authority": "https://github.com/omiyawaki/osrswiki-fleet.git#main",
        "generator": "fixture",
        "artifact_class": "immutable-reproducible-release",
        "generated_intermediates": "host-local-only",
    }
    if cache_id is not None:
        provenance["openrs2_cache_id"] = cache_id
    return {
        "schema_version": 1,
        "asset_set_id": names["asset_set_id"],
        "repository": "osrswiki/osrswiki-tooling",
        "release_tag": names["release_tag"],
        "bundle": {
            "name": "map_floors.zip",
            "sha256": "ab" * 32,
            "bytes": 12,
            "members": [item["name"] for item in records],
        },
        "assets": records,
        "provenance": provenance,
    }


def _underground_manifest(records: list[dict], cache_id: int | None = 100) -> dict:
    fingerprint = fingerprint_from_records(records)
    names = underground_release_names(fingerprint)
    provenance = {
        "source_authority": "https://github.com/omiyawaki/osrswiki-fleet.git#main",
        "generator": "fixture",
        "artifact_class": "immutable-reproducible-release",
        "generated_intermediates": "host-local-only",
        "candidate": "010",
    }
    if cache_id is not None:
        provenance["openrs2_cache_id"] = cache_id
    assets = []
    for item in records:
        assets.append(
            {
                **item,
                "url": (
                    "https://github.com/osrswiki/osrswiki-tooling/releases/download/"
                    f"{names['release_tag']}/{item['name']}"
                ),
            }
        )
    return {
        "schema_version": 1,
        "asset_set_id": names["asset_set_id"],
        "repository": "osrswiki/osrswiki-tooling",
        "release_tag": names["release_tag"],
        "assets": assets,
        "provenance": provenance,
    }


class MapAutoUpdateTests(unittest.TestCase):
    def test_fingerprint_is_stable_for_the_same_bytes(self) -> None:
        first = fingerprint_from_records(_surface_records(b"same"))
        second = fingerprint_from_records(_surface_records(b"same"))
        self.assertEqual(first, second)
        self.assertRegex(first, r"^[0-9a-f]{12}$")

    def test_fingerprint_changes_when_content_changes(self) -> None:
        first = fingerprint_from_records(_surface_records(b"old"))
        second = fingerprint_from_records(_surface_records(b"new"))
        self.assertNotEqual(first, second)

    def test_versioned_release_names_use_the_fixed_v1_pattern(self) -> None:
        fingerprint = "0123456789ab"
        surface = surface_release_names(fingerprint)
        underground = underground_release_names(fingerprint)
        self.assertEqual(surface["release_tag"], "map-assets-v1-0123456789ab")
        self.assertEqual(surface["asset_set_id"], "osrs-surface-maps-0123456789ab")
        self.assertEqual(
            underground["release_tag"], "underground-assets-v1-0123456789ab"
        )
        self.assertEqual(
            underground["asset_set_id"], "osrs-underground-realms-0123456789ab"
        )

    def test_compare_records_detects_changed_added_and_removed(self) -> None:
        generated = _surface_records(b"new")
        pinned = _surface_records(b"old")
        pinned[3] = _record("map_floor_9.mbtiles", b"gone")
        comparison = compare_records(generated, pinned, key="name")
        self.assertIn("map_floor_0.mbtiles", comparison["changed"])
        self.assertEqual(comparison["added"], ["map_floor_3.mbtiles"])
        self.assertEqual(comparison["removed"], ["map_floor_9.mbtiles"])
        self.assertTrue(content_changed(comparison))

    def test_compare_records_is_unchanged_for_identical_pins(self) -> None:
        records = _surface_records(b"same")
        comparison = compare_records(records, records, key="name")
        self.assertEqual(comparison["changed"], [])
        self.assertEqual(comparison["added"], [])
        self.assertEqual(comparison["removed"], [])
        self.assertFalse(content_changed(comparison))

    def test_pin_directory_matches_current_manifest_bytes(self) -> None:
        records = _surface_records(b"current")
        manifest = _surface_manifest(records, cache_id=2772)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for item in records:
                (root / item["name"]).write_bytes(
                    b"floor-%d-%s" % (int(item["name"][10]), b"current")
                )
            self.assertTrue(
                pin_directory_matches_manifest(manifest, root, key="name")
            )

    def test_stale_pin_directory_does_not_match_current_manifest(self) -> None:
        current = _surface_records(b"current")
        stale = _surface_records(b"stale")
        manifest = _surface_manifest(current, cache_id=2772)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for item in stale:
                (root / item["name"]).write_bytes(
                    b"floor-%d-%s" % (int(item["name"][10]), b"stale")
                )
            self.assertFalse(
                pin_directory_matches_manifest(manifest, root, key="name")
            )
        self.assertFalse(
            pin_directory_matches_manifest(manifest, Path("/missing-pin-dir"), key="name")
        )

    def test_missing_pin_cache_id_is_treated_as_newer(self) -> None:
        self.assertTrue(cache_is_newer_than_pin(2615, None))
        self.assertTrue(cache_is_newer_than_pin(2615, 2499))
        self.assertFalse(cache_is_newer_than_pin(2499, 2499))

    def test_pinned_cache_id_reads_provenance(self) -> None:
        manifest = _surface_manifest(_surface_records(), cache_id=2499)
        self.assertEqual(2499, pinned_cache_id(manifest))
        del manifest["provenance"]["openrs2_cache_id"]
        self.assertIsNone(pinned_cache_id(manifest))

    def test_classify_release_tag_never_reuses_the_old_pin(self) -> None:
        with self.assertRaisesRegex(MapAutoUpdateError, "refusing to reuse pin tag"):
            classify_release_tag(
                old_tag="map-assets-v1-aaaaaaaaaaaa",
                new_tag="map-assets-v1-aaaaaaaaaaaa",
                content_changed_flag=True,
                remote_present=False,
                remote_matches=False,
            )

    def test_classify_release_tag_refuses_to_clobber_a_different_remote(self) -> None:
        with self.assertRaisesRegex(MapAutoUpdateError, "refusing to clobber"):
            classify_release_tag(
                old_tag="map-assets-v1-aaaaaaaaaaaa",
                new_tag="map-assets-v1-bbbbbbbbbbbb",
                content_changed_flag=True,
                remote_present=True,
                remote_matches=False,
            )

    def test_classify_release_tag_reuses_an_identical_existing_release(self) -> None:
        action = classify_release_tag(
            old_tag="map-assets-v1-aaaaaaaaaaaa",
            new_tag="map-assets-v1-bbbbbbbbbbbb",
            content_changed_flag=True,
            remote_present=True,
            remote_matches=True,
        )
        self.assertEqual(action, "reuse")

    def test_classify_release_tag_creates_a_new_versioned_release(self) -> None:
        action = classify_release_tag(
            old_tag="map-assets-v1-aaaaaaaaaaaa",
            new_tag="map-assets-v1-bbbbbbbbbbbb",
            content_changed_flag=True,
            remote_present=False,
            remote_matches=False,
        )
        self.assertEqual(action, "create")

    def test_mbtiles_payload_fingerprint_ignores_sqlite_insert_order(self) -> None:
        tiles = [
            (0, 0, 0, b"png-a"),
            (1, 2, 3, b"png-b"),
            (2, 1, 4, b"png-c"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.mbtiles"
            second = Path(directory) / "second.mbtiles"
            for path, order in ((first, tiles), (second, list(reversed(tiles)))):
                connection = sqlite3.connect(path)
                connection.execute(
                    "CREATE TABLE metadata (name text, value text)"
                )
                connection.execute(
                    "CREATE TABLE tiles ("
                    "zoom_level integer, tile_column integer, "
                    "tile_row integer, tile_data blob)"
                )
                connection.execute(
                    "INSERT INTO metadata (name, value) VALUES ('name', 'floor')"
                )
                connection.executemany(
                    "INSERT INTO tiles VALUES (?, ?, ?, ?)", order
                )
                connection.commit()
                connection.close()
            self.assertEqual(
                mbtiles_payload_fingerprint(first),
                mbtiles_payload_fingerprint(second),
            )
            self.assertNotEqual(
                hashlib.sha256(first.read_bytes()).hexdigest(),
                hashlib.sha256(second.read_bytes()).hexdigest(),
            )

    def test_payload_match_skips_release_when_sqlite_wrapper_differs(self) -> None:
        payload = "a" * 64
        generated = [
            {
                "name": f"map_floor_{floor}.mbtiles",
                "sha256": hashlib.sha256(f"gen-{floor}".encode()).hexdigest(),
                "bytes": 10,
                "payload_sha256": payload,
            }
            for floor in range(4)
        ]
        pinned = [
            {
                "name": f"map_floor_{floor}.mbtiles",
                "sha256": hashlib.sha256(f"pin-{floor}".encode()).hexdigest(),
                "bytes": 11,
                "payload_sha256": payload,
            }
            for floor in range(4)
        ]
        underground = _underground_records(b"same")
        plan = decide_plan(
            live_cache={"id": 3000, "timestamp": "2026-11-18T12:00:00Z"},
            surface_manifest=_surface_manifest(pinned, cache_id=1000),
            underground_manifest=_underground_manifest(underground, cache_id=1000),
            generated_surface=generated,
            generated_underground=underground,
            surface_bundle={"sha256": "cd" * 32, "bytes": 99},
        )
        self.assertEqual(plan["surface"]["action"], "skip")
        self.assertFalse(plan["open_pr"])

    def test_unchanged_content_skips_even_when_the_cache_id_moved(self) -> None:
        records = _surface_records(b"same")
        underground = _underground_records(b"same")
        plan = decide_plan(
            live_cache={"id": 3000, "timestamp": "2026-11-18T12:00:00Z", "scope": "runescape"},
            surface_manifest=_surface_manifest(records, cache_id=1000),
            underground_manifest=_underground_manifest(underground, cache_id=1000),
            generated_surface=records,
            generated_underground=underground,
            surface_bundle={"sha256": "cd" * 32, "bytes": 99},
        )
        self.assertEqual(plan["surface"]["action"], "skip")
        self.assertEqual(plan["underground"]["action"], "skip")
        self.assertFalse(plan["open_pr"])
        self.assertNotIn("surface_manifest", plan)

    def test_changed_surface_writes_a_new_manifest_with_cache_provenance(self) -> None:
        pinned = _surface_records(b"old")
        generated = _surface_records(b"new")
        underground = _underground_records(b"same")
        live = {
            "id": 2615,
            "timestamp": "2026-11-18T11:15:04Z",
            "scope": "runescape",
            "build": 242,
            "xtea_cache_id": 2499,
        }
        plan = decide_plan(
            live_cache=live,
            surface_manifest=_surface_manifest(pinned, cache_id=2499),
            underground_manifest=_underground_manifest(underground, cache_id=2499),
            generated_surface=generated,
            generated_underground=underground,
            surface_bundle={"sha256": "ef" * 32, "bytes": 42},
        )
        self.assertEqual(plan["surface"]["action"], "create")
        self.assertEqual(plan["underground"]["action"], "skip")
        self.assertTrue(plan["open_pr"])
        manifest = plan["surface_manifest"]
        self.assertNotEqual(manifest["release_tag"], plan["surface"]["old_release_tag"])
        self.assertTrue(manifest["release_tag"].startswith("map-assets-v1-"))
        self.assertEqual(manifest["provenance"]["openrs2_cache_id"], 2615)
        self.assertEqual(manifest["provenance"]["openrs2_cache_build"], 242)
        self.assertEqual(manifest["provenance"]["openrs2_xtea_cache_id"], 2499)
        self.assertEqual(
            manifest["provenance"]["openrs2_cache_timestamp"],
            "2026-11-18T11:15:04Z",
        )
        self.assertEqual(manifest["bundle"]["bytes"], 42)
        self.assertIn("OpenRS2 cache id: `2615`", plan["pr_body"])
        self.assertIn("map_floor_0.mbtiles", plan["pr_body"])

    def test_build_underground_manifest_rewrites_urls_onto_the_new_tag(self) -> None:
        records = _underground_records(b"next")
        live = {"id": 9, "timestamp": "2026-01-01T00:00:00Z"}
        previous = _underground_manifest(_underground_records(b"old"), cache_id=1)
        manifest = build_underground_manifest(
            assets=records, live_cache=live, previous=previous
        )
        tag = manifest["release_tag"]
        self.assertTrue(tag.startswith("underground-assets-v1-"))
        self.assertNotEqual(tag, previous["release_tag"])
        self.assertEqual(manifest["provenance"]["candidate"], "010")
        self.assertEqual(manifest["provenance"]["openrs2_cache_id"], 9)
        for asset in manifest["assets"]:
            self.assertEqual(asset["name"], github_name_from_path(asset["path"]))
            self.assertTrue(asset["url"].endswith("/" + asset["name"]))
            self.assertIn(tag, asset["url"])

    def test_surface_records_from_directory_hash_each_floor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payloads = {}
            for floor in range(4):
                payload = f"floor-{floor}\n".encode()
                (root / f"map_floor_{floor}.mbtiles").write_bytes(payload)
                payloads[floor] = payload
            records = surface_records_from_directory(root)
            self.assertEqual([item["name"] for item in records], [
                "map_floor_0.mbtiles",
                "map_floor_1.mbtiles",
                "map_floor_2.mbtiles",
                "map_floor_3.mbtiles",
            ])
            self.assertEqual(
                records[0]["sha256"], hashlib.sha256(payloads[0]).hexdigest()
            )

    def test_underground_records_from_directory_flatten_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested = root / "assets" / "cache-world-map-fixture"
            nested.mkdir(parents=True)
            (root / "underground-realms.json").write_bytes(b'{"ok":true}\n')
            (nested / "plane-0.mbtiles").write_bytes(b"tiles\n")
            records = underground_records_from_directory(root)
            paths = [item["path"] for item in records]
            self.assertEqual(
                paths,
                [
                    "underground-realms.json",
                    "assets/cache-world-map-fixture/plane-0.mbtiles",
                ],
            )
            self.assertEqual(
                records[1]["name"],
                "assets__cache-world-map-fixture__plane-0.mbtiles",
            )

    def test_build_surface_manifest_keeps_member_order(self) -> None:
        assets = _surface_records(b"pin")
        manifest = build_surface_manifest(
            assets=assets,
            bundle_sha256="11" * 32,
            bundle_bytes=8,
            live_cache={"id": 5, "timestamp": "t", "scope": "runescape"},
        )
        self.assertEqual(
            [item["name"] for item in manifest["assets"]],
            [
                "map_floor_0.mbtiles",
                "map_floor_1.mbtiles",
                "map_floor_2.mbtiles",
                "map_floor_3.mbtiles",
            ],
        )
        self.assertEqual(manifest["bundle"]["members"], [item["name"] for item in assets])

    def test_evaluate_region_load_stats_allows_small_fallback(self) -> None:
        evaluation = evaluate_region_load_stats(
            {
                "regions_loaded": 2952,
                "locations_loaded": 2940,
                "terrain_only_fallback": 2,
                "unnamed_xtea_applied": 0,
                "unnamed_xtea_keys_available": 2500,
                "fallback_region_ids": [18, 148],
            },
            max_fallback=8,
        )
        self.assertTrue(evaluation["ok"])
        self.assertEqual(evaluation["terrain_only_fallback"], 2)

    def test_evaluate_region_load_stats_fails_closed_over_threshold(self) -> None:
        evaluation = evaluate_region_load_stats(
            {
                "regions_loaded": 2952,
                "locations_loaded": 10,
                "terrain_only_fallback": 200,
                "unnamed_xtea_applied": 0,
                "fallback_region_ids": [1, 2, 3],
            },
            max_fallback=8,
        )
        self.assertFalse(evaluation["ok"])
        self.assertEqual(evaluation["fallback_region_ids"], [1, 2, 3])

    def test_evaluate_region_load_stats_rejects_missing_keys(self) -> None:
        with self.assertRaises(MapAutoUpdateError):
            evaluate_region_load_stats({"regions_loaded": 1})

    def test_region_stats_cli_exits_2_when_fallback_exceeds_threshold(self) -> None:
        from osrs_map_auto_update import main as helper_main

        with tempfile.TemporaryDirectory() as directory:
            stats_path = Path(directory) / "region-load-stats.json"
            stats_path.write_text(
                json.dumps(
                    {
                        "regions_loaded": 100,
                        "locations_loaded": 1,
                        "terrain_only_fallback": 50,
                        "unnamed_xtea_applied": 0,
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                helper_main(
                    [
                        "region-stats",
                        "--stats",
                        str(stats_path),
                        "--max-fallback",
                        "8",
                    ]
                ),
                2,
            )


if __name__ == "__main__":
    unittest.main()
