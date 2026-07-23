#!/usr/bin/env python3
"""Validate generated random-link routing audit artifacts."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


REQUIRED_MANIFEST_FIELDS = {
    "sample_id",
    "sequence",
    "source_page_title",
    "source_page_url",
    "link_text",
    "raw_href",
    "normalized_destination",
    "expected_classification",
}

VALID_CLASSIFICATIONS = {
    "app_article_viewer",
    "allowed_external_or_special",
    "broken_external_escape",
    "navigation_error",
    "blocked_environmental",
    "duplicate_skipped",
}


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {exc}") from exc
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--minimum-distinct", type=int, default=10_000)
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    results_path = Path(args.results)
    summary_path = Path(args.summary)
    manifest = read_jsonl(manifest_path)
    results = read_jsonl(results_path)
    summary = json.loads(summary_path.read_text(encoding="utf-8"))

    if len(manifest) < args.minimum_distinct:
        raise SystemExit(f"manifest has {len(manifest)} rows, below {args.minimum_distinct}")
    if len(results) != len(manifest):
        raise SystemExit(f"results row count {len(results)} != manifest row count {len(manifest)}")

    sample_ids = [row["sample_id"] for row in manifest]
    duplicate_ids = [sample_id for sample_id, count in Counter(sample_ids).items() if count > 1]
    if duplicate_ids:
        raise SystemExit(f"duplicate sample_ids: {duplicate_ids[:10]}")

    for index, row in enumerate(manifest, start=1):
        missing = REQUIRED_MANIFEST_FIELDS - row.keys()
        if missing:
            raise SystemExit(f"manifest row {index} missing fields: {sorted(missing)}")
        if row["expected_classification"] not in VALID_CLASSIFICATIONS:
            raise SystemExit(f"manifest row {index} has invalid expected classification: {row['expected_classification']}")

    for index, row in enumerate(results, start=1):
        observed = row.get("observed_classification")
        if observed not in VALID_CLASSIFICATIONS:
            raise SystemExit(f"result row {index} has invalid observed classification: {observed}")

    if summary.get("sample_count_distinct_tested") != len(manifest):
        raise SystemExit("summary distinct count does not match manifest count")
    if summary.get("deterministic_execution_count") != len(results):
        raise SystemExit("summary deterministic count does not match results count")

    print(
        json.dumps(
            {
                "manifest_rows": len(manifest),
                "results_rows": len(results),
                "summary_count": summary.get("sample_count_distinct_tested"),
                "observed_counts": summary.get("counts_by_observed"),
                "mismatch_count": summary.get("mismatch_count"),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
