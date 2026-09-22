# V3: the album catalogue, the admin console, and the ranking that needs events

Research note, 22 Sep 2026. Written against v1.64.15+328, after the studio
upload page went live and the first two titles were published end to end.

This answers a brief that asked for nine things at once. **It is not a list of
features to build in the order they were asked for**, because the research
turned up something that changes the order: most of the app-side work in that
brief already exists and has existed for months. What is missing is one line in
a view, a handful of columns, and an admin surface. The expensive item in the
brief is the one that was not asked about directly — the event log — and it is
expensive for a reason that gets worse every day it is not built.

Read §1 before §4. The plan only makes sense once the starting position is
clear.

---

## 0. WHAT WAS ACTUALLY READ

Not a survey. Every claim below is from one of these:

* `lib/features/video_hub/` — all 53 Dart files, in particular
  `content_detail_screen.dart`, `album_viewer_screen.dart`,
  `widgets/media_mosaic.dart`, `domain/video_content.dart`,
  `domain/content_category.dart`, `data/api/api_content_repository.dart`.
* The live database: `information_schema.columns`, `information_schema.views`,
  `pg_proc` for every function in `public`, and the actual rows in `titles`
  and `title_assets`.
* `docs/movies_data_model_v2.md`, `docs/movies_gaps.md`,
  `docs/client_api_contract.md`.
* `docs/edge/studio.ts` and `docs/studio/index.html` as deployed.

Where something is a guess it says so.

---

## 1. THE FINDING THAT REORDERS THE WORK

**The Telegram-style mixed photo/video album is already built in the app, and
has been for months.** Not sketched — built, with the awkward parts solved.

| Asked for | Where it already lives |
|---|---|
| grid mixing many videos + photos | `widgets/media_mosaic.dart` — a mosaic, not a grid: it sizes each row from the aspect ratios of the items in it, so a 9:16 clip and a 16:9 still sit side by side without either being cropped into a square hole |
| a play button on every video tile | `content_detail_screen.dart` `_AlbumTile` — `Icons.play_circle_fill` per video tile, plus an `mm:ss` duration badge in the corner |
| tap a card → open the album | `AlbumViewerScreen`, swipeable, already routed from every tile |
| free preview inside a paid title | `AlbumItem.isPreview` + `_PreviewTag`, with locked tiles **blurred** rather than blacked out |
| each clip playable on its own | `requestPlayback` already accepts `asset_id` and signs that asset's key instead of the title's main video |
| seeking a long film | `StreamRenewal` — the player re-asks for a fresh signed URL when a seek lands outside the buffer and the old signature has expired |

So items 2 and 3 of the brief are **not a UI project**. They are a data
problem, and a small one. The screens are waiting for rows that never arrive.

### Why they never arrive

```sql
-- public.title_media, as deployed
WHERE t.published
  AND a.kind = ANY (ARRAY['photo', 'clip', 'trailer'])
```

`'video'` is not in that array. The studio page writes the main file as
`kind = 'video'`. **The main video is therefore excluded from the album by one
line, on purpose, and that purpose no longer holds.**

It was a defensible decision once: the main video was the thing the big Play
button played, so listing it again in the album would have been a duplicate.
The brief changes that — the Play button is to go away and the album becomes
the only route in — so the exclusion now removes the single most important tile
on the screen.

With one photo and one video uploaded, the album the app receives holds exactly
one item: the photo, which is also already the poster at the top of the same
screen. That is why the screen looks like nothing was built.

### Three more reasons it looks unbuilt

**`duration_s`, `width`, `height` are NULL on every asset.** Confirmed in the
live table. The mosaic sizes rows from width/height, so it falls back to a
default shape; the duration badge needs `duration_s`, so it never draws. The
studio page does not read these from the file before uploading — and the
browser can: a `<video>` element exposes `duration`, `videoWidth`,
`videoHeight` after `loadedmetadata`, and an `<img>` exposes
`naturalWidth`/`naturalHeight`. No server work, no ffmpeg.

**`thumb_key` is NULL on every video asset.** `title_media` then falls back to
`t.poster_url`, so in a title with six clips all six tiles show the same
picture — the poster. A poster frame can be grabbed in the browser too:
seek the `<video>` to ~10%, draw it to a `<canvas>`, `toBlob()`, upload it as
a second object. Same presign path already in place.

**One video and one photo per title is all the studio page can upload.**
`docs/studio/index.html` has exactly one `<input type="file" accept="video/*">`
and one `accept="image/*"`. The database has always supported many
(`title_assets`, with `sort_order` and a movable `is_primary`); the uploader
never did.

---

## 2. WHAT GENUINELY DOES NOT EXIST

Four things, ordered by how hard they are to add later.

### 2.1 The event log — and this is the urgent one

`docs/movies_data_model_v2.md` §3, written 2 Sep, made this argument and was
right:

> Algorithms can be written later. Events cannot be recreated later. A ranking
> formula can be rewritten in an afternoon, six months from now. But if the app
> never recorded that a viewer opened a title and quit after ninety seconds,
> that fact is gone permanently.

Twenty days on, it is still not built. What exists is `title_views`: one row
per viewer per title per day, three columns, and `titles.view_count`, a
lifetime counter that only ever goes up.

Every single signal the brief asks to rank on is absent:

| Asked for | Recorded today |
|---|---|
| how many watched | detail-screen opens only — not plays, not finishes |
| engagement, "what people are really into" | nothing |
| download counts | nothing — downloads do not exist at all (§2.4) |
| popular search keywords | nothing — searches are not logged |
| location / IP signals | nothing |

And "Trending" today is:

```sql
-- public.landing_rows(), as deployed
order by view_count desc nulls last limit 20
```

A cumulative counter sorted descending. **It can never change its own answer.**
The first titles to get views sit at the top permanently and nothing new is
ever discoverable — which is exactly the failure `movies_data_model_v2.md` §5
predicted and gave the one-line fix for.

This is the item to start with, and the reason is not that ranking matters most
today. It is that with three titles and a handful of viewers, *no* ranking
matters today — and the log has to be running before the data it needs exists.
Every day it is not shipped is a day of history that cannot be bought back.

### 2.2 Tags, keywords, and a search worth the name

`titles` has `genres text[]` and `extra jsonb`. There is **no `tags` column, no
keywords, and no full-text index**.

Search today, from `api_content_repository.dart`:

```
or=(title.ilike."*q*",title_mm.ilike."*q*")
```

Two columns. A user searching a word from the synopsis, an actor's name, a
genre, or a tag gets nothing. A user who mistypes one letter gets nothing.
A Burmese user searching a word that is in the English synopsis gets nothing.

Postgres answers all of this without an extra service:
`tsvector` + GIN for words, `pg_trgm` for typos and substrings. Both are core
or bundled extensions; `pg_trgm` in particular matters here because Burmese
does not tokenise into a Postgres text-search configuration, so trigram
similarity — not stemming — is what makes Burmese search work.

### 2.3 Categories are compiled into the APK

`lib/features/video_hub/domain/content_category.dart` is a Dart `enum`:
`all, movies, series, reels`. Its labels come from `AppStrings`, which is a
map compiled into `libapp.so`.

So the brief's item 6 — rename "Movies" to "Video" from the server, without
shipping an app — is **not possible today**, and it is the one item in the
whole brief that the current client contract genuinely cannot absorb. It is the
same class of problem `movies_data_model_v2.md` §2 flagged for series:
**widen the client first, fill the table second.** The opposite order leaves
correct data that nothing can read.

Worth stating plainly: the row headings on the landing page are already
half-way there. `landing_rows()` returns a `title` per row and the client
carries it as `fallbackTitle`, using its own localized string when it knows the
`key`. So a server-named row already renders. Categories just never got the
same treatment.

### 2.4 Offline download does not exist for catalogue content

`Capability.downloadOffline` is in the capability matrix.
`AccessPolicy.canDownload()` is written and tested. The Downloads tile on the
account screen calls `_notYet()`.

The app has a complete download engine — `lib/features/downloader/`, with
resume, a foreground service, SHA verification and a queue. None of it is
wired to the hub. This is wiring plus one genuine design question (below), not
a new subsystem.

**The design question, stated honestly:** a signed R2 URL expires in ten
minutes. A downloaded file does not. So "download for offline" means the bytes
leave the protected path permanently, and the only thing standing between a
premium download and a file shared over Bluetooth is that the app stores it
somewhere awkward. That is not enforcement; it is friction. The options are:

* **(a) Accept it.** Store in app-private storage, delete on subscription
  lapse, and treat the leak as a cost of the feature. This is what most
  regional services actually do.
* **(b) Encrypt at rest** with a key held in the Keystore and decrypt during
  playback. The Private Folder vault in this app already does exactly this
  pattern, so the primitive exists. It costs a custom data source in the
  player.
* **(c) Don't ship it.**

(a) is the right answer for now and (b) is the upgrade path. What must not
happen is shipping (a) while describing it as (b).

---

## 3. THE ADMIN CONSOLE

What exists: one page, nine fields, two file pickers, one button. It can create
a title and it can do nothing else. There is no list, no edit, no delete, no
reorder, no way to change the poster, and no way to add a second clip to a
title that already exists.

What the brief asks for is a console. The design below is shaped by one
constraint that is easy to forget: **`docs/studio/` is in a public repository
and served from GitHub Pages.** No secret can live in that page. Everything it
does goes through the `studio` edge function, which checks the caller against
`OPERATOR_IDS` and holds the R2 credentials in Supabase secrets. That is the
existing shape and it stays.

### 3.1 Screens

```
/studio/                 sign in, then the console
  ├── Catalogue          list, filter, status chips, search
  ├── Title editor       everything about one title
  │     ├── Details      title, title_mm, synopsis, year, rating,
  │     │                quality, category, tier, featured, published
  │     ├── Tags         free-text tags + genres, with autocomplete from
  │     │                what already exists in the catalogue
  │     ├── Media        the asset list: drag to reorder, set primary,
  │     │                set free-preview, replace thumbnail, delete,
  │     │                add more files
  │     └── Stats        views, plays, completion, downloads (once §2.1 exists)
  ├── Categories         the server-controlled list (§2.3)
  ├── Requests           the premium approval queue — see below
  └── Health             catalogue_health, already a view, currently unread
```

**The premium approval queue deserves its own line.** `docs/movies_gaps.md` §2
calls the missing operator side *blocking — the product cannot take money*.
The `pending_requests` view, `approve_request()` and `reject_request()` all
already exist in the database; nothing calls them. Two buttons on this console
closes a gap that has been described as launch-blocking for a month. It is the
cheapest high-value thing in this entire document.

### 3.2 Multi-file upload, done properly

The brief's core workflow is "one card, many videos and photos". So the upload
form becomes a **drop zone accepting many files at once**, and for each file
the page:

1. reads `duration`, `videoWidth`/`videoHeight` (or `naturalWidth`/`Height`)
   locally — fixing §1's NULLs at the source;
2. for videos, grabs a poster frame via `<canvas>` and uploads it as
   `thumb_key`;
3. presigns and PUTs, with a per-file progress bar, **bounded to about three
   concurrent uploads** (a phone on a Myanmar mobile network uploading twelve
   files at once finishes none of them);
4. writes one `title_assets` row per file with the metadata it measured.

Sort order comes from the drop order and stays editable by drag afterwards.

### 3.3 One honest constraint on the upload path

Browser-presigned PUT to R2 is capped at **5 GiB per object** for a single
PUT. Above that it needs multipart, which means the edge function has to
presign each part and the page has to drive `CreateMultipartUpload` →
`UploadPart`×N → `CompleteMultipartUpload`. That is real work and it is not
needed for the sizes being uploaded today. **Recommendation: add a clear size
check and a plain refusal message now, and build multipart when a file
actually needs it.** A silent failure at 5 GiB is much worse than a refusal at
4.9.

---

## 4. THE SCHEMA THIS NEEDS

Minimal, and every piece justified by something above. Written so that the
client contract does not break: everything the app selects today keeps
returning what it returns today.

```sql
-- ── 2.3 CATEGORIES, SERVER-OWNED ────────────────────────────────────────
create table public.categories (
  id          text primary key,           -- 'movies'  — never changes
  label       text not null,              -- 'Movies'  — freely editable
  label_mm    text,
  sort_order  int  not null default 0,
  is_visible  boolean not null default true,
  shows_rows  boolean not null default false
);
```

The split between `id` and `label` is the whole feature. `id` is what
`titles.category` stores, what analytics groups by, and what a saved tab
selection holds — it must never change. `label` is what the user reads, and
changing it is the point. Renaming "Movies" to "Video" is then one UPDATE and
takes effect on the next app launch.

**Client side, this is a real widening and must ship first.** `ContentCategory`
stops being an enum and becomes data fetched at startup, cached, with the
current hard-coded four as the offline fallback — because a catalogue that
cannot draw its tab bar when the network is down is worse than one with stale
labels.

```sql
-- ── 2.2 TAGS AND SEARCH ─────────────────────────────────────────────────
create table public.tags (
  id     text primary key,                -- slug
  label  text not null,
  label_mm text,
  kind   text not null default 'tag'      -- 'tag' | 'person' | 'studio'
);
create table public.title_tags (
  title_id uuid references public.titles(id) on delete cascade,
  tag_id   text references public.tags(id)   on delete cascade,
  primary key (title_id, tag_id)
);

alter table public.titles add column search_text text;   -- maintained
create index titles_search_trgm
  on public.titles using gin (search_text gin_trgm_ops);
```

A maintained `search_text` column rather than a generated `tsvector`, for one
reason: the searchable text spans three tables (title, synopsis, tags), and a
generated column cannot read another table. A trigger on all three keeps it
current. `gin_trgm_ops` rather than `to_tsvector` because of Burmese — trigram
similarity does not need a language configuration, and Postgres has no Burmese
one.

```sql
-- ── 2.1 THE EVENT LOG ───────────────────────────────────────────────────
```

Take `movies_data_model_v2.md` §3 as written. It is already correct and there
is nothing to improve in it. Two additions the brief asks for and that document
did not cover:

* `download_start` / `download_complete` are already in its list of kinds.
  Good — they stay, even though §2.4 is not built, because an event kind costs
  nothing until something emits it.
* **Location.** The brief asks for it. State the position plainly: Supabase
  edge functions receive `cf-ipcountry`, so **country** is available free and
  needs no IP storage at all. Store `country` on the event row and **do not
  store the IP address.** On an adult catalogue, a table joining a person's
  viewing history to their IP address is a liability with no matching benefit —
  country is enough to answer every question worth asking ("is this title
  popular outside Yangon?") and carries a fraction of the risk.

```sql
-- ── §1 FIXES, which are the cheapest rows in this document ──────────────
create or replace view public.title_media as
  -- ... unchanged, except:
  where t.published
    and a.kind = any (array['video', 'clip', 'trailer', 'photo']);
```

---

## 5. THE ALGORITHM, AND WHAT IT CAN HONESTLY DO

`movies_data_model_v2.md` §0 established the finding that governs this, and it
has not changed: **collaborative filtering cannot work at this size.** "Members
with similar taste" needs many members with overlapping history; there are
three titles and a handful of viewers. Any recommender built on it would be
producing noise with a confident face.

What works from day one, all of it ordinary SQL:

**Trending = time-decayed heat × completion.** Replaces `view_count desc`.

```sql
heat = sum(exp(-age_seconds / 259200.0))   -- 3-day half-life
rank = heat * (0.5 + completion_rate)
```

The decay is what makes new titles reachable; the completion factor is what
stops a title with a good poster and a bad film from sitting at the top. Both
need the event log and neither needs anything else.

**Because you watched X** — match on genres and tags, not on other people.
This is the cold-start answer and it works with one viewer.

**What to acquire next** — searches that returned nothing, grouped and counted.
The single most directly actionable query in the whole schema: it is the
audience naming what is missing, in their own words.

**Artwork measurement** — with `impression` and `card_click` recorded per
asset, two candidate posters are directly comparable. This is the reason
`title_assets` has many photos and a movable primary flag, and it is why §3.1
puts "set primary" in the editor rather than leaving it to SQL.

**One thing to refuse.** The brief asks to "learn from users" with location and
IP. Country-level is in. Per-user IP history is out, for the reason in §4. If
that is the wrong call it should be an explicit decision, not a default.

---

## 6. ORDER OF WORK

Ordered by *what cannot be recovered if delayed*, then by cost.

| # | Work | Why here | Ships |
|---|---|---|---|
| 1 | ~~`title_media` includes `video`; studio measures duration/width/height; studio grabs video thumbnails~~ ✅ 22 Sep — **plus the permission fault in §6b, which was the larger half** | One view line + browser-side metadata. Makes the album screen that already exists actually appear. Hours, not days. | server + studio only |
| 2 | ~~**Event log live**, client sender batching every 30s~~ ✅ 22 Sep | Cannot be backfilled. Every day costs data permanently. Nothing needs to read it yet. | client + server |
| 3 | ~~Admin console: catalogue list, title editor, media manager, multi-upload~~ ✅ 22 Sep | Unblocks everything editorial, and until it exists every schema addition below is unreachable | studio only |
| 4 | ~~Premium approval queue in the console~~ ✅ 22 Sep | `movies_gaps.md` calls this launch-blocking; the SQL already exists | studio only |
| 5 | Tags + trigram search | Needs #3 to enter tags | server + small client |
| 6 | Server-owned categories | Client widening — must ship before the table is relied on | client first |
| 7 | Hide the Play button when a title has an album | One conditional. Depends on #1 making albums real. | client |
| 8 | Trending from events | Needs ~2 weeks of #2's data to mean anything | server |
| 9 | Offline download | Largest, and §2.4's question must be answered first | client |

**#7 is deliberately not first**, even though it is the smallest change in the
brief. Hiding the Play button before #1 lands would leave a detail screen with
no way to play anything at all.

---

## 6b. WHAT THE FIRST ROUND OF WORK ACTUALLY FOUND

Written 22 Sep, after §6's items 1-4 shipped. Two things here were not in the
plan above because nobody knew them.

### The album had TWO causes, and each one hid the other

§1 blamed the `kind = 'video'` exclusion in `title_media`. That was real and
migration 013 fixed it. It was also not enough.

`title_media` was created `with (security_invoker = true)` in migrations 006
and 009, which means the view runs as the CALLER. `anon` has no SELECT grant
on `title_assets`, so:

```
set local role anon;
select count(*) from public.title_media;
ERROR:  permission denied for table title_assets
```

**The album has never loaded for anybody, on any build.**
`ApiContentRepository._album()` catches its own failures and returns an empty
list on purpose — "a title whose extras cannot be loaded should still play" —
so the fault never appeared as an error. The screen just drew no grid.

Fixing either cause alone would have changed nothing visible. That is worth
remembering the next time something is "obviously" one bug.

It was found by accident: migration 013's `create or replace view` dropped the
`security_invoker` option, because CREATE OR REPLACE VIEW resets reloptions
rather than preserving them, and the Supabase linter flagged the result. The
lint looked like a regression to undo; undoing it is what produced the error
above.

**The fix is not the GRANT the hint suggests.** `title_assets.object_key` is
the address of every private video in the media bucket. Migration 013b makes
the owner-rights choice explicit instead, with the reasoning written into the
file so that nobody "restores" 006's clause and silently empties the album
again.

### The R2 layout, and why the folder is frozen

One folder per title, in both buckets:

```
innocent-media/<slug>/video/20260922-solar-a1b2c3d4.mp4
innocent-public/<slug>/photo/20260922-poster-e5f6a7b8.jpg
innocent-public/<slug>/thumb/20260922-clip-01-c9d0e1f2.jpg
```

The two buckets stay two: that split is the security boundary (private video
behind a signed URL, public stills so the catalogue can draw itself), not an
organisational one. Within each, everything belonging to one card is under one
prefix, so finding "the third clip of Solar" is one click in the R2 console
instead of a database query against a flat list of every video ever uploaded.

**The folder is frozen at creation and a rename does not move it.** Every
`title_assets.object_key` and `titles.locator` names the prefix; a rename that
rewrote R2 would have to copy every object and leave the catalogue broken in
between. The folder is an address; `titles.title` is the label.

Legacy `v/…` and `p/…` keys are left exactly where they are — they are still
valid keys and everything resolves them in full. A title created before
foldering is given a folder the first time it is opened in the console, so
later uploads land in the right place without a backfill migration.

### Geography: what was decided and why it is not the IP

The concern raised was right: a VPN makes `cf-ipcountry` lie, and an interest
model fed a lie recommends the wrong things. The raw address is the wrong
instrument for it, on two counts. It does not actually detect a VPN — telling
a Singapore exit node from a real Singapore viewer needs a commercial
IP-intelligence feed, not the address. And on an adult catalogue, a table
joining viewing history to IP addresses is the highest-liability object in the
system and the one thing in it that could identify a real person.

So three things are stored instead, and between them they do everything the
request was about:

| | |
|---|---|
| `country` | from `cf-ipcountry`. Free, and wrong under a VPN — which is the point of the other two |
| `tz_offset_min`, `locale` | reported by the DEVICE. **A VPN does not change a phone's clock or its language.** A device at UTC+06:30 with a Burmese locale is a Myanmar viewer whatever the exit node claims |
| `ip_hash` | HMAC-SHA256 of the address with a rotating secret. Two events from one network match; the address cannot be recovered. This is what answers "these forty searches came from one connection" and "this account is being used from nine networks" |

The verdict lives in the `event_geo` VIEW rather than in a column, so the rule
can be corrected in one statement and every historical row is re-judged for
free. Proven on the case that prompted it: connection `SG`, phone at +06:30
and `my` locale → `geo_trust = vpn_suspect`, `audience = MM`. The recommender
groups by `audience`, so a VPN user still gets Myanmar recommendations.

---

## 7. DECISIONS NEEDED BEFORE ANY OF THIS IS BUILT

| | |
|---|---|
| **B1** | ✅ **(a) now, (b) later.** Plain files in app-private storage, deleted when the subscription lapses. Keystore encryption is the upgrade path, not the first version — and the difference will be stated plainly rather than implied. §2.4 |
| **B2** | ✅ **Country, plus the two device signals, plus a salted IP hash. Never the raw address.** See §6b. |
| **B3** | ✅ **90 days**, rolled into `event_daily` and `search_daily` first. `prune_events()` rolls up every unrolled day before it deletes anything, in that order always — otherwise a prune is data loss rather than hygiene. |
| **B4** | ✅ **`id` frozen, `label` editable.** Which is the whole feature: `titles.category` stores the id, analytics group by the id, a saved tab selection holds the id. Only the word on screen moves. |
| **B5** | ⏳ See below — the question was what multipart even is. |
| **B6** | ✅ **Not wanted.** Series, seasons and episodes are off the table, which also removes the one item `movies_data_model_v2.md` §2 said had to widen the client before the tables could be filled. |

### B5, since the question was what the 5 GiB thing actually means

R2 accepts a file in one of two ways.

**One PUT.** The browser opens a connection, sends the whole file, done. This
is what the console does, it is simple, and R2 caps it at **5 GiB**. A typical
film is far under that: an hour of 1080p is usually 1–3 GB.

**Multipart.** The file is cut into pieces, each piece is uploaded separately
and R2 glues them back together. It is how anything up to 5 TB gets in. It is
also three separate operations instead of one — start, upload each piece, then
finish — and the page has to track which pieces succeeded and retry the ones
that did not.

The decision taken for now: **refuse a file over 5 GiB before the first byte
is uploaded**, with a message saying to split or re-encode it. The reason is
not laziness about multipart. It is that without the check, the page would
upload for forty minutes and then fail with an unreadable CORS error — R2 does
not attach CORS headers to its error responses, so the browser blocks the
reply before JavaScript can read it. **An hour of uploading that ends in
"something went wrong" is the single worst failure available here.** A refusal
that takes no time and says what to do is better in every way.

Multipart gets built the first time a file actually needs it. Say so then.

B4 is the one remaining decision that is expensive to change afterwards.
