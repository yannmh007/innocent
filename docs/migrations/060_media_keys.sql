-- 060 — media seal keys (2026-11-01, ENC-2; docs/MEDIA_ENCRYPTION.md §4-5).
--
-- Every sealed photo and film has one row here: its DEK, wrapped by
-- MEDIA_KEK (an edge secret the owner set; never in this database), and the
-- sizes the phone's proxy needs to map a byte range. The table is for the
-- service role only: RLS on, no policy, no grant.
--
-- `plain_key` is the plaintext object a sealed one replaces while both exist
-- (rollout gates B-E): request-playback serves the sealed twin to an app that
-- says it can open it and the plaintext to one that cannot, so no installed
-- app stops playing. Born-sealed objects have none.
--
-- Additive: nothing reads it until request-playback is taught to, and
-- nothing is sealed until MEDIA_KEK exists.

create or replace function public.media_sealed_size(p_plain bigint)
returns bigint
language sql
immutable
strict
set search_path to 'public'
as $$
  -- Tink AES-GCM-HKDF streaming, 64 KiB segments: a 40-byte header, a
  -- first segment of 65480 plaintext bytes, then 65520 per segment, 16 bytes
  -- of tag each (tool/media_seal.py sealed_size).
  select 40 + p_plain + 16 * (case when p_plain <= 65480 then 1
                                   else 1 + ((p_plain - 65480) + 65519) / 65520 end);
$$;

create table if not exists public.media_keys (
  dek_id      uuid primary key default gen_random_uuid(),
  bucket      text not null,
  sealed_key  text not null,
  plain_key   text,
  kek_version smallint not null default 1 check (kek_version >= 1),
  -- base64(nonce 12 || AES-256-GCM(DEK) 32 || tag 16): 80 characters.
  wrapped     text not null check (length(wrapped) = 80),
  plain_size  bigint not null check (plain_size >= 0),
  sealed_size bigint not null,
  kind        text not null check (kind in ('video', 'photo', 'other')),
  created_at  timestamptz not null default now(),
  constraint media_keys_sealed_key_key unique (bucket, sealed_key),
  constraint media_keys_size_ck check (sealed_size = public.media_sealed_size(plain_size))
);

create index if not exists media_keys_plain_key_idx
  on public.media_keys (bucket, plain_key) where plain_key is not null;

alter table public.media_keys enable row level security;
revoke all on public.media_keys from public, anon, authenticated;

comment on table public.media_keys is
  'Media seal v1 DEKs, wrapped by MEDIA_KEK. Service role only. docs/MEDIA_ENCRYPTION.md';

-- The phone's key for receiving DEKs (§5): the SPKI of an Android Keystore
-- RSA-2048 key, pinned on first use. A DEK in a grant is wrapped for it with
-- RSA-OAEP (SHA-1, MGF1-SHA-1).
alter table public.devices
  add column if not exists public_key text,
  add column if not exists public_key_at timestamptz;

alter table public.devices drop constraint if exists devices_public_key_ck;
alter table public.devices add constraint devices_public_key_ck
  check (public_key is null or (length(public_key) between 300 and 600
                                and public_key ~ '^[A-Za-z0-9+/=]+$'));
