#!/usr/bin/env python3
"""Generate a reproducible OSRS Wiki random-link routing audit manifest."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable


API_URL = "https://oldschool.runescape.wiki/api.php"
DEFAULT_USER_AGENT = "OSRSWiki iOS random link routing audit/2026-07-08"
TRUSTED_HOSTS = {"oldschool.runescape.wiki", "runescape.wiki"}
EXCLUDED_ARTICLE_PREFIXES = ("file:", "media:", "special:")


@dataclass(frozen=True)
class Link:
    text: str
    href: str


class AnchorParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[Link] = []
        self._href_stack: list[str | None] = []
        self._text_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            if self._href_stack:
                self._text_parts.append(self.get_starttag_text() or "")
            return

        href = None
        for name, value in attrs:
            if name.lower() == "href":
                href = value
                break
        self._href_stack.append(href)
        self._text_parts = []

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "a" or not self._href_stack:
            return

        href = self._href_stack.pop()
        text = " ".join("".join(self._text_parts).split())
        self._text_parts = []
        if href:
            self.links.append(Link(text=text, href=html.unescape(href)))

    def handle_data(self, data: str) -> None:
        if self._href_stack:
            self._text_parts.append(data)


def api_get(params: dict[str, Any], raw_path: Path, sleep_seconds: float) -> dict[str, Any]:
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    if raw_path.exists():
        return json.loads(raw_path.read_text(encoding="utf-8"))

    encoded = urllib.parse.urlencode(params)
    request = urllib.request.Request(
        f"{API_URL}?{encoded}",
        headers={"User-Agent": DEFAULT_USER_AGENT},
    )
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                body = response.read()
            raw_path.write_bytes(body)
            time.sleep(sleep_seconds)
            return json.loads(body.decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last_error = exc
            time.sleep(1.5 * (attempt + 1))

    raise RuntimeError(f"API request failed after retries: {params!r}: {last_error}")


def wiki_title_to_url(title: str) -> str:
    path_title = title.replace(" ", "_")
    return "https://oldschool.runescape.wiki/w/" + urllib.parse.quote(path_title, safe="/:_-().,%")


def source_app_base(title: str) -> str:
    path_title = title.replace(" ", "_")
    return "app-assets://localhost/w/" + urllib.parse.quote(path_title, safe="/:_-().,%")


def normalize_href(href: str, base: str) -> str:
    return urllib.parse.urljoin(base, href)


def path_article_name(path: str) -> str:
    if not path.startswith("/w/"):
        return ""
    return urllib.parse.unquote(path[3:]).lower()


def is_trusted_article_url(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    scheme = parsed.scheme.lower()
    host = (parsed.hostname or "").lower()
    if scheme == "https" and host in TRUSTED_HOSTS:
        article_name = path_article_name(parsed.path)
        return bool(article_name) and not article_name.startswith(EXCLUDED_ARTICLE_PREFIXES)
    if scheme == "app-assets" and host == "localhost":
        article_name = path_article_name(parsed.path)
        return bool(article_name) and not article_name.startswith(EXCLUDED_ARTICLE_PREFIXES)
    return False


def expected_classification(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    article_name = path_article_name(parsed.path)
    if is_trusted_article_url(url):
        return "app_article_viewer"
    if article_name.startswith(EXCLUDED_ARTICLE_PREFIXES):
        return "allowed_external_or_special"
    return "allowed_external_or_special"


def forced_cases() -> list[dict[str, Any]]:
    source_title = "Forced edge case corpus"
    source_url = "https://oldschool.runescape.wiki/w/Old_School_RuneScape_Wiki"
    cases = [
        ("Home/news article path", "Update:The_Blood_Moon_Rises", "/w/Update:The_Blood_Moon_Rises", "app-assets://localhost/w/Update:The_Blood_Moon_Rises"),
        ("The Blood Moon Rises", "The Blood Moon Rises", "/w/The_Blood_Moon_Rises", "app-assets://localhost/w/The_Blood_Moon_Rises"),
        ("The Blood Moon Rises quick guide", "Quick guide", "/w/The_Blood_Moon_Rises/Quick_guide", "app-assets://localhost/w/The_Blood_Moon_Rises/Quick_guide"),
        ("app-assets relative /w link", "Quest guide", "/w/Quest_guide", "app-assets://localhost/w/Quest_guide"),
        ("oldschool absolute /w link", "Varrock", "https://oldschool.runescape.wiki/w/Varrock", "https://oldschool.runescape.wiki/w/Varrock"),
        ("runescape.wiki alias", "RuneScape Wiki alias", "https://runescape.wiki/w/Old_School_RuneScape", "https://runescape.wiki/w/Old_School_RuneScape"),
        ("file page", "File page", "/w/File:Blood_Moon.png", "app-assets://localhost/w/File:Blood_Moon.png"),
        ("media page", "Media page", "/w/Media:Blood_Moon.png", "app-assets://localhost/w/Media:Blood_Moon.png"),
        ("special page", "Special page", "/w/Special:RandomRootpage/main", "app-assets://localhost/w/Special:RandomRootpage/main"),
        ("fragment link", "Quest guide rewards", "/w/Quest_guide#Rewards", "app-assets://localhost/w/Quest_guide#Rewards"),
        ("query link", "Varrock oldid", "/w/Varrock?oldid=14443131", "app-assets://localhost/w/Varrock?oldid=14443131"),
        ("redirect-like title", "Strength potion", "/w/Strength_potion", "app-assets://localhost/w/Strength_potion"),
        ("percent encoded title", "Recipe for Disaster/Freeing Evil Dave", "/w/Recipe_for_Disaster%2FFreeing_Evil_Dave", "app-assets://localhost/w/Recipe_for_Disaster%2FFreeing_Evil_Dave"),
        ("non-wiki external", "RuneScape news", "https://secure.runescape.com/m=news", "https://secure.runescape.com/m=news"),
        ("lookalike external", "Lookalike host", "https://oldschool.runescape.wiki.evil/w/Varrock", "https://oldschool.runescape.wiki.evil/w/Varrock"),
    ]
    rows = []
    for label, text, raw_href, normalized in cases:
        rows.append(
            {
                "source_kind": "forced_edge_case",
                "source_page_title": source_title,
                "source_page_url": source_url,
                "source_page_id": None,
                "link_text": text,
                "raw_href": raw_href,
                "normalized_destination": normalized,
                "expected_classification": expected_classification(normalized),
                "edge_case": label,
            }
        )
    return rows


def random_page_batches(seed: int, raw_dir: Path, sleep_seconds: float) -> Iterable[dict[str, Any]]:
    rng = random.Random(seed)
    batch = 0
    seen_page_ids: set[int] = set()
    while True:
        batch += 1
        params = {
            "action": "query",
            "format": "json",
            "list": "random",
            "rnnamespace": "0",
            "rnlimit": "50",
            "origin": "*",
            "requestid": f"ios-random-link-routing-audit-{seed}-{batch}-{rng.randrange(1_000_000_000)}",
        }
        raw_path = raw_dir / f"random-pages-{batch:04d}.json"
        data = api_get(params, raw_path, sleep_seconds)
        for page in data.get("query", {}).get("random", []):
            page_id = int(page["id"])
            if page_id not in seen_page_ids:
                seen_page_ids.add(page_id)
                yield {"pageid": page_id, "title": page["title"], "batch": batch}


def parse_page(page: dict[str, Any], raw_dir: Path, sleep_seconds: float) -> list[Link]:
    params = {
        "action": "parse",
        "format": "json",
        "prop": "text|displaytitle|revid",
        "disablelimitreport": "1",
        "wrapoutputclass": "mw-parser-output",
        "pageid": str(page["pageid"]),
        "origin": "*",
    }
    raw_path = raw_dir / "parse" / f"page-{page['pageid']}.json"
    data = api_get(params, raw_path, sleep_seconds)
    text = data.get("parse", {}).get("text", {}).get("*", "")
    parser = AnchorParser()
    parser.feed(text)
    return parser.links


def stable_id(row: dict[str, Any]) -> str:
    digest = hashlib.sha256(
        json.dumps(
            [
                row.get("source_page_url"),
                row.get("raw_href"),
                row.get("normalized_destination"),
                row.get("link_text"),
            ],
            sort_keys=True,
            ensure_ascii=False,
        ).encode("utf-8")
    ).hexdigest()
    return digest[:16]


def generate_manifest(args: argparse.Namespace) -> dict[str, Any]:
    evidence_root = Path(args.evidence_root)
    raw_dir = evidence_root / "raw-api"
    manifest_path = evidence_root / "sample-manifest.jsonl"
    metadata_path = evidence_root / "sample-metadata.json"
    target = args.target

    rows: list[dict[str, Any]] = []
    seen_keys: set[tuple[str, str, str]] = set()
    duplicate_candidates = 0

    def add_row(row: dict[str, Any]) -> None:
        nonlocal duplicate_candidates
        key = (
            str(row.get("source_page_url", "")),
            str(row.get("raw_href", "")),
            str(row.get("normalized_destination", "")),
        )
        if key in seen_keys:
            duplicate_candidates += 1
            return
        seen_keys.add(key)
        row["sample_id"] = stable_id(row)
        row["sequence"] = len(rows) + 1
        rows.append(row)

    for row in forced_cases():
        add_row(row)

    pages_scanned = 0
    candidate_links = 0
    for page in random_page_batches(args.seed, raw_dir, args.sleep_seconds):
        if len(rows) >= target:
            break
        pages_scanned += 1
        source_title = page["title"]
        source_url = wiki_title_to_url(source_title)
        base = source_app_base(source_title)
        try:
            links = parse_page(page, raw_dir, args.sleep_seconds)
        except RuntimeError as exc:
            add_row(
                {
                    "source_kind": "random_api_page",
                    "source_page_title": source_title,
                    "source_page_url": source_url,
                    "source_page_id": page["pageid"],
                    "link_text": "",
                    "raw_href": "",
                    "normalized_destination": "",
                    "expected_classification": "blocked_environmental",
                    "edge_case": f"parse_failed:{exc}",
                }
            )
            continue

        for link in links:
            if len(rows) >= target:
                break
            href = link.href.strip()
            if not href or href.startswith("#") or href.lower().startswith("javascript:"):
                continue
            candidate_links += 1
            normalized = normalize_href(href, base)
            add_row(
                {
                    "source_kind": "random_api_page",
                    "source_page_title": source_title,
                    "source_page_url": source_url,
                    "source_page_id": page["pageid"],
                    "link_text": link.text,
                    "raw_href": href,
                    "normalized_destination": normalized,
                    "expected_classification": expected_classification(normalized),
                    "edge_case": None,
                }
            )

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, ensure_ascii=False) + "\n")

    metadata = {
        "seed": args.seed,
        "target": target,
        "sample_count_total": len(rows),
        "sample_count_distinct_tested": len(rows),
        "pages_scanned": pages_scanned,
        "candidate_links_seen": candidate_links,
        "duplicate_candidates_skipped": duplicate_candidates,
        "manifest_path": str(manifest_path),
        "raw_api_dir": str(raw_dir),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-root", required=True)
    parser.add_argument("--target", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=20260708)
    parser.add_argument("--sleep-seconds", type=float, default=0.03)
    args = parser.parse_args()

    metadata = generate_manifest(args)
    print(json.dumps(metadata, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
