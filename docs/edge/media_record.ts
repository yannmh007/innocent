// Recording what a runner sealed — the one way every pipeline does it
// (docs/MEDIA_ENCRYPTION.md §7.2). Used by transcode.ts (rungs, stills) and
// ingest.ts (forwarded files, restores).
//
//   recordSealed(io, items, bucket, kind)
//       each item checked by media_issue.js `record` (the wrap is this
//       function's for its dek_id, both sizes, the header, the first and
//       last segments open), then written by `media_key_put` (069): a twin
//       already there for that plain object is replaced and its copy
//       binned. An item already recorded is skipped (a `done` repeats the
//       rungs before it). A sealed object refused goes to the bin.
//
// The function's own helpers are passed in, so nothing here holds a secret
// of its own.

import { record } from './media_issue.js';
import { isSealedKey } from './media_twin.js';

export type RecordIO = {
  rest: (path: string, init?: RequestInit) => Promise<Response>;
  presign: (method: 'GET' | 'HEAD', key: string, seconds: number, bucket: string) => Promise<string>;
  kek: () => Promise<CryptoKey | null>;
};

export type Recorded = { ok: Set<string>; refused: string[]; replaced: number };

export async function sizeAt(io: RecordIO, key: string, bucket: string): Promise<number | null> {
  const h = await fetch(await io.presign('HEAD', key, 300, bucket), { method: 'HEAD' });
  if (!h.ok) return null;
  const n = Number(h.headers.get('content-length'));
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

/// A sealed object nobody will record goes to the bin for a week, like
/// anything else nobody names. The purge checks `r2_refs()` again first, so
/// a key some row does name is never deleted.
export async function binRefused(io: RecordIO, bucket: string, key: string, why = 'sealed copy refused when recorded') {
  if (!isSealedKey(key)) return;
  await io.rest('r2_trash', {
    method: 'POST',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({
      bucket, key, reason: why.slice(0, 200),
      purge_after: new Date(Date.now() + 7 * 86400_000).toISOString(),
    }),
  }).catch(() => undefined);
}

/**
 * @param items each: dek_id, wrapped, sealed_key, plain_size, header, and
 *   plain_key (the twin's plain object) or null (born sealed)
 * @param kind 'image' → media_image_keys; 'video' → media_keys
 * @param mediaKind media_keys.kind for a film row: 'video' | 'photo' | 'other'
 */
export async function recordSealed(
  io: RecordIO, items: Array<Record<string, unknown>>, bucket: string,
  kind: 'video' | 'image', mediaKind: 'video' | 'photo' | 'other' = 'video',
): Promise<Recorded> {
  const ok = new Set<string>();
  const refused: string[] = [];
  let replaced = 0;
  if (!items.length) return { ok, refused, replaced };
  const k = await io.kek();
  if (!k) return { ok, refused: items.map(() => 'no MEDIA_KEK'), replaced };
  const table = kind === 'image' ? 'media_image_keys' : 'media_keys';
  const ids = items.map((x) => String(x.dek_id ?? '')).filter((x) => /^[0-9a-f-]{36}$/i.test(x));
  if (ids.length) {
    const have = await io.rest(`${table}?select=dek_id&dek_id=in.(${ids.join(',')})`);
    if (have.ok) for (const r of await have.json() as Array<{ dek_id: string }>) ok.add(r.dek_id);
  }
  for (const item of items) {
    const id = String(item.dek_id ?? '');
    if (ok.has(id)) continue;
    const born = item.plain_key == null;
    const sealedKey = String(item.sealed_key ?? '');
    try {
      const row = await record(k, item as never, {
        plainSize: () => sizeAt(io, String(item.plain_key), bucket),
        sealedSize: () => sizeAt(io, sealedKey, bucket),
        readSealed: async (start: number, end: number) => {
          const g = await fetch(await io.presign('GET', sealedKey, 300, bucket),
            { headers: { Range: `bytes=${start}-${end - 1}` } });
          return g.status === 206 ? new Uint8Array(await g.arrayBuffer()) : null;
        },
      }, { kind, born, mediaKind });
      const put = await io.rest('rpc/media_key_put', {
        method: 'POST',
        body: JSON.stringify({ p_kind: kind, p_row: { ...row, bucket } }),
      });
      if (put.ok) {
        ok.add(id);
        replaced += ((await put.json() as { replaced?: string[] }).replaced ?? []).length;
      } else {
        refused.push(`${sealedKey.slice(0, 10)}: record ${put.status}`);
        await binRefused(io, bucket, sealedKey);
      }
    } catch (e) {
      refused.push(`${sealedKey.slice(0, 10)}: ${String((e as Error).message ?? e).slice(0, 80)}`);
      await binRefused(io, bucket, sealedKey);
    }
  }
  return { ok, refused, replaced };
}
