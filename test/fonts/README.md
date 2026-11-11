# Fonts for the layout tests

`test/player_layout_test.dart` lays the player out in real fonts, because a
Burmese line is nearly twice as tall as a Latin one and boxes sized for Latin
text cut it off (docs/player_ux_audit_2026_11.md).

- `NotoSansMyanmar.ttf` — github.com/google/fonts, `ofl/notosansmyanmar/`
  (variable font, © 2022 The Noto Project Authors), the face Android draws
  Burmese in.
- `NotoSansThai.ttf` — github.com/google/fonts, `ofl/notosansthai/`
  (variable font, © 2022 The Noto Project Authors).

Both under the SIL Open Font License 1.1, `OFL.txt`. Roboto and the Material
icons come from the Flutter SDK running the tests. Test-only: nothing here is
in the app (pubspec.yaml lists no fonts).
