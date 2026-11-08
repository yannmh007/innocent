// The restore drill opens the newest backup the way a restore would
// (docs/edge/ingest.ts drillBackup, migration 079).
//
// WHY. A backup that cannot be opened is found on the day it is needed.
// The drill is the only thing that opens one before then, so it must say
// "fine" only for a file that truly opens to what was recorded, and say
// exactly what is wrong otherwise. The real function is lifted out of
// ingest.ts (never copied) and run against an R2 and a database held in
// memory. Pinned: a good sealed backup and a good plain one pass, with the
// row count; a different file (hash), a file sealed under another key, a
// table short of its rows, a missing table, a missing file and a sealed
// file with no key each fail with their own reason, and every outcome is
// recorded on the backup's row; nothing due means nothing is read.
//
//   node tool/js/backup_drill_test.mjs

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { fileURLToPath, pathToFileURL } from 'url';
import { dirname, join } from 'path';
import { createHash, randomBytes } from 'crypto';
import { gzipSync } from 'zlib';

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

const dir = mkdtempSync(join(tmpdir(), 'backup-drill-'));
const modPath = join(dir, 'drill.ts');
writeFileSync(modPath,
  `import { BACKUP_AAD, openFile } from ${JSON.stringify(pathToFileURL(join(ROOT, 'docs/edge/pii.ts')).href)};\n` +
  `const BACKUP_PREFIX = '_backup/db/';\nconst MEDIA_BUCKET = 'media';\n` +
  `const env = () => (globalThis as any).__env;\n` +
  `const rpc = (n: string, b: unknown) => env().rpc(n, b);\n` +
  `const presign = async (_m: string, k: string, _t: number, b: string) => \`https://r2.test/\${b}/\${k}\`;\n` +
  `function hex(buf: Uint8Array): string { return Array.from(buf, (x) => x.toString(16).padStart(2, '0')).join(''); }\n` +
  `let BACKUP_KEY: Promise<CryptoKey | null>;\n` +
  `export function setKey(k: CryptoKey | null) { BACKUP_KEY = Promise.resolve(k); }\n` +
  between('async function gunzip(', '// ── end of the restore drill') +
  `\nexport { drillBackup };\n`);
const pii = await import(pathToFileURL(join(ROOT, 'docs/edge/pii.ts')).href);
const mod = await import(pathToFileURL(modPath).href);

const sha = (b) => createHash('sha256').update(b).digest('hex');
const key = await pii.derivedKey(randomBytes(32).toString('base64'), pii.BACKUP_KEY_INFO);
const other = await pii.derivedKey(randomBytes(32).toString('base64'), pii.BACKUP_KEY_INFO);

// A backup as runBackup writes it, and the record it would leave.
function doc(tables) {
  const counts = Object.fromEntries(Object.entries(tables).map(([k, v]) => [k, v.length]));
  return {
    text: JSON.stringify({ format: 'innocent-db-backup', version: 1, taken_at: '2026-11-07T00:00:00Z',
      trigger: 'daily', order: Object.keys(tables), counts, tables, auth_users: [{ id: 'u1' }] }),
    counts,
  };
}
const TABLES = { titles: [{ id: 1 }, { id: 2 }, { id: 3 }], title_assets: [{ id: 'a' }] };

async function world({ sealed = true, sealWith = key, tables = TABLES, recordCounts, mangle } = {}) {
  const { text, counts } = doc(tables);
  const gz = new Uint8Array(gzipSync(Buffer.from(text)));
  let stored = sealed ? await pii.sealFile(sealWith, gz, pii.BACKUP_AAD) : gz;
  const objectKey = '_backup/db/2026/11/20261107T000000-daily.json.gz' + (sealed ? '.sealed' : '');
  const recordedSha = sha(stored);
  if (mangle) stored = mangle(stored);
  const r2 = new Map([[`media/${objectKey}`, stored]]);
  const row = { id: 7, object_key: objectKey, sha256: recordedSha, tables: recordCounts ?? counts };
  const recorded = [];
  const reads = [];
  globalThis.__env = {
    rpc: async (name, body) => {
      if (name === 'backup_verify_due') return row.due === false ? [] : [row];
      if (name === 'backup_verified') { recorded.push(body); return true; }
      throw new Error('unexpected rpc ' + name);
    },
  };
  globalThis.fetch = async (url) => {
    const k = decodeURIComponent(new URL(url).pathname.slice(1));
    reads.push(k);
    return r2.has(k) ? new Response(r2.get(k)) : new Response('', { status: 404 });
  };
  return { row, r2, recorded, reads, objectKey };
}

// 1. a good sealed backup
{
  mod.setKey(key);
  const w = await world();
  const r = await mod.drillBackup();
  check('a sealed backup that opens passes, with tables and rows counted',
    r && !r.error && r.id === 7 && r.tables === 2 && r.rows === 4 && r.bytes > 0);
  check('the pass is recorded on its row (no error)',
    w.recorded.length === 1 && w.recorded[0].p_id === 7 && w.recorded[0].p_error === null);
}
// 2. a good plain backup (made before sealing)
{
  mod.setKey(key);
  await world({ sealed: false });
  const r = await mod.drillBackup();
  check('a plain backup that opens passes', r && !r.error && r.rows === 4);
}
// 3. different bytes from the ones recorded
{
  mod.setKey(key);
  const w = await world({ mangle: (b) => { const c = new Uint8Array(b); c[c.length - 1] ^= 1; return c; } });
  const r = await mod.drillBackup();
  check('a file that is not the one recorded fails on the hash', /hash differs/.test(r?.error ?? ''));
  check('the failure is recorded on its row', w.recorded[0]?.p_error === r.error);
}
// 4. sealed under another key (the hash matches: what was stored never opens)
{
  mod.setKey(key);
  await world({ sealWith: other });
  const r = await mod.drillBackup();
  check('a file sealed under another key fails: does not open', /does not open/.test(r?.error ?? ''));
}
// 5. a table short of its rows
{
  mod.setKey(key);
  await world({ recordCounts: { titles: 4, title_assets: 1 } });
  const r = await mod.drillBackup();
  check('a table with fewer rows than recorded fails, naming it', /table titles: 3 rows, recorded 4/.test(r?.error ?? ''));
}
// 6. a table the record names that the file lacks
{
  mod.setKey(key);
  await world({ recordCounts: { titles: 3, title_assets: 1, genres: 2 } });
  const r = await mod.drillBackup();
  check('a table missing from the file fails, naming it', /table genres is missing/.test(r?.error ?? ''));
}
// 7. the file is gone from R2
{
  mod.setKey(key);
  const w = await world();
  w.r2.clear();
  const r = await mod.drillBackup();
  check('a file missing from R2 fails with the status', r?.error === 'GET 404');
}
// 8. sealed, and no key here
{
  mod.setKey(null);
  await world();
  const r = await mod.drillBackup();
  check('a sealed file with no key fails and says why', /PII_ENC_KEY is not set/.test(r?.error ?? ''));
}
// 9. nothing due
{
  mod.setKey(key);
  const w = await world();
  w.row.due = false;
  const r = await mod.drillBackup();
  check('nothing due: nothing read, nothing recorded', r === null && w.reads.length === 0 && w.recorded.length === 0);
}
// 10. the drill never reports anything from inside the backup
{
  mod.setKey(key);
  await world({ tables: { titles: [{ id: 1, title: 'SECRET-TITLE' }] } });
  const r = await mod.drillBackup();
  check('the outcome carries counts only, nothing from the rows', !JSON.stringify(r).includes('SECRET-TITLE'));
}

rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.log(`\n${failed} check(s) FAILED`);
  process.exit(1);
}
console.log('\n=== the restore drill opens a backup the way a restore would ===');
