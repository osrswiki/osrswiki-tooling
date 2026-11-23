from __future__ import annotations

import io
import struct
import sys
import unittest
import zipfile
from pathlib import Path

SHARED = Path(__file__).resolve().parents[1]
if str(SHARED) not in sys.path:
    sys.path.insert(0, str(SHARED))

from inspect_apk_signing_block import (  # noqa: E402
    SigningBlockError,
    format_report,
    main,
    parse_signing_block,
)


MAGIC = b"APK Sig Block 42"
V2_ID = 0x7109871A
BREW_ID = 0x42726577
PKDS_ID = 0x504B4453


def build_zip_bytes(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, payload in members.items():
            archive.writestr(name, payload)
    return buffer.getvalue()


def insert_signing_block(zip_bytes: bytes, pairs: list[tuple[int, bytes]]) -> bytes:
    if zip_bytes[-22:-18] != b"PK\x05\x06":
        raise AssertionError("synthetic zip is missing EOCD")
    eocd = len(zip_bytes) - 22
    cd_offset = struct.unpack_from("<I", zip_bytes, eocd + 16)[0]
    pairs_bytes = b""
    for id_, value in pairs:
        pairs_bytes += struct.pack("<Q", 4 + len(value))
        pairs_bytes += struct.pack("<I", id_)
        pairs_bytes += value
    block_size = len(pairs_bytes) + 24
    block = (
        struct.pack("<Q", block_size)
        + pairs_bytes
        + struct.pack("<Q", block_size)
        + MAGIC
    )
    suffix = bytearray(zip_bytes[cd_offset:])
    struct.pack_into("<I", suffix, len(suffix) - 6, cd_offset + len(block))
    return zip_bytes[:cd_offset] + block + bytes(suffix)


class InspectApkSigningBlockTests(unittest.TestCase):
    def write_apk(self, directory: Path, pairs: list[tuple[int, bytes]]) -> Path:
        apk = directory / "app.apk"
        apk.write_bytes(
            insert_signing_block(
                build_zip_bytes({"classes.dex": b"dex\n"}),
                pairs,
            )
        )
        return apk

    def test_v2_only_passes(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            apk = self.write_apk(Path(directory), [(V2_ID, b"v2-signature")])
            pairs = parse_signing_block(apk)
            self.assertEqual(pairs, [(V2_ID, len(b"v2-signature"))])
            report, extra = format_report(apk, pairs)
            self.assertEqual(extra, [])
            self.assertIn("SIGNING_BLOCKS_GATE=PASS only v2/v3", report)
            self.assertEqual(main([str(apk)]), 0)

    def test_brew_padding_fails(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            apk = self.write_apk(
                Path(directory),
                [(V2_ID, b"v2-signature"), (BREW_ID, b"\x00" * 16)],
            )
            pairs = parse_signing_block(apk)
            _, extra = format_report(apk, pairs)
            self.assertEqual(extra[0][0], BREW_ID)
            self.assertEqual(main([str(apk)]), 1)

    def test_dependency_metadata_fails(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            apk = self.write_apk(
                Path(directory),
                [(V2_ID, b"v2-signature"), (PKDS_ID, b"deps")],
            )
            self.assertEqual(main([str(apk)]), 1)

    def test_unsigned_zip_raises(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "unsigned.apk"
            apk.write_bytes(build_zip_bytes({"classes.dex": b"dex\n"}))
            with self.assertRaises(SigningBlockError):
                parse_signing_block(apk)
            self.assertEqual(main([str(apk)]), 2)


if __name__ == "__main__":
    unittest.main()
