-- 042 — the payment inbox: the viewer's own words, and an operator who
-- cannot miss a request
--
-- Owner request (2026-10-06), after trying 040: "a screenshot alone is not
-- enough — there must be somewhere to write a note. And these must show in
-- the console as notifications; opening it, the receipts must be right
-- there. Make it premium, make it pro."
--
-- 1. `message`: what the payer wants to say, in their words — "paid from my
--    sister's account", "sent 10,000 then 500 more", "please hurry, I paid at
--    9 pm". Up to 500 characters; written only by the premium-request
--    function, like every other field of a request.
-- 2. `seen_at`: when an operator first had the request on screen. Unseen
--    pending requests are what the console counts, badges and announces.
-- 3. `reviewed_by`: which operator approved or rejected it (their email), so
--    a team of two never asks "did you do this one?".
-- 4. `admin_requests`: the console's inbox — every request, pending or
--    decided, with the account, whether this person has paid before, and
--    until when they are Premium. Service role only: it reads auth.users.

alter table public.premium_requests
  add column if not exists message     text,
  add column if not exists seen_at     timestamptz,
  add column if not exists reviewed_by text;

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'premium_requests_message_len') then
    alter table public.premium_requests add constraint premium_requests_message_len
      check (message is null or char_length(message) <= 500);
  end if;
end $$;

create index if not exists premium_requests_unseen
  on public.premium_requests (submitted_at) where status = 'pending' and seen_at is null;

-- The viewer reads back what they wrote, and when it was decided.
grant select (message, reviewed_at) on public.premium_requests to authenticated;

create or replace view public.admin_requests as
  select r.id, r.status, r.plan_id, r.price_shown, r.message,
         r.reference, r.sender_phone,
         r.submitted_at, r.seen_at, r.reviewed_at, r.reviewed_by, r.note,
         r.proof_path, r.proof_bytes, r.duplicate_of,
         r.user_id, u.email, u.phone,
         coalesce(u.raw_user_meta_data ->> 'full_name',
                  u.raw_user_meta_data ->> 'name') as display_name,
         (select count(*) from public.premium_requests p
           where p.user_id = r.user_id and p.status = 'approved'
             and p.id <> r.id)::int as approved_before,
         (select max(s.expires_at) from public.subscriptions s
           where s.user_id = r.user_id) as premium_until
    from public.premium_requests r
    left join auth.users u on u.id = r.user_id;

-- It names accounts by email: the console's (service role) and nobody else's.
revoke all on public.admin_requests from public, anon, authenticated;
grant select on public.admin_requests to service_role;

-- The old inbox view gains the message, for anything still reading it.
create or replace view public.pending_requests as
  select r.id, r.plan_id, r.reference, r.sender_phone, r.submitted_at,
         u.email, u.phone,
         r.proof_path, r.proof_bytes, r.duplicate_of, r.price_shown,
         r.message, r.seen_at
    from public.premium_requests r
    left join auth.users u on u.id = r.user_id
   where r.status = 'pending'
   order by r.submitted_at;
revoke all on public.pending_requests from public, anon, authenticated;
grant select on public.pending_requests to service_role;

insert into public.schema_migrations (version, note)
values ('042', 'payment inbox: message, seen_at, reviewed_by, admin_requests')
on conflict (version) do nothing;
