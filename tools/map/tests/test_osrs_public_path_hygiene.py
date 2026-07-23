import base64
import gzip
import hashlib
import io
import json
import struct
import sys
import tempfile
import unittest
import zipfile
from dataclasses import replace
from pathlib import Path


MAP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MAP_DIR))

from osrs_public_path_hygiene import (  # noqa: E402
    osrs_assert_public_json_portable,
    osrs_find_host_absolute_paths,
    osrs_portabilize_source_snapshot,
    osrs_validate_public_artifact_closure,
    osrs_validate_public_archive,
    osrs_validate_public_json_tree,
    osrs_validate_public_release_tree,
    OSRS_DEFAULT_PATH_SCAN_LIMITS,
    osrsPublicPathError,
)


class osrsPublicPathHygieneTests(unittest.TestCase):
    @staticmethod
    def _write_archive(path, member, value):
        with zipfile.ZipFile(
            path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as archive:
            archive.writestr(member, value)

    @staticmethod
    def _nested_zip_bytes(member, value):
        output = io.BytesIO()
        with zipfile.ZipFile(
            output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as archive:
            archive.writestr(member, value)
        return output.getvalue()

    @staticmethod
    def _directory_zip_bytes(value, compression=zipfile.ZIP_STORED):
        output = io.BytesIO()
        with zipfile.ZipFile(
            output, "w", compression=compression, compresslevel=9
        ) as archive:
            archive.writestr("payload/", value)
        return output.getvalue()

    @staticmethod
    def _encrypted_empty_directory_zip_bytes():
        data = bytearray(osrsPublicPathHygieneTests._directory_zip_bytes(b""))
        local_header = data.find(b"PK\x03\x04")
        central_header = data.find(b"PK\x01\x02")
        if local_header < 0 or central_header < 0:
            raise AssertionError("deterministic ZIP fixture is missing headers")
        local_flags = struct.unpack_from("<H", data, local_header + 6)[0] | 0x1
        central_flags = struct.unpack_from("<H", data, central_header + 8)[0] | 0x1
        struct.pack_into("<H", data, local_header + 6, local_flags)
        struct.pack_into("<H", data, central_header + 8, central_flags)
        return bytes(data)

    @staticmethod
    def _zip_with_local_only_extra(value):
        data = bytearray(
            osrsPublicPathHygieneTests._nested_zip_bytes(
                "payload.txt", b"portable member payload"
            )
        )
        name_size, extra_size = struct.unpack_from("<HH", data, 26)
        local_extra = struct.pack("<HH", 0xCAFE, len(value)) + value
        insertion = 30 + name_size + extra_size
        struct.pack_into("<H", data, 28, extra_size + len(local_extra))
        data[insertion:insertion] = local_extra
        eocd = data.rfind(b"PK\x05\x06")
        central_offset = struct.unpack_from("<I", data, eocd + 16)[0]
        struct.pack_into("<I", data, eocd + 16, central_offset + len(local_extra))
        return bytes(data)

    @staticmethod
    def _zip_with_apk_signing_block(value):
        data = bytearray(
            osrsPublicPathHygieneTests._nested_zip_bytes(
                "payload.txt", b"portable member payload"
            )
        )
        eocd = data.rfind(b"PK\x05\x06")
        central_offset = struct.unpack_from("<I", data, eocd + 16)[0]
        pair = struct.pack("<Q", 4 + len(value)) + struct.pack("<I", 0x7109871A) + value
        block_size = len(pair) + 24
        signing_block = (
            struct.pack("<Q", block_size)
            + pair
            + struct.pack("<Q", block_size)
            + b"APK Sig Block 42"
        )
        data[central_offset:central_offset] = signing_block
        eocd += len(signing_block)
        struct.pack_into(
            "<I", data, eocd + 16, central_offset + len(signing_block)
        )
        return bytes(data)

    @staticmethod
    def _zip_with_precentral_gap(value):
        data = bytearray(
            osrsPublicPathHygieneTests._nested_zip_bytes(
                "payload.txt", b"portable member payload"
            )
        )
        eocd = data.rfind(b"PK\x05\x06")
        central_offset = struct.unpack_from("<I", data, eocd + 16)[0]
        data[central_offset:central_offset] = value
        eocd += len(value)
        struct.pack_into("<I", data, eocd + 16, central_offset + len(value))
        return bytes(data)

    def test_release_relative_logical_content_and_web_references_pass(self):
        value = {
            "release_relative": "assets/realm/plane-0.mbtiles",
            "logical_input": "input://renderer-provenance/plane-0/source-rgb.png",
            "logical_tool": "tool://osrs-source-accounting",
            "content_address": "sha256:0123456789abcdef",
            "wiki_url": "https://maps.runescape.wiki/osrs/versions/example/basemaps.json",
            "projection": {
                "game_bounds": {"min_x": 960, "max_y": 12608},
                "game_coord_scale": 4,
            },
        }
        self.assertEqual([], osrs_find_host_absolute_paths(value))
        osrs_assert_public_json_portable(value)

    def test_posix_home_and_alternate_host_roots_fail(self):
        values = [
            "/Users/alice/build/release.json",
            "/home/runner/work/project/release.json",
            "/srv/custom-host/project/release.json",
            "/Volumes/build-disk/project/release.json",
            "cache loaded from /opt/private-build/cache",
            "~/project/release.json",
            "~builder/project/release.json",
        ]
        for index, value in enumerate(values):
            with self.subTest(value=value):
                findings = osrs_find_host_absolute_paths({"nested": [{"path": value}]})
                self.assertEqual(1, len(findings))
                self.assertEqual("/nested/0/path", findings[0]["json_pointer"])
                with self.assertRaises(osrsPublicPathError):
                    osrs_assert_public_json_portable({"value": value}, f"fixture-{index}")

    def test_windows_drive_unc_rooted_and_file_uri_fail(self):
        values = [
            r"C:\Users\builder\project\release.json",
            "D:/ci/project/release.json",
            r"\\server\share\project\release.json",
            "//server/share/project/release.json",
            r"\\?\C:\very-long\project\release.json",
            r"\build-root\project\release.json",
            "file:///Users/builder/project/release.json",
            r"file:\\server\share\project\release.json",
        ]
        for value in values:
            with self.subTest(value=value):
                with self.assertRaises(osrsPublicPathError):
                    osrs_assert_public_json_portable({"path": value})

    def test_nested_serialization_and_escape_variants_fail(self):
        values = [
            r"\/Users\/builder\/project\/release.json",
            r"\u002fhome\u002frunner\u002fwork\u002frelease.json",
            r"C:\\Users\\builder\\project\\release.json",
            json.dumps("/Users/builder/project/release.json"),
            json.dumps({"path": "/home/runner/work/project/release.json"}),
            "%2FUsers%2Fbuilder%2Fproject%2Frelease.json",
        ]
        for value in values:
            with self.subTest(value=value):
                self.assertTrue(osrs_find_host_absolute_paths({"serialized": value}))

    def test_absolute_json_key_fails(self):
        findings = osrs_find_host_absolute_paths({"/Users/builder/secret": "value"})
        self.assertEqual("key", findings[0]["location"])
        with self.assertRaises(osrsPublicPathError):
            osrs_assert_public_json_portable({"/Users/builder/secret": "value"})

    def test_snapshot_portabilization_preserves_projection_and_history(self):
        snapshot = {
            "candidate": "001",
            "cache": {
                "cache_id": 2499,
                "cache_directory": "/Users/builder/cache/2499",
                "sha256": "cache-hash",
            },
            "raster": {
                "path": "/home/runner/work/project/img-0.png",
                "metadata_path": r"C:\build\map-metadata.json",
                "game_bounds": {
                    "min_x": 960,
                    "min_y": 1216,
                    "max_x": 4224,
                    "max_y": 12608,
                },
                "game_coord_scale": 4,
                "width": 13056,
                "height": 45568,
                "sha256": "raster-hash",
            },
            "repository": {"base_commit": "abc", "worktree": "file:///tmp/worktree"},
        }
        portable = osrs_portabilize_source_snapshot(snapshot)
        self.assertEqual("001", portable["candidate"])
        self.assertEqual(2499, portable["cache"]["cache_id"])
        self.assertEqual(snapshot["raster"]["game_bounds"], portable["raster"]["game_bounds"])
        self.assertEqual(4, portable["raster"]["game_coord_scale"])
        self.assertEqual("raster-hash", portable["raster"]["sha256"])
        self.assertEqual(
            "input://source-snapshot/cache/cache_directory",
            portable["cache"]["cache_directory"],
        )
        self.assertEqual(
            "input://source-snapshot/raster/path", portable["raster"]["path"]
        )
        self.assertEqual(
            "input://source-snapshot/repository/worktree",
            portable["repository"]["worktree"],
        )
        osrs_assert_public_json_portable(portable)
        self.assertEqual(
            "/Users/builder/cache/2499", snapshot["cache"]["cache_directory"]
        )

    def test_snapshot_embedded_path_fails_instead_of_redacting(self):
        with self.assertRaisesRegex(osrsPublicPathError, "embedded host path"):
            osrs_portabilize_source_snapshot(
                {"path": "private cache at /Users/builder/cache"}
            )
        with self.assertRaisesRegex(osrsPublicPathError, "outside a path-like field"):
            osrs_portabilize_source_snapshot(
                {"license_notes": "built from /Users/builder/cache"}
            )

    def test_json_tree_scans_every_public_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "reports").mkdir()
            (root / "manifest.json").write_text(
                json.dumps({"asset": "assets/realm.mbtiles"}), encoding="utf-8"
            )
            (root / "reports" / "accounting.json").write_text(
                json.dumps({"tool": "tool://osrs-source-accounting"}),
                encoding="utf-8",
            )
            report = osrs_validate_public_json_tree(root)
            self.assertEqual(2, report["scanned_artifact_count"])
            self.assertTrue(report["checks"]["release_ready"])

            (root / "reports" / "bad.json").write_text(
                json.dumps({"path": "/home/another-user/release"}), encoding="utf-8"
            )
            with self.assertRaisesRegex(osrsPublicPathError, "reports/bad.json"):
                osrs_validate_public_json_tree(root)

    def test_release_tree_scans_non_json_artifacts_and_name_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "assets").mkdir()
            (root / "manifest.json").write_text(
                json.dumps({"asset": "assets/realm.mbtiles"}), encoding="utf-8"
            )
            (root / "assets" / "realm.mbtiles").write_bytes(
                b"SQLite format 3\0metadata\0portable-value\0"
            )
            (root / "assets" / "mask.png").write_bytes(b"\x89PNG\r\n\x1a\n")
            report = osrs_validate_public_release_tree(root)
            self.assertEqual(3, report["scanned_artifact_count"])
            self.assertEqual(1, report["json_artifact_count"])
            self.assertEqual(2, report["non_json_artifact_count"])
            self.assertEqual(64, len(report["scanned_artifact_names_sha256"]))
            self.assertTrue(
                report["checks"]["all_public_release_files_scanned"]
            )

            (root / "assets" / "realm.mbtiles").write_bytes(
                b"SQLite format 3\0/srv/custom-ci/project/source.cpp\0"
            )
            with self.assertRaisesRegex(osrsPublicPathError, "realm.mbtiles"):
                osrs_validate_public_release_tree(root)

    def test_archive_scans_maplibre_native_binary_build_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad_apk = root / "bad.apk"
            with zipfile.ZipFile(bad_apk, "w") as archive:
                archive.writestr(
                    "lib/arm64-v8a/libmaplibre-native.so",
                    b"binary\0/home/runner/work/maplibre-native/src/map.cpp\0"
                    b"/srv/custom-ci/project/source.cpp\0data",
                )
                archive.writestr(
                    "assets/underground-realms.json",
                    json.dumps({"path": "assets/surface/plane-0.mbtiles"}),
                )
            with self.assertRaisesRegex(
                osrsPublicPathError, "libmaplibre-native.so"
            ):
                osrs_validate_public_archive(bad_apk)

            good_apk = root / "good.apk"
            with zipfile.ZipFile(good_apk, "w") as archive:
                archive.writestr(
                    "lib/arm64-v8a/libmaplibre-native.so",
                    b"binary\0/system/lib64/libc.so\0data",
                )
                archive.writestr(
                    "assets/underground-realms.json",
                    json.dumps({"path": "assets/surface/plane-0.mbtiles"}),
                )
            report = osrs_validate_public_archive(good_apk)
            self.assertEqual(2, report["scanned_artifact_count"])
            self.assertEqual(1, report["native_library_count"])
            self.assertTrue(report["checks"]["all_archive_members_scanned"])

    def test_archive_binary_scan_ignores_runtime_paths_and_binary_syntax(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "binary-syntax.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(
                    "classes.dex",
                    b"\\08,\\06,T09,T17,\0"
                    b"K:/K\0"
                    b"~/n ]\0"
                    b"\\Landroidx/activity/ComponentActivity;\0"
                    b"(?:[a-zA-Z0-9\\$\\-\\_\\.]+)\0",
                )
                archive.writestr(
                    "lib/arm64-v8a/libportable.so",
                    b"/system/lib64/libc.so\0/tmp\0file://\0"
                    b"\\{domain\\}|\\{path\\}|\\{directory\\}\0",
                )
                archive.writestr("assets/mask.png", b"\x89PNG\r\n\x1a\n")
            report = osrs_validate_public_archive(apk)
            self.assertEqual(3, report["scanned_artifact_count"])
            self.assertEqual(0, report["findings_count"])

    def test_archive_scan_catches_structured_alternate_host_paths(self):
        bad_values = [
            b"/Users/alternate/project/source/file.kt",
            b"/opt/private-build/project/source.cpp",
            b"C:\\Users\\builder\\project\\source.kt",
            b"D:/ci/project/release/file.json",
            b"\\\\server\\share\\project\\source.kt",
            b"\\build-root\\project\\source.kt",
            b"~/project/release/file.json",
            b"file:///home/runner/work/project/source.cpp",
        ]
        for index, value in enumerate(bad_values):
            with self.subTest(value=value):
                with tempfile.TemporaryDirectory() as directory:
                    apk = Path(directory) / f"bad-{index}.apk"
                    with zipfile.ZipFile(apk, "w") as archive:
                        archive.writestr("classes.dex", b"prefix\0" + value + b"\0")
                    with self.assertRaises(osrsPublicPathError):
                        osrs_validate_public_archive(apk)

    def test_raw_zip_and_apk_regions_are_accounted_and_scanned_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            clean_signed = root / "clean-signed.apk"
            clean_signed.write_bytes(
                self._zip_with_apk_signing_block(b"portable-signing-value")
            )
            report = osrs_validate_public_archive(clean_signed)
            accounting = report["zip_raw_byte_accounting"]
            self.assertEqual(accounting["container_bytes"], accounting["classified_bytes"])
            self.assertEqual(0, accounting["unclassified_bytes"])
            self.assertGreater(accounting["raw_region_count"], 0)
            self.assertGreater(accounting["scanned_raw_metadata_bytes"], 0)
            self.assertTrue(
                report["checks"]["all_zip_apk_raw_bytes_structurally_accounted"]
            )

            trailer = root / "trailer.apk"
            trailer.write_bytes(
                self._nested_zip_bytes("payload.txt", b"portable")
                + b"\0/home/runner/private-report"
            )
            with self.assertRaisesRegex(osrsPublicPathError, "TRAILER"):
                osrs_validate_public_archive(trailer)

            local_extra = root / "local-extra.apk"
            local_extra.write_bytes(
                self._zip_with_local_only_extra(b"\0file:///Users/builder/report")
            )
            with zipfile.ZipFile(local_extra) as archive:
                self.assertEqual(b"", archive.infolist()[0].extra)
            with self.assertRaisesRegex(osrsPublicPathError, "local-header"):
                osrs_validate_public_archive(local_extra)

            inter_record_gap = root / "inter-record-gap.apk"
            inter_record_gap.write_bytes(
                self._zip_with_precentral_gap(b"\0/Users/builder/gap-report")
            )
            with self.assertRaisesRegex(osrsPublicPathError, "local-record-gap"):
                osrs_validate_public_archive(inter_record_gap)

            signing_value = root / "signing-value.apk"
            signing_value.write_bytes(
                self._zip_with_apk_signing_block(b"\0/tmp/build/signing-report")
            )
            with self.assertRaisesRegex(osrsPublicPathError, "APK-SIGNING-BLOCK"):
                osrs_validate_public_archive(signing_value)

            malformed = bytearray(clean_signed.read_bytes())
            central = struct.unpack_from(
                "<I", malformed, malformed.rfind(b"PK\x05\x06") + 16
            )[0]
            trailing_size = struct.unpack_from("<Q", malformed, central - 24)[0]
            signing_start = central - trailing_size - 8
            struct.pack_into("<Q", malformed, signing_start, trailing_size - 1)
            malformed_path = root / "malformed-signing.apk"
            malformed_path.write_bytes(malformed)
            with self.assertRaisesRegex(osrsPublicPathError, "sizes disagree"):
                osrs_validate_public_archive(malformed_path)

    def test_non_empty_directory_members_are_rejected_with_member_provenance(self):
        marker = b"/tmp/build/osrs-directory-payload-marker.txt"
        cases = {
            "stored": zipfile.ZIP_STORED,
            "deflated": zipfile.ZIP_DEFLATED,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, compression in cases.items():
                with self.subTest(compression=name):
                    archive = root / f"directory-payload-{name}.zip"
                    archive.write_bytes(
                        self._directory_zip_bytes(marker, compression=compression)
                    )
                    with self.assertRaisesRegex(
                        osrsPublicPathError,
                        rf"{archive.name}!/payload/.*decoded={len(marker)}",
                    ):
                        osrs_validate_public_archive(archive)

    def test_regular_file_control_with_identical_payload_remains_scanned(self):
        marker = b"/tmp/build/osrs-directory-payload-marker.txt"
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "regular-payload-control.zip"
            archive.write_bytes(self._nested_zip_bytes("payload.txt", marker))
            with self.assertRaisesRegex(
                osrsPublicPathError, r"regular-payload-control\.zip!/payload\.txt"
            ):
                osrs_validate_public_archive(archive)

    def test_zero_byte_directory_is_validated_and_member_accounting_is_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "empty-directory.zip"
            archive.write_bytes(self._directory_zip_bytes(b""))
            report = osrs_validate_public_archive(archive)
            accounting = report["zip_member_inspection_accounting"]
            self.assertEqual(1, accounting["parsed_members"])
            self.assertEqual(0, accounting["payload_members_inspected"])
            self.assertEqual(1, accounting["empty_directory_members_validated"])
            self.assertEqual(1, accounting["accounted_members"])
            self.assertEqual(0, accounting["uninspected_members"])
            self.assertEqual(0, accounting["uninspected_nonzero_payload_members"])
            self.assertEqual(
                report["zip_raw_byte_accounting"]["container_bytes"],
                report["zip_raw_byte_accounting"]["classified_bytes"],
            )
            self.assertEqual(
                0, report["zip_raw_byte_accounting"]["unclassified_bytes"]
            )
            self.assertTrue(report["checks"]["all_archive_members_scanned"])
            self.assertTrue(
                report["checks"][
                    "all_zip_members_inspected_or_validated_empty_directories"
                ]
            )

    def test_encrypted_directory_cannot_bypass_member_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "encrypted-directory.zip"
            archive.write_bytes(self._encrypted_empty_directory_zip_bytes())
            with self.assertRaisesRegex(
                osrsPublicPathError,
                r"encrypted archive member.*encrypted-directory\.zip!/payload/",
            ):
                osrs_validate_public_archive(archive)

    def test_nested_directory_payload_is_rejected_recursively(self):
        marker = b"/tmp/build/osrs-directory-payload-marker.txt"
        inner = self._directory_zip_bytes(marker, compression=zipfile.ZIP_DEFLATED)
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "outer.zip"
            archive.write_bytes(self._nested_zip_bytes("nested.zip", inner))
            with self.assertRaisesRegex(
                osrsPublicPathError, r"outer\.zip!/nested\.zip!/payload/"
            ):
                osrs_validate_public_archive(archive)

    def test_release_tree_rejects_directory_payload_archive(self):
        marker = b"/tmp/build/osrs-directory-payload-marker.txt"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "evidence" / "directory-payload.zip"
            archive.parent.mkdir()
            archive.write_bytes(self._directory_zip_bytes(marker))
            with self.assertRaisesRegex(
                osrsPublicPathError,
                r"evidence/directory-payload\.zip!/payload/",
            ):
                osrs_validate_public_release_tree(root)

    def test_all_23_independent_reviewer_cases_reject(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runners = []

            minimal = {
                "posix_home_minimal": b"/home/runner",
                "posix_tmp_minimal": b"/tmp/build",
                "posix_users_minimal": b"/Users/alice",
                "windows_drive_minimal": br"C:\Users\builder",
                "windows_unc_minimal": br"\\server\share",
                "file_uri_minimal": b"file:///Users/alice",
            }
            for name, value in minimal.items():
                fixture = root / name
                (fixture / "res/raw").mkdir(parents=True)
                (fixture / "res/raw/seed.bin").write_bytes(
                    b"prefix\0" + value + b"\0suffix"
                )
                runners.append(
                    (
                        name,
                        lambda fixture=fixture: osrs_validate_public_release_tree(
                            fixture
                        ),
                    )
                )

            extended = {
                "posix_home_extended": b"/home/runner/project/source.cpp",
                "posix_tmp_extended": b"/tmp/build/project/output.json",
                "posix_users_extended": b"/Users/alice/project/source.kt",
                "windows_drive_extended": br"C:\Users\builder\project\source.kt",
                "windows_unc_extended": br"\\server\share\project\source.kt",
                "file_uri_extended": b"file:///Users/alice/project/source.kt",
            }
            for name, value in extended.items():
                fixture = root / f"{name}.apk"
                self._write_archive(
                    fixture,
                    "lib/arm64-v8a/libseed.so",
                    b"prefix\0" + value + b"\0suffix",
                )
                runners.append(
                    (
                        name,
                        lambda fixture=fixture: osrs_validate_public_archive(fixture),
                    )
                )

            resource = root / "direct_resource_extended"
            (resource / "res/raw").mkdir(parents=True)
            (resource / "res/raw/seed.bin").write_bytes(
                b"/home/runner/project/generated/resource.xml"
            )
            runners.append(
                (
                    "direct_resource_extended",
                    lambda: osrs_validate_public_release_tree(resource),
                )
            )

            for suffix in ("jar", "aar"):
                fixture = root / f"direct_dependency_extended.{suffix}"
                self._write_archive(
                    fixture,
                    "payload/seed.txt",
                    b"/home/runner/project/dependency/source.cpp",
                )
                runners.append(
                    (
                        f"direct_{suffix}_extended",
                        lambda fixture=fixture: osrs_validate_public_archive(fixture),
                    )
                )

            for suffix in ("zip", "jar", "aar"):
                fixture = root / f"compressed_nested_{suffix}.apk"
                self._write_archive(
                    fixture,
                    f"assets/dependency.{suffix}",
                    self._nested_zip_bytes(
                        "payload/seed.txt", b"/home/runner/project/source.cpp"
                    ),
                )
                runners.append(
                    (
                        f"compressed_nested_{suffix}",
                        lambda fixture=fixture: osrs_validate_public_archive(fixture),
                    )
                )

            gzip_fixture = root / "compressed_nested_gzip.apk"
            self._write_archive(
                gzip_fixture,
                "assets/report.txt.gz",
                gzip.compress(
                    b"prefix\0/home/runner/project/source.cpp\0suffix", mtime=0
                ),
            )
            runners.append(
                (
                    "compressed_nested_gzip",
                    lambda: osrs_validate_public_archive(gzip_fixture),
                )
            )

            structured_json = root / "structured_json"
            structured_json.mkdir()
            (structured_json / "manifest.json").write_text(
                json.dumps({"path": "/home/runner"}), encoding="utf-8"
            )
            runners.append(
                (
                    "structured_manifest_json_minimal",
                    lambda: osrs_validate_public_json_tree(structured_json),
                )
            )

            structured_evidence = root / "structured_evidence_json"
            structured_evidence.mkdir()
            (structured_evidence / "TEST-report.json").write_text(
                json.dumps({"system_out": "file:///Users/alice"}), encoding="utf-8"
            )
            runners.append(
                (
                    "structured_test_evidence_json_minimal",
                    lambda: osrs_validate_public_json_tree(structured_evidence),
                )
            )

            indexed_root = root / "recursive_index_root"
            indexed_root.mkdir()
            external = root / "recursive_index_external"
            external.mkdir()
            leaked_log = external / "referenced.log"
            leaked_log.write_text(
                "build report: file:///Users/alice/project/report.html\n",
                encoding="utf-8",
            )
            (indexed_root / "artifact-index.json").write_text(
                json.dumps(
                    {
                        "artifacts": [
                            {
                                "path": "../recursive_index_external/referenced.log",
                                "sha256": hashlib.sha256(
                                    leaked_log.read_bytes()
                                ).hexdigest(),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            runners.append(
                (
                    "recursively_indexed_external_non_json_artifact",
                    lambda: osrs_validate_public_json_tree(indexed_root),
                )
            )
            runners.append(
                (
                    "common_root_public_tree_control",
                    lambda: osrs_validate_public_release_tree(root),
                )
            )

            self.assertEqual(23, len(runners))
            for name, runner in runners:
                with self.subTest(name=name), self.assertRaises(osrsPublicPathError):
                    runner()

    def test_adjacent_encodings_and_recursive_index_chain_reject(self):
        encoded = {
            "users_root": b"/Users",
            "file_uri_users_root": b"file:///Users",
            "windows_drive_root": br"C:\Users",
            "windows_rooted_root": br"\build-root",
            "windows_unc_forward": b"//server/share",
            "percent": b"%2FUsers%2Falice",
            "double_percent": b"%252Fhome%252Frunner",
            "html": b"&#x2F;tmp&#x2F;build",
            "unicode_escape": br"\u002fUsers\u002falice",
            "hex": "/home/runner".encode().hex().encode(),
            "base64": base64.b64encode(b"file:///Users/alice"),
            "utf16le": "/Users/alice".encode("utf-16le"),
            "utf16be": "/home/runner".encode("utf-16be"),
            "prose_punctuation": b"report:file:///Users/alice), then continue",
        }
        for name, value in encoded.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "payload.bin").write_bytes(b"prefix\0" + value + b"\0suffix")
                with self.assertRaises(osrsPublicPathError):
                    osrs_validate_public_artifact_closure(root)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "evidence/logs").mkdir(parents=True)
            leaked = root / "evidence/logs/final.log"
            leaked.write_text("file:///Users/alice/report.html\n", encoding="utf-8")
            nested = root / "evidence/nested-index.json"
            nested.write_text(
                json.dumps({"logs": [{"path": "logs/final.log"}]}),
                encoding="utf-8",
            )
            (root / "artifact-index.json").write_text(
                json.dumps({"artifacts": [{"path": "evidence/nested-index.json"}]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(osrsPublicPathError, "evidence/logs/final.log"):
                osrs_validate_public_json_tree(root)

    def test_clean_binary_controls_do_not_trigger_broad_false_positives(self):
        controls = (
            b"/system/lib64/libc.so\0/tmp\0file://\0",
            b"K:/K\0~/n ]\0\\Landroidx/activity/ComponentActivity;\0",
            b"// this/source-style comment has whitespace and prose\0",
            b"(?:[a-zA-Z0-9\\$\\-\\_\\.]+)\0",
            b"4d61704c6962726520706f727461626c65\0",
            b"cG9ydGFibGUtdmFsdWU=\0",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "portable.bin").write_bytes(b"".join(controls))
            report = osrs_validate_public_artifact_closure(root)
            self.assertEqual(0, report["findings_count"])

    def test_recursive_container_limits_fail_closed_with_provenance(self):
        inner = self._nested_zip_bytes("payload.txt", b"portable")
        outer = self._nested_zip_bytes("nested.zip", inner)
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "outer.apk"
            archive.write_bytes(outer)
            limits = replace(OSRS_DEFAULT_PATH_SCAN_LIMITS, max_container_depth=0)
            with self.assertRaisesRegex(
                osrsPublicPathError, r"outer\.apk!/nested\.zip"
            ):
                osrs_validate_public_archive(archive, limits=limits)

            limits = replace(OSRS_DEFAULT_PATH_SCAN_LIMITS, max_container_members=1)
            with self.assertRaisesRegex(osrsPublicPathError, "member limit"):
                osrs_validate_public_archive(archive, limits=limits)

            limits = replace(OSRS_DEFAULT_PATH_SCAN_LIMITS, max_raw_container_bytes=32)
            with self.assertRaisesRegex(osrsPublicPathError, "raw ZIP/APK container"):
                osrs_validate_public_archive(archive, limits=limits)

            limits = replace(OSRS_DEFAULT_PATH_SCAN_LIMITS, max_raw_region_count=2)
            with self.assertRaisesRegex(osrsPublicPathError, "region count"):
                osrs_validate_public_archive(archive, limits=limits)

            ratio_archive = Path(directory) / "ratio.apk"
            self._write_archive(ratio_archive, "large.txt", b"A" * 4096)
            limits = replace(OSRS_DEFAULT_PATH_SCAN_LIMITS, max_compression_ratio=2.0)
            with self.assertRaisesRegex(osrsPublicPathError, "compression ratio"):
                osrs_validate_public_archive(ratio_archive, limits=limits)

    def test_archive_and_tree_links_or_traversal_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            traversal = root / "traversal.apk"
            self._write_archive(traversal, "../outside.log", b"portable")
            with self.assertRaisesRegex(osrsPublicPathError, "escapes its container"):
                osrs_validate_public_archive(traversal)

            linked_directory = root / "linked-directory"
            real_directory = root / "real-directory"
            real_directory.mkdir()
            linked_directory.symlink_to(real_directory, target_is_directory=True)
            with self.assertRaisesRegex(osrsPublicPathError, "symlink"):
                osrs_validate_public_artifact_closure(root)

    def test_index_integrity_rejects_missing_escape_hash_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = root / "artifact-index.json"
            index.write_text(
                json.dumps({"artifacts": [{"path": "missing.log"}]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(osrsPublicPathError, "unresolved"):
                osrs_validate_public_json_tree(root)

            outside = root.parent / f"{root.name}-outside.log"
            outside.write_text("portable", encoding="utf-8")
            try:
                index.write_text(
                    json.dumps({"artifacts": [{"path": f"../{outside.name}"}]}),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(osrsPublicPathError, "escapes"):
                    osrs_validate_public_json_tree(root)
            finally:
                outside.unlink()

            artifact = root / "retained.log"
            artifact.write_text("portable", encoding="utf-8")
            index.write_text(
                json.dumps(
                    {
                        "artifacts": [
                            {"path": "retained.log", "sha256": "0" * 64}
                        ]
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(osrsPublicPathError, "SHA-256 mismatch"):
                osrs_validate_public_json_tree(root)

            symlink = root / "linked.log"
            symlink.symlink_to(artifact)
            index.write_text(
                json.dumps({"artifacts": [{"path": "linked.log"}]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(osrsPublicPathError, "symlink"):
                osrs_validate_public_json_tree(root)


if __name__ == "__main__":
    unittest.main()
