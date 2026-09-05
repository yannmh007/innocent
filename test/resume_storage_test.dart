import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/resume/resume_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for ResumeStorage. Covers the original per-URI position
/// storage AND the crash-recovery markers added in the production
/// audit (setLastPlaying / clearLastPlaying / getLastPlaying).
///
/// We use SharedPreferences.setMockInitialValues({}) so the suite is
/// fully in-memory — fast, deterministic, no disk.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ResumeStorage — position', () {
    test('returns null when no position saved', () async {
      final rs = ResumeStorage();
      expect(await rs.getPosition('file:///nope.mp4'), isNull);
    });

    test('saves and retrieves position', () async {
      final rs = ResumeStorage();
      final saved = await rs.savePosition(
        uri: 'file:///foo.mp4',
        position: const Duration(minutes: 5),
        duration: const Duration(hours: 1),
      );
      expect(saved, isTrue);
      final read = await rs.getPosition('file:///foo.mp4');
      expect(read, const Duration(minutes: 5));
    });

    test('skips save when position below 30s threshold', () async {
      final rs = ResumeStorage();
      final saved = await rs.savePosition(
        uri: 'file:///short.mp4',
        position: const Duration(seconds: 10),
        duration: const Duration(hours: 1),
      );
      expect(saved, isFalse);
      expect(await rs.getPosition('file:///short.mp4'), isNull);
    });

    test('clears position when >=95% complete', () async {
      final rs = ResumeStorage();
      // Seed a position
      await rs.savePosition(
        uri: 'file:///vid.mp4',
        position: const Duration(minutes: 5),
        duration: const Duration(hours: 1),
      );
      expect(await rs.getPosition('file:///vid.mp4'), isNotNull);
      // Now report position past 95%
      final saved = await rs.savePosition(
        uri: 'file:///vid.mp4',
        position: const Duration(minutes: 58),
        duration: const Duration(hours: 1),
      );
      expect(saved, isFalse);
      expect(await rs.getPosition('file:///vid.mp4'), isNull);
    });

    test('clearPosition wipes only the named URI', () async {
      final rs = ResumeStorage();
      await rs.savePosition(
        uri: 'file:///a.mp4',
        position: const Duration(minutes: 1),
        duration: const Duration(hours: 1),
      );
      await rs.savePosition(
        uri: 'file:///b.mp4',
        position: const Duration(minutes: 2),
        duration: const Duration(hours: 1),
      );
      await rs.clearPosition('file:///a.mp4');
      expect(await rs.getPosition('file:///a.mp4'), isNull);
      expect(await rs.getPosition('file:///b.mp4'), const Duration(minutes: 2));
    });
  });

  group('ResumeStorage — crash recovery markers', () {
    test('getLastPlaying returns null on a fresh install', () async {
      final rs = ResumeStorage();
      expect(await rs.getLastPlaying(), isNull);
    });

    test('setLastPlaying / getLastPlaying round-trips', () async {
      final rs = ResumeStorage();
      await rs.setLastPlaying(
        uri: 'file:///movie.mp4',
        title: 'My Movie',
      );
      final result = await rs.getLastPlaying();
      expect(result, isNotNull);
      expect(result!.uri, 'file:///movie.mp4');
      expect(result.title, 'My Movie');
    });

    test('getLastPlaying returns position when one is saved', () async {
      final rs = ResumeStorage();
      await rs.savePosition(
        uri: 'file:///movie.mp4',
        position: const Duration(minutes: 10),
        duration: const Duration(hours: 2),
      );
      await rs.setLastPlaying(
        uri: 'file:///movie.mp4',
        title: 'My Movie',
      );
      final result = await rs.getLastPlaying();
      expect(result!.position, const Duration(minutes: 10));
    });

    test('clearLastPlaying makes the marker vanish', () async {
      final rs = ResumeStorage();
      await rs.setLastPlaying(
        uri: 'file:///movie.mp4',
        title: 'My Movie',
      );
      await rs.clearLastPlaying();
      expect(await rs.getLastPlaying(), isNull);
    });

    test('clearPosition does NOT clear the lastPlaying marker', () async {
      // Important: the crash-recovery marker is independent of the
      // per-URI position. Completing a video clears its resume
      // position, but the user's "I was just watching this" marker
      // should still let the next cold start prompt them — only an
      // explicit dispose() clears that.
      final rs = ResumeStorage();
      await rs.savePosition(
        uri: 'file:///movie.mp4',
        position: const Duration(minutes: 10),
        duration: const Duration(hours: 2),
      );
      await rs.setLastPlaying(
        uri: 'file:///movie.mp4',
        title: 'My Movie',
      );
      await rs.clearPosition('file:///movie.mp4');
      final result = await rs.getLastPlaying();
      expect(result, isNotNull);
      expect(result!.uri, 'file:///movie.mp4');
      // Position is now null because clearPosition wiped it
      expect(result.position, isNull);
    });
  });
}
