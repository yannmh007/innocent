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
// viewer. It does NOT give an edge copy shared between viewers. Caching
// full-length video needs either a paid plan's larger cacheable size or
// segmented delivery (HLS), and pretending otherwise in a comment would be
// how this gets "fixed" back into the shape that did not work.
//
// Small objects — thumbnails, short clips — still carry `Cache-Control`, so
// they cache wherever something is willing to hold them.

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

/// How big an edge-cache block is, in bytes — or 0 when edge block caching
/// is OFF, which is the default and is today's behaviour exactly.
///
/// WHY THIS IS OPT-IN AND OFF BY DEFAULT. Reassembling a film out of cached
/// blocks is the one change in this Worker that could hand every viewer a
/// corrupt video at once, so it ships dark: with `EDGE_BLOCK_BYTES` unset the
/// Worker reads straight from the R2 binding exactly as it always has. An
/// operator turns it on by setting the variable (8 to 16 MB is the useful
/// range), watches the start-up times the console already shows, and turns it
/// off again by clearing it — no code change and no deploy either way.
function blockSize(env) {
  const n = Number(env.EDGE_BLOCK_BYTES);
  if (!Number.isFinite(n) || n < 1024 * 1024) return 0; // under 1 MB is noise
  // A single cached Response is held whole in memory while it is fetched and
  // must stay well under Workers' 512 MB cacheable ceiling. 64 MB is far
  // inside both; a block much larger than a read-ahead stretch buys nothing.
  return Math.min(Math.floor(n), 64 * 1024 * 1024);
}

/// Answer a range by assembling fixed-size, edge-cached blocks — the piece
/// that turns this Worker from a proxy into a CDN.
///
/// WHY BLOCKS, WHEN WHOLE-FILM CACHING COULD NOT WORK. Two facts killed the
/// first attempt (see the file header): a cacheable response is capped at
/// 512 MB, and a film's URL carries a fresh token on every play, so caching
/// on the public path missed every time. A block fixes both. It is small —
/// well under the cap — and its cache address is derived from the OBJECT KEY
/// and the block number, so it is the SAME address for every viewer and every
/// token. The second viewer of a film in a region is served that region's
/// cached blocks instead of a fresh pull from the bucket's distant home, and
/// the client's own `Range` is rebuilt from the blocks rather than being
/// dropped. That is edge fan-out, which is the thing a CDN does and the one
/// thing this Worker could not do before.
///
/// IMMUTABLE BY CONSTRUCTION, WHICH IS WHAT MAKES IT SAFE WITHOUT A VALIDATOR.
/// Every upload gets a fresh key — a timestamp and a random suffix — so one
/// key never names two different sets of bytes and a cached block can never go
/// stale. No ETag revalidation, no cache-busting, nothing to get wrong.
///
/// Returns a Response, or null to mean "fall back to the direct R2 path", so
/// anything unexpected here degrades to exactly the behaviour shipped today
/// rather than failing a play.
async function serveFromBlocks(request, env, ctx, key, block, cors) {
  try {
    const cache = caches.default;
    // The object's length, from a tiny cached meta entry or one cheap HEAD.
    // Immutable keys mean the meta never needs revalidating.
    const metaReq = new Request(
      `https://edge.block/meta/${encodeURIComponent(key)}`);
    let size = -1;
    let etag = '';
    const metaHit = await cache.match(metaReq);
    if (metaHit) {
      const m = await metaHit.json();
      size = m.size;
      etag = m.etag || '';
    } else {
      const head = await env.MEDIA.head(key);
      if (!head) return null; // no such object: let the direct path log it
      size = head.size;
      etag = head.httpEtag || '';
      ctx.waitUntil(cache.put(metaReq, new Response(
        JSON.stringify({ size, etag }),
        {
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'public, max-age=86400',
          },
        })));
    }
    if (!(size > 0)) return null;

    // Parse the client's Range the way a player means it: `bytes=a-b`,
    // `bytes=a-` (open ended) or `bytes=-n` (the last n bytes). Anything else
    // is handed back to the direct path, which R2 parses itself.
    let start = 0;
    let endIncl = size - 1;
    let partial = false;
    const rh = request.headers.get('Range');
    if (rh) {
      const m = /^bytes=(\d*)-(\d*)$/.exec(rh.trim());
      if (!m || (m[1] === '' && m[2] === '')) return null;
      if (m[1] === '') {
        const n = Number(m[2]);
        if (!(n > 0)) return null;
        start = Math.max(0, size - n);
        endIncl = size - 1;
      } else {
        start = Number(m[1]);
        endIncl = m[2] === '' ? size - 1 : Number(m[2]);
      }
      partial = true;
      if (!Number.isFinite(start) || !Number.isFinite(endIncl)) return null;
      if (start < 0 || start >= size) {
        return new Response(null, {
          status: 416,
          headers: { 'Content-Range': `bytes */${size}`,
            'Cache-Control': 'no-store', ...cors },
        });
      }
      if (endIncl >= size) endIncl = size - 1;
      if (endIncl < start) endIncl = start;
    }

    const headers = new Headers(cors);
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Content-Type', 'video/mp4');
    headers.set('Cache-Control', `public, max-age=${EDGE_TTL_SECONDS}, immutable`);
    if (etag) headers.set('ETag', etag);
    headers.set('Content-Length', String(endIncl - start + 1));
    if (partial) {
      headers.set('Content-Range', `bytes ${start}-${endIncl}/${size}`);
    }

    const b0 = Math.floor(start / block);
    const b1 = Math.floor(endIncl / block);
    // One line per request, as the direct path logs: how the range was asked
    // for and how many blocks it touched. No key and no token — the object is
    // identified by its size, which tells two files apart and nobody anything
    // about the bucket.
    console.log(JSON.stringify({
      ev: 'serve_edge', asked: rh || 'whole', size, blocks: b1 - b0 + 1,
    }));

    if (request.method === 'HEAD') {
      return new Response(null, { status: partial ? 206 : 200, headers });
    }

    // Pull ONE BLOCK AT A TIME, in order, so even a request for the whole
    // film never holds more than a single block in memory — the back-pressure
    // that the first whole-object attempt did not have.
    let i = b0;
    const stream = new ReadableStream({
      async pull(ctrl) {
        if (i > b1) {
          ctrl.close();
          return;
        }
        const idx = i++;
        const blockStart = idx * block;
        const blockLen = Math.min(block, size - blockStart);
        const bk = new Request(
          `https://edge.block/o/${encodeURIComponent(key)}/${block}/${idx}`);
        let bytes;
        const hit = await cache.match(bk);
        if (hit) {
          bytes = new Uint8Array(await hit.arrayBuffer());
        } else {
          const obj = await env.MEDIA.get(key, {
            range: { offset: blockStart, length: blockLen },
          });
          if (!obj) {
            ctrl.error(new Error('block gone'));
            return;
          }
          bytes = new Uint8Array(await obj.arrayBuffer());
          // The WHOLE block is cached, never the slice: the next viewer's
          // range is not this one's, and the block is the unit they share.
          ctx.waitUntil(cache.put(bk, new Response(bytes, {
            headers: {
              'Content-Length': String(bytes.length),
              'Cache-Control': `public, max-age=${EDGE_TTL_SECONDS}, immutable`,
            },
          })));
        }
        // The part of this block the client actually asked for.
        const from = Math.max(start, blockStart) - blockStart;
        const to = Math.min(endIncl, blockStart + bytes.length - 1) - blockStart + 1;
        if (to > from) ctrl.enqueue(bytes.subarray(from, to));
      },
    });
    return new Response(stream, { status: partial ? 206 : 200, headers });
  } catch (e) {
    console.log(JSON.stringify({
      refusal: 'edge_block_error', detail: String(e).slice(0, 120),
    }));
    return null; // fall back to the direct path
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
    const block = blockSize(env);
    if (block > 0) {
      const edged = await serveFromBlocks(
        request, env, ctx, claim.k, block, corsFor(request));
      if (edged) return edged;
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
