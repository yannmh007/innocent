// ===========================================================================
// subtitles-online — Supabase Edge Function — v1, 28 Nov 2026
// Innocent: CC → Online finds and loads a subtitle in the app (P5,
// docs/handoff_2026_11_28_beyond_mx_p1.md). Before: a shared
// opensubtitles.org address the viewer opened in a browser.
//
// WHAT IT DOES. Stands between every viewer and the owner's ONE
// OpenSubtitles.com account (its API key and login are this function's
// secrets; the app never sees them):
//   POST { op: 'search', device_id, query?, moviehash?, languages?, season?,
//          episode?, page? }
//     → 200 { results: [{ file_id, lang, release, name, downloads, hi, ai,
//             fps, hash_match, title, year }], from: 'opensubtitles' }
//   POST { op: 'download', device_id, file_id, name? }
//     → 200 { name, format: 'srt', data: <base64 of the file>, remaining }
// Refusals (JSON `code`): 400 bad_request, 405, 429 rate_limited (this
// app's budget, migration 084, or OpenSubtitles' own pace) with
// `retry_after`, 429 quota_day (the account's downloads for the day are
// spent) with `retry_after`, 503 not_configured (no key set) and
// 502 unavailable (OpenSubtitles failed).
//
// SECRETS (Supabase → Edge Functions → Secrets; the owner sets them):
//   OPENSUBTITLES_API_KEY    the API consumer's key (required)
//   OPENSUBTITLES_USERNAME   the account's user name (not the e-mail)
//   OPENSUBTITLES_PASSWORD   its password — with both, downloads count
//                            against the account's own daily quota; without,
//                            OpenSubtitles' anonymous one.
//   OPENSUBTITLES_USER_AGENT optional; default "Innocent v1.64".
//
// NEVER LOGGED: the key, the password, the login token, a download link
// (one-time and quota-bearing). Logged: the op, OpenSubtitles' status,
// `remaining`, the budget that refused.
//
// STATELESS (rules: edge-functions.md). The login token is kept per isolate
// (20 h, as OpenSubtitles' own client does) and asked again on a 401; the
// budget is Postgres's (take_subtitle_budget). Deployed as a shim at a
// pushed SHA (skill edge-deploy); verify_jwt false (the app calls it with
// the anon key; the budget is the gate).
// ===========================================================================

import {
  API, apiFor, downloadBody, languages, retryAfter, safeName, searchParams,
  secondsToReset, shapeSearch,
} from './subtitles_os.js';
import { keyFacts, keyHeaders, pickKey } from './service_key.js';

const KEYS = { prefer: 'new' } as const;
const SERVICE_KEY = pickKey((n: string) => Deno.env.get(n), 'service', KEYS).key;
const SERVICE_HEADERS = keyHeaders(SERVICE_KEY);
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const OS_KEY = Deno.env.get('OPENSUBTITLES_API_KEY') ?? '';
const OS_USER = Deno.env.get('OPENSUBTITLES_USERNAME') ?? '';
const OS_PASS = Deno.env.get('OPENSUBTITLES_PASSWORD') ?? '';
const OS_AGENT = (Deno.env.get('OPENSUBTITLES_USER_AGENT') ?? '').trim() || 'Innocent v1.64';
// Whether the secrets are there — never their values or a prefix.
console.log(JSON.stringify({
  keys: keyFacts((n: string) => Deno.env.get(n), KEYS),
  opensubtitles: { key: OS_KEY.length > 0, login: OS_USER.length > 0 && OS_PASS.length > 0 },
}));

const MAX_FILE = 1_500_000; // a subtitle is ~50-150 KB; anything far bigger is not one

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'private, no-store', ...extra },
  });
}

function refuse(code: string, status: number, retry?: number): Response {
  return retry
    ? json({ code, retry_after: retry }, status, { 'Retry-After': String(retry) })
    : json({ code }, status);
}

/// The caller's address, for the network budget only — hashed with a
/// secret salt in the database and never stored (as request-playback).
function callerIp(req: Request): string | null {
  const h = req.headers;
  const ip = h.get('cf-connecting-ip') ?? h.get('x-real-ip') ??
    (h.get('x-forwarded-for') ?? '').split(',')[0].trim();
  return ip ? ip.slice(0, 64) : null;
}

async function rpc(name: string, args: Record<string, unknown>): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { ...SERVICE_HEADERS, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
}

/// null when the call may go ahead, else the budget that ran out. OPEN IF
/// THE BUDGET CANNOT BE READ (as request-playback): OpenSubtitles' own
/// quota still stands behind it, and the log says so.
async function takeBudget(device: string, ip: string | null, kind: 'search' | 'download'): Promise<string | null> {
  try {
    const r = await rpc('take_subtitle_budget', { p_device: device, p_ip: ip, p_kind: kind });
    if (!r.ok) {
      console.log(JSON.stringify({ op: kind, budget: 'unavailable', status: r.status }));
      return null;
    }
    const over = await r.json();
    return typeof over === 'string' && over ? over : null;
  } catch (e) {
    console.log(JSON.stringify({ op: kind, budget: 'unavailable', error: String(e).slice(0, 120) }));
    return null;
  }
}

async function giveBack(device: string, ip: string | null): Promise<void> {
  try {
    await rpc('give_back_subtitle_download', { p_device: device, p_ip: ip });
  } catch (_) {
    // A download not given back costs that viewer one of the day's five.
  }
}

/// Seconds until an hourly budget fills again; a daily one at UTC midnight.
function budgetRetry(over: string, now = Date.now()): number {
  const d = new Date(now);
  const next = over.endsWith('_daily_downloads')
    ? Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)
    : Math.floor(now / 3600000 + 1) * 3600000;
  return Math.max(1, Math.ceil((next - now) / 1000));
}

// ── OpenSubtitles ─────────────────────────────────────────────────────────

function osHeaders(token?: string): Record<string, string> {
  const h: Record<string, string> = {
    'Api-Key': OS_KEY,
    'User-Agent': OS_AGENT,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };
  if (token) h['Authorization'] = `Bearer ${token}`;
  return h;
}

// Per isolate: the login and the API host it named. A failed login is not
// tried again for five minutes (a wrong password must not hammer /login).
let login: { token: string; api: string; at: number } | null = null;
let loginFailedAt = 0;
const TOKEN_MS = 20 * 3600_000;

async function token(fresh = false): Promise<{ token: string; api: string } | null> {
  if (!OS_USER || !OS_PASS) return null;
  const now = Date.now();
  if (!fresh && login && now - login.at < TOKEN_MS) return login;
  if (now - loginFailedAt < 5 * 60_000) return null;
  try {
    const r = await fetch(`${API}login`, {
      method: 'POST',
      headers: osHeaders(),
      body: JSON.stringify({ username: OS_USER, password: OS_PASS }),
    });
    if (!r.ok) {
      loginFailedAt = now;
      console.log(JSON.stringify({ op: 'login', status: r.status }));
      return null;
    }
    const j = await r.json();
    if (typeof j?.token !== 'string' || !j.token) {
      loginFailedAt = now;
      console.log(JSON.stringify({ op: 'login', status: r.status, token: false }));
      return null;
    }
    login = { token: j.token, api: apiFor(j.base_url), at: now };
    console.log(JSON.stringify({
      op: 'login', status: r.status,
      allowed: j?.user?.allowed_downloads ?? null, level: j?.user?.level ?? null,
    }));
    return login;
  } catch (e) {
    loginFailedAt = now;
    console.log(JSON.stringify({ op: 'login', error: String(e).slice(0, 120) }));
    return null;
  }
}

async function search(body: Record<string, unknown>): Promise<Response> {
  const p = searchParams(body as never);
  if ('error' in p) return refuse('bad_request', 400);
  const r = await fetch(`${API}subtitles?${p.params}`, { headers: osHeaders(), redirect: 'follow' });
  if (r.status === 429) return refuse('rate_limited', 429, retryAfter(r.headers.get('Retry-After')));
  if (!r.ok) {
    console.log(JSON.stringify({ op: 'search', status: r.status }));
    return refuse('unavailable', 502);
  }
  const rows = shapeSearch(await r.json(), languages(body.languages));
  console.log(JSON.stringify({ op: 'search', status: r.status, rows: rows.length }));
  return json({ results: rows, from: 'opensubtitles' });
}

async function download(body: Record<string, unknown>, device: string, ip: string | null): Promise<Response> {
  const req = downloadBody(body.file_id);
  if (!req) return refuse('bad_request', 400);
  const over = await takeBudget(device, ip, 'download');
  if (over) {
    console.log(JSON.stringify({ op: 'download', refused: over }));
    return refuse('rate_limited', 429, budgetRetry(over));
  }
  let auth = await token();
  const ask = (t: { token: string; api: string } | null) => fetch(`${t?.api ?? API}download`, {
    method: 'POST', headers: osHeaders(t?.token), body: JSON.stringify(req),
  });
  let r = await ask(auth);
  if (r.status === 401 && auth) {
    // The token outlived its validity: once more, logged in again.
    auth = await token(true);
    r = await ask(auth);
  }
  if (r.status === 406) {
    const j = await r.json().catch(() => ({}));
    await giveBack(device, ip);
    console.log(JSON.stringify({ op: 'download', status: 406, remaining: j?.remaining ?? null }));
    return refuse('quota_day', 429, secondsToReset(j));
  }
  if (r.status === 429) {
    await giveBack(device, ip);
    return refuse('rate_limited', 429, retryAfter(r.headers.get('Retry-After')));
  }
  if (!r.ok) {
    await giveBack(device, ip);
    console.log(JSON.stringify({ op: 'download', status: r.status }));
    return refuse('unavailable', 502);
  }
  const j = await r.json().catch(() => null);
  const link = typeof j?.link === 'string' && /^https:\/\//.test(j.link) ? j.link : '';
  if (!link) {
    await giveBack(device, ip);
    console.log(JSON.stringify({ op: 'download', status: r.status, link: false }));
    return refuse('unavailable', 502);
  }
  const f = await fetch(link);
  if (!f.ok) {
    console.log(JSON.stringify({ op: 'download', file: f.status }));
    return refuse('unavailable', 502);
  }
  const bytes = new Uint8Array(await f.arrayBuffer());
  if (bytes.length === 0 || bytes.length > MAX_FILE) {
    console.log(JSON.stringify({ op: 'download', file: 'size', bytes: bytes.length }));
    return refuse('unavailable', 502);
  }
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  const remaining = Number.isFinite(Number(j?.remaining)) ? Number(j.remaining) : null;
  console.log(JSON.stringify({ op: 'download', status: r.status, bytes: bytes.length, remaining }));
  return json({
    name: safeName(String(body.name ?? j?.file_name ?? ''), req.file_id),
    format: 'srt',
    data: btoa(bin),
    remaining,
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return refuse('method', 405);
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return refuse('bad_request', 400);
  }
  const device = typeof body?.device_id === 'string' ? body.device_id.slice(0, 128) : '';
  if (!device) return refuse('bad_request', 400);
  if (!OS_KEY) return refuse('not_configured', 503);
  const ip = callerIp(req);
  try {
    if (body.op === 'search') {
      const over = await takeBudget(device, ip, 'search');
      if (over) {
        console.log(JSON.stringify({ op: 'search', refused: over }));
        return refuse('rate_limited', 429, budgetRetry(over));
      }
      return await search(body);
    }
    if (body.op === 'download') return await download(body, device, ip);
    return refuse('bad_request', 400);
  } catch (e) {
    console.log(JSON.stringify({ op: String(body.op ?? '?').slice(0, 12), error: String(e).slice(0, 160) }));
    return refuse('unavailable', 502);
  }
});
