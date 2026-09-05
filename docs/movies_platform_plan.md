# A movie platform on nothing — what is actually missing

Researched 28 Aug 2026. Companion to `movies_access_plan.md`, which covers
tiers, protection and device binding. This one answers a narrower question:

> Telegram holds the archive. Supabase does auth, metadata and the
> authorization decision. **What else does a working platform need, and can all
> of it be free?**

---

## 1. The four missing pieces

Telegram and Supabase between them cover storage-at-rest and the decision. A
platform needs four more things, and only one of them is hard.

| # | Missing piece | Why neither existing service covers it |
|---|---|---|
| 1 | **Media origin** — serves bytes to the player, with range requests | Telegram Bot API caps downloads at 20 MB; Supabase gives 1 GB total and 5 GB egress/month |
| 2 | **Edge compute** — signs URLs, hands out decryption keys, enforces the grant per segment | Supabase Edge Functions could, but every byte through them burns the 5 GB egress |
| 3 | **Packaging** — turns a 2 GB master into encrypted HLS segments | Needs ffmpeg and CPU; neither service runs it |
| 4 | **Admin tooling** — upload, tag `min_tier`, approve payments | Cheap: a Supabase table plus a Telegram bot, no new service |
| 5 | **A way to sign people in** | Supabase Auth does the identity, but **it does not send SMS** — phone OTP needs a paid third-party provider. At ~$0.10 a verification this is the single largest cost in the project. See `movies_capacity_model.md` §2 |

**Piece 1 is the entire problem** technically. **Piece 5 is the entire problem
financially**, and it is a decision rather than a build. Everything else is a
weekend.

---

## 2. The ToS finding that decides the shape

Cloudflare rewrote the old "Section 2.8" restriction. The current position, in
their own words: video and other large files may be served through the CDN **so
long as that content is hosted by a Cloudflare service** such as Stream, Images
or R2. Video hosted *outside* Cloudflare remains restricted on the CDN, and
their docs state that a Free/Pro/Business app appearing to serve video without
the appropriate paid service may have its content redirected or other action
taken.

That single sentence sorts the options:

* **Video in R2, served by Workers → explicitly permitted, on the free plan.**
* **Video in Telegram, proxied through Workers → the restricted case.** It is
  large-file traffic from an origin outside Cloudflare. It may work for months
  and then stop, which is the worst possible failure mode for a paid product.

So a Telegram-backed platform must not put Cloudflare in front of it. That is
not a preference; it is the difference between a supported configuration and
one that gets throttled without notice.

---

## 3. Two paths that are actually free

### Path A — R2 + Workers  ← recommended

```
Telegram  →  (upload script)  →  R2 (private, encrypted HLS)
                                      ↑ signed, minutes-long URLs
Supabase (auth, tiers, subs)  →  Worker  →  player
                 ↑ grant                key endpoint
```

| Component | Free allowance | Notes |
|---|---|---|
| R2 | 10 GB storage, 1M writes, 10M reads/mo, **zero egress at any volume** | The egress line is the whole reason this path wins |
| Workers | 100K requests/day, 10ms CPU | Signing and key delivery are microseconds of CPU |
| Supabase | 50K MAU, 500 MB DB, 500K function calls | JSON only; no media ever passes through |

**Cost: $0 within those limits, and $0.015/GB/month beyond 10 GB with egress
still free.** 100 GB of catalogue is about $1.50/month.

**The catch, stated plainly: enabling R2 requires billing information on the
Cloudflare account, even on the free tier.** You are not charged inside the
allowance, but a payment method must be on file.

**RESOLVED 28 Aug 2026.** Cloudflare accepts **PayPal** — alongside Visa,
Mastercard, Amex, Discover, Apple Pay, Google Pay, Stripe Link and UnionPay —
and allows **two payment methods per account**, so the PayPal being opened
satisfies this and the backup-method launch gate at the same time. Community
reports of a **$5 charge at activation** are real; read the confirmation screen
before agreeing. If the method later fails, R2 access is suspended and requests
error while the data stays intact, and after **30 days it may be deleted** —
survivable only because every master lives in Telegram.

**This is the answer. Path B below is now a fallback, not a live option.**

### Path B — Telegram origin + Deno Deploy  ← if no card, ever

The trick that makes Telegram viable: **the 20 MB limit is per file, and an HLS
segment is 3–8 MB.** Package the film into 6-second segments, upload each as
its own Telegram file, and every one of them is comfortably under the cap. The
proxy fetches segment N on demand instead of a 2 GB file.

```
Telegram (one file per HLS segment)
        ↑ getFile → 1-hour URL containing the BOT TOKEN
Deno Deploy worker  ← must proxy the bytes, never redirect
        ↑ grant check against Supabase
     player
```

| Component | Free allowance | Card? |
|---|---|---|
| Telegram | effectively unlimited storage | no |
| Deno Deploy | 1M requests/month, ~20–100 GB bandwidth (sources disagree — measure it), 50ms CPU | **no card, commercial use allowed** |
| Supabase | as above | no |

**Why the proxy cannot redirect:** the Telegram URL contains the bot token.
A redirect hands the token to the client, and the token is total control of the
bot. Every byte must be relayed. That is also why this path burns bandwidth on
the proxy where Path A burns none.

**Capacity, honestly:** a 2-hour film is roughly 1,200 segments, so one full
view is ~1,200 proxy requests. Against 1M requests/month that is about **800
full views per month**, and bandwidth will bind sooner than requests if the
free allowance is 20 GB rather than 100 GB — 20 GB is roughly 28 views of a
700 MB film. Path B is a pilot, not a platform.

### Rejected, and why — so nobody re-proposes them

| Option | Why not |
|---|---|
| Supabase Storage | 1 GB total, 50 MB per file. Two films exhaust the month's egress |
| Telegram behind Cloudflare Workers | The restricted case in §2 |
| Internet Archive | Free and card-free, but **everything is public**. Fatal for paid content |
| GitHub Releases / jsDelivr | Free, but their terms prohibit use as a CDN or file host. Same silent-cutoff risk |
| Hugging Face | Free, generous, but it is for models and datasets. Same category of terms violation |
| Vercel Hobby | **Commercial use is prohibited on the free plan.** A paid app is commercial |
| Cloudflare Stream | The purpose-built answer, and $5/month. Worth knowing it exists |

---

## 4. The packaging pipeline is free too

This is the piece people forget to budget for. Turning a master into encrypted
HLS needs ffmpeg and a few minutes of CPU per title — and **GitHub Actions runs
it for nothing**: 2,000 minutes/month on a private repo, unlimited on a public
one.

```yaml
# .github/workflows/package.yml  (sketch)
# Trigger: manual, with a Telegram file_id and a title id.
# 1. Download the master (Telegram, via a local Bot API server in the runner,
#    or from a temporary link — the runner is allowed to be slow).
# 2. openssl rand 16 > key.bin        # the content key
# 3. ffmpeg -i master.mp4 \
#      -c:v libx264 -crf 23 -preset veryfast \
#      -hls_time 6 -hls_key_info_file key_info \
#      -hls_playlist_type vod out.m3u8
# 4. Upload segments to R2 (aws-cli, S3-compatible) or to Telegram (Path B).
# 5. Insert the key into Supabase — NEVER into the bucket, never into git.
```

Two rules for this workflow, both of which are the whole point:

* **The content key goes to the database, not to storage.** A key sitting next
  to the segments it decrypts is not encryption; it is a filing convention.
* **The runner's secrets are repository secrets**, and the workflow must never
  echo them. A leaked R2 token is a leaked catalogue.

Encoding at CRF 23 / 720p puts a 2-hour film at roughly 250–350 MB, which is
what makes "30-ish titles in 10 GB" true. At 1080p it is triple that and the
free tier holds about ten.

---

## 5. Where each service is allowed to be involved

The rule that keeps this honest, and the one to check every future change
against:

> **Supabase decides. R2 stores. The Worker enforces. Telegram archives.
> Nothing does two of those jobs.**

| Service | May do | Must NEVER do |
|---|---|---|
| Supabase | auth, tiers, subscriptions, `min_tier`, content keys, device slots | serve a media byte; return a locator the viewer's tier does not allow |
| R2 | store encrypted segments | be a public bucket. Ever |
| Worker | verify the grant, sign segment URLs, return the key | contain any entitlement logic of its own — it asks Supabase |
| Telegram | hold masters, receive uploads, notify the admin | appear anywhere in the playback path (Path A) |
| GitHub Actions | transcode, package, upload | hold a plaintext content key in the repo |

---

## 6. What "free" actually costs

Free tiers are free in money and expensive in three other currencies. Budget
for them now rather than discovering them at launch:

* **The 7-day pause.** A Supabase free project pauses after a week of
  inactivity. A live app never idles that long, but a *staging* project will —
  and it will be paused the morning you need it.
* **No backups.** The free tier has none. The catalogue metadata is small;
  export it to a Telegram channel on a schedule. Losing the `titles` table
  loses the platform even though every byte of video survives.
* **Two projects.** One production, one staging. There is no third.
* **The card question.** Path A needs one on file. If that is the blocker,
  Path B is real but small, and the honest framing is that it buys time to
  decide rather than a permanent home.

---

## 7. Recommendation

**Take Path A.** R2 plus Workers is the only configuration here that is
explicitly permitted for video, has no egress cost at any scale, and does not
break when the audience grows. The card on file is the price, and it is a
smaller price than rebuilding the delivery layer after a throttle.

**Build it in this order**, so the expensive part is last:

1. Supabase auth, `titles`, `min_tier`, RLS. Test with `curl` and the anon key.
2. One film, packaged by hand with ffmpeg, in a private R2 bucket.
3. A Worker that refuses an unsigned segment request and serves a signed one.
4. The key endpoint, gated on a Supabase grant.
5. The device slot (the partial unique index from `movies_access_plan.md`).
6. The GitHub Actions pipeline — only once steps 2–4 have proven by hand what
   it is supposed to automate.

Step 1 before anything else. Most paywalls do not fail at the cryptography;
they fail because a table was readable from the start.
