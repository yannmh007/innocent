-- 051 — PUBLIC FILES ON OUR OWN DOMAIN (2026-10-27)
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. It deletes nothing.
--
-- Photos, posters and the APK moved from the r2.dev development URL to
-- cdn.innocentplayer.com, the public bucket's custom domain. On a zone of
-- ours the zone's rules (minimum TLS, WAF, a rate rule) stand in front of
-- them, and Cloudflare's cache serves them — r2.dev is rate-limited and,
-- in Cloudflare's own words, not for production.
--
-- 006 made public_asset_base() the one place the host is named, so every
-- poster and photo built from a key follows it. What was stored as a whole
-- URL is rewritten below: four open films' poster_url and the release row.

do $mig$
begin
  create or replace function public.public_asset_base()
  returns text language sql immutable as $fn$
    select 'https://cdn.innocentplayer.com/'
  $fn$;

  update public.titles
     set poster_url = replace(poster_url,
           'https://pub-18c62521649645be87d4d36225021e15.r2.dev/',
           'https://cdn.innocentplayer.com/')
   where poster_url like 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/%';

  -- version_code is unchanged, so 050's guard does not ask for a new file.
  update public.app_releases
     set apk_url = replace(apk_url,
           'https://pub-18c62521649645be87d4d36225021e15.r2.dev/',
           'https://cdn.innocentplayer.com/'),
         apk_url_arm32 = replace(apk_url_arm32,
           'https://pub-18c62521649645be87d4d36225021e15.r2.dev/',
           'https://cdn.innocentplayer.com/')
   where apk_url like 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/%'
      or apk_url_arm32 like 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/%';
end
$mig$;
