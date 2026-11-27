-- The online subtitles' budget   (migration 084)
--
-- Run inside one transaction that ends on a deliberate exception. Success is
-- the message `SUBTITLE BUDGET TEST PASSED`. Its subjects are this test's own
-- install ids and a documentation address (198.51.100.0/24), so no real
-- viewer's row is read or changed.
--   1. an install's 40 searches an hour go through, the 41st is refused;
--   2. its 5 downloads a day go through, the 6th is refused, and a download
--      given back makes room for one more;
--   3. a search does not spend a download, nor a download a search;
--   4. a network's 10 downloads a day bind across installs;
--   5. a call with neither an install nor an address is refused;
--   6. anon and authenticated cannot call either function or read the table.
do $$
declare
  r text;
  i int;
begin
  -- 1.
  for i in 1 .. 40 loop
    r := public.take_subtitle_budget('subtest-install-a', null, 'search');
    if r is not null then
      raise exception 'case 1: search % refused (%)', i, r;
    end if;
  end loop;
  r := public.take_subtitle_budget('subtest-install-a', null, 'search');
  if r is distinct from 'install_hourly_searches' then
    raise exception 'case 1: the 41st search was %', coalesce(r, 'allowed');
  end if;

  -- 2. and 3. (install a has spent its searches, not its downloads)
  for i in 1 .. 5 loop
    r := public.take_subtitle_budget('subtest-install-a', null, 'download');
    if r is not null then
      raise exception 'case 2/3: download % refused (%)', i, r;
    end if;
  end loop;
  r := public.take_subtitle_budget('subtest-install-a', null, 'download');
  if r is distinct from 'install_daily_downloads' then
    raise exception 'case 2: the 6th download was %', coalesce(r, 'allowed');
  end if;
  perform public.give_back_subtitle_download('subtest-install-a', null);
  perform public.give_back_subtitle_download('subtest-install-a', null);
  r := public.take_subtitle_budget('subtest-install-a', null, 'download');
  if r is not null then
    raise exception 'case 2: a download given back made no room (%)', r;
  end if;

  -- 4. ten installs behind one address: the 11th download is the network's.
  if exists (select 1 from public.event_secrets where id = 1 and salt is not null) then
    for i in 1 .. 10 loop
      r := public.take_subtitle_budget('subtest-net-' || i, '198.51.100.7', 'download');
      if r is not null then
        raise exception 'case 4: download % behind one address refused (%)', i, r;
      end if;
    end loop;
    r := public.take_subtitle_budget('subtest-net-11', '198.51.100.7', 'download');
    if r is distinct from 'network_daily_downloads' then
      raise exception 'case 4: the 11th download behind one address was %', coalesce(r, 'allowed');
    end if;
  else
    raise notice 'case 4 skipped: no events salt';
  end if;

  -- 5.
  r := public.take_subtitle_budget(null, null, 'search');
  if r is distinct from 'anonymous' then
    raise exception 'case 5: a call naming nobody was %', coalesce(r, 'allowed');
  end if;

  -- 6.
  if has_function_privilege('anon', 'public.take_subtitle_budget(text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.take_subtitle_budget(text, text, text)', 'execute')
     or has_function_privilege('anon', 'public.give_back_subtitle_download(text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.give_back_subtitle_download(text, text)', 'execute') then
    raise exception 'case 6: a client role may call the budget';
  end if;
  if has_table_privilege('anon', 'public.subtitle_budget', 'select')
     or has_table_privilege('authenticated', 'public.subtitle_budget', 'select') then
    raise exception 'case 6: a client role may read the budget';
  end if;
  if not has_function_privilege('service_role', 'public.take_subtitle_budget(text, text, text)', 'execute')
     or not has_table_privilege('service_role', 'public.subtitle_budget', 'update') then
    raise exception 'case 6: the service role cannot use the budget';
  end if;

  raise exception 'SUBTITLE BUDGET TEST PASSED';
end $$;
