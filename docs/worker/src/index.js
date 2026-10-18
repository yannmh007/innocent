// innocent-stream — the only public door to the private video bucket.
//
// WHAT IT REPLACES.
//
// The app used to play a presigned S3 URL:
//
//   https://<account-id>.r2.cloudflarestorage.com/innocent-media/<folder>/
//       video/<key>.mp4?X-Amz-Credential=<ACCESS-KEY-ID>%2F...&X-Amz-Signature=...
//
// which names the account, names the private bucket, spells out the folder
// scheme, and carries the access key id in its credential scope. None of it
// is a password. All of it is the map an attacker would otherwise have to
// guess at — and it was on screen in the player's own information dialog
// until v1.64.22.
//
// Now the app plays `https://<worker>/v/<token>`, where the token is AES-GCM
// ciphertext holding the object key and an expiry. It says nothing to
// anyone holding the URL, and because GCM is authenticated it cannot be
// edited or its expiry extended: one changed bit fails to decrypt rather
// than decrypting to something else.
//
// ─── WHAT THE FIRST VERSION GOT WRONG, because it is worth writing down ───
//
// It was built around Workers Caching, with two entrypoints — a gateway that
// decrypted the token and a cached inner entrypoint keyed on the object key
// — so that two viewers of the same film would share one edge copy. The
// design was sound and the reasoning was right. Two facts about the platform
// made it the wrong shape for THIS content, and both were discoverable
// before shipping:
//
//  1. IT STRIPPED THE CLIENT'S `Range`. The gateway built the inner request
//     with `headers: new Headers()`, dropping everything — including the
//     `Range` header every video player sends. So the client was answered
//     with a full `200` and no seeking, for a file of any length. That was
//     my error, not the platform's.
//
//  2. WORKERS CACHING CANNOT HOLD A FILM. Cacheable responses are capped at
//     512 MB, and — per Cloudflare's own note — every Workers Caching
//     response is held to the Free-plan limit at launch regardless of the
//     account's plan. A feature film does not fit. So the entire benefit
//     the two-entrypoint shape existed to buy was never available for the
//     content it was built for, while its cost — a cold cache trying to
//     pull a whole object before anyone gets a byte — was paid in full.
//
// The result on a phone was a video that buffered and never started.
//
// ─── WHAT IT DOES NOW ─────────────────────────────────────────────────────
//
// Reads the object straight from the R2 binding and answers `Range` properly,
// with a real `206` and a `Content-Range`. No cache layer between them,
// because there is no cache that can hold these files.
//
// That keeps the part that always worked — the address is hidden, the URL
// expires, the bucket is reached through a binding rather than a credential
// — and it keeps the bytes on Cloudflare's own network from R2 to the
// viewer. That direct path is still every request's fallback.
//
// ─── AND, SINCE 1.64.67, AN EDGE COPY SHARED BETWEEN VIEWERS ─────────────
//
// Not by caching the film — that cannot work, as above — but by caching it
// in fixed-size BLOCKS behind a second entrypoint (`Block`), at a path built
// from the object key. Workers Caching keeps each whole block and the gateway
// cuts the player's range out of it; the second viewer in a region is served
// from beside them. The gateway
// steps aside to the direct path whenever an answer is not exactly what it
// asked for, so this can cost a few milliseconds and never a wrong byte.
// See [serveFromBlocks], and `EDGE_BLOCK_BYTES` in wrangler.toml to turn it
// off.
//
// Small objects — thumbnails, short clips — still carry `Cache-Control`, so
// they cache wherever something is willing to hold them.

import { WorkerEntrypoint } from 'cloudflare:workers';

/// How long anything that CAN be cached may be held.
///
/// The objects are immutable: every upload gets a fresh key with a timestamp
/// and a random suffix, so one key never holds different bytes. `immutable`
/// is a statement of fact here rather than an optimisation.
const EDGE_TTL_SECONDS = 86400;

/// The one page allowed to read a response from here with JavaScript.
///
/// WHY A VIDEO WORKER NEEDS CORS AT ALL. It does not, for playback: a
/// `<video>` element and libmpv both fetch without the same-origin rules
/// applying. It needs it for the console's speed test, which is the only way
/// to answer "what does this phone actually get through the Worker" from the
/// phone that is complaining — and a browser will not let a page read bytes
/// from another origin unless that origin says so.
///
/// AN ALLOWLIST, NOT `*`. A token is still required either way, so `*` would
/// not hand anyone the bucket — but it would let any page on the internet
/// spend this Worker's request budget on a URL it had somehow obtained, and
/// there is exactly one page that has any business reading from here.
const STUDIO_ORIGINS = ['https://yannmh007.github.io'];

function corsFor(request) {
  const origin = request.headers.get('Origin') || '';
  if (!STUDIO_ORIGINS.includes(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    // Without this the page can time the download but cannot read the
    // length it downloaded, which is half a measurement.
    'Access-Control-Expose-Headers': 'Content-Range, Content-Length',
    Vary: 'Origin',
  };
}

/// Rejections say nothing.
///
/// "Expired", "bad signature" and "no such object" are three different
/// facts, and handing them to a caller turns this into an oracle they can
/// use to learn how tokens are built. The log keeps the difference; the
/// response does not.
function refuse() {
  return new Response('Not found', {
    status: 404,
    headers: { 'Cache-Control': 'no-store' },
  });
}

function b64urlToBytes(s) {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Imported once per isolate rather than per request — the import is the
/// expensive half of a decrypt — but KEYED ON THE SECRET, which the first
/// version was not.
///
/// It memoised a single promise and ignored the secret on every call after
/// the first. In production that looks harmless, because `env.TOKEN_SECRET`
/// does not change while a Worker is running. It is exactly wrong on the one
/// day it matters: rotate the secret because you think it leaked, and every
/// warm isolate goes on accepting tokens minted with the old one until it
/// happens to be recycled. A revocation that silently does not revoke is
/// worse than none, because you stop looking.
const keyCache = new Map();
function signingKey(secret) {
  let promise = keyCache.get(secret);
  if (!promise) {
    promise = deriveKey(secret);
    // One live secret and one being rotated out is the whole realistic
    // range. A bound stops a bug elsewhere turning this into a leak.
    if (keyCache.size > 4) keyCache.clear();
    keyCache.set(secret, promise);
  }
  return promise;
}

/// SHA-256 OF THE SECRET, NOT THE SECRET'S BYTES.
///
/// AES-GCM wants exactly 32 bytes, which meant the secret had to be
/// base64url of exactly that length — fine for someone at a terminal with
/// `openssl rand`, a trap for an operator on a phone whose natural source of
/// a long random string is a password manager, which produces text with
/// symbols in it. Hashing turns any string into 32 bytes on both sides, so
/// there is no format to get wrong and therefore no way to get it wrong
/// quietly. `request-playback` derives its key the same way.
async function deriveKey(secret) {
  const digest = await crypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(secret));
  return crypto.subtle.importKey(
    'raw', digest, { name: 'AES-GCM' }, false, ['decrypt']);
}

/// Reads a token back. Returns null for anything at all suspect.
async function openToken(token, secret) {
  try {
    const raw = b64urlToBytes(token);
    if (raw.length < 13) return null;          // 12-byte IV + something
    const iv = raw.slice(0, 12);
    const body = raw.slice(12);
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv },
      await signingKey(secret),
      body,
    );
    const claim = JSON.parse(new TextDecoder().decode(plain));
    if (typeof claim?.k !== 'string' || !claim.k) return null;
    if (typeof claim?.e !== 'number') return null;
    // Expiry is checked on every request, by this Worker. Nothing else
    // enforces it once the URL has left the server.
    if (Date.now() / 1000 > claim.e) return null;
    return claim;
  } catch {
    return null;
  }
}

/// How big an edge block is, in bytes — or 0 when edge fan-out is OFF, in
/// which case every request takes the direct R2 path exactly as before.
///
/// Set in wrangler.toml `[vars]`, NOT in the dashboard: `wrangler deploy`
/// replaces a Worker's plaintext variables with the ones in its config, so a
/// value typed into the dashboard is gone after the next deploy without a
/// word. Clearing the line and redeploying turns this off.
function blockSize(env) {
  const n = Number(env.EDGE_BLOCK_BYTES);
  if (!Number.isFinite(n) || n < 1024 * 1024) return 0; // under 1 MB is noise
  // A block is one cached response, far under the 512 MB cacheable ceiling.
  // Much bigger than a read-ahead stretch buys nothing and makes a cold
  // block slower to fill.
  return Math.min(Math.floor(n), 64 * 1024 * 1024);
}

/// How many blocks one request may span before it is sent down the direct
/// path instead. The phone's proxy asks for parts of 2 MB at most, so one or
/// two; this bound is for anything else — a player reading a whole film in
/// one response — which the direct path streams better.
const MAX_EDGE_BLOCKS = 8;

/// How long a block may be held. Keys are immutable (see [serveFromBlocks]),
/// so this is a bound on space, not on staleness.
const BLOCK_TTL_SECONDS = 30 * 86400;

/// `bytes=a-b` as `[a, b]`; null for anything else — open-ended, suffix,
/// several ranges, or none. Only the closed form takes the block path; every
/// other shape is the direct path's, which R2 parses itself.
function closedRange(header) {
  if (!header) return null;
  const m = /^bytes=(\d+)-(\d+)$/.exec(header.trim());
  if (!m) return null;
  const a = Number(m[1]);
  const b = Number(m[2]);
  if (!Number.isSafeInteger(a) || !Number.isSafeInteger(b) || b < a) return null;
  return [a, b];
}

/// The blocks a range touches, each with the part of it wanted, as
/// block-relative inclusive offsets. The last block of a film is shorter than
/// the rest; the cache clamps a range that runs past it, and the caller reads
/// the length that actually came back from `Content-Range`.
function blockPlan(start, end, block) {
  const out = [];
  for (let i = Math.floor(start / block); i <= Math.floor(end / block); i++) {
    const at = i * block;
    out.push({ idx: i, from: Math.max(start, at) - at, to: Math.min(end, at + block - 1) - at });
  }
  return out;
}

/// The path a block is fetched and cached under: the block size, its number
/// and the object key. Stable across every viewer and every token, which is
/// the whole point; never seen by a client, because only this Worker can call
/// the entrypoint that answers it.
function blockPath(key, block, idx) {
  return `/b/${block}/${idx}/${encodeURIComponent(key)}`;
}

/// `bytes a-b/n` as `[a, b, n]`, or null.
function contentRange(v) {
  const m = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(v || '');
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

/// One block, whole, as a cacheable `200` — what the cached entrypoint
/// answers. It never reads `Range`: Workers Caching keeps the whole block
/// (a `206` from here would never be stored at all), and the gateway cuts the
/// player's range out of what the cache hands back.
async function blockResponse(env, request) {
  const nope = (status, extra = {}) => new Response(null, {
    status, headers: { 'Cache-Control': 'no-store', ...extra } });
  const m = /^\/b\/(\d+)\/(\d+)\/([^/]+)$/.exec(new URL(request.url).pathname);
  if (!m) return nope(404);
  const block = Number(m[1]);
  const idx = Number(m[2]);
  let key;
  try {
    key = decodeURIComponent(m[3]);
  } catch {
    return nope(404);
  }
  if (block !== blockSize({ EDGE_BLOCK_BYTES: block }) || !Number.isSafeInteger(idx)) {
    return nope(404);
  }
  const offset = idx * block;
  let obj;
  try {
    // A length past the end comes back short — R2 trims it — so the last
    // block needs no size looked up first.
    obj = await env.MEDIA.get(key, { range: { offset, length: block } });
  } catch {
    // An offset past the end is refused outright. Say how long the film is,
    // so the gateway can answer the player with a proper 416.
    const head = await env.MEDIA.head(key).catch(() => null);
    return head ? nope(416, { 'X-Total-Size': String(head.size) }) : nope(404);
  }
  if (!obj) return nope(404);
  if (offset >= obj.size) return nope(416, { 'X-Total-Size': String(obj.size) });
  return new Response(obj.body, {
    status: 200,
    headers: {
      'Content-Type': 'video/mp4',
      'Cache-Control': `public, max-age=${BLOCK_TTL_SECONDS}, immutable`,
      // Rides along in the cache with the block, so a hit says how long the
      // film is without a separate look at the bucket.
      'X-Total-Size': String(obj.size),
    },
  });
}

/// Answer a range out of edge-cached blocks — the piece that turns this
/// Worker from a proxy into a CDN.
///
/// WHY THIS SHAPE. Workers Caching cannot hold a whole film (512 MB), and a
/// film's URL carries a fresh token on every play, so caching the public
/// request misses every time. Here the gateway (this function, never cached)
/// opens the token and asks the cached `Block` entrypoint for fixed-size
/// blocks at a path built from the object key — the same path for every
/// viewer — and cuts the player's range out of what comes back. Workers
/// Caching does the rest, and does it better than code here could: a hit is
/// served from the data centre beside the viewer, a miss is
/// tried against an upper tier before the bucket, and six lanes asking for
/// the same cold block at once run the bucket read ONCE (request collapsing).
///
/// IMMUTABLE BY CONSTRUCTION. Every upload gets a fresh key — a timestamp and
/// a random suffix — so one key never names two sets of bytes and a cached
/// block cannot go stale.
///
/// NO LOOP OVER BYTES. A slice the cache cut is piped through as it is; a
/// whole block is cut chunk by chunk ([sliceStream]) — a Free-plan Worker has
/// 10 ms of CPU a request, and a loop over two megabytes would spend it.
///
/// NOTHING IS SAID TO THE PLAYER UNTIL EVERY BLOCK HAS PROVED ITSELF. All the
/// blocks are asked for at once and each answer's `Content-Range` must be
/// exactly the slice wanted. Anything else — caching not switched on (then
/// `Block` answers a whole `200`), an odd answer, an error — returns the
/// REASON, a few words and numbers, and
/// the request goes down the direct path as if none of this existed. A bad
/// block can cost a few milliseconds; it can never reach the screen.
async function serveFromBlocks(request, env, ctx, key, block, cors) {
  let answers = [];
  // What a block answered, for the reason a request stepped aside: its
  // status, its Content-Range and what the cache said. Numbers only.
  const said = (r) => r
    ? `${r.status} cr=${r.headers.get('Content-Range') || '-'} cs=${r.headers.get('Cf-Cache-Status') || '-'}`
    : '-';
  const giveUp = (why) => {
    for (const r of answers) {
      try { r.body?.cancel().catch(() => {}); } catch {}
    }
    return why;
  };
  try {
    if (request.method !== 'GET') return 'method';
    // The live check compares the two paths byte for byte; this is how it
    // asks for the old one. Both still need the token.
    if (request.headers.get('X-Edge-Bypass') === '1') return 'bypass';
    for (const h of ['If-Range', 'If-None-Match', 'If-Match',
                     'If-Modified-Since', 'If-Unmodified-Since']) {
      if (request.headers.has(h)) return 'conditional';
    }
    const asked = closedRange(request.headers.get('Range'));
    if (!asked) return 'not-closed';
    const [start] = asked;
    let [, end] = asked;
    const plan = blockPlan(start, end, block);
    if (plan.length > MAX_EDGE_BLOCKS) return 'too-many-blocks';
    const exp = ctx && ctx.exports && ctx.exports.Block;
    if (!exp) return 'no-exports';

    answers = await Promise.all(plan.map((p) => exp.fetch(new Request(
      'https://block' + blockPath(key, block, p.idx),
      { headers: { Range: `bytes=${p.from}-${p.to}` } }))));

    let total = Number(answers[0].headers.get('X-Total-Size'));
    if (!(Number.isSafeInteger(total) && total > 0) && answers[0].status === 416) {
      // A start past the end that still falls inside the last block: the
      // cache's own 416 can only name the BLOCK's length. One look at the
      // bucket says the film's, so the player still gets a proper 416 —
      // rather than whatever the direct path's R2 call makes of it (a local
      // simulator answered the whole film).
      const head = await env.MEDIA.head(key).catch(() => null);
      total = head ? head.size : NaN;
    }
    if (!Number.isSafeInteger(total) || total <= 0) return giveUp(`no-total ${said(answers[0])}`);
    if (start >= total) {
      giveUp('');
      return new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${total}`, 'Cache-Control': 'no-store', ...cors },
      });
    }
    end = Math.min(end, total - 1);

    // Blocks wholly past the end (a range that ran over) were answered 416;
    // they are dropped. Every one kept must be exactly its slice — or the
    // whole block, from the cache, which is cut here (see below).
    const kept = [];
    const statuses = [];
    let sum = 0;
    for (let k = 0; k < plan.length; k++) {
      const p = plan[k];
      const r = answers[k];
      if (p.idx * block > end) {
        try { r.body?.cancel().catch(() => {}); } catch {}
        continue;
      }
      const blockLen = Math.min(block, total - p.idx * block);
      const wantTo = Math.min(p.to, blockLen - 1);
      const take = wantTo - p.from + 1;
      const cs = r.headers.get('Cf-Cache-Status') || '';
      if (Number(r.headers.get('X-Total-Size')) !== total) {
        return giveUp(`total ${said(r)} want ${total}`);
      }
      if (r.status === 206) {
        // The cache cut the range itself, as it does for a request from
        // outside: it must be exactly the slice asked for.
        const cr = contentRange(r.headers.get('Content-Range'));
        if (!cr || cr[0] !== p.from || cr[1] !== wantTo || cr[2] !== blockLen) {
          return giveUp(`slice ${said(r)} want ${p.from}-${wantTo}/${blockLen}`);
        }
        kept.push({ body: r.body, skip: 0, take, cut: false });
      } else if (r.status === 200 && cs) {
        // WHAT THE CACHE ACTUALLY DOES for a call through `ctx.exports`,
        // seen on the first live check (18 Oct 2026): it keeps the whole
        // block and answers the whole block, `200` with `Cf-Cache-Status`,
        // whatever range was asked for — the slicing in Cloudflare's docs is
        // for a request from outside. So the slice is cut here, chunk by
        // chunk ([sliceStream]). A `200` WITHOUT a cache status is `Block`
        // answering with no cache in front of it, and then there is nothing
        // to gain over the direct path: it steps aside below.
        const cl = r.headers.get('Content-Length');
        if (cl !== null && Number(cl) !== blockLen) {
          return giveUp(`block-length ${said(r)} want ${blockLen}`);
        }
        kept.push({ body: r.body, skip: p.from, take, cut: true });
      } else {
        return giveUp(`not-206 ${said(r)}`);
      }
      sum += take;
      statuses.push(cs || '-');
    }
    const length = end - start + 1;
    if (kept.length === 0 || sum !== length) return giveUp('sum');

    const headers = new Headers(cors);
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Content-Type', 'video/mp4');
    headers.set('Cache-Control', `public, max-age=${EDGE_TTL_SECONDS}, immutable`);
    headers.set('Content-Range', `bytes ${start}-${end}/${total}`);
    // What the cache did for this request — read by the live check and the
    // console. Statuses only: nothing here names the film or the bucket.
    headers.set('X-Edge', `blocks=${kept.length}; ${statuses.join(',')}`);
    console.log(JSON.stringify({
      ev: 'serve_edge', asked: `bytes=${asked[0]}-${asked[1]}`, size: total,
      blocks: kept.length, cache: statuses.join(','),
    }));

    // A FixedLengthStream is what gives the player a real `Content-Length`
    // (the runtime ignores one set by hand on a stream), and it errors rather
    // than let a short or long body through. Outside workerd — the tests —
    // a plain identity stream stands in.
    const { readable, writable } = typeof FixedLengthStream === 'function'
      ? new FixedLengthStream(length)
      : new TransformStream();
    (async () => {
      for (const k of kept) {
        const part = k.cut ? k.body.pipeThrough(sliceStream(k.skip, k.take)) : k.body;
        await part.pipeTo(writable, { preventClose: true });
      }
      await writable.close();
    })().catch(async (e) => {
      for (const r of kept) {
        try { await r.body?.cancel(); } catch {}
      }
      try { await writable.abort(e); } catch {}
    });
    return new Response(readable, { status: 206, headers });
  } catch (e) {
    console.log(JSON.stringify({
      refusal: 'edge_block_error', detail: String(e).slice(0, 120),
    }));
    return giveUp(`error ${String(e).slice(0, 60)}`); // the direct path takes it
  }
}

/// Bytes [skip, skip + take) of a stream, as a stream.
///
/// CHUNK BY CHUNK, NEVER BYTE BY BYTE: a chunk wholly before the slice is
/// dropped, one that straddles it is cut with `subarray` (a view, not a copy),
/// and the rest pass untouched — a few comparisons per chunk, which is what a
/// Free-plan Worker's 10 ms of CPU can afford. The moment the last wanted byte
/// has passed the stream terminates, and the source is let go rather than read
/// to the end of its block.
function sliceStream(skip, take) {
  let seen = 0;
  const end = skip + take;
  return new TransformStream({
    transform(chunk, ctrl) {
      const from = seen;
      seen += chunk.byteLength;
      if (seen <= skip) return;
      const a = Math.max(0, skip - from);
      const b = Math.min(chunk.byteLength, end - from);
      if (b > a) ctrl.enqueue(a === 0 && b === chunk.byteLength ? chunk : chunk.subarray(a, b));
      if (seen >= end) ctrl.terminate();
    },
  });
}

/// The cached half.
///
/// Workers Caching sits in front of this entrypoint (wrangler.toml
/// `[exports.Block.cache]`), so on a hit it never runs. Reachable only from
/// this Worker, through `ctx.exports`: a request from outside always arrives
/// at the default export, which demands a token.
export class Block extends WorkerEntrypoint {
  async fetch(request) {
    return blockResponse(this.env, request);
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // ANSWERED BEFORE THE SECRET IS CHECKED, and that order is the point.
    //
    // The first version put this after the guard below, so a Worker with no
    // TOKEN_SECRET set — which is every Worker between its first deploy and
    // the moment the operator adds the secret — answered `/health` with 404.
    // A health check that reports "dead" during the one procedure it exists
    // to support is worse than not having one: the operator reads it as a
    // failed deploy and starts undoing work that was correct.
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({
        ok: true,
        service: 'innocent-stream',
        secret: !!env.TOKEN_SECRET,
        bucket: !!env.MEDIA,
      }), {
        headers: { 'Content-Type': 'application/json',
                   'Cache-Control': 'no-store', ...corsFor(request) },
      });
    }

    // A plain `Range: bytes=0-N` is a CORS-safelisted header, so the speed
    // test should never preflight. Answered anyway, because "should never"
    // is a prediction about browsers and this costs four lines.
    //
    // 204 CARRIES NO BODY. A 204 with one is malformed and browsers discard
    // the whole response — which cost an afternoon in `probe-media` with
    // nothing in any log to say why.
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          ...corsFor(request),
          'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
          'Access-Control-Allow-Headers': 'range',
          'Access-Control-Max-Age': '86400',
        },
      });
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405 });
    }
    if (!env.TOKEN_SECRET || !env.MEDIA) {
      // Refusing everything beats serving everything. A missing secret or a
      // missing binding is a deployment mistake, and the safe reading of a
      // deployment mistake is "closed".
      console.log(JSON.stringify({
        refusal: 'not_configured',
        secret: !!env.TOKEN_SECRET,
        bucket: !!env.MEDIA,
      }));
      return refuse();
    }

    const match = url.pathname.match(/^\/v\/([A-Za-z0-9_-]+)$/);
    if (!match) return refuse();

    const claim = await openToken(match[1], env.TOKEN_SECRET);
    if (!claim) {
      // Logged, never returned. Which of the three reasons it was is the
      // operator's business and nobody else's — but an operator with no way
      // to tell a wrong secret from an expired token has nothing to work
      // with when something stops playing.
      console.log(JSON.stringify({ refusal: 'bad_token' }));
      return refuse();
    }

    // EDGE FAN-OUT, WHEN THE OPERATOR HAS TURNED IT ON. Off by default, in
    // which case this is skipped and the direct path below runs exactly as it
    // always has. Null means the block path declined (an unhandled range
    // shape, a missing object, any error at all), so playback falls through
    // to the direct path rather than failing. See [serveFromBlocks].
    // Why the edge path stepped aside, if it did — said in `X-Edge` on the
    // direct answer below, so the live check can tell "not switched on" from
    // "the cache answered something odd" without anyone reading a log.
    let edgeOff = '';
    const block = blockSize(env);
    if (block > 0) {
      const edged = await serveFromBlocks(
        request, env, ctx, claim.k, block, corsFor(request));
      if (edged instanceof Response) return edged;
      edgeOff = edged || '';
    }

    // THE CLIENT'S `Range` IS THE WHOLE JOB, and dropping it is what broke
    // the first version. A video player opens a file by asking for a range,
    // seeks by asking for another, and treats a `200` where it asked for a
    // `206` as a server that cannot be seeked. R2's binding parses the
    // header itself when handed the request's headers, which is both less
    // code and less to get wrong than parsing `bytes=` by hand.
    //
    // `onlyIf` carries the conditional headers through in the same way, so
    // `If-Range` and `If-None-Match` behave as a player expects rather than
    // being silently ignored.
    let object;
    try {
      object = await env.MEDIA.get(claim.k, {
        range: request.headers,
        onlyIf: request.headers,
      });
    } catch (e) {
      // An unsatisfiable range throws rather than returning null. 416 is the
      // honest answer and the one a player knows how to recover from.
      console.log(JSON.stringify({
        refusal: 'range_error', detail: String(e),
      }));
      return new Response(null, {
        status: 416,
        headers: { 'Cache-Control': 'no-store' },
      });
    }

    if (!object) {
      console.log(JSON.stringify({ refusal: 'no_object' }));
      return refuse();
    }

    const headers = new Headers(corsFor(request));
    object.writeHttpMetadata(headers);
    headers.set('ETag', object.httpEtag);
    headers.set('Accept-Ranges', 'bytes');
    if (edgeOff) headers.set('X-Edge', `off; ${edgeOff}`);
    if (!headers.has('Content-Type')) headers.set('Content-Type', 'video/mp4');
    // Written on every response even though nothing between here and the
    // viewer will hold a film: it costs nothing, and the small objects that
    // also pass through here — thumbnails, short clips — are cacheable
    // wherever something is willing to hold them.
    headers.set('Cache-Control',
      `public, max-age=${EDGE_TTL_SECONDS}, immutable`);
    // R2 sets none of these, but a future `writeHttpMetadata` change could,
    // and an object key must not travel back out in a header either.
    headers.delete('Content-Disposition');

    // A conditional request that matched has no body. 304 must not carry
    // one, and must not claim a length it is not sending.
    if (!('body' in object) || object.body === null) {
      return new Response(null, { status: 304, headers });
    }

    // `object.range` is present exactly when a range was asked for and
    // honoured. Turning it into `Content-Range` is what makes the response a
    // real 206 rather than a 200 that happens to be short — a player reading
    // 200 concludes the source cannot be seeked and gives up on scrubbing.
    // ONE LINE PER REQUEST, because the question that matters cannot be
    // answered any other way: how many times does the player ask, and for
    // what? A video that plays two seconds, stalls, plays two seconds is
    // either one slow stream or fifty fast ones, and those have opposite
    // fixes. The log says which. It carries no key and no token — the
    // object is identified by its size, which is enough to tell two files
    // apart in a trace and tells a reader nothing about the bucket.
    console.log(JSON.stringify({
      ev: 'serve',
      asked: request.headers.get('Range') || 'whole',
      size: object.size,
      got: object.range ?? null,
      edge: edgeOff || undefined,
      ua: (request.headers.get('User-Agent') || '').slice(0, 40),
    }));

    const range = object.range;
    if (range && request.headers.has('Range')) {
      const offset = 'offset' in range && range.offset !== undefined
        ? range.offset
        : object.size - range.suffix;
      const length = 'length' in range && range.length !== undefined
        ? range.length
        : object.size - offset;
      const end = offset + length - 1;
      headers.set('Content-Range', `bytes ${offset}-${end}/${object.size}`);
      headers.set('Content-Length', String(length));
      return new Response(request.method === 'HEAD' ? null : object.body,
        { status: 206, headers });
    }

    headers.set('Content-Length', String(object.size));
    return new Response(request.method === 'HEAD' ? null : object.body,
      { status: 200, headers });
  },
};
