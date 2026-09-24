// The player's Information dialog was showing the signed R2 address.
//
// It is shared with the local library, where showing a file's folder is the
// whole point of the field. Opened over a Video Hub stream it showed the
// same field, and for a stream "the folder" is
//
//     https://<account-id>.r2.cloudflarestorage.com/innocent-media/<folder>/video
//
// — the account identifier, the private bucket's name and the shape of every
// key inside it, on a viewer's screen and in any screenshot they send.
//
// The near miss is the reason these are rules rather than a patch. The name
// field split the URI at its last `/`. A presigned SigV4 URL carries
// `X-Amz-Credential=<ACCESS-KEY-ID>/<date>/auto/s3/aws4_request` in the
// query string. Those slashes happen to be percent-encoded by the signer
// today, so the split lands before the filename — one encoding decision, in
// a different file, away from putting a key id on screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/utils/media_address.dart';

void main() {
  const signed =
      'https://abc123.r2.cloudflarestorage.com/innocent-media/test-003/video/'
      '20260922-solar-a1b2c3d4.mp4'
      '?X-Amz-Algorithm=AWS4-HMAC-SHA256'
      '&X-Amz-Credential=KEYID%2F20260923%2Fauto%2Fs3%2Faws4_request'
      '&X-Amz-Signature=deadbeef';

  group('isRemoteAddress', () {
    test('the signed stream is remote', () {
      expect(isRemoteAddress(signed), isTrue);
    });

    test('on-device sources are not remote', () {
      expect(isRemoteAddress('/sdcard/Movies/a.mp4'), isFalse);
      expect(isRemoteAddress('file:///sdcard/Movies/a.mp4'), isFalse);
      expect(isRemoteAddress('content://media/external/video/media/42'),
          isFalse);
      expect(isRemoteAddress('Movies/a.mp4'), isFalse);
    });

    test('an unrecognised scheme counts as remote', () {
      // Withholding a local path is a cosmetic loss; showing an address is
      // the failure. Anything this cannot vouch for is treated as an
      // address, so a source added later is private by default.
      expect(isRemoteAddress('rtsp://cam.example/1'), isTrue);
      expect(isRemoteAddress('adb://device/sdcard/a.mp4'), isTrue);
    });
  });

  group('showableLocation', () {
    test('a stream has no showable location at all', () {
      expect(
        showableLocation(
          candidate:
              'https://abc123.r2.cloudflarestorage.com/innocent-media/test-003/video',
        ),
        isNull,
      );
    });

    test('a real on-disk directory is shown', () {
      expect(
        showableLocation(onDiskDirectory: '/storage/emulated/0/Movies'),
        '/storage/emulated/0/Movies',
      );
    });

    test('the on-disk directory wins over a remote candidate', () {
      // A downloaded film has both: it came from R2 and it is now a file.
      // The file is what the viewer can act on.
      expect(
        showableLocation(
          onDiskDirectory: '/data/user/0/app/files/offline',
          candidate: 'https://abc123.r2.cloudflarestorage.com/innocent-media',
        ),
        '/data/user/0/app/files/offline',
      );
    });

    test('a path carrying a query string is refused', () {
      // A local path has no query. One here means the string was cut out of
      // a URL by hand, which is exactly how a signature would arrive.
      expect(
        showableLocation(candidate: '/sdcard/Movies?X-Amz-Signature=deadbeef'),
        isNull,
      );
    });

    test('empty and missing are both null, never an empty row', () {
      expect(showableLocation(), isNull);
      expect(showableLocation(candidate: '   '), isNull);
    });
  });

  group('showableFileName', () {
    test('a stream is named by its title, not by its object key', () {
      // The key is the uploader's, carries the folder scheme, and means
      // nothing to a viewer: `20260922-solar-a1b2c3d4.mp4`.
      expect(
        showableFileName(uri: signed, title: 'Solar'),
        'Solar',
      );
    });

    test('a local file is named by its file name', () {
      expect(
        showableFileName(
            uri: '/sdcard/Movies/Boy.Bastos.2022.720p.mkv', title: 'Boy'),
        'Boy.Bastos.2022.720p.mkv',
      );
    });

    test('the resolved on-disk name wins', () {
      expect(
        showableFileName(
            uri: signed, title: 'Solar', onDiskName: 'solar-offline.mp4'),
        'solar-offline.mp4',
      );
    });

    test('a title-less stream shows a dash rather than an address', () {
      expect(showableFileName(uri: signed, title: '   '), '—');
    });
  });
}
