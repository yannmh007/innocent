-- 050 — A NEW VERSION NEEDS ITS OWN FILE'S FINGERPRINT (2026-10-25)
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. It deletes nothing and changes no row.
--
-- FOUND BY a phone: 1.64.74 was published with its new version, links and
-- notes, but `apk_sha256` and `apk_bytes` (and the arm32 pair) still
-- described 1.64.73's file. Every phone downloaded the right APK, found it
-- 1,348 bytes longer than the row said, and showed "Download was damaged.
-- Try again." — on every network, with or without a VPN, until the row was
-- corrected.
--
-- NOW an update that changes `version_code` must also change the file's
-- fingerprint and size, for the 64-bit APK and, when there is one, the
-- 32-bit APK. The build's summary prints the full statement to run.

create or replace function public.app_releases_new_file()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.version_code is distinct from old.version_code then
    if new.apk_sha256 is not distinct from old.apk_sha256
       or new.apk_bytes is not distinct from old.apk_bytes then
      raise exception 'version % needs its own apk_sha256 and apk_bytes (the build summary prints them)',
        new.version_name;
    end if;
    if new.apk_url_arm32 is not null and (
         new.apk_sha256_arm32 is not distinct from old.apk_sha256_arm32
         or new.apk_bytes_arm32 is not distinct from old.apk_bytes_arm32) then
      raise exception 'version % needs its own apk_sha256_arm32 and apk_bytes_arm32 (the build summary prints them)',
        new.version_name;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists app_releases_new_file on public.app_releases;
create trigger app_releases_new_file
  before update on public.app_releases
  for each row execute function public.app_releases_new_file();
