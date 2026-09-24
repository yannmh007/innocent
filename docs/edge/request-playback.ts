// ===========================================================================
// request-playback — Supabase Edge Function — **v3, 2 Sep 2026**
// Innocent Movies, phase 1.  For app v1.63.5+310.
//
// v3 does two things:
//   * plays a single ASSET (a clip, a trailer) as well as a title's main
//     video, which is what makes the album's clips openable at all;
//   * stops sending its diagnostics to the CLIENT. v2's `reason` and `detail`
//     solved a real problem and carried database error text out to the app,
//     which is nobody's business but the operator's. The same information is
//     now written to the function log, where `supabase Logs` shows it and the
//     user does not.
//
// The signing half below is untouched across all three versions, and was
// verified against an independent implementation of the AWS spec on three
// object keys including one with spaces and brackets.
//
// THIS FILE IS THE MASTER COPY. The Supabase dashboard editor has no version
// control and no rollback, so the copy running in production can be edited
// into something nobody has a record of. Change it HERE first, then paste.
//
// HOW TO DEPLOY WITHOUT A TERMINAL
//   Dashboard -> Edge Functions -> "Deploy a new function" -> "Via Editor"
//   -> name it exactly `request-playback` -> paste this whole file -> Deploy.
//   Then Edge Functions -> Secrets, and add the five R2_* values below.
//
// WHAT THIS FUNCTION IS
//   The security boundary of the whole product. Everything else - the tier
//   table, the locks drawn on posters, the paywall sheet - decides what to
//   DRAW. This decides what to HAND OVER, and it is the only thing that does.
//
//   The client sends no assertion about its own rights; there is no field for
//   one. It sends a title id and gets back either a signed URL or a refusal
//   with a reason. An attacker who patches the app gets a nicer-looking free
//   account and no bytes.
// ===========================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// --- R2, from the function's secrets ---------------------------------------
// Never hardcode these. The account id is the hex string in your Cloudflare
// dashboard URL; the key pair comes from R2 -> Manage R2 API Tokens, scoped to
// OBJECT READ ONLY for the private bucket. A read-only token cannot delete
// your catalogue if it leaks, and it is the only capability this needs.
const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID')!;
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID')!;
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY')!;
const R2_BUCKET = Deno.env.get('R2_BUCKET')!;

// Ten minutes. Long enough to start a film on a slow connection, short enough
// that a copied link is worthless by the time it is pasted anywhere. It does
// NOT have to outlast the film: the app renews mid-playback through
// StreamRenewal, which re-runs every check in this file.
const EXPIRY_SECONDS = 600;

// --- AWS SigV4 query signing, by hand --------------------------------------
// Hand-written rather than pulling in an S3 SDK. Presigning is one hash chain
// and about sixty lines; an SDK is megabytes of cold-start for the same
// string, and cold starts are what an edge function is billed and judged on.
const enc = new TextEncoder();

// Uint8Array in and out, never a bare ArrayBuffer. The chain below feeds each
// result straight back in as the next key, and a union type there is rejected
// by `crypto.subtle.importKey` under strict checking - which the Supabase
// dashboard editor and Deno both apply. One concrete type removes the whole
// question.
async function hmac(key: Uint8Array, msg: string): Promise<Uint8Array> {
  // `as BufferSource` is a LIB-VERSION artifact, not a real conversion.
  // TypeScript 5.7 made Uint8Array generic over its buffer, so a plain
  // Uint8Array no longer satisfies BufferSource under `strict` even though it
  // always has at runtime. Writing `Uint8Array<ArrayBuffer>` instead would fix
  // it on 5.7+ and FAIL TO PARSE on anything older - and the TypeScript
  // version inside the Supabase dashboard editor is not ours to pin. The cast
  // is a no-op in every version.
  const k = await crypto.subtle.importKey(
    'raw', key as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
}

function hex(buf: Uint8Array): string {
  return Array.from(buf)
    .map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256Hex(msg: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(msg))));
}

// STRICT RFC 3986, which `encodeURIComponent` is not.
//
// SigV4 requires every character outside `A-Za-z0-9-_.~` to be percent-encoded,
// and `encodeURIComponent` deliberately leaves `! ' ( ) *` alone. A key like
// `v/2026/my title (HD).mp4` therefore signs one string and requests another,
// and R2 answers SignatureDoesNotMatch - for that title only, while every
// title with a plain name plays perfectly. Verified against an independent
// implementation of the AWS spec: without this replace, the two signatures
// differ for exactly such a key and agree for `v/first-test.mp4`.
function rfc3986(component: string): string {
  return encodeURIComponent(component).replace(
    /[!'()*]/g,
    (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase(),
  );
}

// Each path SEGMENT is encoded, but the slashes between them are not - an
// object key of `v/abc.mp4` must stay `v/abc.mp4`, not become `v%2Fabc.mp4`,
// or R2 looks for an object whose name contains a literal slash character.
function encodeKey(key: string): string {
  return key.split('/').map(rfc3986).join('/');
}

// --- the Worker door -------------------------------------------------------
//
// PREFERRED OVER A PRESIGNED S3 URL WHENEVER IT IS CONFIGURED, and the
// reason is both halves of what people complain about.
//
// `<account>.r2.cloudflarestorage.com` is R2's S3 API endpoint. It answers
// from anywhere and it caches nothing: every byte of every play, for every
// viewer, is fetched from the bucket's region, and two people watching the
// same film ten minutes apart share nothing at all. The Worker is on
// Cloudflare's edge with a read-through cache in front of it, so the second
// viewer in a region is served from beside them.
//
// And the presigned URL says far too much. It names the account, names the
// private bucket, spells out the folder scheme and carries the access key id
// in its credential scope — on screen in the player's own information
// dialog until v1.64.22, and in any screenshot a viewer passes on. A token
// says none of it.
//
// FALLS BACK RATHER THAN FAILING. If either secret is missing this returns
// null and the caller presigns as before, so a half-finished deployment
// degrades to the old behaviour instead of breaking playback. That is also
// what makes the switch a server-side change with no app release: the client
// plays whichever URL it is handed.
const STREAM_BASE = (Deno.env.get('STREAM_BASE') ?? '').replace(/\/+$/, '');
const STREAM_TOKEN_SECRET = Deno.env.get('STREAM_TOKEN_SECRET') ?? '';

function b64urlFromBytes(b: Uint8Array): string {
  let s = '';
  for (const byte of b) s += String.fromCharCode(byte);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function bytesFromB64url(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// A playable URL through the Worker, or null when it is not configured.
///
/// AES-GCM rather than a signature. A signed-but-readable token would still
/// publish the object key to anyone who base64-decodes the URL, which gives
/// back most of what moving off the S3 endpoint was for. Encrypted, the
/// token is opaque, and because GCM is authenticated it also cannot be
/// edited or its expiry extended — one changed bit fails to decrypt rather
/// than decrypting to something else.
async function workerUrl(objectKey: string): Promise<string | null> {
  if (!STREAM_BASE || !STREAM_TOKEN_SECRET) return null;
  try {
    const key = await crypto.subtle.importKey(
      'raw',
      bytesFromB64url(STREAM_TOKEN_SECRET) as BufferSource,
      { name: 'AES-GCM' },
      false,
      ['encrypt'],
    );
    // 12 bytes is the size GCM is defined for; anything else costs an extra
    // derivation step on both sides for no benefit.
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const claim = JSON.stringify({
      k: objectKey,
      e: Math.floor(Date.now() / 1000) + EXPIRY_SECONDS,
    });
    const sealed = new Uint8Array(await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      key,
      new TextEncoder().encode(claim),
    ));
    const token = new Uint8Array(iv.length + sealed.length);
    token.set(iv, 0);
    token.set(sealed, iv.length);
    return `${STREAM_BASE}/v/${b64urlFromBytes(token)}`;
  } catch (e) {
    // A broken secret must not take playback down with it. The presigned
    // path below still works, and the log says which one was used.
    logRefusal('stream_token_failed', String(e));
    return null;
  }
}

async function presign(objectKey: string): Promise<string> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;

  // Query parameters must be sorted by name; R2 is strict about it because
  // the signature is computed over the sorted form.
  const params: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${R2_ACCESS_KEY_ID}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(EXPIRY_SECONDS),
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalQuery = Object.keys(params).sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(params[k])}`)
    .join('&');

  const canonicalPath = `/${R2_BUCKET}/${encodeKey(objectKey)}`;
  const canonicalRequest = [
    'GET',
    canonicalPath,
    canonicalQuery,
    `host:${host}\n`,
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    await sha256Hex(canonicalRequest),
  ].join('\n');

  let key: Uint8Array = enc.encode(`AWS4${R2_SECRET_ACCESS_KEY}`);
  for (const part of [dateStamp, 'auto', 's3', 'aws4_request']) {
    key = await hmac(key, part);
  }
  const signature = hex(await hmac(key, stringToSign));

  return `https://${host}${canonicalPath}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

// --- refusals ---------------------------------------------------------------
// The exact strings the app switches on. `needs_premium` opens the paywall;
// `wrong_device` (v1.63.5) opens the device message; anything else becomes
// "unavailable". Getting `needs_premium` wrong loses the sale AND looks like
// a bug, so it is spelled once, here.
const json = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

// The service key, and WHICH ONE was found.
//
// v2. The first version read `SUPABASE_SERVICE_ROLE_KEY` and asserted it with
// `!`, which in TypeScript silences the compiler and does nothing at run time:
// an unset variable became the empty string, `createClient` fell back to an
// unprivileged connection, the `locator` read was refused by the very column
// grants that exist to refuse it, and the whole thing surfaced as a flat
// `not_found`. The protection worked; the report of it did not.
//
// `SB_SERVICE_KEY` is checked first so the project can move off the legacy
// name - the dashboard already marks `SUPABASE_SERVICE_ROLE_KEY` deprecated -
// without editing this file again. If neither exists the function says so
// instead of quietly continuing with no privileges.
const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const KEY_SOURCE = Deno.env.get('SB_SERVICE_KEY')
  ? 'SB_SERVICE_KEY'
  : (Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    ? 'SUPABASE_SERVICE_ROLE_KEY'
    : 'NONE');

// v3: LOGGED, not returned.
//
// v2 attached `reason` and `detail` to the refusal itself, which is how the
// missing `service_role` grant was found after two confident wrong guesses.
// That was worth it while nothing was live. It is not worth shipping: the
// detail can carry raw database text, and a refusal is not the place to
// explain the server's internals to whoever asked.
//
// The information is not lost - it goes to the function log, which the
// operator can read and the client cannot. Same debugging power, no leak.
function logRefusal(reason: string, detail?: string) {
  console.log(JSON.stringify({
    refusal: reason,
    detail,
    key_source: KEY_SOURCE,
    key_len: SERVICE_KEY.length,
    r2_ready: !!R2_ACCOUNT_ID && !!R2_ACCESS_KEY_ID &&
      !!R2_SECRET_ACCESS_KEY && !!R2_BUCKET,
  }));
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'bad_method' }, 405);

  const auth = req.headers.get('Authorization') ?? '';

  // Stop here rather than continue unprivileged. Without a service key the
  // next query cannot succeed, and failing loudly now is the difference
  // between a five-minute fix and an evening.
  if (!SERVICE_KEY) {
    logRefusal('missing_service_key');
    return json({ code: 'not_found' }, 404);
  }

  // SERVICE ROLE, deliberately. This client reads `titles.locator`, which no
  // other role may see. It never trusts the request for identity - the user is
  // resolved from the JWT below, by Supabase, not from anything in the body.
  const admin = createClient(Deno.env.get('SUPABASE_URL') ?? '', SERVICE_KEY);

  // Wrapped: an absent or malformed Authorization header is the NORMAL case
  // for a free title, and `getUser` throwing on it must not become a 500 that
  // the app reads as "server down".
  let user: { id: string } | null = null;
  try {
    const { data: userData } = await admin.auth.getUser(
      auth.replace('Bearer ', ''),
    );
    user = userData?.user ?? null;
  } catch (_) {
    user = null;
  }

  let body: { title_id?: string; device_id?: string; asset_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ code: 'bad_request' }, 400);
  }
  const titleId = body.title_id;
  if (!titleId) return json({ code: 'bad_request' }, 400);

  const { data: title, error } = await admin
    .from('titles')
    .select('id, access_tier, locator, published')
    .eq('id', titleId)
    .maybeSingle();

  // Four different problems used to share one word. `query_failed` in
  // particular is not a missing title at all - it is the database refusing
  // this connection, which looks identical from the outside and has an
  // entirely different fix.
  if (error) {
    logRefusal('query_failed', error.message);
    return json({ code: 'not_found' }, 404);
  }
  if (!title) {
    logRefusal('no_row', titleId);
    return json({ code: 'not_found' }, 404);
  }
  if (!title.published) {
    logRefusal('not_published', titleId);
    return json({ code: 'not_found' }, 404);
  }

  // ─── WHICH OBJECT ARE WE SIGNING? (v3) ─────────────────────────────────
  //
  // Either the title's main video, or one asset from its folder - a clip, a
  // behind-the-scenes reel, a trailer.
  //
  // THE ASSET IS LOOKED UP BY ID AND CHECKED AGAINST THE TITLE. The client
  // sends an id, never a path, and an id that belongs to a different title is
  // refused. Without that check, anyone could pair a free title with a premium
  // title's asset id and walk straight past the tier test below.
  let objectKey: string = title.locator;
  let assetIsFree = false;

  if (body.asset_id) {
    const { data: asset, error: assetErr } = await admin
      .from('title_assets')
      .select('object_key, is_free, title_id, kind')
      .eq('id', body.asset_id)
      .maybeSingle();

    if (assetErr || !asset) {
      logRefusal('asset_missing', assetErr?.message ?? body.asset_id);
      return json({ code: 'not_found' }, 404);
    }
    if (asset.title_id !== titleId) {
      // Not 'not_found': this is someone pairing an id with the wrong title,
      // which is worth being able to see in the log.
      logRefusal('asset_title_mismatch', `${body.asset_id} vs ${titleId}`);
      return json({ code: 'not_found' }, 404);
    }
    // Photos are served from the public bucket by their URL and never signed.
    // Asking for one here means the client is confused; refuse rather than
    // hand back a signed URL into the wrong bucket.
    if (asset.kind === 'photo' || asset.kind === 'subtitle') {
      logRefusal('asset_not_playable', asset.kind);
      return json({ code: 'not_found' }, 404);
    }
    objectKey = asset.object_key;
    assetIsFree = asset.is_free === true;
  }

  if (!objectKey) {
    logRefusal('no_locator', titleId);
    return json({ code: 'not_found' }, 404);
  }

  // THE TRAILER SLOT. An asset marked `is_free` opens inside a premium title
  // without an entitlement - that is the whole point of it, and it is an
  // explicit flag rather than a rule like "the first clip is free" because
  // which clip is the taste is an editorial decision.
  //
  // A free title needs no account at all. This is what lets ONE title be
  // proved end to end before any of the payment machinery exists - the pipe
  // is shown to carry water before it is decided who may drink.
  if (title.access_tier !== 'free' && !assetIsFree) {
    if (!user) return json({ code: 'needs_premium' }, 401);

    const { data: sub } = await admin
      .from('subscriptions')
      .select('expires_at')
      .eq('user_id', user.id)
      .order('expires_at', { ascending: false, nullsFirst: true })
      .limit(1)
      .maybeSingle();

    // FAIL TOWARD LOCKED. No row, or a past expiry, is a refusal. A null
    // expiry is a lifetime grant - the one case where "no date" means more
    // access rather than less, so it is spelled out rather than inferred.
    const active = !!sub && (sub.expires_at === null ||
      new Date(sub.expires_at).getTime() > Date.now());
    if (!active) return json({ code: 'needs_premium' }, 403);

    // Device binding. Two slots for premium, matching CapabilityMatrix -
    // but counted HERE, because a client-side count only knows about the
    // streams that are not the problem.
    const deviceId = body.device_id;
    if (deviceId) {
      const { data: devices } = await admin
        .from('devices')
        .select('device_id')
        .eq('user_id', user.id);
      const known = (devices ?? [])
        .some((d: { device_id: string }) => d.device_id === deviceId);
      if (!known && (devices?.length ?? 0) >= 2) {
        // 409, which v1.63.5 maps to AccessDenial.wrongDevice and a message
        // that says what to do. Before that release this rendered as
        // "unavailable" and a paying customer had no idea why.
        return json({ code: 'wrong_device' }, 409);
      }
      if (!known) {
        await admin.from('devices')
          .insert({ user_id: user.id, device_id: deviceId });
      }
    }
  }

  // The Worker when it is configured, the S3 endpoint when it is not. Which
  // one was used is worth knowing from a log without reading the URL back,
  // because "is the edge cache actually on" is otherwise a question nobody
  // can answer after the fact.
  const viaWorker = await workerUrl(objectKey);
  const url = viaWorker ?? await presign(objectKey);
  return json({
    url,
    expires_at: new Date(Date.now() + EXPIRY_SECONDS * 1000).toISOString(),
    // A label, not an address. The client ignores it; the function log does
    // not, and neither does anyone checking a deployment took effect.
    via: viaWorker ? 'edge' : 's3',
  }, 200);
});
