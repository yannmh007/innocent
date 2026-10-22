// ===========================================================================
// request-playback — Supabase Edge Function — **v4, 22 Oct 2026**
// Innocent Movies.  For app v1.63.5+310; binds tokens for v1.64.70+.
//
// v4 closes four doors (docs/security_streaming.md, phase 1):
//   * NO PRESIGNED FALLBACK. If the Worker's two secrets are missing the
//     function refuses; it no longer hands out an S3 URL naming the account,
//     the bucket, the object key and the access key id.
//   * A PREMIUM GRANT NEEDS THE INSTALL ID. Without one, the two-device check
//     was skipped. Every app since 1.63.5 sends it.
//   * A BUDGET ON GRANTS (migration 046): per install, per account and per
//     network, by the hour, and distinct titles a day. Over it: 429
//     `rate_limited`, with `retry_after`.
//   * THE TOKEN NAMES WHO IT IS FOR: `u`, the account's hash, always (the
//     Worker logs it); `d`, the install's hash, and `b: 1` when the app asks
//     with `bind: true` — then the Worker checks the app's `X-Innocent-Device`
//     header against it.
//
// v3 did two things:
//   * plays a single ASSET (a clip, a trailer) as well as a title's main
//     video, which is what makes the album's clips openable at all;
//   * stops sending its diagnostics to the CLIENT. v2's `reason` and `detail`
//     solved a real problem and carried database error text out to the app,
//     which is nobody's business but the operator's. The same information is
//     now written to the function log, where `supabase Logs` shows it and the
//     user does not.
//
// (v1–v3's S3 signer, verified against an independent implementation of the
// AWS spec, is gone with the fallback it served; see below.)
//
// THIS FILE IS THE MASTER COPY. The Supabase dashboard editor has no version
// control and no rollback, so the copy running in production can be edited
// into something nobody has a record of. Change it HERE first, then paste.
//
// HOW TO DEPLOY WITHOUT A TERMINAL
//   Dashboard -> Edge Functions -> "Deploy a new function" -> "Via Editor"
//   -> name it exactly `request-playback` -> paste this whole file -> Deploy.
//   It needs STREAM_BASE and STREAM_TOKEN_SECRET (below) and the service key.
//   The R2_* secrets are no longer read here; other functions still use them.
//
// WHAT THIS FUNCTION IS
//   The security boundary of the whole product. Everything else - the tier
//   table, the locks drawn on posters, the paywall sheet - decides what to
//   DRAW. This decides what to HAND OVER, and it is the only thing that does.
//
//   The client sends no assertion about its own rights; there is no field for
//   one. It sends a title id and gets back either a sealed URL or a refusal
//   with a reason. An attacker who patches the app gets a nicer-looking free
//   account and no bytes.
// ===========================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Ten minutes. Long enough to start a film on a slow connection, short enough
// that a copied link is worthless by the time it is pasted anywhere. It does
// NOT have to outlast the film: the app renews mid-playback through
// StreamRenewal, which re-runs every check in this file.
const EXPIRY_SECONDS = 600;

// --- the presigned S3 URL, and why it is gone (v4) ---------------------------
//
// v1–v3 signed an S3 URL for R2 by hand (SigV4) and fell back to it whenever
// the Worker was not configured. That URL names the Cloudflare account, the
// private bucket, the object key and the access key id — everything the
// Worker exists to keep out of a client's hands — and a fallback meant one
// missing secret would quietly hand all of it to every phone. Refusing is the
// safe reading of a deployment mistake, as the Worker itself already does.
// (studio.ts and probe-media.ts keep their own signer for the console.)

// --- the Worker door -------------------------------------------------------
//
// PREFERRED OVER A PRESIGNED S3 URL WHENEVER IT IS CONFIGURED, and the
// reason is both halves of what people complain about.
//
// `<account>.r2.cloudflarestorage.com` is R2's S3 API endpoint. It answers
// from anywhere and it caches nothing: every byte of every play, for every
// viewer, is fetched from the bucket's region, and two people watching the
// same film ten minutes apart share nothing at all. The Worker answers from
// Cloudflare's edge, beside the viewer, and reads the bucket over
// Cloudflare's own network.
//
// And the presigned URL says far too much. It names the account, names the
// private bucket, spells out the folder scheme and carries the access key id
// in its credential scope — on screen in the player's own information
// dialog until v1.64.22, and in any screenshot a viewer passes on. A token
// says none of it.
//
// FAILS CLOSED (v4). If either secret is missing this returns null and the
// caller refuses. v1–v3 fell back to a presigned URL instead; see above.
const STREAM_BASE = (Deno.env.get('STREAM_BASE') ?? '').replace(/\/+$/, '');
const STREAM_TOKEN_SECRET = Deno.env.get('STREAM_TOKEN_SECRET') ?? '';

function b64urlFromBytes(b: Uint8Array): string {
  let s = '';
  for (const byte of b) s += String.fromCharCode(byte);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/// A playable URL through the Worker, or null when it is not configured.
///
/// AES-GCM rather than a signature. A signed-but-readable token would still
/// publish the object key to anyone who base64-decodes the URL, which gives
/// back most of what moving off the S3 endpoint was for. Encrypted, the
/// token is opaque, and because GCM is authenticated it also cannot be
/// edited or its expiry extended — one changed bit fails to decrypt rather
/// than decrypting to something else.
///
/// [who] goes into the token beside the key and the expiry (v4): `u`, the
/// account's hash, for the Worker's log; `d`, the install's hash, and `b: 1`
/// when the app asked for its token to be bound — the Worker then plays it
/// only for a request carrying that install's id. The Worker ignores fields it
/// does not know, so a token with them opens on a Worker without the check.
async function workerUrl(
  objectKey: string,
  who: Record<string, string | number> = {},
): Promise<string | null> {
  if (!STREAM_BASE || !STREAM_TOKEN_SECRET) return null;
  try {
    // SHA-256 OF THE SECRET, NOT THE SECRET'S BYTES. AES-GCM wants exactly
    // 32 bytes, which meant the secret had to be base64url of exactly that
    // length — fine at a terminal with `openssl rand`, a trap for an
    // operator on a phone whose natural source of a long random string is a
    // password manager, which produces text with symbols in it. Hashing
    // turns any string into 32 bytes on both sides, so there is no format
    // to get wrong. The Worker derives its key the same way.
    const key = await crypto.subtle.importKey(
      'raw',
      await crypto.subtle.digest(
        'SHA-256', new TextEncoder().encode(STREAM_TOKEN_SECRET)),
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
      ...who,
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
    // The caller refuses; the log says why.
    logRefusal('stream_token_failed', String(e));
    return null;
  }
}

/// The first [chars] hex digits of SHA-256(text). An install is
/// `sha256Hex(id, 32)` here, in the Worker and in migration 046 alike, so a
/// token, a log line and a budget row name the same phone the same way.
async function sha256Hex(text: string, chars: number): Promise<string> {
  const d = new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  return Array.from(d).map((b) => b.toString(16).padStart(2, '0')).join('')
    .slice(0, chars);
}

/// The caller's address, for the network budget only — it is hashed with a
/// secret salt in the database and never stored.
function callerIp(req: Request): string | null {
  const h = req.headers;
  const ip = h.get('cf-connecting-ip') ?? h.get('x-real-ip') ??
    (h.get('x-forwarded-for') ?? '').split(',')[0].trim();
  return ip ? ip.slice(0, 64) : null;
}

/// Seconds until a budget that ran out fills again: the next hour for an
/// hourly one, the next day (UTC) for the titles.
function retryAfter(which: string): number {
  const now = new Date();
  const next = which.endsWith('_daily_titles')
    ? Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1)
    : Math.floor(now.getTime() / 3600000 + 1) * 3600000;
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
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
/// What goes in `url` — the field every installed app reads, and the one
/// offline downloads fetch.
///
/// THE ORIGINAL when it is in R2, exactly as before. When the storage policy
/// has left the original only in Telegram, the BEST streaming copy instead:
/// an app that knows nothing of `renditions` still plays, and a download gets
/// the best copy that exists rather than a URL to nothing. (The downloader
/// notices that the size changed and starts the file again rather than
/// splicing two encodes together.) Null when there is neither.
function primaryUrl(
  masterUrl: string | null,
  ladder: Array<Record<string, unknown>>,
): string | null {
  if (masterUrl) return masterUrl;
  let best: Record<string, unknown> | null = null;
  for (const r of ladder) {
    if (typeof r.url !== 'string' || !r.url) continue;
    if (!best || Number(r.kbps ?? 0) > Number(best.kbps ?? 0)) best = r;
  }
  return best ? String(best.url) : null;
}

function logRefusal(reason: string, detail?: string) {
  console.log(JSON.stringify({
    refusal: reason,
    detail,
    key_source: KEY_SOURCE,
    key_len: SERVICE_KEY.length,
    stream_ready: !!STREAM_BASE && !!STREAM_TOKEN_SECRET,
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

  let body: {
    title_id?: string; device_id?: string; asset_id?: string; bind?: boolean;
  };
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

  // ─── WHICH OBJECT ARE WE SIGNING? (v3) ──────────────────
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
  // WHICH ROW THE LADDER HANGS OFF. Renditions belong to a `title_assets`
  // row, and a title played through its own `locator` has no asset id in the
  // request — so it is looked up by key below. Without that, the main film
  // of every title would be the one thing in the catalogue that never got a
  // smaller copy, which is exactly backwards.
  let assetId: string | null = null;
  // Whether the ORIGINAL is in R2. The storage policy (migration 029) can
  // leave a film's original only in Telegram once its streaming copies exist.
  let masterInR2 = true;

  if (body.asset_id) {
    const { data: asset, error: assetErr } = await admin
      .from('title_assets')
      .select('id, object_key, is_free, title_id, kind, master_state')
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
    assetId = asset.id as string;
    masterInR2 = asset.master_state !== 'telegram' && asset.master_state !== 'restoring';
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
    //
    // REQUIRED SINCE v4. Until then a premium request without a device id
    // simply skipped this count, which made the two-device limit a matter of
    // leaving a field out. Every app since 1.63.5 sends it. And because one
    // account can hold at most two installs, it is also the limit on how many
    // phones can be watching premium at once (finding #5): no further count
    // is needed.
    const deviceId = typeof body.device_id === 'string' ? body.device_id : '';
    if (!deviceId) {
      // Not `wrong_device`: that tells a person their account is full, and
      // no app of ours gets here. Whatever does is told nothing.
      logRefusal('premium_without_device', titleId);
      return json({ code: 'bad_request' }, 400);
    }
    {
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

  // ─── NOT CONFIGURED IS CLOSED (v4) ───────────────────────────────
  //
  // No Worker secrets, no URL: see "the presigned S3 URL, and why it is
  // gone". 503 rather than 404, so the log and the app both read it as the
  // server's fault, not the title's.
  if (!STREAM_BASE || !STREAM_TOKEN_SECRET) {
    logRefusal('stream_not_configured', titleId);
    return json({ code: 'unavailable' }, 503);
  }

  // ─── THE BUDGET (v4, migration 046) ──────────────────────────────
  //
  // Taken only for a grant that is about to be made: every refusal above
  // has already said no without spending anything, and handed no bytes.
  //
  // OPEN IF THE BUDGET CANNOT BE READ. It is a ceiling for scripts, not the
  // entitlement check — that has already passed — and a database hiccup that
  // stopped every film in the country would be a worse failure than one
  // unmetered grant. The log says when it happens.
  const install = typeof body.device_id === 'string'
    ? body.device_id.slice(0, 128) : '';
  try {
    const { data: over, error: budgetErr } = await admin.rpc(
      'take_playback_budget', {
        p_user: user?.id ?? null,
        p_device: install || null,
        p_ip: callerIp(req),
        p_title: title.id,
      });
    if (budgetErr) {
      logRefusal('budget_unavailable', budgetErr.message);
    } else if (typeof over === 'string' && over) {
      // Which budget, in the log only. The caller is told to wait, and how
      // long — an app can say so; a script learns nothing it did not know.
      logRefusal('budget', over);
      const wait = retryAfter(over);
      return new Response(
        JSON.stringify({ code: 'rate_limited', retry_after: wait }), {
          status: 429,
          headers: { 'Content-Type': 'application/json', 'Retry-After': String(wait) },
        });
    }
  } catch (e) {
    logRefusal('budget_unavailable', String(e).slice(0, 160));
  }

  // ─── WHO THE TOKENS ARE FOR (v4) ─────────────────────────────────
  //
  // `u`: the account, as 16 hex digits of SHA-256 of its id, for the
  // Worker's log — what one account pulled in a day can then be added up.
  // `d`: the install, the same hash migration 046 keeps; the Worker counts
  // its requests per install. `b: 1` only when the app asked (`bind: true`,
  // 1.64.70+), because only that app sends `X-Innocent-Device` on every
  // fetch — binding an older app's token would stop its film. Once no older
  // app is supported, every premium token can be bound.
  const who: Record<string, string | number> = {};
  if (user) who.u = await sha256Hex(user.id, 16);
  if (install) {
    who.d = await sha256Hex(install, 32);
    if (body.bind === true) who.b = 1;
  }

  // Signed after the ladder is read, below: when the original is only in
  // Telegram there is nothing at its key to sign.

  // ─── THE LADDER ──────────────────────────────────────────────────
  //
  // WHY THE SERVER HANDS OVER ALL OF THEM AND THE CLIENT CHOOSES. The one
  // fact that decides which copy of a film somebody should receive — what
  // their connection is actually delivering right now — exists only on their
  // phone. A server can guess from a country code and be wrong about a
  // person in a lift. So every rung is signed and sent, and the player picks
  // against what it has measured, and drops a rung when it measures a stall.
  //
  // SIGNING FIVE URLS INSTEAD OF ONE is five AES-GCM encryptions of about
  // sixty bytes. It is not worth a round trip to avoid.
  //
  // `url` STAYS EXACTLY WHAT IT WAS. Every app already installed reads that
  // field and knows nothing about this one, and an app that stops playing
  // because the server got cleverer is not an improvement.
  const renditions: Array<Record<string, unknown>> = [];
  try {
    if (!assetId) {
      const { data: byKey } = await admin
        .from('title_assets').select('id, master_state')
        .eq('object_key', objectKey).limit(1).maybeSingle();
      if (byKey?.id) {
        assetId = byKey.id as string;
        masterInR2 = byKey.master_state !== 'telegram' && byKey.master_state !== 'restoring';
      }
    }
    if (assetId) {
      const { data: rows } = await admin.rpc('renditions_for', { p_asset: assetId });
      for (const r of (rows ?? []) as Array<Record<string, unknown>>) {
        const key = String(r.object_key ?? '');
        if (!key) continue;
        const rUrl = await workerUrl(key, who);
        if (!rUrl) continue;
        renditions.push({
          height: r.height, kbps: r.kbps, bytes: r.bytes ?? null, url: rUrl,
        });
      }
    }
  } catch (e) {
    // A ladder that cannot be read is not a reason to refuse playback. The
    // original still plays, which is what happened before any of this
    // existed.
    logRefusal('renditions_failed', String(e).slice(0, 160));
  }

  const masterUrl = masterInR2 ? await workerUrl(objectKey, who) : null;
  const url = primaryUrl(masterUrl, renditions);
  if (!url) {
    // Only in Telegram and no streaming copy to play: an archive that lost
    // its ladder. The console shows it; a viewer gets "not found". (In R2
    // and still no URL is a token that could not be sealed — logged above.)
    logRefusal(masterInR2 ? 'no_url' : 'master_in_telegram',
      String(assetId ?? titleId));
    return json({ code: masterInR2 ? 'unavailable' : 'not_found' },
      masterInR2 ? 503 : 404);
  }

  return json({
    url,
    expires_at: new Date(Date.now() + EXPIRY_SECONDS * 1000).toISOString(),
    // A label, not an address. The client ignores it; the function log does
    // not, and neither does anyone checking a deployment took effect.
    via: masterUrl ? 'edge' : 'rung',
    // Cheapest first. Empty for anything not transcoded, which the client
    // reads as "there is one copy and this is it".
    renditions,
  }, 200);
});
