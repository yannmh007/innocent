// innocent-stream — the only public door to the private video bucket.
//
// WHAT IT REPLACES AND WHY.
//
// Until now the app played a presigned S3 URL:
//
//   https://<account-id>.r2.cloudflarestorage.com/innocent-media/<folder>/
//       video/<key>.mp4?X-Amz-Credential=<ACCESS-KEY-ID>%2F...&X-Amz-Signature=...
//
// Two things are wrong with that, and they are the two complaints this
// project has had about video.
//
// IT IS SLOW, and not for the reason it looks. `<account>.r2.cloudflarestorage.com`
// is R2's S3 API endpoint. It is reachable from everywhere, but it is not a
// CDN: nothing it serves is cached at the edge. Every byte of every play,
// for every viewer, is fetched from the bucket's region. The bucket's
// location hint is APAC, so a viewer in Yangon is doing better than most —
// and still paying a round trip to Singapore or Tokyo for each seek, each
// range request, and each of the two requests an MP4 with its index at the
// end needs before the first frame. Nothing is shared between two people
// watching the same film ten minutes apart.
//
// IT SHOWS TOO MUCH. The URL names the account, names the private bucket,
// spells out the folder scheme, and carries the access key id in its
// credential scope. None of that is a password. All of it is the map.
//
// WHAT THIS DOES INSTEAD.
//
// The app is handed an opaque, expiring token and plays
//
//   https://<worker>/v/<token>
//
// The token is AES-GCM ciphertext: the object key is inside it, encrypted
// with a secret only this Worker and the Supabase function that mints
// tokens share. It cannot be read, edited or extended by anyone holding the
// URL, and it says nothing about R2 to anyone who looks at it.
//
// THE CACHE IS THE POINT, and getting it is the whole reason this is
// written as two entrypoints rather than one.
//
// Workers Caching keys on the request path. A token is different on every
// play — a new expiry, a new IV — so caching on the public path would miss
// every single time and be worse than useless. So the gateway below does
// the decrypting and then forwards to a SECOND entrypoint at a stable,
// internal path derived from the object key. That inner entrypoint is the
// one with caching enabled. Two people watching the same film share one
// cache entry even though their URLs have nothing in common.
//
// Range requests are the platform's job, not ours, and the rule is exact:
// Cloudflare strips `Range` before invoking a cached entrypoint, asks for
// the FULL body, stores it, and slices every subsequent range out of the
// stored copy without invoking the Worker at all. A Worker that returns its
// own 206 is treated as uncacheable — so `Media` below always returns 200
// with the whole object and never looks at `Range`. Getting that backwards
// is the difference between an edge cache and an expensive proxy.

import { WorkerEntrypoint } from 'cloudflare:workers';

/// How long a cached object stays at the edge.
///
/// A day. The objects are immutable — every upload gets a fresh key with a
/// timestamp and a random suffix, so the same key never holds different
/// bytes — which is also why `immutable` is honest here rather than
/// optimistic. Changing a film means a new key, and a new key is a new
/// cache entry.
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
///
/// Caught by `tool/js/stream_token_test.mjs`, which opens a token with the
/// wrong secret and expects to be refused.
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
/// The first version required the secret to be exactly 32 bytes of
/// base64url, because that is what AES-GCM wants and what `openssl rand`
/// produces. That is a fine requirement for someone at a terminal and a trap
/// for everyone else: the operator here works from a phone, where the
/// natural way to get a long random string is a password manager — and those
/// produce text with symbols in it, which is not base64url and does not
/// decode to 32 bytes.
///
/// Hashing removes the requirement entirely. Any string at all becomes
/// exactly 32 bytes, deterministically, on both sides. A long random
/// passphrase works; so does a base64url key from `openssl`. There is no
/// format to get wrong, and therefore no way to get it wrong quietly.
///
/// It costs one hash per isolate, not per request — see the cache above.
async function deriveKey(secret) {
  const digest = await crypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(secret));
  return crypto.subtle.importKey(
    'raw', digest, { name: 'AES-GCM' }, false, ['decrypt']);
}

/// Reads a token back. Returns null for anything at all suspect.
///
/// AES-GCM is authenticated encryption, so a token that has been edited by
/// a single bit fails to decrypt rather than decrypting to something else.
/// There is no separate signature to check and no way to make one.
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
    // Expiry is checked HERE, not by the cache. A stale token must stop
    // working even though the object it names is still cached and warm.
    if (Date.now() / 1000 > claim.e) return null;
    return claim;
  } catch {
    return null;
  }
}

/// The cached half. Reads one object from the bucket and returns all of it.
///
/// Never sees a token, never sees a `Range` header (the platform strips it),
/// and never returns a 206. Its path is the object key, which is stable, so
/// every viewer of one film shares one entry.
///
/// EXTENDS `WorkerEntrypoint` RATHER THAN LOOKING LIKE ONE. A plain class
/// with the same constructor shape reads identically and is not the same
/// thing: per-entrypoint caching is configured against named entrypoints,
/// and `ctx.exports.Media` resolves to one. A lookalike would deploy, run,
/// and never be cached — which is the failure mode this whole file exists
/// to avoid, arrived at by a different road.
export class Media extends WorkerEntrypoint {
  async fetch(request) {
    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname.replace(/^\/o\//, ''));
    if (!key) return refuse();

    const object = await this.env.MEDIA.get(key);
    if (!object) return refuse();

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('Content-Type',
      object.httpMetadata?.contentType || 'video/mp4');
    headers.set('Content-Length', String(object.size));
    headers.set('ETag', object.httpEtag);
    // Tells the platform to store it, and tells the player it may seek.
    headers.set('Cache-Control',
      `public, max-age=${EDGE_TTL_SECONDS}, immutable`);
    headers.set('Accept-Ranges', 'bytes');
    // The object key must not travel back out in a header either. R2 sets
    // none of these itself, but a future `writeHttpMetadata` change could.
    headers.delete('Content-Disposition');

    return new Response(object.body, { status: 200, headers });
  }
}

/// The public half. Authenticates, then hands over to the cached half.
///
/// Caching is DISABLED for this entrypoint in wrangler.toml, on purpose: it
/// must run on every request so an expired token stops working immediately,
/// even while the object it named is still warm in the cache.
export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405 });
    }
    if (!env.TOKEN_SECRET) {
      // Refusing everything beats serving everything. A missing secret is
      // a deployment mistake, and the safe reading of it is "closed".
      return refuse();
    }

    const url = new URL(request.url);
    // A liveness probe that reveals nothing about the bucket.
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ ok: true, service: 'innocent-stream' }), {
        headers: { 'Content-Type': 'application/json',
                   'Cache-Control': 'no-store' },
      });
    }

    const match = url.pathname.match(/^\/v\/([A-Za-z0-9_-]+)$/);
    if (!match) return refuse();

    const claim = await openToken(match[1], env.TOKEN_SECRET);
    if (!claim) return refuse();

    // The internal URL. `https://media.internal` is never resolved — it is
    // a name for the cache key, and the key is the object, which is what
    // makes two viewers of one film share one stored copy.
    const inner = new Request(
      'https://media.internal/o/' + encodeURIComponent(claim.k),
      { method: 'GET', headers: new Headers() },
    );
    const response = await ctx.exports.Media.fetch(inner);

    // A HEAD is answered from the same cached entry, without a body. mpv
    // sends one on some paths before it commits to a stream.
    if (request.method === 'HEAD') {
      return new Response(null, {
        status: response.status,
        headers: response.headers,
      });
    }
    return response;
  },
};
