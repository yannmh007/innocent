# Quality checklist

Every check this project runs against a published standard, where it runs,
and what it last said; then what is still open, in the order it is worth
doing. Kept current by whoever closes an item. The findings themselves, with
their history, are in `docs/gap_audit_2026_10.md`.

Last full pass: **30 Oct 2026**; open items worked 31 Oct.

## 1. The checks

| area | standard | how | where it runs | last result |
|---|---|---|---|---|
| Static analysis (code) | OWASP ASVS / CWE | Semgrep 1.183, 830 rules at a pinned commit | `sast.yml`: every push fails on a new ERROR finding in what it changed; weekly full table | 298 hits triaged 30 Oct, 0 open |
| Static analysis (Dart) | Flutter lints | `flutter analyze` | every build | 0 errors, 0 warnings, 272 notes (looked at) |
| Static analysis (edge functions) | TypeScript | `tsc` with a Deno shim | by hand | clean but for TS 5.7's `Uint8Array` typing |
| Structure, secrets, paywall invariants | own | `tool/check.py` (23 checks, 16 JS suites) | before every push | pass |
| Unit and widget tests | — | `flutter test` | every build | 1211 of 1211 |
| Network core on real servers | — | `tool/netlab` (JVM) against Samba, vsftpd, OpenSSH | device lab, `NETLAB=1` | 22 of 22 (run 41092354010) |
| The app on an emulator | — | Maestro flows, shaped Myanmar lines | device lab | green (runs 41083235270, 41092354010) |
| The app on real phones | — | Firebase Test Lab, realme C53 and OPPO A79 | Test Lab, 5 phones a day | 16 of 16 and 15 of 16 (run 41047246611) |
| Dependencies (Dart) | OSV / GitHub Advisories | OSV-Scanner 2.2.2 on a fresh `pubspec.lock` | weekly and on change | 0 |
| Dependencies (Android) | OSV / GitHub Advisories | the same on Gradle's release classpath | weekly and on change | 0 open; 21 accepted until 31 Jan 2027, each with why |
| CI supply chain | OpenSSF Scorecard, GitHub hardening | zizmor 1.31; actions pinned by SHA; every outside download pinned by SHA-256 (`tool/pins.py`) | zizmor by hand; the pins downloaded and compared weekly (`deps-scan.yml`, job `pins`) | 0 medium/high; OSV-Scanner, Maestro, ffmpeg pinned and matching |
| Mobile app security | OWASP MASVS 2 / MASTG | the checklist below | by hand, per release | see below |
| Database | Supabase advisors | security and performance advisors | by hand | nothing new; the known ones are in the gap audit |
| Console (web) | OWASP Top 10 | CSP, frame guard, text-only DOM, smoke test in Chromium | `console_smoke.mjs` in check.py | pass |
| Accessibility | WCAG 2.2 AA, Android a11y | tap targets, labels, contrast, toggled states | screen harness, device lab | "Media only" fixed 30 Oct |

### OWASP MASVS, item by item

| control | what holds it | state |
|---|---|---|
| STORAGE-1 sensitive data stored safely | tokens and vault metadata in the Keystore (`SessionStore`, `PrivateFolderService`); downloads and stream cache sealed (AES-CTR, Keystore key) | ✓ |
| STORAGE-2 no leak through backups | `backup_rules.xml`, `data_extraction_rules.xml`: vault, keys, cache, downloads, catalogue out | ✓ |
| CRYPTO-1 strong, current primitives | AES-256-GCM (wrapping, server sealing), HKDF-SHA256, PBKDF2-HMAC-SHA256 checked against published vectors | ✓ |
| CRYPTO-2 keys managed safely | Android Keystore, random IVs from the Keystore; server keys only in Supabase secrets | ✓ (owner keeps a copy of `PII_ENC_KEY`) |
| AUTH-1 server-side authorisation | `request-playback` fails closed, device-bound grants, admin gate with MFA | ✓ |
| AUTH-2 local authentication | vault PIN: PBKDF2, constant-time compare, escalating lockout on the boot clock (30 Oct) | ✓ in the next release |
| AUTH-3 sign-in | Google sign-in; nonce built, waits for the owner's real sign-in | open (owner) |
| NETWORK-1 TLS everywhere it matters | own hosts HTTPS-only, system CAs only; cleartext only for the local-network features | ✓ |
| NETWORK-2 identity of the server | system trust store; no pinning (Cloudflare rotates) — accepted | ✓ |
| PLATFORM-1 IPC | only launcher, media session, widget and boot receivers exported; providers not exported | ✓ |
| PLATFORM-2 WebView | in-app browser not exported | ✓ |
| PLATFORM-3 UI | screenshots blocked on premium and vault screens | ✓ |
| CODE-1 platform kept current | targetSdk from Flutter; minSdk 24 | decision open (owner: 26?) |
| CODE-2 updates | own updater with SHA-256 and mirrors | ✓ |
| CODE-3 no known-vulnerable components | OSV on both halves | ✓ (21 accepted, dated) |
| CODE-4 input validated | SQL through RPCs; XML ETags checked (30 Oct) | ✓ |
| RESILIENCE | release obfuscated; the account code on paid video | ✓ |
| PRIVACY | payment numbers, receipts and backups sealed; R2 keys say nothing | ✓ but one old receipt still plain (open, P2) |

## 2. Open, in order

**P1 — security, or a gate for the next release. Done next, in this order.**

1. ~~**Pin ffmpeg.**~~ Done 31 Oct: BtbN autobuild-2026-07-31 (n7.1.5) by
   SHA-256 in transcode.yml and the lab, Ubuntu's signed ffmpeg as the
   fallback; checked weekly. transcode.yml takes effect with the next
   release (it runs from main).
2. ~~**A lab flow for the vault's wait.**~~ Done: run 41158555130, 3 of 3.
   Set a PIN, five misses, the wait; the phone's date moved 2 hours on
   (7201 s): the wait held, and ended on the boot clock's 60 s. Gate for
   1.64.79.
3. ~~**The downloader on Jackson 2.13.5.**~~ Done: run 41101805278, "LAB
   engine update ok ALREADY_UP_TO_DATE". The library's Jackson reads only
   the yt-dlp updater's reply from GitHub (the app reads yt-dlp's reports
   in Dart); a flow opens Downloads on a fresh install, so the engine is
   unpacked and updated, then reads an open film's direct link. Gate for
   1.64.79.
4. **1.64.79**: the vault fix, BouncyCastle 1.86 and the other library
   raises, the "Media only" state, the network log lines. Device lab, then
   Test Lab on the realme and the OPPO, then release.

**P2 — privacy and reliability.**

5. Reseal the one payment screenshot stored before sealing: ingest v41
   seals it on its tick (31 Oct; `proof_reseal_test.mjs`).
6. Telegram folder names that say nothing (the bot functions in 023/024/033).
7. The sealed-cache timing tests that sometimes fail on a busy runner.
8. ~~Semgrep in CI with a pinned rule set.~~ Done 31 Oct (`sast.yml`).
   Also found on the way and fixed: the vault PIN pad read each digit
   twice to TalkBack.

**P3 — when convenient.**

9. 106 `withOpacity` and 6 `onPopInvoked` deprecations (with the Flutter
   upgrade, not before).
10. Actions on Node 24 versions (GitHub runs the Node 20 ones on 24 today).
11. Burmese wording in Settings.

**The owner's.**

- Sign in once with a branch build that carries the Google nonce.
- Keep an offline copy of `PII_ENC_KEY`.
- B2: lifecycle "Keep only the last version".
- Console → Files → Scan, so the eight test films' R2 objects can be binned.
- minSdk 26 or not (gap audit, "Needs the owner" 7).
- Android developer verification before 2027; GitHub's private
  vulnerability reporting and push protection; passkeys for console admins
  (gap audit, "Needs the owner" 1-5).

**Paused by the owner:** download speed (DL), first rung when unmeasured
(ST2).
