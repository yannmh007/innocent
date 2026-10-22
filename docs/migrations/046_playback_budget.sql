-- 046 — a budget on playback grants.
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. Nothing here drops or deletes anything.
--
-- ═══════════════════════════════════════════════════════════════════════
-- WHY
-- ═══════════════════════════════════════════════════════════════════════
--
-- request-playback hands out a ten-minute link to any caller it may: a free
-- title to anyone, a premium one to a subscriber. Nothing counted how often.
-- A script with one account — or none, for a free title — could ask for
-- every film in the catalogue, as fast as the function answers, and pull
-- each one through the Worker at line speed (docs/security_streaming.md #4).
--
-- So every grant now takes from three budgets, by the hour, and from a daily
-- count of distinct titles:
--
--   per install (the app's device id)   300 grants an hour, 300 titles a day
--   per account                          600 grants an hour, 500 titles a day
--   per network (HMAC of the address)   1200 grants an hour
--
-- A person never comes near them. A grant is asked for when a title's page
-- is looked at (Play then opens at once), at Play, and once per ten-minute
-- link mid-film; a change of quality reuses the grant it has. An evening of
-- browsing and two films is a few dozen.
--
-- THE NETWORK BUDGET IS THE LOOSEST ON PURPOSE. Myanmar's mobile networks
-- put many subscribers behind one public address (carrier-grade NAT), so a
-- tight limit there would lock out a town. It exists for the caller who
-- invents a new install id on every request.
--
-- WHAT IT IS NOT: a byte meter. A grant is one link; what is fetched through
-- it is limited by the Worker.
--
-- ═══════════════════════════════════════════════════════════════════════
-- ONE ROW PER SUBJECT
-- ═══════════════════════════════════════════════════════════════════════
--
-- Each install, account and network has one row: this hour's count and
-- today's titles. A new hour or a new day resets the row in place, so the
-- table never needs a clean-up job and holds one small row per subject seen.
-- (A first version, 046a, kept a row per hour; its two tables were never
-- written and are set aside as zz_unused_046a_budget and
-- zz_unused_046a_titles. They can be dropped from the SQL editor.)
--
-- ═══════════════════════════════════════════════════════════════════════
-- PRIVACY
-- ═══════════════════════════════════════════════════════════════════════
--
-- No address is stored: the network is HMAC(address, the events salt) as in
-- 041. An install id is stored as a SHA-256 prefix.

create table if not exists public.playback_budget (
  subject text        primary key,         -- 'd:<install hash>' | 'u:<user id>' | 'n:<network hash>'
  hour    timestamptz not null,            -- the hour `grants` counts
  grants  integer     not null,
  day     date        not null,            -- the day (UTC) `titles` counts
  titles  uuid[]      not null default '{}'
);

alter table public.playback_budget enable row level security;
-- No policies: only the service role (request-playback) touches it.
revoke all on public.playback_budget from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- take_playback_budget: null when the grant may go ahead, otherwise the
-- budget that ran out ('install_hourly', 'account_daily_titles', …).
-- ═══════════════════════════════════════════════════════════════════════
--
-- A refused attempt still counts against the hour: a caller hammering a
-- closed door keeps it closed. A title already counted today is never
-- refused for being one too many — going back to a film is not a new one.
-- The list stops growing at its cap, so a row stays small.
create or replace function public.take_playback_budget(
  p_user uuid, p_device text, p_ip text, p_title uuid)
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
  cap    integer;
  n      integer;
  seen   boolean;
begin
  if p_device is not null and length(p_device) > 0 then
    subj := subj || ('d:' || left(encode(digest(p_device, 'sha256'), 'hex'), 32));
    hourly := hourly || 300; daily := daily || 300; label := label || 'install'::text;
  end if;
  if p_user is not null then
    subj := subj || ('u:' || p_user::text);
    hourly := hourly || 600; daily := daily || 500; label := label || 'account'::text;
  end if;
  if p_ip is not null and length(p_ip) > 0 then
    select e.salt into salt from public.event_secrets e where e.id = 1;
    if salt is not null then
      subj := subj || ('n:' || left(encode(hmac(p_ip, salt, 'sha256'), 'hex'), 32));
      hourly := hourly || 1200; daily := daily || 0; label := label || 'network'::text;
    end if;
  end if;

  for i in 1 .. coalesce(array_length(subj, 1), 0) loop
    cap := case when p_title is null then 0 else daily[i] end;
    insert into public.playback_budget as b (subject, hour, grants, day, titles)
      values (subj[i], hr, 1, today,
              case when cap > 0 then array[p_title] else '{}'::uuid[] end)
      on conflict (subject) do update set
        grants = case when b.hour = hr then b.grants + 1 else 1 end,
        hour   = hr,
        titles = case
                   when cap = 0 then
                     case when b.day = today then b.titles else '{}'::uuid[] end
                   when b.day <> today then array[p_title]
                   when p_title = any(b.titles) then b.titles
                   when cardinality(b.titles) >= cap then b.titles
                   else b.titles || p_title
                 end,
        day    = today
      returning b.grants, (cap = 0 or p_title = any(b.titles)) into n, seen;
    if n > hourly[i] then
      return label[i] || '_hourly';
    end if;
    if not seen then
      return label[i] || '_daily_titles';
    end if;
  end loop;
  return null;
end;
$fn$;

revoke execute on function public.take_playback_budget(uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.take_playback_budget(uuid, text, text, uuid)
  to service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- For the operator: who asked for the most today. Admin console only.
-- ═══════════════════════════════════════════════════════════════════════
create or replace view public.playback_heavy_today
with (security_invoker = true) as
  select subject,
         cardinality(titles)                        as titles_today,
         case when hour = date_trunc('hour', now()) then grants else 0 end
                                                    as grants_this_hour
    from public.playback_budget
   where day = (now() at time zone 'utc')::date
   order by titles_today desc, grants_this_hour desc;
revoke all on public.playback_heavy_today from public, anon, authenticated;
grant select on public.playback_heavy_today to service_role;
