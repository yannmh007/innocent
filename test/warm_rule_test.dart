import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/warm_rule.dart';

void main() {
  bool allowed({
    bool offline = false,
    bool metered = false,
    bool dataSaver = false,
    bool heldOnPhone = false,
  }) =>
      warmAllowed(
        offline: offline,
        metered: metered,
        dataSaver: dataSaver,
        heldOnPhone: heldOnPhone,
      );

  test('on an unmetered line, saver off, film not on the phone: warm it', () {
    expect(allowed(), isTrue);
  });

  test('never on mobile data — it is the viewer\'s money', () {
    expect(allowed(metered: true), isFalse);
  });

  test('never with the data saver on — they asked for exactly this not to happen', () {
    expect(allowed(dataSaver: true), isFalse);
  });

  test('never offline — there is nothing to fetch from', () {
    expect(allowed(offline: true), isFalse);
  });

  test('never for a downloaded film — Play opens the file, not the stream', () {
    expect(allowed(heldOnPhone: true), isFalse);
  });
}
