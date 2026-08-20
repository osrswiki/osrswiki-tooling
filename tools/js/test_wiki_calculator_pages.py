#!/usr/bin/env python3
"""Live contract: every hosted wiki calculator still parses with default inputs."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from wiki_calculator_catalog import (
    WIKI_ORIGIN,
    build_catalog,
    default_template_call,
    fetch_all_calculator_pages,
    first_jcconfig,
    is_user_facing_calculator,
)

ROOT = Path(__file__).resolve().parents[2]
SNAPSHOT = ROOT / "shared" / "manifests" / "osrs-wiki-calculators.json"
API = f"{WIKI_ORIGIN}/api.php"
USER_AGENT = "osrswiki-calculator-parity/1.0"


def _get(params: dict) -> dict:
    url = f"{API}?{urlencode(params)}"
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def _post(params: dict) -> dict:
    body = urlencode(params).encode("utf-8")
    request = Request(
        API,
        data=body,
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
    )
    with urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_wikitext(titles: list[str]) -> dict[str, str]:
    contents: dict[str, str] = {}
    for index in range(0, len(titles), 40):
        batch = titles[index : index + 40]
        payload = _get(
            {
                "action": "query",
                "prop": "revisions",
                "rvprop": "content",
                "rvslots": "main",
                "titles": "|".join(batch),
                "format": "json",
            }
        )
        pages = payload.get("query", {}).get("pages", {})
        for page in pages.values():
            title = page.get("title") or ""
            revisions = page.get("revisions") or []
            if not revisions:
                contents[title] = ""
                continue
            slot = revisions[0].get("slots", {}).get("main", {})
            contents[title] = slot.get("*") or ""
    return contents


def parse_wikitext(wikitext: str, title: str) -> dict:
    params = {
        "action": "parse",
        "text": wikitext,
        "prop": "text",
        "title": title,
        "disablelimitreport": "true",
        "contentmodel": "wikitext",
        "format": "json",
    }
    if len(wikitext) > 1900:
        return _post(params)
    return _get(params)


class LiveWikiCalculatorPagesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.live_pages = fetch_all_calculator_pages()
        cls.live_catalog = build_catalog(cls.live_pages)
        cls.snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))

    def test_live_namespace_matches_user_facing_classifier(self) -> None:
        live_titles = {page["title"] for page in self.live_pages}
        user_facing = {title for title in live_titles if is_user_facing_calculator(title)}
        catalog_titles = {entry["title"] for entry in self.live_catalog["calculators"]}
        self.assertEqual(user_facing, catalog_titles)
        self.assertGreaterEqual(len(catalog_titles), 100)

    def test_bundled_snapshot_is_not_missing_live_calculators(self) -> None:
        snapshot_titles = {entry["title"] for entry in self.snapshot["calculators"]}
        live_titles = {entry["title"] for entry in self.live_catalog["calculators"]}
        missing = sorted(live_titles - snapshot_titles)
        self.assertEqual(
            missing,
            [],
            "Refresh shared/manifests/osrs-wiki-calculators.json; live wiki added calculators",
        )

    def test_every_hosted_calculator_has_parseable_default_or_documented_form(self) -> None:
        titles = [entry["title"] for entry in self.live_catalog["calculators"]]
        wikitext_by_title = fetch_wikitext(titles)
        failures: list[str] = []
        missing_form: list[str] = []
        for title in titles:
            source = wikitext_by_title.get(title, "")
            if not source:
                failures.append(f"{title}: empty wikitext")
                continue
            if first_jcconfig(source) is None:
                parsed_page = _get(
                    {
                        "action": "parse",
                        "page": title,
                        "prop": "text",
                        "disablelimitreport": "true",
                        "format": "json",
                    }
                )
                source = ((parsed_page.get("parse") or {}).get("text") or {}).get("*") or ""
            if first_jcconfig(source) is None:
                missing_form.append(title)
                if not source.strip():
                    failures.append(f"{title}: page parse failed")
                continue
            call = default_template_call(source)
            if not call:
                failures.append(f"{title}: jcConfig present but default template call missing")
                continue
            parsed = parse_wikitext(call, title)
            html = ((parsed.get("parse") or {}).get("text") or {}).get("*") or ""
            if "error" in parsed or not html.strip():
                failures.append(f"{title}: default template parse failed")
        self.assertEqual(failures, [])
        self.assertLess(
            len(missing_form),
            max(70, len(titles) // 2),
            f"Unexpectedly many calculators lack jcConfig: {missing_form[:12]}",
        )


if __name__ == "__main__":
    sys.exit(unittest.main())
