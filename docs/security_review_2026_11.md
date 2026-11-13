# Security review — 5 Nov 2026

Owner's questions: how far has the work come; where are the weak points;
if dishonest people, AI bots or AI-driven attackers pose as users and probe
the system, how safe is the content; how well is the R2 origin hidden; and
is the reporting path (that the host is Cloudflare) hidden so that fake
reports cannot cause trouble. Check in detail, record what needs raising,
research, and plan.

Builds on `docs/security.md` (5 Oct), `docs/security_streaming.md`
(22-27 Oct) and `docs/MEDIA_ENCRYPTION.md`. Everything marked *verified*
was checked today against the live project or the code at a146699.

## 0. One question this review does not take up

Hiding the fact that Cloudflare hosts the service so that abuse or takedown
reports cannot reach it is not an aim, and nothing is built for it. That was
the position on 5 Oct (`docs/security.md` §4) and it stands. It cannot work
anyway: the host is visible to anyone (Cloudflare's IP ranges, `server:
cloudflare`, `cf-ray`). And evading a provider's abuse process breaks its
terms and gets the whole account closed. The real defence against *false*
reports is §4 below: a takedown contact of our own, a record of rights for
every title, and the counter-notice process. Encryption at rest (ENC)
protects against breaches. It does not stop legal process or a host acting
on a valid report (`MEDIA_ENCRYPTION.md` §2).

## 1. Where things stand (verified)

| Layer | State today |
|---|---|
| **Film origin** | `innocent-media` is private, with no public URL; it is read only through the Worker's binding. The client only ever holds `stream.innocentplayer.com/v/<opaque token>`: AES-256-GCM, 10 minutes, bound to the install (enforced since 25 Oct). There is no presign fallback. workers.dev and r2.dev are both **off**. WAF allows only `/v/` and `/health`, with GET, HEAD and OPTIONS. An IP rule allows 400 per 10 s, and the Worker allows 600 per 10 s per install (enforced since 29 Oct). TLS 1.2+. The real app behind a MITM proxy refuses the connection (lab). |
| **Grants** | `request-playback` checks title, tier, subscription and two device slots. Budgets: per install 300/h and 300 titles/day; per account 600/h and 500/day; per network 1,200/h. |
| **Database** | RLS is on every table; 40 tables have no policy at all (service role only). The 10 RPCs anon can call are the app's public ones, each budgeted. pg_graphql is not installed. The one SECURITY DEFINER view (`title_media`) is deliberate (041). |
| **Admin** | One admin, the owner. Google plus a verified TOTP factor; `require_mfa` on; step-up 10 min, idle 30 min. `admin_audit` is append-only. Console CSP is `script-src 'self'`, the vendored supabase-js is pinned with SRI, and no database text is rendered as HTML. |
| **Accounts** | Only Google identities exist (1 account). Viewers browse without one. |
| **Secrets** | None in the repo (`security_invariants.py`: 0). The R2 account id is a secret. Every Action is pinned by SHA, no workflow runs on `pull_request_target`, and job permissions are least-privilege. |
| **Sealed data** | All 16 database backups are sealed (IBK1). Payment screenshots and payment numbers are sealed. |
| **Telegram** | The webhook secret is compared in constant time; only operator chats are accepted; the runner signs in as the bot over MTProto, never as a user session. |
| **ENC (media)** | Format, keys and all eight pipeline steps are built, tested and deployed. **41 sealed objects** (12 video, 29 image rows), open films only. Switch `seal_new` = `off`. The app that opens seals is on the branch, not released. |

### Answers to the questions, plainly

* **Content against bots and impostors.** Nobody gets a film byte without a
  grant. Every grant is decided by the server and is sealed, short-lived and
  bound to one install. A bot with no account gets the free titles only,
  slowly. **The gap is a scripted client with a real paid account** (S3).
  It can pull what that account is entitled to, without the player's
  watermark. It cannot be stopped today, only traced afterwards in the
  Worker logs.
* **The R2 origin.** As hidden as it can be. The films' bucket has no
  address that works from outside. Nothing the client receives names the
  account, the bucket or a key. Every film read goes through the Worker. The
  public bucket (posters, the APK) answers only on `cdn.innocentplayer.com`.
  What remains visible is our own domain names, which is unavoidable and
  harmless.
* **Content at rest.** **Not yet protected by ENC.** Every film and photo
  still exists in plain form in R2. If the R2 credentials or the Cloudflare
  account were compromised, plain content would be exposed (S2).

## 2. Findings, worst first

| # | Finding | Severity | Plan (§3) |
|---|---|---|---|
| S1 | **Supabase retires the legacy JWT keys by the end of 2026.** All 9 functions read `SB_SERVICE_KEY ?? SUPABASE_SERVICE_ROLE_KEY`, and 21 raw REST calls sent it as `apikey` *and* `Authorization: Bearer`. Supabase documents that a new `sb_secret_` key is not a JWT and must go in `apikey` only ("Invalid JWT" otherwise); supabase-js 2.117.2 itself puts it in Bearer by default (seen on the wire, 6 Nov). The legacy anon key is still enabled, though the app and console use the publishable key. Supabase no longer lets the legacy JWT secret be rotated, so a leaked service_role JWT could not be revoked except by migrating. **Done 6 Nov: every function runs on the new secret key** (`service_key.js`, P1); the legacy keys can be turned off once the logs stay quiet. **Turned off 13 Nov** (the owner, after a quiet day in the gateway logs; ingest and the transport check green after). | **High** (outage at a fixed date; no revocation) | P1 |
| S2 | **ENC is built but not switched on.** Plain copies still in R2: 10 streaming copies, 24 files, 36 thumbnail choices, 4 covers, 4 thumbnails. Sealed twins exist only for the open films. Until rollout C-E, a leaked R2 token or a Cloudflare account takeover exposes plain content. | **High** | P2 |
| S3 | **No device attestation.** A script with a valid account can (a) send a device RSA key of its own making — the key is only pinned per install at first sight — and receive DEKs, and (b) pull films without the player's moving account code, which the app draws on screen and is not in the file. The account budget (500 titles/day) is far above any human. There is no automatic alert on bytes per account. | Medium-High | P3 |
| S4 | **The console's origin is shared.** `yannmh007.github.io` is the origin of every GitHub Pages site of this account. The admin session (an aal2 refresh token) lives in that origin's localStorage, and the Worker's CORS trusts that origin. Today there is only one repo, so nothing else shares it, but a second Pages site would. The CSP's `connect-src … https:` and `img-src https:` would let an injected script send data to any host. | Medium | P4 |
| S5 | **Five accounts are each a master key.** GitHub (a push to main is a production console *and* Worker deploy), Cloudflare, Supabase, Google (admin sign-in) and Telegram (operator). A takeover of any one bypasses every control in the code. | Medium (likelihood) / Critical (impact) | P5 |
| S6 | **The source is public: a white box for AI-assisted attackers.** Every function, RPC and rule can be read and reviewed by a model in minutes. Making the repo private was declined (Actions minutes). | Medium | P5 |
| S7 | **No takedown contact and no in-app Report** (owner action #5 of 5 Oct, still open). Without them a complaint goes straight to the host instead of to us. | Medium (fake reports) | P6 |
| S8 | **Supabase's `/rest/v1/` OpenAPI root** lists every exposed table and RPC. Supabase announced in Feb 2026 that it would stop serving this to the anon key (March and April 2026). Not checked live, because Supabase is unreachable from the sandbox. | Low | P7 |
| S9 | **The R2 inventory was last scanned on 2 Oct.** The Files page's view of R2 is a month old, so orphaned plain objects would go unnoticed. | Low | P7 |
| S10 | `claim_anonymous_history(anon_id)`: a signed-in caller who knows another install's id could take over that install's anonymous history. Install ids are random and never shown, and anon calls are a no-op. | Low | P7 |

Not findings (re-checked): the advisor's `rls_enabled_no_policy` (40) is the
intended "service role only" state. The "leaked password protection" warning
does not apply, because there are no passwords. The 10 anon SECURITY DEFINER
RPCs are the public API, budgeted (`docs/security.md` §2).

## 3. The plan, in order

**P1 — move off the legacy keys (before 31 Dec).**
1. ~~Code~~ **done 6 Nov**: `docs/edge/service_key.js` is the one place a key
   is read (`SB_SERVICE_KEY`/`SB_ANON_KEY`, then the platform's
   `SUPABASE_SECRET_KEYS`/`SUPABASE_PUBLISHABLE_KEYS` JSON, then legacy) and
   the one place its headers are made: a legacy JWT still gets `apikey` +
   `Bearer`, exactly as before; a new key gets `apikey` alone, also through
   supabase-js (`keyFetch` removes the Bearer copy supabase-js adds). Every
   function logs at boot which names are set and each key's shape, never a
   value. `prefer: 'legacy'` keeps today's choice; `prefer: 'new'` takes a
   new key when one exists and otherwise falls back to the legacy key.
   Proved: `tool/js/service_key_test.mjs` (also fails the build if any
   function reads a key or builds a key header itself), the nine functions
   booted locally, and on the wire against a stand-in server — transcode's
   claim and supabase-js REST, RPC and auth-admin calls carry `apikey`
   alone with a new key and both headers with a legacy one.
2. ~~Canary~~ **done 6 Nov 02:24 UTC**: transcode v26 (56b7db3) on
   `prefer: 'new'`. Its two claims, `claim_transcode` and `claim_frames`, are
   service-role only (no grant to anon or authenticated), and both answered
   200 with the platform's default secret key in `apikey` alone. The boot
   log also showed what the environment holds. `SUPABASE_SECRET_KEYS` and
   `SUPABASE_PUBLISHABLE_KEYS` are present, so **no owner step was needed**.
   The platform already puts new-shaped keys in `SUPABASE_SERVICE_ROLE_KEY`
   and `SUPABASE_ANON_KEY`. And `SB_SERVICE_KEY`, which every function read
   first, held the **legacy JWT** — the one the retirement takes away.
3. ~~All functions~~ **done 6 Nov, 39daef0**:
   - ingest v49 (two runner ticks 200, `runner_ticks` written);
   - request-playback v42 (Playback check 42151014520 on Sintel, all five
     steps green; 7 grants 200);
   - studio v50, probe-media v25, backfill-dimensions v28, self-test v30
     (now the repo copy, as a shim);
   - premium-request v18 and delete-account v7 (verify_jwt kept on;
     delete-account is now a shim too).

   Every boot log reads `service: SUPABASE_SECRET_KEYS.default (secret)`.
   Gateway logs, 24 h before the move: 369 legacy service_role calls (the
   functions), 0 legacy anon calls (the app sends the publishable key).
   Still to see: the first real call of studio, premium-request,
   delete-account, probe-media, backfill-dimensions and self-test (BACKLOG
   R7).
4. Owner, in the dashboard, no code: Settings → JWT Keys → move to
   asymmetric signing keys (user tokens; the app and functions need no
   change). Then, once the gateway logs show no legacy JWT apikey for a
   week, Settings → API Keys → deactivate the legacy anon and service_role
   keys (reversible). Then delete the Edge secret `SB_SERVICE_KEY`, which
   holds the legacy JWT and is no longer read.

**P2 — finish ENC (the rollout already designed, MEDIA_ENCRYPTION §9).**
A: release the app with the opener (nonce held back as before) → C:
`min_supported` and `SEAL_MODE=on` → D: `seal_new` canary, then on → E: a
runner seals existing objects (skipping the do-not-touch list) and deletes
the plaintext after 14 days → F: B2 Object Lock. The live checks owed first
are BACKLOG O19, O20 and O24, and R1-R6.

**P3 — make a scripted client expensive and visible.**
1. **Android Key Attestation** — **built 6 Nov, log mode** (6a87482):
   - **App** (in 1.64.80, with the ENC opener, dormant: the chain is sent
     only by a build that asks for sealed copies). The media key is
     `inv_media_device_v2`, made with the challenge `inv-media-device-v2`.
     A Keystore that refuses attestation still gets its key, without a
     chain. The chain goes with grants until the server answers
     `attest: received`.
   - **Server.** `docs/edge/key_attest.js` checks:
     - every signature, up to one of Google's two roots, pinned by public
       key (RSA-4096 and the 2025 ECDSA P-384 Key Attestation CA1);
     - validity above the leaf;
     - Google's revocation list, cached an hour;
     - that the leaf certifies the key that was sent, with our challenge;
     - TEE or StrongBox;
     - locked and verified boot;
     - our package and release signer;
     - that the key was generated on the phone, not imported.
     It is size-capped, and hostile input is a verdict, not a throw.
     request-playback v43 checks in the background, logs the verdict and
     keeps it on the install's `devices` row (migration 074: `attest`,
     `attest_at`; the app cannot read them). Nothing is refused.
   - **Proved:** `key_attest_test.mjs`, 27 checks — openssl chains in
     Keystore's shapes, each failure naming itself, and Google's real roots
     verifying under the pins.
   - **Seen on real chains, 6 Nov** (request-playback v43):

     | where | root | level | boot | why not `ok` |
     |---|---|---|---|---|
     | device lab, emulator (run 42154151610) | unknown | software | unverified, unlocked | chain, level, boot, app — all as an emulator must read |
     | Test Lab, the realme, Android 15, KeyMint 2, chain of 5 (run 42156742961) | **google-ec** (the 2025 root, through Remote Key Provisioning) | TEE | verified, locked | `app` only |
     | Test Lab, the OPPO, Android 14, Keymaster 4, chain of 4 (same run) | **google-rsa** | TEE | verified, locked | `app` only |

     On all three the key and challenge matched and the revocation list
     was read (`revoked: false`). `app: other_signer` is right for a lab
     build: labs are debug-signed. Only a release build can read
     `app: ok`, so that is the one thing left to see (R8, after the
     release). Playback unchanged: the emulator passed jumps 15 of 15, the
     OPPO 16 of 16 and the realme 15 of 15, all sealed, the key held (rsa).

   **What it does and does not stop, honestly.** A chain is public, so
   anyone can replay a real phone's chain. That buys nothing where it
   counts: the film keys are wrapped for the attested key, which never
   leaves that phone's hardware. So once films exist only sealed (ENC
   rollout E), a script on a computer gets no film key at all. Today's
   plain copies are not covered: a grant for a plain file needs no key.
   Covering them means proof that the phone holds the key. One way: the
   server wraps the stream token itself for the attested key, so only
   that phone can use it (P3b, with the ENC rollout). Then `require` for
   premium: first premium sealed grants only to an attested install, then
   all premium grants.
2. **A lower cap: not yet, on purpose (6 Nov).** A grant is asked for
   when a title's page is opened, so the daily title cap counts pages
   browsed, not films taken. A tight cap would refuse someone who browses.
   Measured on the live table: the busiest install had 2 titles and
   5 grants in an hour, the busiest network 13 grants in an hour, the one
   account 2 titles. The catalogue has 4 published titles. A cap set from
   that would be a guess. It is set once step 3 has seen real viewers.
3. **The owner is told — built 6 Nov** (migration 075, ingest v50).
   `playback_watch_notice()` runs on every ingest runner tick. It reports,
   in Telegram, the first time each day an install or account passes
   60 distinct titles in a day or 200 grants in an hour, or a network
   passes 800 grants in an hour. Each is named only by its 8-character
   code: for an account, the one the player draws over a paid film and the
   start of `u` in the Worker's logs, found with the query in
   `docs/security.md` §9. It refuses nothing. Tested on live in a
   rolled-back transaction (`tool/sql/playback_watch_test.sql`): an
   ordinary day is silent, yesterday is not news, a sweep is reported once
   a day by its code, and no id or address is in the message. Bytes per
   account need the Worker's own counter (Analytics Engine or a Durable
   Object, plus a Cloudflare API token to read it): recorded, not built.
4. Later, with Phase 3 DRM: a forensic (A/B segment) watermark.

**P4 — give the console an origin of its own. Built 6 Nov; ON 6 Nov**
(`docs/console/README.md`):
- `docs/console`: an assets-only Worker, `innocent-console`, on
  `console.innocentplayer.com`. It serves `docs/studio` and the four edge
  modules the console imports, nothing else of `docs/`. `_headers` sets:
  - a CSP with `default-src 'none'`, `frame-ancestors 'none'`, and a
    `connect-src`/`img-src`/`media-src` of exactly the Supabase project,
    `stream.`, `cdn.` and `*.r2.cloudflarestorage.com`;
  - HSTS, COOP `same-origin`, `nosniff`, `no-referrer`, `noindex`.
- `docs/edge/console_origins.js`: one list of console origins for the
  functions — live 6 Nov in studio v51, ingest v52, transcode v27 and
  probe-media v26. Their claims and ticks answered 200, and studio, booted
  locally, answers the new origin's preflight and refuses `evil.example`. `STUDIO_ORIGINS` can
  only add to it. The stream Worker's `STUDIO_ORIGINS` gains the new
  origin.
- `tool/js/console_build_test.mjs`, 20 checks, in Chromium under the real
  header:
  - every import resolves inside the bundle;
  - no violation on load, and the module Service Worker registers;
  - the four hosts are allowed, and `evil.example` is refused.
  The bundle was also built from `main`'s tree, whose console seals
  nothing.
- **Owner:**
  1. Create the Worker from the repository (root `docs/console`).
  2. Limit the zone's WAF rules to `stream.`.
  3. Add the Supabase redirect URL.
  4. Sign in there.
  `docs/console` and the Worker line are on `main` since 6 Nov
  (b6fc0d0, docs only; Playback check 42208213495 passed after the
  Worker's redeploy).
- **On, 6 Nov.** The owner did all four steps. The Worker built from
  `main` (Workers Builds) with workers.dev off. The zone's custom rules
  were already limited to `stream.`; the rate-limiting rule matches only
  `/v/`. The redirect URL was added and the owner signed in with Google
  and the authenticator code; the Dashboard loads. Transport check
  42211630577 (section 9) asked the live origin: `/` answers 302 to
  `/studio/`, the console answers 200 with the strict CSP header, HSTS,
  COOP, `nosniff` and no referrer, and `/edge/studio.ts`, a migration,
  `BACKLOG.md` and `console/wrangler.toml` answer 404.
- **Next:** retire the Pages copy after a week of use (from 13 Nov), as
  the README's "Afterwards" says. **13 Nov: not yet.** Proven on the new
  origin: sign-in with the authenticator code (6 Nov), the Dashboard and
  Review (6 Nov approvals; 13 Nov 09:40 a session refresh and a full
  Dashboard load, all 200), previews and the speed test (the stream Worker
  answers the origin). NOT proven: an upload — it goes from the page to R2
  directly, and the buckets' CORS policy as recorded names only the Pages
  origin; the 6 Nov steps did not change it. The owner adds the console
  origin to both buckets' policy and one upload works there; then the
  retirement (code ready to write in a few lines; its deploy and ship on
  the owner's word).

**P5 — the accounts (owner; no code).** Use passkeys or security keys on
GitHub, Cloudflare, Supabase and Google, with no SMS fallback. Turn on
Telegram two-step verification. Review GitHub sessions and tokens:
`GH_DISPATCH_TOKEN` should be fine-grained, expiring and limited to
Actions. Give Cloudflare API tokens the narrowest scope. On GitHub: a
ruleset on `main` blocking force-push and deletion; secret scanning with
push protection; Dependabot alerts; and CodeQL default setup, all free for
public repos. Repeat this review every quarter, as if the attacker had the
source.

**P6 — the honest defence against fake reports.** Complaints should come
to us first, and be answered.
- **Built 6 Nov.** The takedown address is **innocentmail69@gmail.com**,
  given by the owner. It is kept in one place (`kTakedownEmail`) and in the
  owner's notices.
  - **App** (released in 1.64.80, 6 Nov): About → "Copyright & takedown" says who to
    write to and what to include, with the address copyable. Every
    title's page has a Report flag with five reasons: copyright, illegal,
    someone under 18, someone who did not consent, something else. It
    takes words and an optional contact, in all three languages.
    `test/content_report_test.dart`, 8 tests.
  - **Server** (migration 076, live). `report_content()` is open to the
    app, 5 a day per phone, 20 per network, 200 in all. It keeps the
    report, a contact only if given, and who sent it only as hashes.
    `report_notice()` sends each report to the owner in Telegram once, on
    the next ingest tick (ingest v51). `tool/sql/content_reports_test.sql`
    passed on live, rolled back, as anon and as authenticated.
- **The owner, on each report:**
  - take down what should not be here (unpublish in the console);
  - answer from the address;
  - keep a rights record for every title (a licence, or the performers'
    consent). That record is what lets a valid counter-notice (17 U.S.C.
    §512(g)) restore something removed by mistake.
  - `admin_audit` stays the record of who uploaded what.
- **Not built:** a Reports page in the console (Telegram carries every
  report for now) and a download page for the APK (there is none: the
  APK's address comes from the release row). Both are recorded.

**P7 — tidy.**
- **The schema map (S8): closed, 6 Nov.** The transport check now asks
  `/rest/v1/` and GraphQL introspection as a stranger with the publishable
  key, and fails if either lists the schema (section 8 of
  `transport_check.py`). Run 42177384203: `/rest/v1/` answers 401 (Supabase's
  change is live), GraphQL lists nothing, and the report door answers the
  app (`"bad"` for an unknown reason, so the probe writes nothing).
- **Owner, Data API settings:** turn off "expose new tables
  automatically", so a table made later is private until granted.
- **Files → Scan** (also BACKLOG R2): the R2 inventory was last read on
  2 Oct.
- **`claim_anonymous_history` (S10): accepted, with the reason.** It moves
  an install's anonymous views and age consent to the account that names
  that install's id. The server cannot tell "the calling install" from
  anyone who knows the id, because the id is the install's only
  credential. That is the same as any bearer token, and the right
  protection is the one in place: the id is never shown (the player's code
  is a hash of it), never logged in the clear (budgets and the Worker keep
  hashes), and only ever sent over TLS. A rule such as "only an install
  registered to this account" would refuse every free viewer, since
  `devices` holds only premium installs. Revisit if install ids ever reach
  a screen or a log.

## Sources

* Supabase: [migrating to publishable and secret keys](https://supabase.com/docs/guides/getting-started/migrating-to-new-api-keys)
  (legacy keys retired by end of 2026; Edge `SUPABASE_SECRET_KEYS`; secret
  keys are not JWTs), [API keys](https://supabase.com/docs/guides/api/api-keys),
  [rotating legacy secrets](https://supabase.com/kb/troubleshooting/rotating-anon-service-and-jwt-secrets-1Jq6yd),
  [OpenAPI spec no longer served to the anon key](https://supabase.com/changelog/42949-breaking-change-removing-access-to-openapi-spec-via-the-anon-key),
  [hardening the Data API](https://supabase.com/docs/guides/database/hardening-data-api).
* Android key attestation: [developer guide](https://developer.android.com/preview/features/key-attestation);
  root change 2026 ([Bayton](https://bayton.org/android/android-enterprise-faq/key-attestation-root-certificate-change/),
  [protectt.ai](https://protectt.ai/blog/android-key-attestation-root-certificate-rotation)).
* Cloudflare: Free plan WAF and bot settings ([custom rules](https://developers.cloudflare.com/bots/additional-configurations/custom-rules),
  [WAF get started](https://developers.cloudflare.com/waf/get-started));
  abuse handling and counter-notices ([H2 2025 transparency report](https://cfl.re/h2-2025-transparency-report-abuse),
  [complaint types](https://developers.cloudflare.com/fundamentals/reference/report-abuse/)).
* GitHub Pages shares one origin per account: [what is GitHub Pages](https://docs.github.com/en/enterprise-server@3.16/pages/getting-started-with-github-pages/what-is-github-pages),
  [a worked example of shared localStorage](https://github.com/TomasHubelbauer/github-pages-local-storage).
