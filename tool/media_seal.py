#!/usr/bin/env python3
"""Media seal v1 — the reference implementation (see docs/MEDIA_ENCRYPTION.md).

Every photo and video in R2 is stored in this format. The storage provider
holds only ciphertext: the key of each object (its DEK) lives in the database,
wrapped by MEDIA_KEK, and reaches a phone only inside a playback grant.

THE FORMAT IS TINK'S, NOT OURS. It is AES-GCM-HKDF streaming AEAD exactly as
Google Tink defines it (AesGcmHkdfStreaming), with these parameters:

    key size            32 bytes (the DEK)
    derived key size    32 bytes (AES-256)
    HKDF hash           SHA-256
    ciphertext segment  65536 bytes

so a sealed object is

    header   = 0x28 || salt (32) || nonce_prefix (7)                40 bytes
    segment0 = AES-GCM(k, prefix || be32(0) || last, pt[0:65480])   <= 65496
    segment i= AES-GCM(k, prefix || be32(i) || last, pt[...65520]) <= 65536
    k        = HKDF-SHA256(ikm = DEK, salt = salt, info = AAD, 32)

with `last` = 1 on the final segment only. Segment i >= 1 therefore starts at
ciphertext offset exactly i * 65536, which is what lets a player's byte range
be served from whole segments with one aligned range request.

Borrowing a reviewed format rather than inventing one is the point: every
implementation here (Python, TypeScript, Kotlin) is tested against Tink itself
(tool/media_seal_test.py), so "it decrypts in our code" also means "it is the
format Google specified".

AAD binds a ciphertext to its key record: b"inv-media-v1|" + dek_id. A file
copied under another name still opens; a file swapped for another one fails.

USE
    python3 tool/media_seal.py seal   IN OUT --dek HEX --dek-id ID
    python3 tool/media_seal.py open   IN OUT --dek HEX --dek-id ID
    python3 tool/media_seal.py vectors > test/fixtures/media_seal_vectors.json
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from typing import BinaryIO, Iterator, Optional

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

SEGMENT = 65536          # ciphertext segment size
TAG = 16                 # GCM tag
SALT = 32                # = derived key size
PREFIX = 7               # nonce prefix
HEADER = 1 + SALT + PREFIX                   # 40
PLAIN_SEGMENT = SEGMENT - TAG                # 65520
FIRST_PLAIN = SEGMENT - HEADER - TAG         # 65480
AAD_PREFIX = b"inv-media-v1|"


class SealError(Exception):
    """A ciphertext that is not what it claims: wrong key, altered, cut short."""


def aad_for(dek_id: str) -> bytes:
    return AAD_PREFIX + dek_id.encode("utf-8")


# ---- sizes and offsets ------------------------------------------------------

def segment_count(plain_size: int) -> int:
    """How many segments a plaintext of this size becomes (an empty one is one)."""
    if plain_size <= FIRST_PLAIN:
        return 1
    return 1 + -(-(plain_size - FIRST_PLAIN) // PLAIN_SEGMENT)


def sealed_size(plain_size: int) -> int:
    return HEADER + plain_size + TAG * segment_count(plain_size)


def plain_size(sealed: int) -> int:
    """The plaintext size of a sealed object, from its size alone."""
    if sealed < HEADER + TAG:
        raise SealError("too short to be sealed: %d bytes" % sealed)
    full, rest = divmod(sealed, SEGMENT)
    count = full + (1 if rest else 0)
    n = sealed - HEADER - TAG * count
    if n < 0 or sealed_size(n) != sealed:
        raise SealError("no plaintext seals to %d bytes" % sealed)
    return n


def plain_start(i: int) -> int:
    """Where segment i's plaintext starts."""
    return 0 if i == 0 else FIRST_PLAIN + (i - 1) * PLAIN_SEGMENT


def sealed_start(i: int) -> int:
    """Where segment i starts in the sealed object."""
    return HEADER if i == 0 else i * SEGMENT


def segment_of(plain_offset: int) -> int:
    """The segment holding plaintext byte `plain_offset`."""
    if plain_offset < FIRST_PLAIN:
        return 0
    return 1 + (plain_offset - FIRST_PLAIN) // PLAIN_SEGMENT


def sealed_range_for(plain_first: int, plain_last: int, plain_total: int):
    """The sealed bytes [start, end) that cover plaintext [first, last]
    (inclusive, as an HTTP range is), and the segments they hold."""
    if not (0 <= plain_first <= plain_last < max(plain_total, 1)):
        raise SealError("range %d-%d outside %d" % (plain_first, plain_last, plain_total))
    a = segment_of(plain_first)
    b = segment_of(plain_last)
    count = segment_count(plain_total)
    end = sealed_start(b + 1) if b + 1 < count else sealed_size(plain_total)
    return sealed_start(a), end, a, b


# ---- the cipher -------------------------------------------------------------

def _derive(dek: bytes, salt: bytes, aad: bytes) -> bytes:
    if len(dek) != 32:
        raise SealError("a DEK is 32 bytes, not %d" % len(dek))
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=aad).derive(dek)


def _nonce(prefix: bytes, i: int, last: bool) -> bytes:
    return prefix + i.to_bytes(4, "big") + (b"\x01" if last else b"\x00")


class Opener:
    """Decrypts any segment of one sealed object, in any order."""

    def __init__(self, dek: bytes, aad: bytes, header: bytes, plain_total: int):
        if len(header) < HEADER or header[0] != HEADER:
            raise SealError("not a media seal v1 header")
        self.prefix = header[1 + SALT:HEADER]
        self.gcm = AESGCM(_derive(dek, header[1:1 + SALT], aad))
        self.count = segment_count(plain_total)
        self.plain_total = plain_total

    def open_segment(self, i: int, sealed_segment: bytes) -> bytes:
        if not 0 <= i < self.count:
            raise SealError("segment %d of %d" % (i, self.count))
        try:
            return self.gcm.decrypt(_nonce(self.prefix, i, i == self.count - 1),
                                    sealed_segment, None)
        except Exception as e:  # InvalidTag
            raise SealError("segment %d does not open" % i) from e


def seal_stream(src: BinaryIO, dst: BinaryIO, dek: bytes, aad: bytes,
                plain_total: int, salt: Optional[bytes] = None,
                prefix: Optional[bytes] = None) -> int:
    """Seals exactly `plain_total` bytes of src into dst. The size must be known
    up front: the last segment is marked, and a reader trusts the mark.

    `salt` and `prefix` are for test vectors only. Leave them None: they must be
    random, and a repeated (DEK, salt, prefix) under different plaintext breaks
    GCM outright."""
    salt = salt if salt is not None else os.urandom(SALT)
    prefix = prefix if prefix is not None else os.urandom(PREFIX)
    if len(salt) != SALT or len(prefix) != PREFIX:
        raise SealError("bad salt or prefix size")
    gcm = AESGCM(_derive(dek, salt, aad))
    dst.write(bytes([HEADER]) + salt + prefix)
    written = HEADER
    count = segment_count(plain_total)
    for i in range(count):
        want = (FIRST_PLAIN if i == 0 else PLAIN_SEGMENT)
        want = min(want, plain_total - plain_start(i))
        chunk = _read_exactly(src, want)
        out = gcm.encrypt(_nonce(prefix, i, i == count - 1), chunk, None)
        dst.write(out)
        written += len(out)
    if src.read(1):
        raise SealError("the source is longer than the size it was sealed as")
    return written


def open_stream(src: BinaryIO, dst: BinaryIO, dek: bytes, aad: bytes,
                sealed_total: int) -> int:
    """Opens a whole sealed object, checking every segment and the end mark."""
    total = plain_size(sealed_total)
    header = _read_exactly(src, HEADER)
    op = Opener(dek, aad, header, total)
    out = 0
    for i in range(op.count):
        size = (sealed_start(i + 1) if i + 1 < op.count else sealed_total) - sealed_start(i)
        plain = op.open_segment(i, _read_exactly(src, size))
        dst.write(plain)
        out += len(plain)
    return out


def _read_exactly(src: BinaryIO, n: int) -> bytes:
    parts = []
    got = 0
    while got < n:
        b = src.read(n - got)
        if not b:
            raise SealError("short read: wanted %d, got %d" % (n, got))
        parts.append(b)
        got += len(b)
    return b"".join(parts)


# ---- test vectors -------------------------------------------------------------

def _pattern(n: int, seed: str) -> bytes:
    """A deterministic plaintext every language can rebuild: SHA-256 in counter
    mode over the seed."""
    out = bytearray()
    i = 0
    while len(out) < n:
        out += hashlib.sha256(("%s:%d" % (seed, i)).encode()).digest()
        i += 1
    return bytes(out[:n])


VECTOR_SIZES = [0, 1, FIRST_PLAIN - 1, FIRST_PLAIN, FIRST_PLAIN + 1,
                FIRST_PLAIN + PLAIN_SEGMENT, FIRST_PLAIN + PLAIN_SEGMENT + 1,
                200000, 1048576]


def vectors() -> list[dict]:
    """Fixed DEK, salt and prefix per case; the plaintext is _pattern(size,
    seed). Each language must produce the same sealed bytes (checked by
    SHA-256, and the first 96 bytes in full) and open them back."""
    out = []
    for n in VECTOR_SIZES:
        seed = "inv-vec-%d" % n
        dek = hashlib.sha256(("dek:" + seed).encode()).digest()
        salt = hashlib.sha256(("salt:" + seed).encode()).digest()
        prefix = hashlib.sha256(("prefix:" + seed).encode()).digest()[:PREFIX]
        dek_id = "00000000-0000-4000-8000-%012d" % n
        import io
        src = io.BytesIO(_pattern(n, seed))
        dst = io.BytesIO()
        seal_stream(src, dst, dek, aad_for(dek_id), n, salt=salt, prefix=prefix)
        sealed = dst.getvalue()
        out.append({
            "plain_size": n,
            "seed": seed,
            "dek": dek.hex(),
            "dek_id": dek_id,
            "salt": salt.hex(),
            "prefix": prefix.hex(),
            "sealed_size": len(sealed),
            "sealed_sha256": hashlib.sha256(sealed).hexdigest(),
            "sealed_head": sealed[:96].hex(),
            "plain_sha256": hashlib.sha256(_pattern(n, seed)).hexdigest(),
        })
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("seal", "open"):
        p = sub.add_parser(name)
        p.add_argument("src")
        p.add_argument("dst")
        p.add_argument("--dek", required=True, help="32 bytes, hex")
        p.add_argument("--dek-id", required=True)
    sub.add_parser("vectors")
    a = ap.parse_args(argv)
    if a.cmd == "vectors":
        import json
        print(json.dumps(vectors(), indent=1))
        return 0
    dek = bytes.fromhex(a.dek)
    with open(a.src, "rb") as s, open(a.dst, "wb") as d:
        size = os.fstat(s.fileno()).st_size
        if a.cmd == "seal":
            seal_stream(s, d, dek, aad_for(a.dek_id), size)
        else:
            open_stream(s, d, dek, aad_for(a.dek_id), size)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
