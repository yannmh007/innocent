// docs/edge/media_seal.js against the shared vectors (test/fixtures/media_seal_vectors.json),
// which Google Tink opens (tool/media_seal_test.py). Same bytes from the same
// inputs, back to the same plaintext, any range from whole segments, and
// nothing altered, cut or swapped ever opens.
//
//   node tool/js/media_seal_test.mjs

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import * as ms from '../../docs/edge/media_seal.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(path.join(here, '..', '..', 'test', 'fixtures', 'media_seal_vectors.json'), 'utf8'));

let checks = 0;
function ok(cond, what) {
  checks++;
  if (!cond) {
    console.log('FAIL ' + what);
    process.exit(1);
  }
  console.log('ok   ' + what);
}
const hex = (b) => Buffer.from(b).toString('hex');
const unhex = (h) => new Uint8Array(Buffer.from(h, 'hex'));
const sha = (b) => createHash('sha256').update(b).digest('hex');

function pattern(n, seed) {
  const out = new Uint8Array(n);
  let at = 0;
  for (let i = 0; at < n; i++) {
    const d = createHash('sha256').update(`${seed}:${i}`).digest();
    out.set(d.subarray(0, Math.min(32, n - at)), at);
    at += 32;
  }
  return out;
}

async function refuses(fn) {
  try {
    await fn();
  } catch (e) {
    return e instanceof ms.SealError;
  }
  return false;
}

// -- vectors -------------------------------------------------------------------
for (const v of vectors) {
  const pt = pattern(v.plain_size, v.seed);
  ok(sha(pt) === v.plain_sha256, `vector ${v.plain_size}: the plaintext pattern rebuilds`);
  const dek = unhex(v.dek);
  const aad = ms.aadFor(v.dek_id);
  const sealed = await ms.sealAll(pt, dek, aad, { salt: unhex(v.salt), prefix: unhex(v.prefix) });
  ok(sealed.length === v.sealed_size && sha(sealed) === v.sealed_sha256 && hex(sealed.subarray(0, 96)) === v.sealed_head,
    `vector ${v.plain_size}: the same sealed bytes as the reference (${sealed.length})`);
  const back = await ms.openAll(sealed, dek, aad);
  ok(sha(back) === v.plain_sha256, `vector ${v.plain_size}: opens back`);
}

// -- sizes ---------------------------------------------------------------------
let bad = 0;
const sizes = [0, 1, ms.FIRST_PLAIN - 1, ms.FIRST_PLAIN, ms.FIRST_PLAIN + 1];
for (let k = 1; k < 5; k++) {
  const b = ms.FIRST_PLAIN + k * ms.PLAIN_SEGMENT;
  sizes.push(b - 1, b, b + 1);
}
for (let i = 0; i < 400; i++) sizes.push(Math.floor(Math.random() * 6e9));
for (const n of sizes) if (ms.plainSize(ms.sealedSize(n)) !== n) bad++;
ok(bad === 0, `sealed size and plain size invert for ${sizes.length} sizes, past 4 GB too`);
ok(await refuses(() => ms.plainSize(ms.HEADER + ms.TAG - 1)) && await refuses(() => ms.plainSize(ms.SEGMENT + ms.HEADER)) === false,
  'a size too short to be sealed is refused');

// -- random access -------------------------------------------------------------
const dek = ms.randomBytes(32);
const aad = ms.aadFor('ra-test');
const pt = ms.randomBytes(ms.FIRST_PLAIN + 6 * ms.PLAIN_SEGMENT + 999);
const sealed = await ms.sealAll(pt, dek, aad);
const op = await ms.Opener.create(dek, aad, sealed.subarray(0, ms.HEADER), pt.length);
let wrong = 0;
for (let r = 0; r < 200; r++) {
  const a = Math.floor(Math.random() * pt.length);
  const b = Math.min(pt.length - 1, a + [0, 1, 65519, 65520, 200000][r % 5]);
  const rg = ms.sealedRangeFor(a, b, pt.length);
  const chunk = sealed.subarray(rg.start, rg.end);
  const parts = [];
  for (let i = rg.first; i <= rg.last; i++) {
    const s0 = ms.sealedStart(i) - rg.start;
    const s1 = (i + 1 < op.count ? ms.sealedStart(i + 1) : sealed.length) - rg.start;
    parts.push(await op.openSegment(i, chunk.subarray(s0, s1)));
  }
  const got = Buffer.concat(parts);
  const skip = a - ms.plainStart(rg.first);
  if (Buffer.compare(got.subarray(skip, skip + (b - a + 1)), Buffer.from(pt.subarray(a, b + 1))) !== 0) wrong++;
}
ok(wrong === 0, '200 random plaintext ranges served from whole segments, byte-exact');

// -- what must not open ----------------------------------------------------------
const flipped = sealed.slice();
flipped[ms.SEGMENT * 2 + 7] ^= 1;
ok(await refuses(() => ms.openAll(flipped, dek, aad)), 'a flipped byte does not open');
ok(await refuses(() => ms.openAll(sealed.subarray(0, ms.SEGMENT * 3), dek, aad)), 'cut at a segment boundary does not open');
const swapped = sealed.slice();
swapped.set(sealed.subarray(2 * ms.SEGMENT, 3 * ms.SEGMENT), 3 * ms.SEGMENT);
swapped.set(sealed.subarray(3 * ms.SEGMENT, 4 * ms.SEGMENT), 2 * ms.SEGMENT);
ok(await refuses(() => ms.openAll(swapped, dek, aad)), 'two segments swapped do not open');
ok(await refuses(() => ms.openAll(sealed, ms.randomBytes(32), aad)), 'another DEK does not open it');
ok(await refuses(() => ms.openAll(sealed, dek, ms.aadFor('another-id'))), 'another dek_id (AAD) does not open it');
const s = await ms.Sealer.create(dek, aad, 10);
ok(await refuses(() => s.sealSegment(0, new Uint8Array(9))), 'a segment of the wrong length is refused');

console.log(`media seal (js): all checks passed (${checks})`);
