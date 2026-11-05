# Media encryption — every photo and film sealed at rest

Status (5 Nov 2026): **design approved by the owner (31 Oct); format
libraries done (ENC-1); keys tables live (migrations 060-066).
request-playback v41 live with `SEAL_MODE` defaulting to `ask` (§9): only a
request with `seal: 1` looks at sealed rows, so every released app is
answered exactly as before. `MEDIA_KEK_V1` set by the owner and confirmed
twice from boot logs without reading it: usable, base64, 32 bytes, key check
value `f3bfb0d1` (§4). The app's device key, keyring and unseal gateway are
on the branch (ENC-3, §6), streaming and downloads. THE CANARY'S TWINS ARE IN
R2 (ingest v44 `seal_plan`/`seal_commit`, seed-open-films run 41292286979):
Sintel's master and four rungs, Tears of Steel's master and three, each
re-opened whole on the runner and checked again by the function before its
row was written. The device lab on a build that asks (run 41293034978,
Sintel, jumps) took the sealed path throughout — "grant: 5 of 5 copies
sealed, keys rsa", "seal: key held (rsa)", every copy through the gateway —
and passed 15 of 16; the one failure (a skip that waited for another
read's far segment) is fixed in the gateway (§6). Then 16 of 16 twice (runs
41984466643 and 41988997290, the second after the gateway's connections to
the Worker were made to be used again, §6). IMAGES ARE SEALED TOO (§5, §6):
every poster, photo and thumbnail of the four open films has a sealed twin
(seed-open-films run 42008144845, 52 images, ingest v45), and the catalogue
hands each one's key out exactly where it hands out its address
(migrations 063-066). TEST LAB ON REAL PHONES with a build that asks (run
42008905511): the realme 16 of 16, the OPPO 15 of 15 (Original skipped on a
3.5 Mbit/s line), both "5 of 5 copies sealed, keys rsa" and the key held —
the Keystore unwrap works on Android 14 and 15. Against the plain 1.64.79
runs on the same phones (§8). The device lab then drew the Movies hub and
Sintel's page from sealed posters, none refused (run 42013700193, jumps 16 of
16 for the fourth run running). THE PIPELINES (ENC-4, §7): the switch and
one module for keys (067, media_issue.js); the transcode pipeline seals
(transcode v24, tool/transcode_seal.py, tool/unseal_proxy.py) — in the
canary it rebuilt Big Buck Bunny's ladder FROM ITS SEALED MASTER, opened on
the runner, and sealed both rungs and all ten stills at birth, each
re-opened whole and compared before upload and checked again by the
function (runs 42025083706, 42029250311). The second run proved the rules
that the first one showed were missing (069, 070): a twin follows its
object (the re-encoded rungs were not byte-identical, so the old twins
were stale: twelve replaced, their copies binned for a week), sealed
objects are files in use for the Files page, and a runner that does not
seal is never handed sealed work. Switch back to `off`. Next: Telegram
ingest (§7.4 step 3). WHAT IS NOT CERTAIN OR NOT FINISHED is kept
as numbered open items O1-O17 in docs/BACKLOG.md ("ENC open items"); none
may be dropped without its evidence.**
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
  bytes asked for. A segment on its way for one request is waited for by
  another only when it is the one arriving now or the next (128 KB), and
  the last 8 opened are kept, so two lanes meeting inside a segment cost
  nothing more on the line. A segment further down another fetch's way is
  fetched on the request's own: a skip into a read-ahead, or the next lane
  starting where a long part ends, never waits for the read before it to
  get there (device lab run 41293034978: a skip+30 waited 3.9 s for its
  first byte at 240p; `test/unseal_gateway_test.dart` holds both cases).
  The cost is at most one segment read twice where a lane's part ends.
  When the last request waiting on a fetch lets go, the Worker's connection
  is cut at once, not read on to the end of the segment on its way; a fetch
  read to its end gives its connection back, and every
  object shares one pool kept a minute, as the proxy's ladder pool does —
  so a jump or a change of rung finds a connection open, not a new
  handshake (run 41984466643 found every fetch on a new one: jumps answered
  in 0.55-2.2 s against 0.25-0.9 s plain).
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
- **Images** (`sealed_image.dart`, `poster_image.dart`): a row's image is
  its sealed twin's address when the row carries a usable seal (`tls`, the
  sizes agree, an `https` address) — posters from `title_cards` and the
  landing cards (`poster_seal`), photos and thumbnails from `title_media`
  (`seal`, `thumb_seal`, under the same `may_open` as their address). The
  poster cache and photo downloads keep the sealed bytes as they came, and
  only whole; `SealedFileImage` has the platform open the whole object in
  one call (`SealKeyring.openWhole`, the DEK not kept — a grid would push
  the films' keys out) and decodes it in memory. A sealed address is never
  drawn from the network. A build that asks reads `title_cards` where it
  read `titles`: the app roles may read only named columns of `titles`, so
  no computed column can ride on it (066).
- **Old formats keep working**: plaintext objects (until migrated) and today's
  CTR downloads and cache files are recognised and played as now.
- **The Worker passes sealed bytes untouched**: its one rewrite (a stray
  `sidx` renamed `free`) only reads objects whose first box is `ftyp`; a
  sealed object starts `0x28` and a random salt.
- **Who asks**: `seal: 1` is sent only by a build with `kAsksForSealed`
  (`--dart-define=MEDIA_SEAL=1` for a lab build), and only such a build
  reads the image seals. Every path a sealed address can reach opens it:
  streaming and downloads through the gateway, images through
  `SealedFileImage`, and nothing plays, downloads or draws one directly.
  Still plain, and not yet sealed by any job: the seek-bar preview pictures
  (made by the transcode pipeline, ENC-4).

## 7. Pipelines (ENC-4)

Every writer of a media object seals it before it reaches R2, and every
reader that needs the picture opens it — with the same format (§3), keys
issued and recorded only by an edge function (§4), and nothing plain ever
written to the bucket once a pipeline is `on`.

### 7.1 The switch, and why there are three positions

`admin_settings.seal_new` (migration 067), read by every function that
issues work, cached a minute:

| Position | New objects | Who it is for |
|---|---|---|
| `off` (default) | plain, as before | until the canary |
| `canary` | for an OPEN FILM (`open-film-…`) only: the plain object as before AND a sealed twin made by the same pipeline, at birth; everything else plain | proving each pipeline's sealing on real work without one released app losing a film |
| `on` | sealed only; the asset row names `s/<32 hex>` and its key row has no `plain_key` | after §9 C (`min_supported`, `SEAL_MODE=on`) — never before: a released app cannot open a sealed object |

The pipeline code is the same in `canary` and `on`; `on` only skips the plain
upload. A function reads the position when it hands out the work, and the
work says what to make — a runner never decides.

### 7.2 Keys: issued here, recorded here, never named by a runner

One module (`docs/edge/media_issue.js`) for every pipeline:

* `issue(kek, kind)` — a new `dek_id`, the DEK, its wrap under MEDIA_KEK
  (AAD `inv-kek|v1|dek_id`) and a new `s/<32 hex>` key. The runner gets the
  DEK (it seals) and the wrap (it hands it back untouched).
* `record(kek, item, io, kind)` — `checkTwin` (media_twin.js): the wrap opens
  under MEDIA_KEK for this dek_id, both sizes are what the row will say, the
  object starts with the header and its first and last segments open. Then
  the `media_keys` row (films) or the `media_image_keys` row (images, with
  the DEK the wrap opened to). Nothing is recorded that was not issued here.
* A born-sealed object's row has `plain_key` null; request-playback already
  finds a key by `sealed_key` as well as `plain_key`, and `private.image_seal`
  looks up both from 067.
* ONE TWIN PER PLAIN OBJECT (069): `unique (bucket, plain_key)` on both key
  tables. A pipeline records through `media_key_put(kind, row)`: when the
  plain object already has a twin, the pipeline has just made that object
  again, so the old twin is stale — its row is replaced in the same
  transaction and its sealed copy goes to the bin for a week (a phone that
  holds a grant for it can still finish the film).
* A TWIN NEVER OUTLIVES ITS OBJECT (070, `media_keys_settle`): after `done`
  and `frames_done`, a plain object the job wrote again without a new twin
  (the switch off, or sealing failed) loses its old twin; an object the
  asset no longer names (a rung dropped, a still born sealed taken again)
  loses its key row unless something in the catalogue still names it. Each
  sealed copy dropped goes to the bin.
* SEALED OBJECTS ARE FILES IN USE (069): `r2_refs()` names every key row's
  `s/` object ("sealed copy"), so the Files page never calls one unused and
  the bin's purge, which checks `r2_refs()` again, never deletes one a row
  names. A sealed object the function refuses to record is binned.
* A RUNNER SAYS WHETHER IT SEALS (070): a claim carries `seals: 1` only from
  a runner whose Python imports `tool/media_seal.py`. One that does not is
  never handed a sealed master or a film the switch wants sealed
  (`needs_sealing_runner`, the same open-film rule as `twinAllowed`), so
  runners of two releases share the queue while the sealing encoder rolls
  out; if the switch moves between the claim and the answer, the job goes
  back in the queue.

### 7.3 Each pipeline

| Pipeline | Reads | Writes | What changes |
|---|---|---|---|
| Transcode, ladder (`transcode.ts` claim/done, `tool/transcode.sh`) | the master | rungs (media bucket) | claim: a sealed master comes with its DEK (unwrapped for the runner, which decodes video anyway) and the runner opens it to its temporary disk; each rung to seal comes with an issued DEK and a PUT for its `s/` key; the runner checks the CMAF layout on the plain rung, seals, re-opens the whole sealed rung and compares SHA-256, uploads `application/octet-stream`; done: `record` before `record_renditions` |
| Transcode, frames (`frames_claim`, `tool/frames.py`) | the master or a rung | ten stills (public bucket) | sealed images: issued DEKs, `media_image_keys` |
| Telegram ingest (`ingest.ts` claim/done, `tool/ingest.py`) | Telegram | the film or photo (its row's bucket) | seal the downloaded file, re-open the whole sealed file and compare SHA-256, one PUT of the sealed file (a twin: beside the plain one; born: alone); done records the key (`media_record.ts`) and — born — makes the job's object its `s/` key (`ingest_seal_key`) before `finish_ingest` makes the asset; a born file whose seal does not check is a failed attempt, tried again under a new DEK. The runner's other jobs: **archive** (R2 → Telegram) of a sealed master gets `src_seal`, opens it on the runner and sends the plain film — the Telegram copy is the film it always was; **restore** (Telegram → R2) of a sealed master seals with a NEW DEK to a NEW `s/` key (never the old DEK: a different file under an old nonce breaks GCM; never the old name: the Worker's cache keys on it), and `vault_finish(…, p_key)` makes that key the asset's object; **verify** compares the Telegram file's size with the row's plain size (unchanged: `bytes` is always the plain size). Only a runner that claims with `can: [..., "seal"]` is handed any of this (071) |
| Console upload (`docs/studio/upload.js`, `app.js`, `studio.ts`) | the operator's file | a film, photo or still | sealed in the browser (WebCrypto, `media_seal.js` `sealPart`), 16 MiB parts = 256 whole segments each (part 1 with the header), so every part is sealed, sent and retried alone and all but the last are exactly 16 MiB. `sign` / `beginMultipart` decide (`uploadMake`): `on` → born sealed, the object is its `s/` key; canary → an open film's photos and stills get a browser-sealed twin, its FILMS stay plain (their twins are the twin job's; a phone does not upload a film twice). The DEK is issued by the studio and its wrap kept in `media_upload_keys` (072) until `sealCommit` records the key row FROM THAT ROW (only the header comes from the browser, and the object is checked against it). RESUME: the phone keeps the header and each part's plaintext SHA-256 (recorded before a byte of the part is sent), never the DEK; `sealResume` unwraps it again for an upload still pending, only for the admin who began it or the owner; every part already in R2 is hashed again, and a part that no longer hashes as it did restarts the upload under a new DEK — no nonce ever covers two plaintexts. `create`, `addAssets` and `updateAsset` refuse a sealed key no key row names. PHOTOS (all uploads, sealed or not): EXIF, GPS, XMP, IPTC and comments removed before upload (`jpeg_clean.js`), the orientation written back as a one-tag EXIF and the colour profile kept, the picture not re-encoded; a JPEG that cannot be walked is refused, never published with its location |
| R2 file manager (`studio.ts` move, delete; `r2_move_switch`, `r2_trash_done`) | — | — | sealed objects (`s/<32 hex>`) are in no folder and never move; a move rewrites a twin's `plain_key` with its file (and the cover picker's ten stills, which a move used to leave behind — 073). The bytes never change (the AAD names the dek_id, not the path). A delete removes a key row only once its object is gone: the purge of an `s/` object deletes its rows (071); the purge of a plain file deletes its twins' rows and bins their copies, unless something still names them (a master kept in Telegram keeps its twin) (073) |
| probe-media, backfill-dimensions | head and tail of a film; a photo's header | — | `media_read.js` `readPlain`: a sealed object is read as the whole segments that hold the range (one ranged read; the header from the key row, or read in the same request), each opened and checked before a byte is looked at — a segment that does not open throws, never a verdict on unauthenticated bytes; a plain object is read as before. Films: the DEK unwrapped with MEDIA_KEK from media_keys; photos: media_image_keys. No plaintext leaves the function, and the size reported is the film's own |
| Blurhash (`previews_due`, `tool/previews.py`) | public images | a string | a sealed image's row comes with its DEK, header and size from media_image_keys — only to a runner that says it can open one (`seals: 1`); the runner checks the header is the object's, opens every segment in memory, checks the size, hashes it, and writes nothing opened anywhere. A runner that cannot open it fails the item, which is tried again in a day |
| Console preview (`studio.ts` previewUrl, objectUrl, sealedImage; `review.js`, `files.js`, `sealed_view.js`, `sealed_sw.js`) | an object | — | `previewUrl` / `objectUrl` answer a sealed object with its key (a film's DEK unwrapped with MEDIA_KEK, a picture's from media_image_keys) to an admin who may look at it anyway. PICTURES: the studio's `sealedImage` hands over the bytes still sealed (the public bucket's address does not answer the console with CORS), opened in the browser with WebCrypto into a blob: URL. FILMS: a module Service Worker (`sealed_sw.js`, scope the console) answers the <video>'s `sealed/<id>` Range requests by reading the sealed segments from the streaming Worker — the one origin that answers the console with CORS — and opening each (`media_read.js` `rangeAnswer`), as the phone's gateway does; an altered segment is a 502, never a frame. The key lives in the worker's memory for fifteen minutes; if the browser stops the worker the page posts it again. Every other request goes to the network untouched |
| Off-site copy (B2) | an object | its copy | none: copies sealed bytes as they are, **no key** — and the key tables travel in the encrypted database backup, never with the files |

Every sealed object is uploaded as `application/octet-stream`; EXIF is
stripped before a photo is sealed. The seek-bar pictures are NOT objects:
the phone takes them from the smallest rung, through the gateway (§6).

### 7.4 Order of work, each proven before the next

1. 067 and `media_issue.js` (switch, issue, record), with tests.
2. Transcode ladder and frames — canary: an open film's ladder rebuilt from
   its sealed master, every rung and still with a twin made at birth.
   DONE 5 Nov (Big Buck Bunny, runs 42025083706 and 42029250311; 069, 070):
   240p and 360p sealed, opened whole and matched, one key row each with
   the rendition's own size; ten stills likewise; the re-run replaced all
   twelve twins of the first and binned the old copies; no refusal. On a
   phone (device lab run 42030588785, a build that asks): Big Buck Bunny
   "grant: 3 of 3 copies sealed, keys rsa" — the master and both rungs the
   pipeline sealed, through the gateway — jumps 15 of 15 (Original, the
   61 MB sealed master on a 2-4 Mbit/s line, ready in 8.6 s).
3. Telegram ingest, archive, restore, verify — tested against a stand-in;
   real work only once `on` (no open film comes through Telegram).
   BUILT 5 Nov (071, ingest.ts, tool/ingest.py, `media_record.ts` shared
   with transcode.ts): the runner against a fake Telegram with real sealing
   (twin, born, a seal that fails either way, a sealed master archived
   plain and one that does not open never sent, a restore sealed afresh to
   its new key, no DEK in any report — tool/ingest_runner_test.py), the
   database rules rolled back in tool/sql/media_keys_test.sql. Also in
   071: a key row lives exactly as long as what it opens — a twin is in
   use while its plain object is (or is a master kept in Telegram), and the
   bin's purge deletes the key rows of a sealed object it deletes.
4. Console upload — canary: a photo uploaded into an open film's album.
   BUILT 5 Nov (072, studio.ts, upload.js, app.js, jpeg_clean.js): tested
   in Chromium against a fake studio and R2 (tool/js/console_smoke.mjs, 17
   seal checks: a 40 MB file sealed in 16 MiB parts and opened back to the
   file; a tab that died resumed with the DEK asked for again and only the
   missing parts sent; another middle under the same name restarted under a
   new DEK; a phone photo without its camera and place, sealed in one PUT;
   a canary twin; never a DEK in the resume record), the part arithmetic
   against sealAll byte for byte (media_seal_test.mjs), the photo cleaner
   against a real decode (jpeg_clean_test.mjs). The live canary waits for
   the console to reach Pages with the next release (BACKLOG O20).
5. File manager moves and deletes. DONE 5 Nov (073), rolled back on the
   live database: tool/sql/media_keys_test.sql (a move re-points the twins
   and the stills; a deleted file takes its unnamed twin; a master kept in
   Telegram keeps its twin) and tool/sql/files_test.sql unchanged and
   green.
6. probe-media and backfill-dimensions. DONE 5 Nov (`media_read.js`,
   tool/js/media_read_test.mjs: 47 ranges of a sealed object read back as
   the plaintext, one ranged read each, an altered segment or a short answer
   throws).
7. Blurhash. DONE 5 Nov (ingest.ts previews_due, tool/previews.py;
   tool/previews_test.py: a sealed image opens to its bytes, a flipped
   byte, another object's header or a wrong size is refused).
8. Console preview. BUILT 5 Nov: in Chromium against two loopback servers
   standing for Pages and the streaming Worker (tool/js/
   sealed_preview_test.mjs): a sealed film plays in a <video> through the
   Service Worker, ranges are the film's own bytes, an altered segment is a
   502, a sealed picture is drawn. Live once the console reaches Pages
   (BACKLOG O24).

## 8. Acceptance (each gate must pass before the next)

| Check | Pass |
|---|---|
| Grant → first picture | within +5 % of today's lab baseline (2.0–2.5 s) |
| Seeks and quality switches | device-lab jumps 16/16, frozen time not longer |
| Proxy CPU per MB | not above today's `proxy_cpu_bench` |
| Download speed and CPU | not worse than today |
| Real phones | Test Lab realme C53 and OPPO A79 pass; 32-bit phone opens ≥ 20× its bitrate |
| Corrupt segment | refetched once, then a clear error; no crash |

Real phones (5 Nov, Test Lab run 42008905511 against the plain 1.64.79
runs 41179327588 and 41181014623): every check passes on both. The realme
froze less everywhere (skip 0.2 s against 0.7, back to Auto 1.4 against
4.3, far jump 1.3 against 2.1) and its app's main thread was at 7 % against
12. The OPPO froze more (seek 2.4 s against 0.7, back to Auto 7.1 against
1.1) on a line a third as fast as its plain run had (3.5 Mbit/s; the plain
run's carried the Original), main thread 11 % against 4. Its 7.1 s was the
change back to Auto after Original's six lanes: the gateway read on to the
end of the segment on its way after each lane let go — now it cuts at once
(§6). Lines on Test Lab differ five to twenty times between runs, so these
are a pass, not a measurement; the gate on frozen time stays open.

Measured so far (5 Nov): **proxy CPU per MB is not yet within the gate** —
`proxy_cpu_bench` with `BENCH_MEDIA_SEAL=1` is 75 ms/MB against 66-69 for
the sealed cache alone (+7-10 ms/MB, desktop). The platform channel's codec
is 0.25 ms/MB of it; a plain loopback relay in the gateway's place costs
3-6 ms/MB, so the hop is most of it. Real phones decide whether it matters
(Test Lab, `LAB cpu`, the app's main thread against the plain runs of
1.64.79); if it does, the next step is the gateway in the proxy's process
path without the loopback HTTP hop.

## 9. Rollout

A. App with the opener, the device key and the image loader; old formats kept.
   Labs, Test Lab, release.
B. Canary: the open films only (Sintel, Tears of Steel), sealed; labs measure §8.
   How the twins are made: `seed-open-films.yml` task `seal` runs
   `tool/seal_twins.py` — the ingest function issues each DEK (wrapped under
   MEDIA_KEK, so only it can record the twin), the runner seals, opens the
   whole twin again and compares it with the plain file, uploads it to
   `s/<32 hex>`, and the function checks the wrap, the sizes, the header and
   the first and last segments before writing the row. A twin not recorded
   is deleted by the runner, and any left an hour later by the next run's
   sweep. Open films only: `media_twin.js` `twinAllowed`.
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
