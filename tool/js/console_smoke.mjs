// The console in a real browser, against a fake Supabase.
//
// WHAT THIS GUARDS. The control-room shell is three files sharing one global
// scope, a router, a role-filtered menu in two shapes, and a two-step sign-in
// that interrupts requests and sends them again. None of that can be checked
// by reading it: a menu that draws for an owner and throws for a viewer, or
// a code dialog that verifies and then never retries, both look correct in
// the source. So the page is loaded in Chromium, signed in as each role, and
// driven.
//
// NOTHING REAL IS CONTACTED. Every request to the Supabase project is
// answered here — auth, the MFA endpoints and the edge functions — and the
// page's own files are served from docs/studio. A request this file does not
// expect fails the test, so a page that starts calling something new is
// noticed.
//
//   node tool/js/console_smoke.mjs
//
// Needs Playwright (npm i -g playwright) and a Chromium; skips loudly without.

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, extname } from 'path';
import { createRequire } from 'module';
import { execSync } from 'child_process';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const STUDIO = join(ROOT, 'docs', 'studio');

let chromium;
try {
  const req = createRequire(import.meta.url);
  let mod;
  try { mod = req('playwright'); } catch {
    const g = execSync('npm root -g', { encoding: 'utf8' }).trim();
    mod = req(join(g, 'playwright'));
  }
  chromium = mod.chromium;
} catch {
  console.log('SKIP console smoke test — Playwright is not installed; the console was NOT driven');
  process.exit(0);
}

let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

const SB = 'https://yqonvmuiezqvyqmexrft.supabase.co';
const SITE = 'http://studio.test';
const USER = '6c679480-3387-4442-ad3d-4423b8aceb71';
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);
const jwt = (aal, totpAt) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({
  sub: USER, role: 'authenticated', aal, exp: now() + 86400, session_id: 's1',
  amr: totpAt ? [{ method: 'oauth', timestamp: now() - 600 }, { method: 'totp', timestamp: totpAt }]
    : [{ method: 'oauth', timestamp: now() - 600 }],
})}.sig`;

const TYPES = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css' };

/// One browser page, signed in as `role`, with a scripted backend.
/// `opts.factors` — the account's authenticators; `opts.requireMfa` — what the
/// server enforces; `opts.whoami` — override the whoami answer.
async function open(browser, role, opts = {}) {
  const ctx = await browser.newContext({
    viewport: opts.phone ? { width: 390, height: 844 } : { width: 1280, height: 860 },
  });
  const page = await ctx.newPage();
  const state = {
    role, aal: opts.aal || 'aal1', factors: opts.factors || [],
    calls: [], errors: [], unexpected: [], verifyCount: 0,
  };
  page.on('pageerror', (e) => state.errors.push(String(e)));
  // A refused request is logged by the browser as "Failed to load resource";
  // several scenarios refuse on purpose, and that is not a script error.
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) state.errors.push(m.text());
  });

  await page.addInitScript(({ token, user }) => {
    localStorage.setItem('sb-yqonvmuiezqvyqmexrft-auth-token', JSON.stringify({
      access_token: token, token_type: 'bearer', expires_in: 86400,
      expires_at: Math.floor(Date.now() / 1000) + 86400, refresh_token: 'r1', user,
    }));
  }, {
    token: jwt(state.aal, state.aal === 'aal2' ? now() - (opts.codeAge || 60) : 0),
    user: { id: USER, email: 'boss@example.com', aud: 'authenticated', factors: state.factors },
  });

  await page.route(SITE + '/**', async (route) => {
    const path = new URL(route.request().url()).pathname.replace(/^\//, '') || 'index.html';
    try {
      const body = readFileSync(join(STUDIO, path));
      await route.fulfill({ status: 200, body, contentType: TYPES[extname(path)] || 'application/octet-stream' });
    } catch {
      await route.fulfill({ status: 404, body: 'no' });
    }
  });

  const json = (route, status, body) =>
    route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body),
      headers: { 'Access-Control-Allow-Origin': '*' } });

  await page.route(SB + '/**', async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const p = url.pathname;
    if (req.method() === 'OPTIONS') {
      return route.fulfill({ status: 204, headers: {
        'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*',
        'Access-Control-Allow-Methods': 'GET,POST,DELETE,PUT,OPTIONS' } });
    }
    const auth = req.headers().authorization || '';
    const claims = JSON.parse(Buffer.from((auth.split('.')[1] || 'e30'), 'base64url').toString() || '{}');
    let body = {};
    try { body = req.postDataJSON() || {}; } catch { body = {}; }
    state.calls.push({ p, op: body.op, aal: claims.aal });

    if (p === '/auth/v1/user') {
      return json(route, 200, { id: USER, email: 'boss@example.com', aud: 'authenticated', factors: state.factors });
    }
    if (p === '/auth/v1/logout') return route.fulfill({ status: 204 });
    if (p === '/auth/v1/factors' && req.method() === 'POST') {
      const f = { id: 'f-new', friendly_name: body.friendly_name, factor_type: 'totp', status: 'unverified' };
      state.factors.push(f);
      return json(route, 200, { id: 'f-new', type: 'totp', friendly_name: body.friendly_name,
        totp: { qr_code: '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>',
          secret: 'JBSWY3DPEHPK3PXPJBSWY3DP', uri: 'otpauth://totp/Innocent%20Studio:boss?secret=JBSWY3DPEHPK3PXP' } });
    }
    let m = /^\/auth\/v1\/factors\/([^/]+)$/.exec(p);
    if (m && req.method() === 'DELETE') {
      state.factors = state.factors.filter((f) => f.id !== m[1]);
      return json(route, 200, { id: m[1] });
    }
    m = /^\/auth\/v1\/factors\/([^/]+)\/challenge$/.exec(p);
    if (m) return json(route, 200, { id: 'c1', type: 'totp', expires_at: now() + 300 });
    m = /^\/auth\/v1\/factors\/([^/]+)\/verify$/.exec(p);
    if (m) {
      if (body.code !== '123456') {
        return json(route, 422, { code: 'mfa_verification_failed', msg: 'Invalid TOTP code entered', message: 'Invalid TOTP code entered' });
      }
      state.verifyCount += 1;
      state.aal = 'aal2';
      for (const f of state.factors) if (f.id === m[1]) f.status = 'verified';
      return json(route, 200, {
        access_token: jwt('aal2', now()), token_type: 'bearer', expires_in: 86400,
        expires_at: now() + 86400, refresh_token: 'r2',
        user: { id: USER, email: 'boss@example.com', aud: 'authenticated', factors: state.factors },
      });
    }

    if (p === '/functions/v1/studio') {
      if (opts.notAdmin) return json(route, 403, { error: 'not_an_admin' });
      if (opts.requireMfa && claims.aal !== 'aal2') return json(route, 403, { error: 'mfa_required' });
      if (opts.stepUp && opts.stepUp.includes(body.op) && !(claims.amr || [])
        .some((a) => a.method === 'totp' && now() - a.timestamp < 300)) {
        return json(route, 403, { error: 'reauth_required' });
      }
      const ops = {
        whoami: () => ({ email: 'boss@example.com', role: state.role, aal: claims.aal,
          requireMfa: !!opts.requireMfa, idleMinutes: 30, stepupMinutes: 10, ...(opts.whoami || {}) }),
        summary: () => ({ titles: { live: 12, drafts: 3 }, telegram: { queued: 1, running: 0, failed: 2, unattached: 4 },
          requests: 5, recent: !['owner', 'editor'].includes(state.role) ? [] : [
            { at: new Date().toISOString(), actor_email: 'boss@example.com', actor_role: 'owner',
              fn: 'studio', action: 'save', target: 't1', ok: true, error: null }] }),
        list: () => ({ titles: [] }),
        categories: () => ({ categories: [{ id: 'movies', sort_order: 1 }] }),
        requests: () => ({ rows: [] }),
        admins: () => ({ admins: [
          { id: 'a1', email: 'boss@example.com', role: 'owner', disabled: false, linked: true, mfa: true, last_seen_at: new Date().toISOString() },
          { id: 'a2', email: 'helper@example.com', role: 'uploader', disabled: false, linked: false, mfa: false, last_seen_at: null },
        ] }),
        adminRemove: () => ({ ok: true, result: 'disabled' }),
        audit: () => ({ rows: [
          { id: 7, at: new Date().toISOString(), actor_email: 'boss@example.com', actor_role: 'owner',
            fn: 'studio', action: 'deleteTitle', target: 't9', ok: false, error: 'reauth_required' },
          { id: 6, at: new Date(Date.now() - 7200e3).toISOString(), actor_email: 'helper@example.com',
            actor_role: 'uploader', fn: 'ingest', action: 'create_title', target: 'solar', ok: true, error: null },
        ] }),
        settings: () => ({ settings: { require_mfa: !!opts.requireMfa, stepup_minutes: 10, idle_minutes: 30 } }),
        health: () => ({ rows: [] }),
        stats: () => ({}),
      };
      const f = ops[body.op];
      if (!f) { state.unexpected.push('studio op ' + body.op); return json(route, 400, { error: 'unknown_op' }); }
      return json(route, 200, f());
    }
    if (p === '/functions/v1/ingest') return json(route, 200, { rows: [], runner: true });
    if (p === '/functions/v1/transcode') return json(route, 200, { rows: [], runner: true });
    state.unexpected.push(req.method() + ' ' + p);
    return json(route, 404, { error: 'not_stubbed' });
  });

  await page.goto(SITE + '/index.html' + (opts.hash || ''));
  return { page, ctx, state };
}

// SMOKE_SHOTS=<dir> saves a picture of each page as the test reaches it, for
// a person to look at; the test itself never reads them.
const shot = async (page, name) => {
  if (process.env.SMOKE_SHOTS) await page.screenshot({ path: join(process.env.SMOKE_SHOTS, name + '.png') });
};
const visible = (page, sel) => page.locator(sel).first().isVisible();
const menuTabs = (page, sel) => page.$$eval(sel, (ns) => ns.map((n) => n.dataset.tab).filter(Boolean));

const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' })
  .catch(() => chromium.launch());

try {
  // ── an owner on a desk ──────────────────────────────────────────────────
  {
    const { page, ctx, state } = await open(browser, 'owner');
    await page.waitForSelector('#tab-dashboard:not([hidden]) .cr-kpi');
    await shot(page, 'desk-dashboard');
    check('owner: lands on the dashboard', await visible(page, '#tab-dashboard'));
    check('owner: the address bar says so', page.url().endsWith('#/dashboard'));
    check('owner: four numbers on the dashboard', (await page.$$('.cr-kpi')).length === 4);
    check('owner: the failed Telegram files are the first thing to do',
      /failed/.test(await page.textContent('#dashTodo .cr-todo')));
    check('owner: the sidebar is shown on a desk', await visible(page, '#side'));
    check('owner: the bottom bar is not', !(await visible(page, '#tabbar')));
    const side = await menuTabs(page, '#side .sh-item');
    check('owner: every page is in the menu (' + side.length + ')', side.length === 12 &&
      side.includes('admins') && side.includes('activity') && side.includes('files'));
    check('owner: the Telegram badge counts failed + unfiled',
      (await page.textContent('#side [data-badge=telegram]')) === '6');
    check('owner: the role is shown', (await page.textContent('#roleChip')) === 'owner');

    await page.click('#side a[data-tab=telegram]');
    await page.waitForSelector('#tab-telegram:not([hidden])');
    check('owner: Telegram is its own page now', await visible(page, '#ingestBody'));
    check('owner: and it fills itself', state.calls.some((c) => c.p === '/functions/v1/ingest'));
    check('owner: the menu marks it', (await page.getAttribute('#side a[data-tab=telegram]', 'aria-current')) === 'page');
    check('owner: Health no longer carries the Telegram panel',
      !(await page.$('#tab-health #ingestBody')) && !!(await page.$('#tab-files #orphanBtn')));

    await page.goBack();
    await page.waitForSelector('#tab-dashboard:not([hidden])');
    check('owner: the back button goes back a page', page.url().endsWith('#/dashboard'));

    await page.click('#side a[data-tab=admins]');
    await page.waitForSelector('#admList .cr-adm');
    await shot(page, 'desk-admins');
    check('owner: admins are listed', (await page.$$('#admList .cr-adm')).length === 2);
    check('owner: an admin without 2-step says so',
      /2-step OFF/.test(await page.textContent('#admList .cr-adm:nth-child(2)')));

    await page.click('#side a[data-tab=activity]');
    await page.waitForSelector('#actList .cr-line');
    await shot(page, 'desk-activity');
    check('owner: the activity log is drawn', (await page.$$('#actList .cr-line')).length === 2);
    check('owner: a refused change is marked as failed',
      /failed/.test(await page.textContent('#actList .cr-line.no')));
    check('owner: the person filter fills from the log',
      (await page.$$('#actWho option')).length === 3);

    check('owner: no script errors', state.errors.length === 0);
    if (state.errors.length) console.log('     ' + state.errors.join('\n     '));
    check('owner: nothing unexpected was called', state.unexpected.length === 0);
    if (state.unexpected.length) console.log('     ' + state.unexpected.join('\n     '));
    await ctx.close();
  }

  // ── an uploader on a phone ──────────────────────────────────────────────
  {
    const { page, ctx, state } = await open(browser, 'uploader', { phone: true, hash: '#/admins' });
    await page.waitForSelector('#tab-dashboard:not([hidden])');
    check('uploader: a page above their role falls back to the dashboard',
      page.url().endsWith('#/dashboard'));
    await shot(page, 'phone-dashboard');
    check('uploader: the bottom bar is shown on a phone', await visible(page, '#tabbar'));
    check('uploader: the sidebar is not', !(await visible(page, '#side')));
    const bar = await menuTabs(page, '#tabbar .sh-tab');
    check('uploader: the bar is Dashboard, Library, Upload, Telegram (' + bar.join(',') + ')',
      bar.join(',') === 'dashboard,catalogue,new,telegram');
    await page.click('#tabbar [data-more]');
    await shot(page, 'phone-more');
    const more = await menuTabs(page, '#sheet .sh-item');
    check('uploader: More has no owner or editor pages (' + more.join(',') + ')',
      !more.includes('admins') && !more.includes('activity') && !more.includes('files') &&
      more.includes('security') && more.includes('health'));
    await page.click('#sheet a[data-tab=security]');
    await page.waitForSelector('#tab-security:not([hidden])');
    check('uploader: the sheet closes on a choice', !(await visible(page, '#sheet')));
    check('uploader: More is marked while inside it',
      (await page.getAttribute('#tabbar [data-more]', 'aria-current')) === 'page');
    check('uploader: the console rules are an owner\'s', !(await visible(page, '#secSettings')));
    const w = await page.evaluate(() => document.documentElement.scrollWidth);
    check('uploader: nothing is wider than the phone (' + w + 'px)', w <= 390);
    check('uploader: no script errors', state.errors.length === 0);
    if (state.errors.length) console.log('     ' + state.errors.join('\n     '));
    await ctx.close();
  }

  // ── a viewer ────────────────────────────────────────────────────────────
  {
    const { page, ctx, state } = await open(browser, 'viewer', { phone: true });
    await page.waitForSelector('#tab-dashboard:not([hidden])');
    const bar = await menuTabs(page, '#tabbar .sh-tab');
    check('viewer: no Upload on the bar (' + bar.join(',') + ')', !bar.includes('new'));
    check('viewer: no recent activity (it is an editor\'s)', !(await visible(page, '#dashRecentSec')));
    check('viewer: no script errors', state.errors.length === 0);
    await ctx.close();
  }

  // ── somebody who is not an admin ────────────────────────────────────────
  {
    const { page, ctx } = await open(browser, 'owner', { notAdmin: true });
    await page.waitForSelector('#msg.bad');
    check('stranger: told in words', /not an admin/.test(await page.textContent('#msg')));
    check('stranger: no menu', !(await visible(page, '#side')) && !(await visible(page, '#tabbar')));
    check('stranger: can sign out', await visible(page, '#signout'));
    await ctx.close();
  }

  // ── two-step at sign-in ─────────────────────────────────────────────────
  {
    const { page, ctx, state } = await open(browser, 'editor', {
      requireMfa: true, factors: [{ id: 'f1', factor_type: 'totp', status: 'verified', friendly_name: 'phone' }],
    });
    await page.waitForSelector('.cr-dlg .cr-code');
    await shot(page, 'desk-code');
    check('2-step: the code is asked for before the console opens', !(await visible(page, '#side')));
    await page.fill('.cr-dlg .cr-code', '000000');
    await page.waitForFunction(() => /not right/.test(document.querySelector('.cr-dlg')?.textContent || ''));
    check('2-step: a wrong code keeps the dialog and says so', await visible(page, '.cr-dlg'));
    await page.fill('.cr-dlg .cr-code', '123456');
    await page.waitForSelector('#tab-dashboard:not([hidden]) .cr-kpi');
    check('2-step: the right code opens the console', await visible(page, '#side'));
    check('2-step: and the server saw a session with the code',
      state.calls.filter((c) => c.op === 'whoami').every((c) => c.aal === 'aal2'));
    check('2-step: no script errors', state.errors.length === 0);
    if (state.errors.length) console.log('     ' + state.errors.join('\n     '));
    await ctx.close();
  }

  // ── a fresh code for a dangerous change, then the same request again ────
  {
    const { page, ctx, state } = await open(browser, 'owner', {
      aal: 'aal2', codeAge: 3600, stepUp: ['adminRemove'], hash: '#/admins',
      factors: [{ id: 'f1', factor_type: 'totp', status: 'verified', friendly_name: 'phone' }],
    });
    // A session whose code was given an hour ago: still aal2, but not fresh
    // enough to remove an admin with — the case the step-up exists for.
    await page.waitForSelector('#admList .cr-adm');
    state.calls.length = 0;
    page.once('dialog', (d) => d.accept());
    await page.click('#admList .cr-adm:nth-child(2) button.b.d');
    await page.waitForSelector('.cr-dlg .cr-code');
    check('step-up: removing an admin asks for a fresh code',
      /Confirm it is you/.test(await page.textContent('.cr-dlg')));
    await page.fill('.cr-dlg .cr-code', '123456');
    await page.waitForFunction(() => /removed/.test(document.querySelector('#msg')?.textContent || ''));
    const tries = state.calls.filter((c) => c.op === 'adminRemove');
    check('step-up: the refused request was sent again, once (' + tries.length + ')', tries.length === 2);
    check('step-up: no script errors', state.errors.length === 0);
    if (state.errors.length) console.log('     ' + state.errors.join('\n     '));
    await ctx.close();
  }

  // ── setting up an authenticator on the Security page ───────────────────
  {
    const { page, ctx, state } = await open(browser, 'owner', { phone: true, hash: '#/security' });
    await page.waitForSelector('#mfaBody button.b.p');
    check('setup: says two-step is off', /OFF/.test(await page.textContent('#mfaBody')));
    await page.click('#mfaBody button.b.p');
    await page.waitForSelector('#mfaBody .cr-code');
    check('setup: offers a link that opens the authenticator',
      /^otpauth:/.test(await page.getAttribute('#mfaBody a[href^="otpauth:"]', 'href')));
    await shot(page, 'phone-setup');
    check('setup: shows the key to paste, grouped',
      (await page.inputValue('#mfaBody input.mono')) === 'JBSW Y3DP EHPK 3PXP JBSW Y3DP');
    await page.fill('#mfaBody .cr-code', '123456');
    await page.waitForFunction(() => /is ON/.test(document.querySelector('#mfaBody')?.textContent || ''));
    check('setup: verified, and the page says it is on', state.verifyCount === 1);
    check('setup: the owner sees the console rules', await visible(page, '#secSettings'));
    check('setup: no script errors', state.errors.length === 0);
    if (state.errors.length) console.log('     ' + state.errors.join('\n     '));
    await ctx.close();
  }

  // ── idle sign-out, and never during an upload ───────────────────────────
  {
    const ctxPage = await open(browser, 'owner', { whoami: { idleMinutes: 5 } });
    const { page, ctx, state } = ctxPage;
    await page.waitForSelector('#tab-dashboard:not([hidden])');
    await page.evaluate(() => { uploadsInFlight = 1; shLastActive = Date.now() - 6 * 60000; shIdleTick(); });
    check('idle: not signed out while an upload runs', await visible(page, '#side'));
    await page.evaluate(() => { uploadsInFlight = 0; shLastActive = Date.now() - 4.5 * 60000; shIdleTick(); });
    check('idle: warned a minute before', await visible(page, '.cr-idle'));
    await page.evaluate(() => { shLastActive = Date.now() - 6 * 60000; shIdleTick(); });
    await page.waitForSelector('#gate:not([hidden])');
    check('idle: signed out after the limit', /without use/.test(await page.textContent('#msg')));
    check('idle: the menu is gone', !(await visible(page, '#side')));
    check('idle: no script errors', state.errors.length === 0);
    if (state.errors.length) console.log('     ' + state.errors.join('\n     '));
    await ctx.close();
  }
} finally {
  await browser.close();
}

if (failed) {
  console.log(`${failed} console smoke check(s) failed`);
  process.exit(1);
}
console.log('console smoke: all checks passed');
