// docs/edge/media_grant.js: during the rollout an app that can open seals
// gets the sealed twin and its key, every other app the plaintext exactly as
// before, and nothing sealed is ever signed for an app that cannot open it.
//
//   node tool/js/media_grant_test.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import * as g from '../../docs/edge/media_grant.js';
import * as k from '../../docs/edge/media_keys.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const fx = JSON.parse(readFileSync(path.join(here, '..', '..', 'test', 'fixtures', 'media_device_key_test.json'), 'utf8'));
const subtle = globalThis.crypto.subtle;

let checks = 0;
function ok(cond, what) {
  checks++;
  if (!cond) {
    console.log('FAIL ' + what);
    process.exit(1);
  }
  console.log('ok   ' + what);
}
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const B = 'innocent-media';

const twin = { bucket: B, sealed_key: 's/aa', plain_key: 'p/master', dek_id: 'd1', kek_version: 1, wrapped: '', plain_size: 100, sealed_size: 156 };
const born = { bucket: B, sealed_key: 's/rung720', plain_key: null, dek_id: 'd2', kek_version: 1, wrapped: '', plain_size: 50, sealed_size: 106 };
const other = { bucket: 'innocent-public', sealed_key: 's/x', plain_key: 'p/rung360', dek_id: 'd3', kek_version: 1, wrapped: '' };
const keys = ['p/master', 's/rung720', 'p/rung360', ''];

const forNew = g.planSeal(keys, [twin, born, other], { canOpen: true, bucket: B });
ok(forNew.get('p/master').sign === 's/aa' && forNew.get('p/master').row === twin,
  'an app that opens seals: the sealed twin of a plaintext object');
ok(forNew.get('s/rung720').sign === 's/rung720' && forNew.get('s/rung720').row === born,
  'an app that opens seals: a born-sealed object with its key');
ok(forNew.get('p/rung360').sign === 'p/rung360' && forNew.get('p/rung360').row === null,
  'a row in another bucket is ignored: the plaintext, as before');
ok(!forNew.has(''), 'an empty key is not planned');

const forOld = g.planSeal(keys, [twin, born, other], { canOpen: false, bucket: B });
ok(forOld.get('p/master').sign === 'p/master' && forOld.get('p/master').row === null,
  'an older app: the plaintext, exactly as before');
ok(forOld.get('s/rung720').sign === null, 'an older app is never signed an object it cannot open');
ok(g.planSeal(['p/a'], [], { canOpen: true, bucket: B }).get('p/a').sign === 'p/a',
  'no rows at all (today): every key signed as it is');

ok(g.wrapMode('require') === 'require' && g.wrapMode(' OFF ') === 'off' && g.wrapMode('') === 'prefer' &&
  g.wrapMode('yes please') === 'prefer', 'SEAL_DEVICE_WRAP read strictly, unknown is prefer');

// -- the seal block --------------------------------------------------------------
const kek = await k.importKek(k.b64(k.newDek()));
const dek = k.newDek();
const row = { ...born, wrapped: await k.wrapDek(kek, dek, 'd2', 1) };
const deviceKey = await k.importDeviceKey(fx.public_spki);
const priv = await subtle.importKey('pkcs8', k.unb64(fx.private_pkcs8), { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['decrypt']);

const rsa = await g.sealBlock(kek, row, { deviceKey, mode: 'prefer' });
ok(rsa.wrap === 'rsa' && rsa.v === 1 && rsa.dek_id === 'd2' && rsa.plain_size === 50 && rsa.sealed_size === 106,
  'with the phone\'s key: an RSA-wrapped block with the sizes');
ok(same(new Uint8Array(await subtle.decrypt({ name: 'RSA-OAEP' }, priv, k.unb64(rsa.dek))), dek),
  'the phone opens the DEK in it');
const tls = await g.sealBlock(kek, row, { deviceKey: null, mode: 'prefer' });
ok(tls.wrap === 'tls' && same(k.unb64(tls.dek), dek), 'no phone key, prefer: the DEK over TLS');
ok(await g.sealBlock(kek, row, { deviceKey: null, mode: 'require' }) === null,
  'no phone key, require: no block (the object is then not signed)');
const off = await g.sealBlock(kek, row, { deviceKey, mode: 'off' });
ok(off.wrap === 'tls', 'off: TLS even with a phone key (the escape hatch)');
let refused = false;
try {
  await g.sealBlock(kek, { ...row, dek_id: 'd9' }, { deviceKey, mode: 'prefer' });
} catch (e) {
  refused = e instanceof k.KeyError;
}
ok(refused, 'a row whose wrap belongs to another dek_id is refused, not opened');

ok(g.sealMode('') === 'ask' && g.sealMode(' ON ') === 'on' && g.sealMode('off') === 'off' &&
  g.sealMode('yes') === 'ask', 'SEAL_MODE read strictly, unknown is ask');
ok(!g.looksForSeals('ask', {}) && g.looksForSeals('ask', { seal: 1 }) && !g.looksForSeals('ask', { seal: '1' }),
  'ask: only a request that says seal: 1 looks — every released app is answered as before');
ok(g.looksForSeals('on', {}) && !g.looksForSeals('off', { seal: 1 }), 'on: every request; off: none');
const withHead = await g.sealBlock(kek, { ...row, header: 'A'.repeat(56) }, { deviceKey, mode: 'prefer' });
ok(withHead.header === 'A'.repeat(56), 'the header goes with the block when the row has it');
ok(!('header' in rsa) && !('header' in (await g.sealBlock(kek, { ...row, header: 'short' }, { deviceKey, mode: 'prefer' }))),
  'no header, or a malformed one: none in the block (the phone reads the head instead)');

console.log(`media grant (js): all checks passed (${checks})`);
