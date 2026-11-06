// Sealed twins — a sealed copy of an object already in R2, made on a runner
// and recorded here (docs/MEDIA_ENCRYPTION.md §9 B, E). The ingest function
// issues each twin's DEK and checks the twin before its media_keys row is
// written; this module is the part of that which needs no network, so its
// rules are tested in Node (tool/js/media_twin_test.mjs).
//
// WHAT MAY BE SEALED, FOR NOW: the open films the catalogue was seeded with
// (slug `open-film-…`, Creative Commons). Nothing else — whatever is on the
// owner's do-not-touch list is in no title with such a slug, and this job
// can neither read nor write it.

import { unwrapDek, b64, unb64, KeyError } from './media_keys.js';
import { Opener, aadFor, sealedSize, sealedStart, segmentCount, HEADER } from './media_seal.js';

/** The titles whose objects this job may seal (the canary, §9 B). */
export function twinAllowed(slug) {
  return typeof slug === 'string' && /^open-film-[a-z0-9-]{1,48}$/.test(slug);
}

/** A twin's key: `s/` and 32 random hex digits — says nothing of what it holds. */
export function newSealedKey() {
  const r = new Uint8Array(16);
  globalThis.crypto.getRandomValues(r);
  return 's/' + Array.from(r, (x) => x.toString(16).padStart(2, '0')).join('');
}

export function isSealedKey(key) {
  return typeof key === 'string' && /^s\/[0-9a-f]{32}$/.test(key);
}

/**
 * Whether a twin the runner says it made is what this function issued and
 * what the row will say. Checked: the wrapped DEK opens under MEDIA_KEK for
 * this dek_id (so it was issued here, for this row); both objects are the
 * sizes the row will claim; the twin starts with the header the row will
 * carry; and its first and last segments open with that DEK — a twin sealed
 * under another key, cut short or padded is refused before any app is told
 * it exists.
 *
 * @param {CryptoKey} kek
 * @param {{dek_id: string, wrapped: string, plain_key: string, sealed_key: string,
 *          plain_size: number, header: string}} item
 * @param {{plainSize: () => Promise<number|null>, sealedSize: () => Promise<number|null>,
 *          readSealed: (start: number, end: number) => Promise<Uint8Array|null>}} io
 *   sizes of the two objects (HEAD), and bytes [start, end) of the twin
 * @param {{kind?: 'video'|'image', born?: boolean}} [opts] an IMAGE's row
 *   (media_image_keys, migration 063) carries the DEK itself, as the app
 *   opens it from its catalogue row; it is the DEK the wrap opened to, never
 *   one the runner names. BORN sealed (§7, `on`): there is no plain object —
 *   its size is not looked at, and the row's plain_key is null.
 * @returns {Promise<Record<string, any>>} the media_keys (or media_image_keys) row
 */
export async function checkTwin(kek, item, io, { kind = 'video', born = false } = {}) {
  const plain = Number(item.plain_size);
  if (!Number.isSafeInteger(plain) || plain <= 0) throw new KeyError('plain_size');
  if (!isSealedKey(item.sealed_key)) throw new KeyError('sealed_key');
  if (born) {
    if (item.plain_key != null) throw new KeyError('plain_key');
  } else if (typeof item.plain_key !== 'string' || !item.plain_key || item.plain_key.startsWith('s/')) {
    throw new KeyError('plain_key');
  }
  const dek = await unwrapDek(kek, String(item.wrapped ?? ''), String(item.dek_id ?? ''), 1);
  try {
    const want = sealedSize(plain);
    if (!born && (await io.plainSize()) !== plain) throw new KeyError('the plain object is not that size');
    if ((await io.sealedSize()) !== want) throw new KeyError('the twin is not the sealed size');
    let header;
    try {
      header = unb64(String(item.header ?? ''));
    } catch (_) {
      throw new KeyError('header');
    }
    if (header.length !== HEADER || header[0] !== HEADER) throw new KeyError('header');
    const count = segmentCount(plain);
    const firstEnd = Math.min(want, count > 1 ? sealedStart(1) : want);
    const head = await io.readSealed(0, firstEnd);
    if (!head || head.length !== firstEnd) throw new KeyError('the twin could not be read');
    if (b64(head.subarray(0, HEADER)) !== b64(header)) throw new KeyError('the twin does not start with that header');
    const op = await Opener.create(dek, aadFor(item.dek_id), header, plain);
    try {
      await op.openSegment(0, head.subarray(HEADER));
      if (count > 1) {
        const last = await io.readSealed(sealedStart(count - 1), want);
        if (!last) throw new KeyError('the twin could not be read');
        await op.openSegment(count - 1, last);
      }
    } catch (e) {
      if (e instanceof KeyError) throw e;
      throw new KeyError('the twin does not open with its key');
    }
    if (kind === 'image') {
      return {
        dek_id: String(item.dek_id),
        sealed_key: item.sealed_key,
        plain_key: born ? null : item.plain_key,
        dek: b64(dek),
        plain_size: plain,
        sealed_size: want,
        header: b64(header),
      };
    }
    return {
      dek_id: String(item.dek_id),
      sealed_key: item.sealed_key,
      plain_key: born ? null : item.plain_key,
      kek_version: 1,
      wrapped: String(item.wrapped),
      plain_size: plain,
      sealed_size: want,
      kind: 'video',
      header: b64(header),
    };
  } finally {
    dek.fill(0);
  }
}
