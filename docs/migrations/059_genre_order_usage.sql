-- 059 — the console's genre list: order by arrows, and how many titles use
-- each (2026-10-31, TAX phase 2).
--
-- genre_move is category_move (035) for genres: one place up or down, in
-- one transaction, renumbering 1..n first so ties and gaps cannot make a
-- swap look ignored. genre_usage is what the console needs before it offers
-- Delete (only for a genre no title has) or shows what a merge will move.
-- Both are for the studio function (service role) only.

create or replace function public.genre_move(p_code text, p_dir text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  codes text[];
  i     integer;
  j     integer;
  tmp   text;
begin
  if p_dir not in ('up', 'down') then
    return jsonb_build_object('error', 'bad_direction');
  end if;
  perform pg_advisory_xact_lock(hashtext('genre_move'));
  select array_agg(g.code order by g.sort_order, g.code) into codes from public.genres g;
  i := array_position(codes, p_code);
  if i is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  j := case when p_dir = 'up' then i - 1 else i + 1 end;
  if j < 1 or j > array_length(codes, 1) then
    return jsonb_build_object('error', 'edge', 'order', to_jsonb(codes));
  end if;
  tmp := codes[i];
  codes[i] := codes[j];
  codes[j] := tmp;
  update public.genres g
     set sort_order = array_position(codes, g.code)
   where g.sort_order is distinct from array_position(codes, g.code);
  return jsonb_build_object('ok', true, 'order', to_jsonb(codes));
end;
$$;

create or replace function public.genre_usage()
returns table (code text, titles bigint, published bigint)
language sql
stable
security definer
set search_path to 'public'
as $$
  select u.code, count(*), count(*) filter (where t.published)
    from public.titles t, unnest(t.genre_codes) u(code)
   group by u.code;
$$;

revoke all on function public.genre_move(text, text) from public, anon, authenticated;
revoke all on function public.genre_usage() from public, anon, authenticated;
grant execute on function public.genre_move(text, text) to service_role;
grant execute on function public.genre_usage() to service_role;
