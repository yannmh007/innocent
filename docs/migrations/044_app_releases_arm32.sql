-- 044 — app_releases: a second APK for phones that run 32-bit Android
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice.
--
-- WHY. The release APK carries arm64-v8a code only. A phone whose Android is
-- 32-bit — the Galaxy A10 and A02, many Android Go phones, older itel, TECNO
-- and Infinix models, all common in Myanmar — cannot install it at all:
-- "App not installed", and in Firebase Test Lab "Incompatible Architecture"
-- (run 37967931084). Their CPU is often 64-bit; the system on it is not, and
-- that is what decides. The Build workflow now also builds an armeabi-v7a
-- APK, `innocent-<name>-<code>-arm32.apk`, and these columns describe it.
--
-- SAME VERSION, SAME KEY, SAME NOTES. Only the file differs, so only the
-- file's three facts get columns of their own. An install picks the APK by
-- what its phone can run (lib/features/updater/domain/app_release.dart):
-- arm64 where the phone has it, this one where it does not. A 32-bit phone
-- is NEVER offered the arm64 file — the installer would refuse it after the
-- whole download — so while these are null it is told there is nothing to
-- download, which is the truth for it.
--
-- NULLABLE, like the arm64 columns were before their first APK. Builds
-- before 1.64.60 never ask for these columns, so adding them changes
-- nothing for them.

alter table public.app_releases
  add column if not exists apk_url_arm32    text,
  add column if not exists apk_sha256_arm32 text,
  add column if not exists apk_bytes_arm32  bigint;

comment on column public.app_releases.apk_url_arm32 is
  'The armeabi-v7a APK of the same release, for phones running 32-bit Android. Null = none published.';

insert into public.schema_migrations (version, note)
values ('044', 'app_releases: 32-bit APK columns')
on conflict (version) do nothing;
