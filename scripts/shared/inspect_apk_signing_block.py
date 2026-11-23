#!/usr/bin/env python3
"""Inspect APK Signing Block IDs. No secrets. Fail on unexpected extra blocks."""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# Little-endian IDs used in the APK Signing Block.
KNOWN = {
    0x7109871A: "APK Signature Scheme v2",
    0xF05368C0: "APK Signature Scheme v3",
    0x1B93AD61: "APK Signature Scheme v3.1",
    0x42726577: "Verity padding (Brew)",
    0x504B4453: "Dependency metadata (PKDS)",
    0x2146444E: "Source stamp V1 (NDF!)",
    0x6DFF800D: "Source stamp V2",
    0x634F4D43: "Frosting / Play (COMF)",
}

ALLOWED_IDS = {0x7109871A, 0xF05368C0}
MAGIC = b"APK Sig Block 42"


class SigningBlockError(Exception):
    """The APK has no usable APK Signing Block or the block is corrupt."""


def parse_signing_block(apk: Path) -> list[tuple[int, int]]:
    """Return (id, value_len) pairs from the APK Signing Block."""
    data = apk.read_bytes()
    if data[-22:-18] != b"PK\x05\x06":
        eocd = data.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise SigningBlockError("EOCD not found")
    else:
        eocd = len(data) - 22
    cd_offset = struct.unpack_from("<I", data, eocd + 16)[0]
    footer = data[cd_offset - 24 : cd_offset]
    if len(footer) != 24 or footer[8:] != MAGIC:
        raise SigningBlockError(
            f"APK Sig Block magic missing at CD offset {cd_offset}"
        )
    block_size_from_footer = struct.unpack_from("<Q", footer, 0)[0]
    block_start = cd_offset - 8 - block_size_from_footer
    if block_start < 0 or block_start + 8 > len(data):
        raise SigningBlockError("APK Sig Block start is out of range")
    size_at_start = struct.unpack_from("<Q", data, block_start)[0]
    if size_at_start != block_size_from_footer:
        raise SigningBlockError("APK Sig Block size mismatch")
    pairs = data[block_start + 8 : cd_offset - 24]
    out: list[tuple[int, int]] = []
    i = 0
    while i + 12 <= len(pairs):
        pair_len = struct.unpack_from("<Q", pairs, i)[0]
        id_ = struct.unpack_from("<I", pairs, i + 8)[0]
        value_len = pair_len - 4
        out.append((id_, value_len))
        i += 8 + pair_len
        if pair_len < 4:
            raise SigningBlockError("invalid pair length")
    if i != len(pairs):
        raise SigningBlockError(
            f"trailing bytes in signing block pairs: {len(pairs) - i}"
        )
    return out


def format_report(apk: Path, pairs: list[tuple[int, int]]) -> tuple[str, list[tuple[int, str, int]]]:
    extra: list[tuple[int, str, int]] = []
    lines = [f"apk={apk}", f"pair_count={len(pairs)}"]
    for id_, value_len in pairs:
        name = KNOWN.get(id_, "UNKNOWN")
        lines.append(f"id=0x{id_:08X} name={name} value_len={value_len}")
        if id_ not in ALLOWED_IDS:
            extra.append((id_, name, value_len))
    if extra:
        lines.append("SIGNING_BLOCKS_GATE=FAIL extra blocks present")
        for id_, name, value_len in extra:
            lines.append(f"EXTRA 0x{id_:08X} {name} value_len={value_len}")
    else:
        lines.append("SIGNING_BLOCKS_GATE=PASS only v2/v3")
    return "\n".join(lines) + "\n", extra


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("apk")
    args = parser.parse_args(argv)
    apk = Path(args.apk)
    try:
        pairs = parse_signing_block(apk)
    except SigningBlockError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    report, extra = format_report(apk, pairs)
    sys.stdout.write(report)
    return 1 if extra else 0


if __name__ == "__main__":
    sys.exit(main())
