# Media encryption — every photo and film sealed at rest

Status (1 Nov 2026): **design approved by the owner (31 Oct); format
libraries done (ENC-1); keys table live (migrations 060, 061). request-playback
v41 live with `SEAL_MODE` defaulting to `ask` (§9): only a request with
`seal: 1` looks at sealed rows, so every released app is answered exactly as
before. `MEDIA_KEK_V1` set by the owner and confirmed twice from boot logs
without reading it (04:33 and, after the v41 deploy, 05:54 on two fresh
instances): usable, base64, 32 bytes, key check value `f3bfb0d1` (§4). The
app's device key, keyring and unseal gateway are on the branch (ENC-3, §6),
streaming and downloads, branch build 41276775374 green; next the canary's
sealed copies of the open films, images, the labs, and the pipelines.**
This file is the specification the code follows. Change it first, then the
code.

## 1. What the owner asked for

1. Every photo and video in R2 encrypted so that **Cloudflare cannot read
   it** — only the owner's keys open it.
2. **No real increase in cost.** More work is acceptable.
3. **Streaming and downloads exactly as smooth as today**, unnoticeable to
   viewers.

The owner accepted, in writing: keeping the master key offline personally, one
forced update, and posters sealed too.

## 2. Threat model

| Protects against | Does not protect against |
|---|---|
| A leaked R2 or B2 token, a stolen bucket, a provider's backups or staff: they get ciphertext | Supabase **and** R2 both compromised together (keys + files) |
| A Cloudflare account takeover reading content: **no key is ever on Cloudflare** (the Worker passes ciphertext) | A Cloudflare account takeover deleting content (availability: off-site copies, §9) |
| Anyone fetching a premium album photo from the public CDN by its URL (today possible): without the DEK it is noise | A paying viewer on a rooted phone extracting what they are entitled to (no hardware DRM; the moving account code deters) |
| A file altered or swapped in storage: authenticated, it refuses to open | Object sizes and access patterns (visible to the provider) |
| A grant response captured on the way (logs, a proxy): the DEK inside is wrapped for one phone's Keystore | Legal process and takedowns: unchanged; this is breach protection |

## 3. The format — media seal v1

**Google Tink's AES-GCM-HKDF streaming AEAD**, parameters:

| | |
|---|---|
| key (DEK) | 32 random bytes per object |
| derived key | AES-256, HKDF-SHA256(ikm = DEK, salt, info = AAD) |
| ciphertext segment | 65536 bytes |
| header | `0x28 ‖ salt(32) ‖ nonce_prefix(7)` = 40 bytes |
| segment *i* nonce | `prefix ‖ be32(i) ‖ last` (last = 1 on the final segment only) |
| AAD | `"inv-media-v1|" + dek_id` |

Layout: header, then segment 0 (65480 plaintext bytes + 16-byte tag), then
segments of 65520 + 16. **Segment *i* ≥ 1 starts at sealed offset *i* × 65536**,
so any plaintext range maps to one aligned range request. Overhead: 40 bytes +
0.024 %.

Why this one (research, 31 Oct 2026):

- **A reviewed design, not ours.** Every implementation here is tested against
  Tink itself (`tool/media_seal_test.py`, tink 1.x, both directions: Tink opens
  ours, ours opens Tink's). Implementations: `tool/media_seal.py` (reference,
  runners), `docs/edge/media_seal.js` (edge functions and console),
  `android/.../seal/MediaSeal.kt` (phone), `lib/.../seal/media_seal_layout.dart`
  (the proxy's arithmetic). Shared vectors: `test/fixtures/media_seal_vectors.json`.
- **Authenticated, unlike CTR.** A flipped byte, a cut at a segment boundary
  (the last mark), swapped segments, another key or another dek_id all refuse;
  CTR would decrypt them to garbage frames.
- **Seekable, unlike whole-file GCM.** Each segment opens alone.
- **64 KiB, not Tink's 1 MiB default.** On a 2 Mbit/s line a 1 MiB segment is
  ~4 s before the first byte can be checked; 64 KiB is ~0.25 s. Start time on
  Myanmar's slow lines decides it.
- **Not CENC/ClearKey.** It would need the platform DRM plugin (behaviour
  varies by device), a remux of every Original, and a second path for mpv.
  Decrypting in the app's own proxy keeps both engines and every container.
- **Not Widevine.** Strongest (keys in the TEE) but a paid licence service:
  breaks requirement 2. Possible later without changing storage.

## 4. Keys

- **MEDIA_KEK_V1** — 32 bytes the owner generates on their own computer
  (`openssl rand -base64 32`), puts into Supabase secrets themselves, and keeps
  offline in two places (paper + encrypted USB; optionally Shamir 2-of-3). It
  is never in the repository, a chat, Cloudflare, or a phone. Separate from
  PII_ENC_KEY and the backup key.
- **DEK** — one per object, random. Stored only wrapped:
  `AES-256-GCM(KEK, DEK, nonce 12 random, AAD = "inv-kek|v1|" + dek_id)`
  in `public.media_keys` (dek_id, bucket, object_key, kek_version, wrapped,
  plain_size, sealed_size, created_at), RLS on with no policy: service role
  only.
- **Key check value** — the first 8 hex digits of
  HMAC-SHA256(KEK, `"inv-kek-check|v1"`). request-playback logs it once per
  boot (`{"seal_kek":{"state":"ok",…,"kcv":…}}`) with the form and size, never
  the key. V1's is **`f3bfb0d1`**: a function, runner or restored secret that
  shows another value holds another key. Both forms are accepted (base64, 44
  characters, or the paper copy's hex, 64), and give the same value.
- **Rotation**: a new KEK re-wraps the rows (seconds); no object is rewritten.
  A DEK that leaked means re-sealing that one object.
- **Separation**: Cloudflare holds files without keys; Supabase holds keys
  without files.

## 5. Delivery to the phone

- **Device key**: at first launch the app makes an RSA-2048 key in Android
  Keystore and registers its public half with the install (`devices`).
  Wrapping is **RSA-OAEP with SHA-1 and MGF1-SHA-1**: Keystore supports only
  MGF1-SHA-1 below API 35 (Android's own cryptography guide; projects hit
  "Unsupported MGF1 digest: SHA-256"), and WebCrypto ties the MGF1 hash to the
  OAEP hash, so SHA-256/SHA-1 cannot be produced by the edge function without a
  hand-written OAEP. OAEP with SHA-1 remains approved for encryption (SHA-1's
  collision weakness concerns signatures).
- **Grant**: `request-playback` adds a `seal` block beside each URL it signs:
  `{dek_id, plain_size, dek_rsa}` — the DEK wrapped for that phone — or, while
  `SEAL_DEVICE_WRAP` is `prefer` and the install has no key yet, `{dek}` over
  TLS. No extra request: same response, a few hundred bytes more.
- **Photos**: posters and free album photos carry their DEK in the card/album
  rows any viewer reads; premium album photos' DEKs only for an entitled
  viewer. Free viewers keep the blurhash tiles they have now.
- Unwrapping is one Keystore operation per film (20–200 ms on old phones),
  started while the first bytes download, so nobody waits for it.

## 6. The phone

- **Device key** (`SealDevice.kt`): RSA-2048 in Android Keystore, made once
  in the background at start-up (0.1–2 s in a TEE, never on the way to a
  first frame) and tested with a wrap and unwrap; its public half goes in
  `device_key`. A grant asked before the key is ready goes without it and its
  DEK comes over TLS (`prefer`). DEKs are unwrapped into `SealKeyring.kt` and
  never cross back into Dart.
- **Streaming — the unseal gateway** (`unseal_gateway.dart`). A loopback
  server, behind a token, between the stream proxy and the Worker. The proxy
  registers a sealed grant's URL and fetches the gateway's address instead,
  exactly as it fetched the Worker — ranges of the film, a 206 with the
  film's own length, 403 for an expired link, 429 to slow down — so lanes,
  seeks, the hand-over, the ladder as HLS and its cache are unchanged
  (`stream_cache_server.dart`, `_route`). For plain bytes `[a, b]` the
  gateway asks for exactly the whole segments that hold them (one aligned
  range), opens each as it arrives (`SealOpener.openRun`, one platform call
  per run of the segments that have arrived, at most 16), and sends on the
  bytes asked for. Segments on their way for one request are waited for by
  another, and the last 8 opened are kept, so two lanes meeting inside a
  segment cost nothing more on the line. When the proxy lets go of a part,
  the Worker's connection is cut, not read on.
- **The cache stays sealed**: the proxy writes what the gateway hands it
  under the phone's own key, as it has since 1.64.71 (AES-CTR,
  `OfflineCrypto`); nothing is ever on disk in the clear. Cost: one AES-GCM
  open per byte fetched on top of today's cache cipher — Conscrypt's AES and
  PMULL instructions, one call per run. §8's `proxy_cpu_bench` decides
  whether the next step is needed: keeping each segment's ciphertext itself
  in the cache (GCM is counter mode underneath, so any byte of a segment
  opens alone with AES-CTR from counter `nonce ‖ 2` — tested in
  `tool/sealjvm`), which would drop the cache's own cipher pass.
- **Renewals**: a renewed link is routed again — sealed through the gateway,
  plain as it is (the plain twin holds the same film, so a film renewed
  across the switch plays on), and a sealed one with no gateway fails the
  renewal rather than being read.
- **A sealed URL is never played or downloaded as it is.** Every fallback
  that used to play the remote address checks first (`SealedUrls`), and the
  player refuses one outright (`MediaKitPlayerService.refusesUri`).
- **A segment that does not open**: opened again one by one from the bytes
  already there (so the good ones before it still go on), then fetched once
  more; twice, the request ends — before its status if it was the first
  segment (502), otherwise by cutting the connection, which the proxy reads
  as a failed part. Never a corrupt frame.
- **Downloads** read a sealed copy through the same gateway
  (`offline_downloader.dart`): the film's own bytes and length, every
  segment checked, and the file then kept under the phone's own key exactly
  as before — so the offline shelf, watch-while-downloading and offline
  playback are unchanged, and a download begun on the plain twin resumes on
  the sealed object (`test/download_media_seal_test.dart`). Without the
  gateway, a clear refusal. The same next step as the cache applies if §8
  asks for it: keeping the sealed bytes as they came, with the install's
  wrap of the DEK beside them (`wrapForStorage`), would take the download's
  own cipher pass away.
- **Images** (not yet): an image loader fetches, opens, decodes; the disk
  cache keeps the sealed bytes.
- **Old formats keep working**: plaintext objects (until migrated) and today's
  CTR downloads and cache files are recognised and played as now.
- **The Worker passes sealed bytes untouched**: its one rewrite (a stray
  `sidx` renamed `free`) only reads objects whose first box is `ftyp`; a
  sealed object starts `0x28` and a random salt.
- **Who asks**: `seal: 1` is sent only by a build with `kAsksForSealed`
  (`--dart-define=MEDIA_SEAL=1` for a lab build). Every path a granted URL
  can reach must open seals before a release turns it on — images are the
  one left (posters and album photos are not granted URLs yet; they stay
  plain until the image loader and their seal blocks exist).

## 7. Pipelines

| Step | Where | What changes |
|---|---|---|
| Telegram ingest | runner (`tool/ingest.py`) | seals before the multipart upload; parts are whole segments |
| Console upload | browser | seals with a DEK the studio issues; a resumed upload must be the same file (size, mtime, hash of first and last MiB), else a new DEK — a reused nonce with different plaintext breaks GCM |
| Transcode, frames, previews | runner | DEK from an edge op (runner secret); open to a temporary file on the ephemeral VM, ffmpeg, seal every output with a new DEK |
| probe-media, backfill | edge | open the head/tail segments only |
| Off-site copy (B2/Storj) | runner | copies sealed bytes as they are: **no key needed** |
| Console preview | browser | WebCrypto opens images; a Service Worker opens video ranges |

Every sealed object is uploaded as `application/octet-stream`; EXIF is
stripped before a photo is sealed.

## 8. Acceptance (each gate must pass before the next)

| Check | Pass |
|---|---|
| Grant → first picture | within +5 % of today's lab baseline (2.0–2.5 s) |
| Seeks and quality switches | device-lab jumps 16/16, frozen time not longer |
| Proxy CPU per MB | not above today's `proxy_cpu_bench` |
| Download speed and CPU | not worse than today |
| Real phones | Test Lab realme C53 and OPPO A79 pass; 32-bit phone opens ≥ 20× its bitrate |
| Corrupt segment | refetched once, then a clear error; no crash |

## 9. Rollout

A. App with the opener, the device key and the image loader; old formats kept.
   Labs, Test Lab, release.
B. Canary: the open films only (Sintel, Tears of Steel), sealed; labs measure §8.
   No secret to set: `SEAL_MODE` is `ask` unless set, so the rows plus a
   lab build with `--dart-define=MEDIA_SEAL=1` are the whole canary.
C. `min_supported` = A's build (the brake exists since 10 Sep 2026; older
   builds than that will show a playback error and still offer the update).
   Then `SEAL_MODE=on`, so an older build is told to update (426) rather
   than given an object it cannot open.
D. Every new upload sealed (ingest, console, transcode).
E. Existing objects sealed by a runner job; plaintext kept 14 days for
   rollback, then deleted. **Objects on the owner's do-not-touch list are
   skipped — never sealed, moved or deleted by this job.**
F. B2 Object Lock (governance) after E, never before (it would pin the
   plaintext copies). Quarterly restore drill.

## 10. Recovery

All three are needed and sufficient: a database backup (sealed with the backup
key), the backup key, MEDIA_KEK. Runbook: `docs/RUNBOOK.md` PART 4d; the
restore drill joins it with phase F.

## Research sources

- Tink, AES-GCM-HKDF Streaming AEAD — developers.google.com/tink/streaming-aead/aes_gcm_hkdf_streaming
  (not reachable from the build session; the format was confirmed
  experimentally against tink-python instead, `tool/media_seal_test.py`)
- Android cryptography guide, RSA-OAEP MGF1 note — developer.android.com/privacy-and-security/cryptography
- capcom6/android-sms-gateway PR #453 / issue #460 — MGF1-SHA-256 refused by Keystore
- Supabase Edge Functions limits — supabase.com/docs/guides/functions/limits
  (CPU per request 2 s; another page says 200 ms — why bulk sealing runs on
  runners, not edge functions)
- Cloudflare R2 SSE-C — developers.cloudflare.com/r2/examples/ssec (rejected:
  the key crosses Cloudflare on every request)
