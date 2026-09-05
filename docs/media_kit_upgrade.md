# Upgrading `media_kit_video` — what the versions actually contain

Researched against pub.dev on 26 Aug 2026. Written down because the pin at
`^1.2.4` is the reason this project carries a hand-built workaround for
screen-off playback, and every future session otherwise re-derives the same
question from scratch.

## Why anyone would upgrade

Screen-off playback currently works by writing `vo=null` and
`force-window=no` to libmpv on the way into the background, restoring them on
the way out, and running a watchdog for the first five seconds because the
cold-start case races. That stack exists because `1.2.4` renders through
`SurfaceTextureEntry`, which Android may destroy when the app stops being
visible, with no callback the plugin acts on.

`1.3.0` is the version that changes this: its Android changelog entry is the
`VideoOutput` migration from `SurfaceTextureEntry` to `SurfaceProducer`, plus a
simplification of `AndroidVideoController`. `SurfaceProducer` is Flutter's
newer API precisely for plugins that render to a surface, and it provides
surface lifecycle callbacks so the plugin can recreate the surface itself when
the app is resumed.

So the upgrade is not a nice-to-have. It is the difference between the engine
handling surface loss and this app hand-managing it around the engine's back.

## The version landscape

| Version | What it is | Verdict |
|---|---|---|
| `1.2.4` | Current pin. `SurfaceTextureEntry` rendering. | Where we are |
| `1.3.0` | **The SurfaceProducer migration.** Also many unrelated fixes. | The target — but see `1.3.1` |
| `1.3.1` | Android `VideoController` fixes + removes deprecated API usage. Last of the `1.x` line. | **Go here, not `1.3.0`** |
| `2.0.0` | Flutter 3.38.x support. **BREAKING**: drops the `screen_brightness` and `volume_controller` dependencies. | Later, deliberately |
| `2.0.1` | Fixes a Flutter 3.38.x crash. Current latest (published Dec 2025). | Later |

`1.3.1` gets the whole benefit with the smallest blast radius: it is the
settled version of the migration, and it stays inside the major that the rest
of the pubspec was resolved against.

## Three traps, in the order they will bite

**1. The Flutter floor is probably higher than our pubspec says.**
`pubspec.yaml` declares `flutter: '>=3.22.0'`. Flutter's own migration guide
for this API says plugins moving to `SurfaceProducer` should set **3.24** as
their minimum constraint, and that `onSurfaceCreated` was later deprecated in
favour of `onSurfaceAvailable` in Flutter 3.27. An earlier note in this project
claimed `1.3.x` fits inside `>=3.22.0` — treat that as unverified and probably
wrong. **Check FlutLab's actual Flutter version first**; if it is below 3.24,
nothing else in this document matters yet.

**2. `screen_brightness` may be dragged to a new major.**
The `1.3.0` refactor moved from `screen_brightness` to
`screen_brightness_platform_interface`. This app pins `screen_brightness:
^0.2.2+1` directly and `lib/core/services/brightness/brightness_service.dart`
is written against that API. If the resolver pulls a newer major to satisfy
`media_kit_video`, `BrightnessService` breaks — and it will break at compile
time in FlutLab, not here, because nothing in `tool/` knows about package
versions. Read the resolved versions after `pub get` and before assuming the
build failure is about the player.

**3. `2.0.0`'s breaking change is NOT a problem for us — check anyway.**
It removes `screen_brightness` and `volume_controller` as dependencies. This
app declares `screen_brightness` and `flutter_volume_controller` itself
(note: `flutter_volume_controller`, a different package from the
`volume_controller` that media_kit dropped), so losing the transitive copies
costs nothing. Recorded so that nobody reads "BREAKING CHANGE" and abandons the
upgrade for the wrong reason.

## How to do it without losing five releases

The workaround and the migration must not be removed in the same build. The
whole point of the `vo=null` stack is that it is invisible when it works, so
removing it and the rendering path together makes a failure unattributable.

1. **Bump only.** `media_kit_video: ^1.3.1`, nothing else changed. Build.
   Confirm ordinary playback, seeking, fullscreen and the floating window still
   work. This is a minor version bump because it changes native rendering.
2. **Test screen-off with the workaround still in place.** It should still
   work; `vo=null` is not incompatible with `SurfaceProducer`, just redundant.
   If this build is broken, the migration is the cause and nothing has been
   thrown away.
3. **Only then**, in a separate build, neuter the workaround — make
   `setBackgroundAudioMode` a no-op behind a flag rather than deleting the code
   — and test screen-off again. If it still works, the engine is now handling
   it and the code can go. If it does not, flip the flag back; you have lost
   one build, not the subsystem.
4. Delete `_armDetachWatchdog`, `_voForRestore`, `_surfaceGen`, `_surfaceOp`
   and the four-attempt commentary **only after step 3 has shipped and
   survived**. That commentary is the most expensive thing in the file; it is
   the record of what was already tried.

## What to keep even after the migration

`_surfaceGen` / `_surfaceOp` guard against two transitions overlapping. If
`setBackgroundAudioMode` goes away entirely they go with it. But if ANY
awaited multi-step property sequence remains on the surface path, the
generation guard stays — the bug it closes (a superseded transition finishing
on top of the one that replaced it) is a property of awaited sequences, not of
this particular workaround.
