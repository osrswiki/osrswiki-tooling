#!/usr/bin/env python3
"""Sign an unsigned APK with APK Signature Scheme v2 only (no padding pair).

SDK apksigner 35/36 always writes Verity/Brew padding (0x42726577), which
F-Droid's extra-blocks gate rejects. This signer emits the same v2-only
block layout as live 2.1.4 / 2.1.5.

Reads the PKCS12 keystore named by OSRSWIKI_ANDROID_SIGNING_PROPERTIES
(storeFile may still use a .jks suffix). Never prints secrets.

cryptography is imported inside load_key so block-layout unit tests stay
on stdlib; publish-foss-apk.sh runs this with a Python that provides
cryptography (fdroid-tools pixi).
"""
from __future__ import annotations

import hashlib
import os
import struct
import sys
from pathlib import Path

V2_ID = 0x7109871A
SIG_RSA_PKCS1_SHA256 = 0x0103
CHUNK = 1024 * 1024
MAGIC = b"APK Sig Block 42"


def load_props(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#") or "=" not in trimmed:
            continue
        key, value = trimmed.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def u32(n: int) -> bytes:
    return struct.pack("<I", n)


def u64(n: int) -> bytes:
    return struct.pack("<Q", n)


def prefixed(data: bytes) -> bytes:
    return u32(len(data)) + data


def chunked_sha256(parts: list[bytes]) -> bytes:
    """APK Sig v2 chunked SHA-256. Each DataSource is chunked separately."""
    digests = []
    for total in parts:
        offset = 0
        while offset < len(total):
            piece = total[offset : offset + CHUNK]
            h = hashlib.sha256()
            h.update(b"\xa5")
            h.update(u32(len(piece)))
            h.update(piece)
            digests.append(h.digest())
            offset += len(piece)
    top = hashlib.sha256()
    top.update(b"\x5a")
    top.update(u32(len(digests)))
    top.update(b"".join(digests))
    return top.digest()


def find_eocd(data: bytes) -> int:
    if data[-22:-18] == b"PK\x05\x06" and data[-2:] == b"\x00\x00":
        return len(data) - 22
    pos = data.rfind(b"PK\x05\x06")
    if pos < 0:
        raise SystemExit("EOCD not found")
    return pos


def load_key(props: dict[str, str]):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.serialization import pkcs12

    blob = Path(props["storeFile"]).read_bytes()
    password = props["storePassword"].encode("utf-8")
    key, cert, _additional = pkcs12.load_key_and_certificates(blob, password)
    if key is None or cert is None:
        raise SystemExit("pkcs12 keystore missing key or certificate")
    return key, cert.public_bytes(serialization.Encoding.DER)


def build_signed_data(digest: bytes, cert: bytes) -> bytes:
    digest_entry = u32(SIG_RSA_PKCS1_SHA256) + prefixed(digest)
    # Nested length prefixes match APK Sig v2 and live 2.1.4:
    # digests list, certs list, empty attrs, trailing uint32 0.
    return (
        prefixed(prefixed(digest_entry))
        + prefixed(prefixed(cert))
        + prefixed(b"")
        + u32(0)
    )


def build_v2_value(signed_data: bytes, signature: bytes, public_key: bytes) -> bytes:
    sig_entry = u32(SIG_RSA_PKCS1_SHA256) + prefixed(signature)
    signer = prefixed(signed_data) + prefixed(prefixed(sig_entry)) + prefixed(public_key)
    return prefixed(prefixed(signer))


def signing_block_for_v2_value(v2_value: bytes) -> bytes:
    pair = u64(4 + len(v2_value)) + u32(V2_ID) + v2_value
    # footer size field counts pairs + footer size + magic
    size = len(pair) + 8 + 16
    return u64(size) + pair + u64(size) + MAGIC


def sign_apk(unsigned: Path, output: Path, props: dict[str, str]) -> None:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    data = unsigned.read_bytes()
    eocd = find_eocd(data)
    cd = struct.unpack_from("<I", data, eocd + 16)[0]
    if cd > eocd:
        raise SystemExit("invalid CD offset")
    before_cd = data[:cd]
    central_dir = data[cd:eocd]
    eocd_bytes = bytearray(data[eocd:])
    key, cert = load_key(props)
    public_key = key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    dummy_signed = build_signed_data(b"\x00" * 32, cert)
    dummy_value = build_v2_value(dummy_signed, b"\x00" * 256, public_key)
    dummy_block = signing_block_for_v2_value(dummy_value)
    block_on_disk = len(dummy_block)
    signed_cd = cd + block_on_disk

    # Verifier digests EOCD with the original CD offset (signing-block start),
    # then the written EOCD uses the post-block CD offset.
    digest = chunked_sha256([before_cd, central_dir, bytes(eocd_bytes)])
    struct.pack_into("<I", eocd_bytes, 16, signed_cd)
    signed_data = build_signed_data(digest, cert)
    signature = key.sign(signed_data, padding.PKCS1v15(), hashes.SHA256())
    v2_value = build_v2_value(signed_data, signature, public_key)
    block = signing_block_for_v2_value(v2_value)
    if len(block) != block_on_disk:
        raise SystemExit(
            f"signing block size changed: dummy {block_on_disk} real {len(block)}"
        )

    output.write_bytes(before_cd + block + central_dir + bytes(eocd_bytes))
    print(
        "signed_v2_only",
        str(output),
        "v2_value_len",
        len(v2_value),
        "block",
        block_on_disk,
    )


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sign_apk_v2_only.py <unsigned.apk> <out.apk>", file=sys.stderr)
        return 2
    props_path = Path(
        os.environ.get(
            "OSRSWIKI_ANDROID_SIGNING_PROPERTIES",
            str(Path.home() / ".config/osrswiki/android-signing.properties"),
        )
    )
    props = load_props(props_path)
    sign_apk(Path(sys.argv[1]), Path(sys.argv[2]), props)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
