-- 033 — the bot is told which folder, instead of guessing it from a caption
--
-- Until now the folder came from the first line of the caption. That works
-- for a film the operator sends, and fails for the commonest case there is:
-- FORWARDING an album out of a channel. Telegram does not let a forwarded
-- message's caption be edited, so the folder was whatever the channel's
-- author wrote — a Burmese sentence (which slugifies to nothing, so `inbox`),
-- a hashtag, an emoji line — and three or four albums that belong to one
-- title landed in three or four folders. R2 got untidy, and tidying it meant
-- a move per folder on the Files page.
--
-- So the operator names the folder first, in the chat:
--
--     /folder solo-girl-collection
--     (forward the albums)
--     /done
--
-- Everything that arrives in between goes into that folder, whatever its
-- caption says (the caption is still kept: it is the console's description).
-- `/folder` with a name that already has files simply continues it — that is
-- how more is added to a title later.
--
-- A SESSION ENDS BY ITSELF after three hours without a file. Forgetting
-- `/done` must not put tomorrow's unrelated film into today's folder; the
-- next file after the gap goes by its caption again and the bot says why.
--
-- One row per operator chat. The edge function is the only reader and
-- writer (service role); RLS on with no policies keeps everyone else out.

create table if not exists public.bot_folder_sessions (
  chat_id    bigint primary key,
  folder     text not null,
  started_at timestamptz not null default now(),
  touched_at timestamptz not null default now(),
  closed_at  timestamptz,
  closed_why text
);

alter table public.bot_folder_sessions enable row level security;

comment on table public.bot_folder_sessions is
  'The folder an operator chose with /folder in the bot. Open while closed_at '
  'is null and a file arrived in the last three hours (migration 033).';

-- ---------------------------------------------------------------------------
-- which names are allowed
-- ---------------------------------------------------------------------------
--
-- The same shape the Files page accepts for a folder (028), one level only.
-- And not a name something else already lives under: `apk` is where the app
-- updates are, `v` and `p` are the early flat uploads, `inbox` is "no folder".
create or replace function public.bot_folder_name_ok(p_folder text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case
    when coalesce(p_folder, '') = '' then 'empty'
    when length(p_folder) > 60 then 'too_long'
    when p_folder !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then 'bad_name'
    when p_folder in ('inbox', 'apk', 'v', 'p', 'thumb', 'thumbs', 'backup',
                      'previews') then 'reserved'
    else 'ok'
  end;
$$;

-- ---------------------------------------------------------------------------
-- what is in a folder
-- ---------------------------------------------------------------------------
--
-- From the Telegram queue (what the bot sent there) and from the console's
-- copy of the bucket listing (what is actually in R2, console uploads too).
-- `title` is the title that owns the folder — the one whose slug it is — and
-- `attached_to` every title its Telegram files were filed into, which is how
-- the operator sees "these went into X" without opening the console.
create or replace function public.bot_folder_stats(p_folder text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with j as (
    select * from public.ingest_jobs
     where split_part(object_key, '/', 1) = p_folder
  )
  select jsonb_build_object(
    'folder',     p_folder,
    'files',      (select count(*) from j),
    'queued',     (select count(*) from j where state in ('queued', 'running')),
    'done',       (select count(*) from j where state = 'done'),
    'failed',     (select count(*) from j where state = 'failed'),
    'unattached', (select count(*) from j where state = 'done' and title_id is null),
    'last_at',    (select max(created_at) from j),
    'in_r2',      (select count(*) from public.r2_inventory i
                    where split_part(i.key, '/', 1) = p_folder),
    'title',      (select jsonb_build_object('id', t.id, 'title', t.title,
                                             'published', t.published,
                                             'review_state', t.review_state)
                     from public.titles t where t.slug = p_folder limit 1),
    'attached_to', coalesce((
       select jsonb_agg(distinct t.title)
         from j join public.titles t on t.id = j.title_id), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------------
-- /folder <name>
-- ---------------------------------------------------------------------------
create or replace function public.bot_folder_open(p_chat bigint, p_folder text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_ok   text := public.bot_folder_name_ok(p_folder);
  v_prev text;
begin
  if v_ok <> 'ok' then
    return jsonb_build_object('error', v_ok);
  end if;
  select s.folder into v_prev from public.bot_folder_sessions s
   where s.chat_id = p_chat and s.closed_at is null
     and s.touched_at > now() - interval '3 hours';
  insert into public.bot_folder_sessions (chat_id, folder)
  values (p_chat, p_folder)
  on conflict (chat_id) do update
     set folder = excluded.folder, started_at = now(), touched_at = now(),
         closed_at = null, closed_why = null;
  return jsonb_build_object(
    'ok', true,
    'previous', case when v_prev is distinct from p_folder then v_prev end,
    'stats', public.bot_folder_stats(p_folder));
end;
$$;

-- ---------------------------------------------------------------------------
-- the folder a file arriving now goes into
-- ---------------------------------------------------------------------------
--
-- Touches the session, so an album of forty files keeps it open. Three hours
-- with nothing closes it, and says which folder it was so the bot can tell
-- the operator why this file did not go there.
create or replace function public.bot_folder_current(p_chat bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  s public.bot_folder_sessions%rowtype;
begin
  select * into s from public.bot_folder_sessions
   where chat_id = p_chat and closed_at is null
   for update;
  if not found then
    return jsonb_build_object('folder', null);
  end if;
  if s.touched_at < now() - interval '3 hours' then
    update public.bot_folder_sessions
       set closed_at = now(), closed_why = 'idle'
     where chat_id = p_chat;
    return jsonb_build_object('folder', null, 'expired', s.folder);
  end if;
  update public.bot_folder_sessions set touched_at = now() where chat_id = p_chat;
  return jsonb_build_object('folder', s.folder, 'since', s.started_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- /done
-- ---------------------------------------------------------------------------
create or replace function public.bot_folder_close(p_chat bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  s public.bot_folder_sessions%rowtype;
  n integer;
begin
  select * into s from public.bot_folder_sessions
   where chat_id = p_chat and closed_at is null
   for update;
  if not found then
    return jsonb_build_object('folder', null);
  end if;
  update public.bot_folder_sessions
     set closed_at = now(), closed_why = 'done'
   where chat_id = p_chat;
  select count(*) into n from public.ingest_jobs j
   where split_part(j.object_key, '/', 1) = s.folder
     and j.created_at >= s.started_at;
  return jsonb_build_object('folder', s.folder, 'added', n,
                            'stats', public.bot_folder_stats(s.folder));
end;
$$;

-- ---------------------------------------------------------------------------
-- /folders — the most recent ones, to pick a name to continue
-- ---------------------------------------------------------------------------
create or replace function public.bot_folders_recent(p_limit integer default 10)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(x order by x.last_at desc), '[]'::jsonb) from (
    select g.*,
           (select t.title from public.titles t where t.slug = g.folder limit 1) as title
      from (
        select split_part(j.object_key, '/', 1) as folder,
               count(*) as files,
               count(*) filter (where j.state = 'done' and j.title_id is null) as unattached,
               count(*) filter (where j.state = 'failed') as failed,
               count(*) filter (where j.state in ('queued', 'running')) as queued,
               max(j.created_at) as last_at
          from public.ingest_jobs j
         group by 1
         order by max(j.created_at) desc
         limit greatest(1, least(coalesce(p_limit, 10), 30))
      ) g
  ) x;
$$;

-- ---------------------------------------------------------------------------
-- /status — the queue and the runner, from the chat
-- ---------------------------------------------------------------------------
create or replace function public.bot_queue_status()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'queued',     (select count(*) from public.ingest_jobs where state = 'queued'),
    'running',    (select count(*) from public.ingest_jobs where state = 'running'),
    'failed',     (select count(*) from public.ingest_jobs where state = 'failed'
                     and title_id is null),
    'unattached', (select count(*) from public.ingest_jobs where state = 'done'
                     and title_id is null),
    'waiting_mb', (select coalesce(sum(bytes), 0) / 1048576 from public.ingest_jobs
                    where state in ('queued', 'running')),
    'runner_at',  (select r.seen_at from public.runner_ticks r where r.name = 'ingest'),
    'archive_queued', (select count(*) from public.vault_jobs
                        where kind = 'archive' and state in ('queued', 'running'))
  );
$$;

-- ---------------------------------------------------------------------------
-- /retry <folder> — every spent file of one folder back in the queue
-- ---------------------------------------------------------------------------
--
-- Through retry_ingest, one row at a time, so its refusal of a file that has
-- since been forwarded again still holds.
create or replace function public.bot_retry_folder(p_folder text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j record;
  n integer := 0;
begin
  if coalesce(p_folder, '') = '' then
    return 0;
  end if;
  for j in
    select id from public.ingest_jobs
     where state = 'failed' and split_part(object_key, '/', 1) = p_folder
  loop
    if public.retry_ingest(j.id) = 'queued' then
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- enqueue_ingest — an album's caption reaches every file of it
-- ---------------------------------------------------------------------------
--
-- 024's version took a sibling's caption only together with its folder, when
-- the file had neither. With /folder every file has a folder, so a file that
-- arrived after the captioned one kept no caption. Same signature as 024:
-- replaced, not overloaded (see 024 for why an overload is dangerous).
create or replace function public.enqueue_ingest(
  p_file_id     text,
  p_unique_id   text,
  p_chat_id     bigint,
  p_message_id  bigint,
  p_file_name   text,
  p_mime        text,
  p_bytes       bigint,
  p_duration    integer,
  p_width       integer,
  p_height      integer,
  p_kind        text,
  p_bucket      text,
  p_folder      text,
  p_key_tail    text,
  p_media_group text,
  p_caption     text default null
) returns table(status text, folder text, moved integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_folder  text := nullif(btrim(coalesce(p_folder, '')), '');
  v_group   text := nullif(btrim(coalesce(p_media_group, '')), '');
  v_caption text := nullif(btrim(coalesce(p_caption, '')), '');
  v_moved   integer := 0;
  v_id      uuid;
begin
  -- One delivery of one album at a time. See 023.
  if v_group is not null then
    perform pg_advisory_xact_lock(hashtext('ingest_group:' || v_group));
  end if;

  -- No caption of its own: take what a sibling was given. The folder and the
  -- caption travel together because they come from the same message.
  if v_folder is null and v_group is not null then
    select split_part(j.object_key, '/', 1), j.tg_caption
      into v_folder, v_caption
      from public.ingest_jobs j
     where j.tg_media_group = v_group
       and split_part(j.object_key, '/', 1) <> 'inbox'
     order by j.created_at asc
     limit 1;
  end if;

  -- NO CAPTION OF ITS OWN, BUT A FOLDER (033): a /folder session names the
  -- folder for every file, so the block above never runs — and a file that
  -- arrived after its album's caption kept none. Take the sibling's.
  if v_caption is null and v_group is not null then
    select j.tg_caption into v_caption
      from public.ingest_jobs j
     where j.tg_media_group = v_group
       and j.tg_caption is not null
     order by j.created_at asc
     limit 1;
  end if;

  insert into public.ingest_jobs
    (tg_file_id, tg_unique_id, tg_chat_id, tg_message_id, file_name, mime,
     bytes, duration_s, width, height, kind, bucket, object_key,
     tg_media_group, tg_caption)
  values
    (p_file_id, p_unique_id, p_chat_id, p_message_id, p_file_name,
     nullif(p_mime, ''), nullif(p_bytes, 0), p_duration, p_width, p_height,
     p_kind, p_bucket, coalesce(v_folder, 'inbox') || '/' || p_key_tail,
     v_group, v_caption)
  on conflict (tg_unique_id) where state <> 'failed' do nothing
  returning id into v_id;

  if v_id is null then
    return query select 'duplicate'::text, coalesce(v_folder, 'inbox'), 0;
    return;
  end if;

  -- The caption arrived after its siblings.
  if v_group is not null and v_folder is not null and v_folder <> 'inbox' then
    -- The KEY may only be rewritten while nothing holds it: a claimed row has
    -- a presigned PUT for the old one.
    update public.ingest_jobs j
       set object_key = v_folder || substr(j.object_key, length('inbox') + 1)
     where j.tg_media_group = v_group
       and j.id <> v_id
       and j.state = 'queued'
       and j.object_key like 'inbox/%';
    get diagnostics v_moved = row_count;
  end if;

  -- The CAPTION has no such constraint — nothing is signed against it — so it
  -- reaches siblings in any state, including ones already in the bucket.
  if v_group is not null and v_caption is not null then
    update public.ingest_jobs j
       set tg_caption = v_caption
     where j.tg_media_group = v_group
       and j.id <> v_id
       and j.tg_caption is null;
  end if;

  return query select 'queued'::text, coalesce(v_folder, 'inbox'), v_moved;
end;
$$;

revoke all on function public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text, text) to service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'bot_folder_name_ok(text)', 'bot_folder_stats(text)',
    'bot_folder_open(bigint,text)', 'bot_folder_current(bigint)',
    'bot_folder_close(bigint)', 'bot_folders_recent(integer)',
    'bot_queue_status()', 'bot_retry_folder(text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

insert into public.schema_migrations (version, note)
values ('033', 'bot commands: /folder, /done, /folders, /info, /status, /retry')
on conflict (version) do nothing;
