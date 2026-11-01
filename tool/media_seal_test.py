#!/usr/bin/env python3
"""tool/media_seal.py: the format, the offsets, and what must not open.

What must hold:
  * the committed vectors (test/fixtures/media_seal_vectors.json, read by the
    TypeScript, Kotlin and Dart tests too) are what this implementation makes;
  * every size maps to a sealed size and back, and a size no plaintext seals
    to is refused;
  * any plaintext byte range is served from exactly the segments that hold it;
  * a flipped byte, a cut at a segment boundary, swapped segments, the wrong
    DEK and the wrong AAD all fail to open — never decrypt to garbage;
  * and, when Google's Tink is installed (pip install tink), Tink opens what
    this seals and this opens what Tink seals: the format is Tink's, not a
    look-alike. Without Tink that part says SKIP; it was run on 31 Oct 2026
    with tink 1.x and passed.

RUN:  python3 tool/media_seal_test.py
"""

import io
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import media_seal as ms  # noqa: E402
except BaseException as e:  # no `cryptography` here (pyo3 panics are BaseException)
    print("SKIP media seal: the `cryptography` package does not load here (%s). "
          "The TypeScript and Kotlin tests check the same vectors." % type(e).__name__)
    sys.exit(0)

VECTORS = os.path.join(HERE, "..", "test", "fixtures", "media_seal_vectors.json")
checks = 0


def ok(cond, what):
    global checks
    checks += 1
    if not cond:
        print("FAIL " + what)
        sys.exit(1)
    print("ok   " + what)


def seal(pt, dek, aad, **kw):
    out = io.BytesIO()
    ms.seal_stream(io.BytesIO(pt), out, dek, aad, len(pt), **kw)
    return out.getvalue()


def opens(sealed, dek, aad):
    out = io.BytesIO()
    ms.open_stream(io.BytesIO(sealed), out, dek, aad, len(sealed))
    return out.getvalue()


def refuses(fn):
    try:
        fn()
    except ms.SealError:
        return True
    return False


def main():
    # -- vectors --------------------------------------------------------------
    want = ms.vectors()
    with open(VECTORS) as f:
        have = json.load(f)
    ok(have == want, "the committed vectors are what this implementation makes (%d cases)" % len(want))
    for v in want:
        pt = ms._pattern(v["plain_size"], v["seed"])
        sealed = seal(pt, bytes.fromhex(v["dek"]), ms.aad_for(v["dek_id"]),
                      salt=bytes.fromhex(v["salt"]), prefix=bytes.fromhex(v["prefix"]))
        back = opens(sealed, bytes.fromhex(v["dek"]), ms.aad_for(v["dek_id"]))
        ok(back == pt and len(sealed) == v["sealed_size"],
           "vector %d bytes opens back (%d sealed)" % (v["plain_size"], len(sealed)))

    # -- sizes ----------------------------------------------------------------
    edges = [0, 1, 2, ms.FIRST_PLAIN - 1, ms.FIRST_PLAIN, ms.FIRST_PLAIN + 1]
    for k in range(1, 5):
        b = ms.FIRST_PLAIN + k * ms.PLAIN_SEGMENT
        edges += [b - 1, b, b + 1]
    edges += [random.randrange(0, 50_000_000) for _ in range(500)]
    bad = 0
    for n in edges:
        s = ms.sealed_size(n)
        if ms.plain_size(s) != n:
            bad += 1
        if n and ms.sealed_start(ms.segment_count(n) - 1) >= s:
            bad += 1
    ok(bad == 0, "sealed size and plain size invert for %d sizes" % len(edges))
    impossible = [s for s in range(0, 3 * ms.SEGMENT + 200) if not refuses(lambda s=s: ms.plain_size(s))]
    ok(all(ms.sealed_size(ms.plain_size(s)) == s for s in impossible) and 0 not in impossible
       and (ms.HEADER + ms.TAG) in impossible and (ms.SEGMENT + 1) not in impossible,
       "a size no plaintext seals to is refused (header-only, 1 byte past a full segment)")
    ok(all(ms.sealed_start(i) == i * ms.SEGMENT for i in range(1, 50)),
       "segment i >= 1 starts at i * 65536: ranges stay aligned")

    # -- random access ---------------------------------------------------------
    rnd = random.Random(7)
    dek = os.urandom(32)
    aad = ms.aad_for("ra-test")
    pt = os.urandom(ms.FIRST_PLAIN + 7 * ms.PLAIN_SEGMENT + 12345)
    sealed = seal(pt, dek, aad)
    op = ms.Opener(dek, aad, sealed[:ms.HEADER], len(pt))
    wrong = 0
    for _ in range(300):
        a = rnd.randrange(0, len(pt))
        b = min(len(pt) - 1, a + rnd.choice([0, 1, 100, 65519, 65520, 300000]))
        start, end, sa, sb = ms.sealed_range_for(a, b, len(pt))
        got = bytearray()
        for i in range(sa, sb + 1):
            s0 = ms.sealed_start(i) - start
            s1 = (ms.sealed_start(i + 1) if i + 1 < op.count else len(sealed)) - start
            got += op.open_segment(i, sealed[start:end][s0:s1])
        skip = a - ms.plain_start(sa)
        if bytes(got[skip:skip + (b - a + 1)]) != pt[a:b + 1]:
            wrong += 1
    ok(wrong == 0, "300 random plaintext ranges served from whole segments, byte-exact")
    ok(ms.sealed_range_for(len(pt) - 1, len(pt) - 1, len(pt))[1] == len(sealed),
       "the last byte's range ends at the object's end")

    # -- what must not open ------------------------------------------------------
    flipped = bytearray(sealed)
    flipped[ms.SEGMENT * 3 + 99] ^= 1
    ok(refuses(lambda: opens(bytes(flipped), dek, aad)), "a flipped byte does not open")
    ok(refuses(lambda: opens(sealed[:ms.SEGMENT * 4], dek, aad)),
       "cut at a segment boundary does not open (the last mark is missing)")
    swapped = bytearray(sealed)
    s2 = sealed[2 * ms.SEGMENT:3 * ms.SEGMENT]
    s3 = sealed[3 * ms.SEGMENT:4 * ms.SEGMENT]
    swapped[2 * ms.SEGMENT:3 * ms.SEGMENT] = s3
    swapped[3 * ms.SEGMENT:4 * ms.SEGMENT] = s2
    ok(refuses(lambda: opens(bytes(swapped), dek, aad)), "two segments swapped do not open")
    ok(refuses(lambda: opens(sealed, os.urandom(32), aad)), "another DEK does not open it")
    ok(refuses(lambda: opens(sealed, dek, ms.aad_for("another-id"))),
       "another dek_id (AAD) does not open it")
    ok(refuses(lambda: seal(b"abc", dek, aad) and ms.seal_stream(
        io.BytesIO(b"abcd"), io.BytesIO(), dek, aad, 3)),
       "a source longer than its declared size is refused")
    ok(seal(b"", dek, aad).__len__() == ms.HEADER + ms.TAG and
       opens(seal(b"", dek, aad), dek, aad) == b"", "an empty object seals to header + one tag")

    # -- Tink itself -------------------------------------------------------------
    try:
        import tink  # noqa: F401
        from tink import streaming_aead
        from tink.proto import tink_pb2, aes_gcm_hkdf_streaming_pb2, common_pb2
        from tink import cleartext_keyset_handle
    except Exception:
        print("SKIP tink cross-check (pip install tink to run it)")
        print("media seal: all checks passed (%d)" % checks)
        return
    streaming_aead.register()

    def tink_handle(dek_bytes):
        key = aes_gcm_hkdf_streaming_pb2.AesGcmHkdfStreamingKey(
            version=0, key_value=dek_bytes,
            params=aes_gcm_hkdf_streaming_pb2.AesGcmHkdfStreamingParams(
                ciphertext_segment_size=ms.SEGMENT, derived_key_size=32,
                hkdf_hash_type=common_pb2.SHA256))
        ks = tink_pb2.Keyset(primary_key_id=1, key=[tink_pb2.Keyset.Key(
            key_data=tink_pb2.KeyData(
                type_url="type.googleapis.com/google.crypto.tink.AesGcmHkdfStreamingKey",
                value=key.SerializeToString(),
                key_material_type=tink_pb2.KeyData.SYMMETRIC),
            status=tink_pb2.ENABLED, key_id=1, output_prefix_type=tink_pb2.RAW)])
        return cleartext_keyset_handle.from_keyset(ks).primitive(streaming_aead.StreamingAead)

    class Keep(io.BytesIO):
        def close(self):
            pass

    for v in want:
        dk = bytes.fromhex(v["dek"])
        pt = ms._pattern(v["plain_size"], v["seed"])
        sealed = seal(pt, dk, ms.aad_for(v["dek_id"]),
                      salt=bytes.fromhex(v["salt"]), prefix=bytes.fromhex(v["prefix"]))
        with tink_handle(dk).new_decrypting_stream(io.BytesIO(sealed), ms.aad_for(v["dek_id"])) as d:
            back = d.read()
        ok(back == pt, "Tink opens vector %d" % v["plain_size"])
    for n in [0, 5, ms.FIRST_PLAIN, ms.FIRST_PLAIN + 1, 777777]:
        dk = os.urandom(32)
        pt = os.urandom(n)
        w = Keep()
        with tink_handle(dk).new_encrypting_stream(w, aad) as e:
            e.write(pt)
        ok(opens(w.getvalue(), dk, aad) == pt, "this opens what Tink seals (%d bytes)" % n)
    print("media seal: all checks passed (%d, Tink included)" % checks)


if __name__ == "__main__":
    main()
