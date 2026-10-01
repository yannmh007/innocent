-- Admins, roles and the audit log   (migration 026)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `ADMINS TEST PASSED`; any other
-- exception names the case that failed.
--
-- The cases that matter most are the ones that would be silent in use: an
-- unconfirmed address claiming an invitation, the last owner removing
-- themselves, and the audit log being edited after the fact.
do $$
declare
  owner_id  uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  ed_id     uuid := '00000000-0000-4000-8000-0000000000e1';
  sneak_id  uuid := '00000000-0000-4000-8000-0000000000e2';
  r         record;
  v         text;
  n         integer;
  blocked   boolean;
begin
  -- ── the owner that exists today resolves as owner ──────────────────────
  select * into r from public.admin_resolve(owner_id);
  if r.role is distinct from 'owner' then
    raise exception 'the seeded owner resolved as %', r.role;
  end if;
  if r.require_mfa then
    raise exception 'require_mfa must start off, or the owner is locked out';
  end if;

  -- ── a stranger resolves as nothing ─────────────────────────────────────
  select count(*) into n from public.admin_resolve(gen_random_uuid());
  if n <> 0 then raise exception 'a stranger resolved as an admin'; end if;

  -- ── an invitation links on first sign-in, by CONFIRMED email only ──────
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at)
  values (ed_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'editor.test@example.com', now()),
         (sneak_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'invited.test@example.com', null);

  select public.admin_save(owner_id, 'Editor.Test@example.com', 'editor') into v;
  if v <> 'added' then raise exception 'owner could not invite: %', v; end if;
  select * into r from public.admin_resolve(ed_id);
  if r.role is distinct from 'editor' then
    raise exception 'the invited editor did not link on first sign-in: %', r.role;
  end if;

  select public.admin_save(owner_id, 'invited.test@example.com', 'uploader') into v;
  select count(*) into n from public.admin_resolve(sneak_id);
  if n <> 0 then
    raise exception 'an UNCONFIRMED address claimed an invitation';
  end if;

  -- ── only an owner can hand out roles ───────────────────────────────────
  select public.admin_save(ed_id, 'someone@example.com', 'owner') into v;
  if v <> 'not_owner' then raise exception 'an editor handed out a role: %', v; end if;
  select public.admin_remove(ed_id, (select id from public.admins where user_id = owner_id)) into v;
  if v <> 'not_owner' then raise exception 'an editor removed the owner: %', v; end if;

  -- ── the last owner cannot be demoted or removed, even by themselves ────
  select public.admin_save(owner_id, (select email from public.admins where user_id = owner_id), 'editor') into v;
  if v <> 'last_owner' then raise exception 'the last owner was demoted: %', v; end if;
  select public.admin_remove(owner_id, (select id from public.admins where user_id = owner_id)) into v;
  if v <> 'last_owner' then raise exception 'the last owner was removed: %', v; end if;

  -- ...but with a second owner, the first can step down
  select public.admin_save(owner_id, 'editor.test@example.com', 'owner') into v;
  select public.admin_save(owner_id, (select email from public.admins where user_id = owner_id), 'editor') into v;
  if v <> 'updated' then raise exception 'with two owners one could not step down: %', v; end if;

  -- ── a disabled admin resolves as nothing ───────────────────────────────
  select public.admin_remove(ed_id, (select id from public.admins where user_id = owner_id)) into v;
  if v <> 'disabled' then raise exception 'remove did not disable: %', v; end if;
  select count(*) into n from public.admin_resolve(owner_id);
  if n <> 0 then raise exception 'a disabled admin still resolved'; end if;

  -- ── the audit log records, and cannot be rewritten ─────────────────────
  perform public.admin_log(ed_id, 'studio', 'deleteTitle', 't-1', '{"x":1}'::jsonb, true, null);
  select actor_email, actor_role into r from public.admin_audit
   where actor = ed_id order by id desc limit 1;
  if r.actor_email <> 'editor.test@example.com' or r.actor_role <> 'owner' then
    raise exception 'the audit line lost who did it: % %', r.actor_email, r.actor_role;
  end if;

  blocked := false;
  begin
    update public.admin_audit set action = 'nothing' where actor = ed_id;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'the audit log was EDITED'; end if;

  blocked := false;
  begin
    delete from public.admin_audit where actor = ed_id;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'the audit log was DELETED from'; end if;

  -- ── a sign-in is announced once per session ────────────────────────────
  if not public.admin_note_session('00000000-0000-4000-8000-00000000005e', ed_id, 'test') then
    raise exception 'a new session was not noted';
  end if;
  if public.admin_note_session('00000000-0000-4000-8000-00000000005e', ed_id, 'test') then
    raise exception 'the same session was announced twice';
  end if;

  raise exception 'ADMINS TEST PASSED';
end;
$$;
