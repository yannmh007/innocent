-- 056 — the payment-proofs bucket takes a sealed receipt (2026-10-30).
--
-- premium-request.ts now stores a screenshot sealed (docs/edge/pii.ts
-- sealFile) when PII_ENC_KEY is set: `<user>/<request>.sealed`, sent as
-- application/octet-stream, 32 bytes longer than the picture (`IBK1`, the IV,
-- the tag). The bucket from migration 040 took only the three image types, and
-- exactly 5 MB, which a 5 MB picture sealed is over. The function still
-- refuses anything over 5 MB that is not a PNG, JPEG or WebP by its bytes;
-- this only lets the sealed form of one through.

update storage.buckets
   set allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp',
                                  'application/octet-stream'],
       file_size_limit = 5242880 + 1024
 where id = 'payment-proofs';

insert into public.schema_migrations (version, note)
values ('056', 'payment-proofs bucket takes a sealed receipt')
on conflict (version) do nothing;
