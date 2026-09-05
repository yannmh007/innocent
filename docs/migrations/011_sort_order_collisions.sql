-- ===========================================================================
-- 011 — 009 fixed the tie, then add_title put it back
--
-- Paste the WHOLE file into the SQL Editor and Run. Safe to run twice.
-- No client change.
--
-- THE BUG, FOUND BY AUDITING 009 RATHER THAN BY HITTING IT
--
--   add_title('x', photos => ['a.jpg','b.jpg'])   -> a=1001, b=1002
--   later, one more still arrives:
--   add_title('x', photos => ['c.jpg'])           -> c=1001   ← ties with a
--
-- `unique (bucket, object_key)` stops a duplicate ROW. It does not stop a
-- duplicate sort_order. Two photos at 1001 is a tie, SQL does not promise an
-- order among ties, and the mosaic computes its rows FROM the order - so the
-- album silently rearranges between visits. That is precisely the fault 009
-- was written to remove, reintroduced by the function 009 shipped alongside it.
--
-- THE FIX: stop numbering from the ARRAY POSITION and start numbering from
-- WHAT IS ALREADY THERE. New files land after the existing ones, always, no
-- matter how the caller batches them.
-- ===========================================================================

-- Repair anything already collided, before the constraint below refuses it.
-- row_number() over the existing order gives every asset a distinct slot while
-- keeping the sequence it already had.
with renumbered as (
  select id,
         row_number() over (
           partition by title_id, (kind = 'photo')
           order by sort_order, added_at, id
         ) as seq,
         (kind = 'photo') as is_photo
  from public.title_assets
)
update public.title_assets a
   set sort_order = case when r.is_photo then 1000 + r.seq else r.seq end
  from renumbered r
 where a.id = r.id;

-- Now it cannot happen again. A tie is refused at write time rather than
-- discovered later as a reshuffling album.
create unique index if not exists title_assets_order_unique
  on public.title_assets (title_id, kind, sort_order);


create or replace function public.add_title(
  p_slug     text,
  p_title    text,
  p_videos   text[] default '{}',
  p_photos   text[] default '{}',
  p_category text default 'movies',
  p_tier     text default 'free',
  p_title_mm text default null,
  p_synopsis text default null,
  p_year     int  default null,
  p_genres   text[] default null,
  p_quality  text default null,
  p_episodes int  default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  tid       uuid;
  next_vid  int;
  next_pic  int;
begin
  select id into tid from public.titles where slug = p_slug;

  if tid is null then
    insert into public.titles (slug, title, category, access_tier, status, published)
    values (p_slug, p_title, p_category, p_tier, 'draft', false)
    returning id into tid;
  end if;

  update public.titles set
    title         = coalesce(p_title, title),
    title_mm      = coalesce(p_title_mm, title_mm),
    synopsis      = coalesce(p_synopsis, synopsis),
    year          = coalesce(p_year, year),
    genres        = coalesce(p_genres, genres),
    quality_label = coalesce(p_quality, quality_label),
    episode_count = coalesce(p_episodes, episode_count),
    category      = coalesce(p_category, category),
    access_tier   = coalesce(p_tier, access_tier)
  where id = tid;

  -- CONTINUE the sequence instead of restarting it. This is the whole fix.
  select coalesce(max(sort_order), 0) into next_vid
    from public.title_assets where title_id = tid and kind = 'video';
  select coalesce(max(sort_order), 1000) into next_pic
    from public.title_assets where title_id = tid and kind = 'photo';

  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  select tid, 'video', 'innocent-media', p_slug || '/' || f.name, next_vid + f.ord
  from unnest(p_videos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  select tid, 'photo', 'innocent-public', p_slug || '/' || f.name, next_pic + f.ord
  from unnest(p_photos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

  if not exists (select 1 from public.title_assets
                 where title_id = tid and kind = 'video' and is_primary) then
    update public.title_assets set is_primary = true
     where id = (select id from public.title_assets where title_id = tid
                 and kind = 'video' order by sort_order, added_at limit 1);
  end if;

  if not exists (select 1 from public.title_assets
                 where title_id = tid and kind = 'photo' and is_primary) then
    update public.title_assets set is_primary = true
     where id = (select id from public.title_assets where title_id = tid
                 and kind = 'photo' order by sort_order, added_at limit 1);
  end if;

  return tid;
end;
$fn$;

revoke execute on function public.add_title(text,text,text[],text[],text,text,text,text,int,text[],text,int)
  from public, anon, authenticated;
grant execute on function public.add_title(text,text,text[],text[],text,text,text,text,int,text[],text,int)
  to service_role;

do $mig$
begin
  if not exists (select 1 from public.schema_migrations where version = '011') then
    insert into public.schema_migrations (version, note)
    values ('011', 'sort_order continues instead of restarting; unique index');
  end if;
end
$mig$;


-- ---------------------------------------------------------------------------
-- PROVE IT — this is the test that would have caught the bug
-- ---------------------------------------------------------------------------
-- Add a photo to an existing title in a SECOND call and confirm it lands after
-- the first ones rather than on top of them:
--
--   select public.add_title('first-test','First test title',
--                           array[]::text[], array['second-photo.jpg']);
--   select kind, sort_order, object_key from public.title_assets
--    where title_id = (select id from public.titles where slug='first-test')
--    order by sort_order;
--
-- Every sort_order must be distinct, and the new photo must be LAST.

select title_id, kind, count(*) as assets, count(distinct sort_order) as distinct_orders
from public.title_assets group by title_id, kind
order by title_id, kind;
-- assets and distinct_orders must be EQUAL on every row.
