import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


MAP_DIR = Path(__file__).resolve().parents[1]
if str(MAP_DIR) not in sys.path:
    sys.path.insert(0, str(MAP_DIR))

from build_osrs_non_surface_realms_locked import (  # noqa: E402
    _osrs_is_within,
    osrs_locked_pixi_command,
)
from osrs_release_toolchain import (  # noqa: E402
    OSRS_LOCKED_WRAPPER_ENV,
    osrs_canonical_json_bytes,
    osrs_collect_locked_release_toolchain,
    osrs_compare_release_trees,
    osrs_load_release_toolchain_contract,
    osrs_release_tree_snapshot,
    osrs_sha256_path,
    osrs_verify_distinct_locked_invocations,
    osrs_verify_release_toolchain,
    osrsToolchainError,
)
from verify_osrs_locked_release import main as osrs_verify_main  # noqa: E402


class osrsReleaseToolchainTest(unittest.TestCase):
    def _public_report(self):
        contract = osrs_load_release_toolchain_contract()
        with patch.dict(
            os.environ,
            {OSRS_LOCKED_WRAPPER_ENV: contract["contract_id"]},
            clear=False,
        ):
            public, invocation = osrs_collect_locked_release_toolchain()
        return public, invocation

    def _release(self, root: Path, public: dict, marker: str = "same") -> None:
        contract = osrs_load_release_toolchain_contract()
        reports = root / "reports"
        assets = root / "assets"
        reports.mkdir(parents=True)
        assets.mkdir(parents=True)
        retained_public = json.loads(osrs_canonical_json_bytes(public))
        retained_public["content_addressed_inputs"] = {
            "accounting_helper": {
                "logical_id": "tool://osrs-source-accounting",
                "sha256": "a" * 64,
            }
        }
        report_path = reports / "toolchain-provenance.json"
        report_path.write_bytes(osrs_canonical_json_bytes(retained_public))
        database_path = assets / "fixture.mbtiles"
        with sqlite3.connect(database_path) as database:
            database.execute("CREATE TABLE fixture(value TEXT NOT NULL)")
            database.execute("INSERT INTO fixture(value) VALUES ('stable')")
            database.commit()
            database.execute("VACUUM")
            database.commit()
        (root / "underground-realms.json").write_bytes(
            osrs_canonical_json_bytes(
                {
                    "inputs": {
                        "release_toolchain": {
                            "path": "reports/toolchain-provenance.json",
                            "sha256": osrs_sha256_path(report_path),
                            "contract_id": contract["contract_id"],
                            "sqlite_version": contract["runtime"]["sqlite_version"],
                            "sqlite_version_number": contract["runtime"][
                                "sqlite_version_number"
                            ],
                        }
                    },
                    "realms": [
                        {
                            "assets": [
                                {
                                    "mbtiles_path": "assets/fixture.mbtiles",
                                    "sqlite_version_number": contract["runtime"][
                                        "sqlite_version_number"
                                    ],
                                }
                            ]
                        }
                    ],
                }
            )
        )
        (root / "marker.txt").write_text(marker, encoding="utf-8")

    def test_committed_locked_environment_matches_contract(self):
        public, invocation = self._public_report()
        contract = osrs_load_release_toolchain_contract()
        self.assertEqual("LOCKED_TOOLCHAIN_VERIFIED", public["status"])
        self.assertEqual(contract["runtime"], public["runtime"])
        self.assertEqual(
            contract["installed_package_set"], public["installed_package_set"]
        )
        self.assertEqual(
            "LOCKED_TOOLCHAIN_INVOCATION_VERIFIED", invocation["status"]
        )
        self.assertEqual(4, len(invocation["runtime_files"]))

    def test_wrong_pixi_executable_hash_is_rejected(self):
        contract = osrs_load_release_toolchain_contract()
        with tempfile.TemporaryDirectory() as directory:
            impostor = Path(directory) / "pixi"
            impostor.write_bytes(b"not-the-pinned-pixi-executable")
            with patch.dict(
                os.environ,
                {
                    OSRS_LOCKED_WRAPPER_ENV: contract["contract_id"],
                    "PIXI_EXE": str(impostor),
                },
                clear=False,
            ):
                with self.assertRaisesRegex(
                    osrsToolchainError, r"pixi\.executable_sha256"
                ):
                    osrs_collect_locked_release_toolchain()

    def test_direct_unlocked_inner_invocation_is_rejected(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop(OSRS_LOCKED_WRAPPER_ENV, None)
            with self.assertRaisesRegex(
                osrsToolchainError, "locked_wrapper_marker"
            ):
                osrs_collect_locked_release_toolchain()

    def test_public_report_contains_no_environment_prefix(self):
        public, invocation = self._public_report()
        public_bytes = osrs_canonical_json_bytes(public)
        invocation_bytes = osrs_canonical_json_bytes(invocation)
        prefix = str(Path(sys.prefix).resolve()).encode("utf-8")
        self.assertNotIn(prefix, public_bytes)
        self.assertNotIn(prefix, invocation_bytes)
        self.assertIn(b"python-executable", invocation_bytes)

    def test_outer_command_always_uses_locked_pixi(self):
        command = osrs_locked_pixi_command(
            Path("/logical/pixi"),
            Path("/logical/tools"),
            ["--output", "/private/output"],
        )
        self.assertEqual(
            ["/logical/pixi", "run", "--locked", "--manifest-path"],
            command[:4],
        )
        self.assertEqual("python", command[5])
        self.assertIn("build_osrs_non_surface_realms.py", command[6])

    def test_invocation_evidence_must_be_outside_release(self):
        root = Path("/private/release")
        self.assertTrue(_osrs_is_within(root / "evidence.json", root))
        self.assertFalse(_osrs_is_within(Path("/private/evidence.json"), root))

    def test_exact_tree_gate_accepts_two_replays_of_retained_canonical(self):
        public, _ = self._public_report()
        with tempfile.TemporaryDirectory() as directory:
            roots = [Path(directory) / name for name in ("a", "b", "c")]
            self._release(roots[0], public)
            for root in roots[1:]:
                for source in roots[0].rglob("*"):
                    if source.is_dir():
                        continue
                    destination = root / source.relative_to(roots[0])
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(source.read_bytes())
            result = osrs_compare_release_trees(roots[0], roots[1:])
            self.assertEqual("PASS", result["status"])
            self.assertTrue(result["checks"]["retained_canonical_reproduced"])
            self.assertEqual(3, len(result["toolchain_gates"]))
            self.assertEqual(
                osrs_release_tree_snapshot(roots[0])["file_hash_stream_sha256"],
                result["canonical"]["file_hash_stream_sha256"],
            )

    def test_invocation_gate_requires_three_distinct_environment_prefixes(self):
        _, invocation = self._public_report()
        contract = osrs_load_release_toolchain_contract()
        with tempfile.TemporaryDirectory() as directory:
            reports = []
            for index in range(3):
                value = json.loads(osrs_canonical_json_bytes(invocation))
                value["outer_wrapper"] = {
                    "environment_prefix_identity_sha256": f"{index + 1:064x}",
                    "pixi_executable_sha256": contract["pixi"][
                        "executable_sha256"
                    ],
                    "pixi_version": contract["pixi"]["cli_version"],
                    "spawn_policy": "pixi run --locked",
                }
                value["checks"]["outer_wrapper_used_pixi_run_locked"] = True
                path = Path(directory) / f"invocation-{index}.json"
                path.write_bytes(osrs_canonical_json_bytes(value))
                reports.append(path)
            result = osrs_verify_distinct_locked_invocations(
                reports,
                expected_count=3,
                expected_public_toolchain_report_sha256=invocation[
                    "public_toolchain_report_sha256"
                ],
            )
            self.assertEqual(3, result["distinct_environment_identity_count"])
            with self.assertRaisesRegex(
                osrsToolchainError, "retained public toolchain report"
            ):
                osrs_verify_distinct_locked_invocations(
                    reports,
                    expected_count=3,
                    expected_public_toolchain_report_sha256="b" * 64,
                )
            duplicate = json.loads(reports[1].read_text(encoding="utf-8"))
            duplicate["outer_wrapper"]["environment_prefix_identity_sha256"] = (
                f"{1:064x}"
            )
            reports[1].write_bytes(osrs_canonical_json_bytes(duplicate))
            with self.assertRaisesRegex(osrsToolchainError, "distinct isolated"):
                osrs_verify_distinct_locked_invocations(
                    reports,
                    expected_count=3,
                    expected_public_toolchain_report_sha256=invocation[
                        "public_toolchain_report_sha256"
                    ],
                )

    def test_exact_tree_gate_detects_changed_replay(self):
        public, _ = self._public_report()
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "a"
            second = Path(directory) / "b"
            self._release(first, public, marker="canonical")
            self._release(second, public, marker="changed")
            result = osrs_compare_release_trees(first, [second])
            self.assertEqual("FAIL_EXACT_RELEASE_MISMATCH", result["status"])
            self.assertEqual(1, result["comparisons"][0]["changed_count"])
            self.assertIn(
                "marker.txt", result["comparisons"][0]["first_differences"]
            )

    def test_cli_consumes_all_three_invocation_reports(self):
        public, invocation = self._public_report()
        contract = osrs_load_release_toolchain_contract()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            releases = [root / name for name in ("a", "b", "c")]
            self._release(releases[0], public)
            for release in releases[1:]:
                for source in releases[0].rglob("*"):
                    if source.is_dir():
                        continue
                    destination = release / source.relative_to(releases[0])
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(source.read_bytes())
            retained_hash = osrs_sha256_path(
                releases[0] / "reports" / "toolchain-provenance.json"
            )
            invocation_paths = []
            for index in range(3):
                value = json.loads(osrs_canonical_json_bytes(invocation))
                value["public_toolchain_report_sha256"] = retained_hash
                value["checks"][
                    "retained_public_toolchain_report_hash_recorded"
                ] = True
                value["checks"]["outer_wrapper_used_pixi_run_locked"] = True
                value["checks"]["pixi_cli_version_exact"] = True
                value["outer_wrapper"] = {
                    "environment_prefix_identity_sha256": f"{index + 1:064x}",
                    "pixi_executable_sha256": contract["pixi"][
                        "executable_sha256"
                    ],
                    "pixi_version": contract["pixi"]["cli_version"],
                    "spawn_policy": "pixi run --locked",
                }
                path = root / f"invocation-{index}.json"
                path.write_bytes(osrs_canonical_json_bytes(value))
                invocation_paths.append(path)
            output = root / "reproducibility.json"
            arguments = [
                "--canonical",
                str(releases[0]),
                "--replay",
                str(releases[1]),
                "--replay",
                str(releases[2]),
            ]
            for path in invocation_paths:
                arguments.extend(("--invocation-report", str(path)))
            arguments.extend(("--report", str(output)))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, osrs_verify_main(arguments))
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual("PASS", report["status"])
            self.assertEqual(
                3,
                report["isolated_locked_invocations"][
                    "distinct_environment_identity_count"
                ],
            )
            self.assertTrue(
                report["checks"]["distinct_fresh_locked_environments"]
            )

    def test_release_gate_rejects_wrong_sqlite_header_version(self):
        public, _ = self._public_report()
        contract = osrs_load_release_toolchain_contract()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "reports").mkdir()
            (root / "assets").mkdir()
            retained_public = json.loads(osrs_canonical_json_bytes(public))
            retained_public["content_addressed_inputs"] = {
                "accounting_helper": {
                    "logical_id": "tool://osrs-source-accounting",
                    "sha256": "a" * 64,
                }
            }
            report_path = root / "reports" / "toolchain-provenance.json"
            report_path.write_bytes(osrs_canonical_json_bytes(retained_public))
            header = bytearray(100)
            header[:16] = b"SQLite format 3\x00"
            wrong_version = int(contract["runtime"]["sqlite_version_number"]) - 1
            header[96:100] = wrong_version.to_bytes(4, "big")
            (root / "assets" / "wrong.mbtiles").write_bytes(header)
            (root / "underground-realms.json").write_bytes(
                osrs_canonical_json_bytes(
                    {
                        "inputs": {
                            "release_toolchain": {
                                "path": "reports/toolchain-provenance.json",
                                "sha256": osrs_sha256_path(report_path),
                                "contract_id": contract["contract_id"],
                                "sqlite_version": contract["runtime"][
                                    "sqlite_version"
                                ],
                                "sqlite_version_number": contract["runtime"][
                                    "sqlite_version_number"
                                ],
                            }
                        },
                        "realms": [
                            {
                                "assets": [
                                    {
                                        "mbtiles_path": "assets/wrong.mbtiles",
                                        "sqlite_version_number": contract["runtime"][
                                            "sqlite_version_number"
                                        ],
                                    }
                                ]
                            }
                        ],
                    }
                )
            )
            with self.assertRaisesRegex(
                osrsToolchainError, "sqlite_file_header_version"
            ):
                osrs_verify_release_toolchain(root)

    def test_manifest_and_lock_hashes_are_content_addressed(self):
        contract = osrs_load_release_toolchain_contract()
        tools = MAP_DIR.parent
        self.assertEqual(
            contract["pixi"]["manifest_sha256"],
            osrs_sha256_path(tools / "pixi.toml"),
        )
        self.assertEqual(
            contract["pixi"]["lock_sha256"], osrs_sha256_path(tools / "pixi.lock")
        )


if __name__ == "__main__":
    unittest.main()
