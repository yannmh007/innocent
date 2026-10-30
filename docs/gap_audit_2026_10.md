# Gap audit — 22 October 2026

The owner asked for what is still missing or weak, measured against current
practice and against what the next years are likely to bring — attacks that
lean on AI included — with everything that costs nothing done first. This is
what was checked, what was fixed, and what is left, with the reason.

## How it was checked

| tool | open source / free | what it looked at |
|---|---|---|
| Supabase advisors (security, performance) | free | the production database; re-run after 047: the search_path warning is gone, the rest are the ones left on purpose below |
| [zizmor](https://docs.zizmor.sh) 1.31.1 | open source | every GitHub Actions workflow |
| `tool/apk_page_check.py` (new) | ours | every arm64 library in the 1.64.69 APK |
| [OSV-Scanner](https://github.com/google/osv-scanner) 2.2.2 | open source (Google) | `pubspec.lock`, in CI (the database is not reachable from the dev container) |
| `tool/check.py`, `tool/security_invariants.py` | ours | the whole tree, before every push |
| [actionlint](https://github.com/rhysd/actionlint) 1.7.12 | open source | every workflow (expressions, job outputs, permissions); clean |
| research | — | Android platform changes, payment fraud, SMS fraud, device attestation |

## Fixed (no cost)

| finding | severity | fix |
|---|---|---|
| 24 GitHub Actions pinned only by moving tags (`@v2`), in workflows that hold the APK signing key and the R2/Supabase secrets. Tags can be moved: in March 2025 the `tj-actions/changed-files` tags were moved to a commit that dumped secrets into public logs (CVE-2025-30066). | high | every action pinned to its commit SHA, the tag kept as a comment |
| `playback-check` pasted a dispatch input straight into a shell script | high | passed through the environment, and checked to look like a title id |
| `device-lab` gave write access to the whole workflow | high | read by default; write only for the job that commits results |
| 8 checkouts left the GitHub token on the runner's disk for every later step | medium | `persist-credentials: false` wherever nothing is pushed (2 jobs push results and keep it) |
| Two native libraries in 1.64.69 linked for 4 KB memory pages: ML Kit's `libbarhopper_v3.so` and CameraX's `libimage_processing_util_jni.so` (the QR scanner). Android 15+ phones may run with 16 KB pages; there these do not load and the scanner crashes. | high (future) | ML Kit barcode-scanning 17.3.0, CameraX 1.4.2; `tool/apk_page_check.py` now fails any build that ships such a library. Verified in CI build 39812275343: 17 arm64 libraries, 0 that a 16 KB-page phone cannot load. In the device lab the scanner opened the camera and kept it running (run 39899577028, `flows/qr_scanner.yaml`), and on a phone with no camera says so instead of crashing (run 39897703492, `flows/qr_no_camera.yaml`) |
| RLS policies evaluated `auth.uid()` once per row (4) | performance | `(select auth.uid())` — migration 047 |
| 9 foreign keys without an index | performance | indexed — migration 047 |
| 30 Oct, standards pass (Semgrep 1.183 with 842 rules, zizmor 1.31, OSV-Scanner 2.2, the OWASP MASVS checklist): the device lab and Test Lab kept the push token in `.git/config` for the whole job while third-party code ran (the lab piped Maestro's installer into bash). A push to main is a production deploy. | high | the lab's run job is read-only; a separate `keep` job, running only git, commits; Test Lab sets the token for its committing step alone. Maestro from its release, pinned by SHA-256 (2.12.0). Runs 41075543874 and 41075543751 committed their results this way |
| The dependency scan read only `pubspec.lock`: the Android libraries were never scanned. Its first look: 186 libraries, 32 advisories in 6, two critical in BouncyCastle 1.81 | critical | BouncyCastle 1.86, Guava 33.7.2, Jackson 2.13.5 (newest for Android 7); the rest, which need minSdk 26, listed with reasons in `tool/osv-scanner-android.toml` until 31 Jan 2027 |
| Vault lockout after wrong PINs ran on the wall clock: moving the date forward ended it (OWASP MASTG local auth) | medium | counted on the time since boot; a reboot restarts the wait. 12 tests, 5 fail on the old code (app 1.64.79) |
| Console upload put the page's ETags into the S3 XML unchecked (admin only) | low | hex with an optional `-N`, part numbers 1-10000, or refused (studio v45) |
| A lab run dispatched from main would have committed its results to main | low | refused: results stay in the artifact or Test Lab's bucket |
| `offsite_max_bytes()` had a mutable `search_path` | low | fixed — migration 047 |
| A payment's transaction number could be reused by another account unnoticed; only a byte-identical screenshot was caught. An AI-made or re-edited receipt has a new hash. | medium | `premium-request` flags a reused transaction number like a reused screenshot (owner told in red, console marks it); the console says, beside Approve, to find the payment in the KPay/Wave app first |
| The console — the page that can delete the catalogue and name admins — had no Content-Security-Policy, and any other site could show it inside an invisible frame and line an admin's tap up with Approve or Delete (clickjacking). It renders no database text as HTML today; nothing stopped a future slip from becoming an admin takeover. | medium | the page's script moved to `app.js` and a policy allows only this site's own script files (no inline script, no handler attributes, no eval, no other host); the page starts hidden and `top.js` shows it only as the top window. `console_smoke.mjs` proves both: an injected script and an `onclick` do not run, a framed console stays hidden, and every scenario runs with zero refusals |
| No standing check for published vulnerabilities in dependencies | medium | `.github/workflows/deps-scan.yml`: OSV-Scanner weekly and on every dependency change, binary checksum-verified. It resolves first, with the Build workflow's Flutter, and scans that: the committed `pubspec.lock` had fallen so far behind that it did not list google_sign_in. First run: 157 packages, no known vulnerability |
| The SHA-256 in `app_releases` proves a download is the published file, not who built it: anyone able to write the table or a mirror could publish another APK with a matching hash | medium | every APK a release uploads gets a GitHub artifact attestation (SLSA provenance, signed through Sigstore, public log), in a separate job that holds no signing key and checks nothing out. Check any copy, from any mirror: `gh attestation verify innocent-X-Y.apk -R yannmh007/innocent`. **From 1.64.71:** 1.64.70's job got nothing to sign — GitHub drops a job output holding a secret's value, and the key alias is the word in every APK's name — so only digests and the version cross between the jobs now |

**Caught before it shipped, twice.**

* The 16 KB fix itself broke something. CameraX 1.3 finished starting on a
  phone where it found no usable camera; 1.4 fails, and mobile_scanner
  5.2.3 rethrew that on the main thread: opening the QR scanner crashed the
  whole app. The device lab found it (run 39894951775, an emulator with no
  camera); a phone with its camera disabled by a policy, or broken, would
  have done the same. Fixed with upstream's own patch from 7.4.2 in a copy
  of 5.2.3 (`third_party/mobile_scanner`), and the screen now says, in
  three languages, to go back and type the address. Proved: lab run
  39897703492 — no crash, the message, Back to Receive.
* 1.64.70's first draft let a *rate-limited*
  play fall back to the bytes already on the phone. The project's own
  invariant (`tool/security_invariants.py`) refuses that: held bytes are
  for "the server could not be asked", never for "the server said no".
  Fixed.

## Released

**1.64.78, 30 October 2026** — main `46e45a7` (build 41051432695, signed
and attested), `app_releases` moved at 12:43 UTC. It carries 1.64.77,
which was built on main (`8f30786`) and never published: the real phones
found the start slower, and the fix is the first item here.

* The start rung's head only (64 KB) is read when the ladder is
  registered, where 1.64.77 read its first 512 KB: that prime had the first
  fragment served through the cache path and cost the start more than it
  saved. The length check rides the ladder's own connection pool, and the
  rungs are registered at once rather than one after another. Device lab:
  grant to playlist 2.0-2.5 s, against 3.0-4.3 s (runs 40909578972 and
  40914094670, 16 of 16 each).
* From 1.64.77: the sealed stream cache's cipher calls on a background task
  queue and its writes gathered — 128 KB ahead of the player, 64 KB or a
  tenth of a second while a request waits — instead of one platform-channel
  call per TLS record on the thread that draws the app
  (`test_bench/proxy_cpu_bench.dart`, a sealed 58.6 MB film: 3,800-4,100
  cipher calls and 114-126 ms/MB before, 1,520-1,620 and 102-106 ms/MB
  after); a skip into a read-ahead gone quiet no longer waits twenty
  seconds (22 s frozen to 0.9 s in the device lab's busy 4G line); a jump
  ends the other rungs' read-aheads (a swipe back had waited 4.9 s on a
  3.4 Mbit/s line); the start rung's playlist out as soon as its index is
  in; the title page's album controls at the row's end, its count
  readable; dropdowns in the theme's font.
* Transfer asks before sending, by default (it used to let any phone on the
  network pair), and remembers the choice. A browser upload that the phone
  has no room for is refused before it starts (507, "not sent: the phone
  has no room for it") and stopped if it grows past what it declared; one
  pairing question at a time per sender, and three refusals make it wait a
  minute, doubling. "Declined" and "wait" are said in the sender's
  language.
* The app reads its own payment requests' masks (`09••••••351`), not the
  numbers, which the server now seals (below).
* Strings: Burmese and Thai fixes across Settings, Help and the private
  folder (ကိုယ်ရေးဖိုင်တွဲ).
* Two stream cache races, there since the warm-up (1.64.67), found when the
  full suite ran under load on the release tree: Play pressed while the
  title's warm-up was still registering let the warm-up take Play's film
  for its own and release it (an empty first read); and Play and the
  warm-up making a new film's cache entry at once could write `seal.iv`
  twice — an entry with no IV, its runs plain, or a run sealed under an IV
  not the one on disk. Both pinned by tests that fail without the fix.
* Not in this build: the Google sign-in nonce (29b71b2). It changes the
  sign-in no lab can perform, and ships once the owner has signed in with
  it on a real phone.

Proved: Flutter tests 1199 of 1199 on the branch; the stream cache (97),
Transfer (14) and sign-in suites on the release tree itself; device lab 16
of 16 (runs 40909578972, 40914094670, 41047246610); Test Lab realme C53 16
of 16 and OPPO A79 5G 15 of 16 (run 41047246611). The OPPO's one miss was
the 10 Mbit/s Original on a line that measured 4-14 Mbit/s during it, a
path this release does not touch. An earlier run, 41042377434, met lines
five to twenty times slower than every run it is compared with (the realme
at 0.4 Mbit/s) and failed 5 and 4 checks, every one a wait for bytes; it is
not counted either way.

**Server, 30 October 2026** — live before the app, pinned to `ed6ee97`.
Against a copy of the data leaving with someone else (a leaked R2, B2 or
service key, a dump):

* Payments (migrations 053, 054; premium-request v15-v16): a payer's KPay
  number and transaction id are sealed (AES-256-GCM, bound to the row and
  column), the transaction id indexed by HMAC so a reused number is still
  caught, and masked for the payer. Filing goes only through the function
  (053 took the table's insert from anon and authenticated). The first
  sealed request was checked in the database: no plain number anywhere.
* Payment screenshots (migration 056): stored sealed, under a key derived
  for receipts alone, with the request as associated data; the console's
  inbox has them opened by the function, a few megabytes per answer.
* The daily database backup (migration 055; ingest v38-v39): sealed before
  it is written, in R2 and off-site; the sixteen made before were sealed
  where they lay, and checked: 16 of 16 sealed, 16 of 16 copied off-site.
  The console's Download opens it; `tool/restore_backup.py --key` opens an
  off-site copy with the owner's PII_ENC_KEY if the project itself is lost.
* R2 keys say nothing of what they hold: a console upload goes to
  `f/<20 hex>/<kind>/<32 hex>.<ext>` (HMAC of the folder, random file
  name), its label kept in the database; a file forwarded to the bot keeps
  the folder the operator typed but loses its Telegram file name.
* studio's unused `requests` op removed.
* Telegram ingest, up to ten files at once (migration 057, ingest v40, the
  workflow with this release): the plan job opens lanes 1..(waiting +
  busy), at most INGEST_LANES; each lane its own runner and Telegram
  session, one job at a time across runs; sign-ins 20 s apart; an album's
  places taken under a lock per title (two lanes finishing two files of
  one title had collided on title_assets' unique index). Checked on the
  branch: plan, house and one lane, green (run 41050415899).

**Server, 29 October 2026** — no app release. `request-playback` v34
(pinned `4b5a7a7`): the subscription, the devices and the ladder are asked
together, so a premium Play is three round trips in a row, not six (a free
one three, not five), and the token key is imported once per instance.
Migration 052: `landing_rows()` and `_for_you` read `title_heat`,
refreshed at most every ten minutes under an advisory lock, instead of
scanning the event log on every app open; their output was byte-identical
before and after for the four busiest viewers.

**1.64.76, 29 October 2026** — main `217da3b` (build 40540289076, signed
and attested), `app_releases` moved at 07:12 UTC; then the Worker's
`LIMIT_MODE = "enforce"`, main `b608885`, deployed by Workers Builds. The
app now waits out a 429 — the Worker's per-install ceiling, or the zone's
per-address rule — for what `Retry-After` asks (1–15 s, 10 s when it says
nothing) and asks again, in the stream proxy and the downloader, instead
of failing the part. Proved: Flutter tests 1180 of 1180, with 429 cases in
the proxy (lanes, seek, HLS segment) and the downloader; device lab
40499194182 16 of 16; Test Lab realme C53 16 of 16 (run 40516412135) and
OPPO A79 5G 15 of 16 (run 40536305131: the first seek waited 4.3 s for
the storage's first answer on a US phone; nothing answered 429). The A38
sat in Test Lab's queue for two hours, twice, and never ran. After the
release: transport check 40833941479 (the new APK on the domain, its size
and SHA-256 as the row states), playback check 40835208892 (`/health`:
bind=enforce limit=enforce; the right install plays, any other is
refused). The ceiling stays at 600 in 10 s while older apps are in the
field.

**Public files on cdn.innocentplayer.com, 27 October 2026** — no app
release. The owner connected the public bucket's custom domain (minimum
TLS 1.2); ingest, studio and backfill-dimensions name it (pinned to
`f30e874`); migration 051 moved `public_asset_base()`, the four open
films' stored posters and the release row in one transaction (and put
back its empty `search_path`). The transport check found the domain
serving the same bytes as r2.dev, the APK's SHA-256 as the row states,
writes refused and no listing (40503136593); the owner's phone drew the
posters from it; then the owner turned r2.dev off, and the check now
requires it off (40506716837: 401).

**innocentplayer.com, 27 October 2026** — main `724a879` and `b4b0481`;
no app change. The domain was bought on Cloudflare Registrar and its zone
set up by the owner: minimum TLS 1.2, Always Use HTTPS, CT monitoring,
Bot Fight Mode off (on the Free plan it cannot be skipped and challenges
app traffic). The Worker now answers at `stream.innocentplayer.com` and
nowhere else (workers.dev off). The owner moved `STREAM_BASE` and added
two WAF custom rules (only `/v/` and `/health`; only GET, HEAD, OPTIONS)
and a rate-limiting rule (400 per 10 s per IP on `/v/`). Proved on the
domain: transport check 40479831081, playback check 40479834765, device
lab 40479838296 (15 of 16; the one miss was a swipe still rebuffering on a
2 Mbps line, with 48 upstream requests, every bind ok and nothing
refused); after workers.dev went off, playback check 40488608698. Next:
photos, posters and the APK on `cdn.innocentplayer.com`, then r2.dev off.

**Worker, 26 October 2026** — main `05b8fbb`, deployed by Workers Builds
at 19:41 UTC; no app change. The owner asked whether the film path can be
intercepted, read or traced to its storage (docs/security_streaming.md
§7, §8). The new Transport check found the Worker answering plain HTTP and
requests over TLS 1.0/1.1 (run 40381932657), and R2's ETag (the film's
MD5) on every answer. Now refused / removed; run 40389401589 on the live
Worker: every check passed, including the packet capture (no token, path
or header in it) and expiry. Device lab run 40382851831 put the real app
behind a man in the middle: it refused the proxy's certificate on the path
and with the proxy's CA in the user store, and the proxy read nothing of
Innocent's. The four anti-scraper measures another assistant suggested
were weighed in §8 (none adds protection here on this plan).

**1.64.75 (388), 25 October 2026** — main `78b6642`, release
`v1.64.75-388`, both APKs on the CDN and with a GitHub mirror, attested.
`app_releases` was updated on 26 October at 03:01 UTC with every field,
and both pairs were hashed again here from the release's own files:
96,167,981 bytes `62da6059…`, and arm32 88,130,317 bytes `8ebe103b…`.
Migration 050 would have refused the 1.64.74 mistake. What changed:
- the Original plays on ExoPlayer as a progressive MP4 through the local
  proxy, with libmpv as the fallback, so a change to or from it no longer
  swaps engines (5-6 s on the real phones);
- a film that stalls is still playing, so a quality change during a stall
  no longer reopens it paused;
- choosing a quality waits up to 8 s for a reconnect or climb already
  under way instead of refusing, and steers the ladder directly when the
  renewer is not there. This fixes "Could not switch quality" on Tears of
  Steel;
- player messages are a dark pill near the top, never over the seek bar
  or the buttons, and the app's SnackBars are dark and floating;
- the quality chip says what Auto is showing ("Auto · 480p").

The Worker went out with it. `BIND_MODE = "enforce"` was deployed by
Workers Builds at 18:23 UTC. Three days of logs had shown 3,744 `ok` and
2 `missing`, both from a Windows browser on one admin account and none
from the app. Playback check run 40221423041 (Sintel) then proved it live:
`/health` says `bind=enforce`, and the right install and an unbound token
play (206). No header and another install's header get the bare 404 with
`no-store`, before a byte is read.

Checked before it shipped:
- device lab runs 40184478393 (Tears of Steel, 15 of 15), 40186513057
  (a 4G line, 17 of 17) and 40192338478 (16 of 17: the Original on a line
  slower than its bitrate);
- Test Lab run 40194697661: the OPPO 16 of 16, the realme 15 of 16 (the
  same Original on a 7.5 Mbps line). `bind ok` on every fetch, no crash.

**1.64.74 (387), 25 October 2026** — main `ec18e35`, release
`v1.64.74-387`, both APKs on the CDN and with a GitHub mirror, attested,
`app_releases` updated. What changed:
- `request-playback` runs beside the database (ap-southeast-1, the
  `x-region` header), wherever the phone is; a gateway's 5xx is asked
  once more, unpinned;
- a far jump draws the seek bar's picture of where it lands until its own
  frame is drawn;
- the seek bar's pictures are fetched one at a time, the newest next.

Checked before it shipped:
- device lab, run 40133079214: eleven of eleven, including Home and back;
- real phones: the OPPO A38 in Test Lab run 40134791827 and the realme
  C53 in run 40171631821, ten of ten each (the day's quota split them);
- `bind ok` on every fetch, no crash.

| On the real phones | realme | OPPO |
|---|---|---|
| Play tap to grant (phones in the US) | 1.2 s (1.64.73: 3.6 s) | 1.1 s (3.3 s) |
| First long seek, picture still | 0.4 s (0.6 s) | 0.6 s (1.1 s) |
| Landing picture held, to the first frame | 1.0 s | 0.6 s |
| Pictures fetched on the swipe | 3 (7 queued) | 2 (7 queued) |
| First frame | 148 ms | 184 ms |

Published with a mistake, found by the owner's phone: the row took the new
version, links and notes, but `apk_sha256`/`apk_bytes` (and the arm32
pair and its mirror) still described 1.64.73's file. The update said
"Download was damaged. Try again." on every network. Corrected at 09:5x
UTC from the release's own files, both hashed again here: 96,165,373
bytes `8aaacc1a…`, arm32 88,125,957 bytes `f0023f11…`. Migration 050, run by the owner and
checked in place (a BEFORE UPDATE trigger on both pairs), makes the
database refuse a new `version_code` without a new fingerprint.

**1.64.73 (386), 24 October 2026** — main `cd2d9cd`, release
`v1.64.73-386`, both APKs on the CDN and with a GitHub mirror, attested,
`app_releases` updated. What changed:
- seek-bar pictures on the ladder, and the same picture above the time
  during a swipe (`PreviewFrames.kt`, decoded from memory);
- far jumps land on the nearest keyframe;
- a ladder's rungs share one pool of connections;
- the volume boost works on ExoPlayer;
- ten retries for a segment, so a short drop-out is waited for.

Checked before it shipped:
- device lab, run 40116409244: nine of nine, including Home and back
  (+51 frames in 3 s);
- real phones, Test Lab run 40118247783: the realme C53 and the OPPO A38
  each passed eight of eight. Home and back is not run there: a game loop
  cannot press Home.

| On the real phones | realme | OPPO |
|---|---|---|
| First long seek, picture still | 0.6 s | 1.1 s (1.64.72: 3.0 s) |
| Quality change, picture still | 0.2 s | 0.2 s |
| First seek-bar picture | 0.6 s | 0.46 s |
| The same picture again | 0 ms | 0 ms |
| First frame | 119 ms | 434 ms |

Not good enough: during a fast swipe the pictures queued behind each other,
the last one 1.3-1.5 s after it was asked for.

**1.64.72 (385), 24 October 2026** — main `df540b6`, release
`v1.64.72-385`, both APKs on the CDN and with a GitHub mirror, attested,
`app_releases` updated. Catalogue films with a ladder now play on Media3
ExoPlayer as HLS from the stream proxy, so a change of quality no longer
reopens the film (docs/streaming_pro_plan.md). Also in it: migration 049,
run by the owner and checked rolled back in production. A payment still
pending when its account is deleted now leaves the queue as "account
deleted", and approving one whose account is gone says so. On real phones
before it shipped (Test Lab run 40094466469), the realme C53 and the OPPO
A38 each passed five of five:
- the picture stood still 0.2 s on a change of quality (1.64.71: 4.2-7.1 s);
- first frame 163 and 352 ms;
- `bind ok` 24 and 21;
- 0.75 and 0.81 Worker requests a MB (2.5 and 11 before).
Not better: the OPPO's first long seek, 3.0 s against 1.8 s.

**1.64.71 (384), 24 October 2026** — main `5746e1e`, release
`v1.64.71-384`, both APKs on the CDN and with a GitHub mirror, `app_releases`
updated. Delete my account (migration 048 run by the owner, `delete_my_data`
run dry in production — an unknown account touched nothing, an admin was
refused — and the `delete-account` edge function deployed with JWT
verification), the account code on paid films, and the sealed stream cache.
The first release with artifact attestations: one SLSA provenance statement
covers both APKs, `gh attestation verify innocent-1.64.71-384.apk -R
yannmh007/innocent`. On real phones before it shipped: Test Lab run
39972176423, the realme C53 and the OPPO A38 five of five each, both caches
sealed by the phone's own Keystore, `bind ok` 124 and 190.

**1.64.70 (383), 23 October 2026** — main `7c7e78a`, release
`v1.64.70-383`, `app_releases` updated. On real phones in Firebase Test
Lab: the OPPO A38 five of five checks, `bind ok 150` (run 39919163442); the
realme C53 five of five, `bind ok 186` (run 39922911645). The realme's first
run failed three checks on a line of its own that ran at 1.6-4 Mbit/s and
then nearly stopped — no throughput for 66 s — while the OPPO beside it ran
at 5-38; the rerun, at 8-39 Mbit/s, passed. (The device lab cannot stand in
for that: its emulator's network speed setting does not reach Wi-Fi, and
Sintel does not decode there.)

## Looked at and found sound

* Every edge function that skips Supabase's own JWT check makes its own:
  the console's functions ask `admin_resolve` for a role, the runners send a
  shared secret, `ingest` checks Telegram's, `request-playback` derives the
  caller and fails closed, and `seed-open-film` is retired (410).
* Backups: the vault, the secure store, the ADB key, the device id, the
  stream cache and downloads never go to Google Drive or a new phone
  (`backup_rules.xml`, `data_extraction_rules.xml`).
* Network: Innocent's own hosts are HTTPS-only; only the system's
  certificate authorities are trusted, never one a user installed.
* No accounts were created in the last 30 days that a bot could have made
  in bulk (none at all).
* 30 Oct: the console writes database text only as text (`textContent`,
  no `innerHTML` anywhere; the 109 Semgrep "jQuery" hits are DOM `append`);
  sessions are in the Keystore and out of backups (`SessionStore`); the
  vault's key wrapping is AES-GCM with a Keystore IV and a 128-bit tag; the
  Android manifest exports only the launcher, media session, widget and
  boot receivers; cleartext is allowed only off Innocent's own hosts (the
  local network features). Analyzer: no errors or warnings, 272 notes
  (106 `withOpacity` deprecations, 87 fire-and-forget futures, all looked
  at: haptics, UI callbacks, the break-in photo by design).

## Looked at and left, on purpose

* `title_media` runs with its owner's rights (advisor: ERROR). That *is* the
  access control: anon may not read `title_assets` (every object key in the
  private bucket), and the view hands out a photo's address only when the
  viewer may open it (013b, 041).
* Ten `SECURITY DEFINER` functions callable without signing in: the public
  API (catalogue, search, events). Each derives the caller itself.
* Leaked-password protection: a Pro-plan feature, and the app signs in with
  Google (no passwords).

## Needs the owner

1. **Android developer verification — decide before 2027.** Since 30 Sep 2026
   in Brazil, Indonesia, Singapore and **Thailand**, and everywhere in 2027,
   an app from an unverified developer still installs, but only through the
   "advanced flow": a restart and a one-time 24-hour wait. Every new viewer
   would meet that before the first film. A verified developer account is
   reported at **US$25**; free "limited distribution" accounts cover only 20
   devices. By the owner's rule (buy when the benefit clearly exceeds the
   cost), this is a buy, early in 2027. Note: verification is with a
   government ID, and how much of the name Android shows on install should be
   checked then.
2. **The signing key.** An APK signed with any other key can never update an
   installed Innocent. Two offline copies of the keystore and its passwords,
   in two places, are the whole defence; this audit cannot see them.
3. **GitHub settings (free):** turn on Dependabot alerts, secret-scanning
   push protection and **private vulnerability reporting** (Settings → Code
   security). The last is what the new `SECURITY.md` points finders at; it
   is off today, and this session's GitHub access may not change settings.
   AI-assisted scanners find bugs in public code faster every year; a
   private channel decides whether the first you hear of one is a report or
   an exploit.
4. **A passkey on every console admin's Google account (free).** The console
   signs in with Google, then asks for a six-digit code (026). A code can be
   relayed: an AI-written copy of the console on a look-alike address asks
   for it and passes it on within the same thirty seconds. A passkey cannot
   be relayed — it only answers the real Google. Google Account → Security
   → Passkeys; for the owner, also Google's free Advanced Protection.
   Supabase's own passkeys are still experimental and bind to the console's
   domain, so they wait for the domain (Phase 2).
5. **No other GitHub Pages site on this account.** Every Pages site of an
   account is served from the same origin (`yannmh007.github.io`), and a
   page on that origin can read the console's sign-in from storage. Today
   only this repository is visible to the audit. Keep it that way, or give
   the console its own address when the domain comes (Phase 2), which ends
   the question.
6. **Cloudflare connector:** authorising it lets the Worker's logs and
   request counts be read directly — needed to confirm `bind: ok` from the
   field before `BIND_MODE = "enforce"`.
7. **minSdk 24 → 26 (Android 8)?** The downloader engine's Jackson and
   Commons Compress can only reach their fixed versions on Android 8+;
   fourteen Jackson and seven Commons Compress advisories are accepted
   until 31 Jan 2027 (`tool/osv-scanner-android.toml`, with why). Raising
   minSdk drops Android 7 phones and empties that file. Owner's call.
8. **ffmpeg from BtbN's floating `latest` build** (transcode.yml, and the
   device lab's film flows). The transcode job runs it holding
   TRANSCODE_SECRET, which reaches the masters; that build is replaced every
   day, so nothing says today's is yesterday's. Next step (one CI run): log
   the dated autobuild tag and its SHA-256, pin both, and keep apt (signed
   Ubuntu packages, about thirteen minutes slower) as the fallback when the
   pinned build is gone or does not match.

## Next app release (after 1.64.71)

Shipped in 1.64.71 and kept below for the record: Delete my account, the
account code on paid films, the sealed stream cache.


* **Delete my account**, in the app: Play policy for any app with accounts,
  and Thailand's PDPA (the app ships Thai) gives a right to erasure. BUILT,
  ships with the next release: Me → Account → Delete my account
  (`delete_account_screen.dart`), the `delete-account` edge function and
  `delete_my_data()` (migration 048). The sign-in, devices, bookmarks,
  Premium, consents and problem reports are deleted; payment records and
  watch history are kept with nothing left that names the person (the
  receipt's screenshot, phone number and message go). It needs a sign-in
  from the last ten minutes — a Google account chooses itself again on the
  spot — so an unlocked phone or a copied session is not enough; an admin's
  account is refused. Server rules: `delete_account_test.mjs`; the app's
  side: `test/delete_account_test.dart`. In production the foreign key and
  check of 048 are applied; the function waits for the owner's approval, and
  the edge function is deployed with the release.
* **A faint moving account code on premium video** (8 hex digits of the same
  hash the Worker logs as `u`), so a recording made where FLAG_SECURE is
  bypassed can be traced. Through the four premium player routes and
  picture-in-picture. BUILT, ships with the next release: `AccountMark`
  over the picture in the full player (every premium route sets
  `secureScreen`, which also covers the phone's own picture-in-picture) and
  in the floating window; on the picture, never on the bars or off a zoomed
  screen; a new place every 20 s; no tap, no TalkBack. Finding the account
  behind a code: `docs/security.md` §9. Guarded by security_invariants rule
  14 and `test/account_mark_test.dart`.
* **Sealed premium stream cache** with the downloads' Keystore cipher.
  BUILT, ships with the next release, for every film and not only premium
  (one path, and the cost is a fraction of a millisecond a piece): a new
  film's cache gets its own IV (`seal.iv`, on disk before any run), its runs
  are `s<offset>.bin` ciphered at their own place in the film, and every
  read goes through `CacheEntry.read`, which unseals. What was cached plain
  before still plays and stays plain until it ages out (the stream cache
  screen in Settings → General clears it at once). A sealed run whose IV is lost is deleted,
  never served; a cipher that fails stops the caching, never the film.
  Proof: every stream-cache server test runs again with the cipher on
  (`test/stream_cache_sealed_test.dart`, 40 checks), security_invariants
  rule 15 stops any other reader opening a run's file, and the lab trail
  says `stream cache: a new film, sealed` and `stream from the phone … sealed`.
  ON REAL PHONES (Test Lab run 39972176423, 2026-10-23, realme C53 and
  OPPO): both said `a new film, sealed` with the phone's own Keystore
  cipher, both played sealed runs back from the phone after the jump back
  (1.2-1.9 MB at a time), and both passed all five checks — seek, quality
  change, +30 s, swipe back two minutes, back to Auto — with every Worker
  fetch `bind ok` (124 and 190); no crash, no cipher failure in either
  logcat.
* **Toolchain release, on its own:** Flutter 3.47 with the Gradle, AGP and
  Kotlin it needs, no feature changes in the same release, through the
  same 1,070 tests, the device lab and Test Lab on both real phones before
  it ships. Kept apart so that anything it breaks is the toolchain's.
* **Actions on Node 24.** checkout, setup-java and setup-android at their
  pinned commits target Node 20, which GitHub now runs on Node 24 by force
  and will drop. Move each to a release built for Node 24, pinned by SHA
  the same way, with the toolchain release.
* **Phone codes stay off** in Supabase until they are needed — the owner
  action already in `docs/security.md` §5, which also stops SMS pumping (bots
  requesting codes to premium-rate numbers, billed to the sender). Today no
  account uses a phone. Before they are ever turned on: a Send-SMS hook that
  allows +95 only, and a low SMS rate limit.

## The longer view

Six directions in which the next years will push, and the stance for each:

1. **The client is readable.** AI-assisted decompilers turn an obfuscated APK
   back into code in minutes. Nothing the app decides is enforcement; every
   right is decided by the server (request-playback, budgets, bound tokens),
   and nothing secret ships in the APK (checked: only the publishable key).
2. **Bots are cheap.** Scripted and agent-driven traffic is the default
   attacker. Grant budgets, install-bound tokens and the Worker's ceiling are
   in place; a WAF in front of the Worker comes with the domain.
3. **Pictures prove nothing.** Receipts, screenshots and soon video can be
   generated. Approve on the money in the account, never on an image.
4. **The supply chain is the soft side.** Pinned actions, checksum-verified
   tools, a weekly vulnerability scan, and a signed statement of where each
   APK came from (artifact attestations) that anyone can check.
5. **Platforms move.** 16 KB pages (guarded now), the yearly target-SDK step,
   and Media3 as the documented way out if libmpv's Flutter binding stalls
   (`docs/streaming_abr_research.md`). **Flutter is behind:** CI pins 3.32.8
   on purpose (`build.yml` explains why), and stable is now 3.47 — five
   lines, about fifteen months. Engine, Dart and plugin fixes since then do
   not reach viewers. Raising it is a toolchain move (Gradle ≥ 8.14, AGP,
   Kotlin together), so it is its own release, below.
6. **One person runs this.** The runbook, off-site backups and the signing
   key are what let the project outlive a bad week. Its long-term footing is
   content it has the right to carry (`docs/security.md` §4): no amount of
   engineering makes up for that.

## Sources

* Actions: [tj-actions compromise, CVE-2025-30066](https://www.sentinelone.com/vulnerability-database/cve-2025-30066),
  [zizmor audits](https://docs.zizmor.sh/audits/).
* Attestations: [actions/attest](https://github.com/actions/attest),
  [GitHub docs](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds).
* 16 KB pages: [Android developers](https://developer.android.com/16kb-page-size);
  the same two libraries fixed by the same versions in
  [mob_scanner 0.1.2](https://repo.hex.pm/preview/mob_scanner/0.1.2/CHANGELOG.md).
* Developer verification: [Android Authority](https://www.androidauthority.com/google-android-advanced-flow-sideloading-rollout-begins-3700073/),
  [TechAIWire](https://techaiwire.com/articles/android-developer-verification-enforcement-four-countries/).
* AI-made receipts: [GCash warning](https://mynt.com.ph/news-draft/gcash-warns-public-on-emerging-ai-generated-fake-receipts-scams-urges-users-to-always-check-transactions-tab),
  [bKash sellers, arXiv 2602.12650](https://arxiv.org/pdf/2602.12650).
* Passkeys: [Supabase (experimental)](https://supabase.com/docs/guides/auth/passkeys),
  [FIDO Alliance](https://fidoalliance.org/passkeys/).
* SMS pumping: [Ireland NCSC](https://ncsc.gov.ie/pdfs/2506120143_SMS_Pumping.pdf),
  [TechTarget](https://www.techtarget.com/cybersecurity/feature/SMS-pumping-attacks-and-how-to-mitigate-them).
* Key attestation root change (for Phase 2 device binding):
  [Android developers](https://developer.android.com/preview/features/key-attestation),
  [Bayton](https://bayton.org/android/android-enterprise-faq/key-attestation-root-certificate-change/).
