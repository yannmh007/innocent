// studio — the two calls behind the upload page.
//
// WHY THIS EXISTS. Putting one title into the catalogue used to mean: open the
// R2 dashboard, upload the video, upload the poster, copy both object keys,
// open the SQL editor, write an INSERT for `titles`, write another for
// `title_assets`, get the key spelling exactly right in both. Per title. From
// a phone. That is the whole reason the catalogue has one row in it.
//
// `docs/studio/index.html` is the page that does all of it: pick the files,
// type a name, tap Publish. This file is the API it talks to.
//
// THE PAGE IS NOT SERVED FROM HERE, and that is not a preference. Supabase
// documents it: "Serving of HTML content is only supported with custom
// domains (Otherwise GET requests that return text/html will be rewritten to
// text/plain)." The first version of this function returned the page with a
// text/html header and the platform rewrote it, so Chrome printed the source
// instead of rendering it. A custom domain is a paid add-on; GitHub Pages
// serves the same file, from a repository that is already public, for
// nothing. The page therefore lives in git and this stays an API.
//
// THE FILE NEVER PASSES THROUGH HERE. The page asks this function for a
// presigned PUT URL and then uploads straight from the phone to R2. An edge
// function has a request-body limit and a CPU budget; a 900 MB video respects
// neither. Going direct also means the only size limit is R2's own — 5 GiB in
// a single PUT.
//
// THE SIGNING HALF IS LIFTED FROM request-playback.ts, unchanged except that
// the canonical request says PUT where that one says GET. It has been signing
// real R2 URLs in production since 1 Sep, including for keys with spaces and
// brackets, which is the case that breaks naive implementations. Rewriting it
// would only be a chance to get it wrong.
//
// DEPLOYED WITH verify_jwt: false, deliberately, and this is the one thing to
// understand before editing. The browser's CORS preflight is an OPTIONS with
// no Authorization header, and the platform's own JWT gate rejects it before
// this code runs — so every POST from the page would fail at the preflight,
// with a CORS error that says nothing about tokens. The gate is therefore
// applied HERE, per operation: `sign` and `publish` both refuse without a
// token belonging to an operator, and the unauthenticated GET says only that
// the service is alive.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID')!;
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID')!;
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY')!;

// Two buckets, on purpose. Video is private and reached only through a signed
// URL that expires; posters are public because a catalogue that cannot draw
// its own artwork without minting a URL per thumbnail is a slow catalogue.
const MEDIA_BUCKET = Deno.env.get('R2_BUCKET') ?? 'innocent-media';
const PUBLIC_BUCKET = Deno.env.get('R2_PUBLIC_BUCKET') ?? 'innocent-public';
const PUBLIC_BASE = Deno.env.get('R2_PUBLIC_BASE') ??
  'https://pub-18c62521649645be87d4d36225021e15.r2.dev';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
// SB_ANON_KEY is a secret somebody has to remember to add — self-test.ts has
// a whole branch for it being missing — whereas SUPABASE_ANON_KEY is injected
// into every function by the platform. Falling back to it is the same shape as
// the SERVICE_KEY line above, and for the same reason: without a key here the
// page cannot build a client and `/auth/v1/user` refuses every token, so the
// symptom of a missing secret would be a dead sign-in button and a 403 on
// everything — with nothing on screen to say which secret.
const ANON_KEY = Deno.env.get('SB_ANON_KEY') ??
  Deno.env.get('SUPABASE_ANON_KEY') ?? '';

// Who may publish. A comma-separated list of auth.users.id values.
//
// Defaulted rather than required, so the page works the moment it is deployed
// — but defaulted to ONE id, not to "anyone". A user id is not a secret and
// grants nothing on its own; what it does is keep this list readable next to
// the code that enforces it, instead of in a dashboard nobody opens.
const OPERATORS = (Deno.env.get('OPERATOR_IDS') ??
  '6c679480-3387-4442-ad3d-4423b8aceb71')
  .split(',').map((s) => s.trim()).filter(Boolean);

const EXPIRY_SECONDS = 3600; // An hour: a long video on a Myanmar connection.

// --- AWS SigV4 query signing ------------------------------------------------
// Identical to request-playback.ts. See that file for why each piece is the
// way it is; the notes are not repeated here so the two cannot drift by having
// two explanations.
const enc = new TextEncoder();

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

function rfc3986(component: string): string {
  return encodeURIComponent(component).replace(
    /[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase(),
  );
}

function encodeKey(key: string): string {
  return key.split('/').map(rfc3986).join('/');
}

async function presignPut(bucket: string, objectKey: string): Promise<string> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;

  const params: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${R2_ACCESS_KEY_ID}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(EXPIRY_SECONDS),
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalQuery = Object.keys(params).sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(params[k])}`).join('&');

  const canonicalPath = `/${bucket}/${encodeKey(objectKey)}`;

  // PUT, not GET. The single character that turns a playback URL into an
  // upload URL — the signature covers the method, so a GET-signed URL is
  // refused for a PUT with SignatureDoesNotMatch rather than with anything
  // that says "wrong method".
  //
  // Content-Type is deliberately NOT signed and NOT in SignedHeaders. Signing
  // it would force the browser to send exactly the type we guessed, and a
  // phone's file picker reports types this code has no business predicting.
  const canonicalRequest = [
    'PUT',
    canonicalPath,
    canonicalQuery,
    `host:${host}\n`,
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonicalRequest),
  ].join('\n');

  let key: Uint8Array = enc.encode(`AWS4${R2_SECRET_ACCESS_KEY}`);
  for (const part of [dateStamp, 'auto', 's3', 'aws4_request']) {
    key = await hmac(key, part);
  }
  const signature = hex(await hmac(key, stringToSign));

  return `https://${host}${canonicalPath}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

// --- who is asking ----------------------------------------------------------
// The token is checked by ASKING THE AUTH SERVER, not by verifying a signature
// here. Verifying locally means holding the JWT secret in a second place and
// reimplementing expiry and revocation; asking costs one request and is right
// by construction. It is the same call the app makes on every cold start.
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

// --- object keys ------------------------------------------------------------
// Matches what is already in the bucket: `v/…` for video, `p/…` for stills.
//
// The name is rebuilt rather than trusted. A phone hands over whatever the
// file is called — spaces, brackets, Burmese, a leading dot, `../` if someone
// is trying — and an object key is a path. Keeping only a known alphabet and
// prefixing a timestamp also makes two uploads of `VID_0001.mp4` two objects
// instead of one overwriting the other.
function safeKey(prefix: string, filename: string): string {
  const dot = filename.lastIndexOf('.');
  const stem = (dot > 0 ? filename.slice(0, dot) : filename)
    .toLowerCase().replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '').slice(0, 60) || 'file';
  const ext = (dot > 0 ? filename.slice(dot + 1) : '')
    .toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 8);
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const rand = crypto.randomUUID().slice(0, 8);
  return `${prefix}/${stamp}-${stem}-${rand}${ext ? '.' + ext : ''}`;
}

// The page is on github.io and this is on supabase.co, so every call from it
// is cross-origin and the browser will not even deliver the response without
// these. An allow-list of one origin rather than `*`: nothing here is meant to
// be callable from any page that fancies it, and the operator check is not a
// reason to be careless about who gets to try.
const ALLOWED_ORIGINS = (Deno.env.get('STUDIO_ORIGINS') ??
  'https://yannmh007.github.io')
  .split(',').map((s) => s.trim()).filter(Boolean);

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin') ?? '';
  if (!ALLOWED_ORIGINS.includes(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'authorization, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '86400',
  };
}

function json(body: unknown, status = 200, req?: Request): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...(req ? corsHeaders(req) : {}),
    },
  });
}

Deno.serve(async (req: Request) => {
  // The preflight the browser sends before any POST carrying an
  // Authorization header. Answering it is not optional.
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders(req) });
  }

  // Opening this URL by hand should say what it is rather than 405 at
  // somebody who is trying to check the thing is alive.
  if (req.method === 'GET') {
    return json({
      ok: true,
      service: 'studio',
      page: 'https://yannmh007.github.io/innocent/studio/',
    }, 200, req);
  }

  if (req.method !== 'POST') return json({ error: 'method' }, 405, req);

  const who = await operatorId(req);
  if (!who) return json({ error: 'not_an_operator' }, 403, req);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'bad_json' }, 400, req);
  }

  // --- sign: hand back one presigned PUT URL -------------------------------
  if (body.op === 'sign') {
    const filename = String(body.filename ?? '');
    const kind = body.kind === 'photo' ? 'photo' : 'video';
    if (!filename) return json({ error: 'no_filename' }, 400, req);

    const bucket = kind === 'photo' ? PUBLIC_BUCKET : MEDIA_BUCKET;
    const objectKey = safeKey(kind === 'photo' ? 'p' : 'v', filename);
    const uploadUrl = await presignPut(bucket, objectKey);

    return json({
      uploadUrl,
      bucket,
      objectKey,
      // Only meaningful for the public bucket; the media bucket is reached
      // through request-playback, never by a direct URL.
      publicUrl: kind === 'photo' ? `${PUBLIC_BASE}/${objectKey}` : null,
    }, 200, req);
  }

  // --- selftest: can these credentials actually write to each bucket? ------
  //
  // EXISTS BECAUSE THE BROWSER CANNOT TELL YOU. A failed PUT from the page
  // reports the same "network error" whether the bucket has no CORS policy or
  // the API token has no write permission on it — R2 does not attach CORS
  // headers to its error responses, so the browser blocks the reply before
  // JavaScript can read the status. Two very different faults, one symptom.
  //
  // This does the same signed PUT from the server, where there is no CORS at
  // all. A 200 here with a failure in the page means CORS; a 403 here means
  // the token. It leaves one tiny object per bucket under `_selftest/`, which
  // is harmless and identifiable.
  if (body.op === 'selftest') {
    const out: Record<string, unknown> = {};
    for (const bucket of [MEDIA_BUCKET, PUBLIC_BUCKET]) {
      const key = `_selftest/${crypto.randomUUID()}.txt`;
      try {
        const res = await fetch(await presignPut(bucket, key), {
          method: 'PUT',
          body: 'studio selftest',
        });
        out[bucket] = {
          status: res.status,
          ok: res.ok,
          // R2 explains itself in an XML body. Truncated because the useful
          // part — the <Code> — is at the front.
          detail: res.ok ? null : (await res.text()).slice(0, 300),
        };
      } catch (e) {
        out[bucket] = { error: String(e) };
      }
    }
    return json(out, 200, req);
  }

  // --- publish: the rows that make it a title ------------------------------
  //
  // Service role, because `titles` is not writable by `authenticated` and
  // should not be: the check that matters already happened above, against a
  // list of two-or-fewer people, and widening RLS to let a signed-in user
  // write the catalogue would be a far larger hole than this function is.
  if (body.op === 'publish') {
    if (!SERVICE_KEY) return json({ error: 'no_service_key' }, 500, req);

    const title = String(body.title ?? '').trim();
    if (!title) return json({ error: 'no_title' }, 400, req);

    const video = body.video as { bucket: string; objectKey: string } | null;
    if (!video?.objectKey) return json({ error: 'no_video' }, 400, req);

    const photo = body.photo as { objectKey: string; publicUrl: string } | null;
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: row, error: titleErr } = await admin
      .from('titles')
      .insert({
        title,
        title_mm: String(body.titleMm ?? '').trim() || null,
        synopsis: String(body.synopsis ?? '').trim() || null,
        category: String(body.category ?? 'movies'),
        access_tier: body.free === true ? 'free' : 'premium',
        // `locator` is what request-playback signs. It must be the object key
        // inside the media bucket, with no leading slash and no bucket name.
        locator: video.objectKey,
        provider: 'r2',
        poster_url: photo?.publicUrl ?? null,
        // Draft until the operator says otherwise. Publishing by default is
        // how a half-uploaded title reaches a paying customer.
        status: body.publish === true ? 'published' : 'draft',
        published: body.publish === true,
      })
      .select('id')
      .single();

    // `!row` as well as the error: `.single()` types its data as possibly
    // null, and an error check alone does not narrow it, so `row.id` below
    // is a type error under the strict settings Deno applies.
    if (titleErr || !row) {
      return json({ error: 'title_insert', detail: titleErr?.message ?? 'no row' }, 500, req);
    }

    // The assets rows drive photo_count / video_count through the triggers
    // already on this table — nothing here counts anything itself.
    const assets: Record<string, unknown>[] = [{
      title_id: row.id,
      kind: 'video',
      bucket: video.bucket ?? MEDIA_BUCKET,
      object_key: video.objectKey,
      is_primary: true,
      is_free: body.free === true,
      sort_order: 0,
    }];
    if (photo?.objectKey) {
      assets.push({
        title_id: row.id,
        kind: 'photo',
        bucket: PUBLIC_BUCKET,
        object_key: photo.objectKey,
        is_primary: true,
        is_free: true, // A poster is the advertisement; it is never withheld.
        sort_order: 0,
      });
    }

    const { error: assetErr } = await admin.from('title_assets').insert(assets);
    if (assetErr) return json({ error: 'asset_insert', detail: assetErr.message }, 500, req);

    return json(
      { id: row.id, title, status: body.publish === true ? 'published' : 'draft' },
      200, req,
    );
  }

  return json({ error: 'unknown_op' }, 400, req);
});
