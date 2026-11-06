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
- **No Flutter in this sandbox.** Analyze and tests run in CI: dispatch
  `build.yml` on the branch (it publishes nothing off main).
- **Lab-only code stays behind `INNOCENT_LAB`** and is never shipped
  (skill `release` lists it). `MEDIA_SEAL` is a dart-define; the release
  build leaves it unset.
- No owner name, location or personal contact in the app (the takedown
  address is the one public contact).
