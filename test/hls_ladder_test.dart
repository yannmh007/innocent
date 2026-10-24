import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/cmaf_index.dart';
import 'package:innocent/features/video_hub/domain/hls_ladder.dart';

import 'support/cmaf.dart';

/// The ladder as HLS (domain/hls_ladder.dart).
///
/// The head in fixtures/cmaf_head_720p.b64 is the first 1,613 bytes of a
/// real rung, encoded with tool/transcode.sh's own flags (a 20 s test card
/// at 720p): ftyp, moov, two sidx and the first moof's header. Playlists built from it were checked
/// against ffmpeg — both variants decode, and the 720p copy read through its
/// playlist is identical, frame for frame, to the file.
Uint8List _realHead() => base64Decode(
    File('test/fixtures/cmaf_head_720p.b64').readAsStringSync().trim());

void main() {
  test('the real head: init segment, codec and size as ffmpeg wrote them', () {
    final head = CmafHead.parse(_realHead())!;
    expect(head.initEnd, 1277, reason: 'ftyp 28 + moov 1249');
    expect(head.videoCodec, 'avc1.64001f', reason: 'High profile, level 3.1');
    expect(head.width, 1280);
    expect(head.height, 720);
    expect(head.hasAudio, isTrue);
  });

  test("the real head's fragments become segments, byte for byte", () {
    final bytes = _realHead();
    final idx = CmafIndex.parse(bytes)!;
    final rung = HlsRung(
      height: 720,
      kbps: 1500,
      url: 'http://127.0.0.1:1/c/t/r720',
      index: idx,
      head: CmafHead.parse(bytes),
    );
    final text = HlsLadder.media(rung)!;
    final lines = text.trim().split('\n');
    expect(lines.first, '#EXTM3U');
    expect(lines.last, '#EXT-X-ENDLIST');
    expect(text, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
    expect(text, contains('#EXT-X-TARGETDURATION:2'));
    expect(text, contains('#EXT-X-MAP:URI="http://127.0.0.1:1/c/t/r720",BYTERANGE="1277@0"'));
    // The first fragment's moof starts right after the two sidx, at 1597.
    expect(text, contains('#EXT-X-BYTERANGE:605312@1597'));
    expect(RegExp('#EXTINF:').allMatches(text).length, idx.length);
    expect(RegExp('#EXT-X-BYTERANGE:').allMatches(text).length, idx.length);
  });

  test('segments tile the file: each starts where the last ended', () {
    final film = FakeCmaf.build(fragments: 12, fragmentBytes: 50000);
    final head = Uint8List.sublistView(film.bytes, 0, film.headEnd + 16);
    final rung = HlsRung(
      height: 360,
      kbps: 500,
      url: 'u',
      index: CmafIndex.parse(head),
      head: const CmafHead(initEnd: 1236),
    );
    final ranges = RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)')
        .allMatches(HlsLadder.media(rung)!)
        .map((m) => (int.parse(m.group(1)!), int.parse(m.group(2)!)))
        .toList();
    expect(ranges.length, 12);
    expect(ranges.first.$2, film.headEnd);
    for (var i = 1; i < ranges.length; i++) {
      expect(ranges[i].$2, ranges[i - 1].$2 + ranges[i - 1].$1);
    }
    expect(ranges.last.$2 + ranges.last.$1, film.bytes.length);
  });

  test('no index or no head yet: no media playlist, never a wrong one', () {
    expect(HlsLadder.media(const HlsRung(height: 720, kbps: 1500, url: 'u')), isNull);
  });

  test('the master names every rung, best first, with what the player weighs', () {
    final real = _realHead();
    final text = HlsLadder.master(
      [
        const HlsRung(height: 240, kbps: 300, url: 'a'),
        HlsRung(
            height: 720,
            kbps: 1500,
            url: 'b',
            index: CmafIndex.parse(real),
            head: CmafHead.parse(real)),
        const HlsRung(height: 480, kbps: 900, url: 'c'),
      ],
      mediaUri: (r) => '${r.height}.m3u8',
      aspect: 16 / 9,
      frameRate: 24,
    );
    final inf = RegExp(r'#EXT-X-STREAM-INF:(.*)\n(.*)').allMatches(text).toList();
    expect(inf.map((m) => m.group(2)), ['720.m3u8', '480.m3u8', '240.m3u8']);
    // Read from the file: the real codec, size and the peak a fragment needs.
    expect(inf[0].group(1), contains('CODECS="avc1.64001f,mp4a.40.2"'));
    expect(inf[0].group(1), contains('RESOLUTION=1280x720'));
    expect(inf[0].group(1), contains('AVERAGE-BANDWIDTH=1500000'));
    final peak = int.parse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(inf[0].group(1)!)!.group(1)!);
    expect(peak, greaterThan(1500000));
    // Not read yet: the grant's numbers, a size from the aspect, the level
    // x264 picks for that height.
    expect(inf[1].group(1), contains('RESOLUTION=854x480'));
    expect(inf[1].group(1), contains('CODECS="avc1.64001f,mp4a.40.2"'));
    expect(inf[2].group(1), contains('RESOLUTION=428x240'));
    expect(inf[2].group(1), contains('CODECS="avc1.64001e,mp4a.40.2"'));
    expect(inf[2].group(1), contains('BANDWIDTH=375000'));
    expect(text, contains('FRAME-RATE=24.000'));
    expect(text, startsWith('#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n'));
  });

  test('not a fragmented film: no head', () {
    final b = BytesBuilder();
    void box(String kind, int len) {
      final h = ByteData(4)..setUint32(0, len + 8);
      b
        ..add(h.buffer.asUint8List())
        ..add(kind.codeUnits)
        ..add(List<int>.filled(len, 0));
    }

    box('ftyp', 16);
    box('mdat', 100);
    expect(CmafHead.parse(b.toBytes()), isNull);
    expect(CmafHead.parse(Uint8List(4)), isNull);
    // A head cut before the end of its moov.
    expect(CmafHead.parse(Uint8List.sublistView(_realHead(), 0, 600)), isNull);
  });
}
