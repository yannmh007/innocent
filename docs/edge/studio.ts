// studio — the upload page, and the two calls behind it.
//
// WHY THIS EXISTS. Putting one title into the catalogue used to mean: open the
// R2 dashboard, upload the video, upload the poster, copy both object keys,
// open the SQL editor, write an INSERT for `titles`, write another for
// `title_assets`, get the key spelling exactly right in both. Per title. From
// a phone. That is the whole reason the catalogue has one row in it.
//
// This serves a page that does all of it: pick the files, type a name, tap
// Publish.
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
// understand before editing. A browser loading a page cannot send an
// Authorization header, so the platform's own JWT gate would make the page
// unreachable. The gate is therefore applied HERE, per operation: `sign` and
// `publish` both refuse without a token belonging to an operator. The only
// thing served without a token is the HTML, which contains nothing.

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
const ANON_KEY = Deno.env.get('SB_ANON_KEY') ?? '';

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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  if (req.method === 'GET') {
    // Filled in at serve time rather than written into the HTML, so the page
    // cannot drift from the project it is deployed in. Neither value is a
    // secret: both already ship inside every copy of the app.
    const page = PAGE
      .replaceAll('__SUPABASE_URL__', SUPABASE_URL)
      .replaceAll('__ANON_KEY__', ANON_KEY);
    return new Response(page, {
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  if (req.method !== 'POST') return json({ error: 'method' }, 405);

  const who = await operatorId(req);
  if (!who) return json({ error: 'not_an_operator' }, 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'bad_json' }, 400);
  }

  // --- sign: hand back one presigned PUT URL -------------------------------
  if (body.op === 'sign') {
    const filename = String(body.filename ?? '');
    const kind = body.kind === 'photo' ? 'photo' : 'video';
    if (!filename) return json({ error: 'no_filename' }, 400);

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
    });
  }

  // --- publish: the rows that make it a title ------------------------------
  //
  // Service role, because `titles` is not writable by `authenticated` and
  // should not be: the check that matters already happened above, against a
  // list of two-or-fewer people, and widening RLS to let a signed-in user
  // write the catalogue would be a far larger hole than this function is.
  if (body.op === 'publish') {
    if (!SERVICE_KEY) return json({ error: 'no_service_key' }, 500);

    const title = String(body.title ?? '').trim();
    if (!title) return json({ error: 'no_title' }, 400);

    const video = body.video as { bucket: string; objectKey: string } | null;
    if (!video?.objectKey) return json({ error: 'no_video' }, 400);

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

    if (titleErr) return json({ error: 'title_insert', detail: titleErr.message }, 500);

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
    if (assetErr) return json({ error: 'asset_insert', detail: assetErr.message }, 500);

    return json({ id: row.id, title, status: body.publish === true ? 'published' : 'draft' });
  }

  return json({ error: 'unknown_op' }, 400);
});

// --- the page ---------------------------------------------------------------
// One file, no framework, no build step. It is edited here and deployed by
// deploying this function, which is the only way it can be kept in step with
// the two calls above.
const PAGE = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Innocent Studio</title>
<style>
:root{--bg:#0b0b0d;--s1:#141418;--s2:#1c1c22;--line:#2a2a32;--fg:#f2f2f5;--dim:#9a9aa6;--acc:#ffffff}
*{box-sizing:border-box}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);
  font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  max-width:560px;margin-inline:auto}
h1{font-size:19px;margin:8px 0 4px}
p.sub{color:var(--dim);margin:0 0 20px;font-size:13.5px}
label{display:block;font-size:12.5px;color:var(--dim);margin:14px 0 6px;letter-spacing:.02em}
input,textarea,select,button{width:100%;font:inherit;color:var(--fg);
  background:var(--s2);border:1px solid var(--line);border-radius:10px;padding:11px 12px}
textarea{min-height:72px;resize:vertical}
button{background:var(--acc);color:#000;font-weight:700;border:0;padding:14px;margin-top:20px}
button:disabled{opacity:.45}
.row{display:flex;gap:10px;align-items:center;margin-top:12px}
.row input[type=checkbox]{width:auto;margin:0}
.row label{margin:0;color:var(--fg);font-size:14px}
.card{background:var(--s1);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:14px}
.bar{height:5px;background:var(--s2);border-radius:3px;overflow:hidden;margin-top:8px}
.bar i{display:block;height:100%;width:0;background:var(--fg);transition:width .2s}
.msg{margin-top:16px;padding:12px;border-radius:10px;font-size:13.5px;white-space:pre-wrap}
.ok{background:#0f2a18;color:#8ff0b0}.err{background:#2a1010;color:#ff9b9b}
small{color:var(--dim);font-size:12px}
</style></head><body>

<h1>Innocent Studio</h1>
<p class="sub">Upload a title straight to R2 and put it in the catalogue.</p>

<div id="gate" class="card">
  <p class="sub" style="margin:0 0 12px">Sign in with the account that owns the catalogue.</p>
  <button id="signin">Continue with Google</button>
  <div id="who" hidden><small id="whoami"></small></div>
</div>

<div id="form" hidden>
  <div class="card">
    <label>Video file</label>
    <input id="video" type="file" accept="video/*">
    <div class="bar"><i id="vbar"></i></div>
  </div>

  <div class="card">
    <label>Poster / photo (optional)</label>
    <input id="photo" type="file" accept="image/*">
    <div class="bar"><i id="pbar"></i></div>
  </div>

  <div class="card">
    <label>Title</label>
    <input id="title" placeholder="Name shown in the app">
    <label>Title (Burmese, optional)</label>
    <input id="titleMm">
    <label>Synopsis (optional)</label>
    <textarea id="synopsis"></textarea>
    <label>Category</label>
    <select id="category">
      <option value="movies">movies</option>
      <option value="series">series</option>
      <option value="clips">clips</option>
    </select>
    <div class="row"><input id="free" type="checkbox"><label for="free">Free to watch</label></div>
    <div class="row"><input id="pub" type="checkbox" checked><label for="pub">Publish now</label></div>
  </div>

  <button id="go">Upload and publish</button>
</div>

<div id="msg"></div>

<!-- The UMD build, not the ESM one. esm.sh serves modules, which a plain
     <script src> does not evaluate into a global, so the supabase global would be
     undefined on the next line. jsdelivr's dist/umd/supabase.js is the
     browser bundle the package itself points "jsdelivr" at. -->
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
<script>
const $ = (id) => document.getElementById(id);
let TOKEN = '';

// The same Google sign-in the app uses, through the same provider, so there is
// one account system and not two. The operator check happens on the server
// against a list of user ids — signing in is not the same as being allowed to
// publish, and a stranger who signs in here gets 403 from every call.
const sb = supabase.createClient('__SUPABASE_URL__', '__ANON_KEY__');

async function refresh() {
  const { data } = await sb.auth.getSession();
  const s = data.session;
  if (!s) { $('gate').hidden = false; $('form').hidden = true; return; }
  TOKEN = s.access_token;
  $('gate').hidden = true;
  $('form').hidden = false;
  $('who').hidden = false;
  $('whoami').textContent = 'Signed in as ' + (s.user.email || s.user.id);
}

$('signin').onclick = async () => {
  const { error } = await sb.auth.signInWithOAuth({
    provider: 'google',
    // Back to this page, not to a default — otherwise the round trip lands
    // wherever the project's Site URL points, which is not here.
    options: { redirectTo: location.origin + location.pathname },
  });
  if (error) say(error.message, 'err');
};

// supabase-js parses the tokens out of the URL fragment on load; this runs
// after that has happened.
sb.auth.onAuthStateChange(() => refresh());
refresh();

function say(text, cls) { $('msg').className = 'msg ' + cls; $('msg').textContent = text; }

async function api(payload) {
  const r = await fetch(location.pathname, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + TOKEN },
    body: JSON.stringify(payload),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.detail || body.error || ('HTTP ' + r.status));
  return body;
}

// XHR rather than fetch, for one reason: upload progress. fetch cannot report
// how far a request body has got, and a phone sending 900 MB with no feedback
// is indistinguishable from a phone that has frozen.
function put(url, file, bar) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open('PUT', url);
    x.upload.onprogress = (e) => {
      if (e.lengthComputable) bar.style.width = (e.loaded / e.total * 100) + '%';
    };
    x.onload = () => (x.status >= 200 && x.status < 300)
      ? resolve() : reject(new Error('R2 refused the upload (HTTP ' + x.status + ')'));
    x.onerror = () => reject(new Error('Upload failed. If this is the first run, check the bucket CORS policy.'));
    x.send(file);
  });
}

$('go').onclick = async () => {
  const v = $('video').files[0];
  const p = $('photo').files[0];
  const title = $('title').value.trim();
  if (!v) return say('Pick a video first.', 'err');
  if (!title) return say('Give it a title.', 'err');

  $('go').disabled = true;
  try {
    say('Asking for an upload URL…', 'ok');
    const vs = await api({ op: 'sign', kind: 'video', filename: v.name });
    say('Uploading video…', 'ok');
    await put(vs.uploadUrl, v, $('vbar'));

    let ps = null;
    if (p) {
      const s = await api({ op: 'sign', kind: 'photo', filename: p.name });
      say('Uploading poster…', 'ok');
      await put(s.uploadUrl, p, $('pbar'));
      ps = { objectKey: s.objectKey, publicUrl: s.publicUrl };
    }

    say('Writing the catalogue row…', 'ok');
    const out = await api({
      op: 'publish',
      title,
      titleMm: $('titleMm').value,
      synopsis: $('synopsis').value,
      category: $('category').value,
      free: $('free').checked,
      publish: $('pub').checked,
      video: { bucket: vs.bucket, objectKey: vs.objectKey },
      photo: ps,
    });
    say('Done — "' + out.title + '" is ' + out.status + '.\\n' + out.id, 'ok');
    $('video').value = ''; $('photo').value = ''; $('title').value = '';
    $('vbar').style.width = '0'; $('pbar').style.width = '0';
  } catch (e) {
    say(String(e.message || e), 'err');
  } finally {
    $('go').disabled = false;
  }
};
</script>
</body></html>`;
