import 'dart:async';

import 'package:flutter/foundation.dart';

/// THE WORKER'S "SLOW DOWN", WAITED OUT (2026-10-27).
///
/// The stream Worker answers 429 with `Retry-After: 10` when one install,
/// account or link asks for more than its ceiling in ten seconds, and the
/// zone's rate-limiting rule in front of it does the same per address. Until
/// now every fetch here treated a 429 like any other refusal: the stream
/// proxy gave up on the part, the downloader came straight back (its network
/// wait ends as soon as a DNS lookup succeeds), and the player saw an error
/// where it should have seen a pause. That is why the Worker's ceiling stayed
/// in "log" (docs/security_streaming.md §6): enforced, it would have stalled
/// films instead of pacing them.
///
/// Now a 429 is a wait of what the server asked for — read from
/// `Retry-After`, as seconds or as a date — never less than a second, never
/// more than [longest], and then the same request again within the caller's
/// own try budget.
class RateLimited {
  RateLimited._();

  /// When a 429 says nothing about how long: the Worker's own answer and
  /// the zone rule's block both last ten seconds.
  static const Duration fallback = Duration(seconds: 10);

  /// Longer than this, and a viewer is better served by the player's own
  /// error and retry than by a request held open in silence.
  static const Duration longest = Duration(seconds: 15);

  static const Duration _shortest = Duration(seconds: 1);

  /// The HTTP status that means "slow down".
  static const int status = 429;

  /// How long a 429 asks to be left alone, from its `Retry-After` header:
  /// delta-seconds (`10`) or an HTTP date. Clamped to 1 s .. [longest].
  static Duration waitFor(String? retryAfter, {DateTime? now}) {
    final v = retryAfter?.trim() ?? '';
    Duration? asked;
    final secs = int.tryParse(v);
    if (secs != null) {
      asked = Duration(seconds: secs);
    } else if (v.isNotEmpty) {
      try {
        final at = HttpDateParse.parse(v);
        asked = at.difference((now ?? DateTime.now()).toUtc());
      } catch (_) {
        asked = null;
      }
    }
    final d = asked ?? fallback;
    if (d < _shortest) return _shortest;
    if (d > longest) return longest;
    return d;
  }

  /// Waits as [waitFor] says. Replaceable in tests, which do not sleep.
  @visibleForTesting
  static Future<void> Function(Duration) sleep = Future<void>.delayed;

  /// Waits out a 429 whose `Retry-After` is [retryAfter].
  static Future<void> pause(String? retryAfter) => sleep(waitFor(retryAfter));

  /// Waits [wait], already read from a 429 with [waitFor].
  static Future<void> hold(Duration wait) => sleep(wait);
}

/// RFC 9110's IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the only date
/// form a server may send in `Retry-After`. dart:io has a parser, but this
/// file is also used where dart:io's is not imported.
class HttpDateParse {
  HttpDateParse._();

  static const _months = <String, int>{
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static DateTime parse(String s) {
    final m = RegExp(r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$')
        .firstMatch(s.trim());
    final month = m == null ? null : _months[m.group(2)!.toLowerCase()];
    if (m == null || month == null) throw FormatException('not an HTTP date: $s');
    return DateTime.utc(int.parse(m.group(3)!), month, int.parse(m.group(1)!),
        int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6)!));
  }
}
