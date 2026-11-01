// docs/edge/media_keys.js: a DEK wrapped by MEDIA_KEK opens only in its own
// row and version; a DEK wrapped for a phone opens with that phone's key,
// and with the padding the app's Keystore uses (the same fixture is opened by
// tool/sealjvm with "RSA/ECB/OAEPWithSHA-1AndMGF1Padding").
//
//   node tool/js/media_keys_test.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
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
async function refuses(fn) {
  try {
    await fn();
  } catch (e) {
    return e instanceof k.KeyError;
  }
  return false;
}
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

// -- the KEK -------------------------------------------------------------------
const kekB64 = k.b64(k.newDek());
const kek = await k.importKek(kekB64);
ok(await refuses(() => k.importKek(k.b64(new Uint8Array(16)))), 'a 16-byte KEK is refused');
ok(await refuses(() => k.importKek('not base64 !!')), 'a KEK that is not base64 is refused');
ok(await refuses(() => k.importKek(undefined)), 'a missing KEK is refused');

const dek = k.newDek();
const id = '7e3c1f0a-1111-4222-8333-944455556666';
const wrapped = await k.wrapDek(kek, dek, id, 1);
ok(wrapped.length === 80, 'the wrapped column is 80 characters (migration 060 checks it)');
ok(same(await k.unwrapDek(kek, wrapped, id, 1), dek), 'unwraps to the same DEK');
ok(await k.wrapDek(kek, dek, id, 1) !== wrapped, 'wrapping twice gives two different columns (random nonce)');
ok(await refuses(() => k.unwrapDek(kek, wrapped, '7e3c1f0a-1111-4222-8333-000000000000', 1)),
  'a wrapped key copied to another row does not open');
ok(await refuses(() => k.unwrapDek(kek, wrapped, id, 2)), 'claimed for another KEK version, it does not open');
ok(await refuses(async () => k.unwrapDek(await k.importKek(k.b64(k.newDek())), wrapped, id, 1)),
  'another KEK does not open it');
const bytes = k.unb64(wrapped);
bytes[30] ^= 1;
ok(await refuses(() => k.unwrapDek(kek, k.b64(bytes), id, 1)), 'an altered wrapped key does not open');
ok(await refuses(() => k.wrapDek(kek, new Uint8Array(31), id, 1)), 'a DEK that is not 32 bytes is refused');

// -- the phone's key -------------------------------------------------------------
const deviceKey = await k.importDeviceKey(fx.public_spki);
ok(!!deviceKey, 'the fixture phone key imports (RSA-2048, 65537)');
const priv = await subtle.importKey('pkcs8', k.unb64(fx.private_pkcs8), { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['decrypt']);
const forPhone = await k.wrapForDevice(deviceKey, dek);
ok(k.unb64(forPhone).length === 256, 'a DEK wrapped for a phone is 256 bytes');
ok(same(new Uint8Array(await subtle.decrypt({ name: 'RSA-OAEP' }, priv, k.unb64(forPhone))), dek),
  'the phone key opens a DEK wrapped for it');
ok(same(new Uint8Array(await subtle.decrypt({ name: 'RSA-OAEP' }, priv, k.unb64(fx.wrapped_for_device))), k.unb64(fx.dek_b64)),
  'the fixture wrap (opened by the JVM test too) still opens');

const small = await subtle.generateKey({ name: 'RSA-OAEP', modulusLength: 1024, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-1' }, true, ['encrypt', 'decrypt']);
ok(await refuses(async () => k.importDeviceKey(k.b64(new Uint8Array(await subtle.exportKey('spki', small.publicKey))))),
  'an RSA-1024 phone key is refused');
const ec = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
ok(await refuses(async () => k.importDeviceKey(k.b64(new Uint8Array(await subtle.exportKey('spki', ec.publicKey))))),
  'a key that is not RSA is refused');
ok(await refuses(() => k.importDeviceKey('')), 'an empty phone key is refused');

console.log(`media keys (js): all checks passed (${checks})`);
