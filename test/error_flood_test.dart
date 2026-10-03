import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/error_flood.dart';

/// The flood that froze a Galaxy S23 on 2026-10-03: hundreds of
/// "Error decoding audio." in one tick, each one running the player's
/// handler on the UI thread.
void main() {
  late DateTime t;
  ErrorFloodGate gate() => ErrorFloodGate(clock: () => t);
  setUp(() => t = DateTime(2026, 10, 3, 9));

  test('the first of a kind passes, its repeats do not', () {
    final g = gate();
    expect(g.admit('Error decoding audio.'), ErrorVerdict.pass);
    t = t.add(const Duration(milliseconds: 500));
    expect(g.admit('Error decoding audio.'), ErrorVerdict.repeat);
    t = t.add(const Duration(seconds: 5));
    expect(g.admit('Error decoding audio.'), ErrorVerdict.pass,
        reason: 'the same line long after is news again');
  });

  test('repeats are summarised when something else arrives', () {
    final g = gate();
    g.admit('a');
    g.admit('a');
    g.admit('a');
    expect(g.admit('b'), ErrorVerdict.pass);
    expect(g.takeSummary(), '(previous line ×3)');
    expect(g.takeSummary(), isNull);
  });

  test('a burst is a storm, once per file, and everything after is quiet', () {
    final g = gate();
    final verdicts = <ErrorVerdict>[
      for (var i = 0; i < 300; i++) g.admit('Error decoding audio.'),
    ];
    expect(verdicts.where((v) => v == ErrorVerdict.storm).length, 1);
    expect(verdicts.where((v) => v == ErrorVerdict.pass).length, 1);
    expect(verdicts.indexOf(ErrorVerdict.storm), 29);
    expect(g.admit('Something new'), ErrorVerdict.repeat,
        reason: 'the file has been judged; nothing more is acted on');
    g.reset();
    expect(g.admit('Error decoding audio.'), ErrorVerdict.pass,
        reason: 'a new file starts clean');
  });

  test('errors spread out over time are not a storm', () {
    final g = gate();
    for (var i = 0; i < 100; i++) {
      t = t.add(const Duration(milliseconds: 200));
      expect(g.admit('e$i'), isNot(ErrorVerdict.storm));
    }
  });
}
