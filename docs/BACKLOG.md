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

### Release 1.64.78 (in flight)
- **Test Lab, both phones** (realme RE58C2/35, OPPO OP573DL1/34) — scheduled
  07:12 UTC 30 Oct. Compare Play-to-picture and CPU with runs 40890052023 and
  40883836265. Then release via the main worktree: lib commits d15d478,
  63aeea2, d63727c, cc57e1a, 0e49166 and the version bump only (never the
  lab-only lib/app.dart). The release also carries docs/studio/app.js (opaque
  upload folders) to GitHub Pages. 1.64.77 was built and never published.
- **Gap audit entries** for 1.64.78 (docs/gap_audit_2026_10.md).

### Verify what is live but not yet exercised
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

### Security, next
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
- **Old payment screenshots**: reseal the receipts filed before 30 Oct like
  the backups (premium-request has the key; storage download, seal, upload
  `.sealed`, update proof_path, remove the image).

### Quality
- Two sealed stream-cache timing tests fail under the full parallel run and
  pass alone (903 ms against a 900 ms bound; "a step back into what the
  player was given carries the stretch on"). Make them robust to load.
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
