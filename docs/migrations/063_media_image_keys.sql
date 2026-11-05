-- 063 — sealed images: the keys of posters and album photos, and where the
-- app finds them (docs/MEDIA_ENCRYPTION.md §5 photos, §6 images).
--
-- AS APPLIED, AND CORRECTED BY 064-066: the two helper functions moved to
-- the `private` schema (064 `poster_seal_of`, 065 `image_seal` — a view
-- checks a function's EXECUTE as its reader, and 063 left the app roles
-- without it), and the `titles.poster_seal` computed field was dropped (066:
-- the app roles may read only named columns of `titles`). Read 065 for the
-- definitions that are live.
--
-- A sealed image is opened on the phone with a DEK its row carries — not
-- wrapped for the install, as a film's is: a grid is a key per poster, and
-- the catalogue is read without a grant. So these DEKs are kept here in the
-- clear, where Cloudflare never sees them, and handed out exactly as the
-- image's address is:
--
--   * a POSTER's key to anyone who can see the title — the catalogue already
--     shows them its poster — in `title_cards`, the landing rows' cards
--     (`_card`) and, for a `titles` read, the computed field `poster_seal`;
--   * a PHOTO's key only beside the photo's address in `title_media`, which
--     already withholds a locked photo's address (`may_open`, migration 041).
--
-- Nothing changes for an app that does not ask: the old columns are as they
-- were, and a seal is only there once a sealed twin is recorded. Apps that
-- open seals select the new columns (MEDIA_SEAL builds, then every build).
--
-- THE TABLE IS NOBODY'S BUT THE OWNER'S. No grant to anon or authenticated;
-- the ingest function (service_role) records twins (select, insert only). The
-- one function an app role may call, `_poster_seal`, answers only for the
-- poster of a published title: asked about any other address (a premium
-- photo's, say), it says nothing.

create table if not exists public.media_image_keys (
  dek_id      uuid primary key,
  bucket      text not null,
  plain_key   text not null,
  sealed_key  text not null unique check (sealed_key ~ '^s/[0-9a-f]{32}$'),
  dek         text not null check (length(dek) = 44 and dek ~ '^[A-Za-z0-9+/]{43}=$'),
  header      text not null check (length(header) = 56 and header ~ '^K[A-Za-z0-9+/]{53}==$'),
  plain_size  bigint not null check (plain_size > 0),
  sealed_size bigint not null check (sealed_size > plain_size),
  created_at  timestamptz not null default now(),
  unique (bucket, plain_key)
);

comment on table public.media_image_keys is
  'Sealed twins of public-bucket images: DEK in the clear (base64), header, sizes. No app role may read it.';

alter table public.media_image_keys enable row level security;
revoke all on public.media_image_keys from public, anon, authenticated;
grant select, insert on public.media_image_keys to service_role;

-- The seal block of a public-bucket image, or null. For views and definer
-- functions only.
create or replace function public._image_seal(p_key text)
returns jsonb
language sql
stable
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
revoke all on function public._image_seal(text) from public, anon, authenticated;

-- A poster's seal, for anyone who can see its title. Only for the poster of
-- a PUBLISHED title: any other address gets null.
create or replace function public._poster_seal(p_url text)
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
revoke all on function public._poster_seal(text) from public;
grant execute on function public._poster_seal(text) to anon, authenticated, service_role;

-- `titles?select=…,poster_seal` (a PostgREST computed field).
create or replace function public.poster_seal(t public.titles)
returns jsonb
language sql
stable
set search_path = ''
as $$ select public._poster_seal(t.poster_url) $$;
grant execute on function public.poster_seal(public.titles) to anon, authenticated, service_role;

-- `title_cards`: the same columns, and the poster's seal last. The functions
-- returning `setof title_cards` select `c.*`, so the new column rides along.
create or replace view public.title_cards
with (security_invoker = true) as
 select id,
    title,
    title_mm,
    synopsis,
    category,
    poster_url,
    year,
    rating,
    quality_label,
    genres,
    episode_count,
    view_count,
    access_tier,
    photo_count,
    video_count,
    is_featured,
    category_code,
    genre_codes,
    public._poster_seal(poster_url) as poster_seal
   from public.titles
  where published;

-- The landing rows' cards.
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
    'poster_seal', public._poster_seal(tt.poster_url));
$$;

-- `title_media`: the same columns, and two last — the seal of `url` and of
-- `thumb_url`, each exactly when that address is given and for the same
-- object it names.
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
            else public._poster_seal(poster_url)
        end as thumb_seal
   from judged j;
