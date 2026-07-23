#!/usr/bin/env python3
"""Generate and validate the Android random link routing audit manifest.

The sampler caches OSRS Wiki API responses, extracts broad random page links,
adds forced edge cases, and classifies each navigation against the Android
LinkHandler route contract.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html.parser
import json
import random
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


WIKI_BASE = "https://oldschool.runescape.wiki"
API_URL = f"{WIKI_BASE}/api.php"
DEFAULT_SEED = 20260708
DEFAULT_TARGET = 10_000
STORAGE_HELPER = Path(__file__).resolve().parents[1] / "shared" / "local-artifact-root.sh"
USER_AGENT = "OSRSWikiAndroidRandomLinkAudit/2026-07-08 (local QA; contact: app developer)"


def default_output_dir() -> Path:
    lane_id = os.environ.get("OSRS_LANE_ID", "android-random-link-routing-audit")
    output = subprocess.check_output(
        [str(STORAGE_HELPER), "path", "active", lane_id, "audit-output"],
        text=True,
        env=os.environ,
    )
    return Path(output.strip())


def validated_output_dir(path: Path) -> Path:
    output = subprocess.check_output(
        [str(STORAGE_HELPER), "validate-path", str(path.resolve())],
        text=True,
        env=os.environ,
    )
    return Path(output.strip())

SPECIAL_NAMESPACES = {
    "category",
    "file",
    "help",
    "image",
    "media",
    "mediawiki",
    "module",
    "project",
    "runescape",
    "special",
    "talk",
    "template",
    "user",
    "user talk",
    "wikipedia",
}


class LinkExtractor(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[dict[str, str]] = []
        self._current: dict[str, str] | None = None
        self._text_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        attr_map = {name.lower(): value or "" for name, value in attrs}
        href = attr_map.get("href")
        if not href:
            return
        self._current = {"href": href}
        self._text_parts = []

    def handle_data(self, data: str) -> None:
        if self._current is not None:
            self._text_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "a" or self._current is None:
            return
        text = " ".join("".join(self._text_parts).split())
        self._current["text"] = text
        self.links.append(self._current)
        self._current = None
        self._text_parts = []


@dataclass(frozen=True)
class RouteResult:
    actual_route: str
    actual_article_title: str | None
    normalized_after_app: str


def api_get(cache_path: Path, params: dict[str, Any]) -> dict[str, Any]:
    if cache_path.exists():
        return json.loads(cache_path.read_text(encoding="utf-8"))

    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(f"{API_URL}?{query}", headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                body = response.read().decode("utf-8")
            payload = json.loads(body)
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            return payload
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt == 3:
                raise RuntimeError(f"API request failed after retries: {params}") from exc
            time.sleep(1.5 * (attempt + 1))

    raise AssertionError("unreachable")


def random_pages(cache_dir: Path, batches: int, limit: int) -> list[dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    seen: set[int] = set()
    for batch in range(batches):
        payload = api_get(
            cache_dir / "api-random-pages" / f"batch-{batch:04d}.json",
            {
                "action": "query",
                "format": "json",
                "list": "random",
                "rnnamespace": 0,
                "rnlimit": limit,
            },
        )
        for page in payload.get("query", {}).get("random", []):
            page_id = int(page["id"])
            if page_id in seen:
                continue
            seen.add(page_id)
            pages.append(page)
    return pages


def parse_page(cache_dir: Path, page_id: int, title: str) -> dict[str, Any]:
    return api_get(
        cache_dir / "api-parse-pages" / f"{page_id}.json",
        {
            "action": "parse",
            "format": "json",
            "pageid": page_id,
            "prop": "text|displaytitle|revid|categories",
            "redirects": 1,
            "disablelimitreport": 1,
        },
    )


def source_url_for_title(title: str) -> str:
    return f"{WIKI_BASE}/w/{title.replace(' ', '_')}"


def normalize_destination(source_url: str, href: str) -> str:
    return urllib.parse.urljoin(source_url, href.strip())


def decoded_title(value: str) -> str:
    return urllib.parse.unquote(value).replace("_", " ")


def first_title_namespace(title: str) -> str | None:
    if ":" not in title:
        return None
    return title.split(":", 1)[0].replace("_", " ").lower()


def is_article_title(title: str | None) -> bool:
    if not title or not title.strip():
        return False
    namespace = first_title_namespace(title)
    return namespace not in SPECIAL_NAMESPACES


def title_from_destination(url: str) -> str | None:
    parsed = urllib.parse.urlparse(url)
    path = urllib.parse.unquote(parsed.path or "")
    query = urllib.parse.parse_qs(parsed.query)

    for prefix in ("/w/", "/wiki/"):
        if path.startswith(prefix) and len(path) > len(prefix):
            return decoded_title(path[len(prefix) :])

    if path == "/index.php" and query.get("title"):
        return decoded_title(query["title"][0])

    return None


def expected_classification(url: str) -> tuple[str, str]:
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    path = urllib.parse.unquote(parsed.path or "")
    query = urllib.parse.parse_qs(parsed.query)
    title = title_from_destination(url)

    if host != "oldschool.runescape.wiki":
        if host.endswith("runescape.wiki") and title:
            return (
                "allowed_external_or_special",
                "Current Android policy only trusts oldschool.runescape.wiki; alias hosts are recorded as unsupported external navigations.",
            )
        return ("allowed_external_or_special", "Non-OSRS-Wiki destination may remain external.")

    if path.startswith("/images/") or path.startswith("/thumb/"):
        return ("allowed_external_or_special", "Media asset URL may remain outside the app article viewer.")

    action = (query.get("action") or ["view"])[0]
    if action != "view":
        return ("allowed_external_or_special", f"Wiki action={action} is not a normal article view.")

    if title and is_article_title(title):
        return ("app_article_viewer", "Trusted OSRS Wiki article link should route to PageActivity.")

    return ("allowed_external_or_special", "Special, file, media, or non-article wiki link may remain external/special.")


def android_route(url: str) -> RouteResult:
    parsed = urllib.parse.urlparse(url)
    normalized = url

    if not parsed.scheme:
        if url.startswith("//"):
            normalized = f"https:{url}"
        elif (parsed.path or "").startswith(("/w/", "/wiki/", "/index.php")):
            normalized = urllib.parse.urlunparse(
                ("https", "oldschool.runescape.wiki", parsed.path, "", parsed.query, parsed.fragment)
            )
        parsed = urllib.parse.urlparse(normalized)

    host = (parsed.hostname or "").lower()
    if host != "oldschool.runescape.wiki":
        return RouteResult("external", None, normalized)

    path = urllib.parse.unquote(parsed.path or "")
    query = urllib.parse.parse_qs(parsed.query)
    action = (query.get("action") or ["view"])[0]
    if action != "view":
        return RouteResult("external", None, normalized)

    title: str | None = None
    if path.startswith("/w/") and len(path) > len("/w/"):
        title = path[len("/w/") :]
    elif path.startswith("/wiki/") and len(path) > len("/wiki/"):
        title = path[len("/wiki/") :]
    elif path == "/index.php" and query.get("title"):
        title = query["title"][0]

    if title and is_article_title(title):
        return RouteResult("app_article_viewer", decoded_title(title), normalized)
    return RouteResult("external", None, normalized)


def outcome_for(expected: str, route: RouteResult) -> str:
    if route.actual_route == "app_article_viewer" and expected == "app_article_viewer":
        return "app_article_viewer"
    if route.actual_route == "external" and expected == "allowed_external_or_special":
        return "allowed_external_or_special"
    if route.actual_route == "external" and expected == "app_article_viewer":
        return "broken_external_escape"
    return "navigation_error"


def forced_cases() -> list[dict[str, str]]:
    source_title = "FORCED_PRIOR_EDGE_CASES"
    source_url = source_url_for_title(source_title)
    return [
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "The Blood Moon Rises", "raw_href": "/w/The_Blood_Moon_Rises", "forced_case": "blood_moon"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "The Blood Moon Rises/Quick guide", "raw_href": "/w/The_Blood_Moon_Rises/Quick_guide", "forced_case": "blood_moon_quick_guide"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "relative /w link", "raw_href": "/w/Abyssal_whip", "forced_case": "relative_w"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "oldschool /w", "raw_href": "https://oldschool.runescape.wiki/w/Dragon_scimitar", "forced_case": "oldschool_w"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "legacy /wiki article path", "raw_href": "https://oldschool.runescape.wiki/wiki/Zulrah", "forced_case": "oldschool_wiki_path"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "index.php title", "raw_href": "https://oldschool.runescape.wiki/index.php?title=Vorkath", "forced_case": "index_php_title"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "runescape wiki alias", "raw_href": "https://runescape.wiki/w/RuneScape:About", "forced_case": "runescape_wiki_alias"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "file page", "raw_href": "https://oldschool.runescape.wiki/w/File:Abyssal_whip_detail.png", "forced_case": "file_page"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "media asset", "raw_href": "https://oldschool.runescape.wiki/images/Abyssal_whip_detail.png", "forced_case": "media_asset"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "special page", "raw_href": "https://oldschool.runescape.wiki/w/Special:Random", "forced_case": "special_page"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "fragment", "raw_href": "/w/Barrows#Rewards", "forced_case": "fragment"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "query", "raw_href": "/index.php?title=Barrows&oldid=1", "forced_case": "query_oldid"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "percent encoded", "raw_href": "/w/Dragon%20scimitar", "forced_case": "percent_encoded"},
        {"source_page_id": "forced", "source_page_title": source_title, "source_page_url": source_url, "link_text": "external", "raw_href": "https://www.jagex.com/en-GB/", "forced_case": "external_jagex"},
    ]


def make_record(index: int, raw: dict[str, str], raw_href: str, source_url: str) -> dict[str, Any]:
    normalized = normalize_destination(source_url, raw_href)
    expected, reason = expected_classification(normalized)
    route = android_route(normalized)
    outcome = outcome_for(expected, route)
    return {
        "sample_id": f"android-random-link-{index:05d}",
        "source_page_id": raw.get("source_page_id"),
        "source_page_title": raw.get("source_page_title"),
        "source_page_url": source_url,
        "link_text": raw.get("link_text", ""),
        "raw_href": raw_href,
        "normalized_destination": normalized,
        "routing_input": normalized,
        "expected_classification": expected,
        "expected_reason": reason,
        "actual_route": route.actual_route,
        "actual_article_title": route.actual_article_title,
        "app_normalized_uri": route.normalized_after_app,
        "test_outcome": outcome,
        "forced_case": raw.get("forced_case"),
    }


def generate(args: argparse.Namespace) -> None:
    out_dir = validated_output_dir(Path(args.output))
    cache_dir = out_dir / "raw-api"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "logs").mkdir(parents=True, exist_ok=True)

    rng = random.Random(args.seed)
    records: list[dict[str, Any]] = []
    seen_destinations: set[str] = set()
    raw_candidates = 0

    def add_candidate(candidate: dict[str, str]) -> None:
        nonlocal raw_candidates
        raw_candidates += 1
        source_url = candidate["source_page_url"]
        raw_href = candidate["raw_href"]
        normalized = normalize_destination(source_url, raw_href)
        if normalized in seen_destinations:
            return
        seen_destinations.add(normalized)
        records.append(make_record(len(records) + 1, candidate, raw_href, source_url))

    for case in forced_cases():
        add_candidate(case)

    pages = random_pages(cache_dir, batches=args.random_batches, limit=args.random_batch_size)
    rng.shuffle(pages)

    for page in pages:
        if len(records) >= args.target:
            break
        page_id = int(page["id"])
        title = str(page["title"])
        source_url = source_url_for_title(title)
        try:
            payload = parse_page(cache_dir, page_id, title)
        except Exception as exc:
            blocked = {
                "sample_id": f"android-random-link-{len(records) + 1:05d}",
                "source_page_id": page_id,
                "source_page_title": title,
                "source_page_url": source_url,
                "link_text": "",
                "raw_href": "",
                "normalized_destination": "",
                "routing_input": "",
                "expected_classification": "blocked_environmental",
                "expected_reason": f"API parse blocked: {exc}",
                "actual_route": "blocked_environmental",
                "actual_article_title": None,
                "app_normalized_uri": "",
                "test_outcome": "blocked_environmental",
                "forced_case": None,
            }
            records.append(blocked)
            continue

        html = payload.get("parse", {}).get("text", {}).get("*", "")
        extractor = LinkExtractor()
        extractor.feed(html)
        links = extractor.links
        rng.shuffle(links)
        for link in links:
            if len(records) >= args.target:
                break
            href = link["href"]
            if href.startswith(("#", "javascript:", "mailto:", "tel:")):
                continue
            add_candidate(
                {
                    "source_page_id": str(page_id),
                    "source_page_title": title,
                    "source_page_url": source_url,
                    "link_text": link.get("text", ""),
                    "raw_href": href,
                    "forced_case": "",
                }
            )

    if len(records) < args.target:
        raise RuntimeError(f"Only generated {len(records)} distinct samples; target was {args.target}")

    manifest_path = out_dir / "manifest.jsonl"
    with manifest_path.open("w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    csv_path = out_dir / "manifest.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(records[0].keys()))
        writer.writeheader()
        writer.writerows(records)

    summary = summarize(records, raw_candidates, args.seed)
    summary["manifest_sha256"] = sha256_file(manifest_path)
    summary["csv_sha256"] = sha256_file(csv_path)
    (out_dir / "sample-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    (out_dir / "random-seed.txt").write_text(f"{args.seed}\n", encoding="utf-8")
    (out_dir / "api-cache-index.txt").write_text(
        "\n".join(str(path.relative_to(out_dir)) for path in sorted(cache_dir.rglob("*.json"))) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2, sort_keys=True))


def summarize(records: list[dict[str, Any]], raw_candidates: int, seed: int) -> dict[str, Any]:
    outcomes: dict[str, int] = {}
    expected: dict[str, int] = {}
    routes: dict[str, int] = {}
    forced: dict[str, int] = {}
    findings: dict[str, int] = {}
    for record in records:
        outcomes[record["test_outcome"]] = outcomes.get(record["test_outcome"], 0) + 1
        expected[record["expected_classification"]] = expected.get(record["expected_classification"], 0) + 1
        routes[record["actual_route"]] = routes.get(record["actual_route"], 0) + 1
        if record.get("forced_case"):
            forced[record["forced_case"]] = forced.get(record["forced_case"], 0) + 1
        if record["test_outcome"] in {"broken_external_escape", "navigation_error"}:
            key = finding_key(record)
            findings[key] = findings.get(key, 0) + 1
    return {
        "seed": seed,
        "sample_count_total": len(records),
        "sample_count_distinct_tested": len({r["normalized_destination"] for r in records if r["normalized_destination"]}),
        "raw_link_candidates_seen": raw_candidates,
        "outcomes": dict(sorted(outcomes.items())),
        "expected_classifications": dict(sorted(expected.items())),
        "actual_routes": dict(sorted(routes.items())),
        "forced_cases": dict(sorted(forced.items())),
        "finding_families": dict(sorted(findings.items(), key=lambda item: (-item[1], item[0]))),
    }


def finding_key(record: dict[str, Any]) -> str:
    parsed = urllib.parse.urlparse(record["normalized_destination"])
    path = urllib.parse.unquote(parsed.path or "")
    title = title_from_destination(record["normalized_destination"]) or ""
    namespace = first_title_namespace(title) or "(main)"
    if record["test_outcome"] == "broken_external_escape":
        if path.startswith("/wiki/"):
            return "oldschool_wiki_article_path_escapes_external"
        return "trusted_article_escapes_external"
    if namespace != "(main)":
        return f"non_article_namespace_routes_to_article_viewer:{namespace}"
    return "unexpected_article_viewer_route"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate(args: argparse.Namespace) -> None:
    manifest = Path(args.manifest)
    records = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    required = {
        "source_page_title",
        "source_page_url",
        "link_text",
        "raw_href",
        "normalized_destination",
        "expected_classification",
        "test_outcome",
    }
    missing = [record["sample_id"] for record in records if not required.issubset(record)]
    distinct = len({r["normalized_destination"] for r in records if r["normalized_destination"]})
    if missing:
        raise SystemExit(f"Records missing required fields: {missing[:5]}")
    if len(records) < args.min_count:
        raise SystemExit(f"Total sample count {len(records)} is below {args.min_count}")
    if distinct < args.min_count:
        raise SystemExit(f"Distinct tested count {distinct} is below {args.min_count}")
    allowed_outcomes = {
        "app_article_viewer",
        "allowed_external_or_special",
        "broken_external_escape",
        "navigation_error",
        "blocked_environmental",
        "duplicate_skipped",
    }
    bad_outcomes = sorted({r["test_outcome"] for r in records} - allowed_outcomes)
    if bad_outcomes:
        raise SystemExit(f"Unexpected outcomes: {bad_outcomes}")
    print(json.dumps(summarize(records, raw_candidates=len(records), seed=-1), indent=2, sort_keys=True))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate")
    gen.add_argument("--output", default=str(default_output_dir()))
    gen.add_argument("--seed", type=int, default=DEFAULT_SEED)
    gen.add_argument("--target", type=int, default=DEFAULT_TARGET)
    gen.add_argument("--random-batches", type=int, default=80)
    gen.add_argument("--random-batch-size", type=int, default=500)

    val = sub.add_parser("validate")
    val.add_argument("--manifest", required=True)
    val.add_argument("--min-count", type=int, default=DEFAULT_TARGET)

    args = parser.parse_args(argv)
    if args.command == "generate":
        generate(args)
    elif args.command == "validate":
        validate(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
