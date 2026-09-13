# Filenames and metadata — an audit

*12 September 2026. No code changed by this document.*

Scope: how a downloaded file gets its name, what happens to that name
afterwards, and what metadata (if any) ends up inside the file. Written for
Innocent, whose users are mostly Burmese — so the question "what does this do to
a Burmese title" is asked at every step rather than at the end.

## Method, and what "verified" means here

The repository's history is a single squashed commit
(`501d9b1 Extract Innocent v1.64.7 GitHub-ready release into repo root`), so
`git log -L` yields nothing per-line. **In this project the in-code comments
are the history.** They are unusually complete, and where one explains a
decision this audit treats it as the record and says so.

Everything asserted about yt-dlp's own behaviour was checked by **running it**,
not recalled: yt-dlp `2026.08.19` was installed into a scratch directory and
driven through `YoutubeDL.prepare_filename` / `evaluate_outtmpl` with Innocent's
exact template and real Burmese, Thai, Arabic and emoji titles. Every number in
§2 is an output of that run. Where something could not be executed — the closed
Android downloaders — it is labelled as unverified rather than asserted.

Every `file:line` below was re-checked against the working tree before commit.

## The short version

**The design is right and the number is wrong.** Choosing `B` (bytes) over `s`
(characters) for the title cap is the correct call for Burmese, and the comment
at `DownloadEngine.kt:2977` says exactly why. But the cap itself — **80 bytes**
— is 2.5× tighter than Seal's, which is the closest comparable app, built by the
same author as the yt-dlp binding Innocent uses. Measured: **a Burmese title
keeps 43% of the characters an English title of the same length keeps; emoji
33%.** A 79-character Burmese title arrives on disk as 28 characters.

**Two real defects, neither about length.**

* `extractPath` uses `substringAfterLast("] ")`, so **any title containing
  `] ` defeats it** — `[Official] `, `[HD] `, `[4K] ` are everywhere on these
  sites. Resolution then falls through to `newestIn()`, which with three
  concurrent downloads returns *another job's file*. That is precisely the bug
  the `[id]` tag was added to kill, coming back through a different door
  (`DownloadEngine.kt:3578`).
* **A title beginning with `.` produces a hidden file.** yt-dlp's
  `lstrip('.')` is skipped on this code path (verified), so
  `"...and then this happened"` lands as `'...and then this happened [id].mp4'`
  — invisible to MediaStore, invisible to the gallery, and invisible in the
  Videos tab unless the user has turned on "Show hidden files".

**The Music tab is where metadata handling is thinnest.** `--embed-metadata` is
off by default, `--embed-thumbnail` is refused outright for audio, and the music
scanner — unlike the video scanner — never strips the `[id]` tag. The
combined result is a downloaded song that reads
`ကျွန်တော့်ရဲ့ အချစ် [xy77zz11aa]`, by "Unknown artist", on album "Unknown",
with a placeholder cover.

Nothing here is a crash in the app. The worst outcomes are a failed download
(rare), the wrong video behind a row (occasional), and a file the user cannot
find (rare).

---

## 1. What the system actually does

### 1a. One template, one folder

```kotlin
request.addOption("-o", File(target, "%(title).80B [%(id)s].%(ext)s").absolutePath)
```
`DownloadEngine.kt:2980`

There is exactly one output template in the app. It is not configurable, there
are no per-site or per-playlist subfolders, and playlists write into the same
flat directory as everything else (`playlist_sheet.dart:53` reads the same
`downloadDirProvider`). The directory defaults to
`/storage/emulated/0/Download/Innocent` (`downloader_providers.dart:27`), with a
documented reason: the public `Download` tree is writable without all-files
access, is indexed by MediaStore, and survives an uninstall.

`writableDir` (`DownloadEngine.kt:2708`) proves the folder by writing and
deleting a probe byte, and silently falls back to the app-private Movies
directory if it cannot. A download never dies on a permission — but note the
consequence for names: a fallback download lands somewhere the library's own
scan can still reach, so this is fine.

Innocent's template is yt-dlp's own default (`%(title)s [%(id)s].%(ext)s`,
yt-dlp README:1468) with a byte cap added. That is a good sign, not a
coincidence.

### 1b. What `.80B` actually does — verified against yt-dlp source

`YoutubeDL.py:1480`:

```python
elif fmt[-1] == 'B':  # bytes
    value = f'%{str_fmt}'.encode() % str(value).encode()
    value, fmt = value.decode('utf-8', 'ignore'), 's'
```

Three consequences, all confirmed by running it:

1. **The cut is on bytes, and a codepoint split in half is dropped whole.**
   `errors='ignore'` discards the incomplete tail sequence. **There is no
   mojibake and no invalid byte in the filename, ever.** This was the first
   thing checked and it is clean.

2. **Grapheme clusters are not respected.** A codepoint is atomic here; a
   *cluster* is not. Measured tails from real Burmese titles at exactly 80
   bytes:

   | title | tail codepoint at the cut |
   |---|---|
   | `မြန်မာ့ရိုးရာ အစားအစာ ချက်ပြုတ်နည်း …` | `U+103C` MYANMAR CONSONANT SIGN MEDIAL RA (Mc) |
   | `ကမ္ဘာ့ သတင်း ကမ္ဘာ့ သတင်း …` | `U+1039` MYANMAR SIGN VIRAMA (Mn) |
   | `အအအအကမ္ဘာ့ သတင်း …` | `U+103A` MYANMAR SIGN ASAT (Mn) |

   A name ending in a dangling `U+1039` or `U+103A` renders with a dotted
   circle (`◌္`) in most fonts — the mark has nothing to attach to. A name
   ending in a medial without its vowel is a broken syllable. Cosmetic, but it
   is the *first* thing a Burmese user notices about a downloaded file.

   Same class of problem elsewhere: a ZWJ emoji sequence cut mid-way leaves a
   **trailing `U+200D` ZERO WIDTH JOINER** in the filename — an invisible
   character that breaks exact-name matching and shell completion.

3. **Sanitisation runs AFTER truncation, and can make the name longer.** In
   `create_key` the `B` branch fires before the `if sanitize:` block, so the
   80-byte window is cut from the *raw* title. Then `sanitize_filename`
   (`utils/_utils.py`) replaces each of `" * : < > ? | / \` with its 3-byte
   full-width counterpart. **1 byte becomes 3.** Measured: a title of 90 `/`
   produces a 258-byte filename — past the 255-byte ext4/f2fs limit, and the
   download fails with ENAMETOOLONG. See finding F7; at 80B it takes ~79
   illegal characters in one title, which is why nobody has hit it.

Also verified on the full `prepare_filename` path:

| input title | filename |
|---|---|
| `""` (empty) | `NA [id].mp4` |
| `...and then this happened` | `...and then this happened [id].mp4` **(hidden)** |
| `Rock/Pop: "Best" <Live> \| 100%` | `Rock⧸Pop： ＂Best＂ ＜Live＞ ｜ 100% [id].mp4` |
| `Title with\na newline` | `Title with a newline [id].mp4` |

The full-width substitution is yt-dlp's default because `--windows-filenames`
is unset (default `None`, not `False`); the "minimal sanitisation" branch at
`YoutubeDL.py:1398` needs an explicit `--no-windows-filenames`. So Innocent's
files are Windows- and exFAT-safe by inheritance, which matters when someone
sends one over the Transfer tab to a laptop.

### 1c. `--no-overwrites` and `--continue` — deliberately together

```kotlin
request.addOption("--continue")      // :2957
request.addOption("--no-overwrites") // :2965
```

The comment at `:2958–2964` explains the pairing and it is correct: a
**finished** file is skipped, a half-written `.part` is still resumed. Both
depend entirely on the filename being stable across runs — which it is for the
`[id]` half and is *not* for the title half. See F9.

### 1d. `--no-mtime` — deliberate, do not remove

`DownloadEngine.kt:2981`. yt-dlp's default is to set the file's mtime from the
server's `Last-Modified`. `--no-mtime` overrides that so the mtime is *download*
time. Three things depend on it, none of them obvious:

* `finalFor` → `newestIn` picks by `maxByOrNull { lastModified }`
  (`:3650`). With upload-time mtimes a 2019 clip downloaded today would look
  older than everything.
* `deletePartialsFor` and the tag scan in `finalFor` both use "most recently
  modified wins".
* The library sorts by `dateAdded` descending
  (`library_local_datasource.dart:300`), and MediaStore's `DATE_MODIFIED`
  follows the file's mtime.

There is no comment on this line. **It is load-bearing anyway.** Added to §6.

### 1e. Resolving "which file did this job produce"

Four functions, in order:

| function | line | job |
|---|---|---|
| `extractPath` | `:3565` | read the path off a yt-dlp output line |
| `finalFor` | `:3678` | the file THIS job produced, never a neighbour's |
| `idTagOf` | `:3705` | the last `[...]` group, brackets included |
| `isIntermediate` | `:3719` | `.part` / `.ytdl` / `.temp` / `.fNNN.ext` |
| `newestIn` | `:3650` | last resort — newest non-partial in the folder |

`extractPath` reads three shapes of line: `Merging formats into "…"`,
`Destination: …`, and `… has already been downloaded`. The first two are sound.
The third is not — see F2.

`idTagOf` returning the brackets **with** the tag is a good, deliberate detail:
a bare substring match would confuse `[ab]` with `[abc]`. Likewise
`isIntermediate`'s regex `\.f\d+\.[^.]+$` is safe here precisely *because* the
`[id]` tag always sits between the title and the extension — a title ending in
`.f137` cannot be mistaken for a format piece. That is luck rather than design,
but it holds.

### 1f. And then the name is taken apart again

```dart
static final RegExp _idTagRe = RegExp(r'\s\[[A-Za-z0-9_-]{6,24}\]$');
```
`library_local_datasource.dart:441`, used at `:101` (MediaStore path) and
`:417` (filesystem walk).

The tag must sit at the very end, be 6–24 of `[A-Za-z0-9_-]`, and contain at
least one digit — so ordinary title brackets (`[Official Video]`, `[HD]`)
survive. Tight and well-judged. Its blind spots are in F11.

The **music** scanner does not do this. `music_local_datasource.dart:71` builds
its fallback title with `_stripExt` only. See F3.

### 1g. The two metadata switches

```kotlin
if (job.embedThumbnail && !audioOnly) request.addOption("--embed-thumbnail") // :3108
if (job.embedMetadata)               request.addOption("--embed-metadata")   // :3111
```

Both default to **false** (`downloader_providers.dart:586–587`), both are plain
switches in Settings (`downloader_home_screen.dart:3655`, `:3665`) with no
explanation of what they cost or buy. Both are gated on `ffmpegError == null`,
which is right: they are post-processors and would fail the whole download
rather than be skipped.

Cost, for the switch subtitles that do not exist yet:

| option | time | size | what it buys |
|---|---|---|---|
| `--embed-metadata` | ~0 (a container rewrite, seconds on a 1 GB file) | a few hundred bytes | title / artist / album / date readable by every player, and by Innocent's own Music tab |
| `--embed-thumbnail` | one image fetch + a rewrite | 20–200 KB | cover art in the Music player and in most gallery apps |

Both rewrites happen at 100% and are already covered by `isFinalizing`
(`:3495`), so the bar says "Finalizing…" rather than appearing to freeze. That
was thought about.

---

## 2. Burmese titles — the measured cost

This is the section that matters most for this app, so it gets numbers rather
than adjectives. All from the yt-dlp 2026.08.19 run described above.

**How much of a 60-character title survives `.80B`:**

| script | 60 chars = | keeps | share |
|---|---|---|---|
| English | 60 bytes | 60 chars | **100%** |
| Arabic | 120 bytes | 40 chars | 67% |
| Burmese | 180 bytes | 26 chars | **43%** |
| Thai | 180 bytes | 26 chars | 43% |
| Emoji | 240 bytes | 20 chars | 33% |

Every Myanmar codepoint in U+1000–U+109F is 3 bytes in UTF-8, and Burmese
spells a syllable with 2–4 of them. So **80 bytes ≈ 26 codepoints ≈ 8–12
syllables ≈ three or four words.** A real example, end to end:

```
title  : မြန်မာ့ရိုးရာ အစားအစာ ချက်ပြုတ်နည်း အပိုင်း ၃ - ကြက်သားဟင်း အရသာရှိရှိ ချက်နည်း   (79 chars, 219 bytes)
on disk: မြန်မာ့ရိုးရာ အစားအစာ ချက်ပြ [ph64a3f2c1].mp4                                    (97 bytes)
```

The user sees the whole title in the Downloads list (`r.title`,
`downloader_home_screen.dart:2526`) and this stump in the Videos tab. Two names
for one file, and only the Burmese speaker gets the stump.

**The headroom that is going unused.** The filesystem limit on Android internal
storage (ext4/f2fs) is 255 **bytes** per name component. The overhead beside the
title is:

```
" ["  + id + "]"  + ".fNNN"      + "." + ext
  2   +  11 +  1  +   5          +  1  +  3   = 23 bytes   (11-char id, merged download)
```

So the title may safely occupy **232 bytes**. Innocent uses 80 and leaves 152
on the table. Seal — same author as the yt-dlp binding Innocent depends on —
uses **200** (`DownloadUtil.kt:62`, `const val BASENAME = "%(title).200B"`).

**Recommended: 150B.** Reasoning, so the next person can re-derive it rather
than trust it:

* 150 bytes ≈ 50 Burmese characters — **1.8× today**, and enough for a real
  sentence rather than a fragment.
* Headroom left: 232 − 150 = 82 bytes, which absorbs up to **41** expanding
  illegal characters (§1b point 3). Seventeen is enough to break Seal’s 200; 42
  in one title is not a thing that happens.
* Not 200, because Innocent adds what Seal does not: `--write-subs` writes a
  sibling `.en.vtt`, some extractors on these sites use ids far longer than
  YouTube's 11, and the `.fNNN.` intermediate is counted above but Seal's own
  accounting does not include it.

`--trim-filenames` is **not** the tool for this: yt-dlp documents it as a
character count (README:674), and it applies to the whole name rather than the
title field, so it would cut into the `[id]` tag Innocent depends on.

Raising the cap does **not** fix the dangling-virama tail (§1b point 2) — it
just moves it. Fixing that properly means trimming back to the last grapheme
boundary, which yt-dlp cannot express in a template and would have to be done
Kotlin-side after the fact. That is a "nice to have", not a "needed": a broken
final syllable is ugly, not wrong.

---

## 3. Findings

Likelihood is မကြာခဏ (often) / ရံဖန်ရံခါ (sometimes) / ရှားပါး (rare).
Severity is crash / data loss / annoyance, in this project's sense.

### F1 — 80 bytes is far tighter than it needs to be
`DownloadEngine.kt:2980` · UX · **မကြာခဏ** · annoyance · **trivial**

Every Burmese title over ~26 characters is cut to a fragment, while an English
title of the same length arrives whole. Measured in §2. The design (bytes, not
characters) is correct and must stay; only the constant is wrong. Change `80B`
to `150B`. One token.

### F2 — a `] ` in the title binds the row to another job's file
`DownloadEngine.kt:3578` · silent failure + race · **ရံဖန်ရံခါ** · data confusion · **trivial**

```kotlin
val path = text.substringBefore(alreadyMarker).substringAfterLast("] ").trim()
if (path.startsWith("/")) return path
```

The line is `[download] /path/Title [id].mp4 has already been downloaded`. The
intended anchor is the `[download] ` prefix, but `substringAfterLast` finds the
**last** `] ` — so a title containing one wins. Simulated against the exact
Kotlin string operations:

| title | extracted path |
|---|---|
| `Sunset Drive` | `/storage/…/Sunset Drive [ab12cd34].mp4` ✓ |
| `Best [Official] Video` | `null` ✗ |
| `Top 10 [HD] Clips` | `null` ✗ |
| `မြန်မာ သီချင်း [တရားဝင်] ဗီဒီယို` | `null` ✗ |

`null` means `lastPath` is never set, so `finalFor(null, target)` (`:3180`)
skips the tag-scoped scan entirely and calls `newestIn(dir)` — "whatever file in
the shared folder is newest". With `MAX_PARALLEL_DOWNLOADS` at three, that is
routinely a **different download's video**. The `[id]` tag was introduced
specifically to stop this (README §v1.40.0+252, "Same title, right video"); this
line walks around it.

Fires only on the re-download path, which is why it survived. Fix:
`substringAfter("] ")` — the first occurrence, since the prefix is always a
single `[tag] `. It is possible `substringAfterLast` was chosen to survive some
line shape I have not seen; I could not find one, but flagging the uncertainty.

### F3 — the Music tab shows the `[id]` tag
`music_local_datasource.dart:71` · UX · **မကြာခဏ** · annoyance · **trivial**

The video scanner strips it (`library_local_datasource.dart:101`, `:417`); the
music scanner builds `fallbackTitle: _stripExt(a.title ?? p.basename(path))`
with no `_stripIdTag`. Any downloaded audio without embedded tags — which, per
F4, is the default — reads `Some Song [xy77zz11aa]` in Tracks.

`_stripIdTag` is a pure static with no dependencies. Lift it to a shared helper
and call it here.

### F4 — `--embed-metadata` is off by default, so downloaded music has no tags
`downloader_providers.dart:587` · UX · **မကြာခဏ** · annoyance · **easy**

`music_local_datasource.dart:96–98` reads ID3 title/artist/album and falls back
to the filename with **empty** artist and album. Empty artist and album are then
grouped under `'Unknown'` (`:135`, `:151`). So with the default settings, every
song Innocent downloads lands in one "Unknown" artist and one "Unknown" album.

`--embed-metadata` costs a container rewrite already covered by "Finalizing…".
For the audio path specifically there is no argument for leaving it off. Turning
it on by default only for `audioOnly` jobs would be the conservative version.

### F5 — thumbnails are never embedded for audio
`DownloadEngine.kt:3108` · UX · **မကြာခဏ** · annoyance · easy — **but likely deliberate**

`if (job.embedThumbnail && !audioOnly)`. The Music player has a whole
`_albumArtFallback()` (`music_player_screen.dart:84`) and an `albumArtProvider`
that mostly returns nothing, which is the downstream symptom.

**I am not sure this is a weakness, and it should not be changed without
checking.** `--embed-thumbnail` into `m4a`/`mp4` requires **AtomicParsley**,
which is not bundled (`grep -ri atomicparsley` across the tree: nothing), and a
missing post-processor fails the *whole download* rather than skipping. The
`audioOnly` flag is separate from `toMp3`, so `audioOnly && !toMp3` yields m4a
or webm — exactly the case that would break. A blanket `!audioOnly` is therefore
a defensible conservative guard.

What is probably true, and is worth testing rather than assuming: for `toMp3`
jobs yt-dlp embeds the cover through **ffmpeg**, which *is* bundled, so
`job.embedThumbnail && (!audioOnly || toMp3)` would likely work. Verify on a
device before shipping it.

### F6 — a title starting with `.` produces a hidden file
`DownloadEngine.kt:2980` (via yt-dlp) · silent failure · **ရှားပါး** · looks like data loss · **trivial**

yt-dlp's `sanitize_filename` does `result = result.lstrip('.')` only under
`if not is_id:`, and on this path `is_id` is the truthy `NO_DEFAULT` sentinel —
so the strip never runs. Verified through the full `prepare_filename`:

```
'...and then this happened'  ->  '...and then this happened [ab12cd34].mp4'   hidden
'.hidden clip'               ->  '.hidden clip [ab12cd34].mp4'                hidden
```

MediaStore does not index dot-prefixed files, so the download does not appear in
the Videos tab, the Music tab, or the system gallery. It *is* reachable — the
filesystem walk deliberately includes hidden files
(`library_local_datasource.dart:343–345`) — but only behind the
"Show hidden files and folders" toggle, which the user has no reason to suspect.

The download succeeded, the bytes are on disk, and the file has vanished. That
is the worst shape a bug can take for trust.

Fix: after `finalFor` resolves, rename a leading-`.` basename to `_` + the rest,
before the `MediaScannerConnection.scanFile` call at `:3185`.

### F7 — truncate-then-sanitise can exceed 255 bytes
`DownloadEngine.kt:2980` (via yt-dlp) · crash risk · **ရှားပါး today** · download fails · **moderate**

Per §1b point 3. Arithmetic: with `k` illegal characters inside the truncated
window, the sanitised title is `cap + 2k` bytes, and the name fails when
`cap + 2k + 23 > 255`.

| cap | illegal chars needed to break it |
|---|---|
| 80B (today) | 77 |
| 150B (proposed) | 42 |
| 200B (Seal) | 17 |

At 80 it is unreachable. **At 200 it is reachable** — seventeen of `| : ? " < > * / \`
in one title is an unusual but real title on these sites. This is the concrete
reason not to simply copy Seal's number. If the cap is ever raised past ~150,
the engine should also catch `ENAMETOOLONG` from the yt-dlp error and retry the
job once with a shorter template — which is a real change, not a constant.

### F8 — a leftover sidecar can be reported as the download
`DownloadEngine.kt:3719` · silent failure · **ရှားပါး** · data confusion · **easy**

`isIntermediate` knows `.part`, `.ytdl`, `.temp` and `.fNNN.ext`. It does not
know about the subtitle files `--write-subs` (`:3104`) leaves beside the video,
which carry the same `[id]` tag. When `lastPath` has gone stale (the usual case
after a merge), `finalFor`'s fallback scan takes
`!isIntermediate(name) && name.contains(tag)`, newest-first — and a `.vtt`
written after the merge would win.

Narrow, because it needs subtitles enabled *and* a stale `lastPath`. Fix:
require the candidate's extension to be a media extension, which the app already
enumerates (`library_local_datasource.dart:337`).

### F9 — a retitled clip downloads a second time
`DownloadEngine.kt:2965` · UX · **ရံဖန်ရံခါ** · wasted data + duplicate · **moderate**

`--no-overwrites` dedupes on the whole filename. The `[id]` half is stable; the
80-byte title half is not — these sites re-title clips, and some embed a view
count or a date in the title. A changed title is a changed filename, so yt-dlp
sees no existing file and fetches the whole thing again. The user now has two
copies of one video under two names, and the `.part` from the first is orphaned.

Proper fix: before starting, scan the target directory for `*[<id>]*` and skip
if a finished match exists — the same tag scan `finalFor` already implements.

### F10 — one file, two names
`downloader_home_screen.dart:2526` vs `library_local_datasource.dart:417` · UX · **မကြာခဏ (Burmese)** · annoyance · **moderate**

Downloads and Saved show `r.title` — the full title from the probe. The Videos
tab shows the truncated on-disk name. For an English title these are the same
string; for a Burmese one they differ visibly, and searching for what you saw in
Downloads does not find the row in Videos.

Raising the cap (F1) shrinks this rather than removing it. Removing it means
persisting the full title alongside the file — a sidecar or a small index — and
having the library prefer it. Worth doing only after F1.

### F11 — `_stripIdTag` misses some real ids
`library_local_datasource.dart:441` · UX · **ရှားပါး** · annoyance · **trivial**

The regex demands 6–24 `[A-Za-z0-9_-]` **and** at least one digit. An extractor
whose ids are pure letters, shorter than 6, or longer than 24 leaves the tag
visible in the Videos tab. The digit requirement is a deliberate and good
trade — it is what keeps `[Official Video]` intact — so this should be widened
carefully or not at all. Listed for completeness, not urgency.

### F12 — an empty title becomes `NA`
`DownloadEngine.kt:2980` (via yt-dlp) · UX · **ရှားပါး** · annoyance · **easy**

Verified: `''` → `NA [ab12cd34].mp4`. yt-dlp's `outtmpl_na_placeholder`. The
template can express a better fallback itself — `%(title|%(id)s)s` or a
`,alternate` chain onto `%(webpage_url_basename)s` — with no Kotlin change.

---

## 4. How other apps do it

| | title template | length cap | non-ASCII | folder split |
|---|---|---|---|---|
| **Innocent** | `%(title).80B [%(id)s].%(ext)s` | **80 bytes** | kept | none (flat) |
| **Seal** ✔ | `%(title).200B` + optional `[%(id)s]` | **200 bytes** | kept; `--restrict-filenames` optional | per-extractor, per-playlist |
| **NewPipe** ✔ | site title, regex-replaced | **none in `createFilename`** | kept by default; one preset destroys it | none |
| **yt-dlp** ✔ | `%(title)s [%(id)s].%(ext)s` | none by default | kept | template-driven |
| 1DM / ADM ✻ | `Content-Disposition` / URL basename | OS limit | passthrough | per-category |
| uGet ✻ | `Content-Disposition` / URL basename | OS limit | passthrough | per-category |
| JDownloader ✻ | packagizer rules | configurable | passthrough | per-package |

✔ = read from source during this audit. ✻ = from documentation and general use;
**not verified against source here**, so treat the row as orientation rather
than fact.

**Seal** (`JunkFood02/Seal`, `app/.../util/DownloadUtil.kt:62`) is the most
useful comparison, because Seal and `youtubedl-android` — the library Innocent
binds — have the same author, so it is the same engine on the same OS:

```kotlin
const val BASENAME = "%(title).200B"
private const val ID = "[%(id)s]"
const val OUTPUT_TEMPLATE_ID = "$BASENAME $ID$EXTENSION"
```

**Innocent and Seal made the same two decisions** — byte precision, and an
optional `[id]` tag — independently or otherwise. That is strong evidence the
approach is right. They differ on the number, and on two things Seal offers
that Innocent does not: `--restrict-filenames` as a user toggle, and
subdirectories per extractor and per playlist title
(`SUBDIRECTORY_EXTRACTOR`, `SUBDIRECTORY_PLAYLIST_TITLE`, `:306–307`).

Note what Seal's `--restrict-filenames` toggle *does* to Burmese: it is
`restricted=True` in `sanitize_filename`, which maps every `ord(char) > 127`
either to nothing (combining marks) or to `_`. A Burmese title becomes a row of
underscores. **Innocent not having this toggle is a feature for its users**, and
if it is ever added it must not be the default.

**NewPipe** (`util/FilenameUtils.kt`, read this session) does character
replacement only:

```kotlin
private const val CHARSET_MOST_SPECIAL = "[\\n\\r|?*<\":\\\\>/']+"
private const val CHARSET_ONLY_LETTERS_AND_DIGITS = "[^\\w\\d]+"
```

`createFilename` is a single `title.replace(regex, replacementChar)` — **no
length cap at all**. And Java's `\w` is ASCII-only unless `UNICODE_CHARACTER_CLASS`
is set, so the "letters and digits" preset replaces **every Burmese character**
with `_`. Innocent is better here on both counts.

**yt-dlp's own advice**, from its README: the `B` conversion is documented as
"`B` = **B**ytes" (README:1305 region), `--trim-filenames` is explicitly
"(excluding extension) to the specified number of **characters**" (README:674),
and the default template is `%(title)s [%(id)s].%(ext)s` (README:1468). Nothing
in the documentation recommends a specific byte figure — the choice is the
application's.

**What the comparison shows.** Innocent is ahead of NewPipe on correctness and
level with Seal on approach. Where it is behind is entirely in *generosity and
visibility*: a cap 2.5× tighter than the comparable app, no subfolders, no
sidecar for the full title, and two metadata switches with no explanation and
the less useful default.

---

## 5. What is needed, nice, and not needed

### Really needed

1. **F2 — `substringAfterLast("] ")` → `substringAfter("] ")`.** One word.
   Wrong-video-behind-the-row is the worst outcome in this document that
   actually happens.
2. **F1 — `80B` → `150B`.** One token, with the arithmetic in §2 recorded in the
   comment beside it so the next person does not have to re-derive it.
3. **F3 — share `_stripIdTag` with the music scanner.** A lift-and-call.
4. **F6 — rename a leading-`.` result before the media scan.** A vanished file
   costs more trust than a failed one.

### Nice to have

5. **F4 — default `--embed-metadata` on for audio jobs.** Fixes "Unknown
   artist" for everyone who never opens Settings.
6. **F8 — require a media extension in `finalFor`'s tag scan.**
7. **F9 — dedupe on the `[id]` tag rather than the whole name.**
8. **F12 — a title fallback in the template**, so nothing is ever called `NA`.
9. **F5 — allow thumbnail embedding for `toMp3` only**, after verifying on a
   device that ffmpeg handles it without AtomicParsley.
10. **Subtitles for the two metadata switches**, saying what they cost and what
    they buy. §1g has the content.
11. **Grapheme-safe trimming.** Trim back past a trailing `Mn`/`Mc` mark and a
    dangling `U+1039`/`U+103A`/`U+200D` after yt-dlp has named the file. Cosmetic
    but it is the Burmese user's first impression of every download.

### Not needed

* **`--restrict-filenames` as a toggle.** It would destroy Burmese titles, and
  the audience is Burmese. If it is ever added for someone syncing to a strict
  filesystem, it must be off by default and labelled.
* **Per-extractor or per-playlist subfolders.** Seal has them; Innocent's
  library is search-and-scan rather than browse-by-folder, so folders would add
  a setting and change nothing the user sees.
* **A configurable output template.** One template that is right is worth more
  than a text field that can be made wrong, and every function in §1e parses
  the name this template produces.
* **`--trim-filenames`.** Characters, and applied to the whole name. Wrong tool.
* **Moving `.part` files to a temp directory (`-P temp:`).** They are already
  invisible to both the library scan (extension filter) and MediaStore, and
  `deletePartialsFor` depends on them sitting beside the output.

---

## 6. Do not touch

Things that look odd and are not.

1. **`B` (bytes) rather than `s` (characters) in the template.** The whole
   reason Burmese titles work at all. The comment at `:2977–2979` says so.
2. **`--no-mtime` (`:2981`).** Unremarked in code but load-bearing for
   `newestIn`, `finalFor`, `deletePartialsFor` and the library's sort order.
   §1d.
3. **`idTagOf` returning the brackets with the tag (`:3705`).** Prevents `[ab]`
   matching inside `[abc]`.
4. **The digit requirement in `_idTagRe` (`:441`).** It is the only thing
   keeping `[Official Video]` and `[HD]` out of the stripper.
5. **`--no-overwrites` beside `--continue` (`:2957`, `:2965`).** Not redundant:
   finished files skip, partial files resume. The comment explains it.
6. **`deletePartialsFor` doing nothing when there is no tag (`:3636`).**
   Deliberate: "leaking a few early kilobytes beats deleting a neighbour's
   gigabyte."
7. **`newestIn` surviving as a last resort (`:3650`).** It is wrong under
   concurrency, which is why it is last — but it is the only thing that works
   when yt-dlp announced no destination at all. Fixing F2 makes it rarer, not
   unnecessary.
8. **`embedThumbnail`/`embedMetadata` gated on `ffmpegError == null`
   (`:3099`).** Post-processors fail the whole download; skipping them is right.
9. **The flat download folder (`downloader_providers.dart:20–27`).** The comment
   gives three specific reasons (scoped-storage writability, MediaStore
   indexing, uninstall survival). Not an oversight.
10. **`writeInfoJson` keying its cache on `url.hashCode` (`:3452`).** Collisions
    are possible in principle; the file is a per-job cache in `cacheDir` and a
    wrong hit is corrected by the retry loop dropping to `useInfo = false`.
11. **The filesystem walk including dot-files while the folder picker excludes
    them.** Opposite rules, both correct: the library exists to surface hidden
    media (`:343`), the transfer picker exists to avoid sending app caches to a
    friend (`folder_send_picker.dart:97`).

---

## Sources

* yt-dlp `2026.08.19`, installed and executed for every measurement in §1b, §1e
  and §2. `YoutubeDL.py:1480` (the `B` conversion), `YoutubeDL.py:1387–1402`
  (which sanitiser is chosen), `utils/_utils.py` `sanitize_filename`.
* yt-dlp README (master): `:674` `--trim-filenames`, `:1305` conversion list,
  `:1468` default template.
* Seal — `JunkFood02/Seal`, `app/src/main/java/com/junkfood/seal/util/DownloadUtil.kt`
  `:62`, `:70–81`, `:306–307`. Read this session.
* NewPipe — `TeamNewPipe/NewPipe`,
  `app/src/main/java/org/schabi/newpipe/util/FilenameUtils.kt`. Read this
  session.
* Innocent README, §"v1.40.0+252 — the download list, cleaned up and honest",
  which records the same-title collision this naming scheme was built to fix.
* 1DM, ADM, uGet and JDownloader rows in §4 are **not** source-verified.

## Changelog

* 2026-09-12 — first version. No code changed.
