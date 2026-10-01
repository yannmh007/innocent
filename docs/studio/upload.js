// Innocent Studio — the uploader that does not give up.
//
// WHAT THE OPERATOR ASKED FOR. Uploading from a phone in Myanmar means the
// connection drops — for a second in a lift, for minutes between buildings —
// the screen turns itself off, and Android kills a browser tab it has not
// looked at for a while. Each of those used to cost the whole upload: four
// quick retries, then the upload was ABORTED (its parts deleted) and the
// operator started again from zero, with their data allowance.
//
// WHAT THIS DOES INSTEAD, case by case:
//
//   a blip                retries the part, with a fresh URL
//   minutes offline       stops, says "waiting for the connection", and
//                         carries on by itself when it is back — no limit
//   a stalled transfer    a part with no progress for a minute is treated
//                         as a dropped connection, not waited on for ever
//   the screen sleeping   asks the browser to keep it on while uploading
//   the tab dying         every accepted part is recorded in this phone
//                         (IndexedDB); reopen the console, pick the same
//                         file, and only the missing parts are sent
//   "it said finished"    the size R2 ended up with is checked against the
//                         file before any row is written
//
// SIXTEEN MEGABYTE PARTS, down from sixty-four, so a drop costs at most 16 MB
// again rather than 64. R2 wants every part but the last the same size and
// at most 10,000 of them: 16 MiB × 10,000 = 160 GiB per file.
//
// WHAT IT CANNOT DO, said plainly: a browser cannot reopen a file by itself
// after a reload — that is a security rule, not a missing feature — so after
// the tab died the operator picks the same file once more. The page checks it
// is the same file (name, size and a fingerprint of its bytes) before
// resuming, because sending part 40 of a different film into this upload
// would produce a file of the right length with the wrong minutes in it.
//
// Classic script, functions and constants only — loaded before the page's
// own script, run when it calls in.

/// Above this, upload in parts — and so be resumable. 32 MiB is two parts;
/// below it a single PUT is a minute even on a poor uplink.
const MULTIPART_THRESHOLD = 32 * 1024 * 1024;
/// 16 MiB a part. See the header for why.
const PART_SIZE = 16 * 1024 * 1024;
/// Quick retries before asking whether the connection is there at all.
const PART_TRIES = 4;
/// The clock this file runs on. An object rather than constants so
/// tool/js/console_smoke.mjs can shorten a minute's stall to a second; the
/// page itself never changes them.
///   stallMs    a part with no progress for this long is a dropped connection
///   backoffMs  the first pause between quick retries (then doubled)
///   pollMs     how often to look for the connection while waiting for it
const UPLOAD_TIMING = { stallMs: 60000, backoffMs: 1000, pollMs: 10000 };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── is the connection there? ─────────────────────────────────────────────

function netError(message) {
  const e = new Error(message);
  e.network = true;
  return e;
}

/// A failure that waiting for the connection could fix. Matched on the
/// messages the three browser engines give a failed fetch, and on our own
/// flag for an XHR — never on TypeError as such, which is also what a bug
/// throws.
function isNetworkError(e) {
  return !!e && (e.network === true ||
    /Failed to fetch|NetworkError|Load failed|network connection was lost/i
      .test(String(e.message || e)));
}

/// Can this phone reach the console's server right now? `navigator.onLine`
/// alone says only that some network exists — a captive Wi-Fi or a mobile
/// signal with no data says true — so it is asked, cheaply, with the GET the
/// studio function answers without signing in.
async function reachable() {
  if (!navigator.onLine) return false;
  try {
    const r = await fetch(API, { method: 'GET', cache: 'no-store' });
    return r.ok;
  } catch {
    return false;
  }
}

/// Waits — without limit — until the server can be reached again, saying so
/// on the file's row. Wakes on the browser's `online` event or every ten
/// seconds, whichever comes first.
async function waitForNetwork(status) {
  let shown = false;
  while (!(await reachable())) {
    if (!shown && status) {
      status('Waiting for the connection — it will carry on by itself', 'wait');
      shown = true;
    }
    await new Promise((resolve) => {
      const ac = new AbortController();
      const t = setTimeout(() => { ac.abort(); resolve(); }, UPLOAD_TIMING.pollMs);
      window.addEventListener('online', () => { clearTimeout(t); ac.abort(); resolve(); },
        { once: true, signal: ac.signal });
    });
  }
  if (shown && status) status('Connection back — carrying on', 'ok');
}

/// `api`, but a dropped connection is waited out rather than reported. For
/// the small requests in the middle of an upload — signing a part, finishing
/// it — where failing would throw away everything already sent.
async function apiPatient(payload, status, endpoint) {
  for (;;) {
    try {
      return await api(payload, endpoint);
    } catch (e) {
      if (!isNetworkError(e)) throw e;
      await waitForNetwork(status);
    }
  }
}

/// Runs `attempt` until it works, the way a bad connection needs:
///
///   * a few quick retries with a growing pause (a blip, a tower handover);
///   * then, if the server cannot be reached, wait for the connection — for
///     as long as it takes — and start counting again;
///   * if the server CAN be reached and the bytes still will not go, that
///     is the bucket refusing (its CORS rule, the token), which no amount of
///     waiting fixes. Said at once if nothing of this file ever went up;
///     after a few rounds if some did.
///
/// `attempt(fresh)` is told whether to fetch a new presigned URL: after a
/// long wait the old one may have expired.
async function patiently(attempt, status, hadSuccess) {
  let tries = 0;
  let onlineRounds = 0;
  let fresh = false;
  for (;;) {
    try {
      return await attempt(fresh);
    } catch (e) {
      // A bucket that hides the ETag will hide it on every attempt.
      if (/ExposeHeaders/.test(String(e.message || e))) throw e;
      fresh = true;
      tries += 1;
      if (tries < PART_TRIES) {
        await sleep(UPLOAD_TIMING.backoffMs * Math.pow(2, tries - 1));
        continue;
      }
      if (!isNetworkError(e)) throw e;
      if (await reachable()) {
        onlineRounds += 1;
        if (!hadSuccess() || onlineRounds >= 3) throw e;
        if (status) status('The connection is unsteady — trying again', 'wait');
        await sleep(UPLOAD_TIMING.backoffMs * 5);
      } else {
        await waitForNetwork(status);
        onlineRounds = 0;
      }
      tries = 0;
    }
  }
}

// ── one PUT, with a watchdog ─────────────────────────────────────────────

/// PUTs [blob] to a presigned URL with progress. Resolves the ETag (when the
/// bucket exposes it) or ''. A transfer with no progress for a minute is
/// aborted and reported as a network failure, so a dead connection that the
/// phone never notices does not hang the upload for ever.
function putWatched(url, blob, onProgress, needEtag) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    let last = Date.now();
    let over = false;
    const finish = () => { over = true; clearInterval(dog); };
    const dog = setInterval(() => {
      if (!over && Date.now() - last > UPLOAD_TIMING.stallMs) {
        finish();
        x.abort();
        reject(netError('The upload stalled — no progress for a minute.'));
      }
    }, Math.min(5000, UPLOAD_TIMING.stallMs / 4));
    x.open('PUT', url);
    x.upload.onprogress = (e) => {
      last = Date.now();
      if (e.lengthComputable && onProgress) onProgress(e.loaded / e.total);
    };
    x.onload = () => {
      if (over) return;
      finish();
      if (x.status < 200 || x.status >= 300) {
        const e = new Error('R2 refused the upload (HTTP ' + x.status + ').');
        e.status = x.status;
        return reject(e);
      }
      const etag = (x.getResponseHeader('ETag') || '').replace(/^"+|"+$/g, '');
      if (needEtag && !etag) {
        return reject(new Error(
          'The part uploaded but its ETag is not readable, so the upload ' +
          'cannot be completed. Add ETag to ExposeHeaders in the bucket\'s ' +
          'CORS rule — nothing else is wrong.'));
      }
      resolve(etag);
    };
    x.onerror = () => {
      if (over) return;
      finish();
      // Either the connection went, or the bucket has no CORS rule for this
      // page / the token cannot write. `patiently` tells the two apart by
      // asking whether the server can be reached.
      reject(netError('The upload was cut off (or blocked by the bucket\'s ' +
        'CORS rule — "Check bucket access" tells the two apart).'));
    };
    x.send(blob);
  });
}

// ── a small file: one PUT ────────────────────────────────────────────────

async function putSmall(blob, onProgress, { kind, filename, folder }, status) {
  let sig = null;
  await patiently(async (fresh) => {
    if (!sig || fresh) {
      sig = await apiPatient({ op: 'sign', kind, filename, size: blob.size, folder }, status);
    }
    await putWatched(sig.uploadUrl, blob, onProgress, false);
  }, status, () => false);
  return sig;
}

// ── a large file: parts, each one recorded ───────────────────────────────

/// Uploads [blob] in parts and returns `{ objectKey, publicUrl }`.
///
/// `ctx.resume` is a record from an earlier attempt (see `record` below); its
/// accepted parts are not sent again. `ctx.record(mp)` is called after every
/// accepted part with what is needed to carry on — the upload id, the key,
/// the parts and their ETags — and the page stores it in IndexedDB.
///
/// A FAILURE DOES NOT ABORT THE UPLOAD any more. The parts already in R2 are
/// what a resume needs; R2 deletes an unfinished upload by itself after
/// seven days, and Discard (on the Upload page) deletes it at once.
async function putInParts(blob, onProgress, { kind, filename, folder }, ctx = {}) {
  const status = ctx.status || null;
  const record = ctx.record || (() => {});
  const total = blob.size;
  const count = Math.ceil(total / PART_SIZE);
  if (count > 10000) {
    throw new Error('This file is larger than 160 GB, which is R2\'s limit for one upload.');
  }
  const sizeOf = (n) => (n < count ? PART_SIZE : total - (count - 1) * PART_SIZE);

  let mp = null;
  const done = new Map();
  const old = ctx.resume;
  if (old && old.uploadId && old.partSize === PART_SIZE && old.bodySize === total) {
    // FINISHED ALREADY. The tab died between R2 completing the upload and the
    // page writing the row: the object is whole, and uploading it again would
    // leave a second copy nothing points at.
    if (old.completed) return { objectKey: old.objectKey, publicUrl: old.publicUrl || null };
    mp = { ...old, parts: [...(old.parts || [])] };
    for (const p of mp.parts) done.set(p.partNumber, p.etag);
    // THE OTHER SIDE'S VIEW. A part is in the local record only after R2
    // accepted it and handed back its ETag, so the record is trusted — but if
    // R2 says it holds something different, R2 wins, and that part is sent
    // again. NoSuchUpload means R2 has deleted the upload (after seven days,
    // or a Discard on another device): start this file again.
    try {
      const lp = await apiPatient({ op: 'listParts', kind, objectKey: mp.objectKey,
        uploadId: mp.uploadId }, status);
      const theirs = new Map((lp.parts || []).map((p) => [p.partNumber, p]));
      for (const [n, etag] of [...done]) {
        const p = theirs.get(n);
        if (!p || p.etag !== etag || p.size !== sizeOf(n)) done.delete(n);
      }
    } catch (e) {
      if (e.code === 'no_such_upload') {
        mp = null;
        done.clear();
        if (status) status('The unfinished upload had expired — sending this file again', 'warn');
      }
      // Anything else: the local record stands.
    }
  }

  if (!mp) {
    const begin = await apiPatient({ op: 'beginMultipart', kind, filename, folder }, status);
    mp = { uploadId: begin.uploadId, objectKey: begin.objectKey, kind,
      publicUrl: begin.publicUrl || null, partSize: PART_SIZE, bodySize: total, parts: [] };
    record(mp);
  }
  const ref = { kind, objectKey: mp.objectKey, uploadId: mp.uploadId };

  let sent = 0;
  for (const n of done.keys()) sent += sizeOf(n);
  if (onProgress) onProgress(sent / total);

  let queue = [];
  for (let n = 1; n <= count; n++) {
    if (done.has(n)) continue;
    const start = (n - 1) * PART_SIZE;
    const chunk = blob.slice(start, start + sizeOf(n));

    const etag = await patiently(async (fresh) => {
      // A batch of presigned URLs, refilled as it runs out — and refilled at
      // once after a wait, when the ones in hand may have expired.
      if (fresh || !queue.length || queue[0].partNumber !== n) {
        const r = await apiPatient({ ...ref, op: 'signParts', from: n, count: 8 }, status);
        queue = r.parts || [];
      }
      const slot = queue[0];
      // THE URL MUST BE FOR THE PART WE ARE ABOUT TO SEND. `partNumber` is
      // inside the signature, so a batch offset by one would write each chunk
      // at the wrong index — and R2 would accept every part.
      if (!slot || slot.partNumber !== n) {
        throw new Error('The server signed part ' + (slot && slot.partNumber) +
          ' where part ' + n + ' was asked for.');
      }
      const tag = await putWatched(slot.url, chunk,
        (f) => onProgress && onProgress((sent + f * chunk.size) / total), true);
      queue.shift();
      return tag;
    }, status, () => done.size > 0);

    done.set(n, etag);
    sent += chunk.size;
    if (onProgress) onProgress(sent / total);
    mp.parts = [...done].map(([partNumber, e]) => ({ partNumber, etag: e }));
    record(mp);
  }

  const parts = [...done].sort((a, b) => a[0] - b[0])
    .map(([partNumber, e]) => ({ partNumber, etag: e }));
  const res = await apiPatient({ ...ref, op: 'completeMultipart', parts }, status);
  // CHECKED BEFORE ANY ROW IS WRITTEN. `bytes` null means R2 could not be
  // asked; anything else must be exactly the file.
  if (res.bytes != null && Number(res.bytes) !== total) {
    throw new Error('R2 holds ' + res.bytes + ' bytes of a ' + total + '-byte file. ' +
      'Nothing was saved; upload it again.');
  }
  record({ ...mp, completed: true, publicUrl: res.publicUrl || mp.publicUrl });
  return { objectKey: mp.objectKey, publicUrl: res.publicUrl || mp.publicUrl };
}

/// A fingerprint of the bytes about to be uploaded: SHA-256 over the size,
/// the first and the last megabyte. Enough to tell a re-picked file from a
/// different one — a different film, or the same one re-encoded — without
/// reading gigabytes on a phone.
async function fingerprint(blob) {
  const MB = 1024 * 1024;
  const head = new Uint8Array(await blob.slice(0, MB).arrayBuffer());
  const tail = new Uint8Array(await blob.slice(Math.max(0, blob.size - MB)).arrayBuffer());
  const size = new TextEncoder().encode(String(blob.size) + ':');
  const all = new Uint8Array(size.length + head.length + tail.length);
  all.set(size, 0);
  all.set(head, size.length);
  all.set(tail, size.length + head.length);
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', all));
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// ── keeping the screen on ────────────────────────────────────────────────
//
// A screen that turns itself off is how Android decides a tab is idle and
// starts throttling it. The Screen Wake Lock API keeps it on while an upload
// runs; it is released by the browser whenever the tab is hidden, so it is
// asked for again when the tab comes back. Unsupported → nothing happens.
let upWakeLock = null;
async function holdScreenOn() {
  try {
    if (!('wakeLock' in navigator) || upWakeLock) return;
    upWakeLock = await navigator.wakeLock.request('screen');
    upWakeLock.addEventListener('release', () => { upWakeLock = null; });
  } catch {
    upWakeLock = null;
  }
}
function letScreenSleep() {
  try { if (upWakeLock) upWakeLock.release(); } catch { /* already gone */ }
  upWakeLock = null;
}

// ── the record of unfinished uploads, in this phone ──────────────────────
//
// One "job" per press of Upload: where the files are going (a new title with
// its form, or more files for an existing one), and for each file whether it
// is done (with what the title row needs), part-way (with the multipart
// record) or not started. Kept until the title row is written, then deleted.
//
// IN INDEXEDDB, NOT THE SERVER: it describes files on this phone, which only
// this phone can finish sending. Every access is wrapped — a private window
// or a full disk means no resume, never a failed upload.
const UP_DB = 'innocent-studio-uploads';

function upDb() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(UP_DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore('jobs', { keyPath: 'id' });
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
async function upTx(mode, fn) {
  const db = await upDb();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction('jobs', mode);
      const out = fn(tx.objectStore('jobs'));
      tx.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
      tx.onerror = () => reject(tx.error);
    });
  } finally {
    db.close();
  }
}
async function upSave(job) {
  try { await upTx('readwrite', (s) => s.put(JSON.parse(JSON.stringify(job)))); } catch { /* no resume */ }
}
async function upForget(id) {
  try { await upTx('readwrite', (s) => s.delete(id)); } catch { /* nothing to forget */ }
}
async function upJobs() {
  try {
    const all = (await upTx('readonly', (s) => s.getAll())) || [];
    return all.filter((j) => !ME || !j.who || j.who === ME.email)
      .sort((a, b) => (b.at || '').localeCompare(a.at || ''));
  } catch {
    return [];
  }
}

/// A new job for [files], going to [target]: `{ op: 'create', payload }` or
/// `{ op: 'addAssets', titleId }`.
function newUploadJob(files, folder, target, label) {
  return {
    // randomUUID needs a secure context, which GitHub Pages is; the fallback
    // is for anything that is not, where a resume record is still useful.
    id: crypto.randomUUID ? crypto.randomUUID()
      : Date.now().toString(36) + Math.random().toString(36).slice(2),
    at: new Date().toISOString(),
    who: ME ? ME.email : null,
    folder, target, label: label || '',
    files: [...files].map((f) => ({
      name: f.name, size: f.size, type: f.type, lastModified: f.lastModified,
      state: 'pending',
    })),
  };
}

/// The last step, shared by a first attempt and a resume: write the title
/// (or the extra files) and forget the job.
///
/// The heavy videos are queued for streaming copies HERE, after the row: the
/// queue finds an asset by its key, and before this there is no asset.
/// `res.ladderNote` is a sentence about that for the caller's message.
async function finishUploadJob(job, assets) {
  const t = job.target;
  const res = t.op === 'create'
    ? await apiPatient({ ...t.payload, assets })
    : await apiPatient({ op: 'addAssets', titleId: t.titleId, assets });
  await upForget(job.id);
  res.ladderNote = await queueLadders(job.ladder);
  return res;
}

// ── the "interrupted uploads" panel on the Upload page ───────────────────

async function drawInterrupted() {
  const host = $('upResume');
  if (!host) return;
  host.textContent = '';
  const jobs = await upJobs();
  if (!jobs.length) return;
  const sec = el('div', { className: 'sec' }, [
    el('div', { className: 'sechead' }, [el('h2', {}, text('Interrupted uploads'))]),
    el('p', { className: 'hint' }, text(
      'These stopped before they finished — the tab was closed, the phone ' +
      'restarted, or the connection went for too long. Resume sends only what ' +
      'is missing; you will be asked to pick the same file(s) again, because a ' +
      'browser is not allowed to reopen them by itself.')),
  ]);
  for (const job of jobs) sec.append(interruptedCard(job));
  host.append(sec);
}

function jobProgress(job) {
  let have = 0;
  let all = 0;
  for (const f of job.files) {
    all += f.size || 0;
    if (f.state === 'done') have += f.size || 0;
    else if (f.mp && f.mp.bodySize) {
      have += Math.min(f.mp.bodySize, (f.mp.parts || []).length * f.mp.partSize) *
        ((f.size || 0) / f.mp.bodySize);
    }
  }
  return all ? Math.floor((have / all) * 100) : 0;
}

function interruptedCard(job) {
  const doneN = job.files.filter((f) => f.state === 'done').length;
  const old = Date.now() - Date.parse(job.at) > 7 * 86400000;
  const pick = el('input', { type: 'file', multiple: true, hidden: true,
    accept: 'video/*,image/*' });
  const resume = el('button', { className: 'b p', type: 'button' }, text('Resume'));
  const drop = el('button', { className: 'b d', type: 'button' }, text('Discard'));
  const prog = el('div');
  resume.onclick = () => pick.click();
  pick.onchange = () => resumeUploadJob(job, [...pick.files], prog, resume);
  drop.onclick = async () => {
    if (!confirm('Discard this upload? The parts already sent are deleted from R2.')) return;
    for (const f of job.files) {
      if (f.mp && !f.mp.completed) {
        try {
          await api({ op: 'abortMultipart', kind: f.mp.kind, objectKey: f.mp.objectKey,
            uploadId: f.mp.uploadId });
        } catch { /* R2 deletes it after seven days anyway */ }
      }
    }
    await upForget(job.id);
    say('ok', 'Discarded.');
    drawInterrupted();
  };
  const where = job.target.op === 'create' ? 'New title' : 'More files for';
  return el('div', { className: 'cr-rv' }, [
    el('div', { className: 'cr-rv-cover cr-rv-tg' }, text(jobProgress(job) + '%')),
    el('div', { className: 'cr-rv-main' }, [
      el('div', { className: 'cr-rv-title' }, [
        el('b', {}, text(where + ' "' + (job.label || job.folder) + '"'))]),
      el('div', { className: 'cr-rv-facts' }, text(
        doneN + ' of ' + job.files.length + ' file(s) finished · stopped ' + crWhen(job.at) +
        ' · ' + job.files.filter((f) => f.state !== 'done').map((f) => f.name).join(', '))),
      old ? el('div', { className: 'cr-rv-note' }, text(
        'Over seven days old: R2 has deleted the unfinished parts, so the unfinished ' +
        'file(s) will be sent from the start. The finished ones are kept.')) : null,
      el('div', { className: 'cr-rv-acts' }, [resume, drop, pick]),
      prog,
    ]),
  ]);
}

/// Matches the files the operator picked to the job's files — by name and
/// size, and by modified time when both sides have one — and carries on.
async function resumeUploadJob(job, picked, host, btn) {
  const files = [];
  const missing = [];
  for (const jf of job.files) {
    if (jf.state === 'done') {
      // A finished file is not needed again; a stand-in carries its name.
      files.push({ name: jf.name, size: jf.size, type: jf.type, done: true });
      continue;
    }
    const f = picked.find((p) => p.name === jf.name && p.size === jf.size &&
      (!jf.lastModified || !p.lastModified || p.lastModified === jf.lastModified)) ||
      picked.find((p) => p.name === jf.name && p.size === jf.size);
    if (!f) missing.push(jf.name);
    files.push(f || null);
  }
  if (missing.length) {
    say('warn', 'Pick these too (same name and size as before): ' + missing.join(', '));
    return;
  }
  btn.disabled = true;
  host.textContent = '';
  try {
    say('info', 'Resuming — only what is missing will be sent.');
    const assets = await uploadAll(files, host, job.folder, job);
    const res = await finishUploadJob(job, assets);
    drawInterrupted();
    await openEditor(job.target.op === 'create' ? res.id : job.target.titleId);
    say('ok', 'Finished. ' + (job.target.op === 'create'
      ? 'Saved as a DRAFT — send it for review from the bar at the top.'
      : 'The files were added.') + (res.ladderNote ? ' ' + res.ladderNote : ''));
  } catch (e) {
    say('bad', String(e.message || e) + ' — it can be resumed again.');
    btn.disabled = false;
  }
}
