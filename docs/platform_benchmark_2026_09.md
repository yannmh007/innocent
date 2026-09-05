# What the big platforms do, and which of it is worth copying

Research note, 2 Sep 2026. Written against v1.63.6+311, the day after the
Movies backend went live end to end.

Not a plan. A comparison, and the four decisions that come out of it. Nothing
here should be built before those four are settled, because two of them are
expensive to reverse.

---

## 1. WHERE THE CATALOGUE VERTICAL ACTUALLY STANDS

Proven on 1 Sep 2026, against the live project, by watching it happen:

* `anon` refused `titles.locator`, allowed the catalogue
* all three catalogue RPCs run as `anon`
* `request-playback` returns a signed URL
* that URL plays
* ten minutes later that URL returns `ExpiredRequest`
* the app renders the catalogue, the poster, and plays the title

That is a working streaming backend. It is roughly what a small OTT looked like
in 2015. The gap to a 2026 one is smaller than it looks in some places and much
larger in one.

## 2. THE ONE REAL GAP: ADAPTIVE BITRATE

Every serious platform - Netflix, Viu, the Bangladeshi Bioscope+, Chorki -
ships **one video as many videos**. The source is transcoded into a ladder
(360p / 480p / 720p / 1080p), cut into segments of a few seconds, and described
by an HLS or DASH manifest. The player measures throughput continuously and
switches rung mid-playback.

This project ships **one MP4 at one bitrate**. The current test file is
162.3 MB for 12:43, about 1.7 Mbps.

On a good connection that is fine. On Myanmar mobile it is the whole problem:

* a viewer on a weak cell **cannot** drop to 480p - there is no 480p. The
  player buffers, and buffering is what makes people cancel;
* a viewer on Wi-Fi **cannot** get 1080p - there is no 1080p;
* every viewer pays for 1.7 Mbps whether their screen and network justify it
  or not. On metered data that is the user's money.

Startup time is the other half. An MP4 must have its index read before the
first frame; an HLS player fetches a manifest and one four-second segment.
Perceived speed is mostly time-to-first-frame, and that is where a single MP4
loses.

**This is the highest-value technical work left in this vertical.** Not
security - security is done and proven. Not features. Bitrate.

## 3. CLOUDFLARE STREAM: THE OBVIOUS ANSWER, AND WHY IT IS THE WRONG ONE

Stream does exactly the missing thing. Upload any file; it transcodes to an
H.264 ladder, packages HLS and DASH, serves from the edge, and supports signed
URLs. No pipeline to build. Dashboard-driven, so it fits a phone-only operator.

Published rates (2026): **$5 per 1,000 minutes stored per month**, **$1 per
1,000 minutes delivered**. Encoding is free; extra renditions do not add
storage cost, which is billed on source duration.

At this project's shape:

| | R2 (today) | Stream |
|---|---|---|
| 100 titles, ~100 min each | 40 GB → **$0.45/mo** | 10,000 min → **$50/mo** |
| 500 viewers × 10 h/month | **$0** (egress free) | 300,000 min → **$300/mo** |
| **Total** | **~$0.45** | **~$350** |

The storage difference is affordable. The delivery line is not, and the reason
is structural rather than arithmetic:

> **Under a flat monthly subscription, per-minute delivery billing means the
> better a customer's value, the worse the unit economics. A viewer who watches
> 100 hours a month costs $6 to serve and pays one flat fee. Heavy users -
> exactly the ones who renew - lose money, and there is no cap.**

R2's zero egress inverts that. A heavy viewer costs the same as a light one:
nothing. For a flat-rate subscription in a price-sensitive market, **free
egress is not a discount, it is the business model**.

**Recommendation: stay on R2. Do not move to Stream.** Revisit only if
delivery ever becomes free-tier-bound in a way R2 cannot absorb, which at
10 million Class B reads a month is not soon.

## 4. SO: ADAPTIVE BITRATE ON R2, WHICH MEANS TRANSCODING

HLS on R2 is ordinary. Segments and manifests are just objects; the player
fetches `.m3u8` then `.ts`. Nothing about R2 prevents it. Two things do:

**(a) Signing.** The current design signs ONE object URL for ten minutes. HLS
fetches a manifest and then hundreds of segments, each needing its own signed
URL. That is a different design - either every segment URL is pre-signed into
the manifest, or a Worker signs on the fly, or the bucket gets a custom domain
with token auth. Real work, and it changes `request-playback`.

**(b) A machine to transcode on.** This is the binding constraint, not the
signing. There is no desktop and no terminal here. FFmpeg has to run somewhere.

Options, honestly ranked:

1. **Two fixed quality files, no HLS.** Store `720p` and `480p` as separate
   objects; let the viewer pick, and remember the choice. This is not adaptive
   - it will not switch mid-playback - but it captures most of the benefit for
   a fraction of the work. **`MediaRef` already carries a free-form `meta` map
   and `VideoContent` already has `qualityLabel`, so the data model needs
   almost nothing.** The player is `media_kit`, which handles a plain URL
   either way.
2. **A hosted FFmpeg/transcoding API.** Upload source, get renditions back.
   Costs money per minute, needs no local machine, scriptable from an edge
   function.
3. **Borrow a PC.** Free, slow, needs someone else's time and a place to put
   40 GB.
4. **Full HLS ladder.** Correct, and the most work: transcode, segment, upload
   hundreds of objects per title, and solve segment signing.

**Recommendation: option 1 first, and only if the measurement says so.** Before
building anything, watch one real playback on a weak connection and see whether
1.7 Mbps actually stalls. If it does not, this whole section waits.

## 5. DRM: NOT WORTH IT HERE

Netflix uses Widevine. Widevine L1/L3 licensing means a license server, key
rotation, CDM integration, and a contractual relationship with Google.

What the current design gives instead: an object that is unreachable without a
signed URL that dies in ten minutes, minted only after a server-side tier check
with the media path never leaving the server. Someone determined can capture
the file inside those ten minutes. Widevine would raise that bar.

It would also raise the cost, the complexity, and the number of devices that
cannot play at all - and it does nothing about the far likelier leak, which is
a screen recorder. **Skip DRM.** `FLAG_SECURE` is already in this codebase for
the vault and is the proportionate control.

## 6. WHAT THE COMPETITION'S REVIEWS SAY

"Bioscope for Mobile" (Channel Myanmar Official) is the closest local
comparable on Google Play - 4.6 stars. Its reviews are more useful than its
feature list, because they name what users of exactly this kind of app
complain about:

* **download management** - one reviewer reports downloads that cannot be
  cancelled or removed;
* **bulk downloads** - a request for a whole-season ZIP for long series;
* **more items downloadable at once** - "10+ or more".

Every one of those is about DOWNLOADS, not streaming. That is a signal worth
taking seriously: in a market where data is metered and connections are
uneven, **download is not a secondary feature, it is the product**.

This codebase already has a real downloader with a Wi-Fi-only toggle
(`wifiOnlyProvider`), a queue, and history. **The catalogue vertical does not
use any of it yet.** Wiring Movies into the existing downloader is likely the
single highest-value feature left - higher than ABR, because it sidesteps
bitrate entirely for the viewer who plans ahead.

One review also calls the app out for charging for pirated content. That is a
reputational and legal exposure, not a technical one, and no amount of
engineering addresses it.

## 7. WHAT IS ALREADY RIGHT, AND SHOULD NOT BE DISTURBED

* **Locator as a path, not a URL** - a storage move is a config change, not a
  rebuild. This decision is now load-bearing.
* **Two vendors** - metadata in Supabase, files in Cloudflare. Either can die
  without taking the other.
* **Server-side tier decisions** - the client never asserts its own rights.
* **`access_tier` failing to `premium`** - a schema typo hides a title rather
  than giving it away.
* **Short-lived signed URLs, proven expired.**
* **Offline-first app architecture** - the rest of Innocent already works
  without a network.

## 8. THE FOUR DECISIONS

Two are cheap to change later. Two are not.

**D1. Storage and delivery: stay on R2 (recommended), or move to Stream.**
Hard to reverse once 100 titles are uploaded. Section 3.

**D2. Auth: phone-as-synthetic-email, or something else.**
Hard to reverse - it determines the shape of `subscriptions`, `devices` and
every future account feature. Already provisionally decided; needs confirming
before the premium schema is written.

**D3. Quality strategy: single file / two fixed files / full HLS.**
Cheap to defer, expensive to do twice. Measure first. Section 4.

**D4. Downloads in the catalogue vertical: in or out.**
Cheap to add later, but it changes what "premium" means and therefore the
subscription copy, so it should be decided before anything is sold.

## 9. SUGGESTED ORDER

1. **Android developer verification** - not a choice, a deadline. Certified
   devices in Singapore, Thailand, Indonesia and Brazil from 30 Sep 2026.
2. **Strip the edge function's `reason`/`detail`** - database error text is
   reaching the client.
3. **Confirm D2**, then write the premium schema: `subscriptions`, `devices`,
   `premium_requests`. This is what turns a working player into a business.
4. **Shrink the posters** - 3.31 MB each is 300 MB across 100 titles, paid for
   by the user in mobile data.
5. **Measure playback on a real weak connection.** Then decide D3.
6. **Wire Movies into the existing downloader** if D4 is in.
