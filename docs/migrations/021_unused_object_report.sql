-- ===========================================================================
-- 021  WHICH FILES IN THE BUCKET NOTHING POINTS AT   (H1)
-- ===========================================================================
--
-- R2 had never been audited. Every failed upload, every replaced master, every
-- thumbnail from a title that was later deleted is still there and still
-- billed, and there was no way to ask "which of these objects does the
-- catalogue actually reference?" short of exporting both sides by hand.
--
-- The awkward part is that the answer lives on both sides of a boundary: the
-- key list comes from R2's ListObjectsV2 and the references come from Postgres.
-- Doing it in SQL alone is impossible; doing it in the edge function alone
-- means shipping the whole catalogue to it. So the function lists the bucket a
-- page at a time and asks the database, per page, which of THOSE keys are
-- unreferenced.
--
-- THREE COLUMNS, NOT ONE. A key can be referenced as a master
-- (title_assets.object_key), as a poster (title_assets.thumb_key) or as one
-- rung of the ladder (asset_renditions.object_key). Missing any one of them
-- would report live files as rubbish, which is the one mistake that must not
-- happen — the operator is going to read this list and start deleting.
--
-- STABLE, and search_path is empty so the schema is written out in full: this
-- is SECURITY DEFINER and runs as the owner.
--
-- The report itself is list-only and deletes nothing, and it ignores anything
-- uploaded in the last 24 hours — an upload in progress has no catalogue row
-- yet and would otherwise be reported as an orphan every time.

create or replace function public.unknown_object_keys(keys text[])
returns setof text
language sql
stable
security definer
set search_path to ''
as $$
  select k
  from unnest(coalesce(keys, array[]::text[])) as k
  where k <> ''
    and not exists (
      select 1 from public.title_assets ta
      where ta.object_key = k or ta.thumb_key = k
    )
    and not exists (
      select 1 from public.asset_renditions ar where ar.object_key = k
    );
$$;
