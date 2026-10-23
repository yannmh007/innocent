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
| `offsite_max_bytes()` had a mutable `search_path` | low | fixed — migration 047 |
| A payment's transaction number could be reused by another account unnoticed; only a byte-identical screenshot was caught. An AI-made or re-edited receipt has a new hash. | medium | `premium-request` flags a reused transaction number like a reused screenshot (owner told in red, console marks it); the console says, beside Approve, to find the payment in the KPay/Wave app first |
| The console — the page that can delete the catalogue and name admins — had no Content-Security-Policy, and any other site could show it inside an invisible frame and line an admin's tap up with Approve or Delete (clickjacking). It renders no database text as HTML today; nothing stopped a future slip from becoming an admin takeover. | medium | the page's script moved to `app.js` and a policy allows only this site's own script files (no inline script, no handler attributes, no eval, no other host); the page starts hidden and `top.js` shows it only as the top window. `console_smoke.mjs` proves both: an injected script and an `onclick` do not run, a framed console stays hidden, and every scenario runs with zero refusals |
| No standing check for published vulnerabilities in dependencies | medium | `.github/workflows/deps-scan.yml`: OSV-Scanner weekly and on every dependency change, binary checksum-verified. It resolves first, with the Build workflow's Flutter, and scans that: the committed `pubspec.lock` had fallen so far behind that it did not list google_sign_in. First run: 157 packages, no known vulnerability |
| The SHA-256 in `app_releases` proves a download is the published file, not who built it: anyone able to write the table or a mirror could publish another APK with a matching hash | medium | every APK a release uploads gets a GitHub artifact attestation (SLSA provenance, signed through Sigstore, public log), in a separate job that holds no signing key and checks nothing out. Check any copy, from any mirror: `gh attestation verify innocent-X-Y.apk -R yannmh007/innocent` |

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

## Next app release (after 1.64.70)

* **Delete my account**, in the app: Play policy for any app with accounts,
  and Thailand's PDPA (the app ships Thai) gives a right to erasure. Watch
  history, devices and bookmarks deleted; payment records kept, anonymised.
* **A faint moving account code on premium video** (8 hex digits of the same
  hash the Worker logs as `u`), so a recording made where FLAG_SECURE is
  bypassed can be traced. Through the four premium player routes and
  picture-in-picture.
* **Sealed premium stream cache** with the downloads' Keystore cipher.
* **Toolchain release, on its own:** Flutter 3.47 with the Gradle, AGP and
  Kotlin it needs, no feature changes in the same release, through the
  same 1,070 tests, the device lab and Test Lab on both real phones before
  it ships. Kept apart so that anything it breaks is the toolchain's.
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
