// Innocent Studio — the page's own code, moved out of index.html on
// 2026-10-23 so the page can carry a Content-Security-Policy that allows no
// inline script at all (see the <meta> at the top of index.html). Nothing
// else changed: it is still a classic script, loaded in the same place, in
// the same global scope as shell.js and the rest.
// ── configuration ────────────────────────────────────────────────────────
// Neither is a secret; both already ship inside every APK.
const SB_URL = 'https://yqonvmuiezqvyqmexrft.supabase.co';
const SB_KEY = 'sb_publishable_vTiAxBAhnZL_BqFcZD4m9A_Rb8Q8PHj';
const API = SB_URL + '/functions/v1/studio';
// A SECOND FUNCTION, NOT A SECOND OP. `studio` is a thousand lines and is
// the only control surface this operator has; every deploy of it is a small
// risk taken with that. The probe only reads, so it lives on its own where
// it can be changed without anyone holding their breath.
const PROBE_API = SB_URL + '/functions/v1/probe-media';
const TRANSCODE_API = SB_URL + '/functions/v1/transcode';
const INGEST_API = SB_URL + '/functions/v1/ingest';
// Payment screenshots (migration 040): signed addresses for the Requests page.
const PREMIUM_API = SB_URL + '/functions/v1/premium-request';

// WHAT THE CATEGORY PICKER OFFERS, read from the database rather than compiled.
//
// This was hard-coded, with a comment explaining that the app compiled these
// into libapp.so so the Categories tab could rename them but not add one. That
// is no longer true — titles.category is a foreign key to public.categories
// (migration 020) and the app's tab bar no longer keys off an exhaustive enum
// (CategoryRef) — so hard-coding it here would be the last place a new section
// could not reach.
//
// Seeded with the four that have always existed so the picker is never empty
// on a cold load or an offline console, and replaced by the table as soon as it
// answers. `all` is excluded because it is the landing TAB: the database has a
// constraint saying no title may be in it.
let CATEGORIES = ['movies', 'series', 'reels'];

async function refreshCategoryOptions() {
  try {
    const { categories } = await api({ op: 'categories' });
    const rows = (categories ?? [])
      .filter((c) => c.id !== 'all')
      .sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
    // The value stays the id (what an older studio takes); the code is shown
    // beside the name, so the operator sees what the title will carry.
    const opts = rows.map((c) => ({ value: String(c.id),
      label: (c.label || c.id) + (c.code ? ' · ' + c.code : '') }));
    if (opts.length) CATEGORIES = opts;
  } catch (e) {
    // A console that cannot reach the table keeps the seeded list. Refusing to
    // draw the form would be worse: the operator would be unable to edit a
    // title's other fields either.
    console.warn('category options: ' + (e && e.message ? e.message : e));
  }
}

const sb = supabase.createClient(SB_URL, SB_KEY);

// ── DOM helpers ──────────────────────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, kids = []) => {
  const n = Object.assign(document.createElement(tag), props);
  for (const k of [].concat(kids)) if (k != null) n.append(k);
  return n;
};
// TEXT, NEVER innerHTML, for anything out of the database. "The operator
// typed it" is not the same as "safe to evaluate", and a console that renders
// its own catalogue as HTML is one paste away from running it.
const text = (s) => document.createTextNode(s == null ? '' : String(s));

function say(kind, s) {
  $('msg').className = 'msg ' + kind;
  $('msg').textContent = s;
  if (kind !== 'info') window.scrollTo({ top: 0, behavior: 'smooth' });
}
const clear = () => { $('msg').className = ''; $('msg').textContent = ''; };

const fmtDur = (s) => {
  if (!s) return '';
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return (h ? h + ':' + String(m).padStart(2, '0') : String(m)) +
    ':' + String(x).padStart(2, '0');
};
const fmtSize = (b) => b >= 1073741824 ? (b / 1073741824).toFixed(1) + ' GB'
  : b >= 1048576 ? (b / 1048576).toFixed(0) + ' MB'
  : (b / 1024).toFixed(0) + ' KB';

// ── the API ──────────────────────────────────────────────────────────────
async function api(payload, endpoint, retried) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('Signed out. Reload and sign in again.');
  noteActivity();
  const res = await fetch(endpoint || API, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer ' + session.access_token,
    },
    body: JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  // THE SERVER ASKED FOR THE AUTHENTICATOR CODE: `mfa_required` when this
  // session never gave one, `reauth_required` when it gave one too long ago
  // for what is being done (deleting a title, changing an admin). Asked for
  // here, once, and the same request sent again — so no page has to know.
  if (!retried && (body.error === 'mfa_required' || body.error === 'reauth_required')) {
    if (await askForCode(body.error)) return api(payload, endpoint, true);
  }
  if (!res.ok) {
    const e = new Error(explainError(body.error, res.status) +
      (body.detail ? ' — ' + body.detail : ''));
    e.code = body.error || String(res.status);
    throw e;
  }
  return body;
}

// ── measuring a file in the browser ──────────────────────────────────────
//
// Returns what title_assets wants and could never get from the old page:
// duration, width, height, and for a video a JPEG poster frame.
//
// EVERYTHING IS BEST-EFFORT. A codec the browser cannot decode gives no
// dimensions and no frame, and that must not stop the upload — a video with
// null width still plays, it just gets a default tile shape. So every step
// here resolves rather than rejects.
function measure(file) {
  const isVideo = file.type.startsWith('video');
  const url = URL.createObjectURL(file);

  if (!isVideo) {
    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        resolve({ width: img.naturalWidth, height: img.naturalHeight });
        URL.revokeObjectURL(url);
      };
      img.onerror = () => { resolve({}); URL.revokeObjectURL(url); };
      img.src = url;
    });
  }

  return new Promise((resolve) => {
    const v = document.createElement('video');
    v.preload = 'metadata';
    v.muted = true;
    // Required on iOS Safari, which otherwise refuses to decode a frame
    // without a user gesture and hands back a black canvas.
    v.playsInline = true;

    const done = (out) => { URL.revokeObjectURL(url); resolve(out); };
    // A file the browser cannot decode never fires either event. Without this
    // the whole upload queue would wait forever on one bad file.
    const bail = setTimeout(() => done({}), 15000);

    v.onloadedmetadata = () => {
      const meta = {
        durationS: Number.isFinite(v.duration) ? Math.round(v.duration) : null,
        width: v.videoWidth || null,
        height: v.videoHeight || null,
      };
      // ONE SECOND IN — the owner's rule (2026-10-06), and the same frame
      // the runner takes as frame 0 of the cover picker (043), so a video
      // uploaded here and one forwarded to the bot start with the same
      // picture. Anything shorter than two seconds: half-way.
      const at = (v.duration || 0) >= 2 ? 1 : (v.duration || 0) / 2;
      v.onseeked = () => {
        clearTimeout(bail);
        try {
          const scale = Math.min(1, 640 / (v.videoWidth || 640));
          const c = el('canvas', {
            width: Math.round((v.videoWidth || 640) * scale),
            height: Math.round((v.videoHeight || 360) * scale),
          });
          c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
          c.toBlob((b) => done({ ...meta, thumb: b }), 'image/jpeg', 0.82);
        } catch (_) { done(meta); }
      };
      v.onerror = () => { clearTimeout(bail); done(meta); };
      try { v.currentTime = at; } catch (_) { clearTimeout(bail); done(meta); }
    };
    v.onerror = () => { clearTimeout(bail); done({}); };
    v.src = url;
  });
}


// ── faststart: moving the moov atom to the front ─────────────────────────
//
// THE SINGLE LARGEST CAUSE OF A BLACK SCREEN BEFORE PLAYBACK, and it is
// decided here, at upload, not in the player.
//
// An MP4 is a flat list of boxes. `mdat` holds the samples; `moov` holds the
// index that says where every sample is. Encoders that do not know the final
// size until they are finished — which is most of them, and all of the phone
// ones — write `mdat` first and append `moov` at the end. A local player
// never notices: it seeks to the end for free. Over HTTP it is expensive and
// visible: the demuxer opens at byte zero, finds no index, and has to fetch
// the tail of a file that may be two gigabytes away before it can decode a
// single frame. That is a second round trip at best, and on a fresh
// connection it is a TCP handshake and a TLS negotiation as well.
//
// Rewriting it costs no re-encode. The bytes of every sample are untouched;
// only the ORDER of the top-level boxes changes, plus the chunk-offset table
// inside `moov`, which has to be corrected because every chunk has just moved
// forward by the size of the `moov` box that was inserted in front of it.
//
// EVERY FAILURE PATH RETURNS THE ORIGINAL FILE. A video that uploads slightly
// slow to start is a small problem; a video corrupted by a rewrite that
// misread a box is a total one, and there is no way to get the original back
// once it is in the bucket. So anything unexpected — a box shape not
// recognised, an offset that would overflow, a truncated file — declines and
// says why, and the upload proceeds with the bytes the operator chose.

/// Reads the top-level box list without loading the file.
///
/// `File.slice()` is lazy, so this touches sixteen bytes per box however
/// large the file is. A two-hour film is typically five or six top-level
/// boxes, so this is a handful of small reads.
async function topLevelBoxes(file) {
  const out = [];
  let at = 0;
  while (at + 8 <= file.size) {
    const head = new DataView(await file.slice(at, at + 16).arrayBuffer());
    if (head.byteLength < 8) break;
    let size = head.getUint32(0);
    const type = String.fromCharCode(
      head.getUint8(4), head.getUint8(5), head.getUint8(6), head.getUint8(7));
    let header = 8;
    if (size === 1) {
      // 64-bit size, for an mdat larger than 4 GiB.
      if (head.byteLength < 16) return null;
      const hi = head.getUint32(8);
      const lo = head.getUint32(12);
      size = hi * 4294967296 + lo;
      header = 16;
    } else if (size === 0) {
      // "to end of file" — legal, and only ever the last box.
      size = file.size - at;
    }
    // A size that does not advance, or runs past the end, means this is not
    // a box list we understand. Better to decline than to guess.
    if (size < header || at + size > file.size) return null;
    out.push({ type, start: at, size });
    at += size;
  }
  return out;
}

/// Adds `delta` to every chunk offset inside a moov buffer.
///
/// Walks only the containers chunk offsets can live in, so a box shaped
/// unexpectedly elsewhere in the tree cannot be misread as a table. Returns
/// false if anything is wrong, and the caller then uses the original file.
function shiftChunkOffsets(view, start, end, delta, moovStart) {
  let at = start;
  const CONTAINERS = ['moov', 'trak', 'mdia', 'minf', 'stbl', 'edts'];
  while (at + 8 <= end) {
    let size = view.getUint32(at);
    const type = String.fromCharCode(
      view.getUint8(at + 4), view.getUint8(at + 5),
      view.getUint8(at + 6), view.getUint8(at + 7));
    let header = 8;
    if (size === 1) {
      if (at + 16 > end) return false;
      size = view.getUint32(at + 8) * 4294967296 + view.getUint32(at + 12);
      header = 16;
    } else if (size === 0) {
      size = end - at;
    }
    if (size < header || at + size > end) return false;

    if (CONTAINERS.includes(type)) {
      if (!shiftChunkOffsets(view, at + header, at + size, delta, moovStart)) {
        return false;
      }
    } else if (type === 'stco' || type === 'co64') {
      // version(1) + flags(3) + entry_count(4), then the table.
      const body = at + header + 4;
      if (body + 4 > at + size) return false;
      const count = view.getUint32(body);
      const wide = type === 'co64';
      const width = wide ? 8 : 4;
      if (body + 4 + count * width > at + size) return false;
      for (let i = 0; i < count; i++) {
        const p = body + 4 + i * width;
        if (wide) {
          const v = view.getUint32(p) * 4294967296 + view.getUint32(p + 4);
          // Only what moved. A chunk already past the old moov position does
          // not shift, because the boxes ahead of it are the same set either
          // way — moov simply swapped places with what was between them.
          if (v >= moovStart) continue;
          const n = v + delta;
          view.setUint32(p, Math.floor(n / 4294967296));
          view.setUint32(p + 4, n % 4294967296);
        } else {
          const v = view.getUint32(p);
          if (v >= moovStart) continue;
          const n = v + delta;
          // A 32-bit table that would need 33 bits. Promoting stco to co64
          // means resizing the box and every parent, so this declines
          // instead — it needs a file within a few megabytes of 4 GiB, which
          // the 5 GiB single-PUT ceiling already makes rare.
          if (n > 0xFFFFFFFF) return false;
          view.setUint32(p, n);
        }
      }
    }
    at += size;
  }
  return true;
}

/// Returns `{ blob, state, detail }`. `blob` is always safe to upload.
async function faststart(file) {
  const keep = (state, detail) => ({ blob: file, state, detail });
  if (!/\.(mp4|m4v|mov)$/i.test(file.name) &&
      !/^video\/(mp4|quicktime|x-m4v)$/i.test(file.type || '')) {
    return keep('skipped', 'not an MP4-family file');
  }
  let boxes;
  try {
    boxes = await topLevelBoxes(file);
  } catch (e) {
    return keep('skipped', 'could not be read: ' + (e.message || e));
  }
  if (!boxes) return keep('skipped', 'unrecognised box layout');

  const moov = boxes.find((b) => b.type === 'moov');
  const mdat = boxes.find((b) => b.type === 'mdat');
  if (!moov || !mdat) return keep('skipped', 'no moov/mdat pair');
  // The reassembly below writes ftyp first. That is only a no-op — and the
  // offset arithmetic only holds — if ftyp was already first, which it is in
  // every file any encoder produces. A file that breaks that assumption gets
  // left alone rather than reordered on a guess.
  if (!boxes.length || boxes[0].type !== 'ftyp') {
    return keep('skipped', 'the file does not begin with ftyp');
  }
  if (moov.start < mdat.start) return keep('already', 'moov is already first');
  // A moov this large would have to be held in memory to patch. Declining is
  // honest; the alternative is an out-of-memory crash on the operator's
  // phone midway through a 2 GB upload.
  if (moov.size > 128 * 1024 * 1024) {
    return keep('skipped', 'moov is too large to rewrite in the browser');
  }

  let buf;
  try {
    buf = await file.slice(moov.start, moov.start + moov.size).arrayBuffer();
  } catch (e) {
    return keep('skipped', 'moov could not be read: ' + (e.message || e));
  }
  const view = new DataView(buf);
  // Walk INSIDE the moov box, so `start` is past its own 8-byte header.
  if (!shiftChunkOffsets(view, 8, buf.byteLength, moov.size, moov.start)) {
    return keep('skipped', 'chunk offset table could not be corrected');
  }

  // ftyp first if there is one — some players refuse a file that does not
  // begin with it — then moov, then everything else in its original order.
  const parts = [];
  const ftyp = boxes.find((b) => b.type === 'ftyp');
  if (ftyp) parts.push(file.slice(ftyp.start, ftyp.start + ftyp.size));
  parts.push(buf);
  for (const b of boxes) {
    if (b === moov || b === ftyp) continue;
    parts.push(file.slice(b.start, b.start + b.size));
  }
  const blob = new Blob(parts, { type: file.type || 'video/mp4' });
  // The rewrite must not change a single byte of length. If it did, the
  // offsets just patched are wrong and the file would play as noise.
  if (blob.size !== file.size) {
    return keep('skipped', 'rewrite changed the file length — refused');
  }
  return { blob, state: 'moved', detail: 'moov moved to the front' };
}

// ── uploading ────────────────────────────────────────────────────────────
//
// XHR, not fetch. `fetch` has no upload progress event, and an operator
// watching a 900 MB video go up over a mobile connection with no progress bar
// will conclude the page is broken and reload it.
function put(url, blob, onProgress) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open('PUT', url);
    x.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) onProgress(e.loaded / e.total);
    };
    x.onload = () => (x.status >= 200 && x.status < 300) ? resolve()
      // R2 does not attach CORS headers to its error responses, so the browser
      // usually blocks the body before this can read it. Naming the two likely
      // causes is the most this side can honestly do.
      : reject(new Error('R2 refused the upload (HTTP ' + x.status + '). ' +
          'Use "Check bucket access" to tell a CORS fault from a token fault.'));
    x.onerror = () => reject(new Error(
      'Upload blocked by the browser. Either the bucket has no CORS rule for ' +
      'this page, or the R2 token cannot write to it. Use "Check bucket access".'));
    x.send(blob);
  });
}

// ── multipart, retries, waiting for the network, resume: upload.js ──────
//
// The parts, the patience and the record that lets a dead tab carry on all
// live in upload.js now (`putInParts`, `putSmall`, `patiently`, the job
// store). `put` above stays for the small extras — a poster frame, a chosen
// thumbnail — where losing one costs a picture, not an upload.

/// Measures, presigns, uploads, and returns the asset descriptor the API wants.
///
/// `ctx` (optional): `status(text, tone)` for the row's live line, `resume`
/// (an earlier multipart record for this file) and `record(mp)` (called with
/// each new state of the multipart upload, for the job store).
async function uploadOne(file, onProgress, folder, note, ctx = {}) {
  const isVideo = file.type.startsWith('video');
  const meta = await measure(file);

  // Reordered BEFORE the upload, not after, because there is no "after" —
  // once the object is in R2 the only way to fix its box order is to upload
  // it again. `body` is the original file whenever the rewrite declines, and
  // it declines loudly so the operator knows which of their files will make
  // viewers wait.
  let body = file;
  if (isVideo) {
    const fs = await faststart(file);
    body = fs.blob;
    if (note) note(fs.state, fs.detail);
  }

  // ONE PUT FOR A SMALL FILE, PARTS FOR A LARGE ONE. The threshold is about
  // resumability rather than about the 5 GiB cap — see upload.js.
  const kind = isVideo ? 'video' : 'photo';
  let sig;
  if (body.size > MULTIPART_THRESHOLD) {
    // THE SAME BYTES OR NOTHING. A resume sends only the missing parts, so
    // the file picked again must be byte for byte the one that was started —
    // checked by size and by a fingerprint of the bytes after the faststart
    // rewrite (which is deterministic: the same input gives the same output).
    const fp = await fingerprint(body);
    let resume = ctx.resume || null;
    if (resume && (resume.bodySize !== body.size || (resume.fp && resume.fp !== fp))) {
      resume = null;
      if (ctx.status) ctx.status('This is not the same file as before — sending it from the start', 'warn');
    }
    sig = await putInParts(body, onProgress, { kind, filename: file.name, folder }, {
      status: ctx.status, resume,
      record: (mp) => ctx.record && ctx.record({ ...mp, fp }),
    });
  } else {
    sig = await putSmall(body, onProgress, { kind, filename: file.name, folder }, ctx.status);
  }

  const out = {
    kind: isVideo ? 'video' : 'photo',
    objectKey: sig.objectKey,
    bytes: body.size,
    mime: file.type || null,
    durationS: meta.durationS ?? null,
    width: meta.width ?? null,
    height: meta.height ?? null,
  };

  // The poster frame, as a second object. Failing here loses a thumbnail, not
  // the video, so it is caught and dropped rather than failing a file that
  // already uploaded successfully.
  if (isVideo && meta.thumb) {
    try {
      const t = await api({
        op: 'sign', kind: 'thumb',
        filename: file.name.replace(/\.[^.]+$/, '') + '.jpg',
        size: meta.thumb.size, folder,
      });
      await put(t.uploadUrl, meta.thumb);
      out.thumbKey = t.objectKey;
    } catch (_) { /* a missing thumbnail falls back to the title poster */ }
  }
  return out;
}

/// Uploads a list of files with a progress row each, three at a time.
///
/// BOUNDED CONCURRENCY, not Promise.all. A phone asked to upload twelve files
/// at once divides one slow pipe twelve ways and finishes none of them inside
/// the presigned URL's one-hour life.
/// How many kilobits per second a file may demand before this refuses to
/// upload it without being told twice.
///
/// TWELVE MEGABITS, AND THE NUMBER IS ARGUED RATHER THAN PICKED. A viewer on
/// 6 MB/s has 48 Mbps in perfect conditions, and a stream needs its bitrate
/// delivered CONTINUOUSLY with headroom for a tunnel, a lift, a crowded
/// tower and whatever else the phone is doing. A quarter of the best case is
/// the point where playback stops being reliable and starts being lucky.
///
/// This is not theoretical. Two camera clips uploaded here needed 61 Mbps —
/// 121 MB for sixteen seconds, 139 MB for eighteen — while a ten-minute film
/// in the same bucket needed 1.3 and played perfectly. The operator's report
/// was "small files are fine, camera clips stutter", and it was exactly
/// right: file size was never the variable, bits per second was.
const UPLOAD_CEILING_KBPS = 12000;

/// Duration only, with no frame extraction. `measure()` also decodes a
/// poster frame, which is expensive and pointless for a file that is about
/// to be rejected.
function videoSeconds(file) {
  return new Promise((resolve) => {
    const v = document.createElement('video');
    v.preload = 'metadata';
    v.muted = true;
    const url = URL.createObjectURL(file);
    const done = (s) => { URL.revokeObjectURL(url); resolve(s); };
    v.onloadedmetadata = () => done(Number.isFinite(v.duration) ? v.duration : null);
    // A container this browser cannot read is not a reason to block an
    // upload — it is a reason to stay quiet and let it through.
    v.onerror = () => done(null);
    setTimeout(() => done(null), 8000);
    v.src = url;
  });
}

/// How many uploads are running. The idle sign-out reads it: signing out in
/// the middle of a two-gigabyte upload over a Myanmar connection would cost
/// the operator the upload, and an upload is not "idle" however long it
/// takes without a tap.
let uploadsInFlight = 0;
async function uploadAll(files, container, folder, job) {
  uploadsInFlight += 1;
  holdScreenOn();
  try {
    return await uploadAllNow(files, container, folder, job);
  } finally {
    uploadsInFlight -= 1;
    if (!uploadsInFlight) letScreenSleep();
  }
}
// The browser drops a screen wake lock whenever the tab is hidden; take it
// again when the tab comes back with an upload still going.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && uploadsInFlight > 0) holdScreenOn();
});

/// `job` (from upload.js's `newUploadJob`) is the record that lets this be
/// resumed after the tab dies: each file's progress is written into it as it
/// goes, and a file it already has as done is not uploaded again. A file
/// that is done is passed in as a stand-in `{ name, size, done: true }`.
async function uploadAllNow(files, container, folder, job) {
  // ── ANYTHING CAN BE UPLOADED, AND THAT IS THE REQUIREMENT ─────────────
  //
  // The operator's own words: whatever the size, however it was shot, 4K or
  // high frame rate, it must not stutter — because the person uploading will
  // not be thinking about bitrates and should not have to.
  //
  // So this no longer stands in the way. It measures each video before the
  // upload starts, and anything that a phone connection cannot carry is
  // QUEUED FOR A SMALLER COPY as soon as it lands. The operator uploads the
  // file they have; the ladder appears behind them.
  //
  // THE MEASUREMENT IS STILL DONE HERE, BEFORE THE UPLOAD, for one reason:
  // it is the only place the duration and the size are both known without
  // reading the object back out of the bucket. It costs a metadata load of a
  // local file, which is milliseconds.
  const needsLadder = [];
  for (const f of files) {
    if (!(f instanceof Blob) || !f.type.startsWith('video')) continue;
    const secs = await videoSeconds(f);
    if (!secs || secs <= 0) continue;
    const kbps = Math.round((f.size * 8) / secs / 1000);
    // Every video above the comfortable line gets a ladder, not only the
    // impossible ones. A 3 Mbps film is fine on wifi and miserable on a bus,
    // and the rung that fixes the bus costs nothing to anyone else.
    if (kbps >= COMFORTABLE_KBPS) needsLadder.push({ name: f.name, kbps });
  }

  const notes = [];
  const lines = [];
  const bars = files.map((f) => {
    const bar = el('i');
    // One line per file for what the rewrite did to it. An operator who can
    // see "moov moved to the front" on nine files and "unrecognised box
    // layout" on the tenth knows exactly which upload will make viewers wait
    // — and can re-encode that one instead of wondering why the app feels
    // slow on some titles and not others.
    const nt = el('span', { className: 'note' });
    notes.push(nt);
    // THE LIVE LINE: speed and time left while it runs, "waiting for the
    // connection" while it cannot. A bar that stops moving with nothing
    // beside it reads as a page that has hung, and gets reloaded.
    const st = el('span', { className: 'note up-st' });
    lines.push(st);
    container.append(el('div', { className: 'prog' }, [
      el('span', { className: 'n' }, text(f.name)),
      el('span', { className: 'ptrack' }, [bar]),
      nt, st,
    ]));
    return bar;
  });

  const out = new Array(files.length);
  let next = 0;
  const worker = async () => {
    while (next < files.length) {
      const i = next++;
      const jf = job ? job.files[i] : null;
      if (files[i] && files[i].done && jf && jf.state === 'done') {
        out[i] = jf.asset;
        bars[i].style.width = '100%';
        lines[i].textContent = 'already uploaded';
        continue;
      }
      // Speed over the last ten seconds, not since the start: a connection
      // that has just come back should not be averaged with the minutes it
      // was gone.
      const samples = [];
      let waiting = false;
      const size = files[i].size || 0;
      const status = (t, tone) => {
        waiting = tone === 'wait';
        lines[i].className = 'note up-st ' + (tone || '');
        lines[i].textContent = t;
      };
      out[i] = await uploadOne(files[i], (p) => {
        bars[i].style.width = Math.round(p * 100) + '%';
        const now = Date.now();
        samples.push([now, p * size]);
        while (samples.length > 2 && now - samples[0][0] > 10000) samples.shift();
        if (waiting || samples.length < 2) return;
        const [t0, b0] = samples[0];
        const rate = (p * size - b0) / Math.max(1, (now - t0) / 1000);
        if (rate > 0) {
          const left = ((1 - p) * size) / rate;
          lines[i].className = 'note up-st';
          lines[i].textContent = (rate / 1048576).toFixed(1) + ' MB/s · ' +
            (left > 90 ? Math.round(left / 60) + ' min left' : Math.round(left) + ' s left');
        }
      }, folder, (state, detail) => {
        notes[i].className = 'note ' + state;
        notes[i].textContent = detail;
      }, {
        status,
        resume: jf && jf.mp ? jf.mp : null,
        record: (mp) => {
          if (!jf) return;
          jf.state = 'partial';
          jf.mp = mp;
          upSave(job);
        },
      });
      bars[i].style.width = '100%';
      lines[i].className = 'note up-st ok';
      lines[i].textContent = 'uploaded';
      if (jf) {
        jf.state = 'done';
        jf.asset = out[i];
        delete jf.mp;
        upSave(job);
      }
    }
  };
  const workers = [];
  for (let i = 0; i < Math.min(3, files.length); i++) workers.push(worker());
  await Promise.all(workers);

  // ── HAND THE HEAVY ONES TO THE ENCODER ────────────────────────────────
  //
  // After the upload rather than before it, because the object has to exist
  // for a runner to fetch it. Queued by KEY, which is the one identifier the
  // console has at this point.
  //
  // A FAILURE HERE IS NOT AN UPLOAD FAILURE. The file is in the bucket and
  // plays; it just plays at whatever bitrate it was shot at until somebody
  // queues it from the Health panel. Throwing here would make a successful
  // upload look like a failed one.
  //
  // AFTER THE ROW, NOT HERE. This used to queue them right here — before the
  // title (and so the asset rows) existed — and `queue` finds an asset by its
  // key in title_assets, so it could never find one; every heavy upload
  // ended with "could not be queued" and was queued by hand from Health.
  // The keys are handed to the job, and `queueLadders` runs once the row is
  // written (finishUploadJob in upload.js).
  if (needsLadder.length && job) {
    const wanted = new Set(needsLadder.map((h) => h.name));
    job.ladder = [];
    files.forEach((f, i) => {
      if (wanted.has(f.name) && out[i] && out[i].objectKey) job.ladder.push(out[i].objectKey);
    });
    upSave(job);
  }
  return out;
}

/// Queues smaller streaming copies for the heavy videos of a job whose title
/// row now exists. A failure here is not an upload failure — the file plays;
/// it plays at the bitrate it was shot at until somebody queues it.
/// Answers a sentence for the caller's message ('' when there was nothing to
/// queue) rather than saying it, so it is not overwritten a moment later.
async function queueLadders(keys) {
  if (!keys || !keys.length) return '';
  let queued = 0;
  for (const key of keys) {
    try {
      await api({ op: 'queue', object_key: key }, TRANSCODE_API);
      queued++;
    } catch (e) { /* reported below, never fatal */ }
  }
  return queued
    ? queued + ' video(s) queued for smaller streaming copies; they play as ' +
      'uploaded until those are ready (see Health).'
    : 'These videos are heavier than a phone connection can carry and could ' +
      'not be queued for smaller copies — queue them from Health.';
}

/// Makes a dashed box accept a drop and feed it into the file input.
function wireDrop(box, input, after) {
  const stop = (e) => { e.preventDefault(); e.stopPropagation(); };
  box.addEventListener('dragover', (e) => { stop(e); box.classList.add('hot'); });
  box.addEventListener('dragleave', (e) => { stop(e); box.classList.remove('hot'); });
  box.addEventListener('drop', (e) => {
    stop(e);
    box.classList.remove('hot');
    if (!e.dataTransfer?.files?.length) return;
    input.files = e.dataTransfer.files;
    after();
  });
}

// WHAT THE GENRE CHOOSER OFFERS (migration 058): every genre by its code,
// with its words. Null until the table has answered — the form then shows the
// old comma-separated words, which the database maps to codes itself, so a
// console that cannot reach the list can still save a title.
let GENRES = null;

async function refreshGenreOptions() {
  try {
    const { genres } = await api({ op: 'genres' });
    GENRES = (genres ?? []).slice().sort((a, b) =>
      (a.sort_order ?? 0) - (b.sort_order ?? 0) || String(a.code).localeCompare(String(b.code)));
  } catch (e) {
    console.warn('genre options: ' + (e && e.message ? e.message : e));
  }
  return GENRES;
}

/// The words for a genre in the chooser: English, then Burmese when there is.
function genreWords(g) {
  return g.label + (g.label_mm ? ' · ' + g.label_mm : '');
}

// ── the detail form, shared by New and the editor ────────────────────────
//
// One description, two consumers. Two hand-written copies of a twelve-field
// form drift the first time a field is added to one of them.
const FIELDS = [
  { k: 'title', label: 'Title', ph: 'Name shown in the app', w: 2 },
  { k: 'title_mm', label: 'Title (Burmese)', w: 2 },
  { k: 'synopsis', label: 'Description', type: 'textarea', w: 4 },
  // BY CODE (migration 058): a tap on a genre, not words typed — so a genre
  // is never spelled two ways. New genres, and their words in each language,
  // are made on the Categories page.
  { k: 'genre_codes', label: 'Genres', type: 'genres', w: 2,
    hint: 'Chips on the card, and what the filter bar offers. Add or rename genres on the Categories page.' },
  { k: 'keywords', label: 'Search keywords (hidden)', w: 2,
    ph: 'alternate spelling, actor, မြန်မာလို အမည်',
    hint: 'Searchable, never shown. The words people actually type.' },
  // A FUNCTION, NOT AN ARRAY. `options: CATEGORIES` captured the array that
  // existed when this file was parsed, so a category added while the console was
  // open — or fetched a moment after it loaded — never appeared in the picker.
  { k: 'category', label: 'Category', type: 'select',
    options: () => CATEGORIES },
  { k: 'access_tier', label: 'Access', type: 'select',
    options: ['premium', 'free'] },
  { k: 'year', label: 'Year', type: 'number' },
  { k: 'quality_label', label: 'Quality', ph: 'HD, 4K, CAM' },
  { k: 'rating', label: 'Rating 0-10', type: 'number', step: '0.1' },
  { k: 'episode_count', label: 'Episodes', type: 'number' },
  { k: 'is_featured', label: 'Featured on the home hero', type: 'checkbox', w: 2 },
  // NO "Published" CHECKBOX. Going live is the review's Approve now — the
  // checkbox was a way into the app that skipped every rule the review has,
  // and on the Upload page it started ticked.
];
const ARRAY_FIELDS = new Set(['genres', 'keywords']);

function buildForm(host, prefix, values, onChange) {
  host.textContent = '';
  const wide = el('div', { className: 'grid wide' });
  host.append(wide);

  for (const f of FIELDS) {
    const id = prefix + f.k;
    let input;
    if (f.type === 'genres') {
      input = genreChooser(id, values, onChange);
    } else if (f.type === 'textarea') input = el('textarea', { id });
    else if (f.type === 'select') {
      input = el('select', { id });
      const opts = typeof f.options === 'function' ? f.options() : f.options;
      for (const o of opts) {
        const value = typeof o === 'object' ? o.value : o;
        input.append(el('option', { value }, text(typeof o === 'object' ? o.label : o)));
      }
    } else if (f.type === 'checkbox') input = el('input', { id, type: 'checkbox' });
    else {
      input = el('input', { id, type: f.type || 'text', placeholder: f.ph || '' });
      if (f.step) input.step = f.step;
    }

    const v = values ? values[f.k] : undefined;
    if (f.type === 'genres') { /* drawn with its values */ }
    else if (f.type === 'checkbox') input.checked = v === true;
    else if (ARRAY_FIELDS.has(f.k)) {
      input.value = Array.isArray(v) ? v.join(', ') : (v || '');
    } else input.value = v == null ? '' : v;

    if (onChange && f.type !== 'genres') {
      input.addEventListener('input', onChange);
      input.addEventListener('change', onChange);
    }

    const cell = f.type === 'checkbox'
      ? el('div', { style: 'display:flex;align-items:center;gap:7px;height:var(--ctl);align-self:end' },
          [input, el('label', { htmlFor: id, style: 'margin:0' }, text(f.label))])
      : el('div', {}, [
          el('label', { htmlFor: id }, text(f.label)),
          input,
          f.hint ? el('div', { className: 'hint', style: 'margin-top:3px' },
            text(f.hint)) : null,
        ]);
    // A class, so the stylesheet decides where the span applies. See the
    // note on `.grid.wide` — setting `grid-column: span 4` directly does NOT
    // get clamped by a narrower grid, it grows the grid.
    if (f.w) cell.className = 'w' + Math.min(Math.max(f.w, 2), 4);
    wide.append(cell);
  }
}

/// The genres of a title as chips to tap, every genre the table offers plus
/// any the title already has that it no longer offers (retired, hidden), so
/// those can be seen and taken off.
function genreChooser(id, values, onChange) {
  const have = Array.isArray(values?.genre_codes) ? values.genre_codes.map(String) : [];
  if (!GENRES) {
    const words = el('input', { id, type: 'text', placeholder: 'action, drama' });
    words.dataset.words = '1';
    words.value = Array.isArray(values?.genres) ? values.genres.join(', ') : '';
    if (onChange) {
      words.addEventListener('input', onChange);
      words.addEventListener('change', onChange);
    }
    return words;
  }
  const box = el('div', { id, className: 'genre-pick', role: 'group',
    style: 'display:flex;flex-wrap:wrap;gap:6px;min-height:var(--ctl);align-items:center' });
  const shown = GENRES.filter((g) =>
    have.includes(String(g.code)) || (g.is_visible !== false && !g.retired_at));
  if (!shown.length) {
    box.append(el('span', { className: 'hint' },
      text('No genres yet — add them on the Categories page.')));
  }
  for (const g of shown) {
    const on = have.includes(String(g.code));
    const chip = el('button', { type: 'button', className: 'chip' + (on ? ' on' : ''),
      title: g.code + (g.retired_at ? ' — retired: take it off, it is not given to new titles' : ''),
      style: 'cursor:pointer' + (g.retired_at ? ';opacity:.6;text-decoration:line-through' : '') },
      text(genreWords(g)));
    chip.dataset.code = String(g.code);
    chip.setAttribute('aria-pressed', on ? 'true' : 'false');
    chip.onclick = () => {
      const now = chip.getAttribute('aria-pressed') !== 'true';
      // A retired genre can be taken off, not put back.
      if (now && g.retired_at) return;
      chip.setAttribute('aria-pressed', now ? 'true' : 'false');
      chip.classList.toggle('on', now);
      if (onChange) onChange();
    };
    box.append(chip);
  }
  return box;
}

function readForm(prefix) {
  const out = {};
  for (const f of FIELDS) {
    const n = $(prefix + f.k);
    if (!n) continue;
    if (f.type === 'genres') {
      if (n.dataset.words === '1') {
        // The table did not answer: the old words, mapped to codes by the
        // database.
        out.genres = n.value.split(',').map((s) => s.trim()).filter(Boolean);
      } else {
        out[f.k] = [...n.querySelectorAll('button[aria-pressed=true]')]
          .map((b) => b.dataset.code);
      }
      continue;
    }
    if (f.type === 'checkbox') out[f.k] = n.checked;
    else if (ARRAY_FIELDS.has(f.k)) {
      out[f.k] = n.value.split(',').map((s) => s.trim()).filter(Boolean);
    } else if (f.type === 'number') {
      out[f.k] = n.value === '' ? null : Number(n.value);
    } else out[f.k] = n.value.trim();
  }
  return out;
}

// ── tabs ─────────────────────────────────────────────────────────────────
const TABS = ['dashboard', 'review', 'catalogue', 'new', 'telegram', 'requests',
  'cats', 'stats', 'health', 'files', 'storage', 'status', 'activity', 'admins', 'security', 'editor'];
function show(tab) {
  // LEAVING THE EDITOR WITH UNSAVED DETAILS. `beforeunload` covers closing the
  // tab, but not switching to another tab inside this page — which is the
  // likelier way to lose typing, because it feels like navigation rather than
  // leaving. Media changes save themselves on the spot, so this only ever
  // fires for the form.
  if (dirty && tab !== 'editor' &&
      !$('tab-editor').hidden &&
      !confirm('Discard unsaved changes to this title?')) {
    return;
  }
  if (tab !== 'editor') markClean();
  for (const t of TABS) $('tab-' + t).hidden = (t !== tab);
  markMenu(tab);
  clear();
  if (tab === 'dashboard') loadDashboard();
  if (tab === 'review') loadReview();
  if (tab === 'new') drawInterrupted();
  if (tab === 'activity') loadActivity(true);
  if (tab === 'admins') loadAdmins();
  if (tab === 'security') loadSecurity();
  if (tab === 'catalogue') loadList();
  if (tab === 'requests') loadRequests();
  if (tab === 'cats') { loadCategories(); loadGenres(); }
  if (tab === 'stats') loadStats();
  if (tab === 'health') loadHealth();
  // The From Telegram panel FILLS ITSELF when its page opens. It was wired to
  // its own Refresh button and nothing else, so it drew a heading and then
  // nothing — which reads exactly like a panel that is not there.
  if (tab === 'telegram') loadIngest();
  if (tab === 'files') loadFiles();
  if (tab === 'storage') loadStorage();
  if (tab === 'status') loadStatus();
}

// ── catalogue ────────────────────────────────────────────────────────────
let listTimer = null;
$('q').oninput = () => { clearTimeout(listTimer); listTimer = setTimeout(loadList, 300); };
$('fStatus').onchange = loadList;

async function loadList() {
  const body = $('rows');
  const empty = $('listEmpty');
  empty.textContent = '';
  try {
    const { titles } = await api({
      op: 'list', q: $('q').value, status: $('fStatus').value,
    });
    body.textContent = '';
    $('count').textContent = titles.length + (titles.length === 1 ? ' title' : ' titles');
    if (!titles.length) {
      empty.append(el('div', { className: 'empty' }, text('Nothing here.')));
      return;
    }
    for (const t of titles) {
      const img = el('img', { className: 'cv', alt: '', loading: 'lazy' });
      if (t.poster_url) img.src = t.poster_url;

      // SEVEN CELLS, ONE MARKUP, TWO LAYOUTS. The four facts are wrapped in
      // `.lmeta` so a phone can flex them onto a second line; a wide screen
      // dissolves that wrapper with `display:contents` and they sit in the
      // row's own grid, aligned under the header. See the CSS note.
      //
      // The counts carry their own label on a phone and not on the desk.
      // Both forms are in the DOM and CSS picks one, because the column
      // heading that explains "20 / 0" is only there on the wide layout —
      // on a card, a bare pair of numbers next to a bare "3" is a puzzle
      // rather than a fact. Writing it twice costs two spans; deciding it
      // in JavaScript would mean re-rendering the list on a resize.
      const pair = (wide, narrow, cls) => el('span', { className: cls }, [
        el('span', { className: 'w' }, text(wide)),
        el('span', { className: 'n' }, text(narrow)),
      ]);
      const photos = t.photo_count ?? 0;
      const videos = t.video_count ?? 0;
      const views = t.view_count ?? 0;

      const meta = el('span', { className: 'lmeta' }, [
        el('span', { className: 'mono', style: 'color:var(--dim)' },
          text(t.category)),
        pair(photos + ' / ' + videos,
             photos + ' photo / ' + videos + ' video', 'num mono'),
        pair(String(views), views + (views === 1 ? ' view' : ' views'), 'num'),
        el('span', { className: 'mono', style: 'color:var(--dim2)' },
          text(t.slug || '—')),
      ]);

      const row = el('div', { className: 'lrow' }, [
        img,
        el('div', { className: 'tt' }, [
          text(t.title),
          t.title_mm ? el('small', {}, text(t.title_mm)) : null,
        ]),
        el('span', { className: reviewChip(t).cls }, text(reviewChip(t).label)),
        meta,
      ]);
      row.onclick = () => openEditor(t.id);
      body.append(row);
    }
  } catch (e) { say('bad', String(e.message || e)); }
}

// ── editor ───────────────────────────────────────────────────────────────
let cur = null;      // { title, assets, folder, publicBase }
let editingId = null; // for the address bar: #/title/<id>
let dirty = false;

$('back').onclick = () => show('catalogue');
// Was an onclick="" attribute; the page's policy runs no inline handlers.
$('ssRefresh').onclick = () => loadStatus();

function markDirty() {
  dirty = true;
  const chip = $('eDirty');
  chip.hidden = false;
  // Amber, the one colour this console uses for "needs attention". A grey
  // chip saying "unsaved" is a chip nobody reads.
  chip.className = 'chip draft';
  $('save').disabled = false;
}
function markClean() {
  dirty = false;
  $('eDirty').hidden = true;
  $('save').disabled = true;
}

async function openEditor(id) {
  editingId = id;
  show('editor');
  say('info', 'Loading…');
  try {
    cur = await api({ op: 'get', id });
    // The chooser needs the genre list; a console that has not got it yet
    // asks once more here rather than draw the old words box.
    if (!GENRES) await refreshGenreOptions();
    clear();
    $('eTitle').textContent = cur.title.title || '(untitled)';
    $('eFolder').textContent = cur.folder + '/';
    $('dFolder').textContent = cur.folder + '/';
    $('delConfirm').value = '';
    buildForm($('eFields'), 'e_', cur.title, markDirty);
    markClean();
    drawMedia();
    drawReviewBar();
  } catch (e) { say('bad', String(e.message || e)); }
}

function assetThumb(a) {
  const base = cur.publicBase;
  if (a.thumb_key) return base + '/' + a.thumb_key;
  if (a.kind === 'photo') return base + '/' + a.object_key;
  return cur.title.poster_url || '';
}

function drawMedia() {
  const host = $('mGrid');
  host.textContent = '';
  const assets = cur.assets;
  const photos = assets.filter((a) => a.kind === 'photo').length;
  $('mCount').textContent =
    assets.length + ' items · ' + photos + ' photo, ' + (assets.length - photos) + ' video';

  if (!assets.length) {
    host.append(el('div', { className: 'empty' }, text('No media yet.')));
    return;
  }

  assets.forEach((a, i) => {
    const img = el('img', { alt: '', loading: 'lazy' });
    const src = assetThumb(a);
    if (src) img.src = src;

    // POSITION AS A TYPED NUMBER, not only as a drag. Dragging a tile from
    // twenty to one on a phone means dragging past nineteen tiles while the
    // list scrolls under the finger; typing "1" does it in one tap. The drag
    // is for small moves, this is for large ones, and both write the same
    // sequence.
    const ord = el('input', {
      className: 'ord', type: 'text', inputMode: 'numeric',
      value: String(i + 1), title: 'Position',
    });
    ord.onclick = (e) => e.stopPropagation();
    ord.onchange = () => {
      const to = Math.max(1, Math.min(assets.length, Number(ord.value) || i + 1)) - 1;
      if (to === i) { ord.value = String(i + 1); return; }
      assets.splice(to, 0, assets.splice(i, 1)[0]);
      drawMedia();
      commitOrder();
    };

    // WATCH IT HERE, before anyone approves it — a play button over the
    // frame, the way Telegram draws a video in an album. On the thumbnail
    // rather than in the button row: the row is already full on a 96px
    // phone tile, and the picture is where a thumb goes to play something.
    // Videos only: a photo tile already is the photo.
    const play = a.kind === 'photo' ? null : el('button', {
      className: 'play', title: 'Watch it', type: 'button',
    }, text('▶'));
    if (play) play.onclick = (e) => { e.stopPropagation(); previewAsset(a); };

    const ph = el('div', { className: 'ph' }, [
      img, ord, play,
      a.is_primary && a.kind === 'photo'
        ? el('span', { className: 'cover' }, text('COVER')) : null,
      el('span', { className: 'kind' },
        text(a.kind === 'photo' ? 'photo' : a.kind)),
      a.duration_s ? el('span', { className: 'dur' }, text(fmtDur(a.duration_s))) : null,
      // The state that silently degrades the app's layout: with no width the
      // mosaic cannot size the row and gives a portrait clip a landscape hole.
      !a.width ? el('div', { className: 'nosize' }, text('no size')) : null,
      // The state the app has been in since the first upload: the tile is
      // showing the TITLE POSTER, not this video. It looks fine in the
      // console, which is why nobody caught it — the picture is real, it is
      // just a picture of something else.
      (a.kind !== 'photo' && !a.thumb_key)
        ? el('div', { className: 'borrowed' }, text('poster')) : null,
    ]);

    const handle = el('span', { className: 'hnd', title: 'Drag to reorder' },
      text('⠿'));

    const star = el('button', {
      className: 'i' + (a.is_primary && a.kind === 'photo' ? ' on' : ''),
      title: a.kind === 'photo' ? 'Use as card image' : 'Use as the main video',
    }, text(a.is_primary ? '★' : '☆'));
    star.onclick = (e) => { e.stopPropagation(); setPrimary(a); };

    const freeBtn = a.kind === 'photo' ? null : el('button', {
      className: 'i' + (a.is_free ? ' on' : ''),
      title: a.is_free ? 'Free preview — anyone can watch' : 'Mark as free preview',
    }, text(a.is_free ? '◉' : '○'));
    if (freeBtn) {
      freeBtn.onclick = (e) => {
        e.stopPropagation();
        patchAsset(a, { is_free: !a.is_free });
      };
    }

    // Only videos get one. A photo IS its own thumbnail, and offering to
    // give it a different one would be offering to make the grid lie.
    const thumbBtn = a.kind === 'photo' ? null : el('button', {
      className: 'i' + (a.thumb_key ? ' on' : ''),
      title: a.thumb_key
        ? 'Change the thumbnail'
        : 'No thumbnail — the card is borrowing the title poster',
    }, text('🖼'));
    if (thumbBtn) {
      thumbBtn.onclick = (e) => { e.stopPropagation(); thumbMenu(a); };
    }


    const del = el('button', { className: 'i', title: 'Remove' }, text('🗑'));
    del.onclick = (e) => { e.stopPropagation(); removeAsset(a); };

    const tile = el('div', { className: 'mt' }, [
      ph,
      el('div', { className: 'row' },
        [handle, star, freeBtn, thumbBtn,
          el('span', { className: 'spacer' }), del]),
    ]);
    tile.dataset.index = String(i);
    wireDrag(tile, handle, i);
    host.append(tile);
  });
}


// ── thumbnails for a video that already exists ───────────────────────────
//
// EVERY VIDEO IN THE DATABASE HAS `thumb_key` NULL, so `title_media` falls
// back to the title's poster and a title with four clips draws the same
// picture four times — which is exactly what the app showed.
//
// New uploads fix themselves: `measure()` grabs a frame before the file
// leaves the operator's device. The objects already in the bucket cannot be
// fixed that way, and the obvious approach — sign a GET, load the video off
// R2 into a <video>, draw it — needs the media bucket to answer a
// cross-origin GET with CORS headers, which it currently does not (the rule
// allows PUT only). A canvas that has drawn a frame from a cross-origin
// source without CORS is TAINTED: `toBlob` throws, and the failure looks
// exactly like a network error.
//
// So the path that always works comes first: the operator still has the
// video file, and a frame taken from the local copy is the same frame. It
// uploads a 30 KB JPEG instead of re-uploading two gigabytes. The two
// cheaper options — any image file, or a photo already in this title — are
// there because a hand-picked still is often a better advertisement for a
// clip than any frame in it.

/// A modal that plays a local file and hands back the frame the operator chose.
///
/// SCRUBBING, NOT "10% IN". The automatic rule is a guess that lands on a
/// fade, a title card or the back of someone's head often enough to matter,
/// and the thumbnail is the only thing deciding whether a card gets tapped.
function pickFrame(file) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const v = el('video', { muted: true, playsInline: true, preload: 'auto' });
    v.src = url;
    const scrub = el('input', { type: 'range', min: '0', max: '1000', value: '100',
      className: 'scrub' });
    const at = el('span', { className: 'at' }, text('—'));
    const use = el('button', { className: 'p' }, text('Use this frame'));
    const cancel = el('button', {}, text('Cancel'));

    const close = (out) => {
      URL.revokeObjectURL(url);
      back.remove();
      resolve(out);
    };

    v.onloadedmetadata = () => {
      // A quarter of the way in, which beats the first frame on almost
      // everything: past the fade, before the credits.
      v.currentTime = Math.min(v.duration * 0.25, 30);
    };
    v.ontimeupdate = v.onseeked = () => {
      at.textContent = fmtDur(Math.round(v.currentTime)) +
        ' / ' + fmtDur(Math.round(v.duration || 0));
      if (v.duration) scrub.value = String(Math.round(v.currentTime / v.duration * 1000));
    };
    scrub.oninput = () => {
      if (v.duration) v.currentTime = v.duration * (Number(scrub.value) / 1000);
    };
    use.onclick = () => {
      try {
        // 640 on the long edge. A grid tile is never shown larger, and a
        // full-resolution still would cost more to fetch than the card it
        // decorates.
        const scale = Math.min(1, 640 / Math.max(v.videoWidth || 640, 1));
        const c = el('canvas', {
          width: Math.max(1, Math.round((v.videoWidth || 640) * scale)),
          height: Math.max(1, Math.round((v.videoHeight || 360) * scale)),
        });
        c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
        c.toBlob((b) => close(b ? {
          blob: b,
          atS: Math.round(v.currentTime),
          width: v.videoWidth || null,
          height: v.videoHeight || null,
          durationS: Number.isFinite(v.duration) ? Math.round(v.duration) : null,
        } : null), 'image/jpeg', 0.85);
      } catch (e) {
        say('bad', 'The browser would not give up this frame: ' + (e.message || e));
        close(null);
      }
    };
    cancel.onclick = () => close(null);
    v.onerror = () => {
      say('bad', 'This browser cannot decode that video.');
      close(null);
    };

    const back = el('div', { className: 'modal' }, [
      el('div', { className: 'sheet' }, [
        el('div', { className: 'sh' }, text('Choose the frame')),
        v,
        el('div', { className: 'srow' }, [scrub, at]),
        el('div', { className: 'srow end' }, [cancel, use]),
      ]),
    ]);
    document.body.append(back);
  });
}

/// Uploads a still and points the asset at it.
async function setThumbBlob(a, blob, extra) {
  const t = await api({
    op: 'sign', kind: 'thumb',
    filename: (a.object_key.split('/').pop() || 'thumb')
      .replace(/\.[^.]+$/, '') + '.jpg',
    size: blob.size, folder: cur.folder,
  });
  await put(t.uploadUrl, blob);
  // The dimensions ride along, because a video row with a null width is what
  // makes the app's mosaic give a portrait clip a landscape hole — and the
  // operator has just had the real numbers on screen.
  const patch = Object.assign({ thumb_key: t.objectKey }, extra || {});
  await patchAsset(a, patch);
}

/// The cover picker (043): the ten stills the transcode runner took from the
/// video itself — frame 0 at one second, then every tenth of the running
/// time. One tap makes one the thumbnail. Nothing is uploaded; the still is
/// already in the public bucket, so this only points the video at it.
///
/// WHY THIS IS THE FIRST THING IN THE MENU. The old first option asked the
/// operator to find the original file on the phone again and scrub it, which
/// for a film forwarded from Telegram means finding it in Telegram, saving
/// it, and picking it here — for a 30 KB picture.
function drawFramePicker(a, close) {
  const box = el('div', {});
  const frames = Array.isArray(a.frames) ? a.frames : [];
  const tall = (a.height || 0) > (a.width || 0);
  if (frames.length) {
    const grid = el('div', { className: 'framegrid' });
    frames.forEach((f, i) => {
      const b = el('button', {
        className: 'fk' + (tall ? ' tall' : '') + (a.thumb_key === f.key ? ' on' : ''),
        title: i === 0 ? 'Default — one second in' : 'At ' + fmtDur(Math.round(f.at)),
        type: 'button',
      }, [
        el('img', { src: cur.publicBase + '/' + f.key, alt: '', loading: 'lazy' }),
        el('span', { className: 't' }, text(fmtDur(Math.round(f.at)) || '0:00')),
      ]);
      b.onclick = async () => {
        close();
        if (a.thumb_key === f.key) return;
        await patchAsset(a, { thumb_key: f.key });
        say('ok', 'Thumbnail set from the frame at ' + (fmtDur(Math.round(f.at)) || '0:00') + '.');
      };
      grid.append(b);
    });
    box.append(grid);
  } else {
    const st = a.frames_state;
    box.append(el('div', { className: 'hint' }, text(
      st === 'failed'
        ? 'The frames could not be made: ' + (a.frames_note || 'unknown reason') + '.'
        : 'The frames for this video are being made on the runner — usually a ' +
          'minute or two. Close this and open it again shortly.')));
  }
  // "Again": after replacing the file, or when the first try failed.
  const again = el('button', {}, text(frames.length ? 'Make the frames again' : 'Make the frames now'));
  again.onclick = async () => {
    again.disabled = true;
    try {
      const got = await api({ op: 'frames', asset_id: a.id }, TRANSCODE_API);
      a.frames_state = 'queued';
      say('ok', got.kick === 'started' || got.kick === 'waiting'
        ? 'Making the frames now — they appear here in a minute or two.'
        : 'Queued. The runner makes them on its next pass.');
      close();
    } catch (e) {
      say('bad', String(e.message || e));
      again.disabled = false;
    }
  };
  box.append(el('div', { className: 'srow end' }, [again]));
  return box;
}

/// The per-video thumbnail menu.
async function thumbMenu(a) {
  const photos = cur.assets.filter((o) => o.kind === 'photo');
  const fromVideo = el('button', {}, text('From the video file on this device…'));
  const fromImage = el('button', {}, text('From an image file…'));
  const fromPhoto = photos.length
    ? el('button', {}, text('From a photo in this title…')) : null;
  const cancel = el('button', {}, text('Cancel'));
  let back;
  const close = () => back.remove();

  fromVideo.onclick = () => {
    close();
    const inp = el('input', { type: 'file', accept: 'video/*' });
    inp.onchange = async () => {
      const f = inp.files && inp.files[0];
      if (!f) return;
      const picked = await pickFrame(f);
      if (!picked) return;
      try {
        await setThumbBlob(a, picked.blob, {
          width: picked.width, height: picked.height,
          duration_s: picked.durationS,
        });
        say('ok', 'Thumbnail set from the frame at ' + fmtDur(picked.atS) + '.');
      } catch (e) { say('bad', String(e.message || e)); }
    };
    inp.click();
  };

  fromImage.onclick = () => {
    close();
    const inp = el('input', { type: 'file', accept: 'image/*' });
    inp.onchange = async () => {
      const f = inp.files && inp.files[0];
      if (!f) return;
      try {
        await setThumbBlob(a, f);
        say('ok', 'Thumbnail set.');
      } catch (e) { say('bad', String(e.message || e)); }
    };
    inp.click();
  };

  if (fromPhoto) {
    fromPhoto.onclick = () => {
      close();
      // NOTHING IS UPLOADED. The photo is already an object in the public
      // bucket, so this only writes its key onto the video row — instant,
      // free, and undoable by choosing another.
      const grid = el('div', { className: 'pickgrid' });
      let pb;
      photos.forEach((p) => {
        const im = el('img', { src: cur.publicBase + '/' + p.object_key, alt: '' });
        const b = el('button', { className: 'pk' }, im);
        b.onclick = async () => {
          pb.remove();
          try {
            await patchAsset(a, { thumb_key: p.object_key });
            say('ok', 'Thumbnail set from a photo in this title.');
          } catch (e) { say('bad', String(e.message || e)); }
        };
        grid.append(b);
      });
      const no = el('button', {}, text('Cancel'));
      no.onclick = () => pb.remove();
      pb = el('div', { className: 'modal' }, [
        el('div', { className: 'sheet' }, [
          el('div', { className: 'sh' }, text('Pick a photo')),
          grid,
          el('div', { className: 'srow end' }, [no]),
        ]),
      ]);
      document.body.append(pb);
    };
  }

  cancel.onclick = close;
  back = el('div', { className: 'modal' }, [
    el('div', { className: 'sheet' }, [
      el('div', { className: 'sh' }, text('Choose the cover')),
      el('div', { className: 'hint' }, text(
        'Ten frames from across the video. Tap one to make it the thumbnail ' +
        'viewers see.')),
      drawFramePicker(a, close),
      el('div', { className: 'hint', style: 'margin-top:8px' }, text('Or use something else:')),
      el('div', { className: 'stack' },
        [fromImage, fromPhoto, fromVideo]),
      el('div', { className: 'srow end' }, [cancel]),
    ]),
  ]);
  document.body.append(back);
}

// ── drag to reorder ──────────────────────────────────────────────────────
//
// POINTER EVENTS, NOT HTML5 DRAG-AND-DROP. The HTML5 API does not fire on
// touch at all in any mobile browser, and this console is operated from a
// phone — so a drag built on it would work only on the machine nobody uses.
//
// The handle is the only element with `touch-action: none`. That is
// deliberate: making the whole tile undraggable-by-scroll would trap the page
// the moment a finger landed on the grid, and the grid is most of the screen.
let dragIdx = null;

function wireDrag(tile, handle, index) {
  handle.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    dragIdx = index;
    tile.classList.add('drag');
    handle.setPointerCapture(e.pointerId);
  });

  handle.addEventListener('pointermove', (e) => {
    if (dragIdx === null) return;
    const over = document.elementFromPoint(e.clientX, e.clientY)?.closest('.mt');
    for (const t of document.querySelectorAll('.mt')) t.classList.remove('drop');
    if (over && over !== tile) over.classList.add('drop');
  });

  const end = (e) => {
    if (dragIdx === null) return;
    const over = document.elementFromPoint(e.clientX, e.clientY)?.closest('.mt');
    const from = dragIdx;
    dragIdx = null;
    tile.classList.remove('drag');
    for (const t of document.querySelectorAll('.mt')) t.classList.remove('drop');
    if (!over || over === tile) return;
    const to = Number(over.dataset.index);
    if (Number.isNaN(to) || to === from) return;
    cur.assets.splice(to, 0, cur.assets.splice(from, 1)[0]);
    drawMedia();
    commitOrder();
  };
  handle.addEventListener('pointerup', end);
  handle.addEventListener('pointercancel', () => {
    dragIdx = null;
    tile.classList.remove('drag');
    for (const t of document.querySelectorAll('.mt')) t.classList.remove('drop');
  });
}

/// Writes the WHOLE sequence in one request.
///
/// Not one call per moved tile: dragging from ten to one changes every row
/// between, and ten requests over a mobile connection is ten chances to
/// half-apply an order that neither the operator nor the app expects.
async function commitOrder() {
  try {
    await api({
      op: 'reorder',
      order: cur.assets.map((a, i) => ({ id: a.id, sort_order: i })),
    });
    cur.assets.forEach((a, i) => { a.sort_order = i; });
    say('ok', 'Order saved.');
  } catch (e) { say('bad', String(e.message || e)); }
}

async function setPrimary(a) {
  try {
    await api({ op: 'setPrimary', id: a.id });
    // Only within the same kind: the cover photo and the main video are two
    // independent slots, and clearing both would show the wrong state until
    // the next reload.
    for (const o of cur.assets) if (o.kind === a.kind) o.is_primary = false;
    a.is_primary = true;
    drawMedia();
    say('ok', a.kind === 'photo'
      ? 'Card image updated. The app picks it up on its next fetch.'
      : 'Main video updated.');
  } catch (e) { say('bad', String(e.message || e)); }
}

async function patchAsset(a, patch) {
  try {
    await api({ op: 'updateAsset', id: a.id, patch });
    Object.assign(a, patch);
    drawMedia();
  } catch (e) { say('bad', String(e.message || e)); }
}

async function removeAsset(a) {
  if (!confirm('Remove this file from the title? The object stays in R2.')) return;
  try {
    await api({ op: 'deleteAsset', id: a.id });
    cur.assets = cur.assets.filter((o) => o.id !== a.id);
    drawMedia();
  } catch (e) { say('bad', String(e.message || e)); }
}

$('save').onclick = async () => {
  $('save').disabled = true;
  try {
    const f = readForm('e_');
    await api({
      op: 'save', id: cur.title.id,
      patch: {
        title: f.title, title_mm: f.title_mm, synopsis: f.synopsis,
        category: f.category, year: f.year, rating: f.rating,
        quality_label: f.quality_label, keywords: f.keywords,
        ...(f.genre_codes ? { genre_codes: f.genre_codes } : { genres: f.genres }),
        episode_count: f.episode_count, access_tier: f.access_tier,
        is_featured: f.is_featured,
      },
    });
    Object.assign(cur.title, f);
    $('eTitle').textContent = f.title || '(untitled)';
    markClean();
    say('ok', 'Saved.');
  } catch (e) { say('bad', String(e.message || e)); $('save').disabled = false; }
};

$('addBtn').onclick = () => {
  $('addWrap').hidden = !$('addWrap').hidden;
  if (!$('addWrap').hidden) $('addFiles').click();
};

$('addFiles').onchange = async () => {
  const files = [...$('addFiles').files];
  if (!files.length) return;
  const host = $('addProg');
  host.textContent = '';
  try {
    say('info', 'Uploading ' + files.length + ' file(s) into ' + cur.folder + '/…');
    const job = newUploadJob(files, cur.folder,
      { op: 'addAssets', titleId: cur.title.id }, cur.title.title);
    await upSave(job);
    const assets = await uploadAll(files, host, cur.folder, job);
    const res = await finishUploadJob(job, assets);
    $('addFiles').value = '';
    host.textContent = '';
    $('addWrap').hidden = true;
    await openEditor(cur.title.id);
    say('ok', 'Added ' + assets.length + ' file(s). Drag to place them.' +
      (res.ladderNote ? ' ' + res.ladderNote : ''));
  } catch (e) {
    // Not lost: the parts already sent are recorded, and Upload → Interrupted
    // uploads carries on from them.
    say('bad', String(e.message || e) + ' — what was sent is kept; resume it from Upload.');
  }
};

$('delTitle').onclick = async () => {
  try {
    await api({
      op: 'deleteTitle', id: cur.title.id, confirm: $('delConfirm').value.trim(),
    });
    say('ok', 'Deleted.');
    show('catalogue');
  } catch (e) { say('bad', String(e.message || e)); }
};

// ── new title ────────────────────────────────────────────────────────────
buildForm($('nFields'), 'n_',
  { category: 'movies', access_tier: 'premium' });

/// The New form is drawn before the genre list has answered, with the old
/// words box; once the list is here, an untouched box becomes the chooser
/// (one with words typed in is left as it is — those words still save).
function upgradeNewGenres() {
  const box = $('n_genre_codes');
  if (!GENRES || !box || box.dataset.words !== '1' || box.value.trim()) return;
  box.replaceWith(genreChooser('n_genre_codes', {}, null));
}

let folderTimer = null;
let folderOk = false;
// What the server made of the name typed: the folder the keys will really
// use — `f/<hash>` once R2_NAMING_KEY is set (docs/edge/naming.ts), the name
// itself before — for that exact text. Null until checked.
let folderChecked = null;

$('nFolder').oninput = () => {
  folderOk = false;
  folderChecked = null;
  clearTimeout(folderTimer);
  folderTimer = setTimeout(checkFolder, 350);
  $('nPaths').textContent = 'checking…';
};

/// Shows what the object keys will ACTUALLY be, before a byte is uploaded.
///
/// The operator types `Spider Man /Movies`; the keys will say
/// `spider-man/movies`. Seeing that beforehand is the whole point of letting
/// them choose — a folder silently rewritten is a folder they will not think
/// to look in.
async function checkFolder() {
  const raw = $('nFolder').value.trim();
  const out = $('nPaths');
  out.textContent = '';
  if (!raw) { out.textContent = 'Required — pick a folder first.'; return; }
  try {
    const r = await api({ op: 'checkFolder', folder: raw });
    folderOk = r.ok;
    if (!r.folder) { out.textContent = 'That reduces to nothing usable.'; return; }
    folderChecked = { raw, folder: r.folder, label: raw };
    out.append(
      el('div', {}, [text('innocent-media/'), el('b', {}, text(r.folder)),
        text('/video/…')]),
      el('div', {}, [text('innocent-public/'), el('b', {}, text(r.folder)),
        text('/photo/…')]),
      el('div', {}, [text('innocent-public/'), el('b', {}, text(r.folder)),
        text('/thumb/…')]),
    );
    if (r.label && r.label !== r.folder) {
      // The keys say nothing about the title; this page still calls the
      // folder by its name.
      out.append(el('div', { className: 'hint', style: 'margin-top:4px' },
        text('Hidden in the bucket; shown here as "' + raw + '". File names are random.')));
    }
    if (!r.ok) {
      out.append(el('div', { style: 'color:var(--bad);margin-top:4px' },
        text('Already used' + (r.takenBy ? ' by "' + r.takenBy + '"' : '') +
          '. Pick another.')));
    }
  } catch (e) { out.textContent = String(e.message || e); }
}

$('nFiles').onchange = () => {
  const host = $('nPicked');
  host.textContent = '';
  const files = [...$('nFiles').files];
  if (!files.length) return;
  for (const f of files) {
    host.append(el('div', { className: 'prog' }, [
      el('span', { className: 'n' }, text(f.name)),
      el('span', { className: 'hint' }, text(fmtSize(f.size))),
    ]));
  }
  // The refusal the server would give anyway, said before an hour is spent
  // uploading toward it. 5 GiB is R2's single-PUT limit; multipart is not
  // built, and an hour ending in an unreadable CORS error is the worst
  // failure available here.
  const big = files.filter((f) => f.size > 5 * 1024 * 1024 * 1024);
  if (big.length) {
    say('bad', 'Too large for a single upload (5 GiB limit): ' +
      big.map((f) => f.name).join(', '));
  } else clear();
};

$('create').onclick = async () => {
  const b = $('create');
  const files = [...$('nFiles').files];
  const f = readForm('n_');
  const raw = $('nFolder').value.trim();

  if (!raw) return say('bad', 'Pick a folder first — it cannot be changed later.');
  if (!folderOk || !folderChecked || folderChecked.raw !== raw) {
    await checkFolder();
    if (!folderOk || !folderChecked) return say('bad', 'That folder is not available.');
  }
  const folder = folderChecked.folder;
  if (!f.title) return say('bad', 'A title needs a name.');
  // STILL REQUIRED HERE, and that is not an oversight. This tab is the
  // uploader: it takes files off the phone and builds a title around them. A
  // title whose files are ALREADY in the bucket — forwarded to the bot — is
  // not made here at all; it is made by "New title from this" on the Telegram page →
  // From Telegram, in one statement, with its files already attached.
  if (!files.length) {
    return say('bad', 'Pick at least one file. If the files were forwarded to '
      + 'the bot, make the title from the Telegram page instead.');
  }

  b.disabled = true;
  const host = $('nPicked');
  host.textContent = '';
  try {
    say('info', 'Uploading ' + files.length + ' file(s) into ' + raw + '/…');
    // THE FORM IS KEPT WITH THE FILES, so a resume after the tab died makes
    // the same title — the details typed before the upload started are not
    // something the operator should have to type twice.
    const job = newUploadJob(files, folder, { op: 'create', payload: {
      op: 'create', folder, folderLabel: folderChecked.label,
      title: f.title, titleMm: f.title_mm, synopsis: f.synopsis,
      category: f.category, year: f.year, rating: f.rating,
      quality: f.quality_label, keywords: f.keywords,
      ...(f.genre_codes ? { genreCodes: f.genre_codes } : { genres: f.genres }),
      episodes: f.episode_count, free: f.access_tier === 'free',
      featured: f.is_featured,
    } }, f.title);
    await upSave(job);
    const assets = await uploadAll(files, host, folder, job);
    const res = await finishUploadJob(job, assets);
    $('nFiles').value = '';
    $('nFolder').value = '';
    $('nPaths').textContent = '';
    host.textContent = '';
    await openEditor(res.id);
    say('ok', 'Saved "' + res.title + '" as a DRAFT — it is not in the app yet. '
      + 'Set the cover and the order, then send it for review (or approve it) '
      + 'from the bar at the top.' + (res.ladderNote ? ' ' + res.ladderNote : ''));
  } catch (e) {
    say('bad', String(e.message || e) + ' — what was sent is kept; resume it from '
      + 'Interrupted uploads at the top of this page.');
    drawInterrupted();
  }
  b.disabled = false;
};

$('newCatAdd').onclick = addCategory;
$('newGenreAdd').onclick = addGenre;

$('selftest').onclick = async () => {
  try {
    say('info', 'Testing…');
    say('info', JSON.stringify(await api({ op: 'selftest' }), null, 2));
  } catch (e) { say('bad', String(e.message || e)); }
};

wireDrop($('nDrop'), $('nFiles'), () => $('nFiles').onchange());
wireDrop($('addDrop'), $('addFiles'), () => $('addFiles').onchange());

// ── categories ───────────────────────────────────────────────────────────
async function addCategory() {
  const btn = $('newCatAdd');
  const id = ($('newCatId').value || '').trim().toLowerCase();
  const label = ($('newCatLabel').value || '').trim();
  // CHECKED HERE AS WELL AS ON THE SERVER, because the server's refusal arrives
  // as a code and this one arrives as a sentence next to the box that is wrong.
  // The server check is the one that matters; this one is the one that helps.
  if (!/^[a-z0-9-]{2,32}$/.test(id)) {
    return say('bad', 'The id must be 2-32 characters of lower-case letters, ' +
      'digits and hyphens. It is what every film in this section stores.');
  }
  if (!label) return say('bad', 'A category needs a label — it is the tab name.');
  btn.disabled = true;
  try {
    await api({ op: 'addCategory', id, label,
      label_mm: ($('newCatLabelMm').value || '').trim() || null,
      label_th: ($('newCatLabelTh').value || '').trim() || null });
    $('newCatId').value = '';
    $('newCatLabel').value = '';
    $('newCatLabelMm').value = '';
    $('newCatLabelTh').value = '';
    say('ok', 'Added, as the last tab — move it with ▲▼. It is a tab in the ' +
      'app on its next launch, and in the Category picker here straight away.');
    // BOTH, and in this order. The picker is what the operator will reach for
    // next — they added the section to put something in it.
    await refreshCategoryOptions();
    await loadCategories();
  } catch (e) {
    const m = String(e.message || e);
    say('bad', /id_taken/.test(m)
      ? 'That id is already in use. Pick another, or rename the existing one.'
      : m);
  }
  btn.disabled = false;
}

async function loadCategories() {
  const host = $('catList');
  host.textContent = '';
  try {
    const { categories } = await api({ op: 'categories' });
    // THE ORDER IS ARROWS, NOT NUMBERS (migration 035). A title belongs to a
    // category by its id, so moving a category moves its tab and its row on
    // All with everything in them; nothing about the titles changes. `all`
    // is the landing tab and stays first.
    const movable = categories.filter((c) => c.id !== 'all');
    const lead = categories.length - movable.length; // 1 when All is listed
    for (const c of categories) {
      const label = el('input', { value: c.label || '' });
      const labelMm = el('input', { value: c.label_mm || '' });
      const labelTh = el('input', { value: c.label_th || '' });
      const idx = movable.findIndex((m) => m.id === c.id);
      const pos = c.id === 'all' ? 1 : idx + 1 + lead;
      const arrow = (dir, glyph, can) => {
        const b = el('button', { className: 'b', type: 'button',
          title: dir === 'up' ? 'Move up' : 'Move down',
          style: 'min-width:36px;padding:0 8px' }, text(glyph));
        b.disabled = !can;
        b.onclick = async () => {
          b.disabled = true;
          try {
            await api({ op: 'moveCategory', id: c.id, dir });
            say('ok', 'Moved. Its tab, its row on All and everything in them '
              + 'moved together; the app shows it on its next launch.');
            await refreshCategoryOptions();
            await loadCategories();
          } catch (e) {
            say('bad', String(e.message || e));
            b.disabled = false;
          }
        };
        return b;
      };
      const up = arrow('up', '▲', c.id !== 'all' && idx > 0);
      const down = arrow('down', '▼', c.id !== 'all' && idx >= 0 && idx < movable.length - 1);
      const order = el('div', { style: 'display:flex;align-items:center;gap:4px' }, [
        el('b', { className: 'mono', style: 'min-width:22px;text-align:right' }, text(String(pos))),
        up, down,
      ]);
      const vis = el('input', { type: 'checkbox' });
      vis.checked = c.is_visible !== false;
      // `all` is the landing tab and the app refuses to hide it whatever this
      // says, so the box is disabled rather than lying about what it does.
      if (c.id === 'all') vis.disabled = true;

      const save = el('button', { className: 'b' }, text('Save'));
      save.onclick = async () => {
        save.disabled = true;
        try {
          // NO sort_order here: the arrows own the order, and a number read
          // when this list was drawn would undo a move made since.
          await api({ op: 'saveCategory', id: c.id, patch: {
            label: label.value, label_mm: labelMm.value, label_th: labelTh.value,
            is_visible: vis.checked,
          } });
          say('ok', 'Saved. The app picks it up on its next launch.');
        } catch (e) { say('bad', String(e.message || e)); }
        save.disabled = false;
      };

      host.append(el('div', { className: 'sechead',
        style: 'border-bottom:1px solid var(--line);padding-bottom:8px' }, [
        // THE CODE the app and the database know it by (058), never typed
        // and never changed, with the old id an older app still reads.
        el('span', { className: 'chip mono', style: 'min-width:58px',
          title: 'id ' + c.id }, text(c.code || c.id)),
        el('div', { style: 'flex:1;min-width:110px' },
          [el('label', {}, text('Label')), label]),
        el('div', { style: 'flex:1;min-width:110px' },
          [el('label', {}, text('Burmese')), labelMm]),
        el('div', { style: 'flex:1;min-width:110px' },
          [el('label', {}, text('Thai')), labelTh]),
        el('div', {}, [el('label', {}, text('Position')), order]),
        el('div', { style: 'display:flex;align-items:center;gap:6px;align-self:end;height:var(--ctl)' },
          [vis, el('span', { className: 'hint' },
            text(c.id === 'all' ? 'always shown' : 'visible'))]),
        save,
      ]));
    }
  } catch (e) { say('bad', String(e.message || e)); }
}

// ── genres (migration 058) ──────────────────────────────────────────────
//
// THE CODE IS THE DATABASE'S. G001, G002 … are given when a genre is added,
// never typed, never changed and never given twice, so a title, a saved
// filter and every app's cache keep meaning the same genre. The words —
// English, Burmese, Thai — the order and whether it is offered are the
// operator's, and a rename reaches every title that has it, and the search.
//
// A GENRE A TITLE HAS IS NOT DELETED: it is retired (not offered for new
// titles; those that have it keep it) or merged into another (its titles move
// there). Delete is for one no title has — a typo caught at once.
async function addGenre() {
  const btn = $('newGenreAdd');
  const label = ($('newGenreLabel').value || '').trim();
  if (!label) return say('bad', 'A genre needs its English name — it is what the card shows.');
  if (label.length > 40) return say('bad', 'Keep the name to 40 characters.');
  btn.disabled = true;
  try {
    const { code } = await api({ op: 'addGenre', label,
      label_mm: ($('newGenreLabelMm').value || '').trim() || null,
      label_th: ($('newGenreLabelTh').value || '').trim() || null });
    $('newGenreLabel').value = '';
    $('newGenreLabelMm').value = '';
    $('newGenreLabelTh').value = '';
    say('ok', 'Added as ' + code + ', last in the list. It can be given to a title now.');
    await refreshGenreOptions();
    await loadGenres();
  } catch (e) {
    const m = String(e.message || e);
    say('bad', /label_taken/.test(m)
      ? 'There is a genre with that name already. Rename that one, or pick another name.'
      : m);
  }
  btn.disabled = false;
}

async function loadGenres() {
  const host = $('genreList');
  if (!host) return;
  host.textContent = '';
  let genres;
  try {
    ({ genres } = await api({ op: 'genres' }));
  } catch (e) {
    host.append(el('p', { className: 'hint' }, text('The genre list could not be read: '
      + String(e.message || e))));
    return;
  }
  genres = (genres ?? []).slice().sort((a, b) =>
    (a.sort_order ?? 0) - (b.sort_order ?? 0) || String(a.code).localeCompare(String(b.code)));
  GENRES = genres;
  if (!genres.length) {
    host.append(el('p', { className: 'hint' }, text('No genres yet. Add the first below.')));
    return;
  }
  const live = genres.filter((g) => !g.retired_at);
  const redraw = async () => { await refreshGenreOptions(); await loadGenres(); };
  genres.forEach((g, i) => {
    const retired = !!g.retired_at;
    const label = el('input', { value: g.label || '' });
    const labelMm = el('input', { value: g.label_mm || '' });
    const labelTh = el('input', { value: g.label_th || '' });
    const vis = el('input', { type: 'checkbox' });
    vis.checked = g.is_visible !== false;

    const arrow = (dir, glyph, can) => {
      const b = el('button', { className: 'b', type: 'button',
        title: dir === 'up' ? 'Move up' : 'Move down',
        style: 'min-width:36px;padding:0 8px' }, text(glyph));
      b.disabled = !can;
      b.onclick = async () => {
        b.disabled = true;
        try {
          await api({ op: 'moveGenre', code: g.code, dir });
          say('ok', 'Moved. The filter bar and the chooser show the new order.');
          await redraw();
        } catch (e) { say('bad', String(e.message || e)); b.disabled = false; }
      };
      return b;
    };

    const save = el('button', { className: 'b' }, text('Save'));
    save.onclick = async () => {
      save.disabled = true;
      try {
        await api({ op: 'saveGenre', code: g.code, patch: {
          label: label.value, label_mm: labelMm.value, label_th: labelTh.value,
          is_visible: vis.checked,
        } });
        say('ok', 'Saved. Every title with ' + g.code + ' shows the new words, and the search finds them.');
        await redraw();
      } catch (e) {
        const m = String(e.message || e);
        say('bad', /label_taken/.test(m) ? 'Another genre already has that name.' : m);
        save.disabled = false;
      }
    };

    const retire = el('button', { className: 'b', type: 'button' },
      text(retired ? (g.merged_into ? 'Merged' : 'Bring back') : 'Retire'));
    retire.disabled = !!g.merged_into;
    retire.title = retired
      ? (g.merged_into ? 'Merged into ' + g.merged_into : 'Offer it for titles again')
      : 'Stop offering it for new titles; those that have it keep it';
    retire.onclick = async () => {
      retire.disabled = true;
      try {
        await api({ op: 'retireGenre', code: g.code, retired: !retired });
        say('ok', retired ? g.code + ' is offered again.'
          : g.code + ' is retired: no new title gets it; the ' + (g.titles || 0) + ' that have it keep it.');
        await redraw();
      } catch (e) { say('bad', String(e.message || e)); retire.disabled = false; }
    };

    // MERGE: its titles move to the one chosen, and this one is retired into
    // it. Offered only for a live genre, into another live one.
    const into = el('select', { title: 'Merge into' },
      [el('option', { value: '' }, text('Merge into…')),
        ...live.filter((o) => o.code !== g.code)
          .map((o) => el('option', { value: o.code }, text(o.code + ' · ' + o.label)))]);
    into.disabled = retired || live.length < 2;
    into.onchange = async () => {
      const target = into.value;
      if (!target) return;
      const name = live.find((o) => o.code === target)?.label || target;
      if (!confirm('Merge ' + g.code + ' (' + g.label + ') into ' + target + ' (' + name + ')? '
        + 'Its ' + (g.titles || 0) + ' title(s) move there, and ' + g.code + ' is retired.')) {
        into.value = '';
        return;
      }
      try {
        const res = await api({ op: 'mergeGenres', from: g.code, into: target });
        say('ok', 'Merged: ' + (res.moved ?? 0) + ' title(s) moved to ' + target + '.');
        await redraw();
      } catch (e) { say('bad', String(e.message || e)); into.value = ''; }
    };

    const del = el('button', { className: 'b d', type: 'button' }, text('Delete'));
    del.disabled = (g.titles || 0) > 0;
    del.title = del.disabled ? 'A title has it — retire or merge it instead' : 'No title has it';
    del.onclick = async () => {
      if (!confirm('Delete ' + g.code + ' (' + g.label + ')? No title has it. Its code is not given again.')) return;
      del.disabled = true;
      try {
        await api({ op: 'deleteGenre', code: g.code });
        say('ok', g.code + ' deleted.');
        await redraw();
      } catch (e) {
        const m = String(e.message || e);
        say('bad', /in_use/.test(m) ? 'A title has it now — retire or merge it instead.' : m);
        del.disabled = false;
      }
    };

    const used = (g.titles || 0) + ' title' + ((g.titles || 0) === 1 ? '' : 's')
      + ((g.titles || 0) ? ' (' + (g.published || 0) + ' in the app)' : '');
    host.append(el('div', { className: 'sechead',
      style: 'border-bottom:1px solid var(--line);padding-bottom:8px' + (retired ? ';opacity:.65' : '') }, [
      el('span', { className: 'chip mono', style: 'min-width:58px' }, text(g.code)),
      el('div', { style: 'flex:1;min-width:110px' }, [el('label', {}, text('Label')), label]),
      el('div', { style: 'flex:1;min-width:110px' }, [el('label', {}, text('Burmese')), labelMm]),
      el('div', { style: 'flex:1;min-width:110px' }, [el('label', {}, text('Thai')), labelTh]),
      el('div', {}, [el('label', {}, text('Position')),
        el('div', { style: 'display:flex;align-items:center;gap:4px' },
          [arrow('up', '▲', i > 0), arrow('down', '▼', i < genres.length - 1)])]),
      el('div', { style: 'display:flex;align-items:center;gap:6px;align-self:end;height:var(--ctl)' },
        [vis, el('span', { className: 'hint' }, text('offered'))]),
      el('span', { className: 'hint', style: 'align-self:end;min-width:90px' },
        text(retired ? (g.merged_into ? 'merged into ' + g.merged_into : 'retired') + ' · ' + used : used)),
      save, retire, into, del,
    ]));
  });
}

// ── signals ──────────────────────────────────────────────────────────────
async function loadStats() {
  const host = $('statsBody');
  host.textContent = '';
  try {
    const st = await api({ op: 'stats' });
    const pairs = (o) => Object.entries(o || {}).sort((a, b) => b[1] - a[1]);

    const block = (heading, rows, note) => {
      host.append(el('div', { className: 'sechead', style: 'margin-top:14px' },
        [el('h2', {}, text(heading))]));
      if (note) host.append(el('div', { className: 'hint' }, text(note)));
      if (!rows.length) {
        host.append(el('div', { className: 'hint', style: 'margin-top:4px' },
          text('nothing yet')));
        return;
      }
      const t = el('table', { style: 'margin-top:6px;max-width:420px' });
      for (const [k, v] of rows) {
        t.append(el('tr', {}, [
          el('td', {}, text(k)),
          el('td', { className: 'num mono' }, text(v)),
        ]));
      }
      host.append(el('div', { className: 'tw' }, [t]));
    };

    // FIRST, ABOVE EVERYTHING ELSE, because it is the number users feel.
    // Everything below this is about what to publish; this is about whether
    // what is already published actually starts when somebody taps it.
    //
    // Percentiles rather than an average: 500 ms for most people and twenty
    // seconds for one in twenty averages out to something that looks
    // perfectly healthy and is not. p95 is the experience that decides
    // whether somebody opens the app again.
    const sl = st.startup || [];
    host.append(el('div', { className: 'sechead' },
      [el('h2', {}, text('Time to first frame'))]));
    host.append(el('div', { className: 'hint' }, text(
      'Measured on real devices: from tapping play to the first frame. ' +
      'p95 is what it feels like on a bad day, and it is the number worth ' +
      'chasing — the average hides it.')));
    if (!sl.length) {
      host.append(el('div', { className: 'hint', style: 'margin-top:4px' },
        text('no measurements yet — needs a build that reports play_open')));
    } else {
      const t = el('table', { style: 'margin-top:6px;max-width:520px' });
      t.append(el('tr', {}, ['day', 'plays', 'p50', 'p95', 'p99', 'worst']
        .map((h, i) => el('th', { className: i ? 'num' : '' }, text(h)))));
      for (const r of sl) {
        t.append(el('tr', {}, [
          el('td', { className: 'mono' }, text(r.day)),
          el('td', { className: 'num mono' }, text(r.samples)),
          el('td', { className: 'num mono' }, text(r.p50_ms + ' ms')),
          el('td', { className: 'num mono' }, text(r.p95_ms + ' ms')),
          el('td', { className: 'num mono' }, text(r.p99_ms + ' ms')),
          el('td', { className: 'num mono' }, text(r.worst_ms + ' ms')),
        ]));
      }
      host.append(el('div', { className: 'tw' }, [t]));
    }

    block('Slowest titles to start',
      (st.slowest_titles || []).map((r) =>
        [r.title + '  (' + r.samples + ')', r.p95_ms + ' ms']),
      'Start-up cost is mostly a property of the FILE, not the network — an ' +
      'MP4 whose index sits at the end costs an extra round trip every ' +
      'single play. A title at the top of this list is one to re-upload.');

    // The defect that survived because nothing was broken: a video with no
    // thumbnail still draws a picture, just a picture of something else.
    const mh = st.media_health || {};
    block('Media needing attention', [
      ['videos borrowing the title poster', mh.borrows_poster || 0],
      ['assets with no width/height', mh.no_dimensions || 0],
      ['videos with no duration', mh.no_duration || 0],
      ['assets with no byte size', mh.no_size || 0],
      ['assets in total', mh.total || 0],
    ], 'A video with no thumbnail of its own shows the title poster, so ' +
       'every clip in a title draws the same picture. Fix it per video from ' +
       'the editor: 🖼 → "From the video file…".');

    if ((mh.worst || []).length) {
      block('Titles with a video showing the poster',
        mh.worst.map((w) => [w.title, w.kind]));
    }

    block('Events by kind', pairs(st.kinds),
      st.capped ? 'capped at 5000 — the real number is higher' : null);

    // WORTH LOOKING AT FIRST. `vpn_suspect` means the connection claimed one
    // country while the phone's clock and language said Myanmar — the case
    // that would otherwise push a VPN user into somebody else's
    // recommendations. All rows reading "unknown" means cf-ipcountry is not
    // reaching this project at all, which is the one assumption in migration
    // 014 that no SQL console can check.
    block('Geography', pairs(st.geo_trust),
      'vpn_suspect = the phone says Myanmar and the connection does not. ' +
      'All "unknown" = no country header is arriving.');

    block('Audience (what a recommender groups by)', pairs(st.audience));

    block('Searches that found nothing',
      (st.search_gaps || []).map((g) => [g.q, g.misses]),
      'The audience naming what the catalogue is missing, in their own words.');

    block('Trending (time-decayed × completion)',
      (st.trending || []).map((t) => [t.title_id, t.score]),
      'Not wired into the app yet — it needs about two weeks of events before ' +
      'it ranks anything but noise.');

    if (st.error) say('bad', st.error);
  } catch (e) { say('bad', String(e.message || e)); }
}

// ── health ───────────────────────────────────────────────────────────────
// ── start-up: which files make a viewer wait ─────────────────────────────
//
// TURNS "IT FEELS SLOW" INTO A LIST OF FILES. Start-up cost is mostly a
// property of the OBJECT — where the MP4 keeps its index — and that is
// invisible from the database, invisible in the player, and invisible in
// any metric that averages across titles. It is visible in the first sixty
// kilobytes of the file, which is all the probe reads.
// WHAT THIS PANEL LEARNED TO ASK. It began as "where is the index", which
// is a real cost and turned out not to be THE cost: a viewer reported that
// small files play perfectly and short camera clips stutter every couple of
// seconds on a 6 MB/s connection, and an index at the end delays the START,
// once, not every two seconds forever.
//
// The number that explains it is BITRATE, and nothing here knew it. A 133 MB
// clip is not a big file — a feature here is 155 MB — but a 133 MB clip that
// runs for ninety seconds is 12 megabits every second, and a phone camera
// writing 4K will happily produce five times that. Size says how long a
// download takes. Bitrate says whether a stream can keep up at all, and it
// is size divided by DURATION, which is why the probe now reads the movie
// header as well as the box list.
let lastProbe = [];
let lastDelivery = null;
/// object_key -> what the encoder has already made of it.
///
/// WHY THE START-UP PANEL NEEDS THIS. A heavy ORIGINAL is only a problem for
/// somebody who receives the original. If a ladder exists, the app hands a
/// viewer on a weak connection the smaller copy instead, and the file's own
/// bitrate stops being the number that decides anything. Without knowing that,
/// this panel told the operator to re-encode and re-upload files that were
/// already solved — which on this connection is an hour and a gigabyte, spent
/// on nothing.
let lastLadders = {};
let measuredKbps = null;

// A file needs its bitrate delivered CONTINUOUSLY, with nothing left over
// for a lift, a tunnel or somebody else's phone on the same tower. These are
// the two lines where a stream stops being comfortable and stops being
// possible, and they are stated here rather than in four places.
const COMFORTABLE_KBPS = 6000;
const RISKY_KBPS = 12000;

function bitrateClass(kbps) {
  if (kbps == null) return '';
  // Against a MEASUREMENT once there is one. A fixed threshold is a guess
  // about somebody else's connection; the speed test is that connection.
  const ceiling = measuredKbps != null ? measuredKbps * 0.7 : RISKY_KBPS;
  if (kbps >= ceiling) return 'bad';
  if (kbps >= (measuredKbps != null ? ceiling * 0.5 : COMFORTABLE_KBPS)) return 'warn';
  return 'ok';
}

function fmtSecs(s) {
  if (!s && s !== 0) return null;
  const m = Math.floor(s / 60), r = Math.round(s % 60);
  return m + ':' + String(r).padStart(2, '0');
}

function drawProbe() {
  const host = $('probeBody');
  host.textContent = '';
  const rows = lastProbe;
  if (!rows.length) {
    host.append(el('div', { className: 'empty' }, text('No videos to check.')));
    return;
  }

  const tail = rows.filter((r) => r.verdict === 'tail').length;

  // WHERE THE BYTES COME FROM, said out loud. Playback uses the Worker when
  // both its secrets are set and falls back to a presigned S3 URL when either
  // is missing — and the fallback is SILENT, because the app plays either way
  // at the same quality. So nothing on any screen said which path viewers were
  // on, in either direction: weeks on the slower path for nothing, or a belief
  // that the edge was live with no way to find out it was not.
  const d = lastDelivery;
  if (d) {
    const w = d.worker || {};
    if (d.edge && w.ok && w.secret && w.bucket) {
      host.append(el('div', { className: 'msg ok' }, text(
        'Edge delivery is on. Videos come from Cloudflare\'s network through ' +
        'the Worker, and the address a viewer holds says nothing about the ' +
        'bucket. Run the speed test to measure what it actually delivers.')));
    } else if (!d.base_set || !d.secret_set) {
      host.append(el('div', { className: 'msg warn' }, text(
        'Edge delivery is OFF — ' +
        (!d.base_set && !d.secret_set ? 'neither STREAM_BASE nor STREAM_TOKEN_SECRET is set'
          : !d.base_set ? 'STREAM_BASE is not set' : 'STREAM_TOKEN_SECRET is not set') +
        '. Videos still play, from a presigned S3 address that names the ' +
        'account and the bucket, and the bytes take the longer way round. ' +
        'Set both in the Supabase function settings.')));
    } else {
      host.append(el('div', { className: 'msg bad' }, text(
        'Edge delivery is configured but the Worker did not answer properly' +
        (w.status ? ' (HTTP ' + w.status + ')' : w.error ? ': ' + w.error : '') +
        (w.ok && !w.secret ? ' — it is running with no TOKEN_SECRET set' : '') +
        (w.ok && !w.bucket ? ' — it is running with no bucket binding' : '') +
        '. Playback is falling back to presigned S3 addresses.')));
    }
  }

  // IN THE ORDER OF WHAT IT COSTS. A file too fat to stream ruins every second
  // of the film; an index at the end costs one round trip at the start.
  // Leading with the index — which is what this panel used to do, because it
  // was all it could see — sent the operator to re-upload files whose real
  // problem re-uploading does not touch.
  // AND A HEAVY FILE WITH A LADDER IS NOT THE SAME PROBLEM AS ONE WITHOUT.
  // This panel used to count both together and tell the operator the only fix
  // was to re-encode before uploading again. For a file that already has
  // smaller copies that is simply false — the app hands a viewer on a weak
  // connection the rung, and the original's bitrate decides nothing — and
  // acting on it costs an hour of somebody's life and a gigabyte of their
  // data to replace a file that was already fine.
  const heavy = rows.filter((r) => bitrateClass(r.kbps) === 'bad');
  const covered = heavy.filter((r) => (lastLadders[r.key] || {}).rungs > 0);
  const bare = heavy.filter((r) => !((lastLadders[r.key] || {}).rungs > 0));
  const against = measuredKbps != null
    ? 'the ' + (measuredKbps / 1000).toFixed(1) + ' Mbps this connection measured'
    : 'a typical mobile connection';

  // "AND HAVE NO SMALLER COPY" IS ONLY SAID WHEN IT IS KNOWN. If the encoder
  // could not be reached, this panel has no reading at all — and a sentence
  // that states an absence it did not check is the kind of confident wrong
  // answer this whole panel exists to stop producing.
  const knowLadders = Object.keys(lastLadders).length > 0;
  if (bare.length) {
    host.append(el('div', { className: 'msg bad' }, text(
      bare.length + ' of ' + rows.length + ' videos are too heavy for ' +
      against + (knowLadders ? ' and have no smaller copy' : '') +
      '. They will play a second or two, stop, and play again for as long as ' +
      'anyone watches. THE CHEAP FIX IS NOT TO RE-UPLOAD: open Streaming ' +
      'copies and press "Make streamable", and the encoder builds the smaller ' +
      'sizes from the file already in the bucket. Re-encoding before upload is ' +
      'only worth it for a file you have not sent yet.')));
  }
  if (covered.length) {
    host.append(el('div', { className: 'msg info' }, text(
      covered.length + ' of ' + rows.length + ' videos are heavy as ' +
      'ORIGINALS — more than ' + against + ' could carry — but smaller copies ' +
      'already exist, and the app gives those to anyone whose connection ' +
      'cannot take the original. Nothing to do about these.')));
  }
  if (tail) {
    host.append(el('div', { className: 'msg ' + (heavy.length ? 'info' : 'bad') }, text(
      tail + ' of ' + rows.length + ' videos keep their index at the end. ' +
      'That costs every viewer one extra round trip before the first frame — ' +
      'a slower START, not a stutter — and it also means those films CANNOT ' +
      'be watched while they are still downloading, because a player needs ' +
      'the index before it can play a frame. Re-upload them from New or from ' +
      'the title editor; the console writes the index first now.')));
  }
  if (!tail && !heavy.length) {
    host.append(el('div', { className: 'msg ok' }, text(
      'All ' + rows.length + ' videos start from the front and are light ' +
      'enough to stream. Nothing to do.')));
  }

  const list = el('div', { className: 'lst', style: 'margin-top:8px' });
  for (const r of rows) {
    const facts = [];
    facts.push(el('span', { className: 'pfact' }, text(fmtBytes(r.bytes))));
    const dur = fmtSecs(r.seconds);
    if (dur) facts.push(el('span', { className: 'pfact' }, text(dur)));
    if (r.kbps != null) {
      facts.push(el('span', { className: 'pfact ' + bitrateClass(r.kbps) },
        text((r.kbps / 1000).toFixed(1) + ' Mbps')));
    } else if (!r.error) {
      // Said out loud rather than left blank. A blank cell reads as "fine".
      facts.push(el('span', { className: 'pfact' }, text('length unknown')));
    }
    // WHAT THE ENCODER HAS ALREADY MADE OF IT, beside the original's own
    // numbers — because that is what decides whether a heavy file is a problem
    // for a viewer or only a big object in a bucket.
    const lad = lastLadders[r.key];
    if (lad && lad.rungs > 0) {
      facts.push(el('span', { className: 'pfact ok' }, text(
        lad.rungs + ' smaller ' + (lad.rungs === 1 ? 'copy' : 'copies') +
        (lad.lowest_kbps ? ' from ' + (lad.lowest_kbps / 1000).toFixed(1) + ' Mbps' : ''))));
    } else if (lad) {
      facts.push(el('span', { className: 'pfact warn' }, text('no smaller copy')));
    }

    const v = r.error ? r.error : r.verdict;
    facts.push(el('span', {
      className: 'pfact ' + (v === 'faststart' ? 'ok'
        : v === 'tail' ? 'bad' : v === 'unknown' ? 'warn' : 'bad'),
    }, text(v === 'faststart' ? 'index first'
      : v === 'tail' ? 'index at end' : v)));

    list.append(el('div', { className: 'prow' }, [
      // The key, not the title: this is about the OBJECT, and two titles can
      // point at the same one.
      el('div', { className: 'pkey' }, text(r.key)),
      el('div', { className: 'pfacts' }, facts),
    ]));
  }
  host.append(list);
}

$('probeBtn').onclick = async () => {
  const host = $('probeBody');
  const btn = $('probeBtn');
  btn.disabled = true;
  host.textContent = '';
  const note = el('div', { className: 'hint' },
    text('Reading the head of each video, and the tail when the index is there…'));
  host.append(note);
  try {
    // EVERY VIDEO, NOT THE FIRST PAGE OF THEM. The function reads forty
    // objects at a time because each one is a ranged read of R2 and an edge
    // function has a wall clock — so this asks again until it says there is no
    // more. Before it did, the panel's own sentence ("3 of 40 videos keep
    // their index at the end") read as a complete answer and was a sample of
    // the NEWEST forty: the films most likely to predate the upload rewrite
    // were precisely the ones never looked at.
    //
    // A CEILING ON THE LOOP, because a bug in `more` would otherwise be an
    // infinite one on the operator's phone. Forty pages is 1,600 videos; if a
    // catalogue ever reaches that, this panel is the smaller problem.
    // ASKED FIRST AND SEPARATELY, because it is the answer to a different
    // question and it must not be lost when a probe fails: a catalogue that
    // cannot be read is exactly when knowing which delivery path is live
    // matters most.
    try {
      lastDelivery = await api({ delivery: 1 }, PROBE_API);
    } catch (e) {
      lastDelivery = null;
    }
    // THE ENCODER'S VIEW OF THE SAME FILES, from the op the Streaming copies
    // panel already uses. Asked separately and allowed to fail: a missing
    // ladder reading costs a chip and a softer sentence, never the sweep.
    try {
      const lad = await api({ op: 'health' }, TRANSCODE_API);
      lastLadders = {};
      for (const row of (lad.rows || [])) {
        if (row && row.object_key) lastLadders[row.object_key] = row;
      }
    } catch (e) {
      lastLadders = {};
    }
    const all = [];
    let offset = 0;
    for (let page = 0; page < 40; page++) {
      const got = await api({ offset }, PROBE_API);
      const batch = got.results || [];
      all.push(...batch);
      note.textContent = 'Checked ' + all.length + ' video' +
        (all.length === 1 ? '' : 's') + '…';
      // FROM THE SERVER'S COUNT AND NOT FROM OURS. A table row with no object
      // key is skipped by the probe and still occupies a place in the table;
      // counting what came back would step backwards over it.
      if (!got.more || typeof got.nextOffset !== 'number' ||
          got.nextOffset <= offset) break;
      offset = got.nextOffset;
    }
    lastProbe = all;
    drawProbe();
  } catch (e) {
    say('bad', String(e.message || e));
    host.textContent = '';
  } finally {
    btn.disabled = false;
  }
};

// ── films forwarded to the bot ───────────────────────────────────────────
//
// The queue between "the operator forwarded a film" and "it is in the bucket
// with a ladder". The expensive half — moving gigabytes — happens on a runner
// with a fast link; the only thing that needs a person is deciding which card
// a film belongs to, and that is this panel.
//
// THE TWO HALVES ARE SEPARATE ON PURPOSE. Forwarding takes a second and the
// transfer takes an hour, so being made to choose the title first would hold
// up the expensive half for a decision that can wait. A job with no title is
// parked, its bytes safely in the bucket, until somebody picks one here.
let ingestTitles = null;

async function loadIngest() {
  const host = $('ingestBody');
  const btn = $('ingestBtn');
  btn.disabled = true;
  clear();
  host.textContent = '';
  host.append(el('div', { className: 'hint' }, text('Reading the queue…')));
  try {
    const got = await api({ op: 'list' }, INGEST_API);
    // Fetched once and kept: the picker is a list of every card, it does not
    // change while somebody is looking at one screen, and a request per row
    // would be dozens.
    if (!ingestTitles) {
      try {
        const t = await api({ op: 'list', limit: 500 }, API);
        ingestTitles = t.titles || [];
      } catch (e) {
        ingestTitles = [];
      }
    }
    drawIngest(got);
  } catch (e) {
    say('bad', String(e.message || e));
    host.textContent = '';
  } finally {
    btn.disabled = false;
  }
}

/// The From Telegram panel, GROUPED BY FOLDER.
///
/// WHY NOT A ROW PER FILE, WHICH IS WHAT THIS WAS. One album of a film and
/// five stills arrives as fifteen rows, each with its own "Choose a title…"
/// picker. That is fifteen chances to pick the wrong title on the eleventh,
/// and it presents as fifteen decisions something that was one decision when
/// it was sent. The album already agreed on a folder when it was queued — see
/// migration 023 — so the folder is the handle the operator is already
/// thinking in.
///
/// `inbox` IS THE EXCEPTION AND KEEPS ITS PER-FILE PICKERS. It is not an
/// album; it is the drawer everything with no caption falls into, and its
/// contents have nothing to do with each other. "Attach all of inbox" would
/// be a single tap that files a year of unrelated uploads under one title.
function drawIngest(got) {
  const host = $('ingestBody');
  host.textContent = '';
  const rows = got.rows || [];

  if (!got.runner) {
    host.append(el('div', { className: 'msg warn' }, text(
      'The runner half is switched off: INGEST_SECRET is not set on this '
      + 'project. Films can be forwarded and will queue, and nothing will '
      + 'fetch them until it is.')));
  }
  // START NOW, whenever something is still waiting. Forwarding wakes the
  // runner by itself once GH_DISPATCH_TOKEN is set; this is for a queue that
  // filled before it was, or a wait that has gone on too long anyway.
  const waiting = rows.filter((r) => r.state === 'queued').length;
  $('ingestKick').hidden = !waiting || !got.runner;
  if (waiting && !got.instant) {
    host.append(el('div', { className: 'msg warn' }, text(
      'Waiting files are fetched only when GitHub runs the schedule, which can '
      + 'be hours apart. Set GH_DISPATCH_TOKEN on the ingest function (see '
      + 'RUNBOOK → From Telegram) and every forwarded file starts a runner at once.')));
  }
  if (!rows.length) {
    host.append(el('div', { className: 'hint' }, text(
      'Nothing forwarded yet. Send a film to the bot as a file.')));
    return;
  }

  // Newest folder first, which is the order the rows arrive in.
  const groups = new Map();
  for (const r of rows) {
    const folder = String(r.object_key || '').split('/')[0] || 'inbox';
    if (!groups.has(folder)) groups.set(folder, []);
    groups.get(folder).push(r);
  }

  for (const [folder, items] of groups) {
    host.append(folder === 'inbox'
      ? drawLooseFiles(items)
      : drawFolder(folder, items));
  }
}

/// The state, in the words the operator thinks in rather than the database's.
function stateLabel(state) {
  return state === 'done' ? 'in the bucket'
    : state === 'running' ? 'fetching…'
    : state === 'failed' ? 'failed'
    : 'waiting for a runner';
}

/// One file's line inside a group: name, size, state, and the reason if there
/// is one. The note is shown WHILE IT IS STILL GOING ROUND, not only at the
/// end — a row that has already failed twice reads "waiting for a runner",
/// which is true and useless; the note says `attempt 1 of 3 failed: …`.
function ingestLine(r) {
  const line = el('div', {
    style: 'display:flex;gap:8px;align-items:baseline;padding:3px 0',
  });
  line.append(el('span', { className: 'mono', style: 'font-size:12px' },
    text(r.file_name || '(no name)')));
  line.append(el('span', { className: 'hint', style: 'font-size:11px' },
    text([r.bytes ? fmtSize(r.bytes) : '', r.kind].filter(Boolean).join(' · '))));
  line.append(el('span', { className: 'spacer' }));
  line.append(el('span', {
    style: 'font-size:11px;color:' +
      (r.state === 'failed' ? 'var(--bad)' : 'var(--muted)'),
  }, text(stateLabel(r.state))));

  const wrap = el('div', {}, [line]);
  if (r.note && r.note !== 'claimed' && r.note !== 'ok') {
    const bad = r.state === 'failed' || String(r.note).startsWith('attempt ');
    wrap.append(el('div', {
      className: 'hint',
      style: 'font-size:11px;margin:-2px 0 4px;' + (bad ? 'color:var(--bad)' : ''),
    }, text(r.note)));
  }
  if (r.state === 'failed') wrap.append(retryButton(r));
  return wrap;
}

/// Put a spent job back in the queue. See the `retry` op: every failure this
/// pipeline has actually had was the environment rather than the file.
function retryButton(r) {
  const again = el('button', { className: 'b', style: 'margin:2px 0 6px' },
    text('Try again'));
  again.onclick = async () => {
    again.disabled = true;
    try {
      const got = await api({ op: 'retry', job_id: r.id }, INGEST_API);
      if (got.result === 'queued') {
        say('ok', 'Back in the queue. A runner takes it on the next tick.');
      } else if (got.result === 'duplicate') {
        say('warn', 'That file has already been forwarded again — this row '
          + 'stays as history.');
      } else {
        say('warn', String(got.result || 'nothing to retry'));
      }
      await loadIngest();
    } catch (e) {
      say('bad', String(e.message || e));
      again.disabled = false;
    }
  };
  return again;
}

/// One album: the folder, what the operator typed in Telegram, and the two
/// things they can do with it.
function drawFolder(folder, items) {
  const card = el('div', {
    style: 'border:1px solid var(--line);border-radius:var(--r);'
      + 'padding:10px;margin-bottom:10px',
  });

  const head = el('div', { style: 'display:flex;gap:8px;align-items:baseline' });
  head.append(el('b', { className: 'mono' }, text(folder)));
  head.append(el('span', { className: 'spacer' }));
  const photos = items.filter((r) => r.kind === 'photo').length;
  const videos = items.length - photos;
  const bytes = items.reduce((n, r) => n + (Number(r.bytes) || 0), 0);
  head.append(el('span', { className: 'hint', style: 'font-size:12px' }, text(
    [videos ? videos + ' video' + (videos > 1 ? 's' : '') : '',
      photos ? photos + ' photo' + (photos > 1 ? 's' : '') : '',
      fmtSize(bytes)].filter(Boolean).join(' · '))));
  card.append(head);

  // WHAT THE OPERATOR TYPED IN TELEGRAM, kept whole. They write the name, a
  // blank line and three paragraphs of synopsis while forwarding; until
  // 2026-09-29 everything after the first line was dropped and had to be
  // typed again, into a phone. This is that text.
  const caption = (items.find((r) => r.tg_caption) || {}).tg_caption || '';
  if (caption) {
    card.append(el('div', {
      style: 'white-space:pre-wrap;font-size:12px;color:var(--muted);'
        + 'border-left:2px solid var(--line);padding:4px 0 4px 8px;margin:6px 0',
    }, text(caption)));
  }

  const list = el('div', { style: 'margin:6px 0' });
  for (const r of items) list.append(ingestLine(r));
  card.append(list);

  const ready = items.filter((r) => r.state === 'done' && !r.title_id);
  const attached = items.filter((r) => r.title_id).length;
  if (attached) {
    card.append(el('div', { className: 'hint' }, text(
      attached + ' of ' + items.length + ' attached to a title'
      + (ready.length ? '' : ', and queued for streaming copies.'))));
  }

  // NOTHING IS OFFERED UNTIL THE BYTES ARE THERE. Pointing a title at a
  // half-written object puts a film in the catalogue that fails to play,
  // which is worse than one that is not there yet.
  if (!ready.length) {
    if (!attached) {
      card.append(el('div', { className: 'hint' }, text(
        'Nothing finished yet — the actions appear when the files are in the '
        + 'bucket.')));
    }
    return card;
  }

  const row = el('div', { style: 'display:flex;gap:8px;margin-top:8px;flex-wrap:wrap' });
  const pick = el('select', { style: 'flex:1;min-width:140px' });
  pick.append(el('option', { value: '' }, text('Attach all to an existing title…')));
  for (const t of (ingestTitles || [])) {
    pick.append(el('option', { value: t.id }, text(t.title || t.id)));
  }
  const go = el('button', { className: 'b' }, text('Attach ' + ready.length));
  go.onclick = async () => {
    if (!pick.value) { say('warn', 'Choose a title first.'); return; }
    go.disabled = true;
    try {
      const res = await api(
        { op: 'attach_folder', folder, title_id: pick.value }, INGEST_API);
      say('ok', 'Attached ' + res.attached + '. The streaming copies are queued.');
      await loadIngest();
    } catch (e) {
      say('bad', String(e.message || e));
      go.disabled = false;
    }
  };
  row.append(pick, go);

  // THE ONE THAT CLOSES THE LOOP. Everything the new title needs is already
  // here — the folder these files live in, and the name and synopsis the
  // operator typed in Telegram. Retyping a Burmese synopsis into a phone,
  // from memory or by scrolling back through a chat, is the step that made
  // this whole path not worth using.
  //
  // UNLESS THE FOLDER ALREADY HAS ITS TITLE. `/folder <name>` in the bot is
  // how more is added to a title later, and a title made from a folder is
  // that folder's slug — so a second "New title" here could only be refused.
  // The one thing these files can mean is "more of that title": one tap.
  const owner = (ingestTitles || []).find((t) => t.slug === folder);
  if (owner) {
    const more = el('button', { className: 'b p' },
      text('Add ' + ready.length + ' to “' + (owner.title || folder) + '”'));
    more.onclick = async () => {
      more.disabled = true;
      try {
        const res = await api(
          { op: 'attach_folder', folder, title_id: owner.id }, INGEST_API);
        say('ok', 'Added ' + res.attached + ' to “' + (owner.title || folder) + '”.'
          + (owner.published ? ' It is live, so they are in the app now.' : ''));
        await loadIngest();
      } catch (e) {
        say('bad', String(e.message || e));
        more.disabled = false;
      }
    };
    row.append(more);
  } else {
    const fresh = el('button', { className: 'b p' }, text('New title from this'));
    fresh.onclick = () => startTitleFromIngest(folder, caption, fresh);
    row.append(fresh);
  }

  card.append(row);
  return card;
}

/// Everything forwarded without a caption, which is a drawer and not an album.
function drawLooseFiles(items) {
  const card = el('div', {
    style: 'border:1px solid var(--line);border-radius:var(--r);'
      + 'padding:10px;margin-bottom:10px',
  });
  card.append(el('b', { className: 'mono' }, text('inbox')));
  card.append(el('div', { className: 'hint', style: 'margin:2px 0 6px' }, text(
    'Forwarded with no caption, so they share nothing but this drawer. '
    + 'Attached one at a time on purpose.')));

  for (const r of items) {
    const box = el('div', {
      style: 'border-top:1px solid var(--line);padding-top:6px;margin-top:6px',
    });
    box.append(ingestLine(r));
    if (r.state === 'done') {
      if (r.title_id) {
        box.append(el('div', { className: 'hint' },
          text('Attached to a title, and queued for streaming copies.')));
      } else {
        const row = el('div', { style: 'display:flex;gap:8px;margin-top:4px' });
        const pick = el('select', { style: 'flex:1;min-width:0' });
        pick.append(el('option', { value: '' }, text('Choose a title…')));
        for (const t of (ingestTitles || [])) {
          pick.append(el('option', { value: t.id }, text(t.title || t.id)));
        }
        const go = el('button', { className: 'b' }, text('Attach'));
        go.onclick = async () => {
          if (!pick.value) { say('warn', 'Choose a title first.'); return; }
          go.disabled = true;
          try {
            await api({ op: 'attach', job_id: r.id, title_id: pick.value },
              INGEST_API);
            say('ok', 'Attached. The streaming copies are queued.');
            await loadIngest();
          } catch (e) {
            say('bad', String(e.message || e));
            go.disabled = false;
          }
        };
        row.append(pick, go);
        box.append(row);
      }
    }
    card.append(box);
  }
  return card;
}

/// Turn one album into one title, and open the editor on it.
///
/// EVERYTHING IT NEEDS IS ALREADY HERE. The folder these files agreed on when
/// they were queued, and the name and synopsis the operator typed in Telegram
/// while forwarding — a name, a blank line, the description, which is how they
/// already write them. Retyping a Burmese synopsis into a phone, from memory
/// or by scrolling back through a chat, is the step that made this whole path
/// not worth using.
///
/// THE FOLDER IS THE INGEST'S FOLDER AND IS NOT NEGOTIABLE. Every object key
/// of these files begins with it. A title under a different folder would play
/// perfectly — attaching copies the key across — and then disagree with the R2
/// listing, the unused-file report, and every later upload from this page,
/// which reads the folder back to decide where files go.
///
/// It is created as a DRAFT with its files already on it. The rest of the card
/// is the editor's job, which is where this leaves the operator.
async function startTitleFromIngest(folder, caption, btn) {
  const lines = String(caption || '').split('\n');
  const name = (lines[0] || '').trim() || folder;
  const rest = lines.slice(1).join('\n').trim();

  // The name is the one thing worth confirming: it is what people see, the
  // caption's first line is sometimes a file name or a channel's banner, and
  // it is far easier to fix here than after the card exists.
  const chosen = prompt('Name for this title:', name);
  if (chosen === null) return;
  if (!chosen.trim()) { say('warn', 'A title needs a name.'); return; }

  if (btn) btn.disabled = true;
  try {
    const res = await api({
      op: 'create_title', folder, title: chosen, synopsis: rest,
    }, INGEST_API);
    say('ok', 'Created "' + chosen.trim() + '" with ' + res.attached
      + ' file(s). It is a DRAFT — fill in the rest, then send it for review '
      + 'from the bar at the top.');
    // The picker on every other group is now out of date by one title.
    ingestTitles = null;
    openEditor(res.id);
  } catch (e) {
    say('bad', String(e.message || e));
    if (btn) btn.disabled = false;
  }
}

$('ingestBtn').onclick = loadIngest;
$('ingestKick').onclick = async () => {
  const b = $('ingestKick');
  b.disabled = true;
  try {
    const got = await api({ op: 'kick' }, INGEST_API);
    const k = got.kick;
    say(k === 'started' || k === 'waiting' ? 'ok' : 'bad',
      k === 'started' ? 'Runner starting — files land in the bucket within a few minutes.'
      : k === 'waiting' ? 'A runner is already on its way; it takes the whole queue.'
      : k === 'off' ? 'GH_DISPATCH_TOKEN is not set on the ingest function, so only the schedule can start a runner.'
      : 'GitHub refused to start the runner. Check GH_DISPATCH_TOKEN (Actions: read and write, this repository).');
  } catch (e) {
    say('bad', String(e.message || e));
  } finally {
    b.disabled = false;
  }
};

// ── unused files ─────────────────────────────────────────────────────────
//
// THE ONLY PANEL HERE ABOUT MONEY. R2 bills for every object every month
// whether or not anything in the catalogue points at it, and nothing in this
// system has ever deleted one — so the bill only goes one way and nobody could
// see why.
//
// IT LISTS AND IT NEVER DELETES, and that is a decision rather than caution.
// An automatic sweep would race an upload in flight: the object lands seconds
// before its row is written, so for those seconds a perfectly good new film is
// indistinguishable from an abandoned one. The function leaves anything touched
// in the last day out of the list for the same reason and says how many it left
// out, so the report is honest about the window it cannot see into.
//
// `tool/security_invariants.py` fails the build if a delete ever appears in
// probe-media.ts.
async function findOrphans(bucket, btn) {
  const host = $('orphanBody');
  const other = bucket ? $('orphanBtn') : $('orphanPubBtn');
  btn.disabled = true;
  if (other) other.disabled = true;
  clear();
  host.textContent = '';
  const note = el('div', { className: 'hint' },
    text('Listing the bucket…'));
  host.append(note);
  try {
    const found = [];
    let multipart = null;
    let tooNew = 0;
    let freshHours = 24;
    let examined = 0;
    let which = '';
    let token = '';
    // A CEILING ON THE LOOP. A thousand objects a page, so fifty pages is
    // fifty thousand files; a bug in `more` must not spin forever on the
    // operator's phone.
    for (let page = 0; page < 50; page++) {
      const got = await api(
        bucket ? { orphans: bucket, token } : { orphans: 1, token }, PROBE_API);
      which = got.bucket || '';
      examined += got.examined || 0;
      tooNew += got.too_new || 0;
      if (typeof got.fresh_hours === 'number') freshHours = got.fresh_hours;
      for (const o of (got.orphans || [])) found.push(o);
      // Only the first page carries it; a later page's null must not erase it.
      if (Array.isArray(got.multipart)) multipart = got.multipart;
      note.textContent = 'Checked ' + examined + ' file' +
        (examined === 1 ? '' : 's') + '…';
      if (!got.more || !got.next_token || got.next_token === token) break;
      token = got.next_token;
    }
    drawOrphans({ which, examined, found, tooNew, freshHours, multipart });
  } catch (e) {
    say('bad', String(e.message || e));
    host.textContent = '';
  } finally {
    btn.disabled = false;
    if (other) other.disabled = false;
  }
}

function drawOrphans(r) {
  const host = $('orphanBody');
  host.textContent = '';
  const wasted = r.found.reduce((n, o) => n + (o.bytes || 0), 0);

  const head = el('div', { className: 'hint' });
  if (!r.found.length) {
    head.append(text(
      'Nothing unused in ' + r.which + '. Every one of the ' + r.examined +
      ' files there is pointed at by a title, a thumbnail or a streaming copy.'));
  } else {
    head.append(el('b', {}, text(
      r.found.length + ' unused file' + (r.found.length === 1 ? '' : 's') +
      ' · ' + fmtSize(wasted))));
    head.append(text(
      ' in ' + r.which + ', out of ' + r.examined + ' checked. Nothing in the ' +
      'catalogue points at these. Delete them in the Cloudflare R2 dashboard ' +
      'if you are sure — this page will not, on purpose.'));
  }
  if (r.tooNew > 0) {
    head.append(el('div', { style: 'margin-top:6px' }, text(
      r.tooNew + ' more ' + (r.tooNew === 1 ? 'is' : 'are') +
      ' unaccounted for but newer than ' + r.freshHours +
      ' hours, so they are left out: an upload that has landed but whose row ' +
      'is not saved yet looks exactly the same.')));
  }
  host.append(head);

  if (r.found.length) {
    // Newest first would bury the oldest, which are the ones certainly dead.
    // Biggest first, because the bill is bytes.
    const rows = r.found.slice().sort((a, b) => (b.bytes || 0) - (a.bytes || 0));
    const tbl = el('table');
    const thead = el('thead', {}, el('tr', {}, [
      el('th', {}, text('File')),
      el('th', {}, text('Size')),
      el('th', {}, text('Last changed')),
    ]));
    const body = el('tbody');
    for (const o of rows.slice(0, 200)) {
      body.append(el('tr', {}, [
        el('td', {}, el('code', {}, text(o.key))),
        el('td', {}, text(fmtSize(o.bytes || 0))),
        el('td', {}, text((o.modified || '').slice(0, 10))),
      ]));
    }
    tbl.append(thead, body);
    // Wrapped in `.tw` like every other table here: it scrolls inside a bounded
    // box instead of pushing the rest of the panel off a phone screen.
    host.append(el('div', { className: 'tw', style: 'margin-top:8px' }, [tbl]));
    if (rows.length > 200) {
      host.append(el('div', { className: 'hint' }, text(
        'Showing the 200 largest of ' + rows.length + '.')));
    }
  }

  // ── unfinished uploads ──────────────────────────────────────────────────
  //
  // A separate listing, because a file listing does not show them at all. Since
  // the console started uploading anything over 128 MiB in parts, a phone that
  // loses its signal halfway leaves those parts in the bucket, invisible and
  // billed. Reported with an age because a few minutes old is an upload in
  // progress and a day old is abandoned.
  if (Array.isArray(r.multipart)) {
    const stale = r.multipart.filter((m) => m.hours >= 24 || m.hours < 0);
    const msg = el('div', { className: r.multipart.length ? 'msg warn' : 'hint',
      style: 'margin-top:12px' });
    if (!r.multipart.length) {
      msg.append(text('No unfinished uploads.'));
    } else {
      msg.append(el('b', {}, text(
        r.multipart.length + ' unfinished upload' +
        (r.multipart.length === 1 ? '' : 's'))));
      msg.append(text(
        stale.length
          ? ' — ' + stale.length + ' of them older than a day, so abandoned. ' +
            'Cloudflare can expire these automatically: R2 → the bucket → ' +
            'Settings → Object lifecycle rules → abort incomplete multipart ' +
            'uploads. Parts are billed until then and no file listing shows them.'
          : ' — all recent, so one of them may be in progress right now. ' +
            'Look again later before doing anything about them.'));
      const list = el('div', { style: 'margin-top:6px' });
      for (const m of r.multipart.slice(0, 40)) {
        list.append(el('div', {}, [
          el('code', {}, text(m.key || '(no name)')),
          text(m.hours < 0 ? ' · age unknown'
            : m.hours < 48 ? ' · ' + m.hours + 'h old'
            : ' · ' + Math.floor(m.hours / 24) + ' days old'),
        ]));
      }
      msg.append(list);
    }
    host.append(msg);
  }
}

$('orphanBtn').onclick = () => findOrphans('', $('orphanBtn'));
$('orphanPubBtn').onclick = () =>
  findOrphans('innocent-public', $('orphanPubBtn'));

// ── the speed test ────────────────────────────────────────────────────────
//
// MEASURED FROM HERE, ON PURPOSE. Every other number available about this
// service is measured in a datacentre: the edge function's own timings, the
// Worker's CPU time, R2's latency. None of them is what a viewer has. This
// page runs on the operator's phone, on the operator's connection, and it
// asks the SAME Worker for a range of a REAL object with a REAL token — the
// exact path the player takes. What comes back is the only throughput figure
// in the system that anybody actually experiences.
//
// EIGHT MEGABYTES, and the size is a compromise with a reason on each side.
// Too small and TCP never leaves slow start, so the answer flatters the
// connection; too large and an operator on a metered phone pays for a
// diagnostic. Eight is a couple of seconds on a good link and still an
// honest steady-state reading.
$('speedBtn').onclick = async () => {
  const host = $('probeBody');
  const btn = $('speedBtn');
  if (!lastProbe.length) {
    say('info', 'Run "Check videos" first — the test downloads part of a real file.');
    return;
  }
  // The largest object, because a test that finishes before the connection
  // has settled measures the handshake rather than the throughput.
  const target = lastProbe.filter((r) => r.bytes > 0)
    .sort((a, b) => b.bytes - a.bytes)[0];
  if (!target) { say('bad', 'Nothing to test against.'); return; }

  btn.disabled = true;
  const label = el('div', { className: 'msg info' },
    text('Downloading 8 MB through the Worker…'));
  host.prepend(label);
  try {
    const { url, error } = await api({ speed: target.key }, PROBE_API);
    if (!url) throw new Error(error === 'no_stream_base'
      ? 'STREAM_BASE / STREAM_TOKEN_SECRET are not set, so there is no Worker to test.'
      : (error || 'no url'));
    const want = Math.min(8 * 1024 * 1024, target.bytes) - 1;
    const t0 = performance.now();
    const res = await fetch(url, { headers: { Range: 'bytes=0-' + want } });
    if (!res.ok && res.status !== 206) throw new Error('worker said ' + res.status);
    // COUNTED FROM THE BODY, NOT FROM THE HEADER. A Content-Length says what
    // was promised; reading the stream to the end says what arrived, and the
    // difference between those two is exactly what a stalling viewer sees.
    const buf = await res.arrayBuffer();
    const secs = (performance.now() - t0) / 1000;
    const kbps = Math.round((buf.byteLength * 8) / secs / 1000);
    measuredKbps = kbps;

    // Redrawn, because every bitrate on the list was coloured against a
    // guess until this moment and is now coloured against a measurement.
    drawProbe();
    const heavy = lastProbe.filter((r) => r.kbps != null && r.kbps >= kbps * 0.7);
    host.prepend(el('div', { className: 'msg ' + (heavy.length ? 'bad' : 'ok') }, text(
      (kbps / 1000).toFixed(1) + ' Mbps (' + (kbps / 8000).toFixed(1) +
      ' MB/s) through the Worker, measured over ' + fmtBytes(buf.byteLength) +
      ' in ' + secs.toFixed(1) + 's. ' +
      (heavy.length
        ? heavy.length + ' of these files ask for more than 70% of that, ' +
          'which is why they stutter: there is no headroom left for a ' +
          'moment of congestion.'
        : 'Every file in the list fits inside that with room to spare, so a ' +
          'stutter here is not the connection.'))));
  } catch (e) {
    host.prepend(el('div', { className: 'msg bad' }, text(String(e.message || e))));
  } finally {
    label.remove();
    btn.disabled = false;
  }
};

// ── streaming copies ─────────────────────────────────────────────────────
//
// WHAT THE OPERATOR NEEDS FROM THIS PANEL is not a list of files, it is an
// answer to "can this be watched yet". So each row leads with the state and
// the gap the ladder closes: what the original demands per second, and what
// the smallest copy demands. Those two numbers are the work.
async function drawLadders() {
  const host = $('ladderBody');
  host.textContent = '';
  host.append(el('div', { className: 'hint' }, text('Reading…')));
  let res;
  try {
    res = await api({ op: 'health' }, TRANSCODE_API);
  } catch (e) {
    host.textContent = '';
    host.append(el('div', { className: 'msg bad' }, text(String(e.message || e))));
    return;
  }
  host.textContent = '';

  // The encoder half is off until the shared secret exists on both sides.
  // Said plainly here, because otherwise queued jobs simply never start and
  // nothing on screen explains why.
  if (!res.runner) {
    host.append(el('div', { className: 'msg bad' }, text(
      'No encoder is connected. Add the same TRANSCODE_SECRET to Supabase ' +
      '(Edge Function secrets) and to GitHub (repository secrets), along ' +
      'with SUPABASE_URL in GitHub. Until then, queued files stay queued.')));
  }

  const rows = res.rows || [];
  if (!rows.length) {
    host.append(el('div', { className: 'empty' }, text('No videos yet.')));
    return;
  }

  const list = el('div', { className: 'lst' });
  for (const r of rows) {
    const facts = [];
    const state = r.state || 'none';
    facts.push(el('span', {
      className: 'pfact ' + (state === 'ready' ? 'ok'
        : state === 'failed' ? 'bad'
        : state === 'none' ? '' : 'warn'),
    }, text(state)));
    if (r.src_kbps) {
      facts.push(el('span', { className: 'pfact ' + bitrateClass(r.src_kbps) },
        text('source ' + (r.src_kbps / 1000).toFixed(1) + ' Mbps')));
    }
    if (r.rungs) {
      facts.push(el('span', { className: 'pfact ok' }, text(
        r.rungs + ' sizes, ' + (r.lowest_kbps / 1000).toFixed(1) + '–' +
        (r.highest_kbps / 1000).toFixed(1) + ' Mbps')));
    }
    if (r.note) {
      facts.push(el('span', { className: 'pfact' }, text(r.note)));
    }

    // Offered on everything, not only on what looks heavy: an operator who
    // can see a file is fine and wants a ladder anyway is not wrong, and a
    // button that appears and disappears by rule is a button nobody trusts.
    const go = el('button', { className: 'b' },
      text(r.rungs ? 'Convert again' : 'Make streamable'));
    go.onclick = async () => {
      go.disabled = true;
      try {
        await api({ op: 'queue', object_key: r.object_key }, TRANSCODE_API);
        say('ok', 'Queued. It starts within five minutes.');
        await drawLadders();
      } catch (e) {
        say('bad', String(e.message || e));
        go.disabled = false;
      }
    };

    list.append(el('div', { className: 'prow' }, [
      el('div', { className: 'pkey' }, text((r.title || '—') + '  ·  ' + r.object_key)),
      el('div', { className: 'pfacts' }, [...facts, go]),
    ]));
  }
  host.append(list);
}

$('ladderBtn').onclick = drawLadders;

function fmtBytes(n) {
  if (!n) return '\u2014';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)) + ' ' + u[i];
}

// ── the stream secret ────────────────────────────────────────────────────
//
// THE ONE PIECE OF THIS SYSTEM AN OPERATOR CANNOT MAKE ON A PHONE.
// Everything else in the deployment is a dashboard form; the secret assumed
// a terminal (`openssl rand`) and there is not one. The alternatives were
// worse: a value typed by hand is not random, and a value passed through a
// chat or committed to a repository is somewhere it can never be taken back
// from. The browser has the same CSPRNG the command line would have used.
//
// Deliberately NOT stored. Not in localStorage, not posted anywhere, not
// logged. It exists in the input until the page is closed, which is long
// enough to paste it into two dashboards and no longer.
$('genSecret').onclick = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  // base64url, unpadded — it travels in a URL path on one side and through
  // two dashboard text fields on the other, and `+ / =` survive none of
  // those reliably.
  $('secretOut').value = btoa(bin)
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  $('copySecret').disabled = false;
  say('ok', 'Generated. Paste the same value into Cloudflare and Supabase, ' +
      'then close this tab — it is not saved anywhere.');
};

$('copySecret').onclick = async () => {
  const v = $('secretOut').value;
  if (!v) return;
  try {
    await navigator.clipboard.writeText(v);
    say('ok', 'Copied.');
  } catch (_) {
    // A phone browser without clipboard permission. Selecting it is the
    // fallback that always works, and saying so beats a silent failure.
    $('secretOut').select();
    say('info', 'Could not reach the clipboard — the value is selected, ' +
        'copy it by hand.');
  }
};

async function loadHealth() {
  const host = $('healthBody');
  host.textContent = '';
  try {
    const { rows } = await api({ op: 'health' });
    if (!rows.length) {
      host.append(el('div', { className: 'empty' }, text('Nothing to check.')));
      return;
    }
    const cols = ['title', 'status', 'videos', 'photos', 'has_poster', 'verdict'];
    const t = el('table');
    t.append(el('thead', {}, [el('tr', {},
      cols.map((c) => el('th', {}, text(c.replace(/_/g, ' ')))))]));
    const tb = el('tbody');
    for (const r of rows) {
      tb.append(el('tr', {}, cols.map((c) => {
        const td = el('td', {}, text(r[c]));
        if (c === 'verdict' && r[c] !== 'ok') td.style.color = 'var(--bad)';
        return td;
      })));
    }
    t.append(tb);
    host.append(el('div', { className: 'tw' }, [t]));
  } catch (e) { say('bad', String(e.message || e)); }
}

// ── sign-in ──────────────────────────────────────────────────────────────
$('signin').onclick = () => sb.auth.signInWithOAuth({
  provider: 'google',
  // Back to THIS page, not the site root. The redirect must also be listed on
  // Supabase's Auth → URL Configuration page or the round trip lands on an
  // error page with no explanation.
  options: { redirectTo: location.origin + location.pathname },
});

async function boot() {
  const { data: { session } } = await sb.auth.getSession();
  const signedIn = !!session;
  // ONCE PER PERSON, NOT ONCE PER AUTH EVENT. supabase-js reports a token
  // refresh every hour and a verified 2-step code as auth events too; this
  // used to redraw the console on every one of them, which threw the admin
  // back to the first page — in the middle of an edit, an hour in.
  const who = signedIn ? session.user.id : null;
  if (who === bootedFor) return;
  bootedFor = who;
  $('gate').hidden = signedIn;
  $('who').textContent = signedIn ? (session.user.email || session.user.id) : '';
  $('signout').hidden = !signedIn;
  if (signedIn) {
    // The shell asks the server who this is, asks for the 2-step code if the
    // console requires one, draws the menu for that role and opens the page
    // in the address bar.
    await startShell();
    // Not awaited: the picker is seeded with the four that have always existed,
    // so the editor is usable immediately and gains any newer section the
    // moment the table answers. Awaiting would hold the whole console on a
    // request it does not need.
    refreshCategoryOptions();
    refreshGenreOptions().then(upgradeNewGenres);
  } else {
    stopShell();
    for (const t of TABS) $('tab-' + t).hidden = true;
  }
}
let bootedFor;

// Leaving with unsaved details is almost always a mistake, and the editor is
// the one screen where a back gesture can lose typing. Media changes save
// themselves on the spot, so this only ever fires for the form.
window.addEventListener('beforeunload', (e) => {
  // An upload in flight counts too. It can be resumed now, but resuming
  // means picking the file again — worth one "are you sure".
  if (!dirty && !uploadsInFlight) return;
  e.preventDefault();
  e.returnValue = '';
});

// setTimeout, not a direct call: supabase-js holds a lock while it runs this
// callback, and boot() asks it for the session — awaiting that inside the
// callback is the deadlock its documentation warns about.
sb.auth.onAuthStateChange(() => setTimeout(boot, 0));
boot();
