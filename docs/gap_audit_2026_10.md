# Gap audit — 22 October 2026

The owner asked for what is still missing or weak, measured against current
practice and against what the next years are likely to bring — attacks that
lean on AI included — with everything that costs nothing done first. This is
what was checked, what was fixed, and what is left, with the reason.

## How it was checked

| tool | open source / free | what it looked at |
|---|---|---|
| Supabase advisors (security, performance) | free | the production database |
| [zizmor](https://docs.zizmor.sh) 1.31.1 | open source | every GitHub Actions workflow |
| `tool/apk_page_check.py` (new) | ours | every arm64 library in the 1.64.69 APK |
| [OSV-Scanner](https://github.com/google/osv-scanner) 2.2.2 | open source (Google) | `pubspec.lock`, in CI (the database is not reachable from the dev container) |
| `tool/check.py`, `tool/security_invariants.py` | ours | the whole tree, before every push |
| research | — | Android platform changes, payment fraud, SMS fraud, device attestation |

## Fixed (no cost)

| finding | severity | fix |
|---|---|---|
| 24 GitHub Actions pinned only by moving tags (`@v2`), in workflows that hold the APK signing key and the R2/Supabase secrets. Tags can be moved: in March 2025 the `tj-actions/changed-files` tags were moved to a commit that dumped secrets into public logs (CVE-2025-30066). | high | every action pinned to its commit SHA, the tag kept as a comment |
| `playback-check` pasted a dispatch input straight into a shell script | high | passed through the environment, and checked to look like a title id |
| `device-lab` gave write access to the whole workflow | high | read by default; write only for the job that commits results |
| 8 checkouts left the GitHub token on the runner's disk for every later step | medium | `persist-credentials: false` wherever nothing is pushed (2 jobs push results and keep it) |
| Two native libraries in 1.64.69 linked for 4 KB memory pages: ML Kit's `libbarhopper_v3.so` and CameraX's `libimage_processing_util_jni.so` (the QR scanner). Android 15+ phones may run with 16 KB pages; there these do not load and the scanner crashes. | high (future) | ML Kit barcode-scanning 17.3.0, CameraX 1.4.2; `tool/apk_page_check.py` now fails any build that ships such a library. Verified in CI build 39812275343: 17 arm64 libraries, 0 that a 16 KB-page phone cannot load |
| RLS policies evaluated `auth.uid()` once per row (4) | performance | `(select auth.uid())` — migration 047 |
| 9 foreign keys without an index | performance | indexed — migration 047 |
| `offsite_max_bytes()` had a mutable `search_path` | low | fixed — migration 047 |
| A payment's transaction number could be reused by another account unnoticed; only a byte-identical screenshot was caught. An AI-made or re-edited receipt has a new hash. | medium | `premium-request` flags a reused transaction number like a reused screenshot (owner told in red, console marks it); the console says, beside Approve, to find the payment in the KPay/Wave app first |
| No standing check for published vulnerabilities in dependencies | medium | `.github/workflows/deps-scan.yml`: OSV-Scanner weekly and on every lock change, binary checksum-verified |
| The SHA-256 in `app_releases` proves a download is the published file, not who built it: anyone able to write the table or a mirror could publish another APK with a matching hash | medium | every APK a release uploads gets a GitHub artifact attestation (SLSA provenance, signed through Sigstore, public log), in a separate job that holds no signing key and checks nothing out. Check any copy, from any mirror: `gh attestation verify innocent-X-Y.apk -R yannmh007/innocent` |

**Caught before it shipped:** 1.64.70's first draft let a *rate-limited*
play fall back to the bytes already on the phone. The project's own
invariant (`tool/security_invariants.py`) refuses that: held bytes are for
"the server could not be asked", never for "the server said no". Fixed.

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
3. **GitHub settings (free):** turn on Dependabot alerts and secret-scanning
   push protection (Settings → Code security).
4. **Cloudflare connector:** authorising it lets the Worker's logs and
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
   Flutter kept within two stable releases (CI pins 3.32.8), and Media3 as
   the documented way out if libmpv's Flutter binding stalls
   (`docs/streaming_abr_research.md`).
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
* SMS pumping: [Ireland NCSC](https://ncsc.gov.ie/pdfs/2506120143_SMS_Pumping.pdf),
  [TechTarget](https://www.techtarget.com/cybersecurity/feature/SMS-pumping-attacks-and-how-to-mitigate-them).
* Key attestation root change (for Phase 2 device binding):
  [Android developers](https://developer.android.com/preview/features/key-attestation),
  [Bayton](https://bayton.org/android/android-enterprise-faq/key-attestation-root-certificate-change/).
