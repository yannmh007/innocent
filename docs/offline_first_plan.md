# Offline first, and the platform work that had to come with it

**Written 2026-09-25. Newest status at the top of each section.**

This is the record of the programme that started with one observation from the
operator and grew into fourteen items. It exists so a session that starts cold
knows what was done, what was decided *against* and why, and what order the rest
goes in — without re-deriving any of it from commit messages.

---

## The observation that set the whole thing off

> In Myanmar most people are on mobile data, the signal is poor, and even a film
> that has finished downloading in Telegram stutters. So what people actually do
> is download first and watch offline.
>
> — and the requirement that followed: **a download must arrive as the original
> R2 object, at full quality. Only streaming adapts to the connection.**

That second sentence is the load-bearing one. It is not a preference; it is the
architecture. Everything below is either serving it or getting out of its way.

### The invariant, stated once

| | quality | chosen by |
|---|---|---|
| **Streaming** | adapts — a rung is picked per connection | the app, at play time |
| **Download** | the ORIGINAL object, always | nothing; there is no choice to make |

`offline_downloader.dart` fetches `grant.url`, which is a presign of
`titles.objectKey` — the master. The `renditions` table is a separate,
streaming-only concern and the downloader must never learn about it.

**This is enforced, not documented.** `tool/security_invariants.py` rule 7 fails
the build if `offline_downloader.dart` so much as mentions `renditions`, or stops
reading `grant.url`. A future session optimising "download size" would otherwise
quietly hand people the 480p rung, and nobody would notice until a viewer
complained about a film they had already paid data for.

---

## Where things stand

| | | |
|---|---|---|
| **A1** | Unfinished downloads resume by themselves | **done** — 1.64.28+341 |
| **A2** | Know whether the connection is metered | **done** — 1.64.28+341 |
| **B1** | A new category must not need an app release | **done** — 1.64.29+342 |
| **B2** | Wire `trending_titles()` into `landing_rows()` | **done** — 1.64.29+342 |
| **C1** | Upload above 5 GiB | **done** — 1.64.30+343 |
| **D1** | Email / phone sign-in | **skipped by the operator**, 2026-09-25 |
| **E1** | Downloads encrypted at rest | open — next |
| **F1** | Telegram → R2 pipeline | open |
| **G1** | Watch a download while it is still downloading | open |
| **G2** | True background download | open — **needs a real device** |
| **#31** | Serve video from the Cloudflare edge, not the S3 API | open, older |
| **#32** | Find which videos still have their index at the end | open, older |

Released along the way: 1.64.25+338, 1.64.26+339, 1.64.27+340. 1.64.28 through
1.64.30 are on `claude/extract-github-release-oteqr5` and not yet merged.

---

## A — the download has to survive a Myanmar connection

### A1. Unfinished downloads resume by themselves

The old behaviour was that a download which died — a tunnel, a tower handover, a
cleared task — stayed dead until somebody opened the app and pressed the button
again. On the connection this app is for, that is most downloads.

What it does now:

- **One transfer at a time**, through a `Future` chain rather than a lock, so a
  second tap queues instead of racing.
- **Resume from the byte count on disk**, verified against a `.part.total`
  sidecar. `planResume` decides between continuing, restarting and refusing; a
  file longer than the server says it should be is a restart, not a continue.
- **500 attempts**, with a 2/4/8/16/32/60-second backoff, and a separate count of
  *consecutive* failures (40) so a long download does not exhaust its budget on a
  bad afternoon.
- **A real-progress threshold of 256 KiB.** An attempt that moves fewer bytes
  than that is not progress, and must not reset the failure count.
- **Space is checked from the response headers**, not guessed, with a 256 MB
  headroom. A `freeBytes()` that cannot be read comes back negative and is
  refused — the one case where "I don't know" must not mean "probably fine".
- **Auto-resume on reconnect** (`offline_auto_resume.dart`), which reads the shelf
  *before* probing the network, skips anything the user paused by hand, and will
  not run more often than every two minutes.
- **A foreground service** with a wake lock refreshed on every progress update, a
  pause action in the notification, and a three-minute idle watchdog.

**The thing that is easy to get wrong here, recorded so nobody re-learns it:** a
foreground service keeps the Android *process* alive but **not the Flutter
engine**. The engine belongs to the Activity, so a destroyed Activity ends a
Dart-driven download whatever the service is doing. That is why there is an idle
watchdog instead of a comment claiming the download survives. Doing it properly
is G2, and G2 cannot be verified from a container.

### A2. Know whether the connection is metered

"Wi-Fi only" was the setting people asked for, and asking "is this Wi-Fi" is the
wrong question. A tethered phone and a paid hotspot are both Wi-Fi and both cost
by the megabyte. Android answers the right question directly —
`NET_CAPABILITY_NOT_METERED` — so `NetInfo.kt` reports both the transport and
whether it is metered, and an unreadable state is reported as metered. Refusing a
download on a connection we could not classify is recoverable; starting one is
somebody's money.

The allowance is asked **before every attempt**, not once at the start, because a
download that began on the office Wi-Fi is still running when its owner walks out
of the door.

---

## B — the operator must not need a release to run the catalogue

### B1. A new category must not need an app release

Three obstacles, in three places. Migration 015 gave categories a table and said
plainly what it did *not* buy. Migration 020 removed the database's two — a CHECK
constraint on `titles.category`, replaced with a foreign key to
`public.categories` — and B1 removed the client's: the assumption that the
compiled enum is **exhaustive**.

The enum stays, because it still earns its place (`all` shows curated rows rather
than a grid, `series` and `reels` have glyphs, every built-in has a compiled label
so the bar draws with no network). What went is the idea that it is the whole
list. `CategoryRef` carries the string id that `titles.category` has always
stored, plus the compiled category when this build happens to know one.

Two failure modes are handled because both are reachable the moment an operator
touches the table: an unknown id resolves to a server-only ref rather than falling
back to `all` (falling back is what made a new category *invisible*, and would now
reinterpret a link into a new section as the front page), and a category can stop
existing **while it is selected**.

The console can add one now, with a strictly validated id and an unvalidated
label — the id is the one thing that cannot be fixed later, because every film in
the section stores it.

### B2. Wire `trending_titles()` into `landing_rows()`

`trending_titles()` had been built, tested and called by nothing. A straight
switch would have been **wrong on this catalogue**: 32 plays across 2 of 5
published titles means a trending row of two films and a front page that shrinks.

So it is a hybrid that improves itself: real ranking where there is enough signal,
curated order underneath it. Verified that anon can read the rank and still cannot
read `public.events`.

---

## C1. Upload above 5 GiB

S3 caps a single PUT at 5 GiB, and the console only ever did single PUTs. But the
cap is the smaller half of the problem: a 3 GiB upload on a Myanmar uplink is
hours of somebody's life, and a dropped connection at 92% spent all of it for
nothing, because a PUT has no parts to resume.

Now: anything over **128 MiB** goes up in **64 MiB parts**, four attempts each
with a doubling wait. A blip costs one part. The ceiling becomes S3's 10,000
parts — 640 GB.

**Sequential, not parallel**, deliberately: three parts at once divides one slow
uplink three ways, finishes none of them sooner, and makes the progress bar lie.

**Three ops in the edge function, not one**, because the bytes must not pass
through it: `CreateMultipartUpload` answers with XML and `CompleteMultipartUpload`
has to *send* XML, and a browser should not compose S3 XML. So begin, complete and
abort are signed with an `Authorization` header from the function, and only the
parts are presigned. That needed a second signer — a real payload hash instead of
`UNSIGNED-PAYLOAD`, appearing both as `x-amz-content-sha256` and inside the
canonical request.

Part URLs are signed in **batches of eight as the upload goes**. A presigned URL
lives an hour; 64 parts on this connection can span three, so signing them up
front hands the operator a set that expires underneath them, with the failure
landing at part forty for no visible reason.

### ⚠ ONE THING MUST BE DONE IN THE CLOUDFLARE DASHBOARD

The media bucket's CORS rule has to list **`ETag` in `ExposeHeaders`**. A browser
cannot read a cross-origin response header that is not exposed, and without the
ETag there is no way to complete a multipart upload at all. The page reports
exactly that cause by name rather than "upload failed", because the parts will
have gone up perfectly and the only thing wrong will be one line of bucket
policy.

### Why there is a 55-check test for this

None of it can be tried against the real bucket from a checkout — the credentials
live in Supabase's secret store and R2 is not reachable from CI — and **every** way
of getting SigV4 wrong fails identically: HTTP 403 `SignatureDoesNotMatch`, with a
body that names no parameter, no header and no reason.

`tool/js/sigv4_test.mjs` therefore pulls the real functions out of
`docs/edge/studio.ts` (never copies them) and checks them against an independent
signer written on node's crypto, which is itself verified against AWS's published
worked example — canonical hash `7344ae5b…`, signature `f0e8bdb8…`. Seven
mutations of the real source were tried against the suite and all seven were
caught.

The specific things it pins, each of which is silent when wrong:

- `partNumber` and `uploadId` go **through** the signer. SigV4 covers the
  canonical query string, so a parameter appended to a finished URL is refused.
- Parts are sorted ascending before the complete call, whatever order they
  arrived in.
- The ETag is normalised to exactly one quoting — bare or doubly quoted is an
  `InvalidPart` on a finished transfer.
- A part list with a missing ETag is **refused, not filtered**. Filtering would
  complete the upload without those bytes: a shorter file that plays until it
  stops.
- The signed URL's part number is checked against the chunk about to be sent. A
  batch offset by one writes each chunk at the wrong index, R2 accepts every
  part, and the result is a file of exactly the right length with its minutes
  shuffled — discovered by a viewer.
- `CompleteMultipartUpload` **can answer 200 and still have failed**: it streams,
  so an error after the headers arrives as an `<Error>` document inside the 200.
- An abandoned upload is aborted, or its parts sit in the bucket invisible to
  every listing and billed by the gigabyte-month.
- The object key for complete and abort comes from the page, and a key from a page
  is a path: checked against the three prefixes the function mints, with `..`
  refused outright rather than normalised.

---

## D1. Email / phone sign-in — SKIPPED

> "D1 ကို လောလောဆယ် ကျော်ထားပါ မလုပ်နဲ့ ကျန်တာအကုန်လုပ်မယ်။"
> — the operator, 2026-09-25

Not deferred for a technical reason and not to be revived without being asked.

---

## The rest, in the order to do it

### E1. Downloads encrypted at rest — next

Decision already taken: **B1(a)** — encrypt the file, keep the key in the Android
Keystore. The Private Folder feature already has the Keystore primitive, so the
work is not the crypto. The work is **a decrypting data source in the player**:
libmpv has to read a stream it cannot `open()` directly, which means either a
local loopback that decrypts on the fly or a media_kit custom protocol. Decide
that first; everything else follows from it.

Why it matters here specifically: a downloaded premium film is currently a plain
MP4 in app storage. On a rooted phone, or through any file manager with the right
permission, it is a file somebody can copy and pass around — which is the
operator's entire catalogue leaving by the front door.

### F1. Telegram → R2 pipeline

The operator's masters largely arrive over Telegram today, and the current path is
download-to-phone-then-upload-from-phone: the file crosses the mobile connection
twice. A server-side pull would make it zero.

### G1. Watch a download while it is still downloading

Telegram does this and people expect it. The likely shape is serving the `.part`
file through the loopback cache proxy that already exists, with the player told
the duration up front. **Investigate before promising it**: a seek past the
downloaded head has to fail gracefully rather than look like the stutter this
whole project exists to remove.

### G2. True background download — needs a real device

A headless isolate plus WorkManager, so a download survives the Activity being
destroyed (see the note under A1 for why the foreground service is not enough).

**This cannot be verified from a container, and must not be shipped on the
strength of reading the documentation.** It needs a phone, swipe-killed, with the
screen off, on mobile data, for twenty minutes.

### #31. Serve video from the Cloudflare edge instead of the S3 API

Playback currently presigns the S3 API endpoint. The Worker path exists and the
token design is already tested against both halves
(`tool/js/stream_token_test.mjs`); this is about moving playback onto the edge so
the bytes come from a cache near the viewer.

### #32. Find which videos still have their index at the end

`faststart` reorders on upload, from now on. It says nothing about what was
uploaded before it existed, and a film with its `moov` atom at the tail costs a
second round trip to the end of the file before the first frame — exactly the
delay this programme is about. The box walker already exists
(`tool/js/probe_boxes_test.mjs`); what is missing is the sweep.

---

## Notes for whoever picks this up

- **No Flutter or Dart SDK in the session container.** `python3 tool/check.py`
  runs locally — 15 checks, four of them JavaScript, and it says so *loudly* when
  node is missing rather than quietly passing. `flutter analyze` and
  `flutter test` only run in CI, via `workflow_dispatch` on the branch. The
  release job only fires on `main`.
- **Merging to `main` cuts a public GitHub Release** and pushes an update prompt
  to every phone. It is not a quiet operation and is never done without asking.
- **This repository is public.** `docs/edge/*.ts`, `docs/studio/index.html`,
  `tool/transcode.sh` and `.github/workflows/*` are all readable by anyone.
  Every credential lives in Supabase Edge Function secrets, Cloudflare secrets or
  GitHub Actions secrets, and none has ever been written into source. Keep it that
  way.
- **The odd-looking code is usually deliberate.** Split executors, reflection,
  `useLegacyPackaging`, the WebView thread rules, `--demuxer-lavf-probesize`'s
  minimum of 32. Read `git log` and the docs before calling something a weakness,
  and say plainly when unsure.
