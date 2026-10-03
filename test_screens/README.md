# Screens

Draws the app's screens to PNG — real fonts, two phone sizes, Burmese and
English — so a layout can be **looked at** without a phone: by a person, or
by Claude, who can read the pictures. It is a camera, not a gate: nothing is
compared, and it is not part of `flutter test` (it lives outside `test/`).

```sh
eval "$(tool/screens_fonts.sh)"              # once: fonts into build/screen_fonts
SCREEN_LOCALE=my flutter test test_screens --update-goldens
SCREEN_LOCALE=en flutter test test_screens --update-goldens
```

Pictures land in `test_screens/out/` as `<screen>_<phone>_<locale>.png`
(`_1`, `_2` … are the same screen scrolled one height further). Any layout
error — an overflow, the yellow-and-black stripe — is also printed as a
`PROBLEM` line with the source location, so a run says in words what to look
at. `git checkout pubspec.lock` afterwards if the run rewrote it.

What it can and cannot show:

- Layout, text length, wrapping, Burmese line heights, empty and loading
  states, both phone sizes. That is most of what goes wrong.
- Not video (libmpv does not load in a test), not network images (they draw
  as placeholders), not platform data: folders, songs and the catalogue are
  the samples in `fakes.dart` and the bundled demo catalogue.

Adding a screen is one line in a `*_screens_test.dart`:
`screens('name', () => const SomeScreen(), overrides: ..., scrolls: 1);`
