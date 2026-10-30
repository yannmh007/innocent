// What a payer types, sealed (docs/edge/pii.ts, migration 054).
//
// WHY. A copy of the database that leaves — a leaked backup, a pasted service
// key — must not carry anyone's KPay number or transaction id readable, and
// the reused-transaction check must still work without them. Pinned here: a
// sealed value opens with its keys and its place only; moved to another row
// or column, altered, or opened with another key, it does not; the index is
// the same for the same number however it was typed, different under another
// key, and not a plain hash anyone could recompute; the masks show the payer
// what they need and no more; and with no keys there is no sealing at all.
//
//   node tool/js/pii_test.mjs

import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createDecipheriv, createHash, hkdfSync, randomBytes } from 'crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const pii = await import(join(ROOT, 'docs/edge/pii.ts'));
let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

const k1 = await pii.piiKeys(randomBytes(32).toString('base64'), randomBytes(32).toString('base64'));
const k2 = await pii.piiKeys(randomBytes(32).toString('base64'), randomBytes(32).toString('base64'));
check('two 32-byte keys make a key pair', k1 !== null && k2 !== null);
check('no keys: no sealing', (await pii.piiKeys('', '')) === null);
check('a short key is refused, not padded',
  (await pii.piiKeys(randomBytes(16).toString('base64'), randomBytes(32).toString('base64'))) === null);
check('junk is refused', (await pii.piiKeys('not base64 at all!!', 'x')) === null);

const id = '3f2c8a1e-0d5b-4c7e-9a61-2b8f0e4d7c19';
const aad = `premium_requests:reference:${id}`;
const ref = '01003945 7712 0098';
const sealed = await pii.seal(k1, ref, aad);
check('sealed is p1.<iv>.<ct>', /^p1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$/.test(sealed));
check('nothing of the number is in it', !sealed.includes('7712') && !sealed.includes('0100'));
check('it opens with its keys and its place', (await pii.open(k1, sealed, aad)) === ref);
check('sealed twice, two different values (fresh IV)', sealed !== await pii.seal(k1, ref, aad));
check('moved to another row, it does not open',
  (await pii.open(k1, sealed, 'premium_requests:reference:00000000-0000-4000-8000-000000000000')) === null);
check('moved to another column, it does not open',
  (await pii.open(k1, sealed, `premium_requests:sender_phone:${id}`)) === null);
check('under another key, it does not open', (await pii.open(k2, sealed, aad)) === null);
const flipped = sealed.slice(0, -2) + (sealed.slice(-2) === 'AA' ? 'AB' : 'AA');
check('altered by a byte, it does not open', (await pii.open(k1, flipped, aad)) === null);
check('not one of ours: null, not a throw', (await pii.open(k1, 'plain text', aad)) === null);
check('Burmese text survives the round trip',
  (await pii.open(k1, await pii.seal(k1, 'ညီမ အကောင့်ကနေ', aad), aad)) === 'ညီမ အကောင့်ကနေ');

const n = pii.normaliseReference;
check('a transaction id typed three ways is one id',
  n('0100 3945-7712.0098') === n('01003945771200 98') && n('ab-12cd') === 'AB12CD');
const i1 = await pii.blindIndex(k1, 'reference', n(ref));
check('the index is 64 hex', /^[0-9a-f]{64}$/.test(i1));
check('the same number, typed differently, has the same index',
  i1 === await pii.blindIndex(k1, 'reference', n('0100-3945-7712-0098')));
check('another number, another index',
  i1 !== await pii.blindIndex(k1, 'reference', n('0100394577120099')));
check('under another key, another index', i1 !== await pii.blindIndex(k2, 'reference', n(ref)));
check('another column, another index', i1 !== await pii.blindIndex(k1, 'sender_phone', n(ref)));
const plain = createHash('sha256').update(n(ref)).digest('hex');
const plainKinded = createHash('sha256').update('reference:' + n(ref)).digest('hex');
check('not a plain SHA-256 anyone could recompute', i1 !== plain && i1 !== plainKinded);

const p = pii.normalisePhone;
check('+95, 95 and 0 are one phone', p('+95 9 123 456 789') === '09123456789' &&
  p('959123456789') === '09123456789' && p('09-123-456-789') === '09123456789');
check('a phone is masked to its first two and last three digits',
  pii.maskPhone('+95 9 123 456 789') === '09••••••789');
check('a transaction id is masked to its last four', pii.maskReference(ref) === '••••••0098');
check('a short value is masked whole', pii.maskPhone('123') === '•••' && pii.maskReference('AB') === '•••');

// ── whole files: the database backup ─────────────────────────────────────
// Sealed by ingest.ts, opened by studio.ts, and — with the project gone — by
// tool/restore_backup.py with the owner's copy of PII_ENC_KEY. Node's own
// HKDF and AES-GCM read what pii.ts writes, so the format is the documented
// one and not just whatever WebCrypto happens to do.
{
  const raw = randomBytes(32);
  const b64 = raw.toString('base64');
  const bk = await pii.derivedKey(b64, pii.BACKUP_KEY_INFO);
  check('a backup key derives from PII_ENC_KEY', bk !== null);
  check('no key, no backup key', (await pii.derivedKey('', pii.BACKUP_KEY_INFO)) === null);
  check('a short key derives nothing',
    (await pii.derivedKey(randomBytes(16).toString('base64'), pii.BACKUP_KEY_INFO)) === null);
  const gz = new Uint8Array(randomBytes(70000));   // more than one toB64 piece
  const sealedFile = await pii.sealFile(bk, gz, pii.BACKUP_AAD);
  check('a sealed file starts IBK1', pii.isSealedFile(sealedFile) &&
    new TextDecoder().decode(sealedFile.slice(0, 4)) === 'IBK1');
  check('a gzip is not a sealed file', !pii.isSealedFile(new Uint8Array([0x1f, 0x8b, 8, 0])));
  check('it is 32 bytes longer: magic, IV, tag', sealedFile.length === gz.length + 32);
  const back = await pii.openFile(bk, sealedFile, pii.BACKUP_AAD);
  check('it opens with its key and its label', back !== null &&
    Buffer.from(back).equals(Buffer.from(gz)));
  check('another label does not open it',
    (await pii.openFile(bk, sealedFile, 'premium_requests:proof')) === null);
  const other = await pii.derivedKey(b64, 'another-use-v1');
  check('a key derived for another use does not open it',
    (await pii.openFile(other, sealedFile, pii.BACKUP_AAD)) === null);
  const bent = sealedFile.slice();
  bent[bent.length - 1] ^= 1;
  check('an altered file does not open', (await pii.openFile(bk, bent, pii.BACKUP_AAD)) === null);
  const nodeKey = Buffer.from(hkdfSync('sha256', raw, Buffer.alloc(32),
    Buffer.from(pii.BACKUP_KEY_INFO), 32));
  const d = createDecipheriv('aes-256-gcm', nodeKey, sealedFile.slice(4, 16));
  d.setAAD(Buffer.from(pii.BACKUP_AAD));
  d.setAuthTag(Buffer.from(sealedFile.slice(-16)));
  const nodeOpened = Buffer.concat([d.update(sealedFile.slice(16, -16)), d.final()]);
  check('Node\'s HKDF and AES-GCM open it (the documented format)', nodeOpened.equals(Buffer.from(gz)));
  // restore_backup_test.py holds the same vector for the Python derivation.
  const vec = Buffer.from(hkdfSync('sha256', Buffer.from([...Array(32).keys()]), Buffer.alloc(32),
    Buffer.from(pii.BACKUP_KEY_INFO), 32)).toString('hex');
  check('the derivation vector is the one restore_backup_test.py pins',
    vec === '138cd64bae9bf39faf2071a0abdc3921568565bbd5c867078d11f586fd3f62c0');
  // A payment screenshot: its own derived key, and its request as the label.
  const pk = await pii.derivedKey(b64, pii.PROOF_KEY_INFO);
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...randomBytes(200)]);
  const receipt = await pii.sealFile(pk, png, pii.proofAad(id));
  check('a receipt opens for its own request',
    Buffer.from(await pii.openFile(pk, receipt, pii.proofAad(id))).equals(Buffer.from(png)));
  check('a receipt moved to another request does not open',
    (await pii.openFile(pk, receipt, pii.proofAad('00000000-0000-4000-8000-000000000000'))) === null);
  check('the backup key does not open a receipt, nor the receipt key a backup',
    (await pii.openFile(bk, receipt, pii.proofAad(id))) === null &&
    (await pii.openFile(pk, sealedFile, pii.BACKUP_AAD)) === null &&
    pii.PROOF_KEY_INFO !== pii.BACKUP_KEY_INFO);
  check('toB64 is standard base64, in pieces',
    pii.toB64(gz) === Buffer.from(gz).toString('base64') && pii.toB64(new Uint8Array()) === '');
}

if (failed) {
  console.log(`\n${failed} check(s) FAILED`);
  process.exit(1);
}
console.log('\n=== all checks on sealed payment fields passed ===');
