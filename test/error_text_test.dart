import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/domain/error_text.dart';

void main() {
  test('a signed address keeps its host and loses the rest', () {
    expect(
      scrubPlaybackError('Failed to open https://stream.example/v/abc/'
          'index.m3u8?exp=1&sig=SECRET: connection reset'),
      'Failed to open https://stream.example/…: connection reset',
    );
  });

  test('never a user name or password', () {
    final out = scrubPlaybackError('rtsp://me:pa55@cam.local:554/live failed');
    expect(out, 'rtsp://cam.local:554/… failed');
    expect(out, isNot(contains('pa55')));
  });

  test("a sentence's full stop after a bare host stays a full stop", () {
    expect(scrubPlaybackError('Could not reach https://example.org.'),
        'Could not reach https://example.org.');
  });

  test('a file path and plain words are left alone', () {
    const local = 'Could not open codec. /storage/emulated/0/Movies/a.mkv';
    expect(scrubPlaybackError(local), local);
    expect(scrubPlaybackError('file:///sdcard/a.mkv: bad header'),
        'file:///sdcard/a.mkv: bad header');
  });
}
