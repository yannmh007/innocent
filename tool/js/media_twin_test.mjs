// docs/edge/media_twin.js: only the open films may be sealed, a twin's key
// says nothing, and a twin is recorded only when it is exactly what was
// issued — right DEK, right sizes, right header, first and last segments
// opening.
//
//   node tool/js/media_twin_test.mjs

import * as t from '../../docs/edge/media_twin.js';
import * as k from '../../docs/edge/media_keys.js';
import * as s from '../../docs/edge/media_seal.js';

let checks = 0;
function ok(cond, what) {
  checks++;
  if (!cond) {
    console.log('FAIL ' + what);
    process.exit(1);
  }
  console.log('ok   ' + what);
}
async function refused(p, why) {
  try {
    await p;
  } catch (e) {
    return e instanceof k.KeyError && (!why || e.message.includes(why));
  }
  return false;
}

ok(t.twinAllowed('open-film-sintel') && t.twinAllowed('open-film-tears-of-steel'), 'the open films may be sealed');
ok(!t.twinAllowed('some-film') && !t.twinAllowed('open-film-') && !t.twinAllowed('open-film-../x') &&
  !t.twinAllowed(null), 'nothing else may — no other slug, no path tricks');
const key = t.newSealedKey();
ok(t.isSealedKey(key) && key !== t.newSealedKey(), 'a twin key is s/ and 32 random hex digits');
ok(!t.isSealedKey('s/../video/x') && !t.isSealedKey('video/open-film-sintel/master.mp4'),
  'and nothing else is taken for one');

// A real twin: seal a plaintext the way the runner does, under a DEK this
// "function" issued.
const kek = await k.importKek(k.b64(k.newDek()));
const dekId = '0d6a1f4e-1111-4222-8333-944455556666';
const dek = k.newDek();
const wrapped = await k.wrapDek(kek, dek, dekId, 1);
const plain = new Uint8Array(3 * s.PLAIN_SEGMENT + 1234).map((_, i) => (i * 7 + 3) & 255);
const sealed = await s.sealAll(plain, dek, s.aadFor(dekId));
const item = {
  dek_id: dekId, wrapped, plain_key: 'video/open-film-sintel/master.mp4', sealed_key: key,
  plain_size: plain.length, header: k.b64(sealed.subarray(0, s.HEADER)),
};
const io = (over = {}) => ({
  plainSize: async () => plain.length,
  sealedSize: async () => sealed.length,
  readSealed: async (a, b) => sealed.slice(a, b),
  ...over,
});

const row = await t.checkTwin(kek, item, io());
ok(row.dek_id === dekId && row.sealed_size === sealed.length && row.plain_size === plain.length &&
  row.header.length === 56 && row.kind === 'video' && row.wrapped === wrapped,
  'a true twin: the row, with its sizes and header');
ok(await refused(t.checkTwin(kek, { ...item, dek_id: '0d6a1f4e-1111-4222-8333-000000000000' }, io())),
  'a wrapped DEK claimed for another row is refused (not issued for it)');
ok(await refused(t.checkTwin(await k.importKek(k.b64(k.newDek())), item, io())),
  'a DEK this KEK did not wrap is refused');
ok(await refused(t.checkTwin(kek, item, io({ sealedSize: async () => sealed.length - 16 })), 'sealed size'),
  'a twin cut short is refused');
ok(await refused(t.checkTwin(kek, item, io({ plainSize: async () => plain.length + 1 })), 'plain object'),
  'a plain object of another size is refused');
const other = await s.sealAll(plain, k.newDek(), s.aadFor(dekId));
ok(await refused(t.checkTwin(kek, { ...item, header: k.b64(other.subarray(0, s.HEADER)) },
  io({ readSealed: async (a, b) => other.slice(a, b) })), 'does not open'),
  'a twin sealed under another DEK is refused');
const flipped = sealed.slice();
flipped[sealed.length - 5] ^= 1;
ok(await refused(t.checkTwin(kek, item, io({ readSealed: async (a, b) => flipped.slice(a, b) })), 'does not open'),
  'a twin whose last segment is altered is refused');
ok(await refused(t.checkTwin(kek, { ...item, header: k.b64(new Uint8Array(40)) }, io()), 'header'),
  'a header that is not the twin\'s is refused');
ok(await refused(t.checkTwin(kek, { ...item, sealed_key: 'video/x' }, io()), 'sealed_key'),
  'a twin key that is not s/<hex> is refused');
ok(await refused(t.checkTwin(kek, { ...item, plain_key: 's/' + 'a'.repeat(32) }, io()), 'plain_key'),
  'a twin of a twin is refused');

// One segment only: header and the end mark in one read.
const small = new Uint8Array(1000).fill(9);
const dek2 = k.newDek();
const id2 = '0d6a1f4e-2222-4222-8333-944455556666';
const sealed2 = await s.sealAll(small, dek2, s.aadFor(id2));
const row2 = await t.checkTwin(kek, {
  dek_id: id2, wrapped: await k.wrapDek(kek, dek2, id2, 1), plain_key: 'video/open-film-x/a.mp4',
  sealed_key: t.newSealedKey(), plain_size: small.length, header: k.b64(sealed2.subarray(0, 40)),
}, { plainSize: async () => small.length, sealedSize: async () => sealed2.length,
  readSealed: async (a, b) => sealed2.slice(a, b) });
ok(row2.sealed_size === sealed2.length, 'a one-segment twin opens in one read');

// An IMAGE's row carries the DEK the wrap opened to (the app opens a poster
// with the key from its row), and no wrap.
const img = await t.checkTwin(kek, { ...item, plain_key: 'photo/open-film-sintel/still-1.jpg' }, io(), { kind: 'image' });
ok(img.dek === k.b64(dek) && img.wrapped === undefined && img.kek_version === undefined &&
  img.sealed_size === sealed.length && img.header.length === 56,
  'an image row: the DEK the wrap opened to, sizes, header — no wrap');
ok(await refused(t.checkTwin(kek, { ...item, dek_id: '0d6a1f4e-1111-4222-8333-000000000000' }, io(), { kind: 'image' })),
  'an image twin with a DEK not issued for it is refused too');

console.log(`media twin (js): all checks passed (${checks})`);
