# Domain 5 — Library, Music and Settings: an audit

*13 September 2026. No code changed by this document.*

The last of the five domain audits. Covers the Local/Videos browser and its
cache, the Music tab, the Settings tree, and the shared preference services —
about 26,000 lines, the largest of the five domains.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, UX.

## The short version

**Five settings the app never consults.** A user can open Settings, change
them, watch the subtitle update to show their new value, and nothing anywhere
acts on it:

| setting | screen | what it claims to do |
|---|---|---|
| `scanFolders` | List | which folders the library scans |
| `bluetoothAudioDelay` | Audio | audio delay while on Bluetooth |
| `videoZoomDelay` | Player | *"Delay before HW resize kicks in"* |
| `hwPlusVideoCodecs` | Decoder | which codecs HW+ handles |
| `hwPlusAudioCodecs` | Decoder | which codecs HW+ handles |

Each carries a comment from a previous pass saying it was *wired* — and it
was, **to the key rather than to the behaviour**. The settings screen reads
and writes the preference correctly; nothing downstream ever asks for it.

**This is the single most repeated bug class in this project.** Grepping for
the comments that record a previous instance — *"had no reader"*, *"nothing
read"*, *"nothing that read"* — returns **ten**, each marking a setting that
was found dead and then wired up:

```
app.dart:140                          "Cache thumbnail" and one other
local_screen.dart:650                 List → "Floating button"
video_option_menu.dart:661, :704      delete confirmation, and one more
library_local_datasource.dart:315     List → "File extensions"
settings_general_screen.dart:394      App language
settings_list_screen.dart:178         two PlayerSetting keys
player_controller_navigation.dart:113 Previous-button behaviour
player_screen.dart:235, :388          a description with no reader; a pause
```

Ten found and fixed, one at a time, as somebody happened to notice. The five
below are the ones still outstanding — and §4 argues that after ten
recurrences this deserves a check in `tool/check.py` rather than an
eleventh discovery.

The two that sting most are the ones whose **sibling on the same screen
works**:

* `scanExtensions` was wired all the way through to
  `LibraryLocalDataSource.setExtensionFilter`. `scanFolders`, on the same
  screen, was not — the walk still visits `/storage/emulated/0` and every
  removable volume unconditionally.
* `audioDelay` is applied at `player_controller_playback.dart:221`.
  `bluetoothAudioDelay`, the field directly below it in the same section, is
  not. Someone with earbuds fixing their lip-sync will use the wrong one of
  two adjacent controls and find that only the wrong one works.

Two other findings, and then this domain is clean: the Videos cache decides
staleness by **counting**, and the hidden-files walk has no ceiling.

**And one candidate withdrawn after checking** — I nearly filed a sixth dead
setting that turned out to be a deliberate mirror. §3.

---

## 0. Correction — it is 35, not 5

*Added 13 September 2026, when `tool/dead_settings.py` was written.*

**L1 below undercounts by sevenfold.** The sweep it describes extracted the
enum values from `extra_settings_service.dart` and grepped each one. It never
looked at **`PlayerSetting`**, which lives in a different file
(`player_settings_service.dart`) and has a hundred values — and **thirty of
those are dead too**.

The full list is in `tool/dead_settings.py`'s `KNOWN_OPEN`, grouped by the
screen that offers each control. The worst concentrations:

| screen | dead controls |
|---|---|
| Decoder | 7 |
| Player | 6 |
| List | 3 (+ `scanFolders`) |
| Subtitle | 3 |
| Audio | 2 (+ `bluetoothAudioDelay`) |
| Style, Screen, General | 2 each |
| Development | 1 |
| **referenced nowhere at all** | **2** — `listRecognizeNomedia`, `listShowHiddenFiles` |

Those last two are not even read back by a settings screen. They are pure dead
code and the cheapest thing on the list.

**This is the argument for a check rather than a sweep, in one paragraph.** The
sweep was careful, its method is written out in §1, and it still missed 86% of
the problem because it looked in one file. The check looks at every enum in
every preferences file, and it is now the thing that has to be satisfied rather
than somebody's attention.

§1 below is left as written — it was accurate about the five it found and
about *why* they matter, and the two it singles out (`scanFolders` and
`bluetoothAudioDelay`, whose siblings on the same screen work) are still the
best examples of the shape.

---

## 1. Findings

Likelihood: မကြာခဏ (often) / ရံဖန်ရံခါ (sometimes) / ရှားပါး (rare).

### L1 — five settings nothing reads
`extra_settings_service.dart` + five settings screens · UX · **မကြာခဏ (for anyone who opens Settings)** · annoyance · **easy each, five separate jobs**

Method, so this can be re-run: every `StringSetting` / `IntSetting` enum value
was extracted from `extra_settings_service.dart`, then each was grepped for
across `lib/`, and any whose only references live under
`lib/features/settings/` was flagged — because a reference there is the screen
reading its own value back to display it, not the feature consulting it.

Six came back. One is a deliberate mirror (§3). These five are real:

**`scanFolders`** — `settings_list_screen.dart:107`. The comment above it
names the default as "Internal storage only". `scanFilesystemVideos()`
(`library_local_datasource.dart:354`) walks `/storage/emulated/0` and then
enumerates `/storage` and adds every removable volume it finds, consulting
nothing. Its sibling `scanExtensions` on the same screen *is* wired, through
`setExtensionFilter` — and that function's own docstring records the fix:
*"Settings → List → 'File extensions' persists a pipe-separated list that
nothing read"*. The same sentence is true of `scanFolders` today.

**`bluetoothAudioDelay`** — `settings_audio_screen.dart:198`. `audioDelay` is
read and applied (`player_controller_playback.dart:221`, and a change-watcher
at `player_provider.dart:542`). Nothing reads the Bluetooth variant. Two
adjacent controls, one works.

**`videoZoomDelay`** — `settings_player_screen.dart:328`. The subtitle
promises *"Delay before HW resize kicks in. Higher = fewer flickers"*. No
resize path consults it.

**`hwPlusVideoCodecs` / `hwPlusAudioCodecs`** — `settings_decoder_screen.dart:113`,
`:150`. The comment says *"wire HW+ video codecs to
StringSetting.hwPlusVideoCodecs"*, and that is exactly what happened: the
screen is wired to the setting. The decoder is not wired to either.

**On fixing them.** Not all five deserve the same answer. `scanFolders` and
`bluetoothAudioDelay` are small and worth implementing — the readers they need
are one line each in code that already exists. `videoZoomDelay` and the two
HW+ codec lists reach into libmpv's decoder configuration and are a real
piece of work; **removing them from the UI is a legitimate outcome and may be
the better one**, because a control that does nothing is worse than an absent
control. What should not happen is a third pass that wires them to the key
again.

### L2 — the Videos cache decides staleness by counting
`library_provider.dart:373` · silent failure · **ရံဖန်ရံခါ** · a row that plays nothing · **trivial**

`foldersProvider` and `allVideosProvider` are both cache-first: return the
cached snapshot immediately, refresh in the background, invalidate if the
fresh result differs. They disagree about what "differs" means.

```dart
// foldersProvider — a set difference
bool _hasFolderDiff(List<Folder> a, List<Folder> b) {
  if (a.length != b.length) return true;
  final aPaths = a.map((f) => f.path).toSet();
  final bPaths = b.map((f) => f.path).toSet();
  return aPaths.length != bPaths.length || !aPaths.containsAll(bPaths);
}

// allVideosProvider — a count
if (fresh.length != cached.length) {
  ref.invalidateSelf();
}
```

So any change that leaves the count the same is invisible until the next cold
start: **a file renamed**, **a file replaced**, or **one deleted and one added
between two launches**. The fresh list *is* written to the cache
(`cache.saveAllVideos(fresh)` runs either way), so this self-corrects on the
next launch — but in the meantime the Videos tab lists a file that is gone,
and tapping it fails.

The fix is to give `allVideosProvider` the same shape `_hasFolderDiff` already
has, over `uri` instead of `path`.

### L3 — the hidden-files walk has a depth cap and no file cap
`library_local_datasource.dart:378` · invisible wait · **ရံဖန်ရံခါ (only with the toggle on)** · jank · **moderate**

`_walkForVideos` guards recursion at `depth > 16` and nothing else. It walks
every directory under `/storage/emulated/0` and each removable volume,
`stat()`-ing every file whose extension matches, **on the main isolate** —
there is no `compute()` anywhere in this file.

Compare the Transfer tab's folder picker, which faces the same hazard and caps
it explicitly:

```dart
// folder_send_picker.dart:50
static const int _maxFiles = 3000;
static const int _maxDepth = 12;
```

with a comment that says why: *"Someone will point this at the storage root
sooner or later. Without a ceiling that is a multi-minute freeze that ends in
an out-of-memory kill."* The library walk **is** pointed at the storage root,
by design, every time.

Mitigating it: the walk only runs behind the "Show hidden files and folders"
toggle, and the ordinary path uses MediaStore, which is indexed and fast. So
this is not the default experience. But the users who turn that toggle on are
exactly the ones with a crowded phone.

Two independent fixes, either of which is enough: a file ceiling like the
picker's, or moving the walk into a `compute()` so a long scan cannot block
the frame. The music scanner already does the second thing for tag reading
(`music_local_datasource.dart:79`) and explains why.

### L4 — four `late final` subscriptions make `dispose()` fragile
`music_providers.dart:534–537` · crash risk · **ရှားပါး** · a leaked audio-focus claim · **trivial**

`MusicPlayingNotifier`'s constructor assigns `_focusSub` (nullable) and then
four `late final StreamSubscription` fields. `dispose()` cancels them in order
starting at `_posSub.cancel()` (`:1187`).

If the constructor throws part-way — `_audio.positionStream` unavailable, say —
then `_posSub` is unassigned, `dispose()` throws `LateInitializationError` on
its second statement, and everything after it is skipped: `_errorSub`,
`_focusSub`, and the `abandon()` that releases the audio-focus claim. Other
apps would then find their audio ducked by an app that is gone.

Narrow, because the constructor rarely throws. Trivial to remove: make the
four nullable and cancel with `?.`, the way `_errorSub` and `_focusSub`
already are.

### L5 — the Music tab shows the `[id]` tag (cross-reference)

Already filed as **F3** in `docs/filename_audit.md`: the video scanner strips
the downloader's `[id]` tag and the music scanner does not, so downloaded
audio reads `Some Song [xy77zz11aa]` in Tracks. Not repeated here.

---

## 2. What the six categories look like here

**Crash risk — L4 only.** **Zero `!` null-assertions** across all 26,000 lines
of this domain, which is the same result the Player domain gave and is not a
coincidence.

**Silent failure — L1 and L2.** L1 is the larger one by far, because it is
five features rather than one bug.

**Race conditions — none found.** The cache-first providers write the fresh
result before deciding whether to invalidate, so a refresh that loses the race
with a rebuild still leaves the right data on disk.

**Unclosed resources — nothing found.** `MusicPlayingNotifier` cancels all
seven of its subscriptions and its sleep ticker and releases its audio-focus
claim; the album-art extraction is behind a device-sized `ConcurrencyLimiter`
because *"flinging through the music list would otherwise start dozens
[of isolates] at once"*; every screen with a controller disposes it.

**Invisible waits — L3.** Everything else is cache-first by construction: the
library shows a cached snapshot immediately and refreshes behind it, and the
music scan reads all tags in a single background isolate rather than one per
file, with the reason recorded.

**UX — L1 is the finding**, and it is the most user-visible thing in any of
the five audits: not a crash, not a hang, just five controls that quietly do
nothing.

---

## 3. Withdrawn after checking

**`userLocale` looked like a sixth dead setting.** It is referenced only
inside `features/settings/`, and the comment above it even says *"This used to
write StringSetting.userLocale, which nothing read"* — which reads like an
unfixed confession.

It is the opposite. The comment goes on to explain that the control now drives
`localeProvider`, the same state the dedicated Language screen uses, and the
write to `StringSetting.userLocale` that remains is a deliberate mirror *"so
anything reading that key (diagnostics, future export) agrees"*. The app
re-renders in the chosen language immediately.

**Worth stating because it is the trap in this whole check**: "only referenced
under `features/settings/`" finds dead settings *and* correctly-mirrored ones,
and only reading the surrounding comment tells them apart. Anyone re-running
the method in §1 should expect that and check each hit by hand rather than
trusting the list.

---

## 4. What is needed, nice, and not needed

### Really needed

1. **L1 — decide, per setting, between implementing and removing.** Five
   separate small jobs, not one. `scanFolders` and `bluetoothAudioDelay` are
   worth implementing; the other three are worth considering for removal. A
   control that does nothing is worse than no control.
2. **L2 — give `allVideosProvider` the diff that `foldersProvider` already
   has.** Four lines, copied from twenty lines above it.

### Nice to have

3. **L3 — a file ceiling on the hidden-files walk**, matching the picker's
   3,000, or move it into a `compute()`.
4. **L4 — make the four subscriptions nullable.**
5. **A check in `tool/check.py` for settings nothing reads — and this one is
   closer to "needed" than the rest of this list.** Ten prior instances are
   recorded in the tree's own comments and five more are open; that is not bad
   luck, it is a missing check. The method in §1 is about twenty lines, it fits
   the shape of the eight structural checkers already there, and its only
   awkward part is the `userLocale` mirror, which needs an allow-list entry —
   see §3.

### Not needed

* **Moving the MediaStore path off the main isolate.** It is indexed and fast;
  L3 is only about the raw walk behind the hidden-files toggle.
* **Caching album art in the bulk scan.** Deliberately lazy, with the limiter
  above it; loading art for a list the user is flinging past is work thrown
  away.
* **Unifying the library and music scanners.** They read different MediaStore
  collections with different fallbacks; the one thing they *should* share is
  `_stripIdTag`, which is F3 in the filename audit.

---

## 5. Do not touch

1. **Cache-first providers** — a cached snapshot returned immediately with the
   refresh behind it is what makes the tab open instantly on a cold start.
2. **Writing the fresh result to the cache even when not invalidating**
   (`library_provider.dart:372`). It is why L2 self-corrects on the next
   launch instead of persisting.
3. **The `ConcurrencyLimiter` on album art** (`music_local_datasource.dart:19`)
   and its `adaptiveMediaConcurrency()` sizing.
4. **Reading every tag in one `compute()`** rather than one per file
   (`music_local_datasource.dart:79`) — the docstring records that per-file
   reads janked the scan.
5. **The filesystem walk including dot-files and `.nomedia` folders**
   (`library_local_datasource.dart:343`). That is the entire purpose of the
   walk; MediaStore deliberately omits them.
6. **Skipping `Android/data` and `Android/obb` on Android 11+ while still
   trying `Android/media`** (`:382`).
7. **`_stripIdTag`'s digit requirement** (`:441`) — it is what keeps
   `[Official Video]` and `[HD]` out of the stripper.
8. **`_stripExt` refusing to strip anything over five characters or
   non-alphanumeric** — so `Clip.2026.final` keeps its name.
9. **Claiming audio focus only when playback starts**, not in the constructor
   (`music_providers.dart:579`).
10. **`userLocale` being mirrored rather than read.** See §3 — and leave the
    comment there, because it is the only thing that stops the next audit
    deleting it.

---

## Sources

* Read this session: `library_provider.dart`, `library_local_datasource.dart`,
  `music_providers.dart`, `music_local_datasource.dart`,
  `extra_settings_service.dart`, `settings_list_screen.dart`,
  `settings_audio_screen.dart`, `settings_player_screen.dart`,
  `settings_decoder_screen.dart`, `settings_general_screen.dart`,
  `folder_send_picker.dart` (for the contrast in L3).
* The dead-settings sweep in §1 was produced by extracting the enum values and
  grepping each, then checking every hit by hand — see §3 for why the hand
  check is not optional.

## Changelog

* 2026-09-13 — first version. No code changed.
