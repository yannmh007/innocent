# The production data model, and the algorithms it makes possible

Design note, 2 Sep 2026. Written against v1.63.6+311, after the Movies backend
went live end to end.

Not SQL to run today. A design to agree on first, because three of these
decisions are expensive to reverse once a hundred titles exist.

---

## 0. THE ONE FINDING THAT SHOULD CHANGE THE ORDER OF WORK

Netflix's own description of its recommender lists what it uses: viewing
history, how titles were rated, where playback stopped, other members with
similar taste, and title metadata - genre, cast, release year. Practitioner
write-ups add the context signals: time of day, device, whether the viewer
abandoned mid-title. And they are consistent on one point - **implicit signals
matter more than explicit ones, because almost nobody rates anything but
everybody watches.**

Two consequences for a catalogue this size:

**(a) Collaborative filtering cannot work yet, and pretending otherwise wastes
months.** "Members with similar taste" needs many members with overlapping
history. With a hundred titles and a handful of viewers there is no overlap to
find. The literature's answer for exactly this case is popularity plus
deliberately diverse genre sets plus content-based matching on metadata - all
of which are ordinary SQL, and all of which work on day one.

**(b) Algorithms can be written later. Events cannot be recreated later.**
This is the whole argument of this document. A ranking formula can be rewritten
in an afternoon, six months from now, against whatever data exists. But if the
app never recorded that a viewer opened a title and quit after ninety seconds,
that fact is gone permanently. **The expensive mistake is not choosing the
wrong algorithm. It is not capturing the events.**

So the order is: get the event log right now, even with nothing reading it.
Write the algorithms when there is something to read.

The current `title_views` table records one row per viewer per title per day.
That is enough to count views and nothing else. It cannot answer "did they
finish it", "where did they stop", "did they even press play", or "which of the
six rows on the home screen did they click from" - and those are the questions
every ranking worth having is built on.

---

## 1. ASSETS: ONE TITLE, MANY FILES

The requirement: a folder per title in R2, holding the main video plus clips,
photos, and whatever gets added later; and the ability to choose WHICH photo is
the card image, and change that choice afterwards.

`titles.poster_url` and `titles.locator` are single columns. They cannot
express that. A second table can:

```
titles (1) ──< title_assets (many)
```

```sql
create type asset_kind as enum
  ('video', 'clip', 'trailer', 'photo', 'subtitle', 'audio');

create table public.title_assets (
  id           uuid primary key default gen_random_uuid(),
  title_id     uuid not null references public.titles(id) on delete cascade,

  kind         asset_kind not null,
  bucket       text not null default 'innocent-media',
  object_key   text not null,              -- 'titles/spider-man/video.mp4'

  -- WHICH PHOTO IS THE CARD. Exactly one per title, enforced below.
  is_primary   boolean not null default false,

  sort_order   int not null default 0,
  label        text,                       -- '720p', 'Behind the scenes', 'MM'
  language     text,                       -- subtitles and audio tracks
  duration_s   int,
  width        int,
  height       int,
  bytes        bigint,
  mime         text,

  added_at     timestamptz not null default now(),
  unique (bucket, object_key)
);

-- At most one primary per title. A partial unique index rather than a trigger:
-- the database refuses a second primary rather than silently keeping two.
create unique index title_assets_one_primary
  on public.title_assets (title_id)
  where is_primary;
```

**Changing the card image becomes one UPDATE** - clear the old primary, set the
new one. No re-upload, no path editing, no app rebuild.

### Keeping the client contract intact

The app selects `poster_url` from `titles`. **That must not change** - the
whole "finish the client, then work only on the backend" plan depends on the
contract staying still.

So `titles.poster_url` stays exactly where it is and becomes a **maintained
denormalisation**: a trigger writes the public URL of the primary photo into it
whenever the primary changes. The client keeps reading one column and knows
nothing about assets. Same for `locator` and the primary video.

```sql
create or replace function public.sync_title_primary()
returns trigger language plpgsql security definer
set search_path = public as $fn$
begin
  update public.titles t set
    poster_url = coalesce((
      select 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/' || a.object_key
      from public.title_assets a
      where a.title_id = t.id and a.kind = 'photo' and a.is_primary
      limit 1), t.poster_url),
    locator = coalesce((
      select a.object_key from public.title_assets a
      where a.title_id = t.id and a.kind = 'video'
      order by a.is_primary desc, a.sort_order limit 1), t.locator),
    photo_count = (select count(*) from public.title_assets a
                   where a.title_id = t.id and a.kind = 'photo'),
    video_count = (select count(*) from public.title_assets a
                   where a.title_id = t.id and a.kind in ('video','clip','trailer'))
  where t.id = coalesce(new.title_id, old.title_id);
  return null;
end;
$fn$;
```

That trigger also fills `photo_count` and `video_count`, which the app already
selects and which are currently null. **They start working with no client
change** - which is the pattern this whole design aims at.

---

## 2. SERIES: THE ONE THING THE CLIENT CANNOT ABSORB

Everything else here reaches the app through columns it already reads. Seasons
and episodes do not, because the client has no concept of an episode - it draws
`episode_count` as a number on a card and stops there.

```
titles (kind = 'series')
  └── seasons (number, title, year)
        └── episodes (number, title, synopsis, runtime, assets)
```

**This is the exception that proves the rule about finishing the client
first.** No amount of server work makes an episode list appear. If series are
ever wanted, the client contract has to be widened BEFORE the tables are
filled - otherwise the data exists and is unreachable.

Decide this before uploading any series.

---

## 3. THE EVENT LOG: THE PART THAT CANNOT BE ADDED RETROSPECTIVELY

One append-only table. Never updated, never deleted from, only inserted into
and read.

```sql
create table public.events (
  id           bigserial primary key,
  occurred_at  timestamptz not null default now(),

  viewer_key   text not null,        -- auth.uid() or x-install-id
  session_id   text,                 -- one app run: groups a journey together

  kind         text not null,
  title_id     uuid references public.titles(id) on delete set null,
  asset_id     uuid references public.title_assets(id) on delete set null,

  -- Playback. `position_s` against `duration_s` is the completion ratio,
  -- which is the single most useful number in this entire schema.
  position_s   int,
  duration_s   int,

  -- Context. Netflix's own writing is explicit that a 30-minute comedy on a
  -- phone at lunch and a 2-hour film on a TV on Saturday night are different
  -- experiences. Without these columns that distinction is unrecoverable.
  device_kind  text,                 -- 'phone' | 'tablet' | 'tv'
  network_kind text,                 -- 'wifi' | 'mobile'
  app_version  text,
  locale       text,

  meta         jsonb not null default '{}'
);

create index events_title_time on public.events (title_id, occurred_at desc);
create index events_viewer_time on public.events (viewer_key, occurred_at desc);
create index events_kind_time  on public.events (kind, occurred_at desc);
```

### The event kinds worth recording

| kind | when | why it earns its place |
|---|---|---|
| `impression` | a card is drawn on screen | the denominator. Without it, "popular" only measures what was already promoted |
| `card_click` | a card is tapped | impressions ÷ clicks = whether the ARTWORK works |
| `detail_view` | detail screen opened | interest without commitment |
| `play_start` | playback granted and begun | |
| `play_progress` | every ~30s while playing | where people stop. The most valuable signal here |
| `play_complete` | ≥90% watched | |
| `search` | a query is submitted | what the catalogue is MISSING - queries with no results are a shopping list |
| `filter_apply` | a filter chip used | which facets are worth keeping |
| `bookmark_add` / `_remove` | | strong explicit intent |
| `download_start` / `_complete` | | in a metered market, download intent is a stronger signal than a play |
| `playback_denied` | a refusal | how often the paywall is HIT, which is the conversion funnel |
| `error` | any caught failure | 295 places in this codebase catch an error nobody can see |

**`search` with no results and `playback_denied` are the two that pay for
themselves fastest** - the first says what to acquire, the second says whether
the price is the obstacle.

### Privacy, stated deliberately

This is an adult catalogue, so the event log is sensitive by construction: it
is a record of what individual people watched.

* `viewer_key` is a random install id or an auth uid - **never a phone number,
  never an email**.
* Netflix's own documentation states its recommender excludes demographic
  information such as age and gender. That is a reasonable line to copy: do not
  collect what is not used.
* Set a retention window - raw events aged out after 90 or 180 days, rolled
  into daily aggregates first. Aggregates keep the algorithms working; the raw
  rows are the liability.
* RLS: no policy at all for `anon`. Events are written through a
  `security definer` function and read only by the operator.

---

## 4. THE REST OF THE PRODUCTION SCHEMA

Sketched, not final - these are ordinary once the two above are settled.

**People and credits** — `people` (name, name_mm, kind) and `title_people`
(role, character, billing_order). This is what makes "more with this actor"
possible, and actor search is one of the most used features in every catalogue
app.

**Bookmarks** — `bookmarks (viewer_key, title_id, added_at)`. The client
already has the screen; it says "coming soon".

**Watch progress** — `watch_progress (viewer_key, title_id, asset_id,
position_s, duration_s, updated_at)`, one row per viewer per title, upserted.
This is what makes Continue Watching work, and it must be **server-side** or it
does not survive a reinstall.

**Ratings** — `ratings (viewer_key, title_id, value, rated_at)`. Thumbs, not
stars: Netflix moved to thumbs because five-point scales collect fewer and
noisier responses.

**Comments** — `comments (id, title_id, viewer_key, parent_id, body,
created_at, status)` with `status ∈ (visible, hidden, removed)` and a
`comment_reports` table. **Do not ship comments without moderation already
built.** On an adult catalogue an unmoderated comment thread becomes a legal
problem, not a feature request.

**Availability** — `age_rating`, `available_from`, `available_until` on
`titles`. Scheduling a title to appear at a date is a column, not a job.

**Collections** — `collections` and `collection_titles` for hand-curated rows
("Myanmar films", "Staff picks"). A hand-made row beats a bad algorithm at this
catalogue size, and it needs no data at all.

---

## 5. ALGORITHMS THAT WORK AT THIS SIZE - WITH THE FORMULAS

All of these are SQL over the tables above. None needs machine learning. All of
them work with ten viewers.

### Trending — time-decayed, not a raw count

A raw `view_count` only ever goes up, so the same titles sit at the top
forever and nothing new is ever discovered. Decay fixes that in one line:

```sql
select title_id,
       sum(exp(-extract(epoch from (now() - occurred_at)) / 259200.0)) as heat
from public.events
where kind = 'play_start' and occurred_at > now() - interval '14 days'
group by title_id order by heat desc;
```

`259200` seconds is a three-day half-life: a play today counts double one from
three days ago. Shorten it for a livelier front page.

### Completion rate — the ranking that beats view count

A title people click and quit is worse than one fewer people finish. View count
cannot tell them apart:

```sql
select title_id,
       count(*) filter (where kind = 'play_complete')::numeric
         / nullif(count(*) filter (where kind = 'play_start'), 0) as completion
from public.events group by title_id having count(*) > 20;
```

**Rank by `heat * (0.5 + completion)`** and popular-but-disappointing titles
sink on their own.

### Because you watched X — content-based, no other users needed

This is the cold-start answer: match on metadata, not on people.

```sql
-- shared genres + shared cast, weighted
select t.id, t.title,
       cardinality(array(select unnest(t.genres) intersect select unnest(src.genres))) * 2
       + (select count(*) from title_people a join title_people b
            on a.person_id = b.person_id
          where a.title_id = t.id and b.title_id = src.id) as score
from public.titles t, public.titles src
where src.id = :watched_id and t.id <> src.id and t.published
order by score desc limit 12;
```

### Artwork A/B testing — the one Netflix is famous for

With `impression` and `card_click` recorded per asset, the click-through rate
of two candidate posters is directly comparable. Change `is_primary`, wait,
compare. **This is the reason `title_assets` has many photos and a movable
primary flag** - not tidiness, measurement.

```sql
select asset_id,
       count(*) filter (where kind='card_click')::numeric
         / nullif(count(*) filter (where kind='impression'), 0) as ctr
from public.events where title_id = :id group by asset_id;
```

### Gaps in the catalogue — what to acquire next

```sql
select lower(meta->>'query') as q, count(*)
from public.events
where kind = 'search' and (meta->>'results')::int = 0
group by 1 order by 2 desc limit 50;
```

Failed searches are the audience telling you what is missing, in their own
words. Almost nothing else in analytics is that direct.

### Paywall conversion

```sql
select date_trunc('day', occurred_at) d,
       count(*) filter (where kind='playback_denied') as hit_wall,
       count(distinct viewer_key) filter (where kind='playback_denied') as people
from public.events group by 1 order by 1 desc;
```

If many people hit the wall and few subscribe, the price or the free tier is
wrong - and that is a business answer no amount of code produces.

---

## 6. WHAT THIS MEANS FOR THE CLIENT

Almost all of the above reaches the app through columns and RPCs it already
reads. Three things do not, and they are the client work:

1. **An event sender.** A small batching queue - collect events, flush every
   30s or on background, drop silently on failure. Nothing here is worth
   delaying a frame for or retrying forever.
2. **Episode UI**, if series are wanted. Section 2.
3. **Bookmarks and Continue Watching**, which are stubs today.

Everything else - assets, credits, availability, collections, trending,
because-you-watched - arrives as rows in the RPCs the client already calls.

---

## 7. DECISIONS NEEDED BEFORE ANY OF THIS IS BUILT

| | |
|---|---|
| **A1** | `title_assets` with a movable primary — yes? (Section 1) |
| **A2** | Series/seasons/episodes — needed? If yes, client first (Section 2) |
| **A3** | Event log now, with nothing reading it — yes? (Section 3) |
| **A4** | Comments — yes, and with moderation from day one? (Section 4) |
| **A5** | Event retention window — 90 days? 180? (Section 3) |

A1 and A3 are the two that cannot be added retrospectively without pain. A3
especially: every day it is not shipped is a day of data that does not exist.
