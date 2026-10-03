-- 035 — move a category one place up or down, in one step
--
-- Asked 2026-10-03: "can Movies and Series swap places — with their content,
-- not just the name?" They can, and always could in principle: a title
-- belongs to a category by its ID (`titles.category = 'movies'`), and the
-- order of the tabs — and, since 034, of the category rows on All — is only
-- `categories.sort_order`. Swapping two numbers moves the whole section,
-- everything in it with it, and touches no title.
--
-- What it was not was EASY: the console had a number box per category, so a
-- swap meant typing two numbers right, and two rows left on the same number
-- order themselves by id — which reads as the app ignoring the change.
--
-- `category_move(id, 'up'|'down')` does it in one transaction: it renumbers
-- every category except `all` to 1..n in its current order (closing gaps and
-- ties), then swaps the one asked for with its neighbour. `all` stays at 0:
-- it is the landing tab, the app opens on it, and it is not a section with
-- content of its own. Hidden categories keep their place in the sequence, so
-- showing one again puts it back where it was.
--
-- Returns the new order (ids, first to last), or 'not_found' / 'fixed' /
-- 'edge' when there is nothing to do.

create or replace function public.category_move(p_id text, p_dir text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  ids  text[];
  i    integer;
  j    integer;
  tmp  text;
begin
  if p_id = 'all' then
    return jsonb_build_object('error', 'fixed');
  end if;
  if p_dir not in ('up', 'down') then
    return jsonb_build_object('error', 'bad_direction');
  end if;
  -- One move at a time: two operators pressing arrows together must not
  -- interleave their renumbering.
  perform pg_advisory_xact_lock(hashtext('category_move'));

  select array_agg(c.id order by c.sort_order, c.id) into ids
    from public.categories c
   where c.id <> 'all';
  i := array_position(ids, p_id);
  if i is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  j := case when p_dir = 'up' then i - 1 else i + 1 end;
  if j < 1 or j > array_length(ids, 1) then
    return jsonb_build_object('error', 'edge', 'order', to_jsonb(ids));
  end if;
  tmp := ids[i];
  ids[i] := ids[j];
  ids[j] := tmp;

  update public.categories c
     set sort_order = array_position(ids, c.id),
         updated_at = now()
   where c.id <> 'all'
     and c.sort_order is distinct from array_position(ids, c.id);
  update public.categories set sort_order = 0 where id = 'all' and sort_order <> 0;

  return jsonb_build_object('ok', true, 'order', to_jsonb(ids));
end;
$$;

revoke all on function public.category_move(text, text) from public, anon, authenticated;
grant execute on function public.category_move(text, text) to service_role;

insert into public.schema_migrations (version, note)
values ('035', 'category_move: swap a category with its neighbour, content and all')
on conflict (version) do nothing;
