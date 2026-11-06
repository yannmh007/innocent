-- 066 — `titles.poster_seal` (a computed field, 063) can never be read: the
-- app roles hold SELECT on 21 named columns of `titles`, and a computed
-- field takes the whole row ("permission denied for table titles"). A
-- poster's seal comes with `title_cards` and the landing cards; a build that
-- opens seals reads `title_cards` where it read `titles`
-- (ApiContentRepository._titlesPath).
drop function if exists public.poster_seal(public.titles);
