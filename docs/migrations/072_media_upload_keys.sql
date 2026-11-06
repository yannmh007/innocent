-- 072 — the console's uploads seal in the browser (docs/MEDIA_ENCRYPTION.md
-- §7.3, ENC-4 step 4).
--
-- A key ISSUED FOR AN UPLOAD THAT HAS NOT FINISHED. The studio function
-- issues a DEK when an upload begins (media_issue.js `issue`), hands the
-- DEK to the operator's browser, which seals each 16 MiB part on the phone,
-- and keeps the wrap here — never the DEK — until the upload is recorded:
--
--   · RESUME. A tab that died is picked up again on the same phone, and the
--     parts not yet sent must be sealed under the same DEK (the header, its
--     salt and nonce prefix, are already in part 1). The phone keeps the
--     header and each part's plaintext SHA-256, never the DEK; the studio
--     unwraps the DEK again from this row — only for an upload still
--     pending, only to the admin who began it (or the owner), only within
--     the eight days R2 keeps an unfinished upload.
--   · RECORD. `sealCommit` records the key row from THIS row's wrap, not
--     from anything the browser sends, so a browser can record only a key
--     the studio issued, for the object it was issued for. The row then
--     goes: a recorded key is never unwrapped for a browser again.
--
-- Service role only; no app role and no admin reads it directly.

create table if not exists public.media_upload_keys (
  dek_id      uuid primary key,
  bucket      text not null,
  sealed_key  text not null unique check (sealed_key ~ '^s/[0-9a-f]{32}$'),
  -- A twin's plain object (canary photos and stills); null: born sealed.
  plain_key   text,
  kind        text not null check (kind in ('video', 'image')),
  media_kind  text not null default 'video' check (media_kind in ('video', 'photo', 'other')),
  wrapped     text not null check (length(wrapped) = 80),
  plain_size  bigint not null check (plain_size > 0),
  upload_id   text,
  admin_id    uuid,
  created_at  timestamptz not null default now()
);

alter table public.media_upload_keys enable row level security;
revoke all on public.media_upload_keys from anon, authenticated;
grant select, insert, update, delete on public.media_upload_keys to service_role;

create index if not exists media_upload_keys_created on public.media_upload_keys (created_at);
