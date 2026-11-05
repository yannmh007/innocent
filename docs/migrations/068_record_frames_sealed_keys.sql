-- 068 — record_frames takes a still born sealed (docs/MEDIA_ENCRYPTION.md §7).
--
-- With the switch `on` (067), the cover picker's ten stills are sealed from
-- birth: each one's key is its sealed object, `s/<32 hex>`, and there is no
-- `…/thumb/….jpg` beside it. The key check gains exactly that shape and
-- nothing else; the canary's stills keep their plain keys (their twins are
-- in media_image_keys), so nothing changes for them.

create or replace function public.record_frames(p_asset uuid, p_frames jsonb, p_note text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  first_key text;
  out_key text;
begin
  if p_frames is null or jsonb_typeof(p_frames) <> 'array' or jsonb_array_length(p_frames) = 0 then
    update public.title_assets set frames_state = 'failed', frames_at = now(),
           frames_note = left(coalesce(p_note, 'no frames'), 200)
     where id = p_asset;
    return null;
  end if;
  if exists (select 1 from jsonb_array_elements(p_frames) f
              where coalesce(f->>'key', '') !~ '^(([a-z0-9][a-z0-9.\-]*/)*thumb/[a-z0-9][a-z0-9.\-]*\.jpg|s/[0-9a-f]{32})$'
                 or jsonb_typeof(f->'at') <> 'number') then
    raise exception 'record_frames: unexpected frame entry';
  end if;
  first_key := p_frames->0->>'key';
  update public.title_assets
     set frames = p_frames, frames_state = 'done', frames_at = now(),
         frames_note = left(p_note, 200), thumb_key = coalesce(thumb_key, first_key)
   where id = p_asset
  returning thumb_key into out_key;
  return out_key;
end;
$function$;
