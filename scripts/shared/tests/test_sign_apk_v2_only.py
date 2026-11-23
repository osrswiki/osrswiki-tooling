from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

SHARED = Path(__file__).resolve().parents[1]
if str(SHARED) not in sys.path:
    sys.path.insert(0, str(SHARED))

from inspect_apk_signing_block import parse_signing_block  # noqa: E402
from sign_apk_v2_only import (  # noqa: E402
    MAGIC,
    V2_ID,
    build_signed_data,
    build_v2_value,
    signing_block_for_v2_value,
)
from test_inspect_apk_signing_block import (  # noqa: E402
    BREW_ID,
    build_zip_bytes,
    insert_signing_block,
)


class SignApkV2OnlyLayoutTests(unittest.TestCase):
    def test_signing_block_is_v2_only_without_brew(self) -> None:
        signed_data = build_signed_data(b"\x00" * 32, b"\x11" * 770)
        v2_value = build_v2_value(signed_data, b"\x22" * 256, b"\x33" * 294)
        block = signing_block_for_v2_value(v2_value)
        self.assertTrue(block.endswith(MAGIC))
        self.assertEqual(struct.unpack_from("<Q", block, 0)[0], len(block) - 8)

        with tempfile.TemporaryDirectory() as directory:
            unsigned = build_zip_bytes({"classes.dex": b"dex\n"})
            eocd = len(unsigned) - 22
            cd = struct.unpack_from("<I", unsigned, eocd + 16)[0]
            signed = unsigned[:cd] + block + unsigned[cd:]
            signed = bytearray(signed)
            struct.pack_into("<I", signed, len(signed) - 6, cd + len(block))
            apk_path = Path(directory) / "signed.apk"
            apk_path.write_bytes(bytes(signed))
            pairs = parse_signing_block(apk_path)
            self.assertEqual(len(pairs), 1)
            self.assertEqual(pairs[0][0], V2_ID)
            self.assertNotIn(BREW_ID, [pair_id for pair_id, _ in pairs])

    def test_brew_pair_is_detectable_on_sdk_style_blocks(self) -> None:
        payload = insert_signing_block(
            build_zip_bytes({"classes.dex": b"dex\n"}),
            [(V2_ID, b"v2"), (BREW_ID, b"\x00" * 32)],
        )

        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "brew.apk"
            apk.write_bytes(payload)
            pairs = parse_signing_block(apk)
            self.assertEqual([pair_id for pair_id, _ in pairs], [V2_ID, BREW_ID])
