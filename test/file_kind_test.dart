import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/android_data/domain/file_kind.dart';

/// The Hidden files browser opens a file by what it is: a video or a song
/// streams, a photo opens in the viewer, anything else goes to another app.
void main() {
  test('videos, photos and songs are known by their extension, any case', () {
    expect(kindOf('Episode 3.MP4'), FileKind.video);
    expect(kindOf('clip.mkv'), FileKind.video);
    expect(kindOf('photo_2026-10-10.jpg'), FileKind.image);
    expect(kindOf('IMG.HEIC'), FileKind.image);
    expect(kindOf('voice.ogg'), FileKind.audio);
    expect(kindOf('song.opus'), FileKind.audio);
  });

  test('documents, archives and apps', () {
    expect(kindOf('notes.pdf'), FileKind.document);
    expect(kindOf('subs.srt'), FileKind.document);
    expect(kindOf('pack.zip'), FileKind.archive);
    expect(kindOf('innocent-1.64.60-373.apk'), FileKind.apk);
  });

  test('a file Telegram is still downloading is not what it will become', () {
    expect(kindOf('film.mp4.temp'), FileKind.other);
    expect(kindOf('noextension'), FileKind.other);
    expect(kindOf('trailing.'), FileKind.other);
  });

  test('Telegram keeps its downloads under files/Telegram', () {
    expect(telegramDownloads('org.telegram.messenger'),
        '/storage/emulated/0/Android/data/org.telegram.messenger/files/Telegram');
  });
}
