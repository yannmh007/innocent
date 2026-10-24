// delete-account — a viewer deletes their own account (migration 048).
//
// WHY. A person who made an account must be able to take it back: Thailand's
// PDPA (the app ships Thai) gives a right to erasure, and an app with
// accounts that offers no way out is the thing every store and every
// careful user now checks for. docs/gap_audit_2026_10.md.
//
// WHAT HAPPENS, in order — nothing is touched until every check has passed:
//   1. who: the user from their JWT (Supabase resolves it; the body is never
//      trusted for identity);
//   2. the right account: the body names the account the screen showed
//      (`expect_user`). The app signs in again just before this, and a
//      person who picks a different Google account there must not delete
//      that one by accident;
//   3. a FRESH sign-in: the JWT's newest sign-in (`amr`) is at most ten
//      minutes old. A phone left unlocked, or a session token copied off it,
//      is not enough to erase someone;
//   4. `delete_my_data()`: payments kept and anonymised, watch history kept
//      and anonymised, consents, diagnostics and the budget row deleted — or
//      refused for an admin (the owner removes admins, in the console);
//   5. the receipts' screenshots removed from the payment-proofs bucket;
//   6. the auth user deleted; devices, bookmarks and subscriptions go with
//      it (ON DELETE CASCADE).
//
// A failure at 5 or 6 leaves the data already anonymised and the account
// still there: the app says it failed, and trying again runs the same steps
// (every one of them is safe twice).
//
// Body (JSON): { confirm: 'delete', expect_user: '<user id>' }
// Header: x-install-id (optional) — history recorded on this phone before
//         sign-in, which the account claimed, is deleted with it.
// Answers: 200 { ok: true }, 400 { code: 'bad_request' },
//          401 { code: 'sign_in' }, 403 { code: 'sign_in_again' | 'admin' },
//          409 { code: 'other_account' }, 500 { code: 'failed' }.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BUCKET = 'payment-proofs';

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

// ── the rules, plain enough to test in node (tool/js/delete_account_test.mjs)

/// How recent a sign-in must be to delete an account.
const FRESH_SECONDS = 10 * 60;

/// The JWT's claims. Its signature was checked by the gateway (verify_jwt)
/// and the session by getUser below; this only reads what they vouched for.
function jwtClaims(token) {
  try {
    const part = token.split('.')[1] ?? '';
    const pad = part.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(pad + '='.repeat((4 - pad.length % 4) % 4)));
  } catch {
    return {};
  }
}

/// When this session last proved who it is: the newest `amr` entry that is
/// a sign-in. A refresh renews a token, not the proof, and is not counted.
function signedInAt(claims) {
  const amr = Array.isArray(claims && claims.amr) ? claims.amr : [];
  let newest = 0;
  for (const e of amr) {
    if (!e || typeof e.timestamp !== 'number') continue;
    if (e.method === 'token_refresh' || e.method === 'anonymous') continue;
    if (e.timestamp > newest) newest = e.timestamp;
  }
  return newest;
}

/// Why this request may not delete [userId], or null when it may.
function refusal(body, userId, claims, nowSeconds) {
  if (!body || typeof body !== 'object') return { status: 400, code: 'bad_request' };
  if (body.confirm !== 'delete') return { status: 400, code: 'bad_request' };
  if (typeof body.expect_user !== 'string' || !body.expect_user) {
    return { status: 400, code: 'bad_request' };
  }
  if (body.expect_user !== userId) return { status: 409, code: 'other_account' };
  const at = signedInAt(claims);
  if (!at || nowSeconds - at > FRESH_SECONDS || at - nowSeconds > 60) {
    return { status: 403, code: 'sign_in_again' };
  }
  return null;
}

/// The install id, as the app sends it — or nothing, if it does not look
/// like one.
function installId(raw) {
  const v = (raw ?? '').trim();
  return /^[A-Za-z0-9_-]{8,100}$/.test(v) ? v : null;
}

// ── end of the rules

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'bad_method' }, 405);
  if (!SERVICE_KEY) return json({ code: 'failed' }, 500);
  const admin = createClient(Deno.env.get('SUPABASE_URL') ?? '', SERVICE_KEY);

  // 1. who
  const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
  let userId: string | null = null;
  try {
    const { data } = await admin.auth.getUser(token);
    userId = data?.user?.id ?? null;
  } catch {
    userId = null;
  }
  if (!userId) return json({ code: 'sign_in' }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ code: 'bad_request' }, 400);
  }

  // 2 and 3. the right account, signed in just now
  const no = refusal(body, userId, jwtClaims(token), Math.floor(Date.now() / 1000));
  if (no) return json({ code: no.code }, no.status);

  // 4. the data
  const { data: out, error } = await admin.rpc('delete_my_data', {
    p_user: userId,
    p_install: installId(req.headers.get('x-install-id')),
  });
  if (error) {
    console.log(JSON.stringify({ delete_account: 'data_failed' }));
    return json({ code: 'failed' }, 500);
  }
  const result = (out ?? {}) as { refused?: string; proofs?: string[] };
  if (result.refused === 'admin') return json({ code: 'admin' }, 403);

  // 5. the screenshots. Twice, then on: the rows no longer point at them,
  // and a stuck image must not keep an account the person asked to delete.
  const proofs = (result.proofs ?? []).filter((p) => typeof p === 'string' && p);
  let left = proofs.length;
  for (let i = 0; i < 2 && left > 0; i++) {
    const { error: rmErr } = await admin.storage.from(BUCKET).remove(proofs);
    if (!rmErr) left = 0;
  }

  // 6. the account
  const { error: delErr } = await admin.auth.admin.deleteUser(userId);
  if (delErr) {
    console.log(JSON.stringify({ delete_account: 'user_failed', proofs_left: left }));
    return json({ code: 'failed' }, 500);
  }
  console.log(JSON.stringify({ delete_account: 'done', proofs: proofs.length, proofs_left: left }));
  return json({ ok: true });
});
