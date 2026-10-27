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

## 5. The bill: requests, not storage

Prices: R2 storage $0.015/GB-month; Class B (GetObject, HeadObject)
$0.36/million, **10 million free a month**; egress free. Workers Paid $5 a
month with 10 million requests, then $0.30/million; **the Free plan stops at
100,000 requests a day**. With Workers Caching on, **cache hits and calls to
another entrypoint (our `Block`) are billed as requests**.

A 2-hour film at the 720p rung (1.7 Mbit/s) is ~1.5 GB. **Two meters run
per phone request, and which one counts depends on the edge cache:**

* With an edge cache in front of R2 (fan-out's `Block`, or the Cache API on
  a domain), R2 is read only when a 4 MB block is not cached: ≤ 375 Class B
  reads per copy per cache region per 30 days — the catalogue stays inside
  the free 10 million.
* Without one (fan-out off, as now), **every Worker request is also one R2
  read**: Class B equals the Worker's request count.

Per viewing (one film per viewer per day), Workers Paid plus R2:

| | phone requests / MB | Worker requests | R2 Class B | 1,000 viewers/day | 10,000 viewers/day |
|---|---|---|---|---|---|
| 1.64.69 (shipped), fan-out on | ~7.7 | ~29,000 | ~0 (cached) | ~$260/month | ~$2,600/month |
| 1.64.70, fan-out on | ~0.5–0.9 | ~3,400 | ~0 (cached) | ~$33 | ~$305 |
| **1.64.70, fan-out off (Phase 1, live)** | same | ~1,350 | ~1,350 | ~$14 + ~$11 = **~$25** | ~$124 + ~$142 = **~$266** |
| 1.64.70 + domain, Cache API | same | ~1,350 | ~0 (cached) | **~$14** | **~$124** |

(Worker: $5 a month with 10 million, then $0.30/million. Class B: 10 million
free, then $0.36/million. With fan-out on, Worker requests = gateway + ~1.5
block calls.)

**On the Free plan — today — all of this is $0**, and fan-out off is the
right choice: the Worker cannot pass 100,000 requests a day (3 million a
month), so Class B can never leave its free 10 million, and fan-out off
carries ~75 whole films a day where fan-out on carried ~30 (1.64.69: 3–4).

**On the day viewing outgrows the Free plan, buy the domain with Paid.**
Fan-out off then starts paying R2 for every request, and the Cache API on
a domain removes that line: about $11 a month saved at 1,000 viewers a
day, about $140 at 10,000 — for a $10–11 domain a year. Storage, for
comparison, is small: 100 films with their ladders (~6 GB each) is
~$9 a month. So yes, the owner's worry is right: at scale the per-request
meters outgrow storage. The answer is the cache, not fewer films.

## 6. The plan, and the rule it follows

**The owner's rule (2026-10-22): zero cost first.** Nothing here is bought
until it pays for itself; when a purchase — a domain first — clearly does
more good than it costs, it is bought. And the Worker's request bill is to
stay small. Every choice below is weighed that way.

### Phase 1 — done on the server, 2026-10-22 (no cost)

| # | What | Where | State |
|---|---|---|---|
| 1 | No presigned fallback: no Worker secrets is a 503, and nothing in `request-playback` can sign an S3 URL any more | request-playback v4 | live |
| 3 | A premium grant needs the install id (without it the two-device count was skipped) | request-playback v4 | live |
| 4 | Grant budget per install (300/h, 300 titles/day), per account (600/h, 500/day), per network (1,200/h, HMAC of the address); over it is `429 rate_limited` with `retry_after`; a budget that cannot be read lets playback go on and logs it | migration 046 + v4 | live |
| 5 | Two streams at once: already true — a premium account holds at most two installs, and every premium grant now checks them | v4 | live |
| 2 | Tokens name the account (`u`, 16 hex of SHA-256) and the install (`d`, 32 hex — the same hash the budget keeps); `b: 1` when the app asks with `bind: true`, and the Worker then compares `X-Innocent-Device` | v4 + Worker | **log mode** |
| 4 | Worker ceiling per install / account / link: 600 requests in 10 s (Rate Limiting binding, free) | Worker | **log mode** |
| 7 | `Cache-Control: private, no-store` on every `/v/…` answer | Worker | live |
| — | Edge fan-out off (`EDGE_BLOCK_BYTES = "0"`): each `Block` call was a billed request | Worker | live |
| — | The account's hash in every Worker log line: what one account pulled in a day can be added up from Workers Logs | Worker | live |

"Log mode" refuses nothing: it writes `bind_missing` / `bind_mismatch` /
`rate_limited` to the Worker log and says `X-Bind: ok|missing|mismatch` on
the answer. It is switched to `"enforce"` in `wrangler.toml` only once the
log shows the phones in the field passing:

1. **App 1.64.70** sends `bind: true` and its install id in
   `X-Innocent-Device` on every fetch of a granted URL (stream proxy, warm-up,
   downloads), and shows a plain message for `rate_limited`. It also carries
   the proxy hand-over (~8× fewer Worker requests).
2. When the log shows `bind: ok` from 1.64.70 phones and no `bind_missing`
   from them: `BIND_MODE = "enforce"`. Older apps are unaffected — their
   tokens are not bound. **Done 2026-10-25.** In three days of Workers Logs,
   3,744 bound fetches were `ok`, all from the app. The two `missing` asked
   for bytes 0-4095 with a Windows desktop browser's User-Agent, which no
   build of the app sends, using a token granted to the owner's own phone.
   `/health` now says `bind` and `limit`, so a deploy can be seen to have
   taken.
3. When most phones run 1.64.70: lower the ceiling to ~200 in 10 s and
   `LIMIT_MODE = "enforce"`. **Held back (2026-10-27):** the field is
   there (no version older than 1.64.70 seen since 23 October), but the
   app does not yet wait out a 429: the stream proxy, the downloads and
   the warm-up treat it as a failed part, so an enforced limit would show
   as a stall instead of a pause. The zone's IP rule (400 in 10 s) has the
   same edge, set high for that reason. **1.64.76 waits it out**
   (`rate_limited.dart`): a 429's `Retry-After`, in seconds or as a date,
   held to 1–15 s (10 s when it says nothing), then the same request again
   — in the proxy's length probe, its pooled segment reads, its single
   reads and the first part of a stretch (a later part ends the stretch,
   and the next one starts with that wait), and in the downloader, whose
   next pass waits that long instead of the network wait, which ends as
   soon as DNS answers. The player's own read timeout is 30 s, so a
   15-second wait is a pause, not an error. Pinned in
   `test/rate_limited_test.dart`, `stream_cache_server_test.dart`,
   `stream_cache_hls_test.dart` and `download_throughput_test.dart`. Once
   1.64.76 is most of the field: enforce.
4. When `min_supported` passes 1.64.70: bind every premium token, asked or
   not.

**What Phase 1 cannot do, honestly.** On `workers.dev` nothing stands in
front of the Worker, so a flood of junk requests — even ones it refuses in
a microsecond — still counts against the Free plan's 100,000 a day, and when
that runs out every viewer gets Cloudflare error 1027 until midnight UTC. The
rate limit stops one phone or one copied link from reading the bucket in
tiny pieces; it does not stop the counting. Only a rule in front of the
Worker does, and that needs a domain (Phase 2).

A daily bytes-per-account alert is not built: Workers Logs can be filtered
by `u` in the dashboard today; an automatic alert needs Logpush (paid) or a
small Analytics Engine write per request, which is worth doing with Phase 2.

### Phase 2 — recorded for when a domain is bought

**Under way since 2026-10-27, on innocentplayer.com** (Cloudflare
Registrar, $10.46 a year; .com goes to $11.17 on 1 November 2026, and
auto-renew is set for September 2027).

| step | state |
|---|---|
| zone: minimum TLS 1.2, Always Use HTTPS, TLS 1.3, CT monitoring (email alerts) | done by the owner |
| Bot Fight Mode **off**: on the Free plan it cannot be skipped by any rule and challenges app traffic, which cannot answer a challenge | kept off on purpose |
| the Worker at `stream.innocentplayer.com` (custom domain, `wrangler.toml` `routes`) | live, main `724a879` |
| `STREAM_BASE` (request-playback, probe-media, studio) moved to it | done by the owner; no app release: the app learns the origin from each grant |
| WAF custom rules: only `/v/` and `/health`; only GET, HEAD, OPTIONS | live (403 in front of the Worker) |
| rate-limiting rule: 400 requests per 10 s per IP on `/v/` (high, for mobile carrier NAT; the per-install ceiling is in the Worker) | live |
| `workers_dev = false`: nothing reaches the Worker around those rules | main `b4b0481` |
| photos, posters and the APK from `cdn.innocentplayer.com`, r2.dev off | next: needs the database's `public_asset_base()`, the stored URLs, two edge functions and `app_releases` moved together |
| the Cache API instead of `Block` | when on Workers Paid |

Proved on the domain: transport check 40479831081 (TLS 1.0/1.1 refused at
the edge, http:// redirected, other methods and four scanner paths refused
with 403 before the Worker, every token check and the packet capture as
before), playback check 40479834765, device lab 40479838296.

**Cost:** a `.com` through Cloudflare Registrar is sold at cost, about
**USD 10–11 a year** (no markup on renewal). Everything else below is on
Cloudflare's Free plan.

**What it buys, in order of worth:**

1. **A rule in front of the Worker.** On a zone of our own the Free plan has
   WAF custom rules and one rate-limiting rule, and Bot Fight Mode. Junk is
   refused before the Worker runs, so it is not billed and cannot use up the
   day's 100,000 for everyone. This is the one thing no code can do on
   `workers.dev`.
2. **The Cache API instead of `Block`.** It does nothing on `workers.dev`;
   on a custom domain it gives back the edge copy shared between viewers
   that fan-out gave — the opening seconds of a popular film served from
   beside the viewer — without fan-out's second billed call: ~1 Worker
   request per phone request and almost no R2 reads (§5). On Paid, this is
   most of the bill at scale.
3. **The public bucket off `r2.dev`**, which Cloudflare rate-limits and
   calls "not for production": posters and photos from the domain, cached at
   the edge (a cache hit costs no Class B read).
4. One address the app knows that can move: the Worker, a bucket or a
   region can change behind it without an app release.

**Buy it when any one of these is seen** (the Worker's Metrics page and Logs
say all of them): the move to Workers Paid (from then on every uncached
request is also an R2 read, §5); Worker requests pass ~50,000 on any day
(half the free allowance); a burst of `bad_token` or `rate_limited` lines from one source;
the public photos slowing or refusing; or paying subscribers reach a number
whose evening an error 1027 would ruin. Until then the domain costs more
than it saves.

**Then, in the app and console (no further cost):** #6 seal the premium
stream cache with the downloads' Keystore cipher; #9 a faint moving account
code on premium video, so a recording made on a rooted phone is traceable;
Android Key Attestation (works outside Google Play) to tie premium to a
hardware key; a daily bytes-per-account alert.

**Workers Paid ($5/month, 10 million requests)** is the other lever: it
raises the ceiling rather than lowering the count. After 1.64.70 the free
allowance carries ~75 whole films a day; Paid is for when real viewing —
not abuse — outgrows that.

### Phase 3 — when licensed content needs it

Widevine (§4): Media3/ExoPlayer, CENC-packaged CMAF (no re-encode), a licence
service from ~USD 100 a month. Not before a licensor asks for it.

## 7. On the wire: interception, the observer, the origin (2026-10-26)

Owner's questions: can the film path be intercepted and read, to a
recognised standard? Can someone in the middle tell what is being watched?
Can the storage behind the Worker be reached, or even located? Measured,
not assumed: `tool/playback/transport_check.py` (workflow Transport check)
against the live servers, and the device lab's `mitm` flow, the real app
behind a man in the middle.

**The standard.** OWASP MASVS v2, MASVS-NETWORK-1 ("secure all network
traffic according to current best practices"): met, see below.
MASVS-NETWORK-2 (identity pinning, the L2 profile): not done, on purpose.
Cloudflare does not support pinning its edge certificates and rotates
them on its own schedule, between issuers (the Worker's is Google Trust
Services today, the CDN's Let's Encrypt), and a pin that outlives its
certificate would also break the updater with no store to push a fix
through (§6 of `docs/security.md`). Certificate Transparency monitoring
is Cloudflare's answer to the same risk.

**Measured, run 40381932657:**

| | found | verdict |
|---|---|---|
| TLS, all three hosts | TLS 1.3 (AES-256-GCM) to a modern client; certificates verify | good |
| old TLS | Supabase refuses 1.0/1.1; the edges of workers.dev and r2.dev still complete them | not a hole for the app (TLS 1.3's downgrade sentinel, RFC 8446 §4.1.3); the Worker now refuses requests over them |
| plain HTTP | Supabase and the CDN redirect to https; **the Worker answered** | **fixed**: nothing is answered over http:// |
| altered tokens | one character changed (start, middle, end), cut, extended, traversal, empty: all the same bare 404 | good |
| other methods | POST, PUT, DELETE, PATCH: 405, nothing served; no CORS for a foreign page | good |
| binding | the bound token without its install: 404; an older app's unbound token: plays | good |
| expiry | the same token 610 s later: 404 | good |
| what an answer names | no header and no field of the grant names the account, bucket or object; every address in the grant is the Worker | good |
| ETag | R2's, the film's MD5, the same for every viewer | **removed** |
| packet capture of a real fetch | the token, the device id, the path, the Range header, the response headers and the film's first box: none in it | good |
| what an observer reads | the Worker's host name, in DNS and in the TLS server name (SNI) | see below |

**The real app behind a man in the middle, device lab run 40382851831.**
The emulator was started behind mitmproxy, which answered every connection
with a certificate of its own, and the test film was opened twice:

| | the app | what the proxy could read of Innocent's traffic |
|---|---|---|
| control: the runner's curl, trusting the proxy | — | read it (proves the proxy intercepts) |
| A: the proxy on the path only | refused: `CERTIFICATE_VERIFY_FAILED` | nothing |
| B: its CA also in the phone's user store | refused | nothing |

So a hostile Wi-Fi or line, or a certificate a viewer is talked into
installing, gets nothing: Dart's network stack trusts only the system's
certificate authorities. What such an attacker can do is stop the film
(no connection, no playback); reading it is not possible. A phone the
attacker already controls completely is a different problem, answered by
the server's checks, the bound token, the watermark and the sealed cache,
not by the network (`docs/security.md` §6).

**What someone in the middle can learn.** Not what is watched in the
plain sense: the title, the path, the token and every byte are inside
TLS 1.3. They see that a phone talks to Innocent's Worker and Supabase
(the names), when, and how much. Two limits, honestly:

* **Names.** The Worker's host is visible in DNS and in SNI. Cloudflare
  already publishes an Encrypted Client Hello key for it (its DNS HTTPS
  record carries `ech=`), but the app's network stack (Dart's) cannot use
  ECH. Android 17 supports it for OkHttp 5.5+ (HttpEngine from 17 QPR2),
  with encrypted DNS. Recorded for later; it hides the name, not the IP address, which
  is Cloudflare's shared anycast either way.
* **Traffic shape.** Research shows encrypted video can be recognised from
  its burst pattern: "Beauty and the Burst" (USENIX Security 2017) for
  segment-by-segment players, and catalogue matching on segment sizes. Here
  the phone's proxy fetches the copies in parts of up to 2 MB aligned to
  64 KB, not segment by segment, so the per-request sizes say nothing about
  segments. The rate at which parts are fetched still follows the bitrate,
  so a patient observer holding the same files could in principle guess a
  title. That is true of Netflix and YouTube as well, and padding it away
  costs bandwidth that Myanmar data plans pay for. Not pursued.

**The origin.** The client never holds an R2 address. Verified live, the
grant carries only `https://<worker>/v/<opaque token>`; no header names R2,
the bucket or the account; the bucket is private (no r2.dev address) and
read only through the Worker's binding; and nothing in `request-playback`
can presign. `CF-RAY` names the Cloudflare site nearest the *viewer*, not
the bucket's. The public names that remain are the Worker's
`workers.dev` host and the photos' and APK's `r2.dev` host (the public
bucket, not the films'); a domain of our own replaces both (Phase 2).
Hiding the service from its own host is not an aim (§2, and
`docs/security.md` §4).

## 8. Four further measures, weighed (2026-10-26)

Suggested to the owner by another assistant, against scrapers that drive
headless browsers. Each was weighed for what it adds here, on this stack.

| measure | what it would add | verdict |
|---|---|---|
| JA3/JA4 TLS fingerprints | Cloudflare exposes them only with Bot Management, an Enterprise add-on: not on the Free plan, not on `workers.dev`. As a gate it is brittle: the app's own fingerprint changes with Flutter's TLS library, and Cloudflare itself moved to JA4 when browsers began shuffling their TLS extensions | not available; revisit with Bot Management |
| request signing with a key in the app (HMAC) | a key in the APK is in every copy of the APK and can be read out of it. What is here is stronger: the server mints each token after its own checks, sealed (AES-256-GCM), for 10 minutes, bound to the install. The real step up is a key the phone cannot give away, Android key attestation (Phase 2) | not done; key attestation recorded |
| behaviour analysis and rate limits | Bot Management is Enterprise; Bot Fight Mode and a WAF rate rule need a domain of our own (Phase 2). Already live: grant budgets per install, account and network (enforced), the Worker's per-install ceiling (log mode, §6 step 3) | Phase 2; the ceiling to "enforce" when the log allows |
| HLS with AES-128 segments | the key has to reach every player, so whoever can play can decrypt; it only protects a segment copied without its key, which the tokens already prevent. Not DRM | not done; Widevine is the real one (Phase 3) |

What a headless browser meets here: there is no website to crawl for
films. Every byte needs a grant from `request-playback`, which checks the
title, the account's tier, the device slots and the budgets, and every
grant is a sealed, short-lived, install-bound token.

## Sources

* Cloudflare: [R2 pricing](https://developers.cloudflare.com/r2/pricing/),
  [WAF on the Free plan](https://developers.cloudflare.com/waf/) (custom
  rules; one rate-limiting rule), Registrar at cost
  ([.com price tracker](https://domainoffer.net/tld/com/cloudflare)),
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
* On the wire (§7): [OWASP MASVS-NETWORK](https://mas.owasp.org/MASVS/08-MASVS-NETWORK/)
  and [MASVS-NETWORK-2](https://mas.owasp.org/MASVS/controls/MASVS-NETWORK-2/);
  [Cloudflare on certificate pinning](https://developers.cloudflare.com/ssl/reference/certificate-pinning/);
  [Android: adopting Encrypted Client Hello](https://developer.android.com/privacy-and-security/encrypted-client-hello);
  [Beauty and the Burst (USENIX Security 2017)](https://usenix.org/conference/usenixsecurity17/technical-sessions/presentation/schuster);
  [RFC 8446 §4.1.3 (downgrade protection)](https://www.rfc-editor.org/rfc/rfc8446#section-4.1.3),
  [RFC 8996 (TLS 1.0/1.1 retired)](https://www.rfc-editor.org/rfc/rfc8996);
  Dart's HttpClient trusts only the system store on Android
  ([dart-lang/sdk#50435](https://github.com/dart-lang/sdk/issues/50435),
  [Reqable's note](https://reqable.com/blog/2024/06/27/post)).
