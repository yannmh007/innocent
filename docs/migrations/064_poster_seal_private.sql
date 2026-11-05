-- 064 — a poster's seal, off the API (follows 063).
--
-- 063 put `_poster_seal` in `public`, so besides serving `title_cards`, the
-- landing cards and `titles.poster_seal`, PostgREST answered it as
-- `/rest/v1/rpc/_poster_seal` (the security advisor's lint 0028/0029). It
-- only ever answered for the poster of a published title, which the
-- catalogue shows anyone; still, nothing needs it there. It moves to a
-- schema PostgREST does not expose: the app roles may use the schema, so
-- `title_cards` (security invoker) still reaches it, but no URL does.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

create or replace function private.poster_seal_of(p_url text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when p_url is not null
            and left(p_url, length(public.public_asset_base())) = public.public_asset_base()
            and exists (select 1 from public.titles t where t.poster_url = p_url and t.published)
           then public._image_seal(substr(p_url, length(public.public_asset_base()) + 1))
         end
$$;
revoke all on function private.poster_seal_of(text) from public;
grant execute on function private.poster_seal_of(text) to anon, authenticated, service_role;

create or replace function public.poster_seal(t public.titles)
returns jsonb
language sql
stable
set search_path = ''
as $$ select private.poster_seal_of(t.poster_url) $$;

create or replace view public.title_cards
with (security_invoker = true) as
 select id, title, title_mm, synopsis, category, poster_url, year, rating, quality_label, genres,
    episode_count, view_count, access_tier, photo_count, video_count, is_featured, category_code,
    genre_codes, private.poster_seal_of(poster_url) as poster_seal
   from public.titles
  where published;

create or replace function public._card(tt public.titles)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', tt.id, 'title', tt.title, 'title_mm', tt.title_mm, 'synopsis', tt.synopsis,
    'category', tt.category, 'category_code', tt.category_code, 'poster_url', tt.poster_url,
    'year', tt.year, 'rating', tt.rating, 'quality_label', tt.quality_label,
    'genres', tt.genres, 'genre_codes', tt.genre_codes, 'episode_count', tt.episode_count,
    'view_count', tt.view_count, 'access_tier', tt.access_tier,
    'photo_count', tt.photo_count, 'video_count', tt.video_count,
    'poster_seal', private.poster_seal_of(tt.poster_url));
$$;

-- title_media's thumb_seal falls back to the poster's: the same definition
-- as 063 with the call moved. Only that column's expression changes.

create or replace view public.title_media
with (security_invoker = false) as
 with viewer as (
         select auth.uid() is not null and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false as registered,
            (exists ( select 1
                   from public.subscriptions s
                  where s.user_id = auth.uid() and (s.expires_at is null or s.expires_at > now()))) as premium
        ), assets as (
         select a.id, a.title_id, a.kind, a.bucket, a.object_key, a.thumb_key, a.is_primary,
            a.is_free, a.sort_order, a.label, a.language, a.duration_s, a.width, a.height,
            a.bytes, a.mime, a.extra, a.added_at, a.transcode_state, a.transcode_note,
            a.transcode_at, a.master_state, a.master_moved_at, a.archived_ladder, a.preview,
            a.preview_at, t.access_tier, t.locator, t.poster_url,
            count(*) filter (where a.kind = 'photo') over (partition by a.title_id order by a.sort_order, a.id
              rows between unbounded preceding and current row) as photo_no
           from public.title_assets a
             join public.titles t on t.id = a.title_id
          where t.published and (a.kind = any (array['video', 'clip', 'trailer', 'photo']))
        ), judged as (
         select x.*,
            x.kind <> 'photo' or x.access_tier = 'free' or x.is_free or v.premium
              or x.photo_no <= case when v.registered then 5 else 3 end as may_open
           from assets x
             cross join viewer v
        )
 select id,
    title_id,
    kind,
    is_free,
    sort_order,
    duration_s,
    width,
    height,
    label,
    language,
        case
            when kind = 'photo' and may_open then public.public_asset_base() || object_key
            else null
        end as url,
        case
            when may_open then coalesce(
            case
                when thumb_key is not null then public.public_asset_base() || thumb_key
                else null
            end,
            case
                when kind = 'photo' then public.public_asset_base() || object_key
                else null
            end, poster_url)
            else null
        end as thumb_url,
    kind <> 'photo' and object_key = locator as is_main,
    bytes,
    preview,
        case
            when kind = 'photo' and may_open then public._image_seal(object_key)
            else null
        end as seal,
        case
            when not may_open then null
            when thumb_key is not null then public._image_seal(thumb_key)
            when kind = 'photo' then public._image_seal(object_key)
            else private.poster_seal_of(poster_url)
        end as thumb_seal
   from judged j;

drop function if exists public._poster_seal(text);
