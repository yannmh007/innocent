-- 031 — a thirty-character picture of every album item, for the data saver.
--
-- WHAT THE APP NEEDS. With the data saver on, an album must show what is in
-- it WITHOUT fetching it: Telegram's frosted tiles, each with a download
-- button, and the real photo only when the viewer asks for that one. The
-- frosting has to come from somewhere other than the photo, or drawing it
-- costs exactly what it was meant to save.
--
-- A BLURHASH, NOT A TINY JPEG. A 24-pixel JPEG is mostly header — six to nine
-- hundred bytes once its tables are in — and base64 makes that a kilobyte per
-- item, on every album request, data saver or not. A blurhash of 4×3
-- components is about thirty characters and decodes to the same soft shape
-- and colour. Sixty items cost under two kilobytes.
--
-- WHO MAKES THEM. The ingest runner, on its usual tick: `previews_due` hands it
-- items with no preview and the PUBLIC address of a picture of each — the
-- photo itself, a clip's thumbnail, or the title's poster for a clip without
-- one — and `preview_set` records the answer. Public addresses only: the
-- runner still holds no bucket credentials and learns nothing private.
--
-- A FAILURE IS RECORDED TOO (`preview_at` with no preview), so an image the
-- runner cannot read is retried daily rather than on every tick for ever.

alter table public.title_assets
  add column if not exists preview text,
  add column if not exists preview_at timestamptz;

-- A blurhash is short by construction. Anything long is not one, and must not
-- become a way to put a kilobyte into every album response.
alter table public.title_assets
  drop constraint if exists title_assets_preview_short;
alter table public.title_assets
  add constraint title_assets_preview_short
  check (preview is null or (length(preview) between 6 and 100));

-- title_media gains `preview`, appended after migration 030's columns.
-- Owner rights restated: see 013b and 030.
create or replace view public.title_media as
 select a.id,
    a.title_id,
    a.kind,
    a.is_free,
    a.sort_order,
    a.duration_s,
    a.width,
    a.height,
    a.label,
    a.language,
        case
            when a.kind = 'photo'::text then public_asset_base() || a.object_key
            else null::text
        end as url,
    coalesce(
        case
            when a.thumb_key is not null then public_asset_base() || a.thumb_key
            else null::text
        end,
        case
            when a.kind = 'photo'::text then public_asset_base() || a.object_key
            else null::text
        end, t.poster_url) as thumb_url,
    (a.kind <> 'photo' and a.object_key = t.locator) as is_main,
    a.bytes,
    a.preview
   from title_assets a
     join titles t on t.id = a.title_id
  where t.published and (a.kind = any (array['video'::text, 'clip'::text, 'trailer'::text, 'photo'::text]));

alter view public.title_media set (security_invoker = false);

-- Items with no preview, each with a PUBLIC picture to make one from. Newest
-- titles first, so what was just published gets its frosting soonest.
create or replace function public.previews_due(p_limit int default 40)
returns table (id uuid, source_url text)
language sql
stable
security definer
set search_path = public
as $$
  select a.id,
         case
           when a.kind = 'photo' then public_asset_base() || a.object_key
           when a.thumb_key is not null then public_asset_base() || a.thumb_key
           else t.poster_url
         end as source_url
    from title_assets a
    join titles t on t.id = a.title_id
   where a.kind in ('video', 'clip', 'trailer', 'photo')
     and a.preview is null
     and (a.preview_at is null or a.preview_at < now() - interval '1 day')
     and (a.kind = 'photo' or a.thumb_key is not null
          or coalesce(t.poster_url, '') <> '')
   order by t.created_at desc, a.sort_order
   limit greatest(1, least(coalesce(p_limit, 40), 200));
$$;

-- Records one answer. A null or empty preview is a failure, kept as a time so
-- `previews_due` waits a day before asking again.
create or replace function public.preview_set(p_id uuid, p_preview text)
returns void
language sql
volatile
security definer
set search_path = public
as $$
  update title_assets
     set preview = nullif(btrim(coalesce(p_preview, '')), ''),
         preview_at = now()
   where id = p_id;
$$;

revoke all on function public.previews_due(int) from public, anon, authenticated;
revoke all on function public.preview_set(uuid, text) from public, anon, authenticated;
grant execute on function public.previews_due(int) to service_role;
grant execute on function public.preview_set(uuid, text) to service_role;

insert into public.schema_migrations (version, note)
values ('031', 'album previews: a blurhash per item, made by the runner, for the data saver')
on conflict (version) do nothing;
