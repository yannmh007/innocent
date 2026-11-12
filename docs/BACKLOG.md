# BACKLOG — what is left, and why each item is where it is

2 Sep 2026, against **v1.64.4+317**. Ordered by (risk x likelihood) / cost, not
by how interesting the work is.

Nothing here is urgent. Several items are deliberately marked **do not do yet**,
with the condition that would change that. An item with no trigger is an item
that gets built too early.

---

## 0. OPEN AS OF 30 OCT 2026 — carry these forward

Written at the owner's request so nothing below is lost between sessions.
Newest first within each group; tick an item by deleting it in the commit that
does it.

### WHERE THINGS STAND — read first in a new session (12 Nov 2026)
- **Work branch `claude/extract-github-release-oteqr5`** holds everything
  not yet live (main is 1.64.83, 27e6a938). A new session starts on main:
  fetch this branch and work on top of it, or the notes below are missing.
  Push to it (fast-forward), the owner's choice of 8 Nov: a session's own
  branch starts at main, has no history in common with this one, and
  would need a force-push.
- **1.64.81 (394) is out, 8 Nov**: the Privacy text, the HLS read-ahead
  fix, the playback telemetry (`play_summary`, ladder `play_stall` with
  `ahead_ms`, `error` codes, `grant_ms`), the 7 Nov streaming fixes and
  5b's rung weight by the fastest 20 s. Details under "Next app release".
  On the branch only, by design: the Google sign-in nonce and the lab's
  hooks (tour skip, `rungKbps`, `ladderRungKbps`, `lab_peak`'s A/B, and
  since 9 Nov the jumps in Auto: `_labAutoJumps`, `LabStream.autoJumps` /
  `jumpVariant`, the Test Lab path's `INNOCENT_LAB_AUTOJUMPS` and its
  home-trip skip; since 11 Nov `LabStream.jumpRule` (`lab_jump` on/off →
  `keepSpare`), the Test Lab path's `keepSpare = true` and
  `_labAutoJumps(alternate:)` / `StreamCacheServer.spareForJumps`, and
  `_Ladder.pool`'s lab `connectionFactory` (`_labTimedConnect`, DNS / TCP /
  TLS apart in the trail)).
- **1.64.83 (396) is out, 12 Nov**: the player redesigned (skill
  `ui-design`, `widgets/player_ui.dart`) and the engine judged by the
  film's clock, and nothing else: released like 1.64.82 from main plus the
  session branch `claude/focused-johnson-1915dp`. On this branch too
  (6a6bade6), so the next release from here carries it — and is 1.64.84:
  the "1.64.83 candidate" of b3e2bad1 (5d's keepSpare, the play_summary
  stash) has not shipped. Details under "Player redesign".
- **1.64.82 (395) is out, 11 Nov**: the player audit
  (docs/player_ux_audit_2026_11.md), and nothing else: released from main
  1.64.81 plus the audit (session branch `claude/focused-johnson-1915dp`),
  so none of this branch's unreleased work went with it (5d's keepSpare,
  the play_summary stash, the lab hooks). The audit is on this branch too
  (822a7e8f) and the next release from here carries it. Details under
  "Next app release"; what the audit left open under "Player audit".
- **Live already**: migrations 077–080, ingest v55 (0dfe2a5),
  transport-check every 6 h, the backup drill.
- **The owner still has to**: send the DNSSEC "Active" screenshot on
  12 Nov; update a phone to 1.64.83 and say if the player's menus look
  right now (⋮, CC, the error card), and if "stopped responding" ever shows
  again on a file that plays. (The
  five open films were approved: every `open-film-%` title reads
  `approved`, checked 8 Nov.) Reminders: trig_01Q1Z21R5QVuAzPJQqjTfK7W (12 Nov),
  trig_01G9fdiXXaVGHSbMgqiJc1bg (13 Nov).
- **5d, a connection kept open for a jump (11 Nov, on the branch, ON by
  default; ships with the next release)**: `StreamCacheServer.keepSpare`.
  Measured first (device lab M1, 42951731347): on the weak line a jump's
  answer was 885 ms on a new connection (DNS 25 + TCP 147 + TLS 189 + the
  Worker's wait 441) against 466 on a kept one, and 33 of 34 jumps that cut
  the read ahead in flight paid the handshake (a response cut before its
  end takes its connection with it). Now a ladder's segment reads take
  turns on two pools and a jump takes the one with no read on it: device
  lab S1/S2 (42957372146, 42982586873; 112 pairs, both orders) the answer,
  the jump's stop and the first picture each 0.30 s sooner (stop: 69
  pairs against 33, p 0.0002; the A/A spreads 0.31-0.35 s over 21-28);
  stops after 3 (0.61-0.73 s) against 0, picture after alike; no Worker
  request more. Gate: jumps on Big Buck Bunny 15 of 15 with it on (S2), and
  twice more on the build with it on by default (G1, G2). Test
  Lab with it on: OPPO 16 of 16 (42982587122), realme 16 of 16 on its rerun
  (42985879375; its first run's line read 64-303 kbps and the checks never
  began). On the phones' fast lines every jump found a connection open
  either way. Review §5 "Runs M1, S1, S2". Follow-ups: mark a pool lost
  when a read on it ends cut; the Worker's own wait (~0.3 s, R2 most
  likely) needs a `Server-Timing` header to split (a Worker change).
- **play_summary was lost for a playback the app never came back to
  (found 11 Nov, fixed on the branch)**: it was sent only as the player
  screen closed; an app sent to the background and closed from Recents
  never closed it (1.64.81's first viewer: 4 playbacks, 2 summaries; the
  labs' 79 force-stopped plays: none). Now kept on the phone when the app
  goes to the background mid-playback and sent at the next start with its
  own time, session and version (`stashed: 1`). Viewer data otherwise: 2
  `play_summary` rows since 1.64.81 (one viewer, open films, 212 s played,
  no stall, 20 jumps 2.7 s in all); `network_kind` is never sent (no
  plugin, by design), so "per network" needs the measured line in the
  summary instead.
- **5c tried and taken out (9 Nov)**: a jump's first segment from a rung
  that arrives in ~0.5 s did not pay. Device lab J and J2 (42616754742,
  42628158249; 224 jumps on the weak line, on/off alternating, both
  orders): the jump's own stop a median 0.18 s shorter, the first picture
  no sooner, a second stop right after the jump in 23 jumps against 5, a
  softer picture. Test Lab 42641532315: the phones' lines (realme
  ~15 Mbit/s, OPPO ~0.3) gave the rule nothing to act on. A jump's wait is
  the Worker's answer (0.3-0.9 s), the phone's restart (0.4-0.7 s), then
  half a segment's bytes (review §5). The player code is back as it was
  (cdc1319); the `weakjumps` flow and the jumps in Auto stay, to measure
  jumps. On that build: device lab J3 (42655210613) jumps 15 of 15, and
  an A/A of the flow came apart by 0.35 s over 28 pairs (5c's 0.18 s gain
  in the jump's stop is that flow's noise; its second stops are not);
  Test Lab 42655210615, the OPPO alone: 16 of 16 on 11.5-38.6 Mbit/s (the
  three failures before were its 0.3 Mbit/s line).
- **5b (8 Nov, live in 1.64.81)**: the master weighs a rung by its
  fastest 20 s (`PeakRule.window`), decided by 32 weakline passes in runs
  H, H2, H3 (review §5): 480p or better 89 % against 69 %, no stop;
  Test Lab 42461966293: 15 of 15 on both phones.
  `deep` (a deep buffer weighed against the whole line) tried, dropped.
  The weakline flow now plays `WEAK_PASSES` passes per run, alternating
  `lab_peak` variants: use it for every A/B (one pass says little).
- **Next streaming work**: 5d's follow-ups (a pool marked lost when a
  read on it ends cut; the Worker's wait split by `Server-Timing`, the
  owner's call), or 2 (climb back only when the slow average clears the
  higher rung). Not 5 as written: it doubles the Worker requests and would
  take 5d's spare away (review §5). Method in
  `docs/streaming_review_2026_11.md` §5 and skill `device-labs` (weakline /
  weakjumps flows; read the cap probe first; passes alternating per
  variant, then the other order; read a jump's answer in parts first; an
  A/A of 21-28 pairs spreads 0.31-0.35 s). Lab config now: G2's
  `FLOWS="weakjumps jumps"`, two passes (on, off) then the gate — with 5d on
  by default the gate passed 15 of 15 twice (G1 42995970597, G2
  42999722877); Test Lab `cloud.env`: the realme alone (its rerun) — name
  both phones again for the next run.

### Player redesign (12 Nov, 1.64.83) — skill `ui-design`
The owner's screenshots of 1.64.82: "Playback failed / The player stopped
responding" over a local file that kept playing; ⋮ and the subtitle panel
translucent with the controls showing through, outline rings — "a toy"
beside MX Player. Done:
- The false alarm: MpvLink calls a call stuck after 4 s; the screen now
  asks the film's clock (`domain/engine_check.dart`): moving → alive (the
  link renewed once a film after 15 s), still 3 s playing / 8 s paused or
  buffering → stuck. An error the film survives is a small warning card;
  only one that stopped it takes the screen. Never a signed address on it
  (`domain/error_text.dart`).
- One look for every menu (`player_ui.dart`: PlayerPanel, PanelRow,
  PanelTile, PanelSwitchRow, PanelChoiceChip, PlayerDialog,
  showPlayerSheet…); the controls hide under a panel, dialog, the error
  card and any sheet the player opens. CC lists the tracks itself.
- Found on the way and fixed: after Next the screen acted on the FIRST
  film (title, bookmarks, favourite, share, cut, info, Retry, seek
  previews); the Video display switch hid ⋮'s sixteen actions; Playing
  queue was a stub ("1 items", a dead drag handle) — now the folder; a
  deleted bookmark stayed listed; bookmarks stored a signed stream's
  address or a Private Folder film's name; the resume card blocked taps.
- Proof: device lab 43185129320 (all four player flows exit 0 on the final
  build; 43154335111 / 43176762134 before the review's fixes), Test Lab
  43180990404 (realme, Sintel 16/16, no engine verdict), 1690 tests,
  `player_layout_test` 1062 photographs, a reviewer pass (its findings
  fixed: one relink a film, the warning card, TalkBack live region).
  Build 43186533253: arm64 95641124 bytes `1560c80f…d4a8`, arm32 87609628
  bytes `beb69528…7733`, GitHub's digests agree; app_releases moved at
  09:19 UTC after a rolled-back dry run.
- Every other view, the same day (owner's request; session branch
  9a4f531a, on this branch, not yet released): the screens harness
  (`test_screens/`, 107 screens) in Burmese and English on both phones and
  in Burmese at 320 dp — no overflow anywhere; looked at one by one. Fixed:
  the downloader's tabs dropped the theme's font (a bare `labelStyle`); the
  information dialog (`MxDialog`) moved onto the player's tokens; the Up
  next card on the player's surface. And (owner's screenshot): upright,
  ⋮ rose over the whole picture. First the picture was lifted out of its
  way; the owner then chose misted glass instead: every player menu is
  frosted glass (`PlayerGlass`: the film blurred under a 72 % tint;
  opaque on Android Go and 32-bit-only phones), the picture stays put,
  the upright sheet stops at 55 %, and sideways every player sheet is a
  full-height side panel (they were bottom sheets with ~300 dp that cut
  their lists). Session branch a74047a6, on this branch; ships with the
  next release — worth a look on the realme/OPPO for smoothness under
  an open menu (the blur is redrawn every frame).
- **Every screen size** (owner, 12 Nov): `docs/devices_2026_11.md` — the
  study (large-screen tiers, TV quality, window size classes, Android
  16/17 ignoring orientation locks at ≥600 dp) and the plan. Phase 1 done
  (session branch 851dce81, on this branch, ships with the next release):
  TV overscan margins as insets; the player's remote and keyboard keys
  (media keys, K/J/L, M, Esc, ?), mouse hover and right-click; 25 list and
  form screens capped at 840 dp; upright player panels at 640.
  **Phase 2 item 1 done** (12 Nov, on this branch, ships with 1.64.84):
  two panes from 840 dp (`core/ui/list_detail.dart`) — Settings as the
  list beside the open page (a page opened from it opens in the pane, Back
  closes it first), the Video tab as the folders beside the open folder's
  videos (one search for both; a selection of the videos is the pane's);
  a window narrowed to one pane keeps what the person opened (never over
  the player); grids add columns with width (posters 3 on a phone, 7–8 on
  a tablet sideways; Status Saver, Private Folder, the picker); the
  downloader capped at 840. Found on the way, fixed: four settings dialogs
  closed through the page's context (in a pane they would have closed the
  page, the pane blank); Back closed the Video tab's search but left its
  query (the folders stayed filtered, nothing on screen to say why); a
  folder found by its name opened as "No video matches"; a folder's own
  search filtered the folder list behind it; on a TV the Video tab's title
  sat 48 dp in from its list; the Folders title cut on a 320 dp phone (the
  view mode goes into ⋮ there); a search that took the open folder away
  left its videos selected. Proof: 1723 tests (19 new), the screens
  harness on tablet, foldable at 841, Chromebook, TV and three phones in
  Burmese and English, 1.3 at the tightest — no overflow; sheets sent.
  Next: the ~19 list screens Phase 1 left at full width (History,
  Playlists, Favourites, Watch later, Recycle bin, music's album / artist /
  playlist / folder, Network stream, Stream cache, Cloud drive…), then
  Phase 2 item 2 (targetSdk 36 readiness).
- Left: the gestures help keeps its own full-screen look; the paste bar's
  Burmese hint sits a little high (the font's metrics); a test that drives
  the 750 ms engine check with a fake wedged engine.

### Player audit (11 Nov) — `docs/player_ux_audit_2026_11.md`
The owner's request: every menu and button of the player, both ways round,
in every language, MX-level. Found and fixed (1.64.82): Back closed the
film over an open menu; no subtitles or audio choice in portrait; holding
Next never opened the repeat menu; Display Settings did nothing; "Track
auto/no" in the audio menu; a 4 s timer leaked per film; the last history
entry lost on close; a dozen layouts cut off in Burmese, sideways or at a
large font. Left open:
1. On purpose, the owner's call: Back while the screen is locked still
   leaves the film (Kids Lock swallows it); the error card shows libmpv's
   own sentence (host only since 1.64.83) under its title; "Online
   subtitles" shares a search link (no url_launcher in the app).
2. Toward MX, by what a viewer here would miss: chapters (libmpv's
   `chapter-list`; local MKVs have them, the catalogue does not); subtitle
   search and download in the app (OpenSubtitles, a key on the server);
   the track playing marked in the menus on the ladder engine (1.64.82
   reads it from libmpv only); cast.
3. How to check a player change: `test/player_layout_test.dart` (1,224
   layouts with LANGS=my,en,th SCALES=1.0,1.3; real fonts from test/fonts
   and the SDK; PLAYER_SHOTS=<dir> photographs them),
   `test/player_controls_test.dart`, and in the device lab
   `layout_portrait player_audit layout_landscape player_audit_land`. The
   controls hide 4 s after a tap and Maestro needs about a second a step:
   a flow acts on freshly shown controls, its two taps 0.8 s apart (closer
   is a double tap: play/pause). A build of main shows the first-run tour
   (layout_portrait skips it); run.sh's rotation line read "now 0" in run
   42993934736 while the screen was 2400x1080 — the UI dump's bounds are
   the truth.

### Streaming without stutter (7 Nov) — `docs/streaming_review_2026_11.md`
The owner's request: no stutter, nothing that annoys a viewer. Evidence:
live events (labs only, real viewers one or two) and the six newest lab
runs. Done on the branch (ships with the next release): ladder stalls,
tap-to-picture (`grant_ms`), failures (`error` codes) and one
`play_summary` per playback (migration 080 live; PlaybackQoe), blips
(< 250 ms) counted apart from stops, and the film in hand at each stop.
Also on the branch (7 Nov, review §5), proved step by step on one shaped
line (4 → 0.9 → 3 Mbit/s, 8 s with none, 0.5 % loss, 120 ms): from 3
stops / 5.9 s frozen (run B') to **none** (run E, 42373118426) by
(a) an unmeasured film opening at 480p on every connection; (b) the
ladder's first frame taken from ExoPlayer, not from libmpv's stop (the
"first picture in 0.2 s" of earlier labs was that artefact; open_ms
before and after this change are not comparable); (c) the start rung
leading the master playlist; (d) ExoPlayer's meter keeping the start rung
until a reading (works since run F, 42381638569: the guess must be made
where the selection is built). The line read during a read (fix 1) stays:
no stop in any run with it; its effect on picture quality is not shown
(A' 3 % at 480p, E 87 %, F with fix 1 3 %: early readings decide it).
Test Lab run 42376634865: all checks passed on both phones, honest first
frame 1.5 s / 3.1 s. **The lab line was never shaped
before 7 Nov** (the runner's bpf filter on eth0 took the ifb redirect's
packets): it now runs through `tool/netlab/line_relay.py` on loopback and
proves its cap first. Next, each proved by an emulator A/B on that line:
1. ~~resume after a stall on 5 s~~ tried, undone: it made blips a visible
   1.26 s stop;
2. climb back only when the slow average clears the higher rung (720 →
   240 → 720 → stall);
3. ~~a jump on a slow line takes its first segment from the rung below~~
   (OPPO seek 5.9 s): see 5c, tried and taken out;
4. ~~a dead segment read noticed in 3–4 s~~ dropped down: 8 s with no
   line cost nothing with 26 s in hand (run C); it matters only with a
   nearly empty buffer;
5. two connections for a ladder's reads on a lossy line: one carries
   ~1.5–2 Mbit/s at 0.5 % loss and 120 ms whatever the cap (TCP's own
   limit), less than 720p's peak; costs Worker requests: each read in two
   halves doubles them (an hour of film at 2 MB a read: 720p 360, 480p
   196, 360p 124, 240p 66 requests; the Free plan's 100,000 a day ~510
   viewer-hours at 480p, ~255 with it), and both connections busy at a
   jump would undo 5d (review §5, 11 Nov);
5b. ~~picture quality on a weak line~~ done 8 Nov: a rung is weighed by
   its fastest 20 s, a rung not read by a read rung's ratio
   (`PeakRule.window`; runs H/H2/H3: 480p or better 89 % against 69 %,
   12 pairs of 14, no stop). Left: on a line that falls under the rung in
   hand, the step down lands on 240p where 360p's average fits (ExoPlayer
   defers it to 25 s in hand, then 360p's peak over 0.7 does not fit);
   weighing a deep buffer against the whole line made it worse (`deep`,
   720p in and out). A softer picture, not a stop: low priority;
5c. ~~a jump's first segment from a quick rung~~ tried 9 Nov and taken
   out (runs J, J2, Test Lab 42641532315; review §5): the segment is not
   the wait — the Worker's answer and the phone's restart are; the rule
   saved ~0.2 s and cost a second stop after 23 jumps of 112 against 5.
   The plan as it was written:
   a seek on a ~5 Mbit/s line froze 1.7 s on the realme (first segment
   720p): fix 3 below, for the first segment after a jump only. What the
   trail says (Test Lab 42376634865): the realme's jump fetched a 537,551 B
   720p segment in 1401 ms (answer 380 ms) at ~4.6 Mbit/s and stood 1699 ms;
   the OPPO's same segment at ~30 Mbit/s took 473 ms, frozen 402 ms. A jump
   needs one whole segment (1 s of film to play), so its size is the wait.
   Plan, read in Media3 1.9.2's AdaptiveTrackSelection: on a seek in Auto,
   `SteeredSelection.getSelectedIndex` returns the highest rung whose
   segment arrives in ~0.5 s at the meter's estimate (weight × 2 s /
   estimate), for the first chunk after the jump only; then back to the
   rung before the jump — ExoPlayer's own rule would hold the lower rung
   until 10 s are in hand (minDurationForQualityIncrease), a soft picture
   for 10 s after every jump. Lab: the jumps (`lab_jumps`, LAB check
   frozen=) on the weak line in passes, `lab_jump` on/off alternating;
   then Test Lab on both phones;
5d. a connection kept open for a jump: done 11 Nov, on by default
   (`keepSpare`; runs M1, S1, S2, Test Lab 42982587122 / 42985879375;
   review §5): a ladder's segment reads take turns on two pools, so a jump
   that cuts the read in flight finds the other's connection open — the
   answer, the jump's stop and the first picture 0.30 s sooner over 112
   pairs, no Worker request more;
6. labs to add: ten minutes on a weak line, a link expiring mid-film, a
   low-end and a 32-bit Test Lab phone, two runs per build.
After the release: frozen seconds per minute played, from `play_summary`,
per version and network — the number each step must lower.

### Architecture review, eleven layers (7 Nov) — `docs/architecture.md`
Checked live against a classic web-architecture picture the owner shared.
Most layers are sound (jobs, backups, search for Burmese, rate limits,
security). Found, most urgent first:
1. **Privacy dialog: rewritten, on the branch, ships with the next
   release** (7 Nov). It said "runs entirely offline… sends nothing"; now
   it says what is sent (usage records under the account or a random
   install id, searches included, 90 days then daily totals only; playback;
   reports a user sends), in en/my/th (`app_strings.dart` and the .arb
   files). The dialog scrolls now (test/privacy_dialog_test.dart fails in
   all three languages without it). The owner approved going ahead
   ("ဆက်လုပ်ပါ အကောင်းဆုံး"); the wording can still change before release.
2. **DONE 7 Nov: analytics rollup and 90-day prune run daily.** Migration
   078 `events_housekeeping()` (service role; index on occurred_at), called
   by the ingest house step, ingest **v54** (SHA 261638b). First run 03:46:
   event_daily 35 days, 366 rows, all 2,299 events counted; search_daily
   3 days. Nothing past 90 days yet (first on 22 Dec).
3. **DONE 7 Nov: transport-check on a schedule** (every 6 h asked; on main
   with the next main push, a9fbccb). GitHub e-mails the owner when a
   scheduled run fails: the owner's Actions e-mail is on, failed workflows
   only (screenshot 7 Nov), and the pushes and dispatches act as the
   owner's own account (get_me: yannmh007), so the e-mail reaches the owner.
   Watch: the first scheduled run on main is green.
4. **DONE 7 Nov: restore drill, weekly.** Migration 079 (verified_at,
   verify_error on db_backups; backup_verify_due, backup_verified), ingest
   **v55** (SHA 0dfe2a5): the newest backup is read back, hash-checked,
   unsealed, un-gzipped, parsed and counted per table, in the function;
   a failure goes to the owner on Telegram and is retried daily. First
   drill 03:52: backup #47 (sealed), 50 tables, passed. Still by hand: a
   full restore into an empty database.
5. **DNSSEC: enabled 7 Nov, pending** ("pending while we automatically add
   the DS record"). Cloudflare Registrar publishes the DS in 1–2 days; the
   12 Nov reminder asks for a screenshot showing Active. Never press Cancel
   Setup. CAA: none, and none wanted (`docs/architecture.md`, layer 1).
6. When the catalogue reaches thousands of titles: `search_titles`' fuzzy
   half as `needle <% search_text` with `pg_trgm.word_similarity_threshold
   = 0.45` set on the function (EXPLAIN: Seq Scan today, Bitmap Index Scan
   so); and a short public Worker cache for landing and row RPCs when they
   load the database. Not before.

### Next app release (after 1.64.82)
- **1.64.82 is out** (11 Nov, main 72b20dd, build 42996818415; arm64
  95628676 bytes `dee484cc…de28`, arm32 87598952 bytes `907e8350…3929`;
  GitHub's asset digests agree; app_releases moved at 10:23 UTC after a
  rolled-back dry run, mirrors on the GitHub release). The player audit
  only, on main 1.64.81: 357dfb9a, then 72b20dd adding the lab's player
  flows. Proved before the push: the release tree's 1663 Flutter tests and
  check.py; its Build 42986335820; device lab 42986323922 (plain: genres,
  jumps 15/15); Test Lab 42986497192, the realme alone, 16/16 (one phone:
  this branch's Test Lab had two of the day's five); device lab 42996379027,
  the player flows in both orientations (Back closes ⋮ and the subtitle
  panel with the film still playing; audio and subtitles on the portrait
  top bar; holding Next opens the repeat menu). After it: Pages, Dependency
  scan and CodeQL green; Playback check 43024797061 passed on main. The CDN copy
  cannot be fetched from the sandbox (its host is blocked there); the
  Build's CDN step passed. **The next release from this branch keeps**
  `test_device/flows/player_audit*.yaml` and layout_portrait's tour skip
  (brought here with this record, `[skip ci]`, so the device lab did not
  start under this branch's own runs).
- **Added on the branch 11 Nov, for the next release**: 5d, a connection
  kept open for a jump (`StreamCacheServer.keepSpare`, on; a second pool
  per ladder, `_Ladder.spare`); a jump's answer in parts in the trail
  (`hls jump: … conn new|kept …, wait …`); `play_summary` kept on the phone
  when the app goes to the background mid-playback and sent at the next
  start (`PlaybackReporter.stashSummary` / `sendStashed`, EventSender
  `build` + `enqueue`). Leave out the 11 Nov lab hooks listed in §0
  (`jumpRule`, the Test Lab `keepSpare` line, `alternate` /
  `spareForJumps`, `_labTimedConnect`). Proof so far: device lab M1, S1,
  S2 and the gate (15 of 15), Test Lab 16 of 16 on both phones, the
  branch's 1671 Flutter tests here (the player audit's with them).
- **1.64.81 is out** (8 Nov, main 96d504c, build 42477027297; arm64
  95615240 bytes `44c1ef3d…128a`, arm32 87579964 bytes `66cd8824…5e35`;
  GitHub's asset digests agree; app_releases moved after a rolled-back dry
  run, mirrors on the GitHub release). Proved before the push: device lab
  42465757907 (plain: genres, jumps 15/15), Test Lab 42461966293 (15/15 on
  both phones), the branch's Build 42465763590, the release tree's 1288
  Flutter tests. After it: Playback check 42479026804 passed, Pages
  published, Static analysis green. Left out by design: the Google sign-in
  nonce and the lab hooks, as for 1.64.80. **GitHub's release downloads
  failed (504) for about two hours that day**: the lab and branch builds
  needed four tries, and the Dependency scan on main (42477027283) failed
  on the Gradle download, not on a finding (green on the third try); a release push is safest when a full download of the libmpv jar
  succeeds three times in a row (the CDN step publishes before the GitHub
  release, and a half-published version cannot be rebuilt the same).
- **1.64.80 is out** (6 Nov 14:20 UTC, main 0202f0a, build 42226206227,
  arm64 95609920 bytes `a519403d…8569`, arm32 87572232 bytes
  `a3dd686f…4ee0`; GitHub's digests agree; app_releases moved at 14:20,
  mirrors on the GitHub release). After the push: Playback check
  42226785108 passed, both Workers rebuilt from main (13:32), Pages
  published, the transcode and ingest runners on main claim with
  `seals: 1`. Static analysis on main went red once (42226206270): the two
  fake JWTs in `tool/js/service_key_test.mjs`, fixed on the branch
  (06c70cc); it reaches main with the next release, not before, since a
  change under tool/ rebuilds 1.64.80 for nothing.
- **Main red twice after the Claude-setup pushes (6 Nov), both fixed on
  main the same evening; 1.64.80 rebuilt, nothing uploaded.**
  (a) Static analysis 42258949696: `tool/claude_hooks_test.py` ran a hook
  by a path from a variable; now a literal command per hook. The fake
  JWTs (06c70cc) went with it. (b) Build 42255981825: one Flutter test,
  `stream_cache_hls_test` "asked a few times, not 90": 12 Worker reads
  where 8 do. A REAL BUG, timing-dependent: a film has one cache writer at
  a time, and a segment read that began while the last read's writer was
  still closing got none — its 2 MB reached the player but not the cache,
  so the next segments were read from the Worker again (bytes read twice,
  Worker requests spent). Reproduced here under CPU+disk load (4 runs in
  10); the read now waits for that close, alongside the Worker's answer,
  at most 1 s: 0 in 16. Also one metadata save per film at a time (two
  shared `meta.json.tmp`). Reaches phones with the next release.
- 1.64.80 carries Report on every title and the
  takedown address in About (P6), genres by code in the phone's language
  (TAX phase 3), the media seal's app half (the opener, the device key, the
  unseal gateway, sealed images) DORMANT — the build asks for no sealed
  copy (docs/MEDIA_ENCRYPTION.md §9 step A) — the key attestation code
  (sent only by a build that asks), and the deprecated-API renames
  (d709830). The console, its edge modules and the runners' sealing code
  reach main with it.
- **Left out of 1.64.80, by design**: the Google sign-in nonce (29b71b2,
  `api_account_repository.dart`, its test) and the lab's own hooks
  (`lib/app.dart` tour skip, `rungKbps`, `ladderRungKbps`).
- **Google sign-in nonce (29b71b2)** waits on the branch: no lab can sign in
  with Google. Before it ships, the owner signs in once with a build that
  carries it (a branch build's APK); if Google refuses the token, it stays out.
- **A release that asks for sealed copies** (§9 step C needs one as
  `min_supported`) waits for §8's gates: proxy CPU per MB and frozen time.
  R8 (attestation `app: ok`) can only be read from such a build.
- **The OPPO's Original on a borderline line** (Test Lab 41047246611): the
  10 Mbit/s Original stalled 8 s on a 4-14 Mbit/s line. The lab only skips
  it when the line is measured below the copy's bitrate; a line that swings
  around it fails. Not a regression; worth a look at how the Original's
  first fill sizes itself.

### Open test films, five more (6 Nov)
- **Approved** (all five `approved`, read 8 Nov); seeded 6 Nov 15:49 (seed run 42246218584, ingest
  v53): Cosmos Laundromat (12 min, 1920x804 2.39:1, dialogue), Caminandes:
  Llamigos (2.5 min, 1080p), Glass Half (3 min, 1080p, dialogue), Hero
  (4 min, 2D Grease Pencil, 1280x536 23.976 fps) and Big Buck Bunny (60 fps)
  (10.6 min, 1080p60, 5.1 sound). Free, C01, genre G001 (Open Movie), five
  stills each, the first as the poster. Not in the app until approved.
- **How they were chosen**: `tool/open_films.py find` (run 42240921914)
  read each candidate's licence from video.blender.org's API, from a
  runner. Only CC BY or CC0 is taken: Spring is CC BY-SA there, Coffee Run,
  Charge, Wing It and Caminandes 2 state no licence, Agent 327's file is CC
  BY-ND (studio.blender.org says so too). The seed reads the licence again,
  downloads, and checks the file is that film (H.264 at the height picked,
  sound, the length to 3 s; dry run 42243911348). Each synopsis carries the
  CC BY attribution and the source page.
- **The owner, in the console** (Review, "waiting for approval"): open each,
  play the preview, look at the stills and pick a cover, add a Burmese title
  or Animation if wanted, then Approve (or Send back with a note, to try
  that path). Cosmos Laundromat's story is a sheep who has lost the will to
  live: decide whether it belongs before approving it.
- **Then**: the transcode ladder (queued at seed; Cosmos running at 15:54),
  frames (done for all five), Playback check, and a device lab run on Big
  Buck Bunny (60 fps) and Cosmos Laundromat once approved. Note for the
  `genres` lab flow: it asserts Animation lists Sintel; five more animated
  titles in Animation may push Sintel off the first screen.
- **Found on the way, fixed**: migration 077 (live) — the service role could
  not read genres (the console's Genres section, every genre change, and a
  title made with genre words had failed since 31 Oct) nor asset_renditions
  (three silent reads). `tool/sql/service_role_grants_test.sql`,
  `tool/function_tables.py`.

### Verify what is live but not yet exercised
- **R8 — key attestation, real chains**: SEEN 6 Nov on the emulator
  (software, unknown root) and on Test Lab's realme (google-ec, TEE,
  verified, locked) and OPPO (google-rsa, TEE, verified, locked), key and
  challenge matching, revocation list read; only `app` failed, which is
  right for a debug-signed lab build. Left: the first RELEASE build that
  asks for sealed copies must read `ok: true` (`app: ok`) on a real phone,
  in the function log and in `devices.attest`, before anything is
  enforced. 1.64.80 asks for none, so it sends no chain.
- **R7 — the new Supabase keys, first real calls** (since 6 Nov): studio
  (the console), premium-request, delete-account, probe-media,
  backfill-dimensions, self-test. In the logs, each boot says `service:
  SUPABASE_SECRET_KEYS.default` and the calls are not 5xx. Also, in the
  gateway logs (edge_logs, `request.sb.jwt.apikey.payload.role`), no
  `service_role` or `anon` legacy JWT after 6 Nov 02:40 UTC, before the
  owner deactivates the legacy keys.
- **Sealed payment fields (migration 054, premium-request v15)**: the first
  sealed request (1ccbfbc5) is in, phone sealed and masked, no plain numbers
  anywhere. Still to see: the console's Requests page opening it (the number
  in full, not "(sealed — the key does not open it)"), and a request WITH a
  transaction number, to exercise the HMAC index and the reused-number check.
  Reject 1ccbfbc5 if it was a test.
- **Opaque R2 keys (studio v43, R2_NAMING_KEY)**: after the release reaches
  Pages, make a test title from New with folder `test-naming`: keys must be
  `f/<20 hex>/<kind>/<32 hex>.<ext>`, the Files page must show "test-naming".
  Delete the test title after.

### Security — done 30 Oct, to see working
- **Database backup sealed** (7d3b3d9, ingest v38, migration 055): new backups
  are `….json.gz.sealed`; the sixteen older ones are sealed a few per runner
  tick (`house.resealed` in the tick's answer). Check after a day:
  `select count(*) from db_backups where deleted_at is null and object_key not
  like '%.sealed'` is 0, and Status → Download still gives a .json.gz that
  `tool/restore_backup.py --list` reads. The owner keeps a copy of
  PII_ENC_KEY outside Supabase (RUNBOOK part 4) — without it a lost project's
  off-site backups do not open.
- **B2 keeps deleted files as hidden versions** unless the bucket's Lifecycle
  is "Keep only the last version". Until the owner sets that, the plain
  backups deleted off-site (and every pruned one) are still in B2 as hidden
  versions. Owner, once: B2 → Buckets → the private bucket → Lifecycle
  Settings → Keep only the last version of the file.
- **Payment screenshots sealed** (migration 056): new receipts are
  `<user>/<request>.sealed`; the console's `proofs` opens them (data:
  pictures, a few MB per answer, `more` for the rest). Receipts filed before
  stay as images. A copy also goes to the owner's Telegram chat as before.
- **Telegram ingest file names**: with R2_NAMING_KEY, a forwarded file's key
  is `<folder>/<kind>/<32 hex>.<ext>` — the Telegram file name is no longer in
  it. Check with the next forwarded file.
- **studio.ts `requests` op** removed (unused; inbox goes through
  premium-request).
- **Google sign-in nonce** (29b71b2) and **Transfer** limits (55a89e3): in the
  app, ship with 1.64.78. The nonce needs one real Google sign-in on the
  owner's phone before release.

### Telegram ingest: ten at once (built 30 Oct, live with the next push to main)
- ingest.yml opens lanes 1..(waiting + busy), at most INGEST_LANES (repository
  variable, 10 when unset; 1 = the old one-at-a-time). Migration 057 (queue
  depth, a lock per title for an album's places) and ingest v40 (`depth`) are
  already live; the workflow takes effect only on main.
- First real test: forward 3-10 licensed films at once; watch that lanes sign
  in 20 s apart, no FLOOD_WAIT deferrals pile up, every file lands, and the
  console's folder shows them in Telegram order.
- **Next bottleneck: transcode is one film at a time** (`concurrency:
  transcode`). Ten films in at once are ten ladders in a row. Its claim is
  already per file; two or three lanes the same way would fit inside the 20
  jobs a free account runs. Decide after the first real batch.
- Telegram may throttle one bot's parallel downloads; a long FLOOD_WAIT
  defers the file (not a failure) and the next run takes it.

### Security, next
- **Review of 5 Nov 2026: `docs/security_review_2026_11.md`** — findings
  S1-S10, plan P1-P7. Carry these until each is done:
  - **S1/P1 — DEADLINE 31 Dec 2026**: every function on the new secret
    key since 6 Nov (39daef0; canary transcode v26, then ingest v49,
    request-playback v42, studio v50, probe-media v25,
    backfill-dimensions v28, self-test v30, premium-request v18,
    delete-account v7). Owner, no code: asymmetric JWT signing keys; then,
    after a quiet week in the gateway logs, deactivate the legacy anon and
    service_role keys; then delete the Edge secret `SB_SERVICE_KEY` (legacy
    JWT, no longer read).
  - **S2/P2**: ENC rollout A→F; every film and photo is still plain in R2.
  - **S3/P3**: key attestation BUILT 6 Nov, log mode (6a87482:
    key_attest.js, request-playback v43, migration 074, app key v2 in
    1.64.80, sent only by a build that asks for sealed copies). Next: R8 (real chains), then P3b (the stream token
    wrapped for the attested key, so a plain grant needs the phone too),
    then `require` for premium. The owner is told in Telegram when one
    install/account/network pulls far more than a person (migration 075,
    ingest v50, refuses nothing). A lower cap waits for that data: today
    it would be a guess (4 titles; busiest install 2 titles a day). Bytes
    per account need a Worker counter and a Cloudflare token to read it.
  - **S4/P4**: BUILT 6 Nov (docs/console, console_origins.js live in studio
    v51, ingest v52, transcode v27, probe-media v26; the stream Worker's
    origin on the branch; console_build_test.mjs 20 checks). ON MAIN 6 Nov
    (b6fc0d0: docs/console and the stream Worker's origin; docs only, no
    build; Playback check 42208213495 passed after). ON 6 Nov: the owner
    did the four steps (Worker `innocent-console` built from the repo,
    workers.dev off; the WAF rules were already limited to `stream.`;
    Supabase redirect URL added; signed in, Dashboard loads; Transport
    check 42211630577 section 9: headers live, no docs/ served). Retire the
    Pages copy after a week of use (from 13 Nov): docs/console/README.md
    "Afterwards".
  - **S5/P5 (owner)**: passkeys on GitHub, Cloudflare, Supabase and Google;
    Telegram 2-step; a fine-grained, expiring `GH_DISPATCH_TOKEN`; a `main`
    ruleset; secret scanning with push protection; Dependabot; CodeQL.
  - **S7/P6**: BUILT 6 Nov — takedown address innocentmail69@gmail.com in
    About, Report on every title (both in 1.64.80), migration 076 live (budget
    5/phone/day, owner told in Telegram by ingest v51). Left: a Reports page
    in the console; the owner keeps a rights record per title. Hiding the
    host from abuse reports is NOT a goal (§0).
  - **S8-S10/P7**: S8 closed 6 Nov (transport check section 8: `/rest/v1/`
    answers the publishable key 401; run 42177384203). S10 accepted with its
    reason (review P7). Owner: Data API → turn off auto-expose of new
    tables; Files → Scan (R2).
- **Telegram ingest FOLDERS still plain**: the folder segment is what the
  operator typed (`spider-man/video/…`). Making it `f/<20 hex>` like console
  uploads means every place that takes a folder as the key's first segment
  learns the two-segment form and the label table: enqueue_ingest's album
  inheritance and inbox move (033), bot_folder_stats / bot_folders_recent /
  bot_retry_folder / the /folder session match (033), attach_ingest_folder
  (024), review.js's grouping, and the bot's replies (labels, not hashes). One
  migration with a `key_folder(text)` helper used in all of them, and
  ingest.ts translating names both ways. Test with the bot end to end (a
  /folder session, an album with the caption on the third file, /retry).
- ~~**Old payment screenshots**~~: done 31 Oct. ingest v41 seals a receipt
  sent before sealing where it lies on the house tick (sealed copy, then the
  plain one deleted, then the request repointed); the one plain receipt is
  sealed, the bucket holds no plain file (`proof_reseal_test.mjs`).
### Categories and genres by code (TAX, the owner's request of 31 Oct)
- [x] Phase 1, the database (058, live 31 Oct): categories C00-C03, genres
  G001-G003 in their own table, titles carry `category_code` and
  `genre_codes`; the old text follows the codes by trigger, so every app in
  the field works unchanged (checked as anon); `taxonomy()` gives the words
  for every code in three languages; search finds a genre in Burmese and
  Thai. `tool/sql/taxonomy_test.sql` (codes never reused or changed, a
  genre in use not deleted, retire, merge).
- [x] Phase 2, the console (31 Oct): studio v46 (genre ops by code, 059's
  `genre_move` and `genre_usage`), the Genres section (add, rename,
  translate, move, offer, retire, merge, delete an unused one), category
  codes and Thai names, the editor choosing genres as chips. On main
  (`25d0fca`, docs only). Left: the ingest by code (it sends words, which
  the trigger maps). `tool/js/console_smoke.mjs` reached main with
  1.64.80.
- [x] Phase 3, the app (branch `e72b278`, released in 1.64.80):
  `rpc/taxonomy` once for tabs and names, a category asked by its code, genre
  filters by code, names in the phone's language, never a raw code on
  screen. 23 tests; full suite 1235 of 1235. Device lab on the live
  catalogue: run 41186616962 caught the filter sheet drawing "G001 G002
  G003" (it read the names before they had arrived; be7169a: the facets
  carry their names), run 41188669198 passed (names, Animation lists Sintel
  and not Tears of Steel, no code on any screen). Test Lab with the release.
- [ ] Phase 4, once no app that reads the old text is left: drop
  `titles.category` and `titles.genres` (and `categories.id` as the key).

### Media encryption (ENC, the owner's request of 31 Oct; spec docs/MEDIA_ENCRYPTION.md)

#### ENC checks with a date — LOOK AGAIN ON THE DAY (recorded 5 Nov)
Things that are live and believed right, but whose proof comes later. Each
says when, exactly what to run, and what counts as right. Tick it with the
evidence; if it is wrong, it becomes an open item below.

- [ ] **R1 — 12 Nov, after 12:43 UTC: the bin deletes the twelve replaced
  twins of Big Buck Bunny** (2 rungs, 10 stills, binned by run 42029250311).
  `select key, purged_at, purge_error from r2_trash where reason like
  'sealed copy replaced%'` → every row purged, no error. Then BBB still has
  exactly one key row per rung and per still (`media_keys` plain_key
  `video/open-film-big-buck-bunny/master-%p.mp4` → 2; `media_image_keys`
  plain_key `…/thumb/master-f0%.jpg` → 10), and the next sealed lab run
  on BBB still says "3 of 3 copies sealed".
- [ ] **R2 — after the owner's next Files → Scan: folder `s`.** Every
  `s/` object shows "sealed copy" with its title, except O14's orphan
  (the only one unused). Bin that one. `select count(*) from r2_inventory
  i where key like 's/%' and not exists (select 1 from r2_refs() r where
  r.key = i.key)` → 1 before, 0 after.
- [ ] **R3 — daily until 12 Nov: the pipelines' function logs.** No
  "seal refused", "settle failed", "MEDIA_KEK unreadable", and no 5xx from
  `transcode`, `ingest`, `studio`, `probe-media` or `backfill-dimensions`
  (`function_logs` / `function_edge_logs`). Live versions (5 Nov): transcode
  v25 (209f5e1), ingest v48 (1058fd5), studio v49 (6ecba09), probe-media v24
  and backfill-dimensions v27 (ac29482); migrations through 073.
- [ ] **R4 — at the start of every session: the switch is `off`.**
  `select seal_new from admin_settings` → `off`, unless a canary is running
  that session. A switch left on hands open films to the branch runner
  only.
- [ ] **R5 — after every migration that touches r2_refs, a claim, or a
  key table:** tool/sql/media_keys_test.sql, video_frames_test.sql and
  storage_test.sql, each in its rolled-back transaction on the live
  database, end on their PASSED message.
- [ ] **R6 — when ENC-4 reaches main:** every claim arrives with
  `seals: 1` / `can: [..., "seal"]` (O17), and the device lab and Test Lab
  settings are put back (O12).

#### ENC open items — NOT CERTAIN OR NOT FINISHED (recorded 5 Nov; keep until each is closed)
Each: what is known, why it is open, the next step, and when it is done.
Nothing here may be dropped silently: close it with its evidence, or move it.

- [ ] **O1 Proxy CPU per MB (§8 gate NOT met).** proxy_cpu_bench
  BENCH_MEDIA_SEAL=1: 75 ms/MB against 66-69 for the sealed cache alone
  (+7-10, desktop). The codec is 0.25 ms/MB of it, a plain loopback relay
  3-6 — most is the gateway→proxy loopback HTTP hop. Phones: main thread
  realme 7 % (plain 12), OPPO 11 % (plain 4) — lines differed. Next: a
  like-for-like phone run (O2); if the main thread is higher there, route
  the gateway into the proxy in-process (no loopback hop). Done: bench and
  phone within the plain figures, or the owner accepts the cost.
- [ ] **O2 Frozen time not shown like-for-like (§8 gate open).** OPPO sealed
  froze longer (seek 2.4 s vs 0.7, back to Auto 7.1 vs 1.1, far jump 2.0 vs
  0.8) on a line a third as fast; the realme froze less everywhere; device
  lab seek/far jump about +0.5-1 s over plain runs. Next: plain and sealed
  lab builds back to back on the same phone in the same hour (2 Test Lab
  runs each phone), and the same in the device lab. Done: sealed not longer
  than plain on the same line.
- [ ] **O3 Worker answers slow for sealed twins.** 400-850 ms even on a
  reused connection (run 41988997290), plain 250-900. Thought: R2 keeps the
  much-read plain copies hot, the new twins are cold. Not proven. Next: a
  probe from one runner timing plain and sealed objects of the same film,
  ten each, cold and repeated. Done: the cause named, with numbers.
- [ ] **O4 Many new connections.** 31 Worker answers on new connections in
  one lab session after the pool fix (each cut connection is gone). Next:
  count fetches against new connections in the trail; consider keeping a
  part nearly done instead of cutting (as the proxy's finish-below does).
  Done: new connections only where a cut made them unavoidable.
- [ ] **O5 Album photos not seen opening on a device.** The lab flow
  sealed_images reached the hub and Sintel's page (posters opened, none
  refused) but not the album cell ("1 of N" not found by its scroll). Next:
  loosen the flow (scroll, regex), and log every photo open in lab builds.
  Done: a photo and its next one opened in the viewer, in the trail.
- [ ] **O6 Downloads not measured sealed (§8 gate open).** Sealed downloads
  pass the unit tests only. Next: the downloads flow in the device lab on a
  sealed build, speed and CPU against a plain run. Done: not slower, not
  heavier.
- [ ] **O7 32-bit phone not tried (§8 gate open).** "opens ≥ 20× its
  bitrate" never run. Next: DEVICES32 in Test Lab with MEDIA_SEAL=1. Done:
  a 32-bit phone plays the sealed film.
- [ ] **O8 Corrupt segment only tested off-device (§8).** Next: a lab
  switch that flips a byte in the gateway's input once. Done: refetched once,
  then a clear error, no crash, on a device.
- [x] **O9 Seek-bar preview pictures — not R2 objects (corrected 5 Nov).**
  The phone takes them from the smallest rung through the gateway
  (media_kit_player_service ladderPreview); the lab's preview-far, -again
  and -next passed on every sealed run (e.g. 42013700193). What the
  pipelines DO make as images — the cover picker's ten stills
  (tool/frames.py) and thumbnails — are in ENC-4 §7.3.
- [ ] **O10 Image keys are in the database in the clear (decided, recorded).**
  A poster's or photo's DEK is in media_image_keys (no app role reads it),
  so a database dump together with the bucket opens the images; a film
  needs MEDIA_KEK as well. Accepted for images in the spec (§5). Revisit
  only if the owner wants images to need the KEK too.
- [ ] **O11 Lessons to turn into checks.** (a) A migration touching a view
  must be dry-run AS anon and AS authenticated (063's six minutes). (b)
  tool/check.py before every push (238d7a4 went out with ingest_test red).
  Next: a tool that runs a migration in a rolled-back transaction under
  each app role and compares the catalogue reads. Done: in tool/check.py or
  the runbook.
- [ ] **O12 Lab settings to put back.** test_device/config.env and
  cloud.env carry MEDIA_SEAL=1 and FLOWS="sealed_images jumps", and
  config.env JUMPS_TITLE=Big Buck Bunny (5 Nov, the pipeline's sealed
  rungs); main must never carry them. Put back when the seal labs end.
- [ ] **O13 Plain copies of the canary stay in R2** until ENC-5 removes
  them after the forced update; until then a plain URL still opens them.
- [ ] **O14 One orphan sealed still from the first canary (5 Nov).** Run
  42025083706's tenth still (`s/715c6125…`, Big Buck Bunny f00) was
  uploaded, then refused (409: the still already had a twin), before 069
  replaced stale twins and binned refusals. No row names it, so the next
  Files → Scan lists it in folder `s` as unused. Next: after the scan, bin
  it from the Files page (the only `s/` object with no key row). Done: in
  the bin, then purged.
- [ ] **O15 Pipelines settle twins; the twin job and the console do not
  yet.** 069/070 keep transcode's rungs and stills in step with their
  twins. A plain object rewritten by anything else (the console's upload
  into an existing key, a file manager move, a restore from Telegram)
  leaves its twin stale or misnamed. Next: §7.4 steps 3-5 call
  media_key_put / media_keys_settle, and the move rewrites `plain_key`.
  Done: every writer named in §7.3 does.
- [ ] **O16 Sealed downloads and replaced twins.** A replaced twin's
  sealed copy is purged after a week. A phone that downloaded the old
  sealed rung keeps its own copy and key, so offline play is unaffected;
  but nothing yet renews such a download's grant. Next: decide with O6
  (sealed downloads) whether an offline copy outlives its key row. Done:
  the rule written in §6 and tested.
- [ ] **O18 Off-site copy of a born-sealed master from Telegram.** The
  off-site job reads R2 when R2 has the file and the Telegram copy when it
  does not. For a master born sealed (`on`) and moved to Telegram, that
  copy is PLAIN, so the off-site bucket would get plain bytes. Next: when
  `on` nears, either seal it on the runner under the master's own key row
  (kept while the Telegram copy is the master's) or copy only from R2.
  Done: no plain byte in the off-site bucket for a sealed master.
- [ ] **O19 Telegram pipeline not yet run for real.** Built and tested
  against a fake Telegram and a rolled-back database (§7.4 step 3); no
  open film comes through Telegram, so the first real run is with the
  switch `on`. Next: before `on`, one forwarded test file with the switch
  at `on` for a minute (born sealed end to end: ingest, attach, play),
  then back to `off`. Done: that file plays sealed on a phone.
- [ ] **O20 Console sealing not yet run live.** Built and tested in
  Chromium against a fake studio and R2 (§7.4 step 4). The console with
  sealing is on main since 1.64.80 (Pages and console.innocentplayer.com),
  so the live canary can run: then,
  with the switch at `canary` for a minute, upload one photo into an open
  film's album from a phone (a twin: plain + sealed, the key row from
  media_upload_keys), check it in media_image_keys and in the app, and put
  the switch back. Also then: a 40 MB file with the switch `on` for a
  minute, killed mid-upload and resumed (sealResume once, only the missing
  parts sent), then deleted. Done: both on the live console, from a phone.
- [ ] **O21 Photos that are not JPEG keep their metadata.** jpeg_clean.js
  cleans JPEG (what phones send by default) and refuses a JPEG it cannot
  walk; PNG, WebP and HEIC go as they are, with a warning in the upload
  row. HEIC can carry GPS. Next: decide — convert HEIC/WebP to JPEG in the
  browser (re-encode), or strip their metadata blocks, or refuse them.
  Done: no photo format reaches the public bucket with a location.
- [ ] **O22 Sealing speed on a phone not measured.** WebCrypto seals each
  16 MiB part as 256 AES-GCM segments; on a desktop this is far faster
  than any uplink. Next: time a 500 MB sealed upload from the operator's
  phone against a plain one. Done: sealing adds under 10 % to the upload,
  or the part is sealed in a Worker thread.
- [ ] **O23 Pending upload keys and abandoned sealed objects.** A sealed
  single-PUT object whose `sealCommit` never came (the tab died after the
  PUT, before the commit) is in R2 with no key row; its pending key stays
  in media_upload_keys for eight days, then goes. The Files page lists the
  object as unused after a scan. Next: the bin's housekeeping bins `s/`
  objects named by an expired pending key. Done: none left after a week.
- [ ] **O24 The console's sealed preview not seen live.** Built and
  tested in Chromium against stand-ins (§7.4 step 8). Live it needs: the
  console from main (there since 1.64.80), and the streaming Worker answering the
  console's origin with CORS for ranges (it does today, for the speed test:
  `STUDIO_ORIGINS`, Content-Range exposed). Next: with a sealed film and a
  sealed photo in a draft (O20's canary), preview each from Review and from
  Files on the operator's phone. Done: both shown, nothing plain fetched.
- [ ] **O25 A module Service Worker on older browsers.** The console's
  sealed film preview needs a module Service Worker (Chromium 91+,
  Safari 15+, Firefox recent). A browser without one says so instead of
  playing. Next: note the browser the operator uses; if it lacks module
  workers, bundle the format into a classic worker. Done: the operator's
  browser plays a sealed preview.
- [ ] **O17 Old runners and the seals flag.** Main's runner (no sealing
  code) now gets only plain work (070). When ENC-4 reaches main, every
  runner sends `seals: 1`. Next: after that release, confirm from the
  function log that no claim arrives without it. Done: one week of claims
  all with seals.
- [x] ENC-0/1: the spec; seal v1 in Python, JS, Kotlin and Dart, each
  checked against Tink (`tool/media_seal_test.py`) and shared vectors.
- [x] ENC-2: migration 060 (`media_keys`, `devices.public_key`), live;
  request-playback v40 with the seal plan behind `SEAL_MODE` (off);
  `MEDIA_KEK_V1` set by the owner, check value `f3bfb0d1` (RUNBOOK 4d).
- [x] ENC-3, the app (branch, 1 Nov): Keystore device key, keyring, the
  unseal gateway in front of the stream proxy, downloads through it, no
  sealed URL ever played directly; 26 new tests, full suite green, branch
  build 41276775374 green. Behind `kAsksForSealed` (MEDIA_SEAL=1 for labs).
- [x] ENC-3 images (5 Nov): migrations 063-066 (media_image_keys; a
  poster's key in title_cards and the landing cards, a photo's beside its
  address in title_media; the helpers in a `private` schema no URL reaches),
  SealKeyring.openWhole, SealedFileImage, the poster cache and photo
  downloads keep sealed images whole, a build that asks reads title_cards.
  Twins of all 52 images of the four open films (run 42008144845, ingest
  v45). 063 first left title_media refusing the app roles for six minutes
  (a view checks a function's EXECUTE as its reader); no app request came
  in that window; 065 fixed it and every catalogue read was checked as
  anon and authenticated.
- [ ] ENC-3, left: proxy CPU per MB is +7-10 ms/MB on the bench (the
  loopback hop, §8); real phones decide whether the in-process route is
  needed. Seek-bar preview pictures are not sealed yet (ENC-4).
- [x] request-playback v41: `SEAL_MODE` ask/on/off, `ask` by default; the
  seal block carries the header (migration 061). Transport check 41278679967
  green; KEK check value `f3bfb0d1` again on fresh instances.
- [x] Canary copies (ENC-5 B, 1 Nov): ingest v44 seal_plan / seal_commit /
  sweep, tool/seal_twins.py, seed-open-films task `seal`. Nine twins
  recorded (run 41292286979). The first run (41286865663) found 060 had
  granted service_role nothing on media_keys - request-playback could not
  have read a key either; 062 grants SELECT and INSERT only.
- [ ] Canary in the labs: device lab jumps on a MEDIA_SEAL=1 build (run
  41293034978): sealed path throughout (5 of 5 copies, key held, gateway),
  15/16. The failure, skip+30 frozen 5.3 s: the jump joined a segment far
  down the cancelled read-ahead's fetch and waited 3.9 s for it; the
  gateway now joins only a segment about to arrive (§6). Run 41984466643:
  16/16, skip+30 frozen 1.0 s — but jumps answered in 0.55-2.2 s against
  0.25-0.9 s plain: no connection to the Worker was ever used twice (a
  finished fetch destroyed its socket, and each object had its own pool).
  Fixed (one pool, a finished fetch gives its connection back): run
  41988997290 16/16, skip+30 0.4 s, answers 0.34-1.4 s; run 42008905621
  16/16. Test Lab 42008905511 (sealed, both phones): realme 16/16, OPPO
  15/15 — real-phone gate passed; the OPPO froze longer on a slower line
  (§8), and its 7.1 s showed the gateway reading on after the proxy let go:
  it now cuts at once. Run 42013700193 (the cut, and flow sealed_images):
  jumps 16/16 for the fourth run running; the hub's and Sintel's posters
  opened as sealed images, none refused. The flow did not reach the album
  cell ("1 of N" not found by its scroll) — loosen it at the next run.
  Still to do: frozen time on a like-for-like line (plain and sealed builds
  back to back on one phone).
- [ ] ENC-4, the pipelines: ingest, console upload, transcode, probe,
  console preview (in progress 5 Nov; see the spec §7).
- [ ] ENC-5, rollout: canary on Sintel and Tears of Steel, `min_supported`,
  the migration job (skips the do-not-touch list), B2 Object Lock after.
### Quality
- ~~Two sealed stream-cache timing tests fail under the full parallel run.~~
  Done 31 Oct: the trickle bound is half the film, and the step-back case
  found a real fault — a flush into a reset connection could hold a
  stretch open for seconds after a seek; it now ends at the hang-up.
- `tool/js/console_smoke.mjs` failed twice on 1 Nov ("upload: the resume
  sent only what was missing (1,2,3)", then "(1,1,2,3)" — part 1 sent twice)
  with the console untouched; reruns pass. A timing assumption in the resume
  check, or a real double send of the first part after a resume — find it
  rather than rerun.
- Burmese Settings still shows Pop-up Play, Decoder, Development and
  Diagnostics in English — decide whether those stay technical terms.

---

## A. WAITING ON YOU — no code needed

| | why it is first |
|---|---|
| **Run migrations 001-011** | Eleven migrations and three edge functions have been written and NONE has been run. Everything below is built on assumptions until they are. `docs/RUNBOOK.md` |
| **Upload five titles** | The catalogue holds one test row. Five real ones exercise the whole pipeline and will find things no audit can |
| **Shrink the posters** | 3.31 MB each. A free viewer downloads every LOCKED photo in full just to see a blur of it. ~500 px wide JPEG gets it to ~80 KB |
| **Decide minSdk** | `minSdk = 24` promises Android 7, `abiFilters` ships arm64 only. 32-bit devices get "app not compatible" with no explanation. Either raise minSdk to 26/28 or add armeabi-v7a. **The current state is an inconsistent promise** |
| **Test on a cheap phone** | Every test so far has been on an S23 Ultra with 11 GB of RAM. Myanmar users are on 3-4 GB, Android 11-13. media_kit/mpv is memory-hungry and has never met such a device |

---

## B. READY TO BUILD, WITH A TRIGGER

### B1. Crash reporting  — trigger: **someone other than you installs the APK**
`crash_diagnostics.dart` catches everything and stores it on the device. Nothing
is ever sent. A user whose app crashes on launch uninstalls it and you never
learn why. Every serious app knows its crash-free rate; you do not know whether
yours is 1% or 30%.

Not now: there is one install, and it is yours. Reporting to yourself what you
already saw adds a migration, an RLS policy, a privacy setting and three
locales - and the uploader would run **inside the crash handler**, which is the
most dangerous place in the app to add code.

### B2. Event log — trigger: **real viewers**
Algorithms can be written later; events cannot be recreated later. The design is
already corrected for the 500 MB free-tier cap: session summaries, not raw
impressions, plus daily rollups. `docs/movies_data_model_v2.md` §3.

Not now: zero users means zero data is being lost. **I overstated this as
urgent - it is not.**

### B3. Admin panel — trigger: **the SQL workflow becomes tedious in practice**
Edge function serving HTML, so the service key never reaches the browser.
Passcode in a secret, HMAC session token, per-IP rate limit, audit log.
Would replace most of RUNBOOK Part 3 with taps, and could mint presigned PUT
URLs so uploads bypass the R2 dashboard's 300 MB cap.

### B4. Reels masonry — trigger: **`backfill-dimensions` has run over real clips**
Pinterest-style masonry computes tile height as `columnWidth / ratio`. With no
ratios every tile falls back to one default, which IS the uniform grid it was
meant to replace. `docs/album_mosaic_plan.md` §8-11.

### B5. Slug-derived metadata — trigger: **typing metadata gets annoying**
`spider-man-2026` already contains the title and the year. Deriving them costs
one SQL function, no API, no terms, no six-month cache limit, no dependency -
and works for content TMDB has never heard of.

---

## C. DELIBERATELY NOT DOING

### C1. Splitting the 3,900-line screens
`downloader_home_screen.dart` (3,925) and `player_screen.dart` (3,617). Both
have zero tests, and nothing here can compile Dart - the checkers do not see
types. **This is the riskiest work available**, for a change no user can see.

Do it in pieces, when a feature lands in one of those files anyway.

### C2. The other 211 silent catches
326 `catch (_)` in total; 115 carry an explanation and many are correct
("clipboard access can be denied; the paste bar still works"). Editing 211 sites
blind is more likely to break something than to reveal anything.

Do it one path at a time, when a user reports that path failing.

### C3. Dependency upgrades
`go_router ^14`, `device_info_plus ^10`, `share_plus ^10`, `permission_handler
^11`, `flutter_lints ^4` are each a major behind. Upgrading blind, in a build
that cannot be compiled locally, is the same risk that ruled out
`cached_network_image`. One at a time, when something specific is needed.

### C4. TMDB metadata
Would remove poster uploads and most typing. Costs: attribution in-app, a
six-month cache limit that conflicts with storing synopses permanently, and a
dependency whose terms include a sole-discretion content clause. And it only
helps for titles TMDB catalogues - not local, original or adult content.
Decide only when you know what the catalogue actually holds. `docs/album_mosaic_plan.md`

---

## D. TRANSFER — audited 2 Sep 2026 against the published research

Checked each known failure in this app class against Innocent.

| known issue | Innocent |
|---|---|
| Path traversal on the receiver | ✅ **Tested, not guessed.** 67 hostile inputs (`../`, `....//`, absolute, UNC, NUL, unicode) run through ports of `sanitizeRelDir` and `_safeName` against a real filesystem. **0 escapes** |
| Improperly exported components (Trend Micro, SHAREit RCE 2021) | ✅ `FileProvider` is `exported="false"` with `grantUriPermissions`. Every exported component is justified; the iADB service is gated behind `INTERACT_ACROSS_USERS_FULL` |
| Upload filename injection | ✅ Separators and control characters stripped; the `.`/`..` survivor found by a 30,000-case fuzz is handled |
| **PIN enumeration (CVE-2018-19429, Xender)** | 🔴 **WAS present - fixed in v1.64.4.** Per-IP lockout after 5 failures with doubling backoff, plus a constant-time compare |
| **Cleartext HTTP (CVE-2018-19430/19431)** | ⚠️ **Present, and inherent.** Files and the token cross the LAN in plain HTTP. Every app in this category shares it, because browser-based receive cannot use a self-signed certificate without a full-page warning |

### The cleartext limitation, stated honestly

An attacker on the same Wi-Fi can sniff a transfer and read the token. There is
no cheap fix: HTTPS on a LAN means either a self-signed certificate (a browser
warning that trains users to click through security warnings) or a real
certificate for an IP address (not issuable).

What actually reduces it, in order:
1. **Turn the PIN on** - now that guessing is throttled, it is a real control;
2. **Turn approval on** - it is off by default, matching Zapya/SHAREit, but on
   an untrusted network it is the difference between "anyone nearby may pair"
   and "I tapped Accept";
3. Prefer Turbo (Wi-Fi Direct) over a shared access point on public networks.

**A defensible next step:** make approval default to ON when the phone is on a
network it has not seen before. Not built - it needs a "known network" store,
and the current default is a deliberate speed choice.

---

## E. FILE PICKER — audited 2 Sep 2026

Read end to end, then the risky paths tested rather than reasoned about.

| checked | result |
|---|---|
| Symlink escape / loops | ✅ `dir.list(followLinks: false)` |
| Jank on large folders | ✅ every file `stat()`ed once, in parallel batches of 48. An earlier version called `statSync()` inside the sort comparator AND again per row |
| Unbounded caches | ✅ directory cache capped at 24 entries |
| Cancel vs failure | ✅ distinguished, with the reasoning recorded: reporting a cancel as a failure pushes someone toward deleting an original they still need |
| `Android/data` handling | ✅ routed through ADB, with a connect hint when unavailable |
| **Disk full mid-import** | 🔴 **WAS present - fixed in v1.64.5** |

**The gap.** Vaulting COPIES into app-internal storage. Selecting 20 GB with
5 GB free started anyway, copied until the disk filled, then failed every
remaining file one at a time - leaving a half-vaulted set on a full device.
Worse than an ordinary error, because someone who believes a file is hidden may
delete the original.

The Transfer receiver has refused up front since a Wi-Fi batch once filled a
disk on its last file. The vault had the identical exposure and no guard.
v1.64.5 applies the same control - same native channel, same 64 MB headroom,
same "proceed when the platform will not say".

`freeSpaceBytes()` is new on `PrivateFolderService` rather than borrowed: the
vault writes to app-internal storage and the receiver to public external.
Usually the same volume, not required to be, and a check against the wrong
volume is worse than none.

### Still open here

* **No upfront estimate.** Selecting 300 files shows a progress sheet but never
  says "this will take about twenty minutes". Cancel exists, so this is a
  comfort issue rather than a correctness one.
* **`rawFiles.skip(i).take(batch)`** is O(n²/batch) because `skip` on a List
  walks from the start each time. At 10,000 files that is roughly a million
  extra element traversals - a few milliseconds, measurable but not felt.
  `sublist` would fix it. Left alone: the file is 2,257 lines with no tests,
  and a few milliseconds does not justify touching it.

---

## HOW THIS LIST WAS ORDERED

Everything in section A costs no code and tells you something no audit can.
Everything in B is written or specified but waits on a condition. Everything in
C would cost more than it returns today.

The recurring mistake in this project has been building ahead of evidence -
`title_assets` before there were assets, masonry before there were clips, an
event log before there were users. Each item above carries the trigger that
makes it worth doing, so the next session starts from a condition rather than
from enthusiasm.
