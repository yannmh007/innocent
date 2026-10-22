# Streaming and download security, and what the Worker costs — review (2026-10-22)

Owner's questions: is the film path safe enough, close to YouTube, TikTok
and Facebook? Can a client — even a skilled one — learn anything about R2?
Should links be signed and short-lived, and should a proxy sit between R2
and the viewer ("Private bucket → signed URL → proxy → user")? And will
per-request charges (R2 Class B) outgrow storage when thousands watch at
once? This builds on `docs/security.md` (2026-10-05).

## 1. The path a film takes today (verified in code and in production)

```
 R2 bucket innocent-media (private, no public URL)
   │  read only through the Worker's binding (no credential in the Worker)
   ▼
 request-playback (Supabase Edge, deployed = repo copy at 0291999)
   │  login → published? → tier → subscription → device slots (2)
   │  mints, per copy: AES-256-GCM token {k: object key, e: now + 600 s}
   ▼
 https://innocent-stream.<sub>.workers.dev/v/<opaque token>   ← all the client ever holds
   │  Worker innocent-stream: decrypts, checks expiry on EVERY request,
   │  answers Range from 4 MB edge blocks or R2; every refusal is the same 404
   ▼
 the app's own proxy, 127.0.0.1:<random port>/c/<random 24-byte token>/<id>
   ▼
 libmpv (premium: FLAG_SECURE, no screenshot or screen recording)
 download: AES-CTR, key in Android Keystore — readable on that phone only
```

So the pipeline the owner proposes is the one in use, with two things
stronger than proposed: the link lives **10 minutes**, not 30 (the app
renews it mid-film, and each renewal re-runs every check), and it is
**encrypted, not merely signed** — a signed link would still show the object
key; this one shows nothing. The client never sees the account id, the
bucket name, the folder scheme or an access key.

Checked in the database: the 4 films are in `innocent-media` with no public
URL; only the 16 photos are in `innocent-public` (r2.dev); `renditions_for`
(which returns object keys) cannot be called by `anon` or `authenticated`.

## 2. What is still open

| # | Finding | Risk | Fix |
|---|---|---|---|
| 1 | `request-playback` falls back to a **presigned S3 URL** if the Worker's two secrets are ever missing — which names the account, bucket, key and access key id. | High if it ever happens | Fail closed: no fallback |
| 2 | Tokens are not bound to anyone: a link copied off a phone plays anywhere for its 10 minutes, and parallel downloaders fetch a film well inside that. | Medium | Token carries hashed user + device; the app's proxy and downloader send the device; the Worker compares |
| 3 | `device_id` is optional: a premium call **without** it skips the two-device check. | Medium (account sharing) | Required for premium |
| 4 | No rate limit on grants or on the Worker: one account (or one free title, no account) can be scripted to pull everything at line speed. | Medium (bulk theft, cost) | Per-user/per-install grant budget; Worker per-token and per-IP limits (Workers Rate Limiting binding) |
| 5 | No limit on concurrent streams per account. | Low–medium | 2 at once, counted at grant and renewal |
| 6 | The stream cache is plaintext in app storage (its own note says "downloads are plaintext too" — no longer true). A rooted owner can copy what they watched. | Low–medium | Seal premium cache with the downloads' Keystore cipher |
| 7 | Token responses say `Cache-Control: public, max-age=86400` — an intermediary could replay a film to someone holding an expired link. | Low | `private, no-store` on `/v/…` |
| 8 | `workers.dev` and `r2.dev` names: no WAF, no bot rules, no Cache API (it does nothing on workers.dev), r2.dev is "not for production" and rate-limited. | Medium (availability, cost) | Owner: a domain on Cloudflare (§5) |
| 9 | No watermark: a screen recording made on a rooted phone (FLAG_SECURE bypassed) cannot be traced. | Low today | Visible moving account code on premium |
| 10 | No DRM. | The ceiling | Widevine via Media3, when licensed content requires it (§4) |

None of this hides content from Cloudflare or from a rights holder, and it
should not try to (`docs/security.md` §4): these controls stop theft, abuse
and runaway bills.

## 3. Against the big platforms

| control | YouTube | TikTok / Facebook | Netflix | Innocent 1.64.69 |
|---|---|---|---|---|
| origin hidden behind the CDN | yes | yes | yes | **yes** (private R2, Worker) |
| short-lived links | yes, hours, `expire=` | yes, expiring signatures | yes | **yes, 10 min, encrypted** |
| link bound to the client | IP (`ip=`) + PO token | partly | device certificate | no (#2) |
| anti-bot / attestation | BotGuard, PO tokens | yes | device certification | no (#4) |
| entitlement checked by the server | yes | — | yes | **yes, every grant and renewal** |
| DRM | paid films only | no | Widevine L1/L3, everything | no (#10) |
| screen capture blocked | no | no | yes (secure path) | **premium: yes** (FLAG_SECURE) |
| offline copies device-bound | Premium: yes | watermarked file | yes, licence expiry | **yes** (Keystore AES) |
| watermark | no | visible on downloads | forensic (studios) | no (#9) |

Plainly: the link hygiene is already at or above TikTok/Facebook level (an
opaque, 10-minute, encrypted token is stricter than theirs); below YouTube on
binding the link to the client and on bot defence; far below Netflix, whose
difference is DRM. With §5's first-phase fixes Innocent reaches YouTube's
level for non-DRM video. Nothing short of DRM reaches Netflix's, and even
DRM does not stop a camera pointed at the screen — the realistic goal is
that bulk extraction is slow, attributable and caught.

## 4. DRM, if and when

Widevine needs ExoPlayer/Media3 (libmpv has none), the ladder packaged as
CENC-encrypted CMAF (Shaka Packager, `-c copy`, no re-encode) and a licence
server. Widevine itself is royalty-free; licence services start around
USD 100 a month (EZDRM, Widevine-only) or about €0.01 a licence (Redge,
€0.50 minimum). Budget phones are L3 (software), so studios cap them at
480–720p. Worth it when a licensor requires it; not before §5.

## 5. The bill: Class B is not the meter that matters

Prices: R2 storage $0.015/GB-month; Class B (GetObject, HeadObject)
$0.36/million, **10 million free a month**; egress free. Workers Paid $5 a
month with 10 million requests, then $0.30/million; **the Free plan stops at
100,000 requests a day**. With Workers Caching on, **cache hits and calls to
another entrypoint (our `Block`) are billed as requests**.

A 2-hour film at the 720p rung (1.7 Mbit/s) is ~1.5 GB. R2 is read only when
an edge block (4 MB) is not cached: ≤ 375 Class B reads per copy per cache
region per 30 days — the whole catalogue stays inside the free 10 million.
Even with no cache at all, 300,000 viewings a month would be about $37.

The Worker is where the money is, and it is driven by how many requests the
phone makes:

| | phone requests / MB | billed per viewing | 1,000 viewers/day | 10,000 viewers/day |
|---|---|---|---|---|
| 1.64.69 (shipped) | ~7.7 | ~29,000 | ~$260/month | ~$2,600/month |
| this branch (hand-over, `docs/streaming_seek_research.md`) | ~0.5–0.9 | ~3,400 | ~$33 | ~$305 |
| + domain, Cache API instead of the `Block` entrypoint | same | ~1,350 | ~$14 | ~$125 |

(One film per viewer per day; billed = gateway + ~1.5 block calls. On the
Free plan, 1.64.69 runs out after **3–4 whole films a day**.)

## 6. The plan

**Phase 1 — server and a small app change (days):** #1 fail closed; #3
device required for premium; #2 tokens bound to user + device (old apps keep
working: the claim says whether to check); #4 grant budget per user and per
install, Worker limits per token and per IP; #5 two concurrent streams; #7
cache headers; a hashed user id in the Worker's log line, and a daily
bytes-per-user alert. Plus the hand-over release (1.64.70).

**Phase 2 — owner and app (weeks):** a domain on Cloudflare for the Worker
and the public bucket, r2.dev off, a WAF rate rule and Bot Fight Mode, the
Cache API instead of `Block` (§5); #6 sealed premium cache; #9 watermark;
Android Key Attestation (works outside Google Play) to bind premium to a
hardware key.

**Phase 3 — when licensed content needs it:** Widevine (§4).

## Sources

* Cloudflare: [R2 pricing](https://developers.cloudflare.com/r2/pricing/),
  [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
  [Workers Cache](https://developers.cloudflare.com/workers/cache/) and
  [the Cache API (no effect on workers.dev)](https://developers.cloudflare.com/workers/runtime-apis/cache/),
  [Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/).
* YouTube links and PO tokens: [yt-dlp PO Token Guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide).
* Widevine levels and studio practice: [VdoCipher](https://www.vdocipher.com/blog/widevine-drm-hollywood-video/),
  [BuyDRM](https://go.buydrm.com/thedrmblog/managing-widevine-drm-for-preventing-screen-capture-and-recording-on-android-devices);
  pricing: [EZDRM](https://www.ezdrm.com/service-pricing), [Redge](https://redge.media/en/drm/).
* Device binding: [Android key and ID attestation](https://source.android.com/security/keystore/attestation),
  [Play Integrity standard requests](https://developer.android.com/google/play/integrity/standard).
