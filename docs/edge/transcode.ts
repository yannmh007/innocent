// transcode — the queue between "somebody uploaded a file" and "everybody
// can watch it".
//
// THE REQUIREMENT, IN THE OPERATOR'S WORDS: whatever the size, however it
// was shot, 4K or high frame rate, it must not stutter — because the person
// uploading will not be thinking about bitrates and should not have to.
//
// That cannot be solved in the player. A camera clip needing 61 Mbps over a
// 48 Mbps link is arithmetic, not a setting. It is solved by having a
// SMALLER COPY, and this is the three-line protocol that gets one made:
//
//   queue  — an operator (or the console, automatically) says a file needs
//            a ladder.
//   claim  — a GitHub Actions runner asks for work and is handed presigned
//            URLs: one GET for the master, one PUT per rung.
//   done   — the runner reports the rungs it finished, after EACH one.
//
// WHY THE RUNNER PULLS INSTEAD OF BEING PUSHED. Pushing means a GitHub
// personal access token living in Supabase with write access to the whole
// repository. Pulling means a single shared secret whose only power is "ask
// for a transcode job". The second is a much smaller thing to lose, and the
// cost is that a job starts within five minutes rather than instantly —
// which is nothing next to the hour of encoding that follows it.
//
// WHY THE RUNNER GETS PRESIGNED URLS AND NOT KEYS. This repository is
// public. R2 account keys stored as Actions secrets would be one careless
// `echo` away from being permanent. A presigned URL is scoped to one object
// and expires the same day.

import { b64, importKek, unwrapDek } from './media_keys.js';
import { issue, makeFor, sealNewMode } from './media_issue.js';
import { isSealedKey } from './media_twin.js';
import {
  type RecordIO, recordSealed as recordSealedShared,
} from './media_record.ts';
import { keyFacts, keyHeaders, pickKey } from './service_key.js';

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID')!;
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID')!;
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY')!;
const MEDIA_BUCKET = Deno.env.get('R2_BUCKET') ?? 'innocent-media';
// Where thumbnails live (043's frames among them): served straight off the
// public bucket's domain, which is what `title_media.thumb_url` builds on.
const PUBLIC_BUCKET = Deno.env.get('R2_PUBLIC_BUCKET') ?? 'innocent-public';

// Starting the Transcode workflow the moment there is work, instead of
// waiting for GitHub's schedule — which on 2026-10-05/06 fired five times in
// a day, so four videos queued at 16:30 sat with no streaming copies for
// hours. The same fine-grained token the ingest function uses (Actions: read
// and write, this repository only). Absent, the schedule still comes by.
const GH_DISPATCH_TOKEN = Deno.env.get('GH_DISPATCH_TOKEN') ?? '';
const GH_REPO = Deno.env.get('GH_REPO') ?? 'yannmh007/innocent';
const GH_REF = Deno.env.get('GH_REF') ?? 'main';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
// The Supabase keys (service_key.js, docs/security_review_2026_11.md S1):
// 'legacy' keeps the choice made before the new keys; 'new' once proven.
const KEYS = { prefer: 'legacy' } as const;
const ANON_KEY = pickKey((n) => Deno.env.get(n), 'public', KEYS).key;
const SERVICE_KEY = pickKey((n) => Deno.env.get(n), 'service', KEYS).key;
const SERVICE_HEADERS = keyHeaders(SERVICE_KEY);
console.log(JSON.stringify({ keys: keyFacts((n) => Deno.env.get(n), KEYS) }));

// The one secret the runner holds. Absent means the runner half is switched
// off — `queue` still works, jobs simply pile up, and the console says so.
const RUNNER_SECRET = Deno.env.get('TRANSCODE_SECRET') ?? '';

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
  method: 'GET' | 'PUT' | 'HEAD', objectKey: string, seconds: number,
  bucket: string = MEDIA_BUCKET,
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
// ── media seal (docs/MEDIA_ENCRYPTION.md §7) ───────────────────────────────
//
// What the switch (admin_settings.seal_new, migration 067) makes of a new
// rung or still, read when work is handed out — a runner never decides.
// Keys are issued and recorded through media_issue.js only.

const SERVICE = () => ({ ...SERVICE_HEADERS });

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { ...SERVICE(), 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
}

let sealNewSeen: { mode: string; at: number } | null = null;

/// The switch, a minute at most out of date. `off` when it cannot be read.
async function sealNew(): Promise<string> {
  if (sealNewSeen && Date.now() - sealNewSeen.at < 60_000) return sealNewSeen.mode;
  let mode = 'off';
  try {
    const r = await rest('admin_settings?select=seal_new&limit=1');
    if (r.ok) mode = sealNewMode((await r.json() as Array<{ seal_new: string }>)[0]?.seal_new);
  } catch (_) { /* off */ }
  sealNewSeen = { mode, at: Date.now() };
  return mode;
}

let kekHeld: Promise<CryptoKey | null> | null = null;
function kek(): Promise<CryptoKey | null> {
  return kekHeld ??= importKek(Deno.env.get('MEDIA_KEK_V1') ?? '').catch(() => null);
}

/// The slug of an asset's title: what decides an open film (canary).
async function slugOfAsset(assetId: string): Promise<string | null> {
  const r = await rest(`title_assets?select=titles(slug)&id=eq.${encodeURIComponent(assetId)}&limit=1`);
  if (!r.ok) return null;
  const row = (await r.json() as Array<{ titles: { slug: string } | null }>)[0];
  return row?.titles?.slug ?? null;
}

type KeyRow = { dek_id: string; sealed_key: string; plain_key: string | null; wrapped: string;
  kek_version: number; plain_size: number; sealed_size: number };

/// The key row of a film object, by its sealed key or the plain key it twins.
async function sealOf(key: string): Promise<KeyRow | null> {
  const cols = 'dek_id,sealed_key,plain_key,wrapped,kek_version,plain_size,sealed_size';
  const k = encodeURIComponent(key);
  const r = await rest(`media_keys?select=${cols}&bucket=eq.${MEDIA_BUCKET}&or=(sealed_key.eq.${k},plain_key.eq.${k})&limit=1`);
  return r.ok ? (await r.json() as KeyRow[])[0] ?? null : null;
}

/// What the runner needs to open a sealed object: its DEK, unwrapped here.
/// The runner decodes the film anyway; the DEK lives on its disk only for
/// the job.
async function openerFor(k: CryptoKey, row: KeyRow) {
  const dek = await unwrapDek(k, row.wrapped, row.dek_id, row.kek_version);
  try {
    return { dek_id: row.dek_id, dek: b64(dek), plain_size: row.plain_size, sealed_size: row.sealed_size };
  } finally {
    dek.fill(0);
  }
}

/// What media_record.ts needs from this function: its own REST, signer and
/// KEK. Rungs and stills are recorded there (§7.2, migrations 069-070).
const recordIO: RecordIO = { rest, presign, kek };

async function recordSealed(
  items: Array<Record<string, unknown>>, bucket: string, kind: 'video' | 'image',
): Promise<{ ok: Set<string>; refused: string[] }> {
  const out = await recordSealedShared(recordIO, items, bucket, kind);
  if (out.replaced) console.log(`sealed copy replaced (${kind}): ${out.replaced} old copy binned`);
  return out;
}

async function renditionKeysOf(asset: string): Promise<string[]> {
  const r = await rest(`asset_renditions?select=object_key&asset_id=eq.${encodeURIComponent(asset)}`);
  return r.ok ? (await r.json() as Array<{ object_key: string }>).map((x) => x.object_key) : [];
}

async function frameKeysOf(asset: string): Promise<string[]> {
  const r = await rest(`title_assets?select=frames&id=eq.${encodeURIComponent(asset)}&limit=1`);
  if (!r.ok) return [];
  const f = (await r.json() as Array<{ frames: unknown }>)[0]?.frames;
  return Array.isArray(f) ? f.map((x) => String((x as { key?: unknown })?.key ?? '')).filter(Boolean) : [];
}

/// A TWIN NEVER OUTLIVES ITS OBJECT (070). After a job's rungs or stills are
/// recorded: a plain object it wrote again whose twin it did not make (the
/// switch was off, or sealing failed) keeps no twin, which would open to the
/// old bytes; an object the asset named before and no longer does (a rung
/// dropped, a still born sealed taken again) loses its key row unless
/// something still names it. Each sealed copy so dropped goes to the bin.
async function settle(
  kind: 'video' | 'image', bucket: string, asset: string,
  before: string[], now: string[], keep: Set<string>,
) {
  const nowSet = new Set(now.filter(Boolean));
  const remade = [...nowSet].filter((k) => !isSealedKey(k));
  const gone = before.filter((k) => k && !nowSet.has(k));
  if (!remade.length && !gone.length) return;
  try {
    const out = await rpc('media_keys_settle', {
      p_kind: kind, p_bucket: bucket, p_remade: remade, p_gone: gone, p_keep: [...keep],
    }) as { binned?: string[] };
    const n = (out?.binned ?? []).length;
    if (n) console.log(`sealed copies settled (${kind} ${asset}): ${n} binned`);
  } catch (e) {
    console.log(`settle failed (${kind} ${asset}): ${String(e).slice(0, 120)}`);
  }
}

async function rpc(name: string, body: unknown): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      ...SERVICE_HEADERS,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body ?? {}),
  });
  if (!res.ok) throw new Error(`${name} ${res.status} ${await res.text()}`);
  return await res.json();
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
      ...SERVICE_HEADERS,
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
        ...SERVICE_HEADERS,
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

// CONSTANT TIME, because this compares a secret. A `===` on strings leaks
// how many leading characters were right through how long it took to say
// no, and a runner secret is exactly the kind of thing somebody would sit
// and guess at.
function sameSecret(given: string, expected: string): boolean {
  if (!expected || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

// The rungs a ladder can have. Kept in step with tool/transcode.sh, which
// decides which of them a given source actually gets — this list only has to
// be a superset, because a presigned URL that is never used costs nothing.
const RUNGS = [240, 360, 480, 720, 1080, 1440, 2160];

// Where a rung goes: beside the master, with the height in the name.
//   test006/video/20260924-1000202588-c05d6781.mp4
//   test006/video/20260924-1000202588-c05d6781-720p.mp4
/// Who may call the console's ops here. Deny by default for anything that is
/// neither in this map nor one of the runner's own ops.
const NEED: Record<string, Role> = {
  health: 'viewer',
  queue: 'uploader',
  // 043: make a video's ten frames again (or for the first time, now).
  frames: 'uploader',
};

function rungKey(masterKey: string, height: number): string {
  return masterKey.replace(/\.[^./]+$/, '') + `-${height}p.mp4`;
}

// ── frames (043) ─────────────────────────────────────────────────────────
//
// Ten stills per video for the console's cover picker: frame 0 at one
// second — the default thumbnail — and frames 1–9 at 10 %, 20 % … 90 %.
const FRAME_COUNT = 10;

/// Where frame `i` of a video goes: the video's folder, `thumb/`, the video's
/// own name and the frame number. `<folder>/video/<stem>.mp4` →
/// `<folder>/thumb/<stem>-f03.jpg`. Lower-cased and cleaned, because the key
/// has to pass `record_frames`' check and `isMintedKey` in studio.ts, and a
/// few early keys (`v/index-v1-a1.mp4`) predate the minted shape.
function frameKey(masterKey: string, i: number): string {
  const base = masterKey.replace(/\.[^./]+$/, '').toLowerCase();
  const parts = base.split('/').filter(Boolean);
  const name = parts.pop() ?? 'video';
  if (parts.length && parts[parts.length - 1] === 'video') parts.pop();
  const clean = (s: string) =>
    s.replace(/[^a-z0-9.\-]+/g, '-').replace(/^[^a-z0-9]+/, '').replace(/-+$/, '');
  const folder = parts.map(clean).filter(Boolean).join('/');
  const stem = clean(name) || 'video';
  return `${folder ? folder + '/' : ''}thumb/${stem}-f${String(i).padStart(2, '0')}.jpg`;
}

// One wake-up per burst, as in ingest.ts: a page that queues six uploads in
// a row starts one run, and a run already waiting takes them all.
let lastKick = 0;

/// Ask GitHub to start the Transcode workflow now. 'started', 'waiting'
/// (one is already queued), 'off' (no token) or 'failed'. Never throws.
async function kickTranscode(force = false): Promise<string> {
  if (!GH_DISPATCH_TOKEN) return 'off';
  const now = Date.now();
  if (!force && now - lastKick < 30_000) return 'waiting';
  const base = `https://api.github.com/repos/${GH_REPO}/actions/workflows/transcode.yml`;
  const headers = {
    'Authorization': `Bearer ${GH_DISPATCH_TOKEN}`,
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'innocent-transcode',
  };
  try {
    const q = await fetch(`${base}/runs?per_page=5`, { headers });
    if (q.ok) {
      const j = await q.json() as { workflow_runs?: Array<{ status?: string }> };
      const pending = (j.workflow_runs ?? []).some((r) =>
        ['queued', 'pending', 'requested', 'waiting'].includes(String(r.status)));
      if (pending) { lastKick = now; return 'waiting'; }
    }
    const r = await fetch(`${base}/dispatches`, {
      method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: GH_REF }),
    });
    if (r.status === 204) { lastKick = now; return 'started'; }
    console.log(`kick: GitHub answered ${r.status}`);
    return 'failed';
  } catch (e) {
    console.log('kick: ' + String(e).slice(0, 160));
    return 'failed';
  }
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
    return json({ ok: true, service: 'transcode', runner: !!RUNNER_SECRET }, 200, req);
  }
  if (req.method !== 'POST') return json({ error: 'method' }, 405, req);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { body = {}; }
  const op = String(body.op ?? '');

  // ── the console's two ops go through the admin gate ─────────────────────
  //
  // `claim` and `done` below are the runner's and answer to RUNNER_SECRET;
  // there is no person behind them, so no role.
  const need = NEED[op];
  let who: Admin | null = null;
  if (need) {
    const asked = await whoIsAsking(req);
    if ('error' in asked) return json({ error: asked.error }, asked.status, req);
    if (!mayDo(asked, need)) {
      return json({ error: 'not_allowed', need, role: asked.role }, 403, req);
    }
    who = asked;
  }

  // ── queue ───────────────────────────────────────────────────────────────
  if (op === 'queue' && who) {

    // BY KEY AS WELL AS BY ID, because the console knows the key at the
    // moment it matters. It has just finished uploading a file and wants it
    // queued immediately; the asset id comes back from a different call, and
    // making the operator's browser stitch two responses together to queue
    // its own upload is work for no reason.
    let asset = String(body.asset_id ?? '');
    const key = String(body.object_key ?? '');
    if (!asset && key) {
      const res = await fetch(
        `${SUPABASE_URL}/rest/v1/title_assets?select=id&object_key=eq.` +
        `${encodeURIComponent(key)}&limit=1`,
        { headers: { ...SERVICE_HEADERS } },
      );
      if (res.ok) {
        const rows = await res.json() as Array<{ id: string }>;
        if (rows.length) asset = rows[0].id;
      }
    }
    if (!asset) return json({ error: 'no_asset' }, 400, req);

    const state = await rpc('queue_transcode', { p_asset: asset });
    // NOTHING QUEUED: a photo, or a film whose original the storage policy
    // left only in Telegram (migration 029) — the encoder would be handed a
    // URL to nothing. Restore it first, from Storage.
    if (state === null || (Array.isArray(state) && !state.length)) {
      await audit(who, 'transcode', 'queue', asset, auditDetail(body), false, 'master_in_telegram');
      return json({ error: 'master_in_telegram' }, 409, req);
    }
    await audit(who, 'transcode', 'queue', asset, auditDetail(body), true, null);
    const kick = await kickTranscode();
    return json({ ok: true, asset_id: asset, state, runner: !!RUNNER_SECRET, kick },
      200, req);
  }

  // ── frames (043): "make the frames again" ────────────────────────────────
  if (op === 'frames' && who) {
    const asset = String(body.asset_id ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(asset)) return json({ error: 'no_asset' }, 400, req);
    const state = await rpc('queue_frames', { p_asset: asset });
    if (state === null || (Array.isArray(state) && !state.length)) {
      return json({ error: 'not_a_video' }, 409, req);
    }
    await audit(who, 'transcode', 'frames', asset, auditDetail(body), true, null);
    return json({ ok: true, state, kick: await kickTranscode(true) }, 200, req);
  }

  // ── health ──────────────────────────────────────────────────────────────
  // What the console's panel reads. Admins only: it is a list of object
  // keys, and a list of object keys is a map of the bucket.
  if (op === 'health' && who) {
    const rows = await rpc('rendition_health', {});
    return json({ rows, runner: !!RUNNER_SECRET }, 200, req);
  }

  // ── claim ───────────────────────────────────────────────────────────────
  //
  // Answers `{}` when there is nothing to do, which is the common case: the
  // schedule ticks every five minutes whether or not anyone uploaded.
  if (op === 'claim') {
    const given = (req.headers.get('Authorization') ?? '').replace(/^Bearer /i, '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);

    // A RUNNER SAYS WHETHER IT SEALS (070). One that does not — main's
    // scheduled runner while the sealing encoder is on a branch — is never
    // handed a sealed master, nor a film the switch wants sealed.
    const canSeal = body.seals === 1;
    const rows = await rpc('claim_transcode', { p_seals: canSeal }) as Array<Record<string, unknown>>;
    if (!Array.isArray(rows) || !rows.length) return json({}, 200, req);
    const job = rows[0];
    const masterKey = String(job.object_key ?? '');
    const srcHeight = Number(job.height ?? 0) || 2160;

    // THE SEAL (§7): what the switch makes of this film's rungs — plain, a
    // sealed twin beside each (canary, open films), or sealed only (on) —
    // and whether the master is sealed. A master born sealed is opened by
    // the runner with its DEK; in the canary a master with a twin is read
    // from the twin, which proves that opening on real work.
    const make = makeFor(await sealNew(), await slugOfAsset(String(job.asset_id)));
    if (!canSeal && (make !== 'plain' || isSealedKey(masterKey))) {
      // The switch moved between the claim and here: back in the queue for
      // a runner that seals.
      await rpc('queue_transcode', { p_asset: job.asset_id });
      return json({}, 200, req);
    }
    const k = (make !== 'plain' || isSealedKey(masterKey)) ? await kek() : null;
    let srcKey = masterKey;
    let srcSeal: Record<string, unknown> | null = null;
    const masterRow = (isSealedKey(masterKey) || make === 'twin') ? await sealOf(masterKey) : null;
    if (isSealedKey(masterKey)) {
      if (!k || !masterRow) {
        await rpc('record_renditions', { p_asset: job.asset_id, p_rows: null,
          p_note: 'the master is sealed and its key cannot be read' });
        return json({}, 200, req);
      }
      srcSeal = await openerFor(k, masterRow);
    } else if (make === 'twin' && k && masterRow) {
      srcKey = masterRow.sealed_key;
      srcSeal = await openerFor(k, masterRow);
    }
    // No KEK where one is needed: in the canary the rungs are plain, as
    // before, rather than none at all. With the switch `on` nothing plain
    // may be written and nothing can be sealed, so the film waits.
    if (make === 'sealed' && !k) {
      console.log('MEDIA_KEK unreadable: a film the switch wants sealed waits');
      await rpc('queue_transcode', { p_asset: job.asset_id });
      return json({}, 200, req);
    }
    const makes = k ? make : 'plain';

    // SIX HOURS FOR THE MASTER, TWENTY-FOUR FOR THE RUNGS, and the asymmetry
    // is deliberate. The download happens in the job's first minute; the
    // last rung is written at the end of an encode that can run for hours.
    // A URL that expires mid-job throws away everything after it.
    const put: Record<string, string> = {};
    const seal: Record<string, Record<string, unknown>> = {};
    for (const h of RUNGS) {
      if (h > srcHeight) continue;
      if (makes !== 'sealed') put[String(h)] = await presign('PUT', rungKey(masterKey, h), 86400);
      if (makes !== 'plain') {
        const issued = await issue(k!);
        seal[String(h)] = { ...issued, put_url: await presign('PUT', issued.sealed_key, 86400) };
      }
    }

    return json({
      asset_id: job.asset_id,
      src_url: await presign('GET', srcKey, 21600),
      // The DEKs below live on the runner's disk for this job only, like the
      // presigned URLs; nothing here is ever printed (transcode.yml).
      src_seal: srcSeal,
      make: makes,
      put,
      seal,
      done_url: `${SUPABASE_URL}/functions/v1/transcode`,
      // NOT the runner's token. It already holds the secret — it just used
      // it to claim this job — and echoing a secret back into a response
      // body puts it one careless log line away from a public run log.
      duration_s: job.duration_s ?? null,
      height: srcHeight,
    }, 200, req);
  }

  // ── frames_claim / frames_done (043) ────────────────────────────────────
  //
  // A BATCH, not one: ten seeks of a video take seconds, a run happens when
  // GitHub gets to it, and the eleven videos that had no thumbnail when this
  // was built should all have one after the first run.
  //
  // frames_done is matched before `done` below, which answers to any body
  // carrying a token.
  if (op === 'frames_claim') {
    const given = (req.headers.get('Authorization') ?? '').replace(/^Bearer /i, '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);
    const canSeal = body.seals === 1; // as for `claim` (070)
    const rows = await rpc('claim_frames', { p_limit: 20, p_seals: canSeal }) as Array<Record<string, unknown>>;
    if (!Array.isArray(rows) || !rows.length) return json({ jobs: [] }, 200, req);
    const jobs = [];
    const mode = await sealNew();
    for (const r of rows) {
      const master = String(r.master_key ?? '');
      const src = String(r.src_key ?? '');
      if (!master || !src) continue;
      // THE SEAL (§7), as for the ladder: a sealed source comes with its DEK
      // (tool/frames.py reads it by range through tool/unseal_proxy.py), and
      // each still is plain, plain with a sealed twin (canary, open films),
      // or sealed only (on).
      const make = makeFor(mode, await slugOfAsset(String(r.asset_id)));
      if (!canSeal && (make !== 'plain' || isSealedKey(src))) {
        await rpc('queue_frames', { p_asset: r.asset_id });
        continue;
      }
      const k = (make !== 'plain' || isSealedKey(src)) ? await kek() : null;
      let srcKey = src;
      let srcSeal: Record<string, unknown> | null = null;
      const srcRow = (isSealedKey(src) || make === 'twin') ? await sealOf(src) : null;
      if (isSealedKey(src)) {
        if (!k || !srcRow) {
          await rpc('record_frames', { p_asset: r.asset_id, p_frames: null,
            p_note: 'the source is sealed and its key cannot be read' });
          continue;
        }
        srcSeal = await openerFor(k, srcRow);
      } else if (make === 'twin' && k && srcRow) {
        srcKey = srcRow.sealed_key;
        srcSeal = await openerFor(k, srcRow);
      }
      if (make === 'sealed' && !k) {
        console.log('MEDIA_KEK unreadable: stills the switch wants sealed wait');
        await rpc('queue_frames', { p_asset: r.asset_id });
        continue;
      }
      const makes = k ? make : 'plain';
      const frames = [];
      for (let i = 0; i < FRAME_COUNT; i++) {
        const slot: Record<string, unknown> = {};
        if (makes !== 'sealed') {
          const key = frameKey(master, i);
          slot.key = key;
          slot.put = await presign('PUT', key, 86400, PUBLIC_BUCKET);
        }
        if (makes !== 'plain') {
          const issued = await issue(k!);
          slot.seal = { ...issued, put_url: await presign('PUT', issued.sealed_key, 86400, PUBLIC_BUCKET) };
        }
        frames.push(slot);
      }
      jobs.push({
        asset_id: r.asset_id,
        // Six hours: ffmpeg seeks inside it with range requests, ten times.
        src_url: await presign('GET', srcKey, 21600),
        src_seal: srcSeal,
        duration_s: r.duration_s ?? null,
        frames,
      });
    }
    return json({ jobs, done_url: `${SUPABASE_URL}/functions/v1/transcode` }, 200, req);
  }
  if (op === 'frames_done') {
    const given = String(body.token ?? '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);
    const asset = String(body.asset_id ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(asset)) return json({ error: 'no_asset' }, 400, req);
    let frames = Array.isArray(body.frames) ? body.frames as Array<Record<string, unknown>> : null;
    const framesBefore = frames ? await frameKeysOf(asset) : [];
    let recorded = new Set<string>();
    // SEALED STILLS (§7): each checked and its key recorded first. A twin
    // that does not check keeps its plain still; a still born sealed that
    // does not check is left out.
    if (frames) {
      const items: Array<Record<string, unknown>> = [];
      for (const f of frames) {
        if (!f.sealed || typeof f.sealed !== 'object') continue;
        const sealed = f.sealed as Record<string, unknown>;
        items.push({ ...sealed, plain_key: f.key === sealed.sealed_key ? null : f.key });
      }
      const { ok, refused } = await recordSealed(items, PUBLIC_BUCKET, 'image');
      recorded = ok;
      if (refused.length) console.log(`seal refused (frames ${asset}): ${refused.join('; ')}`);
      frames = frames
        .filter((f) => {
          const sealed = f.sealed as Record<string, unknown> | undefined;
          return !sealed || f.key !== sealed.sealed_key || ok.has(String(sealed.dek_id));
        })
        .map(({ sealed: _s, ...f }) => f);
    }
    try {
      const thumb = await rpc('record_frames', {
        p_asset: asset, p_frames: frames && frames.length ? frames : null,
        p_note: String(body.note ?? '').slice(0, 200) || null,
      });
      if (frames && frames.length) {
        await settle('image', PUBLIC_BUCKET, asset, framesBefore,
          frames.map((f) => String(f.key ?? '')), recorded);
      }
      return json({ ok: true, thumb }, 200, req);
    } catch (e) {
      return json({ error: 'record_failed', detail: String(e).slice(0, 200) }, 400, req);
    }
  }

  // ── done ────────────────────────────────────────────────────────────────
  //
  // Called after EVERY rung, not once at the end. A six-hour runner limit
  // against a film that takes five to encode means the difference between a
  // partial ladder somebody can watch and a row stuck on "running" forever.
  if (op === 'done' || body.token !== undefined) {
    const given = String(body.token ?? '');
    if (!sameSecret(given, RUNNER_SECRET)) return json({ error: 'no' }, 403, req);
    const asset = String(body.asset_id ?? '');
    if (!asset) return json({ error: 'no_asset' }, 400, req);

    const rows = body.rows;
    const note = String(body.note ?? '').slice(0, 200);
    if (rows === null || rows === undefined) {
      await rpc('record_renditions', { p_asset: asset, p_rows: null, p_note: note });
      return json({ ok: true, state: 'failed' }, 200, req);
    }
    // SEALED RUNGS (§7): each checked and its key recorded before the rung
    // is. A twin that does not check keeps its plain rung; a rung born
    // sealed that does not check is left out — never a rung nobody can open.
    const list = Array.isArray(rows) ? rows as Array<Record<string, unknown>> : [];
    const ladderBefore = await renditionKeysOf(asset);
    const sealedItems: Array<Record<string, unknown>> = [];
    for (const r of list) {
      if (!r.sealed || typeof r.sealed !== 'object') continue;
      const sealed = r.sealed as Record<string, unknown>;
      // Born sealed: the rendition's key IS the sealed key, and there is no
      // plain object. A twin: the rendition's key is the plain rung.
      sealedItems.push({ ...sealed, plain_key: r.object_key === sealed.sealed_key ? null : r.object_key });
    }
    const { ok, refused } = await recordSealed(sealedItems, MEDIA_BUCKET, 'video');
    const kept = list
      .filter((r) => {
        const sealed = r.sealed as Record<string, unknown> | undefined;
        return !sealed || r.object_key !== sealed.sealed_key || ok.has(String(sealed.dek_id));
      })
      .map(({ sealed: _s, ...r }) => r);
    // The note stays the runner's: record_renditions reads `complete` and
    // `already light…` as the ladder's state. A refusal is in the log and
    // in the answer, which the runner prints.
    if (refused.length) console.log(`seal refused (${asset}): ${refused.join('; ')}`);
    const written = await rpc('record_renditions', {
      p_asset: asset, p_rows: kept, p_note: note,
    });
    await settle('video', MEDIA_BUCKET, asset, ladderBefore, kept.map((r) => String(r.object_key ?? '')), ok);
    return json({ ok: true, written, sealed: ok.size, refused: refused.length }, 200, req);
  }

  return json({ error: 'unknown_op' }, 400, req);
});
