// When the detail screen draws its big button, and when the grid replaces it.
//
// The rule is three lines long and could have been inlined into `build()`.
// It is not, and it is tested, for one reason: TWO OF THE THREE CASES ARE
// INVISIBLE IN THE OBVIOUS TEST. Anyone checking this by hand opens a title
// with an album, sees no Play button, and concludes it works — while a title
// with no album has quietly become a screen with nothing to tap, and a locked
// title has quietly lost the only unmissable route to the paywall.
//
// Both regressions are silent. Neither throws, neither logs, and neither
// shows up in a screenshot of the case somebody thought to look at.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/content_detail_screen.dart';

void main() {
  group('ContentDetailScreen.showsHeaderButton', () {
    test('a title with no album keeps its button — there is no other way in',
        () {
      // The plain case: one film, a poster, no extras. Hiding the button here
      // would leave a detail screen that cannot play the thing it is about.
      expect(
        ContentDetailScreen.showsHeaderButton(hasAlbum: false, locked: false),
        isTrue,
      );
    });

    test('a title with an album hides it — the grid is the control', () {
      // The case the brief asked for. Every video tile in the mosaic carries
      // its own play glyph, so a second, larger button above the grid is a
      // duplicate that also implies there is only one video in the title.
      expect(
        ContentDetailScreen.showsHeaderButton(hasAlbum: true, locked: false),
        isFalse,
      );
    });

    test('a LOCKED title keeps it even with an album, because it says Upgrade',
        () {
      // The deliberate departure from "hide the button". In this state it is
      // not a Play button — it is the route to the paywall, and the only
      // unmissable one on the screen. A locked tile leads there too, but only
      // after the viewer chooses to tap something they can see is locked.
      //
      // Removing the explicit offer to keep the grid tidy trades a sale for a
      // layout. This screen exists to make the sale.
      expect(
        ContentDetailScreen.showsHeaderButton(hasAlbum: true, locked: true),
        isTrue,
      );
    });

    test('locked and no album is still shown', () {
      expect(
        ContentDetailScreen.showsHeaderButton(hasAlbum: false, locked: true),
        isTrue,
      );
    });
  });
}
