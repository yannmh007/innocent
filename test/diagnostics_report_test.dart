import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/diagnostics_report.dart';

/// What leaves the phone on "Report a problem" (migration 037). The table
/// is the operator's alone, but the trail is still a record of somebody's
/// phone: nothing shaped like a link, a token, an address or a path in their
/// storage may survive into it.
void main() {
  test('links, tokens, emails and storage paths are cut out', () {
    final out = DiagnosticsReport.redact(
      'open https://x.workers.dev/v/abcDEF123?sig=1 ok\n'
      'token Zq9vR2mXcT7wLp4sKd8nHb3yFg6uJe5aQr1tWx0oPz\n'
      'mail someone@example.com\n'
      'file /storage/emulated/0/Movies/my holiday.mp4\n'
      'content://media/external/video/42\n'
      'dl pass x3 from 0/396 MB http 200',
    );
    expect(out, isNot(contains('workers.dev')));
    expect(out, isNot(contains('Zq9vR2mXcT7w')));
    expect(out, isNot(contains('someone@')));
    expect(out, isNot(contains('/storage/emulated')));
    expect(out, isNot(contains('content://')));
    // The trail's own words survive: they are the point.
    expect(out, contains('dl pass x3 from 0/396 MB http 200'));
  });

  test('a long trail keeps its newest lines', () {
    final old = List<String>.generate(5000, (i) => 'old line $i').join('\n');
    final trail = DiagnosticsReport.buildTrail(
      playback: 'THE PROBLEM IS HERE',
      session: old,
      previous: '',
    );
    expect(trail.length, lessThanOrEqualTo(DiagnosticsReport.maxTrail + 40));
    expect(trail, contains('THE PROBLEM IS HERE'));
    expect(trail, startsWith('…(older lines cut)'));
  });

  test('the previous session is included only when there is one', () {
    expect(
        DiagnosticsReport.buildTrail(playback: 'a', session: 'b', previous: ''),
        isNot(contains('previous session')));
    expect(
        DiagnosticsReport.buildTrail(playback: 'a', session: 'b', previous: 'crash'),
        contains('previous session'));
  });

  test('report codes fit the table and are easy to read aloud', () {
    final r = Random(7);
    for (var i = 0; i < 500; i++) {
      final c = DiagnosticsReport.newCode(r);
      // migration 037: code ~ '^[A-Z0-9]{6,12}$'
      expect(RegExp(r'^[A-Z0-9]{6,12}$').hasMatch(c), isTrue, reason: c);
      expect(c, isNot(matches(RegExp('[01OI]'))));
    }
  });
}
