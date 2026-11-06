-- 075 — tell the owner when one phone, account or network pulls a lot
-- (docs/security_review_2026_11.md S3/P3, step 3).
--
-- WHY. 046 caps grants: per install 300 an hour and 300 titles a day, per
-- account 600 and 500, per network 1200 an hour. Those caps are far above a
-- person on purpose. A grant is asked for when a title's page is opened, so
-- a tight daily cap would refuse someone who browses. That leaves a script
-- with a paid account room to sweep the catalogue under the cap, and nobody
-- would know. This tells the owner, in Telegram, the first time each day a
-- subject goes well past what a person does. It refuses nothing. What it
-- reports is also the measurement a lower cap would be set from.
--
-- WHAT THE OWNER SEES. Each subject's kind and an 8-character code:
--   account  the first 8 hex of SHA-256(account id): the same code the
--            player draws over a paid film, and the start of `u` in the
--            Worker's logs. docs/security.md §9 has the query that finds
--            the account from it.
--   install  the first 8 hex of SHA-256(install id): the code a signed-out
--            phone draws (the same §9 query, on devices).
--   network  the first 8 hex of the address's HMAC (046). It names nobody:
--            it says only that one network did it.
-- Never an id, an address or an e-mail.
--
-- ONCE A DAY per subject: `alerted` is the UTC day it was last reported.
-- Called on the ingest runner's tick (ingest.ts, beside storage_notice);
-- service role only.

alter table public.playback_budget
  add column if not exists alerted date;

create or replace function public.playback_watch_notice(
  p_titles integer default 60,         -- distinct titles today, install or account
  p_grants integer default 200,        -- grants this hour, install or account
  p_network_grants integer default 800 -- grants this hour, one network
) returns text
language plpgsql security definer
set search_path = public, extensions as $fn$
declare
  hr    timestamptz := date_trunc('hour', now());
  today date := (now() at time zone 'utc')::date;
  r     record;
  lines text[] := '{}';
begin
  for r in
    update public.playback_budget b
       set alerted = today
     where (b.alerted is distinct from today)
       and (
         (left(b.subject, 2) in ('d:', 'u:') and b.day = today and cardinality(b.titles) >= p_titles)
         or (left(b.subject, 2) in ('d:', 'u:') and b.hour = hr and b.grants >= p_grants)
         or (left(b.subject, 2) = 'n:' and b.hour = hr and b.grants >= p_network_grants)
       )
    returning
      left(b.subject, 1) as kind,
      case left(b.subject, 1)
        when 'u' then left(encode(digest(substr(b.subject, 3), 'sha256'), 'hex'), 8)
        else substr(b.subject, 3, 8)
      end as code,
      case when b.day = today then cardinality(b.titles) else 0 end as titles,
      case when b.hour = hr then b.grants else 0 end as grants
  loop
    lines := lines || format('• %s %s — ယနေ့ ဇာတ်ကား %s ကား၊ ဒီနာရီ grant %s ကြိမ်',
      case r.kind when 'u' then 'account' when 'd' then 'ဖုန်း (install)' else 'network' end,
      r.code, r.titles, r.grants);
  end loop;
  if cardinality(lines) = 0 then
    return null;
  end if;
  return 'Innocent — ဇာတ်ကား အများအပြား ဆွဲယူမှု (ပိတ်ထားခြင်း မရှိပါ၊ အသိပေးချက်သာ):' || chr(10) ||
    array_to_string(lines, chr(10)) || chr(10) ||
    'account/ဖုန်း ကုဒ်ကနေ ရှာနည်း: docs/security.md §9။ Worker logs မှာ u= ဒီကုဒ်နဲ့ စပြီး ဘယ်လောက်ဆွဲသွားလဲ ကြည့်လို့ရပါတယ်။';
end;
$fn$;

revoke execute on function public.playback_watch_notice(integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.playback_watch_notice(integer, integer, integer)
  to service_role;
