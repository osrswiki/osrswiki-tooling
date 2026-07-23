#!/usr/bin/env python3
"""Summarize and gate AFS-015 Android Macrobenchmark output."""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path
from statistics import median
from typing import Iterable


@dataclass(frozen=True)
class MetricRecord:
    benchmark: str
    metric: str
    stat: str
    value: float
    source: str
    trace_files: tuple[str, ...]


@dataclass(frozen=True)
class Threshold:
    metric: str
    stat: str
    limit: float
    status: str
    note: str


@dataclass(frozen=True)
class Evaluation:
    record: MetricRecord
    status: str
    limit: float | None
    note: str


THRESHOLDS = (
    Threshold(
        metric="timeToInitialDisplayMs",
        stat="median",
        limit=5000.0,
        status="FAIL",
        note="conservative startup guard",
    ),
    Threshold(
        metric="timeToFullDisplayMs",
        stat="median",
        limit=8000.0,
        status="FAIL",
        note="conservative full-display startup guard",
    ),
    Threshold(
        metric="frameDurationCpuMs",
        stat="p95",
        limit=250.0,
        status="FAIL",
        note="conservative emulator frame-duration regression guard",
    ),
    Threshold(
        metric="frameOverrunMs",
        stat="p95",
        limit=500.0,
        status="FAIL",
        note="conservative emulator frame-overrun regression guard",
    ),
    Threshold(
        metric="frameDurationCpuMs",
        stat="p95",
        limit=100.0,
        status="WARN",
        note="GUI policy target for local view updates",
    ),
    Threshold(
        metric="frameOverrunMs",
        stat="p95",
        limit=100.0,
        status="WARN",
        note="GUI policy target for local view updates",
    ),
)

STAT_ALIASES = {
    "minimum": "min",
    "min": "min",
    "median": "median",
    "p50": "p50",
    "p90": "p90",
    "p95": "p95",
    "p99": "p99",
    "maximum": "max",
    "max": "max",
}


def normalize_stat(stat: str) -> str:
    key = stat.strip().lower()
    return STAT_ALIASES.get(key, key)


def percentile(values: list[float], pct: float) -> float:
    if not values:
        raise ValueError("percentile requires at least one value")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * pct
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return ordered[int(rank)]
    weight = rank - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def numeric_value(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def stats_from_metric(metric_data) -> dict[str, float]:
    stats: dict[str, float] = {}
    if isinstance(metric_data, (int, float)) and not isinstance(metric_data, bool):
        stats["value"] = float(metric_data)
        return stats
    if not isinstance(metric_data, dict):
        return stats

    for key, value in metric_data.items():
        numeric = numeric_value(value)
        if numeric is not None:
            stats[normalize_stat(key)] = numeric

    runs = metric_data.get("runs")
    if isinstance(runs, list):
        run_values = [numeric for item in runs if (numeric := numeric_value(item)) is not None]
        if run_values:
            stats.setdefault("min", min(run_values))
            stats.setdefault("median", float(median(run_values)))
            stats.setdefault("max", max(run_values))
            stats.setdefault("p90", percentile(run_values, 0.90))
            stats.setdefault("p95", percentile(run_values, 0.95))
            stats.setdefault("p99", percentile(run_values, 0.99))

    return stats


def collect_trace_files(value) -> tuple[str, ...]:
    traces: list[str] = []

    def walk(node):
        if isinstance(node, str):
            if (
                node.endswith(".perfetto-trace")
                or node.endswith(".pftrace")
                or node.endswith(".trace")
            ):
                traces.append(node)
            return
        if isinstance(node, dict):
            for child in node.values():
                walk(child)
            return
        if isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return tuple(dict.fromkeys(traces))


def benchmark_name(benchmark: dict) -> str:
    name = benchmark.get("name") or benchmark.get("testName") or benchmark.get("benchmark")
    if name:
        return str(name)
    class_name = str(benchmark.get("className") or "unknown")
    return class_name.rsplit(".", maxsplit=1)[-1]


def load_macrobenchmark_records(root: Path) -> list[MetricRecord]:
    root = root.resolve()
    records: list[MetricRecord] = []
    for path in sorted(root.rglob("*.json")):
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        benchmarks = report.get("benchmarks") if isinstance(report, dict) else None
        if not isinstance(benchmarks, list):
            continue

        source = str(path.relative_to(root))
        for benchmark in benchmarks:
            if not isinstance(benchmark, dict):
                continue
            name = benchmark_name(benchmark)
            traces = collect_trace_files(benchmark)
            for metrics_key in ("metrics", "sampledMetrics"):
                metrics = benchmark.get(metrics_key)
                if not isinstance(metrics, dict):
                    continue
                for metric_name, metric_data in metrics.items():
                    for stat, value in stats_from_metric(metric_data).items():
                        records.append(
                            MetricRecord(
                                benchmark=name,
                                metric=str(metric_name),
                                stat=normalize_stat(stat),
                                value=value,
                                source=source,
                                trace_files=traces,
                            )
                        )
    return records


def matching_thresholds(record: MetricRecord) -> Iterable[Threshold]:
    for threshold in THRESHOLDS:
        if record.metric == threshold.metric and record.stat == threshold.stat:
            yield threshold


def evaluate_record(record: MetricRecord) -> Evaluation:
    status = "PASS"
    limit: float | None = None
    note = "no threshold configured"
    for threshold in matching_thresholds(record):
        if record.value <= threshold.limit:
            if limit is None:
                limit = threshold.limit
                note = threshold.note
            continue
        if threshold.status == "FAIL":
            return Evaluation(record, "FAIL", threshold.limit, threshold.note)
        if status != "FAIL":
            status = "WARN"
            limit = threshold.limit
            note = threshold.note
    return Evaluation(record, status, limit, note)


def evaluate_records(records: Iterable[MetricRecord]) -> list[Evaluation]:
    return [evaluate_record(record) for record in records]


def overall_status(evaluations: Iterable[Evaluation]) -> str:
    statuses = {evaluation.status for evaluation in evaluations}
    if not statuses:
        return "NO DATA"
    if "FAIL" in statuses:
        return "FAIL"
    if "WARN" in statuses:
        return "WARN"
    return "PASS"


def fmt_limit(limit: float | None) -> str:
    return "" if limit is None else f"{limit:g}"


def write_summary(
    path: Path,
    records: list[MetricRecord],
    evaluations: list[Evaluation],
    evidence_root: Path,
) -> None:
    status = overall_status(evaluations)
    trace_files = sorted({trace for record in records for trace in record.trace_files})
    path.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        "# AFS-015 Android Performance Gate Summary",
        "",
        f"- Overall status: {status}",
        f"- Evidence root: `{evidence_root}`",
        f"- Macrobenchmark metric count: {len(records)}",
        "",
        "## Thresholds",
        "",
        "- WARN: policy target miss for p95 local frame work above 100 ms.",
        "- FAIL: conservative emulator guard for clear regressions: p95 frame duration above 250 ms, p95 frame overrun above 500 ms, initial display median above 5000 ms, or full display median above 8000 ms.",
        "",
        "## Metrics",
        "",
    ]

    if evaluations:
        lines.append("| Status | Benchmark | Metric | Stat | Value | Limit | Source |")
        lines.append("| --- | --- | --- | --- | ---: | ---: | --- |")
        for evaluation in evaluations:
            record = evaluation.record
            lines.append(
                "| "
                f"{evaluation.status} | "
                f"{record.benchmark} | "
                f"{record.metric} | "
                f"{record.stat} | "
                f"{record.value:g} | "
                f"{fmt_limit(evaluation.limit)} | "
                f"`{record.source}` |"
            )
    else:
        lines.append("No Macrobenchmark metrics were found.")

    lines.extend(["", "## Trace Files", ""])
    if trace_files:
        lines.extend(f"- `{trace}`" for trace in trace_files)
    else:
        lines.append("- None reported in parsed benchmark JSON.")

    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_csv(path: Path, records: list[MetricRecord], evaluations: list[Evaluation]) -> None:
    by_record = {evaluation.record: evaluation for evaluation in evaluations}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            [
                "benchmark",
                "metric",
                "stat",
                "value",
                "status",
                "limit",
                "note",
                "source",
                "trace_files",
            ]
        )
        for record in records:
            evaluation = by_record[record]
            writer.writerow(
                [
                    record.benchmark,
                    record.metric,
                    record.stat,
                    record.value,
                    evaluation.status,
                    fmt_limit(evaluation.limit),
                    evaluation.note,
                    record.source,
                    ";".join(record.trace_files),
                ]
            )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--csv", required=True, type=Path)
    parser.add_argument(
        "--fail-on-warning",
        action="store_true",
        help="Return non-zero for policy warnings as well as guard failures.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    records = load_macrobenchmark_records(args.input_dir)
    evaluations = evaluate_records(records)
    write_summary(args.summary, records, evaluations, args.input_dir)
    write_csv(args.csv, records, evaluations)

    if not records:
        return 1

    status = overall_status(evaluations)
    if status in {"FAIL", "NO DATA"} or (status == "WARN" and args.fail_on_warning):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
