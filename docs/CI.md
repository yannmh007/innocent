# Building Innocent without FlutLab

Written 4 Sep 2026, against v1.64.7+320.

## Why

For sixty-odd builds the loop has been: zip the tree, upload it to FlutLab,
press Build, wait, read the error on a phone screen, copy it into a chat, get a
patch back, repeat. Roughly twenty to thirty minutes per iteration, most of it
spent moving text between two windows.

The cost was never the typing. It was this:

> **The compiler was the only thing that knew the truth, and it could only talk
> to one person.**

Everything done outside FlutLab — the eight structural checkers, the Kotlin
stub compiles, the argument and collision scans — exists to approximate what a
compiler already knows for certain. They are good approximations. They caught a
lot. They are still approximations, and the builds that failed anyway
(`_livePosition` shadowing in 274, a `context` capture before 319) failed on
exactly the class of thing only a real analyzer can see.

This setup moves the compiler somewhere both parties can read.

## The shape

```
phone  ──►  Claude Code on the web  ──►  GitHub repo  ──►  GitHub Actions
                     ▲                                          │
                     └────── build log, analyzer, APK ───────────┘
```

Three pieces, each doing the one thing it is good at:

| Piece | Role |
| --- | --- |
| **GitHub** | the single copy of the truth; no more zips |
| **GitHub Actions** | the compiler — real Flutter, real Android SDK, real signing |
| **Claude Code on the web** | edits the repo directly and reads the build log itself |

FlutLab does not disappear on day one. Keep the existing FlutLab project
exactly as it is, with its keystore, until Actions has produced a verified
signed APK that installs over the current build. Then it becomes the backup.

## What changed in the tree

**`android/app/build.gradle.kts`** — the four hardcoded signing constants are
gone. They were defensible while the project lived only in zips, which carried
`innocent.jks` anyway. They are not defensible in git: this file is committed,
and a password in git history cannot be removed later. Signing now resolves in
this order, first match wins:

1. `android/signing.properties` — FlutLab and local builds
2. `android/key.properties` — the Flutter convention
3. `INNOCENT_STORE_FILE` / `INNOCENT_STORE_PASSWORD` / `INNOCENT_KEY_ALIAS` /
   `INNOCENT_KEY_PASSWORD` environment variables — CI

With none of the three the release variant gets no signing config at all and
the build warns loudly. That is the correct failure: an APK that will not
install beats one signed with the wrong key.

**`.gitignore`** — new, and the signing block at the top is the reason it
exists. `android/app/libs/*.aar` are deliberately NOT ignored; they have no
Maven coordinates and the build fails without them.

**`.github/workflows/build.yml`** — new. Analyze, structural checks, signed
release build, signature verification, artifact.

## The signature check

The workflow compares the built APK's certificate against
`E3:E1:EF:...:CD:B1` and fails the build on a mismatch.

This is the most valuable line in the whole pipeline. Innocent has no Play
Store, so Android's rule applies with no override: an installed app can only be
updated by an APK signed with the same key. Ship one release signed with
something else and every existing install is stranded permanently — not
degraded, not warned, stranded. There is no recovery short of asking each user
to uninstall and lose their data.

That failure mode is now impossible to reach by accident.

## Setting it up

### 1. A private repository

Private, not public. `lib/features/video_hub/data/api/backend_config.dart`
carries the Supabase URL and publishable key. The publishable key is designed
to be in client apps and RLS is what actually protects the data — but there is
no reason to hand a stranger the map.

### 2. Three secrets

**Settings > Secrets and variables > Actions > New repository secret.**

| Name | Value |
| --- | --- |
| `KEYSTORE_BASE64` | the base64 of `innocent.jks`, one line, no spaces |
| `KEYSTORE_PASSWORD` | the keystore password |
| `KEY_ALIAS` | `innocent` |
| `KEY_PASSWORD` | the key password (same as the keystore password here) |

GitHub encrypts these and masks them in logs. They cannot be read back through
the UI after saving — only overwritten. Keep the keystore backed up
independently; a GitHub secret is not a backup.

### 3. Push and watch

The workflow runs on every push to `main`, on every pull request, and on
demand from the **Actions** tab. The run summary carries the SHA-256, the byte
count and a ready-to-paste `app_releases` update.

## After the first green build

**Pin the Flutter version.** Read it out of the "Toolchain" step and set
`flutter-version:` in the workflow. An unpinned toolchain means a build can
start failing on a morning when nothing in this repository changed.

**Clear the analyzer backlog.** The Analyze step currently passes warnings and
infos. Work through the list in its own commits, then delete
`--no-fatal-infos --no-fatal-warnings`. After that, the analyzer gates the
build the way `tool/check.py` does.

**Then automate the last two manual steps** — upload to R2 and update
`app_releases` — but only once the pipeline is boring. Automating a step that
still surprises you just moves the surprise somewhere harder to see.

## Known constraints

| | |
| --- | --- |
| Private repo, Free plan | 2,000 Linux minutes/month; a build is ~15–25 min |
| Artifact storage | 500 MB total; the APK is ~88 MB, hence 5-day retention |
| Claude Code on the web | research preview, needs Pro/Max/Team |
| Cloud sessions | share the account's rate limits with ordinary chat |
| First build | slower: NDK 27 is ~2.5 GB and is not cached yet |

## If the build fails

| Symptom | Cause |
| --- | --- |
| `KEYSTORE_BASE64 is not set` | secret missing or misnamed |
| `Failed to read key ... wrong password` | `KEYSTORE_PASSWORD` wrong |
| `WRONG SIGNING KEY` | the base64 is of a different `.jks`. **Stop and check.** |
| Dart SDK version errors | pin `flutter-version` to what FlutLab reports |
| `Could not find ...aar` | the `libs/*.aar` files were not committed |
| Gradle OOM | `org.gradle.jvmargs` in `android/gradle.properties` is tuned for FlutLab's small container; a runner has 16 GB and can take more |
