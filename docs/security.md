# Security review — 2026-10-05

Owner request: "suppose someone skilled and dishonest sets out to attack
Innocent. Where are we weak, in the client, the server, the database and R2?
Protect it to an internationally recognised standard, hide the origin, keep
users anonymous, survive malicious reports, resist interception, and stop
the public repository being copied."

This is the threat model, what was found, what was fixed (and verified),
and what is left for the owner, who is the only one who can do it.

## 1. Who the attacker is and what they have

Assume a capable, patient person with:

* **the APK.** It is downloadable by anyone, so they also have everything
  inside it: the Supabase URL, the publishable (anon) key, every request the
  app can make. **Anything `anon` may do, anyone may do, by script, without
  limit.** This one sentence decides most of what follows.
* **the source.** The repository is public: edge functions, the console,
  the workflows, the migrations.
* **a phone they control** (rooted, Frida, a proxy with its own CA).
* **a network position** (shared Wi-Fi, a hostile ISP), but not the
  ability to forge a certificate from a public CA.
* **a motive**: free premium, cost and outage (fill the database, run up
  storage bills), rigged rankings, or getting the service reported and
  taken down.

They do NOT have: the service keys (Supabase Edge secrets), Cloudflare or
GitHub logins, the signing keystore.

## 2. Findings

| # | Layer | Finding | Severity | Status |
|---|---|---|---|---|
| 1 | R2 | An R2 **secret access key** was once committed and later removed (2026-09-25). Removal does not erase history: the key is still readable in the public repository. Rewriting history was ruled out. | **Critical** | **Closed** — the owner rotated the key (confirmed 2026-10-06); the old one no longer works |
| 2 | DB | `title_media` gave anon the public URL of **every** photo of a premium title; the app blurred locked ones, but one request opened the whole album. | High (paywall bypass) | **Fixed** — migration 041 |
| 3 | Server | `self-test` and `backfill-dimensions` ran with verify_jwt off and no check, using the service key; `backfill-dimensions` writes to the database and spends R2 reads. | High | **Fixed** — admin + MFA gate; deployed v19 / v15 |
| 4 | DB | `record_events` had no budget: a loop writes 200 rows a call until the free 500 MB database is full, and the rows feed Trending. | High (outage, ranking poisoning) | **Fixed** — 600/h per install, 4000/h per network, 30 000/h in all, server clock, meta ≤ 2 KB |
| 5 | DB | `record_view`: fresh install ids inflate any title's view count. | Medium | **Fixed** — ≤ 20 installs per network per title per day |
| 6 | DB | TRUNCATE / TRIGGER / REFERENCES granted to anon and authenticated on every table; trigger functions in the RPC surface; 5 functions without a fixed search_path. | Low (defence in depth) | **Fixed** — 041 |
| 7 | Client | Release APK not obfuscated: every Dart class and method name ships in `libapp.so`. | Medium (reverse engineering) | **Fixed** — `--obfuscate --split-debug-info`; symbols kept encrypted |
| 8 | Network | No network security config: backend hosts could be reached over http:// if a URL was ever downgraded. | Low | **Fixed** — own hosts HTTPS-only, system CAs only |
| 9 | Auth | Leaked-password protection (HaveIBeenPwned) is off. | None today | Not applicable: the only sign-in is Google (no passwords), and the check is a Pro-plan feature. What matters instead: the Email and Phone providers must be OFF if unused (§5) |
| 10 | R2 | Media is served from `pub-….r2.dev`. Cloudflare: r2.dev "is not intended for production usage and has a rate limit" (429 at hundreds of requests/second). It also names the bucket, and every request is a billable Class B read. | Medium (availability, cost) | **Owner: custom domain** (§4) |
| 11 | Server | Worker stream tokens are not bound to a device: a token copied within its lifetime plays elsewhere. | Low (lifetime is short) | Open — see §6 |
| 12 | Repo | Source is public. | — | Owner decision (§7) |

What was checked and is **sound**: row level security on every table
(anon reads only what a view or policy hands out; `title_assets` and
`subscriptions` are unreadable); the paywall for video is enforced in
`request-playback` with short-lived signed URLs; the Worker's sealed
AES-GCM tokens and CORS allowlist; the console requires an admin role and
MFA; diagnostic reports already had a flood guard; no workflow runs on
`pull_request` (a fork cannot reach a secret); no service key, JWT secret or
Telegram token anywhere in git history; the session lives in
flutter_secure_storage (Android Keystore) and is excluded from backups.

The advisor still reports `title_media` as a SECURITY DEFINER view. That is
deliberate (013b): the view *is* the access control over a table anon may
not read. The other "anon can execute SECURITY DEFINER" notices are the
app's public RPCs (catalogue, search, events), each written to trust nothing
the caller names.

## 3. What changed, and how it was verified

All database checks were run as `anon` / `authenticated` inside
transactions that were rolled back.

* **Photos** (041): anon now receives 5 of 7 premium-photo URLs (exactly the
  free allowance: 3 per title, plus the `is_free` one), signed-in 7, a
  subscriber 7, free titles all 56. Locked photos keep their blurhash and
  the app draws them from it behind the lock (`AlbumItem.withheld`; a test
  pins that a withheld photo never opens, whatever the tier).
* **Events**: three batches of 200 from one install were written; the 601st
  event was refused and counted as `(over budget: install)`; a 5 KB meta was
  stored as `{}`.
* **Views**: 25 invented installs from one network on one title added 20.
* **Functions**: unauthenticated calls to `self-test` and
  `backfill-dimensions` now answer 401.
* **App**: analyzer at the baseline (283), 863 tests pass.

## 4. R2: the origin, anonymity and malicious reports

**Hiding the origin.** R2 has no server address to find; the "origin" an
attacker sees is the bucket's own r2.dev hostname. Videos already never show
it — they go through the Worker with sealed, expiring tokens. Photos,
posters and the APK still do. The fix is a **custom domain on Cloudflare**
(about USD 10 a year): connect it to the bucket, turn r2.dev **off**, cache
at the edge (a cached image costs no R2 read), and add a WAF rate-limit rule.
Then the only public name is the domain, behind Cloudflare's network. Change
`public_asset_base()` and the poster/APK URLs together.

**Viewer anonymity.** The database stores no IP address: only an HMAC of it
with a secret salt, used for the budgets above. Viewers need no account to
browse; history is keyed by a random install id. A dump of the database does
not say who watched what. Payment screenshots (names, numbers) sit in a
private bucket only the service role can read.

**Malicious reports.** Cloudflare is not only in front of R2 — it is the
*host*. For hosted content Cloudflare says it "will remove or disable access
to" what it believes violates its terms, and notifies the operator. No
configuration hides content from its own host, and none should be tried:
evading a provider's abuse process is itself a breach of its terms and gets
the whole account closed. The defence against false reports is to be plainly
legitimate, so a report is rejected on its face:

1. hold the rights to every title (licence or the performers' consent);
2. keep the 18+ age gate (it is already enforced and recorded);
3. publish a contact and takedown address in the app and on the APK page,
   and answer it, so a complaint comes to you first;
4. keep the console's audit log (`admin_audit`, append-only) as the record
   of who uploaded what.

## 5. Owner actions (only you can do these)

1. ~~Rotate the R2 key~~ — done by the owner.
2. **Turn off sign-in methods the app does not use**: Supabase →
   Authentication → Sign In / Providers → **Email** and **Phone** off
   (Google stays on). Otherwise anyone with the anon key can create
   accounts by script (each one a "registered" viewer) and, with email
   confirmation on, spend the project's email quota.
3. **Custom domain for R2 and the Worker** (§4), when there is one.
4. Drop the three `*_v039` test functions (they have no grants; this is
   tidiness): `drop function public.<name>_v039(...)`.
5. A takedown/contact address and an in-app Report (§4.3).

## 6. Interception and the phone itself

* **On the network**: every backend call is TLS 1.2+; since this review the
  app refuses cleartext to its own hosts and trusts only the system's CAs, so
  an intercepting proxy fails. **Not pinned, deliberately**: MASVS-NETWORK
  calls pinning the highest level, but with no store to push an urgent fix
  through, a pin that outlives its certificate also breaks the updater and
  strands every install. Revisit if the app gains a store channel.
* **On a phone the attacker owns**, everything in the APK is readable in the
  end — that is true of every app. So nothing secret is in the APK, the
  server decides every entitlement, and obfuscation raises the cost of
  reading the rest (MASVS-RESILIENCE). Root/emulator detection and
  attestation (Play Integrity) are the next step if piracy becomes real; the
  Worker token could then carry the device id and be refused elsewhere.

## 7. The public repository

A public repository can always be read and copied; nothing on GitHub
prevents a clone. The options, strongest first:

1. **Make it private** — declined by the owner (2026-10-06): public
   repositories run GitHub Actions without the free plan's 2 000-minute
   monthly limit, and this pipeline needs that.
2. **A proprietary licence** — done (`LICENSE`, 2026-10-06): reading and
   studying allowed; copying, redistributing, modifying, rebuilding or
   publishing anything made from it is not. A legal tool, not a lock: it
   is what makes a DMCA takedown of a copy on GitHub, an app store or a
   host straightforward. Copyright covers the code, not the ideas in it.
3. **Keep secrets and infrastructure out of it** (done: credentials live
   only in Supabase, Cloudflare and Actions secrets; `tool/security_invariants.py`
   rejects key-shaped strings).
4. **Obfuscated releases** (done), so the shipped app is not the readable
   source either.

## 8. Standards this maps to

* **OWASP MASVS v2.1** (mobile): STORAGE (Keystore session, backup
  exclusions), CRYPTO (HMAC'd IPs, AES-GCM tokens), AUTH (server-side
  entitlements, MFA for admins), NETWORK (§6), PLATFORM (exported
  components reviewed), CODE (signature check in CI), RESILIENCE
  (obfuscation), PRIVACY (no raw IPs, anonymous browsing).
* **OWASP API Security Top 10 (2023)**: API1/BOLA (RLS, auth.uid() only),
  API2 (gated functions), API4 unrestricted resource consumption (event and
  view budgets), API5 function-level authorisation (admin_resolve + MFA).
* **OWASP ASVS** for the console and edge functions (authentication, access
  control, logging).

## Sources

* [Cloudflare R2 — public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/)
  and [limits](https://developers.cloudflare.com/r2/platform/limits/) (r2.dev not for production).
* [Cloudflare — our approach to abuse](https://cloudflare.com/abuse) and the
  [H1 2025 transparency report](https://blog.cloudflare.com/h1-2025-transparency-report).
* [OWASP MASVS releases](https://github.com/OWASP/owasp-masvs/releases);
  [MASVS v2.1 controls](https://opensecurityarchitecture.org/frameworks/owasp-masvs-v2/controls).
* [Supabase — password security](https://supabase.com/docs/guides/auth/password-security);
  [database linter](https://supabase.com/docs/guides/database/database-linter).
