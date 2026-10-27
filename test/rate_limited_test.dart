import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/rate_limited.dart';

/// The Worker's "slow down", read the way RFC 9110 lets a server say it:
/// seconds or a date, and clamped so neither a zero nor an hour is obeyed
/// literally.
void main() {
  final now = DateTime.utc(2026, 10, 27, 12, 0, 0);

  test('seconds: what the server asked for', () {
    expect(RateLimited.waitFor('10', now: now), const Duration(seconds: 10));
    expect(RateLimited.waitFor(' 4 ', now: now), const Duration(seconds: 4));
  });

  test('nothing said, or nothing readable: the Worker\'s own ten seconds', () {
    expect(RateLimited.waitFor(null, now: now), RateLimited.fallback);
    expect(RateLimited.waitFor('', now: now), RateLimited.fallback);
    expect(RateLimited.waitFor('soon', now: now), RateLimited.fallback);
    expect(RateLimited.fallback, const Duration(seconds: 10));
  });

  test('never less than a second: a zero is not a licence to hammer', () {
    expect(RateLimited.waitFor('0', now: now), const Duration(seconds: 1));
    expect(RateLimited.waitFor('-3', now: now), const Duration(seconds: 1));
  });

  test('never more than fifteen: the player has its own retry past that', () {
    expect(RateLimited.waitFor('120', now: now), RateLimited.longest);
    expect(RateLimited.waitFor('3600', now: now), const Duration(seconds: 15));
  });

  test('an HTTP date: the time left until it', () {
    expect(RateLimited.waitFor('Tue, 27 Oct 2026 12:00:07 GMT', now: now),
        const Duration(seconds: 7));
    // Already past: the shortest wait, not a negative one.
    expect(RateLimited.waitFor('Tue, 27 Oct 2026 11:59:00 GMT', now: now),
        const Duration(seconds: 1));
    // Far off: clamped like seconds are.
    expect(RateLimited.waitFor('Wed, 28 Oct 2026 12:00:00 GMT', now: now),
        RateLimited.longest);
  });

  test('IMF-fixdate is read exactly; the obsolete forms are refused', () {
    expect(HttpDateParse.parse('Sun, 06 Nov 1994 08:49:37 GMT'),
        DateTime.utc(1994, 11, 6, 8, 49, 37));
    expect(() => HttpDateParse.parse('Sunday, 06-Nov-94 08:49:37 GMT'),
        throwsFormatException);
    expect(() => HttpDateParse.parse('Sun Nov  6 08:49:37 1994'),
        throwsFormatException);
    expect(() => HttpDateParse.parse('Sun, 06 Foo 1994 08:49:37 GMT'),
        throwsFormatException);
  });

  test('pause sleeps for exactly what waitFor says', () async {
    final slept = <Duration>[];
    RateLimited.sleep = (d) async => slept.add(d);
    addTearDown(() => RateLimited.sleep = Future<void>.delayed);
    await RateLimited.pause('2');
    await RateLimited.pause(null);
    expect(slept, [const Duration(seconds: 2), RateLimited.fallback]);
  });
}
