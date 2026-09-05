# End to end — from a file on your phone to a picture on theirs

Written 28 Aug 2026. The concrete walk-through behind `movies_roadmap.md`; the
step-by-step build order is in `movies_execution_plan.md`.
Two journeys: how a title gets in, and how a viewer gets it out.

---

## Journey A — a new title enters the catalogue

### A0. The problem this journey has to solve first

The master is 200 MB – 2 GB. **The Telegram Bot API cannot download it: the
cap is 20 MB.** So the obvious pipeline — "bot receives file, bot downloads
file, ffmpeg packages it" — does not work, and this is where a naive plan
falls over.

Three ways out, and only one is free and automatic:

| Approach | Verdict |
|---|---|
| Bot API `getFile` | **Fails.** 20 MB cap |
| Local Bot API server | Works (2 GB), but it is a server to host and pay for |
| **MTProto client with the bot token** | **Works, free.** MTProto is not subject to the Bot API's 20 MB limit |

The runner uses a **MTProto library (Telethon or gramjs) signed in as the bot**.
It is the same bot and the same private channel; only the protocol differs.
This needs an `api_id` / `api_hash` from `my.telegram.org` — free, one form.

> **Verify this first, with one 500 MB file, before building anything around
> it.** It is the load-bearing assumption of the whole ingest path.

### A1. Upload the master

You send the video to a **private Telegram channel** that the bot is a member
of. Nothing else. No dashboard, no laptop — the phone is enough.

Caption carries the metadata, so the archive is self-describing:

```
#new
title: Example Title
tier: premium
tags: tag-a, tag-b
```

**What this buys:** Telegram is now both the upload path and the permanent
archive, in one action. Everything downstream is derived and re-creatable.

### A2. The bot records the claim

The bot sees the message and writes one row to Supabase:

```sql
insert into ingest_queue (tg_chat_id, tg_message_id, tg_file_id,
                          title, min_tier, status)
values (..., ..., 'BAACAgUAAx...', 'Example Title', 'premium', 'pending');
```

It does **not** download anything. The bot's only job is to turn a Telegram
message into a row.

### A3. GitHub Actions picks up the job

A scheduled workflow (or a manual `workflow_dispatch`) claims the oldest
`pending` row and marks it `working`.

```
runner:
  1. Telethon, logged in as the bot, downloads the master  (2 GB ok)
  2. openssl rand 16 > key.bin                             (the content key)
  3. ffmpeg → encrypted HLS: playlist + ~150 segments
  4. ffmpeg → poster.jpg at 00:00:05
  5. aws-cli (S3 API) → upload segments + poster to R2
  6. Supabase → insert the title row + the key; mark the job 'done'
```

Free: 2,000 runner-minutes/month on a private repo. A 15-minute clip packages
in roughly 3–5 minutes.

### A4. Where each artifact lands, and why there

| Artifact | Destination | Why not elsewhere |
|---|---|---|
| Master (original) | **Telegram, forever** | The backstop. Everything else is re-creatable from it |
| Encrypted segments | **R2, private bucket** | Zero egress; a private bucket has no permanent URL |
| Poster / thumbnails | **R2, a SECOND public bucket** | Serving these from Supabase would eat the 5 GB egress in weeks; gating them would cost a Worker call per card |
| Content key (16 bytes) | **Supabase, `titles.content_key`** | Next to the segments it decrypts, it would not be encryption at all |
| Title row, `min_tier` | **Supabase** | The decision lives with the data the decision is made from |

**The rule underneath the table:** the key and the bytes must never be
reachable through the same door.

### A5. The end state

**Two R2 buckets, and the split is deliberate.** The media bucket is private
and has no permanent URL for anything; the public one holds only things that
are not secrets and would cost a Worker call each to gate.

```
Telegram          ── master.mp4 (2 GB, private channel)
R2 innocent-media ── titles/<id>/seg_000.ts … seg_149.ts   (AES-128, PRIVATE)
R2 innocent-public── titles/<id>/poster.jpg                 (public domain)
                  ── app/latest.json, app/innocent-x.y.z.apk
Supabase          ── titles: id, title, min_tier, poster_url, segment_count,
                             content_key, duration, status
```

No *media* is publicly readable. There is no segment URL to share, because none
exists yet — they are minted per request in Journey B. The public bucket holds
posters and the APK, both of which are meant to be fetched by anyone.

---

## Journey B — a viewer, from tap to picture

Nine hops. At each one, note **what that hop is allowed to know**.

### B1. App opens → catalogue

```http
GET /rest/v1/titles?select=id,title,poster_url,min_tier&limit=20&offset=0
Authorization: Bearer <anon-or-user-jwt>
```

RLS decides what comes back. An anonymous caller sees `public` rows; a
registered account also sees `free`; only an active subscriber sees `premium`.

**What this hop knows:** ids, titles, poster URLs, tier labels.
**What it does NOT know:** any locator, any key, any segment path. Those columns
are not in the `select`, and RLS would refuse them anyway.

> This is the request the capacity model identified as the binding limit.
> Twenty narrow rows, cached in the app, revalidated by `updated_at`. Wide rows
> here are what burn 5 GB a month.

### B2. Posters load from R2

Straight from R2 over the CDN. Zero egress cost, no Supabase involvement, no
Worker involvement.

### B3. The user taps Play

The app calls **the one function that decides anything**:

```http
POST /functions/v1/request-playback
{ "title_id": "...", "device_id": "..." }
```

### B4. The Edge Function decides

In order, and it stops at the first failure:

1. Is the JWT valid? → 401
2. Is `titles.status = 'live'`? → 404 (this is the kill switch)
3. Is this device the account's active device? → 409 `wrong_device`
4. Does `titles.min_tier` require premium? → if so, `has_active_subscription()`
   → 403 `needs_premium`
5. Over the concurrent-stream cap? → 429
6. Record a row in `play_grants` (audit + concurrency)
7. Ask the Worker to mint a session token, or sign one itself

**The app must be able to tell 3 from 4.** Today `AccessDenial` has only
`needsPremium` and `unavailable`, so a `wrong_device` refusal shows as
"unavailable" and the user never learns their new phone needs to claim the slot.
See `movies_gaps.md` #4.

**The response is a capability, never a permission:**

```json
{ "playlist_url": "https://cdn.example.com/p/<title>?t=<signed-token>",
  "expires_at": "2026-08-28T14:30:00Z" }
```

There is **no `isPremium: true` anywhere in this reply.** A proxy that rewrites
every byte of it still cannot produce a token the Worker will accept, because
only the server holds the signing key.

### B5. The player fetches the playlist

```http
GET https://cdn.example.com/p/<title>?t=<signed-token>
```

The Worker verifies the token, then **generates the `.m3u8` on the spot**:

```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/k/<title>?t=<token>"
#EXTINF:6.0,
https://<r2-bucket>/titles/<id>/seg_000.ts?X-Amz-Signature=...
#EXTINF:6.0,
https://<r2-bucket>/titles/<id>/seg_001.ts?X-Amz-Signature=...
...
```

Two things are happening in that file:

* every segment URL is an **R2 presigned URL**, valid for one viewing session;
* the key URL points at **the Worker**, not at a file.

There is no static manifest anywhere. This one was made for this viewer, now.

### B6. The player fetches the key

```http
GET https://cdn.example.com/k/<title>?t=<signed-token>
→ 16 raw bytes
```

The Worker re-checks the grant, reads `content_key` from Supabase, returns the
bytes. **This is the moment access is actually granted.** Everything before it
was arrangement.

### B7. The player fetches segments — straight from R2

150 requests, **through no Worker at all**. R2's presigned URLs are
S3-standard; the Worker is not in the path.

This is the design decision from the roadmap, and it does two jobs at once:

* **Cost:** 2 Worker requests per view instead of 152 — 20,000/month at month
  9 against an allowance of ~3,000,000.
* **Speed:** segments come from the CDN edge with no extra hop.

### B8. libmpv decrypts and plays

media_kit/libmpv reads the `#EXT-X-KEY` line, uses the 16 bytes, decrypts each
segment as it arrives. Nothing in the Flutter app touches cryptography — this
is standard HLS, handled by the engine.

FLAG_SECURE is on for premium (already shipped), so screenshots and most screen
recorders get a black frame.

### B9. The link dies mid-film

The session signature expires, or the subscription lapses. libmpv re-requests,
gets a 403, and reports an error. `StreamRenewal` (shipped in v1.55.16) asks
for a fresh grant without the player ever learning what entitlement is.

**A renewal is a new decision.** A subscription that lapsed at minute 40 is
refused at minute 41 — not extended.

---

## What each hop is allowed to know

This table is the security design. If a future change breaks a row in it, the
change is wrong.

| Hop | Knows | Must never know |
|---|---|---|
| The app | title, poster, tier label, a signed URL | the content key, the bucket path, whether it "is premium" |
| Supabase catalogue query | everything, filtered by RLS | — (but must not RETURN locators) |
| Edge Function | identity, subscription, device | how to serve bytes |
| Worker | how to sign, how to fetch the key | any entitlement rule of its own — it asks Supabase |
| R2 | encrypted bytes | who is watching, or the key |
| Telegram | the masters | that any of this exists |

**Nothing holds both the key and the bytes.** That is the property to preserve.

---

## Where it breaks, and what happens

| Failure | Effect | Recovery |
|---|---|---|
| Telethon cannot pull a 2 GB master | Ingest stops; nothing else affected | Local Bot API server in the runner, or split the master |
| GitHub Actions minutes exhausted | New titles queue up | Public repo (unlimited), or package by hand |
| R2 suspended (payment) | Playback stops; catalogue still browses | Backup payment method; masters survive in Telegram |
| Cloudflare account lost | Playback stops | Re-package from Telegram to B2/Bunny; change the Worker's origin |
| Supabase paused (7 days idle) | Everything stops | Cannot happen on a live app; will happen to staging |
| **Telegram archive lost** | **Unrecoverable** | **A second copy. Nothing else covers this** |

The last row is why the roadmap makes a second archive copy a launch gate. Every
other failure above is a re-package, because the masters exist.

---

## The shortest possible summary

```
YOU:      phone → Telegram private channel        (upload, once)
BOT:      message → one Supabase row              (no download)
ACTIONS:  MTProto pull → ffmpeg encrypt → R2      (free, 5 min)
KEY:      → Supabase, never the bucket

VIEWER:   catalogue  → Supabase  (narrow JSON, RLS-filtered)
          posters    → R2        (free egress)
          tap play   → Edge Function  → a signed URL, not a yes
          playlist   → Worker    (minted per request)
          key        → Worker    ← THE decision point
          segments   → R2 direct (150 requests, 0 Workers)
          picture    → libmpv decrypts, FLAG_SECURE on
```
