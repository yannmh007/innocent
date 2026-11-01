# Media encryption — every photo and film sealed at rest

Status (1 Nov 2026): **design approved by the owner (31 Oct); format
libraries done (ENC-1); keys table live (migration 060); request-playback
v38 live with the seal plan behind `SEAL_MODE` (off). Next: the app's opener
(ENC-3), then the pipelines.** Waiting on the owner: `MEDIA_KEK_V1` (§4).
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

- **Streaming**: the stream proxy asks the Worker for whole segments (spans
  from `MediaSealLayout`), keeps them **sealed** in its cache (no second
  encryption, as today), and opens them on the way to the player with
  `SealOpener.openRun` — one platform call per run of up to 1 MiB, Conscrypt
  AES-GCM on the CPU's AES instructions. Target: no more cipher calls and no
  more CPU per MB than today's sealed cache (`test_bench/proxy_cpu_bench.dart`).
- **Downloads**: the sealed bytes are written as they arrive (no cipher work
  while downloading — today's downloader encrypts every byte) with the
  device-wrapped DEK beside them; playback opens through the same path.
  Watch-while-downloading works unchanged.
- **Images**: an image loader fetches, opens, decodes; the disk cache keeps
  the sealed bytes.
- **A segment that does not open**: fetched once more; then a clear error and
  an event, never a crash or a corrupt frame.
- **Old formats keep working**: plaintext objects (until migrated) and today's
  CTR downloads and cache files are recognised and played as now.

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
C. `min_supported` = A's build (the brake exists since 10 Sep 2026; older
   builds than that will show a playback error and still offer the update).
D. Every new upload sealed (ingest, console, transcode).
E. Existing objects sealed by a runner job; plaintext kept 14 days for
   rollback, then deleted. **Objects on the owner's do-not-touch list are
   skipped — never sealed, moved or deleted by this job.**
F. B2 Object Lock (governance) after E, never before (it would pin the
   plaintext copies). Quarterly restore drill.

## 10. Recovery

All three are needed and sufficient: a database backup (sealed with the backup
key), the backup key, MEDIA_KEK. Runbook and drill in `docs/RUNBOOK.md` when
phase A lands.

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
