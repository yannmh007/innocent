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

export default {
  async fetch(request, env) {
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
                   'Cache-Control': 'no-store' },
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

    const headers = new Headers();
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
