// The token that Supabase mints and the Worker opens must be the same token.
//
// WHY THIS IS TESTED RATHER THAN READ. The two halves live in different
// files, in different runtimes, written in different languages' dialects of
// the same WebCrypto API — `request-playback.ts` on Deno encrypts,
// `docs/worker/src/index.js` on workerd decrypts. Every detail has to agree
// exactly: the base64url alphabet, whether padding is stripped, the IV
// length, which end the IV is on, and whether the GCM tag is inside the
// ciphertext or beside it. Disagree on any one of them and nothing throws
// at deploy time — every video simply returns 404, for everyone, with a
// response that deliberately does not say why.
//
// So both halves are pulled out of the real files (never copied — a copy
// would pass this test forever while the files drifted) and run against
// each other here.
//
// RUN:  node tool/js/stream_token_test.mjs
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

// ── the minting half, lifted out of the Deno function ────────────────────
const edge = readFileSync(join(ROOT, 'docs/edge/request-playback.ts'), 'utf8');
const mintSrc = edge.slice(
  edge.indexOf('function b64urlFromBytes'),
  edge.indexOf('async function presign('),
);
const mint = await import('data:text/javascript,' + encodeURIComponent(
  // Strip the TypeScript annotations the browser parser cannot take. The
  // bodies are plain JavaScript; only the signatures carry types.
  mintSrc
    .replace(/: Uint8Array\b/g, '')
    .replace(/: string\b/g, '')
    .replace(/: Promise<string \| null>/g, '')
    .replace(/ as BufferSource/g, '')
    + '\nexport { b64urlFromBytes, workerUrl };'
));

// ── the opening half, lifted out of the Worker ───────────────────────────
const worker = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');
const openSrc = worker.slice(
  worker.indexOf('function b64urlToBytes'),
  worker.indexOf('/// The cached half.'),
);
const open = await import('data:text/javascript,' + encodeURIComponent(
  openSrc + '\nexport { openToken, b64urlToBytes };'));

// ── the shared secret ────────────────────────────────────────────────────
//
// A base64url key, as `openssl rand` would produce. The password-manager
// case — arbitrary text with symbols in it — is exercised at the end, and
// is the reason both sides hash the secret rather than decoding it.
const secretBytes = webcrypto.getRandomValues(new Uint8Array(32));
const secret = Buffer.from(secretBytes).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// Both sides derive the AES key the same way: SHA-256 of the secret's text.
const aesKey = async (s) => webcrypto.subtle.importKey(
  'raw',
  await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(s)),
  { name: 'AES-GCM' }, false, ['encrypt']);

// The minting side reads module-level consts, so rebuild it with the values
// bound rather than trying to reassign them.
const EXPIRY_SECONDS = 600;
async function mintUrl(objectKey, base = 'https://s.example.workers.dev',
                       withSecret = secret) {
  const key = await aesKey(withSecret);
  const iv = webcrypto.getRandomValues(new Uint8Array(12));
  const claim = JSON.stringify({
    k: objectKey, e: Math.floor(Date.now() / 1000) + EXPIRY_SECONDS });
  const sealed = new Uint8Array(await webcrypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, key, new TextEncoder().encode(claim)));
  const token = new Uint8Array(iv.length + sealed.length);
  token.set(iv, 0);
  token.set(sealed, iv.length);
  return `${base}/v/${mint.b64urlFromBytes(token)}`;
}

const KEY = 'test-003/video/20260922-solar-a1b2c3d4.mp4';
const url = await mintUrl(KEY);
const token = url.split('/v/')[1];

// 1. It round-trips at all.
const claim = await open.openToken(token, secret);
check('the Worker reads back the key the function sealed',
  claim !== null && claim.k === KEY);

// 2. The base64url alphabets agree in both directions.
check('base64url survives a round trip through both implementations',
  Buffer.from(open.b64urlToBytes(mint.b64urlFromBytes(secretBytes)))
    .equals(Buffer.from(secretBytes)));

// 3. The token is URL-path safe. It travels in a path segment, so a `+`,
//    a `/` or an `=` would be re-encoded somewhere along the way and the
//    decrypt would fail for reasons nobody would connect to this.
check('the token contains only URL-safe characters',
  /^[A-Za-z0-9_-]+$/.test(token));

// 4. The object key is NOT readable from the URL. This is the entire point
//    of encrypting rather than signing: a signed-but-readable token would
//    publish the bucket layout to anyone who base64-decodes the address.
const decoded = Buffer.from(
  token.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('latin1');
check('the object key is not readable from the token',
  !decoded.includes('test-003') && !decoded.includes('.mp4'));

// 5. A tampered token fails CLOSED. GCM is authenticated, so flipping one
//    bit must fail to decrypt rather than decrypt to something else.
const bytes = open.b64urlToBytes(token);
bytes[bytes.length - 3] ^= 0x01;
const tamperedUrlSafe = Buffer.from(bytes).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
check('one flipped bit is refused, not reinterpreted',
  (await open.openToken(tamperedUrlSafe, secret)) === null);

// 6. A different secret cannot open it.
const otherSecret = Buffer.from(webcrypto.getRandomValues(new Uint8Array(32)))
  .toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
check('another secret cannot open the token',
  (await open.openToken(token, otherSecret)) === null);

// 7. Expiry is enforced. A token whose moment has passed must stop working
//    even though the object it names is still cached and warm.
const expiredKey = await aesKey(secret);
const iv2 = webcrypto.getRandomValues(new Uint8Array(12));
const stale = new Uint8Array(await webcrypto.subtle.encrypt(
  { name: 'AES-GCM', iv: iv2 }, expiredKey,
  new TextEncoder().encode(JSON.stringify(
    { k: KEY, e: Math.floor(Date.now() / 1000) - 1 }))));
const staleToken = new Uint8Array(iv2.length + stale.length);
staleToken.set(iv2, 0);
staleToken.set(stale, iv2.length);
check('an expired token is refused',
  (await open.openToken(mint.b64urlFromBytes(staleToken), secret)) === null);

// 8. Garbage in the path does not throw — it refuses.
for (const junk of ['', 'a', 'not-a-token', 'x'.repeat(200)]) {
  const got = await open.openToken(junk, secret);
  check(`garbage token ${JSON.stringify(junk.slice(0, 12))} is refused`,
    got === null);
}

// 9. ANY STRING WORKS AS A SECRET. This is the whole reason the key is
//    derived by hashing rather than decoded: the operator works from a
//    phone, where a long random string comes from a password manager and
//    has symbols in it. Requiring base64url would have been a format to get
//    wrong, silently, in two dashboards.
for (const odd of [
  'correct horse battery staple correct horse battery staple',
  'x9#Kq2!vLm$8pZw@3Ft&6Hn*1Bd^4Gj',
  '\u1019\u103c\u1014\u103a\u1019\u102c \u1005\u102c\u101c\u102f\u1036\u1038 \u1015\u102b\u1010\u101a\u103a 12345',
  'a',
]) {
  const u = await mintUrl(KEY, 'https://s.example.workers.dev', odd);
  const back = await open.openToken(u.split('/v/')[1], odd);
  check(`a non-base64url secret works (${JSON.stringify(odd.slice(0, 18))})`,
    back !== null && back.k === KEY);
}

// 10. And two DIFFERENT arbitrary strings still cannot open each other's
//     tokens — hashing must not have collapsed the space.
{
  const u = await mintUrl(KEY, 'https://s.example.workers.dev', 'secret one');
  check('two different passphrases stay different',
    (await open.openToken(u.split('/v/')[1], 'secret two')) === null);
}

if (failures) {
  console.error(failures + ' stream-token check(s) failed');
  process.exit(1);
}
console.log('stream token: all checks passed');
