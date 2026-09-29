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
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/content_detail_screen.dart';

VideoContent _title({
  List<AlbumItem> items = const <AlbumItem>[],
  int? photoCount,
  int? videoCount,
}) =>
    VideoContent(
      id: 't1',
      title: 'Test title',
      category: ContentCategory.movies,
      accessTier: AccessTier.free,
      items: items,
      photoCount: photoCount,
      videoCount: videoCount,
    );

AlbumItem _video(String id) =>
    AlbumItem(id: id, kind: MediaKind.video, source: MediaRef.none);

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

  // ═══════════════════════════════════════════════════════════════════════
  // WHICH ANSWER THE RULE IS GIVEN, WHICH IS WHERE THE FLICKER WAS
  // ═══════════════════════════════════════════════════════════════════════
  //
  // The rule above is right and was never wrong. What was wrong is that the
  // screen fed it `hasAlbum` — "is the album LOADED" — for a screen whose
  // first frame is drawn before any album is fetched. So every title with an
  // album drew the button for a frame or two and then took it away as the
  // grid arrived, and the whole page below it jumped.
  //
  // `expectsAlbum` answers the question the rule is actually asking, from the
  // counts that come down with the card. These tests exist because the two
  // getters read almost the same and differ only in the one case nobody
  // screenshots: the first frame.
  group('VideoContent.expectsAlbum', () {
    test('the counts answer before the album is loaded', () {
      final card = _title(photoCount: 3, videoCount: 2);
      expect(card.hasAlbum, isFalse, reason: 'nothing loaded yet');
      expect(card.expectsAlbum, isTrue, reason: 'but the server said five');
    });

    test('and it does not change when the album arrives', () {
      final card = _title(photoCount: 0, videoCount: 2);
      final loaded = card.withAlbum(<AlbumItem>[_video('a'), _video('b')]);
      // THE POINT. Same answer on the first frame and the last, so the screen
      // cannot decide one thing and then the other.
      expect(card.expectsAlbum, loaded.expectsAlbum);
      expect(loaded.expectsAlbum, isTrue);
    });

    test('a title the server says has nothing keeps its button', () {
      final card = _title(photoCount: 0, videoCount: 0);
      expect(card.expectsAlbum, isFalse);
      expect(
        ContentDetailScreen.showsHeaderButton(
            hasAlbum: card.expectsAlbum, locked: false),
        isTrue,
      );
    });

    test('no counts at all falls back to what is loaded', () {
      // An old row, or a shape that carries no totals. Guessing "has an
      // album" there would hide the button on a title that has no other way
      // in, which is the one failure this must not have.
      expect(_title().expectsAlbum, isFalse);
      expect(_title(items: <AlbumItem>[_video('a')]).expectsAlbum, isTrue);
    });

    test('a loaded album counts even when the totals say zero', () {
      // Disagreement is possible — a row skipped for having no usable URL,
      // or stale totals. What is in hand wins, because it is on the screen.
      expect(
        _title(photoCount: 0, videoCount: 0, items: <AlbumItem>[_video('a')])
            .expectsAlbum,
        isTrue,
      );
    });
  });

  group('VideoContent.albumCount', () {
    test('is the server total, so it does not count up as tiles arrive', () {
      final card = _title(photoCount: 3, videoCount: 2);
      expect(card.albumCount, 5);
      expect(card.withAlbum(<AlbumItem>[_video('a')]).albumCount, 5);
    });

    test('is null when there is nothing to say', () {
      expect(_title().albumCount, isNull);
    });

    test('falls back to what is loaded when no totals came down', () {
      expect(_title(items: <AlbumItem>[_video('a'), _video('b')]).albumCount, 2);
    });
  });
}
