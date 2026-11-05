// A range of a stored object, read as its PLAINTEXT whether the object is
// plain or sealed (docs/MEDIA_ENCRYPTION.md §7.3, ENC-4 step 6).
//
// For the functions that look inside media without serving it — probe-media
// (an MP4's box list and duration), backfill-dimensions (an image's size).
// A sealed object is read as the whole segments that hold the range, each
// opened and checked before a byte of it is used; a segment that does not
// open throws (SealError) — a probe never reports on bytes it could not
// authenticate. No plaintext leaves the function that calls this.
//
// Plain ES module, no dependencies beyond the format: Deno imports it from
// docs/edge, Node from tool/js/media_read_test.mjs.

import {
  aadFor, HEADER, Opener, plainStart, SealError, sealedRangeFor, sealedSize, sealedStart, segmentCount,
} from './media_seal.js';
import { isSealedKey } from './media_twin.js';

/**
 * @typedef {{bytes: Uint8Array, total: number | null}} Got
 * @typedef {{
 *   get: (key: string, first: number, last: number) => Promise<Got | null>,
 *   seal: (key: string) => Promise<{dekId: string, dek: Uint8Array, plainSize: number,
 *                                   header?: Uint8Array | null} | null>,
 * }} ReadIO
 *   get   one ranged read of the stored object, bytes [first, last] inclusive,
 *         and the object's whole size when the store says it (Content-Range)
 *   seal  the key of a sealed object: its DEK (the caller unwraps or reads
 *         it), plaintext size and, when the key row has it, its header
 */

/**
 * Plaintext bytes [start, end) of [key] (clamped to its size) and its
 * plaintext size. Null when the object cannot be read at all.
 *
 * @param {ReadIO} io
 * @param {string} key
 * @param {number} start
 * @param {number} end exclusive
 * @returns {Promise<Got | null>}
 */
export async function readPlain(io, key, start, end) {
  if (!isSealedKey(key)) return await io.get(key, start, end - 1);
  const s = await io.seal(key);
  if (!s) return null;
  // io.seal hands over a DEK of its own; it is zeroed here, whatever happens.
  try {
    const total = s.plainSize;
    const last = Math.min(end, total) - 1;
    if (!(start >= 0) || start > last) return { bytes: new Uint8Array(0), total };
    const range = sealedRangeFor(start, last, total);
    // Without the header in the key row, it is read in the same request.
    const from = s.header ? range.start : 0;
    const got = await io.get(key, from, range.end - 1);
    if (!got) return null;
    if (got.bytes.length !== range.end - from) {
      throw new SealError(`the store answered ${got.bytes.length} bytes, not ${range.end - from}`);
    }
    const header = s.header ?? got.bytes.subarray(0, HEADER);
    const buf = got.bytes.subarray(range.start - from);
    const op = await Opener.create(s.dek, aadFor(s.dekId), header, total);
    const count = segmentCount(total);
    const parts = [];
    let size = 0;
    for (let i = range.first; i <= range.last; i++) {
      const a = sealedStart(i) - range.start;
      const b = (i + 1 < count ? sealedStart(i + 1) : sealedSize(total)) - range.start;
      const p = await op.openSegment(i, buf.subarray(a, b));
      parts.push(p);
      size += p.length;
    }
    const plain = new Uint8Array(size);
    let at = 0;
    for (const p of parts) { plain.set(p, at); at += p.length; }
    const p0 = plainStart(range.first);
    return { bytes: plain.slice(start - p0, last + 1 - p0), total };
  } finally {
    s.dek.fill(0);
  }
}
