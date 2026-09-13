# Domain 3 — the Private Folder: an audit

*12 September 2026. No code changed by this document.*

Covers the vault service, the PIN and recovery paths, the anti-theft
features (decoy PIN, intruder selfie, break-in log), the file picker, and the
Camera2 capture on the native side.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, UX.

## The short version

**The cryptography and the file-moving are the strongest code in this
repository.** This domain has been audited at least five times before
(README §v0.51.8, §v0.52.4, §v1.49.0 *"audited end to end"*, §v1.64.3 *"the
vault's cryptography is now checked against a reference"*, §v1.64.5), and it
shows: PBKDF2-HMAC-SHA256 with a device-calibrated round count, constant-time
comparison, a per-install salt committed *before* the hash that depends on it,
a persisted five-attempt lockout with escalating tiers, and a copy → verify →
delete import order that cannot lose the user's only copy.

The findings are elsewhere, and two of them matter:

* **The intruder camera is never closed on the success path.**
  `device.close()` appears in five failure branches and in none of the
  successful ones; `reader.close()` appears nowhere at all. So a *successful*
  intruder selfie leaves the front camera open for the life of the process —
  which on Android 12+ means the **camera-in-use indicator stays lit** and no
  other app can open the front camera until Innocent is killed. On a vault
  app, a camera dot that never goes out is the worst possible signal.
* **Nothing tells the user the vault dies with the app.** Vaulted files live
  in `getApplicationSupportDirectory()`, and the originals are deleted at
  import by design. An uninstall — or Settings → Apps → Innocent → *Clear
  data* — destroys every vaulted video permanently. There is no string
  anywhere that says so. That is the largest data-loss exposure in the app and
  it is a wording problem, not an engineering one.

And one thing that must be written down rather than fixed: **the vault does
not encrypt file contents.** It moves them somewhere other apps cannot reach.
The PIN protects the interface, not the bytes.

**Three candidate findings were withdrawn after checking**, including one I
was sure of. They are in §3.

---

## 1. The threat model, stated plainly

The service's own header says it, and it is worth quoting because everything
downstream follows from it:

> Vaulting (see `importToVault`) copies the file into the app's internal
> support dir — not indexed by MediaStore and not reachable by other apps /
> file managers without root — verifies the copy, then deletes the original.

So the vault defends against:

| threat | defended? | by what |
|---|---|---|
| someone picking up the unlocked phone | **yes** | PIN, lockout, auto-lock |
| the gallery / another file manager | **yes** | app-internal dir, `.nomedia`, MediaStore row purged at import |
| a shoulder-surfed PIN | **partly** | decoy PIN, intruder log |
| offline PIN guessing from a device image | **yes** | PBKDF2 + per-install salt + keystore-backed store |
| **a rooted phone** | **no** | — |
| **`adb backup` / a physical extraction** | **no** | — |
| **a forensic image of the device** | **no** | — |

The random 24-character vault filenames raise the cost of a casual look
through the directory and nothing more; the bytes are the original file.

**This is a defensible design, not a defect.** Full-file AES over multi-gigabyte
video on a mid-range phone would make importing unusable and would double the
write wear. Every mainstream "vault" app on Android makes the same trade. It
belongs in this document so that the next person deciding whether to advertise
the feature as *encryption* knows the answer is no.

Checked, and clean: none of the eight vault-related strings in
`app_localizations_en.dart` claims encryption.

---

## 2. Findings

Likelihood: မကြာခဏ (often) / ရံဖန်ရံခါ (sometimes) / ရှားပါး (rare).

### V1 — the intruder camera is never closed on the success path
`MainActivity.kt:2403–2515` · unclosed resources · **မကြာခဏ (whenever the feature is on)** · privacy-alarming · **easy**

`captureIntruderSelfie` opens a `CameraDevice`, creates an `ImageReader`,
configures a session and captures one frame. Tracing every `close()` inside
the function:

| line | what closes | branch |
|---|---|---|
| `:2448` | `image` | inside the reader listener |
| `:2481` | `device` | `session.capture` threw |
| `:2489` | `device` | `onConfigureFailed` |
| `:2496` | `device` | `createCaptureSession` threw |
| `:2502` | `device` | `onDisconnected` |
| `:2507` | `device` | `onError` |

**Five closes, all on failure paths.** On the path where everything works —
`onOpened` → `onConfigured` → `session.capture` → the reader listener fires →
`finish(path)` — the `CameraDevice` and the `CaptureSession` are never closed,
and `reader.close()` does not appear anywhere in the file.

The reason it was missed is visible in the structure: `device` is only in
scope inside `onOpened`, and the success path completes in the
`ImageReader` listener, which cannot see it.

What the user experiences: three wrong PINs, a photo is taken, and from then
on the front camera is held by Innocent. On Android 12+ the system shows a
**persistent camera-in-use indicator**; the phone's own Camera app fails to
open the selfie camera; some OEM ROMs show a notification. All of it until the
process dies.

Fix: hoist the device, session and reader into variables the `finish()`
closure can see, and close all three there. `finish` is already idempotent and
already the single exit point, so it is the right place.

### V2 — the safety timeout closes nothing either
`MainActivity.kt:2513` · unclosed resources · **ရံဖန်ရံခါ** · same · **easy (same fix)**

```kotlin
camHandler.postDelayed({ finish(null) }, 4000)
```

A camera that opens and never delivers a frame — a real case on OEM ROMs where
the front camera is claimed by a face-unlock service — hits this timeout,
reports failure, and leaves the device open. Same fix as V1: once `finish()`
closes the resources, this path is covered for free.

### V3 — nothing warns that the vault dies with the app
`private_folder_service.dart:_vaultDir` · UX / data loss · **ရံဖန်ရံခါ** · **total, unrecoverable** · **trivial (a string)**

The vault is `getApplicationSupportDirectory()/private_vault`, and
`importToVault` deletes the original after a verified copy — correctly, because
that is the whole point of vaulting.

The consequence is that **the only copy of every vaulted video is inside the
app's private data**. It is destroyed by:

* uninstalling Innocent,
* Settings → Apps → Innocent → *Clear data* (one tap past a generic
  system dialog that says nothing about videos),
* some "phone cleaner" apps and factory-reset-adjacent OEM tools.

Grepping every vault string in `app_localizations_en.dart`: the only
"permanent" warnings are about explicitly deleting a file **from** the vault.
Nothing mentions uninstall, clear-data, or backup.

This is not a bug in any function. It is the one place where the design's
consequence is not communicated, and the consequence is the worst kind:
silent, total, and arrived at through a perfectly ordinary action.

The cheap fix is two strings — one on the import confirmation, one in the
vault's own settings. The complete fix is an "Export all" that writes the
vault back to public storage, which the restore path already knows how to do
one file at a time.

### V4 — restore's fallback lands somewhere the user cannot find
`private_folder_service.dart:1465` · silent failure + UX · **ရံဖန်ရံခါ** · looks like data loss · **easy**

```dart
targetDir = (await getExternalStorageDirectory()) ??
    await getApplicationDocumentsDirectory();
```

The comment fourteen lines above says the fallback is *"the public Movies dir
/ app docs"*. It is not. On Android, `getExternalStorageDirectory()` returns
`/storage/emulated/0/Android/data/<package>/files` — app-private, **sandboxed
from the user's own file manager on Android 11+**, not indexed by MediaStore,
and deleted on uninstall.

So restoring an entry whose original path cannot be resolved (a soft-hidden
`content://` item) reports success and puts the file somewhere the user cannot
browse to and the gallery will never show. It also puts it back in exactly the
storage that V3 is about.

Fix: write to the public Movies directory and `MediaScannerConnection.scanFile`
it — both of which this app already does on the download path.

### V5 — the restore filename is the only unsanitised one in the app
`private_folder_service.dart:1467` · crash risk · **ရှားပါး** · a failed restore · **trivial**

```dart
fileName = '${e.videoTitle}$ext';
```

`videoTitle` goes straight into `p.join` with no sanitising. In practice it
comes from MediaStore's `DISPLAY_NAME` or a basename, neither of which can
contain a separator, so this is very unlikely to fire.

It is listed because it is **inconsistent with the rest of this codebase**,
which takes filename injection seriously enough to have fuzzed it: README's
security section records 30,000 cases against the Transfer receiver's name
sanitising, including a `.`/`..` survivor. The vault restore is the one write
path that does not go through anything equivalent.

---

## 3. Withdrawn after checking

**The intruder selfie looked like a feature with no implementation.** There is
a settings toggle, three localisations of *"Silently takes a photo after 3
wrong PIN entries"*, an `IntruderEvent.photoPath` field, a persisted log and a
viewer screen — and no camera package in `pubspec.yaml`. It is implemented in
Kotlin with Camera2 at `MainActivity.kt:2403`, reached over the
`mx_clone/intruder_cam` channel, and the runtime permission is requested when
the toggle is switched on (`private_folder_antitheft.dart:513`). The feature
works; V1 and V2 are about what it fails to release afterwards.

**`_copyWithProgress` looked like it could strand a partial file** on a
storage-full failure — the exact failure mode that would silently cost a user
gigabytes. It closes the sink *first*, with a comment explaining that an open
fd on Android would make the subsequent delete fail, then deletes the partial
on any abnormal exit including cancel. The docstring above it says why
`File.copy()` was rejected, in terms of this specific failure.

**The import verification looked like a length-only check.** The class header
says the copy is *"VERIFIED byte-for-byte by length"*, which reads as a
contradiction and sent me looking. The actual check
(`private_folder_service.dart:1281–1291`) is length **plus** a SHA-256
fingerprint over the head and tail 64 KB, with the reason for not hashing
multi-gigabyte files written out beside it. Only the header comment is loose;
the code is right.

---

## 4. What the six categories look like here

**Crash risk — V5 only, and it is theoretical.** Everything that touches the
filesystem is wrapped, and the failure branches are as carefully written as
the success ones.

**Silent failure — V4.** A restore that reports success and hides the file.

**Race conditions — none found.** The one ordering hazard in this domain (a
crash between writing the salt and writing the hash, which would be a
permanent lockout) is called out in a comment at `:589` and handled by
committing the salt first.

**Unclosed resources — V1 and V2, both in the Camera2 path.** The Dart side is
clean: the picker's one `ScrollController` is disposed, the copy sink is closed
on every path.

**Invisible waits — none.** Import and restore both stream with a byte
counter and a working Cancel, and `VaultCancelled` exists as its own type
specifically so a cancellation is never reported as a failure — the comment
notes that a user told their import *failed* might go and delete an original
they still need.

**UX — V3 is the finding, and it is the biggest one here.** Everything else in
this domain communicates well: the break-in log records *which digits* were
tried and *which door* (PIN, security answer, or recovery key), which is the
difference between "a stranger poked at the phone" and "someone who has
watched me unlock it".

---

## 5. What is needed, nice, and not needed

### Really needed

1. **V1 + V2 — close the camera, the session and the reader in `finish()`.**
   A vault app that leaves the camera light on is doing the one thing its
   users would least forgive.
2. **V3 — say that the vault lives inside the app.** Two strings. The
   engineering is already correct; the user just is not told what it means.

### Nice to have

3. **V4 — restore to public Movies and scan it.**
4. **An "Export all" in the vault's settings**, which turns V3 from a warning
   into a way out.
5. **V5 — sanitise the restore filename**, for consistency with the receiver.
6. **Fix the "byte-for-byte by length" header comment** so the next reader
   does not go looking for a bug that is not there.

### Not needed

* **Encrypting vault contents.** See §1. It would make importing a
  multi-gigabyte film unusable on the phones this app targets, and every
  mainstream Android vault makes the same trade. Record the threat model
  instead.
* **Hashing the whole file at import.** The head+tail fingerprint plus length
  catches truncation and partial writes, which are the failures that actually
  happen, at a fraction of the I/O.
* **Raising the PBKDF2 round count as a constant.** It is calibrated per
  device against a wall-clock budget, which is the correct shape: a fixed
  number is either too slow on a cheap phone or too fast on an expensive one.
* **A shorter lockout ladder.** 15 / 60 / 300 / 900 seconds after every fifth
  attempt, persisted across restarts, is already stricter than most.

---

## 6. Do not touch

1. **The copy → verify → delete order**, and keeping the vault copy when the
   original delete is refused (`originalRemoved`). A failed lock can never
   lose the only copy.
2. **`_copyWithProgress` instead of `File.copy()`** — the docstring records
   that a 4 GB import failing on a full disk used to cost 4 GB, invisibly and
   permanently.
3. **Closing the sink before deleting the partial.** An open fd makes the
   delete fail on Android, which would defeat the whole point.
4. **PBKDF2 with a device-calibrated round count** and the v2/v1/v0
   verify-then-upgrade ladder, so an old hash still opens and is then
   rewritten at full strength.
5. **The constant-time comparison**, and the salt being committed before the
   hash that depends on it (`:589`).
6. **The decoy PIN being checked after the real one** (`:193`) — the other
   order lets a decoy shadow the real PIN and silently lock the owner out of
   their own vault.
7. **The persisted lockout** (5 attempts; 15/60/300/900 s), including the note
   at `:467` that the "wrong PIN" feedback must not be delayed or the pause
   itself becomes an oracle.
8. **Recording the attempted digits and the method in the break-in log.**
9. **Random 24-character vault filenames plus `.nomedia`.**
10. **`freeSpaceBytes()` measuring the vault's own volume** rather than reusing
    the Transfer receiver's answer — the docstring explains that a free-space
    check against the wrong volume is worse than none.
11. **`VaultCancelled` as a distinct exception type.**
12. **Purging the dangling MediaStore row at import** (`_mediaScan`), so the
    title and thumbnail leave the gallery at once.
13. **Restore dropping the vault copy when the original was never removed**,
    rather than copying a multi-gigabyte file back to sit beside itself.

---

## Sources

* Read this session: `private_folder_service.dart`,
  `private_folder_antitheft.dart`, `add_files_picker.dart`,
  `MainActivity.kt` (the Camera2 capture), `AndroidManifest.xml`,
  `app_localizations_en.dart` (vault strings).
* README §v1.64.3, §v1.64.5, §v1.49.0, §v0.52.4, §v0.51.8 — the previous
  audits of this domain.
* `getExternalStorageDirectory()`'s mapping to
  `Android/data/<package>/files`, and its sandboxing on Android 11+, is stated
  from the platform's documented behaviour and was **not** re-verified on a
  device this session.

## Changelog

* 2026-09-12 — first version. No code changed.
