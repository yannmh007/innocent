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

/**
 * The 32 bytes of a MEDIA_KEK secret, written either way the owner may have
 * copied it: base64 (44 characters) or hex (64 characters, the paper copy's
 * form — docs/MEDIA_ENCRYPTION.md §4). Anything else is refused.
 */
function kekBytes(secret) {
  const text = String(secret ?? '').trim();
  if (!text) throw new KeyError('MEDIA_KEK is not set');
  let raw;
  if (/^[0-9a-fA-F]{64}$/.test(text)) {
    raw = new Uint8Array(32);
    for (let i = 0; i < 32; i++) raw[i] = parseInt(text.slice(2 * i, 2 * i + 2), 16);
    return raw;
  }
  try {
    raw = unb64(text);
  } catch (_) {
    throw new KeyError('MEDIA_KEK is neither base64 nor hex');
  }
  if (raw.length !== 32) {
    raw.fill(0);
    throw new KeyError(`MEDIA_KEK is ${raw.length} bytes, not 32`);
  }
  return raw;
}

/** MEDIA_KEK_V<n> from its secret. Refuses anything but 32 bytes. */
export async function importKek(secret) {
  const raw = kekBytes(secret);
  const key = await subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
  raw.fill(0);
  return key;
}

/**
 * What a MEDIA_KEK secret is, without what it holds: missing, unusable (and
 * why), or usable with its key check value — the first 8 hex digits of
 * HMAC-SHA256(KEK, "inv-kek-check|v1"). The check value shows that every
 * function holds the same key and that it has not changed; it says nothing
 * about the key (32 bits of a keyed hash of a constant).
 */
export async function kekStatus(secret) {
  const text = String(secret ?? '').trim();
  const form = !text ? 'none' : /^[0-9a-fA-F]{64}$/.test(text) ? 'hex'
    : /^[A-Za-z0-9+/]+={0,2}$/.test(text) ? 'base64' : 'other';
  let raw;
  try {
    raw = kekBytes(text);
  } catch (e) {
    return { state: text ? 'unusable' : 'missing', form, chars: text.length, why: e.message };
  }
  try {
    const h = await subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const mac = new Uint8Array(await subtle.sign('HMAC', h, enc.encode('inv-kek-check|v1')));
    const kcv = Array.from(mac.subarray(0, 4), (b) => b.toString(16).padStart(2, '0')).join('');
    return { state: 'ok', form, bytes: 32, kcv };
  } finally {
    raw.fill(0);
  }
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
