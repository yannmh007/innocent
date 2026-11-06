// docs/console/build.mjs: what console.innocentplayer.com serves, and the
// headers it serves it with (docs/security_review_2026_11.md S4/P4).
//
// WHY. The console moves off GitHub Pages to an origin of its own, with real
// headers. Two ways that goes wrong, both silent until the owner opens it:
// a file the console imports is left out of the bundle (a sealed upload or
// preview that never loads), or the policy blocks something the console
// needs (a blank page, an upload that cannot reach R2). And one way it goes
// wrong for security: the bundle carries more than the console (the whole of
// docs/, as Pages does).
//
// Pinned here: the bundle is the console and the four edge modules, every
// relative import inside it resolves inside it, nothing else is in it; the
// policy is the strict one (no bare https:, frame-ancestors 'none') and
// names the console's own Supabase project; the console's origins are
// allowed by the functions and the stream Worker. In Chromium (where
// Playwright is here): the page loads under the header with no violation,
// its module Service Worker registers, the four hosts are allowed and any
// other is refused.
//
//   node tool/js/console_build_test.mjs

import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { mkdtempSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, extname, join, normalize, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const b = await import(join(ROOT, 'docs/console/build.mjs'));
const co = await import(join(ROOT, 'docs/edge/console_origins.js'));
let failed = 0;
let count = 0;
const check = (what, ok) => {
  count++;
  if (ok) console.log('ok   ' + what);
  else { failed++; console.log('FAIL ' + what); }
};

const out = b.build(mkdtempSync(join(tmpdir(), 'console-dist-')));
const walk = (d) => readdirSync(d).flatMap((n) => {
  const p = join(d, n);
  return statSync(p).isDirectory() ? walk(p) : [relative(out, p)];
});
const files = walk(out).sort();

// ── the bundle ──────────────────────────────────────────────────────────
const studio = readdirSync(join(ROOT, 'docs/studio')).filter((n) => n !== 'README.md');
check('every console file is in it', studio.every((n) => files.some((f) => f === 'studio/' + n || f.startsWith('studio/' + n + '/'))));
check('the four edge modules, and no other edge file',
  files.filter((f) => f.startsWith('edge/')).sort().join() === b.EDGE_MODULES.map((m) => 'edge/' + m).sort().join());
check('nothing else: no docs, migrations, TypeScript or README',
  files.every((f) => f.startsWith('studio/') || f.startsWith('edge/') || ['_headers', '_redirects', 'robots.txt'].includes(f)) &&
  !files.some((f) => /\.(md|ts|sql|toml)$/.test(f)));
const imports = [];
for (const f of files.filter((x) => x.endsWith('.js') && !x.includes('/vendor/'))) {
  const src = readFileSync(join(out, f), 'utf8');
  for (const m of src.matchAll(/(?:\bfrom\s*|\bimport\s*\(\s*)['"](\.{1,2}\/[^'"]+)['"]/g)) {
    imports.push([f, normalize(join(dirname(f), m[1]))]);
  }
}
const missing = imports.filter(([, target]) => !files.includes(target));
check(`every relative import resolves inside the bundle (${imports.length} imports)` +
  (missing.length ? ': missing ' + missing.map(([f, t]) => f + ' -> ' + t).join(', ') : ''), missing.length === 0 && imports.length >= 5);
check('/ goes to the console', readFileSync(join(out, '_redirects'), 'utf8').trim() === '/ /studio/ 302');

// ── the policy ──────────────────────────────────────────────────────────
const csp = b.CSP;
const dir = Object.fromEntries(csp.split(';').map((d) => d.trim().split(/\s+/)).map(([k, ...v]) => [k, v]));
check('default-src none, scripts only from the page itself', dir['default-src'].join() === "'none'" && dir['script-src'].join() === "'self'");
check('no directive allows any https host', !Object.values(dir).some((v) => v.includes('https:') || v.includes('*') || v.includes('http:')));
check("frame-ancestors 'none', base-uri and form-action none", dir['frame-ancestors'].join() === "'none'" &&
  dir['base-uri'].join() === "'none'" && dir['form-action'].join() === "'none'");
const sbUrl = /const SB_URL = '([^']+)'/.exec(readFileSync(join(ROOT, 'docs/studio/app.js'), 'utf8'))[1];
check('connect-src names the console\'s own Supabase project', dir['connect-src'].includes(sbUrl));
const headers = readFileSync(join(out, '_headers'), 'utf8');
check('HSTS, COOP, nosniff, no referrer, not indexed', /Strict-Transport-Security: max-age=\d{8}/.test(headers) &&
  headers.includes('Cross-Origin-Opener-Policy: same-origin') && headers.includes('X-Content-Type-Options: nosniff') &&
  headers.includes('Referrer-Policy: no-referrer') && headers.includes('X-Robots-Tag: noindex'));
check('the Pages copy keeps its <meta> policy', readFileSync(join(ROOT, 'docs/studio/index.html'), 'utf8')
  .includes('http-equiv="Content-Security-Policy"'));

// ── who may call ────────────────────────────────────────────────────────
check('the functions answer both console origins', co.CONSOLE_ORIGINS.includes('https://console.innocentplayer.com') &&
  co.CONSOLE_ORIGINS.includes('https://yannmh007.github.io'));
check('STUDIO_ORIGINS can add, not replace, and junk is dropped',
  co.consoleOrigins('https://test.example, javascript:alert(1), http://evil.example, http://localhost:8080').join() ===
  [...co.CONSOLE_ORIGINS, 'https://test.example', 'http://localhost:8080'].join());
const worker = readFileSync(join(ROOT, 'docs/worker/src/index.js'), 'utf8');
check('the stream Worker answers the new console origin', /STUDIO_ORIGINS = \[[^\]]*'https:\/\/console\.innocentplayer\.com'/.test(worker));
const toml = readFileSync(join(ROOT, 'docs/console/wrangler.toml'), 'utf8');
check('the console Worker is on the domain only (no workers.dev)', /console\.innocentplayer\.com/.test(toml) &&
  /workers_dev = false/.test(toml) && /directory = "\.\/dist"/.test(toml));

// ── in Chromium, under the header ───────────────────────────────────────
let chromium = null;
try { chromium = createRequire(import.meta.url)('playwright').chromium; } catch { /* below */ }
if (!chromium) {
  console.log('(Chromium part skipped: no Playwright here)');
} else {
  const rules = [];
  let cur = null;
  for (const line of headers.split('\n')) {
    if (!line.trim()) continue;
    if (!/^\s/.test(line)) { cur = { path: line.trim(), h: {} }; rules.push(cur); continue; }
    const i = line.indexOf(':');
    cur.h[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.txt': 'text/plain' };
  const site = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (path === '/') { res.writeHead(302, { Location: '/studio/' }); return res.end(); }
    const want = path.endsWith('/') ? path + 'index.html' : path;
    const file = normalize(join(out, want));
    if (!file.startsWith(out)) { res.writeHead(403); return res.end(); }
    const h = {};
    for (const r of rules) {
      if (r.path === '/*' || r.path === path) Object.assign(h, r.h);
    }
    delete h['Strict-Transport-Security']; // loopback is http
    try {
      const body = readFileSync(file);
      res.writeHead(200, { ...h, 'Content-Type': TYPES[extname(file)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404); res.end();
    }
  });
  await new Promise((r) => site.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${site.address().port}`;
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.addInitScript(() => {
      window.__violations = [];
      document.addEventListener('securitypolicyviolation', (e) =>
        window.__violations.push(e.effectiveDirective + ' ' + e.blockedURI));
    });
    // Nothing leaves the loopback: every other request is answered here,
    // after the page's policy has had its say.
    await page.route((u) => !u.href.startsWith(base), (r) => r.fulfill({ status: 204, body: '' }));
    await page.goto(base + '/');
    await page.waitForLoadState('load');
    check('/ lands on the console', page.url() === base + '/studio/');
    const own = await page.evaluate(() => window.__violations.slice());
    check('the console loads under the header with no violation' + (own.length ? ': ' + own.join('; ') : ''), own.length === 0);
    const sw = await page.evaluate(async () => {
      try {
        const r = await navigator.serviceWorker.register('sealed_sw.js', { type: 'module', scope: './' });
        await navigator.serviceWorker.ready;
        return !!r;
      } catch (e) { return String(e); }
    });
    check('its module Service Worker registers under the header', sw === true);
    const probe = await page.evaluate(async (hosts) => {
      const res = {};
      for (const u of hosts) {
        window.__violations.length = 0;
        try { await fetch(u, { mode: 'no-cors' }); } catch (_) { /* refused or offline */ }
        await new Promise((r) => setTimeout(r, 50));
        res[u] = window.__violations.length === 0;
      }
      return res;
    }, [sbUrl + '/rest/v1/', 'https://stream.innocentplayer.com/health', 'https://cdn.innocentplayer.com/x',
      'https://abc123.r2.cloudflarestorage.com/x', 'https://evil.example/collect']);
    check('the four hosts are allowed', probe[sbUrl + '/rest/v1/'] && probe['https://stream.innocentplayer.com/health'] &&
      probe['https://cdn.innocentplayer.com/x'] && probe['https://abc123.r2.cloudflarestorage.com/x']);
    check('any other host is refused (a stolen session cannot be sent away)', probe['https://evil.example/collect'] === false);
  } finally {
    await browser.close();
    site.close();
  }
}

if (failed) {
  console.log(`\n${failed} of ${count} check(s) FAILED`);
  process.exit(1);
}
console.log(`\n=== ${count} check(s) on the console's own origin passed ===`);
