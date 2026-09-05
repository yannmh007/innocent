# Movies — access tiers, content protection, and a zero-cost backend

Researched 28 Aug 2026. This is a PLAN, not an implementation. Read it with
`premium_backend_spec.md`, which already covers the capability-vs-permission
rule, the schema and RLS; this document answers the questions that one leaves
open: how many tiers, where the bytes live, how offline downloads are
protected, and how one account is held to one device.

---

## 0. Two findings that decide the architecture

Everything below follows from these. Both contradict an assumption in the
current plan, so they come first.

### 0a. Telegram cannot serve the video

Telegram is fine for *storing* masters and for an admin upload workflow. It
cannot be the playback origin:

* **The Bot API downloads at most 20 MB per file.** A movie is 30–100× that.
  Raising the limit to 2 GB requires running a *local Bot API server*, which is
  a server you must host and pay for — the thing this project is trying to
  avoid.
* **The download URL embeds the bot token** (`.../file/bot<TOKEN>/<path>`).
  Handing that to a client hands over full control of the bot. It can never be
  given to the app, so every byte would have to be proxied.
* Even via a local server, `getFile` must pull the WHOLE file to that server's
  disk before a single byte is served. Seeking in a 90-minute film means doing
  that repeatedly.

So Telegram stays as the archive and the ingest path. It is not the CDN.

### 0b. Supabase cannot serve the video either

Free tier: **1 GB total storage, 50 MB max file size, 5 GB egress per month.**
Two 700 MB films would exhaust the egress for the month. Supabase is the right
tool for auth, metadata and the authorization decision — and only those.

### The consequence

Media bytes need an origin with **large storage and free egress**. That points
at Cloudflare R2: 10 GB storage, 1M writes, 10M reads per month, and **zero
egress charges at any volume**, paired with Workers (100K requests/day) for the
signing and gating logic.

| Layer | Service | Free allowance | Why it, and not the alternative |
|---|---|---|---|
| Identity + subscriptions | Supabase Auth + Postgres | 50K MAU, 500 MB DB | RLS makes the rules enforceable in the database, not in code |
| Authorization decision | Supabase Edge Functions | 500K invocations/mo | Sits next to the data it must check |
| Media bytes | Cloudflare R2 (**two buckets** - see below) | 10 GB, zero egress | Egress is the cost that kills every other option |
| Signing + key delivery | Cloudflare Workers | 100K req/day | Runs at the edge, in front of R2, for ~1ms |
| Masters + ingest | Telegram | effectively unlimited | Free archive; never touched at playback time |

**10 GB is roughly 30–35 films at a well-encoded 720p (~300 MB).** That is the
real ceiling of the free tier and it should shape the catalogue plan. When it
is reached, R2 is $0.015/GB/month — 100 GB is about $1.50, still with no egress
charge.

### Two buckets, not one

This document says the media bucket must never be public. `movies_dataflow.md`
says posters live on a public path. Both are right, and together they mean
**two buckets**:

| Bucket | Access | Holds |
|---|---|---|
| `innocent-media` | **private**, presigned URLs only | encrypted HLS segments |
| `innocent-public` | public custom domain | posters, thumbnails, updater JSON, the APK |

A poster is not a secret and gating it would cost a Worker call per card on a
scrolling grid. A segment is, and has no reason to own a permanent URL. Setting
this up now is minutes; splitting them after locators are stored is not.

> **VERIFIED 28 Aug 2026 — this question is now answered.** Enabling R2 does
> require billing information on the Cloudflare account even while usage stays
> inside the free allowance. **Cloudflare accepts PayPal** (alongside Visa,
> Mastercard, Amex, Discover, Apple Pay, Google Pay, Stripe Link and UnionPay)
> and allows **two payment methods per account**, so the PayPal being opened
> works and the backup-method launch gate is a real feature rather than a hope.
> There are user reports of a **$5 charge at activation** — read the
> confirmation screen before agreeing. Supabase itself does not require a card.
> If a card ever becomes unacceptable, the fallback is Backblaze B2 behind
> Cloudflare's CDN, which is more moving parts for the same result.
>
> **What happens if the payment method fails:** R2 access is suspended and
> requests return errors while the data itself stays intact; after **30 days it
> may be deleted**. That is precisely why every master lives in Telegram — a
> lost R2 is a re-package, not a loss.

---

## 1. Tiers — three, not more

The question was whether more than three are needed. **No.** Three tiers with
two orthogonal attributes covers every case, and every extra tier multiplies
the combinations that have to be tested.

```
anonymous  <  registered  <  premium
```

What people reach for as "more tiers" is better modelled as attributes:

| Wanted | Do NOT make it a tier | Model it as |
|---|---|---|
| 1 / 3 / 6 / 12-month plans | four premium tiers | one `plan_id` + `expires_at` on the subscription |
| Free trial | a `trial` tier | a subscription row with `source='trial'` |
| Just-expired grace period | an `expired` tier | `expires_at + grace_days` in the check |
| Banned user | a tier | a `blocked_at` column checked before anything else |
| Early access for supporters | a tier | a per-title `min_tier` override |

The rule: **a tier answers "how much may this person see". Anything answering
"for how long", "why", or "which title" is an attribute.** Plan length changes
nothing about capability, so it must not be encoded in the thing that decides
capability — otherwise every screen learns about billing.

### Content tagging

Tagging lives on the asset, not just the title, so an album can mix free
previews with paid stills:

```sql
alter table public.titles     add column min_tier text not null default 'free';
alter table public.media_assets add column min_tier text not null default 'free';
-- 'public'    : visible to anonymous
-- 'free'      : requires a registered account
-- 'premium'   : requires an active subscription
```

Three values, matching the three tiers. The server compares the viewer's tier
against `min_tier` and **omits the locator entirely** for anything above it —
it does not send a locked flag and trust the client to hide it.

---

## 2. Stream protection — what is achievable and what is not

### Say the honest thing first

`premium_backend_spec.md` already states it: **if a device can play it, a
device can copy it.** Studio-grade protection means Widevine L1 with a licence
server, which is neither free nor available without a Google licence
agreement. Nothing in this plan achieves that, and any plan claiming it does is
wrong.

What IS achievable at zero cost is to close every cheap path, so copying stops
being something a normal person can do with a browser extension:

| Attack | Cost today | Cost after this plan |
|---|---|---|
| Paste the URL into IDM / a downloader | seconds | impossible — no URL exists to paste |
| Share a link with a friend | seconds | it dies in minutes and is bound to one account |
| Pull the file off the phone | minutes | encrypted segments; key is not on disk |
| Sniff the traffic and save the stream | hours | segments are AES-encrypted end to end |
| Screen-record | minutes | blocked by FLAG_SECURE on most devices |
| Point a camera at the screen | minutes | **nothing stops this. Accept it.** |

### The mechanism: HLS + AES-128, with the key as the capability

1. **Package each premium title as HLS** with AES-128 encryption
   (`ffmpeg -hls_key_info_file`). Output: a playlist plus 6-second `.ts`
   segments, all encrypted with a per-title content key.
2. **Segments live in a PRIVATE R2 bucket.** No public bucket, ever. A public
   bucket is a permanent URL, which is the thing being eliminated.
3. **The Worker signs segment URLs** valid for a few minutes, bound to the
   session that asked.
4. **The key URL in the playlist points at the Worker, not at a file.** The
   Worker returns the 16 raw key bytes only when the caller presents a valid
   playback grant. This is the load-bearing part: the playlist is useless
   without the key, and the key is a live authorization decision, not an
   object sitting in storage.
5. **The playlist itself is generated per request** with the signed segment
   URLs already in it, so there is no static manifest to share either.

A grant that expires mid-film is already handled: `StreamRenewal` (shipped in
v1.55.16) lets the player ask for a fresh URL without learning what
entitlement is.

### Why not just a signed URL to an MP4?

Because a signed MP4 URL is still a URL, and for the minutes it lives, anyone
holding it downloads the whole film at full speed. With HLS the same window
buys one 6-second segment, and the next one needs another decision.

---

## 3. Offline downloads that cannot leave the phone

The goal is YouTube's behaviour: a downloaded premium title plays in the app,
offline, and is worthless anywhere else.

### The four properties, and how each is obtained

1. **The bytes on disk are already encrypted.** Download the HLS segments
   *as they are* — still AES-128. No decrypt-then-store step exists, so there
   is never a plaintext file to find. This also makes downloading cheap: it is
   the same bytes the player would have streamed.

2. **The key never touches the filesystem in the clear.** On download, the
   Worker returns the content key; the app immediately wraps it with a
   hardware-backed key in the **Android Keystore** (`setUserAuthenticationRequired`
   optional; `setUnlockedDeviceRequired(true)` is worth setting) and stores only
   the wrapped blob. A Keystore key cannot be exported — copying the app's data
   directory to another device yields a blob nothing can open.

3. **The files are in app-private storage.** `getFilesDir()`, not
   `/sdcard`. Unreadable by other apps and by USB/MTP without root. Combined
   with (1) and (2), a rooted phone yields encrypted segments and an
   unopenable key blob.

4. **The licence expires.** A `download_licenses` row carries `expires_at` and
   `last_verified_at`. The app refuses to play a download that has not been
   revalidated online within N days (30 is the industry norm) and deletes it
   when the subscription ends. This is what stops "subscribe for one month,
   download the catalogue, cancel".

### The hop this section used to skip: how the player GETS the key

Properties 1-3 describe where the key is kept. They do not describe how libmpv
reads it at playback time, and that gap is load-bearing: **an HLS player takes
the key from the URI written in the playlist.** Writing the key to disk as a
file so the playlist can point at it undoes property 2 entirely.

**The mechanism, and it already exists in this codebase.**
`lib/core/services/downloader/stream_proxy.dart` is a loopback HTTP server bound
to 127.0.0.1, protected by random per-item tokens, already forwarding range
requests on behalf of the player. It was built so that TikTok's required headers
could travel with a request; the shape is exactly what this needs.

```
player  ->  127.0.0.1:PORT/p/<token>   rewritten local playlist:
                                         key URI  -> 127.0.0.1:PORT/k/<token>
                                         segments -> file:// paths
player  ->  127.0.0.1:PORT/k/<token>   Keystore unwrap -> 16 bytes FROM MEMORY
player  ->  file:///.../seg_000.ts     encrypted bytes straight off disk
```

The plaintext key exists only inside the process, only while a download is
playing, and nothing writes it anywhere. Segments are never rewritten, never
decrypted to disk, and never leave app-private storage.

**Design this before writing the downloader.** Otherwise the download completes
correctly and there is no way to play it.

### What still leaks, stated plainly

A rooted device running a patched build can hook the app after it unwraps the
key. That is true of every non-DRM scheme and of Widevine L3 as well. The
defence is that it requires a rooted phone, a patched APK and real skill —
which is a different population from the people who currently right-click and
save.

---

## 4. One account, one device

### The mechanism

```sql
create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  device_id     text not null,          -- app-generated, Keystore-backed
  label         text,                   -- "Samsung A15" — so the user knows which
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  released_at   timestamptz             -- set when the user gives up the slot
);
create unique index on public.devices (user_id) where released_at is null;
```

The partial unique index is the whole enforcement: **the database physically
cannot hold two active devices for one user.** Not a check in a function that
someone forgets to call — a constraint.

### The rules

* **First sign-in claims the slot.** Silent; the user notices nothing.
* **A second device is refused** with a clear message naming the device that
  holds it: "Your account is in use on Samsung A15."
* **Releasing the slot has a cooldown.** The user may move to a new phone, but
  no more than once every 14 days. This is the number that decides whether
  account-sharing works: a shared account with a 14-day switch cost is useless
  to a group and barely noticeable to a person who changed phones.
* **The cooldown is server-side and per account**, not per device — otherwise
  it resets by reinstalling.

### The device id must survive a data wipe, or it enforces nothing

An id in SharedPreferences is cleared by "Clear data" and the slot is free
again. Generate a random UUID once and store it **in the Keystore-backed
secure storage the vault already uses**, which the app also excludes from
backup — so it survives an app-data clear but does not travel to a new phone in
a device transfer, which is exactly the behaviour wanted.

`ANDROID_ID` is not a substitute: it is per-app-signing-key and resets on
factory reset, and Google's policy discourages using it as a hardware
identifier.

> **THE CODE DOES NOT DO THIS YET.**
> `lib/features/video_hub/data/device_identity.dart` still stores the id in
> `SharedPreferences`, which "Clear data" wipes — so today the slot frees itself
> and the mechanism above enforces nothing. Moving it to the Keystore-backed
> secure storage the Private Folder vault already uses is half a day's work, and
> it must happen in the same stage as the `devices` table or the constraint
> guards an id anyone can reset. Tracked as `movies_gaps.md` #5.

### Honest limit

A determined sharer factory-resets, or buys a second account. Every service
including Netflix has this ceiling. The goal is to make sharing more annoying
than paying, not to make it impossible.

---

## 5. Build order

Each step is shippable and testable on its own, and nothing later invalidates
anything earlier.

| # | Step | Proves |
|---|---|---|
| 1 | Supabase auth + `profiles`, `titles`, RLS on everything | An anonymous caller with the anon key gets nothing it should not |
| 2 | `min_tier` filtering in the catalogue function | A free account never receives a premium locator, even in raw JSON |
| 3 | R2 bucket (private) + Worker signing one test file | A signed URL works, and an unsigned one is refused |
| 4 | HLS packaging + Worker key endpoint | The playlist is useless without a live grant |
| 5 | `devices` table + the partial unique index | A second sign-in is refused by the database |
| 6 | `subscriptions` + `has_active_subscription` in the grant path | Expiry actually stops playback |
| 7 | Offline download: encrypted segments + Keystore-wrapped key | Copying the app data directory to another phone yields nothing |
| 8 | Licence revalidation + deletion on expiry | Cancelling removes access to downloads |

**Do step 1 and step 2 before anything else, and test them with `curl` and the
anon key rather than with the app.** Most paywall failures are not broken
cryptography; they are a table that was readable all along.

---

## 6. What this plan does not do

* No Widevine, so no studio content and no claim of studio-grade protection.
* No prevention of camera-off-screen capture. Nothing prevents that.
* No protection against a rooted device running a patched build.
* Nothing about payment collection — deliberately. The existing KPay
  request-and-approve flow stays: a claim is recorded, an operator approves it
  against the real statement, and only the approval writes a subscription.
