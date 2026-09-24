// probe-media — answers "which of my videos will be slow to start, and why".
//
// WHY THIS IS NOT A GUESS IN A COMMENT.
//
// A video that streams from R2 through the Worker still has to be OPENED
// before a single frame exists, and the largest avoidable cost in that is
// where the MP4 keeps its index. An `moov` atom at the FRONT means the
// player reads the head of the file and starts. An `moov` at the END means
// it reads the head, finds no index, and seeks to the tail of a file that
// may be two gigabytes away — a whole extra round trip, on every play, for
// every viewer, forever.
//
// The console writes `moov` to the front now. Every object uploaded before
// that does not, and there is no way to tell from the database: the row
// looks identical either way. So this reads the first bytes of the object
// and says which it is.
//
// IT READS 64 KB, NOT THE FILE. The top-level box list is at the very start
// — a few dozen bytes of headers, each naming the size of the box it opens —
// so walking it needs only the first chunk. An edge function has neither the
// memory nor the CPU budget to touch a whole film, and reading one to answer
// a layout question would be absurd anyway.
//
// IT DOES NOT FIX ANYTHING, and that is deliberate rather than unfinished.
// Rewriting a multi-gigabyte object means reading and rewriting every byte,
// which is exactly what an edge function cannot do. The fix is to upload the
// file again from the console, which now writes it correctly — and knowing
// WHICH files need that is the whole job here.
//
// SEPARATE FROM `studio` because it is separate work. studio is a thousand
// lines and every deploy of it risks the operator's only control surface;
// this is a hundred, it only reads, and it can be redeployed without anyone
// holding their breath.

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID')!;
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID')!;
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY')!;
const MEDIA_BUCKET = Deno.env.get('R2_BUCKET') ?? 'innocent-media';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SB_ANON_KEY') ??
  Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const OPERATORS = (Deno.env.get('OPERATOR_IDS') ??
  '6c679480-3387-4442-ad3d-4423b8aceb71')
  .split(',').map((s) => s.trim()).filter(Boolean);
const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// The same two values `request-playback` mints tokens from. Read here so the
// console can time a download over the REAL path — phone to Worker to R2 —
// rather than over a presigned S3 URL that nothing in the app ever uses.
const STREAM_BASE = (Deno.env.get('STREAM_BASE') ?? '').replace(/\/+$/, '');
const STREAM_TOKEN_SECRET = Deno.env.get('STREAM_TOKEN_SECRET') ?? '';

const ALLOWED_ORIGINS = (Deno.env.get('STUDIO_ORIGINS') ??
  'https://yannmh007.github.io')
  .split(',').map((s) => s.trim()).filter(Boolean);

const enc = new TextEncoder();

// --- SigV4, the same as studio.ts and request-playback.ts -----------------
async function hmac(key: Uint8Array, msg: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey(
    'raw', key as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
}
function hex(buf: Uint8Array): string {
  return Array.from(buf).map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function sha256Hex(msg: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(msg))));
}
function rfc3986(c: string): string {
  return encodeURIComponent(c).replace(
    /[!'()*]/g, (x) => '%' + x.charCodeAt(0).toString(16).toUpperCase());
}
function encodeKey(key: string): string {
  return key.split('/').map(rfc3986).join('/');
}

async function presignGet(objectKey: string): Promise<string> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;
  const params: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${R2_ACCESS_KEY_ID}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': '120',
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalQuery = Object.keys(params).sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(params[k])}`).join('&');
  const canonicalPath = `/${MEDIA_BUCKET}/${encodeKey(objectKey)}`;
  const canonicalRequest = [
    'GET', canonicalPath, canonicalQuery, `host:${host}\n`, 'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');
  const stringToSign = [
    'AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonicalRequest),
  ].join('\n');
  let key: Uint8Array = enc.encode(`AWS4${R2_SECRET_ACCESS_KEY}`);
  for (const part of [dateStamp, 'auto', 's3', 'aws4_request']) {
    key = await hmac(key, part);
  }
  return `https://${host}${canonicalPath}?${canonicalQuery}` +
    `&X-Amz-Signature=${hex(await hmac(key, stringToSign))}`;
}

// --- the actual question --------------------------------------------------
//
// Walks the top-level box list. Each box is a 32-bit big-endian size, then
// four ASCII characters naming it. A size of 1 means the real size is a
// 64-bit value in the next eight bytes (how a `mdat` larger than 4 GiB is
// written); a size of 0 means "to the end of the file", which is only ever
// the last box.
function boxes(view: DataView, total: number) {
  const out: { type: string; size: number; start: number }[] = [];
  let at = 0;
  while (at + 8 <= view.byteLength) {
    let size = view.getUint32(at);
    const type = String.fromCharCode(
      view.getUint8(at + 4), view.getUint8(at + 5),
      view.getUint8(at + 6), view.getUint8(at + 7));
    let header = 8;
    if (size === 1) {
      if (at + 16 > view.byteLength) break;
      size = view.getUint32(at + 8) * 4294967296 + view.getUint32(at + 12);
      header = 16;
    } else if (size === 0) {
      size = total - at;
    }
    // Anything that does not advance is not a box list we understand, and
    // guessing past it would produce a confident wrong answer.
    if (size < header) break;
    out.push({ type, size, start: at });
    at += size;
    // The list is walked only as far as the bytes we fetched. `moov` at the
    // front is within the first few boxes; anything further is the body.
    if (out.length > 12) break;
  }
  return out;
}

// --- how long is it, and therefore how fat is it ------------------------
//
// SIZE ALONE ANSWERS NOTHING, and that is the lesson this function was
// extended for. A viewer reported that "small files are fine and short
// camera clips stutter" — and a short camera clip at 133 MB is not a small
// file at all, it is a very FAT one: tens of megabits every second, because
// a phone camera writes for archival quality with no thought for a network.
// A 155 MB feature is gentler than a 116 MB clip of someone's garden. The
// number that decides whether a connection can carry a file is bytes over
// SECONDS, and until now nothing here knew the seconds.
//
// `mvhd` is the movie header: one per file, inside `moov`, carrying a
// timescale and a duration. FOUND BY SCANNING FOR THE FOUR CHARACTERS rather
// than by descending the box tree, and that is deliberate. In a faststart
// file the tree walk would work; in a file with its index at the END the
// index is megabytes away and its offset is not knowable without reading it,
// which is the whole problem. A scan works identically on a chunk taken from
// the head or from the tail, and `mvhd` preceded by a plausible version byte
// is not a sequence that occurs by accident in compressed video.
function mvhdSeconds(bytes: Uint8Array): number | null {
  for (let i = 0; i + 8 <= bytes.length; i++) {
    if (bytes[i] !== 0x6d || bytes[i + 1] !== 0x76 ||
        bytes[i + 2] !== 0x68 || bytes[i + 3] !== 0x64) continue;
    // THE VIEW RUNS TO THE END OF THE CHUNK, and a short one is caught
    // below rather than guarded here. A fixed length is what broke the
    // first version: 28 bytes is enough for a version-0 header and four
    // bytes short of a version-1 one, so every 64-bit header — which is
    // what a long recording gets — read as "no duration found" and lost
    // its bitrate silently.
    const v = new DataView(
      bytes.buffer, bytes.byteOffset + i + 4, bytes.length - i - 4);
    const version = v.getUint8(0);
    try {
      if (version === 0) {
        // version, flags(3), created(4), modified(4), timescale(4), dur(4)
        const timescale = v.getUint32(12);
        const duration = v.getUint32(16);
        if (timescale > 0 && duration > 0) return duration / timescale;
      } else if (version === 1) {
        // version, flags(3), created(8), modified(8), timescale(4), dur(8)
        const timescale = v.getUint32(20);
        const hi = v.getUint32(24), lo = v.getUint32(28);
        const duration = hi * 4294967296 + lo;
        if (timescale > 0 && duration > 0) return duration / timescale;
      }
    } catch {
      // A match too close to the end of the chunk to read. Keep scanning:
      // this is a candidate rejected, not a file without a header.
    }
  }
  return null;
}

// --- a token for the console's own speed test ---------------------------
//
// THE SAME PATH THE PLAYER USES. A speed test against anything else measures
// something nobody experiences: a presigned S3 URL skips the Worker, and a
// generic speed test skips R2 as well. What a viewer's phone actually does
// is ask this Worker for a range of this object, so that is what gets timed.
function b64url(b: Uint8Array): string {
  return btoa(String.fromCharCode(...b))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function streamUrl(objectKey: string): Promise<string | null> {
  if (!STREAM_BASE || !STREAM_TOKEN_SECRET) return null;
  // SHA-256 of the secret, exactly as request-playback and the Worker do it,
  // so any text works as a secret and all three agree on the key.
  const key = await crypto.subtle.importKey(
    'raw',
    await crypto.subtle.digest('SHA-256', enc.encode(STREAM_TOKEN_SECRET)),
    { name: 'AES-GCM' }, false, ['encrypt'],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, key,
    enc.encode(JSON.stringify({
      k: objectKey,
      // Two minutes. A speed test that outlives the page that asked for it
      // is a URL somebody can keep.
      e: Math.floor(Date.now() / 1000) + 120,
    })),
  ));
  const token = new Uint8Array(iv.length + sealed.length);
  token.set(iv, 0);
  token.set(sealed, iv.length);
  return `${STREAM_BASE}/v/${b64url(token)}`;
}

const json = (body: unknown, status: number, req: Request) => {
  const origin = req.headers.get('Origin') ?? '';
  const cors = ALLOWED_ORIGINS.includes(origin)
    ? {
      'Access-Control-Allow-Origin': origin,
      'Access-Control-Allow-Headers': 'authorization, content-type',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Max-Age': '86400',
    }
    : {};
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...cors },
  });
};

async function operatorId(req: Request): Promise<string | null> {
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.toLowerCase().startsWith('bearer ')) return null;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: ANON_KEY },
  });
  if (!res.ok) return null;
  const user = await res.json();
  const id = typeof user?.id === 'string' ? user.id : '';
  return OPERATORS.includes(id) ? id : null;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    // 204 MEANS NO CONTENT, AND MEANS IT LITERALLY. The first version built
    // the preflight response through the same `json()` helper as everything
    // else, which gave it a body — and a 204 carrying a body is malformed,
    // so the browser discarded the whole response and the console reported
    // "Failed to fetch" with nothing in any log to say why. The preflight is
    // the one response here that must be built by hand.
    const origin = req.headers.get('Origin') ?? '';
    return new Response(null, {
      status: 204,
      headers: ALLOWED_ORIGINS.includes(origin)
        ? {
          'Access-Control-Allow-Origin': origin,
          'Access-Control-Allow-Headers': 'authorization, content-type',
          'Access-Control-Allow-Methods': 'POST, OPTIONS',
          'Access-Control-Max-Age': '86400',
        }
        : {},
    });
  }
  if (req.method === 'GET') {
    return json({ ok: true, service: 'probe-media' }, 200, req);
  }
  if (req.method !== 'POST') return json({ error: 'method' }, 405, req);
  if (!(await operatorId(req))) return json({ error: 'not_an_operator' }, 403, req);

  let body: { keys?: unknown; speed?: unknown };
  try { body = await req.json(); } catch { body = {}; }

  // ── the speed test ────────────────────────────────────────────────────
  //
  // Answers the one question the file list cannot: what does THIS phone, on
  // THIS connection, actually get through the Worker? The edge function
  // cannot measure that — it would be measuring a datacentre — so it hands
  // back a short-lived URL and the browser does the timing. That browser is
  // the operator's phone, on the same network as the complaint.
  if (body.speed) {
    const key = typeof body.speed === 'string' ? body.speed : '';
    if (!key) return json({ error: 'no_key' }, 400, req);
    const url = await streamUrl(key);
    if (!url) return json({ error: 'no_stream_base' }, 409, req);
    return json({ url }, 200, req);
  }

  // THE KEYS ARE LOOKED UP HERE WHEN THE CALLER DOES NOT NAME ANY, so the
  // console needs one button and no list-building of its own. PostgREST
  // over plain fetch rather than the supabase-js client: this reads one
  // column from one table, and an SDK import is megabytes of cold start
  // for a query that fits on a line.
  let keys = Array.isArray(body.keys)
    ? (body.keys as unknown[]).map(String).filter(Boolean).slice(0, 40) : [];

  if (!keys.length) {
    if (!SERVICE_KEY) return json({ error: 'no_service_key' }, 500, req);
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/title_assets` +
      `?select=object_key&bucket=eq.${encodeURIComponent(MEDIA_BUCKET)}` +
      `&order=added_at.desc&limit=40`,
      { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
    );
    if (!res.ok) {
      return json({ error: 'lookup_failed', status: res.status }, 500, req);
    }
    const rows = await res.json() as { object_key: string }[];
    keys = rows.map((r) => r.object_key).filter(Boolean);
  }
  if (!keys.length) return json({ error: 'no_keys' }, 400, req);

  const results = [];
  for (const key of keys) {
    try {
      const res = await fetch(await presignGet(key), {
        // 64 KB is generous for a box list and small enough that probing
        // forty objects costs less than a second of transfer.
        headers: { Range: 'bytes=0-65535' },
      });
      if (!res.ok && res.status !== 206) {
        results.push({ key, error: `http_${res.status}` });
        continue;
      }
      // `Content-Range: bytes 0-65535/1234567` carries the real size, which
      // is the only place the total length is available on a ranged read.
      const cr = res.headers.get('Content-Range') ?? '';
      const total = Number(cr.split('/')[1] ?? 0) ||
        Number(res.headers.get('Content-Length') ?? 0);
      const headBytes = new Uint8Array(await res.arrayBuffer());
      const head = new DataView(
        headBytes.buffer, headBytes.byteOffset, headBytes.byteLength);
      const list = boxes(head, total);
      const names = list.map((b) => b.type);
      const moov = names.indexOf('moov');
      const mdat = names.indexOf('mdat');

      // A faststart file carries its header in the chunk already read. A
      // file with its index at the end does not, and its duration is the
      // number that decides whether it is watchable at all — so it is worth
      // one more ranged read of the last megabyte rather than reporting a
      // blank where the bitrate should be.
      let seconds = mvhdSeconds(headBytes);
      if (seconds === null && total > 0) {
        try {
          const from = Math.max(0, total - 1024 * 1024);
          const tail = await fetch(await presignGet(key), {
            headers: { Range: `bytes=${from}-${total - 1}` },
          });
          if (tail.ok || tail.status === 206) {
            seconds = mvhdSeconds(new Uint8Array(await tail.arrayBuffer()));
          }
        } catch {
          // The head answer stands on its own; a failed tail read costs a
          // bitrate, not a verdict.
        }
      }

      results.push({
        key,
        bytes: total,
        seconds: seconds === null ? null : Math.round(seconds),
        // Kilobits per second, which is the unit a connection is sold in and
        // therefore the one that can be compared to it without arithmetic in
        // somebody's head. Null rather than 0 when the duration is unknown:
        // a zero bitrate reads as "this file is free to stream".
        kbps: seconds && seconds > 0
          ? Math.round((total * 8) / seconds / 1000)
          : null,
        boxes: names,
        // The verdict, in the three states that mean different things.
        //   faststart — the index is at the front; nothing to do.
        //   tail      — the index is past the media; every play pays an
        //               extra round trip. Re-upload from the console.
        //   unknown   — not a box layout this understands. Left alone
        //               rather than reported as either, because a wrong
        //               "needs re-uploading" costs a gigabyte of someone's
        //               mobile data.
        verdict: moov >= 0 && (mdat < 0 || moov < mdat) ? 'faststart'
          : (moov < 0 && mdat >= 0) ? 'tail'
          : (moov >= 0 && mdat >= 0 && moov > mdat) ? 'tail'
          : 'unknown',
      });
    } catch (e) {
      results.push({ key, error: String(e).slice(0, 160) });
    }
  }
  return json({ results }, 200, req);
});
