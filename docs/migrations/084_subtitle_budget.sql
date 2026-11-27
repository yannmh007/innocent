-- 084 — a budget on online subtitles (P5, docs/handoff_2026_11_28_beyond_mx_p1.md).
--
-- WHAT WAS WRONG. CC → Online only shared an opensubtitles.org search
-- address: the viewer left the app, found a file, saved it and came back to
-- CC → Open. The owner wants subtitles found and loaded in the app.
--
-- WHAT THIS ADDS (additive: nothing an installed app reads changes).
--   The edge function `subtitles-online` (docs/edge/subtitles-online.ts)
--   holds the OpenSubtitles key and the owner's one account, which every
--   viewer shares: its downloads a day are few (the account's own quota,
--   read from each answer as `remaining`). So every call takes from a
--   budget, per install and per network, before the function asks
--   OpenSubtitles:
--
--     per install (the app's device id)   40 searches an hour, 5 downloads a day
--     per network (HMAC of the address)  200 searches an hour, 10 downloads a day
--
--   The network's caps are looser for a search (carrier-grade NAT puts many
--   viewers behind one address, as 046 says) and tight for a download, the
--   scarce thing: one address cannot take the whole day's quota.
--   * subtitle_budget — one row per subject, this hour's searches and
--     today's downloads, reset in place (no clean-up job), as 046's
--     playback_budget. RLS on, no policy; the service role only.
--   * take_subtitle_budget(device, ip, kind) — null when the call may go
--     ahead, else the budget that ran out ('install_hourly_searches',
--     'network_daily_downloads', …). A refused attempt still counts, as 046.
--   * give_back_subtitle_download(device, ip) — a download OpenSubtitles
--     refused or failed is given back, so its quota or an outage does not
--     spend a viewer's day.
--
-- PRIVACY. No address is stored: the network is HMAC(address, the events
-- salt) as in 041 and 046; an install id is a SHA-256 prefix.
--
-- CALLERS: docs/edge/subtitles-online.ts only (service role).
-- TEST: tool/sql/subtitle_budget_test.sql (ends in 'SUBTITLE BUDGET TEST PASSED').

create table if not exists public.subtitle_budget (
  subject   text        primary key,       -- 'd:<install hash>' | 'n:<network hash>'
  hour      timestamptz not null,          -- the hour `searches` counts
  searches  integer     not null default 0,
  day       date        not null,          -- the day (UTC) `downloads` counts
  downloads integer     not null default 0
);

alter table public.subtitle_budget enable row level security;
-- No policies: only the service role (subtitles-online, through the
-- functions below) touches it.
revoke all on public.subtitle_budget from public, anon, authenticated;
grant select, insert, update, delete on public.subtitle_budget to service_role;

create or replace function public.take_subtitle_budget(
  p_device text, p_ip text, p_kind text)
returns text language plpgsql security definer
set search_path = public, extensions as $fn$
declare
  hr     timestamptz := date_trunc('hour', now());
  today  date := (now() at time zone 'utc')::date;
  salt   text;
  subj   text[] := '{}';
  hourly integer[] := '{}';
  daily  integer[] := '{}';
  label  text[] := '{}';
  s      integer;
  d      integer;
begin
  if p_kind not in ('search', 'download') then
    raise exception 'take_subtitle_budget: kind must be search or download';
  end if;
  if p_device is not null and length(p_device) > 0 then
    subj := subj || ('d:' || left(encode(digest(p_device, 'sha256'), 'hex'), 32));
    hourly := hourly || 40; daily := daily || 5; label := label || 'install'::text;
  end if;
  if p_ip is not null and length(p_ip) > 0 then
    select e.salt into salt from public.event_secrets e where e.id = 1;
    if salt is not null then
      subj := subj || ('n:' || left(encode(hmac(p_ip, salt, 'sha256'), 'hex'), 32));
      hourly := hourly || 200; daily := daily || 10; label := label || 'network'::text;
    end if;
  end if;
  if coalesce(array_length(subj, 1), 0) = 0 then
    -- Nobody to count against: the function refuses such a call first.
    return 'anonymous';
  end if;

  for i in 1 .. array_length(subj, 1) loop
    insert into public.subtitle_budget as b (subject, hour, searches, day, downloads)
      values (subj[i], hr,
              case when p_kind = 'search' then 1 else 0 end, today,
              case when p_kind = 'download' then 1 else 0 end)
      on conflict (subject) do update set
        searches  = case when b.hour = hr then b.searches else 0 end
                    + case when p_kind = 'search' then 1 else 0 end,
        hour      = hr,
        downloads = case when b.day = today then b.downloads else 0 end
                    + case when p_kind = 'download' then 1 else 0 end,
        day       = today
      returning b.searches, b.downloads into s, d;
    if p_kind = 'search' and s > hourly[i] then
      return label[i] || '_hourly_searches';
    end if;
    if p_kind = 'download' and d > daily[i] then
      return label[i] || '_daily_downloads';
    end if;
  end loop;
  return null;
end;
$fn$;

create or replace function public.give_back_subtitle_download(
  p_device text, p_ip text)
returns void language plpgsql security definer
set search_path = public, extensions as $fn$
declare
  today date := (now() at time zone 'utc')::date;
  salt  text;
  subj  text[] := '{}';
begin
  if p_device is not null and length(p_device) > 0 then
    subj := subj || ('d:' || left(encode(digest(p_device, 'sha256'), 'hex'), 32));
  end if;
  if p_ip is not null and length(p_ip) > 0 then
    select e.salt into salt from public.event_secrets e where e.id = 1;
    if salt is not null then
      subj := subj || ('n:' || left(encode(hmac(p_ip, salt, 'sha256'), 'hex'), 32));
    end if;
  end if;
  update public.subtitle_budget
     set downloads = greatest(downloads - 1, 0)
   where subject = any(subj) and day = today;
end;
$fn$;

revoke execute on function public.take_subtitle_budget(text, text, text)
  from public, anon, authenticated;
grant execute on function public.take_subtitle_budget(text, text, text)
  to service_role;
revoke execute on function public.give_back_subtitle_download(text, text)
  from public, anon, authenticated;
grant execute on function public.give_back_subtitle_download(text, text)
  to service_role;
