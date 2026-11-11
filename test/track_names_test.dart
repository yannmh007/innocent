// What the audio and subtitle menus call a track
// (lib/core/services/video_player/models/).
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/core/services/video_player/models/language_names.dart';
import 'package:innocent/core/services/video_player/models/subtitle_track_info.dart';

void main() {
  test('two English audio tracks can be told apart', () {
    const film = AudioTrackInfo(
        id: '1', title: 'Stereo', language: 'eng', codec: 'aac', channels: 2);
    const talk = AudioTrackInfo(id: '2', title: 'Commentary', language: 'eng');
    expect(film.displayName, 'Stereo · English · AAC 2.0');
    expect(talk.displayName, 'Commentary · English');
    expect(film.displayName == talk.displayName, isFalse);
  });

  test('a language is named in its own script, from either code', () {
    for (final c in ['my', 'mya', 'bur', 'MYA']) {
      expect(languageName(c), 'မြန်မာ', reason: c);
    }
    expect(languageName('tha'), 'ไทย');
    expect(languageName('en-US'), 'English');
    expect(languageName('und'), isNull);
    expect(languageName(''), isNull);
    expect(languageName(null), isNull);
  });

  test('an audio title that already names the language says it once', () {
    const t = AudioTrackInfo(id: '1', title: 'English 5.1', language: 'eng');
    expect(t.displayName, 'English 5.1');
  });

  test('an audio track with nothing to say keeps its number', () {
    expect(const AudioTrackInfo(id: '3').displayName, 'Track 3');
  });

  test('channels read as layouts', () {
    expect(channelLayout(6), '5.1');
    expect(channelLayout(8), '7.1');
    expect(channelLayout(3), '3ch');
  });

  test('subtitles: title, then the language by name when it adds something',
      () {
    expect(const SubtitleTrackInfo(id: '1', language: 'mya').displayName,
        'မြန်မာ');
    expect(
        const SubtitleTrackInfo(id: '2', title: 'SDH', language: 'eng')
            .displayName,
        'SDH · English');
    expect(
        const SubtitleTrackInfo(id: '3', title: 'English', language: 'eng')
            .displayName,
        'English');
    expect(const SubtitleTrackInfo(id: '4', title: 'eng').displayName,
        'English');
    expect(const SubtitleTrackInfo(id: '5').displayName, 'Subtitle 5');
  });
}
