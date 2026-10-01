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

// WHO MAY USE THE CONSOLE is no longer a list here. It was OPERATOR_IDS — one
// user id, copied into four functions — and it could not say what each person
// may do. It is the `admins` table now (migration 026), read on every request
// by the admin gate below.

// Where a console sign-in is announced: the owner's own Telegram chat, by the
// same bot that answers forwarded films. Both are project-wide secrets already
// set for `ingest`; if either is absent the announcement is skipped and
// nothing else changes.
const BOT_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const TG_CHATS = (Deno.env.get('TELEGRAM_CHAT_IDS') ?? '')
  .split(',').map((s) => s.trim()).filter(Boolean);

const EXPIRY_SECONDS = 3600; // An hour: a long video on a Myanmar connection.

// The streaming Worker, for the review page's preview. The same two values
// request-playback mints viewers' tokens from, so an admin previews a film
// over the path a viewer will watch it on. Absent, the preview falls back to
// a presigned GET straight from R2.
const STREAM_BASE = (Deno.env.get('STREAM_BASE') ?? '').replace(/\/+$/, '');
const STREAM_TOKEN_SECRET = Deno.env.get('STREAM_TOKEN_SECRET') ?? '';

/// Where the console links to from a Telegram notice.
const CONSOLE_URL = 'https://yannmh007.github.io/innocent/studio/';

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
  method: string = 'PUT',
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
    // A caller may ask for a shorter life (the review preview does); the
    // default is the hour an upload part needs.
    'X-Amz-Expires': extraQuery['X-Amz-Expires'] ?? String(EXPIRY_SECONDS),
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
    method,
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

///
/// `extra` headers are signed and sent as well — CopyObject's
/// `x-amz-copy-source` must be, or R2 cannot tell a copy from an empty PUT.
/// An empty `objectKey` addresses the bucket itself (a listing).
async function signRequest(
  method: string,
  bucket: string,
  objectKey: string,
  query: Record<string, string>,
  body: string,
  extra: Record<string, string> = {},
): Promise<SignedReq> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;
  const payloadHash = await sha256HexOf(body);

  const canonicalQuery = Object.keys(query).sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(query[k])}`).join('&');
  const canonicalPath = objectKey
    ? `/${bucket}/${encodeKey(objectKey)}`
    : `/${bucket}`;

  // SORTED AND LOWER-CASE, and the list below must match the headers actually
  // sent, exactly. A header in SignedHeaders that is not sent, or sent with
  // different whitespace, is a signature failure with no diagnostic.
  const all: Record<string, string> = {
    host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
  };
  for (const [k, v] of Object.entries(extra)) all[k.toLowerCase()] = String(v).trim();
  const names = Object.keys(all).sort();
  const canonicalHeaders = names.map((k) => `${k}:${all[k]}\n`).join('');
  const signedHeaders = names.join(';');

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
      ...Object.fromEntries(Object.entries(extra).map(([k, v]) => [k.toLowerCase(), String(v).trim()])),
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

// ── ADMIN GATE (begin) ───────────────────────────────────────────────────
//
// WHO IS ASKING, AND WHAT MAY THEY DO. The same block, byte for byte, in
// studio.ts, ingest.ts, transcode.ts and probe-media.ts — tool/js/
// admin_gate_test.mjs fails the build if the four copies ever differ. It
// replaces four copies of a one-person OPERATOR_IDS list, which could not say
// what each person may do, could not change without a deploy, and recorded
// nothing about who did what.
//
// THE TOKEN IS CHECKED BY ASKING THE AUTH SERVER, not by verifying a signature
// here: that needs no second copy of the JWT secret and is right about expiry
// and revocation by construction. Once the auth server has accepted this exact
// token, its claims — `aal`, `amr`, `session_id` — can be read without
// checking the signature a second time.
//
// THE ROLE COMES FROM THE DATABASE on every request (`admin_resolve`), so
// disabling an admin takes effect on their next click, not on their next
// sign-in.
type Role = 'viewer' | 'uploader' | 'editor' | 'owner';
const RANK: Record<Role, number> = { viewer: 1, uploader: 2, editor: 3, owner: 4 };

type Admin = {
  id: string;
  email: string;
  role: Role;
  aal: string;
  session: string;
  totpAt: number;
  requireMfa: boolean;
  stepupMinutes: number;
  idleMinutes: number;
};

function jwtClaims(auth: string): Record<string, unknown> {
  try {
    const part = auth.slice(7).trim().split('.')[1] ?? '';
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/');
    const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
    return JSON.parse(atob(padded)) as Record<string, unknown>;
  } catch {
    return {};
  }
}

async function whoIsAsking(
  req: Request,
): Promise<Admin | { error: string; status: number }> {
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.toLowerCase().startsWith('bearer ')) {
    return { error: 'not_signed_in', status: 401 };
  }
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: ANON_KEY },
  });
  if (!res.ok) return { error: 'not_signed_in', status: 401 };
  const user = await res.json();
  const id = typeof user?.id === 'string' ? user.id : '';
  if (!id) return { error: 'not_signed_in', status: 401 };

  const rr = await fetch(`${SUPABASE_URL}/rest/v1/rpc/admin_resolve`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_user: id }),
  });
  if (!rr.ok) return { error: 'admin_lookup_failed', status: 500 };
  const rows = await rr.json() as Array<Record<string, unknown>>;
  const row = Array.isArray(rows) ? rows[0] : undefined;
  const role = String(row?.role ?? '');
  if (!row || !(role in RANK)) return { error: 'not_an_admin', status: 403 };

  const claims = jwtClaims(auth);
  const amr = Array.isArray(claims.amr)
    ? claims.amr as Array<Record<string, unknown>> : [];
  const totp = amr.filter((m) => m && m.method === 'totp')
    .map((m) => Number(m.timestamp) || 0);
  const who: Admin = {
    id,
    email: String(row.email ?? ''),
    role: role as Role,
    aal: String(claims.aal ?? 'aal1'),
    session: String(claims.session_id ?? ''),
    totpAt: totp.length ? Math.max(...totp) : 0,
    requireMfa: row.require_mfa === true,
    stepupMinutes: Number(row.stepup_minutes) || 10,
    idleMinutes: Number(row.idle_minutes) || 30,
  };
  // MFA REQUIRED MEANS REQUIRED. A stolen Google session without the
  // authenticator code is turned away here, on every request.
  if (who.requireMfa && who.aal !== 'aal2') {
    return { error: 'mfa_required', status: 403 };
  }
  return who;
}

function mayDo(who: Admin, need: Role): boolean {
  return RANK[who.role] >= RANK[need];
}

/// For what cannot be undone: the authenticator code must have been entered
/// in the last few minutes, not hours ago when the session began. Applies only
/// once MFA is required — before that the owner may have no factor to give.
function freshEnough(who: Admin): boolean {
  if (!who.requireMfa) return true;
  return who.totpAt > 0 &&
    Date.now() / 1000 - who.totpAt <= who.stepupMinutes * 60;
}

/// What goes in the audit line: enough to know what was done, nothing that is
/// a secret or a link that grants access. Presigned URLs, tokens and upload
/// part lists are dropped by name; long strings are cut; arrays are counted.
function auditDetail(body: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(body ?? {})) {
    if (k === 'op') continue;
    if (/token|secret|url|parts|password|code/i.test(k)) continue;
    if (Array.isArray(v)) out[k] = `[${v.length}]`;
    else if (typeof v === 'string') out[k] = v.length > 120 ? v.slice(0, 120) + '…' : v;
    else if (v && typeof v === 'object') out[k] = auditDetail(v as Record<string, unknown>);
    else out[k] = v;
  }
  return out;
}

/// One line of the audit log. Best effort: an audit write that fails must not
/// turn a change that succeeded into an error the admin then repeats.
async function audit(
  who: Admin, fn: string, action: string, target: string | null,
  detail: Record<string, unknown> | null, ok: boolean, error: string | null,
): Promise<void> {
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/rpc/admin_log`, {
      method: 'POST',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        p_actor: who.id, p_fn: fn, p_action: action, p_target: target,
        p_detail: detail, p_ok: ok, p_error: error,
      }),
    });
  } catch {
    // Nothing useful to do; the change itself already happened.
  }
}
// ── ADMIN GATE (end) ─────────────────────────────────────────────────────

// --- the Files page: folders, listings, copies ------------------------------

/// Which folder a key is in. THE SAME RULE as `r2_folder_of` in migration
/// 028 — <folder>/<video|photo|thumb>/<name>, else the first segment — and
/// tool/js/files_test.mjs fails the build if the two ever disagree, because a
/// move that picked its files by one rule and a page that grouped them by the
/// other would move a folder the operator was not looking at.
function folderOf(key: string): string {
  const m = /^(.*)\/(?:video|photo|thumb)\/[^/]+$/.exec(key);
  if (m) return m[1];
  const i = key.indexOf('/');
  return i > 0 ? key.slice(0, i) : '';
}

/// One page of a bucket listing (1000 keys), asked for with encoding-type=url
/// so a key with characters XML cannot carry still comes back whole.
async function listBucket(
  bucket: string, prefix: string, token: string,
): Promise<{ items: Array<{ key: string; bytes: number; modified: string }>; next: string } | { error: string; status: number }> {
  const q: Record<string, string> = {
    'list-type': '2', 'max-keys': '1000', 'encoding-type': 'url',
  };
  if (prefix) q.prefix = prefix;
  if (token) q['continuation-token'] = token;
  const signed = await signRequest('GET', bucket, '', q, '');
  const res = await fetch(signed.url, { headers: signed.headers });
  const xml = await res.text();
  if (!res.ok) return { error: 'list_failed', status: res.status };
  const items: Array<{ key: string; bytes: number; modified: string }> = [];
  for (const block of xml.split('<Contents>').slice(1)) {
    const raw = xmlTag(block, 'Key') ?? '';
    let key = raw;
    try { key = decodeURIComponent(raw.replace(/\+/g, '%20')); } catch { /* keep raw */ }
    if (!key) continue;
    items.push({ key, bytes: Number(xmlTag(block, 'Size') ?? 0) || 0,
      modified: xmlTag(block, 'LastModified') ?? '' });
  }
  const more = xmlTag(xml, 'IsTruncated') === 'true';
  return { items, next: more ? (xmlTag(xml, 'NextContinuationToken') ?? '') : '' };
}

/// The size of one object, or null when it is not there.
async function objectSize(bucket: string, key: string): Promise<number | null> {
  const h = await signRequest('HEAD', bucket, key, {}, '');
  const r = await fetch(h.url, { method: 'HEAD', headers: h.headers });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error('head_failed_' + r.status);
  return Number(r.headers.get('Content-Length') ?? 0);
}

/// R2 copies one object up to 5 GiB in a single CopyObject. Larger ones go in
/// 1 GiB parts with UploadPartCopy — R2's rule that every part but the last
/// is the same size still applies to copies.
const COPY_SINGLE_MAX = 5 * 1024 * 1024 * 1024;
const COPY_PART = 1024 * 1024 * 1024;

/// Copies one object inside R2 (no bytes pass through here or the phone).
/// `state` carries a multipart copy's progress between calls, because a big
/// file can take longer than one edge-function request may run; the caller
/// saves it and calls again. Answers { done } or { state } to save.
async function copyStep(
  bucket: string, from: string, to: string, size: number,
  state: Record<string, unknown> | null, deadline: number,
): Promise<{ done: true } | { state: Record<string, unknown> }> {
  const source = `/${bucket}/${encodeKey(from)}`;
  if (size <= COPY_SINGLE_MAX) {
    const signed = await signRequest('PUT', bucket, to, {}, '', { 'x-amz-copy-source': source });
    const res = await fetch(signed.url, { method: 'PUT', headers: signed.headers });
    const xml = await res.text();
    // Like CompleteMultipartUpload, a copy can answer 200 and have failed.
    if (!res.ok || xml.includes('<Error>')) {
      throw new Error('copy_failed: ' + (xmlTag(xml, 'Code') ?? res.status));
    }
    return { done: true };
  }
  const st = { ...(state ?? {}) } as { uploadId?: string; parts?: Array<{ n: number; etag: string }> };
  if (!st.uploadId) {
    const b = await signRequest('POST', bucket, to, { uploads: '' }, '');
    const r = await fetch(b.url, { method: 'POST', headers: b.headers });
    const xml = await r.text();
    const id = xmlTag(xml, 'UploadId');
    if (!r.ok || !id) throw new Error('copy_begin_failed: ' + (xmlTag(xml, 'Code') ?? r.status));
    st.uploadId = id;
    st.parts = [];
    return { state: st };
  }
  const parts = st.parts ?? [];
  const count = Math.ceil(size / COPY_PART);
  while (parts.length < count && Date.now() < deadline) {
    const n = parts.length + 1;
    const start = (n - 1) * COPY_PART;
    const end = Math.min(size, n * COPY_PART) - 1;
    const p = await signRequest('PUT', bucket, to, { partNumber: String(n), uploadId: st.uploadId },
      '', { 'x-amz-copy-source': source, 'x-amz-copy-source-range': `bytes=${start}-${end}` });
    const r = await fetch(p.url, { method: 'PUT', headers: p.headers });
    const xml = await r.text();
    const etag = (xmlTag(xml, 'ETag') ?? '').replace(/&quot;|"/g, '');
    if (!r.ok || !etag) throw new Error('copy_part_failed: ' + (xmlTag(xml, 'Code') ?? r.status));
    parts.push({ n, etag });
  }
  st.parts = parts;
  if (parts.length < count) return { state: st };
  const xmlBody = '<CompleteMultipartUpload>' +
    parts.map((p) => `<Part><PartNumber>${p.n}</PartNumber><ETag>"${p.etag}"</ETag></Part>`).join('') +
    `</CompleteMultipartUpload>`;
  const c = await signRequest('POST', bucket, to, { uploadId: st.uploadId }, xmlBody);
  const cr = await fetch(c.url, { method: 'POST',
    headers: { ...c.headers, 'Content-Type': 'application/xml' }, body: xmlBody });
  const cx = await cr.text();
  if (!cr.ok || cx.includes('<Error>')) throw new Error('copy_complete_failed: ' + (xmlTag(cx, 'Code') ?? cr.status));
  return { done: true };
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

// ═══════════════════════════════════════════════════════════════════════
// WHICH ROLE EACH OP NEEDS
// ═══════════════════════════════════════════════════════════════════════
//
//   viewer    reads
//   uploader  uploads and makes drafts — only ITS OWN, only UNPUBLISHED (see
//             uploaderRefusal), and never publishes
//   editor    publishes, edits anything, payments, categories, the audit log
//   owner     deletes titles, manages admins and the security switches
//
// An op missing from here is refused (deny by default, above).
const NEED: Record<string, Role> = {
  // reading
  whoami: 'viewer', summary: 'viewer', list: 'viewer', get: 'viewer',
  requests: 'viewer', stats: 'viewer', categories: 'viewer', health: 'viewer',
  // uploading and drafting
  sign: 'uploader', beginMultipart: 'uploader', signParts: 'uploader',
  completeMultipart: 'uploader', abortMultipart: 'uploader', listParts: 'uploader',
  folder: 'uploader', checkFolder: 'uploader',
  create: 'uploader', save: 'uploader', addAssets: 'uploader',
  updateAsset: 'uploader', reorder: 'uploader', setPrimary: 'uploader',
  deleteAsset: 'uploader',
  // review — looking is anyone's; sending your own draft is an uploader's;
  // deciding is an editor's (and review_decide checks all of it again)
  reviewQueue: 'viewer', reviewHistory: 'viewer', previewUrl: 'viewer',
  reviewSubmit: 'uploader', reviewReopen: 'uploader',
  reviewApprove: 'editor', reviewSendBack: 'editor', reviewReject: 'editor',
  unpublish: 'editor',
  // the Files page — looking and naming are an editor's; anything that
  // deletes or moves a file is the owner's
  filesSummary: 'editor', filesList: 'editor', inventoryScan: 'editor',
  objectUrl: 'editor', folderLabel: 'editor', moveList: 'editor',
  trashObjects: 'owner', trashRestore: 'owner',
  moveStart: 'owner', moveCopy: 'owner', moveSwitch: 'owner', moveCancel: 'owner',
  // the Storage page (migration 029) — looking, bringing a film back and
  // asking for a Telegram check are an editor's; anything that takes a film
  // out of R2, and the policy itself, is the owner's
  storageOverview: 'editor', masterKeep: 'editor', titleRestore: 'editor',
  vaultCheck: 'editor',
  storagePin: 'owner', masterOffload: 'owner', titleArchive: 'owner',
  titleRestoreFinish: 'owner', storageSettings: 'owner',
  // publishing and the business
  publish: 'editor', approve: 'editor', reject: 'editor',
  saveCategory: 'editor', addCategory: 'editor', selftest: 'editor',
  audit: 'editor',
  // the owner's
  deleteTitle: 'owner', admins: 'owner', adminSave: 'owner',
  adminRemove: 'owner', settings: 'owner', settingsSave: 'owner',
};

/// Ops that change nothing, and so are not written to the audit log. Signing
/// a URL is here on purpose: it changes nothing until the upload completes,
/// and the completion IS logged.
const READS = new Set([
  'whoami', 'summary', 'list', 'get', 'requests', 'stats', 'categories',
  'health', 'checkFolder', 'folder', 'selftest', 'audit', 'admins', 'settings',
  'sign', 'beginMultipart', 'signParts', 'listParts',
  'reviewQueue', 'reviewHistory', 'previewUrl',
  'filesSummary', 'filesList', 'inventoryScan', 'objectUrl', 'moveList',
  'storageOverview',
]);

/// What cannot be undone, or hands out power: these need an authenticator code
/// from the last few minutes (once MFA is required), not just a session.
const DANGEROUS = new Set([
  'deleteTitle', 'adminSave', 'adminRemove', 'settingsSave',
  'trashObjects', 'moveStart', 'moveSwitch',
  'masterOffload', 'titleArchive', 'storageSettings',
]);

/// The thing an audit line is about, for the Activity page's one-line view.
function auditTarget(body: Record<string, unknown>): string | null {
  const t = body.id ?? body.titleId ?? body.email ?? body.folder ?? body.key ??
    body.title ?? null;
  return t === null || t === undefined ? null : String(t).slice(0, 200);
}

/// An uploader may make drafts and edit them — its OWN drafts, while they are
/// UNPUBLISHED — and may not publish anything. Answers the refusal, or null.
///
/// Checked against the database, not the page: which title an asset belongs
/// to and who made a title are facts the page could misreport.
async function uploaderRefusal(
  op: string, body: Record<string, unknown>, who: Admin,
): Promise<string | null> {
  if (who.role !== 'uploader') return null;
  if ((op === 'create' || op === 'publish') && body.publish === true) {
    return 'needs_editor_to_publish';
  }
  const db = createClient(SUPABASE_URL, SERVICE_KEY);
  let titles: string[] = [];
  if (op === 'save') {
    const p = (body.patch ?? {}) as Record<string, unknown>;
    if ('published' in p) return 'needs_editor_to_publish';
    titles = [String(body.id ?? '')];
  } else if (op === 'addAssets') {
    titles = [String(body.titleId ?? '')];
  } else if (op === 'reviewSubmit' || op === 'reviewReopen') {
    titles = [String(body.id ?? '')];
  } else if (
    op === 'updateAsset' || op === 'setPrimary' || op === 'reorder' ||
    op === 'deleteAsset'
  ) {
    const ids: string[] = op === 'reorder'
      ? (Array.isArray(body.order) ? body.order as Record<string, unknown>[] : [])
        .map((o: Record<string, unknown>) => String(o?.id ?? ''))
      : [String(body.id ?? '')];
    const { data } = await db.from('title_assets').select('title_id')
      .in('id', ids.filter(Boolean));
    titles = [...new Set<string>(
      ((data ?? []) as Array<{ title_id: unknown }>).map((r) => String(r.title_id)),
    )];
    if (!titles.length) return 'no_such_asset';
  } else {
    return null;
  }
  if (!titles.length || titles.some((t) => !t)) return 'no_title';
  const { data: rows } = await db.from('titles')
    .select('id,published,created_by').in('id', titles);
  if (!rows || rows.length !== titles.length) return 'no_title';
  const owned = rows as Array<{ published: unknown; created_by: unknown }>;
  if (owned.some((r) => r.published === true || r.created_by !== who.id)) {
    return 'not_your_draft';
  }
  return null;
}

/// A Worker URL for one object, valid for [seconds]. THE SAME TOKEN as
/// request-playback.ts's workerUrl — AES-GCM over {k, e} with the SHA-256 of
/// the shared secret — so the Worker cannot tell an admin's preview from a
/// viewer's play. tool/js/stream_token_test.mjs opens one of these with the
/// Worker's own code.
async function previewStreamUrl(objectKey: string, seconds: number): Promise<string | null> {
  if (!STREAM_BASE || !STREAM_TOKEN_SECRET) return null;
  const key = await crypto.subtle.importKey(
    'raw',
    await crypto.subtle.digest('SHA-256', enc.encode(STREAM_TOKEN_SECRET)),
    { name: 'AES-GCM' }, false, ['encrypt'],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, key,
    enc.encode(JSON.stringify({ k: objectKey, e: Math.floor(Date.now() / 1000) + seconds })),
  ));
  const token = new Uint8Array(iv.length + sealed.length);
  token.set(iv, 0);
  token.set(sealed, iv.length);
  const b64 = btoa(String.fromCharCode(...token))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${STREAM_BASE}/v/${b64}`;
}

/// One message to the owner's Telegram chats. Best effort: nothing the
/// console does may fail because Telegram did not answer.
async function tellOwner(text: string): Promise<void> {
  if (!BOT_TOKEN || !TG_CHATS.length) return;
  for (const chat of TG_CHATS) {
    try {
      await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
      });
    } catch {
      // Best effort.
    }
  }
}

/// Tell the owner, in Telegram, that somebody has just signed in to the
/// console — once per session. An admin account being used by somebody else
/// is the attack this whole page is shaped around, and the person most likely
/// to notice a sign-in they did not make is the one it is announced to.
async function announceSignIn(who: Admin): Promise<void> {
  // Myanmar time, which is what the owner's phone shows: UTC+6:30.
  const mmt = new Date(Date.now() + 6.5 * 3600 * 1000).toISOString()
    .slice(0, 16).replace('T', ' ');
  await tellOwner(`Console sign-in\n${who.email} (${who.role})\n` +
    `2-step: ${who.aal === 'aal2' ? 'yes' : 'NO'}\n${mmt} Myanmar time\n` +
    'If this was not you, remove the admin on the Admins page.');
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

  const asked = await whoIsAsking(req);
  if ('error' in asked) return json({ error: asked.error }, asked.status, req);
  const who = asked;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'bad_json' }, 400, req);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // THE CONSOLE API, AND WHO MAY CALL WHICH PART OF IT
  //
  // Every op runs as the SERVICE ROLE once the checks below have said yes.
  // That is deliberate: `titles` and `title_assets` are not writable by
  // `authenticated` and must not become writable — widening RLS to let any
  // signed-in user edit the catalogue would be a far larger hole than one
  // function checking roles.
  //
  // DENY BY DEFAULT. An op that is not in NEED is refused before anything
  // runs. It used to be that a new op was behind the gate automatically; with
  // roles, a new op with no role would be behind NO role, so it is refused
  // until somebody decides who may call it. tool/js/admin_gate_test.mjs fails
  // the build if an op exists in this file and not in NEED, or the reverse.
  // ═══════════════════════════════════════════════════════════════════════
  const op = String(body.op ?? '');
  const need = NEED[op];
  if (!need) return json({ error: 'unknown_op' }, 400, req);
  if (!mayDo(who, need)) {
    return json({ error: 'not_allowed', need, role: who.role }, 403, req);
  }
  if (DANGEROUS.has(op) && !freshEnough(who)) {
    return json({ error: 'reauth_required' }, 403, req);
  }
  const refused = await uploaderRefusal(op, body, who);
  if (refused) return json({ error: refused }, 403, req);

  const res = await handleOp(req, body, who);

  // EVERY WRITE IS WRITTEN DOWN, whether it worked or not — a refused delete
  // is as much a part of the record as a successful one.
  if (!READS.has(op)) {
    let err: string | null = null;
    if (res.status >= 400) {
      try {
        err = String((await res.clone().json())?.error ?? res.status);
      } catch {
        err = String(res.status);
      }
    }
    await audit(who, 'studio', op, auditTarget(body), auditDetail(body),
      res.status < 400, err);
  }
  return res;
});

async function handleOp(
  req: Request, body: Record<string, unknown>, who: Admin,
): Promise<Response> {
  const admin = () => createClient(SUPABASE_URL, SERVICE_KEY);

  // Columns the console reads for ONE title. Not `*`: `locator` is in here on
  // purpose (the operator must be able to see and fix a wrong key) but that
  // is exactly why this list is written out — so adding a column to `titles`
  // never silently starts shipping it to a browser.
  const TITLE_COLS =
    'id,title,title_mm,synopsis,category,poster_url,year,rating,quality_label,' +
    'genres,keywords,episode_count,view_count,access_tier,photo_count,' +
    'video_count,is_featured,locator,provider,published,status,slug,created_at,' +
    'created_by,review_state,review_note,submitted_at,decided_at';

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
    // HOW BIG IS WHAT ARRIVED. Read back from R2 rather than assumed: the
    // page compares it with the file it sent before it writes a row, so an
    // upload that "finished" short is caught here and not by a viewer whose
    // film stops ten minutes early. Best effort — a HEAD that fails leaves
    // `bytes` null, which the page treats as "could not check", not as wrong.
    let bytes: number | null = null;
    try {
      const h = await signRequest('HEAD', bucket, objectKey, {}, '');
      const hr = await fetch(h.url, { method: 'HEAD', headers: h.headers });
      if (hr.ok) bytes = Number(hr.headers.get('Content-Length')) || null;
    } catch {
      // Left null.
    }
    return json({ ok: true, bucket, objectKey, bytes,
      publicUrl: kind === 'video' ? null : `${PUBLIC_BASE}/${objectKey}` }, 200, req);
  }

  // --- listParts: which parts of an upload R2 actually holds ---------------
  //
  // FOR RESUMING after the tab died. The page keeps its own record of the
  // parts R2 accepted; this is the cross-check from the other side, and the
  // way to learn the upload is gone — R2 aborts an unfinished upload after
  // seven days by default, and then answers NoSuchUpload (404).
  //
  // Paged by 1000 like the S3 API; twelve pages is more than the 10,000-part
  // ceiling, so the loop cannot run away.
  if (body.op === 'listParts') {
    const objectKey = String(body.objectKey ?? '');
    const uploadId = String(body.uploadId ?? '');
    if (!isMintedKey(objectKey)) return json({ error: 'bad_key' }, 400, req);
    if (!uploadId) return json({ error: 'no_upload_id' }, 400, req);
    const bucket = body.kind === 'photo' || body.kind === 'thumb'
      ? PUBLIC_BUCKET : MEDIA_BUCKET;
    const parts: Array<{ partNumber: number; etag: string; size: number }> = [];
    let marker = '';
    for (let page = 0; page < 12; page++) {
      const q: Record<string, string> = { uploadId, 'max-parts': '1000' };
      if (marker) q['part-number-marker'] = marker;
      const signed = await signRequest('GET', bucket, objectKey, q, '');
      const res = await fetch(signed.url, { headers: signed.headers });
      const xml = await res.text();
      if (!res.ok) {
        const code = xmlTag(xml, 'Code') ?? '';
        if (res.status === 404 || code === 'NoSuchUpload') {
          return json({ error: 'no_such_upload' }, 404, req);
        }
        return json({ error: 'list_parts_failed', status: res.status, detail: code }, 502, req);
      }
      for (const block of xml.split('<Part>').slice(1)) {
        parts.push({
          partNumber: Number(xmlTag(block, 'PartNumber') ?? 0),
          etag: String(xmlTag(block, 'ETag') ?? '').replace(/&quot;|"/g, ''),
          size: Number(xmlTag(block, 'Size') ?? 0),
        });
      }
      if (xmlTag(xml, 'IsTruncated') !== 'true') break;
      marker = xmlTag(xml, 'NextPartNumberMarker') ?? '';
      if (!marker) break;
    }
    return json({ parts }, 200, req);
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
    if (body.status === 'ready') sel = sel.eq('published', false).eq('review_state', 'ready');
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
    // ALWAYS A DRAFT, whatever the page asks. Since the review queue, nothing
    // reaches the app without an editor's Approve — and this was the one door
    // that published on creation, by default, from a checkbox that started
    // ticked. `publish` is still read from old pages and ignored.
    const wantPublished = false;

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
      // WHO MADE IT, because an uploader may edit only their own drafts.
      created_by: who.id,
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
    // PUBLISHING GOES THROUGH THE REVIEW, not around it. An older page still
    // sends `published` from its checkbox; it is turned into an approve or an
    // unpublish by review_decide, which checks the role, the files and the
    // two-person rule and writes the history — the same as the Review page.
    const publishTo = 'published' in p ? p.published === true : null;
    if (Object.keys(upd).length === 0 && publishTo === null) {
      return json({ error: 'empty_patch' }, 400, req);
    }
    if ('title' in upd && !upd.title) return json({ error: 'no_title' }, 400, req);

    if (Object.keys(upd).length) {
      const { error } = await admin().from('titles').update(upd).eq('id', id);
      if (error) return json({ error: 'save_failed', detail: error.message }, 500, req);
    }
    if (publishTo !== null) {
      const { data: now } = await admin().from('titles')
        .select('published').eq('id', id).maybeSingle();
      if (now && now.published !== publishTo) {
        const { data: word, error } = await admin().rpc('review_decide', {
          p_title: id, p_actor: who.id,
          p_action: publishTo ? 'approve' : 'unpublish', p_note: null,
        });
        if (error) return json({ error: 'save_failed', detail: error.message }, 500, req);
        if (word !== 'approved' && word !== 'unpublished') {
          return json({ error: String(word) }, 409, req);
        }
      }
    }
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

  // ═══════════════════════════════════════════════════════════════════════
  // THE CONTROL ROOM: who is signed in, the dashboard, admins, the audit log
  // ═══════════════════════════════════════════════════════════════════════

  // ── whoami: what this person is, and announce the sign-in once ─────────
  //
  // The console asks this first. Its answer decides which pages it shows —
  // which is manners, not security: every op above checks the role again.
  if (body.op === 'whoami') {
    const db = admin();
    const { data: isNew } = await db.rpc('admin_note_session', {
      p_session: who.session || null,
      p_user: who.id,
      p_agent: (req.headers.get('User-Agent') ?? '').slice(0, 200),
    });
    if (isNew === true) await announceSignIn(who);
    return json({
      // The page compares it with a title's created_by, to know which drafts
      // are this admin's own. Not a secret: it is in their own token.
      id: who.id,
      email: who.email,
      role: who.role,
      aal: who.aal,
      requireMfa: who.requireMfa,
      idleMinutes: who.idleMinutes,
      stepupMinutes: who.stepupMinutes,
    }, 200, req);
  }

  // ── summary: the dashboard, in one request ──────────────────────────────
  if (body.op === 'summary') {
    const db = admin();
    const count = async (q: PromiseLike<{ count: number | null }>) =>
      (await q).count ?? 0;
    const [live, drafts, requests, queued, running, failed, unattached,
      waiting, sentBack, mineBack] =
      await Promise.all([
        count(db.from('titles').select('id', { count: 'exact', head: true })
          .eq('published', true)),
        count(db.from('titles').select('id', { count: 'exact', head: true })
          .eq('published', false)),
        count(db.from('pending_requests').select('*', { count: 'exact', head: true })),
        count(db.from('ingest_jobs').select('id', { count: 'exact', head: true })
          .eq('state', 'queued')),
        count(db.from('ingest_jobs').select('id', { count: 'exact', head: true })
          .eq('state', 'running')),
        count(db.from('ingest_jobs').select('id', { count: 'exact', head: true })
          .eq('state', 'failed')),
        count(db.from('ingest_jobs').select('id', { count: 'exact', head: true })
          .eq('state', 'done').is('title_id', null)),
        count(db.from('titles').select('id', { count: 'exact', head: true })
          .eq('published', false).eq('review_state', 'ready')),
        count(db.from('titles').select('id', { count: 'exact', head: true })
          .eq('published', false).eq('review_state', 'changes')),
        count(db.from('titles').select('id', { count: 'exact', head: true })
          .eq('published', false).eq('review_state', 'changes').eq('created_by', who.id)),
      ]);
    // The recent activity is the audit log, which is an editor's to read.
    let recent: unknown[] = [];
    if (mayDo(who, 'editor')) {
      const { data } = await db.from('admin_audit')
        .select('at,actor_email,actor_role,fn,action,target,ok,error')
        .order('at', { ascending: false }).limit(8);
      recent = data ?? [];
    }
    return json({
      titles: { live, drafts },
      telegram: { queued, running, failed, unattached },
      // `mine` is what was sent back to THIS admin — the uploader's to-do.
      review: { waiting, sentBack, mine: mineBack },
      requests,
      recent,
    }, 200, req);
  }

  // ── admins: the Admins page ─────────────────────────────────────────────
  if (body.op === 'admins') {
    const { data, error } = await admin().rpc('admin_list');
    if (error) return json({ error: 'admins_failed', detail: error.message }, 500, req);
    return json({ admins: data ?? [] }, 200, req);
  }

  // ── adminSave: invite by email, or change a role ────────────────────────
  //
  // `admin_save` checks the caller is an owner AGAIN, and refuses to demote
  // the last owner. Both checks live in the database as well as here because
  // this is the one op that can hand out every other permission.
  if (body.op === 'adminSave') {
    const { data, error } = await admin().rpc('admin_save', {
      p_actor: who.id,
      p_email: String(body.email ?? ''),
      p_role: String(body.role ?? ''),
    });
    if (error) return json({ error: 'save_failed', detail: error.message }, 500, req);
    const result = String(data ?? '');
    if (result !== 'added' && result !== 'updated') {
      return json({ error: result || 'save_failed' }, 400, req);
    }
    return json({ ok: true, result }, 200, req);
  }

  // ── adminRemove: disable, never delete ──────────────────────────────────
  if (body.op === 'adminRemove') {
    const { data, error } = await admin().rpc('admin_remove', {
      p_actor: who.id,
      p_admin: String(body.id ?? ''),
    });
    if (error) return json({ error: 'remove_failed', detail: error.message }, 500, req);
    const result = String(data ?? '');
    if (result !== 'disabled') return json({ error: result || 'remove_failed' }, 400, req);
    return json({ ok: true, result }, 200, req);
  }

  // ── audit: the Activity page ────────────────────────────────────────────
  //
  // Newest first, a page at a time. `before` is the id of the last row the
  // page already has; ids only grow, so the page can never skip or repeat a
  // line however many are written while somebody is reading.
  if (body.op === 'audit') {
    let q = admin().from('admin_audit')
      .select('id,at,actor_email,actor_role,fn,action,target,detail,ok,error')
      .order('id', { ascending: false }).limit(100);
    const before = Number(body.before ?? 0);
    if (before > 0) q = q.lt('id', before);
    const actor = String(body.actor ?? '');
    if (actor) q = q.eq('actor_email', actor.toLowerCase());
    const { data, error } = await q;
    if (error) return json({ error: 'audit_failed', detail: error.message }, 500, req);
    return json({ rows: data ?? [] }, 200, req);
  }

  // ── settings / settingsSave: the security switches ──────────────────────
  if (body.op === 'settings') {
    const { data, error } = await admin().from('admin_settings')
      .select('require_mfa,stepup_minutes,idle_minutes,two_person,updated_at').eq('id', true)
      .maybeSingle();
    if (error) return json({ error: 'settings_failed', detail: error.message }, 500, req);
    return json({ settings: data }, 200, req);
  }

  if (body.op === 'settingsSave') {
    const upd: Record<string, unknown> = { updated_at: new Date().toISOString() };
    if ('require_mfa' in body) {
      const on = body.require_mfa === true;
      // NOT WITHOUT A FACTOR OF YOUR OWN. Requiring MFA while the person
      // switching it on has none would turn them away on their very next
      // click, and if they are the only owner, nobody could switch it back.
      if (on && who.aal !== 'aal2') {
        return json({ error: 'enrol_mfa_first' }, 400, req);
      }
      // NOT WHILE ANOTHER ADMIN HAS NONE EITHER. Supabase lets an account
      // with no authenticator enrol one from an ordinary session — so with
      // MFA required, whoever holds that admin's Google session could enrol
      // THEIR OWN authenticator and walk in. Everyone enrols first; then it
      // is switched on.
      if (on) {
        const { data: list } = await admin().rpc('admin_list');
        const missing = ((list ?? []) as Array<Record<string, unknown>>)
          .filter((a) => a.disabled !== true && a.mfa !== true)
          .map((a) => String(a.email ?? ''));
        if (missing.length) {
          return json({ error: 'admins_without_mfa', detail: missing.join(', ') },
            400, req);
        }
      }
      upd.require_mfa = on;
    }
    if ('two_person' in body) {
      const on = body.two_person === true;
      // NOT WITH ONE APPROVER. With the rule on, the person who made a title
      // cannot approve it — and if they are the only editor or owner, nothing
      // they make could ever go live.
      if (on) {
        const { data: list } = await admin().rpc('admin_list');
        const approvers = ((list ?? []) as Array<Record<string, unknown>>)
          .filter((a) => a.disabled !== true &&
            (a.role === 'editor' || a.role === 'owner'));
        if (approvers.length < 2) {
          return json({ error: 'needs_two_approvers' }, 400, req);
        }
      }
      upd.two_person = on;
    }
    if ('idle_minutes' in body) {
      const v = Math.round(Number(body.idle_minutes));
      if (!(v >= 5 && v <= 480)) return json({ error: 'bad_idle_minutes' }, 400, req);
      upd.idle_minutes = v;
    }
    if ('stepup_minutes' in body) {
      const v = Math.round(Number(body.stepup_minutes));
      if (!(v >= 1 && v <= 120)) return json({ error: 'bad_stepup_minutes' }, 400, req);
      upd.stepup_minutes = v;
    }
    const { error } = await admin().from('admin_settings').update(upd).eq('id', true);
    if (error) return json({ error: 'settings_failed', detail: error.message }, 500, req);
    return json({ ok: true }, 200, req);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // THE REVIEW QUEUE
  // ═══════════════════════════════════════════════════════════════════════

  // ── reviewQueue: everything not live, the ones waiting first ────────────
  if (body.op === 'reviewQueue') {
    const { data, error } = await admin().rpc('review_queue');
    if (error) return json({ error: 'queue_failed', detail: error.message }, 500, req);
    return json({ rows: data ?? [], me: who.id }, 200, req);
  }

  // ── reviewHistory: who sent, approved, sent back — for one title ────────
  if (body.op === 'reviewHistory') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const { data, error } = await admin().from('title_reviews')
      .select('at,actor_email,action,note').eq('title_id', id)
      .order('at', { ascending: false }).limit(50);
    if (error) return json({ error: 'history_failed', detail: error.message }, 500, req);
    return json({ rows: data ?? [] }, 200, req);
  }

  // ── the decisions: one door, review_decide ──────────────────────────────
  //
  // The database checks the role, the state, the files and the two-person
  // rule, locks the row and writes the history; this only translates its
  // answer. A refusal comes back as its own word, which the page explains.
  if (body.op === 'reviewSubmit' || body.op === 'reviewApprove' ||
      body.op === 'reviewSendBack' || body.op === 'reviewReject' ||
      body.op === 'reviewReopen' || body.op === 'unpublish') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const action = ({
      reviewSubmit: 'submit', reviewApprove: 'approve', reviewSendBack: 'send_back',
      reviewReject: 'reject', reviewReopen: 'reopen', unpublish: 'unpublish',
    } as Record<string, string>)[String(body.op)];
    const note = String(body.note ?? '').slice(0, 1000);
    const db = admin();
    const { data: word, error } = await db.rpc('review_decide', {
      p_title: id, p_actor: who.id, p_action: action, p_note: note || null,
    });
    if (error) return json({ error: 'decide_failed', detail: error.message }, 500, req);
    const result = String(word ?? '');
    const done = ['submitted', 'approved', 'sent_back', 'rejected', 'reopened', 'unpublished'];
    if (!done.includes(result)) {
      return json({ error: result || 'decide_failed' },
        result === 'not_allowed' || result === 'two_person' ? 403 : 409, req);
    }
    // "PLEASE LOOK" REACHES A PERSON. Sending for review tells the owner's
    // Telegram, with how many are now waiting, so the queue is not something
    // somebody has to remember to open.
    if (result === 'submitted') {
      const [{ data: t }, { count }] = await Promise.all([
        db.from('titles').select('title').eq('id', id).maybeSingle(),
        db.from('titles').select('id', { count: 'exact', head: true })
          .eq('published', false).eq('review_state', 'ready'),
      ]);
      await tellOwner(`Waiting for review: "${String(t?.title ?? '')}"\n` +
        `sent by ${who.email}\n${count ?? 1} waiting in all.\n${CONSOLE_URL}#/review`);
    }
    return json({ ok: true, result }, 200, req);
  }

  // ── previewUrl: watch a file inside the console before approving it ─────
  //
  // A PHOTO is public already. A VIDEO is in the private bucket, so this
  // hands back a short-lived URL: through the Worker when it is set up (the
  // path viewers use), a presigned GET otherwise. Ten minutes — enough to
  // watch a trailer or skip through a film, short enough that a copied link
  // is worth nothing by the time anyone could share it.
  //
  // THE SMALLEST GOOD COPY, not the master. An admin previewing on a phone
  // over mobile data wants to see the film, not pull a 4K master; a 720p
  // (or the nearest below it) streaming copy is chosen when one exists.
  if (body.op === 'previewUrl') {
    const id = String(body.id ?? '');
    if (!id) return json({ error: 'no_id' }, 400, req);
    const db = admin();
    const { data: a, error } = await db.from('title_assets')
      .select('id,kind,bucket,object_key').eq('id', id).maybeSingle();
    if (error) return json({ error: 'preview_failed', detail: error.message }, 500, req);
    if (!a) return json({ error: 'no_such_asset' }, 404, req);
    if (a.kind === 'photo' || a.bucket === PUBLIC_BUCKET) {
      return json({ url: `${PUBLIC_BASE}/${a.object_key}`, kind: 'photo' }, 200, req);
    }
    const { data: rungs } = await db.from('asset_renditions')
      .select('height,object_key').eq('asset_id', id).order('height');
    const list = (rungs ?? []) as Array<{ height: number; object_key: string }>;
    const pick = list.filter((r) => r.height <= 720).pop() ?? list[0] ?? null;
    const key = pick ? pick.object_key : String(a.object_key);
    const seconds = 600;
    const viaWorker = await previewStreamUrl(key, seconds).catch(() => null);
    const url = viaWorker ??
      await presignPut(MEDIA_BUCKET, key, { 'X-Amz-Expires': String(seconds) }, 'GET');
    return json({
      url, kind: 'video', height: pick ? pick.height : null,
      via: viaWorker ? 'worker' : 'r2',
    }, 200, req);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // THE FILES PAGE — what is in R2, who uses it, the bin, and moves
  // ═══════════════════════════════════════════════════════════════════════

  // ── inventoryScan: refresh the console's copy of one bucket's listing ───
  //
  // One page (1000 keys) a call; the page calls again with `next` until it
  // is empty, and the last call tells the database to forget whatever this
  // scan did not see. Paged so no single request runs long on a big bucket.
  if (body.op === 'inventoryScan') {
    const bucket = body.bucket === PUBLIC_BUCKET ? PUBLIC_BUCKET : MEDIA_BUCKET;
    const given = String(body.scan ?? '');
    const scan = /^[0-9a-f-]{36}$/i.test(given) ? given : crypto.randomUUID();
    const page = await listBucket(bucket, '', String(body.token ?? ''));
    if ('error' in page) return json(page, 502, req);
    const db = admin();
    const up = await db.rpc('inventory_upsert', { p_bucket: bucket, p_scan: scan, p_rows: page.items });
    if (up.error) return json({ error: 'inventory_failed', detail: up.error.message }, 500, req);
    let removed = 0;
    if (!page.next) {
      const fin = await db.rpc('inventory_finish', { p_bucket: bucket, p_scan: scan });
      if (fin.error) return json({ error: 'inventory_failed', detail: fin.error.message }, 500, req);
      removed = Number(fin.data) || 0;
    }
    return json({ bucket, scan, seen: page.items.length, next: page.next, done: !page.next, removed }, 200, req);
  }

  // ── filesSummary: every folder, the bin, and when the listing was taken ─
  if (body.op === 'filesSummary') {
    const db = admin();
    const [f, sc, bin] = await Promise.all([
      db.rpc('files_summary'),
      db.from('r2_scans').select('bucket,started_at,finished_at,objects,bytes'),
      db.from('r2_trash')
        .select('id,bucket,key,bytes,reason,requested_email,requested_at,purge_after,purge_error')
        .is('purged_at', null).is('restored_at', null).order('purge_after').limit(500),
    ]);
    if (f.error) return json({ error: 'files_failed', detail: f.error.message }, 500, req);
    return json({
      folders: f.data ?? [], scans: sc.data ?? [], bin: bin.data ?? [],
      buckets: { media: MEDIA_BUCKET, public: PUBLIC_BUCKET },
      // R2 Standard, as published: per GB-month, the first 10 GB free each
      // month, no charge for downloads. Sent from here so the page and this
      // file cannot disagree about the price.
      price: { perGbMonth: 0.015, freeGb: 10 },
    }, 200, req);
  }

  // ── filesList: the files of one folder ─────────────────────────────────
  if (body.op === 'filesList') {
    const folder = String(body.folder ?? '');
    const { data, error } = await admin().rpc('files_list', { p_folder: folder });
    if (error) return json({ error: 'files_failed', detail: error.message }, 500, req);
    return json({ folder, rows: data ?? [] }, 200, req);
  }

  // ── objectUrl: look at any file, used or not ───────────────────────────
  //
  // previewUrl works from a title's asset; this from a key, so an unused file
  // can be looked at before it is binned. Ten minutes, like the preview.
  if (body.op === 'objectUrl') {
    const key = String(body.key ?? '');
    if (!key || key.includes('..') || key.startsWith('/')) return json({ error: 'bad_key' }, 400, req);
    if (body.bucket === PUBLIC_BUCKET) return json({ url: `${PUBLIC_BASE}/${key}` }, 200, req);
    const url = (await previewStreamUrl(key, 600).catch(() => null)) ??
      await presignPut(MEDIA_BUCKET, key, { 'X-Amz-Expires': '600' }, 'GET');
    return json({ url }, 200, req);
  }

  // ── folderLabel: a display name; nothing in R2 changes ─────────────────
  if (body.op === 'folderLabel') {
    const { data, error } = await admin().rpc('folder_label_set', {
      p_folder: String(body.folder ?? ''), p_label: String(body.label ?? ''), p_actor: who.id,
    });
    if (error) return json({ error: 'label_failed', detail: error.message }, 500, req);
    if (data === 'no_folder') return json({ error: 'no_folder' }, 400, req);
    return json({ ok: true, result: data }, 200, req);
  }

  // ── trashObjects / trashRestore: the seven-day bin ─────────────────────
  //
  // `confirm` must be DELETE, typed — the same as deleting a title. The
  // database refuses any file a title uses, by name, and does it again on the
  // day the bin is emptied.
  if (body.op === 'trashObjects') {
    if (String(body.confirm ?? '') !== 'DELETE') return json({ error: 'not_confirmed' }, 400, req);
    const items = (Array.isArray(body.items) ? body.items as Array<Record<string, unknown>> : [])
      .filter((o) => (o.bucket === MEDIA_BUCKET || o.bucket === PUBLIC_BUCKET) &&
        typeof o.key === 'string' && o.key && !String(o.key).includes('..'))
      .map((o) => ({ bucket: String(o.bucket), key: String(o.key) }))
      .slice(0, 500);
    if (!items.length) return json({ error: 'nothing_to_delete' }, 400, req);
    const { data, error } = await admin().rpc('r2_trash_add', {
      p_items: items, p_actor: who.id, p_reason: 'deleted on the Files page', p_days: 7,
    });
    if (error) return json({ error: 'bin_failed', detail: error.message }, 500, req);
    const out = (data ?? {}) as Record<string, unknown>;
    if (out.error) return json({ error: String(out.error) }, 403, req);
    return json({ ok: true, ...out }, 200, req);
  }
  if (body.op === 'trashRestore') {
    const { data, error } = await admin().rpc('r2_trash_restore', {
      p_id: Number(body.id ?? 0), p_actor: who.id,
    });
    if (error) return json({ error: 'restore_failed', detail: error.message }, 500, req);
    if (data !== 'restored') return json({ error: String(data) }, 409, req);
    return json({ ok: true }, 200, req);
  }

  // ── moves ───────────────────────────────────────────────────────────────
  //
  // moveStart plans and records; moveCopy copies (a step at a time, the page
  // calling it until every file is done); moveSwitch changes every reference
  // in one transaction and bins the old files for seven days; moveCancel
  // stops before the switch. Two kinds:
  //   folder  rename a folder — every file whose folder is exactly `from`
  //   title   gather one title's files into a folder of its own — which is
  //           how the old flat `v/…` and `p/…` uploads get tidied
  if (body.op === 'moveList') {
    const since = new Date(Date.now() - 14 * 86400000).toISOString();
    const { data, error } = await admin().from('r2_moves')
      .select('id,mode,from_folder,to_folder,title_id,state,objects,requested_email,created_at,switched_at')
      .or(`state.eq.copying,created_at.gt.${since}`)
      .order('created_at', { ascending: false }).limit(20);
    if (error) return json({ error: 'moves_failed', detail: error.message }, 500, req);
    return json({ moves: data ?? [] }, 200, req);
  }

  if (body.op === 'moveStart') {
    const mode = body.mode === 'title' ? 'title' : 'folder';
    const to = slugifyPath(String(body.to ?? ''));
    if (!to) return json({ error: 'bad_folder' }, 400, req);
    // TYPED, LIKE A DELETE: the new folder name, a second time.
    if (String(body.confirm ?? '') !== to) return json({ error: 'not_confirmed' }, 400, req);
    const db = admin();
    const objects: Array<{ bucket: string; from: string; to: string; bytes: number | null; done: boolean }> = [];
    let from = '';
    let titleId: string | null = null;

    // A FILM WHOSE ORIGINAL IS ONLY IN TELEGRAM (migration 029) has nothing
    // in R2 to copy, and a move would leave its key — where a restore puts
    // it back — in the old folder. Bring it back first.
    {
      const owner = mode === 'folder'
        ? (await db.from('titles').select('id').eq('slug', String(body.from ?? '')).maybeSingle()).data
        : { id: String(body.titleId ?? '') };
      if (owner?.id) {
        const { data: away } = await db.from('title_assets').select('id')
          .eq('title_id', owner.id).neq('master_state', 'r2').limit(1);
        if ((away ?? []).length) return json({ error: 'master_in_telegram' }, 409, req);
      }
    }

    if (mode === 'folder') {
      from = String(body.from ?? '');
      if (!from || from.includes('..') || from.startsWith('/')) return json({ error: 'bad_folder' }, 400, req);
      for (const bucket of [MEDIA_BUCKET, PUBLIC_BUCKET]) {
        let token = '';
        for (let page = 0; page < 50; page++) {
          const got = await listBucket(bucket, from + '/', token);
          if ('error' in got) return json(got, 502, req);
          for (const o of got.items) {
            // EXACTLY THIS FOLDER: `movies` must not take `movies/solar` with it.
            if (folderOf(o.key) !== from) continue;
            objects.push({ bucket, from: o.key, to: to + o.key.slice(from.length), bytes: o.bytes, done: false });
          }
          if (!got.next) break;
          token = got.next;
        }
      }
    } else {
      titleId = String(body.titleId ?? '');
      const { data: t } = await db.from('titles').select('id,slug').eq('id', titleId).maybeSingle();
      if (!t) return json({ error: 'no_such_title' }, 404, req);
      from = String(t.slug ?? '');
      const { data: assets } = await db.from('title_assets')
        .select('id,bucket,object_key,thumb_key').eq('title_id', titleId);
      const ids = ((assets ?? []) as Array<Record<string, unknown>>).map((a) => String(a.id));
      const { data: rungs } = ids.length
        ? await db.from('asset_renditions').select('object_key').in('asset_id', ids)
        : { data: [] };
      const seen = new Set<string>();
      const add = (bucket: string, key: string) => {
        if (!key || seen.has(key)) return;
        seen.add(key);
        const m = /^(.*)\/(video|photo|thumb)\/([^/]+)$/.exec(key);
        const kind = m ? m[2] : (bucket === MEDIA_BUCKET ? 'video' : 'photo');
        const name = m ? m[3] : key.split('/').pop() ?? '';
        if (!name || name.includes('..')) return;
        const dest = `${to}/${kind}/${name}`;
        if (dest !== key) objects.push({ bucket, from: key, to: dest, bytes: null, done: false });
      };
      for (const a of (assets ?? []) as Array<Record<string, unknown>>) {
        add(String(a.bucket ?? MEDIA_BUCKET), String(a.object_key ?? ''));
        if (a.thumb_key) add(PUBLIC_BUCKET, String(a.thumb_key));
      }
      for (const r of (rungs ?? []) as Array<Record<string, unknown>>) add(MEDIA_BUCKET, String(r.object_key ?? ''));
    }

    const { data, error } = await db.rpc('r2_move_create', {
      p_actor: who.id, p_mode: mode, p_from: from || null, p_to: to,
      p_title: titleId, p_objects: objects,
    });
    if (error) return json({ error: 'move_failed', detail: error.message }, 500, req);
    const out = (data ?? {}) as Record<string, unknown>;
    if (out.error) return json({ error: String(out.error) }, 409, req);
    return json({ ok: true, id: out.id, files: objects.length,
      bytes: objects.reduce((a, o) => a + (o.bytes ?? 0), 0) }, 200, req);
  }

  if (body.op === 'moveCopy') {
    const db = admin();
    const { data: m } = await db.from('r2_moves').select('*').eq('id', String(body.id ?? '')).maybeSingle();
    if (!m) return json({ error: 'no_such_move' }, 404, req);
    if (m.state !== 'copying') return json({ error: 'not_copying', state: m.state }, 409, req);
    const objects = (m.objects ?? []) as Array<Record<string, unknown>>;
    // Well inside the 150 s an edge function may run; the page calls again.
    const deadline = Date.now() + 90000;
    for (let i = 0; i < objects.length && Date.now() < deadline; i++) {
      const o = objects[i];
      if (o.done === true) continue;
      const bucket = String(o.bucket);
      const from = String(o.from);
      const to = String(o.to);
      try {
        const srcSize = await objectSize(bucket, from);
        const dstSize = await objectSize(bucket, to);
        // DONE ALREADY — a copy that finished before the page lost its answer.
        if (dstSize !== null && (srcSize === null || dstSize === srcSize)) {
          o.done = true;
          o.bytes = dstSize;
        } else if (srcSize === null) {
          throw new Error('source_missing');
        } else {
          const step = await copyStep(bucket, from, to, srcSize,
            (o.mp ?? null) as Record<string, unknown> | null, deadline);
          if ('state' in step) {
            o.mp = step.state;
            await db.rpc('r2_move_progress', { p_id: m.id, p_index: i, p_patch: { mp: step.state, bytes: srcSize } });
            break;
          }
          // CHECKED: the copy is the size of the original.
          const after = await objectSize(bucket, to);
          if (after !== srcSize) throw new Error('copy_size_mismatch');
          o.done = true;
          o.bytes = srcSize;
        }
        await db.rpc('r2_move_progress', { p_id: m.id, p_index: i, p_patch: { done: true, bytes: o.bytes, error: null } });
      } catch (e) {
        const msg = String((e as Error).message ?? e).slice(0, 200);
        await db.rpc('r2_move_progress', { p_id: m.id, p_index: i, p_patch: { error: msg } });
        return json({ error: 'copy_failed', detail: msg, file: from }, 502, req);
      }
    }
    const done = objects.filter((o) => o.done === true).length;
    return json({
      done, total: objects.length, finished: done === objects.length,
      bytesDone: objects.filter((o) => o.done === true).reduce((a, o) => a + (Number(o.bytes) || 0), 0),
    }, 200, req);
  }

  if (body.op === 'moveSwitch' || body.op === 'moveCancel') {
    const db = admin();
    const id = String(body.id ?? '');
    if (body.op === 'moveCancel') {
      // A big file's half-finished multipart copy is not an object yet and
      // so not in the bin; abort it here, best effort.
      const { data: m } = await db.from('r2_moves').select('objects,state').eq('id', id).maybeSingle();
      for (const o of ((m?.objects ?? []) as Array<Record<string, unknown>>)) {
        const mp = o.mp as Record<string, unknown> | undefined;
        if (o.done !== true && mp && mp.uploadId) {
          try {
            const d = await signRequest('DELETE', String(o.bucket), String(o.to), { uploadId: String(mp.uploadId) }, '');
            await fetch(d.url, { method: 'DELETE', headers: d.headers });
          } catch { /* R2 drops it after seven days anyway */ }
        }
      }
    }
    const { data, error } = await db.rpc(body.op === 'moveSwitch' ? 'r2_move_switch' : 'r2_move_cancel',
      { p_id: id, p_actor: who.id });
    if (error) return json({ error: 'move_failed', detail: error.message }, 500, req);
    const out = (data ?? {}) as Record<string, unknown>;
    if (out.error) return json({ error: String(out.error) }, 409, req);
    return json({ ok: true, ...out }, 200, req);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // THE STORAGE PAGE — Telegram is the archive, R2 the working set (029)
  // ═══════════════════════════════════════════════════════════════════════
  //
  // Every decision is the database's: these ops pass the actor along and
  // turn the one-word answer into a status. The functions check the role
  // again, and refuse anything that would leave a film with no copy.

  if (body.op === 'storageOverview') {
    const db = admin();
    // New Telegram copies are recorded on every runner tick; doing it here
    // too means a film filed a minute ago shows its copy straight away.
    await db.rpc('vault_sync');
    const [ov, st, jobs, bytes, scans] = await Promise.all([
      db.rpc('storage_overview'),
      db.from('admin_settings').select('auto_offload,storage_alert_gb,storage_noticed_at,storage_notice').limit(1).maybeSingle(),
      db.from('vault_jobs').select('id,asset_id,kind,state,attempts,note,created_at,finished_at')
        .order('created_at', { ascending: false }).limit(30),
      db.rpc('storage_bytes'),
      db.from('r2_scans').select('bucket,finished_at,objects,bytes'),
    ]);
    if (ov.error) return json({ error: 'storage_failed', detail: ov.error.message }, 500, req);
    return json({
      titles: ov.data ?? [], settings: st.data ?? {}, jobs: jobs.data ?? [],
      catalogueBytes: Number(bytes.data ?? 0) || 0, scans: scans.data ?? [],
      // The same price the Files page shows, plus Infrequent Access, so the
      // page can show why it is not used.
      price: { perGbMonth: 0.015, freeGb: 10, iaPerGbMonth: 0.01, iaRetrievalPerGb: 0.01, iaMinDays: 30 },
    }, 200, req);
  }

  if (body.op === 'storagePin') {
    const id = String(body.titleId ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'no_title' }, 400, req);
    const { error } = await admin().from('titles').update({ pinned: body.pinned === true }).eq('id', id);
    if (error) return json({ error: 'save_failed', detail: error.message }, 500, req);
    return json({ ok: true, pinned: body.pinned === true }, 200, req);
  }

  if (body.op === 'masterOffload' || body.op === 'masterKeep') {
    const id = String(body.assetId ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'no_such_asset' }, 400, req);
    const fn = body.op === 'masterOffload' ? 'master_offload' : 'master_keep';
    const { data, error } = await admin().rpc(fn, { p_asset: id, p_actor: who.id });
    if (error) return json({ error: 'storage_failed', detail: error.message }, 500, req);
    const word = String(data ?? '');
    if (!['offloaded', 'kept', 'restoring'].includes(word)) return json({ error: word || 'storage_failed' }, 409, req);
    return json({ ok: true, result: word }, 200, req);
  }

  if (body.op === 'titleArchive' || body.op === 'titleRestore') {
    const id = String(body.titleId ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'no_title' }, 400, req);
    // TYPED, like a delete: an archive takes a title out of the app.
    if (body.op === 'titleArchive' && String(body.confirm ?? '') !== 'ARCHIVE') {
      return json({ error: 'not_confirmed' }, 400, req);
    }
    const fn = body.op === 'titleArchive' ? 'title_archive' : 'title_restore';
    const { data, error } = await admin().rpc(fn, { p_title: id, p_actor: who.id });
    if (error) return json({ error: 'storage_failed', detail: error.message }, 500, req);
    const out = (data ?? {}) as Record<string, unknown>;
    if (out.error) return json({ error: String(out.error), films: out.films ?? null }, 409, req);
    return json({ ok: true, ...out }, 200, req);
  }

  if (body.op === 'titleRestoreFinish') {
    const id = String(body.titleId ?? '');
    const { data, error } = await admin().rpc('title_restore_finish', { p_title: id, p_actor: who.id });
    if (error) return json({ error: 'storage_failed', detail: error.message }, 500, req);
    if (data !== 'finished') return json({ error: String(data) }, 409, req);
    return json({ ok: true }, 200, req);
  }

  if (body.op === 'vaultCheck') {
    const id = String(body.titleId ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'no_title' }, 400, req);
    const db = admin();
    const { data: films } = await db.from('title_assets').select('id').eq('title_id', id).eq('kind', 'video');
    let asked = 0;
    for (const f of (films ?? []) as Array<{ id: string }>) {
      const { error } = await db.rpc('vault_request', { p_asset: f.id, p_kind: 'verify', p_actor: who.id });
      if (!error) asked++;
    }
    return json({ ok: true, asked }, 200, req);
  }

  if (body.op === 'storageSettings') {
    const patch: Record<string, unknown> = {};
    if (typeof body.autoOffload === 'boolean') patch.auto_offload = body.autoOffload;
    if (body.alertGb !== undefined) {
      const gb = Number(body.alertGb);
      if (!Number.isFinite(gb) || gb < 0 || gb > 100000) return json({ error: 'bad_alert' }, 400, req);
      patch.storage_alert_gb = gb;
    }
    if (!Object.keys(patch).length) return json({ error: 'empty_patch' }, 400, req);
    const { error } = await admin().from('admin_settings').update(patch).eq('id', true);
    if (error) return json({ error: 'settings_failed', detail: error.message }, 500, req);
    return json({ ok: true }, 200, req);
  }

  return json({ error: 'unknown_op' }, 400, req);
}

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
