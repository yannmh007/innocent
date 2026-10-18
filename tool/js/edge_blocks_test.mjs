// The edge block path must hand the player EXACTLY the bytes it asked for,
// must share blocks between viewers, and must step aside — never answer
// wrongly — whenever anything is not as expected.
//
// WHY THIS IS TESTED RATHER THAN READ. This is the one path in the Worker that
// can corrupt a film: it rebuilds the player's byte range out of fixed-size
// blocks that Workers Caching stores and slices, and an off-by-one in a block
// boundary, the last (short) block of a film, or a range that runs past the
// end would hand every viewer a video that plays as noise — while each block
// on its own is perfectly valid bytes, so nothing in any log says why.
//
// So the real functions are lifted out of the Worker (never copied — a copy
// would pass forever while the file drifted) and run against a fake R2 and an
// emulation of what Cloudflare documents Workers Caching doing for a call
// through `ctx.exports`: strip `Range`, ask the entrypoint for the full `200`,
// store it, cut the range out of it, answer `206` with `Cf-Cache-Status`.
// The emulation can also be switched OFF (the entrypoint then sees the range
// and answers a whole block), because the gateway must notice that and step
// aside. The reassembled bytes are compared with the original, byte for byte.
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

// ── lift the edge functions out of the real Worker ───────────────────────
const worker = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');
const from = worker.indexOf('function blockSize(');
const to = worker.indexOf('/// The cached half.');
check('the Worker has the edge functions before the cached half', from > 0 && to > from);
check('the Worker exports a Block entrypoint after it',
  /\/\/\/ The cached half\.[\s\S]*export class Block extends WorkerEntrypoint/.test(worker));
check('the Worker imports WorkerEntrypoint from cloudflare:workers',
  worker.includes("import { WorkerEntrypoint } from 'cloudflare:workers';"));
check('the default fetch takes ctx (ctx.exports lives there)',
  worker.includes('async fetch(request, env, ctx)'));
const mod = await import('data:text/javascript,' + encodeURIComponent(
  // `serveFromBlocks` reads this module-level const from the top of the file.
  'const EDGE_TTL_SECONDS = 86400;\n' + worker.slice(from, to) +
  '\nexport { blockSize, closedRange, blockPlan, blockPath, contentRange,' +
  ' blockResponse, serveFromBlocks, MAX_EDGE_BLOCKS };'));
const {
  blockSize, closedRange, blockPlan, blockPath, contentRange,
  blockResponse, serveFromBlocks, MAX_EDGE_BLOCKS,
} = mod;

// ── the wrangler config must actually switch the cache on for Block ──────
{
  const toml = readFileSync(join(ROOT, 'docs/worker/wrangler.toml'), 'utf8');
  check('wrangler.toml enables Workers Caching for the Block entrypoint',
    /\[exports\.Block\]\s*\ntype = "worker"\s*\n\s*\[exports\.Block\.cache\]\s*\n\s*enabled = true/.test(toml));
  check('wrangler.toml keeps the gateway (default) uncached',
    /\[cache\]\s*\nenabled = false/.test(toml));
  check('wrangler.toml sets EDGE_BLOCK_BYTES in [vars] (survives deploys)',
    /\[vars\][\s\S]*EDGE_BLOCK_BYTES = "\d+"/.test(toml));
  const pkg = JSON.parse(readFileSync(join(ROOT, 'docs/worker/package.json'), 'utf8'));
  check('Wrangler is pinned at 4.107+ (per-entrypoint cache map)',
    /\^?4\.(10[7-9]|1[1-9]\d|[2-9]\d\d)\./.test(pkg.devDependencies.wrangler));
}

// ── a fake R2 binding ─────────────────────────────────────────────────────
function makeMedia(bytes) {
  let gets = 0;
  return {
    gets: () => gets,
    async head() { return { size: bytes.length }; },
    async get(_key, opts) {
      gets++;
      const { offset, length } = opts.range;
      if (offset >= bytes.length) throw new Error('InvalidRange');
      const slice = bytes.slice(offset, Math.min(bytes.length, offset + length));
      return {
        size: bytes.length,
        body: new Response(slice).body,
        range: { offset, length: slice.length },
      };
    },
  };
}

// ── Workers Caching in front of `Block`, as the docs describe it ─────────
function makeEdge(env, { cacheOn = true, corrupt = false } = {}) {
  const store = new Map();
  let runs = 0;
  const slice = (entry, rangeHeader) => {
    const len = entry.bytes.length;
    const m = /^bytes=(\d+)-(\d+)$/.exec(rangeHeader || '');
    if (!m) {
      return new Response(entry.bytes, { status: 200, headers: entry.headers });
    }
    const a = Number(m[1]);
    let b = Number(m[2]);
    if (a >= len) return new Response(null, { status: 416 });
    if (b >= len) b = len - 1;
    const h = new Headers(entry.headers);
    h.set('Content-Range', `bytes ${a}-${corrupt ? b - 1 : b}/${len}`);
    h.set('Cf-Cache-Status', entry.hit ? 'HIT' : 'MISS');
    return new Response(entry.bytes.slice(a, b + 1), { status: 206, headers: h });
  };
  return {
    runs: () => runs,
    entries: () => store.size,
    ctx: {
      exports: {
        Block: {
          async fetch(req) {
            const path = new URL(req.url).pathname;
            if (!cacheOn) {
              runs++;
              return blockResponse(env, req);  // Range reaches it; it ignores it
            }
            const held = store.get(path);
            if (held) return slice({ ...held, hit: true }, req.headers.get('Range'));
            runs++;
            // The platform strips Range before invoking the entrypoint.
            const res = await blockResponse(env, new Request(req.url));
            const cc = res.headers.get('Cache-Control') || '';
            if (res.status !== 200 || !cc.includes('public')) return res;
            const entry = { bytes: new Uint8Array(await res.arrayBuffer()),
              headers: new Headers(res.headers) };
            store.set(path, entry);
            return slice({ ...entry, hit: false }, req.headers.get('Range'));
          },
        },
      },
    },
  };
}

const KEY = 'test-003/video/20260922-film-a1b2c3d4.mp4';
const BLOCK = 1024 * 1024; // 1 MB blocks (the smallest allowed)
const SIZE = Math.floor(BLOCK * 3.5) + 12345; // 3.5 blocks: the last one short
const film = new Uint8Array(SIZE);
for (let i = 0; i < SIZE; i++) film[i] = (i * 2654435761) & 0xff;

const get = (range, extra = {}, method = 'GET') => {
  const h = new Headers(extra);
  if (range) h.set('Range', range);
  return new Request('https://w/v/token', { method, headers: h });
};
const bodyOf = async (res) => new Uint8Array(await res.arrayBuffer());
// A decline is the reason, a short string, which the direct path reports in X-Edge.
const declined = (r) => typeof r === 'string' && r.length > 0;
const same = (got, s, e) => {
  const want = film.subarray(s, e + 1);
  if (got.length !== want.length) return false;
  for (let i = 0; i < got.length; i++) if (got[i] !== want[i]) return false;
  return true;
};

// ── 1. the small pure pieces ──────────────────────────────────────────────
check('blockSize is 0 when unset', blockSize({}) === 0);
check('blockSize is 0 for junk and under 1 MB',
  blockSize({ EDGE_BLOCK_BYTES: 'x' }) === 0 && blockSize({ EDGE_BLOCK_BYTES: '500000' }) === 0);
check('blockSize takes 8 MB', blockSize({ EDGE_BLOCK_BYTES: '8388608' }) === 8388608);
check('blockSize caps at 64 MB', blockSize({ EDGE_BLOCK_BYTES: String(1 << 30) }) === 64 * 1024 * 1024);
check('closedRange reads bytes=a-b', JSON.stringify(closedRange('bytes=5-99')) === '[5,99]');
for (const bad of [null, '', 'bytes=5-', 'bytes=-100', 'bytes=0-1,5-6', 'bytes=9-3', 'items=0-5']) {
  check(`closedRange declines ${JSON.stringify(bad)}`, closedRange(bad) === null);
}
check('blockPlan inside one block',
  JSON.stringify(blockPlan(10, 20, BLOCK)) === JSON.stringify([{ idx: 0, from: 10, to: 20 }]));
check('blockPlan across a boundary',
  JSON.stringify(blockPlan(BLOCK - 2, BLOCK + 3, BLOCK)) ===
  JSON.stringify([{ idx: 0, from: BLOCK - 2, to: BLOCK - 1 }, { idx: 1, from: 0, to: 3 }]));
check('blockPath keeps the key whole in one segment',
  blockPath('a/b c.mp4', 8, 3) === '/b/8/3/a%2Fb%20c.mp4');
check('contentRange parses', JSON.stringify(contentRange('bytes 3-9/10')) === '[3,9,10]');

// ── 2. the cached entrypoint ──────────────────────────────────────────────
{
  const env = { MEDIA: makeMedia(film) };
  const ok = await blockResponse(env, new Request('https://block' + blockPath(KEY, BLOCK, 1)));
  const b = await bodyOf(ok);
  check('Block answers a whole block as 200', ok.status === 200 && b.length === BLOCK);
  check('Block bytes are that block', same(b, BLOCK, 2 * BLOCK - 1));
  check('Block is cacheable, immutable, a month',
    ok.headers.get('Cache-Control') === `public, max-age=${30 * 86400}, immutable`);
  check('Block carries the film length', ok.headers.get('X-Total-Size') === String(SIZE));
  const last = await blockResponse(env, new Request('https://block' + blockPath(KEY, BLOCK, 3)));
  const lb = await bodyOf(last);
  check('the last block is short and ends at the end', lb.length === SIZE - 3 * BLOCK && same(lb, 3 * BLOCK, SIZE - 1));
  const past = await blockResponse(env, new Request('https://block' + blockPath(KEY, BLOCK, 9)));
  check('a block past the end is 416 with the length', past.status === 416 && past.headers.get('X-Total-Size') === String(SIZE));
  check('a 416 is never cached', past.headers.get('Cache-Control') === 'no-store');
  for (const p of ['/b/x/1/k', '/nope', `/b/${BLOCK}/1/`, `/b/1000/1/${encodeURIComponent(KEY)}`]) {
    const r = await blockResponse(env, new Request('https://block' + p));
    check(`Block refuses a bad path ${p.slice(0, 20)}`, r.status === 404);
  }
}

// ── 3. every closed range reassembles to the exact bytes ──────────────────
const cases = [
  ['inside block 0', 0, 99],
  ['the probe the proxy sends (8 KB)', 0, 8191],
  ['across a block boundary', BLOCK - 10, BLOCK + 10],
  ['a 2 MB lane part over two blocks', BLOCK - 4096, 3 * BLOCK - 4097],
  ['several whole and partial blocks', 500000, 3 * BLOCK + 5000],
  ['into the short last block', 3 * BLOCK + 10, SIZE - 1],
  ['end past EOF is clamped', SIZE - 50, SIZE + 999999],
  ['the very last byte', SIZE - 1, SIZE - 1],
  ['a single byte', 7, 7],
];
for (const [label, s, e] of cases) {
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env);
  const res = await serveFromBlocks(get(`bytes=${s}-${e}`), env, edge.ctx, KEY, BLOCK, {});
  const end = Math.min(e, SIZE - 1);
  const ok = res instanceof Response && res.status === 206;
  check(`${label}: 206`, ok);
  if (!ok) continue;
  check(`${label}: bytes match`, same(await bodyOf(res), s, end));
  check(`${label}: Content-Range bytes ${s}-${end}/${SIZE}`,
    res.headers.get('Content-Range') === `bytes ${s}-${end}/${SIZE}`);
  const blocks = Math.floor(end / BLOCK) - Math.floor(s / BLOCK) + 1;
  check(`${label}: X-Edge counts ${blocks} block(s)`,
    (res.headers.get('X-Edge') || '').startsWith(`blocks=${blocks};`));
}

// ── 4. EDGE FAN-OUT: the second viewer costs the bucket nothing ───────────
{
  const media = makeMedia(film);
  const env = { MEDIA: media };
  const edge = makeEdge(env);
  // Viewer one: the start of the film, as the proxy's lanes ask for it.
  for (const [s, e] of [[0, 8191], [0, 2 * BLOCK - 1], [2 * BLOCK, 3 * BLOCK + 99]]) {
    const r = await serveFromBlocks(get(`bytes=${s}-${e}`), env, edge.ctx, KEY, BLOCK, {});
    check(`viewer 1 bytes=${s}-${e} correct`, !!r && same(await bodyOf(r), s, e));
  }
  const runsAfterOne = edge.runs();
  const getsAfterOne = media.gets();
  check('viewer 1 filled each block once (4 blocks, 4 reads)', runsAfterOne === 4 && getsAfterOne === 4);
  // Viewer two: different ranges over the same blocks.
  for (const [s, e] of [[100, 5000], [BLOCK - 7, BLOCK + 7], [3 * BLOCK, 3 * BLOCK + 50]]) {
    const r = await serveFromBlocks(get(`bytes=${s}-${e}`), env, edge.ctx, KEY, BLOCK, {});
    const ok = !!r && same(await bodyOf(r), s, e);
    check(`viewer 2 bytes=${s}-${e} correct, from the cache`, ok &&
      !(r.headers.get('X-Edge') || '').includes('MISS'));
  }
  check('viewer 2 ran the Block entrypoint ZERO times', edge.runs() === runsAfterOne);
  check('viewer 2 read ZERO bytes from the bucket', media.gets() === getsAfterOne);
}

// ── 5. it STEPS ASIDE (null → direct path) rather than guess ─────────────
{
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env);
  const declines = [
    ['open-ended range', get('bytes=0-')],
    ['suffix range', get('bytes=-500')],
    ['no Range at all', get(null)],
    ['HEAD', get('bytes=0-10', {}, 'HEAD')],
    ['a conditional (If-Range)', get('bytes=0-10', { 'If-Range': '"x"' })],
    ['the live check asking for the old path', get('bytes=0-10', { 'X-Edge-Bypass': '1' })],
    [`more than ${MAX_EDGE_BLOCKS} blocks`, get(`bytes=0-${(MAX_EDGE_BLOCKS + 1) * BLOCK}`)],
  ];
  for (const [label, req] of declines) {
    check(`declines: ${label}`, declined(await serveFromBlocks(req, env, edge.ctx, KEY, BLOCK, {})));
  }
  check('declines: no ctx.exports', declined(await serveFromBlocks(get('bytes=0-10'), env, {}, KEY, BLOCK, {})));
}
{
  // Caching NOT switched on: Block answers a whole 200 to a ranged ask.
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env, { cacheOn: false });
  const r = await serveFromBlocks(get('bytes=0-10'), env, edge.ctx, KEY, BLOCK, {});
  check('declines when the cache is not doing the slicing (a 200 came back)', declined(r));
}
{
  // A slice that is not exactly the one asked for.
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env, { corrupt: true });
  const r = await serveFromBlocks(get('bytes=100-200'), env, edge.ctx, KEY, BLOCK, {});
  check('declines when a block answers the wrong Content-Range', declined(r));
}
{
  // A missing object: Block says 404; the direct path will log no_object.
  const env = { MEDIA: { async get() { return null; }, async head() { return null; } } };
  const edge = makeEdge(env);
  const r = await serveFromBlocks(get('bytes=0-10'), env, edge.ctx, KEY, BLOCK, {});
  check('declines for a missing object', declined(r));
}

// ── 6. a start past the end ───────────────────────────────────────────────
{
  // Past the last block: `Block` itself says 416 and how long the film is,
  // so the gateway can answer a proper 416.
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env);
  const r = await serveFromBlocks(get(`bytes=${5 * BLOCK}-${5 * BLOCK + 50}`), env, edge.ctx, KEY, BLOCK, {});
  check('a start beyond the last block answers 416', !!r && r.status === 416);
  check('the 416 names the length', !!r && r.headers.get('Content-Range') === `bytes */${SIZE}`);
}
{
  // Past the end but inside the last block: the cache's own 416 can only
  // name the BLOCK's length, so the gateway looks the film's up once and
  // still answers a proper 416 — never a guessed Content-Range, and never
  // left to the direct path (a local R2 simulator answered the whole film).
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env);
  const r = await serveFromBlocks(get(`bytes=${SIZE + 5}-${SIZE + 50}`), env, edge.ctx, KEY, BLOCK, {});
  check('a start past the end inside the last block answers 416', !!r && r.status === 416);
  check('and names the FILM\'s length, not the block\'s',
    !!r && r.headers.get('Content-Range') === `bytes */${SIZE}`);
}

// ── 7. the console's speed test still reads it (CORS) ─────────────────────
{
  const env = { MEDIA: makeMedia(film) };
  const edge = makeEdge(env);
  const cors = { 'Access-Control-Allow-Origin': 'https://yannmh007.github.io' };
  const r = await serveFromBlocks(get('bytes=0-1000'), env, edge.ctx, KEY, BLOCK, cors);
  check('CORS is carried onto the edge answer',
    r.headers.get('Access-Control-Allow-Origin') === 'https://yannmh007.github.io');
  check('Accept-Ranges: bytes', r.headers.get('Accept-Ranges') === 'bytes');
  await bodyOf(r);
}

if (failures) {
  console.error(failures + ' edge-block check(s) failed');
  process.exit(1);
}
console.log('edge blocks: all checks passed');
