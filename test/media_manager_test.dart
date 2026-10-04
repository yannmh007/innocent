import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/grid_tiles.dart';
import 'package:innocent/features/me/presentation/media_manager_screen.dart';

Video _v(String uri, int day) => Video(
      id: uri,
      uri: uri,
      title: uri.split('/').last,
      folderPath: '/sdcard/Movies',
      duration: const Duration(minutes: 1),
      sizeBytes: 0,
      width: 1280,
      height: 720,
      dateAdded: DateTime(2026, 1, day),
    );

void main() {
  test("Haven't Played: never played, newest first, file:// or not", () {
    final all = [
      _v('/sdcard/Movies/a.mp4', 1),
      _v('/sdcard/Movies/b.mp4', 3),
      _v('/sdcard/Movies/c.mp4', 2),
      _v('/sdcard/Movies/d e.mp4', 4),
    ];
    final out = unplayedVideos(all, [
      '/sdcard/Movies/a.mp4',
      // History may hold the same file as a file:// URI.
      'file:///sdcard/Movies/d%20e.mp4',
    ]);
    expect(out.map((v) => v.title), ['b.mp4', 'c.mp4']);
  });

  test('every video played: an empty list, not a crash', () {
    final all = [_v('/x/a.mp4', 1)];
    expect(unplayedVideos(all, ['/x/a.mp4']), isEmpty);
    expect(unplayedVideos(const [], ['/x/a.mp4']), isEmpty);
  });

  group('video grid tiles', () {
    test("at the normal font size they keep MX's 1.15 : 1", () {
      const d = VideoGridDelegate(textScaler: TextScaler.noScaling);
      for (final w in [141.0, 177.0, 200.0]) {
        expect(d.tileHeight(w), closeTo(w / 1.15, 0.001));
      }
    });

    test('at 200 % they grow to hold the thumbnail and the title', () {
      const d = VideoGridDelegate(textScaler: TextScaler.linear(2));
      const w = 141.0;
      final needed = w * 9 / 16 + 9 + 28 * 1.5;
      expect(d.tileHeight(w), greaterThanOrEqualTo(needed));
      expect(d.tileHeight(w), greaterThan(w / 1.15));
    });
  });
}
