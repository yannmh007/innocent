// Which object a playback grant signs, and the seal it carries
// (docs/MEDIA_ENCRYPTION.md §5, §9). request-playback calls this; it is a
// separate module so its rules are tested in Node (tool/js/media_grant_test.mjs).
//
// THE ROLLOUT RULE. While a plaintext object and its sealed twin both exist,
// an app that says it can open seals (`seal: 1` in the request) gets the
// sealed twin and its key, and any other app gets the plaintext exactly as
// before. An object that exists only sealed (born sealed, or its plaintext
// retired after the forced update) is never signed for an app that cannot
// open it: that app is told to update instead of being handed bytes it would
// play as noise.

import { unwrapDek, wrapForDevice, b64 } from './media_keys.js';

/**
 * @param {string[]} keys the object keys the grant would sign, as the
 *   catalogue names them (title_assets / asset_renditions)
 * @param {Array<Record<string, any>>} rows media_keys rows for those keys
 *   (matched by sealed_key or plain_key), any bucket
 * @param {{canOpen: boolean, bucket: string}} opts
 * @returns {Map<string, {sign: string|null, row: Record<string, any>|null}>}
 *   per key: what to sign (null: nothing this app can play) and the row
 *   whose seal goes with it (null: plaintext)
 */
export function planSeal(keys, rows, { canOpen, bucket }) {
  const bySealed = new Map();
  const byPlain = new Map();
  for (const r of rows ?? []) {
    if (!r || r.bucket !== bucket) continue;
    if (r.sealed_key) bySealed.set(String(r.sealed_key), r);
    if (r.plain_key) byPlain.set(String(r.plain_key), r);
  }
  const plan = new Map();
  for (const key of keys) {
    if (!key) continue;
    const born = bySealed.get(key); // the catalogue already names the sealed object
    const twin = byPlain.get(key); // a sealed copy of a plaintext object
    if (canOpen) {
      const row = born ?? twin ?? null;
      plan.set(key, row ? { sign: String(row.sealed_key), row } : { sign: key, row: null });
    } else {
      // The catalogue's key IS sealed: nothing here this app can open.
      plan.set(key, born ? { sign: null, row: null } : { sign: key, row: null });
    }
  }
  return plan;
}

/**
 * The `seal` block for one signed sealed object. The DEK leaves the function
 * wrapped for the phone when it sent its key; in the clear (over TLS) only
 * when the mode allows it. Returns null when neither is possible: the caller
 * then does not sign that object at all.
 *
 * @param {CryptoKey} kek MEDIA_KEK for the row's version
 * @param {Record<string, any>} row
 * @param {{deviceKey: CryptoKey|null, mode: 'prefer'|'require'|'off'}} opts
 */
export async function sealBlock(kek, row, { deviceKey, mode }) {
  const dek = await unwrapDek(kek, String(row.wrapped), String(row.dek_id), Number(row.kek_version ?? 1));
  try {
    const base = {
      v: 1,
      dek_id: String(row.dek_id),
      plain_size: Number(row.plain_size),
      sealed_size: Number(row.sealed_size),
      // The object's first 40 bytes (salt and nonce prefix, not secret):
      // with them the phone opens any segment first, without a round trip
      // for the head — a resume or a seek straight into the film.
      ...(typeof row.header === 'string' && row.header.length === 56 ? { header: row.header } : {}),
    };
    if (deviceKey && mode !== 'off') {
      return { ...base, wrap: 'rsa', dek: await wrapForDevice(deviceKey, dek) };
    }
    if (mode === 'require') return null;
    return { ...base, wrap: 'tls', dek: b64(dek) };
  } finally {
    dek.fill(0);
  }
}

/**
 * SEAL_MODE, read strictly (docs/MEDIA_ENCRYPTION.md §9):
 *   off  nothing sealed is looked at — the kill switch
 *   ask  (the default) only a request that says it opens seals (`seal: 1`)
 *        looks; every other app is answered exactly as before, with no
 *        extra query. Right while every sealed object has its plain twin.
 *   on   every request looks, so an app that cannot open a sealed-only
 *        object is told to update (426) — needed once twins are retired.
 */
export function sealMode(value) {
  const v = String(value ?? '').trim().toLowerCase();
  return v === 'off' || v === 'on' ? v : 'ask';
}

/** Whether a request looks at media_keys at all, under [mode]. */
export function looksForSeals(mode, body) {
  if (mode === 'off') return false;
  if (mode === 'on') return true;
  return body?.seal === 1;
}

/** SEAL_DEVICE_WRAP, read strictly: anything unknown is the safe default. */
export function wrapMode(value) {
  const v = String(value ?? '').trim().toLowerCase();
  return v === 'require' || v === 'off' ? v : 'prefer';
}
