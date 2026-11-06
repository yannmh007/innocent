// docs/edge/key_attest.js: is a phone's media key certified by real secure
// hardware, made by our signed app, on a phone that boots what it should?
// (docs/security_review_2026_11.md S3/P3)
//
// WHY. request-playback wraps film keys for whatever RSA key a phone sends.
// This is the check that tells a Keystore key on a genuine phone from a key a
// script made on a computer. Pinned here, on chains built with openssl in the
// shapes Keystore makes (an EC or RSA root, an intermediate, an RSA leaf
// carrying the KeyDescription extension): a good chain passes; a wrong root,
// a changed byte, another key, another challenge, an unlocked phone,
// software-only keys, another app or signer, a revoked or expired
// certificate each fail and say why; hostile input is a verdict, never a
// throw. And Google's two real roots (fixtures, public certificates) verify
// as themselves under the pinned keys.
//
// Skipped where openssl is missing.
//
//   node tool/js/key_attest_test.mjs

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const ka = await import(join(ROOT, 'docs/edge/key_attest.js'));
let failed = 0;
let count = 0;
const check = (what, ok) => {
  count++;
  if (ok) console.log('ok   ' + what);
  else { failed++; console.log('FAIL ' + what); }
};
try { execFileSync('openssl', ['version'], { stdio: 'ignore' }); } catch {
  console.log('key attestation: skipped (no openssl here)');
  process.exit(0);
}

// ── a little DER, enough to write a KeyDescription ──────────────────────
const B = (x) => (Buffer.isBuffer(x) ? x : Buffer.from(x));
const len = (n) => (n < 128 ? [n] : n < 256 ? [0x81, n] : [0x82, n >> 8, n & 255]);
const tlv = (tag, ...parts) => {
  const body = Buffer.concat(parts.map(B));
  return Buffer.concat([B(tag), B(len(body.length)), body]);
};
const ctx = (n, inner) => tlv(n < 31 ? [0xa0 | n] : [0xbf, 0x80 | (n >> 7), n & 0x7f], inner);
const int = (n) => {
  const out = [];
  do { out.unshift(n & 0xff); n = Math.floor(n / 256); } while (n > 0);
  if (out[0] & 0x80) out.unshift(0);
  return tlv([0x02], out);
};
const enumd = (n) => tlv([0x0a], [n]);
const oct = (x) => tlv([0x04], B(x));
const bool = (v) => tlv([0x01], [v ? 0xff : 0]);
const seq = (...p) => tlv([0x30], ...p);
const set = (...p) => tlv([0x31], ...p);

const SIGNER = ka.OUR_APP.signers[0];
function keyDescription({
  level = 1, keymint = 1, challenge = ka.CHALLENGE, pkg = ka.OUR_APP.packageName, signer = SIGNER,
  locked = true, boot = 0, origin = 0,
} = {}) {
  const appId = seq(set(seq(oct(pkg), int(1))), set(oct(Buffer.from(signer, 'hex'))));
  const sw = seq(ctx(709, oct(appId)));
  const hw = seq(
    ctx(702, int(origin)),
    ctx(704, seq(oct(Buffer.alloc(32, 7)), bool(locked), enumd(boot), oct(Buffer.alloc(32, 9)))),
    ctx(705, int(150000)),
    ctx(706, int(202610)),
    ctx(718, int(20261005)),
  );
  return seq(int(300), enumd(level), int(300), enumd(keymint), oct(challenge), oct(''), sw, hw);
}

// ── certificates, the way Keystore chains them ──────────────────────────
const dir = mkdtempSync(join(tmpdir(), 'key-attest-'));
const p = (n) => join(dir, n);
const ssl = (...a) => execFileSync('openssl', a, { stdio: ['ignore', 'pipe', 'pipe'] });
const b64 = (pem) => readFileSync(pem, 'utf8').replace(/-----[^-]+-----|\s+/g, '');
writeFileSync(p('ca.cnf'), 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign\n');

function makeRoot(name, kind) {
  if (kind === 'ec') ssl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', p(name + '.key'));
  else ssl('genrsa', '-out', p(name + '.key'), '2048');
  ssl('req', '-x509', '-new', '-key', p(name + '.key'), '-subj', '/CN=' + name, '-days', '3650',
    kind === 'ec' ? '-sha384' : '-sha256', '-set_serial', '1', '-out', p(name + '.pem'));
}
function makeCa(name, root, days = '3650', serial = '2') {
  ssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', p(name + '.key'));
  ssl('req', '-new', '-key', p(name + '.key'), '-subj', '/CN=' + name, '-out', p(name + '.csr'));
  ssl('x509', '-req', '-in', p(name + '.csr'), '-CA', p(root + '.pem'), '-CAkey', p(root + '.key'),
    '-set_serial', serial, '-days', days, '-sha256', '-extfile', p('ca.cnf'), '-out', p(name + '.pem'));
}
ssl('genrsa', '-out', p('device.key'), '2048');
ssl('req', '-new', '-key', p('device.key'), '-subj', '/CN=Android Keystore Key', '-out', p('device.csr'));
const deviceSpki = ssl('pkey', '-in', p('device.key'), '-pubout', '-outform', 'DER').toString('base64');
let leafN = 0;
function makeLeaf(ca, kd) {
  const name = 'leaf' + (++leafN);
  writeFileSync(p(name + '.cnf'), kd ? `1.3.6.1.4.1.11129.2.1.17=DER:${kd.toString('hex')}\n` : 'basicConstraints=CA:false\n');
  ssl('x509', '-req', '-in', p('device.csr'), '-CA', p(ca + '.pem'), '-CAkey', p(ca + '.key'),
    '-set_serial', String(100 + leafN), '-days', '3650', '-sha256', '-extfile', p(name + '.cnf'), '-out', p(name + '.pem'));
  return b64(p(name + '.pem'));
}
const spkiOf = (pem) => ssl('x509', '-in', pem, '-pubkey', '-noout').toString()
  .replace(/-----[^-]+-----|\s+/g, '');

makeRoot('rootEC', 'ec');
makeRoot('rootRSA', 'rsa');
makeCa('intEC', 'rootEC');
makeCa('intRSA', 'rootRSA');
makeRoot('otherRoot', 'ec');
const roots = { test: spkiOf(p('rootEC.pem')), 'test-rsa': spkiOf(p('rootRSA.pem')) };
const opts = { deviceKey: deviceSpki, challenge: ka.CHALLENGE, roots };
const chain = (leaf, ca = 'intEC', root = 'rootEC') => [leaf, b64(p(ca + '.pem')), b64(p(root + '.pem'))];

// ── the good one, both root kinds ───────────────────────────────────────
const good = makeLeaf('intEC', keyDescription());
let v = await ka.verdict(chain(good), opts);
check('a Keystore-shaped chain to the EC root: ok, and says what it saw',
  v.ok && v.chain === 'ok' && v.root === 'test' && v.level === 'tee' && v.boot === 'verified' &&
  v.locked === true && v.app === 'ok' && v.key === 'match' && v.challenge === 'match' &&
  v.os_patch === 202610 && v.length === 3 && v.why.length === 0);
const goodRsa = makeLeaf('intRSA', keyDescription({ level: 2, keymint: 2 }));
v = await ka.verdict(chain(goodRsa, 'intRSA', 'rootRSA'), opts);
check('the same to an RSA root, StrongBox: ok', v.ok && v.root === 'test-rsa' && v.level === 'strongbox');
v = await ka.verdict([good, b64(p('intEC.pem'))], opts);
check('a phone that leaves its root off: still found by the pinned key', v.ok && v.root === 'test');

// ── each thing that must fail, and says so ──────────────────────────────
v = await ka.verdict(chain(good), { ...opts, roots: { other: spkiOf(p('otherRoot.pem')) } });
check('a chain to a root we do not pin: refused (unknown_root)', !v.ok && v.chain === 'unknown_root' && v.why.includes('chain'));
v = await ka.verdict(chain(good), { ...opts, roots: ka.GOOGLE_ROOTS });
check('a test chain is not Google\'s', !v.ok && v.chain === 'unknown_root');
const flip = (b64s, at) => {
  const d = Buffer.from(b64s, 'base64');
  d[at < 0 ? d.length + at : at] ^= 1;
  return d.toString('base64');
};
v = await ka.verdict([flip(good, -5), ...chain(good).slice(1)], opts);
check('one bit of the leaf\'s signature changed: bad_signature_0', !v.ok && v.chain === 'bad_signature_0');
const leafDer = Buffer.from(good, 'base64');
const at = leafDer.indexOf(Buffer.from(ka.CHALLENGE));
v = await ka.verdict([flip(good, at), ...chain(good).slice(1)], opts);
check('the challenge rewritten inside a signed leaf: the signature no longer holds', !v.ok && v.chain === 'bad_signature_0');
v = await ka.verdict(chain(good), { ...opts, deviceKey: spkiOf(p('rootRSA.pem')) });
check('a genuine chain for another key than the one sent: key mismatch', !v.ok && v.key === 'mismatch' && v.why.includes('key'));
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ challenge: 'something else' }))), opts);
check('another challenge: refused', !v.ok && v.challenge === 'mismatch');
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ locked: false, boot: 2 }))), opts);
check('an unlocked bootloader: boot unverified, refused', !v.ok && v.boot === 'unverified' && v.locked === false && v.why.includes('boot'));
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ boot: 1 }))), opts);
check('a self-signed OS: refused', !v.ok && v.boot === 'self-signed');
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ level: 0, keymint: 0 }))), opts);
check('a software-only key: refused (level)', !v.ok && v.level === 'software' && v.why.includes('level'));
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ pkg: 'com.example.ripper' }))), opts);
check('another app\'s key: refused', !v.ok && v.app === 'other_package');
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ signer: 'ab'.repeat(32) }))), opts);
check('our package name, another signer (a rebuilt APK): refused', !v.ok && v.app === 'other_signer');
v = await ka.verdict(chain(makeLeaf('intEC', keyDescription({ origin: 2 }))), opts);
check('a key imported rather than made inside: refused', !v.ok && v.why.includes('imported_key'));
v = await ka.verdict(chain(makeLeaf('intEC', null)), opts);
check('a certificate with no KeyDescription: refused, says so', !v.ok && v.why.includes('no_keydescription'));
v = await ka.verdict(chain(good), { ...opts, revoked: new Set(['2']) });
check('a revoked intermediate (by serial): refused', !v.ok && v.revoked === true && v.why.includes('revoked'));
v = await ka.verdict(chain(good), { ...opts, revoked: new Set(['deadbeef']) });
check('a status list that does not name it: not revoked', v.ok && v.revoked === false);
check('no status list: revocation unknown, not a refusal', (await ka.verdict(chain(good), opts)).revoked === null);
v = await ka.verdict(chain(good), { ...opts, now: Date.now() + 20 * 365 * 86400e3 });
check('an expired intermediate: refused', !v.ok && v.chain === 'expired_1');

// ── hostile input is a verdict, never a throw ───────────────────────────
let threw = false;
const odd = [];
try {
  for (const c of [null, 'x', [], [good], ['!!!', '###'], [good, 'AAAA'], new Array(11).fill(good),
    [Buffer.from([0x30, 0x84, 0xff, 0xff, 0xff, 0xff]).toString('base64'), good]]) {
    odd.push((await ka.verdict(c, opts)).ok);
  }
} catch (e) {
  threw = String(e);
}
v = await ka.verdict([good, 'A'.repeat(13000)], opts);
check('a certificate far bigger than Keystore makes: refused before any work', !v.ok && v.chain === 'too_large');
check('garbage, one certificate, eleven, truncated DER: refused, nothing thrown' + (threw ? ' (' + threw + ')' : ''),
  !threw && odd.every((x) => x === false));

// ── Google's real roots, and the pins ───────────────────────────────────
const rsaRoot = b64(join(ROOT, 'tool/js/fixtures/google_attest_root_rsa.crt'));
const ecRoot = b64(join(ROOT, 'tool/js/fixtures/google_attest_root_ec.crt'));
v = await ka.verdict([rsaRoot, rsaRoot]);
check('Google\'s RSA-4096 root verifies itself under the pinned key', v.chain === 'ok' && v.root === 'google-rsa');
v = await ka.verdict([ecRoot, ecRoot]);
check('Google\'s ECDSA P-384 root verifies itself under the pinned key', v.chain === 'ok' && v.root === 'google-ec');
const sha = (s) => createHash('sha256').update(Buffer.from(s, 'base64')).digest('hex');
check('the pins are the keys their comments name',
  sha(ka.GOOGLE_ROOTS['google-rsa']) === 'feb2ea7551ee316ed4bb443c8293b884dbfdea40b603ee3e4f4a897e4580fbae' &&
  sha(ka.GOOGLE_ROOTS['google-ec']) === '3ee44512a1af2beb39c889490c60ea3f82e43f5d5a5532f5ab9419f676cd07ec');
const rev = ka.revokedFrom({ entries: { '00A1B2': { status: 'REVOKED', reason: 'KEY_COMPROMISE' }, c3: { status: 'SUSPENDED' } } });
check('the status list: serials normalised to lowercase hex without leading zeros', rev.has('a1b2') && rev.has('c3') && rev.size === 2);
check('a status list that is not one: empty', ka.revokedFrom('nonsense').size === 0 && ka.revokedFrom(null).size === 0);

if (failed) {
  console.log(`\n${failed} of ${count} check(s) FAILED`);
  process.exit(1);
}
console.log(`\n=== ${count} check(s) on Android key attestation passed ===`);
