// premium-request — a viewer files a payment, proved by the receipt's
// screenshot (migration 040).
//
// WHY A FUNCTION AND NOT AN INSERT FROM THE APP. The old flow inserted a
// premium_requests row straight from the app with a transaction id the viewer
// had retyped. A screenshot cannot go that way: it has to be checked (is it an
// image at all, is it small enough), stored where only the operator can see
// it, compared with every receipt already filed (one screenshot, two claims
// is the fraud this catches), and announced to the owner — and none of that
// may be left to the app, which anyone can modify.
//
// What it does, in order:
//   1. who: the user from their JWT (Supabase resolves it; the body is never
//      trusted for identity);
//   2. what: a plan that has a price in payment_instructions;
//   3. limits: at most 3 pending and 6 filed per day per account;
//   4. proof: a PNG, JPEG or WebP up to 5 MB (magic bytes, not the name), or
//      a transaction id, or both;
//   5. the same screenshot already filed BY THIS ACCOUNT and still pending →
//      that request is returned again (a retry after a timeout files nothing
//      twice); filed by ANOTHER account → filed, marked duplicate_of, and the
//      owner told in red;
//   6. stored in the private `payment-proofs` bucket under the user's id;
//   7. the row inserted (the owner trigger accepts the user id from the
//      service role only);
//   8. the owner's Telegram gets the screenshot with the plan, the price the
//      viewer saw, the sending number and the id. Best effort: a Telegram
//      outage never loses a request.
//
// Body (JSON): { plan_id, reference?, sender_phone?, price_shown?, message?,
//                image_b64?, image_mime? }
//          or, from the console: { op, ... } — see THE CONSOLE'S PAYMENT INBOX
//
// `message` (migration 042): the payer's own note, up to 500 characters —
// "paid from my sister's account", "sent it at 9 pm". It goes to the owner's
// Telegram with the screenshot and into the console's inbox.
// Answers: 200 { request }, 400 { code }, 401 { code: 'sign_in' },
//          429 { code: 'too_many' }, 500 { code: 'failed' }.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SERVICE_KEY = Deno.env.get('SB_SERVICE_KEY') ??
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BOT_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const TG_CHATS = (Deno.env.get('TELEGRAM_CHAT_IDS') ?? '')
  .split(',').map((s) => s.trim()).filter(Boolean);

const BUCKET = 'payment-proofs';
const MAX_BYTES = 5 * 1024 * 1024;
const MAX_PENDING = 3;
const MAX_PER_DAY = 6;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// The image's real type, from its first bytes. A name or a declared MIME
/// type is whatever the sender says; the bytes are what will be shown.
function sniff(b: Uint8Array): { mime: string; ext: string } | null {
  if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    return { mime: 'image/png', ext: 'png' };
  }
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) {
    return { mime: 'image/jpeg', ext: 'jpg' };
  }
  if (b.length > 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) {
    return { mime: 'image/webp', ext: 'webp' };
  }
  return null;
}

function fromBase64(s: string): Uint8Array | null {
  try {
    const bin = atob(s.replace(/^data:[^,]*,/, '').replace(/\s/g, ''));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

async function sha256Hex(b: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', b));
  return Array.from(d).map((x) => x.toString(16).padStart(2, '0')).join('');
}

function clean(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim().slice(0, max);
  return t.length ? t : null;
}

/// The owner's Telegram: the screenshot itself, with what to check it
/// against. Best effort.
async function tellOwner(opts: {
  image: Uint8Array | null;
  mime: string;
  caption: string;
}): Promise<void> {
  if (!BOT_TOKEN || !TG_CHATS.length) return;
  for (const chat of TG_CHATS) {
    try {
      if (opts.image) {
        const form = new FormData();
        form.append('chat_id', chat);
        form.append('caption', opts.caption.slice(0, 1000));
        form.append('photo', new Blob([opts.image], { type: opts.mime }), 'receipt');
        await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto`, {
          method: 'POST',
          body: form,
        });
      } else {
        await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ chat_id: chat, text: opts.caption }),
        });
      }
    } catch {
      // Best effort: the request is filed whatever Telegram does.
    }
  }
}

const SELECT = 'id,plan_id,reference,sender_phone,status,note,submitted_at,message';

const RANK: Record<string, number> = { viewer: 1, uploader: 2, editor: 3, owner: 4 };

function jwtClaims(token: string): Record<string, unknown> {
  try {
    const part = token.split('.')[1] ?? '';
    const pad = part.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(pad + '='.repeat((4 - pad.length % 4) % 4)));
  } catch {
    return {};
  }
}

// ── THE CONSOLE'S PAYMENT INBOX (migration 042) ─────────────────────────────
//
// Everything the console's Requests page does goes through here, behind one
// gate: an editor or owner (the role that approves payments in studio.ts),
// with an authenticator code when that admin's row requires MFA. It lives in
// this function, beside the code that files a request, so the two halves of
// one feature cannot drift apart.
//
//   { op: 'pulse' }               → { pending, unseen, newest }
//   { op: 'inbox', status }       → { requests, counts }   (pending|approved|rejected|all)
//   { op: 'seen', ids }           → marks those still unseen as seen
//   { op: 'proofs', ids? }        → { urls: { id: signedUrl } } for 10 minutes
//   { op: 'approve', id, days, note? }
//   { op: 'reject', id, note }    → the note is what the payer's app shows
//
// Approve and reject are written to admin_audit, as every console write is.

type Gate = { id: string; email: string; role: string };

async function consoleGate(
  admin: ReturnType<typeof createClient>,
  userId: string,
  token: string,
): Promise<Gate | Response> {
  const { data: rows, error } = await admin.rpc('admin_resolve', { p_user: userId });
  const row = (Array.isArray(rows) ? rows[0] : rows) as Record<string, unknown> | null;
  const role = String(row?.role ?? '');
  if (error || !row || (RANK[role] ?? 0) < RANK.editor) {
    return json({ error: 'not_an_admin' }, 403);
  }
  if (row.require_mfa === true && jwtClaims(token).aal !== 'aal2') {
    return json({ error: 'mfa_required' }, 403);
  }
  return { id: userId, email: String(row.email ?? ''), role };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function idList(v: unknown, max: number): string[] {
  return (Array.isArray(v) ? v : []).map(String).filter((x) => UUID.test(x)).slice(0, max);
}

async function audit(
  admin: ReturnType<typeof createClient>,
  who: Gate, action: string, target: string, detail: unknown, ok: boolean, err: string | null,
): Promise<void> {
  try {
    await admin.from('admin_audit').insert({
      actor: who.id, actor_email: who.email, actor_role: who.role,
      fn: 'premium-request', action, target, detail, ok, error: err,
    });
  } catch {
    // A failed audit write never fails the decision it records.
  }
}

async function consoleOp(
  admin: ReturnType<typeof createClient>,
  who: Gate,
  body: Record<string, unknown>,
): Promise<Response> {
  const op = String(body.op);

  if (op === 'pulse') {
    const [p, u, n] = await Promise.all([
      admin.from('premium_requests').select('id', { count: 'exact', head: true })
        .eq('status', 'pending'),
      admin.from('premium_requests').select('id', { count: 'exact', head: true })
        .eq('status', 'pending').is('seen_at', null),
      admin.from('premium_requests').select('id,submitted_at,plan_id,price_shown')
        .eq('status', 'pending').is('seen_at', null)
        .order('submitted_at', { ascending: false }).limit(1),
    ]);
    return json({ pending: p.count ?? 0, unseen: u.count ?? 0,
      newest: (n.data ?? [])[0] ?? null });
  }

  if (op === 'inbox') {
    const status = String(body.status ?? 'pending');
    // Waiting: oldest first, as a queue. Decided: the latest decision first.
    const waiting = status === 'pending';
    const decided = status === 'approved' || status === 'rejected';
    const base = admin.from('admin_requests').select('*');
    const filtered = waiting || decided ? base.eq('status', status) : base;
    const { data, error } = await filtered
      .order(decided ? 'reviewed_at' : 'submitted_at', { ascending: waiting })
      .limit(waiting ? 200 : 60);
    if (error) return json({ error: 'inbox_failed', detail: error.message }, 500);
    const count = async (st: string) => (await admin.from('premium_requests')
      .select('id', { count: 'exact', head: true }).eq('status', st)).count ?? 0;
    const [pending, approved, rejected] = await Promise.all(
      [count('pending'), count('approved'), count('rejected')]);
    return json({ requests: data ?? [], counts: { pending, approved, rejected } });
  }

  if (op === 'seen') {
    const ids = idList(body.ids, 200);
    if (ids.length) {
      await admin.from('premium_requests')
        .update({ seen_at: new Date().toISOString() })
        .in('id', ids).is('seen_at', null);
    }
    return json({ ok: true });
  }

  if (op === 'proofs') {
    const ids = Array.isArray(body.ids) ? idList(body.ids, 60) : null;
    let q = admin.from('premium_requests')
      .select('id, proof_path').not('proof_path', 'is', null);
    q = ids ? q.in('id', ids) : q.eq('status', 'pending');
    const { data } = await q;
    const urls: Record<string, string> = {};
    for (const r of data ?? []) {
      const { data: signed } = await admin.storage.from(BUCKET)
        .createSignedUrl(String(r.proof_path), 600);
      if (signed?.signedUrl) urls[String(r.id)] = signed.signedUrl;
    }
    return json({ urls });
  }

  if (op === 'approve' || op === 'reject') {
    const id = String(body.id ?? '');
    if (!UUID.test(id)) return json({ error: 'no_id' }, 400);
    const note = clean(body.note, 300);
    let res: Response;
    if (op === 'approve') {
      const days = Math.max(1, Math.min(Math.floor(Number(body.days ?? 365)) || 365, 3650));
      const { data: said, error } = await admin
        .rpc('approve_request', { p_request_id: id, p_days: days });
      if (error) res = json({ error: 'approve_failed', detail: error.message }, 500);
      else if (typeof said === 'string' && !said.startsWith('APPROVED')) {
        res = json({ error: 'not_pending', detail: said }, 409);
      } else {
        await admin.from('premium_requests')
          .update({ reviewed_by: who.email, ...(note ? { note } : {}) }).eq('id', id);
        res = json({ ok: true, id, days });
      }
      await audit(admin, who, 'approve', id, { days, note }, res.status < 400,
        res.status < 400 ? null : String(res.status));
    } else {
      const { data: said, error } = await admin.rpc('reject_request', {
        p_request_id: id, p_note: note ?? 'Not approved',
      });
      if (error) res = json({ error: 'reject_failed', detail: error.message }, 500);
      else if (typeof said === 'string' && said !== 'REJECTED') {
        res = json({ error: 'not_pending', detail: said }, 409);
      } else {
        await admin.from('premium_requests').update({ reviewed_by: who.email }).eq('id', id);
        res = json({ ok: true, id });
      }
      await audit(admin, who, 'reject', id, { note }, res.status < 400,
        res.status < 400 ? null : String(res.status));
    }
    return res;
  }

  return json({ error: 'unknown_op' }, 400);
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ code: 'bad_method' }, 405);
  if (!SERVICE_KEY) return json({ code: 'failed' }, 500);
  const admin = createClient(Deno.env.get('SUPABASE_URL') ?? '', SERVICE_KEY);

  // 1. who
  const token = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
  let user: { id: string; phone?: string; email?: string } | null = null;
  try {
    const { data } = await admin.auth.getUser(token);
    user = data?.user ?? null;
  } catch {
    user = null;
  }
  if (!user) return json({ code: 'sign_in' }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ code: 'bad_request' }, 400);
  }

  // The console, not a viewer filing a request.
  if (typeof body.op === 'string') {
    const gate = await consoleGate(admin, user.id, token);
    if (gate instanceof Response) return gate;
    return consoleOp(admin, gate, body);
  }

  // 2. what
  const planId = clean(body.plan_id, 40);
  if (!planId) return json({ code: 'bad_plan' }, 400);
  const { data: pay } = await admin.from('payment_instructions')
    .select('prices').eq('id', 1).maybeSingle();
  const prices = (pay?.prices ?? {}) as Record<string, string>;
  if (!(planId in prices)) return json({ code: 'bad_plan' }, 400);

  // 4. proof (before the limits, so a malformed body costs no lookups)
  const reference = clean(body.reference, 80);
  const senderPhone = clean(body.sender_phone, 30);
  const priceShown = clean(body.price_shown, 40) ?? prices[planId] ?? null;
  const message = clean(body.message, 500);
  let image: Uint8Array | null = null;
  let kind: { mime: string; ext: string } | null = null;
  if (typeof body.image_b64 === 'string' && body.image_b64.length) {
    // base64 is 4/3 of the bytes: refuse before decoding something huge.
    if (body.image_b64.length > Math.ceil(MAX_BYTES * 4 / 3) + 64) {
      return json({ code: 'too_big' }, 400);
    }
    image = fromBase64(body.image_b64);
    if (!image || image.length === 0) return json({ code: 'bad_image' }, 400);
    if (image.length > MAX_BYTES) return json({ code: 'too_big' }, 400);
    kind = sniff(image);
    if (!kind) return json({ code: 'bad_image' }, 400);
  }
  if (!image && !reference) return json({ code: 'no_proof' }, 400);

  const sha = image ? await sha256Hex(image) : null;

  // 5a. the same screenshot, this account, still pending: a retry.
  if (sha) {
    const { data: mine } = await admin.from('premium_requests').select(SELECT)
      .eq('user_id', user.id).eq('proof_sha256', sha).eq('status', 'pending')
      .limit(1).maybeSingle();
    if (mine) return json({ request: mine, again: true }, 200);
  }

  // 3. limits
  const since = new Date(Date.now() - 86400_000).toISOString();
  const { data: recent } = await admin.from('premium_requests')
    .select('status, submitted_at').eq('user_id', user.id).gte('submitted_at', since);
  const pending = (recent ?? []).filter((r) => r.status === 'pending').length;
  if (pending >= MAX_PENDING || (recent ?? []).length >= MAX_PER_DAY) {
    return json({ code: 'too_many' }, 429);
  }

  // 5b. the same screenshot, another request: filed, but flagged.
  let duplicateOf: string | null = null;
  if (sha) {
    const { data: other } = await admin.from('premium_requests').select('id')
      .eq('proof_sha256', sha).order('submitted_at').limit(1).maybeSingle();
    duplicateOf = other?.id ?? null;
  }

  // 6. stored
  const id = crypto.randomUUID();
  let proofPath: string | null = null;
  if (image && kind) {
    proofPath = `${user.id}/${id}.${kind.ext}`;
    const { error: upErr } = await admin.storage.from(BUCKET)
      .upload(proofPath, image, { contentType: kind.mime, upsert: false });
    if (upErr) {
      console.log(JSON.stringify({ upload_failed: upErr.message }));
      return json({ code: 'failed' }, 500);
    }
  }

  // 7. filed
  const { data: row, error: insErr } = await admin.from('premium_requests').insert({
    id,
    user_id: user.id,
    plan_id: planId,
    reference,
    sender_phone: senderPhone,
    proof_path: proofPath,
    proof_sha256: sha,
    proof_bytes: image?.length ?? null,
    duplicate_of: duplicateOf,
    price_shown: priceShown,
    message,
  }).select(SELECT).single();
  if (insErr || !row) {
    console.log(JSON.stringify({ insert_failed: insErr?.message }));
    // The screenshot without a row is an orphan; take it back.
    if (proofPath) await admin.storage.from(BUCKET).remove([proofPath]);
    return json({ code: 'failed' }, 500);
  }

  // 8. told
  const who = user.phone || user.email || user.id;
  const lines = [
    duplicateOf ? '⚠️ THIS SCREENSHOT WAS ALREADY USED (request ' + duplicateOf.slice(0, 8) + ')' : null,
    `💳 Premium request · ${planId}${priceShown ? ' · ' + priceShown : ''}`,
    `from ${who}`,
    senderPhone ? `paid from ${senderPhone}` : null,
    reference ? `transaction ${reference}` : null,
    image ? null : 'no screenshot',
    message ? `💬 "${message}"` : null,
    `id ${id.slice(0, 8)} — approve in the console, Requests`,
  ].filter(Boolean);
  await tellOwner({ image, mime: kind?.mime ?? 'image/png', caption: lines.join('\n') });

  return json({ request: row }, 200);
});
