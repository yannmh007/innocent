// The one place a pipeline gets a DEK and gets a sealed object recorded
// (docs/MEDIA_ENCRYPTION.md §7.2). Transcode, Telegram ingest, the console's
// uploads and the twin job all go through here, so there is one rule for
// what a new object becomes and one check before a key is written:
//
//   makeFor(mode, slug)   what the switch (admin_settings.seal_new) makes of
//                         a new object for a title: 'plain', 'twin' or 'sealed'
//   issue(kek)            a new dek_id, its DEK for the runner that seals, the
//                         DEK wrapped under MEDIA_KEK (handed back untouched),
//                         and the object's `s/<32 hex>` key
//   record(kek, item, io) checkTwin, then the key row — nothing is recorded
//                         that was not issued here, and nothing that does not
//                         open
//
// Pure: no network, no database. Tested in Node (tool/js/media_issue_test.mjs).

import { newDek, wrapDek, b64 } from './media_keys.js';
import { checkTwin, newSealedKey, twinAllowed } from './media_twin.js';

/** The switch's positions (migration 067). Anything else reads as `off`. */
export const SEAL_NEW = Object.freeze(['off', 'canary', 'on']);

export function sealNewMode(value) {
  return SEAL_NEW.includes(value) ? value : 'off';
}

/**
 * What a pipeline makes of a new object for a title whose slug is [slug]:
 *   'plain'  as before;
 *   'twin'   the plain object AND a sealed twin (canary: open films only);
 *   'sealed' sealed only, no plain object ever in R2 (`on`).
 */
export function makeFor(mode, slug) {
  const m = sealNewMode(mode);
  if (m === 'on') return 'sealed';
  if (m === 'canary' && twinAllowed(slug)) return 'twin';
  return 'plain';
}

/**
 * A new key for one object. The DEK is for the runner that seals and is
 * held only while it does; the wrap comes back to [record] untouched, and is
 * what proves the key was issued here, for this dek_id.
 */
export async function issue(kek) {
  const dekId = crypto.randomUUID();
  const dek = newDek();
  try {
    return {
      dek_id: dekId,
      dek: b64(dek),
      wrapped: await wrapDek(kek, dek, dekId, 1),
      sealed_key: newSealedKey(),
    };
  } finally {
    dek.fill(0);
  }
}

/**
 * The key row for a sealed object a runner says it made, after checkTwin:
 * the wrap is this function's for this dek_id, the sizes are what the row
 * will say, the header is the object's and its first and last segments
 * open. A film's row goes to media_keys (the wrap, never the DEK); an
 * image's to media_image_keys (the DEK the wrap opened to). [born]: no
 * plain object, `plain_key` null.
 *
 * @param {CryptoKey} kek
 * @param {Record<string, any>} item dek_id, wrapped, sealed_key, plain_size, header, plain_key (twin)
 * @param {{plainSize: () => Promise<number|null>, sealedSize: () => Promise<number|null>,
 *          readSealed: (start: number, end: number) => Promise<Uint8Array|null>}} io
 * @param {{kind?: 'video'|'image', born?: boolean, mediaKind?: 'video'|'photo'|'other'}} [opts]
 */
export async function record(kek, item, io, { kind = 'video', born = false, mediaKind = 'video' } = {}) {
  // A born-sealed item that names a plain object is a pipeline's mistake,
  // and refused by checkTwin rather than quietly corrected here.
  const row = await checkTwin(kek, item, io, { kind, born });
  if (kind === 'image') return row;
  return { ...row, kind: mediaKind };
}
