// ingest — the queue between "the operator forwarded a film to the bot" and
// "it is in R2 and the transcoder has it".
//
// ═══════════════════════════════════════════════════════════════════════
// THE PROBLEM THIS SOLVES
// ═══════════════════════════════════════════════════════════════════════
//
// The operator works from a phone, and the films are gigabytes. Uploading one
// from a handset over a Myanmar connection is hours of holding the screen
// awake — the console does it, and does it in parts since C1, but it is still
// the phone's uplink and the phone's battery.
//
// The film is usually ALREADY on Telegram, on a server with a fast link to
// everywhere. So the shortest path does not go through the phone at all:
// forward the message to a bot, and have something with real bandwidth move
// the bytes. The operator's part becomes one tap.
//
//   webhook — Telegram tells us a file was forwarded. One row, queued.
//   claim   — a GitHub Actions runner asks for work and is handed a download
//             token and one presigned PUT.
//   done    — the runner reports; the catalogue row is created HERE, and the
//             transcode is queued in the same breath.
//   attach  — the console points a finished ingest at a title, afterwards.
//
// ═══════════════════════════════════════════════════════════════════════
// WHY MTProto AND NOT A LOCAL BOT API SERVER
// ═══════════════════════════════════════════════════════════════════════
//
// The CLOUD Bot API refuses to download anything over 20 MB. That limit is
// the whole reason this looked impossible: 20 MB is a photo, not a film.
//
// The obvious answer is a SELF-HOSTED Bot API server, which serves files up
// to 2000 MB. It was the plan, and it does not work here. Moving a bot to a
// local server requires calling `logOut` on the cloud API first, and after
// that the cloud API stops delivering that bot's updates — which is exactly
// how the forwarded film reaches this function. The download would have
// worked and the webhook would have gone silent.
//
// So the runner speaks MTProto instead. A bot can sign in over MTProto with
// `api_id`, `api_hash` and its own token; that session is SEPARATE from the
// Bot API's, so the webhook carries on untouched, and MTProto has no 20 MB
// limit. Still NO USER SESSION STRING, which is the thing worth being careful
// about — a session string is the operator's whole Telegram account, and a
// bot token is a bot.
//
// The runner is given the CHAT AND MESSAGE rather than a file id. A Bot API
// file id is an encoding of an MTProto file location and libraries do decode
// it, but fetching the message and downloading its media depends on nothing
// about that encoding.
//
// TELEGRAM'S OWN 2 GB CEILING IS WHY THERE IS NO MULTIPART HERE. R2 takes a
// single PUT up to 5 GiB, comfortably more than Telegram can ever hand over,
// so one presigned URL does every job this path can receive. A master bigger
// than that cannot come through Telegram at all and still belongs in the
// console's own multipart uploader. Said plainly because the instinct is to
// mirror C1's multipart machinery here, and it would be several hundred lines
// that can never execute.
//
// ═══════════════════════════════════════════════════════════════════════
// WHAT THIS FUNCTION NEVER HOLDS
// ═══════════════════════════════════════════════════════════════════════
//
// The runner gets a presigned PUT scoped to one object, and a Telegram file
// path scoped to one file. It never receives an R2 key, a service key, or
// anything that can write the catalogue — the catalogue row is made here, by
// a database function, after the bytes are confirmed. This repository is
// public and Actions logs on it are public.

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID')!;
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID')!;
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY')!;
const MEDIA_BUCKET = Deno.env.get('R2_BUCKET') ?? 'innocent-media';

// TWO BUCKETS, AND A PHOTO IN THE WRONG ONE IS A BROKEN IMAGE. Video is
// private and reached through a signed URL; artwork is public and served
// straight off the public bucket's domain. The `title_media` view builds a
// photo's URL as `public_asset_base() || object_key` and NEVER LOOKS AT THE
// `bucket` COLUMN, so a photo whose bytes went to the media bucket produces a
// URL that 404s, in the app, with nothing anywhere saying why. studio.ts has
// picked between them on `kind` since it was written; this file did not, and
// put everything in the media bucket.
const PUBLIC_BUCKET = Deno.env.get('R2_PUBLIC_BUCKET') ?? 'innocent-public';

// Where the public bucket answers from. The same base `public_asset_base()`
// builds artwork URLs on, so an APK put here is served by the edge that is
// already delivering every poster in the app.
const PUBLIC_BASE = Deno.env.get('R2_PUBLIC_BASE') ??
  'https://pub-18c62521649645be87d4d36225021e15.r2.dev/';

/// Which bucket a kind belongs in. One place, because the webhook and the
/// presigned PUT have to agree and the row is written by one and signed by
/// the other.
function bucketFor(kind: string): string {
  return kind === 'video' ? MEDIA_BUCKET : PUBLIC_BUCKET;
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SB_ANON_KEY') ??
  Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// The one secret the runner holds. Absent means the runner half is off: files
// still queue, they simply wait, and the console says so.
const RUNNER_SECRET = Deno.env.get('INGEST_SECRET') ?? '';

// The bot's token, used only to answer the operator in Telegram. The runner
// gets it separately as an Actions secret; it is NOT echoed in any response.
const BOT_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';

// What `setWebhook` was given as `secret_token`. Telegram sends it back in a
// header on every delivery, and it is the ONLY thing standing between this
// endpoint and anyone who finds the URL — the function has to be reachable
// without a JWT for Telegram to call it at all.
const WEBHOOK_SECRET = Deno.env.get('TELEGRAM_WEBHOOK_SECRET') ?? '';

// WHICH TELEGRAM ACCOUNT MAY FILL THE QUEUE. A bot that anybody can find can
// be messaged by anybody, and without this any stranger could make this
// project download their file into the operator's bucket, at the operator's
// expense. Numeric chat ids, comma separated.
const TG_CHATS = (Deno.env.get('TELEGRAM_CHAT_IDS') ?? '')
  .split(',').map((s) => s.trim()).filter(Boolean);

const ALLOWED_ORIGINS = (Deno.env.get('STUDIO_ORIGINS') ??
  'https://yannmh007.github.io')
  .split(',').map((s) => s.trim()).filter(Boolean);

const enc = new TextEncoder();

// --- SigV4, the same as every other function here -------------------------
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

async function presign(
  method: 'GET' | 'PUT' | 'DELETE', objectKey: string, seconds: number, bucket: string,
): Promise<string> {
  const host = `${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/auto/s3/aws4_request`;
  const params: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${R2_ACCESS_KEY_ID}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(seconds),
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalQuery = Object.keys(params).sort()
    .map((k) => `${rfc3986(k)}=${rfc3986(params[k])}`).join('&');
  const canonicalPath = `/${bucket}/${encodeKey(objectKey)}`;
  const canonicalRequest = [
    method, canonicalPath, canonicalQuery, `host:${host}\n`, 'host',
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

// --- talking to our own database ------------------------------------------
async function rpc(name: string, body: unknown): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body ?? {}),
  });
  if (!res.ok) throw new Error(`${name} ${res.status} ${await res.text()}`);
  // A function that returns nothing answers with no body (204).
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
}

const json = (body: unknown, status: number, req: Request) => {
  const origin = req.headers.get('Origin') ?? '';
  const cors: Record<string, string> = ALLOWED_ORIGINS.includes(origin)
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

/// Constant time, because a comparison that returns early on the first wrong
/// character tells an attacker how much of the secret they have.
function sameSecret(given: string, expected: string): boolean {
  if (!expected || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

// --- object keys, the same shape studio.ts mints --------------------------
//
// One folder per title, `<folder>/video/<stamp>-<stem>-<rand>.<ext>`, because
// everything else in the bucket is already organised that way and a second
// naming scheme would mean the console's own listing, the unused-file report
// and the R2 prefix view all disagreeing about where a film lives.
//
// The name is REBUILT and never trusted. Telegram hands over whatever the
// sender called the file — spaces, brackets, Burmese, a leading dot, `../` if
// somebody is trying — and an object key is a path.
function slugify(raw: string): string {
  return String(raw ?? '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
}

/// Everything in a key EXCEPT the folder: `<kind>/<date>-<slug>-<rand>.<ext>`.
///
/// SPLIT OUT BECAUSE ONLY THE FOLDER IS EVER IN QUESTION. A file sent as part
/// of an album may not know its folder yet — the caption is on one message of
/// the group and this may not be that one — so the database decides the folder
/// across the whole group and is handed this tail to put in front of. The tail
/// is minted here rather than there because it has to keep agreeing with
/// `isMintedKey` in studio.ts, which is the console's gate on a key it will
/// later be asked to complete, abort or list.
function keyTail(prefix: string, filename: string): string {
  const dot = filename.lastIndexOf('.');
  const stem = slugify(dot > 0 ? filename.slice(0, dot) : filename) || 'file';
  const ext = (dot > 0 ? filename.slice(dot + 1) : '')
    .toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 8);
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const rand = crypto.randomUUID().slice(0, 8);
  return `${prefix}/${stamp}-${stem}-${rand}${ext ? '.' + ext : ''}`;
}

function safeKey(prefix: string, filename: string, folder: string): string {
  return `${slugify(folder) || 'inbox'}/${keyTail(prefix, filename)}`;
}

/// Tell the operator what happened, in Telegram, where they are already
/// looking. Best effort in every direction: a bot that cannot be reached must
/// not fail the enqueue that already succeeded.
async function say(chatId: number | string, text: string): Promise<void> {
  if (!BOT_TOKEN || !chatId) return;
  try {
    await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text: text.slice(0, 900) }),
    });
  } catch {
    // Nothing to do about it and nothing that should fail because of it.
  }
}

/// The file out of a Telegram message, whichever way it was sent.
///
/// FOUR SHAPES AND THEY ARE NOT INTERCHANGEABLE. A film sent as a VIDEO is
/// re-encoded by Telegram's clients and carries width, height and duration; a
/// film sent as a DOCUMENT is byte-for-byte the original and carries none of
/// them. The operator should send documents — the whole point is the master —
/// but a video is accepted because refusing one with "send it differently"
/// after an hour of uploading would be cruel.
///
/// `video_note` and `animation` are deliberately not handled: neither is ever
/// a film somebody meant to publish, and treating a round selfie video as a
/// master would put it in the catalogue.
function fileOf(msg: Record<string, unknown>): {
  id: string; uniq: string; name: string; bytes: number; mime: string;
  duration: number | null; width: number | null; height: number | null;
  kind: string;
} | null {
  const doc = msg.document as Record<string, unknown> | undefined;
  const vid = msg.video as Record<string, unknown> | undefined;
  const photos = msg.photo as Array<Record<string, unknown>> | undefined;
  const pick = doc ?? vid ??
    (Array.isArray(photos) && photos.length
      // The last entry is the largest size Telegram kept.
      ? photos[photos.length - 1]
      : undefined);
  if (!pick) return null;
  const id = String(pick.file_id ?? '');
  const uniq = String(pick.file_unique_id ?? '');
  if (!id || !uniq) return null;

  const mime = String(pick.mime_type ?? (photos && !doc && !vid ? 'image/jpeg' : ''));
  const isPhoto = !doc && !vid ? true : mime.startsWith('image/');
  const name = String(pick.file_name ?? '') ||
    (isPhoto ? `${uniq}.jpg` : `${uniq}.mp4`);
  return {
    id,
    uniq,
    name,
    bytes: Number(pick.file_size ?? 0) || 0,
    mime,
    duration: pick.duration === undefined ? null : Number(pick.duration) || null,
    width: pick.width === undefined ? null : Number(pick.width) || null,
    height: pick.height === undefined ? null : Number(pick.height) || null,
    kind: isPhoto ? 'photo' : 'video',
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
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
    return json({ ok: true, service: 'ingest' }, 200, req);
  }
  if (req.method !== 'POST') return json({ error: 'method' }, 405, req);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { body = {}; }

  // ── webhook ──────────────────────────────────────────────────────────────
  //
  // Telegram's delivery. Recognised by the header rather than by an `op`,
  // because Telegram decides the body and will never send one.
  //
  // ALWAYS ANSWERS 200. Telegram retries a delivery it considers failed, and
  // a retry of a file that is already queued is noise at best; every refusal
  // below is a 200 with a reason nobody but the log reads. The one thing that
  // must not happen is Telegram redelivering the same film all day.
  const tgSecret = req.headers.get('X-Telegram-Bot-Api-Secret-Token');
  if (tgSecret !== null) {
    if (!sameSecret(tgSecret, WEBHOOK_SECRET)) {
      // Not Telegram, or a stale secret. Nothing is said back: a caller
      // guessing the URL learns nothing from the shape of this response.
      return json({ ok: true }, 200, req);
    }
    const msg = (body.message ?? body.channel_post ??
      (body.edited_message as unknown)) as Record<string, unknown> | undefined;
    if (!msg) return json({ ok: true, skipped: 'no_message' }, 200, req);

    const chat = (msg.chat ?? {}) as Record<string, unknown>;
    const chatId = String(chat.id ?? '');
    // A bot anyone can find can be messaged by anyone. Without this, a
    // stranger could make this project download their file into the
    // operator's bucket at the operator's expense.
    if (!TG_CHATS.includes(chatId)) {
      return json({ ok: true, skipped: 'not_an_operator_chat' }, 200, req);
    }

    const file = fileOf(msg);
    if (!file) {
      await say(chatId, 'Send a film as a FILE (document) and it will be '
        + 'fetched. Add a caption to choose the folder.');
      return json({ ok: true, skipped: 'no_file' }, 200, req);
    }

    // The caption is the folder. It is the only thing a phone can type in one
    // gesture while forwarding, and a folder is what the bucket is organised
    // by; picking the TITLE happens in the console afterwards, because
    // matching a card by a typed name is a guess and this should not guess
    // about where a film ends up.
    const caption = String(msg.caption ?? '').split('\n')[0] ?? '';

    // WHICH ALBUM THIS WAS SENT IN, and it is the difference between the
    // folder working and three files out of four landing in `inbox`.
    //
    // Telegram does NOT deliver a media group as one update. It sends one per
    // file, they share `media_group_id`, and the caption is attached to
    // exactly one of them — so reading `msg.caption` per message, which is
    // right for a single forwarded film, silently loses the folder for every
    // other file of an album. Sending a title's artwork as an album is the
    // natural gesture from a phone, so this was most of the traffic.
    //
    // The folder cannot be sorted out afterwards either: the object key is
    // minted before the bytes move and the runner is handed a presigned PUT
    // for that exact key. So it is agreed at INSERT time, in one statement,
    // by `enqueue_ingest` — which inherits a sibling's folder when this
    // message has no caption, and moves siblings already parked in `inbox`
    // when it does. See migration 023 for why that needs a lock.
    const mediaGroup = String(msg.media_group_id ?? '');

    let queued: Record<string, unknown>;
    try {
      const rows = await rpc('enqueue_ingest', {
        p_file_id: file.id,
        p_unique_id: file.uniq,
        p_chat_id: Number(chatId) || null,
        p_message_id: Number(msg.message_id ?? 0) || null,
        p_file_name: file.name,
        p_mime: file.mime || null,
        p_bytes: file.bytes || null,
        p_duration: file.duration,
        p_width: file.width,
        p_height: file.height,
        p_kind: file.kind,
        p_bucket: bucketFor(file.kind),
        p_folder: slugify(caption),
        p_key_tail: keyTail(file.kind, file.name),
        p_media_group: mediaGroup,
        // THE WHOLE CAPTION, not just the line the folder came from. The
        // operator types the name, a blank line and three paragraphs of
        // synopsis in Telegram while forwarding; everything after the first
        // line used to be dropped here, so it had to be typed a second time
        // into a phone. The console reads it back and fills the form with it.
        p_caption: String(msg.caption ?? ''),
      }) as Array<Record<string, unknown>>;
      queued = (Array.isArray(rows) ? rows[0] : rows) ?? {};
    } catch {
      await say(chatId, 'Could not queue that one. Try again in a minute.');
      return json({ ok: true, error: 'insert_failed' }, 200, req);
    }

    if (String(queued.status ?? '') === 'duplicate') {
      // Forwarding the same film twice is the ordinary accident, not an
      // unusual one, and the second one costing nothing is the point of the
      // unique index behind this.
      await say(chatId, 'Already queued — same file.');
      return json({ ok: true, skipped: 'duplicate' }, 200, req);
    }

    const mb = file.bytes ? Math.round(file.bytes / 1048576) : 0;
    const moved = Number(queued.moved ?? 0) || 0;
    await say(chatId,
      `Queued: ${file.name}${mb ? ` (${mb} MB)` : ''}\n`
      // THE FOLDER IT ACTUALLY WENT IN, which is not always the one this
      // message carried. Reporting the caption was true and useless: for
      // three files of a four-file album it said `inbox`, which is the one
      // thing the operator needed to not be true.
      + `Folder: ${String(queued.folder ?? 'inbox')}\n`
      + (moved ? `Moved ${moved} more from this album into it.\n` : '')
      // NOT "within five minutes", which is what this said and what the
      // cron expression claims. GitHub runs a free public repository's
      // schedule when it gets to it — fourteen to twenty minutes apart,
      // measured — and a promise the system cannot keep is how somebody comes
      // to believe the thing is broken and forwards it all again.
      + 'A runner usually picks it up within twenty minutes, and takes the '
      + 'whole queue when it does. Choose the title in the console after.');
    return json({ ok: true, queued: true }, 200, req);
  }

  const op = String(body.op ?? '');

  // ── claim ────────────────────────────────────────────────────────────────
  //
  // Answers `{}` when there is nothing to do, which is the common case.
  if (op === 'claim') {
    const given = (req.headers.get('Authorization') ?? '').replace(/^Bearer /i, '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);

    const rows = await rpc('claim_ingest', {}) as Array<Record<string, unknown>>;
    if (!Array.isArray(rows) || !rows.length) return json({}, 200, req);
    const job = rows[0];

    return json({
      job_id: job.job_id,
      // CHAT AND MESSAGE, so the runner can fetch the message and download
      // its media without decoding a Bot API file id. The file id goes too,
      // as a fallback for a library that prefers it. No bot token is in this
      // response; the runner already holds one as an Actions secret.
      tg_chat_id: job.tg_chat_id ?? null,
      tg_message_id: job.tg_message_id ?? null,
      tg_file_id: job.tg_file_id,
      file_name: job.file_name ?? '',
      bytes: job.bytes ?? null,
      // TWENTY-FOUR HOURS. The download from Telegram and the upload to R2 are
      // one pass on a runner with a fast link, so this is generous — but a URL
      // that expires mid-transfer throws away everything already moved, and
      // the whole job is a single object.
      // Signed for the bucket the ROW names. Signing the media bucket for a
      // photo would have R2 refuse the PUT — which is the good failure; the
      // bad one was writing the photo there and serving a 404 for ever.
      put_url: await presign('PUT', String(job.object_key ?? ''), 86400,
        String(job.bucket ?? MEDIA_BUCKET)),
      done_url: `${SUPABASE_URL}/functions/v1/ingest`,
    }, 200, req);
  }

  // ── done ─────────────────────────────────────────────────────────────────
  //
  // The catalogue row is created HERE, by finish_ingest, and only on success.
  // A row written when the job was queued would be a title that fails to play
  // for the hour the transfer takes.
  if (op === 'done') {
    const given = String(body.token ?? '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);
    const jobId = String(body.job_id ?? '');
    if (!jobId) return json({ error: 'no_job' }, 400, req);

    const ok = body.ok === true;
    const result = await rpc('finish_ingest', {
      p_job: jobId,
      p_ok: ok,
      p_note: String(body.note ?? '').slice(0, 300),
      // What R2 accepted, not what Telegram claimed. They should agree; the
      // bucket is the one that is right if they ever do not.
      p_bytes: Number(body.bytes ?? 0) || null,
    });
    return json({ ok: true, result }, 200, req);
  }

  // ── defer ────────────────────────────────────────────────────────────────
  //
  // Give a claimed job back WITHOUT spending an attempt on it.
  //
  // For one reason only: Telegram answered FLOOD_WAIT. That is Telegram's
  // scheduling, not a verdict on the file, and reporting it through `done`
  // with ok=false counted it as one of the job's three tries. The first run
  // that drained a whole queue signed in once per file, was throttled, and
  // burned three tries on each of seven good files in under a minute — every
  // one of them marked dead for a wait of about seven minutes. The runner
  // signs in once per run now; this is what keeps a wait from killing a film
  // on the day Telegram is slow anyway.
  //
  // Runner-only, with the same token as `done`. `defer_ingest` refuses any
  // job that is not currently claimed, so this cannot be used to reset a
  // failed job's attempts and run it a fourth time.
  if (op === 'defer') {
    const given = String(body.token ?? '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);
    const jobId = String(body.job_id ?? '');
    if (!jobId) return json({ error: 'no_job' }, 400, req);
    const seconds = Math.max(0, Math.floor(Number(body.seconds ?? 0)) || 0);
    const result = await rpc('defer_ingest', { p_job: jobId, p_seconds: seconds });
    return json({ ok: true, result }, 200, req);
  }

  // ── release ──────────────────────────────────────────────────────────────
  //
  // A presigned PUT for an APK, in the PUBLIC bucket.
  //
  // ═══════════════════════════════════════════════════════════════════════
  // WHY THE UPDATE IS NOT SERVED FROM GITHUB ANY MORE
  // ═══════════════════════════════════════════════════════════════════════
  //
  // A GitHub release asset is a redirect to Azure blob storage, and from
  // Myanmar that path is not reliable for ninety megabytes: the transfer is
  // cut off part way, repeatedly, at roughly the same place. The operator's
  // own update failed that way over and over while every poster and every
  // film in the app arrived without trouble — because those come off
  // Cloudflare, which has an edge near these users and Azure does not.
  //
  // So the APK goes where the artwork already goes. The GitHub release is
  // still cut and is still the record of what was built; this is the copy
  // people download.
  //
  // THE RUNNER STILL HOLDS NO BUCKET CREDENTIALS. It asks for a signature
  // and gets one URL, for one object, for an hour — the same shape as the
  // ingest path above, and for the same reason: this repository is public.
  //
  // THE NAME IS A PATTERN, NOT A STRING THE CALLER CHOOSES. Anything holding
  // the runner secret could otherwise write anywhere in a bucket the whole
  // app reads, including over a poster. `innocent-<x>.<y>.<z>-<code>.apk`
  // and nothing else, under `apk/`.
  if (op === 'release') {
    const given = (req.headers.get('Authorization') ?? '').replace(/^Bearer /i, '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);

    const name = String(body.name ?? '');
    if (!/^innocent-\d+\.\d+\.\d+-\d+\.apk$/.test(name)) {
      return json({ error: 'bad_name' }, 400, req);
    }
    const key = `apk/${name}`;
    return json({
      // An hour. The upload is one PUT from a runner with a fast link, and a
      // signature that outlives the job it was minted for is a signature
      // somebody can find in a log and reuse.
      put_url: await presign('PUT', key, 3600, PUBLIC_BUCKET),
      public_url: `${PUBLIC_BASE}${key}`,
    }, 200, req);
  }

  // ── purge ────────────────────────────────────────────────────────────────
  //
  // EMPTY THE R2 BIN — what the Files page put there seven days ago (or a
  // cancelled move's copies, at once). Called by the same runner as `claim`,
  // on every run, with the same secret; it answers at once when nothing is
  // due. `r2_trash_due` checks AGAIN that nothing uses each file and takes
  // back out of the bin anything that is in use by now, so a file attached to
  // a title during its week in the bin is never deleted.
  //
  // Here and not in the console: deletes run whether or not anybody opens the
  // page, and the runner holds no bucket credentials — this function signs
  // each DELETE itself.
  if (op === 'purge') {
    const given = (req.headers.get('Authorization') ?? '').replace(/^Bearer /i, '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);
    const due = (await rpc('r2_trash_due', { p_limit: 200 }) ?? []) as
      Array<{ id: number; bucket: string; key: string }>;
    let purged = 0;
    let failed = 0;
    for (const d of due) {
      let err: string | null = null;
      if (d.bucket !== MEDIA_BUCKET && d.bucket !== PUBLIC_BUCKET) {
        err = 'unknown bucket';
      } else {
        try {
          const res = await fetch(await presign('DELETE', d.key, 300, d.bucket), { method: 'DELETE' });
          // 404 is success: it is gone, which is what was wanted.
          if (!res.ok && res.status !== 404) err = 'http ' + res.status;
        } catch (e) {
          err = String(e).slice(0, 200);
        }
      }
      await rpc('r2_trash_done', { p_id: d.id, p_error: err });
      if (err) failed++; else purged++;
    }
    return json({ ok: true, purged, failed }, 200, req);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // EVERYTHING BELOW IS THE CONSOLE'S, and goes through the admin gate.
  //
  // The runner's ops above answer to RUNNER_SECRET and the webhook to
  // Telegram's header; neither has a person behind it, so neither has a
  // role. These four do, and an op that is not in NEED is refused before
  // anything runs — deny by default, as in studio.ts.
  // ═══════════════════════════════════════════════════════════════════════
  const need = NEED[op];
  if (!need) return json({ error: 'unknown_op' }, 400, req);
  const asked = await whoIsAsking(req);
  if ('error' in asked) return json({ error: asked.error }, asked.status, req);
  const who = asked;
  if (!mayDo(who, need)) {
    return json({ error: 'not_allowed', need, role: who.role }, 403, req);
  }
  const refused = await uploaderRefusal(op, body, who);
  if (refused) return json({ error: refused }, 403, req);

  let res: Response;
  try {
    res = await consoleOp(req, op, body, who);
  } catch (e) {
    // `rpc` throws on a database error. Caught here so the failure is in
    // the audit log as well as in the admin's face.
    res = json({ error: 'failed', detail: String(e).slice(0, 200) }, 500, req);
  }
  if (op !== 'list') {
    let err: string | null = null;
    if (res.status >= 400) {
      try {
        err = String((await res.clone().json())?.error ?? res.status);
      } catch {
        err = String(res.status);
      }
    }
    await audit(who, 'ingest', op,
      String(body.job_id ?? body.folder ?? body.title_id ?? '') || null,
      auditDetail(body), res.status < 400, err);
  }
  return res;
});

/// Who may call which of the console's ops. Deny by default: an op that is
/// not here is refused. tool/js/admin_gate_test.mjs fails the build if an op
/// handled in consoleOp is missing from here, or the reverse.
const NEED: Record<string, Role> = {
  list: 'viewer',
  attach: 'uploader', attach_folder: 'uploader', create_title: 'uploader',
  retry: 'uploader',
  // Taking forwarded files out of the inbox is a decision about what the
  // catalogue receives, so it is an editor's — the review queue's reject.
  discard: 'editor',
};

/// An uploader may file Telegram's files into a title only while that title
/// is THEIR OWN DRAFT — the same rule as studio.ts. `create_title` makes a
/// draft owned by the caller, and `retry` puts a file back in the queue
/// without touching any title, so neither needs the check.
async function uploaderRefusal(
  op: string, body: Record<string, unknown>, who: Admin,
): Promise<string | null> {
  if (who.role !== 'uploader') return null;
  if (op !== 'attach' && op !== 'attach_folder') return null;
  const titleId = String(body.title_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(titleId)) return 'no_title';
  const res = await rest(
    `titles?select=published,created_by&id=eq.${titleId}`);
  if (!res.ok) return 'no_title';
  const rows = await res.json() as Array<Record<string, unknown>>;
  const t = Array.isArray(rows) ? rows[0] : undefined;
  if (!t) return 'no_title';
  if (t.published === true || t.created_by !== who.id) return 'not_your_draft';
  return null;
}

async function consoleOp(
  req: Request, op: string, body: Record<string, unknown>, who: Admin,
): Promise<Response> {
  // ── list ─────────────────────────────────────────────────────────────────
  // The console's panel. Admins only: it is a list of object keys and
  // Telegram file ids, and either one is worth keeping off a public page.
  if (op === 'list') {
    const res = await rest(
      'ingest_jobs?select=id,file_name,bytes,kind,state,note,object_key,'
      + 'title_id,created_at,finished_at,tg_caption,tg_media_group'
      + '&order=created_at.desc&limit=200');
    if (!res.ok) return json({ error: 'list_failed' }, 500, req);
    return json({ rows: await res.json(), runner: !!RUNNER_SECRET }, 200, req);
  }

  // ── attach ───────────────────────────────────────────────────────────────
  // Point a finished ingest at a title. Idempotent — see attach_ingest.
  if (op === 'attach') {
    const jobId = String(body.job_id ?? '');
    const titleId = String(body.title_id ?? '');
    if (!jobId || !titleId) return json({ error: 'no_job_or_title' }, 400, req);
    const result = await rpc('attach_ingest', {
      p_job: jobId, p_title: titleId,
    });
    return json({ ok: true, result }, 200, req);
  }

  // ── attach_folder ────────────────────────────────────────────────────────
  //
  // Point a title at EVERY finished file of one folder.
  //
  // An album is one thing to the person who sent it. Fifteen rows each with
  // their own picker is fifteen chances to choose the wrong title on the
  // eleventh, and the folder is the thing the album already agreed on when it
  // was queued, so it is the right handle. `attach_ingest_folder` skips what
  // is not finished and what is already attached.
  if (op === 'attach_folder') {
    const folder = String(body.folder ?? '');
    const titleId = String(body.title_id ?? '');
    if (!folder || !titleId) return json({ error: 'no_folder_or_title' }, 400, req);
    const result = await rpc('attach_ingest_folder', {
      p_folder: folder, p_title: titleId,
    });
    return json({ ok: true, attached: result }, 200, req);
  }

  // ── create_title ─────────────────────────────────────────────────────────
  //
  // One album becomes one title, in one statement.
  //
  // WHY NOT studio.ts's `create`. That one exists to take files off the
  // phone: it demands at least one, uploads them, and makes the title around
  // them. After an ingest the files are ALREADY in the bucket — and the
  // operator's next step, "choose the title in the console", could not be
  // taken at all, because the only titles to choose from were five old test
  // ones and making a new one demanded uploading a file that was already
  // there. Attaching a 416 MB film to `Test 001` is not a workaround.
  //
  // Loosening `create` would have left five steps to say one thing. This says
  // it once, and the title is never empty for a moment because
  // `create_title_from_ingest` attaches the folder inside the same
  // transaction that creates the row. It is born a DRAFT; the rest of the card
  // — category, year, the Burmese title, the tags — is typed in the editor,
  // which is where the operator is standing once the title exists.
  if (op === 'create_title') {
    const folder = String(body.folder ?? '');
    const name = String(body.title ?? '');
    if (!folder || !name.trim()) {
      return json({ error: 'no_folder_or_title' }, 400, req);
    }
    try {
      const rows = await rpc('create_title_from_ingest', {
        p_folder: folder,
        p_title: name,
        p_synopsis: String(body.synopsis ?? ''),
        p_actor: who.id,
      }) as Array<Record<string, unknown>>;
      const made = (Array.isArray(rows) ? rows[0] : rows) ?? {};
      return json({
        ok: true,
        id: made.title_id ?? null,
        attached: Number(made.attached ?? 0) || 0,
      }, 200, req);
    } catch (e) {
      // The database's own words. `that folder already belongs to another
      // title` is the one the operator can act on, and a generic 500 would
      // send them to look in the logs for it.
      return json({ error: 'create_failed', detail: String(e).slice(0, 200) },
        400, req);
    }
  }

  // ── retry ────────────────────────────────────────────────────────────────
  //
  // Put a terminally failed job back in the queue.
  //
  // WHY THIS EXISTS. 022 made a failure re-forwardable, which covers a file
  // that was wrong. It does not cover a file that was fine and an ENVIRONMENT
  // that was not: the first two jobs this pipeline ever saw died three times
  // each on `Telegram credentials are not set on this repository`, and once
  // the credentials existed the only way to recover them was to find the
  // messages in Telegram and forward them again. The chat, the message and
  // the file id were all still in the row.
  //
  // An uploader's, and `retry_ingest` refuses anything that is not spent —
  // including a file that has since been forwarded again, which would fetch
  // the same gigabyte twice.
  if (op === 'retry') {
    const jobId = String(body.job_id ?? '');
    if (!jobId) return json({ error: 'no_job' }, 400, req);
    const result = await rpc('retry_ingest', { p_job: jobId });
    return json({ ok: true, result }, 200, req);
  }

  // ── discard ──────────────────────────────────────────────────────────────
  //
  // "I forwarded that by mistake." One file, or every finished file of one
  // folder that is in no title, leaves the inbox. `discard_ingest` never
  // touches a queued or running job (the runner holds those) or a filed one.
  // The rows go, so the same file can be forwarded again on purpose; the
  // object stays in R2 for the Files page to list as unused.
  if (op === 'discard') {
    const jobId = String(body.job_id ?? '');
    const folder = String(body.folder ?? '');
    if (!jobId && !folder) return json({ error: 'no_job_or_folder' }, 400, req);
    const n = await rpc('discard_ingest', {
      p_job: jobId || null, p_folder: jobId ? null : folder,
    });
    return json({ ok: true, discarded: Number(n) || 0 }, 200, req);
  }

  return json({ error: 'unknown_op' }, 400, req);
}
