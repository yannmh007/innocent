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
| **E1** | Downloads encrypted at rest | **done** — 1.64.31+344 |
| **F1** | Telegram → R2 pipeline | open — **blocked on a decision**, see below |
| **G1** | Watch a download while it is still downloading | **done** — 1.64.32+345 |
| **G2** | True background download | open — **needs a real device** |
| **#31** | Serve video from the Cloudflare edge, not the S3 API | code complete — **needs one look**, see below |
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

## E1. Downloads encrypted at rest

A downloaded film was a plain MP4 in app storage — the operator's master, at full
quality. On a rooted phone, or through any file manager granted the right
permission, that is the whole catalogue leaving by the front door one download at
a time. It is now ciphertext that only this phone can read.

### The four decisions, and why each went the way it did

**AES-CTR, not GCM.** A player seeks: libmpv will ask for the bytes at 01:42:07
without having read anything before them, so the cipher has to be addressable by
byte offset with no state carried from the start of the file. CTR is; GCM is one
authenticated message, and authenticating a four-gigabyte film as one message
means reading all of it before the first frame. That trades away tamper
detection, which is the right trade rather than a compromise: the threat is a
copy of the file being played elsewhere, not an attacker rewriting bytes in a
directory where they could simply delete the film instead. ExoPlayer's own cache
encryption makes the same choice for the same reason.

**A wrapped key, not a Keystore key used directly.** A Keystore key never leaves
the secure hardware, which is what makes it worth having — and it would mean every
block of every film ciphered through a binder call into keymaster. So this is the
envelope Jetpack Security and Tink use: a 256-bit data key does the film, a
Keystore key does nothing but wrap that data key, and the bulk cipher runs on the
platform's AES, which on every ARMv8 phone is the CPU's own AES instruction.

**The trailer is at the END of the file.** Nothing is prepended, so *the byte at
offset N of the film is the byte at offset N of the file*. The downloader appends
as the network delivers, the resume point is the file's own length, and the
player's range requests need no arithmetic. A header at the front would have
shifted all of those by a constant — and a constant that is right in four places
and forgotten in the fifth is a film that plays as noise.

**Fail open on a phone that cannot seal.** If the Keystore will not answer, the
download proceeds unencrypted rather than not at all. A viewer who cannot
download is a worse outcome than a file that is not encrypted, and the realistic
cause is a transient Keystore error rather than a phone without one. Recorded
here so it is not quietly reversed into a hard failure.

### What the player does with it

libmpv cannot open a file it has to decrypt, and decrypting the whole film to a
second file first would want another four gigabytes of a phone that has not got
them — and a minute of staring at nothing. So the decryption wears the shape of a
loopback HTTP server, which is the same answer `StreamCacheServer` reached for the
same reason. A separate server, because the two have nothing in common but the
shape: this one has no upstream, no refresh, no store and no budget.

The address carries a token minted once per process. Loopback is not private on
Android — any app may connect to 127.0.0.1 on any port — so without it the server
would be a decryption service for the whole device, which is the exact thing the
encryption was for.

The player resolves a `sealed://<path>` URI to that address, the same way it
already resolves `adb://`. **The stable identity stays the `sealed://` URI**: the
loopback address carries a port and a token that change every launch, so a resume
point keyed on it would be a new key every time — which is the same as having no
resume point at all, on films two hours long.

### What is deliberately NOT done

- **Existing downloads are not re-encrypted, and never will be.** Every one of
  them is a plain MP4 on somebody's phone; the app does not get to make people
  download their films again. A row written before this feature reads as plain,
  which is correct rather than merely safe.
- **A sealed film's trailer is not verified on every shelf read.** The length is,
  which is what the verification needs; the trailer is read at play time, where a
  missing one becomes "delete this and download it again" rather than noise on
  screen.
- **The 32-byte overhead is not subtracted from the storage figures.** It is
  thirty-two bytes.

### The part nobody should have to rediscover

A film ciphered under one keystream and then, after a restart, under another is
noise with a seam in it. Two things stop that: the IV lives in a sidecar beside
the part file, so a resume continues under the same keystream, and **its presence
is also the answer to "was this download started sealed"** — which a resume must
not guess. A restart onto a replaced object mints a *new* IV, because one
keystream used for two different films hands anybody holding both of them the XOR
of the two plaintexts without needing the key at all.

## G1. Watch a download while it is still downloading

**Done out of order, and deliberately.** The plan had F1 before this, but F1 turned
out to be blocked on a decision only the operator can make (below) — and E1 had
just built the thing G1 needed: a loopback server that serves a local film with
byte ranges. So G1 went from a week to an afternoon, and it is the item on this
list a viewer notices.

Telegram plays a video while it downloads, and that is what this audience is used
to. Waiting for a whole film before it will open is what makes downloading feel
worse than streaming even when it is the better choice.

### What decides whether it can be offered

An MP4 keeps its frames in `mdat` and its index — every frame's offset, size and
timestamp — in `moov`. A demuxer cannot play one frame without the index, so where
`moov` sits decides everything:

| | |
|---|---|
| `ftyp moov mdat` | index at the FRONT — the first megabytes are enough to start |
| `ftyp mdat moov` | index at the END — nothing plays until the last byte |

The console reorders every upload into the first shape, which is what makes this
worth offering at all. But every film uploaded before that existed is in the
second, so **the shape is read out of the bytes rather than assumed**: `moov` has
to come before `mdat`, and the whole of it has to have arrived, plus four
megabytes of frames behind it so the demuxer starts instead of stalling on its
first read.

`assessMp4Head` is a pure function on bytes with 18 tests, because its answer is a
button and both ways of being wrong are silent: `ready` on a film whose index is at
the end opens a black screen with a spinner that never resolves, and `indexAtEnd`
on a film that is fine hides a feature nobody will then find.

### The three things that make it work rather than half-work

**Bytes that have not arrived are WAITED FOR, not refused.** Every demuxer seeks
ahead, and so does anybody dragging a seek bar. Answering short there looks to the
player exactly like a dropped connection, and it would give up on a film that is
arriving perfectly well. The server polls the part file's length every quarter
second, for up to ninety seconds; past that a download has not slowed down, it has
stopped.

**An open handle survives the download finishing.** A rename moves a name and not
an inode, so somebody watching while the last megabytes arrive is not interrupted
by the `.part` file becoming the film.

**A growing sealed film has no trailer yet** — that is written at the end — so its
IV comes from the sidecar and its length from the size note. This is the reason
`SealInfo` is a value the caller can construct rather than something only a
finished file can produce.

### What it deliberately does not do

The address is **ephemeral**: no resume point, no cold-start "Resume X?" marker. A
film watched while it downloads has no stable identity yet — the file is called
`.part` and will be renamed the moment it finishes — so it is watched without one
and gets a real resume point as an ordinary download afterwards. Writing the
loopback address down would leave a key that never matches again, pointing at a
port that no longer exists.

The readiness check runs **on the tap, not in `build`**: it is a read and a decrypt
of the first two megabytes, and a list does not get to do that per frame. So the
button appears on a cheap test — eight megabytes in, and only when the film's
length is known — and the real answer comes when it is pressed. Which means it can
say no, and **every no says which no it is**: "not enough of this has arrived yet"
is worth waiting a minute for, and "only once the download has finished" means
going and doing something else. Telling somebody the second when it is the first
invites them to keep pressing.

## The rest, in the order to do it

### F1. Telegram → R2 pipeline — BLOCKED ON A DECISION, not on work

The operator's masters largely arrive over Telegram, and the current path is
download-to-phone-then-upload-from-phone: the file crosses the worst connection in
the system twice. A pull straight into R2 would make it zero.

**The shape is already proven.** `transcode.yml` runs ffmpeg on a GitHub Actions
runner, claims work from an edge function with a shared secret, and touches nothing
but presigned URLs. An ingest job is the same pipeline with a different program in
the middle.

**What blocks it is Telegram's own limits.** A bot using the cloud Bot API cannot
download a file larger than **20 MB** — not a setting, not a rate limit, the API's
own ceiling — so no bot can fetch a film. The two ways past it are:

1. **An MTProto user session** (Telethon, GramJS, TDLib), which can fetch up to
   2 GB per file, or 4 GB on Premium. The session string would live in a GitHub
   Actions secret.
2. **A self-hosted Local Bot API server**, which lifts the limit for bots — and
   means a machine to run, patch and pay for, which this project deliberately does
   not have.

Option 1 is what everybody actually does, and it needs saying plainly: **a Telegram
user session string is the operator's whole account**, not a scoped key like
`TRANSCODE_SECRET` whose entire power is "ask for a transcode job". Anyone who
reads it can read every chat that account can. That is a different order of
trust from anything else in this repository, and it is the operator's call to
make rather than a detail to be got on with.

So: ask first. If the answer is yes, the work is an `ingest_jobs` table, an
`ingest` edge function with `claim`/`done` ops (multipart, since masters pass
5 GiB), a workflow, and the api_id / api_hash / session secrets. None of it can be
tested from a checkout — there is no Telegram from here — which is one more reason
the decision comes before the code.

### G2. True background download — needs a real device

A headless isolate plus WorkManager, so a download survives the Activity being
destroyed (see the note under A1 for why the foreground service is not enough).

**This cannot be verified from a container, and must not be shipped on the
strength of reading the documentation.** It needs a phone, swipe-killed, with the
screen off, on mobile data, for twenty minutes.

### #31. Serve video from the Cloudflare edge — the code is done, the switch is a secret

This turned out not to be code at all. `request-playback` already does
`const url = viaWorker ?? await presign(objectKey)`, the Worker
(`innocent-stream`) is deployed with its R2 binding, and the token design is
tested against both halves in `tool/js/stream_token_test.mjs`. Playback uses the
edge the moment **`STREAM_BASE`** and **`STREAM_TOKEN_SECRET`** are both set on the
Supabase functions.

**And the fallback is silent, which is the actual problem.** The app plays either
way, at the same quality, so nothing on any screen said which path viewers were
on — in either direction. Weeks on the slower path cost nothing visible; and
somebody who believed the edge was live had no way to find out it was not, which
is the state this item sat in.

So the console now says so. The Start-up panel reports **Edge delivery: on / off /
misconfigured**, from a `delivery` op that returns booleans and never values, and
asks the Worker's own `/health` from the server side — the console does not know
the Worker's address, because that address is the secret, and it should not learn
it from a diagnostic.

It cannot prove the two secrets MATCH. Only the speed test can, because that mints
a real token for a real object and fetches it. "Is it wired up" and "does it work"
are different questions with different fixes, and they are answered by different
buttons.

**What is left is one look**, in this order: press *Check videos* and read the
first line; if it says on, press *Speed test*. Both need `probe-media` redeployed,
since the `delivery` op is new.

### #32. Find which videos still have their index at the end — the finder is done

The sweep existed; it was **lying by omission**. `probe-media` read forty objects
and stopped, and the console then said "3 of 40 videos keep their index at the
end" — a sentence that sounds like a complete answer and was a sample. It sampled
the wrong end, too: newest first, so the films most likely to predate the upload
rewrite were the ones never looked at. An operator could have run the check every
week and never once seen the file that was slow.

It pages now, and the console loops until the function says there is no more, so
the number in that sentence is the real one at any catalogue size. The next page
starts at a **database row count** rather than at the number of results returned:
a row with an empty object key is skipped by the probe and still occupies a place
in the table, so counting results would step backwards over it and probe one
object twice.

**Asked and answered, 2026-09-25.** The media bucket holds six objects and the
sweep covered all of them. **Two have their index at the end**, both legacy `v/`
uploads from before the console started reordering:

| object | | |
|---|---|---|
| `v/20260922-1000189108-ddedfd53.mp4` | 18 MB, 0:54 | Test 001 (free) |
| `v/index-v1-a1.mp4` | 155 MB, 12:45 | First test title (premium) |

Both are test content, so re-uploading them costs nothing anybody minds — which is
also why the remux pipeline below stayed unbuilt. Every upload since is written
index-first by the console.

**What that actually costs, now that the numbers exist.** Both have ladders (4
rungs and 2), and `tool/transcode.sh` writes every rung with `-movflags
+faststart`, so a viewer who receives a rung pays nothing. The extra round trip is
paid only by a viewer good enough to get the original — and, since 1.64.32, by
anyone who wanted to **watch while downloading**, because a download is always the
original and a player cannot start without the index. That second cost did not
exist when this item was written.

⚠ **`probe-media` has to be redeployed for the paging to take effect.** The console
half is backward compatible on purpose: against the old function `more` comes back
undefined, the loop stops after one page, and the panel behaves exactly as it does
today.

### What to do about a `tail` verdict — NOT built, and here is the design

Today the console says "re-upload them", which on a Myanmar connection is a
gigabyte of somebody's data per film. With six objects that is the right answer;
with sixty it is not.

The better answer costs no upload at all: `ffmpeg -c copy -movflags +faststart` is
a pure box reorder — no re-encode, no quality change, minutes rather than hours —
and the transcode runner already has ffmpeg, a presigned GET and a presigned PUT.
It would be a second job type in the pipeline that already exists.

**And it must not overwrite the master.** Write the reordered copy to a NEW key,
verify it by walking its boxes before anything else happens, then repoint
`title_assets.object_key` at it in one statement. Nothing is destroyed, the switch
is atomic, and if it is wrong the operator points the row back. An in-place
overwrite would be the only operation in this system that can silently destroy the
thing it was asked to improve — and this project already has one of those
(`faststart` in the browser) and treats it with the respect it deserves.

---

## The destructive paths, and what stops each one

Read once on 2026-09-25, deliberately and in order of what they can destroy. Two
of them were already right for reasons worth knowing; one was not.

| what it can destroy | what stops it |
|---|---|
| A viewer's downloaded film (`items()` deleting a "truncated" file) | Judged against `fileLengthFor(bytes, sealed)`, never a bare length; `bytes > 0` guards it; it never reads the trailer, so a Keystore failure cannot make it delete anything |
| A viewer's film, on sign-out (`dropEntitled`) | **This one was wrong — see below** |
| A viewer's film, on discard from the UI | `_discard` has always cancelled the download before deleting. That is where the rule came from |
| Everything (`dropAll`) | Exactly what it is for. Called from nowhere but a test |
| The operator's master, by a rung written over it | **Impossible by construction.** `rungKey` appends `-<height>p.mp4` after stripping the extension, so the output always carries one more segment than its input — and the runner is handed a presigned **GET** for the master and **PUT**s only for rung keys, so even a broken runner cannot write to it |
| The operator's master, by a multipart complete onto an existing key | S3 ties an upload id to one key, and the only thing that begins an upload is `beginMultipart`, which always mints a fresh timestamped key. `isMintedKey` refuses anything else on complete and abort |
| The operator's master, by the browser's faststart rewrite | Six checks in `faststart_test.mjs`, untouched by the multipart work — and a file over 128 MiB still goes through the rewrite before it is cut into parts, which is the case where the index position costs most |
| A title's objects, on delete | Deleting a title deletes the ROW and lets the foreign key cascade; the objects stay in the bucket. That is a bill rather than a loss, and it is the safe direction to be wrong in. Confirmed with `confirm: "DELETE"` |

### The one that was wrong: signing out during a download

`dropEntitled` deleted a premium download's part file and did not stop the
downloader writing to it. **Deleting a file does not stop a write to it.** On
POSIX an open handle outlives its name, so the transfer carried on spending the
viewer's mobile data into an inode nothing could reach, and then either failed to
rename or — on the next pass, because `openWrite` recreates a missing file —
started appending to an empty one and "finished" a film that was mostly missing.
The shelf's own verification would then delete that, so the viewer ended with
nothing, having paid for all of it.

The Downloads screen has cancelled before discarding since the day it was
written. `dropEntitled` now takes the same `stop` callback and calls it **before**
the first delete, for premium rows only — a free download survives a sign-out
untouched, because a free title needs no account and stopping one would also mark
it paused, which is the one state that stops it resuming by itself.

The callback is wired with `ref.read` inside a closure rather than by holding the
downloader, so no edge is added to the provider graph: holding it would let a
rebuild anywhere below the content repository rebuild the account notifier and
reset the signed-in state mid-session.

**And the rule is now a check.** `security_invariants.py` rule 9 fails the build
if `dropEntitled` deletes a part file without calling `stop()`, if it calls it
AFTER the delete (the same bug with a callback in it), or if the sign-out stops
passing one. Scoped to the PART files, because the finished films the same method
deletes have no writer — the downloader writes `<id>.mp4.part` and renames only at
the very end — and a check that failed on those would teach whoever met it that
the rule is noise. Both halves were proved by breaking them and watching the build
go red.

### The second one that was wrong: the downloads were going to Google Drive

`res/xml/backup_rules.xml` and `res/xml/data_extraction_rules.xml` exist because
**Android Auto Backup uploads an app's internal storage to the user's Google
Drive by default**, and the "copy your apps to a new phone" transfer is a second
channel that copies more. Both files were written carefully — for the vault, the
break-in selfies, the ADB key and the streaming cache, each with the reasoning
beside it. The streaming cache's reason says it plainly: *"It is premium video …
Auto Backup would therefore upload the catalogue to the viewer's Google Drive."*

Then E1 and A1 put the offline downloads in `files/offline/` and **nobody added a
line**. Those are not cache pieces; they are complete masters at full quality. So:

- every downloaded film was being uploaded to the viewer's personal Google Drive,
- and cloned onto whatever handset the new-phone transfer was run against,
- and, past the per-app backup quota, **the whole backup fails** — so the settings
  and history these files deliberately keep backing up stopped arriving too, for a
  reason nobody would ever connect to a download.

The wrapped data key had the same hole, and it is the trap the file already
documents for `FlutterSecureStorage`: restored without the Keystore key that wraps
it, it opens nothing — and because the trailer is plaintext, every sealed film
would be *found*, *decrypted with the wrong key* and **drawn as noise**, rather
than saying it can no longer be opened.

Both are excluded now, from both channels. Losing them on a restore is the right
outcome: a download belongs to a phone, the app re-downloads on request, and the
shelf drops any row whose file is missing the next time it is read.

**And this one is a check too.** Rule 10: every directory the video hub creates on
disk must be NAMED in both files — named, not necessarily excluded, so a directory
that genuinely should travel can be listed with a comment saying why. What is
refused is the silence. The wrapped key's preferences file is checked by name
against `MediaCrypto`'s own constant, so renaming it there without updating the
rules fails the build. Both halves proved by breaking them.

The check took two goes to be worth having, and both corrections are the point:

- **It matched one spelling and the tree uses three.** `offline/` is written
  `Directory('${base.path}/offline')`; the stream cache — the OTHER directory full
  of catalogue video — is written `Directory(p.join(base.path, _dirName))`, with
  the name in a constant. The first version would have sailed straight past the
  very thing it was written to catch, and whoever adds the next directory will
  copy whichever file they happened to open.
- **It demanded a rule for a directory the platform never backs up.** The poster
  cache lives in `getApplicationCacheDirectory()`, which is outside every backup
  domain by platform rule. A check that asks for something unnecessary is one
  people learn to override, so it now looks at which base directory each one
  hangs off and stays quiet about the cache and temporary ones.

### Checked and safe: an offline film cannot be turned back into a stream

Worth writing down because it is not obvious and because somebody could
"simplify" it away. The player steps down a rung when it stalls, and a stall on a
downloaded film would be a disaster: a viewer watching offline would be switched
to a network copy — spending mobile data on a film they had already paid to
download, or failing outright with no signal at all.

It cannot happen, and the reason is not the `ephemeral` flag. `StreamRenewal`
holds ONE registration and `canRenew(uri)` compares the **exact URI string**. A
stream registers the address it actually opened; a downloaded film is opened from
`sealed://…` resolved to a different local server on a different port, and a
partially-downloaded one from that same local server. Neither string can ever
equal the registered one, so `canRenew` is false and both the downgrade and the
mid-stream renewal return immediately.

**If `canRenew` is ever reduced to a boolean, that protection is gone.** The
comparison is the guard.



## The offline UI (O1–O5) — "Internet မရှိလို့ Layout မပေါ်တာမျိုးမဖြစ်ရ"

The request was Telegram's and Facebook's behaviour: with the radio off the
layout, the artwork, the grid and a title's album must all still be there;
downloads play at full quality; anything else plays as much as was already
watched. Five separate things were wrong, and four of them were invisible from
the code that showed the symptom.

### O1 — offline, every viewer was ANONYMOUS, so premium downloads showed a paywall

The worst of them, and nothing to do with the catalogue.

`ApiAccountRepository.currentUser()` **rethrows** a network failure rather than
reporting a sign-out — deliberately and correctly, with a comment saying so.
Nothing caught it. `AccountNotifier.refresh()` is called unawaited from its own
constructor, so with no connection the throw escaped as an unhandled async error
and the state never left its initial value:

```dart
const AccountState()   // isLoading: true, user: null, Entitlement.free()
```

`viewerProvider` builds `ViewerTierX.from(account: null, …)`, which is
`ViewerTier.anonymous`. And `playOffline` asks
`CapabilityMatrix.allows(tier, Capability.downloadOffline)` before opening a
file. **So a paying subscriber who had downloaded a film specifically to watch
without a connection was shown a paywall for their own file, on the one
connection state the entire download feature exists to serve.**

Fixed by remembering the server's own last answer:

- `data/api/account_snapshot.dart` — user identity plus entitlement, in the
  Keystore-backed vault (the one store the backup rules already exclude), used
  under four conditions that must all hold: **only when the network failed**,
  **only for `grace` (30 days)**, **only for the same user id**, and **only
  while signed in** (`signOut` forgets it in the same step that empties the
  shelf). `Entitlement.isActive` still applies on top, because the expiry
  travels with the snapshot.
- `refresh()` now resolves to a state always, and tells the two failures apart:
  a REFUSAL (401/403/404) signs the user out and forgets the snapshot; an
  UNREACHABLE server falls back to it and sets `AccountState.isOffline`.
- The `installId` read is outside that try and tolerant of its own failure, so
  it cannot reintroduce the same bug from one line higher.

### O2 — nothing in the catalogue half was ever persisted

`getRows`, `getCatalogue`, `getRowCatalogue`, `getFacets`, `getById` and the
album all went straight to the network and kept nothing. Offline the landing tab
drew `HubErrorState` **instead of** its rows, so there was no layout at all; a
category grid drew an error; and the album silently vanished from the detail
screen, which kept its poster and synopsis only because the card object had been
handed to it by the screen behind.

`data/cache/catalogue_cache.dart` keeps **raw response bodies**, keyed by
request. Not parsed objects: a second copy of the parser would have to be kept in
step with `VideoContent` by hand, and the copy that goes stale is always the one
some screen happens to read. Keeping the JSON means the one parser stays the only
one, and a column added tomorrow is cached correctly today.

- `getApplicationSupportDirectory()/vh_catalogue/`, SHA-1 file names, bounded by
  age (45 days), count (200) and bytes (8 MB), write-then-rename.
- The **support** directory and not the system cache directory: this is the only
  copy a phone with no signal has, and Android empties the cache directory
  without asking. Excluded from both backup channels — rule 10 proves it.
- `_cachedGet` / `_cachedPost` in `ApiContentRepository` are the only door.
  **The fallback is for "could not ask", never for "was told no"**: only
  `isUnreachableError` reaches the cache, so a 401 still rethrows rather than
  serving a listing row-level security has just declined.
- Offline **search** falls back to `CatalogueCache.titleRows()` matched against
  `VideoContent.searchHaystack` — the same field set the demo repository
  searches, so the two cannot drift.
- `signOut` clears it. The catalogue is RLS-scoped, so what is in it is what the
  person signing out was allowed to see.

### O3 — the poster cache was in the directory Android empties

`PosterCache` lived in `getApplicationCacheDirectory()` on the argument that
artwork "can always be fetched again". That premise is exactly what the offline
programme breaks: with the text now surviving, artwork reclaimed by Android would
leave the catalogue rendering as a grid of grey tiles — the same blank screen one
layer down. And this app writes multi-gigabyte downloads to the same device, so
it is itself the likeliest reason that directory would ever be reclaimed.

Moved to `getApplicationSupportDirectory()/vh_posters/`, same 48 MB ceiling, old
directory deleted once on upgrade, excluded from both backup channels, and
clearable by the user — a second button on the stream-cache screen, deliberately
separate from the video one because they answer opposite needs.

### O4 — and the UI now says "offline" instead of printing an exception

`HubErrorState` showed `error.toString()`, which on a phone with no signal reads
`ApiException(network)`. It now tells the two apart with the same
`isUnreachableError` the repository uses, and `OfflineNotice` — driven by
`CatalogueCache.servedFromCache` — puts one line above the hub and the see-all
grid saying what is on screen was saved rather than fetched. Driven by the thing
that answered the request rather than by a connectivity probe, because the honest
question is not "is there a signal" but "is what you are reading current".

### O5 — the bytes were on the disk and the app refused to open them

The one the user asked for in so many words: *"တခြားဟာတွေကတော့ ကိုယ့်ကြည့်မိသလောက်ကို
Offline အခြေနေမှာ ကြည့်လို့ရရမယ်"*.

The streaming cache keeps every byte the phone receives, in app-private storage,
so that dragging the bar back thirty seconds costs nothing. All of it was still
there with the radio off — and unreachable, because **every** play goes through
`requestPlayback` first and a phone with no signal never gets an answer. Bytes on
the disk, already paid for, already authorised once by the server that sent them,
and the app showed "unavailable".

What changed:

- **`AccessDenial.offline`**, its own value. Everything that failed was
  `unavailable`, which mixes "we could not ask" in with "the answer was no for a
  reason we did not recognise" — a region block, a banned account. That mixture
  cannot be acted on, because playing what is on disk is exactly right for the
  first and exactly wrong for the second. `requestPlayback` returns it only for
  `isUnreachableError`.
- **`data/cache/offline_replay.dart`** finds the best copy and refuses honestly.
  The cache holds arbitrary runs of bytes, so the run containing **byte zero** is
  what matters — somebody who dragged the bar has a hundred megabytes from the
  middle of a film and cannot open it at all. Its header is walked by
  `assessMp4Head`, the same function the watch-while-downloading screen uses, and
  a film whose index is at the end is refused rather than opened into a black
  screen that never resolves.
- **`kStreamCacheRungs`** in `stream_cache_id.dart`. A cache id is a hash of the
  title, the asset and the rung — deliberately one-way, so a directory listing is
  not a list of what somebody has watched — which means offline the only way to
  find a film is to compute every id it could have been. Seven hashes. The
  alternative was writing title ids into the cache directory, which is the
  property that scheme exists to keep. Rule 12 fails the build if the list and
  `LADDER_H` in `tool/transcode.sh` disagree.
- **`StreamCacheServer.localUrlForHeldBytes`** serves from disk and nowhere else:
  `_Source.offline` skips the length probe and the upstream fetch rather than
  attempting them and letting them fail, which would have spent two connection
  timeouts plus three per gap on the path to the first frame — forty-five seconds
  of spinner before a film the phone already had.
- **`_playHeldBytes`** in `playback.dart`, because the structural checker is right
  that only that file may reference `Routes.player`. It asks `CapabilityMatrix`
  exactly as `playOffline` does and is the same concession, not a new one: the
  client's own table decides, which protects nothing against a modified app, and
  what limits it is that the bytes exist only because the server authorised the
  stream and the tier behind the decision is itself the server's last answer.
  It says out loud when playback will stop early, because a film that ends
  without warning three-quarters of the way through reads as a broken app.

Rule 12 was mutation-tested five ways: offering held bytes for any denial rather
than `offline`, removing the entitlement test, another file minting the loopback
address, removing the header walk, and the ladder drifting out of step with the
encoder.

### Fenced by rule 11 in `tool/security_invariants.py`

Each of these was mutation-tested by breaking it and watching the check fail:

1. no `/functions/**` path may go through the caching helpers (a signed URL that
   expires must never be remembered);
2. every `CatalogueCache.read` must be preceded by the retryable test;
3. fewer than five cached reads means a screen fell off the offline path;
4. `grace` must exist and be ≤ 60 days;
5. a snapshot dated in the future must be refused (the grace window is measured
   against the device clock, so winding it forward is the way past it);
6. `signOut` must call both `AccountSnapshot.forget()` and
   `CatalogueCache.clear()`;
7. `refresh()` must contain a `catch`.

`test/offline_first_test.dart` covers the three pure decisions —
`isUnreachableError`, `AccountSnapshot.decode` and
`CatalogueCache.collectTitles` — including every refusal, because a refusal that
stopped working would be silent.


## Notes for whoever picks this up

- **No Flutter or Dart SDK in the session container.** `python3 tool/check.py`
  runs locally — 15 checks, four of them JavaScript, and it says so *loudly* when
  node is missing rather than quietly passing. `flutter analyze` and
  `flutter test` only run in CI, via `workflow_dispatch` on the branch. The
  release job only fires on `main`.
- **Merging to `main` cuts a public GitHub Release** and pushes an update prompt
  to every phone. It is not a quiet operation and is never done without asking.
- **This repository is public.** `docs/edge/*.ts`, `docs/studio/index.html`,
  `tool/transcode.sh` and `.github/workflows/*` are all readable by anyone, and
  `docs/` is additionally published as the operator console. Every credential
  belongs in Supabase Edge Function secrets, Cloudflare secrets or GitHub Actions
  secrets.
- ⚠️ **One was not.** `docs/RUNBOOK.md` carried the live `R2_SECRET_ACCESS_KEY`
  and `R2_ACCESS_KEY_ID` in full, from the first commit that pushed this project
  to GitHub until 2026-09-25. It is out of the working tree now and **that does
  not undo it**: the value is still in this repository's history, in every clone
  and fork, and in whatever cached the page. **Those keys have to be rolled in
  Cloudflare** — R2 → Manage API tokens → a new token with **Object Read & Write**
  scoped to the two buckets, both values pasted into the Supabase project's Edge
  Function secrets (ONE place: all four functions read the same two), then the old
  token revoked. The Worker is unaffected throughout, because it reaches the
  bucket through a binding rather than a credential.
  Until that is done, anyone who has read the repository can read, overwrite and
  delete every object in the media bucket.
  `tool/security_invariants.py` rule 8 now fails the build on a credential-shaped
  string anywhere in the tree, so it cannot come back the way it arrived.
- **The odd-looking code is usually deliberate.** Split executors, reflection,
  `useLegacyPackaging`, the WebView thread rules, `--demuxer-lavf-probesize`'s
  minimum of 32. Read `git log` and the docs before calling something a weakness,
  and say plainly when unsure.
