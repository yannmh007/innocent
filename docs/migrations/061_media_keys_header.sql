-- 061 — media seal: each object's header beside its key (docs/MEDIA_ENCRYPTION.md §5).
--
-- The first 40 bytes of a sealed object — the format byte, the HKDF salt and
-- the nonce prefix — are not secret, and with them the phone can open any
-- segment first: a resume or a seek straight into a film then needs no round
-- trip for the head. request-playback sends it in the seal block when the
-- row has it; the phone reads the head itself when it does not.
--
-- base64 of 40 bytes: 56 characters, 'K' first (0x28) and '==' last.

alter table public.media_keys
  add column if not exists header text;

alter table public.media_keys drop constraint if exists media_keys_header_ck;
alter table public.media_keys add constraint media_keys_header_ck
  check (header is null or (length(header) = 56 and header ~ '^K[A-Za-z0-9+/]{53}==$'));

comment on column public.media_keys.header is
  'base64 of the sealed object''s first 40 bytes (0x28, salt, nonce prefix). Not secret.';
