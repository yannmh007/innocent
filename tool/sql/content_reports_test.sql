-- A viewer reports a title; the owner hears of it   (migration 076)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `CONTENT REPORTS TEST PASSED`;
-- any other exception names the case that failed.
--
-- The cases that matter: anyone with the app may report, but not without
-- limit; a report keeps no address and no raw install id; the owner is told
-- each report once; and no app role can read what others reported.
do $$
declare
  t      uuid;
  v      text;
  n      integer;
  msg    text;
  blocked boolean;
begin
  select id into t from public.titles where published order by created_at limit 1;
  if t is null then raise exception 'no published title to report'; end if;
  delete from public.content_reports;

  -- ── as the app, signed out: a phone and its network ─────────────────────
  perform set_config('request.headers',
    '{"x-install-id": "report-test-install", "cf-connecting-ip": "203.0.113.9"}', true);
  set local role anon;
  v := public.report_content(t, 'rights', '  I own this film. Please remove it.  ', ' owner@example.com ');
  if v <> 'ok' then raise exception 'a plain report was refused: %', v; end if;
  v := public.report_content(t, 'nonsense', 'x', null);
  if v <> 'bad' then raise exception 'an unknown reason was taken: %', v; end if;
  v := public.report_content(gen_random_uuid(), 'rights', 'x', null);
  if v <> 'bad' then raise exception 'a title that does not exist was taken: %', v; end if;
  v := public.report_content(t, 'other', '   ', null);
  if v <> 'bad' then raise exception '"other" with nothing said was taken: %', v; end if;
  v := public.report_content(null, 'illegal', 'about the app in general', null);
  if v <> 'ok' then raise exception 'a report with no title was refused: %', v; end if;
  v := public.report_content(t, 'other', repeat('x', 5000), repeat('y', 500));
  if v <> 'ok' then raise exception 'an over-long report was refused rather than cut: %', v; end if;

  -- ── what an app role can see: nothing ───────────────────────────────────
  begin
    perform 1 from public.content_reports limit 1;
    blocked := false;
  exception when insufficient_privilege then
    blocked := true;
  end;
  if not blocked then raise exception 'anon can read content_reports'; end if;

  -- ── five a day from one phone ───────────────────────────────────────────
  v := public.report_content(t, 'minor', 'four', null);
  v := public.report_content(t, 'consent', 'five', null);
  if v <> 'ok' then raise exception 'the fifth report from a phone was refused: %', v; end if;
  v := public.report_content(t, 'rights', 'six', null);
  if v <> 'too_many' then raise exception 'a sixth report in a day from one phone was taken: %', v; end if;
  reset role;

  -- ── what was kept ───────────────────────────────────────────────────────
  select count(*) into n from public.content_reports;
  if n <> 5 then raise exception 'expected 5 kept reports, found %', n; end if;
  select count(*) into n from public.content_reports
   where install = 'report-test-install' or network like '%203.0.113.9%';
  if n <> 0 then raise exception 'a raw install id or address was kept'; end if;
  select count(*) into n from public.content_reports
   where install = left(encode(extensions.digest('report-test-install', 'sha256'), 'hex'), 32);
  if n <> 5 then raise exception 'the install was not kept as its hash (% rows)', n; end if;
  select count(*) into n from public.content_reports where length(detail) > 1000 or length(contact) > 200;
  if n <> 0 then raise exception 'an over-long report was kept whole'; end if;
  select count(*) into n from public.content_reports where detail = 'I own this film. Please remove it.'
     and contact = 'owner@example.com';
  if n <> 1 then raise exception 'the report was not kept trimmed as written'; end if;

  -- ── the owner is told, once ─────────────────────────────────────────────
  msg := public.report_notice();
  if msg is null or position('I own this film' in msg) = 0 or position('owner@example.com' in msg) = 0 then
    raise exception 'the notice does not carry the report: %', msg;
  end if;
  if position('203.0.113.9' in msg) > 0 or position('report-test-install' in msg) > 0 then
    raise exception 'the notice names the reporter''s address or install';
  end if;
  msg := public.report_notice();
  if msg is not null then raise exception 'the same reports were told twice: %', msg; end if;

  -- ── another network, another phone: its own budget ──────────────────────
  perform set_config('request.headers',
    '{"x-install-id": "report-test-other", "cf-connecting-ip": "198.51.100.7"}', true);
  set local role authenticated;
  v := public.report_content(t, 'rights', 'from another phone', null);
  if v <> 'ok' then raise exception 'another phone was refused by the first one''s budget: %', v; end if;
  reset role;

  if has_function_privilege('anon', 'public.report_notice()', 'execute') then
    raise exception 'anon may call report_notice';
  end if;

  raise exception 'CONTENT REPORTS TEST PASSED';
end;
$$;
