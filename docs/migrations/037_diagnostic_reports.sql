-- 037 — diagnostic_reports: a viewer's phone sends what it saw
--
-- WHY. The device lab (.github/workflows/device-lab.yml) runs the app on an
-- emulator over a network shaped like Myanmar's, but a shaped network is not
-- the real one, and an emulator has no real video decoder. The questions that
-- matter most — why a download crawled on THIS line, why a film would not
-- start on THIS phone — can only be answered from the phone it happened on.
-- Settings is too far from the moment; a viewer taps "Send diagnostics" on the
-- Account screen, sees exactly what will be sent, and gets a short code to
-- quote. The report is read by the operator (service role) and by nobody
-- else.
--
-- WHAT IS IN A REPORT. The app's own diagnostic trail (PlaybackLog: what each
-- download pass and each playback did, with links and tokens removed on the
-- phone before sending), the app version, the phone model and Android
-- version, and the connection type. No file names, no titles watched beyond
-- what the trail says, no location.
--
-- WHO MAY WRITE. Anyone using the app, signed in or not — a viewer with a
-- problem is often one who has not signed in. So the table defends itself:
-- lengths are capped by CHECK, and a flood guard refuses inserts once 300
-- reports have arrived in an hour. Nobody may read through the API: RLS has
-- no SELECT policy, and anon/authenticated hold INSERT only.

create table if not exists public.diagnostic_reports (
  id          bigint generated always as identity primary key,
  -- Made on the phone and shown to the viewer, so they can quote it. The
  -- phone cannot read its own row back (no SELECT), so the code is not
  -- returned by the server; it is chosen before sending.
  code        text not null check (code ~ '^[A-Z0-9]{6,12}$'),
  created_at  timestamptz not null default now(),
  user_id     uuid default auth.uid() references auth.users (id) on delete set null,
  app_version text check (app_version is null or length(app_version) <= 40),
  device      jsonb check (device is null or pg_column_size(device) <= 4096),
  network     text check (network is null or length(network) <= 200),
  note        text check (note is null or length(note) <= 1000),
  trail       text not null check (length(trail) <= 65536)
);

create index if not exists diagnostic_reports_code_idx on public.diagnostic_reports (code);
create index if not exists diagnostic_reports_created_idx on public.diagnostic_reports (created_at desc);

alter table public.diagnostic_reports enable row level security;

drop policy if exists diagnostic_reports_insert on public.diagnostic_reports;
create policy diagnostic_reports_insert on public.diagnostic_reports
  for insert to anon, authenticated
  -- A report may name no one, or the caller; never somebody else.
  with check (user_id is null or user_id = (select auth.uid()));

revoke all on public.diagnostic_reports from anon, authenticated;
grant insert on public.diagnostic_reports to anon, authenticated;

create or replace function public.diagnostic_reports_flood_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.diagnostic_reports
       where created_at > now() - interval '1 hour') >= 300 then
    raise exception 'too many diagnostic reports this hour'
      using errcode = 'P0001';
  end if;
  return new;
end
$$;

revoke all on function public.diagnostic_reports_flood_guard() from public, anon, authenticated;

drop trigger if exists diagnostic_reports_flood_guard on public.diagnostic_reports;
create trigger diagnostic_reports_flood_guard
  before insert on public.diagnostic_reports
  for each row execute function public.diagnostic_reports_flood_guard();

insert into public.schema_migrations (version, note)
values ('037', 'diagnostic_reports: insert-only reports from phones, flood-guarded')
on conflict (version) do nothing;
