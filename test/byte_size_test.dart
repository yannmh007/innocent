import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/byte_size.dart';

void main() {
  group('formatBytes', () {
    test('gigabytes carry one decimal, because half a gigabyte is half an '
        'evening and a third of a data bundle', () {
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes((1.47 * 1024 * 1024 * 1024).round()), '1.5 GB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });

    test('megabytes are whole, because nobody can act on one of them', () {
      expect(formatBytes(1024 * 1024), '1 MB');
      expect(formatBytes(412 * 1024 * 1024), '412 MB');
      expect(formatBytes(900 * 1024 * 1024), '900 MB');
    });

    test('the boundary is exact', () {
      expect(formatBytes(1024 * 1024 * 1024 - 1), '1024 MB');
      expect(formatBytes(1024 * 1024 - 1), '1024 KB');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1 KB');
    });

    test('zero and a negative are printed, never thrown', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-1), '0 MB');
    });
  });
}
