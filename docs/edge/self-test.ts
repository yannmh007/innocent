// ===========================================================================
// self-test — Supabase Edge Function
// Innocent Movies. Written 2 Sep 2026 for app v1.63.6+311.
//
// WHAT THIS IS FOR
//
// The plan is to finish the client, then work only on the server and watch the
// app for the result. That plan has one hole: when the server refuses or
// misbehaves, the app shows one sentence and hides the reason. Twice in two
// days a flat `not_found` sent this project down the wrong path, and both
// times the fix was to make the server SAY what happened.
//
// This function is that, generalised. One call checks that the server still
// satisfies the contract the client was built against, and names the first
// thing that stopped being true.
//
// EVERY CHECK HERE IS SOMETHING THAT HAS ALREADY BROKEN, OR NEARLY DID:
//   * the column list drifted from the code and would have 400'd every request
//   * `service_role` had no grants, and the symptom was `not_found`
//   * `verify_jwt` defaults on, and a redeploy can turn it back on
//   * the new-style key is not a JWT and cannot go in Authorization
//   * a signed URL that does not expire makes every other control decorative
//
// DEPLOY
//   Edge Functions -> Deploy a new function -> Via Editor -> name it exactly
//   `self-test` -> paste -> Deploy -> Settings -> turn `Verify JWT` OFF.
//
//   Add one secret:  SB_ANON_KEY = the sb_publishable_... key.
//   That key is not secret - it ships inside the APK - but the function needs
//   it to ask questions AS THE APP, which is the only way to test what the app
//   will actually experience. Checking as service_role would pass while the
//   app fails, which is worse than not checking at all.
// ===========================================================================

const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY = Deno.env.get('SB_ANON_KEY') ?? '';
const URL_BASE = Deno.env.get('SUPABASE_URL') ?? '';

// The EXACT column list `api_content_repository.dart` sends. Copied, not
// summarised: PostgREST rejects the whole request if one name is unknown, so
// this string is the contract and a paraphrase of it tests nothing.
const TITLE_COLUMNS =
  'id,title,title_mm,synopsis,category,poster_url,year,rating,' +
  'quality_label,genres,episode_count,view_count,access_tier,' +
  'photo_count,video_count';

type Check = {
  name: string;
  status: 'PASS' | 'FAIL' | 'SKIP';
  detail?: string;
};

const checks: Check[] = [];
function record(name: string, ok: boolean, detail?: string) {
  checks.push({ name, status: ok ? 'PASS' : 'FAIL', detail });
}
function skip(name: string, detail: string) {
  checks.push({ name, status: 'SKIP', detail });
}

/** A request made the way the APP makes it: key in `apikey`, never Bearer. */
function asAnon(path: string, init: RequestInit = {}) {
  return fetch(`${URL_BASE}${path}`, {
    ...init,
    headers: {
      apikey: ANON_KEY,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
}

// ── ADMINS ONLY (security review 2026-10-05) ────────────────────────────────
// This function was deployed with verify_jwt off and no check of its own, so
// anybody on the internet could run it — and it answers with what it found
// (key lengths, table errors, object keys), using the service key. Now only
// a console admin (editor or owner) may, with the same MFA rule as the
// console (studio.ts whoIsAsking).
const GATE_RANK: Record<string, number> = { viewer: 1, uploader: 2, editor: 3, owner: 4 };

async function adminGate(req: Request): Promise<Response | null> {
  const no = (code: string, status: number) => new Response(
    JSON.stringify({ error: code }),
    { status, headers: { 'Content-Type': 'application/json' } });
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const key = Deno.env.get('SB_SERVICE_KEY') ??
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const anon = Deno.env.get('SB_ANON_KEY') ?? Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.toLowerCase().startsWith('bearer ') || !url || !key) {
    return no('not_signed_in', 401);
  }
  const u = await fetch(`${url}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: anon || key },
  });
  if (!u.ok) return no('not_signed_in', 401);
  const id = (await u.json())?.id;
  if (typeof id !== 'string' || !id) return no('not_signed_in', 401);
  const r = await fetch(`${url}/rest/v1/rpc/admin_resolve`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`,
               'Content-Type': 'application/json' },
    body: JSON.stringify({ p_user: id }),
  });
  if (!r.ok) return no('admin_lookup_failed', 500);
  const rows = await r.json();
  const row = Array.isArray(rows) ? rows[0] : null;
  if (!row || (GATE_RANK[String(row.role ?? '')] ?? 0) < GATE_RANK.editor) {
    return no('not_an_admin', 403);
  }
  if (row.require_mfa === true) {
    try {
      const part = auth.slice(7).split('.')[1] ?? '';
      const b = part.replace(/-/g, '+').replace(/_/g, '/');
      const claims = JSON.parse(atob(b + '='.repeat((4 - b.length % 4) % 4)));
      if (claims.aal !== 'aal2') return no('mfa_required', 403);
    } catch {
      return no('mfa_required', 403);
    }
  }
  return null;
}

Deno.serve(async (req) => {
  const refused = await adminGate(req);
  if (refused) return refused;
  checks.length = 0;

  // --- 0. the function's own prerequisites ---------------------------------
  record('service key present', SERVICE_KEY.length > 50,
    `${SERVICE_KEY.length} chars`);
  const anonReady = ANON_KEY.length > 20;
  record('anon key present', anonReady, `${ANON_KEY.length} chars`);

  // --- 1. schema version ---------------------------------------------------
  try {
    const r = await fetch(
      `${URL_BASE}/rest/v1/schema_migrations?select=version&order=version.desc&limit=1`,
      { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
    );
    const rows = await r.json();
    // `Array.isArray(rows) && ...` yields FALSE, not null, when PostgREST
    // returns an error object - and `false ?? x` is `false`, because `??`
    // only falls back on null/undefined. The first version of this line
    // therefore reported `detail: false` and threw away the actual error, in
    // a function whose entire purpose is to not do that.
    const latest = Array.isArray(rows) ? rows[0]?.version : undefined;
    record('schema_migrations readable', !!latest,
      latest ?? `HTTP ${r.status} ${JSON.stringify(rows).slice(0, 200)}`);
  } catch (e) {
    record('schema_migrations readable', false, String(e).slice(0, 120));
  }

  if (!anonReady) {
    skip('anon checks', 'SB_ANON_KEY not set — add it and re-run');
    return new Response(JSON.stringify({ checks }, null, 2),
      { headers: { 'Content-Type': 'application/json' } });
  }

  // --- 2. THE COLUMN CONTRACT ----------------------------------------------
  // The single most expensive failure this project has had. One unknown name
  // and every catalogue request 400s, which on screen is an empty catalogue
  // with no error at all.
  try {
    const r = await asAnon(`/rest/v1/titles?select=${TITLE_COLUMNS}&limit=1`);
    const body = await r.text();
    record('all 15 client columns readable as anon', r.status === 200,
      r.status === 200 ? `${r.status}` : body.slice(0, 200));
  } catch (e) {
    record('all 15 client columns readable as anon', false, String(e).slice(0, 120));
  }

  // --- 3. THE ONE THAT MUST FAIL -------------------------------------------
  // `anon` is the key inside the APK. Anyone can extract it. If this check
  // ever passes, every media path in the catalogue is public and the paywall
  // is decorative.
  try {
    const r = await asAnon('/rest/v1/titles?select=locator&limit=1');
    record('anon CANNOT read locator', r.status !== 200,
      r.status === 200 ? 'LEAK — anon read the locator column' : `refused ${r.status}`);
  } catch {
    record('anon CANNOT read locator', true, 'refused');
  }

  // --- 4. the catalogue is actually visible --------------------------------
  try {
    const r = await asAnon('/rest/v1/titles?select=id,title&limit=5');
    const rows = await r.json();
    const n = Array.isArray(rows) ? rows.length : 0;
    record('anon CAN read the catalogue', r.status === 200 && n > 0,
      `${n} row(s)`);
  } catch (e) {
    record('anon CAN read the catalogue', false, String(e).slice(0, 120));
  }

  // --- 5. the RPCs the home screen depends on ------------------------------
  for (const [name, path, body] of [
    ['landing_rows', '/rest/v1/rpc/landing_rows', '{}'],
    ['catalogue_facets', '/rest/v1/rpc/catalogue_facets', '{}'],
  ] as const) {
    try {
      const r = await asAnon(path, { method: 'POST', body });
      record(`rpc ${name}`, r.status === 200,
        r.status === 200 ? 'ok' : (await r.text()).slice(0, 160));
    } catch (e) {
      record(`rpc ${name}`, false, String(e).slice(0, 120));
    }
  }

  // --- 6. playback, end to end ---------------------------------------------
  // Uses a FREE published title, because the premium path needs tables that do
  // not exist yet and would fail for the right reason - which would still read
  // as a failure here.
  let freeId: string | null = null;
  try {
    const r = await asAnon(
      '/rest/v1/titles?select=id&access_tier=eq.free&limit=1');
    const rows = await r.json();
    freeId = Array.isArray(rows) && rows[0] ? rows[0].id : null;
  } catch { /* reported below */ }

  if (!freeId) {
    skip('playback grant', 'no free published title to test with');
    skip('signed URL expires', 'no free published title to test with');
  } else {
    try {
      const r = await asAnon('/functions/v1/request-playback', {
        method: 'POST',
        body: JSON.stringify({ title_id: freeId }),
      });
      const j = await r.json();
      const url: string | undefined = j?.url;
      record('playback grant', !!url,
        url ? 'signed URL returned' : JSON.stringify(j).slice(0, 200));

      // A URL that does not expire makes every other control here pointless:
      // one leaked link would serve the file forever.
      if (j?.expires_at) {
        const mins = (new Date(j.expires_at).getTime() - Date.now()) / 60000;
        record('signed URL expires within 15 min', mins > 0 && mins <= 15,
          `${mins.toFixed(1)} min`);
      } else {
        record('signed URL expires within 15 min', false, 'no expires_at');
      }
    } catch (e) {
      record('playback grant', false, String(e).slice(0, 120));
      skip('signed URL expires', 'playback grant failed');
    }
  }

  const failed = checks.filter((c) => c.status === 'FAIL').length;
  return new Response(
    JSON.stringify({
      ok: failed === 0,
      failed,
      checked_at: new Date().toISOString(),
      checks,
    }, null, 2),
    {
      status: failed === 0 ? 200 : 500,
      headers: { 'Content-Type': 'application/json' },
    },
  );
});
