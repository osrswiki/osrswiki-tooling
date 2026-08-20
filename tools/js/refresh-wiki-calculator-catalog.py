#!/usr/bin/env python3
"""Refresh the bundled OSRS wiki calculator catalog from live allpages ns=116."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from wiki_calculator_catalog import build_catalog, fetch_all_calculator_pages

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "shared" / "manifests" / "osrs-wiki-calculators.json"
PLATFORM_COPIES = (
    ROOT / "platforms" / "android" / "app" / "src" / "main" / "assets" / "manifests" / "osrs-wiki-calculators.json",
    ROOT / "platforms" / "ios" / "osrswiki" / "Assets" / "manifests" / "osrs-wiki-calculators.json",
)


def main() -> int:
    pages = fetch_all_calculator_pages()
    catalog = build_catalog(pages)
    payload = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"
    DEST.parent.mkdir(parents=True, exist_ok=True)
    DEST.write_text(payload, encoding="utf-8")
    for copy in PLATFORM_COPIES:
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_text(payload, encoding="utf-8")
    print(
        f"Wrote {DEST} with {catalog['calculator_count']} calculators "
        f"({catalog['excluded_count']} excluded templates/docs)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
