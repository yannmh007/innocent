// The database backups made before sealing, sealed where they lie
// (docs/edge/ingest.ts resealOldBackups, migration 055).
//
// WHY. This deletes things: the plain backup in R2 and its copy off-site. A
// mistake in the order would lose a backup, or leave a plain one behind with
// no row pointing at it. So the real function is lifted out of ingest.ts
// (never copied) and run against an R2, an off-site bucket and a database
// held in memory, through each way a tick can stop half-way. Pinned: nothing
// is deleted before the sealed file is written; the sealed file opens to the
// exact bytes of the old one; a backup whose hash differs from its record is
// left alone; a failed off-site delete keeps the plain R2 file and the row; a
// tick that died after deleting is finished by the next; and with no key
// nothing happens at all.
//
//   node tool/js/backup_seal_test.mjs

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { fileURLToPath, pathToFileURL } from 'url';
import { dirname, join } from 'path';
import { createHash, randomBytes } from 'crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const src = readFileSync(join(ROOT, 'docs/edge/ingest.ts'), 'utf8');
let failed = 0;
const check = (what, ok) => {
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

// The function and its helper, with what they use from the rest of the file
// handed in by the test.
const dir = mkdtempSync(join(tmpdir(), 'backup-seal-'));
const modPath = join(dir, 'reseal.ts');
writeFileSync(modPath,
  `import { BACKUP_AAD, openFile, sealFile } from ${JSON.stringify(pathToFileURL(join(ROOT, 'docs/edge/pii.ts')).href)};\n` +
  `const BACKUP_PREFIX = '_backup/db/';\n` +
  `const MEDIA_BUCKET = 'media';\nconst OFFSITE_BUCKET = 'offsite';\n` +
  `const env = () => (globalThis as any).__env;\n` +
  `const rpc = (n: string, b: unknown) => env().rpc(n, b);\n` +
  `const presign = async (m: string, k: string, _t: number, b: string) => env().url('r2', b, k);\n` +
  `const presignAt = async (_o: unknown, m: string, k: string, _t: number, b: string) => env().url('b2', b, k);\n` +
  `function hex(buf: Uint8Array): string { return Array.from(buf, (x) => x.toString(16).padStart(2, '0')).join(''); }\n` +
  `let BACKUP_KEY: Promise<CryptoKey | null>;\nlet OFFSITE: unknown;\n` +
  `export function setKey(k: CryptoKey | null, off: unknown) { BACKUP_KEY = Promise.resolve(k); OFFSITE = off; }\n` +
  between('function backupType(', '/// `_backup/db/2026/10/x.json.gz` in R2') +
  `\nexport { resealOldBackups, backupType };\n`);
const pii = await import(pathToFileURL(join(ROOT, 'docs/edge/pii.ts')).href);
const mod = await import(pathToFileURL(modPath).href);

// ── the world, in memory ─────────────────────────────────────────────────
const sha = (b) => createHash('sha256').update(b).digest('hex');
function world() {
  const store = { r2: new Map(), b2: new Map() };
  const rows = [];
  const fail = {};   // e.g. fail['PUT r2'] = 1 makes the next one fail
  const deletes = [];
  const env = {
    url: (where, bucket, key) => `https://${where}.test/${bucket}/${key}`,
    rpc: async (name, body) => {
      if (fail['rpc ' + name] > 0) { fail['rpc ' + name]--; throw new Error(name + ' 500'); }
      if (name === 'backup_plain_due') {
        return rows.filter((r) => !r.deleted && r.object_key.startsWith('_backup/db/') &&
          !r.object_key.endsWith('.sealed')).slice(0, body.p_limit)
          .map(({ id, object_key, sha256, offsite_key }) => ({ id, object_key, sha256, offsite_key }));
      }
      if (name === 'backup_resealed') {   // the same conditions as migration 055
        const r = rows.find((x) => x.id === body.p_id && !x.deleted);
        if (!r || body.p_key !== r.object_key + '.sealed' || !/^[0-9a-f]{64}$/.test(body.p_sha) ||
          !(body.p_bytes > 0)) return false;
        Object.assign(r, { object_key: body.p_key, bytes: body.p_bytes, sha256: body.p_sha,
          offsite_key: null, offsite_at: null });
        return true;
      }
      if (name === 'backup_deleted') {
        rows.find((x) => x.id === body.p_id).deleted = true;
        return null;
      }
      throw new Error('unexpected rpc ' + name);
    },
  };
  globalThis.__env = env;
  globalThis.fetch = async (url, init = {}) => {
    const u = new URL(url);
    const where = u.hostname.split('.')[0];
    const key = decodeURIComponent(u.pathname.split('/').slice(2).join('/'));
    const method = init.method ?? 'GET';
    if (fail[`${method} ${where}`] > 0) {
      fail[`${method} ${where}`]--;
      return new Response('nope', { status: 503 });
    }
    const m = store[where];
    if (method === 'GET') {
      return m.has(key) ? new Response(m.get(key)) : new Response('', { status: 404 });
    }
    if (method === 'PUT') {
      m.set(key, new Uint8Array(await new Response(init.body).arrayBuffer()));
      return new Response('', { status: 200 });
    }
    if (method === 'DELETE') {
      deletes.push(`${where}:${key}`);
      m.delete(key);
      return new Response(null, { status: 204 });
    }
    throw new Error('unexpected ' + method);
  };
  const add = (id, offsite) => {
    const gz = new Uint8Array(randomBytes(3000 + id));
    const key = `_backup/db/2026/10/2026100${id}T010000-daily.json.gz`;
    store.r2.set(key, gz);
    const row = { id, object_key: key, sha256: sha(gz), bytes: gz.length, offsite_key: null, offsite_at: null };
    if (offsite) {
      row.offsite_key = 'db/' + key.slice('_backup/db/'.length);
      row.offsite_at = 'then';
      store.b2.set(row.offsite_key, gz);
    }
    rows.push(row);
    return { gz, key, row };
  };
  return { store, rows, fail, deletes, add };
}

const key = await pii.derivedKey(randomBytes(32).toString('base64'), pii.BACKUP_KEY_INFO);
const OFF = { host: 'b2.test' };
const opens = async (w, row, gz) => {
  const got = w.store.r2.get(row.object_key);
  const back = got && await pii.openFile(key, got, pii.BACKUP_AAD);
  return !!back && Buffer.from(back).equals(Buffer.from(gz));
};

// ── the ordinary run ─────────────────────────────────────────────────────
{
  const w = world();
  const a = w.add(1, true), b = w.add(2, false);
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('two plain backups, two sealed', r.sealed === 2 && !r.errors);
  check('each row names <its old key>.sealed', a.row.object_key === a.key + '.sealed' &&
    b.row.object_key === b.key + '.sealed');
  check('no plain file is left in R2', !w.store.r2.has(a.key) && !w.store.r2.has(b.key));
  check('the plain copy off-site is deleted', w.store.b2.size === 0);
  check('the off-site columns are cleared, so the catch-up copies the sealed one',
    a.row.offsite_key === null && a.row.offsite_at === null);
  check('each sealed file opens to the exact bytes it was', await opens(w, a.row, a.gz) &&
    await opens(w, b.row, b.gz));
  check('the row records the sealed file\'s size and hash',
    a.row.bytes === w.store.r2.get(a.row.object_key).length &&
    a.row.sha256 === sha(w.store.r2.get(a.row.object_key)));
  check('it is a sealed file (IBK1), stored as bytes', pii.isSealedFile(w.store.r2.get(a.row.object_key)) &&
    mod.backupType(a.row.object_key) === 'application/octet-stream' &&
    mod.backupType(a.key) === 'application/gzip');
  const again = await mod.resealOldBackups();
  check('a second tick finds nothing to do', again.sealed === 0 && !again.errors);
}

// ── no key: nothing ──────────────────────────────────────────────────────
{
  const w = world();
  const a = w.add(1, true);
  mod.setKey(null, OFF);
  const r = await mod.resealOldBackups();
  check('without PII_ENC_KEY nothing is touched', r.sealed === 0 && w.deletes.length === 0 &&
    a.row.object_key === a.key && w.store.r2.has(a.key) && w.store.b2.size === 1);
}

// ── a file that is not the one recorded ──────────────────────────────────
{
  const w = world();
  const a = w.add(1, true);
  a.row.sha256 = sha(Buffer.from('something else'));
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('a hash that differs from the record: left exactly as it is, and said',
    r.sealed === 0 && /hash differs/.test(String(r.errors)) && w.deletes.length === 0 &&
    w.store.r2.size === 1 && a.row.object_key === a.key);
}

// ── the sealed PUT fails ─────────────────────────────────────────────────
{
  const w = world();
  const a = w.add(1, true);
  w.fail['PUT r2'] = 1;
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('the sealed file not written: nothing deleted', r.sealed === 0 && w.deletes.length === 0 &&
    w.store.r2.has(a.key) && w.store.b2.size === 1 && a.row.object_key === a.key);
  const r2 = await mod.resealOldBackups();
  check('and the next tick does it', r2.sealed === 1 && await opens(w, a.row, a.gz));
}

// ── the off-site delete fails ────────────────────────────────────────────
{
  const w = world();
  const a = w.add(1, true);
  w.fail['DELETE b2'] = 1;
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('the off-site copy not deleted: the plain R2 file and the row stay',
    r.sealed === 0 && w.store.r2.has(a.key) && a.row.object_key === a.key &&
    a.row.offsite_key !== null);
  const r2 = await mod.resealOldBackups();
  check('and the next tick finishes, writing the same sealed object, not a second one',
    r2.sealed === 1 && w.store.b2.size === 0 && w.store.r2.size === 1 && await opens(w, a.row, a.gz));
}

// ── the tick dies after the deletes, before the row moved ────────────────
{
  const w = world();
  const a = w.add(1, true);
  w.fail['rpc backup_resealed'] = 1;
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('the row not moved: the error is said', r.sealed === 0 && r.errors?.length === 1 &&
    !w.store.r2.has(a.key) && w.store.r2.has(a.key + '.sealed'));
  const r2 = await mod.resealOldBackups();
  check('the next tick finds the sealed file, proves it opens, and moves the row',
    r2.sealed === 1 && a.row.object_key === a.key + '.sealed' && await opens(w, a.row, a.gz));
}

// ── a sealed file that does not open is never adopted ────────────────────
{
  const w = world();
  const a = w.add(1, false);
  w.store.r2.delete(a.key);
  w.store.r2.set(a.key + '.sealed', new Uint8Array(randomBytes(100)));
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('a sealed file that does not open is not adopted', r.sealed === 0 &&
    /does not open/.test(String(r.errors)) && a.row.object_key === a.key);
}

// ── gone from R2 altogether ──────────────────────────────────────────────
{
  const w = world();
  const a = w.add(1, false);
  const b = w.add(2, true);
  w.store.r2.delete(a.key);
  w.store.r2.delete(b.key);
  mod.setKey(key, OFF);
  const r = await mod.resealOldBackups();
  check('neither file in R2, none off-site: marked gone, as the prune would', a.row.deleted === true);
  check('neither file in R2 but a copy off-site: that copy is kept, the row stays',
    !b.row.deleted && w.store.b2.size === 1 && b.row.offsite_key !== null && r.errors?.length === 2);
}

// ── without the off-site secret, a plain off-site copy is not forgotten ──
{
  const w = world();
  const a = w.add(1, true);
  mod.setKey(key, null);
  const r = await mod.resealOldBackups();
  check('a plain copy off-site and no off-site key: nothing deleted, the row stays',
    r.sealed === 0 && w.store.r2.has(a.key) && a.row.offsite_key !== null);
}

rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.log(`\n${failed} check(s) FAILED`);
  process.exit(1);
}
console.log('\n=== all checks on sealing the old backups passed ===');
