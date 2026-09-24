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

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID')!;
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID')!;
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY')!;
const MEDIA_BUCKET = Deno.env.get('R2_BUCKET') ?? 'innocent-media';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SB_ANON_KEY') ??
  Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const OPERATORS = (Deno.env.get('OPERATOR_IDS') ??
  '6c679480-3387-4442-ad3d-4423b8aceb71')
  .split(',').map((s) => s.trim()).filter(Boolean);

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
  method: 'GET' | 'PUT', objectKey: string, seconds: number,
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
  const canonicalPath = `/${MEDIA_BUCKET}/${encodeKey(objectKey)}`;
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
  return await res.json();
}

const json = (body: unknown, status: number, req: Request) => {
  const origin = req.headers.get('Origin') ?? '';
  const cors = ALLOWED_ORIGINS.includes(origin)
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

async function isOperator(req: Request): Promise<boolean> {
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.toLowerCase().startsWith('bearer ')) return false;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: ANON_KEY },
  });
  if (!res.ok) return false;
  const user = await res.json();
  return OPERATORS.includes(typeof user?.id === 'string' ? user.id : '');
}

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
const RUNGS = [360, 480, 720, 1080, 1440, 2160];

// Where a rung goes: beside the master, with the height in the name.
//   test006/video/20260924-1000202588-c05d6781.mp4
//   test006/video/20260924-1000202588-c05d6781-720p.mp4
function rungKey(masterKey: string, height: number): string {
  return masterKey.replace(/\.[^./]+$/, '') + `-${height}p.mp4`;
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

  // ── queue ───────────────────────────────────────────────────────────────
  if (op === 'queue') {
    if (!(await isOperator(req))) return json({ error: 'not_an_operator' }, 403, req);

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
        { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
      );
      if (res.ok) {
        const rows = await res.json() as Array<{ id: string }>;
        if (rows.length) asset = rows[0].id;
      }
    }
    if (!asset) return json({ error: 'no_asset' }, 400, req);

    const state = await rpc('queue_transcode', { p_asset: asset });
    return json({ ok: true, asset_id: asset, state, runner: !!RUNNER_SECRET },
      200, req);
  }

  // ── health ──────────────────────────────────────────────────────────────
  // What the console's panel reads. Operator-only: it is a list of object
  // keys, and a list of object keys is a map of the bucket.
  if (op === 'health') {
    if (!(await isOperator(req))) return json({ error: 'not_an_operator' }, 403, req);
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

    const rows = await rpc('claim_transcode', {}) as Array<Record<string, unknown>>;
    if (!Array.isArray(rows) || !rows.length) return json({}, 200, req);
    const job = rows[0];
    const masterKey = String(job.object_key ?? '');
    const srcHeight = Number(job.height ?? 0) || 2160;

    // SIX HOURS FOR THE MASTER, TWENTY-FOUR FOR THE RUNGS, and the asymmetry
    // is deliberate. The download happens in the job's first minute; the
    // last rung is written at the end of an encode that can run for hours.
    // A URL that expires mid-job throws away everything after it.
    const put: Record<string, string> = {};
    for (const h of RUNGS) {
      if (h > srcHeight) continue;
      put[String(h)] = await presign('PUT', rungKey(masterKey, h), 86400);
    }

    return json({
      asset_id: job.asset_id,
      src_url: await presign('GET', masterKey, 21600),
      put,
      done_url: `${SUPABASE_URL}/functions/v1/transcode`,
      // NOT the runner's token. It already holds the secret — it just used
      // it to claim this job — and echoing a secret back into a response
      // body puts it one careless log line away from a public run log.
      duration_s: job.duration_s ?? null,
      height: srcHeight,
    }, 200, req);
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
    const written = await rpc('record_renditions', {
      p_asset: asset, p_rows: rows, p_note: note,
    });
    return json({ ok: true, written }, 200, req);
  }

  return json({ error: 'unknown_op' }, 400, req);
});
