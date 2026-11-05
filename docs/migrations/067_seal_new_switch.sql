-- 067 — the pipelines' switch, and objects born sealed (docs/MEDIA_ENCRYPTION.md §7).
--
-- `admin_settings.seal_new`: what the pipelines make of a NEW object —
--   off     plain, as before (the default);
--   canary  for an open film only, the plain object AND a sealed twin made
--           by the same pipeline, at birth;
--   on      sealed only — after §9 C (min_supported, SEAL_MODE=on), never
--           before: a released app cannot open a sealed object.
-- Read by the functions that hand out work; a runner never decides.
--
-- An image born sealed has no plain object: its key row's plain_key is
-- null, and the asset row names its `s/<32 hex>` key — so the lookup finds a
-- row by its sealed key as well as its plain one (media_keys already allows
-- a null plain_key, and request-playback looks both up).

alter table public.admin_settings
  add column if not exists seal_new text not null default 'off';
alter table public.admin_settings drop constraint if exists admin_settings_seal_new_ck;
alter table public.admin_settings add constraint admin_settings_seal_new_ck
  check (seal_new in ('off', 'canary', 'on'));
comment on column public.admin_settings.seal_new is
  'Media seal for new objects: off | canary (open films get a sealed twin at birth) | on (sealed only; after min_supported and SEAL_MODE=on).';

alter table public.media_image_keys alter column plain_key drop not null;

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
     and (k.plain_key = p_key or k.sealed_key = p_key)
   limit 1
$$;
