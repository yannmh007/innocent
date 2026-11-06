-- 065 — the image seal function in `private`, where the app roles may run it.
--
-- A view checks a FUNCTION's EXECUTE as the user reading it, not as the
-- view's owner. 063 revoked `public._image_seal` from anon and
-- authenticated, and `title_media` then refused them ("permission denied for
-- function _image_seal") — for six minutes on 5 Nov (07:53-07:59 UTC), with no
-- app request in that window (the database's error log holds only the two
-- test queries that found it). In `private`, which PostgREST does not expose,
-- the roles may execute it inside the views and no URL reaches it.
--
-- Read as anon and as authenticated after this: title_cards 4 rows,
-- title_media 20 (16 with an address), landing_rows, search_titles and
-- row_catalogue all answer.

create or replace function private.image_seal(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'v', 1,
           'url', public.public_asset_base() || k.sealed_key,
           'dek_id', k.dek_id,
           'plain_size', k.plain_size,
           'sealed_size', k.sealed_size,
           'wrap', 'tls',
           'dek', k.dek,
           'header', k.header)
    from public.media_image_keys k
   where k.bucket = 'innocent-public'
     and k.plain_key = p_key
$$;
revoke all on function private.image_seal(text) from public;
grant execute on function private.image_seal(text) to anon, authenticated, service_role;

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
           then private.image_seal(substr(p_url, length(public.public_asset_base()) + 1))
         end
$$;

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
            when kind = 'photo' and may_open then private.image_seal(object_key)
            else null
        end as seal,
        case
            when not may_open then null
            when thumb_key is not null then private.image_seal(thumb_key)
            when kind = 'photo' then private.image_seal(object_key)
            else private.poster_seal_of(poster_url)
        end as thumb_seal
   from judged j;

drop function if exists public._image_seal(text);
