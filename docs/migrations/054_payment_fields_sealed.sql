-- 054 — A PAYER'S KPAY NUMBER AND TRANSACTION ID, SEALED (2026-10-30)
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. It deletes nothing and drops nothing.
--
-- WHY. Every request kept the number it was paid from (`sender_phone`) and
-- the transaction id (`reference`) as plain text. A copy of the database that
-- leaves — a leaked backup, a pasted service key, a dump taken by whoever got
-- in — carried both for every payer. From premium-request v11 (docs/edge/pii.ts)
-- a request keeps, in their place:
--
--   *_sealed   AES-256-GCM under an Edge Function secret (PII_ENC_KEY), bound
--              to its row and column. Opened only by the function, for an
--              operator past the console gate (role and MFA).
--   reference_index
--              HMAC-SHA256 of the normalised transaction id under a second
--              secret (PII_INDEX_KEY): how a reused transaction number is
--              still caught without the number being kept.
--   *_mask     what the payer sees of their own request: 09••••••789,
--              ••••••0098.
--
-- `reference` and `sender_phone` stay, empty for a sealed request, so an app
-- older than this still reads its list (without the numbers). Until the owner
-- adds the two secrets the function goes on writing them as before.

alter table public.premium_requests
  add column if not exists reference_sealed text,
  add column if not exists sender_phone_sealed text,
  add column if not exists reference_index text,
  add column if not exists reference_mask text,
  add column if not exists sender_phone_mask text;

create index if not exists premium_requests_reference_index
  on public.premium_requests (reference_index) where reference_index is not null;

-- The payer reads the masks of their own requests (the policy "own requests"
-- already limits the rows); never the sealed values or the index.
grant select (reference_mask, sender_phone_mask) on public.premium_requests to authenticated;

-- The console's views (service role only): the same columns as before, in the
-- same order, and the sealed values and masks after them. The function opens
-- the sealed ones before anything reaches the console.
create or replace view public.admin_requests as
 select r.id,
    r.status,
    r.plan_id,
    r.price_shown,
    r.message,
    r.reference,
    r.sender_phone,
    r.submitted_at,
    r.seen_at,
    r.reviewed_at,
    r.reviewed_by,
    r.note,
    r.proof_path,
    r.proof_bytes,
    r.duplicate_of,
    r.user_id,
    u.email,
    u.phone,
    coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name') as display_name,
    (( select count(*) as count
           from public.premium_requests p
          where p.user_id = r.user_id and p.status = 'approved' and p.id <> r.id))::integer as approved_before,
    ( select max(s.expires_at) as max
           from public.subscriptions s
          where s.user_id = r.user_id) as premium_until,
    r.reference_sealed,
    r.sender_phone_sealed,
    r.reference_mask,
    r.sender_phone_mask
   from public.premium_requests r
     left join auth.users u on u.id = r.user_id;

create or replace view public.pending_requests as
 select r.id,
    r.plan_id,
    r.reference,
    r.sender_phone,
    r.submitted_at,
    u.email,
    u.phone,
    r.proof_path,
    r.proof_bytes,
    r.duplicate_of,
    r.price_shown,
    r.message,
    r.seen_at,
    r.reference_mask,
    r.sender_phone_mask
   from public.premium_requests r
     left join auth.users u on u.id = r.user_id
  where r.status = 'pending'
  order by r.submitted_at;
