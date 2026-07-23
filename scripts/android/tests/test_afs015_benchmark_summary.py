import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "afs015_benchmark_summary.py"


def load_module():
    spec = importlib.util.spec_from_file_location("afs015_benchmark_summary", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Afs015BenchmarkSummaryTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def write_report(self, root, filename, report):
        path = pathlib.Path(root) / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report), encoding="utf-8")
        return path

    def test_extracts_macrobenchmark_metrics_and_trace_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.write_report(
                tmp,
                "outputs/device/afs015.json",
                {
                    "benchmarks": [
                        {
                            "name": "bottomTabSwitches",
                            "className": "com.omiyawaki.osrswiki.macrobenchmark.Afs015PerformanceBenchmark",
                            "metrics": {
                                "frameCount": {
                                    "minimum": 12.0,
                                    "median": 12.0,
                                    "maximum": 12.0,
                                },
                            },
                            "sampledMetrics": {
                                "frameDurationCpuMs": {
                                    "minimum": 8.0,
                                    "median": 16.0,
                                    "maximum": 96.0,
                                    "P95": 74.0,
                                },
                                "frameOverrunMs": {
                                    "P95": -2.0,
                                },
                            },
                            "profilerOutputs": ["bottomTabSwitches_iter000.perfetto-trace"],
                        }
                    ]
                },
            )

            records = self.module.load_macrobenchmark_records(pathlib.Path(tmp))

        self.assertEqual(len(records), 8)
        p95 = next(
            record
            for record in records
            if record.benchmark == "bottomTabSwitches"
            and record.metric == "frameDurationCpuMs"
            and record.stat == "p95"
        )
        self.assertEqual(p95.value, 74.0)
        self.assertEqual(p95.trace_files, ("bottomTabSwitches_iter000.perfetto-trace",))

    def test_conservative_guards_fail_clear_regressions_but_warn_policy_misses(self):
        warning_record = self.module.MetricRecord(
            benchmark="bottomTabSwitches",
            metric="frameDurationCpuMs",
            stat="p95",
            value=125.0,
            source="warning.json",
            trace_files=(),
        )
        failure_record = self.module.MetricRecord(
            benchmark="mapPanZoomFloor",
            metric="frameDurationCpuMs",
            stat="p95",
            value=275.0,
            source="failure.json",
            trace_files=(),
        )
        overrun_warning_record = self.module.MetricRecord(
            benchmark="searchOpenAndLocalQueryEntry",
            metric="frameOverrunMs",
            stat="p95",
            value=275.0,
            source="overrun-warning.json",
            trace_files=(),
        )

        warning_only = self.module.evaluate_records([warning_record, overrun_warning_record])
        with_failure = self.module.evaluate_records([warning_record, failure_record])

        self.assertFalse(any(item.status == "FAIL" for item in warning_only))
        self.assertTrue(any(item.status == "WARN" for item in warning_only))
        self.assertTrue(any(item.status == "FAIL" for item in with_failure))

    def test_writes_markdown_summary_and_csv(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            output_summary = root / "summary.md"
            output_csv = root / "metrics.csv"
            records = [
                self.module.MetricRecord(
                    benchmark="warmLaunchHome",
                    metric="timeToInitialDisplayMs",
                    stat="median",
                    value=420.0,
                    source="warm.json",
                    trace_files=("warmLaunchHome_iter000.perfetto-trace",),
                )
            ]
            evaluations = self.module.evaluate_records(records)

            self.module.write_summary(output_summary, records, evaluations, evidence_root=root)
            self.module.write_csv(output_csv, records, evaluations)

            summary = output_summary.read_text(encoding="utf-8")
            csv_text = output_csv.read_text(encoding="utf-8")

        self.assertIn("AFS-015 Android Performance Gate Summary", summary)
        self.assertIn("warmLaunchHome", summary)
        self.assertIn("warmLaunchHome_iter000.perfetto-trace", summary)
        self.assertIn("benchmark,metric,stat,value,status", csv_text)
        self.assertIn("warmLaunchHome,timeToInitialDisplayMs,median,420.0,PASS", csv_text)

    def test_main_returns_nonzero_when_no_macrobenchmark_json_is_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            summary_path = root / "summary.md"
            status = self.module.main(
                [
                    "--input-dir",
                    str(root),
                    "--summary",
                    str(summary_path),
                    "--csv",
                    str(root / "metrics.csv"),
                ]
            )
            summary = summary_path.read_text(encoding="utf-8")

        self.assertEqual(status, 1)
        self.assertIn("Overall status: NO DATA", summary)
        self.assertIn("No Macrobenchmark metrics were found.", summary)


if __name__ == "__main__":
    unittest.main()
