// docs/edge/media_issue.js: what the switch makes of a new object, keys
// issued only here, and a sealed object recorded only when it is what was
// issued — as a twin, or born sealed with no plain object at all.
//
//   node tool/js/media_issue_test.mjs

import * as i from '../../docs/edge/media_issue.js';
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

// ── the switch ─────────────────────────────────────────────────────────────
ok(i.sealNewMode('on') === 'on' && i.sealNewMode('canary') === 'canary' && i.sealNewMode(undefined) === 'off' &&
  i.sealNewMode('ON') === 'off' && i.sealNewMode('yes') === 'off', 'only the three positions; anything else is off');
ok(i.makeFor('off', 'open-film-sintel') === 'plain' && i.makeFor('off', 'a-film') === 'plain', 'off: plain for every title');
ok(i.makeFor('canary', 'open-film-sintel') === 'twin' && i.makeFor('canary', 'a-film') === 'plain' &&
  i.makeFor('canary', null) === 'plain', 'canary: a twin at birth for an open film only, plain for anything else');
ok(i.makeFor('on', 'a-film') === 'sealed' && i.makeFor('on', 'open-film-sintel') === 'sealed' &&
  i.makeFor('on', null) === 'sealed', 'on: sealed only, for every title');

// ── issued here ────────────────────────────────────────────────────────────
const kek = await k.importKek(k.b64(k.newDek()));
const a = await i.issue(kek);
const b = await i.issue(kek);
ok(a.dek_id !== b.dek_id && a.sealed_key !== b.sealed_key && a.dek !== b.dek, 'every object its own id, DEK and key');
ok(/^s\/[0-9a-f]{32}$/.test(a.sealed_key) && k.unb64(a.dek).length === 32, 'an s/<32 hex> key and a 32-byte DEK');
const opened = await k.unwrapDek(kek, a.wrapped, a.dek_id, 1);
ok(k.b64(opened) === a.dek, 'the wrap opens to the DEK, under MEDIA_KEK, for its dek_id');
ok(await refused(k.unwrapDek(kek, a.wrapped, b.dek_id, 1)), 'and for no other dek_id');

// ── recorded only as issued ────────────────────────────────────────────────
async function made(issued, plainLen) {
  const plain = new Uint8Array(plainLen).map((_, n) => (n * 13 + 5) & 255);
  const sealed = await s.sealAll(plain, k.unb64(issued.dek), s.aadFor(issued.dek_id));
  const io = (over = {}) => ({
    plainSize: async () => plain.length,
    sealedSize: async () => sealed.length,
    readSealed: async (x, y) => sealed.slice(x, y),
    ...over,
  });
  return { plain, sealed, io, header: k.b64(sealed.subarray(0, s.HEADER)) };
}

const rung = await made(a, 2 * s.PLAIN_SEGMENT + 999);
const twin = await i.record(kek, {
  dek_id: a.dek_id, wrapped: a.wrapped, sealed_key: a.sealed_key, plain_size: rung.plain.length,
  header: rung.header, plain_key: 'video/x/720.mp4',
}, rung.io());
ok(twin.plain_key === 'video/x/720.mp4' && twin.kind === 'video' && twin.wrapped === a.wrapped &&
  twin.dek === undefined, 'a twin: its plain key, the wrap and never the DEK');

let plainLooked = false;
const born = await i.record(kek, {
  dek_id: a.dek_id, wrapped: a.wrapped, sealed_key: a.sealed_key, plain_size: rung.plain.length,
  header: rung.header,
}, rung.io({ plainSize: async () => { plainLooked = true; return null; } }), { born: true });
ok(born.plain_key === null && born.sealed_size === rung.sealed.length && !plainLooked,
  'born sealed: no plain key, and no plain object looked for');
ok(await refused(i.record(kek, {
  dek_id: a.dek_id, wrapped: a.wrapped, sealed_key: a.sealed_key, plain_size: rung.plain.length,
  header: rung.header, plain_key: 'video/x/720.mp4',
}, rung.io(), { born: true }), 'plain_key'), 'a born-sealed object that names a plain one is refused');

const still = await made(b, 30000);
const img = await i.record(kek, {
  dek_id: b.dek_id, wrapped: b.wrapped, sealed_key: b.sealed_key, plain_size: still.plain.length,
  header: still.header,
}, still.io(), { kind: 'image', born: true });
ok(img.dek === b.dek && img.plain_key === null && img.wrapped === undefined,
  'a born-sealed image: the DEK the wrap opened to, no plain key');

ok(await refused(i.record(kek, {
  dek_id: b.dek_id, wrapped: a.wrapped, sealed_key: b.sealed_key, plain_size: still.plain.length,
  header: still.header,
}, still.io(), { kind: 'image', born: true })), 'another object\'s wrap is refused');
const flipped = still.sealed.slice();
flipped[60] ^= 1;
ok(await refused(i.record(kek, {
  dek_id: b.dek_id, wrapped: b.wrapped, sealed_key: b.sealed_key, plain_size: still.plain.length,
  header: still.header,
}, still.io({ readSealed: async (x, y) => flipped.slice(x, y) }), { kind: 'image', born: true }), 'does not open'),
  'an altered object is refused');

console.log(`media issue (js): all checks passed (${checks})`);
