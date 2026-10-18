// The edge block cache must hand the player back EXACTLY the bytes it asked
// for, whatever the range, and must share blocks between viewers.
//
// WHY THIS IS TESTED RATHER THAN READ. This is the one function in the whole
// Worker that can corrupt a film: it rebuilds the client's byte range out of
// fixed-size blocks it fetched and cached separately, and an off-by-one in
// the slice math, the block boundaries, a suffix range or an open-ended one
// would hand every viewer with the feature enabled a video that plays as
// noise — with nothing in any log to say why, because each block on its own
// is perfectly valid bytes. So the real `blockSize` and `serveFromBlocks` are
// lifted out of the Worker (never copied — a copy would pass forever while
// the file drifted) and run here against a fake R2 and a fake edge cache,
// and the reassembled output is compared byte-for-byte with the original.
//
// RUN:  node tool/js/edge_blocks_test.mjs
// tool/check.py runs it when node is present, and says so loudly when not.

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { webcrypto } from 'crypto';

globalThis.crypto ??= webcrypto;
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

let failures = 0;
const check = (label, ok) => {
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};

// ── lift the two functions out of the real Worker ────────────────────────
const worker = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');
const from = worker.indexOf('function blockSize(');
const to = worker.indexOf('export default {');
if (from < 0 || to < 0 || to <= from) {
  console.error('could not find blockSize..export default in the Worker');
  process.exit(1);
}
const src = worker.slice(from, to);
const mod = await import('data:text/javascript,' + encodeURIComponent(
  // `serveFromBlocks` reads this module-level const; bind it the same value
  // the Worker declares (docs/worker/src/index.js).
  'const EDGE_TTL_SECONDS = 86400;\n' + src +
  '\nexport { blockSize, serveFromBlocks };'));
const { blockSize, serveFromBlocks } = mod;

// ── a fake edge cache (caches.default) ────────────────────────────────────
//
// Keyed on the request URL, exactly as Cloudflare's is. Stores the body
// bytes and the content type, and hands back a fresh Response on a match so
// the body can be read more than once.
function makeCache() {
  const map = new Map();
  let puts = 0;
  return {
    puts: () => puts,
    entries: () => map.size,
    default: {
      async match(req) {
        const url = typeof req === 'string' ? req : req.url;
        const e = map.get(url);
        if (!e) return undefined;
        return new Response(e.body, { headers: { 'Content-Type': e.ct } });
      },
      async put(req, res) {
        const url = typeof req === 'string' ? req : req.url;
        const ct = res.headers.get('Content-Type') || '';
        const body = new Uint8Array(await res.arrayBuffer());
        map.set(url, { body, ct });
        puts++;
      },
    },
  };
}

// ── a fake R2 binding (env.MEDIA) ─────────────────────────────────────────
//
// One film of known bytes. Counts how many block reads it serves, because
// "the second viewer costs the bucket nothing" is the entire point and the
// only way to prove it is to watch this number stay put.
function makeMedia(bytes, etag = '"testetag"') {
  let gets = 0;
  let heads = 0;
  return {
    gets: () => gets,
    heads: () => heads,
    async head(_key) {
      heads++;
      return { size: bytes.length, httpEtag: etag };
    },
    async get(_key, opts) {
      gets++;
      const { offset, length } = opts.range;
      const slice = bytes.subarray(offset, offset + length);
      return { size: bytes.length, async arrayBuffer() { return slice; } };
    },
  };
}

function makeCtx() {
  const pending = [];
  return {
    ctx: { waitUntil: (p) => pending.push(p) },
    settle: () => Promise.all(pending),
  };
}

const KEY = 'test-003/video/20260922-film-a1b2c3d4.mp4';
const BLOCK = 1024 * 1024; // 1 MB blocks

// A film of 3.5 blocks, every byte a known function of its offset so a single
// wrong byte anywhere is caught.
const SIZE = Math.floor(BLOCK * 3.5) + 12345;
const film = new Uint8Array(SIZE);
for (let i = 0; i < SIZE; i++) film[i] = (i * 2654435761) & 0xff;

function req(range, method = 'GET') {
  const h = new Headers();
  if (range) h.set('Range', range);
  return new Request('https://w/v/token', { method, headers: h });
}

async function bodyOf(res) {
  return new Uint8Array(await res.arrayBuffer());
}

function eqRange(got, s, e) {
  const want = film.subarray(s, e + 1);
  if (got.length !== want.length) return false;
  for (let i = 0; i < got.length; i++) if (got[i] !== want[i]) return false;
  return true;
}

// ── 1. blockSize: off by default, sane when set ───────────────────────────
check('blockSize is 0 when unset (edge caching off by default)',
  blockSize({}) === 0);
check('blockSize is 0 for empty / non-numeric', blockSize({ EDGE_BLOCK_BYTES: '' }) === 0 &&
  blockSize({ EDGE_BLOCK_BYTES: 'abc' }) === 0);
check('blockSize is 0 under 1 MB (noise)', blockSize({ EDGE_BLOCK_BYTES: '500000' }) === 0);
check('blockSize takes a set value', blockSize({ EDGE_BLOCK_BYTES: String(8 * 1024 * 1024) }) === 8 * 1024 * 1024);
check('blockSize is capped at 64 MB', blockSize({ EDGE_BLOCK_BYTES: String(256 * 1024 * 1024) }) === 64 * 1024 * 1024);

// ── 2. every range shape reassembles to the exact original bytes ──────────
const cases = [
  ['whole file (no Range)', null, 0, SIZE - 1, 200],
  ['from zero, part of block 0', 'bytes=0-99', 0, 99, 206],
  ['across a block boundary', `bytes=${BLOCK - 10}-${BLOCK + 10}`, BLOCK - 10, BLOCK + 10, 206],
  ['several whole and partial blocks', `bytes=500000-${BLOCK * 2 + 5000}`, 500000, BLOCK * 2 + 5000, 206],
  ['within one middle block', `bytes=${BLOCK + 100}-${BLOCK + 200}`, BLOCK + 100, BLOCK + 200, 206],
  ['open-ended to EOF', `bytes=${BLOCK * 3}-`, BLOCK * 3, SIZE - 1, 206],
  ['suffix: the last 100 bytes', 'bytes=-100', SIZE - 100, SIZE - 1, 206],
  ['a single byte', 'bytes=0-0', 0, 0, 206],
  ['the very last byte', `bytes=${SIZE - 1}-${SIZE - 1}`, SIZE - 1, SIZE - 1, 206],
  ['end past EOF is clamped', `bytes=${SIZE - 50}-${SIZE + 999}`, SIZE - 50, SIZE - 1, 206],
];

for (const [label, range, s, e, status] of cases) {
  const cache = makeCache();
  globalThis.caches = cache;
  const media = makeMedia(film);
  const { ctx, settle } = makeCtx();
  const res = await serveFromBlocks(req(range), { MEDIA: media }, ctx, KEY, BLOCK, {});
  await settle();
  const ok = res && res.status === status;
  const body = res ? await bodyOf(res) : new Uint8Array();
  check(`${label}: status ${status}`, ok);
  check(`${label}: bytes match the original`, eqRange(body, s, e));
  const cr = res && res.headers.get('Content-Range');
  if (status === 206) {
    check(`${label}: Content-Range is bytes ${s}-${e}/${SIZE}`,
      cr === `bytes ${s}-${e}/${SIZE}`);
  }
  const cl = res && Number(res.headers.get('Content-Length'));
  check(`${label}: Content-Length is the slice length`, cl === e - s + 1);
}

// ── 3. HEAD carries the headers and no body ───────────────────────────────
{
  globalThis.caches = makeCache();
  const media = makeMedia(film);
  const { ctx, settle } = makeCtx();
  const res = await serveFromBlocks(req('bytes=0-1000', 'HEAD'),
    { MEDIA: media }, ctx, KEY, BLOCK, {});
  await settle();
  const body = await bodyOf(res);
  check('HEAD answers 206 with a Content-Range', res.status === 206 &&
    res.headers.get('Content-Range') === `bytes 0-1000/${SIZE}`);
  check('HEAD sends no body', body.length === 0);
  check('HEAD never reads a block (metadata only)', media.gets() === 0);
}

// ── 4. EDGE FAN-OUT: the second viewer costs the bucket nothing ───────────
{
  const cache = makeCache();
  globalThis.caches = cache;
  const first = makeMedia(film);
  // Viewer one, whole film: every block is a miss and is fetched once.
  {
    const { ctx, settle } = makeCtx();
    const res = await serveFromBlocks(req(null), { MEDIA: first }, ctx, KEY, BLOCK, {});
    const body = await bodyOf(res);
    await settle();
    check('viewer 1 gets the whole film', eqRange(body, 0, SIZE - 1));
  }
  const blocksExpected = Math.ceil(SIZE / BLOCK);
  check(`viewer 1 read every block once (${blocksExpected})`,
    first.gets() === blocksExpected);
  check('viewer 1 did one HEAD', first.heads() === 1);

  // Viewer two, same film, overlapping range: served entirely from the cache.
  const second = makeMedia(film);
  {
    const { ctx, settle } = makeCtx();
    const res = await serveFromBlocks(req(`bytes=0-${BLOCK * 2 + 10}`),
      { MEDIA: second }, ctx, KEY, BLOCK, {});
    const body = await bodyOf(res);
    await settle();
    check('viewer 2 gets correct bytes from the cache', eqRange(body, 0, BLOCK * 2 + 10));
  }
  check('viewer 2 read ZERO blocks from the bucket (edge fan-out)',
    second.gets() === 0);
  check('viewer 2 did ZERO HEADs (size came from cached meta)',
    second.heads() === 0);
}

// ── 5. UNSATISFIABLE range is a 416, not a corrupt read ───────────────────
{
  globalThis.caches = makeCache();
  const media = makeMedia(film);
  const { ctx, settle } = makeCtx();
  const res = await serveFromBlocks(req(`bytes=${SIZE + 100}-`),
    { MEDIA: media }, ctx, KEY, BLOCK, {});
  await settle();
  check('a start past EOF is 416', res.status === 416);
  check('416 names the size', res.headers.get('Content-Range') === `bytes */${SIZE}`);
}

// ── 6. FALLS BACK rather than failing ─────────────────────────────────────
{
  globalThis.caches = makeCache();
  // A missing object: head returns null -> the block path declines (null) so
  // the Worker's direct path handles (and logs) it.
  const gone = { async head() { return null; }, async get() { throw new Error('nope'); } };
  const { ctx } = makeCtx();
  const res = await serveFromBlocks(req('bytes=0-10'), { MEDIA: gone }, ctx, KEY, BLOCK, {});
  check('a missing object declines to the direct path (null)', res === null);
}
{
  globalThis.caches = makeCache();
  const media = makeMedia(film);
  const { ctx } = makeCtx();
  // A range shape this path does not handle (multipart) -> decline, not crash.
  const res = await serveFromBlocks(req('bytes=0-10,20-30'),
    { MEDIA: media }, ctx, KEY, BLOCK, {});
  check('an unhandled range shape declines to the direct path (null)', res === null);
}

// ── 7. CORS headers are carried onto the block response ───────────────────
{
  globalThis.caches = makeCache();
  const media = makeMedia(film);
  const { ctx, settle } = makeCtx();
  const cors = { 'Access-Control-Allow-Origin': 'https://yannmh007.github.io' };
  const res = await serveFromBlocks(req('bytes=0-10'), { MEDIA: media }, ctx, KEY, BLOCK, cors);
  await settle();
  check('CORS allow-origin is carried through',
    res.headers.get('Access-Control-Allow-Origin') === 'https://yannmh007.github.io');
  check('the response says Accept-Ranges: bytes',
    res.headers.get('Accept-Ranges') === 'bytes');
}

if (failures) {
  console.error(failures + ' edge-block check(s) failed');
  process.exit(1);
}
console.log('edge blocks: all checks passed');
