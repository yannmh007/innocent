// The admin gate: who may call which op of the console's edge functions.
//
// WHAT THIS GUARDS. Four functions take requests from the console — studio,
// ingest, transcode and probe-media — and each carries the same block that
// asks the auth server who the caller is, looks their role up in the
// database, and turns away anyone without the authenticator code once MFA is
// required. Four copies of a security check drift: one gets a fix and three do
// not, and the one that did not is the one somebody finds. So this fails the
// build if the four copies differ by a single byte.
//
// And DENY BY DEFAULT only means something if every op is in the map. An op
// added to a handler and forgotten in NEED is refused (safe, and noticed the
// first time anyone presses the button); an op left in NEED after its handler
// is gone is a permission nobody can see the reason for. Both are failures.
//
// The block is then RUN, against a fetch that plays the auth server and the
// database, because a gate that reads right and lets a viewer delete a title
// is the failure that matters.
//
//   node tool/js/admin_gate_test.mjs

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import * as nodeModule from 'node:module';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(ROOT, p), 'utf8');

let failed = 0;
const check = (what, ok) => {
  if (ok) console.log('ok   ' + what);
  else { failed += 1; console.log('FAIL ' + what); }
};

const BEGIN = '// ── ADMIN GATE (begin)';
const END = '// ── ADMIN GATE (end)';
const FILES = ['studio', 'ingest', 'transcode', 'probe-media'];
const src = Object.fromEntries(FILES.map((f) => [f, read(`docs/edge/${f}.ts`)]));

const gateOf = (s) => {
  const a = s.indexOf(BEGIN);
  const b = s.indexOf(END);
  return a >= 0 && b > a ? s.slice(a, b) : null;
};

// ── one gate, four copies, byte for byte ─────────────────────────────────
const gates = FILES.map((f) => gateOf(src[f]));
for (const [i, f] of FILES.entries()) {
  check(`${f}.ts carries the admin gate`, gates[i] !== null);
  check(`${f}.ts carries it once`, src[f].split(BEGIN).length === 2);
}
for (const [i, f] of FILES.entries()) {
  if (i === 0 || gates[i] === null) continue;
  check(`${f}.ts's gate is identical to studio.ts's`, gates[i] === gates[0]);
}

// The one-person list the gate replaced. Its env var is still set in the
// project, so code that read it would still work — which is the danger.
for (const f of FILES) {
  check(`${f}.ts no longer reads OPERATOR_IDS`,
    !/Deno\.env\.get\('OPERATOR_IDS'\)/.test(src[f]));
  check(`${f}.ts no longer has an operator check of its own`,
    !/function (isOperator|operatorId)\(/.test(src[f]));
}

// ── every op in NEED, and nothing in NEED that is not an op ──────────────
const ROLES = new Set(['viewer', 'uploader', 'editor', 'owner']);

function needOf(s, file) {
  const m = /const NEED: Record<string, Role> = \{([\s\S]*?)\n\};/.exec(s);
  if (!m) { check(`${file}.ts has a NEED map`, false); return {}; }
  const out = {};
  for (const [, op, role] of m[1].matchAll(/(\w+): '(\w+)'/g)) out[op] = role;
  return out;
}

const sameSet = (a, b) =>
  a.size === b.size && [...a].every((x) => b.has(x));
const show = (s) => [...s].sort().join(', ');

{
  const s = src.studio;
  const need = needOf(s, 'studio');
  for (const [op, role] of Object.entries(need)) {
    check(`studio: ${op} needs a real role (${role})`, ROLES.has(role));
  }
  // The ops handleOp answers. `publish` is the old page's name for create,
  // handled in the same branch and kept in NEED at a higher role.
  const body = s.slice(s.indexOf('async function handleOp('));
  const handled = new Set(
    [...body.matchAll(/body\.op === '(\w+)'/g)].map((m) => m[1]));
  const inNeed = new Set(Object.keys(need));
  check(`studio: every op handled is in NEED and the reverse ` +
    `(handled: ${show(handled)}; NEED: ${show(inNeed)})`,
    sameSet(handled, inNeed));

  const setOf = (name) => {
    const m = new RegExp(`const ${name} = new Set\\(\\[([\\s\\S]*?)\\]\\)`).exec(s);
    return new Set(m ? [...m[1].matchAll(/'(\w+)'/g)].map((x) => x[1]) : []);
  };
  const reads = setOf('READS');
  const dangerous = setOf('DANGEROUS');
  check('studio: READS names only real ops',
    [...reads].every((op) => inNeed.has(op)));
  check('studio: DANGEROUS names only real ops',
    dangerous.size > 0 && [...dangerous].every((op) => inNeed.has(op)));
  // A dangerous op that was also a "read" would never reach the audit log.
  check('studio: nothing dangerous is filed as a read',
    [...dangerous].every((op) => !reads.has(op)));
  check('studio: deleting a title is the owner\'s', need.deleteTitle === 'owner');
  check('studio: handing out roles is the owner\'s',
    need.adminSave === 'owner' && need.adminRemove === 'owner' &&
    need.settingsSave === 'owner');
  check('studio: publishing is an editor\'s',
    need.publish === 'editor' && need.approve === 'editor');
  check('studio: deleting a title needs a fresh code', dangerous.has('deleteTitle'));

  // THE REVIEW QUEUE. Approving puts a title in front of paying viewers.
  check('studio: approving, sending back, rejecting and taking down are an editor\'s',
    need.reviewApprove === 'editor' && need.reviewSendBack === 'editor' &&
    need.reviewReject === 'editor' && need.unpublish === 'editor');
  check('studio: an uploader may send their own draft for review',
    need.reviewSubmit === 'uploader' &&
    /op === 'reviewSubmit' \|\| op === 'reviewReopen'/.test(s));
  check('studio: a new title is always a draft, whatever the page asks',
    /const wantPublished = false;/.test(s));
  check('studio: save cannot publish around the review',
    /p_action: publishTo \? 'approve' : 'unpublish'/.test(s) &&
    !/upd\.published = /.test(s));
  check('studio: every decision goes through review_decide',
    /rpc\('review_decide'/.test(s) &&
    !/from\('titles'\)\.update\(\{[^}]*published: true/.test(s));
  check('studio: a preview link lives ten minutes',
    /const seconds = 600;/.test(s));

  // The order of the checks in the handler. Role before step-up before the
  // uploader's ownership rule, and all of them before handleOp runs.
  const serve = s.slice(s.indexOf('Deno.serve('), s.indexOf('async function handleOp('));
  const at = (re) => serve.search(re);
  const order = [
    at(/await whoIsAsking\(req\)/),
    at(/const need = NEED\[op\]/),
    at(/if \(!mayDo\(who, need\)\)/),
    at(/DANGEROUS\.has\(op\) && !freshEnough\(who\)/),
    at(/await uploaderRefusal\(op, body, who\)/),
    at(/await handleOp\(req, body, who\)/),
    at(/await audit\(who, 'studio'/),
  ];
  check('studio: who → NEED → role → step-up → ownership → op → audit',
    order.every((x) => x >= 0) && order.every((x, i) => i === 0 || x > order[i - 1]));
  check('studio: an unknown op is refused, not run',
    /if \(!need\) return json\(\{ error: 'unknown_op' \}/.test(serve));
  check('studio: a new title records who made it', /created_by: who\.id/.test(s));
}

{
  const s = src.ingest;
  const need = needOf(s, 'ingest');
  const consoleBody = s.slice(s.indexOf('async function consoleOp('));
  const handled = new Set(
    [...consoleBody.matchAll(/op === '(\w+)'/g)].map((m) => m[1]));
  const inNeed = new Set(Object.keys(need));
  check(`ingest: every console op is in NEED and the reverse ` +
    `(handled: ${show(handled)}; NEED: ${show(inNeed)})`,
    sameSet(handled, inNeed));
  // The runner's ops have no person behind them and answer to the runner's
  // secret — each one, before it does anything.
  const serve = s.slice(s.indexOf('Deno.serve('), s.indexOf('async function consoleOp('));
  for (const op of ['claim', 'done', 'defer', 'release']) {
    check(`ingest: runner op ${op} checks the runner's secret first`,
      new RegExp(`if \\(op === '${op}'\\) \\{\\s*\\n[^\\n]*\\n\\s*if \\(!sameSecret\\(given, RUNNER_SECRET\\)\\)`)
        .test(serve));
    check(`ingest: runner op ${op} is not in NEED`, !inNeed.has(op));
  }
  check('ingest: the gate runs before consoleOp',
    serve.search(/await whoIsAsking\(req\)/) >= 0 &&
    serve.search(/await whoIsAsking\(req\)/) < serve.search(/await consoleOp\(/));
  check('ingest: role then ownership then the op',
    serve.search(/mayDo\(who, need\)/) < serve.search(/uploaderRefusal\(op, body, who\)/) &&
    serve.search(/uploaderRefusal\(op, body, who\)/) < serve.search(/await consoleOp\(/));
  check('ingest: writes are audited', /await audit\(who, 'ingest'/.test(serve));
}

{
  const s = src.transcode;
  const need = needOf(s, 'transcode');
  check('transcode: NEED is health and queue',
    sameSet(new Set(Object.keys(need)), new Set(['health', 'queue'])));
  check('transcode: queue answers only behind the gate',
    /if \(op === 'queue' && who\)/.test(s));
  check('transcode: health answers only behind the gate',
    /if \(op === 'health' && who\)/.test(s));
  check('transcode: the runner\'s claim still checks its secret',
    /if \(op === 'claim'\) \{\s*\n[^\n]*\n\s*if \(!sameSecret\(given, RUNNER_SECRET\)\)/.test(s));
}

{
  const s = src['probe-media'];
  const serve = s.slice(s.indexOf('Deno.serve('));
  check('probe-media: the gate runs before the body is read',
    serve.search(/await whoIsAsking\(req\)/) >= 0 &&
    serve.search(/await whoIsAsking\(req\)/) < serve.search(/await req\.json\(\)/));
  check('probe-media: it is an editor\'s', /probe: 'editor'/.test(s));
}

// ── and the gate itself, run ─────────────────────────────────────────────
const strip = nodeModule.stripTypeScriptTypes;
if (typeof strip !== 'function') {
  // A check that vanishes without a word is worse than none: the summary
  // would still read "all passed".
  console.log('SKIP the gate was not RUN — this node (' + process.version +
    ') cannot strip TypeScript; the static checks above still ran');
} else {
  process.removeAllListeners('warning');
  const js = strip(gates[0], { mode: 'strip' });
  const USER = '6c679480-3387-4442-ad3d-4423b8aceb71';
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const jwt = (claims) => `Bearer x.${b64(claims)}.sig`;

  // Plays the auth server and the database. `admin` is the row
  // admin_resolve answers with, or null for "not an admin".
  const world = { userOk: true, admin: null, logged: [] };
  const fakeFetch = async (url, init = {}) => {
    const u = String(url);
    const ok = (body) => ({ ok: true, status: 200, json: async () => body });
    if (u.endsWith('/auth/v1/user')) {
      return world.userOk ? ok({ id: USER }) : { ok: false, status: 401, json: async () => ({}) };
    }
    if (u.endsWith('/rest/v1/rpc/admin_resolve')) {
      return ok(world.admin ? [world.admin] : []);
    }
    if (u.endsWith('/rest/v1/rpc/admin_log')) {
      world.logged.push(JSON.parse(init.body));
      return ok(null);
    }
    throw new Error('unexpected fetch ' + u);
  };
  const make = new Function('SUPABASE_URL', 'ANON_KEY', 'SERVICE_KEY', 'fetch',
    js + '\nreturn { whoIsAsking, mayDo, freshEnough, auditDetail, audit, RANK };');
  const g = make('https://sb.example', 'anon', 'service', fakeFetch);

  const req = (auth) => new Request('https://x/', {
    method: 'POST', headers: auth ? { Authorization: auth } : {},
  });
  const row = (role, extra = {}) => ({
    admin_id: 'a1', email: 'boss@example.com', role,
    require_mfa: false, stepup_minutes: 10, idle_minutes: 30, ...extra,
  });
  const now = Math.floor(Date.now() / 1000);

  let r = await g.whoIsAsking(req(null));
  check('no token → not_signed_in', r.error === 'not_signed_in' && r.status === 401);

  world.userOk = false;
  r = await g.whoIsAsking(req(jwt({ aal: 'aal1' })));
  check('a token the auth server refuses → not_signed_in', r.error === 'not_signed_in');
  world.userOk = true;

  world.admin = null;
  r = await g.whoIsAsking(req(jwt({ aal: 'aal1' })));
  check('a real user who is not an admin → not_an_admin, 403',
    r.error === 'not_an_admin' && r.status === 403);

  world.admin = row('superuser');
  r = await g.whoIsAsking(req(jwt({ aal: 'aal1' })));
  check('a role the code does not know → not_an_admin', r.error === 'not_an_admin');

  world.admin = row('editor');
  r = await g.whoIsAsking(req(jwt({ aal: 'aal1', session_id: 's1' })));
  check('an editor, MFA not yet required → let in', r.role === 'editor' && r.id === USER);
  check('and the session is read from the token', r.session === 's1');

  world.admin = row('editor', { require_mfa: true });
  r = await g.whoIsAsking(req(jwt({ aal: 'aal1' })));
  check('MFA required and no code given → mfa_required',
    r.error === 'mfa_required' && r.status === 403);
  r = await g.whoIsAsking(req('Bearer garbage'));
  check('an unreadable token counts as no code', r.error === 'mfa_required');

  r = await g.whoIsAsking(req(jwt({
    aal: 'aal2', amr: [{ method: 'oauth', timestamp: now - 3600 },
      { method: 'totp', timestamp: now - 60 }],
  })));
  check('MFA required and a code given → let in', r.role === 'editor' && r.aal === 'aal2');
  check('the code\'s time is read from amr', r.totpAt === now - 60);
  check('a code a minute old is fresh', g.freshEnough(r) === true);

  r = await g.whoIsAsking(req(jwt({
    aal: 'aal2', amr: [{ method: 'totp', timestamp: now - 3600 }],
  })));
  check('a code an hour old is not fresh enough to delete with',
    g.freshEnough(r) === false);

  world.admin = row('owner');
  r = await g.whoIsAsking(req(jwt({ aal: 'aal1' })));
  check('before MFA is required, nothing asks for a fresh code',
    g.freshEnough(r) === true);

  const as = (role) => ({ role });
  check('a viewer may read', g.mayDo(as('viewer'), 'viewer'));
  check('a viewer may not upload', !g.mayDo(as('viewer'), 'uploader'));
  check('an uploader may not publish', !g.mayDo(as('uploader'), 'editor'));
  check('an editor may not hand out roles', !g.mayDo(as('editor'), 'owner'));
  check('an owner may do anything', g.mayDo(as('owner'), 'owner') &&
    g.mayDo(as('owner'), 'viewer'));

  const d = g.auditDetail({
    op: 'save', id: 't1', uploadUrl: 'https://secret', token: 'x',
    parts: [1, 2], patch: { title: 'A', poster_url: 'u' }, list: [1, 2, 3],
    note: 'y'.repeat(300),
  });
  check('the audit line keeps what was done', d.id === 't1' && d.patch.title === 'A');
  check('and drops links, tokens and part lists',
    !('uploadUrl' in d) && !('token' in d) && !('parts' in d) &&
    !('poster_url' in d.patch) && !('op' in d));
  check('and counts arrays rather than copying them', d.list === '[3]');
  check('and cuts long text', d.note.length <= 121);

  await g.audit({ id: USER }, 'studio', 'deleteTitle', 't1', { id: 't1' }, false, 'boom');
  const line = world.logged.at(-1);
  check('an audit line names who, what, and whether it worked',
    line.p_actor === USER && line.p_action === 'deleteTitle' &&
    line.p_ok === false && line.p_error === 'boom');

  const broken = make('https://sb.example', 'anon', 'service',
    async () => { throw new Error('network'); });
  let threw = false;
  try { await broken.audit({ id: USER }, 'studio', 'save', null, null, true, null); }
  catch { threw = true; }
  check('a failed audit write does not fail the change it records', !threw);
}

if (failed) {
  console.log(`${failed} admin gate check(s) failed`);
  process.exit(1);
}
console.log('admin gate: all checks passed');
