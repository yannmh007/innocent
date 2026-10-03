-- 036 — bookmarks: titles a viewer saved for later
--
-- The account screen has had a "Bookmarks" shelf since the hub was built; it
-- said "coming soon". `docs/movies_data_model_v2.md` sketched the table as
-- `bookmarks (viewer_key, title_id, added_at)`. This is that, keyed by the
-- signed-in user.
--
-- WHY ON THE SERVER AT ALL. The app keeps bookmarks on the phone first — a tap
-- saves instantly, with or without a connection, signed in or not — and that
-- copy is what the shelf draws. This table is what makes them survive a
-- reinstall, a new phone, or signing in on a second one. The client pushes
-- adds and removes it made while signed in, then takes the server's list.
--
-- RLS does all of the authorisation: a row can only be read, added or removed
-- by the user it names, and `user_id` defaults to the caller, so the client
-- never sends one. `on delete cascade` from titles: a title taken down leaves
-- no dangling bookmark that would draw as a blank card.

create table if not exists public.bookmarks (
  user_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title_id  uuid not null references public.titles (id) on delete cascade,
  added_at  timestamptz not null default now(),
  primary key (user_id, title_id)
);

create index if not exists bookmarks_user_added_idx
  on public.bookmarks (user_id, added_at desc);

alter table public.bookmarks enable row level security;

drop policy if exists bookmarks_select_own on public.bookmarks;
create policy bookmarks_select_own on public.bookmarks
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists bookmarks_insert_own on public.bookmarks;
create policy bookmarks_insert_own on public.bookmarks
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists bookmarks_delete_own on public.bookmarks;
create policy bookmarks_delete_own on public.bookmarks
  for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.bookmarks from anon;
grant select, insert, delete on public.bookmarks to authenticated;

insert into public.schema_migrations (version, note)
values ('036', 'bookmarks: saved titles per user, RLS-owned, synced from the app')
on conflict (version) do nothing;
