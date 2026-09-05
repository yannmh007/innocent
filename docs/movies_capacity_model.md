# Year one — the numbers, and where they actually bind

Written 28 Aug 2026 against the owner's own projections and content profile;
revised the same day to add the auth cost, which was missing entirely.
Read after `movies_platform_plan.md`, and act on it via
`movies_execution_plan.md`. This document exists because the intuition
about which limit hurts first is usually wrong, and it is wrong here.

---

## 1. The inputs

**Distribution:** outside Google Play. Own APK, own in-app updater. Play's
Inappropriate Content policy prohibits apps whose purpose is sexual content, so
this is settled, not a preference.

**Content profile:** short clips (10–30 min), not feature films. Many photo
sets. This matters more than it sounds — see §3.

**Users:**

| | App users | Registered | Premium |
|---|---|---|---|
| Month 2 | 1,000 | 100 | 25–60 |
| Month 9 | 5,000 | 2,500 | 1,000 |

**Assumed behaviour** (state these, so they can be corrected when real numbers
arrive): a premium viewer watches ~10 clips/month; a registered viewer browses
~20 sessions/month; a clip averages 15 minutes at 720p ≈ **200 MB**; a photo
set is 50 images ≈ **25 MB**.

---

## 2. What each limit looks like at month 9

### Cloudflare R2

| Dimension | Month-9 load | Free allowance | Verdict |
|---|---|---|---|
| Storage | 500 clips × 200 MB + 1,000 sets × 25 MB ≈ **125 GB** | 10 GB | **exceeded — costs $1.88/mo** |
| Egress | 1,000 × 10 × 200 MB ≈ **2 TB/month** | unlimited, $0 | **free** |
| Class B (reads) | see below | 10M/month | comfortable |
| Class A (writes) | ~5,000 uploads/month | 1M/month | trivial |

**The egress line is the whole reason this stack was chosen.** 2 TB/month on
AWS S3 would be about $180/month. Here it is zero, permanently, at any volume.

**Storage is the only line that costs money, and it costs almost nothing.**
125 GB × $0.015 = **$1.88/month**. Even at 1 TB it is $15/month.

### Class B operations — the one people get wrong

With HLS, every 6-second segment is one `GetObject`. A 15-minute clip is
**150 segments**, so one view is ~150 reads.

```
1,000 premium × 10 views × 150 segments = 1.5M reads/month
+ posters and thumbnails, ~0.5M
                                        ≈ 2M of the 10M free
```

Comfortable — **but only if the segments come straight from R2.** See §4, which
is where the design decision lives.

### Cloudflare Workers

| Design | Requests/month at month 9 | Against 100K/day (~3M/mo) |
|---|---|---|
| Every segment through a Worker | ~2M | tight, and pointless |
| **Worker issues playlist + key only** | **~20,000** | 0.7% of the allowance |

The second design is 100× cheaper and simpler. §4.

### Supabase — and here is the surprise

| Dimension | Month-9 load | Free allowance | Verdict |
|---|---|---|---|
| MAU | 2,500 | 50,000 | 5% — no issue |
| Database size | titles + profiles + subs + grants ≈ 50 MB | 500 MB | fine, with pruning |
| API requests | unlimited on free | unlimited | fine |
| Edge Function calls | 10,000 grants/month | 500,000 | 2% |
| **Egress (JSON)** | **see below** | **5 GB/month** | **THE BINDING LIMIT** |

```
5,000 users × 20 sessions × 50 KB of catalogue JSON  =  5 GB/month
```

**That is 100% of the free allowance, from browsing alone, before a single
video plays.** Not storage, not users, not functions — the JSON.

Three rules follow, and they are cheap if applied from the start and expensive
to retrofit:

1. **Posters and thumbnails come from R2, never from Supabase.** An image
   served from Supabase Storage is billed against the same 5 GB.
2. **Paginate hard and select narrow.** `select=id,title,poster,min_tier`, 20
   rows a page. A catalogue row should be a few hundred bytes, not a few KB.
3. **Cache in the app.** The existing library cache pattern applies: fetch
   once, revalidate with `updated_at`, do not re-download the catalogue on
   every tab switch.

With those three, the same traffic is comfortably under 1 GB.

### Auth - the line item that was missing entirely

Every other number in this document is about bytes. This one is about SMS, and
it is larger than all of them put together.

**Supabase does not send SMS.** Phone login requires a third-party provider
(Twilio, MessageBird, Vonage or TextLocal), and Twilio Verify runs about
**$0.10 per successful verification**.

```
month 9:  2,500 registered users
          x ~2 verifications each (sign-up, re-login, undelivered retries)
          x $0.10
                                        =  ~$500 in year one
```

Set against $2/month of infrastructure, **authentication would be roughly 99% of
the cost of running this platform.**

And money is the smaller half. International A2P SMS to Myanmar (+95) numbers
is not reliably delivered, and an OTP that does not arrive is a sign-up that
does not happen — a conversion failure the app cannot detect, explain or retry
its way out of.

| Option | Year-one cost | Delivery risk | Client work |
|---|---|---|---|
| Twilio / Vonage OTP | $300-500 | high in MM | none |
| Supabase Send SMS hook -> a Myanmar SMS gateway | local rates | medium | none (server config) |
| **Email + password; phone recorded, not verified** | **$0** | none | ~1 day |

**The observation that makes the third row viable:** a human already checks the
payer's phone number against the real KPay statement before approving a
subscription. The verification the business needs happens at approval time. An
SMS OTP at sign-in buys the same fact, earlier, less reliably, and for money.

Decide this before the schema exists — see `movies_execution_plan.md` §0.1.

### Total money, month 9

| Item | Cost |
|---|---|
| R2 storage, 125 GB | $1.88 |
| R2 egress, 2 TB | $0.00 |
| R2 operations | $0.00 |
| Workers | $0.00 |
| Supabase | $0.00 |
| **Infrastructure total** | **≈ $2/month** |
| SMS auth, if phone OTP is chosen | **$25-45/month** |
| SMS auth, if email sign-in is chosen | **$0** |

Add Workers Paid ($5) only if request volume ever justifies it. It will not, at
these numbers, with the design in §4.

**Read those last two rows together.** The delivery stack was designed around
the fact that 2 TB of egress would cost $180/month on S3 and costs nothing here.
That care is worth very little if the login quietly spends fifteen times the
infrastructure bill every month. **The auth decision is the largest cost
decision in this project**, and it is the cheapest one to get right, because it
costs nothing to make before the schema exists.

---

## 3. Short clips change two things

**In your favour:** a 15-minute clip is 150 segments where a 2-hour film is
1,200. Every per-segment cost — reads, Worker calls, download time — is 8×
smaller. Short-form is the cheap case.

**Against you:** many small titles means many rows and many posters, so the
catalogue JSON and the poster traffic grow faster than the video does. That is
exactly the limit §2 identified. **The photo sets are the same story**: a
gallery of 50 images is 50 requests, and if those images come from Supabase the
5 GB disappears immediately.

So the rule for this content profile: **video is the cheap part; the browsing
experience is the expensive part.** Optimise the catalogue, not the encoder.

---

## 4. The design decision that saves 100× on Workers

The instinct is to proxy every segment through a Worker so entitlement can be
checked on each one. Do not.

**The segments are AES-128 encrypted. Without the key they are noise.** So the
thing that must be gated is the KEY, not each segment.

```
player → Worker /playlist/<title>   (1 request)
             ↓ checks the grant with Supabase
             ↓ returns an .m3u8 whose segment URLs are R2 PRESIGNED URLs,
               valid for the length of one viewing session
player → R2 directly, 150 times      (0 Worker requests)
player → Worker /key/<title>        (1 request)
             ↓ checks the grant again, returns 16 raw bytes
```

Two Worker requests per view instead of 152. R2 presigned URLs are S3-standard
and need no Worker in the path.

Why this is not weaker:

* A leaked segment URL yields encrypted bytes. Useless.
* A leaked key with no segment URLs is useless.
* Getting both requires being a legitimate premium viewer at that moment —
  which is the same person who could screen-record anyway.
* The grant is checked twice, at the two moments that matter.

**Session-length presigning** (a few hours, not minutes) is deliberate: it lets
the player fetch every segment and seek freely without renewal, and
`StreamRenewal` (already shipped) covers the case where a session outlives it.

---

## 5. Not being trapped by PayPal — or by Cloudflare

The requirement was an adapter so a payment ban does not end the platform. The
right abstraction is not around payment; **it is around the origin**, and most
of it already exists.

### The four layers of insulation

1. **Masters live in Telegram, always.** R2 holds *derived* artifacts —
   encrypted HLS segments, which can be regenerated from the masters by the
   GitHub Actions pipeline. Losing R2 costs a re-package, not a catalogue.
   This is the single most important line in this document.

2. **The `titles` table already has `provider` and `locator`.** Keep them.
   Migrating from R2 to Backblaze B2 or Bunny is: copy the bucket, change the
   Worker's origin constant, update `provider`. The app changes not at all,
   because it never learns where bytes come from — it asks for a grant.

3. **The Worker is the only thing that knows the storage vendor.** One file.
   That is the adapter, and it is already the shape of the design.

4. **A second payment method on the Cloudflare account**, added on day one.
   If the primary fails, Cloudflare retries the backup automatically. Without
   one, a failed charge suspends R2 access and after 30 days the data may be
   deleted — which is survivable only because of point 1.

### The runbook, written before it is needed

| Trigger | Action | Time to restore |
|---|---|---|
| PayPal declines once | Backup method covers it | none |
| PayPal account closed | Add a new method within 30 days | none |
| Cloudflare account lost | Re-package masters from Telegram to B2/Bunny; point the Worker elsewhere | days, not weeks |
| Telegram archive lost | **Unrecoverable.** Keep a second copy | — |

The last row is the one to act on now. Telegram is the backstop for everything
else, so it needs its own backstop: a second channel, a second account, or a
cold copy on a drive. **The place with no fallback is the place to add one.**

---

## 6. What to build first, given these numbers

The numbers say the catalogue is the risk and the video is not. So:

0. **Decide how sign-in works** (§2, "Auth"). It changes the schema, so it
   cannot come second.
1. **Supabase auth + `titles` + RLS**, tested with `curl` and the anon key.
2. **The narrow catalogue query** — paginated, few hundred bytes a row,
   posters as R2 URLs. Measure the response size. If a page of 20 is over
   10 KB, fix it now rather than at 5,000 users.
3. **One clip, packaged by hand**, in a private R2 bucket.
4. **The playlist Worker** returning presigned URLs, and the key endpoint.
5. **The device slot** (the partial unique index).
6. **The in-app updater** — before launch, not after. Outside Play there is no
   other way to ship a fix, and the first security fix will be urgent.
7. The GitHub Actions packaging pipeline, once 3–4 are proven by hand.

**Step 2 is the one that is cheap now and expensive later.** Everything else can
be changed after launch; a catalogue shape that burns the egress allowance
cannot be, because by then there are users depending on it.
