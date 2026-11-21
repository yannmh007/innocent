// The Worker's per-isolate caches keep ANSWERS, never a request's promise.
//
// WHY (20 Nov 2026). `strayIndexes` kept the first request's pending bucket
// read for every later request of the same film to await. A promise belongs
// to the request that made it: when that first request was cut — the
// phone's warm-up giving the film over to Play — the runtime refused every
// later await ("This promise was created by a request that has since
// ended, so it can never settle"), and every read of that rung's front on
// that isolate answered 500 for 43-60 s: a start that stood still (device
// lab T2 44744740674; the Worker's logs, 14:00:34-14:01:17 UTC, 75 such
// 500s). Node has no request contexts, so this test holds the shape that
// makes the failure impossible: nothing pending is ever shared, only a
// settled answer is kept, a failed read is not kept.
//
// RUN:  node tool/js/worker_cache_test.mjs   (tool/check.py runs it)

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const src = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');

let failures = 0;
const check = (label, ok) => {
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};

// The two caches, cut out of the Worker as they are (straySidx and the
// key's derivation stood in for: what is under test is the caching).
const slice = (from, to) => {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error(`not found: ${from}`);
  return src.slice(a, b + to.length);
};
const stray = slice('const strayCache = new Map();', '\n  return found;\n}');
const key = slice('const keyCache = new Map();', '\n  return key;\n}');
const mod = await import('data:text/javascript,' + encodeURIComponent(`
  const HEAD_SCAN_BYTES = 512 * 1024;
  const straySidx = (bytes, size) => [bytes.length, size];
  let derived = 0;
  let gate = null;
  async function deriveKey(secret) { derived++; if (gate) await gate; return 'key:' + secret; }
  ${stray}
  ${key}
  export { strayIndexes, strayCache, signingKey, keyCache };
  export const derivedCount = () => derived;
  export const holdDerive = (p) => { gate = p; };
`));

// A bucket whose front reads wait until the test lets them go.
function bucket() {
  const b = { gets: 0, fail: false, waiting: [] };
  b.MEDIA = {
    get(k, opts) {
      b.gets++;
      if (b.fail) return Promise.reject(new Error('bucket down'));
      return new Promise((resolve) => b.waiting.push(() => resolve({
        body: {}, size: 1000,
        arrayBuffer: async () => new Uint8Array(opts.range.length).buffer,
      })));
    },
  };
  b.release = () => { for (const r of b.waiting.splice(0)) r(); };
  return b;
}

// ── strayIndexes ────────────────────────────────────────────────────────
{
  const b = bucket();
  const env = { MEDIA: b.MEDIA };
  const first = mod.strayIndexes(env, 'film-a');
  const second = mod.strayIndexes(env, 'film-a');
  await Promise.resolve();
  check('two requests at once: each reads for itself (no pending read shared)', b.gets === 2);
  check('nothing is kept while a read is on its way', !mod.strayCache.has('film-a'));
  b.release();
  const [x, y] = await Promise.all([first, second]);
  check('both get the answer', Array.isArray(x) && Array.isArray(y) && x[0] === 512 * 1024);
  const kept = mod.strayCache.get('film-a');
  check('what is kept is the answer itself, not a promise',
    Array.isArray(kept) && typeof kept.then !== 'function');
  const third = await mod.strayIndexes(env, 'film-a');
  check('a later request takes the answer without a read', b.gets === 2 && third === kept);
}
{
  const b = bucket();
  b.fail = true;
  const env = { MEDIA: b.MEDIA };
  const got = await mod.strayIndexes(env, 'film-b');
  check('a read that fails answers [] (the film is served unmended)', Array.isArray(got) && got.length === 0);
  check('a failed read is not kept', !mod.strayCache.has('film-b'));
  b.fail = false;
  const again = mod.strayIndexes(env, 'film-b');
  await Promise.resolve();
  check('the next request reads again', b.gets === 2);
  b.release();
  await again;
  check('and its answer is kept', Array.isArray(mod.strayCache.get('film-b')));
}

// ── signingKey ──────────────────────────────────────────────────────────
{
  let let_go;
  mod.holdDerive(new Promise((r) => { let_go = r; }));
  const a = mod.signingKey('s1');
  const b = mod.signingKey('s1');
  await Promise.resolve();
  check('the signing key: nothing kept while it is derived', !mod.keyCache.has('s1'));
  let_go();
  mod.holdDerive(null);
  check('both requests get the key', (await a) === 'key:s1' && (await b) === 'key:s1');
  const kept = mod.keyCache.get('s1');
  check('what is kept is the key, not a promise', kept === 'key:s1');
  const n = mod.derivedCount();
  check('a later request derives nothing', (await mod.signingKey('s1')) === 'key:s1' && mod.derivedCount() === n);
  check('another secret is its own key', (await mod.signingKey('s2')) === 'key:s2');
}

// ── and no other cache in the Worker keeps a promise ───────────────────
const sets = [...src.matchAll(/(\w+Cache)\.set\(([^,]+),\s*([^)]+)\)/g)].map((m) => m[3].trim());
check(`every cache .set stores a settled value (${sets.join(', ')})`,
  sets.length >= 2 && sets.every((v) => !/promise|\(async|\.then\(/i.test(v)));

if (failures) {
  console.log(`worker cache: ${failures} FAILED`);
  process.exit(1);
}
console.log('worker cache: all checks passed');
