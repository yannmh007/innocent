// The console's sealed preview, in Chromium (docs/MEDIA_ENCRYPTION.md §7.3,
// ENC-4 step 8): docs/studio/sealed_sw.js and sealed_view.js.
//
// Two real servers on loopback, as on Pages: the console's origin, serving
// docs/ (so studio/ and edge/ sit side by side), and a stand-in for the
// streaming Worker on another origin, answering ranges with the CORS the
// real Worker gives the console. A short film made by ffmpeg is sealed and
// played in a <video> through the Service Worker; ranges come back as the
// film's own bytes; an altered segment is never served; a sealed picture
// opens to an image the browser draws.
//
// Skipped where Playwright's Chromium or ffmpeg is missing.
//
//   node tool/js/sealed_preview_test.mjs

import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as ms from '../../docs/edge/media_seal.js';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const DOCS = join(ROOT, 'docs');
let checks = 0;
function ok(cond, what) {
  checks++;
  if (!cond) {
    console.log('FAIL ' + what);
    process.exitCode = 1;
    return;
  }
  console.log('ok   ' + what);
}

let chromium;
try {
  chromium = createRequire(import.meta.url)('playwright').chromium;
} catch {
  console.log('sealed preview: skipped (no Playwright here)');
  process.exit(0);
}
try { execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' }); } catch {
  console.log('sealed preview: skipped (no ffmpeg here)');
  process.exit(0);
}

// ── a film and a picture, sealed ─────────────────────────────────────────
const dir = mkdtempSync(join(tmpdir(), 'sealed-preview-'));
execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24', '-t', '6',
  '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
  join(dir, 'film.mp4')]);
execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=200x120', '-frames:v', '1',
  join(dir, 'still.jpg')]);
const film = new Uint8Array(readFileSync(join(dir, 'film.mp4')));
const still = new Uint8Array(readFileSync(join(dir, 'still.jpg')));
const dek = ms.randomBytes(32);
const dekId = '00000000-0000-4000-8000-0000000000f1';
const sealedFilm = await ms.sealAll(film, dek, ms.aadFor(dekId));
const badFilm = sealedFilm.slice();
badFilm[ms.sealedStart(2) + 5] ^= 1;
const idek = ms.randomBytes(32);
const idekId = '00000000-0000-4000-8000-0000000000f2';
const sealedStill = await ms.sealAll(still, idek, ms.aadFor(idekId));
const b64 = (u) => Buffer.from(u).toString('base64');

// ── the console's origin: docs/, and a harness page ──────────────────────
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };
const site = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path === '/studio/__harness.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    // upload.js gives sealLib and unb64; sealed_view.js the rest; `api` is
    // stood in for (the studio's sealedImage: the picture, still sealed).
    return res.end('<!doctype html><meta charset="utf-8"><body>' +
      '<script>const API = "/none"; window.__img = "' + b64(sealedStill) + '";' +
      'async function api(b) { if (b.op === "sealedImage") return { bytes: window.__img }; throw new Error("op " + b.op); }</script>' +
      '<script src="upload.js"></script><script src="sealed_view.js"></script></body>');
  }
  const file = normalize(join(DOCS, path));
  if (!file.startsWith(DOCS)) { res.writeHead(403); return res.end(); }
  try {
    const body = readFileSync(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404); res.end();
  }
});

// ── the streaming Worker's stand-in: ranges, with the console's CORS ─────
let workerReads = 0;
let siteOrigin = '';
const worker = createServer((req, res) => {
  const cors = { 'Access-Control-Allow-Origin': siteOrigin, 'Access-Control-Expose-Headers': 'Content-Range, Content-Length',
    Vary: 'Origin' };
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { ...cors, 'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS', 'Access-Control-Allow-Headers': 'range' });
    return res.end();
  }
  const obj = req.url.startsWith('/v/bad') ? badFilm : sealedFilm;
  workerReads++;
  const m = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
  if (!m) { res.writeHead(200, { ...cors, 'Content-Length': obj.length }); return res.end(Buffer.from(obj)); }
  const a = Number(m[1]);
  const b = m[2] ? Math.min(Number(m[2]), obj.length - 1) : obj.length - 1;
  res.writeHead(206, { ...cors, 'Content-Range': `bytes ${a}-${b}/${obj.length}`, 'Content-Length': b - a + 1 });
  res.end(Buffer.from(obj.subarray(a, b + 1)));
});

await new Promise((r) => site.listen(0, '127.0.0.1', r));
await new Promise((r) => worker.listen(0, '127.0.0.1', r));
siteOrigin = `http://127.0.0.1:${site.address().port}`;
const workerBase = `http://127.0.0.1:${worker.address().port}`;

const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(siteOrigin + '/studio/__harness.html');

  const seal = (sealedKey, d, id, size, sealed) => ({ dekId: id, dek: b64(d), plainSize: size,
    header: b64(sealed.subarray(0, ms.HEADER)), sealedKey });
  const filmP = { url: workerBase + '/v/film', kind: 'video',
    seal: seal('s/' + 'f'.repeat(32), dek, dekId, film.length, sealedFilm) };

  // Ranges through the Service Worker: the film's own bytes.
  const got = await page.evaluate(async (p) => {
    const f = await sealedVideoSrc(p);
    const out = [];
    for (const [a, b] of [[0, 99], [70000, 70100], [p.seal.plainSize - 50, p.seal.plainSize - 1]]) {
      const r = await fetch(f.src, { headers: { Range: `bytes=${a}-${b}` } });
      out.push({ status: r.status, range: r.headers.get('Content-Range'), bytes: Array.from(new Uint8Array(await r.arrayBuffer())), a, b });
    }
    return { src: f.src, out, controlled: !!navigator.serviceWorker.controller };
  }, filmP);
  ok(got.controlled && /^sealed\/[0-9a-f]{32}$/.test(got.src), 'the console\'s worker controls the page; the film is sealed/<id>');
  ok(got.out.every((o) => o.status === 206 && o.range === `bytes ${o.a}-${o.b}/${film.length}` &&
    Buffer.from(o.bytes).equals(Buffer.from(film.subarray(o.a, o.b + 1)))),
    'three ranges through the worker: the film\'s own bytes (head, middle, tail)');

  // A <video> plays it.
  const played = await page.evaluate(async (p) => {
    const f = await sealedVideoSrc(p);
    const v = document.createElement('video');
    v.muted = true;
    v.playsInline = true;
    keepSealedPlaying(v, f);
    document.body.append(v);
    v.src = f.src;
    await v.play().catch(() => {});
    const t0 = Date.now();
    while (v.currentTime < 1.5 && Date.now() - t0 < 20000 && !v.error) await new Promise((r) => setTimeout(r, 100));
    return { t: v.currentTime, w: v.videoWidth, err: v.error && v.error.code, dur: v.duration };
  }, filmP);
  ok(played.t >= 1.5 && played.w === 320 && Math.abs(played.dur - 6) < 0.3,
    `a <video> plays the sealed film through the worker (${played.t.toFixed(1)} s of ${played.dur}, ${played.w} px)`);
  ok(workerReads > 0, 'every byte came from the Worker\'s origin, sealed (' + workerReads + ' reads)');

  // An altered segment: an error, never the bytes.
  const bad = await page.evaluate(async (p) => {
    const f = await sealedVideoSrc(p);
    const r = await fetch(f.src, { headers: { Range: `bytes=${p.at}-${p.at + 10}` } });
    return r.status;
  }, { ...filmP, url: workerBase + '/v/bad', at: ms.plainStart(2) });
  ok(bad === 502, 'an altered segment is answered 502, never served (' + bad + ')');

  // A film the worker no longer holds: 410, and the page posts it again.
  const gone = await page.evaluate(async () => (await fetch('sealed/' + '0'.repeat(32), { headers: { Range: 'bytes=0-9' } })).status);
  ok(gone === 410, 'an id the worker does not hold: 410 (' + gone + ')');

  // Everything else goes to the network untouched.
  const other = await page.evaluate(async () => (await fetch('sealed_view.js')).status);
  ok(other === 200, 'the console\'s own files are not touched by the worker');

  // A sealed picture: opened here, drawn by the browser.
  const pic = await page.evaluate(async (p) => {
    const src = await sealedImageSrc(p);
    const img = new Image();
    await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = src; });
    return { w: img.naturalWidth, h: img.naturalHeight, blob: src.startsWith('blob:') };
  }, { kind: 'photo', seal: { ...seal('s/' + 'e'.repeat(32), idek, idekId, still.length, sealedStill), mime: 'image/jpeg' } });
  ok(pic.blob && pic.w === 200 && pic.h === 120, 'a sealed picture opens to an image the browser draws (' + pic.w + 'x' + pic.h + ')');

  ok(errors.length === 0, 'no script errors' + (errors.length ? ': ' + errors.join('; ') : ''));
} finally {
  await browser.close();
  site.close();
  worker.close();
}
console.log(process.exitCode ? 'sealed preview: FAILED' : 'sealed preview: all checks passed (' + checks + ')');
