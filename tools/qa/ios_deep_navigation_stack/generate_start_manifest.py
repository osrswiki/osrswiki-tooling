#!/usr/bin/env python3
"""Generate deterministic random OSRS Wiki start pages for iOS deep-stack audits."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


API_URL = "https://oldschool.runescape.wiki/api.php"
USER_AGENT = "OSRSWiki iOS deep navigation stack audit/2026-07-09"


FORCED_STARTS = [
    {
        "source_kind": "forced_edge_case",
        "edge_case": "Blood Moon update to quest quick guide",
        "title": "The Blood Moon Rises",
        "url": "https://oldschool.runescape.wiki/w/The_Blood_Moon_Rises",
        "required_link_text": "quick guide",
    },
    {
        "source_kind": "forced_edge_case",
        "edge_case": "Blood Moon explicit quick guide destination",
        "title": "The Blood Moon Rises/Quick guide",
        "url": "https://oldschool.runescape.wiki/w/The_Blood_Moon_Rises/Quick_guide",
    },
    {
        "source_kind": "forced_edge_case",
        "edge_case": "Prior alias/routing edge case",
        "title": "Old School RuneScape",
        "url": "https://runescape.wiki/w/Old_School_RuneScape",
    },
    {
        "source_kind": "forced_edge_case",
        "edge_case": "Fragment link source page",
        "title": "Quest guide",
        "url": "https://oldschool.runescape.wiki/w/Quest_guide#Rewards",
    },
    {
        "source_kind": "forced_edge_case",
        "edge_case": "Slash-containing title",
        "title": "Recipe for Disaster/Freeing Evil Dave",
        "url": "https://oldschool.runescape.wiki/w/Recipe_for_Disaster/Freeing_Evil_Dave",
    },
]


def wiki_title_to_url(title: str) -> str:
    encoded = urllib.parse.quote(title.replace(" ", "_"), safe="/:_-().,%")
    return f"https://oldschool.runescape.wiki/w/{encoded}"


def stable_id(seed: int, sequence: int, title: str, url: str) -> str:
    digest = hashlib.sha256(f"{seed}\n{sequence}\n{title}\n{url}".encode("utf-8")).hexdigest()
    return digest[:16]


def api_get(params: dict[str, Any], raw_path: Path, sleep_seconds: float) -> dict[str, Any]:
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    if raw_path.exists():
        return json.loads(raw_path.read_text(encoding="utf-8"))

    request = urllib.request.Request(
        f"{API_URL}?{urllib.parse.urlencode(params)}",
        headers={"User-Agent": USER_AGENT},
    )
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                body = response.read()
            raw_path.write_bytes(body)
            time.sleep(sleep_seconds)
            return json.loads(body.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001 - keep retry diagnostics simple for audit artifacts.
            last_error = exc
            time.sleep(1.5 * (attempt + 1))

    raise RuntimeError(f"API request failed after retries: {params!r}: {last_error}")


def generate(args: argparse.Namespace) -> dict[str, Any]:
    evidence_root = Path(args.evidence_root)
    manifest_path = evidence_root / "manifests" / "start-points.jsonl"
    metadata_path = evidence_root / "manifests" / "start-points-metadata.json"
    raw_dir = evidence_root / "raw-api"
    rng = random.Random(args.seed)

    rows: list[dict[str, Any]] = []
    seen_titles: set[str] = set()

    def add_row(row: dict[str, Any]) -> None:
        title = row["title"]
        if title in seen_titles:
            return
        seen_titles.add(title)
        sequence = len(rows) + 1
        row = dict(row)
        row["sequence"] = sequence
        row["sample_id"] = stable_id(args.seed, sequence, row["title"], row["url"])
        rows.append(row)

    for forced in FORCED_STARTS:
        add_row(forced)

    batch = 0
    while len(rows) < args.count:
        batch += 1
        params = {
            "action": "query",
            "format": "json",
            "list": "random",
            "rnnamespace": "0",
            "rnlimit": "50",
            "origin": "*",
            "requestid": f"ios-deep-navigation-stack-{args.seed}-{batch}-{rng.randrange(1_000_000_000)}",
        }
        data = api_get(params, raw_dir / f"random-starts-{batch:04d}.json", args.sleep_seconds)
        for page in data.get("query", {}).get("random", []):
            if len(rows) >= args.count:
                break
            title = str(page["title"])
            add_row(
                {
                    "source_kind": "random_start",
                    "batch": batch,
                    "page_id": int(page["id"]),
                    "title": title,
                    "url": wiki_title_to_url(title),
                }
            )

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, ensure_ascii=False) + "\n")

    metadata = {
        "seed": args.seed,
        "requested_count": args.count,
        "written_count": len(rows),
        "forced_count": sum(1 for row in rows if row["source_kind"] == "forced_edge_case"),
        "random_count": sum(1 for row in rows if row["source_kind"] == "random_start"),
        "manifest": str(manifest_path),
    }
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-root", required=True)
    parser.add_argument("--seed", type=int, default=20260709)
    parser.add_argument("--count", type=int, default=10000)
    parser.add_argument("--sleep-seconds", type=float, default=0.05)
    args = parser.parse_args()
    print(json.dumps(generate(args), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
