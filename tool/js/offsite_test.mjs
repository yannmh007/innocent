// The off-site copy's signatures and names (migration 045).
//
// WHY THIS IS TESTED RATHER THAN READ. The off-site bucket is somebody
// else's S3 (Backblaze B2 by default), its key lives in Supabase's secret
// store, and nothing in a checkout can reach it. Every way of signing for it
// wrongly — the R2 region left in the scope, the R2 host left in the URL, the
// R2 key used for the wrong bucket — fails the same opaque way, a 403 that
// names nothing, on the first night the runner tries to copy a film.
//
// So the real functions are pulled out of `docs/edge/ingest.ts` (never
// copied) and checked against an INDEPENDENT signer written here on node's
// crypto, which is itself first checked against AWS's published presigned-URL
// example. And the names: what goes into the off-site bucket is an id, never
// a film's title, and the backup's off-site key mirrors its R2 key.
//
// RUN:  node tool/js/offsite_test.mjs
// tool/check.py runs it when node is present, and says so loudly when not.

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createHash, createHmac } from 'crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const FILE = 'docs/edge/ingest.ts';
const src = readFileSync(join(ROOT, FILE), 'utf8');

let failures = 0;
const check = (label, ok) => {
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};

const between = (from, to) => {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a + 1);
  if (a < 0 || b < 0 || b <= a) {
    console.log('FAIL could not find ' + JSON.stringify(from) + ' .. ' +
      JSON.stringify(to) + ' in ' + FILE);
    process.exit(1);
  }
  return src.slice(a, b);
};

// Only the signatures carry types; every body is JavaScript already.
const ts = (s) => s
  .replace(/interface S3Target \{[^}]*\}/g, '')
  .replace(/ as BufferSource/g, '')
  .replace(/ as BodyInit/g, '')
  .replace(/method: 'GET' \| 'PUT' \| 'DELETE' \| 'HEAD'/g, 'method')
  .replace(/: Promise<[^>]*>/g, '')
  .replace(/: Record<string, string>/g, '')
  .replace(/: S3Target \| null/g, '')
  .replace(/: S3Target/g, '')
  .replace(/: Uint8Array\b/g, '')
  .replace(/now: Date = /g, 'now = ')
  .replace(/: string\b/g, '')
  .replace(/: number\b/g, '');

// ── the independent signer, on node's crypto ─────────────────────────────
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
const mac = (k, s) => createHmac('sha256', k).update(s, 'utf8').digest();
const enc3986 = (c) => encodeURIComponent(c)
  .replace(/[!'()*]/g, (x) => '%' + x.charCodeAt(0).toString(16).toUpperCase());

function presignedSignature({ method, host, path, query, region, secret, amzDate }) {
  const canonicalQuery = Object.keys(query).sort()
    .map((k) => `${enc3986(k)}=${enc3986(query[k])}`).join('&');
  const canonicalRequest = [method, path, canonicalQuery, `host:${host}\n`, 'host',
    'UNSIGNED-PAYLOAD'].join('\n');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/${region}/s3/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha(canonicalRequest)].join('\n');
  let k = Buffer.from(`AWS4${secret}`, 'utf8');
  for (const p of [dateStamp, region, 's3', 'aws4_request']) k = mac(k, p);
  return mac(k, stringToSign).toString('hex');
}

// 1. THE VECTOR: AWS's own worked example of a presigned GET
//    (sigv4-query-string-auth), so the judge is right before it judges.
{
  const got = presignedSignature({
    method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt',
    query: {
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': 'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request',
      'X-Amz-Date': '20130524T000000Z',
      'X-Amz-Expires': '86400',
      'X-Amz-SignedHeaders': 'host',
    },
    region: 'us-east-1', secret: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    amzDate: '20130524T000000Z',
  });
  check('the reference signer reproduces AWS\'s published presigned signature',
    got === 'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
}

// ── the real thing, lifted out of the edge function ──────────────────────
const mod = await import('data:text/javascript,' + encodeURIComponent(
  "const enc = new TextEncoder();\n" +
  "const BACKUP_PREFIX = '_backup/db/';\n" +
  ts(between('async function hmac(', 'async function presign(\n')) +
  ts(between('function regionOf(', 'const OFFSITE = offsiteTarget(')) +
  ts(between('function offsiteKeyFor(', '/// What the off-site bucket holds at [key]')) +
  ts(between('function offsiteBackupKey(', 'async function putBackupOffsite(')) +
  '\nexport { presignAt, regionOf, offsiteTarget, offsiteKeyFor, offsiteBackupKey };'
));

const B2 = 'https://s3.eu-central-003.backblazeb2.com';
const KEY_ID = '003a1b2c3d4e5f60000000001';
const SECRET = 'K003abcdefghijklmnopqrstuvwxyzABCDE';

// ── which store, and which region it signs as ────────────────────────────
check('a Backblaze endpoint names its own region',
  mod.regionOf(B2) === 'eu-central-003' &&
  mod.regionOf('https://s3.us-west-004.backblazeb2.com') === 'us-west-004');
check('any other host needs OFFSITE_REGION',
  mod.regionOf('https://s3.example.com') === '');

const target = mod.offsiteTarget(B2, '', KEY_ID, SECRET, 'innocent-offsite');
check('a full set of secrets is a store', target !== null &&
  target.host === 's3.eu-central-003.backblazeb2.com' && target.region === 'eu-central-003');
check('plain http is never a store (the key would travel readable)',
  mod.offsiteTarget('http://s3.eu-central-003.backblazeb2.com', '', KEY_ID, SECRET, 'b-1x') === null);
check('a missing key, secret or bucket is no store',
  mod.offsiteTarget(B2, '', '', SECRET, 'innocent-offsite') === null &&
  mod.offsiteTarget(B2, '', KEY_ID, '', 'innocent-offsite') === null &&
  mod.offsiteTarget(B2, '', KEY_ID, SECRET, '') === null);
check('an endpoint with a path is refused, not half-used',
  mod.offsiteTarget(B2 + '/innocent-offsite', '', KEY_ID, SECRET, 'innocent-offsite') === null);
check('another provider works once its region is given',
  mod.offsiteTarget('https://s3.example.com', 'eu-west-1', KEY_ID, SECRET, 'my-bucket')?.region
    === 'eu-west-1' &&
  mod.offsiteTarget('https://s3.example.com', '', KEY_ID, SECRET, 'my-bucket') === null);

// ── the signature is the off-site store's, not R2's ─────────────────────
{
  const now = new Date('2026-10-17T09:30:00.000Z');
  const key = 'masters/6c679480-3387-4442-ad3d-4423b8aceb71.mp4';
  for (const method of ['PUT', 'GET', 'HEAD', 'DELETE']) {
    const url = await mod.presignAt(target, method, key, 86400, 'innocent-offsite', now);
    const u = new URL(url);
    const query = {};
    for (const [k, v] of u.searchParams) if (k !== 'X-Amz-Signature') query[k] = v;
    const want = presignedSignature({
      method, host: u.host, path: u.pathname, query,
      region: 'eu-central-003', secret: SECRET, amzDate: '20261017T093000Z',
    });
    check(`a presigned ${method} signs as an independent implementation signs it`,
      u.searchParams.get('X-Amz-Signature') === want);
    if (method === 'PUT') {
      check('it addresses the off-site host and bucket, path-style',
        u.host === 's3.eu-central-003.backblazeb2.com' &&
        u.pathname === `/innocent-offsite/${key}`);
      check('its scope is the off-site region, never R2\'s "auto"',
        u.searchParams.get('X-Amz-Credential') ===
          `${KEY_ID}/20261017/eu-central-003/s3/aws4_request`);
      check('it lasts the day it was asked for', u.searchParams.get('X-Amz-Expires') === '86400');
    }
  }
  // The method is signed: a GET URL is not a PUT URL.
  const get = new URL(await mod.presignAt(target, 'GET', key, 300, 'innocent-offsite', now));
  const put = new URL(await mod.presignAt(target, 'PUT', key, 300, 'innocent-offsite', now));
  check('a GET signature does not work as a PUT',
    get.searchParams.get('X-Amz-Signature') !== put.searchParams.get('X-Amz-Signature'));
}

// R2 still signs exactly as it did: region "auto" at its own host.
{
  const r2 = { host: '0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com',
    region: 'auto', keyId: 'AKIAR2', secret: 'r2-secret' };
  const now = new Date('2026-10-17T09:30:00.000Z');
  const u = new URL(await mod.presignAt(r2, 'GET', 'a/b.mp4', 600, 'innocent-media', now));
  const query = {};
  for (const [k, v] of u.searchParams) if (k !== 'X-Amz-Signature') query[k] = v;
  check('R2 signs as before: region auto, at its own host',
    u.searchParams.get('X-Amz-Signature') === presignedSignature({
      method: 'GET', host: u.host, path: u.pathname, query, region: 'auto',
      secret: 'r2-secret', amzDate: '20261017T093000Z',
    }) && u.pathname === '/innocent-media/a/b.mp4');
}

// ── what the off-site bucket's listing says ─────────────────────────────
{
  const id = '6c679480-3387-4442-ad3d-4423b8aceb71';
  check('a film is stored under its id, with its extension',
    mod.offsiteKeyFor(id, 'solar-eclipse/video/20260922-my-film-a1b2.MP4') ===
      `masters/${id}.mp4`);
  check('never under its name',
    !mod.offsiteKeyFor(id, 'solar-eclipse/video/my-film.mp4').includes('film'));
  check('a file with no extension keeps none',
    mod.offsiteKeyFor(id, 'x/y/noext') === `masters/${id}`);
  check('a backup keeps its date path under db/',
    mod.offsiteBackupKey('_backup/db/2026/10/20261017T093000-daily.json.gz') ===
      'db/2026/10/20261017T093000-daily.json.gz');
}

// ── and nothing hands the runner a key, or a name it chose ──────────────
{
  const finish = between("if (body.type === 'offsite') {", "if (body.type === 'archive') {");
  check('the finished copy\'s key is worked out from the job, not taken from the runner',
    /offsiteKeyFor\(asset, objectKey\)/.test(finish) && !/body\.key/.test(finish));
  check('the size recorded is the bucket\'s answer (HEAD), not the runner\'s',
    /offsiteHead\(key\)/.test(finish) && /bytes = head\.bytes/.test(finish) &&
    !/p_bytes: Number\(body\.bytes/.test(finish));
  const claim = between('async function claimOffsite(', '/// What a runner may say about itself');
  check('the runner gets one presigned PUT, never the off-site secret',
    /presignAt\(OFFSITE, 'PUT'/.test(claim) && !/OFFSITE_SECRET|secret:/.test(claim));
  check('the mirror is the PUBLIC bucket, never the private one',
    /presignAt\(OFFSITE, 'PUT', key, 3600, OFFSITE_PUBLIC_BUCKET\)/.test(src));
}

console.log();
if (failures) {
  console.log(`=== ${failures} off-site check(s) FAILED ===`);
  process.exit(1);
}
console.log('=== off-site: signed for its own store, named by id, sized by the bucket ===');
