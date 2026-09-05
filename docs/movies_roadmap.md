# The Movies build, in order

One page that ties together `premium_backend_spec.md` (the security rules),
`movies_access_plan.md` (tiers, protection, device binding),
`movies_platform_plan.md` (what was missing, which services) and
`movies_capacity_model.md` (the numbers). Written 28 Aug 2026.

Read this one for the reasoning. **Read `movies_execution_plan.md` when you are
about to do the work** — it holds the same order with the actual SQL, the exact
gates, and a client-side work queue.

---

## Part 0 — Decisions already made. Do not reopen these.

Each of these was researched and settled. Re-deciding them costs weeks.

| Decision | Why it is settled |
|---|---|
| **Not on Google Play** | Play's policy prohibits apps whose purpose is sexual content, regardless of licensing. Own APK, own updater |
| **Telegram is the archive, never the origin** | Bot API caps downloads at 20 MB; the download URL contains the bot token |
| **Supabase decides, never delivers** | 1 GB storage, 50 MB per file, 5 GB egress. Right for JSON, impossible for video |
| **Cloudflare R2 is the origin** | Zero egress at any volume, and Cloudflare's terms explicitly permit video hosted in R2 |
| **Three tiers, not more** | `anonymous < registered < premium`. Plan length is an attribute, not a tier |
| **HLS + AES-128, not signed MP4s** | A signed MP4 URL still downloads the whole file. HLS makes the KEY the capability |
| **The server sends a capability, never a permission** | There is no boolean for a proxy to flip |

### The two decisions that are NOT settled, and block the schema

Unlike the table above, these are open. Both change the database, so both come
before Phase 1.

| Open decision | Why it cannot wait |
|---|---|
| **How sign-in works** | Phone OTP needs a third-party SMS provider at ~$0.10 a verification — **$300-500 in year one against $2/month of infrastructure**, with unreliable delivery to +95 numbers. Email sign-in costs nothing, and a human already verifies the payer's number against the KPay statement at approval. Full comparison in `movies_execution_plan.md` §0.1 |
| **How far age verification goes** | Declaration, date-of-birth record, or a real provider. Legal question before a technical one, and the record of a deliberate choice is worth more than the mechanism |

---

## Part 1 — The order, and why it is this order

The rule behind the ordering: **do the things that are cheap now and impossible
later, first.** Everything else can be changed after launch.

```
Phase 1  Foundation ......... expensive to change later
Phase 2  Delivery ........... proves the money model
Phase 3  Enforcement ........ proves the business model
Phase 4  Offline ............ the feature people pay for
Phase 5  Automation ......... only after 3-4 done by hand
Phase 6  Launch gates ....... cannot launch without these
```

---

## Phase 1 — Foundation

### 1.1 Supabase auth + `titles` + RLS on every table

**How it works.** Every table in `public` gets RLS enabled and a policy. The
anon key ships inside the APK, so a table without a policy is a table the whole
internet can read.

**What it buys.** The paywall becomes a property of the database rather than a
property of the app. A patched APK gains nothing.

**Gate before moving on:** with `curl` and the anon key — not the app — try to
read `titles` as an anonymous caller. Premium rows must not come back, and no
`locator` may appear in any response.

> Most paywalls do not fail at the cryptography. They fail because a table was
> readable from the start.

### 1.2 The narrow catalogue query

**How it works.** `select=id,title,poster_url,min_tier`, 20 rows per page,
posters pointing at R2. The app caches and revalidates on `updated_at`.

**What it buys.** This is the one identified in the capacity model as **the
binding limit of the whole system**: 5,000 users browsing at 50 KB a session is
5 GB/month — 100% of Supabase's free egress, before any video plays. Narrow
rows plus caching bring the same traffic under 1 GB.

**Gate:** measure one page's response size. Over 10 KB means fix it now.

### 1.3 `min_tier` on titles AND on individual assets

**How it works.** Three values matching the three tiers. The server compares
the viewer's tier and **omits the locator entirely** for anything above it.

**What it buys.** A photo album can mix free previews with paid stills, and a
free account's raw JSON contains nothing it should not have. Not a hidden
button — an absent field.

---

## Phase 2 — Delivery

### 2.1 One clip, packaged by hand

```bash
openssl rand 16 > key.bin
ffmpeg -i master.mp4 -c:v libx264 -crf 23 -preset veryfast \
       -hls_time 6 -hls_key_info_file key_info -hls_playlist_type vod out.m3u8
```

**What it buys.** Proves the encode settings before automating them. 720p at
CRF 23 is what makes "125 GB for the year-one catalogue" true.

**Rule:** the key goes into Supabase, never into the bucket. A key stored next
to the segments it decrypts is not encryption; it is a filing convention.

### 2.2 Private R2 bucket + presigned URLs (and a second, public one)

**Two buckets.** `innocent-media` is private, presigned only, and holds the
encrypted segments. `innocent-public` sits on a custom domain and holds posters,
thumbnails, the updater JSON and the APK. A poster is not a secret and gating it
would cost a Worker call per card on a scrolling grid; a segment is, and has no
reason to own a permanent URL.


**What it buys.** No permanent URL exists anywhere. Nothing to paste into a
downloader, nothing to share.

**Gate:** an unsigned request must be refused; a signed one must work.

### 2.3 The playlist Worker and the key endpoint

**How it works.**

```
player → Worker /playlist   (1 request)  → checks the grant
                                         → returns .m3u8 with presigned URLs
player → R2 directly        (150 requests, 0 Workers)
player → Worker /key        (1 request)  → checks the grant → 16 raw bytes
```

**What it buys — two things at once.**

*Cost:* two Worker calls per view instead of 152. At month 9 that is 20,000
requests/month against an allowance of ~3,000,000. The obvious design
(proxy every segment) would have used 2M and forced a paid plan for nothing.

*Security:* the segments are encrypted, so a leaked segment URL is noise, and
a leaked key without URLs is useless. Gating the KEY rather than each segment
is both cheaper and no weaker.

### 2.4 Playback grant wired to `has_active_subscription`

**What it buys.** The rule from the security spec becomes real: **the server
never returns a playable URL to an account without an active subscription.**
Expiry now actually stops playback instead of hiding a button.

---

## Phase 3 — Enforcement

### 3.0 The client half of enforcement

Two small changes without which Phase 3 enforces nothing and cannot be reached.

**The device id must move to Keystore-backed storage.**
`device_identity.dart` still uses `SharedPreferences`, which "Clear data" wipes
— so the partial unique index below would guard an id any user can reset at
will. Half a day.

**`AccessDenial` needs a third value.** It has two, `needsPremium` and
`unavailable`, so a server 409 `wrong_device` renders as "unavailable": a paying
customer with a new phone sees an unexplained error and no route to the
self-service release. Add `wrongDevice` and the screen behind it, or 3.1 exists
and nobody reaches it.

### 3.1 The device slot

```sql
create unique index on public.devices (user_id) where released_at is null;
```

**How it works.** A partial unique index. Not a check inside a function that
someone forgets to call — **the database physically cannot hold two active
devices for one user.**

**What it buys.** One VIP account cannot be shared. With a 14-day cooldown on
releasing the slot, a shared account is useless to a group and barely
noticeable to someone who changed phones.

**The detail that decides whether it works at all:** the device id must live in
Keystore-backed storage, excluded from backup. In SharedPreferences, "Clear
data" frees the slot and the whole mechanism enforces nothing.

### 3.2 Subscriptions and plan lengths

**How it works.** One `plan_id` plus `expires_at`. 1 / 3 / 6 / 12 months are
four rows of config, not four tiers.

**What it buys.** Plan length never reaches the code that decides capability,
so no screen ever learns about billing. Adding a plan is a config change.

---

## Phase 4 — Offline downloads

**How it works — four properties, each closing one leak.**

| Property | Mechanism | What it stops |
|---|---|---|
| Bytes on disk already encrypted | Download the HLS segments as-is | There is never a plaintext file to find |
| Key never in the clear | Wrapped by an Android Keystore key | Copying app data to another phone yields an unopenable blob |
| App-private storage | `getFilesDir()`, not `/sdcard` | Other apps, USB and MTP see nothing |
| Licence expires | `expires_at` + revalidate within 30 days | "Subscribe one month, download everything, cancel" |

**The fifth thing, which the table above does not cover: how the player GETS the
key.** An HLS player reads it from the URI in the playlist, so writing it to
disk as a file would undo property 2 completely. The answer is a loopback HTTP
server serving a rewritten local playlist whose key URI points back at itself,
unwrapping from Keystore and returning the 16 bytes **from memory** — and
`stream_proxy.dart` in the downloader is already exactly that server. Settle
this design before writing the downloader, or the download completes and cannot
be played.

**What it buys.** YouTube's behaviour: it plays in the app, offline, and is
worthless anywhere else — which is the feature people actually pay for, on
mobile data in Myanmar especially.

**Stated honestly:** a rooted phone running a patched build can hook the app
after it unwraps the key. True of every non-DRM scheme and of Widevine L3 too.
The defence is that it takes a rooted phone, a patched APK and real skill —
a different population from people who right-click and save.

---

## Phase 5 — Automation

**GitHub Actions packaging.** Free: 2,000 minutes/month private, unlimited
public.

**What it buys.** Adding a title becomes: upload the master to Telegram, run
the workflow. No local machine, no manual ffmpeg, no chance of forgetting to
encrypt one.

**Do this only after 3–4 titles have gone through by hand.** Automating a
process you have not yet performed correctly automates the mistake.

---

## Phase 6 — Cannot launch without these

### 6.1 The in-app updater

**What it buys.** Outside Play there is no other way to ship a fix, and **the
first urgent fix will be a security fix.** An app with no update path is one
bug away from being unrecoverable.

### 6.2 The age gate, done properly

**What it buys.** Legal exposure, and it is your responsibility now that Play
is not doing it. The existing versioned-consent gate is the right shape; decide
deliberately how far it goes — declaration only, or real verification.

### 6.3 A second copy of the Telegram archive

**What it buys.** Telegram is the backstop for R2, for Cloudflare, and for the
payment method. **It has no backstop of its own.** A second channel, a second
account, or a cold copy on a drive.

Every other failure in the runbook is recoverable *because* the masters exist.
This is the one row in that table that says "unrecoverable".

### 6.4 A backup payment method on Cloudflare

**What it buys.** A failed charge suspends R2 access — requests error while the
data itself stays intact — and after **30 days the data may be deleted**.
Cloudflare retries a backup method automatically. Two minutes of work against a
catalogue outage.

**VERIFIED 28 Aug 2026:** Cloudflare allows **two payment methods per account**
and accepts **PayPal** alongside Visa, Mastercard, Amex, Discover, Apple Pay,
Google Pay, Stripe Link and UnionPay. So this gate is achievable exactly as
written, with the PayPal being opened as primary and anything else as backup.
Note also that R2 requires billing information to activate **even inside the
free allowance**, and some users report a **$5 charge at activation**.

---

## Part 2 — What each piece is worth, at a glance

| Piece | Without it | With it |
|---|---|---|
| RLS on every table | The catalogue is public to anyone with the APK | The paywall is a database property |
| Narrow catalogue | 5 GB egress gone in month 9 on browsing alone | Under 1 GB, same traffic |
| `min_tier` per asset | A free account's JSON contains premium locators | The field is absent, not hidden |
| Private R2 + presigning | A permanent URL exists and will be shared | Nothing to paste anywhere |
| HLS + AES | A signed URL still yields the whole file | The key is the capability, and it expires |
| Worker gates the key, not segments | 2M Worker calls/month, paid plan needed | 20,000 calls/month, free |
| Server-side grant | A patched APK walks through the paywall | The bytes are simply not obtainable |
| Device slot | One VIP account serves a whole group | One account, one phone, 14-day switch |
| Encrypted offline files | A downloaded film is a shareable file | An unopenable blob off the device |
| In-app updater | No way to ship a security fix | A fix reaches users in a day |
| Telegram second copy | One account loss ends the platform | Every other failure is a re-package |

---

## Part 3 — The money, for the whole first year

| | Month 2 | Month 9 |
|---|---|---|
| App users / registered / premium | 1,000 / 100 / 40 | 5,000 / 2,500 / 1,000 |
| R2 storage | ~20 GB → $0.30 | ~125 GB → **$1.88** |
| R2 egress | ~80 GB → **$0** | ~2 TB → **$0** |
| Workers, Supabase, Telegram, Actions | $0 | $0 |
| **Infrastructure total** | **under $1** | **about $2** |
| SMS auth, if phone OTP | ~$2 | **$25-45** |
| SMS auth, if email sign-in | $0 | **$0** |

The 2 TB of egress at month 9 would cost roughly **$180/month on AWS S3**.
That single line is why the stack is shaped this way.

And the two rows beneath the total are why the auth decision belongs before
Phase 1: a delivery stack built to avoid a $180 bill is not much of an
achievement if the login spends fifteen times the infrastructure cost every
month to verify a phone number a human re-verifies by hand at approval.

---

## Part 4 — The three sentences to remember

> **Supabase decides. R2 stores. The Worker enforces. Telegram archives.
> Nothing does two of those jobs.**

> **Never send a permission. Send a capability.**

> **The video is the cheap part. The catalogue is the expensive part — and
> until the auth decision is made, so is the login.**
