// The Worker's door, end to end: a token request-playback really minted,
// through the Worker's real `fetch`, against a fake R2.
//
// WHY. The other tests take the Worker apart — the token, the edge blocks —
// and this one runs it whole, because what changed on 2026-10-22 lives in
// the order of things inside `fetch`: whether a bound token is checked before
// a byte is read, whether "log" really refuses nothing (a phone in the field
// whose film stops because a check meant to watch it refused it instead is
// the failure to fear), whether "enforce" really refuses, and what every
// answer tells a cache between here and the player.
//
// RUN:  node tool/js/worker_gate_test.mjs
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

// ── the Worker, whole. Only its one platform import is stood in for. ─────
const workerSrc = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');
const IMPORT = "import { WorkerEntrypoint } from 'cloudflare:workers';";
check('the Worker imports only WorkerEntrypoint from the platform',
  workerSrc.includes(IMPORT));
const worker = (await import('data:text/javascript,' + encodeURIComponent(
  workerSrc.replace(IMPORT, 'class WorkerEntrypoint { constructor(c, e) { this.env = e; } }'),
))).default;

// ── request-playback's own minter ────────────────────────────────────────
const edge = readFileSync(join(ROOT, 'docs/edge/request-playback.ts'), 'utf8');
const SECRET = 'a test secret, any text at all';
const mint = await import('data:text/javascript,' + encodeURIComponent(
  `const STREAM_BASE = 'https://s.example.workers.dev';\n` +
  `const STREAM_TOKEN_SECRET = ${JSON.stringify(SECRET)};\n` +
  'const EXPIRY_SECONDS = 600;\nconst logRefusal = () => {};\n' +
  edge.slice(edge.indexOf('function b64urlFromBytes'), edge.indexOf('// --- refusals'))
    .replace(/: Record<string, string \| number>/g, '')
    .replace(/: Promise<string \| null>/g, '')
    .replace(/: Promise<string>/g, '')
    .replace(/: Uint8Array\b/g, '')
    .replace(/: string \| null\b/g, '')
    .replace(/: string\b/g, '')
    .replace(/: number\b/g, '')
    .replace(/: Request\b/g, '')
    .replace(/ as BufferSource/g, '')
    + '\nexport { workerUrl, sha256Hex };'));

// ── a fake R2 binding: the two ways the Worker reads ────────────────────
const KEY = 'test-003/video/20260922-solar-a1b2c3d4.mp4';
const FILM = new Uint8Array(1 << 20).map((_, i) => (i * 31 + 7) & 0xff);
let reads = 0;
const MEDIA = {
  async head(k) { return k === KEY ? { size: FILM.length } : null; },
  async get(k, opts) {
    reads++;
    if (k !== KEY) return null;
    let offset = 0;
    let length = FILM.length;
    if (opts.range instanceof Headers) {
      // The direct path hands R2 the request's headers and lets it parse.
      const m = /^bytes=(\d+)-(\d*)$/.exec(opts.range.get('Range') || '');
      if (m) {
        offset = Number(m[1]);
        const end = m[2] ? Math.min(Number(m[2]), FILM.length - 1) : FILM.length - 1;
        length = end - offset + 1;
      } else {
        length = FILM.length;
      }
    } else if (opts.range) {
      offset = opts.range.offset;
      length = Math.min(opts.range.length, FILM.length - offset);
    }
    const slice = FILM.slice(offset, offset + length);
    const ranged = opts.range instanceof Headers ? opts.range.has('Range') : !!opts.range;
    return {
      size: FILM.length,
      range: ranged ? { offset, length } : undefined,
      httpEtag: '"etag"',
      body: new Response(slice).body,
      writeHttpMetadata(h) { h.set('Content-Type', 'video/mp4'); },
      async arrayBuffer() { return slice.slice().buffer; },
    };
  },
};

// The log, captured: what the Worker writes is part of what it promises.
const logged = [];
const realLog = console.log;
console.log = (line) => {
  if (typeof line === 'string' && line.startsWith('{')) logged.push(line);
  else realLog(line);
};

const INSTALL = '8c2b5f0e-0d4b-4f1a-9e3a-6b7c8d9e0f1a';
const D = await mint.sha256Hex(INSTALL, 32);
const U = await mint.sha256Hex('11111111-2222-3333-4444-555555555555', 16);

async function ask({ who = {}, headers = {}, env = {}, path, cf } = {}) {
  const url = path ?? (await mint.workerUrl(KEY, who)).replace('https://s.example.workers.dev', 'https://w.example');
  const before = logged.length;
  const req = new Request(url, { headers: { Range: 'bytes=1000-1999', ...headers } });
  // What Cloudflare's edge attaches; a plain Request has none.
  if (cf) Object.defineProperty(req, 'cf', { value: cf });
  const res = await worker.fetch(req, { TOKEN_SECRET: SECRET, MEDIA, EDGE_BLOCK_BYTES: '0', ...env }, {});
  const body = res.status === 206 ? new Uint8Array(await res.arrayBuffer()) : null;
  return { res, body, log: logged.slice(before).map((l) => JSON.parse(l)) };
}
const rightBytes = (b) => b !== null && b.length === 1000 &&
  Buffer.from(b).equals(Buffer.from(FILM.slice(1000, 2000)));

// 1. An older app's token: no binding, no header — plays exactly as before.
{
  const { res, body, log } = await ask({ who: { u: U, d: D } });
  check('an unbound token plays: 206 and the right bytes', res.status === 206 && rightBytes(body));
  check('nothing between here and the player may keep it',
    res.headers.get('Cache-Control') === 'private, no-store');
  check('no X-Bind on an unbound token', !res.headers.has('X-Bind'));
  const serve = log.find((l) => l.ev === 'serve');
  check('the log line names the account by hash', serve && serve.u === U);
  check('and never the object key or the token',
    log.every((l) => !JSON.stringify(l).includes('solar') && !JSON.stringify(l).includes('/v/')));
}

// 2. A bound token from the phone it was granted to.
{
  const { res, body, log } = await ask({
    who: { u: U, d: D, b: 1 }, headers: { 'X-Innocent-Device': INSTALL } });
  check('bound, right install: plays', res.status === 206 && rightBytes(body));
  check('and says so in X-Bind', res.headers.get('X-Bind') === 'ok');
  check('and in the log', log.find((l) => l.ev === 'serve')?.bind === 'ok');
}

// 3. "log" REFUSES NOTHING. The whole point of starting there.
for (const [label, headers, want] of [
  ['no header', {}, 'missing'],
  ['another install', { 'X-Innocent-Device': 'someone-else' }, 'mismatch'],
]) {
  const { res, body, log } = await ask({ who: { u: U, d: D, b: 1 }, headers });
  check(`log mode, ${label}: still plays`, res.status === 206 && rightBytes(body));
  check(`log mode, ${label}: X-Bind says ${want}`, res.headers.get('X-Bind') === want);
  check(`log mode, ${label}: logged as bind_${want}`,
    log.some((l) => l.refusal === 'bind_' + want && l.mode === 'log' && l.u === U));
}

// 4. "enforce" refuses — before a byte is read — and still plays the right phone.
{
  const r0 = reads;
  const { res } = await ask({
    who: { u: U, d: D, b: 1 }, headers: { 'X-Innocent-Device': 'someone-else' },
    env: { BIND_MODE: 'enforce' } });
  check('enforce, another install: the same 404 as any refusal',
    res.status === 404 && (await res.text()) === 'Not found');
  check('and the bucket was not read', reads === r0);
  const missing = await ask({ who: { u: U, d: D, b: 1 }, env: { BIND_MODE: 'enforce' } });
  check('enforce, no header: refused', missing.res.status === 404);
  const right = await ask({
    who: { u: U, d: D, b: 1 }, headers: { 'X-Innocent-Device': INSTALL },
    env: { BIND_MODE: 'enforce' } });
  check('enforce, right install: plays', right.res.status === 206 && rightBytes(right.body));
  const old = await ask({ who: { u: U, d: D }, env: { BIND_MODE: 'enforce' } });
  check('enforce, an unbound token (older app): plays', old.res.status === 206 && rightBytes(old.body));
}

// 5. The rate limit: logged in "log", 429 in "enforce", per install.
{
  const keys = [];
  const over = { async limit({ key }) { keys.push(key); return { success: false }; } };
  const logMode = await ask({ who: { u: U, d: D }, env: { STREAM_LIMIT: over } });
  check('over the limit in log mode: still plays', logMode.res.status === 206 && rightBytes(logMode.body));
  check('and is logged', logMode.log.some((l) => l.refusal === 'rate_limited' && l.mode === 'log'));
  check('counted per install', keys[0] === 'd:' + D);
  const enforced = await ask({ who: { u: U, d: D }, env: { STREAM_LIMIT: over, LIMIT_MODE: 'enforce' } });
  check('over the limit in enforce mode: 429 with Retry-After',
    enforced.res.status === 429 && enforced.res.headers.get('Retry-After') === '10' &&
    enforced.res.headers.get('Cache-Control') === 'no-store');
  const broken = { async limit() { throw new Error('limiter down'); } };
  const down = await ask({ who: { d: D }, env: { STREAM_LIMIT: broken, LIMIT_MODE: 'enforce' } });
  check('a limiter that fails stops nothing', down.res.status === 206 && rightBytes(down.body));
}

// 6. Everything else still refuses, the same way.
{
  const bad = await ask({ path: 'https://w.example/v/not-a-token' });
  check('a bad token: 404', bad.res.status === 404);
  const whole = await worker.fetch(new Request(
    (await mint.workerUrl(KEY)).replace('https://s.example.workers.dev', 'https://w.example')),
  { TOKEN_SECRET: SECRET, MEDIA, EDGE_BLOCK_BYTES: '0' }, {});
  check('a request with no Range: the whole film, 200, not kept',
    whole.status === 200 && whole.headers.get('Cache-Control') === 'private, no-store' &&
    (await whole.arrayBuffer()).byteLength === FILM.length);
  const noSecret = await worker.fetch(new Request('https://w.example/v/x'), { MEDIA }, {});
  check('no TOKEN_SECRET: closed', noSecret.status === 404);
}

// 8. Nothing in the clear, nothing over old TLS (2026-10-26): workers.dev
// runs the Worker for plain HTTP too, and its edge still takes TLS 1.0/1.1.
// Both are refused before the token is read; the app's TLS 1.3 plays; and
// no answer carries R2's ETag (the film's MD5, the same for every viewer).
{
  const good = await ask({ who: { u: U, d: D } });
  check('a 206 carries no ETag', good.res.status === 206 && !good.res.headers.has('ETag'));
  const r0 = reads;
  const clearUrl = (await mint.workerUrl(KEY, { u: U, d: D }))
    .replace('https://s.example.workers.dev', 'http://w.example');
  const clear = await ask({ path: clearUrl });
  check('a real token over plain HTTP: the same 404, the bucket not read',
    clear.res.status === 404 && (await clear.res.text()) === 'Not found' && reads === r0);
  check('and logged as plain_http', clear.log.some((l) => l.refusal === 'plain_http'));
  const health = await worker.fetch(new Request('http://w.example/health'), { TOKEN_SECRET: SECRET, MEDIA }, {});
  check('/health is not answered over plain HTTP either', health.status === 404);
  for (const v of ['TLSv1', 'TLSv1.1']) {
    const old = await ask({ who: { u: U, d: D }, cf: { tlsVersion: v } });
    check(`a real token over ${v}: refused, the bucket not read`, old.res.status === 404 && reads === r0);
    check(`and logged as old_tls ${v}`, old.log.some((l) => l.refusal === 'old_tls' && l.tls === v));
  }
  for (const v of ['TLSv1.2', 'TLSv1.3']) {
    const ok = await ask({ who: { u: U, d: D }, cf: { tlsVersion: v } });
    check(`${v}: plays`, ok.res.status === 206 && rightBytes(ok.body));
  }
}

// 7. What is deployed: fan-out off, the bind check refusing (since
// 2026-10-25, once the field's phones were seen to pass it), the rate limit
// still watching, the limiter bound, and /health saying which.
{
  const toml = readFileSync(join(ROOT, 'docs/worker/wrangler.toml'), 'utf8');
  check('edge fan-out is off (every Block call is billed)', /\nEDGE_BLOCK_BYTES = "0"\n/.test(toml));
  check('the bind check is enforced', /\nBIND_MODE = "enforce"\n/.test(toml));
  const src = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');
  check('/health says which mode each check is in',
    /bind: env\.BIND_MODE === 'enforce'/.test(src) && /limit: env\.LIMIT_MODE === 'enforce'/.test(src));
  check('the rate limit starts in log mode', /\nLIMIT_MODE = "log"\n/.test(toml));
  check('the Worker answers on our own domain, where the zone\'s rules stand in front',
    /\nroutes = \[\s*\n\s*\{ pattern = "stream\.innocentplayer\.com", custom_domain = true \},\s*\n\]/.test(toml));
  check('workers.dev is set explicitly, on or off', /\nworkers_dev = (true|false)\n/.test(toml));
  check('the limiter is bound as STREAM_LIMIT, 10-second period',
    /\[\[ratelimits\]\]\s*\nname = "STREAM_LIMIT"\s*\nnamespace_id = "\d+"[\s\S]*?\[ratelimits\.simple\]\s*\n\s*limit = \d+\s*\n\s*period = 10\b/.test(toml));
}

console.log = realLog;
if (failures) {
  console.error(failures + ' worker gate check(s) failed');
  process.exit(1);
}
console.log('worker gate: all checks passed');
