// Media seal keys — the edge functions' half (docs/MEDIA_ENCRYPTION.md §4-5).
//
// A DEK is never stored or sent in the clear except to the phone that plays
// it, over TLS, while SEAL_DEVICE_WRAP allows that:
//
//   at rest   wrapped = base64(nonce 12 || AES-256-GCM(MEDIA_KEK, DEK) || tag)
//             AAD "inv-kek|v<version>|<dek_id>", so a wrapped key moved to
//             another row, or claimed for another KEK version, does not open
//   to phone  RSA-OAEP (SHA-1, MGF1-SHA-1) under the install's Keystore key.
//             Keystore below API 35 supports only MGF1-SHA-1, and WebCrypto
//             uses one hash for both; OAEP with SHA-1 remains approved for
//             encryption (the collision weakness concerns signatures).
//
// Plain ES module on WebCrypto: Deno (edge), Node (tests).

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();

export class KeyError extends Error {}

export function b64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

export function unb64(text) {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function newDek() {
  const d = new Uint8Array(32);
  globalThis.crypto.getRandomValues(d);
  return d;
}

/** MEDIA_KEK_V<n> from its base64 secret. Refuses anything but 32 bytes. */
export async function importKek(secretB64) {
  let raw;
  try {
    raw = unb64(String(secretB64 ?? '').trim());
  } catch (_) {
    throw new KeyError('MEDIA_KEK is not base64');
  }
  if (raw.length !== 32) throw new KeyError(`MEDIA_KEK is ${raw.length} bytes, not 32`);
  const key = await subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
  raw.fill(0);
  return key;
}

function kekAad(dekId, version) {
  return enc.encode(`inv-kek|v${version}|${dekId}`);
}

/** The `wrapped` column for a DEK (80 base64 characters). */
export async function wrapDek(kek, dek, dekId, version = 1) {
  if (!(dek instanceof Uint8Array) || dek.length !== 32) throw new KeyError('a DEK is 32 bytes');
  const nonce = new Uint8Array(12);
  globalThis.crypto.getRandomValues(nonce);
  const ct = new Uint8Array(await subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, additionalData: kekAad(dekId, version), tagLength: 128 }, kek, dek));
  const out = new Uint8Array(12 + ct.length);
  out.set(nonce, 0);
  out.set(ct, 12);
  return b64(out);
}

/** The DEK in a `wrapped` column; refuses another row's or another version's. */
export async function unwrapDek(kek, wrapped, dekId, version = 1) {
  let all;
  try {
    all = unb64(wrapped);
  } catch (_) {
    throw new KeyError('wrapped key is not base64');
  }
  if (all.length !== 60) throw new KeyError('wrapped key is not 60 bytes');
  try {
    const dek = await subtle.decrypt(
      { name: 'AES-GCM', iv: all.subarray(0, 12), additionalData: kekAad(dekId, version), tagLength: 128 },
      kek, all.subarray(12));
    return new Uint8Array(dek);
  } catch (_) {
    throw new KeyError('wrapped key does not open (another KEK, row or version)');
  }
}

/**
 * An install's public key as the phone registered it (base64 SPKI DER of an
 * RSA-2048 key, exponent 65537). Anything else is refused: a phone whose key
 * is not what this function wraps for would get a grant it cannot open.
 */
export async function importDeviceKey(spkiB64) {
  let der;
  try {
    der = unb64(String(spkiB64 ?? '').trim());
  } catch (_) {
    throw new KeyError('device key is not base64');
  }
  let key;
  try {
    key = await subtle.importKey('spki', der, { name: 'RSA-OAEP', hash: 'SHA-1' }, true, ['encrypt']);
  } catch (_) {
    throw new KeyError('device key is not an RSA public key');
  }
  const a = key.algorithm;
  const e = Array.from(a.publicExponent ?? []).reduce((n, x) => n * 256 + x, 0);
  if (a.modulusLength !== 2048 || e !== 65537) {
    throw new KeyError(`device key must be RSA-2048/65537, not ${a.modulusLength}/${e}`);
  }
  return key;
}

/** The DEK wrapped for one phone (base64, 256 bytes before encoding). */
export async function wrapForDevice(deviceKey, dek) {
  const ct = await subtle.encrypt({ name: 'RSA-OAEP' }, deviceKey, dek);
  return b64(new Uint8Array(ct));
}
