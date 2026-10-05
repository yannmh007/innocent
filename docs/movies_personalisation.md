# Movies: what the big platforms do for the viewer, and what Innocent now does

Owner request (2026-10-05): is the player at MX's level; what is weak in
the Movies UI/UX next to Netflix, YouTube, Facebook and the other big apps;
fix it — with the algorithms on the SERVER, and with thought for how people
actually use these apps.

## 1. Research

**Netflix** (Gomez-Uribe & Hunt, "The Netflix Recommender System", ACM TMIS
2015, and the Netflix tech blog). The home page is not one algorithm but a
page of rows, each ranked for the member: a Personalized Video Ranker orders
the whole catalogue per member and feeds the genre rows; **Continue
Watching** is its own model (how likely the member is to come back to a
title they paused); **Because You Watched** rows are built from item-to-item
similarity to one recent title; Trending is a separate short-window model.
The most used row is Continue Watching.

**YouTube** (Covington, Adams & Sargin, "Deep Neural Networks for YouTube
Recommendations", RecSys 2016). Two stages — candidate generation, then
ranking — and the ranking is trained on **expected watch time per
impression**, not click-through: ranking on clicks "often promotes
deceptive videos that the user does not complete (clickbait)". Impressions
are the denominator; without them a ranking measures only what was already
promoted.

**Android** (developer.android.com, Engage SDK, "Continue watching"): the
platform's own Continuation cluster — unfinished videos and the next
episode, with the position, synced across the user's devices when signed
in.

**Post-play / autoplay** (Netflix engineer's account on Hacker News, 2019;
University of Chicago study of autoplay, arXiv 2412.16040, 2024). Autoplay
of the next episode was the largest single increase in hours watched
Netflix ever measured; the countdown went from 10 s to 5 s because shorter
windows raise viewing. The Chicago study found that the 5 s window leaves
"hardly enough time to reconsider" and that viewers with autoplay off
watched more deliberately. Netflix asks "Are you still watching?" after
three episodes with no interaction.

**What that means for Innocent.** The lasting habit these apps build is not
a trick; it is that the app remembers you: where you stopped, what you like,
what comes next. That is what was missing. The parts of the research that
are about squeezing hours out of people who would rather stop are left out
on purpose (see section 4).

## 2. Innocent before

* **Every film restarted at 00:00.** The player keeps no resume point for a
  stream — rightly: its URL is signed and different every time, and the
  player's resume UI sits on the Local tab in front of the age gate
  (player_provider.dart, `_isEphemeral`). Nothing else kept one.
* **The same home page for everybody**: Trending, Recently added, a row per
  category. No Continue watching, nothing personal, no "More like this" —
  a title's page ended in a wall.
* **Trending counted plays**: one person replaying a title ten times
  counted ten times, and a title opened and closed at once counted as much
  as one watched to the end.
* **No impressions** were sent, so no click rate could ever be computed.
* **At the end of an episode, nothing**: the next one had to be found by
  hand.
* On the title page the Play button was under the synopsis — below the
  fold on a small phone.

The player itself is at MX's level for features (gestures, the five screen
modes, subtitles, PiP, background play, sleep timer, decoders, A-B repeat,
EQ, lock and kids lock — see player_gestures.md and
player_playback_modes.md); what it lacked was everything above, which is
about the catalogue rather than the player.

## 3. What changed

### Server (migration 039, applied to the live project)

All built from the events the app already sends (play_progress every 30 s
with position and duration, the final event with the furthest point,
play_complete at 90 %, detail_view, bookmark_add). The viewer is the
request's own — `auth.uid()` and the install id — so no caller can name
someone else.

| Function | What it does |
|---|---|
| `_watch_state(keys)` | per title and clip: latest position, furthest, length, when, finished (play_complete, or ≥ 92 %), removed by hand |
| `my_watch_state()` | the caller's own, for the app's resume points |
| `_continue_watching` | started (≥ 30 s or 3 %), unfinished, not removed, last 60 days, one card per title, newest first, each with its resume point |
| `_similar_scores(t)` | 0.40 genre Jaccard + 0.25 same category + 0.15 keyword Jaccard + 0.20 co-watch (viewers 20 %+ into both over either, × n/(n+10)) |
| `similar_titles(t)` | "More like this" |
| `_for_you` | 0.45 taste (similarity to what they watched, weighted by how much and fading over 30 days; bookmarks count 0.8) + 0.25 Bayesian completion ((completes + 5·mean)/(starts + 5)) + 0.20 trending heat + 0.10 freshness; nothing for a viewer with no history |
| `_because_you_watched` | similar titles to the latest one they got 20 %+ into |
| `trending_title_ids` | each viewer once per title, weighted 0.3 + 0.7 × fraction watched, 3-day decay |
| `landing_rows()` | Continue watching, Trending, Picked for you, Because you watched X, Recently added, categories — same contract, so the rows reached the app already installed |
| `row_catalogue()` | See all for the new rows |

Co-watch counts are refreshed hourly into `title_cowatch` / `title_reach`
by the landing page itself (`_maybe_refresh_cowatch`; the project has no
pg_cron): scanning the whole event log per seed on every page load would
cost seconds at scale. Measured on the live data, signed in: 81 ms with the
scan per request; with the counts table, 16 ms per page load, and 257 ms
for the one load an hour that refreshes the counts.

Small-catalogue honesty: with ten titles and a dozen viewers, co-watching
means nothing yet, so similarity leans on what a title is; the co-watch
term grows by itself as viewers arrive.

**Tuning without a release**: every weight and window above is a number in
SQL. Change it with `create or replace function` and the next page load
uses it.

### App

* **Films resume where they stopped** — on this phone and the account's
  others. `WatchLedger` (the Movies feature, behind the age gate) is
  written from every progress sample, merged with `my_watch_state()`, and
  Play opens the stream at the held position.
* **Title page**: "Resume 12:34" (with "· 3 of 7" for an album clip), a
  progress bar, minutes left, Start over; the button above the synopsis;
  progress lines on album video tiles; **More like this** at the foot.
* **Hub**: Continue watching first among the rows, ordered from this phone
  at once (the server's copy is a step behind until the events flush), the
  account's other phones after; a progress bar on each card; a tap plays
  from where it stopped; long press removes it (with Undo).
* **Up next**: at the end of an album video the next one (the admin's
  order, so episodes play in order) is offered on a card with a 10 s
  countdown, Play now and close.
* **Impressions and card clicks** from every hub row, with the row and the
  position.

## 4. The line drawn

The owner asked for an app people cannot do without. These are the choices
made about that, deliberately:

* **Countdown 10 s, not Netflix's 5 s** — long enough to read the title and
  decide.
* **"Still watching?" after three videos started by the countdown with
  nobody touching the phone** — the next waits for a tap. Autoplay should
  serve someone watching, not run on for someone asleep, on their data.
* **Autoplay follows "Play next automatically"** in Settings; off means the
  card waits.
* **Never autoplay onto a paywall.** A next clip the viewer cannot open is
  not offered; an autoplay that lands on a payment screen is an advert.
* **Continue watching can be edited** (remove, undo), as on Netflix.
* **Ranking on watch time, not clicks** — the YouTube lesson, which is also
  the honest one: it rewards titles people finish, not titles people are
  tricked into opening.
* **No personal row for someone with no history** rather than a "for you"
  that is Trending under another name.
* **Adult titles never on a general row**, so the first screen is safe to
  have open in front of someone.

## 5. Verification

* Live database: every function run against the real events as `anon`
  with a real install id and as a signed-in account (Continue watching
  carried "Unknow" at 0:58 of 18:29; Picked for you, Because you watched
  "Test 001" with 7 titles; similar_titles); internals not executable by
  `anon`.
* Unit tests: the ledger (newer wins, merge, one per title, hidden, cap,
  storage round trip, server rows), the hub's merge with the server row,
  Up next (offer per video, the still-watching count, the countdown, a tap,
  no countdown when asking or when autoplay is off).
* Harness renders: hub with Continue watching, the title page with Resume /
  Start over / More like this, the Up next card and Still watching.
* Device lab, live catalogue (run 37328292300, Android 14, a fresh
  install): hub, title page and album flows pass, no crash or ANR. The
  title page drew More like this from the live `similar_titles`; the hub
  had no personal rows, which is right for a viewer with no history; 19
  impressions and the card click reached `events` with their row names.
* Not verifiable in the device lab: the emulator cannot play a stream past
  ~3.5 s, so a real resume and a real Up next need a phone.

## 6. Follow-ups

* Use impressions in the ranking (click rate per position, so the first
  slot's luck is discounted) once there are enough.
* A daily rollup and prune: `rollup_events` / `prune_events` exist and are
  scheduled by nothing.
* Three test functions (`landing_rows_v039`, `row_catalogue_v039`,
  `trending_title_ids_v039`) are left in the database with no grants; drop
  them from the SQL editor.
