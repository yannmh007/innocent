// Media seal v1 — WebCrypto implementation (edge functions, the console, Node).
//
// The format is Google Tink's AES-GCM-HKDF streaming AEAD with a 64 KiB
// ciphertext segment, a 32-byte DEK, AES-256 and HKDF-SHA256. The reference
// implementation and the reasons are in tool/media_seal.py and
// docs/MEDIA_ENCRYPTION.md; tool/js/media_seal_test.mjs checks this file
// against the shared vectors (test/fixtures/media_seal_vectors.json), which Tink itself
// opens.
//
// Plain ES module, no dependencies: Deno imports it from docs/edge, the
// console from ../edge/media_seal.js, Node from the tests.

export const SEGMENT = 65536;
export const TAG = 16;
export const SALT = 32;
export const PREFIX = 7;
export const HEADER = 1 + SALT + PREFIX; // 40
export const PLAIN_SEGMENT = SEGMENT - TAG; // 65520
export const FIRST_PLAIN = SEGMENT - HEADER - TAG; // 65480
const AAD_PREFIX = 'inv-media-v1|';

export class SealError extends Error {}

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();

/** @param {string} dekId */
export function aadFor(dekId) {
  return enc.encode(AAD_PREFIX + dekId);
}

// ---- sizes and offsets -------------------------------------------------------

/** @param {number} plain */
export function segmentCount(plain) {
  if (plain <= FIRST_PLAIN) return 1;
  return 1 + Math.ceil((plain - FIRST_PLAIN) / PLAIN_SEGMENT);
}

/** @param {number} plain */
export function sealedSize(plain) {
  return HEADER + plain + TAG * segmentCount(plain);
}

/** The plaintext size of a sealed object, from its size alone. */
export function plainSize(sealed) {
  if (sealed < HEADER + TAG) throw new SealError(`too short to be sealed: ${sealed} bytes`);
  const full = Math.floor(sealed / SEGMENT);
  const count = full + (sealed % SEGMENT ? 1 : 0);
  const n = sealed - HEADER - TAG * count;
  if (n < 0 || sealedSize(n) !== sealed) throw new SealError(`no plaintext seals to ${sealed} bytes`);
  return n;
}

export function plainStart(i) {
  return i === 0 ? 0 : FIRST_PLAIN + (i - 1) * PLAIN_SEGMENT;
}

export function sealedStart(i) {
  return i === 0 ? HEADER : i * SEGMENT;
}

export function segmentOf(plainOffset) {
  if (plainOffset < FIRST_PLAIN) return 0;
  return 1 + Math.floor((plainOffset - FIRST_PLAIN) / PLAIN_SEGMENT);
}

/** Sealed bytes [start, end) covering plaintext [first, last] (inclusive). */
export function sealedRangeFor(first, last, plainTotal) {
  if (!(first >= 0 && first <= last && last < Math.max(plainTotal, 1))) {
    throw new SealError(`range ${first}-${last} outside ${plainTotal}`);
  }
  const a = segmentOf(first);
  const b = segmentOf(last);
  const count = segmentCount(plainTotal);
  const end = b + 1 < count ? sealedStart(b + 1) : sealedSize(plainTotal);
  return { start: sealedStart(a), end, first: a, last: b };
}

// ---- the cipher --------------------------------------------------------------

async function derive(dek, salt, aad, usages) {
  if (dek.length !== 32) throw new SealError(`a DEK is 32 bytes, not ${dek.length}`);
  const ikm = await subtle.importKey('raw', dek, 'HKDF', false, ['deriveBits']);
  const bits = await subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info: aad }, ikm, 256);
  return subtle.importKey('raw', bits, { name: 'AES-GCM' }, false, usages);
}

function nonce(prefix, i, last) {
  const n = new Uint8Array(12);
  n.set(prefix, 0);
  new DataView(n.buffer).setUint32(PREFIX, i, false);
  n[11] = last ? 1 : 0;
  return n;
}

export function randomBytes(n) {
  const b = new Uint8Array(n);
  // getRandomValues takes at most 65536 bytes a call.
  for (let at = 0; at < n; at += 65536) {
    globalThis.crypto.getRandomValues(b.subarray(at, Math.min(n, at + 65536)));
  }
  return b;
}

/** Seals one object segment by segment; the plaintext size must be known. */
export class Sealer {
  /**
   * @param {Uint8Array} dek
   * @param {Uint8Array} aad
   * @param {number} plainTotal
   * @param {{salt?: Uint8Array, prefix?: Uint8Array}} [fixed] test vectors, and
   *   the console resuming an upload whose header is already in R2 — only ever
   *   over the SAME plaintext (each part's SHA-256 is checked first): a
   *   repeated (DEK, salt, prefix) over different plaintext breaks GCM.
   */
  static async create(dek, aad, plainTotal, fixed = {}) {
    const salt = fixed.salt ?? randomBytes(SALT);
    const prefix = fixed.prefix ?? randomBytes(PREFIX);
    if (salt.length !== SALT || prefix.length !== PREFIX) throw new SealError('bad salt or prefix size');
    const s = new Sealer();
    s.key = await derive(dek, salt, aad, ['encrypt']);
    s.prefix = prefix;
    s.count = segmentCount(plainTotal);
    s.plainTotal = plainTotal;
    s.header = new Uint8Array(HEADER);
    s.header[0] = HEADER;
    s.header.set(salt, 1);
    s.header.set(prefix, 1 + SALT);
    return s;
  }

  /** The plaintext length segment i must be given. */
  plainLength(i) {
    const full = i === 0 ? FIRST_PLAIN : PLAIN_SEGMENT;
    return Math.min(full, this.plainTotal - plainStart(i));
  }

  async sealSegment(i, plain) {
    if (!(i >= 0 && i < this.count)) throw new SealError(`segment ${i} of ${this.count}`);
    if (plain.length !== this.plainLength(i)) {
      throw new SealError(`segment ${i} wants ${this.plainLength(i)} bytes, got ${plain.length}`);
    }
    const out = await subtle.encrypt(
      { name: 'AES-GCM', iv: nonce(this.prefix, i, i === this.count - 1), tagLength: 128 },
      this.key, plain);
    return new Uint8Array(out);
  }
}

/** Opens any segment of one sealed object, in any order. */
export class Opener {
  static async create(dek, aad, header, plainTotal) {
    if (header.length < HEADER || header[0] !== HEADER) throw new SealError('not a media seal v1 header');
    const o = new Opener();
    o.prefix = header.slice(1 + SALT, HEADER);
    o.key = await derive(dek, header.slice(1, 1 + SALT), aad, ['decrypt']);
    o.count = segmentCount(plainTotal);
    o.plainTotal = plainTotal;
    return o;
  }

  async openSegment(i, sealed) {
    if (!(i >= 0 && i < this.count)) throw new SealError(`segment ${i} of ${this.count}`);
    try {
      const out = await subtle.decrypt(
        { name: 'AES-GCM', iv: nonce(this.prefix, i, i === this.count - 1), tagLength: 128 },
        this.key, sealed);
      return new Uint8Array(out);
    } catch (_) {
      throw new SealError(`segment ${i} does not open`);
    }
  }
}

// ---- a sealed object uploaded in parts (the console, §7.3) -----------------
//
// A part of PART_SIZE sealed bytes, a whole number of 64 KiB segments, is
// sealed on its own from the plaintext that makes it — part 1 also carries
// the header — so each 16 MiB part of a multipart upload is sealed, sent and
// retried alone, and every part but the last is exactly PART_SIZE, as R2
// requires.

function wholeSegments(partSize) {
  if (!(partSize > 0) || partSize % SEGMENT) throw new SealError('a part must be whole segments');
  return partSize / SEGMENT;
}

/** How many parts of [partSize] sealed bytes the sealed object has. */
export function sealedPartCount(partSize, plainTotal) {
  wholeSegments(partSize);
  return Math.ceil(sealedSize(plainTotal) / partSize);
}

/** The plaintext [start, end) that sealed part [n] (1-based) is made of. */
export function partPlainRange(n, partSize, plainTotal) {
  const per = wholeSegments(partSize);
  const count = segmentCount(plainTotal);
  const first = (n - 1) * per;
  if (!(n >= 1) || first >= count) throw new SealError(`part ${n} is past the end`);
  const last = Math.min(count, first + per);
  return [plainStart(first), last >= count ? plainTotal : plainStart(last)];
}

/** Sealed part [n] (1-based) from exactly its plaintext (partPlainRange). */
export async function sealPart(sealer, n, partSize, plain) {
  const per = wholeSegments(partSize);
  const first = (n - 1) * per;
  const last = Math.min(sealer.count, first + per);
  const [p0, p1] = partPlainRange(n, partSize, sealer.plainTotal);
  if (plain.length !== p1 - p0) {
    throw new SealError(`part ${n} wants ${p1 - p0} plaintext bytes, got ${plain.length}`);
  }
  const start = (n - 1) * partSize;
  const end = last >= sealer.count ? sealedSize(sealer.plainTotal) : last * SEGMENT;
  const out = new Uint8Array(end - start);
  let at = 0;
  if (first === 0) {
    out.set(sealer.header, 0);
    at = HEADER;
  }
  for (let i = first; i < last; i++) {
    const s0 = plainStart(i) - p0;
    const seg = await sealer.sealSegment(i, plain.subarray(s0, s0 + sealer.plainLength(i)));
    out.set(seg, at);
    at += seg.length;
  }
  if (at !== out.length) throw new SealError(`part ${n} sealed to ${at} bytes, not ${out.length}`);
  return out;
}

/** Seals a whole buffer (images, tests). */
export async function sealAll(plain, dek, aad, fixed) {
  const s = await Sealer.create(dek, aad, plain.length, fixed);
  const out = new Uint8Array(sealedSize(plain.length));
  out.set(s.header, 0);
  for (let i = 0; i < s.count; i++) {
    const p0 = plainStart(i);
    const seg = await s.sealSegment(i, plain.subarray(p0, p0 + s.plainLength(i)));
    out.set(seg, sealedStart(i));
  }
  return out;
}

/** Opens a whole sealed buffer, checking every segment and the end mark. */
export async function openAll(sealed, dek, aad) {
  const total = plainSize(sealed.length);
  const o = await Opener.create(dek, aad, sealed.subarray(0, HEADER), total);
  const out = new Uint8Array(total);
  for (let i = 0; i < o.count; i++) {
    const end = i + 1 < o.count ? sealedStart(i + 1) : sealed.length;
    out.set(await o.openSegment(i, sealed.subarray(sealedStart(i), end)), plainStart(i));
  }
  return out;
}
