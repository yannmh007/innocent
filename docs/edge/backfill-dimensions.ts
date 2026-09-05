// ===========================================================================
// backfill-dimensions — Supabase Edge Function
// Innocent Movies. Written 2 Sep 2026.
//
// WHY THIS EXISTS
//
// `title_assets.width` and `.height` are null for everything, because files
// are uploaded through the R2 dashboard and it supplies no dimensions.
//
// That is not cosmetic. A Pinterest-style masonry - the right layout for a
// Reels feed of clips whose shapes genuinely vary - computes each tile's
// height as `columnWidth / aspectRatio`. With no ratio there is no height, and
// the masonry degenerates into the uniform grid it was meant to replace. The
// album mosaic works without dimensions by cropping; masonry cannot.
//
// So: read the dimensions out of the files themselves.
//
// SCOPE: PHOTOS ONLY, DELIBERATELY.
//
// Image headers are a few bytes at a known offset. MP4 dimensions live in a
// nested `moov > trak > tkhd` atom that can sit anywhere in a multi-hundred-
// megabyte file, and the file is in the PRIVATE bucket, so reading it means
// signing a URL first. Far more work, for a case that does not need solving:
// a clip is drawn in the grid using its THUMBNAIL, which is a photo, so the
// thumbnail's ratio is the right ratio for the tile anyway.
//
// HOW IT READS ONLY THE HEADER
//
// A `Range: bytes=0-65535` request. R2's public URL honours it, so a 3 MB
// photo costs 64 KB to measure. Class B operations are 10 million a month
// free; a hundred photos is a hundred.
//
// DEPLOY
//   Edge Functions -> Deploy a new function -> Via Editor -> `backfill-dimensions`
//   -> paste -> Deploy -> Settings -> Verify JWT OFF.
//   No new secrets. Run it after each upload session; it only touches rows
//   that are still null, so running it twice costs nothing.
// ===========================================================================

const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const URL_BASE = Deno.env.get('SUPABASE_URL') ?? '';

/// Public bucket base. Kept in step with `public_asset_base()` in migration
/// 006 - if the custom domain ever replaces r2.dev, both change together.
const PUBLIC_BASE = 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/';

const HEADER_BYTES = 65535;

type Size = { w: number; h: number } | null;

// --- format parsers ---------------------------------------------------------

/// PNG: an 8-byte signature, then the IHDR chunk whose first eight bytes of
/// data are width and height, big-endian. Fixed offsets 16 and 20.
function pngSize(b: Uint8Array): Size {
  if (b.length < 24) return null;
  if (b[0] !== 0x89 || b[1] !== 0x50 || b[2] !== 0x4E || b[3] !== 0x47) return null;
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return { w: v.getUint32(16), h: v.getUint32(20) };
}

/// JPEG: a chain of markers. Walk it until a Start Of Frame (SOF0..SOF15,
/// excluding DHT/JPG/DAC at C4/C8/CC), whose payload holds height then width.
///
/// Walked rather than searched for the byte pattern: 0xFFC0 occurs inside
/// compressed scan data often enough that a naive search finds garbage.
function jpegSize(b: Uint8Array): Size {
  if (b.length < 4 || b[0] !== 0xFF || b[1] !== 0xD8) return null;
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xFF) { i++; continue; }         // resync on padding
    const marker = b[i + 1];
    if (marker === 0xFF) { i++; continue; }        // fill bytes
    if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD9)) { i += 2; continue; }
    const len = v.getUint16(i + 2);
    if (len < 2) return null;
    const isSOF = marker >= 0xC0 && marker <= 0xCF &&
      marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC;
    if (isSOF) {
      // i+2 length, i+4 precision, i+5 height, i+7 width
      return { h: v.getUint16(i + 5), w: v.getUint16(i + 7) };
    }
    i += 2 + len;
  }
  return null;
}

/// WebP: RIFF container. Three sub-formats, all with the size in a different
/// place - VP8X (extended), VP8L (lossless, bit-packed), VP8 (lossy).
function webpSize(b: Uint8Array): Size {
  if (b.length < 30) return null;
  const tag = String.fromCharCode(b[0], b[1], b[2], b[3]);
  const web = String.fromCharCode(b[8], b[9], b[10], b[11]);
  if (tag !== 'RIFF' || web !== 'WEBP') return null;
  const fmt = String.fromCharCode(b[12], b[13], b[14], b[15]);

  if (fmt === 'VP8X') {
    // 24-bit little-endian, stored as (value - 1).
    const w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
    const h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
    return { w, h };
  }
  if (fmt === 'VP8L') {
    // 14 bits each, packed across four bytes after the 0x2F signature.
    if (b[20] !== 0x2F) return null;
    const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    return { w: 1 + (bits & 0x3FFF), h: 1 + ((bits >> 14) & 0x3FFF) };
  }
  if (fmt === 'VP8 ') {
    // Key-frame header: 3-byte start code 0x9D012A, then 14-bit w and h.
    if (b[23] !== 0x9D || b[24] !== 0x01 || b[25] !== 0x2A) return null;
    const w = (b[26] | (b[27] << 8)) & 0x3FFF;
    const h = (b[28] | (b[29] << 8)) & 0x3FFF;
    return { w, h };
  }
  return null;
}

function sizeOf(bytes: Uint8Array): Size {
  return pngSize(bytes) ?? jpegSize(bytes) ?? webpSize(bytes);
}

// --- the job ----------------------------------------------------------------

const db = (path: string, init: RequestInit = {}) =>
  fetch(`${URL_BASE}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });

Deno.serve(async () => {
  if (!SERVICE_KEY) {
    return new Response(JSON.stringify({ error: 'no service key' }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    });
  }

  // Only rows still missing a size. That is what makes this safe to run after
  // every upload session rather than something to remember to run once.
  const listed = await db(
    'title_assets?select=id,object_key,bucket&kind=eq.photo&width=is.null&limit=200',
  );
  if (!listed.ok) {
    return new Response(JSON.stringify({ error: await listed.text() }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    });
  }
  const rows = await listed.json() as
    Array<{ id: string; object_key: string; bucket: string }>;

  let updated = 0;
  const failures: Array<{ key: string; why: string }> = [];

  for (const row of rows) {
    try {
      // Private-bucket photos have no public URL; they are not the case this
      // solves and are skipped rather than guessed at.
      if (row.bucket !== 'innocent-public') {
        failures.push({ key: row.object_key, why: 'not in the public bucket' });
        continue;
      }
      const res = await fetch(PUBLIC_BASE + row.object_key, {
        headers: { Range: `bytes=0-${HEADER_BYTES}` },
      });
      // 206 is the expected answer; 200 means Range was ignored, which is
      // still usable - just a bigger download.
      if (res.status !== 206 && res.status !== 200) {
        failures.push({ key: row.object_key, why: `HTTP ${res.status}` });
        continue;
      }
      const bytes = new Uint8Array(await res.arrayBuffer());
      const size = sizeOf(bytes);
      if (!size || size.w <= 0 || size.h <= 0) {
        failures.push({ key: row.object_key, why: 'unrecognised image header' });
        continue;
      }

      const patched = await db(`title_assets?id=eq.${row.id}`, {
        method: 'PATCH',
        headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({ width: size.w, height: size.h }),
      });
      if (patched.ok) updated++;
      else failures.push({ key: row.object_key, why: await patched.text() });
    } catch (e) {
      failures.push({ key: row.object_key, why: String(e).slice(0, 120) });
    }
  }

  return new Response(
    JSON.stringify({
      examined: rows.length,
      updated,
      failures,
      note: rows.length === 200
        ? 'hit the 200-row page limit - run again for the rest'
        : 'all pending rows examined',
    }, null, 2),
    { headers: { 'Content-Type': 'application/json' } },
  );
});
