-- The owner told when one subject pulls a lot   (migration 075)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `PLAYBACK WATCH TEST PASSED`;
-- any other exception names the case that failed.
--
-- The cases that matter: a person's day says nothing; a sweep is reported
-- once a day, not on every tick; the code is the one the player draws, so
-- the owner can find the account; and nothing that names anyone is in it.
do $$
declare
  today date := (now() at time zone 'utc')::date;
  hr    timestamptz := date_trunc('hour', now());
  uid   uuid := '00000000-0000-4000-8000-0000000000a7';
  dev   text := 'lab-install-watch-test';
  code_u text := left(encode(digest(uid::text, 'sha256'), 'hex'), 8);
  code_d text := left(encode(digest(dev, 'sha256'), 'hex'), 8);
  many  uuid[];
  few   uuid[];
  msg   text;
begin
  select array_agg(gen_random_uuid()) into many from generate_series(1, 70);
  select array_agg(gen_random_uuid()) into few from generate_series(1, 12);

  -- Only these rows, for the length of the test.
  delete from public.playback_budget;

  -- ── an ordinary evening says nothing ───────────────────────────────────
  insert into public.playback_budget (subject, hour, grants, day, titles) values
    ('u:' || uid, hr, 30, today, few),
    ('d:' || left(encode(digest(dev, 'sha256'), 'hex'), 32), hr, 30, today, few),
    ('n:' || repeat('ab', 16), hr, 500, today, '{}');
  msg := public.playback_watch_notice();
  if msg is not null then raise exception 'an ordinary day was reported: %', msg; end if;

  -- ── yesterday's sweep is not today's news ──────────────────────────────
  update public.playback_budget set titles = many, day = today - 1 where subject = 'u:' || uid;
  msg := public.playback_watch_notice();
  if msg is not null then raise exception 'yesterday was reported as today: %', msg; end if;

  -- ── a sweep today: reported, with the player's code ────────────────────
  update public.playback_budget set titles = many, day = today where subject = 'u:' || uid;
  msg := public.playback_watch_notice();
  if msg is null then raise exception 'seventy titles in a day were not reported'; end if;
  if position(code_u in msg) = 0 then
    raise exception 'the account was not named by its player code: %', msg;
  end if;
  if position(uid::text in msg) > 0 then raise exception 'the account id itself is in the notice'; end if;
  if position('70' in msg) = 0 then raise exception 'the count is not in the notice: %', msg; end if;

  -- ── and only once that day ─────────────────────────────────────────────
  msg := public.playback_watch_notice();
  if msg is not null then raise exception 'the same subject was reported twice in a day: %', msg; end if;

  -- ── an install hammering this hour; a network past its own line ────────
  update public.playback_budget set grants = 250
   where subject = 'd:' || left(encode(digest(dev, 'sha256'), 'hex'), 32);
  update public.playback_budget set grants = 900 where subject = 'n:' || repeat('ab', 16);
  msg := public.playback_watch_notice();
  if msg is null or position(code_d in msg) = 0 then
    raise exception 'an install at 250 grants an hour was not reported by its code: %', msg;
  end if;
  if position('network ' || repeat('ab', 4) in msg) = 0 then
    raise exception 'a network at 900 grants an hour was not reported: %', msg;
  end if;
  if position(dev in msg) > 0 then raise exception 'the install id itself is in the notice'; end if;

  -- ── the thresholds are the caller's ────────────────────────────────────
  update public.playback_budget set alerted = null;
  msg := public.playback_watch_notice(1000, 100000, 100000);
  if msg is not null then raise exception 'thresholds were not honoured: %', msg; end if;

  -- ── no app role may call it ────────────────────────────────────────────
  if has_function_privilege('anon', 'public.playback_watch_notice(integer, integer, integer)', 'execute')
     or has_function_privilege('authenticated', 'public.playback_watch_notice(integer, integer, integer)', 'execute') then
    raise exception 'an app role may call playback_watch_notice';
  end if;

  raise exception 'PLAYBACK WATCH TEST PASSED';
end;
$$;
