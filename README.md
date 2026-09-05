> **New here? Read `docs/project_brief.md` first.**
> It states what this project is, what is decided, where things stand and the
> rules that were learned the hard way — so a new session does not begin with
> the project being re-explained.
>
> | Document | Holds |
> |---|---|
> | **`docs/handoff_2026_08_31.md`** | **start here** — newest state, and the Movies files that are ready to run |
> | `docs/handoff_2026_08_30.md` | the previous one: signing history and the on-device test table |
> | `docs/project_brief.md` | the whole picture: what, why, current state, conventions |
> | `docs/maintenance.md` | how to verify a change, honest weakness list, roadmap |
> | `docs/premium_backend_spec.md` | schema, RLS, playback function, security model |
> | `docs/client_api_contract.md` | every endpoint the app already calls |
> | `tool/README.md` | the structural checks, and how to add one |
>
> Verify in this order: **FlutLab Analyzer → `python3 tool/check.py` → Build.**

## v1.64.7+320 - The compiler stops being invisible (4 Sep 2026)

No app-facing change. This one moves where the project is built.

For sixty builds the loop was: zip, upload to FlutLab, press Build, read the
error on a phone, copy it back, repeat. The cost was never the typing - it was
that the compiler was the only thing that knew the truth and it could only talk
to one person. Every check outside FlutLab exists to approximate what a
compiler already knows for certain, and the builds that failed anyway failed on
exactly the class of thing only a real analyzer can see.

`.github/workflows/build.yml` runs the analyzer, the eight structural checkers
and a signed release build on every push. `docs/CI.md` is the runbook.

**The signing constants are gone from `android/app/build.gradle.kts`.** They
were defensible while this project lived only in zips that carried
`innocent.jks` anyway. They are not defensible in git: that file is committed,
and a password in git history cannot be removed later - not from forks, not
from clones, not from a log that already printed it. Signing now resolves
`signing.properties`, then `key.properties`, then environment variables. With
none of the three the release variant gets no signing config and the build says
so loudly, which is the right failure.

**The workflow verifies the APK's certificate against the Innocent key and
fails on a mismatch.** This is the most valuable line in it. With no Play
Store, an installed app can only be updated by an APK signed with the same key
- ship one signed with something else and every existing install is stranded
permanently, with no recovery short of uninstalling. That failure mode is now
unreachable by accident.

FlutLab is not retired yet. Keep that project as it stands, keystore included,
until Actions has produced a signed APK that installs over the current build.

## v1.64.6+319 - Settings knows whether the app is stale (4 Sep 2026)

Steps 1 and 2 of `docs/updater_plan.md`. There is no Play Store, so an
installed build has no way to learn that a newer one exists. This adds the
smallest half of that: a single-row table on the server, and a screen that
reads it.

**It checks. It does not download and it does not install.** That split is the
whole reason to build it in this order - the manifest is proven end to end
without a line of code that could leave a half-written APK on the phone or hand
a corrupt file to the package installer.

**Server** - `docs/migrations/012_app_releases.sql`, and it deliberately
depends on no other migration: no foreign key, no RPC, and it creates
`schema_migrations` itself. So it runs today whether or not 008-011 have been
applied, and they can follow in any order.

Both grants are in the same file as the table, because this project has twice
shipped a table that no role could read. `authenticated` is granted alongside
`anon` - PostgREST resolves the role from the bearer token, so granting only
`anon` would mean the check works until someone signs in and then stops.

`apk_url` and `apk_sha256` are NULLABLE here, which the plan document has as
`not null`. There is no APK published yet, and a `not null` column would have
to be filled with an invented hash. Step 3 compares a download against that
hash; a fake one fails in a way that reads as tampering. Null says "not
published", which is true.

**Client** - a new `lib/features/updater/` with three files. The version check
compares `version_code` as an INTEGER, never the name: '1.9.0' sorts above
'1.64.5' as text, which every project discovers once. It is strictly greater
than, so a build that is ahead of the server reads as up to date - the updater
must never offer a downgrade.

It does not route through `ApiClient`. That client attaches the user session
and refreshes tokens; the version check has to work before anyone signs in, so
it sends the publishable key as `apikey` and no `Authorization` at all.

Settings -> App update is never hidden, even when up to date. It is where
someone goes after dismissing a prompt, and the only place they can confirm the
app is not stale.

## v1.64.5+318 - The vault could fill your phone (2 Sep 2026)

Three files. The Add Files picker was audited the way Transfer was: read end to
end, then the risky paths ported and tested rather than reasoned about.

**Most of it came back clean, and it is well built.** `dir.list(followLinks:
false)` closes symlink escapes and loops. Every file is `stat()`ed exactly once
in parallel batches of 48, because an earlier version called `statSync()` inside
the sort comparator AND again per row and froze on large folders. The directory
cache is bounded at 24 entries. Cancelling mid-import is distinguished from
failing, with the reasoning written down: reporting a cancel as a failure would
push someone toward deleting an original they still need.

**One real gap, and the fix already existed elsewhere in this codebase.**

Vaulting COPIES each file into app-internal storage. Selecting 20 GB with 5 GB
free started anyway: the loop copied until the disk filled, then every remaining
file failed one at a time, leaving a half-vaulted set on a full device.

That is worse than an ordinary error. The reason to vault a file is to hide it,
and someone who believes a file is hidden may delete the original. A run that
half-succeeds while reporting per-file errors is precisely the state in which
that happens.

**The Transfer receiver has refused up front since a Wi-Fi batch once filled a
disk on its last file** - it sums the sizes, asks the native `freeBytes`
channel, and stops with a clear message. The vault had the identical exposure
and no guard. This applies the same control rather than inventing a new one:
same channel, same 64 MB headroom, same "proceed when the platform will not
say", because refusing on an unknown would block every import on any device
whose answer cannot be read.

`freeSpaceBytes()` is new on `PrivateFolderService` rather than borrowed from
the receiver, deliberately: the vault writes to `getApplicationSupportDirectory()`
and the receiver writes to public external storage. Usually the same volume, not
required to be - and a free-space check against the wrong volume is worse than
none, because it returns a reassuring number about somewhere else.

Verified by decision table across eleven boundary cases, including exactly-equal
and one-byte-short. The first run failed - on an expectation I had written
wrongly, not on the code. That is the table earning its place.

## v1.64.4+317 - Transfer audited against the published research (2 Sep 2026)

One file. The share PIN could be brute-forced.

Transfer was audited by taking the known failures of this app class - SHAREit,
Xender, Zapya - from published security research and checking each one against
this implementation, rather than by reading the code and forming opinions.

**Three came back clean, and two of those were verified rather than eyeballed:**

* **Path traversal on the receiver.** `sanitizeRelDir` and `_safeName` were
  ported and run against a real filesystem with 67 hostile inputs - `../`,
  `....//`, absolute paths, UNC paths, NUL bytes, unicode lookalikes, a
  40-level nest. **Zero escapes**, and nothing appeared outside the root on
  disk afterwards.
* **Exported components.** Trend Micro's 2021 SHAREit RCE came from an
  improperly exported content provider. This app's `FileProvider` is
  `exported="false"` with `grantUriPermissions`, every exported component is
  justified, and the iADB service is gated behind
  `INTERACT_ACROSS_USERS_FULL`.
* **Upload filename injection** was already handled, including the `.`/`..`
  survivor a 30,000-case fuzz had found.

**One was present.** CVE-2018-19429 is a PIN in Xender whose length the UI
limited but whose guessing nothing limited. `/pair` had exactly that shape: a
four-digit PIN is ten thousand possibilities, and over a LAN with no throttle
that is seconds.

Now: per-IP lockout after five failures, doubling from 30 s. Twelve failures
cost an attacker 95 minutes; exhausting a four-digit PIN moves from seconds to
years. Per SOURCE ADDRESS, not global - a global counter would let one clumsy
neighbour lock the real receiver out, which is a denial of service wearing a
security control's clothes. A correct PIN clears the history, because fumbling
one's own PIN is the common case. Lockouts are cleared when sharing stops, so
the map cannot grow across sessions.

The comparison is also constant-time now. A plain `!=` returns as soon as two
characters differ, so the time taken leaks how many leading digits were right -
which turns 10,000 guesses into about 40.

**One is present and inherent, and is documented rather than papered over.**
CVE-2018-19430/19431 are cleartext HTTP in Xender and SHAREit. Innocent has the
same exposure: files and the token cross the LAN unencrypted. There is no cheap
fix - HTTPS on a LAN means either a self-signed certificate, which trains users
to click through security warnings, or a real certificate for an IP address,
which is not issuable. What reduces it is the PIN (now that guessing is
throttled, it is a real control) and approval mode. See `docs/BACKLOG.md` §D.

`docs/BACKLOG.md` is new: every remaining item with the TRIGGER that makes it
worth doing, and an explicit list of what is deliberately not being done. The
recurring mistake in this project has been building ahead of evidence, and a
backlog without triggers is how that keeps happening.

## v1.64.3+316 - The vault's cryptography is now checked against a reference (2 Sep 2026)

Tests and three annotated accessors. No behaviour change; `test/` is not
compiled into a release build.

An audit of the whole project, not just Movies, measured this:

    code            99,779 lines
    tests            1,201 lines          1.2%
    tests exist      aspect ratio, settings, resume, video hub, insights
    tests absent     downloader, transfer, PRIVATE FOLDER, music, browser

The absence that mattered is the vault. `private_folder_service.dart` is 1,600
lines holding the PIN hashing, the decoy-PIN decision and the lockout state -
the code standing between a borrowed phone and someone's private files - and it
had no tests at all. The three largest untested files in the project are its
service, its screen and its file picker.

Worse: its PBKDF2 is **hand-written** rather than taken from a package. That is
a defensible choice - the function stays readable and auditable, which a
dependency does not - but a hand-written primitive that has never been checked
against a reference implementation is a hope, not a control. One transposed
index in the XOR loop yields a hash that is perfectly self-consistent, verifies
every PIN it ever wrote, and offers a fraction of the intended resistance.
Nothing in the app would look wrong.

**It is correct.** Verified against Python's `hashlib.pbkdf2_hmac` - a separate,
standards-conformant implementation - on eight vectors, and against the three
published PBKDF2-HMAC-SHA256 vectors for `password`/`salt` at 1, 2 and 4096
rounds. The expected values in the test file come from that reference, never
from this implementation: a test whose expectations came from the code under
test proves only that the code agrees with itself.

Seventeen tests, in four groups:

* **published vectors** - the standard proof for any PBKDF2;
* **edges a real vault meets** - empty PIN, empty salt, a Burmese-digit PIN
  (the app is Burmese-first and the PIN is a String, so a byte-vs-code-unit
  slip would show up here and nowhere else), 32-byte output for every input,
  and a check that changing the round count changes the hash - which guards
  the `i = 1; i < rounds` loop bound that a version ignoring `rounds` would
  otherwise pass;
* **`roundsOf`** - the parse that decides how many rounds a stored hash was
  written with. Get it wrong and verification derives a different hash from the
  CORRECT PIN: a permanent lockout from one's own vault, with nothing on screen
  to explain it. Five malformed inputs must all fall back rather than crash;
* **`constantTimeEquals`** - differences at both ends, and differing lengths,
  because the length is folded into the same accumulator and without that
  `abc` would match the first three characters of `abcdef`.

Dart's `_` is library-private, so a test file cannot reach any of this. Three
`@visibleForTesting` wrappers are the narrowest opening that makes the security
code testable at all; they add no behaviour, hold no state, and the analyzer
flags any production call site.

## v1.64.2+315 - Two weaknesses found by auditing the last three releases (2 Sep 2026)

Dart only, two files. Neither was reported; both came from re-reading what had
just been shipped.

**The album query had no limit.** `_album()` asked `title_media` for every row.
The mosaic is a `Column` inside a `SliverToBoxAdapter`, so there is no
virtualisation to hide behind - a folder with two hundred stills would build
two hundred image widgets in a single frame and jank the screen it exists to
show off. Capped at 60, which is far beyond any album that still reads as a
glance and far below where the layout costs anything.

**Clamped rows dumped their slack on the last tile.** When a row is taller than
1.15x the container it gets clamped, and `ratio * height` then no longer fills
the width. The shortfall was handed entirely to the last tile, making it
visibly wider than its neighbours - two identical portrait stills would come
out different sizes. It is spread proportionally now, so equal ratios get equal
widths.

Reachable with two items at the 0.4 ratio floor, so a real case rather than a
theoretical one. The layout suite gained a sixth invariant to catch it - *within
a row, tiles of equal ratio must have equal width* - and now runs seventeen
shapes including the two clamp cases.

Migration `011` ships alongside and fixes a third, which was mine: **009
removed a sort_order tie and the `add_title` it shipped with put it back.**
Photos were numbered from their ARRAY POSITION, so adding one more still in a
second call restarted at 1001 and collided with the first photo.
`unique (bucket, object_key)` stops a duplicate row; it does not stop a
duplicate sort_order, and a tie is exactly the nondeterministic album order 009
was written to remove. `add_title` now continues the sequence from what is
already stored, and a unique index refuses a tie at write time instead of
leaving it to be discovered as an album that reshuffles itself between visits.

## v1.64.1+314 - Locked items are blurred, not blacked out (2 Sep 2026)

Dart only, two files.

A locked album tile was a 62% black scrim: it proved something was missing and
said nothing about what. In the full-page viewer it was worse - a lock glyph on
an empty background, with the picture not drawn at all.

Both now draw the image BLURRED. The shape, the colour and the composition
survive; only the detail is withheld. The offer becomes "there is more of THIS"
rather than "there is more of something", which is the whole mechanism behind
feature-preview paywalls: people judge what they can see far more readily than
what they have to imagine.

`sigma 14` in both places, from one shared helper. Two hand-tuned values would
drift apart the first time either was adjusted, and a preview crisper in the
grid than in the viewer reads as a bug. `TileMode.decal` rather than the
default clamp, which smears edge pixels outward and paints a dirty border
around every locked tile. The scrim drops from 0.62 to 0.22 on the tile,
because the blur is now doing that work and the scrim only has to make the lock
glyph legible.

**Stated plainly: this is a presentation choice, not a control.** These photos
live in the PUBLIC bucket and their URLs are already reachable by anyone; the
app blurs them after downloading them. It exists to sell, not to protect.
Anything that genuinely must not be seen belongs in the private bucket behind
`request-playback`, like the video does.

The cost that follows from that, and the fix: a free viewer DOWNLOADS every
locked photo in full in order to see a blur of it. At the current 3.31 MB per
photo, a premium title with seventeen locked stills is fifty-odd megabytes of a
Myanmar user's mobile data spent on pictures they are being denied. Shrinking
the photos - already on the list - takes that to about 1.4 MB. The permanent
answer is BlurHash or ThumbHash: a 20-30 character string that renders the blur
without the image existing on the device at all, which is how Telegram, Signal
and Mastodon do this. The blocker is encoding, not decoding - it needs a real
image decoder server-side, which the R2 dashboard workflow has nowhere to run
yet. Noted rather than half-built.

## v1.64.0+313 - The album stops being a grid of squares (2 Sep 2026)

Dart only, plus two edge functions that deploy separately. Minor rather than
patch because the album's layout is now a different thing.

**The mosaic.** The album was `crossAxisCount: 3, childAspectRatio: 1` - three
columns of squares, forever. A 9:16 portrait clip and a 16:9 still were handed
the same square hole, so the clip lost about 44% of its frame. That is a poster
grid, and a folder of mixed stills and clips is not a poster screen.

`MediaMosaic` lays rows out from what is in them, the way Telegram's grouped
media does. Its maintainers state the rule this obeys: the layout may crop
however it likes, but the pixel aspect ratio is sacred and must never be
stretched. Every tile draws with `BoxFit.cover`, which crops.

The algorithm: a ratio per item, `round(total / 2.2)` rows, items split into
that many contiguous groups of roughly equal ratio-sum, each row scaled so its
widths plus gaps exactly fill the container.

**The partition needed a second attempt, and testing found it.** The obvious
greedy version closes a row as soon as its sum reaches the average, which
front-loads: nine square photos came out as `3+3+2+1`, and that trailing single
tile is drawn full width - the ninth photo became a banner twice the height of
the eight above it. The look-ahead version asks whether stopping lands closer
to the average than taking one more, and the same nine become `2+2+2+3`.

Verified by porting the algorithm and running it over nineteen shapes - 1 to 20
items, portrait, landscape, mixed, a panorama, a single 9:16 clip - checking
four invariants each time: every item placed exactly once, every row's widths
plus gaps equal the container to within a rounding error, no zero-size tile, and
nothing taller than 1.15x the width. Plus a fifth after the fix: no lonely
trailing tile.

Items are NOT reordered. Telegram reorders to pack tighter, which is right for
a message nobody curated; here `sort_order` was chosen by the operator, and
resequencing it would be the app overruling an editorial decision.

**Clips became playable.** `_album()` gives a clip `provider: 'asset'` and the
asset id, never a URL. The client now sends `asset_id`, and `request-playback`
v3 looks that asset up, **checks it belongs to the title**, and signs its object
key. Without that ownership check anyone could pair a free title with a premium
title's asset id and walk past the tier test. An `is_free` asset opens inside a
premium title - the trailer slot, an explicit flag rather than a rule like "the
first clip is free", because which clip is the taste is an editorial decision.

**The v2 diagnostics left the client.** `reason` and `detail` found the missing
`service_role` grant after two confident wrong guesses, and were worth it while
nothing was live. They also carried raw database error text out to the app.
v3 writes the same information to the function log instead: same debugging
power, nothing leaked.

Two functions deploy alongside this build - `request-playback` v3, and a new
`backfill-dimensions` that reads image headers over a `Range` request so a 3 MB
photo costs 64 KB to measure. Its PNG, JPEG and WebP parsers were run against
seven real files generated for the purpose, at sizes from 1x1 to 1920x1080,
plus a thousand random bytes that must return null rather than a wrong number.
The JPEG parser walks the marker chain rather than searching for `0xFFC0`,
which occurs inside compressed scan data often enough to find garbage.

## v1.63.7+312 - The album the API could never return (2 Sep 2026)

Dart only. Two files.

The detail screen has always had an album section - the mixed grid of stills
and clips behind a poster - and `VideoContent.items` to fill it. **The API
adapter never populated it.** `getById` selected the fifteen title columns and
stopped, so on a real backend `hasAlbum` was false for every title and the
section never drew. Only the demo repository ever produced an album.

That would have been discovered the expensive way: upload a hundred folders of
four photos each, then find the app shows one poster per title and nothing
else.

`getById` now makes a second request to `title_media` - the view added in
migration 006, which exposes photos with a public URL and clips WITHOUT one.
A clip's playable URL still has to come from `requestPlayback`, so the
ten-minute expiry keeps applying to everything in the folder, not just the
main video. `title_assets` itself, which holds raw object keys, is not
readable with the app's key at all.

A second request, and only on the detail screen. The catalogue draws thirty
cards from one response; giving each of those its album would multiply the
payload by the part nobody has looked at yet. The card badges already come
from `photo_count` and `video_count`, which the server maintains - so the grid
knows how many extras exist without fetching any.

Three deliberate details:

* **Failure returns an empty album rather than throwing.** A title whose
  extras will not load should still play; the album is the bonus, not the film.
* **`photoCount` and `videoCount` are not recomputed from what loaded.** The
  server counts everything in the folder, the album holds only what this screen
  fetched, and overwriting the first with the second would make a card's badge
  shrink when the detail screen opened.
* **`withAlbum` is a narrow copier, not a general `copyWith`.** The entity
  already refuses a wide one for a stated reason - a copyWith this broad
  invites call sites to rebuild everything and silently drop a field. Verified
  mechanically that all seventeen constructor fields are carried through.

## v1.63.6+311 - Pointed at the real backend (1 Sep 2026)

One file changed: `BackendConfig._baseUrlDefault` and `_anonKeyDefault`, which
were empty strings. Every build until now ran on the bundled demo repositories
and never opened a socket, so the API adapter written weeks ago had still never
met a server.

Filled in rather than passed as `--dart-define`. The build runs in FlutLab,
where a custom define may not be reachable; a value that must be retyped into a
web IDE on a phone for every build is a value that will eventually be typed
wrong, and the symptom - an empty catalogue - looks nothing like the cause. The
defines still override these when present, so a staging build needs no edit
here.

Neither value is a secret. The publishable key identifies the project and
authorises nothing; it is meant to ship inside the APK. What protects the
catalogue is RLS plus the column grants, and what protects the media is
`request-playback`.

**The backend was proven before this build, not after.** On 1 Sep 2026, against
the live project: `anon` was refused `titles.locator` and allowed the catalogue;
all three RPCs ran as `anon`; the playback function returned a signed URL; that
URL played; and ten minutes later the same URL returned `ExpiredRequest`. The
last of those is the one that matters - a link that does not expire makes every
other control decorative.

Three things worth recording from getting there, because all three cost time:

* **`Verify JWT with legacy secret` must be OFF** on `request-playback`. The app
  sends its key in the `apikey` header and only sets `Authorization` when a user
  is signed in, so an anonymous free-title call carries no bearer JWT and the
  platform 401s before the function runs - which this client maps to
  `needsPremium`, i.e. a paywall on a free title. The toggle has been reported
  to switch itself back on after a redeploy.
* **`service_role` needed explicit grants.** Disabling "expose new tables" at
  project creation withholds them from `service_role` too, so the playback
  function - which is the only thing allowed to read `locator` - was refused by
  the very grants written to protect it. Diagnosed only because the function was
  changed to report `reason` and `detail` instead of a bare `not_found`; two
  confident guesses before that were both wrong.
* **A VPN silently breaks R2 uploads.** The dashboard loads from
  dash.cloudflare.com but the file goes straight to
  `<account>.r2.cloudflarestorage.com`, so the page working proves nothing about
  the upload path.

## v1.63.5+310 - Three defects the plans already named, and the docs that had drifted (31 Aug 2026)

Dart only. No native change, no new dependency, no new permission.

**`AccessDenial.wrongDevice`.** `client_api_contract.md` documents a `409
{"code":"wrong_device"}` refusal, and `api_client.dart` had no case for 409 -
it fell through to `default` and became `ApiErrorKind.server`, which the
repository read as "unavailable". So the ONE refusal a user can act on was the
one they could not be told about: a paying customer holding a replacement phone
saw "this item is not available yet", waited, and would have asked for a
refund. Now 409 is mapped, and `wrong_device` / `too_many_devices` are told
apart by the server's own code rather than by the status alone, so a deployment
that answers 403 with that code still reaches the right message. Its own enum
value and not a flavour of `needsPremium`, because showing the paywall to
someone who has already paid reads as being charged twice.

**The device id was being backed up to Google Drive.** The known gap said
`device_identity.dart` used SharedPreferences and that "Clear data" wipes it -
which turned out to be the wrong worry, since clearing data is indistinguishable
from a reinstall and a reinstall SHOULD mint a new id. The real defect was the
opposite one: Android's Auto Backup uploads SharedPreferences, and the
device-transfer flow copies it to a new handset. The single value whose whole
job is to say "this is a different phone" was riding along to the different
phone. Moved to `flutter_secure_storage`, whose file both `backup_rules.xml`
and `data_extraction_rules.xml` already exclude from cloud backup AND device
transfer - so this closes both channels with no manifest change and no new
dependency. An id written by an older build is migrated once rather than
replaced; a failed keystore write falls back to the old location, because an id
that is backed up is a smaller problem than one that changes every launch.
Concurrent first calls now share one future - a cold start fires several
requests at once, and each used to generate and write its own value.

**Posters were re-downloaded on every cold start.** `Image.network` caches in
memory only. On Myanmar mobile data, scrolling the same grid tomorrow cost the
same megabytes again. New `PosterCache`: app-private cache directory, SHA-1
file names, atomic `.part` rename so an interrupted download can never be read
as complete, 48 MB cap pruned oldest-first once per session, and a corrupt file
is dropped rather than served forever. Written by hand rather than adding
`cached_network_image`, which pulls in `flutter_cache_manager` and `sqflite` -
a NATIVE plugin, which would make this a minor release and add a platform
library to a build that cannot be compiled locally to check. Every failure path
returns null and the widget falls back to plain `Image.network`, so the worst
case is exactly the behaviour that existed before. The file names are hashes
deliberately: this catalogue is adult, and a directory listing of real titles
is a leak even inside app-private storage. One line - `PosterCache.enabled` -
turns the whole thing off.

`PosterImage` became a `ConsumerStatefulWidget` to hold the cache result. The
previous `FutureBuilder` created a new future on every rebuild, which is what
made posters blink during a scroll; the fetch is now guarded on the resolved
URL, so it runs once per poster and not once per frame. `didUpdateWidget`
clears it when a recycled tile is handed a different title.

**Two documents had drifted from the code, one of them expensively.**
`client_api_contract.md` listed the catalogue columns as `...,popularity,
access_tier`. The code asks for `view_count`, `photo_count`, `video_count` and
filters on `is_featured`, none of which the document mentions - so a `titles`
table built from the document would answer every catalogue request with HTTP
400 and the app would show an empty catalogue with no explanation. Corrected
against the code, which is the only authority here. `maintenance.md` weakness
&#35;3 claimed no tests cover the video hub; `test/video_hub_logic_test.dart` has
covered all four named cases since 25 Aug. Corrected, and the new refusal
reasons are covered too.

## v1.63.2+307 - Signed for real, and the frame-step buttons taken back out (Aug 2026)

**The release keystore exists.** Generated 30 Aug 2026 and now in the tree at
`android/app/innocent.jks` with `android/key.properties`. Identity and
fingerprint are recorded in `docs/signing_identity.md`. This ends the blocker
that `docs/handoff_2026_08_30.md` called the next real task.

Two consequences worth stating plainly. **The zip now carries a private signing
key and its password** — `android/.gitignore` covers both for git, but a zip
ignores .gitignore entirely, so those two files must be deleted by hand before
this archive goes anywhere. And **the signing key is now permanent**: the first
build that reaches another person's phone fixes it forever, because Android
refuses an update signed with a different key and the in-app updater is the
only distribution channel.

**Frame-by-frame is hidden.** It worked — the buttons appeared while paused and
stepped correctly on a real device. It is off because two extra icons either
side of play/pause crowd the one control everybody reaches for, and stepping
frames is a rare need on a phone. The switch is `_kShowFrameStepButtons` in
`player_screen.dart`; changing one word restores it, and every layer beneath —
`onFrameStep`, `frameStep()` in the controller, `frameStep()` in the media_kit
service — is untouched and still wired.

**The v1.63.1 untested list is now tested**, with results written into the
handoff. Widget buttons, music notification, lock screen and the full-screen
music player all work. Bluetooth headset controls and the subtitle work
(tune panel, seven new formats) remain unverified, deliberately — see the
handoff for why that is a decision and not an oversight.

## v1.63.1+306 - Three things that would have looked broken, and a handoff (Aug 2026)

A pass over v1.63.0 as a user rather than as its author, plus the documentation
a new session needs to start from the truth instead of from the last thing it
was told.

**The subtitle panel was showing a number that was not true.** `_subtitleDelayMs`
was hard-initialised to 0 and never read `IntSetting.subtitleDefaultSync`, so
the panel opened at "+0.0s" while libmpv was applying a real saved offset to
every file. The display and the engine disagreed, and the first tap of "+"
would have jumped the subtitle by the entire hidden offset. It is seeded from
the setting now.

**And it was throwing the fix away.** Size and position persisted; timing did
not. A user fixing a badly-synced episode would have had to fix it again for
the next one. It writes back to the same setting now, so all three behave
alike.

**The last hardcoded subtitle list.** v1.63.0 said there were four copies and
consolidated them; there were five. The delete-sidecars helper had its own,
knowing six formats while the player knew four, so deleting a video could
leave an `.idx` orphaned beside nothing. That one is routed through
`SubtitleFormats` too, and there are now zero hardcoded lists in the tree.

**Immersive mode is re-applied when the tune panel closes.** The player's
existing restore path only fires on an app resume, which an in-app sheet does
not produce.

### docs/handoff_2026_08_30.md (new)

The owner continues in fresh chats, so the state has to live in the repo rather
than in a conversation. It separates what is confirmed working on a device from
what merely compiles and has never been used — the music widget buttons, the
lock-screen controls, the frame-step buttons and the new subtitle formats are
all in the second group, and saying so is more useful than implying otherwise.
It also names the next task without ambiguity: **generate the release keystore
and back it up three times**, before any APK reaches anyone.

`README.md` and `docs/project_brief.md` both point at it, and the brief's
status section — which still described v1.55.14 as unable to compile — has been
rewritten around the fact that the app now runs on a real phone.

## v1.63.0+305 - Closing the gap on MX Player (Aug 2026)

An audit of every feature MX Player advertises against what this app actually
does. The good news first: subtitle styling, seek preview, aspect ratio,
shuffle/repeat, resume, sleep timer, A-B repeat, subtitle and audio delay,
playback speed, PiP, background play, equalizer, screen lock and audio-track
switching were all already here. Four real gaps were found. Three are closed
below; the fourth (SMB/FTP/UPnP) is scoped in `docs/maintenance.md` #10.

### Subtitle formats: five became thirteen

The list of accepted formats was written out FOUR times and all four had
drifted — the file picker took `srt ass ssa vtt sub`, the sidecar scan looked
for `srt ass ssa vtt`, the copy-alongside helper knew about `idx` and `smi`,
the URL downloader had a fourth of its own, and the delete-sidecars helper a
fifth. So a `.smi` could be copied by the app but never opened by it, a `.sub`
could be chosen by hand but was invisible sitting next to its own video, and
deleting a video left an `.idx` orphaned beside nothing.

`SubtitleFormats` is now the only list, and it adds `.smi .sami .idx .mpl .pjs
.txt .sup`. **libmpv already read every one of these** — our whitelists were
refusing them, not the player, which is why this closes most of the distance to
MX's format list in one change. VobSub is a `.idx`+`.sub` pair, so `.idx` is
ordered ahead of `.sub` in the sidecar scan; opening the `.sub` half alone
shows nothing. `.txt` is auto-detected but deliberately kept OUT of the picker,
where it would bury the list under every readme on the device.

### Frame-by-frame

libmpv's real `frame-step` / `frame-back-step`, not a small seek — a seek lands
on the nearest decodable point, which on a long-GOP file can be seconds from
where the user asked. The buttons appear only while PAUSED: stepping a playing
video is meaningless, and two more icons in the transport row would crowd the
one control everybody reaches for.

### Subtitles adjusted against the running picture

Timing, size and position were reachable only from Settings — three screens
from the one moment anyone notices they are wrong, which is mid-scene. The new
panel does all three over the playing video: drag sideways for timing, up and
down for position, tap any value to reset it. Changes are written to libmpv AND
persisted, so they outlive the file.

**Why not gestures on the video, the way MX does it.** The gesture layer
already carries brightness, volume, seek, long-press speed, double-tap skip and
pinch zoom, each with its own enable switch. Adding a mode on top of that
router would risk the gestures people use every day for one they use
occasionally. Inside the panel the drags cannot reach the router at all, and
the capability is the same.

The panel's ranges are pinned to `IntSetting.subtitleScale` (10–200) and
`subtitleVerticalPos` (0–100) because `setInt` CLAMPS silently — a wider range
would not have thrown, it would have quietly lied: 130% on screen, 100% in the
store, and a different number when the panel was reopened.

### Diagnostics, sharpened by the last crash

* libmpv's error stream now writes to the persistent trail. Errors were going
  only to whatever UI happened to be listening, so one arriving just before a
  crash left no record — and that is the only moment that matters.
* `Player.open` is bracketed with `open ok` / `open FAILED`. A crash inside
  libmpv's load and a crash afterwards during decode are different suspects and
  used to look identical in the trail.
* The report lists live SAF folder grants. "Local shows nothing" and "the grant
  went away" look the same from outside — and grants DO go away, since they
  belong to the installed app.

### Package rename, residual effects

Nothing is left in code. What remains is not fixable in code and is written
down instead: folder grants, Auto Backup and any file under the old
`Android/data/<old id>/` belong to the previous application id and do not
transfer. The Settings copy now says so. **Correction:** the v1.60 note claimed
the Dart package stays `mx_clone`; it has always been `innocent`. Only the 19
MethodChannel strings are named `mx_clone`.

`docs/maintenance.md` is current again: #1 and #6 were both out of date, and
two new entries name the 295 invisible catches and the SMB gap.

## v1.62.0+304 - The crash, found (Aug 2026)

+303's diagnostics were installed on a device, the app died, and the report
named the cause on the first try. This release fixes it.

### What the log said

    reason      : CRASH_NATIVE (5)      importance: FOREGROUND
    JNI DETECTED ERROR IN APPLICATION: mid == null
        in call to CallIntMethod        thread: io.worker.3

and, from the breadcrumb trail, the ninety seconds before it:

    80.9  open scheme=path hwdec=auto autoplay=true
    91.7  ERROR  Cannot use "ref" after the widget was disposed
              _PlayerScreenState.dispose (player_screen.dart:756)
    92.7  ERROR  ... didChangeAppLifecycleState (player_screen.dart:563)
    97.9  ERROR  ... didChangeAppLifecycleState (player_screen.dart:563)
    98.7  open scheme=path hwdec=auto autoplay=false      <- second video
    (process aborts)

### The bug

`dispose()` called `ref.read(floatingPipProvider)` on its 34th line. Riverpod's
ConsumerStatefulElement marks itself disposed inside `unmount()`, and
`unmount()` is what calls `State.dispose()` — so that read does not sometimes
throw, it throws EVERY TIME. Everything after it never ran:

* playback was never stopped and **libmpv was never destroyed**
* `WidgetsBinding.removeObserver(this)` never ran, so a finished screen stayed
  subscribed to lifecycle events — the two later errors are that zombie firing
* `super.dispose()` never ran, so `State.mounted` stayed **true** forever,
  which is why the existing `if (!mounted) return` guard did not help. The
  breadcrumbs show it: `lifecycle inactive mounted=true` on a dead screen.
* the wakelock stayed held, the orientation lock was never lifted, the PiP
  callbacks kept pointing into the dead tree

Then a second video was opened on top of a libmpv nobody owned — the exact
pile-up the comment in that same method warns about — and the process aborted
in native code. One line cost the entire teardown, and nothing reported it: the
exception went to a console that does not exist on a phone.

### The fix

* `deactivate()` — which runs BEFORE unmount, while `ref` is still legal —
  snapshots the three values the teardown needs into fields.
* `dispose()` touches `ref` nowhere at all, and `removeObserver` is now its
  FIRST statement, because a leaked observer is the one failure that outlives
  the screen.
* Every teardown step runs through `_step(name, body)` with its own guard, so
  one failure can cost at most its own line and is named in the log.
* An explicit `_disposed` flag guards `didChangeAppLifecycleState`, since
  `mounted` cannot be trusted after a partial dispose.
* `floating_pip_overlay.dart` had the same `ref`-in-`dispose()` bug and got the
  same treatment.
* `tool/ref_in_dispose.py` (new, wired into `check.py`) fails the gate on any
  `ref` inside a `dispose()`. Negative-tested by putting the original bug back:
  it is caught at the exact line.

### Also

The tombstone section of the report was ~200 lines of every thread's backtrace
around the three that mattered. It now leads with a **what went wrong** block
(abort message, signal) and **our own libraries in the trace**, deduplicated,
with the remainder capped below. Checked by replaying the real tombstone
through the sorting.

**Still open:** whether the JNI abort is fully explained by the leaked player.
The evidence is circumstantial — right cause, right moment, right mechanism —
but the abort itself is in a Flutter IO worker thread and that is not proven
from this log alone. The next report will say: teardown now writes
`player teardown done` when it completes, so its absence is the signal.

## v1.61.0+303 - Diagnostics, and the four bugs that were already provable (Aug 2026)

Device testing of +302 turned up seven observations. Four of them had a cause
that could be found by reading the code; the fifth — the app closing outright
during playback — could not, and this release is mostly about making it
findable.

**First, what +302 did NOT cause.** A file-by-file diff against +301 shows the
package rename touched exactly two Dart files: `main.dart` (one notification
channel id) and `app_version.dart`. Everything below therefore pre-dates it and
was simply never exercised.

### Settings → Diagnostics (new)

The app now reports on itself, because on a phone there is no `adb logcat` and
a process that dies takes its in-memory log with it.

* `Diagnostics.kt` reads `ActivityManager.getHistoricalProcessExitReasons`,
  which since Android 11 lets an app ask why its own previous processes ended —
  native crash, ANR, low memory, killed by the system, swiped away. On
  Android 12+ a native crash carries a tombstone; it arrives as a protocol
  buffer, so the readable runs are extracted from it (the abort message, the
  signal, the `.so` names) rather than printed raw.
* `CrashBreadcrumbs` keeps a short trail of what the app was doing in a file
  that is fsync'd after every entry, and rotates it on the next start. An exit
  reason says how the process died; the trail says what it was in the middle
  of. Neither is much use alone.
* `PlaybackLog` gained a sink, so its six existing call sites became persistent
  evidence without one of them changing. `open()` now records the URI SCHEME —
  never the path, which can name a private file — plus the decoder in force.
* The `AudioService.init()` failure below was reported through a `debugPrint`
  behind `kDebugMode`, i.e. nowhere at all in a release build. It is now on the
  Diagnostics screen.
* One **Copy report** button puts the whole thing on the clipboard.

Not localised, deliberately: every line it shows is an Android record in
English, and three translations of `REASON_CRASH_NATIVE` would be decoration.

### audio_service was never starting

`MainActivity` extended `FlutterFragmentActivity`. audio_service requires the
activity to hand back ITS cached FlutterEngine instead of creating a private
one, and the documented way to inherit that is `AudioServiceActivity` — or, for
a FragmentActivity, `AudioServiceFragmentActivity`. Without it `AudioService.init()`
throws, and the swallowed exception took three reported symptoms with it: no
music notification, dead home-screen widget buttons (they deliver media-button
events to audio_service's receiver), and music with no foreground service of
its own — which is why killing the VIDEO notification also stopped the music.

`AudioServiceFragmentActivity` extends `FlutterFragmentActivity`, so the
BiometricPrompt requirement that chose that base class is still met.

**One real consequence:** the Flutter engine is now cached and shared, so the
Dart isolate survives the Activity being destroyed. That is the point — it is
what lets music keep playing — but state now persists across a close-and-reopen
where it used to reset. One line to revert if it misbehaves; see MainActivity.

### The music player left the bottom tab bar behind

All 20 pushes of `MusicPlayerScreen` used `Navigator.of(context)`, which is the
SHELL's navigator. So the player rendered inside the shell's body with the tab
bar still showing — and a tab tap ran `context.go()`, changed the route
underneath, and left the player sitting on top of it. The tap worked; nothing
looked like it had. All 20 now push with `rootNavigator: true`, the rule this
repo already applies to Settings, Private Folder and the video player.

### A notification that outlived its service

`PlaybackService.update()` reaches the service with `startService`, which on a
live app succeeds even when the service is NOT running — it creates a fresh
instance, which took the ACTION_UPDATE branch, never called `startForeground`,
and posted the ongoing notification with `NotificationManager.notify`. The
comment claimed such an update would be "dropped by notify() targeting an id
that isn't shown"; `notify()` creates the notification if it is not there. The
result was an ongoing notification with no service behind it and nothing that
would ever remove it. The service now tracks whether it is actually foreground
and an update to a cold instance stops it instead of drawing.

### Smaller

The music notification's middle button was hard-coded to `pause`, so a paused
track offered a pause button that asked for the state it was already in.

Verified: 23 Kotlin sources and the Gradle script parse clean; `Diagnostics.kt`
stub-compiled against signature-accurate Android stubs (negative-tested with a
typo'd constant); `tool/check.py` 7/7 with two faults injected into the new
files to prove it can see them; whole-tree diff against +302.

## v1.60.0+302 - App identity: package name and release signing (Aug 2026)

The app stops being a sample. Two identity changes that are cheap now and
impossible later, done while there are still no users.

**Application id + package rename.** `com.example.mx_clone` is gone from the
Android project entirely. `applicationId` and `namespace` are both
`com.innocent.media`, all 22 Kotlin files and `IUserService.aidl` declare
`package com.innocent.media`, and their source directories moved to
`kotlin/com/innocent/media/` and `aidl/com/innocent/media/`.

CORRECTION (v1.62): the line that used to sit here said "the internal Dart
package stays `mx_clone`". That was wrong — the Dart package has been
`innocent` all along (`name: innocent` in pubspec.yaml; stack traces read
`package:innocent/…`). What is actually named `mx_clone` is the 19
MethodChannel strings, and only those. Nothing about the conclusion changes;
the record was simply inaccurate.

Deliberately NOT renamed: the 19 `mx_clone/...` MethodChannel names. They are
opaque strings that must match on both sides of the bridge; changing them buys
nothing and breaks the app if either side is missed. Cross-checked: 19 in
Kotlin, 19 in Dart, sets identical.

Renamed with them, because they contained the old package string: the six
service action constants (`DOWNLOAD_START`, `TRANSFER_*`, `PLAYBACK_*`,
`ADB_PAIR_*`, `PIP_CONTROL`, `PLAYBACK_CONTROL`) — Kotlin-only, never named in
the manifest or in Dart — plus the audio_service notification channel id and
the iOS bundle identifier.

Nothing needed changing for the two `FileProvider` authorities: both are
declared `${applicationId}.…` in the manifest and read as `$packageName.…` in
Kotlin, so they follow by themselves. `R` is referenced unqualified in
`MusicWidgetProvider`, so it follows `namespace`.

**Release signing.** Release builds were signed with the debug key — a key that
is regenerated per build container, is not owned and is not backed up, which
made the app's identity an accident of whichever machine last built it. Android
refuses an update signed with a different key, and the in-app updater is the
only distribution channel there is. `android/app/build.gradle.kts` now reads
`android/key.properties` and signs release with a real keystore. It fails SOFT:
with no keystore present the build still succeeds on the debug key and prints a
five-line warning, because a hard failure inside FlutLab is harder to diagnose
from a phone than a line in the log. That warning is the release gate — an APK
built with it in the log must not be given to anyone.

**Consequence, once:** this installs as a new app beside any existing
`com.example.mx_clone`, which keeps its own data and must be uninstalled by
hand. The iADB app must re-grant permission to the new package name.

Verified: 22 Kotlin sources and the Gradle script parse clean (filter
negative-tested — an injected broken paren fires); package declarations 22 + 1
all `com.innocent.media`; no `com.example` left in any built file; whole-tree
diff against +301 shows only the intended files changed and none truncated.

## v1.59.2+301 - The Movies plan, audited against the code (Aug 2026)

Documentation only. No code changed; the eight structural checks and the app
behave exactly as in +300.

The +300 documents described an architecture. This build audits that
architecture against the code that exists, and against what the services
actually charge. **Six things were wrong or missing, and one of them changes the
budget by two orders of magnitude.**

New: **`docs/movies_execution_plan.md`** - the plan to actually work from. Every
stage in order, with the SQL, the exact gate that proves each one, the
client-side work queue, and a six-week schedule.

### Sign-in costs more than the entire rest of the platform

Every plan assumed phone-first sign-in with an SMS OTP. **Supabase does not send
SMS** - phone login needs a third-party provider, and Twilio Verify runs about
$0.10 per verification. At the month-9 projection of 2,500 registered users that
is **$300-500 in year one, against $2/month of infrastructure**: authentication
would be roughly 99% of the cost of running this.

Money is the smaller half. International A2P SMS to Myanmar numbers is not
reliably delivered, and an OTP that never arrives is a sign-up that never
happens.

The resolution is an observation, not a technique: **a human already verifies
the payer's phone number against the real KPay statement before approving a
subscription.** The verification the business needs already happens, at
approval. An SMS OTP buys the same fact earlier, less reliably, and for money.
Three options are laid out; email sign-in costs nothing and is recommended. The
decision changes the schema, so it belongs before the first table.

### Offline downloads had no way to give the player the key

The plan was right about storage - keep the segments encrypted, wrap the key in
the Android Keystore, store only the blob - and silent about the one hop that
matters: **an HLS player reads the key from the URI in the playlist.** Writing
it to disk as a file undoes the wrapping entirely.

The answer was already in this codebase. `stream_proxy.dart`, built so TikTok's
headers could travel with a request, is a loopback server with per-item tokens
and range forwarding. Serve a rewritten local playlist from it whose key URI
points back at itself, unwrap from Keystore on that request, return the sixteen
bytes from memory. The plaintext key never touches a filesystem.

### Two places where the code contradicts its own plan

**The device id is in SharedPreferences.** `movies_access_plan.md` says plainly
that an id there is wiped by "Clear data", the slot frees itself, and the
binding enforces nothing. `device_identity.dart` still uses it.

**`AccessDenial` has two values.** A server 409 `wrong_device` arrives as
`forbidden` and renders as "unavailable" - so a paying customer holding a
replacement phone sees an unexplained error and no route to the self-service
release. The device-recovery work can be built perfectly and stay unreachable.

### Posters and segments cannot share a bucket

The documents said both "the bucket must never be public" and "posters go to a
public path". Both are right, and together they mean two buckets: a private one
for encrypted segments, a public one on a custom domain for posters, the updater
JSON and the APK. Minutes to set up now; tedious once locators are stored.

### Three questions closed by checking rather than guessing

Cloudflare **accepts PayPal** and allows **two payment methods per account** -
so the PayPal being opened works, and the backup-payment launch gate is a real
feature. R2 does require billing information even inside the free allowance, and
some users report a $5 charge at activation. If the method fails, R2 access is
suspended and the data may be deleted after 30 days - which is survivable only
because every master lives in Telegram.

### Everything else

`titles` gains `status` from day one (a kill switch cannot be added under
pressure) and `access_tier` now defaults to `premium` - fail toward locked, so a
row from a script that forgot the column is hidden rather than given away. The
pre-launch checklist gains seven lines, including the one that matters most:
`locator` and `content_key` must be **revoked** from the API roles, because RLS
filters rows and a client can ask for any column it likes.

Updated: `movies_gaps.md` (rewritten, 13 items), `movies_access_plan.md`,
`movies_capacity_model.md`, `movies_platform_plan.md`, `movies_roadmap.md`,
`movies_dataflow.md`, `premium_backend_spec.md`, `client_api_contract.md`,
`project_brief.md`, `maintenance.md`.

## v1.59.1+300 - The Movies backend, planned (Aug 2026)

Documentation only. No code changed; the seven structural checks and the app
behave exactly as in +299.

Five new documents in `docs/`, from a research pass on how the Movies vertical
can run at near-zero cost with the content and audience actually planned.

* **`movies_roadmap.md`** — read this one first. Every decision, in build
  order, with what each step buys.
* **`movies_gaps.md`** — what is still missing for this to work with real,
  paying users. Mostly operational, not technical.
* **`movies_dataflow.md`** — the end-to-end walk: a file on a phone, into
  Telegram, through packaging, to a picture on someone else's screen.
* **`movies_capacity_model.md`** — the numbers for year one.
* **`movies_platform_plan.md`** — which services, and why not the others.
* **`movies_access_plan.md`** — tiers, stream and offline protection, device
  binding.

### Four findings that changed the plan

**Google Play is not an option.** Its policy prohibits apps whose purpose is
sexual content, licensed or not. Distribution is outside Play, which makes an
in-app updater a launch requirement rather than a nicety.

**Telegram cannot serve the video, and Supabase cannot either.** The Bot API
caps downloads at 20 MB and its download URL embeds the bot token; Supabase's
free tier is 1 GB of storage and 5 GB of egress, which two films would
exhaust. Media bytes need Cloudflare R2 — zero egress at any volume, and
Cloudflare's terms explicitly permit video hosted in R2 while restricting
video hosted outside it.

**The binding limit is not what anyone expects.** Not storage, not users, not
video. It is Supabase's 5 GB of JSON egress: 5,000 users browsing at 50 KB a
session is the entire monthly allowance before a single video plays. Narrow
catalogue rows, R2-hosted posters and app-side caching bring the same traffic
under 1 GB — cheap to do now, impossible to retrofit once people depend on it.

**Gating the key rather than each segment is 100× cheaper and no weaker.** The
segments are AES-encrypted, so a leaked segment URL is noise. Two Worker
requests per view instead of 152.

Year-one cost at the projected 1,000 premium users: **about $2/month**. The
2 TB of egress in that month would be roughly $180 on AWS S3.

## v1.59.0+299 - Full-screen tasks, the PIN pad, and a ref held too long (Aug 2026)

Dart only. Minor bump: the PIN pad's layout is rewritten.

### The tab bar sat under four full-screen tasks

Transfer lives inside a `ShellRoute`, so `Navigator.of(context).push` from it
lands in the NESTED navigator — above the page, below the tab bar. Four
full-screen tasks were opened that way and kept Video / Music / Transfer / Me
across the bottom: the file picker, the folder send picker, the QR scanner and
the equalizer.

On the picker that is not cosmetic. A stray tap on a tab walks out of a
half-made selection with no warning and no way back to it. The QR scanner was
worse — a camera viewfinder with a tab bar stuck across it reads as broken.

All four now push on the root navigator. Browsing WITHIN a tab (an artist, an
album, a folder) is the opposite case and deliberately still keeps the tab bar,
the way every music app behaves.

### The PIN pad pushed its own bottom row off the screen

Not a `SafeArea` problem — there was one. `_keySize` reserved 58% of the height
for everything above the keys and then clamped the key size to a 52px floor. On
a short phone those two rules contradict each other: the keypad no longer fits
what is left, the `Spacer`s collapse, and **a `Column` that cannot fit its
children overflows rather than shrinking**. The bottom row and the footer went
off the screen — on a PIN pad, meaning 0 and the confirm key could not be
reached at all.

Now the space above the keys is measured rather than guessed, the floor is
44px (reachable beats comfortable — a key pushed off screen has a tap target of
zero), and if even that will not fit the pad scrolls. It is designed never to
scroll, but silent clipping is the one outcome that is never acceptable here.

The pad also reads `MediaQuery.paddingOf` and applies its own bottom inset.
That is self-correcting — inside a `SafeArea` it reports 0 and cannot
double-pad — and it matters because **two of the four screens hosting this pad
return it without a SafeArea at all**.

### A `WidgetRef` held across a hundred awaits

`MediaIdentityMigrator.migrate` read from `ref` a dozen times, and
`migrateAll` runs it once per file: a fifty-file move is hundreds of reads over
several seconds, with the user free to press Back at any point. A `WidgetRef`
belongs to its widget and throws once that widget is disposed — and a
half-finished migration is worse than none, because the resume position moves,
the playlists do not, and the two disagree permanently.

Everything is now captured before the first await. Notifiers live in the
provider container rather than the widget, so once captured they keep working
whatever happens to the screen. The same pattern was applied to
`purgePublicTraces` and to six per-item loops that called `ref.read` on every
iteration.

Typing those captured fields properly rather than `dynamic` immediately caught
a bug that `dynamic` would have hidden until runtime: `favouritesProvider`
holds a `Set<String>`, not a `List<String>`.

### One more crash, in the player

`player_screen` resolved a chosen playlist with `firstWhere` and no `orElse`,
which throws. The sheet is async, so a playlist deleted from another screen
while it was open would have taken the player down on an otherwise successful
add — the identical defect fixed in the multi-select bar in +297, in a copy
that was missed. Its hardcoded English toast is localised at the same time.

### Audited and clean

Every `firstWhere` / `lastWhere` / `singleWhere` without an `orElse` (the other
four are inside `try`/`catch` or behind a `contains` guard), `.reduce` on
possibly-empty collections (none), and every `Timer` / `AnimationController` /
`TextEditingController` / `ScrollController` / `FocusNode` field against its
`dispose` or `cancel` (no leaks).

## v1.58.2+298 - Build fix, and the checker that should have caught it (Aug 2026)

Dart only. +297 did not compile.

### The bug

`VideoOptionMenu` is a `ConsumerWidget`, not a `State`, so it has no `context`
field — its methods receive `sheetContext`. The four localised strings +297
hoisted were written as `AppStrings.of(context)`, which the analyzer rejects
outright. Fixed to `AppStrings.of(sheetContext)`, which is also the correct
context: it is the one whose `.mounted` those methods already check.

### Why nothing caught it

All six checkers passed on code that could not compile. `compile_risk.py` asks
whether a known project TYPE is used without its import, and `context` is
neither a type nor an import. The same file contains `build(BuildContext
context)` and dozens of legitimate `context` uses inside builder closures, so
the mistake reads as ordinary at a glance.

New `tool/context_scope.py`, now the seventh check. **Two earlier versions of
it were written and thrown away**, useless in opposite directions:

1. Scanning per FILE rather than per class. A file holds both a Widget and its
   State, so State methods were scanned too — nine accusations against working
   code, and a checker that accuses working code gets switched off.
2. Skipping any method whose parameters mention `BuildContext`. The bug is
   precisely a method taking `sheetContext` that writes `context`, so the only
   case worth catching was the one excluded. The parameter has to be named
   exactly `context`.

Two further traps the shipped version handles: `AppStrings.of(context)`
contains the literal text `(context)`, so a naive closure-parameter pattern
matches the very line it should accuse — a real closure parameter is followed
by `=>`, `{` or `async`; and a signature can span lines, which was skipping the
two-line declarations entirely.

Verified both directions before shipping: silent on all 414 files, and it names
the exact line and file when the bug is re-injected.

## v1.58.1+297 - The messages, before real users see them (Aug 2026)

Dart only. A pass over everything the app SAYS, prompted by the app going out
to users shortly.

**Emoji were doing the work of words.** Seven user-facing messages led with a
lock, a pencil or a bin glyph — `🔒 Moved to Private Folder`, `✏️ Renamed`,
`🗑️ Deleted`. It reads as a chat app rather than a tool, and worse, four of
those were hardcoded English shipping to Burmese and Thai users. All replaced
with localised sentences.

**Several dialogs and toasts were bare numbers.** The confirmation for moving
files to the Recycle Bin had a title and a body consisting of the digit `3`.
The vault confirmation was the same. A playlist toast said `12 → "Films"`; the
folder version said just `12`. A number with no sentence around it looks like a
string that failed to load. Every one now uses a proper `{n}` message in all
three languages, and the confirmations say what will happen and how to undo it.

**A playlist toast printed an internal ID.** The folder selection bar showed
the value the sheet returns — the playlist's id, not its name — so a successful
add announced something like `pl_1724…`.

**A crash on a rare-but-real path.** The video bar resolved the chosen playlist
with `firstWhere` and no `orElse`, which throws. The sheet is async, so a
playlist deleted from another screen while it was open would have taken the tab
down on an otherwise successful add.

**Localising those messages nearly added a crash.** `AppStrings.of(context)`
reads an inherited widget from the element, and three of the replaced literals
sat AFTER awaits — on lines whose neighbours already check
`sheetContext.mounted` for exactly that reason. The old literal strings touched
no context, so the translation would have introduced the failure. All four are
now resolved before their first await, the pattern `transfer_screen` already
documents.

**A search matching nothing rendered as an empty list**, which is
indistinguishable from an empty folder: the user reads "these files are gone"
rather than "your query is too narrow", and nothing on screen suggests clearing
it. It now says so, with an icon.

## v1.58.0+296 - The file picker could not search or select all (Aug 2026)

Dart only. `AddFilesPicker` is shared: it is the picker for BOTH "Add Files" in
the Private Folder and "Select files to send" in Transfer, so everything here
lands in both.

**No select-all.** A folder holding two hundred videos took two hundred taps.
Now one, scoped to the CURRENT listing — never the whole device, because a
button that can sweep several thousand files across every folder into a vault
with one press is a way to lose a phone's contents by accident. It respects the
search filter, so "find, then select all" behaves the way it reads.

**No search.** The picker browses the entire device — the Files category alone
can hold thousands of entries in one folder — with no way to type a name.
Matching is case-insensitive and unanchored: people remember a word from the
middle of a filename far more often than its first letters.

Both hook into `_sortFiles`, the single funnel every file list already passed
through, so the counter, the select-all state and what is on screen cannot
disagree.

**Three stale-list bugs that came with it, closed before shipping.** The
rendered list is cleared when entering a folder, leaving one, and switching
category. Without that, "select all" would tick files from the folder just
left — invisible on screen and impossible to notice before committing them to
a vault. The query resets on a category switch too, or a term typed against
Videos makes Apps look empty for a reason nothing explains.

**Back exits search before it exits the picker**, so clearing a query cannot
discard a selection that took a minute to build.

Three hardcoded English tooltips ("Close", "Show hidden folders", "Hide hidden
folders") were localised — they had been shipping in English to Burmese and
Thai users.

## v1.57.1+295 - Tracing what the last four releases actually touched (Aug 2026)

Dart only. No new features. This is the ripple audit of +292 through +294 —
what those changes reached that was not obvious at the time.

### "Hidden" was only hidden in the grids

The Recycle Bin exclusion in +293 covered the video and folder lists. Three
places on the SAME SCREEN kept showing binned videos by name:

* **Continue Watching**, **the Resume button** — both read
  `publicHistoryProvider`, which stripped vaulted entries and knew nothing
  about the bin.
* **The cold-start "Resume X?" prompt** — announced the title seconds after
  the app opened, then cleared its marker, so it fired exactly once at the
  worst possible moment.

Hiding a video from one strip and not the one above it is not hiding it. All
three now honour the bin, and the cold-start prompt also skips vaulted videos —
which it never did.

### Moving a file made it look unwatched

+293's migrator carried the resume position across and DELETED the history
entry, reasoning that a dead entry is worse than none. That was half right and
missed that three views derive from history: the progress bar on every tile
(`watchProgressProvider`), the "recently watched" sort (`lastWatchedProvider`)
and the watched badge (`playedUrisProvider`). So a video the user had merely
reorganised came back looking untouched. The entry is now re-recorded at the
new path first, and only then removed — and not counted as a new play, because
moving a file is not watching it.

**Bookmarks were not migrated at all.** They are the least reproducible thing
here: a resume position regenerates itself the next time the video is watched;
a hand-placed timestamp never does.

### Vaulting left the title in four public lists

+294's Lock in Private Folder cleared history and the resume position and
stopped. Favourites, every playlist holding the video, Watch Later and the
bookmarks list all still named it — and each of those screens is one tap from
the Me tab and prints the title in plain text. A video was hidden everywhere
except the four places that spell out what it was called. New
`purgePublicTraces` removes all four. Nothing is lost that the owner cannot see
after unlocking; the vault keeps its own index.

### A rescan that should never have been there

`BulkActions.hide` called `ref.invalidate(allVideosProvider)`, which discards
the cached library and re-queries MediaStore for every video on the device. The
bin exclusion WATCHES `recycleBinProvider`, so writing to the bin already
rebuilds every dependent list instantly from data in memory. On a phone holding
thousands of files that invalidate turned a free update into a full rescan. The
one in "Rebuild thumbnails" is kept and now explains itself: nothing observable
changes there, so without a rescan the tiles keep painting the frames they
already hold.

## v1.57.0+294 - Selection mode, finished (Aug 2026)

Dart only. Minor bump: folder selection gains capabilities it never had.

### The two modes had drifted into different apps

Selecting three folders means "every video underneath these three", so the
actions are the same actions. They were not:

| | Videos | Folders |
|---|---|---|
| Move / Copy | since +292 | **absent** |
| Add to playlist | yes | **absent** |
| File Transfer | **absent** | **absent** |
| Lock in Private Folder | **absent** | yes |
| Properties | count only | **absent** |
| Bottom action bar | since +292 | **absent** |

Folder mode had four icons in an AppBar and nothing else. Video mode's overflow
offered three items. Neither could send a selection to the Transfer tab — on an
app whose whole third tab is file transfer.

New `BulkActions` holds one implementation of each, and every bar calls it. An
action can no longer be real in one selection mode and theatre in the other,
and a fix lands in both. Both modes now have a bottom bar of seven actions and
a complete overflow.

### What each action actually does now

* **Lock in Private Folder** verifies identity BEFORE anything moves — without
  that, anyone holding an unlocked phone could bury files where the owner
  cannot find them — and refuses when no PIN exists rather than making someone
  invent one under time pressure. It then erases the public trail: a vaulted
  video whose history entry survives still shows in Continue Watching, by name,
  on a screen anyone can see.
* **File Transfer** queues the files and lands on the Transfer tab in Send
  mode. `adb://` videos are pulled to a local copy first, because the LAN
  server cannot read another app's private directory.
* **Properties** reports count, folders, total size and total duration. The old
  one showed the count — a number the title bar was already displaying.
* **Share** is bounded to 50 files. Handing a share sheet several hundred is
  how it stops responding, and nobody means to share four hundred videos.

### A selection is no longer thrown away on cancel

Every action used to clear the selection whether or not it did anything, so a
cancelled destination picker or a dismissed vault prompt meant picking all
twenty files again. Actions now report success and the selection survives a
cancel.

### Folder video matching

Videos are matched on exact `folderPath`, never a path prefix. A prefix match
would pull `/Movies 2` in when the user picked `/Movies` — and moving a folder
nobody selected is not a mistake that can be undone.

## v1.56.1+293 - The Recycle Bin never hid anything (Aug 2026)

Dart only. Found by auditing +292 before it was ever run.

**`recycleBinProvider` had one reader: the Recycle Bin screen.** Three places
wrote to it — the per-video option menu and both multi-select bars — each
reporting "Moved to Recycle Bin", and the video then stayed exactly where it
was in every list. The screen even offered "restore", implying there was
something to restore from. This predates the multi-select work; +292's new
Hide inherited it.

Both list providers now exclude binned URIs, and `filteredFoldersProvider`
corrects the counts — otherwise a folder reads "12 videos" and opens showing
10, and a folder whose contents are all binned sits in the list forever with
nothing inside it. Matched on the normalised URI, because the same file arrives
as `content://`, `file://` or a bare path depending on which scanner found it.

### Moving a file threw away everything saved about it

Every piece of per-video state is keyed by the video's URI, and a file's URI is
its path. So a move silently detached all of it: the resume position, the
Continue Watching entry (still listed, now pointing at nothing), favourites,
Watch Later, and every playlist slot.

None of it is visible at the moment of the move. The user sees "Moved 3" and
finds out days later, one video at a time — the worst way to discover data
loss, because it cannot be connected to what caused it. And organising a
library is the single most likely reason anyone selects twenty files at once,
so the operation that punished organising was exactly the wrong one to ship
un-migrated.

New `MediaIdentityMigrator` re-keys all of it, driven by an old-to-new path map
`FileOpsService` now returns. **Rename had the identical defect and is fixed
too.**

### Also in this build

* **Sidecars follow their video.** A `.srt` beside a file IS that file's
  subtitles — the player finds it by name. Leaving it behind silently turned
  subtitles off for a video that had them and left an orphan behind. Matched on
  the exact stem only, and the sidecar follows the video's final name including
  any " (2)" the collision rule added.
* **Removed a per-file subprocess.** The free-space precheck spawned `stat`
  once per file, on a platform where process spawning is restricted and slow,
  to answer a question the copy already answers: running out of space produces
  a short file, and the length check catches every short file, deletes the
  partial and reports it.
* **Selection actions reached the folder screen.** Long-press already worked
  inside a folder, so a user could enter selection mode there and find no way
  to act on it. Its "select all" is scoped to the folder being viewed.
* **Back leaves selection mode inside a folder**, as it already did on the
  Local tab. Without it the screen popped with the selection still set, so the
  tab underneath came up in selection mode holding items the user could no
  longer see — and Move would then have acted on files from a folder they had
  just left.
* `ref` is no longer touched after the await chain in a move without a
  `mounted` check first.

## v1.56.0+292 - Multi-select: a real one (Aug 2026)

Dart only. Minor bump because Move and Copy are new capabilities, not fixes.

### What was there before

`SelectionAppBar` existed and looked complete. Most of it was theatre:

* **Play** called `Navigator.pushNamed('/player')`. This app is routed
  entirely by GoRouter and registers no such route — the primary action of the
  whole mode could never have worked.
* **Hide** showed "N videos hidden" and hid nothing. It invented a concept no
  other part of the app knew about.
* **Rebuild thumbnails** showed "Rebuilding..." and rebuilt nothing.
* **Share** told the user to go and use a different menu instead.
* **Play using HW / HW+ / SW** carried a comment about storing a decoder
  override; no code stored anything.

Reporting success for work that did not happen is worse than not offering the
action, because people act on it — someone who "hid" a file and then handed
their phone over was told the file was hidden.

Every one is now wired to an implementation that already existed elsewhere in
the app: `context.push(Routes.player, extra: ...)` like every other play site,
`Share.shareXFiles` so the FILES are shared rather than meaningless path
strings, and the Recycle Bin — this app's real soft-hide, already filtered out
of every list and restorable from Me.

### Move and Copy

New `core/services/file_ops/file_ops_service.dart`. Not a wrapper around
`File.copy`; the failure modes are the whole job:

* **`File.rename` only works inside one mount.** Internal storage and an SD
  card are different mounts, so a move between them throws — and the obvious
  fix, catch-copy-delete, deletes the source even when the copy was truncated.
  Here the copy's length is verified against the source's BEFORE the original
  is removed.
* **If the delete then fails**, the copy is kept and the file is reported as a
  failure. Two copies is recoverable; none is not.
* **Copying a file onto itself truncates it to zero** — `File.copy` opens the
  destination for writing before reading the source. Checked, including for a
  destination that resolves back through a symlink.
* **Free space is checked before a large copy**, because filling the last of
  someone's storage mid-batch leaves a partial file and an unusable phone.
* **Collisions are asked once for the whole batch** (keep both / skip /
  overwrite). Prompting per file means fifty answers to the same question,
  which is how people stop reading it.
* Long names are clamped to the filesystem's 255-byte component limit, trimming
  the stem and never the extension — a video that loses its `.mp4` stops being
  recognised as a video.
* Both ends are handed to the media scanner. Without the ORIGINALS in that
  list, a moved file leaves a ghost in MediaStore that other apps try to open.

Move respects Settings → General → "Allow editing"; Copy does not, because
copying modifies nothing.

### The bar moved to the bottom

Seven actions were in the AppBar's `actions:` row. A phone fits three or four
before Flutter drops the rest, so some were simply invisible — Delete among
them. The top bar now carries what is selected (`2 / 99`, because the
denominator is what tells you whether "select all" is worth pressing) plus Play
and the overflow; the actions live in a bottom bar with room for them, with the
destructive one furthest from where the thumb rests.

"Select all" reads `filteredAllVideosProvider` — the same provider the list is
built from — so it can never select something the current filter is hiding.

### Also

`ThumbnailCache.invalidate` / `invalidateAll`: a targeted drop, in memory and
on disk. `clear()` was the only tool available, and using it to refresh one
tile regenerates every thumbnail in the library.

The bulk Recycle Bin path no longer falls back to `allVideos.first` when a
lookup misses. It did, then relied on a follow-up equality check to undo it — a
bin entry for the wrong file was one edit away the entire time.

## v1.55.18+291 - Auditing the audit: five holes in +289's own fix (Aug 2026)

Dart only. Every item here is a defect in the previous two releases, found by
re-reading them rather than by a report.

**The +289 ephemeral flag closed resume, the crash marker and history — and
missed four more paths that write the address down or hand it out.** Same bug,
four more hats:

* **Share was a paywall bypass.** `Share.share(widget.videoUri)` sent the
  signed premium URL to WhatsApp or Telegram, where anyone receiving it could
  watch until the signature expired. The URL is signed precisely so it cannot
  be passed around; a share button undid that in one tap.
* **Favourites and Playlists** stored the signed URL as the entry key — an
  entry that can never match again, in a list that is meant to be permanent.
* **Transfer** treated it as a file path.

All four now refuse for ephemeral playback with an explanation, guarded in the
handler rather than the menu so no route reaches them.

**The +290 renewal made `widget.videoUri` a lie.** A renewed stream plays from
a different URL than the one the screen was pushed with, and three places still
asked the widget instead of the controller: both floating-window activations
handed the little window a dead address, and the adopt check on expanding back
compared against the original — so it refused to adopt and REOPENED a URL that
had expired. Playback restarted from zero on a link that could not work. Those
three sites now use the live URI.

Written down because the shape generalises: introducing a mutable "current
address" into a screen whose `widget` field was previously the only answer
means every existing reader of that field has to be re-examined, not just the
ones the new feature touches.

## v1.55.17+290 - The header handoff did not do what its own comment said (Aug 2026)

Dart only. Continues the audit in +289.

**`MediaKitPlayerService.attachHeaders` was documented as "keyed by the exact
URL and consumed on use, so it cannot leak onto an unrelated file". It was
neither keyed by the exact URL nor consumed.** It matched on HOST inside a
sixty-second window and stayed armed until it expired, which is two faults:

* **Leakage.** Any other video opened from the same host inside that window
  inherited the downloader's headers, cookies included.
* **Silent loss on retry.** The window expired on wall-clock time, so a
  reconnect more than a minute into a film reopened the URL with no headers and
  failed for a reason nothing reported — the exact shape of bug that gets
  blamed on the network.

Now two-stage. A PENDING arming is still host-matched in a short window, purely
to survive a redirect between the URL the downloader resolved and the one
libmpv opens. The first playback that matches CLAIMS it: the headers become
that stream's live headers, bound to its exact URI, and the arming is cleared
so nothing else can take it. Live headers are keyed on the URI rather than the
clock, so a reconnect of the stream that is playing keeps them however long it
has been running, and `open()` releases them the moment a different video
starts.

Also new: `docs/media_kit_upgrade.md`. The `media_kit_video: ^1.2.4` pin is why
this project hand-manages screen-off playback, so the upgrade path is now
written down with the versions checked rather than remembered — `1.3.0` is the
`SurfaceTextureEntry` to `SurfaceProducer` migration, `1.3.1` is where to
land, `2.x` waits. It also records two traps: Flutter's own guidance puts the
floor for that API at 3.24 rather than the 3.22 this pubspec declares, and the
`1.3.0` refactor can drag `screen_brightness` past the `^0.2.2+1` that
`BrightnessService` is written against. And a staging order, so the workaround
and the rendering path are never removed in the same build.

## v1.55.16+289 - Audit: playback races, and a signed URL that was being written down (Aug 2026)

Dart only. Ten fixes from one audit pass over the Video Hub and the player
engine. Nothing here is a feature; every item is something that was wrong.

### The two engine races (worst first)

Detaching and reattaching the video output are each several awaited property
writes, and nothing stopped one running inside the other. Two orderings were
reachable, both leaving the app playing sound over a black picture until the
next `open()`:

* `Timer.cancel()` does not abort a callback already part-way through its
  awaits. The detach watchdog checked its flag once, at the top, then awaited
  twice — so a reattach landing between those awaits was immediately undone by
  the tail of the tick writing `vo=null`. The watchdog covers the first five
  seconds of every background transition, which is exactly where "power button
  pressed by mistake, pressed again" lands.
* Screen off then straight back on. The detach had written `vo=null` and was
  still awaiting; the reattach ran to completion; the detach's remaining writes
  landed on top of it and armed a watchdog whose flag had already been cleared.

Fixed with a surface generation counter plus a single-flight chain: whole
transitions can no longer interleave, and any write still in flight from a
superseded transition abandons itself instead of finishing on top of the one
that replaced it. `dispose()` invalidates in-flight work the same way.

### A signed URL was being persisted, and the resume key changed every play

Video Hub playback is handed a short-lived signed URL. The player wrote it to
three places — the crash-resume marker, the resume position, and watch history
— which is three bugs at once: resume could never match twice, so every title
restarted at 00:00 and Continue Watching filled with duplicates; catalogue
titles surfaced on the **Local tab**, in front of the age gate rather than
behind it; and tapping one opened a URL that had expired hours earlier.
`session_store.dart` already carried the rule this broke: never store a signed
media URL.

New `ephemeral` flag, carried from `playback.dart` through the route to the
player, and deliberately separate from `isPrivate` (which also forces a pause on
every background transition — right for a vault item, wrong for a stream). It
says only: do not write this string down.

### An expired link can now be replaced instead of retried

Both recovery paths — the automatic reconnect and the Retry button — reopened
the same address, which cannot work once a signature has expired. libmpv
re-requests on any seek outside its buffer, so a film longer than the URL's
lifetime simply stopped part-way through, blaming the network.

New `core/services/video_player/stream_renewal.dart`: the player is handed a
closure, never a grant, so it can ask for a fresh URL without learning what
entitlement is and `playback.dart` stays the only place a `PlaybackGrant` is
interpreted. A renewal is a new server request, so a lapsed subscription is
refused rather than extended.

### The rest

* **The floating window dropped FLAG_SECURE.** The claim was held by the player
  screen and released in its dispose — but sending a video to the little window
  pops that screen, so protected content carried on playing, screenshot-able
  and visible in the recents thumbnail. The window showing the picture now
  holds the claim, and expanding back restores every flag: that push
  reconstructs the player screen, so anything missing from the map was silently
  reset to its default.
* **`SecureScreenService` defers dropping the flag** by 300 ms. Taking the
  claim is still immediate. A hand-off releases before the successor acquires,
  so the counter touches zero while protected content is on screen the whole
  time — and re-applying the window flag re-creates the surface on some
  devices.
* **The dev "approve my own payment" button shipped in release builds.** One
  tap granted thirty days. Now behind `kDebugMode`, so the tree-shaker removes
  it from a release binary entirely.
* **Session tokens moved to keystore-backed storage.** They were in plain
  SharedPreferences on the argument that the access token is short-lived — true
  of the access token, silent about the refresh token stored beside it, whose
  entire job is to mint new ones. Android's Auto Backup uploads
  SharedPreferences to Google Drive and the device-transfer flow copies it to a
  new handset, so the long-lived half of the session was leaving the phone by
  two channels. `FlutterSecureStorage` is already excluded from both by the
  vault's backup rules, and was already a dependency — the reason previously
  given for not using it no longer held.
* **A wrong device clock could refuse a grant the server had just minted.**
  `isGranted` no longer consults the local clock: the signature is checked by
  the server, which has the only clock that counts, and a genuinely dead URL
  now has a renewal path. A zoneless server timestamp is also read as UTC
  rather than local — the error would have been six and a half hours here.
* **The age gate's refusal was a one-tap reset.** Reconsidering now asks for an
  explicit confirmation. Still a locked door on a ground-floor window; the point
  is that it no longer advertises the window.
* **Every poster flashed its placeholder on every rebuild.** A `FutureBuilder`
  built inside `build` gets a new future each time, and a fresh future always
  starts in the waiting state. Artwork resolves synchronously now
  (`resolveImageUrlSync`); the async path stays for an implementation that
  genuinely has to look something up.
* **A signed URL is never drawn on screen**, whatever
  `styleShowSourceUrl` says — the whole string is the credential.

### One checker was fixed, because it had stopped working

`tool/contract_conformance.py` let its return-type group match pure whitespace,
so the continuation line of an expression body read as a member declaration.
Any adapter that DELEGATED to a member appeared to declare it, and the
`implements` completeness check — the reason that file exists — was satisfied by
the call site. Found by a negative test that refused to fire.

Also worth knowing: `check_args.py` deliberately skips `obj.method(...)` calls,
because the receiver may belong to any package. The new named arguments in this
release are therefore covered by no automated check and were verified by hand.

## v1.55.15+288 - Handover: the project explains itself now (Aug 2026)

Documentation only. No Dart changed.

The problem this solves: every new conversation started with the project being
re-explained - what it is, what was decided, what is a stub, which mistakes
already cost a build. That is a tax on the owner and a source of drift, because
a re-explanation is never quite the same twice.

### `docs/project_brief.md`

One document that states the project as DECIDED, not proposed:

* what Innocent is, and the constraint that shapes everything - FlutLab
  copy-paste, no local compiler
* the Video Hub: why there is no Adult category (a tab matching everything is
  not a filter, so the 18+ decision moved to the door)
* the three-tier model as a table, and why registering buys something real
* KPay-outside-the-app with human approval, and why the confirmation screen
  never says "you are premium"
* the four seams that must not be broken - one storage seam, one access
  decision, one playback path, one token file
* what is built, what is a stub, and what comes next in order
* the eight rules that each cost a broken build or a wrong-looking screen

### The rest of the map

The README now opens with a table pointing at all five documents and the
verification order, so the brief is found without being looked for:

    FlutLab Analyzer  ->  python3 tool/check.py  ->  Build

| Document | Holds |
|---|---|
| `docs/project_brief.md` | the whole picture |
| `docs/maintenance.md` | how to verify, weaknesses, roadmap |
| `docs/premium_backend_spec.md` | schema, RLS, playback function, security |
| `docs/client_api_contract.md` | every endpoint the app already calls |
| `tool/README.md` | the structural checks |

Together with `tool/` moving into the repo last release, the project now
carries its own instructions, its own quality gate and its own history. Hand
someone the zip and they have everything - which is the only handover that
survives a machine being wiped.

**No code changed. Still UNTESTED on device - Analyzer first.**

## v1.55.14+287 - The toolchain moves into the repo (Aug 2026)

No new screens. This release is about the thing that let a broken build ship,
and about what happens to this project when nobody is looking at it for a
month.

### The verification toolchain lived outside the project

Six checkers, rebuilt from scratch every session, on one machine, invokable by
one person. **A quality gate only one person can run is not a gate.** They now
live in `tool/`, behind one command:

```bash
python3 tool/check.py
```

### The order that actually works

The failed build was not caused by a missing check. It was caused by going
straight to Build:

    1. FlutLab -> Analyzer tab      types, overrides, arity      seconds
    2. python3 tool/check.py        structure, architecture      seconds
    3. FlutLab -> Build             the truth                    minutes

FlutLab's Analyzer 2.0 runs a real language server that understands every
object in the project and every imported library - it reports the same errors
the compiler will, without the wait. `tool/check.py` reads source as TEXT and
knows nothing about types. Neither replaces the other, and skipping step 1 is
what turned a two-minute mistake into a two-minute wait to hear about it.

### A seventh checker, for the errors that remained

`contract_conformance.py` compares declarations against their uses ACROSS
files, which is where the rest of the failed build lived:

* a class that `implements` an interface declares every member of it
* those members have the same positional count and named-parameter set
* constructor calls pass an argument count the constructor accepts

Negative-tested by reproducing the real failures: a renamed member, a drifted
named parameter, a changed positional count, and the exact
`RowFacetsArg(widget.rowKey)` that broke build 285. Four out of four.

It found two of its own bugs against known-good code first. Blanking string
literals during stripping destroyed the very thing it was counting -
`f('a', 'b')` read as zero arguments - and optional positionals `[this.x = '']`
were excluded from the count, so a legal call looked like an overflow. **A
checker that accuses working code gets switched off**, so both were fixed
before the rule was kept.

### Lints: seventeen, not twenty-one

Added the rules that catch real bugs - `annotate_overrides`, the
unrelated-type collection traps, null-check discipline, `await_only_futures`.

Deliberately did NOT add `prefer_const_constructors` and three like it. Each is
a fine rule; together they would fire hundreds of times across 273 files. The
Analyzer badge currently shows a number small enough to read. Bury four real
errors under six hundred style notes and the badge becomes wallpaper and the
tab stops being opened - which is the one thing standing between a typo and a
failed build. They go on one at a time, each with a cleanup pass.

### First tests for the feature

`test/video_hub_logic_test.dart` - 25 tests over the pure logic, chosen because
each is quietly wrong-able and none would fail loudly in review:

* `ViewCount.compact` boundaries, including that 999,999 reads `999K` and never
  `1.0M`
* the three-tier capability table, and that the free-still allowance only ever
  increases with tier
* that an EXPIRED subscription is `registered`, not `premium`
* that photo ordinals count photos and ignore interleaved clips, so "first 3"
  means the same thing whatever the album contains
* that `ContentFilters.signature` is order-independent - it is a paging cache
  key, so {A,B} and {B,A} must not fetch twice

Every API they call was verified to exist with that exact signature (24/24),
and every numeric expectation was simulated independently before being written
down.

### docs/maintenance.md

The honest state of the project, worst weakness first: nothing has been
compiler-verified in this workflow; there is no backend; images have no disk
cache; there is no crash reporting; `app_strings.dart` is past 4,000 lines.
Plus the conventions that were learned the hard way - never edit a signature
with a regex across many files, advisory tables stay advisory, fail toward
locked, absent is not zero.

**Dart-only. Still UNTESTED on device - run the Analyzer first this time.**

## v1.55.13+286 - Build fix, and the checker gap that let it through (Aug 2026)

285 did not compile. Owning that first: I removed a parameter from eleven files
with a regex, the checkers reported clean, and the mistake reached the device.

### What the regex did

Stripping `{required bool includeRestricted}` from a signature left:

```dart
Future<VideoContent?> getFeatured(());        // was ({required bool x})
Future<List<VideoContent>> search(            // was (String q, {required bool x})
    String query, {
});
```

**Both have perfectly balanced parentheses**, so the balance check waved them
past. The rest was ordinary fallout: references to the deleted identifier left
in eleven bodies, and a provider block that got pasted twice because a slice
index was wrong - `entitlementProvider` and `accessPolicyProvider` each declared
in the same file, four hundred lines apart.

All repaired by hand this time, not by regex.

### Two new checks, scoped so they cannot cry wolf

`verify.py` gained the two shapes that broke the build:

* **empty parens in a declaration** - `getFeatured(())`
* **empty named-parameter list** - `search(String q, {})`
* and **duplicate top-level declarations within one file**

Scoped to DECLARATIONS deliberately. `f(())` passes an empty record and
`f(a, {})` passes an empty map: legal as CALLS, meaningless as parameter lists.
The first attempt was not scoped, immediately accused `replaceFirst('{n}', '$n')`
in app_strings - the string stripper blanks literals and leaves `( , )` behind -
and a rule that accuses working code is a rule that gets switched off. The
narrow version reproduces the exact build failure and leaves the tree clean.

A contract-vs-implementation completeness check ran too: all eleven
`ContentRepository` members and all nine `AccountRepository` members are
implemented in both adapters.

### Everything from the previous instructions, re-verified

A 25-point audit against every instruction from the last several rounds - adult
category removed, gate at the door with a real refusal path and versioned
consent, nav-bar insets on six scrollables, avatar replacing the overflow menu,
Bookmarks and Downloads, Google plus phone sign-in, views replacing the rating
star, photo/video counts that are server-supplied so an album can grow, the
filter-chip layout fix, ripple above the artwork, haptics, three viewer tiers,
anonymous install id, design tokens. 25/25.

Ten injected faults, ten caught.

**Dart-only. The previous build did not compile; this one is repaired but is
still UNTESTED on device.**

## v1.55.12+285 - The door, the navigation bar, and counts that grow (Aug 2026)

### The Adult category is gone

Not hidden - removed. The whole catalogue is adult now, so a category for it
would have been a tab that always matches everything, which is not a filter but
a formality people learn to tap through. `ContentCategory.adult`, the
section toggle, the gate store and `includeRestricted` threaded through eleven
files all went with it.

The 18+ decision moved to the DOOR, which is where every adult platform puts
it and where it actually means something.

### The gate

A full screen in front of the hub, with three deliberate properties:

* **Two buttons, not one.** "I am 18 or older" beside "I am under 18" forces an
  answer. A single Enter under some fine print is a door with a sign on it, and
  everyone walks through signs.
* **The refusal is real.** Answering under-18 does not reopen the question next
  launch. It is a locked door on a ground-floor window - anyone determined gets
  past - but a question that visibly means nothing teaches people to lie to
  every other question the app asks.
* **The terms are ON the screen**, scrollable, not behind a link. A link is a
  way of not showing someone something while being able to say you did.

Six commitments, each a separate line because a paragraph gets skimmed and a
list gets read: age, **voluntary entry** (nobody sent, asked or pressured you,
and you are not doing this for someone else), legality where you are, not
showing it to minors, no copying or redistribution, and that all performers are
consenting adults.

Consent is VERSIONED. A consent recorded against terms that have since changed
is not consent to the current terms; bumping the version re-prompts everyone.
It is recorded server-side too - for anonymous viewers as well, whose
acceptance is exactly the one worth having on file.

### The navigation bar was covering the posters

Android 15 enforces edge-to-edge for every app targeting API 35: the window
spans the whole display and draws behind the system bars. The hub used
`SafeArea(bottom: false)`, so the last row of posters ended underneath
Recent/Home/Back.

The wrong fix is a global `SafeArea(bottom: true)` - it pushes the whole view
up and leaves a dead band the artwork never reaches. The fix the Flutter issue
thread converged on, after every global approach failed, is per-scrollable:
run edge to edge and give the CONTENT bottom padding equal to the inset. Six
scroll views now do that through one helper.

`viewPadding`, not `padding`: the latter drops to zero while the keyboard is
open, so a form would lose its clearance exactly when it is being typed into.

### An avatar where the three dots were

"⋮" is where features go to be forgotten - no clue what is inside, nobody opens
it twice. The avatar is a destination people reach for by habit, and unlike a
column of dots it SHOWS state: hollow when signed out, filled when signed in,
an accent ring when paying.

Behind it: account, subscription status, payment history, and now **Bookmarks**
and **Downloads** - above the receipts, because someone opening this screen is
far more often looking for what they saved than for a receipt.

Sign-in offers **Google first**, then phone. For an adult app, preferring not
to hand over a number is a real and reasonable position, not an edge case.
Google is not wired yet and says so plainly rather than failing silently.

### Counts that survive the catalogue growing

Cards now show stills and clips with their own glyphs, opposite the view count
on the same baseline - two facts of equal weight, balanced rather than stacked.

`photoCount` and `videoCount` are SERVER-SUPPLIED fields, never derived from the
loaded album, because a grid card has no album and because the album grows: the
operator adds stills and clips to a title long after publishing. A count taken
from whatever the client happened to load would be a different number on every
screen.

**Absent draws nothing, never zero.** A reader cannot tell an honest zero from
an unfilled column, and only one of those is true.

### Four real bugs, caught by the checkers

Stripping `includeRestricted` with a regex left three dangling `),` - files
that read perfectly and would not have compiled. And the new insets helper was
called `SystemInsets`, which `core/utils` already owns for the immersive
player's nav-bar snapshot: two different problems, one name, and it would have
compiled until the first file imported both. Renamed `VhInsets`.

Ten injected faults, ten caught.

**Dart-only. UNTESTED on device.**

## v1.55.11+284 - Three viewer tiers, and where anonymous people go (Aug 2026)

### The problem with booleans

Access was decided by `isSignedIn && entitlement.isActive`, evaluated
separately in ten widgets. That is how a product ends up treating a registered
free user as anonymous on one screen and as premium on another - and it gets
worse with every screen added.

`ViewerTier` replaces it: **anonymous < registered < premium**, one ordered
value, derived in exactly one place. `Viewer` carries it along with the
account, the entitlement and the install id, and `viewerProvider` is the only
thing screens read. Every `entitlementProvider` reference in the presentation
layer is gone.

The order is load-bearing, so "at least registered" is a comparison rather than
a hand-written pair of conditions - and inserting a tier later re-bases every
check at once.

### Anonymous viewers are viewers

They had no identity, so their taps counted for nothing. Now every request
carries `x-install-id`: 128 random bits generated once per install and kept in
app-private storage.

That is precisely what Android's own guidance prescribes for signed-out
analytics - a privately stored GUID or Firebase Installation ID. Explicitly NOT
IMEI or serial (a `SecurityException` since Android 10), not `ANDROID_ID`
(app-scoped and regenerated on reinstall anyway), not the advertising id.

Two roles, one value, deliberately: before sign-in it identifies the VIEWER, so
anonymous activity has somewhere to land; after sign-in it identifies the
DEVICE for the concurrency cap. A second id would only be a second thing to
keep in step.

### The thing that would have hurt later

Sign-in now calls `claimAnonymousHistory(installId)` so the server can re-key
what was watched before registering.

Without it, **registering is the moment a person's history disappears** - the
worst possible first impression for an account, and entirely avoidable.
Best-effort by design: a merge failure must never fail a sign-in that
otherwise worked.

### A ladder, not a cliff

`CapabilityMatrix` now has three rows:

| | Anonymous | Registered | Premium |
|---|---|---|---|
| Browse, posters, synopsis | yes | yes | yes |
| Preview stills | **3** | **5** | all |
| Marked preview clip | yes | yes | yes |
| Watchlist + synced history | no | **yes** | yes |
| Full album | no | no | yes |
| Play a premium title | no | no | yes |
| Offline download | no | no | yes |
| Quality ceiling | 480p | 480p | source |
| Concurrent streams | 1 | 1 | 2 |

Registering buys a watchlist and history that follow the account - things that
are account-bound by nature, so they cost nothing to give away and turn
"sign up" into an offer rather than a toll gate. Two small steps convert far
better than one leap from nothing to pay-me.

The table is still explicitly ADVISORY: it decides whether to draw a lock,
never whether to hand over a file. `security_invariants.py` still forbids any
data adapter from consulting it.

### Views are segmented

`recordView` carries the tier, so the numbers can answer the question that
actually matters commercially - whether the people who never pay are the ones
driving them. Reported, never trusted: when a JWT is present the server must
prefer what the JWT and the subscription table say.

`docs/client_api_contract.md` now specifies the tier model, the header, the
claim RPC and the de-dupe rule.

### Verification

Eleven injected faults, eleven caught. The checker earned its keep again: it
caught five missing `account_provider` imports the moment call sites moved to
`viewerProvider`.

**Dart-only. UNTESTED on device.**

## v1.55.10+283 - View counts, and two silent bugs (Aug 2026)

### The filter sheet was a LAYOUT BUG, not a style problem

Every genre sat on its own full-width row. That was not a design choice that
went wrong - it was `Container`:

> A Container with a non-null `alignment` and no width **expands to its
> maximum constraint.**

Inside a `Wrap` the maximum constraint is the whole row, so each chip took a
line to itself and the sheet became a stack of grey bars. Sizing by padding
instead lets a chip be exactly as wide as its label, which is the thing that
lets a Wrap wrap. The same pattern was audited across the feature; the other
seven sites are all inside unbounded parents or genuinely want full width.

Section labels are now small caps, so they read as structure rather than as
another option competing with the chips beneath them.

### Rating star -> view count

Ratings are gone from the UI. A rating answers "was it good?", which needs a
crowd to have voted before it means anything, and a new catalogue has nobody.
A view count answers "are people watching this?", which is true from the first
tap.

**What counts as a view is now written down**, because a counter without a
definition is a random number with an eye icon next to it, and every platform
picks a different rule - Facebook counts almost instantly, LinkedIn at two
seconds, YouTube at thirty. Here:

> the detail screen being opened, by anyone, free or premium - once per title
> per app session.

Not a scroll past the card, not a second look a moment later. The app de-dupes
per session; the server should de-dupe per account per day. `recordView` is
fire-and-forget and swallows failures: a lost count is worth nothing next to a
screen that would not open.

`ContentSort.rating` and the "Top rated" row went with it. An option that sorts
by a number the user cannot see anywhere is a control they cannot predict, and
one unpredictable control makes the whole filter bar feel untrustworthy.

Formatting is one definition used everywhere - `842`, `4.1K`, `37K`, `1.2M` -
with truncation rather than rounding, so 999,999 reads `999K` and never
`1.0M` while the catalogue still says it is under a million.

### Tapping a poster did nothing

The card's `InkWell` splashed on its Material **ancestor**, which is behind the
artwork - so every tap on every poster was completely silent. The ripple now
lives inside the clipped stack, above the image. Touch feedback is most of what
separates an app that feels responsive from one that feels like it missed the
tap, and its absence is felt without being noticed.

Selection haptics added to the category bar and the filter chips, for the same
reason.

### Verification

Eleven injected faults, eleven caught. Two injections had to be re-anchored
after failing to apply - a negative test that "passes" because nothing was
injected proves nothing.

**Dart-only. UNTESTED on device.**

## v1.55.9+282 - The client half, finished and ready to connect (Aug 2026)

App-side only, as asked. Everything that talks to a server is written; nothing
server-side is. Filling in `BackendConfig` is the whole switch.

### The gap the audit found

With manual KPay approval the sequence is: pay, leave the app, an operator
approves, come back. **Nothing refreshed on return** - the app still said
"free" until a manual pull or a restart. That is precisely the moment a paying
customer decides they were cheated. The hub now re-reads entitlement on resume,
rate-limited to once per 20 seconds because Android delivers `resumed` for
things that are not a return to the app (a dismissed dialog, the notification
shade) and refetching on each would be a request storm for no information.

### The API layer

| File | Job |
|---|---|
| `backend_config.dart` | the only file to edit to go live |
| `api_exception.dart` | typed failures, so a paywall is never an error screen |
| `session_store.dart` | tokens, with an honest note about where they live |
| `api_client.dart` | headers, timeouts, refresh, error mapping |
| `api_account_repository.dart` | auth, entitlement, KPay requests |
| `api_content_repository.dart` | catalogue, and the playback call |

`docs/client_api_contract.md` states every path, payload and status code the
app already sends, so the backend can be built to match rather than guessed at.

Decisions worth keeping:

* **Unconfigured falls back to the demo stub, which grants nothing.** A build
  with a missing URL shows an empty-handed catalogue rather than quietly
  handing out content. The fallback direction is the safe one.
* **One refresh per 401, then give up.** Refreshes are serialised: six requests
  failing on a stale token produce one refresh, not six that race and
  invalidate each other.
* **A network failure never signs the user out.** Offline is not logged out.
  Only a server-rejected refresh clears the session.
* **`select=*` appears nowhere.** Columns are listed explicitly and the storage
  locator is not among them.
* **Unknown `access_tier` reads as PREMIUM; unknown request status reads as
  PENDING.** Both defaults fail toward locked. A schema typo then hides content
  (visible, recoverable) instead of unlocking it (silent, expensive).
* **The client sends no assertion about its own rights** - there is no field
  for one. It sends a title id and a device id and receives a verdict.

### Two bugs caught before they shipped

**A duplicate map key.** `getCatalogue` built its query with `'category'` twice
- once for the chosen category, once to exclude adult. A Dart map literal keeps
the LAST value, so asking for Movies silently became "anything that is not
adult". It reads perfectly in review.

**A checker that flagged correct code.** `security_invariants.py` reported the
new API repository for handling a `PlaybackGrant` - but producing grants is
what implementing the repository MEANS. The rule had exempted a hand-written
list of filenames, which is a rule that needs editing every time a file is
added, and a rule like that gets silenced rather than maintained. Rescoped to
its actual intent: no file under `presentation/` may interpret a grant.

### Verification

Eleven injected faults, eleven caught, across five checkers - including the
tear-off and provider-import gaps closed in 281. Tree diff: nothing missing,
nothing shrunk.

**Dart-only. UNTESTED on device. No backend exists yet - with `BackendConfig`
empty the app runs entirely on the demo stub, which refuses every playback.**

## v1.55.8+281 - Capabilities, device binding, and invariants the build enforces (Aug 2026)

Answering the right worry: what stops someone intercepting the server's reply
and walking through the paywall?

### The answer is not a stronger channel

Flutter TLS pinning is **known to be bypassable** - `libflutter.so` handles TLS
inside the engine, and public tooling patches that binary to disable
verification. Play Integrity does not close it either; it reports on the device
and explicitly does not prevent man-in-the-middle. Both are worth adding. Build
on neither.

What decides whether interception matters is WHAT THE REPLY CONTAINS:

| Server returns | Attacker on the wire |
|---|---|
| `{"isPremium": true}` - a PERMISSION | flips false to true, is in |
| a signed, expiring URL - a CAPABILITY | gains nothing |

In the second case there is no boolean to flip. Playback needs an artifact only
the server can mint, because only the server holds the signing key. A free
account's proxy can rewrite every byte and still not produce a URL the CDN will
honour; intercepting a premium user's reply shows them their own URL, which
they already had, and which expires in minutes.

> **Never send a permission. Send a capability.**

### Enforced by the build, not by discipline

`security_invariants.py` is a new pre-zip checker. It does not look for bugs;
it looks for the ARCHITECTURE quietly coming apart, which is how this kind of
model actually fails - a screen that pushes the player directly, a URL written
to preferences "just for resume", a temporary local override that becomes
permanent. None of those look wrong in review and none fail any other check.

1. only `playback.dart` may reference `Routes.player` - every play goes through
   `requestPlayback`
2. only `playback.dart` may interpret a `PlaybackGrant` - one place decides what
   a denial means, so a paywall cannot be rendered as an error somewhere else
3. nothing URL-shaped may be written to storage - a stored signed URL outlives
   the expiry that made it safe
4. the UI may not take a writable handle on entitlement
5. no data adapter may consult `CapabilityMatrix` - an adapter that asks a local
   table has moved the decision back into the client

Five invariants, five injected violations, five caught.

### What actually differs between the tiers

`CapabilityMatrix` replaces scattered `isPremium` checks with one table, so
"free users get 480p" is a row rather than a hunt through call sites:

| | Free | Premium |
|---|---|---|
| Browse, posters, synopsis, rating | yes | yes |
| First 4 stills + the marked preview clip | yes | yes |
| Full album | no | yes |
| Play a premium title | **no** | yes |
| Offline download | no | yes |
| Quality ceiling | 480p | source |
| Concurrent streams | 1 | 2 |

The table is explicitly documented as ADVISORY - it decides whether to draw a
lock, never whether to hand over a file. An attacker who patches it gets a
nicer-looking free account.

Two deliberate choices: the quality ceiling is a ceiling rather than a block,
because "your copy is worse" converts better than "you may not look"; and a
premium subscriber's downloads are theirs and stay playable, because that is
what they bought. The thing that must not happen is a FREE account obtaining
the file at all, which is a server question.

### Device binding

`DeviceIdentity` - 128 bits from `Random.secure()`, generated once per install.
Deliberately NOT a hardware id: no IMEI, no MAC, no advertising id. Those are
privacy-hostile, increasingly restricted, and no less forgeable to someone who
has already patched the app.

Sent with every playback request so the server can bind the grant and count
concurrent streams - the number that decides whether one subscription serves a
group chat, and one that can only be counted server-side. Honest limit: it can
be cleared for a fresh slot. What it stops is CASUAL sharing, which is the
sharing that actually happens.

### Attestation is a hint, never a verdict

Written into the spec because it is an easy mistake: if Play Integrity is added
it may raise friction - rate-limit, re-login, flag for review - and must never
grant or deny. It fails for ordinary reasons (de-Googled phone, custom ROM,
sideloaded build, Play Services outage). A subscriber locked out by a false
positive is a refund and a bad review; an attacker who fails it simply turns it
off.

**Dart-only. UNTESTED on device. Still no backend - the stubs enforce nothing;
`docs/premium_backend_spec.md` is the half that does.**

## v1.55.7+280 - Accounts, KPay activation, and where protection actually lives (Aug 2026)

Identity and manual payment, plus the security model written down. The code in
this release is the CLIENT half; `docs/premium_backend_spec.md` is the half
that enforces anything.

### Why accounts exist here

Not as a feature - as an operational necessity. With manual KPay activation
somebody has to look at a transfer and say which account it belongs to. An
anonymous app has nothing to attach that answer to.

Phone leads because KPay is phone-based: the number that pays is almost always
the number that signs in, which turns manual matching from an investigation
into a glance. Numbers are normalised to E.164 at the edge (09... -> +959...),
once, because a subscription keyed on one format and a KPay statement listing
the other are the same person, and code that has to remember that at every
comparison will eventually forget.

### The payment flow, honestly

The app CANNOT verify a KPay transfer and does not pretend to:

1. sign in
2. see the KPay number, name and amount - number copyable, because a mistyped
   digit sends money to a stranger and produces a support conversation nobody
   can resolve
3. pay outside the app
4. submit the transaction id and sending number
5. **a human** checks it against the real KPay statement and approves

The confirmation screen says "submitted, under review" and never "you are
premium". Telling someone they have access before the money is confirmed is how
a free account watches paid content, and how the operator ends up arguing with
someone who sincerely believes they paid.

The account screen exists for step 5's WAIT. A wait with no visible state is
indistinguishable from a failure: someone who paid twenty minutes ago needs to
see their claim queued, or they pay twice, or they leave.

### One entitlement, not two

278 had `LocalEntitlementStore`; this release deletes it. Entitlement now
derives from the account and nothing else. Two stores would be a split brain,
and the copy that goes stale is always the one some screen happens to read.
Signing out drops the session and the entitlement in the same assignment,
because there is only one of them.

### Anti-piracy: what is real and what is theatre

The honest summary, and the reason the spec exists:

> If a device can play it, a device can copy it.

Nothing configurable changes that - not signed URLs, not FLAG_SECURE, not full
DRM. The goal is to make copying expensive and traceable, and to close the
cheap paths. In order of value:

1. **The server must never return a playable URL to an account without an
   active subscription.** Not "the app hides the button" - the bytes must not
   be obtainable. Everything else is refinement; this one is the difference
   between a paywall and a suggestion.
2. **Short-lived signed URLs.** A link that dies in minutes cannot be shared,
   posted or scraped. `PlaybackGrant` now carries `expiresAt`, and the client's
   obligation is absolute: never persist a media URL, always request a fresh
   one.
3. **FLAG_SECURE during premium playback.** Blocks Android screenshots and most
   screen recorders - the cheap, common leak. Does nothing against a rooted
   device or a second camera.
4. Watermarking and concurrency caps - deterrence and traceability, specified
   but not yet built.

`docs/premium_backend_spec.md` carries the schema, the RLS policies, the
playback Edge Function, the approval transaction and a pre-launch checklist.
Its last line is the only test that matters: sign in as a FREE account and try
to curl a playable URL out of the backend. If that works, nothing in the app
matters.

### A bug introduced and caught in the same session

FLAG_SECURE was first acquired in `playback.dart`, next to the player push.
The service is REF-COUNTED and every acquire must be paired with a release -
so that version would have left the entire app capture-blocked until restart
after one premium video. The claim now lives in the player, acquired in
initState and released in dispose, next to the vault's identical claim.

It also needed a flag of its own rather than reusing `isPrivate`: that one also
suppresses background play, system PiP and floating PiP, which a paid film
should still get. Only the capture protection is shared.

### Three checker gaps, found by faults that would not fire

* **Tear-offs.** The private-symbol check looked for `_name(`. A callback
  passed as `onPressed: _submit` has no parentheses, so a reference to a
  method that does not exist was invisible.
* **Providers.** `compile_risk` tracked types only. A top-level
  `final xProvider = ...` is not a type, so a forgotten provider import - among
  the most common Riverpod errors - was invisible. Narrowed to `ref.*()` call
  sites after a first attempt produced two false positives against constructor
  parameters that happen to be NAMED after providers.
* **Private getters and enums.** `int get _totalVaultBytes` and
  `enum _VaultCat` were not recognised as declarations, so widening the check
  immediately accused working code of calling undefined symbols.

Ten injected faults, ten caught, and the tree stays clean under every widened
rule.

**Dart-only. UNTESTED on device. No backend: sign-in, approval and entitlement
are all on-device stubs that enforce nothing.**

## v1.55.6+279 - Video Hub: entitlements, soft paywall, VIP access (Aug 2026)

Groundwork for paid access, built now rather than retrofitted, because who may
see what reaches into the model, the repository contract and every screen -
and a paywall bolted on afterwards leaks through whichever surface was
forgotten.

### The shape: a soft paywall

The free tier is a real taste of each title, then an honest wall:

* poster, title, synopsis, rating, metadata - **always free**. These are the
  advertisement; hiding them hides the reason to pay.
* the first four stills of a premium title - free.
* one clip per title marked as the trailer - free, and tagged so it is
  findable. Without the tag a preview looks identical to the locked clips
  beside it and nobody discovers it.
* everything else - **shown but not openable**. Locked stills are dimmed
  behind a lock rather than hidden: a free viewer who cannot see what they are
  missing has no reason to pay, while one looking at eleven dimmed stills has
  a very concrete one.

The research is blunt about both failure modes - too generous and nobody
upgrades, too restrictive and people leave before the app means anything - and
that access to full content is the single largest reason people do upgrade.
So the paywall names what is being bought: "unlock 11 more in this title",
not a generic pitch.

### Where the rules live

`access_policy.dart` owns EVERY free-tier rule. Changing what a free user gets
is a one-line edit in a file you can find in six months, not a hunt through
widgets for scattered `if (isPremium)` checks. Nothing else in the feature is
allowed to decide what is locked; screens ask the policy.

Tiers are DATA (`VideoContent.accessTier`, `AlbumItem.isPreview`), not code.
Which titles are free changes for commercial reasons and must never need a
rebuild. `accessPolicyProvider` means a promotion - "everything free this
weekend" - is a config change, not a release.

### Where it is enforced - and where it is not

`resolveStreamUrl` is gone. `ContentRepository.requestPlayback` replaces it and
returns a **reason** when it refuses:

* a URL        -> open the player
* needsPremium -> open the paywall, **not** an error
* unavailable  -> a plain message

Distinguishing the last two is the reason a grant object replaced a nullable
string: a paywall rendered as "something went wrong" loses the sale AND reads
as a bug. Entitlement is checked BEFORE availability, so a free viewer is never
told a title is broken when they simply have not paid for it.

**Read this part twice.** `LocalEntitlementStore` is a boolean in
SharedPreferences and it ENFORCES NOTHING. Anyone with a rooted phone, a backup
tool or a patched APK can set it, and no obfuscation changes that - a client
cannot keep a secret from the person holding it. It exists so the paywall can
be built and both states tested before billing exists.

Real protection has one shape: **the server checks the session and does not
return a playable URL to a viewer who has not paid.** That is why the decision
sits behind `requestPlayback` rather than in the widgets - when the API adapter
lands, the verdict starts arriving over the network and no screen changes.

### UI

* `PaywallSheet` - names the title, counts what is locked, shows BOTH prices
  with the annual saving stated up front. Hiding a price behind a tap, or
  revealing the real billing frequency at the last step, is the classic
  conversion killer and costs more in retention than it wins. Dismissible over
  the content the user was already looking at.
* Purchase flows straight back into playback. Making someone who has just paid
  hunt for the play button again is the worst possible moment to add a step.
* Detail screen: Play becomes **Upgrade** when locked - never disabled. A dead
  button teaches nothing; one that says Upgrade explains the state and offers
  the way out.
* A small monochrome VIP marker, drawn only for viewers who do not already have
  premium. Badging every card for a subscriber is noise about a decision they
  already made.
* `playback.dart` is the single place all four surfaces go through, so the
  paywall cannot be wired into three of them and forgotten in the fourth.

### Checker note

A checker GAP surfaced, found because an injected fault could not be placed:
`verify.py` validated `AppColors.*` members but knew nothing about the `VH`
token class introduced in 278, so a typo'd design token was caught by nothing.
The check is now generalised over token classes. 10 injected faults, 10 caught.

**Dart-only. UNTESTED on device. No billing integration - purchases are
simulated locally.**

## v1.55.5+278 - Video Hub: design system, featured hero, filter redesign (Aug 2026)

Device review of 277 said it looked childish and that something was missing.
Both were right, and both had specific causes rather than being a matter of
taste.

### "Something is missing" was the opening

The hub opened straight into a row of small posters. Every catalogue app worth
copying opens with ONE title presented large, and it is not decoration - it
gives the page a focal point, it sets the scale that makes the rows below read
as deliberate rather than as everything the app has, and it puts a real action
on screen so the first tap can be "watch this" instead of "go looking".

`FeaturedHero` is now the top of the landing tab: artwork bleeding into the
page (a framed banner reads as an advert inside the app; a bleeding one reads
as the app), two separate scrims so the middle of the image stays clean, title
on the display scale, a metadata line, and Play / More info. Play PLAYS - a
hero button that opens a detail screen is the most prominent control on the
page lying about what it does. Which title is featured is a repository call,
`getFeatured`, not something the UI infers from whatever sorted highest.

### "Childish" was three concrete things

**1. Colour was doing the work of hierarchy.** The selected category was a
saturated blue fill - the loudest thing on a black page, competing with the
artwork the page exists to show. On a dark canvas the convention is the
opposite: raise the SELECTED item to near-white and let everything else
recede. Unselected pills are outlined rather than filled, because a dark fill
on a black page is nearly the same tone and the row loses its shape. White is
now reserved for exactly one thing per screen - the primary action - which is
what makes it read as primary without a colour.

**2. Nothing had a rhythm.** Type was 12.5 / 13 / 16 / 17px and gaps were
5 / 6 / 8 / 10 / 14 / 16 / 18px, all picked by eye. `video_hub_theme.dart`
now owns a 4dp spacing scale, a seven-step type scale, tonal surfaces and a
text luminance ramp. Premium in an interface is mostly the absence of arbitrary
numbers - a reader cannot name the rhythm, but they feel it when there is none.

**3. Badges buried the artwork.** A 108dp tile could carry four of them -
quality, rank, rating, episode count. Each was defensible; together they
covered the only thing on the card that sells the title. Now at most two:
one marker top-left (rank where the list is ranked, otherwise quality) and the
rating bottom-right. Episode count moved to the detail screen, where there is
room to write "12 episodes" instead of "EP 12". The scrim is drawn only under a
badge that exists, instead of dulling every poster.

Placeholder art was also stamping a large letter on every card, so a screen of
them read as alphabet blocks. Muted tones and a small low-contrast glyph
instead - it recedes and the titles do the identifying.

### Filters: a pill row became a toolbar and a sheet

Four dropdown pills sat permanently under the category bar. They cost 46dp of
every screen, gave four unrelated controls identical weight, and still could
not show what was selected without being opened one at a time.

Replaced with the researched mobile standard:

* a **toolbar** - result count on the left, Sort and Filters on the right,
  each stating its CURRENT value ("Newest", "Filters 2") rather than its own
  name. The count on the Filters button is the single detail that most reduces
  filter confusion on mobile;
* a **filter sheet** with room to show every genre at once, and a primary
  button that reads "Show 24 titles" and updates live - so a filter that empties
  the catalogue is visible BEFORE it is applied, not as a blank screen after.
  Disabled at zero: letting someone confirm their way to a blank screen is
  worse than a dead button;
* a **sort sheet**, separate, because filtering and sorting answer different
  questions and merging them makes users wade through genres to change an
  ordering. Sort applies on tap; filters batch on confirm;
* **applied-filter chips** above the grid, each labelled with its facet
  ("Year: 2024", not "2024" - the same word can appear in two facets) with a
  32dp removal target, plus Clear all.

Default sort is now Most watched rather than Newest. A catalogue's default
ordering is a recommendation, and "whatever was added last" surfaces the
thinnest titles the moment a backend ingests a batch.

### Correctness

* `playback.dart` - one function for "resolve a ref and open the player",
  shared by the hero, the detail screen and the album viewer. Playback is
  exactly the thing that diverges when written three times: one caller forgets
  the mounted check, another shows a different message, a third passes the
  wrong title.
* Changing a filter now returns to the top of the list. The old offset points
  at nothing in the new result set.
* Sticky bars separate with a HAIRLINE, not an elevation. A shadow cast onto a
  true-black page is invisible, so the bars had no edge at all while content
  slid under them.

### Checker note

The AppStrings check had a false NEGATIVE, found only because an injected fault
failed to fire. It bound `s.` only in files with exactly ONE `final s = ...`,
a rule written to dodge shadowing (`final s = songs[i]`). Any file where three
widgets each did `final s = AppStrings.of(context);` was therefore skipped
entirely. It now checks whenever EVERY binding is AppStrings and skips only on
real ambiguity. 10 injected faults, 10 caught, and the tree stays clean under
the widened rule.

**Dart-only. UNTESTED on device.**

## v1.55.4+277 - Video Hub: card geometry, See all on every row, paging (Aug 2026)

Device review of 276 said the cards looked slightly too tall. Measuring them
found something worse than "slightly": the same card was TWO different shapes.

### The card-shape defect

The row let a Column's `Expanded` absorb whatever height was left over. The
grid used `childAspectRatio` on the whole cell, text included. Neither said
what shape the artwork was supposed to be, so neither could be wrong:

| | poster aspect | |
|---|---|---|
| in a row  | 0.638 | 1 : 1.57 - taller than printed poster art |
| in a grid | 0.688 | 1 : 1.45 |

Both were accidents of leftover space. `poster_metrics.dart` now owns the
number and both places derive from it:

* artwork pinned to **0.72** with an `AspectRatio` in the row AND the grid;
* the grid delegate takes an absolute `mainAxisExtent` derived from that
  aspect, not a `childAspectRatio` - an aspect ratio makes cell height depend
  on cell width, so the artwork drifts away from the intended shape on wider
  screens and the text block grows with it;
* the text block is measured through `MediaQuery.textScalerOf`, so a user at
  130% text size gets a taller card instead of a clipped year;
* the title/year sit in a `Stack` over reserved space rather than in the
  Column, so a long title cannot push a card past the height the grid was
  promised.

Result: row cards **13% shorter**, grid cells 5% shorter, and one shape
everywhere. 0.72 rather than the 2:3 of printed posters is a density choice -
real artwork loses ~7% top and bottom under `BoxFit.cover`, which is invisible
on posters and buys a noticeably tighter grid.

### See all, on every row

Every landing row now carries a **See all** affordance, and the whole header is
the tap target rather than one small word at the screen edge. A row is a
sample, not an inventory; when some rows lead somewhere and others silently do
not, the user learns which by tapping.

Tapping one opens the full list - and for Trending, New releases and Top rated
that list spans **every category at once**: films, series and clips ranked
together, which is what "show me what is popular" means. Row scope is a
repository concept (`getRowCatalogue`), deliberately not a `ContentCategory`,
because no single category can express "all of them".

Each list opens in its row's own ordering so the first screenful continues the
row that was tapped, then offers the full filter and sort set. Trending draws
1..n numerals, and drops them the moment the user re-sorts - a numeral that
survives a sort change is a lie about the ordering.

`popularity` is now a first-class field, kept separate from `rating`: rating is
what people thought of it, popularity is how many showed up. "Trending" that
quietly sorts by rating shows a beloved obscurity above the thing everyone is
actually watching.

### Paging

The grid fetched page 0 and stopped - `hasMore` was returned and ignored.
Fetching four hundred posters to show nine is slow on a good connection and a
wall on a bad one, which is the connection this app is built for.
`PagedCatalogueNotifier` now loads 30 at a time, 600px before the bottom so the
grid grows under the thumb, with an in-flight guard (a scroll listener fires on
every pixel, so one flick would otherwise queue a dozen identical requests).
A failed *next* page keeps what is already on screen and offers retry in the
footer instead of discarding it.

Shared by the hub grid and the See-all screen through `PagedPosterGrid`, so
"load more" cannot be fixed in one and forgotten in the other.

### Smaller fixes found on the way

* the filter bar is now **pinned**. Scrolling forty titles deep and having to
  scroll back up to change a genre is why people stop using filters.
* the "All" tab showed a GRID skeleton while loading ROWS, so the layout
  visibly rearranged itself when data landed. It now shows a row skeleton.
* switching category resets the scroll to the top - staying 40 rows deep while
  the content underneath changes completely is disorienting.
* pull-to-refresh on both screens, with `AlwaysScrollableScrollPhysics` so it
  still works when the results are shorter than the screen.
* `getCatalogue` and `getFacets` were duplicating filter/sort/page/facet logic
  that `getRowCatalogue` needed too; all four now share one implementation.

### Checker notes

A parameterised string was written as `replaceFirst('{n}', '\$n')` - an
ESCAPED dollar, which substitutes the literal text `$n` instead of the count.
It compiles, it passes every structural check, and it is only visible by
reading the generated line against an existing one.

All four checkers were negative-tested this session: 10 injected faults, 10
caught.

**Dart-only. UNTESTED on device.**

## v1.55.3+276 — Video Hub: the movie/series/reels vertical, phase 1 (Aug 2026)

Innocent grows a second kind of content. Until now every video it played came
from the phone; this release adds the shell for remote content — Movies,
Series, Reels and an opt-in Adult section — reached from a new **Movies** chip
at the head of the Local screen's quick-access strip.

### What is in it

A Video Hub screen laid out the way the streaming apps converged on, because
the pattern solves a real problem rather than being decoration:

* a **search field** that covers the entire catalogue, not the visible tab;
* a **pinned, horizontally-scrollable category bar** between the search field
  and the content (All · Movies · Series · Reels · Adult);
* **"All" shows curated rows** — Trending, New releases, then one row per
  category with a *More* link. Rows turn one impossible decision into a series
  of cheap glances;
* **a specific category shows a poster grid** with genre / year / quality /
  sort filters. Someone who has already decided what they want is served by a
  grid, and rows would be in the way;
* **content detail** = poster, facts, and a Telegram-style mixed grid of stills
  and clips, opening into a swipeable viewer.

Playback is handed to the **existing player** via `Routes.player`. This feature
deliberately gains no second video surface — the player already owns gestures,
subtitles, decoders, PiP, background audio and resume, and a parallel one would
inherit none of it.

### The part that matters for later: a storage seam

Everything the screens need sits on one interface, `ContentRepository`, and
nothing on it names a storage provider. A widget never learns where a file
lives — it holds a provider-agnostic `MediaRef` and asks the repository to make
it playable. Provider choice, health checks and failover all live behind that
line.

The consequence is the point: moving from the bundled demo catalogue to a real
backend — or from one backend to another, or failing over between two — is a
change to `contentRepositoryProvider` and an adapter class. No widget, no
screen and no provider above that line is edited.

Phase 1 ships a `DemoContentRepository` over a bundled catalogue, so the whole
surface can be reviewed on a real phone before any backend is chosen.

### Adult section: opt-in, and off by default

Two separate flags, deliberately not one. The section must be **enabled** (it
does not exist in the tab bar otherwise, so nobody reaches it by mis-tapping)
**and** the 18+ prompt must be answered. Turning the section off later drops
the user back to a safe tab rather than stranding them on a category that no
longer exists.

### The chip strip stopped being hand-balanced

Adding a seventh chip to a hand-written page of six overflowed 360dp phones.
The strip is now one flat list with the page size derived from the available
width and clamped to 4-6 — appending a future chip re-flows the layout instead
of requiring the pages to be re-balanced by hand.

### Found by the checkers, not by the compiler

Two latent build failures were caught before zipping, both of the class no
balance check can see:

* the album item class was first called `MediaItem`, which is also a class in
  `audio_service`. Nothing broke yet only because no single file imported both
  — a landmine for the next file that would. Renamed to `AlbumItem`.
* the search provider was first called `searchQueryProvider`, which already
  exists in `library_provider.dart`. Renamed to `videoSearchQueryProvider`.

A new `collision.py` now scans every top-level name the feature declares against
the rest of the project, and `compile_risk.py` learned that importing a library
also brings in its `part` files' types (which had been producing seven false
positives against code that compiles fine).

**Dart-only. UNTESTED on device.**

## v1.55.2+275 — the build failure 274 shipped, and the checker that now catches it (Aug 2026)

Build 274 did not compile:

    player_controller_modes.dart:183:30: Error: '_livePosition' isn't a
    function or method and can't be invoked.

### What happened

`Duration _livePosition()` already existed, on `extension PlayerPlayback on
PlayerController`, doing exactly what was needed — read the live position from
the player service and fall back to the UI copy. Build 274 added a getter of the
same name to the **class** `PlayerController`, having failed to notice it.

Dart resolves a class member ahead of an extension member. So the new class
getter silently won, and the three pre-existing `_livePosition()` calls stopped
being calls at all. Nothing was redeclared in any single scope — the two names
simply lived in different scopes on the same type — so neither the balance check
nor the duplicate check could see it, and neither could a reviewer reading one
file at a time.

The fix is to delete the getter and use the helper that was already there. Its
duration twin, `_liveDuration()`, now sits beside it in the same extension
rather than on the class, which removes the question entirely.

The waste here was not the mistake; it was writing a second copy of a helper
that existed. In a notifier split across a class and six `part` extensions,
"does this already exist?" is not a question worth answering from memory.

### The checker

`dart_shadow.py` walks each library — a head file plus every file it declares as
a `part` — collects the members declared on each class and on each extension of
that class, and reports any name declared in more than one of them. It also
catches the same member on two extensions of one type, which is the same error
wearing a different hat (ambiguous extension member invocation).

It reports nothing across this project and fires on both shapes when they are
injected. All six extensions on `PlayerController` live inside the library, so
they are all in scope for it.

That makes eight gates before a zip now: seven structural checks, duplicate
declarations, class/extension shadowing, a real Kotlin compile of
`PlaybackService.kt` against stubs, a parse of the other twenty-one Kotlin
files, the Kotlin/Dart constant cross-check, and a whole-tree diff against the
original archive — each run again on the extracted zip rather than on the
working copy.

There is still no Dart compiler in reach, and that is exactly why this failure
got out. Every gate that exists was written after something escaped; this one is
no different.

**Untested on device.** Force Stop once before testing.

## v1.55.1+274 — verified with a real compiler, not with confidence (Aug 2026)

Build 273 was never released. This one replaces it, and three of the four things
below were found by checking rather than by thinking harder.

### A real Kotlin compiler now runs before the zip

There is Java in the build container and the Kotlin compiler downloads from
GitHub, so `PlaybackService.kt` — where every line of new native code lives — is
now compiled for real against hand-written, signature-accurate stubs of the
exact platform surface it touches. The Android SDK is unreachable, hence the
stubs; every error that survives them is a genuine error.

It earned its place on the first run. It found a **duplicate local declaration**:
a patch had replaced the tail of `buildNotification` and re-declared two values
the surviving head already had. Braces balanced. Every symbol resolved. Nothing
missing. All thirteen existing checks passed it, and the FlutLab build would
have failed. Balance checking proves shape; only a compiler proves meaning.

The other twenty-one Kotlin files are too entangled with the Android SDK to stub,
so they get a parse-only pass instead, filtered down to syntax and redeclaration
errors — with the filter itself negative-tested against an injected broken paren.

### The MediaStyle assumption was wrong

Build 273 built its notification with `NotificationCompat` and put the session
token into `Notification.EXTRA_MEDIA_SESSION`, assuming the system would read it
from there. Google's guidance is explicit that the media card on the lock screen
and in the shade's media panel comes from a **MediaStyle notification with a
valid session token**. The style is the contract; the extra is not.

That would have compiled, run, crashed nothing, and shown no media card at all —
the exact failure that costs a build, a test and a puzzled bug report. It is now
the framework `Notification.Builder` with `Notification.MediaStyle`, which takes
our session token directly and keeps the no-new-dependency position (androidx's
MediaStyle wants a `MediaSessionCompat.Token`, which a framework session does not
speak). Play/pause and Stop show in the compact row.

While there: the notification's play/pause button now sends a definite `play` or
`pause` rather than the old toggle, so the button and the session can never
disagree about what "the other state" means.

### Asking for the permission that decides whether any of it is visible

On Android 13+, POST_NOTIFICATIONS is what decides whether a foreground
service's notification is **shown**. Without it the service still runs and the
audio still plays — so nothing looks broken from inside — but the notification is
silently suppressed, and with it go the Play, Pause and Stop buttons and the
media card. Every visible part of background play would simply be absent, with
no error anywhere to explain it.

The app already asks for this for ADB pairing, so the plumbing existed; it was
never wired to the feature that needs it most. Turning background play on now
asks, which is the right moment and the only one.

### A position that was true and a position that was current

The MediaSession was being fed `state.position`. That value is quantised to one
write a second and, since the battery work in v1.42.2, is only written while the
controls are on screen — correct for the UI, wrong for anything the system
reads. The lock-screen scrubber would have sat wherever the controls were last
up, which on a film watched without them is the beginning. It reads the player's
live position now.

### Audit

A new `dart_dupes.py` looks for the same duplicate-declaration shape in Dart,
since the patch scripts that caused the Kotlin one write Dart too. Its first run
accused two shipping files, both wrongly: a `for (...)` header is its own scope,
and Dart — unlike Java — gives each `case` clause of a switch its own scope. Both
rules are now in the checker, which reports nothing across 222 files and still
fires on an injected duplicate.

Two `setState`-after-`await` calls with no `mounted` guard were fixed outside the
player: the downloader's probe (which can run for tens of seconds, during which
leaving the screen is the normal thing to do) and the backup restore confirm
dialog. A third and fourth hit from that sweep were false positives and were
checked by hand rather than patched on the scanner's word.

`AppLifecycleState.detached` now requires the app to have reached the foreground
at least once before it tears playback down — Flutter can deliver `detached`
before any view is attached, and an unguarded hard-stop there is a teardown for
an app that has not started. And the session declares its audio attributes, so
the volume keys and the output switcher have a stream to attach to.

**Untested on device.** Force Stop once before testing; orphaned players from
before build 273 may still be running.

## v1.55.0+273 — a regression of mine, and the last real gap closed (Aug 2026)

Two things in this build. The first is a bug I introduced; the second is the
one item that was still genuinely missing against MX Player.

### The pile-up was mine

Reported: play with background play on, leave, pick another video — both play
at once, and every video after that adds another voice. Clearing the app from
Recents does not stop it. Only Force Stop does.

**libmpv's threads belong to the process, not to the Dart isolate.** Nothing in
Flutter tears them down; `mpv_destroy` runs only if something calls dispose. So
playback that outlives the player screen is playback nobody owns — and when the
engine is destroyed the isolate goes with it while those native threads keep
running. Relaunching builds a new engine, a new isolate and a new libmpv, which
cannot even *see* the orphan, because statics do not survive an isolate. So it
plays alongside it. A few rounds of that and everything you have opened is
singing at once, and only killing the process clears them.

Leaving the player with background play on has always kept libmpv running —
that predates me. What v1.51 added was keeping the foreground service and its
WakeLock alive too, and that is what let the process outlive the task. The
orphan could finally survive long enough to meet its successor.

So the rule is now explicit: **libmpv must never outlive the widget that owns
it.** Only the floating window may carry playback out of the player screen, and
it is a live widget that can stop it. Backing out stops playback, the service
stop in the controller's dispose is unconditional again, and the callback
handover that only existed to serve the old behaviour is gone. As a last line
of defence, `AppLifecycleState.detached` — the only warning Flutter gives that
the isolate is going — now hard-stops from the floating overlay, which is the
one widget still listening at that point.

MX draws the line in the same place: background play means the audio keeps
going while the **app** is in the background — screen off, Home, another app —
not that it keeps going after you have closed the video.

**This changes behaviour you may have been relying on:** backing out of the
player now stops playback even with background play on. Say so if you want the
other behaviour back, and it should be built as a proper audio-only handoff
rather than by letting the video engine run unowned.

### MediaSession

The video player had transport buttons on its own notification and nothing
else. A MediaSession puts the same controls where people actually reach for
them: the lock screen, the shade's media panel, a wired headset button, a car
head unit, a watch. It is also how Android itself decides what "media" means —
an app holding an active session in a playing state is treated differently by
the audio policy and, in practice, by the OEM battery managers that are most of
the reason background audio is hard on these phones. On Android 14+ a
`mediaPlayback` foreground service is expected to have one.

Deliberately the framework `android.media.session.MediaSession` rather than
MediaSessionCompat: the Music tab already runs its own session through
audio_service, which brings the androidx.media stack with it, and two owners of
one compat layer is a class of bug worth not having. No new Gradle dependency.
minSdk is 24, so the framework API is there unconditionally.

Play, pause, stop, seek, next and previous are wired through to the player.
Play and pause are deliberately separate from the existing play/pause toggle: a
button press genuinely means "the opposite of now", but a session command is a
statement about the state the system wants, and answering it with a toggle
inverts playback whenever the two disagree.

Progress rides along with the service's start and update calls rather than on a
ticker — the session extrapolates elapsed time from position, speed and the
moment it was last told, so pushing on real state changes is enough.

**Untested on device.** Force Stop the app once before testing: orphaned
players from the previous build may still be running.

## v1.54.1+272 — the cold-start window, and a timer that outlived its player (Aug 2026)

Build 271 settled it. One case was left: open the app, go straight into a
folder, start a video while the folder is still scanning, turn the screen off —
and background audio dies. Wait a moment first and it is fine, and every video
after the first is fine.

### Why waiting fixed it

That shape is an initialisation race, and this one has a specific mechanism.
`AndroidVideoController.create()` writes its own batch — `force-window: 'yes'`,
`vid: 'auto'`, `vo`, and the rest — and the library writes `vo` again from
`widListener` the first time it is handed a surface and a size. None of that is
awaited by anything on our side.

The part that decides the race: media_kit's own writes pass
`waitForInitialization: false`, while ours take the default `true`. During
start-up the library's writes overtake ours **by design**. So a detach that
lands in that window is not merely racing — it is scheduled to lose, and it is
overwritten a moment later. The output is rebuilt against a surface nobody is
draining, which is the original stall arriving from a different direction.

Once the engine has settled there is nothing left to overwrite it. That is
exactly why a few seconds of patience appeared to fix it, and why the second
video was never affected. A folder scan in the background makes the window
wider, which is why it showed up on that path first.

So the detach no longer assumes it won. It re-states `force-window=no` and
`vo=null` every 250 ms for about five seconds, then stops. Both writes are
idempotent — setting an mpv property to the value it already holds
reinitialises nothing — so the cost is a couple of dozen cheap FFI calls, only
ever while backgrounded, and the watchdog stops the instant the picture is
wanted again.

### A leak from last build

The single re-assert added in 271 was never cancelled in the service's
`dispose()`. A player torn down while backgrounded left a timer behind, writing
properties into a disposed engine. Cancelled now.

### Audit notes

A sweep for timers assigned and never cancelled came back clean apart from the
one above — the transfer and player screen timers all cancel, just further down
their dispose bodies than a naive scan reaches, and each was checked by hand
rather than taken on the scanner's word.

A second sweep looked for `state = ...` written after an `await` with no
`mounted` guard in between, which is how a notifier ends up writing to itself
after disposal. Nothing in the player. The handful of hits elsewhere are in
providers that are not `autoDispose` and so cannot be torn down mid-await, or
already guard before the await rather than after it.

**Untested on device.** The case to retry is the original one: cold start →
straight into a folder → play while it is still scanning → screen off.

## v1.54.0+271 — the other half of force-window, and an end to guessing (Aug 2026)

Build 269 built and ran, and background play still stopped — on screen-off and,
newly reported, on Home as well. That second fact is worth more than it looks:
Home means the display is still on, nothing is dozing and no process is being
frozen, so whatever kills the sound is not a power-management story. It is the
render path. That part of the diagnosis holds.

### What build 269 got half right

Finding that `AndroidVideoController` sets `force-window: 'yes'` was the right
finding. Only half of it got used. Build 269 released `vo` and left
force-window alone — which leaves mpv under standing orders to have a window.
So the moment anything re-asserts `vo`, the output is rebuilt against a surface
nobody is draining, and the stall is back exactly as before.

Something does re-assert it. `AndroidVideoController.widListener` writes `vo`
on every surface or size change, which is precisely the kind of event a
backgrounding relayout produces. Releasing `vo` while force-window says "always
have a window" is an instruction the library is free to undo a frame later.

So the detach now turns **force-window off** as well, and with no video track
selected mpv has no grounds to build a window at all. A stray `vo=gpu` from the
library becomes harmless instead of fatal. This is the property that makes the
detach stay detached. A single idempotent re-assert 700 ms later covers the
relayout that arrives after we have gone.

### A real bug on the Home path

`_pipTransitionInFlight` was honoured by the pause branch of the lifecycle
handler and not by the detach branch, though both need it for the same reason.
Pressing Home with PiP enabled sends `paused` **before**
`onPictureInPictureModeChanged`, so `inSystemPip` was still false when the
detach ran — audio over a black PiP window, with nothing afterwards to put the
picture back. The detach now stands down during that transition, and entering
system PiP reattaches unconditionally as a second net.

### And a way to stop guessing

This bug has now been diagnosed four times from reading code and fixed four
times, and each round cost a build, a test and a guess. The reasoning was not
the problem: the one moment that matters happens with the screen off, where
nothing can be observed.

So build 271 records it. `PlaybackLog` is a capped in-memory list of short
lines — no I/O, no isolate, safe to call from the service layer — and the
Debug overlay (Settings → Player → Debug, any of the three switches) now shows
the tail of it. Turn a switch on, do the screen-off, come back and read.

It answers the three questions that have been guessed at until now: whether the
detach FIRED or its gate was false; whether libmpv ACCEPTED the writes or they
threw and were swallowed; and — the one that matters most — whether the
playback position ADVANCED while backgrounded. `reattach ... advanced=Ns`
separates "the renderer blocked" from "something paused us" from "the process
was frozen". Those three look identical from outside and have nothing else in
common, and knowing which one it is turns the next round into a fix instead of
a fifth guess.

**If it still stops:** turn on Debug, reproduce, and send the `background play`
block. If `advanced` is near zero the renderer is still stalling; if it tracks
the wall clock the audio path was alive and something else took the sound.

**Untested on device.**

## v1.52.0+269 — the fourth attempt, and the first one aimed at the right property (Aug 2026)

Background play still died the moment the screen went off. Three fixes had
already been shipped for this — v0.97, v1.45, v1.51 — and every one of them
was aimed at `vid`. None of them could ever have worked. This release stops
reasoning about it and reads media_kit's own source.

### What was actually wrong

On Android, media_kit does not use libmpv's render API. It hands libmpv a raw
`android.view.Surface`, taken from a Flutter texture entry, through `--wid`,
and renders with `--vo=gpu --gpu-context=android`. The consumer of that surface
is Flutter's raster thread. Screen-off stops that thread, nothing drains the
buffer queue, it fills in a frame or three, and mpv blocks in `eglSwapBuffers`.
A blocked VO stalls the core, the core stops refilling the audio ring, and the
second or so of sound you still hear is the hardware buffer emptying.

That much the last release had right. Here is the part that defeated it:

`AndroidVideoController` sets **`force-window: 'yes'`** when it creates the
controller. With force-window on, mpv keeps the video output alive *even with
no video track selected*. So `vid=no` dutifully deselected the track and left
the output exactly where it was — still holding the surface, still swapping
buffers, still blocking. Right medicine, wrong organ, three times running.

**`vo` is the property that owns the surface.** And releasing it is not a
workaround on this stack, it is the sanctioned path: media_kit's own
`AndroidVideoController.widListener` writes `vo=null` first on *every* surface
change, and its own comment says `vo=null` is required once the surface pointer
is gone. The v1.45 note that avoided `vo=null` on the strength of mpv-android
issue #1076 was reading advice written for a different architecture —
mpv-android drives the surface itself with attachSurface/detachSurface and
`vo=mediacodec_embed`.

So: detach is now `vo=null`, then `vid=no` (that one is the battery half — no
sense decoding pictures nobody can see), then the idle housekeeping. Reattach
is `vid=auto`, then `vo` back to what was there, then a resync seek — media_kit
re-seeks after every VO re-init too, and without it the picture can sit black
until the next keyframe. The `vo` to restore is read once at toggle time, never
during the screen-off race.

A safety gate sits in front of the restore: it asks libmpv for `wid` first and
declines to attach an output when the surface pointer is zero, because that
combination is the documented SIGSEGV. It also makes this code correct on the
newer media_kit, which is the other half of this release.

### One more bug on the way out

`open()` restored only `vid`, which meant it left `vo=null` in force. A file
opened while the player happened to be in background-audio mode would have
played with sound and no picture at all, permanently. It restores both now.

### The real cure, for later

media_kit_video 1.3.0 migrated Android from `SurfaceTextureEntry` to Flutter's
`SurfaceProducer`, whose `onSurfaceCleanup` fires when the app is backgrounded —
so from 1.3.0 the library releases the output by itself and none of the above
would be needed. This app is pinned to `^1.2.4`, which predates that callback
entirely and therefore never learns the surface stopped being drained. That is
the whole bug, one version behind. Build 270 is the same code with that pin
moved; this build is the same code without it, for whichever turns out to work.

**Untested on device.** Worth checking, in this order: background play + power
button; then the same after pressing Home instead (screen still on); then
whether the picture comes back correctly on unlock.

## v1.51.0+268 — background play that survives the screen going off (Aug 2026)

The reported bug: background play on, press the power button, sound stops.
Turn the video into the floating window first, expand it back, then lock the
phone — and the same setup works. That contrast was the whole diagnosis last
release too, and the fix shipped in v1.45 was aimed at the right thing. It was
simply too late to land.

### The bug

media_kit hands libmpv a Flutter `SurfaceTexture`, and the thing that drains
that texture is Flutter's raster thread. The instant the display goes off that
thread stops. Nothing calls `updateTexImage` any more, the buffer queue fills —
three or four frames, about a tenth of a second at 30 fps — and libmpv blocks
inside `dequeueBuffer`. mpv's core is what refills the audio ring buffer, so a
blocked core means the audio drains and the sound dies a beat later. That beat
is the hardware buffer emptying, not a timeout.

v1.45 already deselected the video track for exactly this reason, and that is
the correct medicine. But it was triggered from `AppLifecycleState.inactive`,
which on Android cannot tell a screen-off from a pulled notification shade — so
the code armed a **1200 ms timer** and decided later. By then the core is
already blocked, and a blocked core can never process the property write that
would have released it. The fix was not late; it was absent.

**Ask Android instead of guessing.** `ACTION_SCREEN_OFF` is broadcast the moment
the display goes off, before `onStop`, and it means exactly one thing — it is
never sent for a shade or a dialog. A runtime receiver in `MainActivity` now
forwards it to Dart, and the video track is released before the queue can fill
at all. `PowerManager.isInteractive()` is exposed alongside it so the ambiguous
`inactive` path can resolve itself in one cheap round trip: shade keeps its
grace period, screen-off gets none. The 1200 ms timer stays as a third line of
defence for OEM builds that delay the broadcast.

Two smaller things on the same path. `setBackgroundAudioMode(true)` used to
`await` two housekeeping properties **before** the only write that matters;
`vid=no` now goes first, and the housekeeping (already pre-armed at toggle time)
follows. And the screen-off handler is owned by the **controller**, not the
player screen — the screen is popped when a video is sent to the floating
window, and that is precisely when someone is most likely to lock the phone.

### Background audio no longer dies when you leave the player

`PlayerController` is `autoDispose`, and the only two widgets watching it are
the fullscreen player and the floating window. Press Back with background play
on and both are gone, so the controller was disposed a microtask later — while
libmpv was deliberately still playing, because that is what background play
means. Its `dispose()` then stopped the foreground service unconditionally,
taking the ongoing notification and the partial WakeLock with it. Audio kept
coming out of a process Android now considered cached, so it was frozen at the
next screen-off, and there was no notification left to stop it with either.

The service is now stopped only when nothing is meant to keep playing, and the
notification callbacks are handed over to closures bound to the app-scoped
player service rather than nulled — so the buttons stay live after the
controller is gone. The closures capture the service objects, never `_ref`.

### The notification is a real one now (MX parity)

MX Player's background-play notification carries transport controls, which is
the entire point of a notification you cannot see the screen behind. Ours was a
label. It now has **Play/Pause** and **Stop**, updates in place through a new
`ACTION_UPDATE` (no restart, no re-taken WakeLock), and is categorised
`TRANSPORT` instead of `SERVICE` — the old category told Android we were a
housekeeping task, which is why it sorted below everything.

### Expanding the floating window is seamless

The overlay's own comment promised that "the fullscreen player will adopt the
already-running libmpv instance so playback is seamless" — and nothing ever
told the player that. Its `initState` called `openVideo()` unconditionally, so
expanding the little window reloaded the file from disk every time: black
frame, spinner, re-seek. A one-shot, five-second, uri-matched hand-off marker
now carries the fact across the route push, and two independent locks have to
agree (the marker AND the controller still holding that exact file) before the
open is skipped — so a genuine "play this file again" can never silently do
nothing.

### And a picture that can always come back

Background audio works by releasing the video track. The fullscreen player put
it back on `resumed`, but the floating window is not the player — its route was
popped, so nothing there was listening to the lifecycle at all. Lock the phone
with the floating window open, unlock it, and you would have had sound over a
permanently black rectangle. The overlay is mounted for the whole session, so
it now owns that restore while it is the thing showing the video. A second net
covers the OEM builds this codebase has already been bitten by, where
screen-off arrives as `inactive` and the activity is never paused (so there is
no `resumed` to come back on): `ACTION_SCREEN_ON` reattaches, but only when
Flutter itself already considers us foreground.

### Also

A stray `@override` was sitting on the private `_videoDetached` field — a
private field cannot override anything, and the annotation belonged to
`setBackgroundAudioMode`, which really does implement the interface member. Put
back where it goes.

**Untested on device.** Please test, in order: background play + power button
(audio continues, notification shows Pause/Stop); the notification's buttons;
Back with background play on (audio continues, notification stays);
floating window → expand (no reload); lock/unlock with the floating window open
(picture returns).

## v1.50.0+267 — the PIN pad, the picker strip, and four more bugs (Aug 2026)

A polish pass that turned into a bug hunt. The visual work is real, but the
four defects found along the way matter more, and one of them was mine from
last release.

### Bugs

**The keypad vibrated once a second for the whole lockout.** The pad shook and
fired a heavy haptic whenever its error TEXT changed — and the cooling-off
countdown added in v1.49 rewrites that text every second ("wait 15s", "wait
14s"...). So being locked out meant fifteen minutes of the phone buzzing in
the user's hand. The shake predates the countdown; the two were never
considered together. Fixed with an explicit `errorNonce` that only a genuine
new rejection increments, so nothing about the wording can imply a rejection
that did not happen. All three call sites verified by scan.

**Batch unlock could crash the app.** `ref.invalidate()` ran after a copy loop
that can last minutes on a large restore, with no `mounted` guard. Riverpod's
`ref` dies with the State exactly like `context` does, so leaving the vault
mid-restore threw "Cannot use ref functions after the dependency was
disposed" — and the bigger the batch, the likelier it was.

**Imports could leave a privacy trace behind.** The import loop read its
providers per file, after an await. If the user left mid-import the read threw,
the inner best-effort catch swallowed it, and the consequence was silent: the
video was locked into the vault but stayed in public history and resume state.
Providers are now resolved once before the loop, so the cleanup no longer
depends on this widget being alive.

**Opening Anti-theft re-locked the vault behind the user.** Enabling break-in
capture asks for the camera permission; that dialog reads as `inactive`, which
armed the auto-lock underneath. The same failure the picker had in v1.49 —
one door was left. Every route the vault opens now keeps the vault in use.

Also: `_reload()` refused to run during a decoy session but not while LOCKED,
so a picker opened before an auto-lock could pull every vault path and title
back into memory behind a screen saying they were gone.

### PIN keypad

- ITU E.161 letters under the digits, dropped below 58px where they stop being
  legible. The strongest "this is a real keypad" cue there is.
- The error slot is now a fixed height. It used to appear and disappear, so
  the dots and the whole header jumped ~16px on every wrong PIN — on the one
  screen where a thumb is aiming at a fixed target.
- Success flashes the dots green and holds a beat before the screen changes.
- Long-press backspace clears the entry (with the fingerprint key occupying
  the bottom-left there was no dedicated clear).
- Auto-submit moved to a cancellable timer, so a sixth digit typed quickly
  after a fourth cancels the four-digit submit instead of racing it — real and
  decoy PINs can legitimately differ in length.
- Semantics labels on every key.

### File picker

- **The selected category could be off screen.** Five chips do not fit a 360dp
  phone, so a user on Apps saw a strip with nothing visibly selected. The
  active chip is now scrolled into view.
- Both edges fade, so a clipped chip reads as "there is more this way" instead
  of a hard crop.
- Animated pill selection with a soft lift, icon scale, and a haptic.
- A count badge per category: tick four videos, move to Images, and it is no
  longer possible to forget what the Add button is about to move.
- Height follows the text scale; theme tokens replace the hardcoded
  `Colors.white12` / `withOpacity` literals; hairline under the strip.
- **Sort by size did nothing in Videos, Images and Audio.** Every media item
  reported zero bytes, so the size chip never rendered and the sort option
  silently did nothing. It was lazy because the old code loaded whole buckets;
  bounded to a 120-item page it is affordable, and now both work.
- **Folder thumbnails fetched 120 files to use one.** A grid of 30 folders
  meant 3 600 platform round-trips for 30 previews. Now one.
- The bottom bar shows the total SIZE about to be moved (12 films is not 12
  screenshots), a Clear all, and slides in. The total is hidden entirely
  rather than shown wrong when any file's size is unknown.
- All 13 empty states get an icon and real typography, and errors are now
  visually distinct from "this folder is empty".

### Verification

New `runtime_bugs.py` checker (context/ref across async gaps, undisposed
controllers, awaited-own-dialog). It initially MISSED two of the bugs above
because it treated `if (mounted) doOneThing();` as guarding the rest of the
scope — it guards that one statement. Corrected, taught about `else` branches
and getters, then negative-tested: 5 injected faults, 5 caught.

Also simulated, outside the app: the PIN hash migration matrix across all five
stored formats (nobody is locked out by the v1.49 KDF change) and the shared
attempt limiter across 30 attempts and all four tiers.

Dart-only release. UNTESTED on device.

## v1.49.0+266 — the Private Folder, audited end to end (Aug 2026)

A full security + UX pass over the vault. The headline is that three of the
findings were not "could be better" — they were features that did not do what
the screen said they did.

### The three that mattered

**The decoy PIN leaked the real vault.** Entering the decoy PIN correctly
showed an empty vault. But a dozen ordinary actions ended by re-reading the
store and assigning the result straight to the entry list — and Refresh in the
overflow menu was one of them. One tap and the complete hidden file list
appeared, in front of exactly the person the decoy exists to deceive. Delete,
rename, move and every batch operation had the same ending.
Fixed structurally rather than with a dozen scattered checks: `_reload()` is
now the ONE path that pulls real data into the UI and it refuses to run during
a decoy session, and mutations go through a `_decoyEdit()` helper that applies
them to the in-memory list only. A future action that forgets to think about
the decoy inherits the correct behaviour instead of reopening the hole. Proven
with a mechanical scan over all 47 methods in the screen, negative-tested by
re-injecting the original bug.

**The vault was being uploaded to Google Drive.** `android:allowBackup` was
unset, so it defaulted to true, and the vault lives in `getApplicationSupport`
— which on Android is `filesDir`, squarely inside Android Auto Backup's scope.
Every file the user hid was eligible to be copied to a cloud account they were
never asked about. The same default carried a second, quieter failure:
flutter_secure_storage keeps the PIN hash and the vault index as ciphertext in
SharedPreferences with the key in the hardware keystore, and the key is never
part of a backup. A restore therefore brought back an undecryptable blob, the
app concluded no PIN was set, and every vaulted file became an unreachable
random-named file. Now excluded from BOTH cloud backup and device-to-device
transfer (a separate channel that is easy to miss and copies far more), on
both the pre-12 and 12+ rule formats. Ordinary settings and history still back
up normally.

**Anyone could screenshot the vault, and Android already had.** No FLAG_SECURE
anywhere in the app. Screen recording worked, screenshots worked, and the
recents/app-switcher preview showed the unlocked file list with no PIN in the
way at all. Now blocked across the vault screen, the PIN pad, the image
viewer, both recovery screens, anti-theft, and private playback — through a
REF-COUNTED service, because the flag is one global Window flag in a
single-Activity app and a naive set-on-enter/clear-on-exit would have let a
closing image viewer silently unprotect the list underneath it.

### Also closed

- **Recovery had no rate limit at all.** The PIN pad counted failures,
  escalated, and persisted the count. "Forgot PIN?" counted nothing and waited
  for nothing — and a proven security answer grants a full PIN reset, so
  guessing a pet's name was the cheapest attack on the vault and every
  hardening measure on the PIN pad was decoration next to it. One
  service-owned limiter is now shared by the PIN pad, the security question
  and the recovery key: 5 misses → 15s, 10 → 1min, 15 → 5min, 20+ → 15min,
  persisted, and enforced against biometric unlock too.
- **PIN hashing was one round of SHA-256.** A 4-digit PIN is ten thousand
  possibilities; one SHA-256 round over that is a rounding error. Now
  PBKDF2-HMAC-SHA256 with a round count each device MEASURES for itself
  (~320 ms budget) and stores inside the hash string, run on an isolate so the
  keypad never freezes. All three previous hash formats still verify and are
  silently upgraded on the next correct entry — nobody is locked out of their
  own vault by the fix. Verified against RFC test vectors up to 120 000
  rounds. Comparison is constant-time. Being honest: this raises the cost of
  an offline attack by orders of magnitude, it does not eliminate it — a
  4-digit PIN cannot be made offline-safe by a KDF alone, and the keystore and
  the limiter carry more of the weight.
- **Auto-lock fought the user.** It re-locked on `inactive`, which is
  ambiguous — it covers a screen turning off, but equally a pulled
  notification shade or a permission dialog. Adding files asks for a media
  permission, so the vault threw the user out onto the PIN pad every single
  time they used the picker. Now `paused` is treated as real, `inactive` has
  to prove itself by lasting (with a floor, because some OEM builds report
  screen-off as `inactive` and never reach `paused` — the same device
  behaviour that broke background audio here in v0.97), and flows that pop a
  system surface suppress it explicitly. Grace period is configurable:
  Immediately / 30s / 1min / 5min.
- **Batch unlock aborted silently.** An integrity failure on file three threw
  straight out of the loop: files four onward were skipped, the list never
  refreshed, and nothing at all was shown. Every file is now attempted and the
  result reported honestly.
- **`build()` did blocking disk I/O.** The storage total called `existsSync()`
  + `lengthSync()` per entry during layout — two blocking syscalls per file on
  the UI thread, on every reload. Measured asynchronously now.

### Premium pass

- **A real PIN keypad** replaces the system keyboard everywhere: dot
  indicator, damped-sine shake on error, press-scale, haptics, auto-submit at
  the stored PIN length. Not only cosmetic — the soft keyboard is a
  third-party app that saw every digit of the vault PIN. Setup, unlock,
  change-PIN and decoy-PIN now share ONE surface, which is also why the decoy
  can no longer be told apart from the real thing by how it behaves.
- **Import and restore show progress**: current file, per-file bar, overall
  bar, live MB/s, and a Cancel that takes effect between chunks. `File.copy()`
  gave none of that and left partial files behind on failure; the copy is
  streamed now, with back-pressure, and cleans up after itself.
- **The picker stops loading whole buckets.** It asked MediaStore for every
  asset in a folder and then resolved a file path for each — 5 000 platform
  round-trips before one row could be drawn in a big Camera folder. Paged at
  120 with lead-in prefetch: first paint is bounded by the page, not the
  library.
- **Break-in log now records what was typed** and which door was tried (PIN /
  security question / recovery key), matching what Keepsafe and Vault offer.
  A run of 1234/0000 reads as a stranger; a near-miss of the owner's own PIN
  reads as someone who has watched them unlock it. Only wrong entries are ever
  stored.

Native changes: `MainActivity` gains `mx_clone/secure_screen`; new
`backup_rules.xml` and `data_extraction_rules.xml`; manifest wires both.
20 new strings across en/my/th. UNTESTED on device.

## v1.48.0+265 — Measured against Zapya (Aug 2026)

This release started as a comparison rather than a feature list. Zapya's actual
feature set was gone through item by item against what Innocent now does, and
this closes the gaps that turned out to matter — plus a bug the comparison
exposed.

### Where the two stand

Innocent already matches Zapya on the things people use it for: a radar that
finds the other phone by name, QR pairing, a direct Wi-Fi link instead of the
router, group sending to several phones at once, whole folders, and sending the
app itself to someone who doesn't have it. On two counts Innocent is ahead —
transfers resume byte-for-byte after a drop or a reboot, which Zapya does not
advertise at all, and there are no ads.

Zapya is genuinely ahead on two things this release does not attempt. It has
native clients on iOS, Windows and macOS, and it has Phone Replication —
migrating contacts, messages and call logs to a new handset. Contacts and SMS
would mean permissions a media player has no business holding, so that stays
out on purpose.

### A browser is now a full peer

The address Innocent serves has always let any browser download. It can now
**upload** too: open the address on an iPhone, a Windows laptop, anything with
a browser, and send files back to the phone. Choose files or drag them in,
with a progress bar per file.

That is the practical answer to Zapya's native clients. It doesn't need one
written for each platform, and there is nothing to install on the other side.
Implementation note: the page posts raw bytes with the filename in the query
string rather than a multipart form, so the Dart side needs no multipart
parser — `mime` is only a transitive dependency here, and pinning it directly
has broken this project's dependency solve before.

### Received files actually open now

Tapping a received file used to show its path and nothing else unless it was
video or audio. It now hands the file to whichever app owns it, through a
FileProvider — Android 7 and later refuse a `file://` URI across an app
boundary, which is why this needed a provider rather than an intent.

For an APK that means the package installer. This is the flow the whole
feature exists for in this market: a friend hands you an app over Wi-Fi with no
data involved, and you install it. Android 8+ gates that behind a per-app
switch, so Innocent checks first and explains, instead of dropping you on a
system screen with no idea why you're there.

### The bug the comparison found

**Files added after Start were never actually shared.** `addFiles` updated the
sender's on-screen list, but the running server keeps its own copy that was
only ever filled once, at Start. Picking more photos mid-share showed them on
your screen and served a stale manifest — the other phone could not see them
and nothing said why.

Fixed, with two consequences worth stating. New files are appended and indices
never move, because a receiver already holds indices into that list; renumbering
would have it download the wrong bytes under the right name. For the same
reason removing a file mid-share is now blocked rather than silently
repointing everything after it. And the receiver gets a refresh button, since
the sender can now add to a live share.

### One more path-escape, found by fuzzing

The upload filename and the manifest filename are both attacker-controlled, and
both were stripped of separators and control characters. A 30 000-case fuzz
found exactly one survivor: a name of precisely `..` contains no separator, so
it passed through untouched and then resolved to the parent folder. Both call
sites now reject `.`, `..` and blank names. Re-fuzzed at 60 000 cases plus the
targeted forms — zero escapes.

### Verification

Thirteen automated checks, all negative-tested. One was extended this release
after it missed five undeclared strings: the AppStrings check only understood
`final s = AppStrings.of(context)` and was blind to an explicitly-typed
`AppStrings s` parameter, which is how those five got in. Beyond that: upload
name sanitising, append-only index safety, and filename HTML escaping against
XSS probes were each simulated separately.

Still untested on a phone.

---

## v1.47.1+264 — build fix (Aug 2026)

v1.47.0 did not compile. Three string keys — `noHistoryYet`, `pinLabel` and
`enterPin` — were each declared twice, because app_strings.dart is 3400 lines
and a new block was appended without checking whether those names were already
taken. Dart rejects both the repeated getter and the repeated const-map key.

The completeness check could not see it: it compared en/my/th as sets, and a
set silently collapses duplicates, so all three locales matched perfectly while
none of them would build. The check now counts occurrences instead, and the
exact failure was reproduced against it before and after the fix.

`pinLabel` was already 'PIN' in all three locales, so the duplicate was dropped
and the existing key reused. The other two carried different meanings — the old
`noHistoryYet` is the watch-history screen's, and `enterPin` is the vault's
generic prompt — so the Transfer versions were renamed rather than folded into
strings that would have read wrongly.

### Found while fixing it

Because the build died inside the localisation file, nothing written in v1.46
or v1.47 had been type-checked even once. A pass over that code for the classes
of error a structural check cannot see turned up four more things:

**A silent Start button.** With Turbo armed, Start can take most of half a
minute while the radio negotiates, and the screen showed nothing at all — no
spinner, no disabled state. People would have tapped it again. It now shows
what it is waiting for.

**A wrong PIN said nothing.** Mistyping the code re-showed an identical empty
box with no indication anything had gone wrong. It now says so.

**A folder picker that lied.** Backing out of the folder browser without
choosing anything still reported "folder added", and the warning shown when a
folder exceeds the 3000-file cap was posted to a screen that was closing, so
nobody would ever have seen it. Both now report what actually happened.

**A newer Flutter API than the project builds against.** The folder browser
used `PopScope.onPopInvokedWithResult`; every other PopScope in the codebase
uses `onPopInvoked`. Matched to the tree rather than to the newest docs.

Five unused strings left over from iteration were removed rather than shipped —
an unused key is a promise the UI never keeps.

---

## v1.47.0+263 — Transfer: the last five things (Aug 2026)

v1.46 made the Transfer tab findable and fast. This release closes what was
still missing: the transfer loop moves off the UI thread, both sides can pause,
whole folders can be sent with their structure intact, sending to several
phones at once is finally legible, and a share can be locked with a PIN.

### The download loop no longer fights the UI

At 25 MB/s the socket pump wakes hundreds of times a second. On the UI isolate
it was taking turns with every widget rebuild, so a busy frame throttled the
transfer and a fast transfer janked the list — each making the other worse.

The byte-moving half now lives in `download_isolate.dart` and runs on a
background isolate. Two things are worth knowing about how it is built.

**One implementation, two hosts.** The engine is a plain class with no Flutter
imports at all, and both the isolate and the in-process fallback run the same
code. If `Isolate.spawn` fails for any reason the transfer still works, at the
old speed, with no separate code path that could quietly drift out of step.

**No platform channel crosses the boundary.** Every path is resolved on the
main isolate before the job is handed over, so the worker only ever sees an
absolute `.part` file to write. Media scanning, the resume record, history and
the final rename all stay where the plugins already are.

### Pause, on either side

The data plane is a pull, so a sender cannot "stop sending" — it has to tell
the puller to come back. Pausing now answers file requests with 503 and a
Retry-After, and cuts any stream already in flight at its next block boundary.
`/ping`, `/pair` and `/manifest` keep answering, so the other phone can still
see that you are there and why nothing is moving.

The receiving side treats 503 as a wait rather than a failure: it does not
consume the retry budget, and every partial file stays exactly where it is. A
parallel download handles the pause per segment, which matters more than it
sounds — letting it bubble up would abort the run and throw away all eight
segments' progress. A pause can last ten minutes before it is called a failure,
because a pause is a deliberate human act and killing someone's transfer after
thirty seconds would be worse than useless.

The receiver can pause too. Pause and Cancel sit side by side on purpose: one
keeps every downloaded byte, the other does not, and that is exactly the
distinction that needs to be visible at the moment of choosing.

### Whole folders

Pick a folder and the tree arrives intact. Each file carries its position in
the manifest, and the receiver rebuilds the directories under `Innocent/`
instead of sorting a hundred-photo album into `Photos/` with its structure gone
and its names colliding.

The relative path is the one place a remote peer gets to influence a filesystem
path, so it is treated as hostile: absolute paths, drive letters, `..`, `.`,
empty segments and control characters are all dropped, and depth is capped.
Thirty thousand fuzzed paths and every hostile form we could think of stay
inside the storage root.

The folder browser is deliberately its own small screen rather than a change to
the Private Folder's picker. That picker is 1750 lines shared with the vault
import, and bending it to also return a directory would have put the vault at
risk for a feature that needs one screen and one button.

### Sending to several phones

The server always served any number of clients at once — but it lumped
everyone's bytes into one total, so with two phones pulling, the numbers meant
nothing. Bytes are now counted per receiver, listed per receiver, and the
headline bar follows whichever phone is furthest along rather than summing them
into a number over 100%.

### A PIN, and a straight answer about encryption

A share can now require a four-digit code, shown on the sender's screen. That
closes the realistic risk on a shared Wi-Fi, which is not someone cracking a
36-character token — it is a stranger seeing your phone in their list and
tapping it.

On encryption we are not going to pretend. **Turbo already encrypts everything:
the link is WPA2, so files are protected in the air.** Over an ordinary Wi-Fi
network the transfer is plain HTTP and is not encrypted, the same as Zapya. We
considered AES over HTTP and rejected it — Dart has no hardware AES, so it
would cost most of the speed this feature exists for — and we rejected a
self-signed TLS certificate too, because a private key shipped inside the APK
protects nobody. The app now says which of the two modes you are in, and the
honest advice is: on a network you don't trust, use Turbo or use the PIN.

### Also

Every string in the Transfer tab is now in Burmese, Thai and English, including
the two that had been left in English. A per-file download button is disabled
while a batch runs, because the engine takes one job at a time and "a job is
already running" tells the user nothing.

### Verification

Thirteen automated checks, each proven to fire against a deliberately broken
copy of the tree — a check never shown to fail is not evidence of anything. Two
were written this release after finding bugs nothing else caught: a callback
that gained a fourth argument while a call site still passed three, and a state
field used before it existed. Both had passed every existing check, because the
shape was fine and only the meaning was wrong. Beyond that: the path sanitiser,
the pause protocol, the PIN gate, the per-receiver accounting and the isolate
message protocol were each simulated separately.

Still untested on a phone, deliberately — the whole of this and the previous
release were built in one pass to avoid a long test-and-patch cycle. If Turbo
turns out not to work on a particular handset, everything else stands on its
own over ordinary Wi-Fi.

---

## v1.46.0+262 — Transfer becomes a Zapya replacement (Aug 2026)

The Transfer tab worked, but it was not competitive. Two phones could only find
each other if somebody scanned a QR code or typed
`http://192.168.x.y:8765/<36-character-token>` by hand, and once connected the
throughput sat around 1-3 MB/s against Zapya's 20-30. This release closes both
gaps and fixes ten real bugs found while reading the existing code.

### The bugs that were already there

**A fresh `HttpClient` per file.** Every file in a batch opened its own client
and therefore its own TCP connection. Sending 300 photos meant 300 handshakes
paid back to back — the actual reason many small files felt so much slower than
one large video. There is now one pooled client per batch, so HTTP keep-alive
holds the sockets open across files.

**`sink.add()` has no back-pressure.** When the Wi-Fi link is faster than the
flash write — routine at 20+ MB/s on cheap eMMC — unwritten chunks pile up in
RAM until the OS kills the app. Switched to `sink.addStream`, which pauses the
socket while the disk catches up. Safer, and in practice faster, because the
buffer stays cache-warm.

**One cancel disabled the fast path for good.** `downloadOne` never cleared the
cancel flag, so after a single cancel every guard kept reading a stale `true`
and individual downloads silently lost parallel segmenting and their retries
until the next Download-all.

**Suffix ranges served the whole file.** `bytes=-500` means "the last 500
bytes". The parser read the empty start as null, fell through, and returned the
entire file with a 200. Media players and download managers do use that form.

**There was no cancel button.** Once a receive started there was no way to stop
it from anywhere in the UI.

Also fixed: no whole-batch progress or ETA; the sender was completely blind to
who had connected or how far along they were; no free-space check before a
batch; a create-and-delete write probe ran per file when resolving the
destination folder (500 files, 500 probes); MediaScanner and the resume record
were written once per file, making a large batch quadratic.

### Finding the other phone

The sending phone now announces itself over UDP and appears by name in a
Nearby-devices list. One tap connects. A probe goes out the moment the Receive
tab opens and every sender answers by unicast, so devices show up in well under
a second rather than waiting for the next beacon.

The broadcast deliberately carries no share token. Anyone on a teashop Wi-Fi
can read a broadcast, so the receiver has to ask over HTTP for it; that
handshake is also what lets the sender display "Ko Ko's phone connected" and
offer an approve-before-sending switch for public networks.

This needs a Wi-Fi MulticastLock on the native side. Without one Android drops
broadcast frames not addressed to the device, which is exactly why this class
of feature "works on my phone" and mysteriously finds nothing on someone
else's.

### Turbo — the direct link

Parallel TCP streams are the whole of what software can do about speed. The
rest is physical: through a router every byte crosses the air twice, on a
channel shared with everyone else on that router.

Turbo puts the two phones on their own radio link. It uses a Wi-Fi Direct
autonomous group, which is the only public Android API that lets an ordinary
app choose the network name, the passphrase **and** the 5 GHz band — and 5 GHz
is what makes 20-30 MB/s reachable at all. Android's own documentation notes
that a group owner is an ordinary access point that non-P2P clients can join,
which is how the receiving phone connects. On Android 8-9, where that API does
not exist, it falls back to a local-only hotspot; that is 2.4 GHz, but it still
removes the router hop.

**On the band, honestly.** Most Wi-Fi chips only manage single channel
concurrency: with the phone connected to a Wi-Fi network, the group is dragged
onto that network's channel, and `createGroup` reports success anyway. So the
badge reads the group's *measured* frequency rather than the band we asked for,
and when it lands on 2.4 GHz because of this it says so and tells you what to
change. For the fastest link, disconnect the sending phone from Wi-Fi first —
leaving Wi-Fi itself switched on, since Turbo needs the radio, not the network.

The QR code becomes an `innocent://turbo` invite carrying the credentials,
because under Turbo no URL is reachable until the other phone has joined. When
Turbo is off the QR stays a plain http address, so older builds of Innocent can
still scan a new one. The network name and password are also shown as plain
text, so a phone that does not have Innocent yet can join by hand and download
the APK from its browser.

**While Turbo is joined, the receiving phone has no internet.** That is
inherent — the process is pinned to a link with no route out, which is the only
way Android will send traffic over it at all. There is a prominent Disconnect
button, the pin is released when the Transfer screen closes, and if nothing is
transferring for three minutes it lets go by itself.

### Everything else

Received files are now listed and can be opened straight from the app.
A dismissible notification reports the result, because the ongoing one
disappears with the service and someone who left the app during a 2 GB transfer
would otherwise get no signal at all. A Send-the-Innocent-app button adds the
APK to the share, for handing the app to someone with no data. Files already on
the receiving phone byte-for-byte are skipped. Both phones can be renamed. A
download starts automatically once you connect, the way every app in this
category behaves. And the QR is no longer re-encoded once a second: the sender
pane rebuilds continuously to show live byte counts, and rebuilding a QR matrix
on each pass is CPU stolen from the transfer itself.

### Known and deliberate

Turbo needs the Nearby-devices permission on Android 13+, and on Android 12 and
below the platform requires Location — permission and master toggle both — for
the very same Wi-Fi calls. Innocent never reads your position; the permission is
declared `neverForLocation` where the OS supports saying so, and capped at
Android 12 where it does not.

Not in this release: sender-side pause, recursive folder send, sending to
several receivers at once, and end-to-end encryption. The transfer is plain
HTTP over the local link, the same as Zapya, but a shared-Wi-Fi PIN is worth
adding.

---

## v1.45.0+261 — background audio survives screen-off (Aug 2026)

### Background play stopped the moment the screen went off
Your own observation was the diagnosis: with the pop-up window open it kept
playing, without it it stopped. The pop-up keeps a live video surface; turning
the screen off destroys it.

This is a well-documented class of bug rather than anything unusual. A player
still bound to a video surface stalls when that surface disappears, and the
couple of seconds of audio you hear afterwards is just the hardware audio
buffer draining. A wake lock cannot help — nothing is waiting on the CPU.
Players that get this right (VLC among them) detach the video layer and let the
audio thread carry on alone.

Our code explicitly declined to do that:

    // Note: we intentionally do NOT set vid=no — keeping the video track
    // selected means resuming to foreground shows the frame instantly.

That trade is upside down. It bought a fraction of a second on return by giving
up background audio entirely.

**`vid=no`, deliberately not `vo=null`.** mpv-android #1076 documents `vo=null`
putting MediaCodec into a deadloop on Android 14/15 that hangs the app on
return. Deselecting the video track shuts the decoder down cleanly instead of
leaving it waiting on a surface that is never coming back, and mpv re-syncs the
picture to the audio clock by itself when the track comes back.

**The timing matters as much as the property.** Detaching when you flip the
toggle would make the picture vanish mid-film, so the toggle only pre-arms the
harmless part. The detach happens on an actual background transition. And
because `inactive` is ambiguous — it covers screen-off, but also a pulled
notification shade or a permission dialog, moments when the video is still on
screen — `inactive` only *arms* the detach on a short timer. Come back within
about a second and nothing ever flickered.

System PiP is exempt: the surface is alive there and showing the picture is the
entire point.

Opening any file now also reattaches the video track first, so a video opened
while the player happened to be in background mode can't come up with no
picture and no way back.

### The rotate button had no way back to automatic
It read the current orientation and flipped to the other, so it could only ever
*pin* the device. The first tap overrode your phone's own auto-rotate and
nothing in the player could hand it back — straighten out one awkward clip and
you were stuck with a fixed orientation for every video that session.

It now cycles Auto → Portrait → Landscape → Auto, the way MX Player's does, and
names the mode as you pass through it. Portrait includes upside-down and Auto
includes all four orientations, so a phone held either way behaves like it does
everywhere else.

### Crashes when leaving the player at the wrong moment
The player controller is the one piece of state in the app that is thrown away
when you leave the screen. Eight places wrote to it *after* an await — after a
platform round-trip to change the audio track, set the speed, mute, resume, or
restore per-video settings. Leaving during any of those windows meant writing
to a disposed object, which throws. Tapping Mute or picking an audio track and
immediately pressing Back is a normal thing to do; the awaits in between are
real. All eight now check first.

### Audited and found correct
The sleep timer (wall-clock deadline, survives timer throttling, releases the
wake lock and the foreground service when it fires) and the equalizer and voice
effects (real native effect chain, sharing one audio session id with the
playback engine — session 0 would be silently ignored on modern Android — with
the tuning persisted and re-applied on every video) both hold up. No changes
needed there.

## v1.44.1+260 — switching decoder no longer restarts the video (Aug 2026)

### The bug
Changing HW/SW mid-playback sent the video back to 00:00. It should carry on
from where you were, the way MX Player does.

### Why
The app was doing the job twice. Writing libmpv's `hwdec` property **is** the
decoder switch — mpv's own command handler reinitialises the decoder in place
and then seeks back to the frame you were on:

    mp_decoder_wrapper_control(dec, VDCTRL_REINIT, NULL);
    double last_pts = mpctx->video_pts;
    if (last_pts != MP_NOPTS_VALUE)
        queue_seek(mpctx, MPSEEK_ABSOLUTE, last_pts, MPSEEK_EXACT, 0);
                                              -- mpv, player/command.c

It is a designed runtime toggle; mpv's own Ctrl+h binding flips hwdec during
playback for exactly this reason. Our code set the property — so the switch had
already completed correctly — and then reopened the file on top of it.

The reopen is what lost your place. `Player.open()` issues `loadfile` and
returns before the demuxer has the file open, so the seek fired immediately
afterwards had nothing to seek in. It threw, the catch swallowed it, and
playback carried on from the beginning of the freshly loaded file.

It had a second symptom too: on a local file, "Default" and "HW" both resolve to
the same hwdec mode, so picking one after the other restarted the video to
change nothing whatsoever.

### The fix
The reopen is gone. The switch is now one property write, and mpv restores the
exact frame itself — so it is also much faster than it was.

If a device's driver refuses the requested mode, libmpv keeps the decoder it
already had and playback is undisturbed; the previous code would have reloaded
the file regardless.

### Related, found while fixing it
- **Resuming now uses mpv's own `start` option.** Seeking after `open()` was
  always a race for the same reason as above. `start` is read while the file is
  being loaded, so the demuxer begins at the right place — no race, and no
  moment where frame 0 is decoded and shown before the jump. The old seek is
  kept as a fallback, because silently resuming a two-hour film from the
  beginning is a far worse failure than one redundant keyframe seek.
- **A rejected decoder mode is no longer remembered as applied.** The requested
  mode was cached before libmpv had accepted it, so on a device that refuses one
  every later attempt to select it became a no-op — the switch appeared
  permanently stuck.
- **A resume point can no longer be overwritten with zero.** During a network
  auto-retry the position reads 0 for a moment; if the five-second save landed
  in that window it wrote 0 over a real resume point.

## v1.44.0+259 — settings that were lying (Aug 2026)

Three settings existed in two places each, and in every case the copy people
find first was the dead one. That is worse than a missing feature: the app
appears to take an instruction and then ignores it.

### App language did nothing — and offered languages that don't exist
Settings → General → "App language" wrote a value nothing read, then showed a
toast saying the change would apply after a restart. There was no code anywhere
to apply it, at any point. A second, real Language screen worked fine, so which
screen you happened to open decided whether changing the language worked.

It also offered Chinese, Japanese, Korean and Hindi. The app has English,
Burmese and Thai. Even wired up, choosing Korean could only have shown English —
a picker that lists languages it cannot display is a promise the app cannot
keep, so those four are gone. The remaining picker drives the real setting, so
the app re-renders immediately, and both screens now read one shared list and
can never disagree.

### "Recognize .nomedia" was stored twice and honoured never
The Videos list's own sort sheet has this switch. So does Settings → List. They
saved to two separate values, so turning one on left the other looking off — and
no code anywhere used either one to filter the library. The feature simply did
not exist.

It exists now, with MX Player's actual rule: a file is hidden if a `.nomedia`
sits in its folder **or any folder above it**. The inheritance is the part that
matters — one `.nomedia` at the top of a tree is how apps like WhatsApp mark
everything beneath it, and checking only the file's own folder would have left
most of it showing.

Opening such a folder deliberately still shows its contents. `.nomedia` is an
indexing hint, not a lock, and MX treats it the same way.

The cost is small and bounded: each folder is walked upward once and every
directory on the way is remembered in the same pass, so a library of two
thousand videos across eighty folders does tens of file checks, not thousands.
With the setting off it does none.

"Show hidden files and folders" had the same split-brain problem and is fixed
the same way — both screens now drive the state the library actually reads.

### Eleven more switches connected
- **Full screen** — hide the status and navigation bars, or don't. The bars were
  always hidden; some people want the clock and battery while watching.
- **Lock screen on rotation** — rotating is when the phone is most likely to be
  in a hand, a bag or a lap, so it's when a stray touch is most likely. That's
  why MX offers this.
- **Play alone** — whether to take exclusive audio focus. Off, your podcast
  keeps playing alongside. (Focus *events* are still watched either way — an
  incoming call must duck the video regardless.)
- **Toggle playback with play button** — off, the button only starts playback
  and can't pause. For handing the phone to a child.
- **Limit Video Resizing** — caps pinch zoom at 2x. Past that on a 1080p source
  you're magnifying compression artefacts, not seeing more.
- **Floating button** — the Resume button can now be turned off.
- **Allow editing** — off, the app won't delete or modify your files. Delete
  used to work regardless.
- **Delete subtitle files together** — a sidecar subtitle is useless once its
  video is gone. Only exact `name.ext` matches are removed; never a file that
  merely starts the same.
- **Cache thumbnail** — off, thumbnails are still generated and still kept in
  memory for the session, they just aren't written to disk. That's the point of
  it on a shared phone.
- **File extensions** — the list you type in Settings now reaches the scanner.
- **Show source URL** — the stream's address under the title, for network
  playback only.

That takes the settings that actually do something from 63 of 145 at the start
of this work to 109 of 145.

### Three more defaults corrected
Same reasoning as last release: connecting a switch nobody had read raises the
question of what the app did while it was ignored, and the stored default was
the opposite of the real behaviour. The default is the arbitrary part — it was
chosen when the switch was inert — so it's what moved. **Play alone** and
**Toggle playback** were `false` (the player has always taken focus and always
toggled), and **Full screen** was `false` (the bars have always been hidden).
All three are now `true`, so nothing changes for anyone who never touched them.

### What is deliberately still not connected
Roughly thirty-five settings remain inert, and they are honest about needing
real work rather than a wire: battery level and headset multi-press need native
code, `.nomedia`-style legacy MX options (`Android 4.0 mode`, `TV mode`,
`Custom codec`) don't map to anything this app does, and the software-audio
decoder switches don't apply because libmpv already decodes audio in software
on Android. Listing them here is more useful than quietly connecting them to
something that isn't what they say.

## v1.43.0+258 — NEW that means new, and switches that switch (Aug 2026)

### The NEW tag now goes away when you watch something
MX Player documents its own rule, and half of it was missing here. Theirs is:
*"NEW: Copied or modified files within 7 days, which have no playback record."*
Ours only checked the first half, so a video kept its NEW tag for the rest of
the week after you had watched it — which is the one thing the tag exists to
tell you.

It is now the AND of both halves, in one place instead of copied into four, and
"copied **or** modified" means exactly that: re-encoding a file in place updates
its modified date but not its added date, and the old check only looked at the
latter. The tag disappearing when you watch something also means it can come
back if the record goes — after "Clear history", or a reinstall. That is MX
Player's behaviour too, and it is the honest one: the badge means "you have not
watched this", so if the app genuinely no longer knows, it should say so.

**The red number on folders was never real.** It looked at one file per folder,
hard-coded seven days, ignored playback records, and could only ever say "1".
A folder with six unwatched new episodes showed a badge reading 1, and a folder
you had finished still showed it. It is now counted properly, from the video
list the app already has in memory, so it costs no extra scan and always agrees
with the badges on the files inside.

**"Recently added" was showing the wrong ten videos.** It took ten and then
sorted those ten, instead of sorting and then taking ten — so copying ten new
episodes onto a phone with a large library could miss every one of them. Its
NEW badges were painted on unconditionally, too.

### 82 settings did nothing at all
Every setting key was checked against the whole codebase for a reader outside
the settings screens themselves. 82 of 145 had none: a label, a description, a
saved value, and nothing anywhere that looked at it. 36 of those are now
connected.

**Four went straight to the video engine** — Fast seeking, Deinterlace (the
comb-shaped tearing on DVD rips and TV captures), Use speedup tricks, and
subtitle Italic. One property each; there was simply no wire between the switch
and the engine.

**Six control what you see** — Show seek bar, Show previous/next buttons, Show
title, Show system clock, and the two seek-preview switches (the thumbnail
bubble appeared for everyone regardless, and network previews now have their
own switch because pulling frames from a remote file spends your data).

**Five change how it behaves** — Smart Previous (past five seconds in, Previous
restarts what you are watching instead of jumping to the one before, which is
what you actually want forty minutes into an episode), Pause on headset
disconnected, Auto brightness (on, the player stops touching screen brightness
at all, including via the swipe), Background play as the default for the
in-player toggle, and Tap to show/hide controls.

**System volume** decides whose volume the swipe moves: the phone's media volume
as before, or only this player's, leaving the device where you left it.

**The Debug section had three switches and no overlay to control.** Show buffer
info, Show decoder info and Show FPS now draw a small stats panel built entirely
from data the player already had — decoder and codec, resolution and bitrate,
audio track, video frame rate, and how far ahead the buffer has read. The frame
rate is labelled "video FPS" on purpose: it is what the file contains, not what
the screen is managing to draw, and confusing those two sends you chasing the
wrong problem.

**"Subtitle folder" was a text box nothing read**, so only subtitles sitting
next to the video were ever found.

**Half the decoder grid was ignored.** "Use HW decoder for local files" and
"...for network streams" had no readers — only the software side of the same
grid did — so turning hardware decoding off for network streams did nothing.
Debug's "Disable hardware acceleration" was inert too.

**The Customise Items screen saved nothing.** A master switch and fifteen
checkboxes, all writing to state that is thrown away the moment the player
closes, so every video came back with the stock four icons.

### Some switches disagreed with what the app was actually doing
Connecting a switch nobody had ever read raises a question the switch cannot
answer: what did the app do while it was being ignored? For five of them the
saved default was the opposite of the real behaviour, and honouring it would
have changed the app under people who never touched the setting. The default is
the part that was arbitrary — it was picked when the switch did nothing — so
that is what moved:

- **Use HW decoder (local / network)** were `false`. Left alone, connecting them
  would have put **every user on software decoding for every video** — several
  times the CPU, a hot phone, and the battery gone by lunch. Now `true`, which
  is what the player has always done.
- **Background play** was `true`. It would have started a foreground service and
  a wake lock on every video for everyone. Now `false`, like MX Player's.
- **Fast seeking** was `true`; the player has always seeked precisely, and
  landing exactly where you release the bar was deliberate. Now `false`.
- **Use speedup tricks** was `false`; the engine has always had them on. Turning
  them off would have made software decoding slower and hotter on exactly the
  weak devices that need them. Now `true`.

### Three sort options were decoration
"Played time", "Status" and "Type" all fell through to the same branch and
sorted by date — the sheet closed, the checkmark moved, the list came back
unchanged. All three work now (Status groups as not-started → in progress →
finished, with 95% counting as finished because nobody watches the credits).
"Frame rate" is deliberately still a fallback: the frame rate is not in the
media index, so honouring it means probing every file in the folder, which is a
feature rather than a fix.

### Smaller ones
- Watch count was counting SAVES, not plays: one viewing of a feature-length
  film reported over a hundred watches.
- Each video tile scanned the entire watch history to draw its progress bar —
  twenty tiles on screen meant four thousand string comparisons every time a
  position was saved. One prebuilt lookup now, narrowed so a save for one video
  rebuilds nothing on the others.
- "Audio device" had an if/else whose two branches did the same thing, which
  made the setting look wired while doing nothing. Android does not let an app
  pick its output route; the code now says so instead of pretending.
- Two files imported each other after this work; the provider causing it never
  belonged to either and now lives on its own. A file that imported itself no
  longer does.

## v1.42.2+257 — battery and heat (Aug 2026)

Nothing about how the app works changes here. Every item is work the app was
doing that produced no result you could see, and each one costs battery.

### The screen stayed awake even when nothing was playing
This is the big one, and it is worth putting first because on a phone the
display uses more power than decoding the video does. The player asked Android
to keep the screen on the moment it opened and only released it when you left.
Pause a film and put the phone down and the screen stayed lit — not until the
normal timeout, but indefinitely, because our request overrode it. The screen
now stays on while something is actually playing, buffering or loading, and is
released the moment you pause. Exactly what MX Player does.

### Background play held the CPU awake through pauses
Background play runs a foreground service with a partial wake lock, which is
what stops Android suspending the CPU and cutting your audio with the screen
off. It was tied to the *toggle*, not to playback — so pausing with background
play left on kept the CPU pinned awake with nothing to decode, for as long as
the player existed. It now follows playback, with a short grace period so a
normal pause-and-resume does not flicker the notification.

### The player rebuilt its entire screen once a second, for nothing
Watching fullscreen with the controls hidden is the normal case, and in that
state nothing on screen displays the playback position — yet the whole player
was being rebuilt and re-compared every second to update a number that was not
drawn. Over a two-hour film that is about seven thousand rebuilds of a
2,800-line screen. The position is now written only while something is showing
it, and refreshed the instant the controls, the lock overlay or a panel appear,
so nothing looks stale. The seek bar is unchanged — it already read the engine
directly, which is why it stays smooth.

### Local files were being buffered like network streams
The player forced libmpv's read-ahead cache on for every file and sized it for a
desktop: 150 MB forward, 75 MB back, thirty seconds of cache, and 250 MB for
network. On a high-bitrate video that is over two hundred megabytes of RAM held
for the whole film — which makes Android evict your other apps and pushes our
own memory into repeated garbage collection, and that collection is CPU, and CPU
is heat.

Local files now use small buffers, which is what mpv itself defaults to and for
a good reason: reading from storage is far faster than decoding, so reading
further ahead buys nothing and costs storage wake-ups. Network streams keep a
generous read-ahead, because absorbing a dead spot in your signal is the entire
point of it there. Music got the same treatment — its buffer was 32 MB, over ten
minutes of audio held in memory from app start whether or not you ever opened
the Music tab.

### Software decoding used every core on the phone
When a file's codec has no hardware support libmpv falls back to software, and
it was configured to run one decode thread per CPU core. Eight cores at full
load is exactly the state a phone throttles and heats in. It is capped at four
now, which decodes 1080p comfortably and leaves the efficiency cores alone. If
you have raised the thread count in Settings → Decoder yourself, your setting
still wins. When hardware decoding is working — the normal case — this changes
nothing at all.

### Music updated its state ten to twenty times a second
Background music is the longest-running thing this app does. Every position
report from the engine created a new state object and marked every widget
watching it for rebuild — for hours, with the screen off. It settles four times
a second now, which still looks live on the progress bar and in the lyrics.

### The music sleep timer could overrun by a lot
It counted down by subtracting a second per tick. Android coalesces and throttles
timers once the device sleeps, so ticks get skipped and a counter drifts long — a
thirty-minute timer could still be playing well past the hour, holding the wake
lock the whole time. It is anchored to a wall-clock deadline now, so it fires as
soon as any tick runs past the moment you asked for, however many the system
swallowed. The video sleep timer already worked this way.

### Smaller ones
- The video was wrapped in a zoom transform even at 1× — an identity transform
  the compositor still had to carry on every frame.
- Music A-B repeat fired a burst of seeks each time it looped, for the same
  reason the video one did.
- The sleep-timer countdown redrew the player every second even with the
  controls hidden, where the countdown is not drawn.

## v1.42.1+256 — the video player, audited end to end (Aug 2026)

No new buttons in this one. Every item below is something that was already in
the player and was quietly not doing what it said.

### The first video you open no longer sometimes fails for no reason
Two different pieces of the app were both starting the playback engine — the
provider starts it the moment it is created, and opening a file checked "is it
ready yet?" a few milliseconds later. It was not ready yet, so the second one
started it *again*, and building the engine twice throws. On a fast phone the
first start usually won the race and everything looked fine; on a slower one, or
on a cold start, you got a black screen and "playback failed" on a file that was
perfectly good. There is one start now, and the second caller waits for it.

### Resuming an episode no longer plays a second of the wrong scene first
Jumping to your saved position used to happen after roughly a dozen other
settings had been written, so the file played — with sound — from 00:00 for a
moment before snapping forward. The position is now handed to the engine as part
of loading the file, and it lands on the nearest keyframe so the first frame
appears immediately.

### Skip ±10s actually moves 10 seconds
The on-screen position is deliberately rounded to whole seconds so the player
does not redraw itself sixty times a second. Every relative jump was being
measured from that rounded value, so "+10 seconds" moved somewhere between 9 and
10, and repeated taps drifted further and further behind. Jumps now use the
engine's exact position. Same fix for swipe-to-seek, for switching decoder
mid-video, and for a network stream reconnecting after a drop.

### Dragging the seek bar is smooth now
The player had a fast keyframe-scrub mode built in, but it was only ever wired to
the swipe gesture — never to the seek bar itself, which is how most people seek.
Dragging the bar asked for a frame-exact landing on every step, which is what
made long drags stutter and flash the loading circle. Both now use the same
scrub mode, and the exact landing still happens where you let go.

### Volume, mute and the audio booster stop fighting each other
- The booster no longer switches itself off. "Fade in on seek" ramped the volume
  to a hard-coded 100%, so the first seek after turning on a 200% boost silently
  halved the sound and never gave it back. Fades now end at whatever level your
  settings actually call for.
- Scrubbing no longer makes the audio pump. A drag fires a seek every 60ms and
  each one started its own 300ms fade, so several were writing the volume at
  once. Fades are skipped during a drag, and a new fade cancels the old one.
- Mute no longer turns down your phone. It used to write zero to the *device's*
  media volume, which stayed turned down after you left the app, and unmuting
  discarded any boost. It now uses the player's own mute.
- A video no longer gets quieter every time you reopen it. The saved per-video
  level was being applied to both the system volume and the player's volume, so
  20% came back as 20% of 20%.

### Next, Previous and Shuffle
- Next / Previous / Loop-all did nothing at all on Android/data videos. Those are
  copied to a cache file before playing, and the player was looking for that cache
  path in your library, where it could never be.
- Shuffle was a toggle that lit up and changed nothing — no code read it. It now
  picks a random other file in the same folder.

### Subtitles do what the settings say
- "Show background" was writing to the subtitle *shadow* colour, so it darkened
  the outline and never drew the panel it promises.
- "Bold" was faked by thickening the border — the same setting the border-style
  picker controls — so switching one silently cancelled the other. Bold is its
  own property now and the two compose.
- Turning "improve stroke" off used to strip all ASS/SSA formatting, flattening
  signs, karaoke and positioned captions in anime and Blu-ray rips into plain
  centred text. It now leaves the file's own styling alone.

### Timers, loops and markers
- A sleep timer set to "end of video" could never fire while Loop was on, so the
  phone played all night. Stopping now wins over repeating, and it releases the
  wake lock.
- Marked intro/outro skips only worked on the first pass; every later loop played
  the intro you had explicitly marked. They re-arm on replay and on "start over".
- A-B repeat fired a burst of seeks each time it wrapped, because the engine keeps
  reporting positions past B for a moment after a jump is queued. One jump per lap
  now.

### Smaller things
- Watch history was being rewritten every 5 seconds — about 1,400 full-list
  rewrites during a two-hour film. It settles every 30 seconds now, and always
  when you close the player. Your resume point still saves every 5 seconds.
- Leaving the player while a video was in the floating window released the screen
  wake lock, so the display could sleep on top of a playing picture.
- A failed Android/data load left the loading circle spinning behind the error,
  so it looked like it was still trying.
- Switching decoder mid-video showed a frozen picture with no indication anything
  was happening.

## v1.42.0+255 — give any site its own icon (Aug 2026)

Site tiles are monograms by default on purpose — no logos are bundled (so the
app stays small) and no icons are fetched (so which sites you open, adult ones
included, is never sent to anyone). Now you can set a real icon for any site
yourself: long-press its tile, choose "Set icon", and pick an image. It is
copied into the app's own folder and shown on the tile; "Remove icon" puts the
monogram back. Your image, kept on your device — nothing bundled, nothing
fetched.

## v1.41.1+254 — clearer download status (Aug 2026)

- The download list now shows "Finalizing…" while a finished download is merging
  or embedding its thumbnail, instead of a bar that sits at 100% looking frozen —
  matching what the notification already showed.
- The Downloads tab shows how many downloads are running, so the count is visible
  even while you are on the Browse tab.

## v1.41.0+253 — two clean screens, and a faster, steadier download (Aug 2026)

### The downloader is two tabs now, not one crammed scroll
Everything used to live on one screen — what you were downloading, what you had
already saved, and eighteen hundred sites to browse, all stacked together, so
the download you came to watch sat in the middle of the sites you were only
glancing at. It is two tabs now: **Downloads** (what is running and what you have
saved) and **Browse** (your favourites and the rest of the sites). The link box
stays above both, because pasting a link starts a download from either place.
When you have no downloads yet, the Downloads tab says so plainly instead of
sitting blank.

### Big downloads start the instant you tap
aria2c used to reserve the whole file on disk before pulling a single byte — on a
gigabyte clip that was a real pause that looked like a stall. It now begins
writing immediately.

### A shaky connection recovers on its own
Each connection now retries itself a few times before giving up, and HLS streams
(the kind most of these sites serve) retry a dropped segment up to twenty times
with a growing wait, so one unlucky moment on a phone network no longer fails the
whole download. Pieces are also pulled roughly front-to-back, so a partly
downloaded clip is ready to open sooner.

## v1.40.0+252 — the download list, cleaned up and honest (Aug 2026)

This release is about what you SEE after a download — the list on the Downloads
screen and in the library — and about downloads that run three at a time.

### Same title, right video — bulk downloads no longer cross their wires
On these sites several different clips often carry the exact same title (the
library was showing four "…မလေး" rows at four different sizes). The file name
was built from the title alone, so those clips landed on one path, and with
three downloading at once their part-files and thumbnails overwrote each other —
a row's title ended up on another row's video, and the same title appeared again
and again. Every clip now gets a name that is unique to it (yt-dlp's stable id,
kept out of the title you see — the library strips it), so same-titled clips no
longer collide. Resolving the finished file is now scoped to the job's own clip
too, instead of grabbing whatever file in the folder was newest — which, with
three running, was often a different download's.

### Re-adding a clip you already have does nothing
It used to download a second copy. Now it finds the finished file and stops,
while a half-finished one still resumes where it left off.

### Lengths show, instead of 00:00
A freshly downloaded file gets indexed before its length is ready, so every row
read "00:00". The real length is now read straight off the file and filled in,
and the row updates the moment it arrives.

### Three downloads at once actually move
The progress clock was shared across all downloads, so three running at once had
to share one update a second between them — two of three rows sat still, and
each new download reset the others' clock. Each download now has its own, so
every row moves.

### "Finalizing…" instead of a bar stuck at 100%
Merging video and audio, or embedding a thumbnail, rewrites the whole file after
the bytes are down — several seconds on a big clip, during which the bar used to
sit at 100% looking frozen. It now says "Finalizing…" so you know it is working.

### A cancelled download cleans up after itself
Cancelling used to leave the half-downloaded data on the card — a cancelled 1 GB
download left 1 GB behind. Its partial files are now removed (scoped to that one
download, so nothing else in flight is touched). Pausing still keeps its data to
resume from.

## v1.39.0+251 — every quality, and the download at full speed (Aug 2026)

### The download was crawling at a sixteenth of the line speed
The device log showed a 1.1 GB file downloading at ~1 MB/s on a phone that
could pull the same link at 7-13 MB/s. That gap was not the network — it was
the CDN throttling a single connection, which phncdn and its kind do as a
matter of course. aria2c defaults to one connection per server, so it walked
straight into the cap. It now opens up to sixteen (`--max-connection-per-server=16
--split=16 --min-split-size=1M`), each throttled the same, adding up to the
real line speed. The multi-connection flags and the proxy flag travel in one
`--downloader-args` value, because YoutubeDLRequest keys options by name and a
second call would replace the first. Streamed HLS/DASH, which stays on the
native downloader, now pulls eight segments at once instead of four — the same
per-connection cap bites a stream as hard as a whole file.

### A stream-first site showed one quality where it has four
XVideos, xHamster and TXXX declare one progressive rung inline and keep every
other quality inside their HLS master. The old path showed that single row and
offered a ten-second read to fill the rest in — a merge that the log showed
firing and not landing. The master is a tiny text file the player already
fetched, so it is now parsed on the spot: one `#EXT-X-STREAM-INF` per rung,
each with a height and a size estimated from its BANDWIDTH times the running
time the player reports. One row becomes the whole ladder before the sheet is
drawn, and each row selects its own height off the master so yt-dlp pulls that
exact rendition — with a separate audio track merged in on the rare master
that keeps one apart. A ladder already three rungs deep is left alone.

### PornHub showed qualities with no sizes
Some CDNs (phncdn among them) refuse both a HEAD and a one-byte range GET, so a
row came back with an em dash where its size should be. Two things fix it: the
size requests now go through the app's own resolver when it is running (these
CDN names can be poisoned like the site names, and a plain request would fail
to connect at all on the networks where the download itself works), and a row
the site named with a bitrate — `1080P_4000K_…mp4` — is sized from that bitrate
and the duration when a request returns nothing. A measured size still wins; an
estimate now stands in where there would otherwise be no number at all.

### Sessions already persist
Logins and on-site history — a Gmail sign-in, a YouTube search — are kept
across restarts: the browser accepts first- and third-party cookies, keeps DOM
storage, and flushes cookies to disk when it pauses. No change was needed here.

## v1.38.0+250 — the download that would have failed silently (Aug 2026)

### aria2c never heard about the proxy

`--proxy` configures **yt-dlp's** network layer. aria2c is a separate process that has to be told separately, and youtube-dl #23730 is exactly this failure: extraction succeeds through the proxy and then the download goes direct and dies.

On this phone that would have been invisible in the worst possible way. The bypass exists precisely *because* those hosts are unreachable without it — so the quality sheet would open perfectly, every time, and every download from it would fail. Modern yt-dlp is believed to forward the setting, but "believed" is not a basis for the one path that cannot be tested from here, and a duplicate flag costs aria2c nothing. It is passed explicitly now.

*(Looking back at the last report with this in mind: two PornHub picks were logged and neither was followed by a `download finished`. That may be nothing — the log ends shortly after — but it is the shape this bug would leave.)*

### The notification could pause but never resume

Half a control. The moment somebody wants a download back is the same moment they are looking at the shade, and the only way was to open the app, find the row and press it there. A paused job now shows **Resume** where Pause was.

Routed over the **browser** channel rather than the download event stream — a deliberate choice, not a convenience. That stream turns any phase it does not recognise into `error`, so inventing a `resumeRequested` phase there would have marked the very job being revived as failed. Dart owns resuming because Dart owns the spec: the address, the selector, the folder. Native has the process; it does not have the job.

`jobTitles` was something I assumed existed and did not — the engine already hands a title to the notification when a job starts, so it is remembered there, and forgotten when the job is cancelled.

### "You already have this one"

The quality sheet now says so when the same **page** has been downloaded before, with a button to play the copy. Matched on the page rather than the file, because the media address behind it is signed and rotates every few hours — comparing those would say *new* to the same video every time. It is the reason `sourceUrl` was worth persisting.

**Never a refusal.** A second copy at a different quality is a perfectly reasonable thing to want, so the download proceeds if that is what was meant. The alternative is a phone quietly filling with the same film.

**Untested on device.** Worth confirming: that a download started while the bypass is on actually finishes, and that Resume in the shade brings one back.

---

## v1.37.0+249 — the crash, and the ladders that were half read (Aug 2026)

### The XVideos crash

Pressing Download on XVideos closed the app. `titleFor()` reads `web?.title`, and it was being called from inside a background thread — **a WebView may only be touched from the thread that created it**, so it threw, and an uncaught throw on a plain `Thread` takes the whole process down.

It only ran when the instant ladder was **short**, which is exactly why XVideos (one declared quality) crashed and PornHub (four) did not. The title is captured on the UI thread now, the trap function is deleted, and both workers are wrapped so that nothing on a background thread can close the browser again.

**This is the fourth time this rule has been broken in this file, so it is now mechanical.** `kotlin-webview-thread` fails on any `web` access inside a `Thread { }`, with `runOnUiThread { … }` removed first by brace matching — a pattern that understood one level of nesting reported four correct call sites, and its line numbers were counted in the stripped text rather than the file. Sixteen checks.

### A feed is not a video

    read started · page address · www.tiktok.com/…/foryou  →  Unsupported URL

Seven seconds spent being told what the address already said. The site is still page-first; it is that *address* that is a listing. `looksLikeListing` now catches `/foryou`, `/explore`, `/following`, a bare host and the rest, and those fall through to whatever the player is actually streaming — which on a feed is the only thing identifying the clip on screen.

### xHamster was being read one bucket deep

    read started · stream · video3.xhpingcdn.com/…/720p.av1.mp4.m3u8  →  1 video + 0 audio

A single-rendition variant, silent. The harvest looked only under `sources.mp4`, and that key has moved: the current player uses `h264` and `av1`, with `hls` alongside, and some builds keep the lot under `xplayerSettings`. Every bucket is read now, and entries may be a plain address or an object with its own quality name. Executed against that shape it returns 240p, 480p, 720p, 1080p and the playlist — where it previously returned nothing at all.

### YouTube on a VPN, said once instead of twice

    playback refused · m.youtube.com · VPN on · embed offered
    playback refused · www.youtube-nocookie.com · VPN on · embed offered

Offering the same escape from inside it is the app repeating itself. The embed row is withheld on an embed page, and what replaces it is the thing that is actually true on this phone: **the blocked sites open without a VPN now — turn it off and YouTube works too.** The first log in the same report proves it: with no VPN, `read for the browser: 7 video + 4 audio` in four seconds.

Also confirmed working in that log: the bypass restoring itself at launch (`app resolver ON` before anything was tapped), and applying to every site opened afterwards.

**Untested on device.** Worth checking first: that XVideos no longer closes the app, and that xHamster now offers a full ladder rather than one silent rendition.

---

## v1.36.0+248 — do it, do not ask (Aug 2026)

**The bypass works.** The report proves it end to end, with the VPN off:

    resolver check · www.pornhub.com=sinkhole · bypassable · private DNS off
    browsing through the app's own resolver on port 46259
    quality ladder read off the page · 4 qualities · no extraction

PornHub and XVideos both opened and both downloaded, on a network where they had been unreachable. **The VPN is no longer needed for them.**

### But it was still being handed over as a decision

The person who tested it could not say which button they had pressed — only that pressing something had worked. That is the whole verdict on that sheet: a measurement had already established what to do, and the app made somebody choose anyway.

So when a name is blocked **and the route was measured as reachable**, the bypass now turns itself on and the page reloads. No sheet, no question. The choice is remembered, so it happens at most once per phone — after that it is already on before the first page is asked for. Nothing is quietly traded away: it changes only which address the phone is told to connect to, and the trail says plainly that it happened.

The sheet survives for the cases where there is a real decision to make — a route that is genuinely blocked, or a bypass that did not take.

### The quality sheet fills itself in

XVideos declares one quality inline and keeps the rest inside its HLS list, which is why the screenshot shows a single row called *Low* and an invitation to go looking. Nobody should have to accept an invitation to be shown what a site already offers.

The instant ladder now appears immediately **and the full read runs behind it**; when it answers, the extra rungs are merged in and the sheet redraws. Instant *and* complete, rather than instant *or* complete. Merged by label, keeping what the page declared — a site's own name for a rung, with a size measured from the file itself, beats the same rung described second-hand.

Only if the same sheet is still open. Somebody who has already chosen has moved on, and redrawing over them would be the app arguing with a decision they made.

### The missing sizes

That em dash where a size should be was a CDN refusing a `HEAD`. The same question is now asked a second way — a `GET` for a single byte, `Range: bytes=0-0`, with the total arriving in `Content-Range`. One byte of traffic for a number people actually choose on.

### YouTube on a VPN: the honest answer

`_warmYouTubeSession` fired exactly as designed — `bot wall · visiting the video to earn a session, then retrying` — and the retry still failed. That is not a bug in it.

The research is consistent and now checked against yt-dlp's own documentation: `visitor_data` addresses the **rate limit**, not the bot check; PO tokens no longer clear it; VPN and datacentre ranges are scrutinised deliberately, and session cookies are invalidated *faster* when seen from one. The reliable fix is a signed-in account, which the browser has offered since v1.33.0.

**But the more useful answer is that the VPN has stopped being necessary.** It was only ever on for the blocked sites, and those now open without it. With it off, YouTube is not challenged at all — which the same phone has already demonstrated.

**Untested on device.** Leave the VPN off and simply use the app: the blocked sites should open on their own, and YouTube should behave as it always did without one.

---

## v1.35.0+247 — Innocent resolves the name itself, so no VPN is needed (Aug 2026)

**The verdict on whether this is even possible: yes, and it is now measured rather than assumed.**

The two requirements have never been reconcilable by a switch. The router answers the adult sites' names with an address that goes nowhere, so those need a VPN; YouTube then refuses, because a shared exit address is what its bot check looks for. On, off, on, off — every time.

But the measurement was specific: `www.pornhub.com=sinkhole`. **Only the ANSWER is being interfered with, not the route.** So the fix is to stop asking that router — and an app can do that for itself.

### A resolver, and a proxy that uses it

Innocent now runs a small proxy on its own loopback address that resolves names over HTTPS and connects to what it gets back. The WebView is pointed at it with `ProxyController` — the one API that can do this, and why `androidx.webkit` is now a dependency — and yt-dlp with `--proxy`. **One mechanism, both halves of the app.**

This is not a workaround somebody invented on a forum; it is the architecture Alibaba Cloud documents for HTTPDNS on Android, for exactly the reason it applies here: a local proxy covers every protocol and request method, which `shouldInterceptRequest` cannot.

**It never reads the traffic.** For `CONNECT` — every https:// page — it opens a plain socket and pipes bytes without looking. No certificate is generated, none is installed, and nothing in it could decrypt anything if it wanted to. **And it is not an anonymiser**: the connection still comes from this phone's own address, which is precisely why YouTube stays happy. A VPN replaces that address; this does not.

**The system resolver still gets the first word.** On a name nobody is interfering with, the phone's own answer is used — it is closer, it is cached, and for a site the size of YouTube a distant resolver's answer is a *worse* address, not a better one. Only when that answer is missing or points somewhere that cannot be a real site does it ask elsewhere. So the proxy is transparent on a healthy network and a bypass only on the names actually being tampered with.

### It is offered only when it has been proved to work

A poisoned name is half a diagnosis. If the router *also* rejects the connection once it reads the site's name out of the TLS greeting, resolving the name ourselves changes nothing and a VPN really is the only way in.

So before offering anything, the app opens a real connection to the address the encrypted resolver gave, announces the real hostname the way a browser would, and waits for the handshake. It completes — the route is open, the block was only the answer to a question, and **Open it anyway, without a VPN** appears. It does not — the sheet says the route itself is blocked, and does not waste anybody's evening pretending otherwise. The report carries the same word: `NAME POISONED on this network · bypassable without a VPN`.

Simulated against the device's own answers: pornhub `127.0.0.1` → the encrypted address, rescued; xvideos `0.0.0.0` → likewise; YouTube → the system's answer, untouched; nothing resolvable at all → refuses rather than guessing.

**Untested on device.** With the VPN off, open a blocked site, and take the one offer on the sheet. Both halves should then work at once for the first time.

---

## v1.34.0+246 — the trail handed over the answer (Aug 2026)

**The blocked sites are diagnosed.** `www.pornhub.com=sinkhole · private DNS off`. The name is answered with an address that goes nowhere, which is why the browser reported a refused connection rather than a failed lookup. **Private DNS removes that, and no VPN is needed for it** — which matters twice over, because with the VPN off YouTube stops being challenged as well.

**And the instant ladder is working.** PornHub opened four qualities in two seconds with no extraction at all, twice; XVideos the same. `page says 1067s` next to `player: playing · 1070s` shows the page-declared duration arriving and settling the advert question before a frame of the film had been seen.

### The wall, and what the trail proved about it

The same session failed a shared YouTube link twice — `Sign in to confirm you're not a bot`, sixteen seconds each — and then read a YouTube video **perfectly from the in-app browser** seven minutes later. Nothing about the network or the clients had changed. What had changed is that the browser had **loaded a watch page first**, and the cookies it collected went into the same jar the reader is handed.

The existing rescue could not do that, for two reasons that are now the whole design of the fix. It only ran when a read came back **thin** — and a wall arrives as a *thrown error*, so it never reached the rescue at all. And it visited the **home page**, which earns a weaker visitor session than the page for the video actually being asked about.

So a wall now warms a session by **visiting that video's own page** off-screen, then reads again. Once per link, no account, nothing typed.

### Two things the report was saying that were not true

**`youtube.com=dns` was a false alarm.** A disagreement between two *public* answers is not evidence of anything: a site that size is served from enormous anycast pools and two resolvers in two places routinely return different addresses for it. The next host in the very same check — `www.youtube.com` — came back `ok`, same site, same second. That case is now reported as `differs` and treated as no block at all. What remains as evidence is the pair that cannot be innocent: an address that goes nowhere, and a name the system cannot resolve while an encrypted resolver can.

**A failed read was recorded as a success.** `SiteNetworkMemory.remember` sat above the failure branch, so a bot wall taught the phone that YouTube works on this network. That is worse than not recording at all — the memory exists so a later failure can say *"this site last worked with the VPN off"*, and one that learns from failures will eventually say it about a network where the site never worked. It now runs past every early return, where success is certain.

### Smaller

`read started · stream · www.youtube.com/…/watch` was a page address mislabelled, because the test compared strings and `canonicalWatch` had rewritten the host. Labelled by kind now. And the network sheet is one per **host per minute** rather than one per address — each failed load starts a new page and cleared the guard, so one refusal raised three sheets over one blank screen.

**Untested on device.** The thing worth doing first is still Private DNS — the diagnosis is no longer a guess.

---

## v1.33.1+245 — the no-token clients, and a duplicate that would not have compiled (Aug 2026)

### The client list was one hope deep

Under a flagged address `android_vr` answers `LOGIN_REQUIRED`, and the list behind it was `web,tv_downgraded` — of which **neither can work unaided**. `web` needs a proof-of-origin token for its media server, and `tv_downgraded` is the client yt-dlp reaches for when *logged-in* cookies are present. So the fallbacks were a token we cannot mint and an account nobody had signed into.

The wiki's own table names exactly three clients that need no token: **`android_vr`** (nearly unrestricted), **`web_embedded`** (embeddable videos, none at all) and **`web_safari`** (its HLS formats are exempt). Those go first now, with `tv_downgraded` kept last where it is genuinely right — once somebody *has* signed in.

`web_embedded` is also the same asymmetry the browser's *Play without signing in* button uses: **YouTube checks an embed far less suspiciously than it checks the site.** Reader and browser now lean on the same fact from both sides.

### A duplicate that would not have compiled

Working on the bot wall, I wrote a second `embedUrlFor` into a file that already had one, alongside a parallel detector that matched the **English text** of YouTube's message — where the existing one tests for the player's error **element**, and therefore works for somebody reading YouTube in Burmese. The better implementation was already there; mine was a worse copy that also broke the build.

All of it is removed. What survives from that work is the client change above, which is the part that was actually missing.

**And the suite gained the check that would have caught it.** Thirteen checks looked for "called but not defined"; none looked for "defined twice", and every one of them passed on a file with two identical functions in it. `kotlin-redeclared` now fires on a repeated member — overload-aware, because same name with a different parameter list is ordinary Kotlin, and scope-aware, because two local `fun`s of the same name in two different methods are ordinary too. It took three passes: the first flagged `attempt`, `once` and a legitimate `sheetRow` overload; the second still carried a stale copy of its own earlier version, which the negative test exposed by reporting the same fault twice in two different formats.

**Fifteen checks.** Untested on device: a YouTube video under the VPN, and *Play without signing in* when it refuses.

---

## v1.33.0+244 — the embed player is the way in (Aug 2026)

Correction to the last release's claim: YouTube **is not** working under the VPN. The read succeeded, but the video would not play — the site itself shows the bot check to addresses it does not trust, and a downloader whose browser cannot play the video is not much use.

That is a different problem from the one v1.30–v1.32 solved, and the research points at one fix that needs **neither an account nor a different network**:

> **YouTube checks an embedded player far less suspiciously than it checks the site.** An embed is meant to be watched from anywhere by anyone without signing in, so a video the watch page refuses very often plays through it.

So when the player refuses to start, the browser now offers **Play without signing in** — the same video through `youtube-nocookie.com/embed/…`, which is the same player with the least attached to it. On a phone where the VPN cannot simply be turned off because the rest of the browsing needs it, that is the difference between a working YouTube and none.

**Deliberately offered, not imposed.** Reloading somebody into a different player unasked feels like a malfunction, and the embed has no comments, description or related videos — a fair trade against nothing, a poor one taken without consent.

The other route is on the same sheet: **Sign in to YouTube**, which the research calls the most reliable fix there is, done in this same browser so the cookies land where everything else already looks.

### Detecting it without reading English

The wall is found by the presence of the player's own error overlay — `ytp-error`, `ytd-enforcement-message-view-model` — rather than by matching a phrase. Somebody using YouTube in Burmese gets the same behaviour as somebody using it in English, which testing for text could never deliver.

**Downloading still asks about the watch address.** An embed is a way of *playing* a video, not a different video, so the reader is handed the canonical `watch?v=…` form however playback happened to start. Quietly changing which address we ask about depending on how somebody pressed play is exactly the sort of difference that surfaces weeks later as "it only works sometimes". The id is extracted from every shape — `watch?v=`, `youtu.be/`, `/shorts/`, `/embed/` — and verified against all of them, including two addresses that must yield nothing.

### A signed-in session is not the network's to invalidate

v1.30 forces a fresh guest session whenever the network changes, which is right: a visitor session is judged by the address it was issued to. An **account** session is judged by whose it is and travels anywhere — so discarding one on a network change would replace something that works everywhere with something that works nowhere. The research is blunt about the cost, too: frequent cookie clearing is itself one of the things that provokes the check. The jar is inspected for `LOGIN_INFO` / `__Secure-3PSID` and left alone when it holds an account.

And cookies are now flushed on pause and destroy. A sign-in that does not survive the app closing is not a sign-in.

### A checker for the injected scripts

A `$` in a Kotlin raw string is an interpolation and a backtick opens a JavaScript template literal; both compile and then behave differently from what is written. The rule existed only as a comment, and this release put two backticks into a JS comment without anything noticing. Now checked mechanically — and a rule with an exception for comments could not be, so the comment lost its backticks instead.

**Fourteen checks.** Untested on device: the thing to try is a YouTube video under the VPN, and then *Play without signing in* when it refuses.

---

## v1.32.0+243 — a refused connection is what a poisoned name looks like (Aug 2026)

**YouTube now works with the VPN on.** The report proves it: `read started · page address · m.youtube.com/…/watch` → five seconds → `read for the browser: 6 video + 3 audio`. The client change and the network-matched guest session did it.

The adult sites, on the same connection, all failed with `net::ERR_CONNECTION_REFUSED` — and the app said nothing useful, because the resolver advice only appeared when the error *mentioned* a name lookup.

That was the wrong test, and the research is unambiguous about why. `ERR_NAME_NOT_RESOLVED` means the lookup failed. `ERR_CONNECTION_REFUSED` means the lookup **worked** and the connection was rejected — which is exactly what happens when a resolver blocks a site the usual way: **it does not refuse to answer, it answers with somewhere that goes nowhere.** A sinkhole hands back `127.0.0.1` or `0.0.0.0`, the phone connects, gets an instant rejection, and the browser reports a refused connection. Four sites in five seconds, on a connection where YouTube was fine.

So the browser now **measures every page that will not load**, and the sheet says what was found rather than what the error string hinted at. A new `sinkhole` verdict names the most confident case there is: a public site does not live on the loopback, so an answer saying it does can only have come from something rewriting the reply.

### And the report knows about it

`dns unknown` was itself a bug. The browser had just measured, but the measurement lived in the half of the app that took it, and the report is assembled by a class that never runs a check. The device keeps it now — one place — and the report reads it from there:

    dns        system resolver  ·  NAME POISONED on this network

### Four sheets over a blank screen

A refused connection is reported for sub-resources as well as the page, so `showNetworkTrouble` fired four times in five seconds. One sheet per address now, cleared when the page changes.

### "WATCHER SILENT" was crying wolf

The report flagged it on the YouTube feed, where the truth is simply that a feed has no video element. The script *had* reported that — once — and its own duplicate-suppression then kept it quiet, while Kotlin cleared what it knew on every navigation. Two sides disagreeing about what "unchanged" means, and the conclusion drawn was that the script had been refused.

Fixed on the reporting side: the suppression is dropped on navigation, and a heartbeat drops it every five seconds regardless. Verified by running the script — three ticks on one page produce one report, a navigation produces a fresh one immediately, and twelve more ticks produce another. `WATCHER SILENT` now means what it says.

Also: a `NetworkCheck` field that was written and never read is gone. Two places holding one fact is the shape of a disagreement waiting to happen, and the copy that gets read is never the one that gets updated.

**Untested on device.** The thing to try: open a blocked site and let the sheet appear. If it reports a poisoned name, Private DNS should let the VPN stay off — and YouTube already works either way.

---

## v1.31.1+242 — a field on the wrong class (Aug 2026)

v1.31.0 did not compile. `_netCheck` was stored on the downloads screen's State, and the diagnostics report is assembled inside the **settings sheet** — a different class in the same file. Four errors, all the same one.

The fix is not to reach across: the last network measurement is a fact about the **network**, not about a widget, so it now lives on the service that performs the check. Any caller populates it and any reader can see it — which is where it belonged before the compiler had an opinion.

**And the suite gained the check that would have caught it.** No existing one could: the name existed, just not where it was used. `dart-member-scope` fires when a `_name` is used inside class A while being declared in class B of the same file and nowhere reachable from A. It took three passes to be right about working code:

1. Ownership was matched as "`_name` followed by `;` or `)`", so `int borrow() => _count;` made the *borrowing* class look like the owner — the synthetic test passed when it should have failed. A field declaration needs a type in front of it.
2. Top-level private functions were invisible to it, so `_questionText` — declared at file scope in the recovery screen and used from two States, which is correct Dart — was reported as a fault.
3. Only then did it catch exactly the real failure and the synthetic one, and nothing else.

Thirteen checks now, every one negative-tested against a deliberately broken copy before the tree is trusted.

---

## v1.31.0+241 — measure the network instead of guessing at it (Aug 2026)

The requirement was: **Innocent must work for everyone, whether a VPN is on or off.** Working through it properly turns out to hinge on one question nobody was asking.

**Almost every block of this kind is done at the resolver.** The research is unambiguous — public, school and ISP filtering overwhelmingly works by answering a name with nothing, or with a lie. And Android has shipped encrypted DNS as a system setting since version 9, which removes the local resolver from the picture entirely.

If that is what is happening here, then **the VPN is not needed at all** — and with the VPN off, YouTube and TikTok work too. One setting, and the two halves of the problem stop being opposites.

"If" is not good enough to tell somebody, because a router can also block the encrypted port and because some blocks are done on the address rather than the name. So the app now **measures it**: it asks the phone's own resolver and an encrypted resolver over ordinary HTTPS, and compares the answers.

- Both agree → the name is fine, so any block is further along and **a VPN really is the way in**. Saying otherwise would send somebody down a dead end.
- The encrypted resolver has addresses and the system one has none, or a completely different set → **a resolver block, and Private DNS removes it.** That is a finding, not a suggestion.
- The encrypted resolver could not be reached → **nothing is claimed.**

That verdict appears on the failure card with a *Check this network* button, in the browser's own sheet when a page will not load, and in the report:

    dns        system resolver  ·  NAME BLOCKED on this network

The report also gained that line unconditionally, because whether encrypted DNS is on is read from the **live connection** rather than from the setting — the setting can say `opportunistic` while the network quietly refuses it, and what matters is what is actually in force.

### Three bugs caught before they shipped

**`s.downloaderMissing` in a helper that has no `s`.** `s` is a local in the build methods, never a field, so this would not have compiled. The AppStrings check could not see it — the *key* exists; only the *name* was out of scope — so the suite gained a scope check. It needed three passes to stop being wrong about working code: the first flagged twenty compiling call sites because the return-type pattern ate the indentation and matched `setState(() {` as a class member; the second still missed `final s = AppStrings.of(context)`, where the type is inferred. It now catches exactly the one real fault and nothing else.

**The escaped-dollar trap, for the second time.** `\$` is not a Python escape, so a patch script wrote it straight into Dart, where it is a *literal* dollar — the report would have printed its own source code, and compiled perfectly while doing it. The rule recorded after the first time (grep the target afterwards) caught it. The suite now checks for it directly, with comments stripped and strings kept — the exact opposite of what the balance checker needs, because this file legitimately documents the `replaceAll` trap using that same sequence.

**A blanket assertion that refused to write.** The first fix asserted no `\$` remained anywhere in the file and correctly refused, because two comment lines are entitled to theirs. Guarding on the specific lines rather than a global count is the recorded rule, and it held.

### Also

The player clients are `android_vr,web,tv_downgraded` from v1.30.0 — `tv_downgraded` is what yt-dlp reaches for when *logged-in* cookies are present, so pairing it with a guest session asked the one client that most expects an account. A guest session is now re-collected whenever the network changes, because a visitor session earned on one address and replayed from another is one of the shapes YouTube's check is watching for.

**Untested on device.** The first thing worth doing is pressing *Check this network* on a blocked site. If it says the name is blocked, setting Private DNS to `dns.google` should let the VPN stay off permanently — and then everything works at once.

---

## v1.30.0+240 — the network is the fact, so the app should know it (Aug 2026)

Two groups of sites on this connection want opposite things and cannot both be satisfied at once. The router blocks the adult sites, so those are only reachable through a VPN — and YouTube then refuses, because a shared exit address is exactly what its bot check looks for. **There is no setting that makes both true**, and pretending otherwise would waste somebody's evening.

What the app can stop doing is making that discovery slow. The report shows it costing thirty seconds to learn nothing:

    ! probe @youtube.com  took 15s → Sign in to confirm you're not a bot  [tried: alt-clients]
    ! probe @youtube.com  took 15s → Sign in to confirm you're not a bot  [tried: alt-clients]
      network  unmetered · VPN ON

So:

- **Every successful read writes down which network it happened on.** One word per site, in the app's own preferences — no address stored, nothing sent anywhere.
- **A failure on the other network says exactly that**, above the buttons: *"This site last worked with the VPN off."* Only when the phone has actually seen it work on the other one; a guess dressed as a memory would be worse than silence.
- **A guest session now belongs to a network as well as to a site.** YouTube issues a visitor session against the address that asked for it, and replaying it later from a completely different one is one of the shapes its check is watching for — so a session harvested without the VPN is *worse* than useless once the VPN is on. The app notices the change and collects a fresh one. That is not an optimisation; it may be the whole fix.

### Player clients

`android_vr,tv_downgraded` is retired. yt-dlp's own documentation says `tv_downgraded` is the client it reaches for when **logged-in** cookies are present, so pairing it with a guest session asked the one client that most expects an account to work without one — and the report shows `android_vr` answering LOGIN_REQUIRED with nothing useful behind it. The stated guest default is `android_vr` then `web`, and we have the JS runtime `web` needs, so the new default is **`android_vr,web,tv_downgraded`**. (`visionos` stays out: this engine answered `Skipping unsupported client` the week it was tried.)

### Three faults the report named

**The button appeared over an eleven-second pre-roll on XNXX.** The rule only calls something short an advert once the page has *already* shown something longer — and the advert plays first, so on the first video of a visit there is nothing longer yet. The page knew all along: it publishes the real running time in `og:duration` or JSON-LD before a frame has played. An eleven-second clip on a page that says 493 seconds is now settled without waiting to be shown the difference.

**PornHub offered one quality.** `read started · stream · em-h.phncdn.com/…/index-v1-a1.m3u8` → `1 video + 0 audio`. That is a *variant* playlist, which honestly lists the single rendition it is for. The master sits in the player's own configuration, so a page-declared playlist is now preferred over anything caught on the wire. And PornHub's mp4 ladder lives behind one more door — the `mediaDefinitions` entry holds an API address rather than a file — so the page fetches that itself, where the cookies already are, and reports the real list.

**A real XNXX video page was called "not a video page"** in the trail, because the test looked for `/video/` and XNXX writes `/video-1234/title`.

### Verified by running it

The page-duration parser was executed as JavaScript against all three shapes it will meet — a plain number, `PT8M13S`, and `PT1H2M3S` — and returns 493, 493 and 3723. All three injected scripts still parse as JavaScript and remain free of the dollar sign a Kotlin raw string would turn into an interpolation. A missing `deviceStatusProvider` was caught by checking that every symbol the new code names actually exists; it never did — the device status comes over the channel, not from a provider.

**Untested on device.** Worth watching: whether `android_vr,web` alone gets past the wall, and — if not — whether a session collected *while the VPN is on* does.

---

## v1.29.0+239 — read what the page already says (Aug 2026)

The fastest extraction is the one that never happens, and every one of these sites has been writing the answer down in plain sight the whole time.

- **XVideos and XNXX** (one player) put it inline: `html5player.setVideoUrlHigh('…mp4')`, `setVideoUrlLow`, `setVideoHLS`.
- **PornHub** keeps a `flashvars_<id>` global whose `mediaDefinitions` carry a `quality` and a `videoUrl` for each rung.
- **xHamster** keeps `initials.videoModel.sources.mp4` as quality → address.
- Anything else, generically: the playing element, its `<source>` children, `og:video`, JSON-LD `contentUrl`.

So a small script now reads that, and tapping Download on those sites opens the ladder **immediately** — no extraction, and with the site's own names for the qualities, which beat anything inferable from a file name. Then a HEAD request per row fills in the **exact** size, capped at five seconds and best-effort. Having just saved ten seconds, spending one on real numbers instead of none is a good trade.

**And a short ladder does not become a ceiling.** XVideos declares two rungs and keeps the rest inside its HLS list, so a sheet with fewer than four rows carries *Look for more qualities…*, which runs the full read. Instant by default, thorough one tap away. A complete ladder gets no such row — offering to repeat work whose answer is already on screen is noise.

### Two faults found while checking this one

**The harvest would have worked exactly once per visit.** Its guard is a flag on `window`, and a single-page navigation replaces a page's *content* without replacing `window` — so the flag survives, the scan never re-runs, and the second video of an evening silently falls back to a ten-second extraction with nothing to show that anything was wrong. It re-runs on navigation now. (The watcher and the banner-hiding do not need it: an interval keeps ticking and an injected stylesheet keeps applying.)

**The failure sheet would have interrupted for nothing.** `onReceivedError` fires for cache misses and cancelled navigations too, and a warning that appears when nothing is wrong is a warning nobody reads when something is. Only host-lookup, connect, timeout and I/O failures raise it now.

Also corrected in the same pass: the sheet header falls back to the player's own running time (the instant path never reads a duration, because it never reads anything); the session is saved for the **row's** host at the moment it is picked, not only the sheet's, because a declared ladder can point somewhere else entirely and a request with no Referer is the 404 this project has already debugged once; the trail's duplicate-suppression resets per page, so the same sentence about a second video is no longer swallowed; and the saved orientation starts as *unspecified* rather than as landscape.

### Verified rather than assumed

The harvest script was run as JavaScript against the real markup from each player — Low/High/HLS out of XVideos, four rungs out of PornHub's `mediaDefinitions`, three out of xHamster — and again across a simulated navigation to prove the re-scan. All three injected scripts are parsed as JavaScript by the checker, and all three are confirmed free of the dollar sign that a Kotlin raw string would silently turn into an interpolation.

**Untested on device.** Worth watching first: that PornHub and xHamster open a full ladder with sizes and no wait, that XVideos shows High/Low plus *Look for more qualities…*, and that the second video on a page opens just as fast as the first.

---

## v1.28.0+238 — one reader, and the browser stops downloading fragments (Aug 2026)

Six faults, every one of them found in the device trail rather than guessed at.

### The browser was downloading four-second pieces of video

    read started · stream · em-h.phncdn.com//seg-5-v1-a1.ts
    browser pick · mp2t → download finished

`seg-5-v1-a1.ts` is one **piece** of an HLS stream. The reason it was ever offered is that the rule matched `.mp4` **anywhere in the address**, and PornHub and xHamster serve their pieces out of a folder named after the file: `…/1080P_4000K_57004305.mp4/seg-5-v1-a1.ts`. So a fragment scored as an mp4, and when no playlist happened to fall inside the advert window it was handed over as the film. Four times in one session.

The extension is now read from the **file name**, and a piece is never a target — `.ts`, `.m4s`, `init.mp4`, `seg-*`, `frag*`, `chunk*`. Simulated against the exact addresses from the trail, including a real file called `chunky.mp4` that must survive.

### And it was only ever offering one quality

`index-v1-a1.m3u8` contains "index", so it was treated as a master playlist. It is the playlist for **one** rendition, so reading it truthfully reported the one quality it lists — `1 formats · 1 offered`, every time, which reads as a stingy site rather than a naming mistake of ours. A `-v<n>-a<n>` suffix is HLS's own way of saying "one track", and it now disqualifies a name from being a master however it is spelled.

### The whole ladder, with no extraction at all

The trail showed the person doing this by hand — two ten-second reads, minutes apart, each answering `1 formats · 1 offered`:

    read started · stream · em.phncdn.com//240P_1000K_57004305.mp4
    read started · stream · em.phncdn.com//1080P_4000K_57004305.mp4

Same video. The site publishes each quality as its own file and names it with the height, the bitrate and the video's id — and the browser had already watched both go past. Everything a row needs is in those names, and the size follows from the bitrate and the duration the player is already reporting. So tapping Download on those sites now opens the full ladder **instantly**, with no read at all. Requires two different heights sharing one id, because one row proves nothing.

### One reader

Pasting a YouTube link gave a full sheet; finding the same video in the browser gave a thin, **silent** one. Both true, and both inevitable: the browser had grown its own reader in Kotlin, and that reader drops audio-only renditions and never pairs a video-only one with a soundtrack.

That is not a bug to fix twice. The browser now **asks Dart**, which owns the ladder, the guest session, the self-heal, the ffmpeg question and `probe_parser`, and hands back rows ready to draw. The Kotlin reader survives only as the answer to "Flutter is not awake yet". The sound fix falls out of it for free: a video-only rendition downloads as `<id>+bestaudio/<id>`, which is what the Flutter sheet has always sent and the Kotlin one never did. The YouTube alternate-client escalation moved out of the downloads screen into the shared pipeline, so both callers ask the same function.

### TikTok's one workaround was being skipped

    read started · page address · www.tiktok.com  →  19s  →  returned nothing

No exception, so the error was null, so the `api_hostname` rung — the one that exists for exactly this site — was gated out. A read that produced nothing has told us nothing; on TikTok that host is now asked regardless of *how* the first attempt declined.

*(Researched and settled: curl_cffi **does** now publish an Android arm64 wheel matching our minSdk — verified against the package index, 2026-08-01. It needs CPython 3.13 and the engine bundles **Python 3.8**, so impersonation stays out of reach. That is a much more precise statement than "unavailable on Android", and it names the thing that would change it.)*

### The network is often the real answer, and now it says so

This phone's router blocks the adult sites, so those need a VPN — and YouTube and TikTok then refuse, because a shared exit address is what a bot wall is looking for. Two opposite remedies, and a blank page tells you nothing.

- The report's network line now says **VPN ON** when one is carrying the connection. That single bit decides what "YouTube does not work" even means.
- A page that will not load is caught separately from a page that cannot be read, and says which. A name that would not resolve offers **Private DNS** — encrypted DNS has been an Android setting since version 9, it defeats a name-based block *without* a VPN, and nobody is ever told about it. One setting instead of a trade-off.
- A read that fails while a VPN is on says so, because the remedy is the opposite of the one that got them onto the site.

### It behaves like the app it replaces

- **Fullscreen video works.** It never did: `WebChromeClient` only enters fullscreen if the host handles `onShowCustomView`, so the button was there, it was pressed, and nothing happened. On a phone without Google services this browser *is* YouTube.
- **The screen stays awake while a video plays** — a web page cannot ask for that, only the host can, which is why an in-app browser goes dark mid-video and the real app does not. We already know exactly when something is playing.
- **Back leaves fullscreen before it leaves the page**, like every player on the platform.
- **The "open in app" banners are hidden** — on a phone that cannot install that app they are a strip of every screen and sometimes a dialog over all of it. Done in CSS, which cannot navigate, cannot fire a handler and cannot break a page that changes.
- **Eleven more telemetry paths blocked** — playback stats, attestation pings, interaction logs. Nothing the page draws, every one a connection set up and torn down while somebody waits for a video.

Also: `view_video.php?viewkey=` is recognised as a video page, so the trail stops calling real PornHub pages "not a video page"; and the twelve-second verdict waits rather than firing while an advert is plainly running, because that is the rule working, not a fault.

**A checker gap, caught by arithmetic.** Adding four strings took the count from 709 to 712. One already existed — and because the duplicate landed identically in all three locales, comparing them against each other saw nothing, while two Dart getters of one name do not compile at all. The suite now checks uniqueness *within* each locale and among the getters, and both were negative-tested.

**Untested on device.**

---

## v1.27.2+237 — the advert rule was guarding a door that does not exist (Aug 2026)

The report was six lines and told the whole story once you knew where to look:

    +0:19  tap  site tile: YouTube
    +0:19  tap  @m.youtube.com  in-app browser opened
    +1:02  tap  site tile: XVideos
    +1:33  browser  browser read: 3 formats → 3 offered · 129s · player: playing

XVideos produced a read. YouTube produced **nothing at all** — not a failed read, not an error. No read was ever attempted, which means the button never appeared, which the trail had no way of saying.

### Why the button never appeared

The button waits for the main video because on a stream-first site we hand the reader a **sniffed address**, and during a pre-roll the newest address *is* the pre-roll. That reasoning is sound and it is why PornHub works.

**It does not apply to YouTube at all.** For YouTube, TikTok and the other page-first sites we hand over the **page address**, and the reader answers a page address with the video that page is about — never with the advert in front of it. So on YouTube the advert rule was protecting against something that cannot happen, while being strict enough to hide the button forever if the player markup was not what the script expected. It was not.

On a page-first **video** page the button now appears at any sign of playback: a video running, a media request seen, or — the case that would otherwise be unrecoverable — a script that never spoke at all. Deliberately narrow: a feed, a channel or a search result is not a video page, and the strict rule still governs every stream-first site.

### The trail can now answer the question the trail could not answer

This is the more important half, and it is the change asked for: **paste the report and the answer should be in it.**

A page that produces no button now says so, in one line, twelve seconds after it settles:

    browser  no download button after 12s · m.youtube.com · page-first · videos=1 ·
             not playing · 0s · media seen=0

Every fact in that line changes what the repair would be, and none of them were visible before. In particular the browser now distinguishes **"no video is playing"** from **"we cannot see the page"** — a page can refuse the injected script outright, and when it does, every rule built on what the player reports is quietly *dead* rather than *wrong*, which is a completely different bug. That case prints `WATCHER SILENT` and, on a video page, releases the button anyway.

Three more lines join it: `read started · page address · m.youtube.com/…/watch` (so "did it even try" is answerable), `main video started · …`, and `download button shown · … · media seen=3`. All deduplicated, because the watcher speaks twice a second and a trail that scrolls is a trail nobody reads. A read started with no player clients configured says `NO CLIENTS SET` in the same line.

### The sheet is the height of what is in it

On PornHub the quality sheet filled the screen. The window had been told to be 86% of the display — **a fixed height is not a cap**, so three rows got the twelve-row dimensions and buried the video somebody was choosing a quality for.

The ceiling now lives on the list, in its own `onMeasure` with `AT_MOST`, which is the one place the two rules can be stated together: grow to fit, stop at half the screen. The window wraps. Three qualities take three rows; twelve scroll. The stream list and the failure sheet got the same treatment.

**Untested on device.** If YouTube still produces no button, the report will now say which of the four causes it is — that is the point of this release.

---

## v1.27.1+236 — the fix for YouTube is what broke YouTube (Aug 2026)

Reported: YouTube and TikTok used to work and now do not. Everything else in v1.27.0 is good. **The cause is mine and it is embarrassingly direct.**

`probeForBrowser` — the browser's own read — passed `null` where the player clients go. That was harmless for as long as the browser only ever handed it a **sniffed media address**, because a plain file fetch needs no player client and no challenge solver. v1.27.0 started handing it the **page address** for YouTube, TikTok and fourteen other sites. A YouTube page read with no `--extractor-args youtube:player_client=` is answered as whatever yt-dlp defaults to, that default needs a PO token, and a PO token is the bot wall. So the change that finally let the browser *ask* about a YouTube page is exactly what made the answer unusable.

The other half was as bad. The Dart path has a five-rung ladder — clients, IPv4, TikTok's API host, alternate clients, the remote challenge scripts. The browser made **one attempt with no escalation**. TikTok's page refusing to give up its embedded data is a *normal first answer* that the `api_hostname` retry has existed to fix since v1.21.0, and the browser never made that retry.

Both fixed:

- The player clients now travel with the browser at launch — **one source**, since Dart both knows the setting and is what opens the browser.
- `probeForBrowser` climbs the rungs that apply to it: the read as configured, then TikTok's API host when the page refuses, then the remote challenge scripts when the engine blames the JS side. `blamesJs()` was a local function inside `runProbe` and is now a member — **promoted, not copied**, because two copies of a question drift and the drifting one is the one nobody watches.
- **A net under the page-first sites.** Asking for the page is the better question and occasionally the unanswerable one, so a page read that returns nothing now falls back to the stream the page actually played — the same mechanism that makes the adult sites work. Two different failures, one net.

### Which rungs actually ran

A TikTok read failed with "Unable to extract universal data for rehydration" — which is precisely the message the API retry exists to answer. From outside there was no way to tell whether that retry ran and also failed or never fired, and those are two completely different bugs wearing one message. A whole test round has been spent on that shape before. Every failure now carries what was tried: `… [tried: tiktok-api, alt-clients, remote-ejs]`.

*(The TikTok extractor breakage itself is upstream — yt-dlp issue #16199, TikTok changed their page. The engine's own updater is the fix for that; this release makes sure our ladder is not silently skipping the step that works around it.)*

### The quality sheet, rebuilt

The in-page sheet now looks like the one a pasted link gets, because it is built to the same plan: grabber, a header with the title and `12:34 · pornhub.com`, a hairline, then rows of `◉ 1080p   MP4   [no sound]        ~412 MB`, and a blue Download button at the bottom. **Radio-then-confirm, not tap-to-start** — over a page, a single tap that both chooses and begins means a mis-tap downloads two gigabytes. Capped at 86% of the screen so a twelve-row ladder scrolls instead of burying the video.

**And the sizes are there now.** They were missing for a reason worth writing down: the sheet only showed a size when the engine *stated* one, and an HLS master playlist states none — which is the normal shape on every site this browser exists for. The Flutter sheet has always fallen back to bitrate × duration, so the same JSON produced `~412 MB` on one screen and a bare `M3U8` on the other. `sizeOf` now mirrors `probe_parser.dart` exactly: stated size, then the engine's approximation, then bitrate × duration, with `~` when it is an estimate.

**Untested on device.** Worth checking first: that YouTube in the browser now offers a real ladder, that a TikTok failure names its rungs, and that every row shows a size.

---

## v1.27.0+235 — the button waits for the film (Aug 2026)

The advert problem is fixed at the place it was always going to be fixed: **the player.**

v1.26.0 answered it after the fact, by reading two streams and keeping the longer one. That works, and it is still here as a backstop, but it cannot stop the button appearing during the advert — and that is the part somebody actually sees. A button offered over a pre-roll is a button that downloads a pre-roll, however cleverly the code recovers afterwards.

So a small script now rides along with every page and reports what the video element is doing: whether it is playing, how long it is, and whether the page is showing one of the advert markers a player puts in the DOM while an advert runs. From that, three facts decide the button, and each one is something the player **knows** rather than something we deduce:

- **A marker.** YouTube states it outright — its player carries `ad-showing` while an advert runs, which is what every ad-skipping extension has keyed on for years.
- **A length that looks like a pre-roll.** Under ninety seconds *on a page that has already shown something half again as long*. Note the ordering: a short video on a page that has shown nothing longer is treated as **real**, because that is exactly what a genuinely short video looks like, and refusing to download those would be a worse failure than the one being fixed.
- **A moment's patience.** Two seconds of playback before the button appears, because a player reports a duration before it reports a steady one and a button that flickers is worse than one that waits.

**And it does more than hide the button.** The instant the main video starts is a line drawn through the collected addresses: the advert's are older than it, the film's are newer. So the download no longer has to out-guess the advert either — it simply looks on the right side of the line.

### The button is a floating pill now, not a bar

It used to take a permanent stripe off the bottom of a screen somebody is using to watch something, and it was there whether or not it could do anything. Now it sits in the corner, arrives when the film starts, and leaves when the page changes. Long-press it — or use the new icon in the toolbar — for the manual list of everything the page has offered. That list is always available, which is what lets the automatic button afford to be cautious: a careful rule must never be the only way in.

### It no longer leaves the site by itself

The loudest complaint about this screen, and it was right. When a read came back with nothing usable the page was handed to the downloads screen automatically — so tapping Download over a video landed somebody on a different screen with their place in the site gone, and even the successful version of that felt like a failure. Now the failure is stated where it happened, with **Try again**, the media list, and *going to the other screen as something you choose*.

### Two silent bugs found on the way

**YouTube could not be downloaded from the browser at all.** Its media comes from `/videoplayback` with no file extension, so the sniffer — which matched on extensions — collected nothing, so the button never appeared. On the one site Myanmar phones without Google services actually depend on. It was never a YouTube problem: the extractor reads a YouTube *page* address perfectly, and now for YouTube, TikTok, Instagram, Facebook and eleven others the page is what it is given, which is also richer — every quality, the real title, the subtitles.

**Watching a second YouTube video kept the first one's addresses.** `onPageStarted` is what cleared them, and on a single-page site it fires once, when the app opens. So the third video of an evening could hand over the first one's stream, with the right title on the row because the title came from the page. Single-page navigations are now noticed from both sides — the script and `doUpdateVisitedHistory` — and guarded on the address, so an ordinary load cannot clear a list it should be filling.

### The download's whole life, not just its middle

- **`sourceUrl` was being thrown away on every restart.** The field has existed since v1.22.0 and `toJson` never wrote it, so it survived exactly until the app closed. Everything built on it would have worked in testing and failed for anyone who reopened the app — the worst shape a bug can have.
- **Three dots on every row, running or finished.** *View original page* reopens it in the browser; also copy link, download again, share, play, remove from list, and delete the file — with removing from the list and erasing the film named as the two different things they are.
- **A running download gets the same options**, plus pause, cancel and retry where each can do something. Reopening the page is how somebody checks they took the right video without cancelling first.
- **Saved rows say where, how big and when** instead of repeating the file name that is already on the line above.
- **Full history** behind *See all*, built from the same row so the two cannot drift.
- **Three downloads at once instead of one.** The old reasoning was sound about bandwidth and wrong about people: the second thing you start said *Queued* and then sat still, and a stationary row does not read as a working queue, it reads as a download that was thrown away.

### Faster pages

Off-screen pre-rastering, hardware layers, normal caching, no pop-under windows, and advertising *paths* blocked on hosts that also serve real content — `/pagead/`, `/ptracking`, the ad statistics endpoints — which is a visible difference on a cheap phone and something no host list could do.

**Untested on device.** Worth watching: that the pill appears only after the advert on PornHub and XVideos, that YouTube now offers a quality list at all, that a second YouTube video downloads itself and not the first, and that three downloads really do run together.

---

## v1.26.0+234 — telling the advert from the film (Aug 2026)

The in-page flow works now. The record shows it end to end: the quality list opening over the page, a choice being made, the download finishing, and the browser never once leaving the site. Three of those in a row without touching the downloads screen.

And it exposed the thing that made it feel worse rather than better. Two of those downloads finished in **ten seconds**, offering a single nameless quality. The third took thirty-three, offered three proper resolutions, and was the video. Ten seconds is not something anybody wanted — it is the advert that plays first.

**Neither of the approaches tried so far could have caught that.** Blocking advertising networks does nothing here, because these sites serve their pre-roll from the same delivery machines as the film. And ordering cannot help either: whichever end of the list you prefer, one of the two cases breaks — take the earliest and the advert wins, take the latest and every quality but one is lost.

There is one honest signal, and the engine hands it over for nothing: **how long the thing actually runs.** So the newest stream is read first, and if it turns out to be a few seconds long while another stream is available, that other one is read too and whichever runs longer is the one offered. Two reads at most, and only when the first looks like an advert. A short video that genuinely is the video keeps its place when there is nothing longer to replace it — checked against exactly that case, and against the two real ones from the device.

**The qualities also have names again.** One of those downloads was labelled "2666", which is an internal identifier and means nothing to anybody. For these streams the picture size often appears only as a plain "1280x720" rather than as a number the code was looking for, so that is now read too — the difference between a row that says 720p and a row that says 2666.

The record now reports what it decided and why: how many streams the page offered, how long the chosen one runs, and whether a short clip was skipped over.

## v1.25.0+233 — the reply was never the problem (Aug 2026)

Four releases were spent inspecting a reply that was fine all along.

The message this time was the one that mattered: **"had no formats"** rather than **"unusable"**. Those are different branches. The first says the reply was read successfully and simply contained nothing; the second says reading it went wrong. Getting the first meant the reply parsed, the qualities were found — and then something after that threw, was caught, and returned nothing. The counter that would have proved otherwise was never reached, so the message honestly reported an absence that was really an accident.

**The something was mine, and it is four releases old.** When downloads started being named after a file instead of a video, the fix was to read the page's own title from the browser. That reading was put inside the function that interprets the reply — and that function runs on a background thread, while a browser view may only be touched from the thread that made it. So it threw. Every read. On every site. The catch beneath it said nothing, the fallback to the downloads screen fired exactly as designed, and from outside it looked like six sites all refusing to cooperate.

The timing fits precisely: the in-page quality sheet worked in the two releases before that change and has not worked in any release since.

The title is now read where it is legal to read it — on the main thread, before the work starts — and handed in. And the catch no longer swallows: it names what went wrong, so a fault of this shape can never again disguise itself as an empty answer. That silence is the same one the browser's reporting line was added to end, sitting one level further down where nobody thought to look.

There is a lesson here worth more than the fix. A message that can describe two different situations will eventually describe the wrong one, and every hour spent afterwards is spent on the wrong question.

## v1.24.0+232 — one message for two different faults (Aug 2026)

The line added two releases ago was supposed to say why the in-page quality list came back empty. It said the same sentence on every site, again, after a fix that should have changed it — and that is the tell: **the message could not distinguish "the reply had no qualities in it" from "reading the reply went wrong."** Both left the counter at nought and both printed the same words, so a round of testing was spent learning nothing. That is my mistake, and it is the more important one, because a wrong diagnosis is worse than none.

They are separated now. If the reply cannot be read at all, the message says so and carries the first characters of it, because a warning printed on the wrong channel, an error page and an empty response look nothing like each other and none of them can be told apart from a byte count. If the reply reads but holds no qualities, the message lists its top-level field names — the shape was the entire answer last time, and it should never have been left to guesswork.

**And the reader now looks everywhere the qualities could reasonably be.** The engine returns at least four shapes for these addresses: a video with its qualities listed at the top, a playlist wrapping a single video with the qualities one level down, a nested structure, and a single quality with no list at all — just the video's own fields. Only the first was ever handled. A reader that knows one shape and calls the other three "empty" is exactly how six sites failed identically and silently.

All four are read now, checked one by one against a made-up reply of each shape, and a reply that genuinely holds nothing says what it does hold instead of shrugging.

The last of those matters more than it sounds: a bare media address often has exactly one quality, and answering "nothing here" to that is wrong in the way that stings — it sends somebody to another screen when the thing they asked for was sitting right in front of it.

## v1.23.0+231 — two parsers disagreeing about one reply (Aug 2026)

The line added last release answered its question on the first try, on six sites at once:

    browser read had no formats array (6452 bytes)

Six thousand bytes of perfectly good reply, and no list of qualities in it — while the main screen, given the very same address seconds later, read three to seven qualities out of it without complaint. Two readers, one reply, opposite conclusions.

The reason is a shape. Handed a bare media address the engine falls back to its general-purpose reader, and that often answers with a *playlist containing one video* rather than with a video. The qualities are one level down, inside that single entry. The main screen has unwrapped that since the day it was written; the in-page reader was looking at the top level and finding nothing. So every site fell back to the downloads screen, silently, six times over.

Two readers of the same reply must agree about its shape. They do now.

**The advert problem needed a better answer than blocking.** Blocking the advertising networks helps generally, but these sites serve their pre-roll from the same delivery hosts as the feature — so nothing can separate them by address alone, and refusing those hosts would refuse the video too.

There were two rules pulling in opposite directions, and both were right. Within one video, the list of every quality is requested before the single quality the player picked, so the first one is the one worth having. Across a page, the advert loads before the feature, so the last one is the video anybody actually wants. Take the first and the advert wins; take the last and every quality but one is lost.

Grouping settles it without guessing at durations or file sizes: a quality list and its variants share a folder, so the newest folder is the newest stream, and the earliest entry inside that folder is that stream's full list. Checked against a real sequence — advert, then feature — the old rule picked the advert and the new one picks the feature, while a page with only one video still gets its full quality list.

And moving to a new page now forgets the previous one's addresses, so a clip from a video you have already left can no longer be handed over by mistake.

## v1.22.0+230 — blocking the adverts instead of guessing around them (Aug 2026)

Six adult sites were tried in one sitting and every single one behaved the same way: the browser opened, and a minute later the app was back on the downloads screen with the qualities listed there. That is the fallback firing every time — the in-page quality list came back empty on all six — and the same addresses, read again seconds later from the main screen, produced three to five qualities without complaint. So the addresses were fine and the reading was fine; something in between was not.

**And there was no record of what.** The fallback said nothing at all: not whether the read came back empty, not whether it came back without a list of qualities, not whether it failed outright. Six identical mysteries and not one clue. That is now fixed first, because every other puzzle in this project fell the moment the thing was made to explain itself. The browser now reports the outcome of every read, in words, whether it worked or not.

**The adverts are now blocked rather than worked around.** Every one of these sites — and YouTube — plays an advert first, and an advert is a video. So a Download button that appears the moment any video is spotted appears during the advert, and pressing it gets the advert. The tempting fix is a rule of thumb: ignore anything too short, or too small, or on the wrong host. Every one of those is a guess that will be wrong somewhere, and being wrong here means quietly saving the wrong file.

Reading how the mature downloaders handle it gave a better answer: they block the advertising outright. If it never loads, its address is never requested, so it can never be collected, so the button cannot appear for it. The button starts meaning "the real video is playing" without anything having to work out what "real" means. Forty advertising and analytics hosts are refused — including the specific networks these sites actually use, taken from what the device saw rather than from a list somebody wrote down. Pages load faster as a side effect, which is the other thing that was asked for.

**And every download now remembers the page it came from.** The page somebody was looking at and the address the file was fetched from are almost never the same host, and only the second was being kept — so a finished download could never be traced back to where it came from. Both are stored now, which is what "open the video I got this from" needs.

## v1.21.0+229 — why the bar could never move (Aug 2026)

Last release tried to work the progress out from what the download tool prints. It could not have worked, and this time I checked before changing anything rather than after.

**Handing a playlist to the video tool means there is no progress to report at all.** The download engine's own issue tracker says it plainly: it sits idle while that tool does the work, and does not report again until the whole thing has finished. The tool's own output never reaches us during the download either — it only turns up at the very end, which is how it ended up in the record looking like an error. So there was no percentage available anywhere, and a healthy download running at two megabytes a second honestly showed nothing the entire way.

The engine's own downloader for playlists prints exactly what this app already knows how to read — the total number of pieces, then a running percentage — and it honours the setting that fetches several pieces at once, so it is faster as well as legible. Playlists go back to it. The video tool is not lost: the engine still picks it for genuine live broadcasts, which is the one case it was ever needed for.

**Downloads were being named after a file rather than a video.** Reading a bare playlist gives the engine nothing to go on, so it names the result after the address — which is how something ended up saved as "master". The page has a real title sitting in the browser the whole time; that is what a person would have called it, so that is what it is called now. Names that are obviously a file rather than a title — "master", "index", a bare number — are recognised and passed over.

**And a single quality where there should have been several.** From the outside, one row looks identical whether the site really offers one or this app's own filtering ate the rest — which is precisely the complaint, and precisely what cannot be judged from a screenshot. Two things now. When the engine clearly returned more than made it through, the list falls back to showing everything it sent: a row too many costs a line of scrolling, a row too few costs the quality somebody actually wanted. And the record now carries both numbers, so the next report answers the question instead of raising it again.

## v1.20.0+228 — a healthy download that looked stuck (Aug 2026)

Finding a video on a site, choosing a quality over the page and having it download while you carry on browsing now works end to end. Everything here is about the difference between working and looking like it works.

**The progress bar in the notification never moved.** Not because anything was wrong — because playlists are handed to a tool that does not report progress as a percentage. It reports how long it has been going, not how far through it is. So the figure stayed at nought, the notification showed an endless barber's pole, and a download running at two megabytes a second looked frozen. That is worse than a real failure: a failure at least tells you where you stand.

It does announce the total length near the start, though, and its position on every line after that. One divided by the other is the answer, and that is now what the notification and the progress bar both show.

**Only ever one quality was on offer, and the reason is almost funny.** A player asks for the master list — the one naming every quality — and then immediately asks for the single quality it has decided to play. We were keeping the most recent of the two, which is always the second one, so we handed over a list containing exactly one entry and then faithfully reported that there was one quality. Preferring the first now brings back the whole ladder, with sizes.

The rule is reversed for plain files, deliberately: there, a page loads its poster and preview clips before the video anybody pressed play on, so the last one is the real one.

**The Download button no longer sits there on pages that have nothing to download.** A button that cannot work teaches people the app is unreliable every time they press it. It now appears the moment a playable video is spotted — which doubles as the clearest possible signal that this page can be downloaded, without needing to say so. It also says "Download video" rather than "Download this page", because the page was never the thing anybody wanted.

One thing not changed, and worth being straight about: a second download really does wait for the first. That is the queue working as built, not a fault — but "Queued" sitting next to a stalled-looking bar made it read like everything had died. With progress now moving, the wait should at least be legible. Running several at once is the next piece of work.

## v1.19.1+227 — the answer was in the part we threw away (Aug 2026)

Good news first: the video engine is now reading these streams. The record shows it opening the playlist, walking its pieces and reporting a real duration — none of which was happening before. What it does *after* that is still unclear, and the reason it is unclear is a mistake of mine.

**When a message is too long, we were keeping the beginning of it.** A tool describes what it is doing first and what went wrong last, so cutting at a fixed length from the front keeps the narration and discards the answer. That is exactly what arrived: three lines of a stream being opened, and then an ellipsis where the actual failure would have been. It looked like a report while saying nothing. Long messages are now trimmed from the other end, in whole lines, so the last thing said always survives.

**The permission prompt was in the one place the browser never goes.** Choosing a video in the in-app browser picks natively and starts the download directly — it never touches the screen where the prompt lived. So the route most likely to need that permission was the only route that never asked, which is precisely what was reported: no dialog, and files quietly going somewhere else. The prompt now also appears before the browser opens, which is the last moment the app can ask anything.

It is one shared implementation used by both routes rather than a copy in each. Two copies of a question like this drift, and the one that drifts is always the one nobody is looking at.

**And I was forcing a setting that only applies to live broadcasts.** The engine's advice began with the word "if" — *if* this is a livestream — and I applied it to everything. It changes the container the video is written into, which fights the file type being asked for, and almost nothing that comes out of the browser is a live broadcast. The engine already turns it on by itself when it genuinely is one. Removed.

One thing considered and rejected: a check for unused imports. Written and run, it flagged a hundred and seventy-five files, including ones that are perfectly correct. A check that is wrong about working code is worse than no check — a rule this project has now paid for twice — so it was thrown away rather than shipped.

## v1.19.0+226 — the folder it was never allowed to write to (Aug 2026)

Choosing a quality over the page works — the record shows the choice made in the browser arriving without the app ever switching screens. What happened next did not, and the reason had nothing to do with any of it.

**Every download was being written to a folder Android does not let this app write to.** The permission that would allow it is declared, but it is the kind granted only by a switch buried in system Settings, which nobody turns on by accident and nothing here ever asked for. Worse, the check that was supposed to catch this only asked whether the folder could be *created* — and a folder can exist perfectly well while still refusing every write. So the check passed, the download started, and the failure surfaced minutes later as an unreadable error from deep inside the engine.

Two changes. The app now proves it can write by actually writing a byte and deleting it again, rather than by asking — the storage layer answers that question optimistically and only the write is the truth. And if it cannot, files go to a folder that needs no permission at all rather than the download dying. **A download must never fail because of a permission.**

It also now asks, once, before the first download, explaining plainly what the switch is for and that videos are saved either way — just somewhere other apps cannot see them. Declining is fine. The point is to put files where people expect them, not to hold the feature hostage.

**A second failure was the engine telling us exactly what to do.** It warned that live playlist streams are beyond its fast downloader and named the setting that fixes it. A playlist address is the normal case coming out of the in-app browser, not an unusual one, so playlists now go to the tool that handles them and ordinary files keep the fast one.

**And the quality list looks like the rest of the app now.** It was a plain system list — one word per row, no size, no indication of whether a choice includes sound — which looked like a debug menu beside the sheet a YouTube link gets. It is now a proper sheet: dark, rising from the bottom, two lines per row with the container, the size, and a note when a choice has no sound of its own. The same facts were always available; there was no reason for the browser to be the cheaper half of the app.

Three smaller things found while checking rather than by breaking. Photo sets were writing to the same forbidden folder and now share the same protection. Pressing Download before playing anything used to spend ten seconds arriving at a refusal; it now says to play the video first, which is both faster and true. And closing the browser stops any reading it had started, instead of leaving it running for nobody.

One near miss worth recording: the browser was being sent two of its six pieces of text, so four would have appeared in English on a phone set to another language — nothing missing, only unsent, and invisible to every check. They are now passed as a set that is looped over, so a new one cannot be forgotten.

## v1.18.1+225 — two of mine, corrected (Aug 2026)

The report of what actually happened — browse, tap, "reading", then thrown onto the downloads screen anyway — described both of my mistakes precisely.

**The quality list was always empty, so it always fell back.** When the browser reads a page it asks the engine what qualities exist, and then throws away anything the engine describes as sound-only. The check for that was wrong in a way that is easy to write and hard to see: it treated a MISSING answer as "sound only". These sites describe their video with no format details at all — that is the whole reason they need the browser — so every quality was discarded, the list came back empty, and the old behaviour took over exactly as designed. What looked like the new feature not existing was the new feature correctly giving up.

The rule now matches the one the rest of the app has always used: only an explicit "no video" means no video. Absence means the stream carries both, which is what such a stream is. Checked against a response shaped like the real ones: nothing found before, three qualities now.

**And my fix for the duplicate entries in the recent-apps list was backwards.** I made the browser declare that it belongs to no particular group of screens, thinking that would make it match the main one. It does the opposite — belonging to nothing means it is given a brand new group every time it opens, which is precisely the duplicate it was supposed to prevent. The screenshots showing two Innocents were the fix working exactly as written and exactly not as intended.

The real answer was to stop asking for a new one at all. Opened from the screen already in front of you, the browser sits on top of it, back walks down, and there is one entry where there should be one entry. That does require knowing which screen is in front, which the app now keeps track of and releases properly when it goes away.

**Third, smaller, and overdue: a failed download now says so.** The report kept reading "no faults" while a download plainly was not working, because downloads reported to the queue and nowhere else. That is the same blindness the link reader had before it was instrumented, and it cost the same thing — somebody saying it does not work, and no way to tell them why. Both outcomes are recorded now.

## v1.18.0+224 — choose the quality without leaving the page (Aug 2026)

Two things, and the second is the one that changes how this app feels.

**One Innocent in Recents instead of four.** The main screen declares itself as belonging to no particular task, and the two browser screens did not declare anything at all — so they inherited a different one, and a different task means its own card in the recent-apps list. That is why a screenshot of four Innocents was possible. They now agree, which also means the back gesture leads where it should instead of out of the app.

**And the browser now offers the qualities over the page.** Previously, pressing Download in the browser threw you onto the downloads screen — which is the wrong shape entirely. Somebody browsing a site is not collecting one video; they are looking through many, and every one of them should cost a tap, not a round trip through another screen and back.

So the button reads the page where it stands, lists what it found, and starts what you pick. The page stays exactly where it was, still scrolled, and a short line confirms the download began. The next one is one tap away. This is how the downloaders this app is measured against have always worked, and it is worth saying plainly that it was the flow that was wrong, not the machinery — everything underneath already did its job.

Three decisions worth recording, because each one had a tempting shortcut.

The choice travels on a channel of its own rather than the existing progress stream. That stream treats any message it does not recognise as a failed download, so a quality choice sent down it would have arrived looking like something that had already gone wrong. Two kinds of message, two channels.

The browser hands over only what it can legitimately know — the address, the format chosen, the title the reader reported. Where files go, which session applies, which extras are set: those are answered in one place, as they always were. A second place answering them is a second place to get them wrong, and nobody would know which one had.

And the reading happens off to one side, so the page stays scrollable while it works and the button says what it is doing. A screen that freezes for eight seconds has not saved anybody a round trip.

If a page turns out to be one the reader cannot make sense of, the old behaviour is still there as a fallback — the downloads screen has escalations this one does not, and losing those to gain a nicer flow would be a poor trade.

## v1.17.0+223 — a button you cannot press, and segments that were never allowed (Aug 2026)

The browser works. It opens, it loads the page, and it sees the video address go past. Four things were wrong with what happened next, and the screenshots and the notification named all four.

**The Download button was underneath the navigation bar.** Only the hint line and a sliver of blue were visible. A button you cannot press is the same as no button at all, and no amount of correct behaviour behind it matters. The layout now stops above the system bars instead of behind them.

**The download started and then every piece of it was refused.** The notification showed it plainly: fetching a playlist succeeded, then segment after segment came back "not found". A media server generally serves a file only to a request that says which page asked for it — and a page and its video almost never live on the same host, so handing over the video address alone left the part that matters behind. The browser now records both the browser it was and the page it came from, for the page's host *and* the video's host, and the engine presents them. The playlist was allowed; the segments were not; now they are.

**The only quality on offer was called "0 - unknown".** That is the extractor saying it has nothing to tell us, and passing it through dressed an absence up as an answer. A bare playlist address carries no resolution — but it usually carries a bitrate, which is a real number that sorts correctly and lets somebody choose between two rows. Failing that it now says "Video", which is at least honest.

**And pressing Download no longer throws you out of the browser.** Somebody browsing a site wants to send several videos, not one and then start again from the home screen. The page stays open, still scrolled where you left it, so the next one costs a tap instead of five. That is the whole difference between a browser and a link box, and it was one line.

The quality choice still happens on the downloads screen rather than over the page itself. Doing it in place is the right end state and is written down as the next step — it needs the chooser to exist on the native side, which is real work and not something to rush in behind four fixes.

## v1.16.0+222 — watching the page instead of arguing with it (Aug 2026)

The record disproved my own fix, which is the most useful thing it has done yet.

Last release assumed that browsing a difficult site inside the app and keeping its cookies would let the reader in. The cookies arrived — the report lists that site's session sitting in the jar — and the answer was still 403 Forbidden. So cookies were never the whole lock. These sites inspect *how* the connection is made, and a session collected by one program and replayed by another does not change that.

**Two things follow, and the second is the important one.**

A pass issued to a browser is checked against the browser presenting it. Ours was collecting a site's cookies and then handing them to the engine, which introduces itself completely differently — so the pass was refused, and from the outside that looks exactly like having no pass at all. The app now remembers which browser earned a site's cookies and presents the same one alongside them.

**And the app now watches the page rather than trying to out-argue it.** The video plays perfectly well inside the in-app browser, which means its address passed through it. Every request a page makes is visible, so the ones that look like video are simply written down, and the Download button shows how many have appeared. Pressing it now hands over the address the page actually played, not the page itself.

That skips extraction altogether. A direct file or playlist address is a plain fetch, which the engine is very good at and which needs no disguise, because there is nothing left to disguise. It is also how the downloaders this one gets compared to have always worked, and it means a site nobody has ever written support for still works, provided it plays in a browser.

A playlist is preferred to a plain file, because a playlist carries every quality while a stray file is usually the preview clip a page loads before you press play.

One more thing, from the record: tapping a site tile was logged, and then nothing — with no way to tell whether the browser refused to open or opened and came straight back. Both outcomes are now written down, so if it is still not opening, the next report will say so instead of leaving it to be guessed at.

## v1.15.1+221 — a return where a return is not allowed (Aug 2026)

The browser did not compile. One small helper was written as a single expression rather than a block, and inside it a null guard did what null guards do — leave early. That is fine in an ordinary function and illegal in one written as an expression, and the language says so outright.

Mine, and the third build in this run to fail on my native code, each time on a different rule. So the fix is not only the line: it is another check, and this one took some care to get right.

The first attempt reported two faults in code that has been shipping for months. Both were the same shape — a body written as a call that takes a block — and the language does accept a return inside one of those, because the call is inlined. **A check that is wrong about working code is worse than no check**, and I have now learned that twice in this run, so it was narrowed to the exact shape that actually failed rather than left to guess.

It also reported the wrong line numbers at first, because it strips comments before reading and was deleting their line breaks along with them, which quietly shifted everything below. Reports that point at innocent lines cannot be judged, so that is fixed too — and the whole thing was then tested by putting the original mistake back and confirming it is named, at the right line, and that removing it goes quiet again.

Ten checks now run before anything is packaged.

## v1.15.0+220 — Innocent has its own browser now (Aug 2026)

Three complaints, and they turned out to be one problem.

**Tapping a site used to hand you to Chrome.** That is the moment this app stopped being useful: you find a video in somebody else's browser, then have to remember to copy the address, come back here, and paste it. Every one of those steps is a place to give up, and none of them exist in the downloaders this one gets compared to. Sites now open inside Innocent, with a Download button on the page. Find a video, tap the button, that is the whole interaction.

**A link from an adult site would not read at all**, and the record said why: the site answered a plain request with 403 Forbidden, right after warning that it could not disguise itself. Some sites — that one and TikTok among them — inspect *how* the connection is made rather than what it asks for. The engine's answer to that is a component Android does not have, so no amount of correct headers gets past it.

A real browser passes that check by simply being one. So the new screen is not only about convenience: when you press Download it hands the reader the session it collected while you were looking at the page, and that session is accepted from anything that presents it afterwards. The wall that could not be climbed from one side turns out to have a door on the other.

The handover deliberately reuses the share path rather than inventing a new one. Sharing a link into Innocent is the most exercised route in this app — it survives a cold start, it interrupts an in-flight read correctly, and it is instrumented end to end. A second mechanism doing the same job would be a second mechanism to keep working.

**And the tiles have real logos now, without giving anything away.** Logos were refused twice before for good reasons: shipping other people's trademarks inside the app, and the fact that fetching icons at runtime would tell an icon service which sites someone cares about — which, with adult sites in the same grid, is a real leak rather than a theoretical one.

Neither objection survives having our own browser. Nothing is bundled: an icon only exists once you have chosen to visit that site, and it arrives as part of a page you asked for, over a connection you opened. No request is made that you did not already make. So the grid fills in with real logos as you use it, a site you never open keeps its letter, and nobody is told anything.

Back inside the browser walks the page history first, links that try to open elsewhere are kept in, and if the phone's web component is missing the old behaviour still works as a fallback rather than leaving a dead tile.

## v1.14.0+219 — the grid was teaching the wrong thing (Aug 2026)

Both YouTube and TikTok now work without a VPN, so this release is about the gap between what this app can do and what it looks like it can do.

**It could already handle almost any video site.** The engine underneath understands roughly eighteen hundred of them, and the list of sites shown on the home screen was never a restriction — it is only a set of shortcuts, and pasting a link from somewhere not pictured has always worked exactly the same way. But a screen showing twelve tiles teaches the opposite. Somebody holding a link from a site that is not on it will reasonably conclude it is not supported and stop, and that is a loss that no amount of engine capability fixes.

So the shortcuts went from eighteen to forty, chosen for what is actually likely to be open in a phone's browser rather than what looks impressive, and the adult section doubled. More importantly, one sentence now sits under the grid saying plainly that these are shortcuts and not limits. That sentence is worth more than the other twenty-two tiles put together.

**Two things are written down as deliberately not done yet**, at your direction: getting YouTube working through a VPN, and downloading TikTok photo posts. Both are real, both are wanted, neither is guesswork away — and half-doing either would risk what now works.

**On maintainability**, I looked for the tangle you asked about and mostly did not find one worth cutting into. The reading sequence has six decision points, but only two of them are about a particular site — one for YouTube, one for TikTok — and the rest are general responses to a failure that happen to be tested in a fixed order. Building an elaborate per-site framework to hold two entries would add more to maintain than it removes, so I left it and recorded why. What did need saying is that the ORDER of that sequence is load-bearing, and that is now stated where the next person will read it.

One more check was added instead, because this release nearly shipped a colour that does not exist — the palette jumps from fifty to fifty-five and I wrote fifty-four. Nothing covered that: the existing checks look inside a file, and this is a name borrowed from another one. Every such reference in the app is now confirmed to exist before anything is packaged, which is twelve hundred of them, and it was tested by putting the mistake back and watching it get caught.

## v1.13.0+218 — the 360p was ours (Aug 2026)

One number added last release answered a question four earlier releases had been assuming their way past. Sharing a link and pasting the same kind of link produced very different lists, and the record now shows why:

    shared:  engine sent 37 formats → kept 1 video + 3 audio
    pasted:  engine sent 37 formats → kept 8 video + 4 audio

**Thirty-seven both times.** YouTube was never being stingy. Everything above 360p was being thrown away here, by this app, and every previous round had read that short list as the site's doing and gone looking for the fault somewhere else entirely.

The cause is one line and it is almost reasonable. Most qualities above 360p arrive as picture without sound, so they have to be joined to an audio track before they are any use — and if the tool that joins them is absent, offering them would be a promise the app cannot keep. So when that tool is missing, those qualities are correctly dropped, leaving only the single pre-merged rendition YouTube provides, which is 360p.

The mistake was where the answer came from. The app was consulting a remembered note about whether the tool is available — and on a cold start, opening straight from a share, that note has not been written yet. So it read "no", discarded everything, and produced a 360p-only list from a video that had eight qualities in it. The tool was present the whole time. Nobody had asked.

It now asks, at the moment the answer matters. That question is free once the engine is awake, which it already is by that point, and the record notes the answer alongside the format counts so this can never again be invisible.

**On the VPN question, the answer is honest rather than clever.** The record shows YouTube replying "Sign in to confirm you're not a bot" through a VPN, while TikTok works perfectly through the same connection. So it is not the connection, and it is not this app: it is YouTube distrusting an address that a great many people share, which is precisely what a VPN exit is. My earlier guess about the connection type was wrong, and the trail said so plainly.

Nothing in an app can argue YouTube out of that. So instead of retrying quietly and failing quietly, it now says what happened and points at the two things that genuinely work — turn the VPN off for YouTube, or sign in, since a signed-in account is trusted either way. In all three languages, on the card itself rather than folded away, because this is one of only two failures a person can actually do something about.

TikTok now reads in five or six seconds with or without a VPN, and no faults recorded.

## v1.12.0+217 — the network, the thirteen seconds, and an honest number (Aug 2026)

The step-by-step record is now good enough that this release is mostly reading it rather than guessing at it. Pasting a YouTube link takes five seconds and reports no faults at all. That is the shape everything else should be measured against.

**With a VPN switched on, nothing worked — no options at all, on any site.** That deserves to be treated as a headline failure rather than a footnote, because the people this app is built for use one as a matter of course. It is not a site problem and not a rate limit: it is the signature of a connection that advertises modern addressing and cannot actually carry it, which is how most phone VPN apps behave. Every request tries that route first, waits, and fails — for every site at once, which is exactly the "everything is broken" that was reported.

The app now recognises that shape and quietly retries over the older addressing, once, and remembers it for the rest of the session so nobody pays the diagnosis twice. It costs nothing when the connection is healthy, since every site here is reachable either way. The patience for a slow connection also went up from fifteen seconds to twenty-five: a limit tuned for a direct connection turns a working-but-slow link into a bare failure, and a VPN is always an extra hop.

**TikTok was wasting about thirteen seconds on every single read.** The record shows its web page refusing to hand over its embedded data on the first attempt, every time, followed a few seconds later by a second read that succeeds. That second read was being started from scratch by the app, paying a fresh start for something the engine could have retried immediately. It now retries in place, against TikTok's own application interface instead of its web page — and not by guessing at an address, but the one this app already talks to elsewhere and which the record shows answering correctly on this very phone. It is used only after the ordinary route has already failed, so a working read never pays for it.

**And one number that should have been there from the start.** When a site offers a single quality, the record has said so four times and nobody has ever checked whether that was true. This app deliberately collapses twenty-odd near-identical renditions into one row per resolution — so a short list could just as easily be that collapse going wrong as the site being stingy. The record now shows both figures side by side: what the engine sent, and what was kept. One line, and the question is settled at a glance instead of being assumed.

Streaming from TikTok is still refused by their servers, and by agreement that is left alone. Reading the link, seeing the qualities and downloading it are what matter, and those are what this release makes faster and more reliable.

## v1.11.1+216 — a function reading something not yet declared (Aug 2026)

The last build did not compile. One small helper inside a larger routine read a value that is created seventy lines further down the same routine — legal to write, impossible to run, and this language refuses it outright. Mine, and the second time in this run that a change of mine reached a build it should never have got near.

The fix is not to move the lines closer together, which would last exactly until the next edit. The helper is now handed the value it needs instead of reaching out for it, so there is no ordering left to get wrong.

The more useful part is why nothing caught it. Every check in the suite covered the Dart side; the native side had exactly one — whether its brackets balanced. So an entire language in this project had no symbol checking at all, and this class of mistake had a free run.

It has one now, and building it was instructive. The first attempt reported eight hundred and seven faults, every one of them the checker's own: it looked for a function's body by finding the next opening brace after its name, which fails for any function written as a single expression, so one function appeared to contain the rest of the file and every value in it looked out of order. The second attempt reported ten, all still wrong: a value created *inside* the small helper was being counted against it. Only the third was clean.

Then it was checked against a copy with the original mistake put back, and it named it exactly. **A check that has never been shown to fail proves nothing** — this run has now proved that twice, and the second time it took three tries to earn the pass.

## v1.11.0+215 — when the answer is to stop asking (Aug 2026)

The record now reports something new, three times over: the site is refusing us for asking too often. Not a broken video, not a missing component — too many requests from this network in too short a time.

**Part of this is mine.** The previous release fixed a rescue that could never run, so a thin result now correctly triggers a second attempt. Combined with the ladder that was already there — try the normal way, then the alternates, then fetch the challenge solver — a single link could set off four or five separate conversations with the site. Then a failure triggers an automatic repair, which reads again. The record shows exactly that: refused, then refused again six seconds later, then again a minute after.

**Escalating is the one response guaranteed to make this particular failure worse.** So the app now stops the moment it sees it. No alternates, no solver fetch, no automatic repair — those are all just more requests aimed at something that has explicitly asked for fewer.

Beyond stopping, it now waits, and says so. That site is left alone for ten minutes, and pressing the button in the meantime shows how long is left rather than quietly trying anyway. This matters more than it sounds: when a screen says "failed" and offers a button, pressing it is the natural thing to do, and here it is the exact behaviour that keeps the refusal alive. An app that lets someone dig deeper without telling them is not being polite, it is being useless.

The message explains what is actually happening and what genuinely helps — wait a few minutes, or switch between Wi-Fi and mobile data — and it appears immediately rather than being folded away behind a "details" toggle like every other error. It says this in all three languages, because the people most likely to be affected are on shared mobile networks where one address is used by very many people, and none of this is anything they did.

One more thing, switched on only when needed: while a site is asking us to slow down, the engine now pauses briefly between its own requests. It is dead time on an ordinary read, so it is not a permanent tax — it turns itself on from evidence and expires on its own.

A successful read clears the wait early. Nobody should sit out a clock for a problem that is already over.

## v1.10.0+214 — reading the trail (Aug 2026)

The step-by-step record works, and it answered in one round what four previous rounds could not. Three separate faults, each named by the app itself.

**YouTube was offering one quality instead of a full list, and the rescue meant to fix that could never run.** When a site answers with a single rendition, this app is supposed to fetch a browsing session and ask again. That rescue was written to run only when no session had ever been collected — reasonable when written, since a missing session was the usual cause. But once a session exists the condition is permanently false, so the retry could only ever fire on a phone that had never collected one. The record shows the cost plainly: a session present, one quality offered, and no second attempt made. The rescue was switched off exactly when it was needed. It now retries whenever the list comes back thin, gets a session first only if one is missing, and asks through the alternate players rather than repeating the identical request that just came back thin.

**TikTok refused to play, and the reason turns out to be something we simply never sent.** The record is unambiguous: the site answered the playback request with a refusal, in under a second, on the saved address and again on a freshly fetched one, with five headers attached. The engine is handed the session cookies on every call, which is why downloading the very same video works. The small local server the player fetches through had no idea the cookie store existed. It now asks the engine which cookies belong to that host — through the same code that decides this for downloads, so there is one answer to that question rather than two — and sends them.

Two supporting changes. A refusal is now retried once as an ordinary request, because some sites decline a request for the first two bytes while serving the whole file happily, and a wrong verdict is worse than an extra moment. And the record now lists which headers were sent rather than how many; a count told us nothing, and no header name is a secret.

**And if a site really will not allow direct playback, the app now says so and offers the thing that does work.** After two independent refusals you get a plain message and a choice between trying anyway and downloading instead. That is evidence rather than a guess, so it is worth interrupting for — but it is still an offer, not a veto. The check advises; it never decides.

Also added: the checks now confirm every piece of text in the app exists in all three languages. There are six hundred and forty six of them, kept in step by hand across three lists, and a missing translation shows up only when someone using that language reaches that screen — which means the people most likely to find it are the ones this app was built for.

## v1.9.3+213 — the log could never write anything down (Aug 2026)

Every link now hung. Every entry point, every site, forever — and the report said, as it always had, that nothing had gone wrong. The two lines it printed together are what gave it away:

    IN FLIGHT  reading vt.tiktok.com — 163s so far
    activity   nothing recorded yet

The first line proves the read got started. The statement immediately after the one that prints it, with nothing that waits in between, writes a line to the log — and no line was written. And a hundred and sixty three seconds is longer than the engine wait and the reading limit put together, so the read was not stuck reading. It had never got that far.

The cause is one character sequence in the routine that strips private details out of a report before it is written down. It asked for a case-insensitive search using a prefix that this language does not accept — a prefix borrowed from a different family of tools. The pattern is not merely ignored: building it fails outright, every time, and the failure escapes.

So that routine has failed on every call since the day it was written, which means the log has never successfully recorded a single thing. **That is why every report this project has ever produced said no failures were recorded.** We read that as good news four separate times, and it was really the log telling us it could not hold anything.

What made it fatal this week was mine. The previous release began writing a line at the very start of a read, on the path a person is waiting on and outside anything that catches a failure. The failure then escaped the read itself before any reading had been requested — so nothing timed out, because nothing had started. The fault was always there; I moved it somewhere it could kill the feature.

A second fault sat in the same three lines: the replacement text referred to part of what it matched, using a form only the other kind of replacement understands. Even with a working pattern it would have written that reference into the report as literal text.

Both are fixed, and the log can no longer fail at all — if writing a line is impossible, the cost is one missing line and never a dead read. **An instrument must not be able to break the thing it measures.** The address check learned that same lesson two releases ago when it held the Play button shut.

Finally, the checks now build every search pattern in the project the way the app will and confirm each one is accepted — thirty-four of them, all valid. A pattern this language rejects fails when it runs, not when it is built, so nothing about it was ever visible beforehand.

## v1.9.2+212 — packing four of everything (Aug 2026)

The code compiles now. This build stopped because the build service ran out of patience waiting for it, not because anything was wrong with it — and the log showed why it was taking so long.

The build was packaging four different processor architectures. It has a note in it, written some time ago, saying in as many words that it should package exactly one, and explaining carefully why: each architecture carries its own copy of the video engine, a Python runtime, ffmpeg and the download accelerator, and doing several at once had already been the cause of earlier failures.

The instruction underneath that note adds an architecture to the list. It does not limit the list to it. If anything has already filled that list in — and the toolchain does exactly that by default, which is also why the log downloads the video engine four separate times — then adding an entry that is already present changes nothing whatsoever. The note had been describing an intention rather than a behaviour, and nobody had checked, because the only symptom was a build that took a while.

Cutting four down to one removes roughly three quarters of the work in the slowest stage of the build.

A second, smaller waste: three of the bundled files are archives that merely wear the extension of a program library, so that the installer will carry them. The build was running a program-library tool over each of them, which failed to recognise each one and logged an error, twelve times over. They are now skipped. The genuine libraries beside them are still processed normally.

Nothing about the app changes. If the build still runs long, the emulator-only architectures are now excluded at packaging time as well, and the build target can be set explicitly to arm64 in the build settings.

## v1.9.1+211 — a build that does not compile (Aug 2026)

v1.9.0 did not build. One field was used in three places and declared in none, because a patch script exited partway through and wrote nothing while I read its output as though it had. That is my error, and the interesting part is not the missing line — it is that the check meant to catch exactly this said everything was fine.

It said so for two reasons, both of which were wrong in the same direction. It looked only for things being *called*, so a plain field being read was invisible to it. And it treated an assignment as a declaration, which is backwards: assigning to something is using it, and in this language it declares nothing at all. A check that counts uses as definitions cannot fail, and something that cannot fail cannot help.

Rewriting it turned up two further things worth recording. Private names in this language belong to a whole library rather than a single file, so files that are declared as parts of another share them — before accounting for that, the new check reported over three hundred faults, every one of them its own mistake. And a type can contain spaces, brackets and parentheses, so a rule that assumed otherwise rejected most real declarations; a first attempt was loose enough that plain indentation satisfied it, which is how an assignment passed as a declaration all over again.

The check is now run against a deliberately broken copy before it is trusted. It reports the fault when the line is removed and is silent when it is restored. A check that has never been shown to fail is not evidence of anything, and this one had never been shown to fail.

The missing field is restored, and the behaviour it belongs to — collecting a browsing session after a shared link has finished being read, rather than skipping it — works as intended.

## v1.9.0+210 — the report keeps a transcript now (Aug 2026)

Three separate times in this run, a report arrived saying nothing was wrong while nothing at all worked. That is not bad luck; it is what happens when an app writes down only its failures. A failure on its own is a riddle — the sequence that produced it is usually the whole answer.

So the report now records what happened, in order, with the time each thing happened: the app opening, where a link came from, how long it waited for the engine, when the read actually started, how many options came back, which button was pressed and with which quality selected, what the site answered, whether the video was served through the local proxy or sent straight to the player, and where the handover to the player happened. Anything that went wrong sits in the same list, marked, in its proper place among the rest.

**One detail matters more than the rest: successes are recorded too.** Last release added a check that tests a video address before the player opens, and it wrote a line only when that check failed. So when streaming visibly broke and the check had passed, the report showed nothing whatsoever — the trail stopped precisely where it got interesting. A step that stays quiet when it works can hide the answer as effectively as one that never runs.

The report now holds about eighty steps instead of twelve, which is roughly a full session of ordinary use rather than a single failed read. Addresses are still reduced to a site name and anything resembling a token or cookie is still removed before anything is written down; a report is meant to be pasted into a chat, and being useful and being nosy are not the same thing.

Nothing about the app's behaviour changes here. The point is simply that the next time something goes wrong, the report should be able to explain it without anyone having to remember what they tapped.

## v1.7.0+208 — the fallback was making things worse (Aug 2026)

Two device reports, and between them they named both remaining faults outright. This is the first release in this run where I did not have to work out what was wrong — the app said it.

**YouTube's fallback list had gone stale, and a stale fallback is worse than none.** The report carried this, from the engine itself: `mweb client https formats require a GVS PO Token which was not provided. They will be skipped as they may yield HTTP Error 403`. That is one of the four alternates this app switches to when a first read comes back thin. Checking the other three: one is being pushed onto a delivery method that yields no usable addresses, one only ever helps on age-restricted videos, and only the fourth still works. Meanwhile the engine's own current choice is a different set entirely.

So the fallback was *replacing good options with ones that need a credential we do not have*. That is also the exact shape of "pasting works, sharing does not" — a paste succeeds on the first try and never reaches the fallback, while a cold share is more likely to need it and got actively harmed by it. The list is now the current one, and anyone carrying the old default is moved across automatically on next launch. A list someone typed themselves is left alone, because that is a preference and this was only ever our old opinion.

**Opening the app from a share sheet no longer waits for the engine to wake up.** The clue was precise: reading a link is slow the first time and normal every time after, and cancelling and sharing a second video fixes it. That is not a share problem and never was a link problem — it is the first read paying for the engine to unpack itself while somebody watches a spinner. The engine now starts waking the moment native code has somewhere to stand, which is roughly a second before the interface finishes drawing. That second was previously spent doing nothing. If it finishes in time the first read is instant; if it does not, nothing is any slower than it was.

**The stream check no longer holds the Play button shut.** Last release added a test of the address before opening the player, which was right, and then refused to play when the test failed, which was not: some servers decline a two-byte request while serving the real one perfectly, so the diagnostic could invent the outage it was meant to explain. It now does its job — fetch a fresh address if the saved one has gone stale, write down what happened — and then gets out of the way. If a stream really is dead the player will still say so, and the report will already know why.

Also: the engine's deprecation nag about one of our format spellings was eating a third of the small window of engine output kept for diagnosis. Corrected to the short spelling, which means the same thing and says nothing.

## v1.6.0+207 — the header set that was thrown away (Aug 2026)

The JavaScript engine fix in v1.5.0 landed: the report now says `js engine ok (quickjs)` and the engine is current. This release is about what that made visible, and about one real bug found by reading the parser rather than guessing at a server.

**TikTok would download and would not play, and the reason was ours.** When a video is read, the engine describes each quality and attaches the headers its servers check for. Some sites attach them to every quality; TikTok attaches the full set once, at the top, and leaves the individual qualities carrying a token one or two. Our code was written to use the top-level set as a *fallback* — and a fallback only applies when there is nothing else, so the moment a quality carried a single header of its own, the entire top-level set was discarded. In practice that meant we were sending one header where the engine sends six, and the missing ones were exactly the ones being checked.

That is also why downloading a file and playing the very same file behaved differently, which had looked impossible and sent us hunting for explanations on TikTok's side three times. Downloading hands the whole description back to the engine, which combines the two sets correctly by itself. Only playback was fed from our reading of it. The two are now combined properly, top-level first and the quality's own on top, and a header named two different ways is treated as one header rather than sent twice.

**An address is now tested before the player opens.** One two-byte request, over exactly the path the player will use. If a saved address has gone stale — and several sites tie one to the moment it was issued — a fresh one is fetched and used, silently, and nothing is shown. If both are refused, you get the actual reason and the code, and so does the report. "Playback error" on a black screen is the message that let this hide for three versions; it is gone.

**Reading a link on anything other than YouTube was doing the work twice.** The fallback the reader uses when a first attempt comes back empty is a YouTube setting, and every other site ignores it — so for TikTok, Instagram, Facebook and the rest we were re-running a command identical to the one that had just failed, paying a second engine startup and a second round trip for an answer that could not change. It now only does that where it means something. This was worst on exactly the links that were already slow.

**One thing this release does not fix, and I would rather say so.** The report now carries a warning from the engine that TikTok wants a browser disguise it cannot put on. This is a known limitation of running the engine on Android rather than anything in this app, it is being worked on upstream, and it is why TikTok can be unreliable in a way YouTube no longer is. If TikTok reads fail intermittently, that is where it is coming from, and the report will now say so in the engine's own words instead of leaving you guessing.

## v1.5.0+206 — the missing piece was never a login (Aug 2026)

Every YouTube problem this downloader has ever had came back to one absence, and it was sitting inside our own APK the whole time.

Since November 2025, yt-dlp cannot extract a YouTube video without a JavaScript engine to solve the challenge the site hands out. Without one it quietly drops every quality whose address needs unscrambling, keeps whatever plain copy survives, and — when nothing survives — reports that you need to sign in to prove you are not a robot. That last message is what sent this project chasing sessions, guest cookies and tokens for three releases. It was never the disease. It was the last thing the engine says on its way down.

The engine we ship has always included that JavaScript component. It is listed in our own diagnostics screen, and it has never once been used, because yt-dlp only finds it automatically when the file is named a particular way and Android requires ours to be named another. It had to be pointed at directly, and nobody had pointed at it. One argument, added to every call.

The reason this took so long to find deserves its own paragraph. Every call this app made carried an instruction telling the engine to keep its warnings to itself. On every single YouTube read, going back months, the engine had been saying in plain words that it had no JavaScript engine and that formats would be missing — and we were throwing that sentence away unread before anyone could see it. Warnings are on now. The diagnostics report has a line for the JavaScript engine whether it is healthy or not, and it prints the engine's own last words verbatim underneath. A tool that hides its own explanation of a failure can only ever be debugged by guessing, and that is exactly how this went.

Two smaller things follow from the same fix. Reading a link is allowed to take longer than it used to, because solving that challenge on a phone is real work and the old limit was killing reads seconds before they would have succeeded — and a killed read looks exactly like a site refusing you. And if the engine should ever fail to recognise the new argument, it drops it and retries by itself rather than taking the whole downloader down with it.

**Playing a TikTok video** was a separate fault with a separate cause. Files that downloaded perfectly refused to play, and the small local server that fetches media on the player's behalf was the reason. It asked servers for compressed data, then passed the compressed bytes to the player without telling it they were compressed. It also announced a length that could disagree with the bytes that followed. Both are now correct: data is requested untouched, and length is declared through the proper channel so it cannot contradict itself.

Streaming playlists — the kind of address that is a list of pieces rather than a video — no longer go through that server at all. Sending them through it never helped: the player would read the list through us and then fetch every piece of the video directly from the site, bare, which is precisely the thing the server exists to prevent. Those now go straight to the player, which does attach the right identification to every piece it fetches.

**Sharing a link** no longer competes with itself. Opening the downloader used to start fetching a browsing session in the same instant, and creating a browser view is heavy work on the one thread that also has to draw the screen and carry the engine's answers back. That is the third time in this feature that a background chore was put in the path of the one thing a person is actually waiting for. It now waits until something needs it, which is a decision the read already knows how to make.

## v1.4.0+205 — why YouTube and TikTok were exact opposites (Jul 2026)

YouTube worked when the link was pasted but not when it was shared. TikTok worked when it was shared but not when it was pasted. Precise opposites, which is not something coincidence produces — and it was one cause with two signs.

Sharing a link opens the downloader and reads it immediately. Pasting one happens a few seconds later, after the screen has settled. In that gap the saved cookie file finishes loading — so a shared link was read with no cookies at all, and a pasted one with cookies. YouTube needs a session and failed without one; TikTok is derailed by being handed a session it never asked for, and hung with one. Same difference, opposite results.

And the cookies it was handed were not even TikTok's. There was one jar for every site, so a YouTube session was being sent to TikTok, to Facebook, to everything.

Both halves are fixed in the same place. Cookies are now worked out by the engine itself at the moment a link is read, and filtered to the site being asked about — a site only ever sees its own, and if it has none then none are sent, which is not the same as sending an empty file. Because the engine resolves them itself there is nothing left to finish loading, so sharing and pasting became identical by construction rather than by luck. That is what should have been true from the start: sharing a link is passing a link, and it has no business behaving differently.

The report now names the sites it holds cookies for, instead of saying "present" and leaving out the half that mattered.

## v1.3.2+204 — one stale flag was stopping every link from being read (Jul 2026)

Reading a link stopped working entirely — no options, no error, nothing in the report — and it was worse than the version before it. The cause was a single line I added two versions ago, and the way it failed is worth explaining because it hid so well.

Stopping a read is recorded as a flag, and every read uses the same name. That flag was only ever examined AFTER an attempt had been made. So a stop issued while nothing was actually running — which is exactly what a newer link taking over now did — simply sat there waiting. The next read would do its work normally, and then, if its first attempt happened to come back empty (routine for YouTube, which is the entire reason there are fallback players), it found that leftover flag, declared itself cancelled, and never tried the fallbacks. And because a cancel is treated as the user's own decision, the screen showed nothing at all and the report recorded nothing at all. A downloader that had quietly stopped working, with no evidence anywhere.

It now clears any leftover flag before it starts, which is not merely convenient but correct: a stop issued before a read began cannot possibly have been meant for it.

Two things changed so that this class of fault cannot hide again. A read taken over by a newer link no longer claims the user cancelled it — those are different events and only one of them deserves silence. And every outcome is now written to the report, including cancellations; keeping a cancel off the screen is courtesy, keeping it out of the diagnostics was how a real bug survived a full round of testing with nothing to show for itself.

## v1.3.1+203 — two compile errors of my own making, and the checks that would have caught them (Jul 2026)

The previous build did not compile, and both faults were mine. One edit had replaced everything between two landmarks in a file, and a function that had been added between them since was swallowed along with the code being replaced — so a method was still being called that no longer existed anywhere. Another had inserted code by matching a single line, and that line turned out to sit in a different class from the one assumed, leaving the new code reaching for two things that class has never had.

What is worth saying is why nothing caught either. Both files were still perfectly well formed: every brace balanced, every import resolved, every string present in all three languages. A file can be flawless in all those ways and still call something that isn't there. So there are two new checks now, and they run over the whole downloader before anything is packaged: every private method that is called must be defined in the same file, and every named argument passed to one of our own constructors or methods must be one that thing actually declares. Together they cover both mistakes, and thirty call sites are verified this way rather than assumed.

## v1.3.0+202 — saved files stay saved, and two of my own bugs caught before you saw them (Jul 2026)

Downloads used to vanish. A finished one existed only as a row in a list, and Clear wiped it — so the question everyone asks afterwards, "where did that go", had no answer inside the app at all. There is now a Saved files section that survives restarts, and each entry plays, shares or deletes without going hunting through a file manager. Deleting removes the file from the phone's own index too, because deleting only the bytes leaves a ghost in the gallery that plays nothing — which reads as a broken app rather than a deleted file. If a file has been removed some other way, tapping it says so and stops listing something that isn't there.

Two problems in the previous version were found by reviewing it rather than by anyone hitting them. Waiting for the engine before reading a link is right, but the elapsed counter was starting after that wait instead of before it, so the card sat frozen at zero for up to forty seconds — and since that counter is the only thing that redraws the card while a link is being read, the line explaining that the engine was updating could never appear either. And the rule for "how old is too old" had been written down in two places at once, which is precisely the mistake that let an eight-month-old engine survive with updates switched on. There is one copy now, living with the code that uses it.

## v1.2.0+201 — the engine is made current before anything reads a link (Jul 2026)

Sharing a link never worked and pasting the same link always did, and the reason was never the link. It was a race. Opening the downloader starts making the engine current, and the engine bundled in the app is eight months old, so a link pasted a few seconds later was read by an updated engine while a link shared the instant the screen appeared was read by the old one. Two earlier attempts moved that work onto separate threads, which did not help because reading a link still raced it.

Reads now wait for the engine instead of racing it. There is a single rule in a single place: the engine is made current before anything reads a link. It starts at app launch rather than when the downloader is opened, so it is usually finished before anyone gets there; a read that arrives early waits, with the screen saying it is updating rather than showing a bare spinner; and the wait is capped, because an engine that cannot be updated must not become an app that refuses to try.

The check runs on four triggers now, and together they cover everyone. At launch. Before any read. After any failure, since a failure is the strongest single hint that the engine has fallen behind. And once a week in the background whether the app is opened or not — which matters most for people who use it rarely, and who until now found it broken every time they came back.

One more piece of the same knot: reading the engine's version was happening while holding the lock that reading a link needs. Moving readiness checks onto their own thread had achieved nothing, because two threads that share a lock are not two lanes. Nothing needs the version in order to extract anything, so it is out of that path entirely.

TikTok playback is fixed at a different layer, after two attempts at the wrong one. TikTok refuses requests for its own video addresses unless they carry the reference the page would have sent. Twice this was tackled by handing those details to the player, and twice it still failed — which is the point at which the approach is the problem, not its details. So they are no longer handed over: a small server inside the app fetches the video itself, with everything the site expects, and hands the player an ordinary local address that needs nothing special. Seeking works exactly as before, nothing leaves the phone, and the fix covers every site rather than the one that prompted it.

## v1.1.1+200 — the engine kept going backwards, and that explained almost everything (Jul 2026)

One line in a diagnostics report answered nearly all of this at once: the engine had gone from July 2026 back to November 2025. Not forward slowly — backwards, by eight months. The reason is structural and had been happening quietly every time: the download engine bundled inside the app is a November 2025 build, updating replaces it with a current one, and installing a new version of Innocent throws that replacement away and reverts to the bundled copy. Every new build silently reinstated an eight-month-old engine. That is why TikTok stopped resolving after having worked, why reads crawled, and why a photo post sat there indefinitely.

An engine older than the app now replaces itself immediately, rather than waiting for a weekly turn. A schedule cannot repair something that is broken on first launch, so staleness is judged against a fixed floor instead of against a clock. The routine weekly check waits for an unmetered connection; a stale engine does not, because two megabytes costs less than an app that does nothing.

And the check itself had been quietly cancelling itself. Fixing an earlier bug — where a background update could queue in front of reading a link — left behind a thirty-second delay and a rule that skipped the check whenever a link was being read. The queueing was fixed properly at the same time, which made both guards unnecessary, and on a phone where something is usually in flight they meant the check simply never happened. They are gone; the updater has its own lane, and when it does step aside for a reader it now tries again in under a minute instead of next week.

Pasting a link while another was being read now works. It used to be dropped on the floor with no message at all — the only way out was to cancel the first one. A newer link is a clearer statement of intent than an older one, so it takes over, and the read it replaced can no longer overwrite its result on the way out.

Readiness checks were the second thing queueing in front of reads. Preparing the engine unpacks a runtime and then runs a process to read its version, which after a fresh install is a long wait. It shared a lane with reading links, so the very first read queued behind all of it — invisible if you open the screen and then go and copy a URL, glaring if a shared link is read the moment the screen appears. It has its own lane now.

If notifications are switched off, Innocent says so. A download running with them blocked completes behind a service nobody can see, which from the outside is exactly like a download that never started — and the report now states plainly whether they are allowed, along with when the engine was last checked and how long a slow read actually took.

## v1.1.0+199 — playlists, one-tap downloads, and buttons where your thumb already is (Jul 2026)

A playlist link now behaves like a playlist. Until now every link was read as a single video, so pasting a playlist or an album got you one track out of forty. Paste one now and Innocent lists what is in it, everything ticked, and you untick whatever you don't want. It reads the list without resolving each entry first, because working through fifty videos to draw a list you might close again is minutes of requests to a site that is already rationing them. A link like `watch?v=…&list=…` is deliberately still treated as one video, because that is a video that happens to sit in a playlist and doing otherwise would override what you plainly meant.

Choosing a quality once is now possible, which is what makes the rest work. Quality used to mean picking a row out of a resolved list — which only works when there is exactly one video and someone is looking at it. It cannot say "720p if there is one" about forty unresolved entries, and it cannot be remembered. So quality can now also be expressed as an instruction each download works out for itself: Best, 1080p, 720p, 480p, 360p, or audio only, each falling back gracefully rather than failing when a video simply isn't published that large.

That unlocks the thing this has needed all along: set a default quality and a pasted link just downloads. No sheet, no choosing, nothing to tap. It stays off until you set it, because someone using this for the first time has no idea what 1080p costs on their connection — but once they know, answering the same question on every link is the most tiring part of the whole screen.

The download notification has Pause and Cancel on it. The moment you want to stop a download is almost always the moment you are looking at its notification, not the moment you feel like opening an app to find it.

And a handful of things that were simply missing. Subtitles can be downloaded and written into the file, in whichever languages you list. The cover image and the title and author can be saved into the file, so a download stops looking anonymous in your gallery. And there is a speed limit, for when something needs to finish without taking the whole connection with it.

## v1.0.1+198 — sharing a link works, and nothing waits forever (Jul 2026)

The strangest bug report of this whole project turned out to have the most ordinary cause. Sharing a link from another app left "Reading link…" turning and never finishing, while copying the exact same link and pasting it a few seconds later always worked. The link was never the problem. Opening the downloader starts a background check for a newer engine, and that check was running on the same single lane as reading a link — so a share, which reads the link the instant the screen opens, ended up queued behind a multi-megabyte download that retries up to three times with pauses in between. Pasting worked purely because a few seconds had passed and the check had finished.

Reading a link is the one thing a person is actually waiting for, so nothing is allowed to queue in front of it any more. The update check has its own lane, it now waits half a minute before starting, it stands aside entirely while a link is being read, and it will not replace the engine underneath a read in progress. And reading a link now has an upper bound: if it has not finished in forty-five seconds it stops and says so, instead of turning a spinner indefinitely.

TikTok playback gets another go, this time at the part that was probably wrong. The headers a video address needs were being attached to one exact text string and looked up by that same string — and that string travels through a route, a screen and two controllers before the player sees it. Any one of them tidying a single character and the headers vanish silently, which looks precisely like never having attached them. They are now matched by site within a short window, and if the engine did not report the two headers that CDNs most often insist on, Innocent supplies them: the page the link came from, and a browser to be.

Photo posts now say what went wrong. Every failure along that path — no post id in the link, an address that answered with an error, a post that genuinely has no photos in it — is recorded and shows up in Copy diagnostics. It has never worked yet, and a report that says only "nothing found" cannot be acted on; one that names the step can.

## v1.0.0+197 — the session happens by itself (Jul 2026)

The device's own report settled a question that had been guessed at for weeks. The first YouTube link came back with the full ladder — 1080p down to 144p — and every link after it came back with a single 360p entry, while the report's cookie line read "none". The engine was current, both helper components were running: nothing was stale, nothing was broken. It was a site giving a short leash to a caller it has no session for. A couple of complete answers, then progressively less.

So Innocent now gets a session by itself, and it does it before anything fails rather than after. Opening the downloader quietly asks YouTube for the ordinary anonymous visit any first-time visitor is given. There is no account, no password, no window, and nothing to tap — cookies are handed out while a page loads, and a page can load without anyone looking at it. If a link still comes back with one lonely resolution, that is treated as the symptom it is: a session is fetched on the spot and the link is asked once more.

The settings file is no longer the plan. It was a good mechanism and a bad answer — it only works if somebody keeps it updated forever, and building a feature that depends on its author never being busy is building a feature that breaks quietly. It still exists for anyone who wants it, but nothing now depends on it. What keeps this working instead is the two things that maintain themselves: an engine that updates from its own community, and a session the app fetches on its own.

TikTok videos should play now. Playback was failing on files that downloaded perfectly, and the reason was one line of data in the wrong place: TikTok publishes the headers its servers insist on at the top of its response rather than on each individual format, so the app read past them. The downloader had them and the player did not. Both do now.

## v0.99.9+196 — fixes that arrive without a new app (Jul 2026)

Until now, every repair in this downloader has taken the same slow road: change the code, rebuild, and get a new file onto the phone — which in practice means most installs never receive the fix at all. That is the wrong shape for a tool whose job is to keep up with sites that change their minds. So the settings most likely to go stale — which players to ask YouTube through, which addresses to reach TikTok on — can now be read from a small file on the internet instead of being sealed into the app. When a site changes, editing one line in that file repairs every installed copy within hours. Nothing to rebuild, nothing to install, nothing for anyone to do.

That file can only change settings, never behaviour. It carries no code and cannot point Innocent at anything to run or download; every value is checked before it is believed, and anything unrecognised is ignored. The worst a bad file could achieve is a list that does not work, which is the situation it exists to repair. It is off until an address is set, in Settings under Advanced.

The engine keeps itself current. It checks once a week, on an unmetered connection so it is never spending anyone's data, and again whenever a link is refused — and if that update actually moved, the link is retried by itself. The invisible repairs happen unprompted; anything that would open a window still waits to be asked, because a screen appearing on its own is alarming even when it would have helped.

Mobile data is no longer spent quietly. There is a Wi-Fi-only switch, and with it on, a download that would use mobile data stops to ask first rather than after. Free space is checked the same way — with a margin, since a file that finishes by filling the last of the storage is its own kind of failure. Neither is a hard refusal: both can be overridden, neither happens in silence.

And when something does go wrong, one tap explains it. Copy diagnostics puts everything a report needs on the clipboard — app and engine versions, whether the muxer is alive, which players are in use, whether a session exists, free space, and the last few failures. Web addresses are reduced to a site name and anything resembling a token or cookie is stripped, because a diagnostic is written to be pasted somewhere public and being useful is not the same as being nosy.

A line can also be sent to everyone at once. When a site breaks for everybody, a short notice appears at the top of the downloader — which beats a thousand people each discovering it alone and concluding the app is broken.

## v0.99.7+194 — sign in inside Innocent, and TikTok plays as well as it downloads (Jul 2026)

You can now sign in to a site from inside Innocent, and that is the real answer to YouTube. The device settled the question: the engine reported itself current, both of its helper components were running, and YouTube still asked this device to prove it was not a bot and handed over nothing at all. There was no stale part left to blame — what an anonymous request lacks is a session, and no amount of updating supplies one. The engine has always been able to use a signed-in session; the obstacle was that supplying one meant exporting a cookies file from a desktop browser, which is not something anyone is going to do on a phone. So the browser comes to you: tap Sign in, log in the way you normally would, press Done, and the link you were trying to open is retried by itself.

It adds nothing to the app. The sign-in screen is Android's own web view with a title bar and a Done button drawn in code — the large browser component this seemed to require, and the build risk that came with it, turned out to be unnecessary for this job. What is saved stays in Innocent's private storage, is used only to ask sites for what you can already see, and Settings has one button that forgets all of it.

Sign-in is offered where it helps and nowhere else. It appears on failures that an account would actually fix — the bot check, members-only and age-gated posts — and Innocent knows the right page for YouTube, TikTok, Instagram and Facebook, including the other addresses each session quietly depends on.

TikTok videos now play as reliably as they download. Pressing Play could fail on a video that downloaded perfectly, which made no sense until you look at what each path sends: TikTok's servers refuse a request for one of their own video addresses if it does not carry the reference the page would have sent, and the downloader was sending it while the player was not. The player is now handed the same details, for that one address only.

## v0.99.6+193 — the full quality ladder comes back (Jul 2026)

A quality sheet with one row on it was a regression, and this fixes its cause. Two versions ago the app started asking YouTube through its alternate players first, because they answer faster. They also answer with a much shorter list — often a single resolution — and because that answer was perfectly valid the app accepted it and never asked the player that knows the whole ladder. Speed was the wrong thing to optimise for there, and the speed that actually mattered came from somewhere else anyway. The full-list player goes first again; the fast ones stay as the fallback for when it is refused.

There is now a second line of defence for the same problem. If a YouTube link still comes back with a single resolution, the app quietly asks again through the alternate players and keeps whichever list is longer. It costs nothing when the first answer was already complete, which is nearly always.

A short list now explains itself. Most resolutions above 360p arrive as separate video and audio streams that have to be joined before they are any use, so if the joiner is unavailable they cannot be offered at all and the sheet collapses to whatever single combined stream the site publishes. That is now stated in the sheet rather than left to look like the app being broken — and Settings will tell you whether the joiner is missing from the build or merely unreachable, which are different faults with different fixes.

The engine updater retries. The reported failure was the update losing its connection partway through — a network fault, not a problem with the update itself, and one that usually succeeds on a second attempt. It now makes three, with a pause between them, instead of giving up after one.

## v0.99.5+192 — the site is never read twice, and Innocent is in the share sheet (Jul 2026)

The download stopped asking the same question twice. Reading a link and downloading it were two separate lookups: the app resolved the page, showed you the quality list, and then — when you pressed Download — threw that away and made the site explain itself all over again. That is slower, and worse, it is a second chance to be refused. It was happening in practice: a TikTok link would resolve cleanly, show its qualities, and then fail on download with an extraction error, because the site said yes the first time and no the second. The download now starts from the answer the app already has, so extraction happens once. If that saved answer turns out to be stale — media links do expire — it quietly falls back to a fresh lookup, once, and carries on.

Innocent is in the share sheet. Watch something in the YouTube or TikTok app, press Share, pick Innocent, and the downloader opens already reading that link. This is how these apps are actually used, and it was deliberately held back until now: an entry in every share sheet that did nothing when chosen would have been worse than not being there. Shared text rarely arrives as a bare link — it is usually a caption with a URL buried in it — so the link is picked out of whatever comes through, and text with no link in it is ignored rather than opening an error.

Failed downloads say what went wrong in words. A download that died was showing the engine's raw output — the same nine-line text the link reader stopped showing three versions ago. Both now go through the same explanation, so a failure reads the same wherever it happens.

Some quiet housekeeping. The list of links already offered from the clipboard, and the engine's record of finished jobs, were both growing without limit for the length of a session. Neither was large, and neither had any reason to keep growing.

## v0.99.4+191 — TikTok photos reach a second door, and the engine updater explains itself (Jul 2026)

The photo downloader was knocking on the wrong door. It read the post's own web page — which is exactly what the download engine does — so when TikTok served that page stripped of its data, both failed together and the app said there was nothing at the link. Sharing a failure with the tool you are working around is not a workaround. ("Unable to extract webpage video data" is a long-running, still-open issue in the engine itself, reported continuously since 2024; it is not something this app caused or can fix from that side.)

So photos now go to TikTok's mobile app service first — a different host, answering with a small piece of data instead of a half-megabyte page, and unaffected when the web front end decides to stonewall. The page stays as a second attempt, because when it does answer it carries a better caption. Two service addresses are tried before giving up, the post is matched by its own id rather than assumed to be the first thing that comes back, and only the clean picture is ever read — the watermarked copies sit right beside it in the same response and are never touched.

Failures stop lying about what happened. If the engine errored and the photo lookup then found nothing, the app was reporting "no downloadable media found at this link", as though the post were empty. It now reports what actually went wrong, which is also what decides whether updating the engine is worth offering.

The engine updater got five ways in and a receipt. It reaches the update through reflection, because the exact shape of that call is not something the library's documentation pins down — and if the shape it assumed was wrong, the old code failed with no explanation. It now tries the simplest form first, has four more ways to find the release channel if that form isn't there, and on success tells you the version before and after so you can see it moved. On failure it opens a readable panel naming which step broke, instead of a message that slides away before it can be read.

## v0.99.3+190 — TikTok photo posts, saved at full size with no watermark (Jul 2026)

A growing share of TikTok isn't video at all: it's photo mode, a set of stills you swipe through with a song underneath. Paste one of those links now and Innocent saves the whole set — every picture, at the size the creator uploaded, with no logo burned into it — into its own folder named after the post, and the music track is still there to grab separately if you want it.

This needed its own path, because the download engine genuinely cannot do it. yt-dlp builds its list from a post's video, and a photo post doesn't have one, so it falls through to a branch that returns the soundtrack by itself — its own tests for these posts expect an audio file and nothing else. No setting changes that. The pictures are in the page's own data, which is where TikTok's web player reads them from, so that is where Innocent reads them from too. The watermark you see on a shared TikTok belongs to the rendered video copy; the source images never had one.

Full size, not thumbnails. TikTok's image server encodes a resize recipe into the URL and hands out several versions of every picture. Innocent ranks them and takes the untouched original, falling back through the alternatives only if a mirror refuses — which is the difference between keeping a 1080-wide photo and keeping a 300-wide preview of it.

None of this slows a normal video down. The extra lookup only runs when a TikTok link comes back with no video in it, which is exactly the signature of a photo post, so an ordinary clip never pays for the check.

Two things a review pass caught before this shipped. A photo set was being recorded the same way a video download is, which meant that if Android killed the app mid-save it came back offering a Resume button — and resuming would have failed every time, because a photo set has no partial file to continue from and its recipe is not something the download engine can replay. It is now marked as what it is: not resumable, no Pause button, and it says "Photos saved" rather than borrowing the wording for files. Separately, a photo post whose soundtrack could not be read left an empty bar with a stray border at the bottom of the sheet; that bar now stays away when there is nothing in it to press.


## v0.99.2+189 — TikTok without the watermark, downloads that show their work, pause and resume that survive anything (Jul 2026)

TikTok downloads no longer carry the logo. TikTok serves every clip twice — one copy with its watermark burned into the picture and one without — and the previous build not only listed the watermarked one, it pre-selected it. That copy is now hidden whenever a clean one exists, and if a clip only has the watermarked version it is labelled so you know before you tap.

Resolutions are named the way everyone names them. A TikTok clip is 1080 wide and 1920 tall, and the last build called that "1920p". Quality is named after the short side, so it now reads 1080p — and the same fix applies to every portrait video from every site.

Reading a link is faster again, on two fronts. The player used to try the slow, heavily-checked path first and only fall back to the quick one after it had already failed; that order is now reversed, so the fifteen-second refusal isn't paid before the fast attempt is even made. And pressing Play no longer starts a second engine process to ask for something we were already holding — the answer is in the data we just read, so playback starts straight away.

Downloads now tell you what is happening. Every row shows how much of how big, the live speed, and the time remaining, and the numbers keep working even when the multi-connection downloader is doing the fetching — that mode reports progress in its own format, which the last build simply didn't read, leaving the bar stuck at zero.

Pause and resume, and nothing lost to a dropped connection. Downloads can be paused and picked up where they stopped rather than started over. If the connection drops mid-download, Innocent now reconnects and continues by itself, up to four times with a growing wait between tries. And if Android kills the app outright, the unfinished download comes back as a Resume button the next time you open the downloader instead of disappearing — the partial file was always still on disk; what was missing was the record of what to do with it.

The download sheet clears the navigation bar. On phones with a three-button bar the Download button was sitting underneath it. It now measures the real inset, so it sits clear on gesture navigation and button navigation alike.

Site tiles look like icons rather than neon. The coloured glow is gone — no shipped launcher lights an icon with its own colour — replaced with a top-left light source, a hairline rim to lift each tile off the black background, and a neutral shadow.

## v0.99.1+188 — the downloader gets fast, gets past YouTube's bot wall, and stops looking unfinished (Jul 2026)

Reading a link is dramatically faster after the first one. yt-dlp caches YouTube's decoded player script — the part that costs a round trip and a slow JavaScript challenge — but on Android it has no writable home directory, so that cache was silently disabled and the whole cost was paid again on every single paste. The engine now keeps its cache inside the app, so the expensive work happens once and later links resolve in a fraction of the time.

"Sign in to confirm you're not a bot" now has a fix you can tap. That check is YouTube's, it moves every few weeks, and the copy of yt-dlp bundled inside the library is frozen at whatever was current when the library shipped — so it goes stale and starts getting refused. Innocent can now replace that engine with the current release from inside Settings, no rebuild and no reinstall, and when a link is refused the failure card offers the update right there and retries the link for you once it finishes. If a link is refused because it genuinely needs an account, you can point Innocent at a cookies.txt file instead, and there is an editable list of fallback YouTube players it will try automatically before giving up.

Failures explain themselves. The old build dumped yt-dlp's raw nine-line error — wiki links and all — into a snackbar. Now each failure is sorted into what actually went wrong (bot check, needs an account, network, outdated engine, nothing downloadable there) and shown as one sentence with the buttons that fix it, and the full text is one tap away under Details.

Reading a link no longer freezes the screen. It reports inline, with a seconds counter so a slow network reads as slow rather than stuck, and Cancel really does kill the process. A link you looked at in the last twenty minutes reopens instantly from memory instead of being fetched again.

The site grid looks like a finished product. Tiles are drawn as proper app icons — a gradient fill with a white monogram and a soft shadow — instead of the washed-out tinted outlines of the first build, and the grid is now sized to fit them: cells used to be nearly four times taller than what sat inside them, which is what made the screen feel loose and empty. Each group sits on its own panel, "Add" moved into the section header as Edit (as a tile it was stranded alone on a second row next to three empty cells), and the paste bar is taller, highlights while you type, and has a clear button and a Go arrow.

## v0.99.0+187 — a real downloader: paste a link from almost any site, pick a quality, stream or save (Jul 2026)

The Downloads tile in the Me tab is no longer a placeholder. It opens a full downloader built on yt-dlp, the same engine behind Seal and YTDLnis, running entirely on your phone — no server in the middle, so nothing to be blocked or shut down, and no one else sees what you look up.

Paste a link from almost anywhere. yt-dlp ships extractors for well over a thousand sites, so YouTube, Facebook, TikTok, Instagram, X, Dailymotion, Vimeo, SoundCloud, Reddit, Twitch and the long tail beyond them all resolve to a real quality list. Adult sites are supported too, but they are kept out of the grid until you switch them on in the downloader's own settings.

Three ways to hand over a link, because the obvious one isn't the one people use. Paste it into the bar; or copy it anywhere and come back — the clipboard is checked every time the screen regains focus, and an offer appears; or tap a site tile, which opens that site in your browser so you can find something and copy its link. (An in-app browser that spots media on the page by itself is the next step.)

The quality sheet tells you the truth. One row per resolution instead of twenty-five near-duplicates, with the real file size — and for the high resolutions, which arrive as separate video and audio streams, the size shown already includes the audio that gets merged in. Estimated sizes are marked with a ~ rather than presented as fact. Audio-only rows are listed separately, with an MP3 option when a conversion is possible.

Codecs are labelled, which matters more on some phones than others. AV1 and VP9 have no hardware decoder on a lot of devices and fall back to software: hot phone, flat battery, dropped frames. Those rows carry a badge, and the pre-selected choice is always the most compatible h264 option at or below 720p.

Stream before you commit. Every link can be played straight away without downloading anything, in the same player with all its gestures, subtitles and audio effects.

Downloads survive you leaving. A foreground service holds the download open when you press Home, switch apps, or swipe Innocent out of recents, with progress in the notification shade and a wake lock so a sleeping screen can't stall it. Cancel is a real cancel — it kills the process, including while a link is still being read. Finished files land in Download/Innocent by default (you can change the folder), and are handed to the media index immediately, so they appear in the Videos tab and your gallery without a restart.

Multi-connection downloading is used where it helps. Plain HTTP files are fetched with aria2c across several connections; fragmented streams stay on the engine's own downloader, which is the only thing that can walk them.

No icons are bundled and none are fetched. Site tiles are monograms in each site's colour — which keeps the app smaller, and means the list of sites you care about is never sent to an icon service to be looked up.

## v0.98.0+186 — background play that survives screen-off, a sleep timer you can trust overnight, and clean exits (Jul 2026)

Background play now keeps going with the screen off. Turning on Background Play and locking the phone used to fall silent on many devices — the audio only stayed alive if the app went fully to the background, not when the screen simply switched off in the foreground. Now the audio thread is made independent of the display the moment you enable Background Play, so music and video keep playing with the screen off, powered by the media foreground service and its wake lock.

The sleep timer is now reliable for overnight use. It counts down against the real clock instead of ticking a counter, so deep sleep can't make it drift or stall — it fires right on time. And when it fires it now fully releases the foreground service and wake lock, so your phone actually sleeps and saves battery instead of staying awake all night.

Leaving a video cuts the sound instantly. Pressing Back (with Background Play off) now silences audio on the same frame you leave, instead of letting it bleed for a moment behind the previous screen — while still saving your exact resume position.

Sending the video you're watching works for Android/data files too. "Transfer this video" now pulls a local copy first for app-data videos, so they actually send.

## v0.97.2+185 — build fix: missing Video import (Jul 2026)

Fixes a compile error in the previous build: local_screen.dart used the Video type in its new guarded video-open path without importing it, so the release build failed with "Type 'Video' not found". Added the missing import. No behaviour change.

## v0.97.1+184 — Android/data everywhere in the pickers, locked-content guards, and storage that stays in check (Jul 2026)

Add-Files pickers now reach Android/data fully. When iADB is connected, the Images and Audio tabs surface app-data media, and the Files tab browses Android/data like a real file manager — every file type, any depth. Pick anything there and it's pulled to a local copy on the way into your vault or a transfer, so it keeps working even after you disconnect. The picker is also faster: reopening a folder you already viewed is now instant instead of re-scanning each time.

Locked content no longer dead-ends. Tapping an Android/data video before connecting used to open the player and fail; now it asks you to connect first, with a one-tap path to the ADB screen — the same friendly prompt folders already used.

Private Folder keeps hidden files for good. Adding an Android/data file to your vault now copies the actual bytes in, so it plays with no ADB connection later.

Settings opens cleanly. However you open Settings — the Me tab, the ⋮ menu, or the top shortcut row — the bottom tab bar now steps out of the way, so tapping another tab takes you there instead of leaving Settings on top.

Pulled copies no longer pile up. The iADB playback cache is now capped and reuses existing copies, so replaying large app-data files can't slowly fill your storage.

## v0.97.0+183 — Voice Effects & Equalizer that actually change the sound, plus a smarter iADB and Continue Watching (Jul 2026)

Audio effects now work on video and music. Picking a Voice Effect or adjusting the Equalizer during playback used to do nothing on many phones — the effect was attaching to Android's "global mix" (session 0), which modern Android ignores for apps that play through their own audio track (which this app does, via libmpv). Now the player generates a real audio-session id, binds libmpv's audio output to it, and attaches the Equalizer, Bass Boost and Virtualizer to that same id — for both the video player and the music player. The Equalizer also makes sure it has a real session before it starts, so it can never silently bind to the dead session again.

iADB is smarter about your app-data videos. Connecting over iADB now scans Android/data automatically and shows those videos in Local right away — no need to open the ADB screen and tap Scan (that button stays, for a manual re-scan). Pulling to refresh, or the ⋮ Refresh, now re-scans Android/data too when iADB is connected. If the connection drops mid-refresh your existing videos are kept (never blanked), and you get a gentle "Reconnect" prompt only if you actually had app-data videos before.

Continue Watching is now on demand. It no longer always sits at the top of Local; long-press the round Resume button to peek at it, and it tucks away again as soon as you open a folder, play something, or search. If there's nothing in progress, long-press tells you so instead of showing an empty strip.

## v0.96.2+182 — better crash diagnostics (Jul 2026)

The Details panel on the error screen now shows more. When a screen fails, it lists the actual code locations involved — and when a release build has stripped those out, it falls back to the widget and library the failure happened in, so there's always something concrete to point at. A screenshot of this panel is what pins down an intermittent crash exactly.

## v0.96.1+181 — the tab-switching crash, and an error card that says what broke (Jul 2026)

**Switching tabs quickly no longer breaks a screen.** Each tab records which tab it is one frame after it appears. When you tapped through tabs faster than a frame — or left a tab while a picker or scan was still loading — that record could run *after* the tab had already been thrown away, and reaching for a discarded screen threw an error. Because the throw landed while the *next* tab was drawing, that tab got replaced by "Something didn't load". This is why the error moved around (Transfer one time, Music the next) and why fast tapping triggered it. Every one of these delayed callbacks now checks the screen still exists before doing anything — in the tab shell, the shared-video handler, the search bar and the Video tab's startup.

**The error card now tells you what happened.** If a screen ever does fail, tapping **Details** shows the actual error and the lines of Innocent's own code involved. These failures are intermittent and hard to reproduce, so a screenshot of that panel is worth more than any description — it points straight at the cause.

## v0.96.0+180 — much faster transfers, and transfers that survive (Jul 2026)

### Faster file transfer

Sending a large movie between two phones used to crawl at a few MB/s. The single connection was the bottleneck: between two phones on the same Wi-Fi every byte crosses the air twice, and one stream keeps backing off whenever the shared airwaves drop a packet. Big files (8 MB and up) now download over **several connections at once**, each pulling a different part of the file — the same trick fast-share apps use — so the link stays full instead of stalling. Bigger files use more connections (up to four).

There's a second half to the speed that no app can do for you: the path the data takes. Through a shared home router every byte makes two hops; over one phone's **hotspot** it makes one, which can be several times faster. The Send screen now points this out while a share is live — turn on the sending phone's hotspot, connect the other phone to it (no internet needed), and start the share. Innocent already prefers the hotspot connection automatically when one is up.

Combined, these bring same-Wi-Fi transfers into the range people expect from dedicated file-sharing apps, especially on 5 GHz Wi-Fi or a hotspot.

### Transfers that don't die

A transfer no longer stops just because you leave. Press Home, switch to another app, or even swipe Innocent out of recents — the transfer keeps running in the background with its progress in the notification shade. If Android ever kills the app under memory pressure, it comes back.

And if a download is genuinely interrupted — the app is force-closed, or the Wi-Fi drops for good — reopening Innocent shows a **Resume** banner on the Receive tab. One tap reconnects to the sender and continues each file from exactly where it stopped, not from the beginning. This works because each download is written to a temporary file that's only finalised once complete, and the partial is kept until then; a half-received 900 MB video resumes as a 900 MB video, not a fresh download. Finished transfers clean up after themselves.

## v0.95.0+179 — the real cause of "Something didn't load", and a proper prompt for locked folders (Jul 2026)

### The error screen: found and fixed at the source

v0.94 fixed four things that could freeze or break a screen, but the error card kept appearing — most visibly on the Transfer tab. The actual cause was somewhere else entirely, and it affected the whole app.

Every piece of text in Innocent is looked up through a single helper. That helper ended with a "this can never be null" assertion — and when the lookup *did* come back empty, that assertion threw **while the screen was being drawn**, which Flutter turns into the full-screen "Something didn't load" card. The lookup comes back empty whenever the translation set isn't in scope for the code asking: a phone set to a language outside English, Burmese and Thai, a dialog built from the wrong context, or the moment a language change is applied. There are over five hundred of these lookups across the app, so any one of them could take out a screen — which is exactly why it seemed random and kept coming back.

Two changes make it impossible:

- **A missing translation can no longer crash a screen.** The lookup now falls back to English instead of asserting. Seeing one English label is a cosmetic problem; losing the whole screen is not.
- **The translation set now loads for every language**, not just the three that are fully translated. Individual missing phrases already fall back to English on their own, so a phone set to any language gets readable text instead of no screen.

Also fixed: the QR code on the Send screen is only drawn once there's an address to encode — handing it an empty value could fail mid-draw and take the tab down with it.

### Locked folders now explain themselves

Opening an Android/data or Android/obb folder after the ADB connection had dropped just showed an empty folder with no explanation. Now it opens a short prompt that says why the folder is locked and offers one tap through to the ADB screen — worded differently depending on whether iADB is already installed ("Reconnect") or not ("Set up"). Come back connected and the folder opens.

This lives in one shared component, so every place that needs an ADB connection asks in exactly the same way — the file pickers in Transfer and Private Folder already use the same path.

## v0.94.0+178 — iADB by default, a cleaner ADB screen, and a big stability fix (Jul 2026)

**The iADB app is now the default way in.** On Android 11 and up, Innocent starts out set to the iADB backend — the one that stays connected — instead of the built-in engine. If iADB isn't installed, the screen now offers a single "Get iADB on Play Store" button that takes you straight there. (On older phones nothing changes: they still default to the built-in engine, which is all they can use.)

**The ADB screen no longer mixes the two backends.** Choosing "Use the iADB app" now shows only what iADB needs — a status card and Connect. All the built-in engine's pairing codes, notification pairing, reboot setup and manual IP:Port controls stay hidden unless you actually pick the built-in backend. Whichever one you choose, you get that flow and nothing else.

**App-data folders read better in Local.** Videos found in Android/data and Android/obb still appear alongside everything else, but a folder is now labelled with just the folder that holds the videos — "Telegram Video" rather than a long package path — with a small "Hidden" tag underneath so its origin is still obvious. The same tag now appears in grid view, which previously only marked dot-folders.

**Hidden folders in the file pickers.** Transfer and Private Folder share one picker, and it now has a "Show hidden" button. Turning it on reveals hidden folders straight away; if the locked Android/data caches would need an ADB connection you don't have yet, it offers to open the ADB screen and picks up where you left off when you come back.

### Stability: the "Something didn't load" screen

Several people hit a screen reading *"Something didn't load"*, or found the app stopped responding to taps until it was closed and reopened — usually while something was loading or a transfer was running. There were four separate causes, all now fixed:

- **The file picker re-read the whole folder on every tap.** Flutter restarts an asynchronous task if it's started from inside a rebuild, and ticking a file, opening a menu or a thumbnail arriving each counts as a rebuild. Large folders effectively never finished loading, and a tap landing mid-read could break the screen. The read now happens once per folder.
- **The picker read the disk from the drawing code.** File sizes and dates were fetched with blocking calls inside the sort and again for every visible row — hundreds of disk reads while the screen was trying to draw. They're now fetched once, in the background, before the list is shown.
- **The "Largest videos" sheet re-measured the entire library while being dragged.** Every drag frame restarted a scan of every video's size. It's now measured once, before the sheet opens.
- **A failure could leave buttons permanently disabled.** Screens disable their controls while working and re-enable them when finished — but if the work failed part-way, the "finished" step never ran, so everything stayed greyed out and the app looked dead. Every one of these paths now re-enables its controls whether the work succeeds or fails. The PIN dialog had the same flaw and would strand its Save button.

On top of that, background errors that nothing was waiting for are now caught and logged instead of being able to take the app down, and the error screen itself has a **Reload** button — the old "Go back" couldn't help when the failing screen *was* the one you were on, which is why a restart was needed.

## v0.93.3+177 — build fix: iADB libraries no longer force a newer Android (Jul 2026)

The previous build got past finding the iADB libraries but then failed the manifest merge: those libraries require Android 11 (minSdk 30), while Innocent supports Android 7+ (minSdk 24), so the merger refused to combine them.

Rather than raising Innocent's minimum to Android 11 — which would drop every Android 7/8/9/10 phone — this release keeps the minimum at Android 7 and tells the manifest merger to allow the newer libraries (`tools:overrideLibrary`). That's only safe if the iADB code is never actually run on an older phone, so the code was restructured to guarantee it:

- All references to the iADB libraries are now isolated in a single class (`IadbBridge`) that is only ever reached after an "Android 11 or newer?" check. On older phones that class is never loaded, so there's nothing that could crash.
- Every iADB entry point returns early on older Android versions, and the "Use the iADB app" option reports that it needs Android 11.

Result: Innocent still installs and runs on Android 7 and up (using the built-in ADB backend), and the iADB backend simply becomes available on Android 11+. No app behaviour changed for existing users.

## v0.93.2+176 — build fix: the iADB library folder is now found (Jul 2026)

The previous build still failed to find the four iADB libraries, and the error message showed why: it was looking in `android/app/app/libs/` — with "app" twice. The library folder declaration was written in the project-wide section, where a relative path gets resolved against *each* module's own folder, so `app/libs` became `app/app/libs`. Moved the declaration into the app module itself, where `libs` unambiguously means `android/app/libs`.

This was verified by reproducing the real project layout (root project plus an `:app` module) and resolving all four libraries against a real Gradle run — the old form fails, the new one resolves every file. No app code changed.

## v0.93.1+175 — build fix: iADB libraries now resolve (Jul 2026)

v0.93.0 failed to build with "Could not find :aidl-release:" (and the other three iADB libraries). The library files were in the right place — the build could see them at `app/libs/` — but the way they were referenced in Gradle (Kotlin DSL) didn't resolve. Switched to the standard module-notation reference (`":aidl-release@aar"`) alongside the flatDir repository, which is the reliable Kotlin-DSL equivalent of the usual local-AAR declaration. This was verified by actually resolving the four libraries against a real Gradle run, so the reference form is confirmed correct. No app code changed — this is purely the Gradle wiring. (`app/libs` with the four `.aar` files must still be present in the build.)

## v0.93.0+174 — the iADB backend is now real: bind to iADB like a file manager (Jul 2026)

Innocent's second ADB backend is now functional. Pick **"Use the iADB app"** on the ADB screen and Innocent connects to the separately-installed **iADB** app the same way EX File Manager does — through iADB's always-on privileged server.

**Why this is the reliable one.** The built-in engine talks to the phone over a Wi-Fi ADB socket, so it needs Wireless debugging left on and can drop when Wi-Fi changes or the phone sleeps. The iADB backend is different: iADB runs a small helper process on the phone (set up once), and Innocent talks to it through Android's internal channels (a "binder") instead of a socket. So once iADB is set up, reconnecting is instant, it survives Wi-Fi changes, and Wireless debugging doesn't have to stay on. This is the "pair once, always connected" behaviour you get in iADB-based file managers.

**How to use it.** Install the iADB app and start its server (it shows "iAdb is running"). In Innocent, open ADB connection, choose "Use the iADB app", tap **Connect**, and allow access when iADB asks ("Allow Innocent to access iAdb?"). Scanning Android/data and playback then run through iADB automatically. The built-in engine stays the default and is unchanged, so nothing you've set up breaks.

**Under the hood (for the curious).** Innocent now bundles the iAdb-api client libraries and exposes a tiny privileged service (`IUserService`) that iADB runs inside its server as the shell user — so it can open files in Android/data that a normal app can't. Scanning goes through a shell `find` in that privileged process; playback copies the file out through a shell-owned file descriptor. All of it is defensive: if iADB isn't installed, isn't running, permission is denied, or the connection drops, the screen says so and nothing crashes.

**Build note.** This release adds the iADB client libraries (four `.aar` files in `app/libs`, resolved via a flatDir repository), turns on AIDL compilation (off by default in modern Gradle), and declares the iADB app in `<queries>` for Android 11+ visibility. If you build it yourself, make sure the `app/libs` folder is included.

## v0.92.0+173 — pairing now connects in one step, and "Connected" tells the truth (Jul 2026)

Two targeted fixes to the built-in connection, informed by studying how Shizuku/iADB actually work under the hood.

**Pairing now hands straight off to a live connection.** This was the quiet culprit behind "it paired but still won't connect." Pairing and connecting use two *different* services on two *different* ports (Android advertises `…-pairing` and `…-connect` separately), so after a successful pair there was still no live connection and no saved port — the app had to go discover the connect service all over again, and that second discovery was the flaky step. Now, the moment pairing succeeds — while Wireless debugging is freshly advertising — the app immediately connects and remembers the port. So "Pair from notification" ends with you actually connected, and every later reconnect uses the fast remembered-port path instead of re-discovery.

**"Connected" no longer lies.** An ADB socket can look open while being completely dead (Wi-Fi changed, phone dozed, or Wireless debugging restarted on a new port) — this is a well-known socket problem, and it's why the status could say Connected while every operation failed. Now, before trusting a connection that claims to be up, the app does a tiny bounded check to prove it's really alive; if the check fails, it quietly drops the dead socket and reconnects for real. So the badge reflects reality, and stale-socket failures heal themselves.

**Why this still isn't quite iADB, and what's actually next.** These fixes make the socket-based built-in engine as solid as that approach can be — but iADB/Shizuku feel unbreakable because they don't rely on a socket at all. They use the ADB connection *once* to launch a tiny helper process on the phone that keeps running on its own; after that, the app talks to it through Android's internal channels (a "binder"), so the connection survives Wi-Fi changes, doesn't need Wireless debugging left on, and reconnects instantly with no re-pairing. Bringing that same always-on model into Innocent — either by connecting to iADB's helper, or by building our own — is the next step now that pairing and status are solid. Nothing here was removed; the built-in engine stays the default.

## v0.91.0+172 — connect that doesn't hang, scans that don't drop, honest status (Jul 2026)

The notification pairing works now, so this release fixes the three things that made the *built-in* connection feel unreliable afterward.

**Status no longer contradicts itself.** The screen could show a green "Connected" badge with "Not connected. Tap Connect…" right underneath. The help text was guessing the state from old wording instead of the real connection state. Now it follows the actual state, so what you read matches the badge.

**Connect fails fast instead of spinning forever.** When the phone's mDNS was being slow, the app used to try two long discovery windows back-to-back — up to ~30 seconds of spinner before giving up. Now it's one bounded window, then a clear message telling you to check the Wireless-debugging toggle (or paste IP:Port once, which is remembered so later connects are instant). No more endless spinner.

**Scanning Android/data no longer drops the connection.** During a scan, the background keep-alive could slip a ping in between the scan's file-listing batches, and on some phones that interruption killed the scan. Scans now hold the connection to themselves — the keep-alive steps aside until the scan finishes — and if the connection was lost just before a scan, the scan now re-establishes it on its own (saved port → local sweep → mDNS) instead of failing outright.

**Why the built-in connection still isn't as rock-solid as iADB — the honest version.** The built-in engine talks to the phone over a Wi-Fi ADB socket, which means Wireless debugging has to stay on (that's the "tap to turn off Wireless debugging" notification you see), and the connection port changes every time Wireless debugging restarts. Apps like iADB feel better because they work differently: after connecting once, they start a small helper process on the phone that keeps running on its own — so you can even turn Wireless debugging back off, the connection survives Wi-Fi changes, and reconnecting later is a single instant tap with no re-pairing. That "always-on helper" model is the real fix for the last of these rough edges, and wiring Innocent up to iADB's helper is the next release. Everything here makes the built-in path as smooth as a socket connection can be in the meantime; nothing was removed and it stays the default.

## v0.90.0+171 — the pairing notification actually works now (Jul 2026)

v0.89 added "pair from the notification," but on modern phones the notification never appeared. This release fixes that at the root and hardens the whole flow.

**Why it didn't work:** the app had never requested the **notifications permission** (POST_NOTIFICATIONS, required since Android 13). On Android 13+, if that permission isn't granted, the system **silently hides** a foreground-service's notification from the shade — so the pairing notification was being created but suppressed, and there was nothing to reply to.

**The fix:**
- The app now **asks for notification permission** the moment you tap "Pair from notification." If you've turned notifications off, it tells you and opens the right Settings screen so you can switch them back on.
- The pairing notification is now posted **immediately** (no longer waiting for the phone's pairing service to be discovered first), so it's there the instant you open the pairing dialog. When the dialog is detected, the notification updates to "Pairing dialog detected" for reassurance.
- The reply you type is now caught by a **dedicated, always-registered receiver** instead of one that lived inside the service — so the 6-digit code is captured reliably even if Android had paused the helper while you were in Settings. The actual pairing runs on a background thread (pairing can take longer than a notification reply is allowed to run), then the app connects automatically.

So the flow is now exactly like a good file-manager's: start it, open Wireless debugging → "Pair device with pairing code," pull down the shade, tap **Reply**, type the 6 digits, send. No split-screen.

**Honest note on "stays connected forever":** the built-in engine keeps the connection warm (a light keep-alive every ~25 seconds) and silently reconnects (remembered port → local-port sweep → mDNS) whenever it's needed, so day-to-day it feels always-on. But it's a Wi-Fi ADB socket, so a Wi-Fi change, deep sleep, or reboot can still drop it — the app just re-establishes it on the next action. A truly always-alive connection (the kind that never needs re-establishing) comes from the **iADB-app backend**, which is next.

**On the iADB third-party backend:** the integration is now fully mapped — the iADB API and its prebuilt libraries are ready to wire in. It's deliberately **not** in this build: it's a large native change involving binary libraries that can't be verified without a full compile, and bundling it here would have risked breaking the build so this pairing fix couldn't be tested. It ships in the next release, once this fix is confirmed working on your phone. Nothing was removed — the built-in engine remains the default and is unaffected.

## v0.89.0+170 — choose your ADB backend + pair from the notification (Jul 2026)

Two changes aimed at making Android/data access easier and more flexible, both built on the existing (working) libadb-android engine — nothing was ripped out.

**Backend selector.** The ADB screen now lets you choose how Innocent reads Android/data:
- **Built-in (default)** — the embedded engine. No other app needed; Innocent pairs and connects on its own.
- **Use the iADB app** — the setting is saved now and the choice is offered, but binding to the separately-installed iADB app (the way EX File Manager does, Shizuku-style) lands in a later update. Picking it today shows a note and keeps working via Built-in.

**Pair from the notification — no split-screen.** This is the big usability win, modeled on how iADB does it. Previously, pairing forced you into split-screen / pop-up so the system "Pair device with pairing code" dialog stayed visible while the app ran the pairing. Now, tapping **"Pair from notification"** starts a small foreground service that:
- keeps discovering the pairing service in the background (a service can use the network while the app isn't visible), and
- posts a reply notification ("Enter the pairing code here").

You just open the pairing dialog, read the 6-digit code, pull down the shade, tap **Reply**, type the code, and send. The dialog never closes because you never leave it. On success, Innocent connects automatically. On aggressive OEMs (Xiaomi/OnePlus etc.) you may need to exclude Innocent from battery optimization so the background service keeps its network access.

Under the hood: new `AdbPairingService.kt` (foreground service + `AdbMdns(SERVICE_TYPE_TLS_PAIRING)` discovery + `RemoteInput` notification + a receiver that calls the existing `AdbManager.pairWithMdns`); new `mx_clone/adb` channel methods `getBackend`/`setBackend`/`startPairingService`/`stopPairingService`; the pairing result is broadcast back and forwarded to Flutter as `onPairResult`. `AdbManager` gained a persisted backend preference. No new dependencies, no new binaries — build-safe. Backend 2 (the iADB-app client, which needs the repo's prebuilt `.aar`) is deliberately deferred to v0.90 so this build can be tested on its own first.

## v0.88.0+169 — connecting is clean again; the connection was never the bug (Jul 2026)

Careful audit result: the connection logic is sound and "Connected" is honest —
it's only shown after the device actually answers a command. What looked like a
broken/stuck connection was the **auto-refresh** that ran right after connecting:
it scanned Android/data (which can take up to a minute) while holding the busy
state, so every button was greyed out and a spinner sat next to "Connected" —
the app looked frozen even though it was connected.

- **Removed the auto-refresh after connecting.** Connecting is now clean and
  immediate: it reconnects, shows a steady green "Connected", and leaves every
  button usable. Refreshing your video list is back to being the "Scan
  Android/data" button you press when you want it — your already-scanned videos
  still appear in Local for everyday watching.
- **A manual Connect is quicker.** It now retries the last-known port first and
  only does the deeper localhost sweep if that's actually stale, instead of
  always sweeping.

Native + Dart change -> full rebuild.

## The longer view
Wireless ADB is fundamentally a bit fragile — Android lies about whether the
socket is alive, the port changes on reboot, its mDNS discovery is unreliable,
and Wi-Fi power-saving quietly drops the link. Each of those is worked around
now. The genuinely bulletproof long-term design is a persistent helper running
in the device's shell (the approach Shizuku uses), which survives all of the
above — a larger, dedicated piece of work worth doing once this is confirmed
stable in daily use.
## v0.87.0+168 — connection confirmed; daily-use polish (Jul 2026)

The connection is solid now (it reconnects on open via the remembered port).
This build cleans up the rough edges around it.

- **Clear status.** The green "Connected" line now stays visible even while the
  app is refreshing your video list in the background — previously it vanished
  and left just a spinner, which looked like it was stuck mid-connect. Now you
  always see "Connected", with "Scanning…" underneath when it's refreshing.
- **The indicator is accurate after a manual connect too** (not only the
  automatic one), and a manual connect also refreshes Local in the background.
- **Playing a video after a reboot just works.** If you open a video from your
  library and the wireless port has changed since last time, the app now finds
  the new port on its own (the same quick localhost sweep) instead of saying
  "not connected" — you don't have to visit the ADB screen first.

Native + Dart change -> full rebuild.
## v0.86.0+167 — fix pairing/connect getting stuck (Jul 2026)

v0.85's port sweep had an unintended side effect: it ran during the automatic
reconnect that fires when the ADB screen opens, and while you weren't connected
yet that sweep-plus-mDNS could hold the connection lock for ~20 seconds. So when
you then tried to pair or connect, it sat waiting behind it — "Pairing…" that
never finished.

Fix — split automatic from explicit:
- The **automatic** reconnect (screen open, and getting the socket back mid-use)
  is now light: it only retries the last-known port, quickly, and never holds
  things up. If that doesn't work it just says "Not connected — tap Connect."
- The **full** rediscovery (the localhost port sweep + mDNS) now runs only when
  you explicitly ask — right after pairing, when you tap Connect, and in the
  after-reboot auto-reconnect that runs in the background. Those are the moments
  you're waiting on a connection anyway, so nothing interactive gets blocked.
- After a reboot the background receiver finds the new port and remembers it, so
  the next time you open the screen the light reconnect just works.
- The keep-alive now stops itself the moment the connection is actually gone,
  instead of periodically re-taking the lock — so it can't get in the way of
  your own pair/connect either.

Net: open the screen and pairing/connecting is immediate again; after the first
pairing it reconnects on its own. Native change -> full rebuild.

## v0.85.0+166 — reconnect that actually works: localhost port sweep (Jul 2026)

The real fix for the "Reconnecting… → Not connected" frustration.

**Why it kept failing:** reconnection leaned on mDNS to find the device, and
Android's mDNS (NsdManager) is notoriously unreliable — it often finds nothing,
especially for a service on the *same* device. After a reboot or a Wireless-
debugging toggle the port changes, the saved port goes stale, mDNS comes back
empty, and you're stuck.

**The insight:** the app and adbd run on the *same phone*, so the address is
always 127.0.0.1 — the only thing we don't know is the port. And a connection
attempt to a closed port on localhost fails instantly. So instead of waiting on
mDNS, the app now **sweeps localhost for the adb port directly**: it scans the
port range in a fraction of a second, then does an adb handshake on each open
port — whichever one authenticates is adbd. This doesn't depend on mDNS at all.

- Reconnect order is now: last-known port (instant if unchanged) → localhost
  sweep (reliable, mDNS-free) → mDNS (last resort for unusual setups).
- The same sweep is used right after pairing and by the after-reboot
  auto-reconnect, so those are reliable too.
- Once the sweep finds the new port it's remembered, so the next reconnect is
  instant.

Together with the keep-alive from the last build, the goal is: pair once, keep
Wireless debugging on, and it reconnects itself — no more connect/drop/retry
churn. Native change -> full rebuild.

## v0.84.0+165 — connection stays warm + real file sizes (Jul 2026)

Working toward "the connection just stays up, and it's easy" — plus chipping at
the remaining list, incrementally.

**A keep-alive is back — this time it can't hang.** The socket used to go idle
between actions (Wi-Fi power-save / adbd), so the next scan or play paid a
reconnect. A light ping every 25s now keeps it warm. The earlier keep-alive was
removed in v0.82 because it could freeze everything; this one runs against a
hard 8-second deadline and only ever holds the lock for that short ping — never
for a reconnect — so it physically can't cause the old hang. While you're using
the app the connection stays ready; after a long idle it still re-establishes on
your next tap. (A connection that literally never drops across reboots needs the
bigger Shizuku-style rework noted below.)

**Android/data videos now show their real size.** The scan reads each file's
size (`stat`) and Local shows e.g. "48 MB" instead of "0 B", so they no longer
look broken. If a device's shell doesn't support that form, the scan
automatically falls back to the proven path-only command — it can never come
back empty because of this. (Duration still needs per-file probing, which is too
slow over ADB to do for hundreds of files; left for later.)

**The scan can't time out on a full device.** Reading sizes makes the scan a bit
heavier, so it now gets a longer time budget than ordinary commands — a big
Android/data tree won't trip the 12-second limit that guards normal actions.

Native + Dart change -> full rebuild.

## Still to do (honest, incremental)
- **Faster playback for big files.** The reliable path still copies the file out
  first. True zero-copy instant playback needs a persistent reader running in the
  shell (the Shizuku "user service" architecture) that hands the app a file
  descriptor — a larger, dedicated piece of work, best done once the connection
  and copy are confirmed solid on-device.
- Duration for Android/data videos.

## v0.83.0+164 — daily-use polish: copy feedback + auto-refresh (Jul 2026)

Hardening the everyday experience (not a specific bug report):

- **Tapping an Android/data video shows clear progress.** Before, the player sat
  on a blank frame for the whole copy and looked frozen. It now shows "Loading
  video over ADB… Larger files take a moment." under the spinner, and a plainer
  error if it can't load. So a slow copy reads as progress, not a hang.
- **Local refreshes itself after reconnecting.** When the ADB screen reconnects
  (which it does on its own when opened) and this device has been scanned
  before, it re-scans Android/data in the background so newly-arrived videos
  (new Telegram downloads, etc.) show up in Local without hunting for the Scan
  button. First-time users still scan once manually.

Dart-only on top of v0.82.0's timeout work; rebuild as usual.

## v0.82.0+163 — no more "spinner forever": every ADB op is time-bounded (Jul 2026)

v0.81 introduced a worse bug: connecting/reconnecting would spin forever and
never finish. Root cause: ADB stream reads had no timeout, so a half-dead socket
(TCP still up, but the device's adbd not answering) blocked indefinitely — and
because operations are serialised under one lock, a single stuck call froze the
whole ADB subsystem. The keep-alive added in v0.81 was the trigger: its
background ping could block while holding that lock.

Fixes:
- Every shell round-trip now runs against a hard 12-second deadline. If it
  doesn't answer, the socket is dropped (which unblocks it) and the next action
  reconnects — so the UI can never hang on a dead connection.
- The keep-alive is removed entirely. It was the thing holding the lock in the
  background; instead the connection simply re-establishes on demand the next
  time you scan or play (fast, via the remembered port). Simpler and safer.
- Copying a video for playback no longer takes the shared lock (a long copy
  can't block reconnecting) and has its own stall watchdog: if no data arrives
  for 30 seconds it aborts instead of hanging on "Preparing…". It still only
  keeps a copy verified complete, and retries once.

Net effect: connect, reconnect, scan and play are all bounded — nothing spins
forever, and a dropped connection recovers on the next tap. Native change ->
full rebuild.

## v0.81.0+162 — playback fixed at the source + honest, simple status (Jul 2026)

Testing v0.80.0 showed playback failing with "Failed to recognize file format"
and "Stream closed" still appearing. Both had one root cause and it's now fixed.

**Truncated copies could never play — now the copy is verified whole.** When the
ADB connection dropped mid-copy, the old code saw "some bytes copied" and kept
the *partial* file, which media_kit then rejected as an unrecognised format. The
copy now fetches the file's real size first and only accepts a copy that matches
it byte-for-byte; an incomplete copy is discarded and retried once (reconnecting
in between). A cached copy is re-used only if it's provably complete. The whole
copy runs under the connection lock so nothing else can disturb it mid-transfer.

**The keep-alive can no longer hurt a transfer.** It now pings under the same
lock (so it never runs while a copy or scan holds the connection) and, on
failure, simply skips that cycle instead of tearing the socket down — the next
real action reconnects on its own.

**Status is honest and written for normal users.** The ADB screen shows a plain
green "Connected" / red "Not connected" line, and raw engine messages like
"IOException: Stream closed" are translated to "Not connected. Tap Connect — if
that doesn't work, open Wireless debugging and make sure it's still on." No jargon.
Native + Dart change -> full rebuild.

## v0.80.0+161 — reliable playback + keep-alive (Jul 2026)

Fixes from testing v0.79.1: Local visibility + Hidden badges are confirmed
working; playback and connection stability were not.

**Playback is reliable again — copy, not fragile streaming.** Tapping an
Android/data video now always copies it out over the ADB connection into the
app's own cache and plays that (the proven full-read path, the same idea
Shizuku-based file managers use). The on-demand HTTP-proxy streaming added in
v0.78 was the culprit: per-request byte-range pipes over ADB are fragile, and
when media_kit couldn't play the stream URL there was no fallback, so playback
failed outright. Reliability wins over the (unverifiable-blind) speed
optimisation; the proxy code stays in the tree but is no longer in the playback
path. Errors now say plainly to check the device is still connected.

**Connection no longer goes stale mid-session.** Root cause of the lingering
"Stream closed": Wi-Fi power-save / adbd idle silently drops the TLS socket
while it sits unused between connect, scan, browse and play. Added a keep-alive
that pings ("true") every ~20s once connected, keeping the socket warm; if it
did drop, execRead's existing recovery reconnects on the next real call. The
ping thread stops itself when the connection is gone. Net effect: as long as
Wireless debugging stays on, the session stays usable. Native + Dart change ->
full rebuild.

## v0.79.1+160 — clearer Android/data folder names (Jul 2026)

Small polish on top of v0.79.0: synthesised Android/data|obb folders in the
Local Folders view now show the owning app package instead of a bare "cache" or
"files", so several apps' caches are distinguishable — e.g.
"com.iMe.android · cache" rather than just "cache". Dart-only; if you already
built v0.79.0 the native side is unchanged.

## v0.79.0+159 — reliability + Local visibility fixes (Jul 2026)

Fixes from on-device testing of v0.78.0.

**Connection no longer breaks with "Stream closed".** Root causes: (1)
isConnected() reports a dead socket as alive after a reboot or Wi-Fi change, so
the first openStream throws "Stream closed" — but only runShell recovered;
connect/auto-connect didn't. (2) Auto-reconnect used the saved port with no
mDNS fallback, so a reboot (which changes the port) left it stale. (3) A
screen-open auto-reconnect could race a user-tapped pair/connect on the shared
connection. Fix: a single execRead path that, on any stream failure, drops the
connection and reconnects fresh (saved port -> mDNS) before one retry; a new
reconnectAndRun (saved-first, then mDNS) for the screen-open reconnect; an
op-lock serialising connect/pair/shell (streaming stays unlocked); and the ADB
screen claims "busy" immediately so a fast tap can't race the auto-reconnect.

**Android/data videos now show in Local without "Show hidden".** Scanning them
over ADB is itself the opt-in, so they're decoupled from the toggle: they appear
in the Local Files list, get their own synthesised folders in the Folders view,
and — the missing piece — actually list when you tap that folder (the per-folder
query was MediaStore-only and returned nothing for Android/data). They carry the
amber Hidden badge. A fresh scan now refreshes Local immediately.

**The picker can't brick the app any more.** Flipping a picker category before
its media finished loading could throw during build and leave the whole app
stuck on "Something didn't load", forcing a kill-from-recents. The error screen
now has a "Go back" button that pops the errored route (or resets to Home), and
a force-unwrap in the video-folder list was made null-safe. Native + Dart
change -> full rebuild.

## v0.78.0+158 — hidden badges + instant streaming playback (Jul 2026)

Two things at once.

**Hidden badges.** Videos and folders that live where normal galleries hide
them now carry a small amber "Hidden" mark, so it's always clear when an item
isn't in the usual media locations. "Hidden" = an Android/data cache reached
over ADB (adb:// uri), a dot-file, or a folder on the path whose name starts
with a dot (.thumbnails, .Trash, …). Shown in the Local list and grid (a corner
chip on grid thumbnails, incl. dot-folders) and in the Private-Folder / Transfer
file pickers (list rows, folder rows, and the thumbnail grid). New shared
HiddenBadge / HiddenCornerBadge widgets + a Video.isHidden getter; the picker
computes it from the path.

**Instant streaming playback.** Playing an Android/data video used to copy the
whole file out first (slow for big files). Now the app runs a tiny loopback HTTP
proxy (127.0.0.1, random port) and media_kit plays straight from it — bytes are
streamed on demand off the device over ADB, so playback starts immediately.
Range requests are supported (206 + Content-Range + Accept-Ranges), so seeking
works: a block-aligned dd seek jumps near the offset fast, then tail/head trim
to the exact bytes. Before handing media_kit a stream URL we probe a real 4-byte
range; if that pipeline can't run on a given device, we transparently fall back
to the old full-copy path, so playback still works everywhere. Crash-resume for
these videos remembers the adb:// uri (not the per-session proxy URL) so it
re-resolves cleanly. Native + Dart change -> full rebuild.

## v0.77.0+157 — auto-reconnect after reboot (no PC, no root) (Jul 2026)

The big one for "stop making me reconnect": the app can now re-establish ADB by
itself after a reboot. Technique (same as the libadb-android-based
mouldybread/adb-auto-enable project): once connected, the app grants ITSELF
WRITE_SECURE_SETTINGS by running `pm grant <pkg> ...` over its own ADB shell —
no PC needed. With that permission it can flip Wireless debugging back on via
Settings.Global (adb_wifi_enabled). A BOOT_COMPLETED receiver then, on the next
boot, waits for Wi-Fi, re-enables wireless debugging, waits for adbd, and
reconnects over mDNS — pairing persists, so no re-pairing and no re-typing.

ADB screen gets a "Stay connected after a reboot" card: while connected, tap
"Set up auto-reconnect" once; after that a switch controls whether the app
restores ADB on boot, and the card shows ✓ Set up. If a phone's permission
monitoring blocks the self-grant (some Xiaomi/OnePlus builds), the status
explains the one Developer-options toggle to flip. Manifest adds
WRITE_SECURE_SETTINGS + RECEIVE_BOOT_COMPLETED and the BootReceiver. Native +
manifest change -> full rebuild. (Still queued: hidden badges in Local/pickers,
faster streaming playback.)

## v0.76.0+156 — fix the mDNS-connect regression from 0.75.0 (Jul 2026)

0.75.0's connect "retry" made things worse, not better — this reverts the core
mistake. The retry chopped the mDNS discovery into four ~5s slices, each
starting a FRESH NsdManager discovery. But NsdManager needs an uninterrupted
window: start-up + finding the service + resolving host/port routinely takes
more than 5s, so every slice restarted before the resolve could finish and it
never connected — even though pairing (a separate mDNS service) had just
succeeded on the same network. That's why "it worked before": 0.73.0 gave mDNS
one continuous 20s window.

Fix: mdnsConnect is back to ONE continuous discovery for the whole budget (the
window that reliably connected), with a single fresh-instance fallback only
after the full window genuinely fails. The saved-port reconnect path's mDNS
timeout also went 8s→15s. Once connected by any route the port is saved, so mDNS
is only needed once per Wireless-debugging session; manual IP:Port stays under
Advanced as the always-works fallback. Native change -> full rebuild.

## v0.75.0+155 — fix "can't connect after pairing" + one-button flow (Jul 2026)

Root-caused the "paired OK but Connect fails — couldn't find the device over
mDNS" bug. Pairing and connecting use two DIFFERENT mDNS services
(adb-tls-pairing vs adb-tls-connect), and Android's NsdManager is notoriously
flaky — a second discovery right after the pairing one frequently misses, and
its resolve step (which even binds a probe socket to the resolved port) fails
intermittently. Fix: mDNS connect now retries with a FRESH AdbMdns instance per
attempt (4 tries within the timeout, short gaps so NsdManager releases its
listener and the connect service re-announces), and once connected it saves the
port so future reconnects skip mDNS entirely.

UX: the confusing two-button Pair/Connect pair is now ONE adaptive button.
With a 6-digit code entered it reads "Pair & connect" and does both — pairing,
waiting ~1.5s for the connect service to appear after the dialog closes, then
connecting — so users don't need to know the order. With no code it reads
"Connect". The button is disabled while busy, so double-taps can't stack. Manual
IP:Port stays under Advanced as the always-works fallback (the port is on the
Wireless debugging screen; it's remembered after one use). Native change ->
full rebuild.

## v0.74.0+154 — Android/data videos appear in the Local library (Jul 2026)

The ADB-scanned Android/data videos are no longer trapped in the settings
screen — they now show up in the normal Local library (both Files and Folders
views) whenever "Show hidden files and folders" is on, right alongside the
filesystem-walk and SAF hidden sources that were already surfaced that way. Each
scanned path becomes a Video whose uri is an "adb://<path>" marker; the scan
result is persisted natively so the library shows them without re-scanning every
launch. Playback has a single interception point: PlayerPlayback._doOpenVideo
detects an adb:// uri, copies the file out via ADB to a readable cache (the
streaming exec:cat path from v0.73), then plays the local copy — so these videos
play from anywhere they appear (Local list, folder view, up-next navigation),
and a copy error surfaces as the normal player error with Retry. Merged as a
new source in _hiddenVideos so folders synthesize automatically; nothing in the
default (hidden-off) library changes. Native + Dart change -> full rebuild.
Next: a "hidden" badge to mark these in Local + the Private Folder/Transfer
pickers, faster streaming playback, and a keep-alive service.

## v0.73.0+153 — fix playback ("Failed to open") + rock-solid connect (Jul 2026)

Two real bugs from on-device testing, root-caused and fixed.

1) Playback failed ("Failed to open .../.Innocent_cache/x.webm"). Cause: the file
was copied by the ADB *shell* (uid 2000) into /sdcard, but a file another uid
writes there often isn't readable/visible to the app process (cross-uid + FUSE
view), so media_kit couldn't open it. Fix: the APP now streams the bytes itself
over the ADB connection using "exec:cat" (exec, not shell, so no PTY newline
translation to corrupt binary) and writes them into its OWN external cache dir —
a path this app can always open. Writes to a .part file then renames, verifies a
non-zero byte count, and prunes the cache under 2 GB.

2) Connect was flaky and Android/data listing failed after a while. Cause: an
mDNS connect never saved the port, so once the connection dropped there was
nothing to reconnect with. Fix: connect now discovers host+port via AdbMdns
(TLS-connect service), connects via loopback first (bypasses VPN), and SAVES the
port; every shell op reconnects on a dropped connection using the saved port,
falling back to a fresh mDNS discovery if the saved one is stale (e.g. after a
reboot). Net effect: pair once with the 6-digit code, and connect/scan/play keep
working — reconnecting transparently after the phone sleeps. Native change ->
full rebuild.

## v0.72.1+152 — fix FlutLab build OOM ("daemon disappeared") (Jul 2026)

No app-code change — a build-config fix. The FlutLab build failed with "Gradle
build daemon disappeared unexpectedly": the container (~4 GB) ran out of memory
mid-build, not a compile error. Root cause: the Kotlin compiler forks its own
daemon JVM (~700 MB) that stacks on the Gradle heap (2560 MB); as the Kotlin
source grew (MainActivity + AdbManager), the two heaps together crossed the
container limit and the build was OOM-killed at ~387 s. Fix: run the Kotlin
compiler in-process (kotlin.compiler.execution.strategy=in-process) so there's a
single heap to bound, trim the Gradle heap to 2048 MB for headroom, cap the
fallback Kotlin daemon heap, and disable incremental Kotlin / VFS watch / build
cache (all memory that a one-shot container doesn't benefit from). Rebuild the
same way. This is the same class of fix as the earlier arm64-only ABI change.

## v0.72.0+151 — play Android/data videos + one-tap Wireless debugging (Jul 2026)

The found videos are now playable, and getting into Wireless debugging is one
tap. Full lifecycle: discover (ADB find) -> tap a result -> the file is copied
out of Android/data via ADB to /sdcard/Movies/.Innocent_cache (a spot the app
CAN read thanks to All-files access) -> media_kit plays the local copy. Copy is
on demand (not the whole library), the file copy runs on-device via the shell
(not streamed through the connection), and the cache self-prunes to stay under
2 GB so the phone never fills up. Re-tapping a cached video plays instantly.

Also adds an "Open Wireless debugging" button: if Developer options is on it
jumps straight there (best-effort direct component, else the Developer options
screen); if it's off, a dialog explains the Build number x7 unlock with a
shortcut to About phone. Works across OEMs via public intents with safe
fallbacks. Video results now render as tappable play tiles. Native change ->
full rebuild. Next: surface these same videos in the main library grid + picker.

## v0.71.0+150 — one-code pairing front and centre + scan fixes (Jul 2026)

Two things. First, the ADB screen now leads with the easy path: enter ONLY the
6-digit pairing code and tap Pair — the app discovers the pairing/connect ports
over mDNS, no IP:Port typing. "Connect" auto-discovers too. Manual IP:Port entry
is still there but demoted to a collapsible "Advanced" section for networks that
block mDNS (e.g. a VPN forcing a 169.254.x.x link-local address). Note mDNS
one-code needs the network to allow multicast; with a real LAN IP (VPN off) it
works, which is the common case.

Second, the Android/data scan is more robust and better presented: runShell now
retries once on a stale connection (fixes the "Stream closed" error by dropping
the dead connection and reconnecting via the remembered loopback address), and
found videos render as a proper list (filename + path, movie icon) instead of a
wall of text, with a live progress spinner in the status box. Native change →
full rebuild.

## v0.70.0+149 — M2: list videos inside Android/data via ADB (Jul 2026)

The ADB chain is fully working (uid=2000 shell with ext_data_rw + ext_obb_rw
groups confirmed on device — exactly the access needed for Android/data and
Android/obb). This build starts using it.

Adds a native runShell(command) that runs any command over the existing ADB
connection (reconnecting via the remembered loopback address if the connection
dropped), plus a Dart scanAndroidDataVideos() that runs a find across
/storage/emulated/0/Android/{data,obb} for the usual video extensions and
returns the paths. A "Scan Android/data for videos" button on the ADB screen
demonstrates it end-to-end: tap it once connected and it lists the videos
sitting in app caches (Telegram etc.) that the app itself is not allowed to
read. Next (M2b): feed those paths into the real library; then M3: pull-to-play.
Native change → full rebuild.

## v0.69.0+148 — ADB: it was already connected + auto-reconnect (Jul 2026)

Big realization from reading the libadb source: connect() returns false when a
connection ALREADY EXISTS — so the "connect failed — returned false" seen on
device wasn't a failure at all. The device was paired and connected the whole
time (Settings showed "Currently connected"). connectAndRun now trusts
isConnected() instead of connect()'s return value, so an existing connection is
used and the shell command runs. Same fix applied to the mDNS autoConnect path.

Also makes day-to-day use effortless: the last working host:port is saved and,
on opening the ADB screen, the app pre-fills it and reconnects automatically —
no typing. A banner notes the device was paired before and that pairing is only
needed again after a reboot. Pairing itself (the one-time split-screen dance)
is unavoidable — even LADB requires it, because Android invalidates pairing if
the dialog is dismissed. Native change → full rebuild.

## v0.68.0+147 — ADB: connect over loopback first (Jul 2026)

Fixes the ECONNREFUSED that on-device testing hit on both a link-local
(169.254.x.x) and a normal Wi-Fi (192.168.x.x) network. Root cause: the app was
connecting to the LAN/link-local IP that the Wireless debugging screen shows —
but that address is meant for a *remote* machine. adbd on the same device is
reachable over loopback (this is how apps like LADB work).

`pairDevice` and `connectAndRun` now try 127.0.0.1 first and fall back to the
shown IP, so the user can still paste the on-screen IP:Port and it just works.
Error messages now report each host attempt. Native change → full rebuild.
Pairing still needs the "Pair device with pairing code" dialog kept open with a
fresh code.

## v0.67.1+146 — ADB connect UI: copy IP:Port as-is (Jul 2026)

Reworks the ADB connection screen after on-device testing on a device whose
adbd binds a link-local 169.254.x.x address — which broke both the 127.0.0.1
default and mDNS auto-discovery (mDNS can't see services on the link-local
interface). Manual entry also proved error-prone: it was easy to paste the
"IP:Port" string into the host field or the code into the port field.

Fix: the primary flow now takes the "IP address & Port" string exactly as
Android shows it (e.g. 169.254.1.1:42749) in one field, plus the 6-digit code,
and the app splits host and port itself — no IP/port/code mix-ups, and it works
on link-local addresses too. mDNS is kept as an optional shortcut behind a
toggle. Dart-only; the native pair/connect/mDNS methods are unchanged.

## v0.67.0+145 — M1b-B simpler: mDNS auto-discovery (Jul 2026)

Makes pairing/connecting almost effortless. Instead of hunting for two
different ports and typing an IP, the app now discovers everything over mDNS:

- Pair: type ONLY the 6-digit code (host + pairing port found automatically via
  AdbMdns on the TLS-pairing service). Keep the pairing dialog open.
- Connect: one tap — autoConnect discovers the connect service and the real
  device IP itself (important, since some phones bind adbd to a link-local
  address like 169.254.x.x rather than 127.0.0.1).

The manual host/port fields are kept under a collapsed "Advanced" section as a
fallback for devices where mDNS is unreliable — so the simple path serves most
phones while the fallback covers the rest. Verified libadb's exact API from
source (AdbMdns, autoConnect, isConnected, AdbInputStream) before wiring.
Native change → full rebuild.

## v0.66.0+144 — M1b-B: ADB pairing + connect + shell (Jul 2026)

The first real connection. Adds native `pairDevice` and `connectAndRun` on top
of the ADB engine, wires them through the `mx_clone/adb` channel, and adds an
"ADB connection (experimental)" screen (Settings → List) with fields for host,
pairing port + code, and connect port, plus a live output box.

Flow: turn on Wireless debugging → pair once with the code Android shows →
connect to the debug port → run `id`. A result of `uid=2000(shell)` proves the
embedded-ADB path onto the device works — the foundation for listing and
playing videos inside Android/data. Host defaults to 127.0.0.1 (works on most
phones); editable so devices that only bind the Wi-Fi IP still work. Native
change → full rebuild. Listing/playback via ADB come in M2/M3.

## v0.65.0+143 — M1b-A: hidden-API bypass + Application (Jul 2026)

Groundwork for ADB pairing on modern Android. Android 9+ blocks reflective
access to non-SDK APIs, and libadb-android's TLS handshake (used by ADB
pairing/connect on Android 11+) needs the platform Conscrypt provider that
lives behind those hidden APIs. Without lifting the restriction, pairing would
fail at runtime on any Android 9+ device — i.e. almost every phone in use.

Adds a custom `InnocentApplication` that calls HiddenApiBypass once at startup,
registers it in the manifest, and adds the `hiddenapibypass:4.3` dependency. The
self-test now also reports the exemption status so we can confirm it ran
on-device. Isolated as its own step to de-risk the dependency fetch before the
pairing UI + native pair/connect land in M1b-B. No pairing yet.

## v0.64.2+142 — M1a fix 2: align BouncyCastle to libadb (Jul 2026)

Fixes the v0.64.1 build error (hundreds of "Duplicate class
org.bouncycastle.*"). Root cause: libadb-android already bundles BouncyCastle
(`bcprov-jdk15to18:1.81`) as a transitive dependency, and the `bcprov-jdk18on`
I added was a second copy of the exact same classes — so every class collided.

Fix: drop the duplicate bcprov entirely and add only `bcpkix-jdk15to18:1.81`
(the cert-builder half libadb doesn't include) in the SAME variant + version
libadb uses, so both share one bcprov. No code change — the
`org.bouncycastle.*` import paths are identical across BC variants. Same M1a
scope: key + certificate self-test, no network.

## v0.64.1+141 — M1a fix: BouncyCastle cert generation (Jul 2026)

Fixes the v0.64.0 build error (`Unresolved reference 'sun'`). The
sun-security-android library resolved fine, but Android's compiler blocks
referencing `sun.*` packages from app code, so the README's sun.security cert
generation can't compile here. Swapped it for BouncyCastle
(`bcprov-jdk18on` + `bcpkix-jdk18on`, Maven Central) — which the
libadb-android README lists as the supported alternative and which is
battle-tested on Android. Same M1a scope: build/load the ADB client key +
certificate and self-test, no network yet.

## v0.64.0+140 — Milestone 1a: ADB engine foundation (Jul 2026)

First real code toward non-root Android/data access. Adds the native ADB
client engine on top of libadb-android — but NOT the network part yet, so this
is a foundation probe:

- `AdbManager.kt` — a concrete `AbsAdbConnectionManager` that generates (and
  persists) an RSA key + self-signed X509 certificate. The key is stored in the
  app's private files dir and reused on every launch, which is what makes
  "pair once, reconnect forever" possible later (adbd remembers this exact key).
- `mx_clone/adb` method channel with `init`, and an **"ADB engine self-test
  (experimental)"** tile in Settings → List. Tapping it builds/loads the key +
  cert off the main thread and shows the result.

Why staged: the cert-generation + library wiring is intricate and can't be
tested from here, so this step verifies the foundation compiles and RUNS on the
real device (correct package names, sun-security cert gen, manager
instantiation) BEFORE the pairing/connect/shell code is layered on in M1b. If
the self-test shows "OK — ADB engine ready…", the foundation is solid. If it
shows an ERROR, the message pinpoints exactly what to fix. Native change →
full rebuild.

## v0.63.2+139 — Milestone 0: libadb-android dependency probe (Jul 2026)

Groundwork for reaching Android/data on non-rooted Android 11+ (where SAF is
OS-blocked). This build adds the `libadb-android` library (MuntashirAkon,
Apache-2.0, via JitPack) as a dependency — a pure-Java embedded wireless-ADB
client that needs NO bundled binary and works across devices using the OS's
own wireless-debugging mechanism. NO code uses it yet: this is purely a build
probe. If this release compiles on FlutLab, it proves (a) JitPack is fetchable
there and (b) the library is compatible with our Kotlin 2.1.0 / minSdk 24
setup — the green light to build the real capability cascade (root → Android
≤10 direct → wireless-ADB with pair-once + WRITE_SECURE_SETTINGS auto-enable +
mDNS auto-reconnect → graceful fallback), which lets the app pick the best
Android/data access method per device and self-report its tier. If it fails to
fetch, we pivot (e.g. Shizuku). This is a build-config change → full rebuild.

## v0.63.0+137 — Hidden files in the picker + Android/data via SAF (Jul 2026)

Builds on v0.62.1's "Show hidden files" so the toggle now reaches everywhere,
standard file-manager style. All of this is gated by the toggle — off means
none of it shows.

**File pickers now honour the toggle.** The Files browser inside the Private
Folder "Add files" picker and the File-Transfer picker previously always hid
dot entries; with the toggle on they now show dot files and dot folders too.
The picker's Videos tab now uses the same filtered lists as Local, so hidden
folders/videos appear there as well.

**Android/data via per-folder SAF grant (the standard, OS-blessed route).**
On Android 11+ neither MediaStore nor All-Files-Access can read other apps'
`Android/data` / `Android/obb` — the OS sandboxes them. The only sanctioned way
in is a user-granted folder permission (Storage Access Framework). New in
Settings → List, under the hidden-files toggle: **"Grant access to restricted
folders"** opens the system folder picker seeded at `Android/data`. Once
granted, every video inside the granted tree is folded into Local (flat list,
folder list, and inside each folder) as a playable `content://` item, and a
**"Clear granted folders"** tile revokes it. The grant persists across
restarts. On Android ≤10 this isn't even needed — the filesystem walk now also
descends into `Android/data` and `Android/obb` directly (it already did
`Android/media`), so those users get it automatically.

Honest OS limits: Google blocks *selecting* `Android/data` itself through SAF
on Android 13+, so on the newest devices the seeded pick may come back empty —
the user can still grant any other folder, and the feature degrades cleanly
rather than pretending. SAF-sourced videos show a placeholder thumbnail and no
duration (they're read through a content URI, not a file path); they play
normally.

This is a **native** change (new SAF method channel + `onActivityResult` in
MainActivity), so it needs a full rebuild/reinstall, not just a Dart reload.

## v0.62.1+136 — Real video thumbnails + Show hidden files (Jul 2026)

**Video thumbnails now actually appear (MX-Player style).** Videos inside a
folder were showing a generic film-strip placeholder — you couldn't tell what
each one was. Cause: thumbnails were generated from a raw file path via
MediaMetadataRetriever, which fails for files on SD cards / scoped storage /
content URIs (a large share of real libraries). Thumbnails now come from
Android's MediaStore thumbnail pipeline via the file's asset id, which works
across those storage types on essentially any device, with the old path
decoder kept as a fallback. Cached to disk exactly like before, so a folder
is instant the second time. Folder rows still show a folder icon (no cover
thumbnail) as intended — thumbnails are per-video, inside the folder.

**"Show hidden files and folders" now truly reveals everything.** The toggle
(Settings → bottom of the list) only ever hid/showed dot-prefixed entries that
MediaStore happened to return — it could never surface genuinely hidden files,
because MediaStore doesn't index files in `.nomedia` folders or with a dot
prefix at all. When the toggle is ON, the app now also walks the storage
volumes directly (All-Files-Access) and folds in every video file it finds —
dot files, `.nomedia` folders, `Android/media`, SD cards — into the flat list,
the folder list (hidden folders appear), and inside each folder. It's opt-in:
the walk doesn't run at all while the toggle is off, so normal browsing pays
nothing for it. (`Android/data` and `Android/obb` of other apps stay
inaccessible — Android sandboxes those even with All-Files-Access; that needs
a per-folder SAF grant, a future addition.)

## v0.62.0+135 — Single-instance PiP: close-stops-playback + no double windows (Jul 2026)

Fixes two ways the floating PiP could end up behaving like TWO players instead
of one (MX Player has exactly one).

**Fixed: dismissing the system PiP with × didn't stop the video.** When the
video was floating over other apps and you tapped × on the system PiP window,
libmpv kept the audio thread running in the background and — worse — the
floating window was still there (playing) when you reopened the app. Cause:
Android reports × and "tap to expand" through the SAME callback, and we treated
both as "just left PiP". Now we tell them apart by what the activity does next:
a dismiss stops it (onStop) without resuming, an expand resumes it (onResume).
On a real dismiss the app now fully stops playback and tears the floating
window down, exactly like closing the in-app × does.

**Fixed: opening a new video while one was floating showed both at once.**
Watching video 1 in the floating window and then picking video 2 left the
fullscreen player AND the floating window on screen together (two views of the
same libmpv output). Opening any video in the player now clears the floating
window first, so there's only ever one. (The expand-back-to-player path already
did this; this covers picking a different video.)

Native MainActivity gains onResume/onStop lifecycle handling to detect the PiP
dismiss; PipService gains an onPipClosed callback.

## v0.61.1+134 — PiP full-frame fix + real file sizes (Jul 2026)

Two fixes on top of the over-apps PiP that landed in +133.

**Fixed: system PiP window showed only a cropped corner of the video.** Now
that leaving the app hands off to a system PiP window (v0.61.0), the window was
showing just a clipped piece instead of the whole frame. Cause: the Android 12+
auto-enter fires so fast it can outrun the "expand the floating window to
fullscreen" rebuild — so at capture time the small floating window was still on
screen, and it overflows the tiny PiP surface, leaving only a corner visible.
Fix: the overlay now renders the video fullscreen whenever we're actually in a
system PiP window (driven by onPictureInPictureModeChanged, which fires
reliably on entry), not only when the pre-leave expand had time to render. The
PiP window now shows the complete video.

**Fixed: file sizes showed "0 B" everywhere.** The library scanner was
hard-coding size to 0 (a deferred-for-speed shortcut that was never finished),
so every video read "0 B". Since the scanner already resolves each file's real
path, reading its length is just a cheap stat — so the real size is now read
and shown (e.g. "1.4 GB", "720.5 MB"). Guarded so a rare stat failure hides the
size chip instead of falling back to a misleading "0 B".

## v0.61.0+133 — Floating PiP over other apps: system auto-enter + permission guidance (Jul 2026)

Targeted fix for the persistent "the floating window works inside Innocent but
doesn't continue over other apps when I leave" problem. The whole hand-off
chain (native onUserLeaveHint → PipService → overlay → enterPip → manifest)
was already correct, so this release attacks the two things that can still make
it fail silently at RUNTIME:

**1. System auto-enter PiP (Android 12+) — the reliable path.** Previously we
relied on manually calling enterPictureInPictureMode() from onUserLeaveHint the
instant the user leaves. Android can reject that call if the activity has
already begun pausing, so nothing appears over other apps. We now ARM the
platform's own auto-enter (setAutoEnterEnabled) the moment the floating window
opens, with the real video aspect ratio, and disarm it when it closes. On
Android 12+ the system itself moves the app into a PiP window on leave — it
doesn't depend on our call landing in a razor-thin timing window. To keep the
PiP window showing ONLY the video (not the app behind it), onUserLeaveHint
still expands the little window to fullscreen first, and the manual enterPip
now DEFERS to the system when auto-enter is armed (so it can't snapshot the
small window before the fullscreen frame renders). Android 11 and below keep
the manual enterPip path as before.

**2. Picture-in-picture permission detection + guidance.** "Picture-in-picture"
is a special per-app permission. It's ON by default on stock Android, but some
OEM builds ship it OFF and the user can revoke it — and when it's off, entering
system PiP silently does nothing, which looks exactly like this bug. The app
now checks the permission (via AppOps) the first time per session that you tap
the PiP button, and if it's off, shows a short dialog explaining that over-apps
playback needs the permission, with an "Open Settings" shortcut straight to the
toggle. (Shown at most once per session so it never nags.)

New localized strings (EN/MY/TH) for the permission dialog. Native
MainActivity gains isPipAllowed / openPipSettings / setAutoEnterPip plus an
autoEnter flag on the PiP params.

**If it STILL doesn't work after this build, that narrows it down a lot** — see
the testing notes when you install: whether the permission dialog appears, and
whether the fullscreen player (not the floating window) enters PiP on leave,
together tell us if it's permission, timing, or something device-specific.

## v0.60.1+132 — Nav-bar leak + resume-dialog pause (Jul 2026)

Bug-fix release (Dart-only; native unchanged from +131).

**Fixed: system nav bar stayed hidden after leaving the player.** After
backing out of a video — or popping it into the floating window — the phone's
Recent/Home/Back bar stayed hidden and a reveal-swipe overlapped the app's
bottom tabs, "self-correcting" only later when some app-resume happened to
fire the shell's restore. Root cause: the fullscreen player uses
immersiveSticky; a plain Back is an in-app pop so no resume fires (the shell's
resume-time restore never runs), and the player's own dispose-time edge-to-edge
call is made while Android is still settling the sticky flag and doesn't
reliably stick. Fixed with a single root-navigator observer that restores
edge-to-edge after EVERY pop, deferred to a post-frame callback so it lands at
a stable point after the transition. Nothing is ever pushed above the player as
a route, so this can never fight a screen that wants immersive.

**Fixed: resume dialog now pauses the video.** When the "Resume / Start over"
dialog appears, the video no longer plays (with sound) from 0 behind it — it
opens PAUSED on the first frame and only starts playing once you pick Resume
(or Start over, or after the 12 s auto-default). Root cause: the file was
always opened with autoplay and the ask-dialog was shown without pausing.
Fixed by opening with autoplay:false when an ask-dialog is going to appear
(decided up-front so there's no play-then-pause audio blip), then starting
playback from resumeFromSaved / startOverFromBeginning.

**Also fixed:** the multi-select folder app-bar title showed a raw closure
string instead of "N selected" (a localization method was referenced without
being called). Now shows the correct localized count in English/Burmese/Thai.

**Already correct (verified, no change needed):**
- Floating PiP over other apps — the YouTube-style hand-off to system PiP
  landed in v0.60.0; if it's not working, the device is running a build from
  before v0.60.0 (the +130 build failed the OOM issue fixed in +131). Rebuild
  +132 and it will continue over other apps when you leave the app.
- Back stops the video unless Background Play is on — the exit path already
  keeps playing only when floating PiP is active or Background Play is enabled,
  and hard-stops otherwise.

## v0.60.0+131 — Build fix: arm64-only (Jul 2026)

Same features as +130; fixes the FlutLab release build failing with "the
daemon has disappeared". That was a native-packaging out-of-memory: the APK
was set to bundle two ABIs of libmpv (arm64-v8a + armeabi-v7a, ~80 MB each)
and the combined packaging peak exceeded the ~4 GB build container even with
R8 already disabled. Reverted to arm64-v8a only, which cuts the peak by ~70%
and builds reliably. arm64 covers virtually all phones from ~2019; if a
separate 32-bit APK is ever needed, build it on its own with
`flutter build apk --release --target-platform android-arm` so its packaging
peak doesn't stack on top of arm64.

## v0.60.0+130 — Pop-up over other apps, faster library, player fixes (Jul 2026)

Bundles the picture-in-picture rework, a media-library performance pass, and
three player bug fixes. **Requires a native rebuild** (Android PiP code).

**Pop-up (PiP) — YouTube-style.** The in-app floating window now follows you
OUT of the app: leave Innocent while the little window is up and the video
keeps playing in Android's system PiP over the launcher and other apps, then
shrinks back to the in-app window when you return. Leaving from the fullscreen
player still enters system PiP directly. The PiP window has a working
play/pause control, a smooth morph in/out, and crash-safe aspect handling for
ultra-wide / vertical clips. The on-screen PiP button follows the "Use custom
PiP" setting (in-app window vs system PiP).

**Library performance.** Video-thumbnail and album-art generation are now
bounded by a device-sized concurrency limiter, so fast-scrolling a big folder
no longer fires dozens of native decoders / isolates at once and spikes the
CPU. The cache-first loading that already gives an instant Video/Music tab is
unchanged; this just stops the bursts. The limit scales with CPU cores.

**Player fixes.**
- Fixed a "Playback failed: audio-wait-open" error that could appear with
  background play when the screen turned off (an invalid libmpv option was
  being set; screen-off playback is kept alive by the wake lock regardless).
- The Prev/Play/Next row no longer sits under the system Back/Home/Recent bar
  when it reappears in fullscreen — the controls now reserve the real nav-bar
  height on every device (3-button, 2-button, or gesture).
- The phone's Back button now actually closes the player (it previously only
  showed the "press back again" hint and never exited); it behaves exactly
  like the on-screen back arrow, honouring the double-tap-to-exit setting.

## v0.59.0+129 — Video floats over other apps via System PiP (Jul 2026)

Leaving Innocent while a video is playing now drops it into Android's system
Picture-in-Picture window, so the video keeps playing over the launcher and
other apps — the "watch while you do something else" experience. **Requires a
native rebuild** (Android code changed).

What's included:
- **Leave-app → System PiP.** Pressing Home / switching apps during fullscreen
  playback enters system PiP (previously it tried an in-app overlay, which can
  only draw inside Innocent and so vanished the moment you left). The on-screen
  PiP *button* still follows the "Use custom PiP" setting: ON → the in-app
  floating window (within Innocent); OFF → system PiP over other apps. If a
  device can't do system PiP, it falls back to the in-app window.
- **Play/Pause in the PiP window.** A control in the little window toggles
  playback without expanding, and its icon stays in sync.
- **Smooth transition.** The video morphs from its on-screen position into the
  PiP window (source-rect hint), with seamless resize on Android 12+.
- **Crash-safe aspect handling.** Ultra-wide or vertical videos are clamped to
  Android's legal PiP aspect range so entering PiP can't throw.

Tap the PiP window to expand back to fullscreen; close it to stop.

## v0.58.1+128 — Faster phone-to-phone transfer (Jul 2026)

Tunes the direct Innocent-to-Innocent file transfer for higher throughput.
The sender now streams each file in 512 KB blocks (via a raw random-access
read) instead of the platform's default 64 KB chunks, which cuts the number of
native round-trips and stream events ~8× and lets a fast 5 GHz Wi-Fi link run
much closer to its ceiling. The receiver skips gzip negotiation entirely since
the body is already uncompressed. Combined with the existing Wi-Fi
HIGH-PERF/LOW-LATENCY lock, wake lock, and throttled progress reporting, a good
5 GHz link between two nearby phones can reach the ~20–30 MB/s range; slower
links (2.4 GHz, distance, interference) remain bounded by the radio, not the
app. Range/resume support is unchanged.

## v0.58.0+127 — Pop-up (PiP) now stays inside the app, over your current screen (Jul 2026)

Reworks the pop-up player to behave like MX Player. Tapping the pop-up button
used to hand off to Android's system Picture-in-Picture, which dropped you out
of Innocent and floated the video over the launcher/home screen. Now the video
shrinks into an in-app floating window and you're returned to exactly the
screen you came from — e.g. the Movies folder you were browsing — with the
video floating on top, still inside the app. From there you can move around the
app (switch tabs, open other folders) and the little window follows.

Under the hood the floating overlay was lifted to the top of the widget tree so
it renders above every screen, including the folder and stream screens that are
pushed outside the tab shell (which is why the old overlay used to hide behind
them). Playback is handed to and from the floating window on the same libmpv
instance, so expanding back to fullscreen — or closing with × — is seamless,
and × still fully stops playback (no lingering background audio).

## v0.57.1+126 — Build fix: corrupt character in a localization string (Jul 2026)

Fixes a release-build failure ("The non-ASCII space character U+200B can only
be used in strings and comments", reported against main.dart line 1). The real
cause was two invisible/corrupt characters — a U+FFFD replacement char and a
U+200C zero-width non-joiner — that had crept into the start of the Burmese
"choose folder" title string in the localization table. The Dart compiler
misattributed the location to the entry file; the offending string has been
cleaned and every source file re-scanned to confirm no other invisible
characters remain. No behaviour changes.

## v0.57.0+125 — Convert to Audio, leave-player stops playback, zoom-not-crop (Jul 2026)

**"Convert to Audio" now actually extracts the audio.** The old "Convert to
MP3" menu item only showed a toast. It's renamed to "Convert to Audio" and
extracts the video's audio track (AAC / .m4a) into the public Innocent/Music
folder using a dedicated libmpv instance, with a live progress dialog. The
result is scanned into the media library so it appears in the Music tab. Note:
whether the device's libmpv build supports encoding is detected early — if not,
it reports so cleanly instead of hanging. (No heavy FFmpeg dependency, so the
build stays lean.)

**Leaving the player now fully stops playback unless you opted into
background.** Backing out of a video with background-play OFF previously could
leave audio playing; it now hard-stops the player AND the background service,
so there's no lingering sound. Background-play ON (or floating PiP) still keeps
playing as intended.

**Closing the floating PiP (×) stops everything.** Tapping × on the pop-up
player used to just hide the overlay while audio kept running in the
background. It now fully stops playback and the background service.

**Video zoom modes scale instead of hard-cropping.** "Fit to Screen"/zoom now
uses libmpv panscan to smoothly scale the video to fill the screen while
keeping its aspect ratio — like MX Player — rather than chopping the sides off
the texture. Pinch-to-zoom still adjusts on top. The mode formerly labelled
"Crop" is now "Zoom".

**Fix:** resolved a possible "kDebugMode isn't defined" compile error in the
video player service by importing foundation.dart explicitly.

## v0.56.2+124 — Fix nav bar covering the app's bottom tabs (Jul 2026)

Fixes an intermittent bug where the phone's Recent/Home/Back keys would
disappear and the app would extend to the very bottom of the screen; swiping
the nav bar back then covered the app's bottom tab bar instead of sitting
above it.

Root cause: the fullscreen player uses immersive (sticky) mode and is pushed on
the root navigator, on top of — and outside — the tab shell, so the shell stays
mounted underneath it. Both screens re-assert their system-UI mode when the app
returns to the foreground, so on resume the player's "immersive" and the shell's
"edge-to-edge" raced; sometimes immersive won and leaked onto the main screen,
hiding the nav bar there.

Fix: the shell is now lifecycle-aware and restores edge-to-edge whenever it's
the visible screen, and both the shell and the player only assert their UI mode
when they are actually the current route (guarded by ModalRoute.isCurrent). The
player also ignores a late resume callback once it's being disposed. The result
is that the player stays immersive while it's open, and the main screen always
keeps the system bars visible with the bottom tabs above them.

## v0.56.1+123 — Options menu reorder + rich in-player Information (Jul 2026)

**The video options menu is reordered and opens compactly.** New order:
Favourite, File Transfer, Lock in Private Folder, Properties, Share, Convert
to MP3, Rename, then (below the fold) Add To Playlist, Add to Watch Later,
Add Subtitle from URL, Move to Recycle Bin, Delete. The sheet now opens showing
through "Rename" so it no longer eats the whole screen; drag it up to reveal
the rest. The list clears the phone's navigation bar, so the last row (Delete)
is always tappable and never sits under the Home/Back keys. Adapts to both
portrait and landscape.

**The in-player Information dialog now shows full details.** Tapping the
Information icon in the player's overflow menu previously showed only the title,
duration and raw URI. It now opens the same rich Properties view used in the
library — file name, location, exact size, date, format, resolution, length,
estimated bitrate and playback history — over a translucent scrim so the video
stays faintly visible behind it.

## v0.56.0+122 — Equalizer actually works, reliable background play, fullscreen fix (Jul 2026)

Three root-cause fixes for audio effects, background playback, and the
fullscreen player. **Requires a native rebuild** (Android code changed).

**The equalizer and voice effects now change the sound.** They were attaching
to Android's global output mix (audio session 0), which modern Android no
longer routes app playback through — so moving the sliders or picking a voice
effect did nothing audible. The app now generates a real audio session id,
binds libmpv's AudioTrack output to that id, and attaches the Equalizer /
BassBoost / Virtualizer to the same id — so the effects process the actual
video sound. The saved tuning is also re-applied at the start of every video
(gated by the audio-effects master switch), matching MX Player. Remember to
turn the audio-effects master switch on first.

**Background play no longer stops intermittently when the screen turns off.**
The cause was libmpv reacting to its video surface being destroyed on sleep —
sometimes it kept decoding audio, sometimes it stalled waiting for the surface
(the "works after a few tries" behaviour). When the app goes to the background
with background-play on, libmpv is now told to keep its audio thread
independent of the video surface, so playback continues every time; returning
to the foreground restores normal audio/video sync and shows the frame
instantly.

**Player controls no longer overlap the phone's navigation keys.** After a
screen-off/on cycle the fullscreen player briefly brought the system nav bar
back while the transport controls were still laid out for a full-bleed screen,
so Prev/Play/Next sat on top of the Home/Back keys. The player now uses sticky
immersive mode and re-asserts fullscreen on every resume, so the controls stay
above the nav bar.

## v0.55.2+121 — Emoji/Unicode folder fix, menu scroll, per-folder scroll (Jul 2026)

Three reliability fixes for everyday use.

**Folders with emoji or non-Latin names now open correctly.** Opening a folder
whose name contained an emoji (e.g. "Design 👗") — or Thai, Korean, Burmese,
or a literal "%" — showed a full-screen "Something didn't load" error. The
cause: the folder's absolute path was crammed into a URL path segment, which
meant every "/" was percent-encoded and the value was then decoded twice; that
double-decode threw a FormatException on certain byte sequences and the whole
screen crashed. Folder path and name are now passed as query parameters, which
Dart decodes exactly once and which carry arbitrary UTF-8 safely — so every
folder name, in any language, opens reliably. A defensive fallback screen
replaces any crash if a folder is ever reached without a path.

**The video options menu is now fully scrollable.** The 3-dot menu on a video
has ~12 items; on shorter phones and in landscape the bottom ones — including
Properties, Move to Recycle Bin and Delete — were clipped off the bottom of
the sheet with no way to reach them. The sheet now grows (up to 85% of the
screen) and the item list scrolls, so every option is always reachable.

**Each folder remembers its own scroll position.** The folder detail screen
used a single shared scroll key, so scrolling in one folder could carry that
offset into the next folder you opened. Scroll position is now tracked
per-folder, matching MX Player.

## v0.55.1+120 — Build fix (Jul 2026)

Fixes two compile errors from +119 that broke the release build:
- The Sort/View dialog's new `preferencesProvider` parameter was given a
  provider as a default value inside a `const` constructor, which Dart
  rejects (a provider isn't a constant). Made the parameter nullable and it
  now falls back to the Local tab's store at the point of use.
- The folder multi-select "some files failed" snackbar called the
  `someFilesFailed(n)` message without its count argument. It now passes the
  failed-file count.
Also cleared the analyzer noise these touched: removed an unused import, an
unused local, a stray unused widget class, and added the missing
`context.mounted` guards after the batch dialogs.

## v0.55.1+119 — Private Folder privacy hardening & equalizer fixes (Jul 2026)

A privacy + audio correctness pass. No new UI — these close real leak paths
and make the equalizer behave like MX Player.

**Private Folder view settings are now fully isolated.** The vault previously
shared the Local tab's view/sort preferences, so switching List/Grid (or any
sort/field option) inside the Private Folder also changed the public Local tab,
and vice-versa. The vault now has its own independent preference store (a
separate 'pf' key namespace), and the shared Sort/View dialog was
parameterised so it writes to whichever store opened it. Local and Private
Folder layouts are now completely independent.

**A vault video leaves no trace in the public tab.** When a Private Folder
video played, the player was still writing its resume position, its
"last playing" crash-recovery marker, and a watch-history record to shared
storage — so a vault title could surface in the Local tab's Continue Watching
row or the cold-start "Resume X?" prompt. The player now carries an isPrivate
flag through playback and skips all three writes for vault items. Combined with
the existing history filter, this is defense-in-depth: the trace is never
written, and anything legacy is still filtered out.

**File Transfer can't reach the vault (verified).** The transfer file picker
only scans public volumes (/storage/emulated/0 and SD cards); the vault lives
in internal app storage with a .nomedia guard and its MediaStore row is purged
on import, so vaulted files are unreachable from the sender — confirmed by
audit, no code change needed.

**Equalizer now applies on every video.** Saved EQ tuning previously only took
effect while the equalizer sheet was open; after an app restart, playback
started flat until the panel was reopened. The engine now re-applies the saved
bands, bass boost, virtualizer and reverb at the start of each video (gated by
the audio-effects master switch), matching MX Player. The equalizer was
verified to be genuinely wired to Android's native AudioFx — the effect cards,
band sliders and presets all drive the real audio engine, not just the UI.

## v0.55.0+118 — Folder multi-select & rich video Properties (Jul 2026)

Two MX Player-parity features built from the reference screenshots.

**Folder multi-select (Local tab).** Long-press any folder to enter selection
mode; tap to select as many folders as you like. A contextual app bar appears
with bulk actions: Play all, Lock in Private Folder, Share, Delete, and a
Select-all overflow. Both the list and grid folder views show consistent
selection UI (a leading check in the list, a dimming checkmark overlay in the
grid), and the hardware back button exits selection mode first — matching
MX Player and every premium gallery.

**No-ANR batch operations with progress.** Moving a large batch (many big
videos) into the Private Folder — or deleting one — now runs file-by-file
behind a determinate progress dialog showing "n / total". The loop yields to
the event loop between every file, so the UI keeps repainting and the app
never freezes or ANRs even under a heavy batch. The dialog has its own Cancel
(with a "Cancelling…" state); files already processed stay processed, and
per-file failures are counted rather than aborting the whole run.

**Rich video Properties dialog.** The video 3-dot → Properties dialog was
rebuilt in MX Player's grouped style: a File section (name, full location,
exact size like "829 MB (828,943,837 bytes)", and a "Mon D, YYYY at H:MM AM/PM"
date), a Media section (format, resolution, length, estimated bit rate), and a
Playback history section (Finished / Not finished, and the exact last-watched
position pulled from resume storage). Everything loads asynchronously off the
UI thread from reliable sources — file stat + resume history — so it's
accurate on every device without needing a heavyweight container probe.

## v0.54.0+117 — Transfer polish: resume, live speed, robust paths (Jul 2026)

A professional/premium pass over the transfer + performance work from +116,
adding the pieces a Zapya-class app is expected to have.

**Resume interrupted downloads.** A dropped Wi-Fi link on a large video no
longer forces a restart from zero. Each download now retries up to four times
and, because the sender advertises `accept-ranges: bytes`, resumes from the
exact byte it reached using an HTTP Range request — the partial file is kept
between attempts and appended to (206), or cleanly overwritten if the server
ignores the range (200). Cancelling stops the retry loop; a fresh batch clears
the cancel flag.

**Live transfer speed.** The receive screen now shows a real-time rate
(e.g. "24.7 MB/s") and byte progress ("1.2 GB / 2.6 GB") under each file's
progress bar, plus the speed in the ongoing notification. The rate is
exponentially smoothed so it reads steadily instead of jittering.

**Robust save location.** The public Innocent/ root is now derived from the
device's real primary-storage path (walking up from the app-specific external
dir) rather than assuming /storage/emulated/0, with that well-known path kept
only as a last-resort fallback. The write-probe + app-specific fallback from
+116 still guarantees a transfer never fails outright.

**Code-quality.** Removed a fragile non-null assertion in the parallel video
scan (captured folder path is now a proper final local), and confirmed all
three foreground services (transfer + playback) hold their wake/wifi locks and
release them deterministically.

## v0.54.0+116 — Transfer speed, background transfer, file organization, Local-tab perf, background playback (Jul 2026)

A performance + reliability release focused on Wi-Fi transfer and the Local
tab, plus true background video playback.

**Faster Wi-Fi transfer.** The receiver now streams downloads through a raw
dart:io HttpClient instead of package:http, pumping the socket straight to
disk with the OS doing the buffering (package:http added a stream-copy layer
in between). The sender disables on-the-fly gzip (autoCompress = false) —
media files are already compressed, so gzip just burned CPU on both ends and
capped throughput. Progress callbacks are throttled to every 2 MB / 100 ms so
Riverpod rebuilds never back-pressure the socket. Together these lift
real-world throughput well above the previous ~5 MB/s toward the Wi-Fi link
rate.

**Background transfer that survives sleep.** The native TransferService now
holds a Wi-Fi lock (WIFI_MODE_FULL_LOW_LATENCY) and a partial WakeLock for
the life of a transfer, acquired on start and released on stop / destroy /
task-removal. The foreground service kept the process alive; these locks stop
the Wi-Fi radio dropping to power-save and the CPU suspending when the screen
turns off — which is what previously stalled transfers mid-file.

**Organized received files.** Incoming files now land in a public
Internal Storage/Innocent/ folder, sorted into category subfolders — Videos,
Photos, Music, Documents, Others — by file extension, and are media-scanned so
they appear in Gallery / file managers immediately. If all-files access isn't
available the app falls back to its private Innocent_Received folder so a
transfer never fails outright.

**Local tab no longer hangs on some phones.** The video scan previously
resolved each asset's physical file serially (a slow MediaStore → cache
materialization on some devices / SD cards), which made the Local tab spin for
seconds — or seemingly forever — while Music loaded fine. Folder buckets and
per-file resolution now run in parallel (batches of 16), with an 8-second
per-file and 10-second permission-request timeout so a single stuck file or
permission prompt can never hang the whole tab.

**True background video playback.** With "Background play" on, audio now keeps
playing when the phone sleeps. The foreground PlaybackService gained a partial
WakeLock so libmpv's audio thread keeps decoding with the screen off, released
deterministically when playback stops. The player already avoided pausing on
background when the toggle is on; the missing piece was the CPU wake lock.

## v0.53.0+115 — Fix Kotlin build error in intruder channel (Jul 2026)

Fixed a syntax error in MainActivity.kt that broke the release build: when
the intruder-camera channel handler was inserted, the opening line of the
following music-widget channel (musicWidgetChannel = MethodChannel() was
accidentally dropped, leaving an orphaned argument list. Restored it — all
12 native channels are now well-formed (each MethodChannel assignment
paired with its handler) and the file compiles cleanly.

## v0.53.0+114 — Vault recovery + anti-theft (Jul 2026)

A major security release for the Private Folder, plus a professional polish
pass over the whole feature.

**Forgot-PIN recovery (two independent paths).** A forgotten PIN no longer
strands the vault forever. Users can configure a security question and/or a
one-time recovery key; either one proves ownership and then lets them set a
new PIN. The vault contents are never touched — recovery resets only the
PIN gate. Neither secret is stored in the clear (SHA-256 + per-install
salt, Keystore-backed). The six built-in security questions are fully
localized (EN/MY/TH) and stored by stable ID so a language switch never
breaks an existing question. Architecture leaves room for an email/OTP
method later. Entry points: a "Forgot PIN?" link on the unlock screen
(shown only when recovery exists), a "Recovery options" item in the
overflow menu, and a gentle first-run prompt after the PIN is created.

**Decoy PIN (anti-coercion).** An optional second PIN opens a convincing
but empty vault. Real and decoy unlocks are indistinguishable to a coercer
(same lockout behaviour), decoy mode hides the sensitive settings (Change
PIN / Recovery / Anti-theft), and anything "added" in decoy mode lives only
in memory — it never persists or touches the real hidden data. Changing the
real PIN to match the decoy auto-clears the now-shadowed decoy.

**Intruder selfie (anti-theft).** After 3 wrong PIN attempts the app can
silently capture a front-camera photo (native Camera2, no preview or
shutter sound) and log the attempt with a timestamp. The break-in log —
viewable in the new Anti-theft screen with tappable photo thumbnails — is
recorded even when the photo fails, so the owner always sees that someone
tried. Photos are stored in app-private storage, never the gallery. Capture
is off by default and gated on a camera-permission prompt.

**Premium polish.** Haptic feedback on unlock success/failure, recovery
verification, and toggles; animated step transitions in the recovery flow;
intra-flow back navigation; floating success toasts; and a shared service
provider so all vault surfaces resolve cleanly. Also folded in the earlier
audit fixes (Keystore-encrypted metadata, sampled content-hash vault
integrity, memoised sizes, concurrency guards, missing-file guard, and
import-failure feedback).

## v0.52.7+113 — Found the REAL double-bottom-bar cause (Jul 2026)

The router was already correct — Private Folder is a top-level route pinned
to the root navigator. The bar persisted because there was a SECOND way in
that bypassed the route entirely: the Local screen's "Privacy" quick-access
chip opened the vault with Navigator.push(MaterialPageRoute(...)), which
lands on the shell's navigator and leaves the tab bar underneath. Users
reaching the vault from that chip (not the Me tab) always saw two bars.

Fix: the Privacy chip now uses context.push(Routes.privateFolder) like the
Me tab, so BOTH entry points go through the root-pinned route and the shell
bar is always hidden. Swept the whole codebase — this was the only
remaining leaky Navigator.push to Private Folder; no others exist. Privacy
lock-on-background (re-lock on paused/inactive) verified intact.

## v0.52.6+112 — Category tabs span folders + folder-delete choice (Jul 2026)

- **Category tabs now reach inside folders.** At the vault root, the All
  tab keeps the organiser view (folder tiles + unfiled entries), but a
  specific category (Video/Image/Audio/File) now shows EVERY matching file
  regardless of which folder it sits in — so a video moved into a folder
  finally appears under the Video tab, mirroring how Local's category
  filter works. Same for Image/Audio/File.
- **Folder delete now asks what to do with the contents.** Deleting a
  folder that holds files opens a choice dialog: "Keep files, delete
  folder" (files move back to the main vault, still locked) or "Delete
  folder and files" (everything inside is permanently erased, via the new
  deleteFolderWithContents() + a single MediaStore rescan). An empty folder
  still deletes with a simple confirm.
- Re-verified the double-bottom-bar fix structurally: all three
  full-screen routes (Private Folder, Player, Folder detail) are pinned to
  the root navigator, so the shell tab bar can never render inside them.

## v0.52.5+111 — Definitively fix the intermittent double bottom bar (Jul 2026)

The two-stacked-bottom-bars glitch came back intermittently because the
router had no explicit navigator keys. GoRouter's context.push then chose
the navigator by context, and sometimes placed a full-screen route on the
shell's own navigator — leaving the tab bar (Local/Music/Transfer/Me)
visible under the vault's category bar.

Fixed at the source: the router now declares an explicit root navigator key
and shell navigator key, and every full-screen route (Private Folder,
Player, Folder detail) sets parentNavigatorKey: rootNavigatorKey. That
forces those screens onto the root navigator ABOVE the shell every single
time, regardless of which tab the push originated from — so the shell's
bottom bar is always hidden and the vault shows only its own category bar.
Deterministic now, not context-dependent.

## v0.52.4+110 — Private Folder audit: perf, races, robustness (Jul 2026)

Bug + code-quality audit of the whole Private Folder feature:

- **Fixed synchronous-I/O jank.** _entrySize() did a synchronous disk stat
  (existsSync + lengthSync) and was called from the storage indicator in
  build() and from the size-sort — so a large vault re-statted every file
  on every rebuild. Sizes are now memoised (vaultPath → bytes) and the
  cache is cleared on reload. build() no longer touches the disk.
- **Added a concurrency guard.** Batch move/unlock/delete are now gated by
  a _busy flag wrapped in try/finally, so tapping two actions quickly can't
  interleave file moves and reload a half-updated list — and the guard can
  never get stuck, even on error or unmount.
- **Made batch ops atomic + fast.** Batch move/delete used to call the
  single-item service method in a loop — N full load+save cycles for N
  items. New moveEntries() and deleteVaultedBatch() do one read-modify-
  write, and the delete batch fires a single MediaStore rescan.
- **Localised the last hardcoded tooltips** (View mode / Sort & view / Add
  files) across EN/MY/TH.
- Verified clean: no swallowed exceptions, all controllers/focus nodes
  disposed, every BuildContext use across an async gap is mounted-guarded.

## v0.52.3+109 — Fix picker Images empty + Files showing folders-only (Jul 2026)

Two picker bugs traced to Android storage-permission granularity:

**Images "Nothing here".** The app requests only READ_MEDIA_VIDEO at
startup (it's a video player). On Android 13+ that grant is per-type, so a
later blanket RequestType.common check reported hasAccess=true (video was
granted) while the image query returned nothing. The picker now requests
the SPECIFIC media type of the open tab — opening Images prompts for
READ_MEDIA_IMAGES, Audio prompts for READ_MEDIA_AUDIO — and the permission
probe / grant panel are type-aware too.

**Files showing folder names + a few videos only.** On Android 11+, raw
dart:io directory listing returns sub-folders but NOT regular files without
All-files access (MANAGE_EXTERNAL_STORAGE); the handful of visible "files"
were videos surfaced via MediaStore. The Files browser previously rendered
this half-empty list while the permission check was still pending. It now
waits for the check: spinner while unknown, the Grant-access panel when
denied, the full browser only once All-files access is confirmed.

## v0.52.2+108 — Fix double bottom bar in Private Folder (Jul 2026)

The shell's bottom nav bar (Local/Music/Transfer/Me) was still showing
underneath the vault's category bar — two stacked bars. The earlier
rootNavigator push didn't work because this app routes through GoRouter's
ShellRoute, where a Navigator.push lands inside the shell. Fixed properly:
Private Folder is now a top-level GoRoute OUTSIDE the ShellRoute (exactly
like the player and folder-detail screens), reached via
context.push(Routes.privateFolder). Full-screen routes outside the shell
don't render the bottom nav bar, so the vault's All·Video·Image·Audio·File
category bar is the only bottom bar.

## v0.52.1+107 — Picker caching + entry rename + storage indicator (Jul 2026)

- **Instant picker (Images / Audio / Files / Apps).** The picker's data
  sources moved from local StatefulWidget fields to app-lifetime
  FutureProviders (picker_providers.dart), exactly how Local and Music
  cache. The first open resolves once; every reopen after that is instant
  until the app is killed. The slow PackageManager app scan especially now
  runs a single time. Lists invalidate after a permission grant so newly-
  accessible media shows up.
- **Rename a vaulted file.** Entry ⋮ → Rename retitles the vault entry
  (label only — the file on disk is untouched). Added renameEntry() to the
  service and videoTitle to PrivateEntry.copyWith.
- **Storage indicator.** When the vault has files, the app-bar title shows
  a subtitle with the total size occupied (e.g. "1.4 GB in vault").

## v0.52.0+106 — Private Folder: multi-select + god-file refactor (Jul 2026)

Two of the three audit items closed (the third, withOpacity→withValues, is
deliberately deferred — see below):

**Multi-select (batch operations).** Long-press any vault item to enter
selection mode: tap to add/remove, a selection app bar shows the count with
Select-all · Move · Unlock · Delete actions, and the category bar hides so
the batch bar has focus. Move and Delete reuse the existing folder chooser
and confirm dialog; every batch op reloads and reports how many files were
affected. The back button now exits selection first, then closes an open
folder, then leaves the screen (proper PopScope priority). Grid cells get a
dimming overlay + check badge; list rows get a radio/check leading.

**God-file refactor.** private_folder_screen.dart was 1903 lines with 8
classes. The three PIN surfaces (Setup / Unlock / Change-PIN field) and the
in-vault image viewer — ~650 lines — moved into
private_folder_pin_widgets.dart as a Dart `part` file. Library-private
classes stay private and call sites are unchanged; the main file is now
1590 lines focused on the file-manager. (part/part-of chosen over separate
public classes so nothing had to be renamed — safest for the copy-paste
workflow.)

**Deferred: withOpacity.** The build runs on Flutter 3.32 where withOpacity
is deprecated but fully functional. Converting all 65 call sites project-
wide would break builds on the pubspec's declared floor (>=3.22) for only a
lint win, so it stays as documented tech-debt until the Flutter floor is
raised.

## v0.51.8+105 — Private Folder audit: permanent delete + quality pass (Jul 2026)

Completeness + code-quality audit of the Private Folder feature:
- **Added "Delete permanently"** to the entry menu — the service already
  had deleteVaulted() but the UI never exposed it, so users could only
  Unlock (restore), never erase. Gated behind a confirm dialog (no undo).
- **Zeroed the last silent catch** in the picker media source (size fetch
  now debug-logs on failure) — the whole feature is now free of
  swallowed exceptions.
- Verified: PIN is Keystore-backed (FlutterSecureStorage +
  encryptedSharedPreferences), SHA-256 with a per-install random salt,
  legacy-hash migration, and failure-count lockout. Vault import is
  copy → byte-length-verify → delete, aborting safely (original kept) on a
  bad copy, and flagging entries whose original couldn't be deleted.

## v0.51.7+104 — Private Folder reuses Local's sort system verbatim (Jul 2026)

Per request, the vault now shares Local's ACTUAL sort/view machinery
instead of a reduced copy — true 1:1 parity, zero duplication:
- The dashboard icon opens Local's own `SortViewDialog` (all 10 sort
  fields — Title · Date · Played time · Status · Length · Size ·
  Resolution · Path · Frame rate · Type — plus the Fields and Advanced
  expandable sections and the View-Mode / Layout chips), driven by the
  same `libraryPreferencesProvider` Local uses, so settings persist and
  stay in lockstep between the two screens.
- The view-mode toolbar button is now Local's exact cycle
  (allFolders → files → folders) with Local's `_viewModeIcon` glyphs.
- The vault list honours the shared sortBy / direction / viewMode /
  layout. Vault entries only carry title/date/size, so the video-only
  fields fall back to title order — every field is still selectable for
  parity, they simply have no data to act on for mixed content.

## v0.51.6+103 — Private Folder top bar: full Local-parity audit (Jul 2026)

Detailed audit of every top-bar action against Local, and closed the last
behavioural gap:
- **Icon 1 is now a view-mode toggle** matching Local's cycle button — it
  flips the vault between a Folders view (organiser folders shown, glyph
  Icons.folder_outlined) and a Files view (flat entry list, glyph
  Icons.description_outlined), exactly the glyphs Local's _viewModeIcon
  uses. Layout (list ↔ grid) now lives solely in the sort dialog, as in
  Local, instead of being duplicated on this button.
- **Icon 2 (search)**, **Icon 3 (dashboard → sort dialog: field ·
  direction · layout)** and **Icon 4 (overflow)** were already
  Local-faithful — verified. The sort dialog intentionally offers Name /
  Date / Size (the fields that are meaningful across mixed vault content:
  video, image, audio, APK) rather than Local's video-only extras like
  resolution / frame-rate.

## v0.51.5+102 — Video tab shows a Resume FAB (Jul 2026)

The vault's FAB now depends on the active category, mirroring Local:
- **Video** category → a Resume FAB (▶) that resumes the last-watched
  vault video. Privacy-safe: it reads only vault entries and their saved
  resume positions — never the public history — picking the newest video
  with a mid-way position (falling back to the newest video, or a "nothing
  to resume yet" hint if there are none).
- **All · Image · Audio · File** categories → the Private-Folder-only "+"
  FAB that opens the picker (adds into the current folder).

## v0.51.4+101 — Hide shell nav bar inside Private Folder (Jul 2026)

Root cause of the mismatched look: Me → Private Folder was pushed on the
shell's nested navigator, so the persistent bottom tab bar (Local · Music ·
Transfer · Me) stayed visible *underneath* the vault's own category bar —
two stacked bottom bars, cramped and wrong. The push now uses the root
navigator (`Navigator.of(context, rootNavigator: true)`), so Private Folder
covers the whole screen and its All · Video · Image · Audio · File category
bar is the only bottom bar — matching the intended design. The top toolbar
already mirrors Local's AppBar attributes 1:1 (transparent bg, 17sp/w700
title, folder · search · dashboard · overflow actions).

## v0.51.3+100 — Fix Private Folder toolbar first icon (Jul 2026)

Side-by-side screenshot comparison showed the first toolbar action was
rendering a 4-square grid glyph in list view, whereas Local shows a plain
folder outline. The icon now reflects the current view mode the way Local
does — folder_outlined in list view, grid_view in grid view — so the
toolbar reads folder · search · dashboard · overflow, matching Local
icon-for-icon.

## v0.51.2+99 — Private Folder toolbar + nav bar: Local parity (Jul 2026)

The Private Folder chrome now mirrors the Local screen 1:1 (per the
reference screenshot):
- **Top toolbar** = title + four actions in Local's order and glyphs:
  view-mode toggle (folder ↔ grid), search, sort-and-view (dashboard-grid
  icon opening the shared PickerSortDialog), and a ⋮ overflow with New
  folder · Refresh · Lock · Change PIN (each with a leading icon, like
  Local's Refresh/Settings/Help/About menu). Title reads "Private Folder"
  while locked, "Folders" once unlocked, or the folder name inside one.
- **Bottom bar** = a full BottomNavigationBar sized exactly like the shell
  nav bar (28px icons, 13/12sp labels, specNavBar bg) showing the vault
  categories All · Video · Image · Audio · File.
- The + FAB (Private-Folder-only, distinct from Local's Resume FAB) floats
  above the bottom bar and adds into the current folder.

## v0.51.1+98 — Private Folder privacy hardening + nav-style category bar (Jul 2026)

Security audit + fixes:
- **Private videos never play in the background.** A vault video opens with
  isPrivate:true; the player then suppresses background-play, system PiP
  AND floating PiP, and hard-pauses the instant the app loses the
  foreground (any lifecycle state that isn't `resumed`). So a
  locked/backgrounded private video is immediately silent and hidden —
  even the Home button or app-switch stops it.
- **MediaStore purge (metadata leak).** After a file is moved into the
  vault and the original deleted, a native MediaScannerConnection rescan
  (new `mx_clone/media_scan` channel) drops the now-dangling MediaStore
  row, so the video's name/thumbnail vanishes from Gallery, Google Photos
  and other players at once instead of lingering until the next boot.
  Restoring a file rescans it back in.
- **Local's Resume FAB** already can't surface a vaulted video — the lock
  flow clears history + resume position — verified during the audit.
- **Category filter is now a bottom nav-style bar** (All · Video · Image ·
  File …) matching the shell nav bar, with the Private-Folder-only + FAB
  (unrelated to Local's Resume FAB) and the Local-style top toolbar.

## v0.51.0+97 — Private Folder is now a full file manager (Jul 2026)

- **Organiser folders inside the vault.** Create folders (⋮ → New folder or
  the empty-state button), open them, rename and delete them (delete moves
  their contents back to the root — never deletes files). Membership is
  pure metadata on each entry, so moving between folders is instant.
- **Category tabs** (All · Video · Image · Audio · File) filter the current
  view; **search** filters by name; **view toggle** switches list/grid with
  real image/video thumbnails; **Sort** reuses the same dialog language as
  Local (Name / Date / Size × Asc / Desc), all functional.
- **Lock-from-Local is gated.** Video ⋮ → Lock in Private Folder first asks
  for fingerprint/face (when enrolled), then a folder chooser (existing
  folder · Main folder · create new) before moving the file in.
- **Add anything from inside a folder.** The + FAB opens the 5-category
  picker; files added while inside a folder inherit that folder.
- **Unlock restores to the original location** (verified in
  restoreFromVault): a file unlocked from the vault returns to the exact
  directory it came from, untouched.
- Entry ⋮ menu: Move to folder · Share · Unlock. Long-press works in grid.

## v0.50.5+96 — Fix empty Images + Files-only-folders (Jul 2026)

Two separate picker bugs traced and fixed:

**Images/Audio still empty:** the custom `FilterOptionGroup` (OrderOption +
needTitle:false) I added for speed made some OEM MediaStores return zero
buckets. Removed it — now the picker queries exactly like the working
Videos tab (bare getAssetPathList, sort in Dart). Added a fallback that
re-queries `RequestType.common` and filters by asset type for devices that
return nothing for a narrow type query, plus debug logging so any
remaining case is visible in logcat.

**Files shows folders but no files:** on Android 11+ raw dart:io File
listing is blocked without "All files access" — folders enumerate for
navigation but File entries are hidden. The Files tab now detects this and
shows a "Grant access" panel that opens the All-files-access settings
screen; statSync calls are guarded so blocked files can't crash the list.

## v0.50.4+95 — Picker Sort & Layout controls (Jul 2026)

Brought the Local tab's Sort/View affordance to the Transfer + Private
Folder picker, scoped to a mixed-content picker:
- A sort icon in the app bar opens a compact centered dialog (same dark
  card + accent chips as Local) offering Sort by Name / Date / Size with a
  dynamic direction row (A→Z ⇄ Z→A, Oldest ⇄ Newest, Smallest ⇄ Largest),
  plus a List / Grid layout toggle on thumbnail-bearing views.
- Sort applies across Videos, Images, Audio and the Files browser (folders
  stay grouped at the top, files honour the chosen key + direction). Media
  sizes are now fetched so Size sort and the size chip work; Date uses the
  MediaStore createDate.
- New 3-up thumbnail Grid mode for Images and Videos with a selection
  check badge; Apps (no meaningful order) hide the control.

## v0.50.3+94 — Fix empty Images/Audio picker (Android 13+ permissions)

The picker showed "Nothing here" for Images and Audio because Android 13
(API 33) split storage access into granular READ_MEDIA_IMAGES / _VIDEO /
_AUDIO permissions, and photo_manager's default request only covered a
subset — since Innocent is a video player, the image/audio grant was never
requested, so those MediaStore queries returned empty.

- The picker now requests `RequestType.common` (image + video + audio) as
  one grant, with the *same* request option on every query (photo_manager
  requires consistency), so the user is prompted once and all three
  categories populate.
- Added `READ_MEDIA_VISUAL_USER_SELECTED` for Android 14's partial
  "Select photos" access.
- When access is genuinely missing, the Images/Audio tab now shows a
  "Grant access" panel (→ retries the prompt, then falls back to the
  system settings page) instead of a dead "Nothing here".

## v0.50.2+93 — Instant picker + no more mid-scan freeze (Jul 2026)

Root cause of the slow picker AND the "tap Me → blank screen" bug was the
same: the Images/Audio categories walked the whole filesystem with a
`dart:io` recursion inside `compute()`. On a library of thousands of files
that took many seconds, and spawning the isolate + its listSync IO briefly
froze the platform thread, so a tab switch mid-scan rendered nothing.

- Images/Audio/Videos now enumerate via `photo_manager` (the OS MediaStore
  index the Videos tab already uses) — folder lists return in
  milliseconds regardless of library size. `compute()` is gone from the
  picker entirely, so the UI thread never stalls.
- Folder covers resolve lazily (list paints first, thumbnails fill in).
- A monotonic load-token makes every async loader cancel-safe: a scan that
  finishes after you've navigated away silently drops its result instead
  of calling setState on a dead screen.
- MediaStore calls are wrapped so a permission revoke mid-scan yields an
  empty list (→ "Nothing here") rather than an error.

## v0.50.1+92 — Private Folder PIN surfaces: professional redesign (Jul 2026)

Root cause of the "toy" look: every _PinField hardcoded `autofocus: true`,
so two widgets fought for focus — one rendered a floated micro-label with a
lone centred cursor, the other a giant in-place label. All three PIN
surfaces (Setup · Unlock · Change-PIN dialog) now share one professional
field: 50dp dense, 10dp radius, centred hint, digits-only, 6-max, obscured
with an eye toggle (an invisible prefix keeps the dots optically centred),
accent focus ring. Panels: 380dp column, 56dp lock badge, 19/13sp
hierarchy, compact biometric row, 48dp flat button that live-enables only
when both PINs reach 4 digits, Enter-key chaining (next → submit),
keyboard-safe scrolling, inline error rows. Every remaining hardcoded PIN
string (errors, lockout countdown, biometric prompts) localized EN/MY/TH.

## v0.50.0+91 — Zapya-class Transfer & universal Private Folder (Jul 2026)

- **Picker rebuilt (Transfer + Private Folder):** Videos · Images · Audio ·
  Files · Apps categories. Images/Audio scan runs in a background isolate;
  Files is a real any-depth directory browser over every mounted volume
  (internal + SD); Apps lists installed user apps via a new
  `mx_clone/apps` MethodChannel and shares their APKs, Zapya-style.
  Selection persists across categories.
- **Bug fixed:** Video ⋮ → File Transfer now actually registers the tapped
  file with the share server (it used to open an empty Transfer page).
- **Every-phone compatibility:** `usesCleartextTraffic` added (the in-app
  LAN receiver was silently blocked on Android 9+); Wi-Fi IP detection now
  prefers wlan/ap interfaces so the QR carries a reachable address on
  multi-interface phones; `QUERY_ALL_PACKAGES` for the Apps tab.
- **Speed/robustness:** a wakelock is held for the life of a share so OEM
  Doze can't park the Wi-Fi radio mid-download.
- **Private Folder:** vault now accepts ANY file type; entries route by
  kind — video/audio → player, images → new in-app pinch-zoom viewer,
  other files → Share / Unlock sheet.

## v0.49.3+90 — Brand mark redrawn 1:1 from final artwork (Jul 2026)

Forensically measured from Innocent.png (3464²): mark 971×1880, red
#F00000, body #383838, white hairline ≈0.0053·H, drop shadow #434343 @α.73
(σ 0.006·H, offset 0.008/0.011·H), 45°-in-pixels split with a 0.032·H air
gap, wedge tip at (0.222, 0.376). `InnocentLogo` now paints TWO pieces
(red + dark) with the gap and shadow; wordmark restyled to the artwork's
#F5E9E9 fill + #D50000 contour (no glow). Launcher regenerated from the
same constants: vector foreground, Android-13 monochrome (gap bridged),
and all ten legacy PNGs. About + Onboarding pick the new mark up
automatically.

## v0.49.2+89 — Audio Effect / Equalizer sheet: MX Player visual parity (Jul 2026)

Pixel-measured against MX Player reference screenshots (density 3.0):
- Effect cards 92×57dp (were ~103×100dp), 16dp gaps, 24dp margins; selected
  card = #20356A→#233D78 gradient with #4388CB frame; grid pinned to the
  top in portrait, centred in landscape.
- Band panel 164dp tall with a visible #35455F 1.2dp steel frame; sliders
  restyled to MX's #66BAFF thumb (ø16) over a #335777 upper track; band
  labels now "60 Hz … 14000 Hz".
- Bass Boost / Virtualizer dials shrunk to MX's ~101dp with a radial
  #3871C2→#184588 body, arc end-ticks, and a #66BAFF handle dot.
- Sheet itself is shorter (60% portrait) and goes opaque sooner; landscape
  panel narrowed to ~48% to hug the right edge like MX.

## v0.49.1+88 — Build fixes (Jul 2026)

- `kDebugMode` needs a direct `foundation.dart` import (material's export
  list doesn't include it) — added to 12 files.
- `video_option_menu` helper methods use `sheetContext`, not `context`
  (12 sites); `_PreparePane._emptyHint` now receives a BuildContext.
- `savedToPath(st.saveDir!)` — null-guard already present, promotion isn't.
- Removed duplicate `tooltip:` on the music-player More button.

## v0.49.0+87 — Full compatibility + localization pass (Jul 2026)

- **Real launcher icon**: adaptive icon (API 26+) with vector foreground
  reproducing the InnocentLogo, Android 13 themed-icon (monochrome) layer,
  and legacy PNGs for API 24-25. Replaces the generic system icon.
- **Notch / cutout support**: `values-v27` + `values-night-v27` styles set
  `windowLayoutInDisplayCutoutMode=shortEdges` so fullscreen video fills
  punch-hole and notch displays edge-to-edge (MX behaviour).
- **Full UI localization**: ~250 previously hardcoded strings across all
  features (settings, dialogs, snackbars, empty states, player sheets,
  transfer, private folder, music) now flow through `AppStrings`
  (EN / MY / TH — 387 keys per language). `.arb` files kept in sync.
- **Kids Lock (new, MX parity)**: player More-menu → Kids Lock. Absorbs
  every touch and blocks the system back button; unlock by holding the
  on-screen chip for 2 s (progress ring).
- **Error visibility**: all 68 silent `catch (_) {}` blocks now log via
  `debugPrint` in debug builds (behaviour unchanged in release).
- **Fixes**: About screen showed stale version (0.47.5) — `AppVersion`
  now matches pubspec. Added missing tooltips on icon-only buttons.

Known follow-ups: settings tile titles/subtitles (~120 strings) and icon
tooltips are still English; `withOpacity` deliberately kept (works on all
Flutter versions; `withValues` would require ≥3.27).

# Innocent

A personal Flutter media player. **Inspired by MX Player V3** — built as a
learning project to understand modern Android media playback architecture.
Not affiliated with MX Tech Inc. or J2 Interactive. **Personal use only**,
not distributed via Play Store.

## What's in the box

Flutter app + libmpv backend via `media_kit`. Targets Android 7+ (API 24+).

- Hardware-accelerated video playback (H.264/H.265/AV1 via libmpv)
- 117 user-tunable settings (subtitle styling, audio behaviour, gestures,
  decoder strategy, scan rules, equalizer, etc.)
- Library browser with folder grouping, recently-added detection, and
  filtering
- Music tab (artist / album / playlist views with background playback +
  foreground-service notification)
- User data: history, favourites, watch-later, playlists, recycle bin,
  private folder
- **Original feature**: Watch Insights — per-user analytics dashboard
  (total watch time, streak, top folder, completion rates) computed
  locally from history. No equivalent in the inspiration source.
- **Original feature**: Privacy Mode — pauses all history / resume
  recording while the toggle is on. Existing data untouched.
- Crash recovery: if the app dies mid-playback, the next cold start
  offers a one-shot "Resume X?" snackbar.

## Architecture (high level)

State management: **Riverpod 2.x** (`StateNotifier` for mutable feature
state, `Provider`/`FutureProvider` for service singletons and async reads).

Navigation: **go_router** for declarative routes.

Storage: **SharedPreferences** for all settings + per-URI resume positions
+ schema-version migration ladder.

Native: small Kotlin `MainActivity` (audio focus, media keys,
becomingNoisy broadcast) + `PlaybackService` (foreground service for
background audio).

Layout (`lib/`):

- `main.dart`, `app.dart` — entry, theme, router
- `core/di/` — Riverpod top-level providers
- `core/router/` — GoRouter routes
- `core/theme/` — AppColors + dark palette
- `core/services/` — cross-feature services (preferences, video_player,
  playback, audio_focus, hardware_keys, permission, connectivity,
  thumbnail, haptic, insights, resume, user_data, ...)
- `core/ui/` — shared widgets (`SafeThumbnail`, etc.)
- `core/utils/` — `AsyncValue` extensions, etc.
- `features/` — feature folders: local_browser, player, music, user_data,
  settings, private_folder, network_stream, transfer, cloud, me, about,
  onboarding

## What this project is NOT

- **Not a clone you should ship.** Many internal comments still cite
  "MX Player V3's <feature>" as the spec source for individual
  behaviours. These attributions are intentional — accurate
  documentation of what was learned where.
- **Not Play Store-ready.** Uses `MANAGE_EXTERNAL_STORAGE` (allowed
  under Play policy only with special review). No custom icon yet.
  No splash. No privacy policy URL.
- **Not localized.** Hardcoded English strings. Settings has a
  language picker but `flutter_localizations` is not wired yet.

## Running

```
flutter pub get
flutter run
```

Targets Android. Desktop / iOS builds are not maintained.

## Running tests

```
flutter test
```

Tests cover settings persistence, aspect-ratio enum integrity,
export/import round-trip, Watch Insights analytics math, and a few more.
Coverage is sparse — extend as needed.

## Version

Current: **0.46.0+63**. See `lib/core/app_version.dart`.

## License

This is a personal learning project. No license granted for redistribution.
