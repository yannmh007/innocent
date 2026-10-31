// The payment screenshots sent before sealing, sealed where they lie
// (docs/edge/ingest.ts resealOldProofs).
//
// WHY. This deletes a buyer's receipt. A mistake in the order would lose the
// only proof of a payment, or leave a request pointing at a file that is not
// there. So the real function is lifted out of ingest.ts (never copied) and
// run against a storage bucket and a request table held in memory, through
// each way a tick can stop half-way. Pinned: nothing is deleted before the
// sealed copy is written and opens; no stop leaves a plain receipt that no
// request names (the delete comes before the request is repointed, as a
// failed delete afterwards would strand it); the sealed copy opens, with the
// request's own id as associated data, to the exact bytes of the plain one; a receipt
// whose size differs from its request is left alone; a request that moved
// meanwhile is not repointed; a tick that died after writing is finished by
// the next; a path that is not `<user>/<request>.<ext>` is not touched; and
// with no key nothing happens at all.
//
//   node tool/js/proof_reseal_test.mjs

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { fileURLToPath, pathToFileURL } from 'url';
import { dirname, join } from 'path';
import { randomBytes, randomUUID } from 'crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const src = readFileSync(join(ROOT, 'docs/edge/ingest.ts'), 'utf8');
let failed = 0;
let count = 0;
const check = (what, ok) => {
  count += 1;
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};
const between = (from, to) => {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a + 1);
  if (a < 0 || b < 0) {
    console.log(`FAIL could not find ${JSON.stringify(from)} .. ${JSON.stringify(to)} in ingest.ts`);
    process.exit(1);
  }
  return src.slice(a, b);
};

const KEY = randomBytes(32).toString('base64');
const dir = mkdtempSync(join(tmpdir(), 'proof-seal-'));
const modPath = join(dir, 'reseal.ts');
const piiUrl = pathToFileURL(join(ROOT, 'docs/edge/pii.ts')).href;
const prelude = (key) =>
  `import { derivedKey, openFile, PROOF_KEY_INFO, proofAad, sealFile } from ${JSON.stringify(piiUrl)};\n` +
  `const Deno = { env: { get: (_k: string) => ${JSON.stringify(key)} } };\n` +
  `const SUPABASE_URL = 'https://db.test';\nconst SERVICE_KEY = 'service';\n` +
  `async function rest(path: string, init: RequestInit = {}): Promise<Response> {\n` +
  `  return await fetch(SUPABASE_URL + '/rest/v1/' + path, init);\n}\n`;
const body = between('const PROOF_BUCKET = ', "/// THE OFF-SITE HOUSEKEEPING, on the runner's tick:");
writeFileSync(modPath, prelude(KEY) + body + '\nexport { resealOldProofs };\n');
const noKeyPath = join(dir, 'nokey.ts');
writeFileSync(noKeyPath, prelude('') + body + '\nexport { resealOldProofs };\n');
const pii = await import(piiUrl);
const mod = await import(pathToFileURL(modPath).href);
const noKey = await import(pathToFileURL(noKeyPath).href);
const key = await pii.derivedKey(KEY, pii.PROOF_KEY_INFO);

// ── the world, in memory ─────────────────────────────────────────────────
function world() {
  const files = new Map();      // path -> Uint8Array
  const rows = [];              // { id, proof_path, proof_bytes }
  const fail = {};              // fail['DELETE'] = 1: the next one fails
  const log = [];
  const take = (k) => { if (fail[k] > 0) { fail[k]--; return true; } return false; };
  globalThis.fetch = async (url, init = {}) => {
    const u = new URL(url);
    const m = init.method ?? 'GET';
    log.push(m + ' ' + u.pathname);
    if (u.pathname.startsWith('/storage/v1/object/payment-proofs/')) {
      const path = decodeURIComponent(u.pathname.slice('/storage/v1/object/payment-proofs/'.length));
      if (take(m)) return new Response('boom', { status: 500 });
      if (m === 'GET') {
        return files.has(path) ? new Response(files.get(path)) : new Response('{"error":"not_found"}', { status: 400 });
      }
      if (m === 'POST') {
        if (files.has(path)) return new Response('{"error":"Duplicate"}', { status: 400 });
        files.set(path, new Uint8Array(init.body));
        return new Response('{}');
      }
      if (m === 'DELETE') {
        return files.delete(path) ? new Response('{}') : new Response('{"error":"not_found"}', { status: 400 });
      }
    }
    if (u.pathname === '/rest/v1/premium_requests') {
      if (m === 'GET') {
        return new Response(JSON.stringify(rows.filter((r) => r.proof_path && !r.proof_path.endsWith('.sealed'))
          .slice(0, 3).map((r) => ({ ...r }))));
      }
      if (m === 'PATCH') {
        if (take('PATCH')) return new Response('boom', { status: 500 });
        const id = u.searchParams.get('id').slice(3);
        const was = u.searchParams.get('proof_path').slice(3);
        const hit = rows.filter((r) => r.id === id && r.proof_path === was);
        const to = JSON.parse(init.body).proof_path;
        hit.forEach((r) => { r.proof_path = to; });
        return new Response(JSON.stringify(hit));
      }
    }
    return new Response('unexpected ' + m + ' ' + u.pathname, { status: 599 });
  };
  return { files, rows, fail, log };
}

function receipt(w, { bytes = 4000, ext = 'jpg', size } = {}) {
  const user = randomUUID();
  const id = randomUUID();
  const image = randomBytes(bytes);
  const path = `${user}/${id}.${ext}`;
  w.files.set(path, new Uint8Array(image));
  w.rows.push({ id, proof_path: path, proof_bytes: size ?? image.length });
  return { user, id, image, path, sealed: `${user}/${id}.sealed` };
}

const opens = async (w, r) => {
  const b = w.files.get(r.sealed);
  if (!b) return null;
  return await pii.openFile(key, b, pii.proofAad(r.id));
};
const same = (a, b) => a && b && a.length === b.length && Buffer.from(a).equals(Buffer.from(b));

// 1. The plain receipt becomes a sealed one that opens to the same bytes.
{
  const w = world();
  const r = receipt(w);
  const out = await mod.resealOldProofs();
  check('one receipt sealed', out.sealed === 1 && !out.errors);
  check('the sealed copy opens, with the request id, to the exact bytes', same(await opens(w, r), r.image));
  check('it does not open as another request', !(await pii.openFile(key, w.files.get(r.sealed), pii.proofAad(randomUUID()))));
  check('the plain receipt is gone', !w.files.has(r.path));
  check('the request points at the sealed copy', w.rows[0].proof_path === r.sealed);
  const order = w.log.filter((l) => !l.startsWith('GET /rest'));
  const put = order.findIndex((l) => l.startsWith('POST'));
  const patch = order.findIndex((l) => l.startsWith('PATCH'));
  const del = order.findIndex((l) => l.startsWith('DELETE'));
  check('written, then the plain one deleted, then repointed', put >= 0 && put < del && del < patch);
  const again = await mod.resealOldProofs();
  check('nothing left for the next tick', again.sealed === 0 && !again.errors);
}

// 2. Every way a tick can stop leaves the receipt reachable, and the next
//    tick finishes.
for (const stop of ['POST', 'PATCH', 'DELETE']) {
  const w = world();
  const r = receipt(w);
  w.fail[stop] = 1;
  const out = await mod.resealOldProofs();
  // Reachable now (the plain file, or after a stop at PATCH the sealed one,
  // which the next tick adopts); and never a plain file no request names.
  const named = new Set(w.rows.map((x) => x.proof_path));
  const strandedPlain = [...w.files.keys()].some((k) => !k.endsWith('.sealed') && !named.has(k));
  const reachable = w.files.has(w.rows[0].proof_path) || w.files.has(r.sealed);
  check(`a tick stopped at ${stop}: an error, the receipt reachable, no plain file stranded`,
    out.errors?.length === 1 && reachable && !strandedPlain);
  const next = await mod.resealOldProofs();
  check(`... and the next tick finishes it (stopped at ${stop})`,
    w.rows[0].proof_path === r.sealed && same(await opens(w, r), r.image) && !w.files.has(r.path) &&
    next.sealed === 1);
}

// 3. A receipt whose size is not its request's is left exactly as it is.
{
  const w = world();
  const r = receipt(w, { size: 1234 });
  const out = await mod.resealOldProofs();
  check('a receipt of another size is not touched',
    out.errors?.length === 1 && w.files.has(r.path) && !w.files.has(r.sealed) && w.rows[0].proof_path === r.path);
}

// 4. A sealed copy already there that does not open stops the move.
{
  const w = world();
  const r = receipt(w);
  w.files.set(r.sealed, new Uint8Array(randomBytes(100)));
  const out = await mod.resealOldProofs();
  check('a sealed copy that does not open: nothing repointed, nothing deleted',
    out.errors?.length === 1 && w.files.has(r.path) && w.rows[0].proof_path === r.path);
}

// 5. A request repointed meanwhile (by the console, another tick) is left.
{
  const w = world();
  const r = receipt(w);
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    if ((init.method ?? 'GET') === 'PATCH') w.rows[0].proof_path = 'elsewhere';
    return realFetch(url, init);
  };
  const out = await mod.resealOldProofs();
  check('a request that moved meanwhile is not repointed over',
    out.errors?.length === 1 && w.rows[0].proof_path === 'elsewhere');
}

// 6. Paths that are not ours are not touched.
{
  const w = world();
  const id = randomUUID();
  w.files.set(`../${id}.jpg`, new Uint8Array(10));
  w.rows.push({ id, proof_path: `../${id}.jpg`, proof_bytes: 10 });
  const other = randomUUID();
  const r = receipt(w);
  w.rows[1].id = other;   // the file names another request
  const out = await mod.resealOldProofs();
  check('a path outside `<user>/<request>.<ext>`, or naming another request, is not touched',
    out.sealed === 0 && !out.errors && w.files.has(`../${id}.jpg`) && w.files.has(r.path));
}

// 7. Every extension premium-request writes.
for (const ext of ['png', 'webp']) {
  const w = world();
  const r = receipt(w, { ext });
  const out = await mod.resealOldProofs();
  check(`a .${ext} receipt is sealed too`, out.sealed === 1 && same(await opens(w, r), r.image));
}

// 8. No key: nothing at all.
{
  const w = world();
  const r = receipt(w);
  const out = await noKey.resealOldProofs();
  check('with no key, nothing is read, written or deleted',
    out.sealed === 0 && w.log.length === 0 && w.files.has(r.path));
}

rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.log(`\n${failed} of ${count} check(s) failed`);
  process.exit(1);
}
console.log(`\n=== ${count} check(s) on the receipts sent before sealing, sealed where they lie ===`);
