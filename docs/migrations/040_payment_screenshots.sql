-- 040 — a payment is proved with the receipt's screenshot
--
-- Owner request (2026-10-05): "a KPay transaction id cannot be copied in one
-- go, and most users do not know what it is." Both true. The KBZPay receipt
-- shows a long Transaction No. that the app does not let you select; the
-- form asked people to retype it from one app into another, digit by digit,
-- right after sending money. What people in Myanmar actually do — with every
-- Facebook shop, every Telegram seller — is send a screenshot of the
-- receipt (ငွေလွှဲပြေစာ). So the screenshot is now the proof, and the
-- transaction id is optional.
--
-- (The automatic answer is KBZPay's merchant payment gateway, where the
-- payment confirms itself; it needs a registered business and a merchant
-- contract. docs/payments.md.)
--
-- The screenshot is stored PRIVATELY and only by the server: the app sends
-- it to the `premium-request` edge function, which checks it is an image,
-- hashes it, notices a screenshot already used for another request, keeps a
-- per-account limit, stores it, files the request and sends it to the
-- owner's Telegram. Nobody but the service role can read the bucket; the
-- console shows it through a short-lived signed URL.

-- ---------------------------------------------------------------------------
-- 1. The request carries its proof
-- ---------------------------------------------------------------------------
alter table public.premium_requests alter column reference drop not null;
alter table public.premium_requests
  add column if not exists proof_path   text,
  add column if not exists proof_sha256 text,
  add column if not exists proof_bytes  int,
  -- The earlier request that used the very same screenshot, if any. Set by
  -- the server, shown to the operator in red: one receipt, two claims.
  add column if not exists duplicate_of uuid references public.premium_requests(id),
  -- What the request was for, as the app showed it ("10,500 MMK"), so the
  -- operator compares the receipt with the price the viewer saw.
  add column if not exists price_shown  text;

create index if not exists premium_requests_sha
  on public.premium_requests (proof_sha256) where proof_sha256 is not null;

-- A request must carry SOMETHING to check: a screenshot or a transaction id.
do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'premium_requests_has_proof') then
    alter table public.premium_requests add constraint premium_requests_has_proof
      check (proof_path is not null or coalesce(btrim(reference), '') <> '');
  end if;
end $$;

-- The viewer may see that their request has a screenshot, not where it is.
grant select (id, plan_id, reference, sender_phone, status, note, submitted_at)
  on public.premium_requests to authenticated;

-- The owner trigger (migration 010) set user_id from the JWT only, so a row
-- filed by the edge function (service role, no auth.uid()) had no owner.
-- The service role — and only it — may now name the owner it resolved from
-- the viewer's JWT; everybody else still gets auth.uid(), whatever they send.
create or replace function public.set_request_owner()
returns trigger language plpgsql security definer
set search_path = public as $fn$
begin
  new.user_id := coalesce(auth.uid(),
                          case when auth.role() = 'service_role' then new.user_id end);
  new.status := 'pending';
  return new;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. The private bucket
-- ---------------------------------------------------------------------------
-- 5 MB is four times a full-resolution phone screenshot; the app sends far
-- less. No policies on storage.objects for it: only the service role (the
-- edge function, the console) reads or writes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 5242880,
        array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- 3. The operator's inbox shows the proof
-- ---------------------------------------------------------------------------
create or replace view public.pending_requests as
  select r.id, r.plan_id, r.reference, r.sender_phone, r.submitted_at,
         u.email, u.phone,
         r.proof_path, r.proof_bytes, r.duplicate_of, r.price_shown
    from public.premium_requests r
    left join auth.users u on u.id = r.user_id
   where r.status = 'pending'
   order by r.submitted_at;

grant select on public.pending_requests to service_role;

insert into public.schema_migrations (version, note)
values ('040', 'payment screenshots: proof_path, sha256, duplicate_of, private bucket')
on conflict (version) do nothing;
