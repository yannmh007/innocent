---
paths:
  - "lib/**"
  - "test/**"
  - "android/**"
---

# The app

- **Every user-facing string in three languages**: a key in each of `_en`,
  `_my`, `_th` in `lib/core/localization/app_strings.dart`, read through
  `AppStrings`. `tool/check.py` (ui_literals, verify) fails a bare literal
  or a missing key.
- **Flutter is 3.32.8** (CI). Not there: `RadioGroup` (use `RadioListTile`
  with `groupValue`). Use `withValues(alpha:)`, not `withOpacity`. Lints are
  strict: `prefer_const` and friends.
- **Flutter is not preinstalled, but installs here in ~2 min** (the CI
  version, from storage.googleapis.com, which the sandbox reaches):
  `cd /root && curl -sSO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.32.8-stable.tar.xz && tar -xf flutter_linux_3.32.8-stable.tar.xz && rm flutter_linux_3.32.8-stable.tar.xz && git config --global --add safe.directory /root/flutter`.
  Then `~/flutter/bin/flutter analyze` and `flutter test` (whole suite
  ~4.5 min) run locally; `git checkout pubspec.lock` after. CI (`build.yml`
  dispatched on the branch, publishes nothing off main) stays the record.
- **A test that fails only in CI is timing, not luck:** rerun it here with
  the CPU and disk loaded (busy loops plus a `dd … conv=fsync` loop) and
  count the event with a temporary print. That found the lost read-ahead
  of 6 Nov (stream_cache_hls_test: a read starting while the last one's
  writer was closing got no writer).
- **Lab-only code stays behind `INNOCENT_LAB`** and is never shipped
  (skill `release` lists it). `MEDIA_SEAL` is a dart-define; the release
  build leaves it unset.
- **What the app tells users about data matches what it does.** It sends
  usage events (`record_events`), playback requests, account data when
  signed in, crash reports when SENTRY_DSN is set. A change to any data
  flow checks the Privacy text (`privacyBody`, three languages) in the same
  change. Why: on 7 Nov it still said "runs entirely offline, sends
  nothing".
- No owner name, location or personal contact in the app (the takedown
  address is the one public contact).
