-- 027 — the review queue: nothing reaches the app without one approval
--
-- WHAT THE OPERATOR ASKED FOR. Everything that comes in — forwarded to the bot
-- or uploaded from the console — waits until an editor or the owner has looked
-- at it and said yes. "But not complicated": one tap to approve.
--
-- WHAT WAS ALREADY TRUE. A Telegram file is in no title until somebody files
-- it, a title made from it is born a draft, and a title with no files cannot be
-- published (024). What was missing: the console's own upload published on
-- creation by default, there was no "this is ready, please look" signal, no
-- way to send something back with a reason, and no record of who approved
-- what.
--
-- THE STATES, kept apart from `published`/`status`. The app reads `published`
-- and must go on doing exactly that; `status` is read by the health view. So
-- the review lives in its own column and a trigger keeps the two in step:
--
--     editing   a draft somebody is preparing            (not in the app)
--     ready     sent for review — "please look"          (not in the app)
--     changes   sent back with a note                    (not in the app)
--     rejected  not wanted; out of the queue             (not in the app)
--     approved  live                                     (in the app)
--
-- ONE DOOR. Every move between states goes through `review_decide`, which
-- checks the caller's role ITSELF — the edge function checks too, but this is
-- the function that puts a title in front of paying viewers, so a missed check
-- upstream must not be enough.

-- ---------------------------------------------------------------------------
-- the columns
-- ---------------------------------------------------------------------------
alter table public.titles
  add column if not exists review_state text not null default 'editing',
  add column if not exists review_note  text,
  add column if not exists submitted_at timestamptz,
  add column if not exists submitted_by uuid references auth.users(id) on delete set null,
  add column if not exists decided_at   timestamptz,
  add column if not exists decided_by   uuid references auth.users(id) on delete set null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'titles_review_state_check') then
    alter table public.titles add constraint titles_review_state_check
      check (review_state in ('editing', 'ready', 'changes', 'rejected', 'approved'));
  end if;
end $$;

-- What is live today was approved by being published; say so, so the queue
-- does not open with five finished films in it.
update public.titles set review_state = 'approved'
 where published and review_state <> 'approved';

create index if not exists titles_review_queue_idx
  on public.titles (review_state, submitted_at desc) where not published;

-- ---------------------------------------------------------------------------
-- review_state follows `published`, whichever way it was changed
-- ---------------------------------------------------------------------------
--
-- NAMED zz ON PURPOSE. Postgres fires BEFORE triggers in name order, and
-- `titles_sync_published` turns a change of `status` into a change of
-- `published`. This has to see the result of that, so it runs after it.
--
-- AND IT CLOSES A HOLE IN 024. `titles_no_empty_publish` runs BEFORE the sync
-- trigger, so setting status = 'published' in the Table Editor reached it
-- while `published` was still false and went live with no files. The same
-- check is made here, after the sync, where both paths are visible.
create or replace function public.title_review_follows_published()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    if new.published then
      new.review_state := 'approved';
    end if;
    return new;
  end if;

  if new.published and not coalesce(old.published, false) then
    if not exists (select 1 from public.title_assets a where a.title_id = new.id) then
      raise exception 'a title with no files cannot be published'
        using errcode = 'check_violation';
    end if;
    if new.review_state is not distinct from old.review_state then
      new.review_state := 'approved';
    end if;
  elsif not new.published and coalesce(old.published, false) then
    if new.review_state is not distinct from old.review_state then
      new.review_state := 'editing';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists titles_zz_review_follows_published on public.titles;
create trigger titles_zz_review_follows_published
  before insert or update on public.titles
  for each row execute function public.title_review_follows_published();

-- ---------------------------------------------------------------------------
-- the history of each title's review
-- ---------------------------------------------------------------------------
--
-- NO FOREIGN KEY TO titles, like title_views: a deleted title's history is
-- still a true record of what happened, and a cascade would be a delete, which
-- this table refuses.
create table if not exists public.title_reviews (
  id          bigint generated always as identity primary key,
  title_id    uuid not null,
  at          timestamptz not null default now(),
  actor       uuid,
  actor_email text,
  action      text not null check (action in
                ('submit', 'approve', 'send_back', 'reject', 'reopen', 'unpublish')),
  note        text
);
create index if not exists title_reviews_title_idx on public.title_reviews (title_id, at desc);
alter table public.title_reviews enable row level security;
revoke all on public.title_reviews from anon, authenticated;
grant select, insert on public.title_reviews to service_role;

drop trigger if exists title_reviews_no_rewrite on public.title_reviews;
create trigger title_reviews_no_rewrite
  before update or delete on public.title_reviews
  for each row execute function public.admin_audit_is_append_only();
drop trigger if exists title_reviews_no_truncate on public.title_reviews;
create trigger title_reviews_no_truncate
  before truncate on public.title_reviews
  for each statement execute function public.admin_audit_is_append_only();

-- ---------------------------------------------------------------------------
-- the two-person rule — an owner's switch, off by default
-- ---------------------------------------------------------------------------
--
-- With it on, whoever made a title cannot also approve it. Off by default
-- because with one owner and nobody else it would make approval impossible;
-- the edge function refuses to switch it on until there are two people who
-- can approve.
alter table public.admin_settings
  add column if not exists two_person boolean not null default false;

-- ---------------------------------------------------------------------------
-- review_decide — the one door
-- ---------------------------------------------------------------------------
--
-- Answers a word. Success: submitted, approved, sent_back, rejected, reopened,
-- unpublished. Refusal: not_an_admin, no_such_title, not_allowed, already_live,
-- not_live, bad_state, no_files, note_required, two_person, bad_action.
--
-- `p_actor` is the auth user id the edge function resolved from the token.
-- The row is locked for the decision, so two editors tapping Approve and Send
-- back at the same moment get one each, in order, and the second is told the
-- state has moved on.
create or replace function public.review_decide(
  p_title uuid, p_actor uuid, p_action text, p_note text default null
) returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a        record;
  t        record;
  s        public.admin_settings%rowtype;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_editor boolean;
  v_mine   boolean;
  v_files  boolean;
  v_result text;
begin
  select ad.id, ad.email, ad.role into a
    from public.admins ad
   where ad.user_id = p_actor and not ad.disabled;
  if a.id is null then
    return 'not_an_admin';
  end if;

  select * into t from public.titles where id = p_title for update;
  if t.id is null then
    return 'no_such_title';
  end if;
  select * into s from public.admin_settings where id;

  v_editor := a.role in ('editor', 'owner');
  v_mine   := t.created_by is not distinct from p_actor;
  v_files  := exists (select 1 from public.title_assets x where x.title_id = t.id);

  if p_action = 'submit' then
    if not (v_editor or (v_mine and a.role = 'uploader')) then return 'not_allowed'; end if;
    if t.published then return 'already_live'; end if;
    if t.review_state not in ('editing', 'changes') then return 'bad_state'; end if;
    if not v_files then return 'no_files'; end if;
    update public.titles
       set review_state = 'ready', submitted_at = now(), submitted_by = p_actor,
           review_note = null
     where id = t.id;
    v_result := 'submitted';

  elsif p_action = 'approve' then
    if not v_editor then return 'not_allowed'; end if;
    if t.published then return 'already_live'; end if;
    if t.review_state = 'rejected' then return 'bad_state'; end if;
    if not v_files then return 'no_files'; end if;
    if s.two_person and v_mine then return 'two_person'; end if;
    update public.titles
       set published = true, status = 'published', review_state = 'approved',
           review_note = null, decided_at = now(), decided_by = p_actor
     where id = t.id;
    v_result := 'approved';

  elsif p_action = 'send_back' then
    if not v_editor then return 'not_allowed'; end if;
    if t.published then return 'already_live'; end if;
    if t.review_state not in ('ready', 'editing') then return 'bad_state'; end if;
    -- A send-back without a reason is a puzzle for whoever gets it.
    if v_note is null then return 'note_required'; end if;
    update public.titles
       set review_state = 'changes', review_note = v_note,
           decided_at = now(), decided_by = p_actor
     where id = t.id;
    v_result := 'sent_back';

  elsif p_action = 'reject' then
    if not v_editor then return 'not_allowed'; end if;
    if t.published then return 'already_live'; end if;
    if t.review_state = 'rejected' then return 'bad_state'; end if;
    update public.titles
       set review_state = 'rejected', review_note = v_note,
           decided_at = now(), decided_by = p_actor
     where id = t.id;
    v_result := 'rejected';

  elsif p_action = 'reopen' then
    if not (v_editor or (v_mine and a.role = 'uploader')) then return 'not_allowed'; end if;
    if t.published then return 'already_live'; end if;
    if t.review_state <> 'rejected' then return 'bad_state'; end if;
    update public.titles set review_state = 'editing' where id = t.id;
    v_result := 'reopened';

  elsif p_action = 'unpublish' then
    if not v_editor then return 'not_allowed'; end if;
    if not t.published then return 'not_live'; end if;
    update public.titles
       set published = false, status = 'draft', review_state = 'editing',
           review_note = v_note, decided_at = now(), decided_by = p_actor
     where id = t.id;
    v_result := 'unpublished';

  else
    return 'bad_action';
  end if;

  insert into public.title_reviews (title_id, actor, actor_email, action, note)
  values (t.id, p_actor, a.email, p_action, v_note);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- review_queue — everything not live, the ones waiting first
-- ---------------------------------------------------------------------------
create or replace function public.review_queue()
returns table(
  id uuid, title text, title_mm text, poster_url text, category text,
  folder text, review_state text, review_note text, created_at timestamptz,
  created_by uuid, creator_email text, submitted_at timestamptz,
  decided_at timestamptz, decider_email text, photos integer, videos integer
)
language sql
security definer
set search_path to 'public'
as $$
  select t.id, t.title, t.title_mm, t.poster_url, t.category, t.slug,
         t.review_state, t.review_note, t.created_at, t.created_by,
         c.email, t.submitted_at, t.decided_at, d.email,
         (select count(*) from public.title_assets x
           where x.title_id = t.id and x.kind = 'photo')::integer,
         (select count(*) from public.title_assets x
           where x.title_id = t.id and x.kind <> 'photo')::integer
    from public.titles t
    left join public.admins c on c.user_id = t.created_by
    left join public.admins d on d.user_id = t.decided_by
   where not t.published
   order by case t.review_state
              when 'ready' then 0 when 'changes' then 1
              when 'editing' then 2 else 3 end,
            coalesce(t.submitted_at, t.created_at) desc
   limit 300;
$$;

-- ---------------------------------------------------------------------------
-- discard_ingest — "I forwarded that by mistake"
-- ---------------------------------------------------------------------------
--
-- Takes finished or failed files that are in NO title out of the Telegram
-- inbox: one job, or every such job of one folder. Never a queued or running
-- one — the runner holds those.
--
-- THE ROWS ARE DELETED, and that is what makes it undoable: the dedupe index
-- on `tg_unique_id` would otherwise answer "Already queued" for ever if the
-- same file were forwarded again on purpose. The object stays in R2, where the
-- Files page lists it as unused once it is a day old. The audit log keeps the
-- folder and the count.
create or replace function public.discard_ingest(
  p_job uuid default null, p_folder text default null
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  n      integer;
  v_pref text := btrim(coalesce(p_folder, ''));
begin
  if p_job is not null then
    delete from public.ingest_jobs
     where id = p_job and title_id is null and state in ('done', 'failed');
  elsif v_pref <> '' then
    delete from public.ingest_jobs
     where title_id is null and state in ('done', 'failed')
       and object_key like v_pref || '/%';
  else
    return 0;
  end if;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.review_decide(uuid, uuid, text, text)',
    'public.review_queue()',
    'public.discard_ingest(uuid, text)',
    'public.title_review_follows_published()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
