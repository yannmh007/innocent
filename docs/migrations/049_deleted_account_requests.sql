-- 049 — A DELETED ACCOUNT'S PENDING PAYMENT (2026-10-24)
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. It deletes nothing.
--
-- FOUND BY the premium + delete lifecycle check (2026-10-24): a person who
-- sent a payment and deleted their account before it was reviewed left a
-- request in the console's queue with no account behind it. Approving it
-- failed with "null value in column user_id of relation subscriptions" —
-- a 500 and an operator with no idea why.
--
-- NOW:
--   * delete_my_data() closes the account's pending requests as rejected,
--     "account deleted", before it anonymises them: they leave the queue,
--     and stay in the books like every other request;
--   * approve_request() refuses a request whose account is gone, in words
--     the console shows, instead of failing inside the insert.

create or replace function public.delete_my_data(p_user uuid, p_install text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_key text := p_user::text;
  install_key text := nullif(btrim(coalesce(p_install, '')), '');
  -- One fresh key per old key, so two keys stay two and a day's unique
  -- viewer counts do not change.
  gone_account text := 'gone:' || gen_random_uuid()::text;
  gone_install text := 'gone:' || gen_random_uuid()::text;
  proofs text[];
begin
  if p_user is null then
    raise exception 'delete_my_data: no user';
  end if;
  if exists (select 1 from public.admins a where a.user_id = p_user) then
    return jsonb_build_object('refused', 'admin');
  end if;

  select coalesce(array_agg(r.proof_path) filter (where r.proof_path is not null), '{}')
    into proofs
    from public.premium_requests r
   where r.user_id = p_user;

  -- Nobody is left to grant it to: out of the queue, before the account
  -- goes from the row.
  update public.premium_requests
     set status = 'rejected',
         note = 'account deleted',
         reviewed_at = now()
   where user_id = p_user
     and status = 'pending';

  update public.premium_requests
     set user_id = null,
         sender_phone = null,
         message = null,
         proof_path = null,
         proof_bytes = null
   where user_id = p_user;

  update public.events
     set viewer_key = case when viewer_key = account_key then gone_account else gone_install end,
         ip_hash = null,
         session_id = null
   where viewer_key = account_key
      or (install_key is not null and viewer_key = install_key);

  update public.title_views
     set viewer_key = case when viewer_key = account_key then gone_account else gone_install end,
         ip_hash = null
   where viewer_key = account_key
      or (install_key is not null and viewer_key = install_key);

  delete from public.age_consents
   where viewer_key = account_key
      or (install_key is not null and viewer_key = install_key);

  delete from public.diagnostic_reports where user_id = p_user;

  delete from public.playback_budget where subject = 'u:' || account_key;

  return jsonb_build_object('proofs', to_jsonb(proofs));
end;
$$;

revoke all on function public.delete_my_data(uuid, text) from public, anon, authenticated;
grant execute on function public.delete_my_data(uuid, text) to service_role;

create or replace function public.approve_request(p_request_id uuid, p_days integer default 30)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r record;
begin
  select * into r from public.premium_requests where id = p_request_id;
  if r is null then return 'NOT FOUND'; end if;
  if r.status <> 'pending' then
    return 'ALREADY ' || upper(r.status) || ' - nothing done';
  end if;
  -- The account was deleted: there is nobody to grant it to. An error, so
  -- the console says "approve failed: account deleted" rather than "done".
  if r.user_id is null then
    raise exception 'account deleted - nothing to approve';
  end if;

  -- Extends an existing subscription rather than overwriting it: someone who
  -- renews early must not lose the days they already paid for.
  insert into public.subscriptions (user_id, plan_id, starts_at, expires_at, source, note)
  values (
    r.user_id, r.plan_id, now(),
    greatest(
      now(),
      coalesce((select max(expires_at) from public.subscriptions
                where user_id = r.user_id), now())
    ) + make_interval(days => p_days),
    'kpay', 'request ' || r.id::text
  );

  update public.premium_requests
     set status = 'approved', reviewed_at = now()
   where id = p_request_id;

  return 'APPROVED ' || r.plan_id || ' for ' || p_days || ' days';
end;
$$;

revoke all on function public.approve_request(uuid, integer) from public, anon, authenticated;
grant execute on function public.approve_request(uuid, integer) to service_role;

-- Requests left pending by accounts deleted before this ran.
update public.premium_requests
   set status = 'rejected', note = 'account deleted', reviewed_at = now()
 where user_id is null
   and status = 'pending';
