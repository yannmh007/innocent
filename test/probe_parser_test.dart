import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/downloader/data/probe_parser.dart';
import 'package:innocent/features/downloader/domain/media_probe.dart';

/// What a link can be downloaded as.
///
/// WHY THIS FILE EXISTS. `ProbeParser.parse` decides which qualities a person
/// is offered, and until now it had no tests at all — despite being a pure
/// function from a JSON string to an object, which is the easiest thing in the
/// codebase to test. Every case below is a bug this project has already
/// shipped and fixed; the comments name which, so a future change that
/// re-breaks one is refused with an explanation rather than a red line.
String jsonOf(Map<String, Object?> m) => jsonEncode(m);

Map<String, Object?> fmt({
  required String id,
  String ext = 'mp4',
  int? height,
  String? vcodec,
  String? acodec,
  int? filesize,
  String? note,
  Map<String, String>? headers,
}) =>
    <String, Object?>{
      'format_id': id,
      'ext': ext,
      if (height != null) 'height': height,
      if (vcodec != null) 'vcodec': vcodec,
      if (acodec != null) 'acodec': acodec,
      if (filesize != null) 'filesize': filesize,
      if (note != null) 'format_note': note,
      if (headers != null) 'http_headers': headers,
    };

void main() {
  const String url = 'https://example.com/watch?v=abc';

  group('the muxer gate', () {
    // The "360p only" release. With no ffmpeg a video-only rendition cannot be
    // joined to audio, so offering it would produce a silent file. Dropping
    // those rows is CORRECT — the bug was asking a stale cache whether ffmpeg
    // existed, not the dropping itself. Both directions are pinned because
    // each has been wrong once.
    final String body = jsonOf(<String, Object?>{
      'title': 'Clip',
      'formats': <Object?>[
        fmt(id: '18', height: 360, vcodec: 'avc1', acodec: 'mp4a'),
        fmt(id: '137', height: 1080, vcodec: 'avc1', acodec: 'none'),
        fmt(id: '251', ext: 'webm', vcodec: 'none', acodec: 'opus'),
      ],
    });

    test('without a muxer only combined video is offered', () {
      final MediaProbe p = ProbeParser.parse(body, url, ffmpegAvailable: false);
      expect(p.videoFormats.map((f) => f.id), <String>['18']);
    });

    test('with a muxer the video-only rendition is offered too', () {
      final MediaProbe p = ProbeParser.parse(body, url, ffmpegAvailable: true);
      expect(p.videoFormats.map((f) => f.id), containsAll(<String>['18', '137']));
    });
  });

  test('a video-only size includes the audio it will be merged with', () {
    // A 1080p download used to land ~10% larger than advertised, because the
    // row showed the video stream's size and the file also contains audio.
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        'title': 'Clip',
        'formats': <Object?>[
          fmt(
              id: '137',
              height: 1080,
              vcodec: 'avc1',
              acodec: 'none',
              filesize: 100000000),
          fmt(id: '251', ext: 'webm', vcodec: 'none', acodec: 'opus', filesize: 8000000),
        ],
      }),
      url,
    );
    final MediaFormat video = p.videoFormats.firstWhere((f) => f.id == '137');
    expect(video.filesize, 108000000);
    // And it must say so: the number is now a sum, not something the server
    // reported.
    expect(video.sizeIsEstimate, isTrue);
  });

  test('an unknown video size is not turned into a confident wrong one', () {
    // Adding audio to an unknown total would turn "size unknown" into a
    // confidently wrong 3 MB, which is worse than saying nothing.
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        'title': 'Clip',
        'formats': <Object?>[
          fmt(id: '137', height: 1080, vcodec: 'avc1', acodec: 'none'),
          fmt(id: '251', ext: 'webm', vcodec: 'none', acodec: 'opus', filesize: 8000000),
        ],
      }),
      url,
    );
    expect(p.videoFormats.firstWhere((f) => f.id == '137').filesize, isNull);
  });

  group('watermarks', () {
    // TikTok. Every clip is offered twice, once with the logo burned in. The
    // watermarked copy is not a choice worth showing when a clean one exists —
    // but it is better than nothing when it is all there is.
    test('the logo copy is dropped when a clean one exists', () {
      final MediaProbe p = ProbeParser.parse(
        jsonOf(<String, Object?>{
          'title': 'TikTok',
          'formats': <Object?>[
            fmt(id: 'download_addr-0', height: 720, vcodec: 'h264', acodec: 'aac'),
            fmt(id: 'play_addr-0', height: 720, vcodec: 'h264', acodec: 'aac'),
          ],
        }),
        url,
      );
      expect(p.videoFormats.map((f) => f.id), <String>['play_addr-0']);
    });

    test('and kept when it is the only copy', () {
      final MediaProbe p = ProbeParser.parse(
        jsonOf(<String, Object?>{
          'title': 'TikTok',
          'formats': <Object?>[
            fmt(id: 'download_addr-0', height: 720, vcodec: 'h264', acodec: 'aac'),
          ],
        }),
        url,
      );
      expect(p.videoFormats, hasLength(1));
      expect(p.videoFormats.single.watermarked, isTrue);
    });

    test('the note spelling is caught as well as the id spelling', () {
      // yt-dlp marks it one way or the other depending on version; matching
      // only one lets the bad copy through on whichever we happen to run.
      final MediaProbe p = ProbeParser.parse(
        jsonOf(<String, Object?>{
          'title': 'TikTok',
          'formats': <Object?>[
            fmt(id: 'a', height: 720, vcodec: 'h264', acodec: 'aac', note: 'watermarked'),
            fmt(id: 'b', height: 720, vcodec: 'h264', acodec: 'aac'),
          ],
        }),
        url,
      );
      expect(p.videoFormats.map((f) => f.id), <String>['b']);
    });
  });

  test('top-level headers reach a format that carries none', () {
    // TikTok again: the CDN's required headers sit at the top level and the
    // formats are bare. Reading only the per-format ones gives a file that
    // downloads perfectly and refuses to play.
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        'title': 'Clip',
        'http_headers': <String, String>{'Referer': 'https://tiktok.com/'},
        'formats': <Object?>[
          fmt(id: 'a', height: 720, vcodec: 'h264', acodec: 'aac'),
        ],
      }),
      url,
    );
    expect(p.videoFormats.single.httpHeaders['Referer'], 'https://tiktok.com/');
  });

  test('a per-format header wins over the top-level one of the same name', () {
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        'title': 'Clip',
        'http_headers': <String, String>{'Referer': 'https://top/'},
        'formats': <Object?>[
          fmt(
            id: 'a',
            height: 720,
            vcodec: 'h264',
            acodec: 'aac',
            headers: <String, String>{'Referer': 'https://format/'},
          ),
        ],
      }),
      url,
    );
    expect(p.videoFormats.single.httpHeaders['Referer'], 'https://format/');
  });

  test('a playlist wrapper falls through to its first entry', () {
    // Some extractors ignore --no-playlist. Showing "no media found" for a
    // link that plainly has media is the failure this avoids.
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        '_type': 'playlist',
        'entries': <Object?>[
          <String, Object?>{
            'title': 'Inner',
            'formats': <Object?>[
              fmt(id: 'a', height: 480, vcodec: 'h264', acodec: 'aac'),
            ],
          },
        ],
      }),
      url,
    );
    expect(p.title, 'Inner');
    expect(p.videoFormats, hasLength(1));
  });

  test('a response with no formats array still yields one row', () {
    // A plain .mp4 link. Both codecs unknown is the ordinary shape, and
    // guessing "has both" is what keeps it in the video list.
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        'title': 'Direct',
        'ext': 'mp4',
        'url': 'https://example.com/a.mp4',
      }),
      url,
    );
    expect(p.videoFormats, hasLength(1));
    expect(p.videoFormats.single.isCombined, isTrue);
  });

  test('a storyboard track is not offered as a download', () {
    // BELT AND BRACES, and this test cannot tell which brace is holding.
    // `_format` returns null for a row whose codecs are both "none", AND such
    // a row would fail the hasVideo / isAudioOnly filters anyway. Mutating
    // either one alone leaves this test green — verified. It is kept because
    // it pins the OUTCOME a user sees, which is what must never regress, and
    // because a change that alters both at once is exactly the change that
    // would put mhtml thumbnail tracks in the quality sheet.
    final MediaProbe p = ProbeParser.parse(
      jsonOf(<String, Object?>{
        'title': 'Clip',
        'formats': <Object?>[
          fmt(id: 'sb0', ext: 'mhtml', vcodec: 'none', acodec: 'none'),
          fmt(id: 'a', height: 720, vcodec: 'h264', acodec: 'aac'),
        ],
      }),
      url,
    );
    expect(p.videoFormats.map((f) => f.id), <String>['a']);
    expect(p.audioFormats.map((f) => f.id), isNot(contains('sb0')));
  });

  group('the title', () {
    Map<String, Object?> base(Map<String, Object?> extra) => <String, Object?>{
          'formats': <Object?>[
            fmt(id: 'a', height: 720, vcodec: 'h264', acodec: 'aac'),
          ],
          ...extra,
        };

    test('prefers title', () {
      expect(
          ProbeParser.parse(
                  jsonOf(base(<String, Object?>{'title': 'T', 'id': 'X'})), url)
              .title,
          'T');
    });

    test('falls back to the id', () {
      expect(
          ProbeParser.parse(jsonOf(base(<String, Object?>{'id': 'X'})), url).title,
          'X');
    });

    test('and to a placeholder when there is nothing at all', () {
      expect(ProbeParser.parse(jsonOf(base(<String, Object?>{})), url).title,
          'Video');
    });

    test('a Burmese title survives the parse unchanged', () {
      // Nothing here should normalise, transliterate or truncate a title —
      // that happens once, in the output template, and is audited separately
      // in docs/filename_audit.md. A parser that quietly altered it would
      // make that audit's measurements wrong.
      const String burmese = 'မြန်မာ့ရိုးရာ အစားအစာ ချက်ပြုတ်နည်း';
      expect(
        ProbeParser.parse(
                jsonOf(base(<String, Object?>{'title': burmese})), url)
            .title,
        burmese,
      );
    });
  });

  test('is_live and live_status are both understood', () {
    for (final Map<String, Object?> live in <Map<String, Object?>>[
      <String, Object?>{'is_live': true},
      <String, Object?>{'live_status': 'is_live'},
    ]) {
      final MediaProbe p = ProbeParser.parse(
        jsonOf(<String, Object?>{
          'title': 'Stream',
          ...live,
          'formats': <Object?>[
            fmt(id: 'a', height: 720, vcodec: 'h264', acodec: 'aac'),
          ],
        }),
        url,
      );
      expect(p.isLive, isTrue, reason: 'for $live');
    }
  });

  test('malformed JSON throws rather than returning an empty probe', () {
    // The caller shows the extractor's own words on a failure. A parser that
    // swallowed this would turn a readable error into "no media found".
    expect(() => ProbeParser.parse('not json', url), throwsA(isA<Object>()));
  });
}
