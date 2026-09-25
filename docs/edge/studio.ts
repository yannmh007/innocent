// studio — the API behind the operator console.
//
// Was two calls (sign, publish) behind an upload form. It is now the whole
// console: list, get, create, save, addAssets, updateAsset, setPrimary,
// deleteAsset, deleteTitle, reorder, requests, approve, reject, categories,
// saveCategory, addCategory, stats, health, folder, checkFolder, sign,
// beginMultipart, signParts, completeMultipart, abortMultipart, selftest.
//
// WHY THIS EXISTS. Putting one title into the catalogue used to mean: open the
// R2 dashboard, upload the video, upload the poster, copy both object keys,
// open the SQL editor, write an INSERT for `titles`, write another for
// `title_assets`, get the key spelling exactly right in both. Per title. From
// a phone. That is the whole reason the catalogue has one row in it.
//
// `docs/studio/index.html` is the page that does all of it. This file is the
// API it talks to.
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
// applied HERE, ONCE, as an early return before any op is dispatched — so an
// op added later is behind it automatically and cannot be forgotten, and the
// unauthenticated GET says only that the service is alive.

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

/// [extraQuery] carries the parameters a MULTIPART part upload needs
/// (`partNumber` and `uploadId`). They are signed like any other query
/// parameter, which is the whole reason they have to go through here rather
/// than being appended to a finished URL: SigV4 covers the canonical query
/// string, so a parameter added afterwards invalidates the signature and R2
/// answers SignatureDoesNotMatch without saying which parameter it minded.
async function presignPut(
  bucket: string,
  objectKey: string,
  extraQuery: Record<string, string> = {},
): Promise<string> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;

  const params: Record<string, string> = {
    ...extraQuery,
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

// --- multipart, which the server has to speak itself ------------------------
//
// ═══════════════════════════════════════════════════════════════════════
// WHY THIS IS A SECOND SIGNER AND NOT A REUSE OF THE FIRST
// ═══════════════════════════════════════════════════════════════════════
//
// A presigned URL carries its signature in the query string and lets somebody
// ELSE make the request — which is exactly right for uploading a part, because
// the bytes are in the operator's browser and must not pass through an edge
// function. It is exactly wrong for the two ends of a multipart upload:
// CreateMultipartUpload ANSWERS with the upload id in an XML body, and
// CompleteMultipartUpload has to SEND an XML body listing every part's ETag.
// A browser cannot be handed a presigned URL for either without also being
// handed the job of parsing and composing S3 XML.
//
// So begin, complete and abort are made from here with an Authorization header,
// and only the parts themselves are presigned. The difference in the signing is
// small and unforgiving: the payload hash is real rather than UNSIGNED-PAYLOAD,
// and it appears twice — once as the `x-amz-content-sha256` header and once in
// the canonical request — so a mismatch between the two is refused as a
// signature error rather than as a content error.
async function sha256HexOf(body: string): Promise<string> {
  return await sha256Hex(body);
}

interface SignedReq {
  url: string;
  headers: Record<string, string>;
}

async function signRequest(
  method: string,
  bucket: string,
  objectKey: string,
  query: Record<string, string>,
  body: string,
): Promise<SignedReq> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;
  const payloadHash = await sha256HexOf(body);

  const canonicalQuery = Object.keys(query).sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(query[k])}`).join('&');
  const canonicalPath = `/${bucket}/${encodeKey(objectKey)}`;

  // SORTED AND LOWER-CASE, and the list below must match the headers actually
  // sent, exactly. A header in SignedHeaders that is not sent, or sent with
  // different whitespace, is a signature failure with no diagnostic.
  const canonicalHeaders =
    `host:${host}\n` +
    `x-amz-content-sha256:${payloadHash}\n` +
    `x-amz-date:${amzDate}\n`;
  const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';

  const canonicalRequest = [
    method, canonicalPath, canonicalQuery,
    canonicalHeaders, signedHeaders, payloadHash,
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonicalRequest),
  ].join('\n');

  let key: Uint8Array = enc.encode(`AWS4${R2_SECRET_ACCESS_KEY}`);
  for (const part of [dateStamp, 'auto', 's3', 'aws4_request']) {
    key = await hmac(key, part);
  }
  const signature = hex(await hmac(key, stringToSign));

  return {
    url: `https://${host}${canonicalPath}` +
      (canonicalQuery ? `?${canonicalQuery}` : ''),
    headers: {
      'Authorization': `AWS4-HMAC-SHA256 Credential=${R2_ACCESS_KEY_ID}/${scope}, ` +
        `SignedHeaders=${signedHeaders}, Signature=${signature}`,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
    },
  };
}

/// One tag out of an S3 XML response.
///
/// A REGEX AND NOT A PARSER, deliberately. Deno's edge runtime has no DOM, the
/// responses here are three tags deep, and pulling in an XML library to read
/// `<UploadId>` would be a dependency added to a function that holds the R2
/// credentials. Anchored on the exact tag and non-greedy, so a longer document
/// cannot make it read past the element it was asked for.
function xmlTag(xml: string, tag: string): string | null {
  const m = new RegExp(`<${tag}>([^<]*)</${tag}>`).exec(xml);
  return m ? m[1] : null;
}

/// An object key the operator is allowed to be writing to.
///
/// CHECKED EVEN THOUGH THE CALLER IS THE OPERATOR. `complete` and `abort` take
/// a key from the page, and a key from a page is a path: without this, a typo
/// or a stale tab could complete a multipart upload onto any object in the
/// bucket — including one somebody is watching. The prefixes are the three this
/// function ever mints (see safeKey), and `..` is refused outright rather than
/// normalised, because there is no legitimate key that needs it.
function isMintedKey(key: string): boolean {
  if (!key || key.length > 512) return false;
  if (key.includes('..') || key.startsWith('/')) return false;
  return /(^|\/)(video|photo|thumb)\/[a-z0-9][a-z0-9.\-]*$/.test(key);
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
//
// ONE FOLDER PER TITLE, CHOSEN BY THE OPERATOR, in both buckets:
//
//   innocent-media/<folder>/video/20260922-solar-a1b2c3d4.mp4
//   innocent-public/<folder>/photo/20260922-poster-e5f6a7b8.jpg
//   innocent-public/<folder>/thumb/20260922-clip-01-c9d0e1f2.jpg
//
// The buckets stay two, because that split is the security boundary and not
// an organisational one: video is private and reached only through a signed
// URL, stills are public so the catalogue can draw itself. Within each, every
// file belonging to one card lives under one prefix.
//
// WHY THIS IS WORTH A MIGRATION OF HABIT. R2's console lists objects by
// prefix, so `v/` and `p/` meant one flat list of every video ever uploaded
// and another of every still, with nothing but a timestamp in the name to say
// which card a file belonged to. Finding "the third clip of Solar" meant
// reading the database first. With a folder it is one click, and deleting or
// auditing a title is one prefix.
//
// THE FOLDER IS FROZEN AT CREATION. Renaming a title later does NOT move its
// objects: every `title_assets.object_key` and `titles.locator` names the old
// prefix, and a rename that rewrote R2 would have to copy every file and
// leave the catalogue broken in between. The folder is an address, not a
// label — `titles.title` is the label.
//
// The legacy `v/…` and `p/…` keys are left exactly where they are. They are
// still valid object keys and everything resolves them by the full key; only
// new uploads are foldered.
//
// The name is rebuilt rather than trusted. A phone hands over whatever the
// file is called — spaces, brackets, Burmese, a leading dot, `../` if someone
// is trying — and an object key is a path. Keeping only a known alphabet and
// prefixing a timestamp also makes two uploads of `VID_0001.mp4` two objects
// instead of one overwriting the other.
function safeKey(prefix: string, filename: string, folder?: string): string {
  const dot = filename.lastIndexOf('.');
  const stem = (dot > 0 ? filename.slice(0, dot) : filename)
    .toLowerCase().replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '').slice(0, 60) || 'file';
  const ext = (dot > 0 ? filename.slice(dot + 1) : '')
    .toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 8);
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const rand = crypto.randomUUID().slice(0, 8);
  const name = `${stamp}-${stem}-${rand}${ext ? '.' + ext : ''}`;
  // `slugify` again on the way past, even though the folder came from this
  // same file: it arrives over HTTP from a page, and a folder is the first
  // half of a path.
  const dir = slugifyPath(folder ?? '');
  return dir ? `${dir}/${prefix}/${name}` : `${prefix}/${name}`;
}

/// The one shape allowed in a path segment.
///
/// Shared by the folder and the file name so a name cannot be legal in one
/// and a traversal in the other. Burmese, spaces, brackets and `../` all
/// reduce to hyphens; an empty result is the caller's problem to handle,
/// because silently inventing a name is how two titles end up in one folder.
function slugify(raw: string): string {
  return String(raw ?? '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
}

/// A folder the operator chose, which may be nested.
///
/// `slugify` alone cannot be used for this: it turns `/` into a hyphen, so
/// `movies/spiderman` would become the single folder `movies-spiderman` and
/// the operator's choice of shelf would silently vanish. This slugifies each
/// SEGMENT and rejoins, which keeps the nesting and still makes `../` and a
/// leading `/` impossible — `..` slugifies to nothing and an empty segment is
/// dropped.
///
/// Depth is capped at three. Not because anything breaks deeper, but because
/// a path nobody can hold in their head is a path files get lost in, and R2's
/// console is a prefix browser rather than a tree.
function slugifyPath(raw: string): string {
  return String(raw ?? '')
    .split('/')
    .map(slugify)
    .filter(Boolean)
    .slice(0, 3)
    .join('/');
}

/// A folder name no other title is using.
///
/// Suffixed rather than randomised, because the folder is the thing an
/// operator reads in the R2 console: `solar-2` says what it is, and
/// `solar-f3a91c` does not. Falls back to a timestamp when the title has no
/// latin characters at all — a Burmese-only name slugifies to nothing.
async function uniqueFolder(
  db: ReturnType<typeof createClient>,
  title: string,
): Promise<string> {
  const base = slugify(title) ||
    `title-${new Date().toISOString().slice(0, 10).replace(/-/g, '')}`;
  for (let n = 1; n <= 50; n++) {
    const candidate = n === 1 ? base : `${base}-${n}`;
    const { data } = await db.from('titles')
      .select('id').eq('slug', candidate).maybeSingle();
    if (!data) return candidate;
  }
  // Fifty collisions means something is wrong with the loop, not with the
  // catalogue. A random suffix always terminates.
  return `${base}-${crypto.randomUUID().slice(0, 6)}`;
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

  // ═══════════════════════════════════════════════════════════════════════
  // THE CONSOLE API
  //
  // Every op below runs as the SERVICE ROLE once `operatorId()` above has
  // said yes. That is deliberate and is the whole security model of this
  // file: `titles` and `title_assets` are not writable by `authenticated`
  // and must not become writable, because widening RLS to let any signed-in
  // user edit the catalogue would be a far larger hole than one function
  // checking a list of two people.
  //
  // So: the gate is ONE function, at the top, and nothing below it re-checks.
  // If an op is added, it is behind that gate automatically. If the gate is
  // ever removed, everything below it falls open at once — which is why it is
  // written as an early return and not as a flag.
  // ═══════════════════════════════════════════════════════════════════════

  const admin = () => createClient(SUPABASE_URL, SERVICE_KEY);

  // Columns the console reads for ONE title. Not `*`: `locator` is in here on
  // purpose (the operator must be able to see and fix a wrong key) but that
  // is exactly why this list is written out — so adding a column to `titles`
  // never silently starts shipping it to a browser.
  const TITLE_COLS =
    'id,title,title_mm,synopsis,category,poster_url,year,rating,quality_label,' +
    'genres,keywords,episode_count,view_count,access_tier,photo_count,' +
    'video_count,is_featured,locator,provider,published,status,slug,created_at';

  // --- sign: hand back one presigned PUT URL -------------------------------
  //
  // THREE KINDS, not two. `thumb` is new and is what fixes the album grid: a
  // video has no picture of its own, so `title_media` used to fall back to the
  // title's poster, and a title with six clips drew the same image six times.
  // The page now grabs a frame from each video with a <canvas> and uploads it
  // here, into the PUBLIC bucket like any other still — a thumbnail is an
  // advertisement for the clip, not the clip.
  if (body.op === 'sign') {
    const filename = String(body.filename ?? '');
    if (!filename) return json({ error: 'no_filename' }, 400, req);

    const kind = body.kind === 'photo' ? 'photo'
      : body.kind === 'thumb' ? 'thumb'
      : 'video';

    // A SINGLE PUT IS STILL CAPPED AT 5 GiB, and the refusal stays — but it is
    // no longer the end of the road. Multipart is built now (see
    // beginMultipart below), so the page uses it for anything large and this
    // path only ever sees small files. The check remains because a page held in
    // a browser cache predates multipart and would otherwise upload for forty
    // minutes and fail with a CORS error: R2 does not attach CORS headers to
    // its error responses, which is the single worst failure mode available.
    const size = Number(body.size ?? 0);
    if (size > 0 && size > 5 * 1024 * 1024 * 1024) {
      return json({
        error: 'too_large',
        detail: 'A single upload is limited to 5 GiB. Reload this page — the ' +
          'current console uploads large files in parts and has no such limit.',
      }, 413, req);
    }

    const bucket = kind === 'video' ? MEDIA_BUCKET : PUBLIC_BUCKET;
    const prefix = kind === 'video' ? 'video' : kind === 'thumb' ? 'thumb' : 'photo';
    // No folder means a caller that predates foldering. It still works and
    // still lands in `video/…` — it simply has no title prefix. Refusing it
    // would break a page held in a browser cache for the sake of tidiness.
    const objectKey = safeKey(prefix, filename, String(body.folder ?? ''));

    return json({
      uploadUrl: await presignPut(bucket, objectKey),
      bucket,
      objectKey,
      kind,
      // Only meaningful for the public bucket; the media bucket is reached
      // through request-playback, never by a direct URL.
      publicUrl: kind === 'video' ? null : `${PUBLIC_BASE}/${objectKey}`,
    }, 200, req);
  }

  // --- multipart: one upload, many parts, each retryable on its own ---------
  //
  // ═══════════════════════════════════════════════════════════════════════
  // WHAT THIS IS ACTUALLY FOR, WHICH IS NOT THE 5 GiB CAP
  // ═══════════════════════════════════════════════════════════════════════
  //
  // The cap was the visible problem: a 4K master over 5 GiB could not be
  // uploaded at all. The problem that costs the operator their evening is a
  // different one — a single PUT of three gigabytes that fails at ninety per
  // cent starts again from zero, and on a Myanmar uplink that is hours of
  // someone's life and their data allowance, twice. Multipart makes each part
  // its own transfer with its own retry, so a dropped connection costs one part
  // and not the file.
  //
  // THREE OPS AND NOT ONE, because the browser holds the bytes and must upload
  // them directly to R2 — routing gigabytes through an edge function would be
  // slower, would cost money and would put the media through a process that has
  // no business holding it. So: this function begins and completes the upload
  // (both need S3 XML, which a browser should not be composing), and hands out
  // presigned URLs for the parts themselves.
  if (body.op === 'beginMultipart') {
    const filename = String(body.filename ?? '');
    if (!filename) return json({ error: 'no_filename' }, 400, req);
    const kind = body.kind === 'photo' ? 'photo'
      : body.kind === 'thumb' ? 'thumb'
      : 'video';
    const bucket = kind === 'video' ? MEDIA_BUCKET : PUBLIC_BUCKET;
    const prefix = kind === 'video' ? 'video' : kind === 'thumb' ? 'thumb' : 'photo';
    const objectKey = safeKey(prefix, filename, String(body.folder ?? ''));

    const signed = await signRequest('POST', bucket, objectKey, { uploads: '' }, '');
    const res = await fetch(signed.url, { method: 'POST', headers: signed.headers });
    const xml = await res.text();
    if (!res.ok) {
      return json({ error: 'begin_failed', status: res.status,
        detail: xmlTag(xml, 'Message') ?? xml.slice(0, 200) }, 502, req);
    }
    const uploadId = xmlTag(xml, 'UploadId');
    if (!uploadId) {
      return json({ error: 'no_upload_id', detail: xml.slice(0, 200) }, 502, req);
    }
    return json({ uploadId, bucket, objectKey, kind,
      publicUrl: kind === 'video' ? null : `${PUBLIC_BASE}/${objectKey}` }, 200, req);
  }

  // --- signParts: URLs for a BATCH of parts, not all of them ----------------
  //
  // A presigned URL lives an hour. A four-gigabyte file is sixty-four parts,
  // and on the connection this exists for the last of them may be uploaded
  // three hours after the first — so signing all sixty-four up front hands the
  // operator a set of URLs that expire underneath them, with the failure landing
  // at part forty for no visible reason. The page asks for the next handful as
  // it goes, and each batch is fresh.
  if (body.op === 'signParts') {
    const objectKey = String(body.objectKey ?? '');
    const uploadId = String(body.uploadId ?? '');
    if (!isMintedKey(objectKey)) return json({ error: 'bad_key' }, 400, req);
    if (!uploadId) return json({ error: 'no_upload_id' }, 400, req);
    const kind = body.kind === 'photo' ? 'photo'
      : body.kind === 'thumb' ? 'thumb'
      : 'video';
    const bucket = kind === 'video' ? MEDIA_BUCKET : PUBLIC_BUCKET;

    const from = Math.max(1, Math.floor(Number(body.from ?? 1)));
    // Bounded so one call cannot be turned into ten thousand signatures.
    const count = Math.min(32, Math.max(1, Math.floor(Number(body.count ?? 8))));
    const urls: Array<{ partNumber: number; url: string }> = [];
    for (let n = from; n < from + count; n++) {
      if (n > 10000) break; // S3's own ceiling on part numbers.
      urls.push({ partNumber: n, url: await presignPut(bucket, objectKey, {
        partNumber: String(n), uploadId,
      }) });
    }
    return json({ parts: urls, expiresIn: EXPIRY_SECONDS }, 200, req);
  }

  if (body.op === 'completeMultipart') {
    const objectKey = String(body.objectKey ?? '');
    const uploadId = String(body.uploadId ?? '');
    if (!isMintedKey(objectKey)) return json({ error: 'bad_key' }, 400, req);
    if (!uploadId) return json({ error: 'no_upload_id' }, 400, req);
    const kind = body.kind === 'photo' ? 'photo'
      : body.kind === 'thumb' ? 'thumb'
      : 'video';
    const bucket = kind === 'video' ? MEDIA_BUCKET : PUBLIC_BUCKET;

    const raw = Array.isArray(body.parts) ? body.parts : [];
    if (!raw.length) return json({ error: 'no_parts' }, 400, req);
    // SORTED HERE, whatever order they arrived in. S3 requires ascending part
    // numbers and rejects the whole upload otherwise — and the page uploads
    // sequentially today, which is exactly the kind of thing a later change to
    // parallel uploads would break silently.
    const parts = raw
      .map((p) => {
        const o = (p ?? {}) as Record<string, unknown>;
        return {
          n: Math.floor(Number(o.partNumber ?? 0)),
          // The ETag comes back quoted and S3 wants it back quoted. Normalised
          // to one form so it cannot be sent doubly quoted or bare.
          etag: String(o.etag ?? '').replace(/^"+|"+$/g, ''),
        };
      })
      .filter((p) => p.n >= 1 && p.etag)
      .sort((a, b) => a.n - b.n);
    if (parts.length !== raw.length) return json({ error: 'bad_parts' }, 400, req);

    const xmlBody = '<CompleteMultipartUpload>' +
      parts.map((p) =>
        `<Part><PartNumber>${p.n}</PartNumber><ETag>"${p.etag}"</ETag></Part>`)
        .join('') +
      '</CompleteMultipartUpload>';

    const signed = await signRequest(
      'POST', bucket, objectKey, { uploadId }, xmlBody);
    const res = await fetch(signed.url, {
      method: 'POST',
      headers: { ...signed.headers, 'Content-Type': 'application/xml' },
      body: xmlBody,
    });
    const xml = await res.text();
    // S3 CAN ANSWER 200 AND STILL HAVE FAILED. CompleteMultipartUpload streams
    // its response, so an error that happens after the headers arrives as an
    // <Error> document inside a 200. Checking the body is not belt and braces
    // here; it is the only way to know.
    if (!res.ok || xml.includes('<Error>')) {
      return json({ error: 'complete_failed', status: res.status,
        detail: xmlTag(xml, 'Message') ?? xml.slice(0, 200) }, 502, req);
    }
    return json({ ok: true, bucket, objectKey,
      publicUrl: kind === 'video' ? null : `${PUBLIC_BASE}/${objectKey}` }, 200, req);
  }

  // --- abortMultipart: the tidying that stops an abandoned upload billing ---
  //
  // Parts that were uploaded and never completed sit in the bucket, invisible
  // to every listing and charged for by the gigabyte-month. An operator who
  // closes the tab halfway through a four-gigabyte master would otherwise pay
  // for it every month until somebody thought to look.
  if (body.op === 'abortMultipart') {
    const objectKey = String(body.objectKey ?? '');
    const uploadId = String(body.uploadId ?? '');
    if (!isMintedKey(objectKey)) return json({ error: 'bad_key' }, 400, req);
    if (!uploadId) return json({ error: 'no_upload_id' }, 400, req);
    const bucket = body.kind === 'photo' || body.kind === 'thumb'
      ? PUBLIC_BUCKET : MEDIA_BUCKET;
    const signed = await signRequest(
      'DELETE', bucket, objectKey, { uploadId }, '');
    const res = await fetch(signed.url,
      { method: 'DELETE', headers: signed.headers });
    // A failed abort is reported and not thrown: the upload is already
    // abandoned, and the operator needs to know the parts may still be there
    // rather than to be given an error about a thing they did not ask for.
    return json({ ok: res.ok, status: res.status }, 200, req);
  }

  // --- folder: SUGGEST a free prefix --------------------------------------
  //
  // Suggests one from a title and guarantees uniqueness by appending a
  // number. Kept for callers that want a name chosen for them; the console
  // asks the operator instead and validates with `checkFolder`.
  //
  // Reserving is not locking. Two operators creating "Solar" in the same
  // minute would both be handed `solar`, and the second `create` would then
  // fail on the unique slug. With an OPERATOR_IDS list of one that is a
  // theoretical problem, and the honest fix is a real reservation table, not
  // a comment claiming this is safe.
  if (body.op === 'folder') {
    if (!SERVICE_KEY) return json({ error: 'no_service_key' }, 500, req);
    const wanted = String(body.title ?? '').trim();
    if (!wanted) return json({ error: 'no_title' }, 400, req);
    return json({ folder: await uniqueFolder(admin(), wanted) }, 200, req);
  }

  // --- checkFolder: is the name the operator typed free? ------------------
  //
  // SEPARATE FROM `folder`, and the difference is who decides. That one
  // suggests; this one takes a name the operator chose and answers yes or no
  // — because silently turning their `spiderman` into `spiderman-2` would put
  // the files somewhere they did not ask for and would not think to look.
  //
  // Answers with what the key will actually be, so the page can show the real
  // path rather than the operator's draft of it: `Spider Man /Movies` becomes
  // `spider-man/movies` before anything is uploaded, and seeing that before
  // committing is the whole point.
  if (body.op === 'checkFolder') {
    if (!SERVICE_KEY) return json({ error: 'no_service_key' }, 500, req);
    const wanted = slugifyPath(String(body.folder ?? ''));
    if (!wanted) return json({ ok: false, reason: 'empty', folder: '' }, 200, req);

    const { data } = await admin().from('titles')
      .select('id, title').eq('slug', wanted).maybeSingle();
    return json({
      ok: !data,
      folder: wanted,
      // Naming the occupant rather than just refusing: "taken" sends an
      // operator hunting through the catalogue; "taken by Spider-Man (2019)"
      // usually ends the question.
      takenBy: data ? String((data as Record<string, unknown>).title ?? '') : null,
      preview: {
        video: `${MEDIA_BUCKET}/${wanted}/video/…`,
        photo: `${PUBLIC_BUCKET}/${wanted}/photo/…`,
        thumb: `${PUBLIC_BUCKET}/${wanted}/thumb/…`,
      },
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

  if (!SERVICE_KEY) return json({ error: 'no_service_key' }, 500, req);

  // --- list: the catalogue, including drafts -------------------------------
  //
  // Drafts INCLUDED, which is the point of an operator view: `title_cards` and
  // every client path filter on `published`, so a half-finished title is
  // invisible everywhere else. This is the only screen that can see one, and
  // therefore the only screen from which one can be finished.
  if (body.op === 'list') {
    const q = String(body.q ?? '').trim();
    let sel = admin().from('titles').select(TITLE_COLS)
      .order('created_at', { ascending: false })
      .limit(Math.min(Number(body.limit ?? 100), 500));

    if (body.status === 'draft') sel = sel.eq('published', false);
    if (body.status === 'published') sel = sel.eq('published', true);
    if (body.category) sel = sel.eq('category', String(body.category));
    // Quoted: a comma or a parenthesis in the search text would otherwise
    // rewrite the or-group rather than be matched by it. Stripped rather than
    // escaped for the same reason api_content_repository.dart strips them —
    // escaping inside a quoted value varies between PostgREST versions.
    if (q) {
      const safe = q.replace(/["\\,()]/g, '');
      if (safe) sel = sel.or(`title.ilike."*${safe}*",title_mm.ilike."*${safe}*"`);
    }

    const { data, error } = await sel;
    if (error) return json({ error: 'list_failed', detail: error.message }, 500, req);
    return json({ titles: data ?? [] }, 200, req);
  }

  // --- get: one title and everything attached to it ------------------------
  if (body.op === 'get') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const db = admin();

    const { data: title, error: tErr } = await db
      .from('titles').select(TITLE_COLS).eq('id', id).maybeSingle();
    if (tErr) return json({ error: 'get_failed', detail: tErr.message }, 500, req);
    if (!title) return json({ error: 'not_found' }, 404, req);

    // A TITLE WITHOUT A FOLDER GETS ONE HERE, which is a write inside a read
    // and is deliberate. Every title created before foldering has a null (or
    // a legacy filename) in `slug`, and "Add files" needs a folder BEFORE it
    // can sign anything. Doing it lazily on first open means no backfill
    // migration and no title that can silently keep scattering files into the
    // flat prefixes. Existing objects are not moved — see safeKey.
    let folder = slugifyPath(String(title.slug ?? ''));
    if (!folder) {
      folder = await uniqueFolder(db, String(title.title ?? ''));
      await db.from('titles').update({ slug: folder }).eq('id', id);
      title.slug = folder;
    }

    const { data: assets, error: aErr } = await db
      .from('title_assets')
      .select('id,kind,bucket,object_key,thumb_key,is_primary,is_free,' +
        'sort_order,label,language,duration_s,width,height,bytes,mime,added_at')
      .eq('title_id', id)
      // SORT_ORDER FIRST, NOT KIND. The app asks title_media for
      // `order=sort_order.asc` and draws photos and clips interleaved in that
      // one sequence. Grouping by kind here would show the operator a list
      // that is not the list they are reordering — every drag would land
      // somewhere other than where it looked like it would.
      .order('sort_order').order('kind');
    if (aErr) return json({ error: 'assets_failed', detail: aErr.message }, 500, req);

    return json({
      title,
      folder,
      // The page needs the base to draw a thumbnail from an object key. It is
      // public information — it is already compiled into every APK — but
      // sending it beats hard-coding the same string in a second file where
      // the two can drift.
      publicBase: PUBLIC_BASE,
      assets: assets ?? [],
    }, 200, req);
  }

  // --- create: a new title, with as many files as were uploaded ------------
  //
  // `publish` is kept as an alias because an operator's browser may still be
  // holding the previous version of the page from cache, and a stale page that
  // silently stops working is worse than one that looks old.
  if (body.op === 'create' || body.op === 'publish') {
    const title = String(body.title ?? '').trim();
    if (!title) return json({ error: 'no_title' }, 400, req);

    // The page sends a flat list now. The old page sent `video` and `photo`
    // singletons; both shapes are accepted so neither version of the page is
    // broken by a deploy.
    const incoming = Array.isArray(body.assets)
      ? (body.assets as Record<string, unknown>[])
      : [
          ...(body.video ? [{ ...(body.video as object), kind: 'video' }] : []),
          ...(body.photo ? [{ ...(body.photo as object), kind: 'photo' }] : []),
        ];
    if (incoming.length === 0) return json({ error: 'no_assets' }, 400, req);

    const db = admin();
    const wantPublished = body.publish === true;

    // `locator` and `poster_url` are MAINTAINED DENORMALISATIONS: a trigger on
    // title_assets rewrites both from whichever asset is primary. They are set
    // here as well, rather than left null for the trigger, because the trigger
    // fires on the asset insert that happens a line later and a row that is
    // briefly published with no locator is a row a client can briefly fetch.
    const firstVideo = incoming.find((a) => normKind(a.kind) !== 'photo');
    const firstPhoto = incoming.find((a) => normKind(a.kind) === 'photo');

    const { data: row, error: titleErr } = await db.from('titles').insert({
      title,
      title_mm: str(body.titleMm),
      synopsis: str(body.synopsis),
      category: String(body.category ?? 'movies'),
      year: num(body.year),
      rating: num(body.rating),
      quality_label: str(body.quality),
      genres: arr(body.genres),
      // SEARCHABLE, NEVER RENDERED. `genres` draws the chips on the card and
      // fills the filter bar; these are the words people actually type —
      // alternate spellings, a Burmese transliteration, an actor's name —
      // which would clutter the card and must still find the title.
      keywords: arr(body.keywords),
      episode_count: num(body.episodes),
      // THE FOLDER THE OPERATOR CHOSE. Every object key of this title begins
      // with it, so it is not decoration: `addAssets` reads it back to put
      // later files in the same place, and the R2 console is browsable by it.
      slug: slugifyPath(String(body.folder ?? '')) || null,
      access_tier: body.free === true ? 'free' : 'premium',
      is_featured: body.featured === true,
      locator: firstVideo ? String(firstVideo.objectKey ?? '') : null,
      provider: 'r2',
      poster_url: firstPhoto ? `${PUBLIC_BASE}/${firstPhoto.objectKey}` : null,
      // Draft until the operator says otherwise. Publishing by default is how
      // a half-uploaded title reaches a paying customer.
      status: wantPublished ? 'published' : 'draft',
      published: wantPublished,
    }).select('id').single();

    // `!row` as well as the error: `.single()` types its data as possibly
    // null, and an error check alone does not narrow it, so `row.id` below
    // would be a type error under the strict settings Deno applies.
    if (titleErr || !row) {
      return json({ error: 'title_insert', detail: titleErr?.message ?? 'no row' }, 500, req);
    }

    // EXACTLY ONE PRIMARY PHOTO AND ONE PRIMARY VIDEO, chosen here when the
    // page did not choose. The primary photo is what the trigger writes into
    // `poster_url` and the primary video is what it writes into `locator`, so
    // a title created with neither has a card the app cannot draw and a film
    // request-playback cannot sign. A partial unique index refuses a SECOND
    // primary, which is why this marks at most one of each rather than all.
    const rows = incoming.map((a, i) => assetRow(String(row.id), a, i));
    if (!rows.some((r) => r.kind === 'photo' && r.is_primary)) {
      const first = rows.find((r) => r.kind === 'photo');
      if (first) first.is_primary = true;
    }
    if (!rows.some((r) => r.kind !== 'photo' && r.is_primary)) {
      const first = rows.find((r) => r.kind !== 'photo');
      if (first) first.is_primary = true;
    }

    const ins = await db.from('title_assets').insert(rows);
    if (ins.error) {
      return json({ error: 'asset_insert', detail: ins.error.message }, 500, req);
    }

    return json({ id: row.id, title, status: wantPublished ? 'published' : 'draft' }, 200, req);
  }

  // --- save: edit everything about an existing title -----------------------
  //
  // PATCH SEMANTICS, not replace: only keys actually present in the request
  // are written. A page that sent the whole row back would overwrite a field
  // it did not render — and the first field to be forgotten would be
  // `view_count`, which nothing should ever be able to reset by accident.
  if (body.op === 'save') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);

    const p = (body.patch ?? {}) as Record<string, unknown>;
    const upd: Record<string, unknown> = {};
    if ('title' in p) upd.title = String(p.title ?? '').trim();
    if ('title_mm' in p) upd.title_mm = str(p.title_mm);
    if ('synopsis' in p) upd.synopsis = str(p.synopsis);
    if ('category' in p) upd.category = String(p.category ?? 'movies');
    if ('year' in p) upd.year = num(p.year);
    if ('rating' in p) upd.rating = num(p.rating);
    if ('quality_label' in p) upd.quality_label = str(p.quality_label);
    if ('genres' in p) upd.genres = arr(p.genres);
    if ('keywords' in p) upd.keywords = arr(p.keywords);
    if ('episode_count' in p) upd.episode_count = num(p.episode_count);
    if ('access_tier' in p) {
      upd.access_tier = p.access_tier === 'free' ? 'free' : 'premium';
    }
    if ('is_featured' in p) upd.is_featured = p.is_featured === true;
    if ('locator' in p) upd.locator = str(p.locator);
    if ('published' in p) {
      upd.published = p.published === true;
      // `status` and `published` are two columns saying one thing, and the
      // catalogue_health view reads `status` while every client path reads
      // `published`. Writing one without the other is how they disagree.
      upd.status = p.published === true ? 'published' : 'draft';
    }
    if (Object.keys(upd).length === 0) return json({ error: 'empty_patch' }, 400, req);
    if ('title' in upd && !upd.title) return json({ error: 'no_title' }, 400, req);

    const { error } = await admin().from('titles').update(upd).eq('id', id);
    if (error) return json({ error: 'save_failed', detail: error.message }, 500, req);
    return json({ ok: true, id, changed: Object.keys(upd) }, 200, req);
  }

  // --- addAssets: more files onto a title that already exists --------------
  //
  // THE OPERATION THE OLD PAGE COULD NOT DO AT ALL, and the reason a card
  // could never hold more than one video and one photo. The database has
  // supported many since the title_assets table was written; only the uploader
  // did not.
  if (body.op === 'addAssets') {
    const id = String(body.titleId ?? '');
    const incoming = Array.isArray(body.assets)
      ? (body.assets as Record<string, unknown>[]) : [];
    if (!id) return json({ error: 'no_id' }, 400, req);
    if (incoming.length === 0) return json({ error: 'no_assets' }, 400, req);

    const db = admin();
    // Appended AFTER whatever is already there. Reading the current maximum
    // rather than counting rows: a deleted asset leaves a gap, and counting
    // would hand the new file a sort_order that is already taken.
    const { data: last } = await db.from('title_assets')
      .select('sort_order').eq('title_id', id)
      .order('sort_order', { ascending: false }).limit(1).maybeSingle();
    const base = (last?.sort_order ?? -1) + 1;

    const { error } = await db.from('title_assets')
      .insert(incoming.map((a, i) => assetRow(id, a, base + i)));
    if (error) return json({ error: 'asset_insert', detail: error.message }, 500, req);
    return json({ ok: true, added: incoming.length }, 200, req);
  }

  // --- updateAsset: order, label, free-preview, thumbnail, dimensions ------
  if (body.op === 'updateAsset') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);

    const p = (body.patch ?? {}) as Record<string, unknown>;
    const upd: Record<string, unknown> = {};
    if ('sort_order' in p) upd.sort_order = num(p.sort_order) ?? 0;
    if ('is_free' in p) upd.is_free = p.is_free === true;
    if ('label' in p) upd.label = str(p.label);
    if ('language' in p) upd.language = str(p.language);
    if ('thumb_key' in p) upd.thumb_key = str(p.thumb_key);
    if ('duration_s' in p) upd.duration_s = num(p.duration_s);
    if ('width' in p) upd.width = num(p.width);
    if ('height' in p) upd.height = num(p.height);
    // Added with the thumbnail tools. A video uploaded by the old page has
    // null for every one of these, and the console can now measure them from
    // the operator's local copy without re-uploading the video — so the
    // patch has to be able to carry them.
    if ('bytes' in p) upd.bytes = num(p.bytes);
    if ('mime' in p) upd.mime = str(p.mime);
    if (Object.keys(upd).length === 0) return json({ error: 'empty_patch' }, 400, req);

    const { error } = await admin().from('title_assets').update(upd).eq('id', id);
    if (error) return json({ error: 'update_failed', detail: error.message }, 500, req);
    return json({ ok: true, id }, 200, req);
  }

  // --- reorder: the whole sequence in one request -------------------------
  //
  // ONE CALL, NOT ONE PER TILE. Dragging a photo from position ten to
  // position one changes every row between them, and ten `updateAsset` calls
  // over a Myanmar mobile connection is ten chances to half-apply an order —
  // leaving the grid in a state neither the operator nor the app expects, with
  // no way to tell which half landed.
  //
  // Sent as the FULL sequence rather than a diff, because the page already
  // knows the whole order and a diff would need both sides to agree on what
  // changed. The last write wins, which is correct for a single operator and
  // honestly stated for the day there are two.
  if (body.op === 'reorder') {
    const items = Array.isArray(body.order)
      ? (body.order as Record<string, unknown>[]) : [];
    if (items.length === 0) return json({ error: 'no_order' }, 400, req);
    if (items.length > 500) return json({ error: 'too_many' }, 400, req);

    const db = admin();
    // Sequential rather than Promise.all: these are writes to one table and a
    // burst of five hundred concurrent updates is how a pooler runs out of
    // connections. The list is tens of rows, so the cost is milliseconds.
    let done = 0;
    for (const it of items) {
      const id = String(it.id ?? '');
      const order = num(it.sort_order);
      if (!id || order === null) continue;
      const { error } = await db.from('title_assets')
        .update({ sort_order: order }).eq('id', id);
      if (error) {
        return json({
          error: 'reorder_failed',
          detail: error.message,
          // Says how far it got. A partial order is recoverable only if
          // somebody knows it happened.
          applied: done,
        }, 500, req);
      }
      done += 1;
    }
    return json({ ok: true, applied: done }, 200, req);
  }

  // --- setPrimary: which photo is the card, which video is the film --------
  //
  // Through the RPC that already exists rather than two UPDATEs from here.
  // `set_primary_asset()` clears the old primary and sets the new one inside
  // one statement, and a partial unique index refuses a second primary — so
  // doing it by hand from here would be the one path that could leave two.
  if (body.op === 'setPrimary') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const { error } = await admin().rpc('set_primary_asset', { asset_id: id });
    if (error) return json({ error: 'set_primary_failed', detail: error.message }, 500, req);
    return json({ ok: true, id }, 200, req);
  }

  // --- deleteAsset / deleteTitle -------------------------------------------
  //
  // THE R2 OBJECT IS LEFT WHERE IT IS, on purpose. Deleting a row is
  // recoverable — the file is still in the bucket and can be pointed at again.
  // Deleting the object is not, and an operator tapping the wrong row on a
  // phone is a thing that happens. Storage is a fraction of a cent per GB per
  // month; an unrecoverable video is a re-upload over a mobile connection.
  // Orphans are findable: an object key with no title_assets row — and now
  // also a folder in R2 with no matching `titles.slug`.
  if (body.op === 'deleteAsset') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const { error } = await admin().from('title_assets').delete().eq('id', id);
    if (error) return json({ error: 'delete_failed', detail: error.message }, 500, req);
    return json({ ok: true, id }, 200, req);
  }

  if (body.op === 'deleteTitle') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    // The name has to be typed back in the page before this is called. Not a
    // security measure — the caller is already an operator — but the one
    // interaction that reliably separates "delete this" from "I meant the row
    // above".
    if (String(body.confirm ?? '') !== 'DELETE') {
      return json({ error: 'not_confirmed' }, 400, req);
    }
    // title_assets cascades on the foreign key; title_views does not and is
    // deliberately left, because a deleted title's view history is still a
    // true record of what happened.
    const { error } = await admin().from('titles').delete().eq('id', id);
    if (error) return json({ error: 'delete_failed', detail: error.message }, 500, req);
    return json({ ok: true, id }, 200, req);
  }

  // --- the premium approval queue ------------------------------------------
  //
  // `docs/movies_gaps.md` §2 calls the missing operator side BLOCKING — "until
  // this exists, the product cannot take money". Every piece of it was already
  // in the database: the `pending_requests` view, `approve_request(id, days)`
  // and `reject_request(id, note)`. Nothing called them. These three ops are
  // the whole fix.
  //
  // The approval writes the subscription row and nothing else does — that is
  // the rule from premium_backend_spec.md and it is why this goes through the
  // RPC rather than inserting into `subscriptions` from here.
  if (body.op === 'requests') {
    const { data, error } = await admin()
      .from('pending_requests').select('*').order('submitted_at');
    if (error) return json({ error: 'requests_failed', detail: error.message }, 500, req);
    return json({ requests: data ?? [] }, 200, req);
  }

  if (body.op === 'approve') {
    const id = String(body.id ?? '');
    const days = Math.max(1, Math.min(Number(body.days ?? 365), 3650));
    if (!id) return json({ error: 'no_id' }, 400, req);
    const { error } = await admin()
      .rpc('approve_request', { p_request_id: id, p_days: days });
    if (error) return json({ error: 'approve_failed', detail: error.message }, 500, req);
    return json({ ok: true, id, days }, 200, req);
  }

  if (body.op === 'reject') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const { error } = await admin().rpc('reject_request', {
      p_request_id: id,
      p_note: str(body.note) ?? 'rejected by operator',
    });
    if (error) return json({ error: 'reject_failed', detail: error.message }, 500, req);
    return json({ ok: true, id }, 200, req);
  }

  // --- stats: proof that the event log is actually filling ----------------
  //
  // EXISTS TO BE VERIFIABLE FROM A PHONE. The event log's whole design is
  // that nothing on screen changes because of it — no counter moves, no row
  // reorders, nothing fails if it silently stops working. That is correct for
  // the app and terrible for the operator, who would have no way to tell a
  // working log from a dead one until the day they needed the data and found
  // three months of nothing.
  //
  // So this is the one surface that says "it is on". Four numbers, and the
  // geo breakdown in particular is worth watching: it is what says whether
  // `cf-ipcountry` reaches this project at all, which is the one assumption
  // in migration 014 that could not be checked from a SQL console.
  //
  // START-UP LATENCY LEADS IT NOW. A user reported the player showing "Slow
  // connection — buffering…" for seconds on a 13 MB/s link, and there was no
  // way to tell whether that was everyone, one title or one evening. The
  // client now reports time-to-first-frame and `startup_latency` turns it
  // into percentiles — p95, not a mean, because a mean hides exactly the
  // tail that makes people stop opening the app.
  if (body.op === 'stats') {
    const db = admin();
    const since = new Date(Date.now() - 7 * 86400_000).toISOString();

    const [kinds, geo, gaps, trend, startup, slowest, health] =
      await Promise.all([
      db.from('events').select('kind').gte('occurred_at', since).limit(5000),
      db.from('event_geo').select('geo_trust, audience')
        .gte('occurred_at', since).limit(5000),
      db.from('search_gaps').select('*').limit(25),
      db.rpc('trending_titles', { p_limit: 10 }),
      // How long viewers stare at black before a video starts. The only
      // answer to "it feels slow" that can be argued with.
      db.rpc('startup_latency', { p_days: 7 }),
      db.rpc('startup_by_title', { p_days: 7, p_limit: 8 }),
      // Assets that look fine and are not — chiefly videos with no
      // thumbnail of their own, which have been drawing the title poster.
      db.from('media_health').select('*').limit(500),
    ]);

    const rows = Array.isArray(health.data)
      ? (health.data as Record<string, unknown>[]) : [];
    const countWhere = (f: string) => rows.filter((r) => r[f] === true).length;

    // Counted here rather than in SQL because PostgREST has no group-by and
    // adding an RPC for two tallies over at most five thousand rows is more
    // moving parts than it saves.
    const tally = (rows: unknown, field: string): Record<string, number> => {
      const out: Record<string, number> = {};
      for (const r of (Array.isArray(rows) ? rows : [])) {
        const k = String((r as Record<string, unknown>)[field] ?? '?');
        out[k] = (out[k] ?? 0) + 1;
      }
      return out;
    };

    return json({
      since,
      // Capped at 5000 above, so say so rather than letting a plateau at
      // exactly 5000 read as a suspiciously round week.
      capped: (kinds.data?.length ?? 0) >= 5000,
      kinds: tally(kinds.data, 'kind'),
      geo_trust: tally(geo.data, 'geo_trust'),
      audience: tally(geo.data, 'audience'),
      search_gaps: gaps.data ?? [],
      trending: trend.data ?? [],
      startup: startup.data ?? [],
      slowest_titles: slowest.data ?? [],
      media_health: {
        total: rows.length,
        borrows_poster: countWhere('borrows_poster'),
        no_dimensions: countWhere('no_dimensions'),
        no_duration: countWhere('no_duration'),
        no_size: countWhere('no_size'),
        // The worst offenders by name, so the operator can go straight to
        // the title rather than hunting for which one the number meant.
        worst: rows
          .filter((r) => r.borrows_poster === true)
          .slice(0, 12)
          .map((r) => ({ title: r.title, kind: r.kind, id: r.title_id })),
      },
      error: kinds.error?.message ?? geo.error?.message ?? null,
    }, 200, req);
  }

  // --- categories: rename a tab without shipping an app -------------------
  //
  // THE id IS NOT EDITABLE HERE AND MUST NEVER BECOME EDITABLE. It is what
  // `titles.category` stores, what analytics group by and what a saved tab
  // selection holds; changing one orphans every title that used it. The
  // label, the order and the visibility are the editable half, and between
  // them they are the whole feature — renaming "Movies" to "Video" is one
  // UPDATE and takes effect on the next app launch.
  //
  // ADDING ONE IS POSSIBLE NOW, and the note that used to sit here saying it
  // was not was accurate when it was written: the client keyed off a Dart enum,
  // so no row this wrote could make a build draw a tab it had never heard of.
  // Three things had to change and all three have — the CHECK constraint on
  // titles.category became a foreign key to this table (migration 020), the
  // landing page learned to honour is_visible (020), and the app's tab bar
  // stopped being an exhaustive enum (CategoryRef). An insert here produces a
  // tab on the next launch.
  if (body.op === 'categories') {
    const { data, error } = await admin()
      .from('categories').select('*').order('sort_order');
    if (error) return json({ error: 'categories_failed', detail: error.message }, 500, req);
    return json({ categories: data ?? [] }, 200, req);
  }

  if (body.op === 'saveCategory') {
    const id = String(body.id ?? '').trim();
    if (!id) return json({ error: 'no_id' }, 400, req);

    const p = (body.patch ?? {}) as Record<string, unknown>;
    const upd: Record<string, unknown> = { updated_at: new Date().toISOString() };
    if ('label' in p) upd.label = String(p.label ?? '').trim();
    if ('label_mm' in p) upd.label_mm = str(p.label_mm);
    if ('sort_order' in p) upd.sort_order = num(p.sort_order) ?? 0;
    if ('is_visible' in p) upd.is_visible = p.is_visible === true;
    // A blank label would render an empty pill in the tab bar, which reads as
    // a broken build rather than as a mistake somebody made in a form.
    if ('label' in upd && !upd.label) return json({ error: 'no_label' }, 400, req);

    const { error } = await admin()
      .from('categories').update(upd).eq('id', id);
    if (error) return json({ error: 'save_failed', detail: error.message }, 500, req);
    return json({ ok: true, id, changed: Object.keys(upd) }, 200, req);
  }

  // --- addCategory: a new section, without an app release
  //
  // THE ID IS THE ONE THING THAT CANNOT BE FIXED LATER. It is what
  // `titles.category` stores for every film put in this section, so renaming it
  // means rewriting all of them; the label is what people see and can be
  // changed whenever. So the id is validated strictly and the label is not:
  // lower-case letters, digits and hyphens, which is what survives a URL, a
  // filter query and a log line unchanged.
  //
  // `all` is refused explicitly. It is the landing TAB and the database has a
  // constraint saying no title may be in it, so a row for it would create a
  // section that can never contain anything.
  if (body.op === 'addCategory') {
    const id = String(body.id ?? '').trim().toLowerCase();
    const label = String(body.label ?? '').trim();
    if (!/^[a-z0-9-]{2,32}$/.test(id)) {
      return json({ error: 'bad_id', detail:
        'lower-case letters, digits and hyphens, 2 to 32 characters' }, 400, req);
    }
    if (id === 'all') return json({ error: 'reserved_id' }, 400, req);
    // A blank label would render an empty pill, which reads as a broken build
    // rather than as a form somebody left half-filled.
    if (!label) return json({ error: 'no_label' }, 400, req);

    const row: Record<string, unknown> = {
      id,
      label,
      label_mm: str(body.label_mm),
      sort_order: num(body.sort_order) ?? 0,
      is_visible: body.is_visible !== false,
      updated_at: new Date().toISOString(),
    };
    // INSERT AND NOT UPSERT. An operator typing an id that already exists has
    // almost certainly mistyped a new one, and silently overwriting the label
    // of a live section is a worse outcome than being told the name is taken.
    const { error } = await admin().from('categories').insert(row);
    if (error) {
      const taken = /duplicate key/i.test(error.message);
      return json({ error: taken ? 'id_taken' : 'add_failed',
        detail: error.message }, taken ? 409 : 500, req);
    }
    return json({ ok: true, id }, 200, req);
  }

  // --- health: the view that has existed unread since the schema was written
  if (body.op === 'health') {
    const { data, error } = await admin().from('catalogue_health').select('*');
    if (error) return json({ error: 'health_failed', detail: error.message }, 500, req);
    return json({ rows: data ?? [] }, 200, req);
  }

  return json({ error: 'unknown_op' }, 400, req);
});

// --- shaping what the browser sent -----------------------------------------
//
// Below the handler, not inside it, because these are pure and a reader
// chasing an op should not have to step over them first.

/// Empty string and whitespace become NULL, never ''.
///
/// A column holding '' and a column holding NULL look identical in the page
/// and behave differently everywhere else: `title_mm = ''` renders as a
/// nameless card, while NULL falls back to the English title. The app has a
/// guard for exactly this (`displayTitle` trims before deciding) — but a guard
/// in the client is not a reason to write bad rows.
function str(v: unknown): string | null {
  const s = String(v ?? '').trim();
  return s === '' ? null : s;
}

function num(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/// Accepts an array or a comma-separated string, because the tag field in the
/// page is a text input and a paste from anywhere is comma-separated.
function arr(v: unknown): string[] {
  const raw = Array.isArray(v) ? v.map((x) => String(x))
    : String(v ?? '').split(',');
  const out: string[] = [];
  for (const item of raw) {
    const s = item.trim();
    // De-duplicated case-insensitively: 'Drama' and 'drama' would otherwise
    // both reach the filter bar as separate chips selecting the same titles.
    if (s && !out.some((o) => o.toLowerCase() === s.toLowerCase())) out.push(s);
  }
  return out;
}

/// The four kinds `title_assets` accepts from this page.
///
/// Anything unrecognised becomes 'clip' rather than being rejected: a clip is
/// the kind with the fewest consequences — it is playable, it is not the
/// poster, and it is not the main film — so a future page sending a kind this
/// version has not heard of degrades instead of failing.
function normKind(v: unknown): string {
  const k = String(v ?? '').toLowerCase();
  return k === 'photo' || k === 'video' || k === 'trailer' ? k : 'clip';
}

/// One `title_assets` row from what the page measured and uploaded.
///
/// THE DIMENSIONS ARE THE POINT. They were null on every asset in the
/// catalogue, and two things downstream need them: the app's MediaMosaic sizes
/// each row of tiles from the aspect ratios in it — with nothing to read it
/// gives a portrait clip the same shape as a landscape still — and the
/// duration badge in the corner of a video tile simply never draws. The
/// browser has all three for free: a <video> exposes duration, videoWidth and
/// videoHeight once `loadedmetadata` fires, and an <img> exposes
/// naturalWidth/naturalHeight. No ffmpeg, no server work, no second pass.
function assetRow(
  titleId: string,
  a: Record<string, unknown>,
  order: number,
): Record<string, unknown> {
  const kind = normKind(a.kind);
  const isPhoto = kind === 'photo';
  return {
    title_id: titleId,
    kind,
    bucket: isPhoto ? PUBLIC_BUCKET : MEDIA_BUCKET,
    object_key: String(a.objectKey ?? ''),
    thumb_key: str(a.thumbKey),
    // `is_primary` is set only when the page asks. The partial unique index
    // refuses a second primary per title, so sending it on every row of a
    // twelve-file upload would fail the whole insert.
    is_primary: a.isPrimary === true,
    // A poster is the advertisement; it is never withheld. A video follows the
    // title's tier unless the operator marked it a free preview.
    is_free: isPhoto ? true : a.isFree === true,
    sort_order: num(a.sortOrder) ?? order,
    label: str(a.label),
    language: str(a.language),
    duration_s: num(a.durationS),
    width: num(a.width),
    height: num(a.height),
    bytes: num(a.bytes),
    mime: str(a.mime),
  };
}
