import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/download_plan.dart';

void main() {
  group('retryDelay', () {
    // THE BUG: there was no delay at all, so a twenty-attempt budget was spent
    // in about a second and a ten-second tunnel ended a download that had
    // forty minutes of progress on disk.
    test('no failures means no wait', () {
      expect(retryDelay(0), Duration.zero);
      expect(retryDelay(-1), Duration.zero);
    });

    test('doubles from two seconds', () {
      expect(retryDelay(1), const Duration(seconds: 2));
      expect(retryDelay(2), const Duration(seconds: 4));
      expect(retryDelay(3), const Duration(seconds: 8));
      expect(retryDelay(4), const Duration(seconds: 16));
      expect(retryDelay(5), const Duration(seconds: 32));
    });

    test('caps at a minute so a long outage is retried sixty times, not '
        'thousands', () {
      expect(retryDelay(6), const Duration(seconds: 60));
      expect(retryDelay(40), const Duration(seconds: 60));
      expect(retryDelay(1000), const Duration(seconds: 60));
    });

    test('never decreases', () {
      var previous = Duration.zero;
      for (var i = 0; i <= 12; i++) {
        final d = retryDelay(i);
        expect(d >= previous, isTrue, reason: 'step $i went backwards');
        previous = d;
      }
    });
  });

  group('planResume', () {
    test('an empty part file is not a resume', () {
      expect(
        planResume(onDisk: 0, expectedTotal: null, freshTotal: 900),
        ResumePlan.keep,
      );
    });

    test('same length means the same film', () {
      expect(
        planResume(onDisk: 400, expectedTotal: 900, freshTotal: 900),
        ResumePlan.keep,
      );
    });

    // THE BUG: nothing checked. An object replaced behind the same key made a
    // file that was half of one encode and half of another, passed the length
    // check, said "downloaded", and played until the seam.
    test('a different length means a different film', () {
      expect(
        planResume(onDisk: 400, expectedTotal: 900, freshTotal: 1200),
        ResumePlan.restart,
      );
      expect(
        planResume(onDisk: 400, expectedTotal: 900, freshTotal: 700),
        ResumePlan.restart,
      );
    });

    test('more on disk than the whole object cannot be a prefix of it', () {
      expect(
        planResume(onDisk: 1000, expectedTotal: null, freshTotal: 900),
        ResumePlan.restart,
      );
      expect(
        planResume(onDisk: 1000, expectedTotal: 900, freshTotal: null),
        ResumePlan.restart,
      );
    });

    test('an unknown length on both sides keeps what is there', () {
      // Nothing to compare is not evidence of a problem, and discarding real
      // bytes on no evidence spends the data again.
      expect(
        planResume(onDisk: 400, expectedTotal: null, freshTotal: null),
        ResumePlan.keep,
      );
    });

    test('landing exactly on the end is a finished download, not a restart', () {
      expect(
        planResume(onDisk: 900, expectedTotal: 900, freshTotal: 900),
        ResumePlan.keep,
      );
    });
  });

  group('hasRoomFor', () {
    const g = 1024 * 1024 * 1024;

    // THE BUG: nothing looked at free space, so a 900 MB film on a phone with
    // 300 MB free downloaded 300 MB of metered data and then failed on a full
    // disk with a message that said nothing about why.
    test('refuses a film that does not fit', () {
      expect(
        hasRoomFor(freeBytes: 300 * 1024 * 1024, totalBytes: 900 * 1024 * 1024),
        isFalse,
      );
    });

    test('allows a film that fits with headroom to spare', () {
      expect(hasRoomFor(freeBytes: 4 * g, totalBytes: g), isTrue);
    });

    test('refuses a film that fits only by filling the phone', () {
      // Exactly the size of the film and not a byte more: it would fit, and
      // the phone would then be unable to take a photo.
      expect(hasRoomFor(freeBytes: g, totalBytes: g), isFalse);
    });

    test('the headroom is the boundary, exactly', () {
      expect(
        hasRoomFor(freeBytes: g + kDownloadHeadroomBytes, totalBytes: g),
        isTrue,
      );
      expect(
        hasRoomFor(freeBytes: g + kDownloadHeadroomBytes - 1, totalBytes: g),
        isFalse,
      );
    });

    test('only the remaining bytes have to fit', () {
      // 900 MB of a 1 GB film is already on disk; the question is whether the
      // last 124 MB fit, not whether the whole film does again.
      expect(
        hasRoomFor(
          freeBytes: 400 * 1024 * 1024,
          totalBytes: g,
          alreadyOnDisk: 900 * 1024 * 1024,
        ),
        isTrue,
      );
    });

    test('a complete part file needs no room at all', () {
      expect(
        hasRoomFor(freeBytes: 0, totalBytes: g, alreadyOnDisk: g),
        isTrue,
      );
    });

    // A FAILED MEASUREMENT IS NOT PERMISSION. -1 means the platform did not
    // answer, and a feature that can fill a phone does not proceed on an
    // unanswered question.
    test('an unanswered measurement refuses', () {
      expect(hasRoomFor(freeBytes: -1, totalBytes: 1), isFalse);
      expect(hasRoomFor(freeBytes: -1, totalBytes: 0), isFalse);
    });

    test('a film of unknown size is not refused on arithmetic it cannot do', () {
      expect(hasRoomFor(freeBytes: 10 * g, totalBytes: 0), isTrue);
    });
  });
}
