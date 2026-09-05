# The Movies operating plan — one phone, one operator

**v2, 30 Aug 2026.** Expanded from v1 with a simplification pass: what can be
*removed* from the design, what vendor tooling replaces hand-written glue, and
what each remaining piece costs in money and in minutes per week.

It sits beside `movies_execution_plan.md` and answers the question the other
documents assume away: **who runs this, and on what machine.**

> **Read `START_HERE.md` and `phase1_simple_plan.md` first.** This document
> describes the *finished* system. Phase 1 deliberately does less: no HLS, no
> AES, no GitHub Actions for media, no Cloudflare Worker, no domain. Where the
> two disagree, phase 1 wins until the first hundred titles are live.

| Read this when | Read instead |
|---|---|
| You need to know what to press, and where | this file |
| You need the stage-by-stage build order | `movies_execution_plan.md` |
| You need the list of what is missing | `movies_gaps.md` |
| You need the numbers | `movies_capacity_model.md` |
| You need the security rules | `premium_backend_spec.md` |

---

## 0. The constraint that changes the plan

**The operator has a phone. No desktop, no terminal.** Flutter builds happen in
FlutLab in a browser; everything else has to happen in a browser, in Telegram,
or not at all.

Every other document quietly assumes a laptop: `curl` for the gates, `psql` for
the schema, `ffmpeg` for packaging, `wrangler` for the Worker, `pg_dump` for the
backup. None of those exist here.

**The rule that resolves it:**

> Every command becomes a **file in the repo** and a **button in GitHub
> Actions**.

Two things follow, and the second matters more.

1. A phone is bad at typing and fine at tapping. Buttons fit the hardware.
2. **The repo becomes the memory.** Three months from now, "what was the command
   for that?" has an answer that is checked in, versioned and re-runnable —
   the only documentation a one-person operation reliably keeps.

---

## 1. The Stage-0 decisions, resolved

### 1.1 Auth — option C′: phone identity, no SMS, no email delivery

`movies_execution_plan.md` §0.1 recommends option C (email + password) on the
grounds that it costs nothing and never fails to deliver. **Half true. The
missing half was checked.**

Supabase's built-in mail server delivers **only to addresses on the project
team**, refusing everything else, and is rate-limited to roughly **two messages
per hour project-wide** across confirmations, resets and invites [R1][R2]. It is
a testing facility. Plain email + password with confirmations on does not work
without a custom SMTP provider — a second vendor, a domain, and SPF/DKIM
records.

**C′ deletes the mail server from the design:**

| Element | Choice |
|---|---|
| What the user types | **their phone number** — matches KPay, familiar in MM |
| Stored in Supabase as | `09xxxxxxxxx@mm.<owned-domain>`, synthetic, never displayed |
| Secret | a password the user sets |
| Email confirmation | **off.** Supabase then implicitly confirms the address in the database and sends nothing [R3] |
| SMS | none, ever |
| Cost | **$0**, with no delivery step that can fail |
| Password reset | operator, via the admin bot; proof is the KPay transaction id they paid with |
| Abuse control | Cloudflare Turnstile on sign-up + Supabase auth rate limits |

**Why not Supabase anonymous sign-ins**, which look like a smoother on-ramp:
converting an anonymous user to a permanent one with a password requires the
email or phone to be **verified first** [R4] — reintroducing the exact delivery
step this design exists to avoid. The app already has the better answer:
`x-install-id` with `claimAnonymousHistory()` at sign-in. **Keep it.**

### 1.2 Age — DOB entry + stored consent + geo-gate

Declaration alone is weak; a verification provider costs money and conversion.
The middle is a date-of-birth entry stored through `record_age_consent`,
attributed to `auth.uid()` or `x-install-id`.

**Geo-gating is the half nobody wrote down.** Several jurisdictions now require
real age assurance for this content. Serving only the countries actually being
served shrinks that exposure to nearly nothing, costs zero, and is three lines
wherever the grant is minted. If the market widens later, the decision gets
revisited deliberately rather than by accident.

### 1.3 Two setup choices that cannot be undone later

* **Supabase region: Singapore.** The nearest region to Myanmar, and the region
  cannot be changed after the project is created without migrating everything.
* **Two repos, not one.** `innocent-ops` (private) holds `supabase/`, `worker/`
  and the workflows, and is the only place the service-role key exists. The
  Flutter app stays exactly where it is, in FlutLab, unchanged. Mixing them puts
  app code in a repo with production secrets for no benefit.

---

## 2. The journey, for every kind of user

```
install APK  →  age gate (DOB)  →  browse as ANONYMOUS
                                    posters, titles, synopsis, counts
                                    3 stills, 1 marked preview clip
                                    everything else visible but LOCKED
      ↓ taps a locked title
   paywall sheet: what VIP costs, what it unlocks
      ↓ sign up: phone + password. No SMS. No email. No wait.
   REGISTERED: watchlist, synced history, 5 stills.
               History carried over from the anonymous install id.
      ↓ pays with KPay, outside the app
   submits transaction id + sending number  →  "submitted, under review"
      ↓ operator sees it within seconds (bot notification)
   /approve <id> <months>  →  one transaction writes the subscription
      ↓ app re-checks entitlement on resume, shows an approved banner
   PREMIUM: playback, full album, download, >480p, 2 concurrent streams
```

| Friction | Answer |
|---|---|
| Sign-up can fail (no OTP arrives) | removed — nothing is delivered to anyone |
| The wait after paying | bot notification makes it minutes; the app says "under review", never "you are premium" |
| New phone, old device holds the slot | `AccessDenial.wrongDevice` → self-service release, once, 14-day cooldown, visible date |
| Forgot password | operator reset; proof is the KPay transaction id, which only the payer knows |

---

## 3. The operating surface

| Cadence | Where | What | Time |
|---|---|---|---|
| Daily | **Telegram** | `/pending` → `/approve` (~4/day at month 9) | 2 min |
| Per title | Telegram + GitHub | upload master, forward to archive #2, tap **Run workflow** | 1 min |
| Weekly | Telegram | confirm the backup file arrived | 1 min |
| Monthly | Cloudflare + Supabase | the bill, R2 Class B, and the egress line in §5.2 | 2 min |
| On demand | Telegram | `/takedown`, `/device`, `/reject` | 1 min |
| Per release | FlutLab + GitHub | build APK → `release.yml` | — |

**Daily operations are one app.** That is the test of whether one person on a
phone can run this, and it passes.

---

## 4. The machine — vendor tooling, not hand-written glue

Everything below is the vendor's own documented path. Hand-rolled equivalents
were considered and rejected: they are more code, and code is the thing that has
to be maintained from a phone.

```
innocent-ops/
  supabase/
    migrations/    20260901000000_titles.sql, …_rls.sql, …_subs_devices.sql
    functions/     request-playback/  admin-bot/  record-age-consent/
    config.toml
  worker/          index.js        (phase 2 only — see §5)
  .github/workflows/
    migrate.yml       supabase db push                     [R5]
    deploy.yml        supabase functions deploy            [R6]
    gate.yml          every curl gate, prints PASS / FAIL
    keepwarm.yml      one REST call every 3 days           [R7]
    backup.yml        pg_dump → Telegram, weekly
    restore-test.yml  restore into a scratch project (once)
    package.yml       master → HLS+AES → R2 → row + key
    release.yml       APK + version.json + sha256 → public bucket
```

**Migrations and function deploys use the Supabase CLI inside Actions** —
`supabase/setup-cli@v1`, then `supabase db push` and `supabase functions deploy
--project-ref $PROJECT_ID`, with `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`
and `SUPABASE_PROJECT_ID` as encrypted secrets [R5][R6]. This is Supabase's own
recommended CI/CD shape, it tracks which migrations have already run, and it is
about eight lines per workflow.

**Secrets** live in GitHub Secrets and the two dashboards. Nowhere else — not in
a note app, not in a chat message, not in a workflow `echo`.

The one interactive step Actions cannot do is generating `TG_SESSION` for
Telethon. Do it once in **Google Colab**, which runs in a phone browser, and
paste the string into Secrets.

---

## 5. The simplification pass — what can be deleted

### 5.1 The Cloudflare Worker is not needed to launch

This is the largest single reduction available, and it rests on one verified
fact: **R2 presigned URLs are generated entirely client-side, with no call to
R2, from the API credentials plus a SigV4 implementation, with an expiry from
one second to seven days** [R8].

So the Supabase Edge Function — which already makes the authorization decision —
can sign the segment URLs itself. Nothing has to run at Cloudflare's edge for
the design to work.

```
PHASE 1  (launch)                        PHASE 2  (when §5.2 triggers)
app → EF /playback                        app → EF /playback
      JWT, status, device, subscription         the same checks
      signs 90 segment URLs itself              returns a Worker URL + token
      returns the .m3u8                   app → Worker /p → signs, returns .m3u8
app → EF /key?t=…  → 16 bytes             app → Worker /k → 16 bytes
app → R2 direct, 90 segments              app → R2 direct, 90 segments
```

| | Phase 1 (no Worker) | Phase 2 (Worker) |
|---|---|---|
| Platforms to deploy to | **1** (Supabase) | 2 |
| Extra secrets | none | `CF_API_TOKEN` |
| Supabase egress per view | ~36 KB (the playlist) | ~1 KB |
| Cloudflare egress | — | free, unlimited |
| Edge Function calls per view | 2 of 500,000/month | 1 |
| Security | identical — segments are AES-encrypted either way | identical |

**Phase 1 is not weaker.** "Supabase decides, the Worker enforces" existed to
keep entitlement logic off the edge; with no edge, there is nothing to keep it
off. The segments are ciphertext in both designs, the key is a live
authorization decision in both, and the app never learns where bytes come from —
which is exactly why the switch is reversible.

### 5.2 The trigger for Phase 2, written down now

Supabase's free tier allows **5 GB of egress a month**, and
`movies_capacity_model.md` already names it the binding limit. Phase 1 spends
the playlist against it:

```
60,000 views/month × 36 KB                        ≈  2.2 GB
+ catalogue JSON, narrow selects and hard paging  ≈  1.0 GB
                                                  ≈  3.2 GB of 5 GB
```

> **Add the Worker when Supabase egress passes 3 GB in a month.** Check it once
> a month, at the same time as the Cloudflare bill.

Write `worker/index.js` in advance and leave it undeployed. When the trigger
fires the change is: deploy the Worker, change one URL in one Edge Function.
Not a redesign — a switch built waiting to be flipped.

### 5.3 What NOT to build

For a solo operator on a phone, each of these looks necessary and is not:

* **No staging project.** The free tier pauses inactive projects, so the staging
  copy will be asleep exactly when it is needed. One project; `gate.yml` is the
  safety net.
* **No local dev, no Docker, no wrangler.** Nothing that requires a machine.
* **No admin dashboard.** The Telegram bot is the console.
* **No push notifications at launch.** Re-check entitlement on app resume; FCM
  is a native change and can wait.
* **No Cloudflare Images or Stream.** Both cost money and solve problems this
  design does not have.
* **No monitoring stack.** A `play_failures` table and a weekly glance.
* **No second payment integration.** Manual KPay approval is four minutes a day
  at month-9 scale and needs no code.

Every line above is a week not spent.

---

## 6. Gaps this document adds

Numbered on from `movies_gaps.md`.

**#14 — A domain is a hard requirement.** Three things need it and no document
says so: the public bucket's custom domain (`r2.dev` is rate-limited and not for
production), the Worker route in phase 2, and the synthetic email domain in
§1.1, which must be a domain actually owned. ~$10/year at Cloudflare Registrar.

**#15 — A free Supabase project pauses after ~7 days of inactivity** [R7]. The
backup is weekly, exactly at the boundary. `keepwarm.yml` on a three-day cron
making one authenticated REST call removes a failure whose symptom is "it
stopped working and I changed nothing".

**#16 — Nothing tells the user their payment was approved.** Re-check
entitlement on app resume and show an approved banner. No new dependency.

**#17 — Sign-up abuse, now that confirmations are off.** Turnstile on the
sign-up call plus Supabase's auth rate limits.

**#18 — `version.json` must not be cached long.** A long TTL means the forced
security update is served from cache to the people who most need it.
`Cache-Control: max-age=60` on that object; the APK itself can cache for a year.

**#19 — Do not re-encode in the packaging workflow.** `movies_execution_plan.md`
§7.3 specifies `libx264 -crf 23`; most masters here are already H.264.
`-c copy -hls_time 10` segments and encrypts without transcoding: seconds
instead of minutes, no quality loss, and GitHub's 2,000 free private-repo
minutes per month [R9] stop being a constraint. Ten-second segments also cut R2
Class B operations by 40%. Re-encode only when the master is oversized.

**#20 — A credential map, not the credentials.** One page listing where each key
lives and what it unlocks. A one-person operation with keys across four
dashboards and no index is one lost phone from an outage nobody can diagnose.

**#21 — Per-title licence records.** Cloudflare and Supabase both permit legal
adult content; both draw an absolute line at CSAM and non-consensual imagery.
The record is what makes "legal" demonstrable rather than asserted.

**#22 — The second archive costs two taps, not a second upload.** Telegram
**forwarding does not re-upload the file** — it references the same stored
object. So "upload the master, then forward it to the second channel on the
second account" adds seconds and no data. This is the one unrecoverable risk in
the whole runbook (`movies_execution_plan.md` §10.1), and it is nearly free to
close.

**#23 — Masters must stay under 2 GB.** Telegram allows 2 GB per file free and
4 GB with Premium [R10]. At 15–30 minutes and 720p this is not close, but a
1080p master can pass it. Down-encode at ingest rather than paying $4.99/month
for headroom a `-vf scale` line removes.

**#24 — Generate two poster sizes at ingest.** One extra `ffmpeg` line produces
a 300 px grid poster and an 800 px detail poster. The grid is what loads twenty
at a time on mobile data; shipping the large one there costs the user money and
the project Class B operations.

---

## 7. The ledger — money and minutes

**Money, year one:**

| Item | Cost |
|---|---|
| Domain | ~$10/year |
| Supabase | $0 (free tier, Singapore) |
| R2 storage | $0 to 10 GB, then $0.015/GB-month → ~$1.75/month at 125 GB |
| R2 egress | **$0 at any volume** |
| Cloudflare Workers | $0 (phase 1: none; phase 2: free tier) |
| GitHub Actions | $0 (2,000 private minutes/month; `-c copy` uses ~1 per title) |
| Telegram | $0 |
| **Year-one total** | **~$30** |

The card on file exists for R2's billing requirement and for the day storage
crosses the free allowance, not because anything is being bought.

**Minutes per week at month-9 scale:** approvals ~14, ingest ~10, backup check
~1, monthly checks amortised ~1. **Under half an hour a week.** That number is
what the whole design optimises, and it is why §5.3 matters more than any
feature in this repo.

---

## 8. Long-run verdict

**The architecture holds. The operating model was the missing half.** What binds
first, in order:

| At scale | First to bind | Answer |
|---|---|---|
| 10× browsing | **Supabase egress, 5 GB/month** | narrow selects, hard paging, disk image cache (C6), posters from R2 only |
| 10× views | Supabase egress again (phase-1 playlists) | the §5.2 trigger — add the Worker |
| 10× views after that | R2 Class B operations | 10 s segments already halve it; then $0.36/M |
| 10× premium users | approvals per day | `/approve` batch mode |
| Any scale | **the operator** | this is the real limit |

The one genuine single point of failure is **the person**. Telegram survives R2;
R2 survives Cloudflare; the backup survives Supabase. Nothing survives the
operator being unavailable for two weeks — which is why the credential map and
"every command is a checked-in button" are not tidiness. They are the continuity
plan.

---

## 9. The revised order

```
0    decide auth + age  (§1 — done, in this file)          0 days
0.5  domain + innocent-ops repo + secrets                  1 day
     + migrate.yml + gate.yml + keepwarm.yml
1    green build: Analyzer → tool/check.py → Build         1 day
2    Supabase (Singapore): titles, RLS, revoke,            3 days
     3 rows, 3 RPCs — gate.yml proves it, not the app
3    point the app at it (--dart-define), fix mismatches   2 days
4    backup.yml + restore-test.yml                         ½ day
5    subs, requests, devices, admin bot + C1, C2, C3       6 days
6    updater (C4) + kill switch                            3 days
7    R2 ×2 + package.yml + playback EF, one title          4 days
     end to end — NO WORKER (§5.1)
8    offline downloads (C5)                                4 days
10   launch gates: age, support, telemetry, pricing,       3 days
     second archive, licence records
──── later, on the §5.2 trigger only ────
     worker/index.js + one URL change                      1 day
```

**Stage 9 no longer exists separately.** "Package three by hand, then automate"
cannot happen on a phone; the workflow *is* the hand step, run one title at a
time with the log read end to end. The principle it protected — never automate a
process you have not performed correctly — survives intact.

---

## 10. How to continue in a new chat

### 10.1 Always say these four things

1. Which **stage** you are on, from §9.
2. What **succeeded last** (the gate that passed, the build that ran).
3. What you want **out of this session** — one deliverable, not three.
4. **"Phone only. No terminal. Everything must be a repo file or a dashboard
   step."**

### 10.2 Backend session

> Innocent Movies — Stage 0.5/2. Attached: `movies_operating_plan.md`,
> `movies_execution_plan.md`, `client_api_contract.md`.
> Auth = C′, age = DOB + consent + geo-gate, Supabase region Singapore, ops repo
> separate from the app, **no Cloudflare Worker in phase 1** — all per the
> operating plan.
> Phone only, no terminal.
> Today I want: `supabase/migrations/*.sql` + `migrate.yml` + `gate.yml` +
> `keepwarm.yml`, ready to paste, and the tap-by-tap for the Supabase and GitHub
> screens.

### 10.3 Client session

> Innocent v1.59.2+301 attached. Stage 5 client work.
> One zip containing: C2 (`DeviceIdentity` → `flutter_secure_storage`, migrating
> the old SharedPreferences value once), C3 (`AccessDenial.wrongDevice` +
> device-switch screen), C6 (`cached_network_image` in `PosterImage`).
> Follow the pre-zip gate in `docs/maintenance.md` and `tool/README.md`:
> Analyzer, then `python3 tool/check.py`, then bump `app_version.dart` +
> `pubspec.yaml` + the README changelog.

### 10.4 Delivery session

> Innocent Movies — Stage 7. Attached: `movies_operating_plan.md`,
> `movies_capacity_model.md`, `premium_backend_spec.md`.
> Design is fixed: encrypted HLS in a private bucket, per-segment **presigned**
> URLs direct from R2, signed **inside the Supabase Edge Function** — no Worker
> in phase 1. Do not propose proxy streaming.
> Today I want: the `request-playback` function including SigV4 presigning, and
> `package.yml` using `-c copy`, 10-second segments and two poster sizes.

### 10.5 The standing rules

* **Supabase decides. R2 stores. Telegram archives.** (Phase 2 adds: the Worker
  enforces.) Nothing does two of those jobs.
* **Never send a permission. Send a capability.**
* **Test with `gate.yml`, as a free account. The app is not the attacker.**
* **A stage is done when its gate passes, not when the code is written.**
* **Every command is a repo file and a button.**
* **The cheapest feature is the one deleted in §5.3.**

---

## 11. References

The load-bearing external facts in this document, with sources, so a future
reader can re-check them rather than trust them.

| | Claim | Source |
|---|---|---|
| R1 | Supabase's built-in SMTP sends only to project-team addresses; custom SMTP is required for production | `supabase.com/docs/guides/auth/auth-smtp` |
| R2 | Built-in mail is rate-limited (~2/hour project-wide); 30/hour default after enabling custom SMTP | same, plus `supabase.com/docs/guides/deployment/going-into-prod` |
| R3 | With Confirm Email disabled, Supabase implicitly confirms the address in the database | `supabase.com/docs/guides/auth/general-configuration` |
| R4 | Converting an anonymous user to permanent with a password requires a verified email or phone | `supabase.com/docs/guides/auth/auth-anonymous` |
| R5 | `supabase/setup-cli` + `db push` in GitHub Actions is the vendor's recommended CI/CD path | `supabase.com/docs/guides/deployment/managing-environments` |
| R6 | `supabase functions deploy --project-ref` in Actions deploys all Edge Functions at once | `supabase.com/docs/guides/functions/examples/github-actions` |
| R7 | Free-plan projects are paused after ~7 days of inactivity | `supabase.com/docs/guides/deployment/going-into-prod` |
| R8 | R2 presigned URLs are generated client-side with no call to R2; expiry 1 second to 7 days | `developers.cloudflare.com/r2/api/s3/presigned-urls/` |
| R9 | GitHub Free: 2,000 Actions minutes/month on private repos; unlimited on public | `docs.github.com/billing/managing-billing-for-github-actions` |
| R10 | Telegram: 2 GB per file free, 4 GB with Premium; the Bot API caps downloads at 20 MB, which is why ingest uses MTProto | Telegram limits and `core.telegram.org/bots/api#getfile` |
| R11 | Cloudflare removed §2.8 in May 2023; video hosted on R2 may be served through the CDN | `blog.cloudflare.com/updated-tos` |
| R12 | Workers Free: 100,000 requests/day, 10 ms CPU; Paid: $5/month including 10M requests | `developers.cloudflare.com/workers/platform/pricing/` |
| R13 | Verify JWTs at the edge with the public JWKS, never the shared secret | `supabase.com/docs/guides/auth/signing-keys` |
| R14 | `aws4fetch` is the Workers/Deno-compatible SigV4 implementation; the AWS SDK is not | Cloudflare R2 examples, `github.com/mhart/aws4fetch` |

---

## 12. Decision record

| Date | Decision | Why |
|---|---|---|
| 28 Aug 2026 | Not publishing on Play; own PayPal; in-app updater | Play bans this content outright |
| 28 Aug 2026 | Telegram + Supabase + R2 (+ Worker) | ~$2/month at month-9 volumes |
| 30 Aug 2026 | **Auth = C′** — phone identity, synthetic email, no SMS, no mail | the built-in mailer reaches team addresses only, ~2/hour; SMS is ~99% of the budget and unreliable to +95 |
| 30 Aug 2026 | **Age = DOB + consent record + geo-gate** | declaration is weak, a provider kills conversion; geo-gating removes most exposure for free |
| 30 Aug 2026 | **Keep `x-install-id`; no Supabase anonymous sign-ins** | anonymous → permanent with a password wants a verified email |
| 30 Aug 2026 | **Presigned direct-to-R2 segments; never proxy streaming** | 2 calls per view against 152; proxying forces the paid plan and protects nothing extra |
| 30 Aug 2026 | **Every command becomes a repo file + an Actions button** | the operator has a phone, and the repo is the only memory that survives |
| 30 Aug 2026 | **No Cloudflare Worker in phase 1**; add it when Supabase egress passes 3 GB/month | presigned URLs need no edge; one platform instead of two, and the switch is a URL change |
| 30 Aug 2026 | **Supabase region Singapore; ops repo separate from the app** | neither can be changed later without pain |
| 30 Aug 2026 | **Vendor CI/CD (`supabase db push`, `functions deploy`) over hand-written glue** | less code is less to maintain from a phone |
