-- 048 — DELETE MY ACCOUNT (2026-10-23)
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. It deletes nothing by itself: it changes one foreign key and one
-- check, and adds the function the `delete-account` edge function calls.
--
-- ═══════════════════════════════════════════════════════════════════════
-- WHAT "DELETE MY ACCOUNT" DOES WITH EACH THING (docs/edge/delete-account.ts)
-- ═══════════════════════════════════════════════════════════════════════
--
-- DELETED, with the account:
--   the auth user (and with it its sessions, identities, factors),
--   devices, bookmarks, subscriptions          — ON DELETE CASCADE already,
--   age consents, diagnostic reports, the account's grant budget row.
--
-- KEPT, AND NO LONGER ANYONE'S:
--   * payment requests — plan, price shown, transaction number, status and
--     dates stay, because they are the books, and because a transaction
--     number filed again later must still be seen to be a reuse (5c in
--     premium-request.ts). What names the person goes: the account, the
--     sending phone number, the message and the receipt's screenshot (the
--     edge function removes the image itself from storage).
--   * watch history (events, title_views) — the counts behind Trending and
--     "More like this" stay; the viewer key becomes a fresh random one and
--     the IP hash and session are cleared, so no row leads back to anyone.
--
-- REFUSED: an admin's account. Removing an admin is the owner's act in the
-- console, and titles name their creators — a deletion from the app must
-- not be the way an admin disappears.
--
-- WHY THE FOREIGN KEY CHANGES. premium_requests.user_id was ON DELETE
-- CASCADE: deleting a user deleted every payment they ever made, which
-- would have taken the books and the reuse check with it. Now SET NULL, as
-- a safety net — delete_my_data() has already cleared it by then.
--
-- WHY THE CHECK CHANGES. A request needs a screenshot or a transaction
-- number (040). A deleted account's request may have neither left: the
-- screenshot was theirs. So the check now also accepts a request whose
-- account is gone.

alter table public.premium_requests alter column user_id drop not null;

alter table public.premium_requests
  drop constraint if exists premium_requests_user_id_fkey;
alter table public.premium_requests
  add constraint premium_requests_user_id_fkey
  foreign key (user_id) references auth.users (id) on delete set null;

alter table public.premium_requests
  drop constraint if exists premium_requests_has_proof;
alter table public.premium_requests
  add constraint premium_requests_has_proof check (
    proof_path is not null
    or coalesce(btrim(reference), '') <> ''
    or user_id is null
  );

-- Everything the account left, in one transaction, before the auth user is
-- deleted. Returns { proofs: [...storage paths] } for the edge function to
-- remove from the payment-proofs bucket, or { refused: 'admin' }.
--
-- p_install is the install id the app sends (`x-install-id`, the same key
-- _request_viewer_keys() reads): history recorded before sign-in and then
-- claimed by the account (claim_anonymous_history) is the account's too.
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
