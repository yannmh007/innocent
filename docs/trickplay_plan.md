# The seek bar's pictures made in advance (trick-play) — plan

The owner's go-ahead, 20 Nov 2026 ("Sprite လုပ်၊ plan သေချာချ"). Status
and run ids are kept in BACKLOG §0; this file is the design and the order of
work, for whichever session carries it.

## Why

A seek-bar picture of a part not yet seen costs 1.2-1.4 s in the device lab
(S1-S3, G1): the app fetches the smallest rung's two-second fragment (~67 KB)
from the Worker (~0.5 s to its answer), reads it (0.16-0.33 s) and decodes a
frame from it (~0.45 s on the emulator). The app-side changes of 19 Nov (the
pictures beside the moment taken when the controls come up, the nearest one
shown at once) made a drag's first picture 0 ms and a short drag's stop
0.4-0.6 s; a far drag into a part never seen still waits ~1.0-1.3 s, and each
picture is a fragment. Only a picture made beforehand removes that.

## The design in one paragraph

A runner job reads each film's smallest plain rung, takes one small picture
every few seconds (tool/trickplay.py), packs them into ONE file (`ITP1`: a
24-byte header, one offset a picture, the pictures) and puts it in the
private media bucket beside the rungs. The database records it; the
playback grant signs its address exactly as a rung's (a new, additive
field: older apps ignore it). The app registers it with the stream proxy
like a rung — the same Worker, signed address, renewal, ranges and cache
rules — reads the header once, and then any picture, or a run of
neighbours, is one range request; the picture is shown as it is (JPEG), no
decode of video. Without a pack (a film before its backfill, a sealed-only
film) the seek bar works exactly as now.

## The pack (`ITP1`) — tool/trickplay.py is the reference

Big-endian; offsets from the file's start.

| bytes | field |
|---|---|
| 0-3 | magic `ITP1` |
| 4-5 | version (1) |
| 6-7 | codec: 1 JPEG, 2 WebP |
| 8-11 | interval_ms: picture i is the film at i × interval |
| 12-13, 14-15 | width, height |
| 16-19 | count |
| 20-23 | header length = 24 + 4 × (count + 1) |
| 24 … | count + 1 offsets: picture i is [offsets[i], offsets[i+1]) |
| … | the pictures, each a whole image file |

A two-hour film at 4 s: 1800 pictures, a 7 KB header. tool/trickplay_test.py
holds the layout (in tool/check.py); the app's reader is tested against the
same bytes.

## The setting (chosen from phase 0's numbers)

Measured on the nine open films' real frames by the Trick-play measure
workflow (tool/trickplay_measure.py): sizes per picture and per film-hour,
the runner's time, at seven settings. See "Phase 0 results" below; the
choice is made there, not guessed.

## Pieces, file by file

1. **The tool** — tool/trickplay.py, tool/trickplay_test.py (done, phase 0).
2. **The job** — `.github/workflows/trickplay.yml`, modelled on the frames
   job (tool/frames.py, edge ops `frames_claim` / `frames_done`):
   `trick_claim` gives a batch of assets that have a ladder and no current
   pack, each with a presigned GET of its smallest PLAIN rung and a
   presigned PUT for its pack; the runner makes the pack, PUTs it
   (`Content-Type: application/octet-stream`), and `trick_done` records it.
   A separate job, not a step of tool/transcode.sh: existing ladders need
   packs too (one path for both), a failed pack never fails a ladder, and it
   can run on the branch for the open films without touching a real upload
   (the transcode cron runs main's copy).
3. **Scope** — the claim takes `scope`: `open` (slugs `open-film-…`, the
   default) or `all`. CLAUDE.md: no catalogue title but the open films
   unless the owner names it — `all` only on the owner's word.
4. **Keys** — in docs/edge/transcode.ts, a sibling of `rungKey`:
   `<master stem>-trick.itp` in the private media bucket. No sealed key in
   v1 (below).
5. **Database, migration 083 (additive)** — table `asset_trickplay`
   (asset_id primary key → title_assets on delete cascade, object_key,
   bytes, interval_ms, width, height, count, codec, source_height,
   source_bytes, claimed_at, created_at); RLS on, no policy; security-definer
   RPCs `claim_trickplay(p_scope, p_limit)`, `record_trickplay(p_asset,
   p_row)`, `trickplay_for(p_asset)`, granted to service_role and revoked
   from anon / authenticated explicitly (.claude/rules/migrations.md);
   tool/sql/trickplay_test.sql. A re-transcoded ladder makes its pack stale:
   `trickplay_for` returns a pack only while `source_bytes` still equals the
   smallest rung's bytes, and the claim then offers the asset again — no
   change to `record_renditions`.
6. **Edge** — transcode.ts `trick_claim` / `trick_done` (TRANSCODE_SECRET,
   as frames); request-playback.ts: `trickplay: {url, bytes, interval_ms,
   width, height, count, codec}` beside `renditions`, the url signed by the
   same `workerUrl` (same token, same expiry). Deployed from a pushed commit
   (skill `edge-deploy`).
7. **Worker** — no change. It serves any key its token names from the media
   bucket with the object's own Content-Type, ranges included
   (docs/worker/src/index.js `/v/…`); its mp4 mend (`straySidx`) stops at a
   file that does not start with `ftyp`, so a pack passes untouched (one
   extra 64 KB head read per key per isolate, cached).
8. **App**
   - `PlaybackGrant.trickplay` (domain) and its parsing
     (api_content_repository.dart), unknown keys ignored as now.
   - The pack registered with StreamCacheServer when the ladder is armed
     (playback.dart), refreshed with the grant like a rung.
   - A reader (lib/features/video_hub/domain/trickplay_pack.dart): first read
     [0, 16 KB) — the header and every offset of a film up to ~4 h at 4 s —
     then a picture or a run is one range. In memory (an LRU of ~2 MB a
     film), never written out in the clear (the preview rule today).
   - `MediaKitPlayerService.ladderPreview(at)`: picture ⌊at / interval⌋ from
     the pack when there is one (no ExoEngine.frame), else the fragment path.
     `prefetchPreviewsAround`: with a pack, the run of pictures ±40 s in ONE
     request (20 pictures) instead of six fragments; with the data saver
     on, none ahead, only the picture under the finger. `nearestPreview`
     stays.
   - Tests: the reader on bytes laid out as above; a pack cut short, a
     foreign one, a picture past the end; the fallback without a pack.
9. **Labs** — `ladderstart` drags with a preview word `trick` (the pack)
   against `near` (fragments), on the open films once packed: the first
   picture, `near_ms`, `stop_ms`, and bytes and requests a drag. Then the
   gate and Test Lab (its preview checks).

## Sealed films

v1 leaves them out: the claim offers only assets whose smallest rung is
plain (a twin keeps plain copies anyway, so a plain pack of it is no new
exposure). A sealed-only film keeps today's previews (from the sealed rung
through the gateway). Sealing the pack (an issued DEK, an `s/` key, its
media_keys row, the gateway reading it) is a later step, with
docs/MEDIA_ENCRYPTION.md's ENC-4 note about preview pictures.

## What must not happen

- No pack or picture in the repository or a lab result (public repository):
  numbers only.
- No title outside the open films packed until the owner says `all`.
- Nothing live before the checkpoint below; nothing on main without the
  owner's release call (the job's cron and the app reader ship with it).
- An old app must not notice: the grant's field is additive, the table is
  new, `record_renditions` is untouched.

## Order of work, and where the owner decides

| Phase | What | Live? |
|---|---|---|
| 0 | The tool and the measurement on the open films (done 20 Nov, 44668658121) | no |
| 1 | Choose the setting from phase 0; write migration 083, the edge ops, the grant field, the job — all on the branch, tested locally (SQL dry-run rolled back as each role) | no |
| **checkpoint** | **The owner sees the exact SQL, the grant field and the costs, and says go** | — |
| 2 | Apply 083 (skill `live-db-change`), deploy transcode + request-playback (skill `edge-deploy`), prove: SQL tests, a grant with no pack unchanged | yes, additive |
| 3 | Run the job on the branch, scope `open`: nine packs; prove each (bytes, header, a ranged read through the Worker) | yes (R2 writes, open films) |
| 4 | The app reader, its tests, Stream bench, branch Build | no |
| 5 | Device lab A/B `trick` against `near`, the gate, Test Lab | no |
| 6 | The owner's release call: the app reader ships; the job's cron on main for new ladders | owner |
| 7 | The catalogue, when the owner says `all`; then sealed films | owner |

## Costs

From phase 0 (below), scaled: R2 storage for the catalogue's hours at the
chosen setting; one Worker request for the header and one a run of pictures
(not one a picture); the runner's minutes per film-hour (the transcode
workflow's free minutes); data per drag on the phone against today's ~67 KB a
picture.

## Phase 0 results (Trick-play measure 44668658121, 20 Nov)

The nine open films' smallest rungs (240p, 80 minutes of film), read as the
app reads them; every setting at 12 s of the runner per film-hour:

| setting | median KB | p90 KB | MB per film-hour |
|---|---|---|---|
| 2 s, 224 px, JPEG q5 | 3.8 | 7.1 | 6.95 |
| 4 s, 160 px, JPEG q5 | 2.3 | 4.4 | 2.22 |
| 4 s, 224 px, JPEG q5 | 3.5 | 7.1 | 3.47 |
| 4 s, 224 px, JPEG q8 | 2.6 | 5.0 | 2.50 |
| 4 s, 224 px, WebP q60 | 2.1 | 5.4 | 2.35 |
| 4 s, 320 px, JPEG q5 | 6.0 | 13.0 | 5.92 |
| 5 s, 224 px, JPEG q5 | 3.7 | 7.4 | 2.78 |

THE CHOICE: every 4 s, 320 px wide, JPEG. The bubble is 144 x 81 dp (~430
px on the owner's phone) and today's pictures are 320 px from the same 240p
rung: a narrower picture would look softer than what it replaces. 4 s, not
2: half the size for a picture at most 2 s from the finger (the time label
stays exact). JPEG, not WebP: 6 % bigger at 224 px for a codec every
decoder has. Quality q8 rather than q5: measured in run 44671051967, 320 px
at q8 is a median 4.4 KB a picture (p90 9.3 KB), 4.28 MB per film-hour,
against 5.92 at q5 (288 px q8: 3.9 KB, 3.68 MB/h).

What that costs:
- R2: the films with a ladder today are the nine open films, 1.3 h: about
  5.6 MB in all. A hundred film-hours later: ~430 MB, under a cent a month.
- The runner: 12-19 s per film-hour (two runs).
- The Worker: one request for the header, then one a run of pictures —
  ±40 s around the finger is 20 pictures, ~90 KB, one request — where today
  each picture is one request of ~67 KB.
- The phone: a far drag ~90-180 KB for 20-40 pictures, against today's
  2-3 fragments (~135-200 KB) for 2-3 pictures; the data saver fetches only
  the picture under the finger (~5 KB).
