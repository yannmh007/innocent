-- 076 — a viewer can report a title, and the owner hears of it at once
-- (docs/security_review_2026_11.md S7/P6).
--
-- WHY. With no way to complain to us, a complaint about a title goes
-- straight to the host. A rights holder, a parent, a person in a film:
-- each should be able to reach the people who can act, and be answered.
-- This is the in-app half: Report on a title's page. The other half is
-- the takedown address shown in the app (About) and kept in this file's
-- notice: innocentmail69@gmail.com.
--
-- WHAT IS KEPT. The title, the reason, what the person wrote (at most
-- 1000 characters), a contact if they chose to give one (at most 200),
-- and who sent it only as far as a budget needs: the account if signed in,
-- the install and the network as hashes (041's HMAC; never an address).
--
-- A BUDGET, because report_content is open to anyone with the app's
-- publishable key: 5 a day per install, 20 a day per network, 200 a day in
-- all. Over it, the report is refused ('too_many') and nothing is kept.
--
-- THE OWNER IS TOLD on the ingest runner's next tick (a few minutes), in
-- Telegram: report_notice() returns the new reports once each. Service
-- role only; no app role reads the table.

create table if not exists public.content_reports (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  title_id    uuid references public.titles (id) on delete set null,
  reason      text not null check (reason in ('rights', 'illegal', 'minor', 'consent', 'other')),
  detail      text not null default '' check (length(detail) <= 1000),
  contact     text check (contact is null or length(contact) <= 200),
  user_id     uuid,
  install     text,          -- SHA-256 prefix of the install id
  network     text,          -- 041's HMAC of the address
  noticed_at  timestamptz,
  state       text not null default 'new' check (state in ('new', 'seen', 'acted', 'rejected'))
);

alter table public.content_reports enable row level security;
revoke all on public.content_reports from public, anon, authenticated;
grant select, insert, update, delete on public.content_reports to service_role;
create index if not exists content_reports_day on public.content_reports (created_at);
create index if not exists content_reports_unnoticed on public.content_reports (created_at)
  where noticed_at is null;

-- 'ok', 'too_many' or 'bad'. Nothing about the reporter is returned.
create or replace function public.report_content(
  p_title uuid, p_reason text, p_detail text default '', p_contact text default null)
returns text language plpgsql security definer
set search_path = public, extensions as $fn$
declare
  hdr     json := current_setting('request.headers', true)::json;
  raw_dev text := left(coalesce(hdr ->> 'x-install-id', ''), 128);
  dev     text := case when raw_dev = '' then null
                       else left(encode(digest(raw_dev, 'sha256'), 'hex'), 32) end;
  net     text := public._request_ip_hash();
  since   timestamptz := now() - interval '1 day';
  detail  text := left(btrim(coalesce(p_detail, '')), 1000);
  contact text := nullif(left(btrim(coalesce(p_contact, '')), 200), '');
begin
  if p_reason is null or p_reason not in ('rights', 'illegal', 'minor', 'consent', 'other') then
    return 'bad';
  end if;
  if p_title is not null and not exists (select 1 from public.titles t where t.id = p_title) then
    return 'bad';
  end if;
  if p_reason = 'other' and length(detail) = 0 then
    return 'bad';
  end if;
  if (dev is not null and (select count(*) from public.content_reports r
                            where r.install = dev and r.created_at > since) >= 5)
     or (net is not null and (select count(*) from public.content_reports r
                               where r.network = net and r.created_at > since) >= 20)
     or (select count(*) from public.content_reports r where r.created_at > since) >= 200 then
    return 'too_many';
  end if;
  insert into public.content_reports (title_id, reason, detail, contact, user_id, install, network)
  values (p_title, p_reason, detail, contact, auth.uid(), dev, net);
  return 'ok';
end;
$fn$;

revoke execute on function public.report_content(uuid, text, text, text) from public;
grant execute on function public.report_content(uuid, text, text, text) to anon, authenticated, service_role;

-- The new reports, as one Telegram message for the owner, each once.
create or replace function public.report_notice()
returns text language plpgsql security definer
set search_path = public as $fn$
declare
  r     record;
  lines text[] := '{}';
  why   text;
begin
  for r in
    with due as (
      select c.id from public.content_reports c
       where c.noticed_at is null
       order by c.created_at
       limit 10
       for update skip locked
    )
    update public.content_reports c
       set noticed_at = now()
      from due
     where c.id = due.id
    returning c.created_at, c.reason, c.detail, c.contact, c.user_id is not null as signed_in,
      (select coalesce(t.title, '?') from public.titles t where t.id = c.title_id) as title
  loop
    why := case r.reason
      when 'rights' then 'မူပိုင်ခွင့် (copyright)'
      when 'illegal' then 'တရားမဝင် အကြောင်းအရာ'
      when 'minor' then 'အရွယ်မရောက်သူ ပါဝင်နိုင်'
      when 'consent' then 'ပါဝင်သူ၏ ခွင့်ပြုချက် မရှိ'
      else 'အခြား' end;
    lines := lines || format('• %s — %s%s%s%s',
      coalesce(r.title, '(ဇာတ်ကား မဖော်ပြ)'), why,
      case when r.detail <> '' then chr(10) || '  "' || left(r.detail, 300) || '"' else '' end,
      case when r.contact is not null then chr(10) || '  ဆက်သွယ်ရန်: ' || r.contact else '' end,
      case when r.signed_in then ' (sign in ထားသူ)' else '' end);
  end loop;
  if cardinality(lines) = 0 then
    return null;
  end if;
  return 'Innocent — Report အသစ် ' || cardinality(lines) || ' ခု:' || chr(10) ||
    array_to_string(lines, chr(10)) || chr(10) ||
    'အရေးကြီးရင် ဇာတ်ကားကို console မှာ unpublish လုပ်ပါ။ ပြန်ကြားရန်: innocentmail69@gmail.com';
end;
$fn$;

revoke execute on function public.report_notice() from public, anon, authenticated;
grant execute on function public.report_notice() to service_role;
