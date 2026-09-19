// audit_video_hub.md M5.
//
// `title_mm` was selected from the server, arrived on every catalogue
// request, was parsed into VideoContent — and rendered by nothing. Every
// render site used `title`. So the app paid for the Burmese title on every
// request and showed the English one to an audience that is mostly Burmese.
//
// displayTitle is the accessor those sites now use. It is a one-line
// conditional, which is exactly the kind of thing that gets "simplified" back
// into `=> title` by someone who cannot see why it exists.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';

VideoContent _title({String title = 'The Quiet Earth', String? mm}) =>
    VideoContent(
      id: 't1',
      title: title,
      titleMm: mm,
      category: ContentCategory.movies,
      poster: MediaRef.none,
      source: const MediaRef(provider: 'server', locator: 't1'),
    );

void main() {
  group('VideoContent.displayTitle', () {
    test('Burmese locale gets the Burmese title', () {
      expect(_title(mm: 'တိတ်ဆိတ်သောကမ္ဘာ').displayTitle('my'),
          'တိတ်ဆိတ်သောကမ္ဘာ');
    });

    test('every other locale gets the original title', () {
      final c = _title(mm: 'တိတ်ဆိတ်သောကမ္ဘာ');
      expect(c.displayTitle('en'), 'The Quiet Earth');
      expect(c.displayTitle('th'), 'The Quiet Earth');
      // A null language code is the "we do not know" case and must not
      // silently pick Burmese.
      expect(c.displayTitle(null), 'The Quiet Earth');
    });

    test('a title with no Burmese version falls back, it does not blank', () {
      expect(_title().displayTitle('my'), 'The Quiet Earth');
    });

    test('an empty or whitespace title_mm falls back too', () {
      // A row where somebody saved an empty string must not render as a
      // nameless card.
      expect(_title(mm: '').displayTitle('my'), 'The Quiet Earth');
      expect(_title(mm: '   ').displayTitle('my'), 'The Quiet Earth');
    });

    test('the Burmese title is returned untouched, not trimmed into the UI',
        () {
      // Myanmar text is full of combining marks; anything that rewrites it is
      // a bug waiting to happen. Only the emptiness CHECK trims.
      const mm = 'ရုပ်ရှင် ၂၀၂၄';
      expect(_title(mm: mm).displayTitle('my'), mm);
    });
  });

  group('searchHaystack still covers the Burmese title', () {
    // The demo repository searches this, and it is what made the omission in
    // the API repository visible in the first place.
    test('contains both titles, lowercased', () {
      final hay = _title(mm: 'ကမ္ဘာ').searchHaystack;
      expect(hay, contains('the quiet earth'));
      expect(hay, contains('ကမ္ဘာ'));
    });
  });
}
