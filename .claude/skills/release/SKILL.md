---
name: release
description: "Ship a new app version to main (Innocent): build the release tree from the work branch without lab-only code, prove it, push, and move app_releases. Use whenever the owner asks for a release."
---

# Releasing the app (as 1.64.80 was, 6 Nov 2026)

main and the work branch diverge on purpose: main gets copies of the branch's
files, minus what must not ship. Nothing is merged.

## 1. Inventory
- `git fetch origin main`; `git diff --name-status origin/main HEAD`.
- For every M file, check main's version ever existed on the branch
  (`git rev-list HEAD -- f` and compare blobs). Only `pubspec.yaml` and
  `lib/core/app_version.dart` should differ on main alone; anything else is
  main-only work and must be kept.
- Never ship: `test_device/results/**`; lab hooks (`lib/app.dart` tour skip,
  `ExoEngine.rungKbps`, `MediaKitPlayerService.ladderRungKbps`); the Google
  sign-in nonce (`api_account_repository.dart`, `test/google_sign_in_gate_test.dart`)
  until the owner has signed in once with a build that carries it. Check
  BACKLOG §0 "Next app release" for the current list.

## 2. Prove the candidate (on the branch)
- Device lab on a PLAIN build: `test_device/config.env` `MEDIA_SEAL=0`,
  flows such as `genres jumps` (skill `device-labs`).
- Test Lab on the realme and the OPPO, `cloud.env` `MEDIA_SEAL=` empty.
  A FAIL on a slow line: read the trace (segment times, measured kbps) and
  run that phone once more before calling it the line.
- Dispatch `build.yml` on the branch: Analyze, Flutter tests, the JVM seal,
  signed arm64 and 32-bit APKs; publishing steps are main-only.

## 3. The release tree (worktree, detached at origin/main)
- `git worktree add --detach $SCRATCHPAD/main-wt origin/main` (or reuse it
  clean at origin/main).
- `git checkout <branch> -- <every shipping file>`; remove lab-only lines
  from files that also carry real changes.
- Bump `pubspec.yaml` `version: X+N` and `AppVersion.name/build` together.
- `python3 tool/check.py` in the worktree; `git diff --cached --stat <branch>`
  must show only the exclusions and the version.
- Commit as `Claude <noreply@anthropic.com>`, message: what users get, what
  is server-side, the run ids that proved it, what is left out by design.

## 4. Ship
- Push: `git push origin HEAD:main`. Do NOT push anything else to main
  until the Build finishes: build.yml cancels an in-progress run on a new push.
- Watch: Build (Analyze, Test, APKs, CDN, Release), Pages, both Workers.
  Run the Playback check on main after the Workers rebuild.
- Build summary gives sizes and SHA-256; compare with the GitHub release
  asset digests. Then update `app_releases` id 1 (both APKs: url on
  cdn.innocentplayer.com, sha256, bytes; mirrors = the GitHub release URLs;
  notes_en and notes_mm both — short, user-facing; released_at = now()).
- A published version's APK never changes: a later push to main rebuilds
  but uploads nothing; a different binary needs a version bump.
- Record it: BACKLOG §0 (version, commit, build, digests), docs-only push to
  main from the worktree.
