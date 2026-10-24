// The rules of "delete my account", from the edge function itself
// (docs/edge/delete-account.ts), and the shape of the SQL it calls
// (docs/migrations/048_delete_my_account.sql).
//
// WHAT THIS GUARDS. Deleting an account is the one request this server
// cannot take back. Three things must hold before anything is touched: the
// account is the one the screen showed, the person proved who they are a
// moment ago, and the body says "delete" on purpose. And the SQL must keep
// the books: payments anonymised, never deleted.
//
//   node tool/js/delete_account_test.mjs
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
let failures = 0;
let checks = 0;
const check = (label, ok) => {
  checks++;
  console.log((ok ? 'ok   ' : 'FAIL ') + label);
  if (!ok) failures++;
};

const edge = readFileSync(join(ROOT, 'docs/edge/delete-account.ts'), 'utf8');
const from = edge.indexOf('// ── the rules');
const to = edge.indexOf('// ── end of the rules');
check('delete-account has its rules between the markers', from > 0 && to > from);
const rules = await import('data:text/javascript,' + encodeURIComponent(
  edge.slice(from, to) + '\nexport { FRESH_SECONDS, jwtClaims, signedInAt, refusal, installId };'));

const b64url = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (claims) => `${b64url({ alg: 'HS256' })}.${b64url(claims)}.sig`;
const USER = '6c679480-3387-4442-ad3d-4423b8aceb71';
const now = 1_800_000_000;
const ok = { confirm: 'delete', expect_user: USER };
const fresh = { sub: USER, amr: [{ method: 'oauth', timestamp: now - 120 }] };

// ── reading the token
check('claims are read from the token', rules.jwtClaims(jwt(fresh)).sub === USER);
check('a malformed token reads as no claims', Object.keys(rules.jwtClaims('nope')).length === 0);
check('the sign-in time is the newest sign-in', rules.signedInAt({
  amr: [{ method: 'oauth', timestamp: 100 }, { method: 'otp', timestamp: 300 }] }) === 300);
check('a refresh is not a sign-in', rules.signedInAt({
  amr: [{ method: 'token_refresh', timestamp: 900 }, { method: 'oauth', timestamp: 100 }] }) === 100);
check('no amr, no sign-in time', rules.signedInAt({}) === 0);

// ── who may delete what
check('the right account, signed in two minutes ago: allowed',
  rules.refusal(ok, USER, fresh, now) === null);
check('signed in eleven minutes ago: sign in again',
  rules.refusal(ok, USER, { amr: [{ method: 'oauth', timestamp: now - 11 * 60 }] }, now)?.code === 'sign_in_again');
check('exactly ten minutes is still fresh',
  rules.refusal(ok, USER, { amr: [{ method: 'oauth', timestamp: now - rules.FRESH_SECONDS }] }, now) === null);
check('only refreshed, never signed in: sign in again',
  rules.refusal(ok, USER, { amr: [{ method: 'token_refresh', timestamp: now }] }, now)?.code === 'sign_in_again');
check('a sign-in from the future (a clock trick): sign in again',
  rules.refusal(ok, USER, { amr: [{ method: 'oauth', timestamp: now + 3600 }] }, now)?.code === 'sign_in_again');
check('another account than the screen showed: refused, 409',
  rules.refusal({ ...ok, expect_user: '00000000-0000-4000-8000-000000000001' }, USER, fresh, now)?.status === 409);
check('no "delete" in the body: refused',
  rules.refusal({ expect_user: USER }, USER, fresh, now)?.code === 'bad_request');
check('"yes" is not "delete"',
  rules.refusal({ confirm: 'yes', expect_user: USER }, USER, fresh, now)?.code === 'bad_request');
check('no expected account: refused',
  rules.refusal({ confirm: 'delete' }, USER, fresh, now)?.code === 'bad_request');
check('no body: refused', rules.refusal(null, USER, fresh, now)?.code === 'bad_request');

// ── the install id
check('an install id as the app makes it is taken',
  rules.installId('Zm9vYmFyYmF6cXV4MTIzNA') === 'Zm9vYmFyYmF6cXV4MTIzNA');
check('anything else is not', rules.installId("x'; drop table events; --") === null
  && rules.installId('') === null && rules.installId(null) === null);

// ── the SQL keeps the books
const sql = readFileSync(join(ROOT, 'docs/migrations/048_delete_my_account.sql'), 'utf8')
  .replace(/--[^\n]*/g, '');
check('payments survive the account (ON DELETE SET NULL)',
  /references auth\.users \(id\) on delete set null/.test(sql));
check('payments are anonymised, not deleted',
  /update public\.premium_requests[\s\S]*?user_id = null/.test(sql)
  && !/delete from public\.premium_requests/.test(sql));
check('the screenshot, phone number and message go with the person',
  /sender_phone = null/.test(sql) && /message = null/.test(sql) && /proof_path = null/.test(sql));
check('watch history is anonymised, not deleted',
  /update public\.events/.test(sql) && /update public\.title_views/.test(sql)
  && !/delete from public\.events/.test(sql) && !/delete from public\.title_views/.test(sql));
check('an admin is refused', /from public\.admins a where a\.user_id = p_user[\s\S]*?'refused', 'admin'/.test(sql));
check('the function runs with an empty search_path',
  /security definer\s+set search_path = ''/.test(sql));
check('only the service role may call it',
  /revoke all on function public\.delete_my_data\(uuid, text\) from public, anon, authenticated/.test(sql)
  && /grant execute on function public\.delete_my_data\(uuid, text\) to service_role/.test(sql));

if (failures) {
  console.log(`${failures} delete-account check(s) failed`);
  process.exit(1);
}
console.log(`=== ${checks} check(s) on deleting an account: who, how fresh, what is kept ===`);
