// Tests for the resumable APK download behind Settings → App update.
//
// THESE COVER THE TWO BUGS THAT REACHED A REAL PHONE, and nothing else:
//
//   1. RESUME RESTARTED FROM ZERO. An interrupted download has to continue
//      from the bytes already on disk, which means the second request must
//      carry `Range: bytes=<partial size>-`. The test asserts the header the
//      server actually received, not just that the file ended up correct — a
//      download that silently re-fetched all 88 MB would also end up correct,
//      and on a metered bundle that is the whole problem.
//
//   2. TWO WRITERS, ONE .part. The screen used to own the download, so
//      reopening it mid-fetch offered a Download button that started a SECOND
//      writer appending to the same file. The result was a file of the wrong
//      length and a SHA-256 failure at 100% that read like a corrupt server
//      object. The test starts two downloads at once and asserts that exactly
//      one fetch reached the server and the file is byte-correct.
//
// Everything runs against a real HttpServer on the loopback interface and the
// real transport in UpdateDownloadService — no mock of the thing under test.
// The only seams are the download directory (a temp dir) and the foreground
// service's MethodChannel, which has no implementation in a test binding.

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/data/update_download_controller.dart';
import 'package:innocent/features/updater/data/update_download_service.dart';
import 'package:innocent/features/updater/domain/app_release.dart';

/// A self-signed certificate for 127.0.0.1, valid for a century.
///
/// The download refuses any URL that is not `https`, and that check is not
/// relaxed for tests — so the test serves real TLS instead. Generated once
/// with openssl; it guards nothing and is checked in deliberately.
const String _testCertPem = '''
-----BEGIN CERTIFICATE-----
MIIDJzCCAg+gAwIBAgIUOKxesmRGKBYCAhobDRDMcGUyhK0wDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDkwNjA1NDc1MFoYDzIxMjYw
ODEzMDU0NzUwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQClz1jOO0AvseadSY5zzoigy0IQR2KsUz3cxNM2u3mN
2BvDKN17PMNd3nXdOa4hx6VdDtcZMggquoGdf9lTbMp1bZY7gowuNJZCwSvJ+Jad
/lKFvuLtVOFl4orx6wHm+738OAF11Pm3gH0URj+PBoizyvVQJY6Ad0E6yWvm9k6g
GWA+k+WShqOikiQBQOd0JD8EhqpF6EEiXZXHBlyzhshniSiHegh6BM3KpKPlfyXA
ZrrIlbymSJKksh8s9c9Q+cPiv/MesRgDiI7k0Jw+Mn3Hhc3S7RgW3eNOY0gOpgT4
OIOiLGHsw2aqYvPfTxOQErlDLXqQuRPuK27y2yJBI1tVAgMBAAGjbzBtMB0GA1Ud
DgQWBBQ/D5D1VI+HNoqA3zKFcB/7NzqBLDAfBgNVHSMEGDAWgBQ/D5D1VI+HNoqA
3zKFcB/7NzqBLDAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGHBH8AAAGCCWxv
Y2FsaG9zdDANBgkqhkiG9w0BAQsFAAOCAQEAmmvxJxw1lnuyAA20oSWhPj8+QvZp
HXJDDsQQ9m3cx4QgrVYZJePL8bsL+aUcWNn6+lWbxlbEMxiyNl2ylrPVgI78tUHk
jiuPfMOm2EG/VHrhgHU+qMvHhxZq3a30rV1sAU+k381yUH7ljV32EnTR+ZojDPhe
5HwgG0vMg2sqNU3KVDJ7Z4TnucbrV4quVUnoUkap212SgzMfxE8YIZ+/lCq0cx6n
AT/5L7ZzrfSVImlbcIt+fjmHbhoJkctGG/u04WANPQFDqR9vCm/5qwkS4Cj5VPiR
1kBWQFUBjx2tJIUwZSAHxYmvwZl7EQ3eyJqpO/n+lK3qbXcUTHovs93V8g==
-----END CERTIFICATE-----
''';

const String _testKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQClz1jOO0Avsead
SY5zzoigy0IQR2KsUz3cxNM2u3mN2BvDKN17PMNd3nXdOa4hx6VdDtcZMggquoGd
f9lTbMp1bZY7gowuNJZCwSvJ+Jad/lKFvuLtVOFl4orx6wHm+738OAF11Pm3gH0U
Rj+PBoizyvVQJY6Ad0E6yWvm9k6gGWA+k+WShqOikiQBQOd0JD8EhqpF6EEiXZXH
BlyzhshniSiHegh6BM3KpKPlfyXAZrrIlbymSJKksh8s9c9Q+cPiv/MesRgDiI7k
0Jw+Mn3Hhc3S7RgW3eNOY0gOpgT4OIOiLGHsw2aqYvPfTxOQErlDLXqQuRPuK27y
2yJBI1tVAgMBAAECggEACM2DR3T51A5mfJSPzYd6KsnfuKwxiY3kdji020OvZl/C
HuWn1zJt+ikkqhlf10dEI4v1e3mehAuMH2fO3+ZMsVifZeATv82RlKWwxMjqe3op
uL6zntSndW3w4SW633UfVv6aL+lIq1H/p03mHe/DiNgOQgexvbxBvZ89QpvHp37b
gsnkhHVmyIHhFWfBOa0asvNBz4e+FdMsAdGs2YapqWsUnoPZ318vEAczokVXxwxD
CtAZLLSfL3iAMFYWf5YCr3NOG9TjIXTnKB8DS8tZOxJg/cmR8GUVNHVbCAvnKF/b
qFs+VC/Bvyp2ztRbhdlStpvXdYJQE9CRhYv0xdrBAQKBgQDSyLwtI2XGVR2mxQBl
80WnKg9AYgpzzE+EyQQxOtgi2Tn3GBqSWguxAaZj/ke2xa3wIlqRgB03DNh7hdQh
WE1eixlK6StXQYI7Y2Fr6QZB8lKlJMpyTxCZsyTpdIY0HmxfLoFNRcEygKwcRNeE
uXw61F1vQikk80rk2wCc0RDeNQKBgQDJYNfrLTWFmuhhCMjGEf0f6xkhL9TBf1yo
yGsj1D+OQB2ZZ6+uZSf5R967/kwIFuxvrYFDnZ/2GUVuOSM8oyOexbkuk2IFjUq1
PTDvrCSOKM/4170hikPf4pKHzN94PkdCaBMqq14uKOn0saG3Y3/wFx3iTGu3ALc8
4Kj0psysoQKBgDQpTLf23Ia6JX5RngmcrA30EJYkLOX/F2aKwCjWoQnuq7OEGX9C
HUaOW/i+wkxumt6kAbmj9Jbc7O2UbqxZx7uvvHCXRwxuv6WmsEMeBVhoeR84/YhQ
HJGMjYPgPB3FsZfUUFco/ehbgzvzpUnJBP8h8oVH4BquwkfkEkC8U+pJAoGAG7jn
QIriuVfP8bvB1/KWBBTbSsRI57Je0SV2CmKntS+CY6Hwf3ORgzGvqfWiBeMR/XXH
O8WxRbHI6xmWjjxvJOZXTeAgOF9xD24zFGuARMm9h6Y7dSiRm3qXbXZ4tRbtvGiT
auZYesZLHtJtTs+1xxmHlaWrlm/Uyd6ro7JqrsECgYEArNUDesiQF8ZlY42lmxC/
d8pb7REHoq6qaD9RLtWQZmDrXX+7aDHDUCB8PfgrP1pQBvwHt+cj+VdR40r1MAsM
XRgpsWup5TzkccDWufzYGvtyFOhgMXjookcI+/k/OPEOthwOyFGT37HcWBAqDxxF
pCiWey4ZwKxPwll2ursl/RM=
-----END PRIVATE KEY-----
''';

/// A Range-aware static file server that can also be told to misbehave.
class _ApkServer {
  _ApkServer(this.body);

  final List<int> body;
  HttpServer? _server;

  /// Every Range header the server was sent, in order. The resume assertion
  /// reads this.
  final List<String?> rangeHeaders = [];

  /// How many GETs arrived. The concurrency assertion reads this.
  int requests = 0;

  /// When set, the NEXT response is cut off after this many bytes and the
  /// socket is closed, simulating a dropped link mid-download. Consumed on
  /// use, so a test that wants three interruptions sets it three times.
  int? truncateNextResponseAt;

  /// When set, every response omits Content-Range on a 206.
  bool omitContentRange = false;

  /// When set, 206 responses claim this total instead of the real one.
  int? lieAboutTotal;

  int get port => _server!.port;
  String get url => 'https://127.0.0.1:$port/innocent.apk';

  Future<void> start() async {
    final context = SecurityContext()
      ..useCertificateChainBytes(_testCertPem.codeUnits)
      ..usePrivateKeyBytes(_testKeyPem.codeUnits);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    _server = server;
    server.listen((req) async {
      requests++;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      rangeHeaders.add(range);

      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (start > body.length) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.partialContent;
        if (!omitContentRange) {
          final total = lieAboutTotal ?? body.length;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${body.length - 1}/$total',
          );
        }
      }

      final slice = body.sublist(start);
      final cut = truncateNextResponseAt;
      if (cut != null) {
        truncateNextResponseAt = null;
        // No Content-Length: the client must notice the short read itself.
        req.response.add(slice.sublist(0, min(cut, slice.length)));
        await req.response.flush();
        await req.response.close().catchError((_) {});
        return;
      }
      req.response.contentLength = slice.length;
      req.response.add(slice);
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

String _hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Only the fields the download reads.
AppRelease _release(_ApkServer server, {int versionCode = 321}) => AppRelease(
      versionName: '1.64.8',
      versionCode: versionCode,
      apkUrl: server.url,
      apkSha256: _hex(server.body),
      apkBytes: server.body.length,
    );

/// The offset in every Range header the server saw, for readable assertions.
List<int> _rangeOffsets(_ApkServer server) => server.rangeHeaders
    .whereType<String>()
    .map((h) => int.parse(RegExp(r'bytes=(\d+)-').firstMatch(h)!.group(1)!))
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _ApkServer server;
  late UpdateDownloadService service;
  late List<int> body;

  setUp(() async {
    // TestWidgetsFlutterBinding installs HttpOverrides that answer EVERY
    // request with 400 and never touch a socket — sensible for widget tests,
    // fatal here, because the transport is the thing under test. Clearing the
    // override restores the real HttpClient; the binding is still needed for
    // the MethodChannel mock below.
    HttpOverrides.global = null;

    // The foreground service has no Android side in a test binding. Swallowing
    // the calls keeps the transport under test and the output readable.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('mx_clone/transfer_service'),
      (call) async => true,
    );

    dir = await Directory.systemTemp.createTemp('updater_test');
    final rnd = Random(11);
    body = List<int>.generate(400000, (_) => rnd.nextInt(256));
    server = _ApkServer(body);
    await server.start();
    service = UpdateDownloadService(
      downloadDirOverride: () async => dir,
      // Trusts ONLY this test's own certificate, on loopback. The production
      // client is untouched.
      httpClientFactory: () => HttpClient(
        context: SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(_testCertPem.codeUnits),
      ),
    );
  });

  tearDown(() async {
    await server.stop();
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('mx_clone/transfer_service'),
      null,
    );
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> download(AppRelease release) => service.download(
        release,
        notificationTitle: 'Downloading update',
        notificationDone: 'Downloaded',
      );

  group('resume', () {
    test('a clean download produces the published bytes', () async {
      final file = await download(_release(server));

      expect(await file.readAsBytes(), body);
      expect(server.requests, 1);
      // Nothing on disk was resumable, so no Range was sent.
      expect(server.rangeHeaders, [null]);
      expect(file.path, endsWith('innocent-321.apk'));
    });

    test('an interrupted download keeps its .part', () async {
      server.truncateNextResponseAt = 150000;

      await expectLater(
        download(_release(server)),
        throwsA(isA<UpdateDownloadFailure>().having(
          (e) => e.kind,
          'kind',
          UpdateDownloadFailureKind.network,
        )),
      );

      // THE POINT OF THE WHOLE REWORK: a dropped link must not cost the bytes
      // already fetched.
      final part = File('${dir.path}/innocent-321.apk.part');
      expect(await part.exists(), isTrue);
      expect(await part.length(), 150000);
    });

    test('resume continues from the offset instead of starting over',
        () async {
      server.truncateNextResponseAt = 150000;
      await expectLater(download(_release(server)), throwsA(anything));
      final carriedOver = await File('${dir.path}/innocent-321.apk.part')
          .length();

      final file = await download(_release(server));

      // The bytes are right...
      expect(await file.readAsBytes(), body);
      // ...and they were not re-fetched. The second request asked to continue
      // from exactly what was on disk.
      expect(_rangeOffsets(server), [carriedOver]);
      expect(server.requests, 2);
    });

    test('resume survives several interruptions', () async {
      // A fixed slice per attempt, not a growing one: the cut applies to
      // what is LEFT to send, so a growing cut eventually exceeds the
      // remainder and the "interrupted" response quietly completes.
      for (var i = 0; i < 3; i++) {
        server.truncateNextResponseAt = 60000;
        await expectLater(download(_release(server)), throwsA(anything));
      }
      server.truncateNextResponseAt = null;
      final file = await download(_release(server));

      expect(await file.readAsBytes(), body);
      // Every resume moved forward; none restarted at zero.
      final offsets = _rangeOffsets(server);
      expect(offsets, isNotEmpty);
      expect(offsets.first, greaterThan(0));
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i], greaterThan(offsets[i - 1]));
      }
    });

    test('a 206 whose Content-Range names another total is not appended to',
        () async {
      server.truncateNextResponseAt = 100000;
      await expectLater(download(_release(server)), throwsA(anything));
      expect(
        await File('${dir.path}/innocent-321.apk.part').length(),
        100000,
      );

      // The object at this URL is now a different size, so the bytes on disk
      // belong to nothing. Appending would splice two APKs together — the
      // corruption that reads as tampering when the hash finally fails.
      server.lieAboutTotal = body.length + 4096;
      final before = server.requests;

      final file = await download(_release(server));

      // NOT an error to the user. The partial is dropped and the file is
      // re-fetched from zero in the same call, which is the outcome someone
      // wants when the publisher replaced a build mid-download.
      expect(await file.readAsBytes(), body);
      // Two requests: the refused resume, then a clean restart carrying no
      // Range header at all.
      expect(server.requests - before, 2);
      expect(server.rangeHeaders.last, isNull);
    });

    test('a partial from another version is discarded, not resumed', () async {
      final stale = File('${dir.path}/innocent-320.apk.part');
      await stale.writeAsBytes(List<int>.filled(90000, 7));

      final file = await download(_release(server, versionCode: 321));

      expect(await file.readAsBytes(), body);
      expect(await stale.exists(), isFalse);
      // The new version started clean; it never saw the old build's bytes.
      expect(server.rangeHeaders, [null]);
    });

    test('a corrupt complete file is deleted and reported as damaged',
        () async {
      final wrong = _release(server);
      final release = AppRelease(
        versionName: wrong.versionName,
        versionCode: wrong.versionCode,
        apkUrl: wrong.apkUrl,
        // A hash that no download can ever match.
        apkSha256: 'f' * 64,
        apkBytes: wrong.apkBytes,
      );

      await expectLater(
        download(release),
        throwsA(isA<UpdateDownloadFailure>().having(
          (e) => e.kind,
          'kind',
          UpdateDownloadFailureKind.damaged,
        )),
      );
      expect(
        await File('${dir.path}/innocent-321.apk.part').exists(),
        isFalse,
      );
    });
  });

  group('single owner', () {
    test('two concurrent starts run ONE download and do not corrupt the file',
        () async {
      final controller = UpdateDownloadNotifier(service);
      addTearDown(controller.dispose);
      final release = _release(server);

      // The reopened-screen case: something starts a download, and a second
      // caller that cannot see it presses Download too.
      final first = controller.start(
        release,
        notificationTitle: 'Downloading update',
        notificationDone: 'Downloaded',
      );
      final second = controller.start(
        release,
        notificationTitle: 'Downloading update',
        notificationDone: 'Downloaded',
      );

      // Attached, not started: the same future, so there is only one download.
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);

      expect(server.requests, 1);
      expect(controller.state.phase, UpdateDownloadPhase.done);

      final file = File('${dir.path}/innocent-321.apk');
      expect(await file.exists(), isTrue);
      // The 100% failure was a file of the wrong length. Both are checked
      // because the length is what told us there were two writers.
      expect(await file.length(), body.length);
      expect(_hex(await file.readAsBytes()), _hex(body));
    });

    test('repeated taps while downloading never spawn a second fetch',
        () async {
      final controller = UpdateDownloadNotifier(service);
      addTearDown(controller.dispose);
      final release = _release(server);

      final futures = <Future<void>>[
        for (var i = 0; i < 6; i++)
          controller.start(
            release,
            notificationTitle: 'Downloading update',
            notificationDone: 'Downloaded',
          ),
      ];
      await Future.wait(futures);

      expect(server.requests, 1);
      expect(await File('${dir.path}/innocent-321.apk').length(), body.length);
    });

    test('a start after one finishes reuses the verified file', () async {
      final controller = UpdateDownloadNotifier(service);
      addTearDown(controller.dispose);
      final release = _release(server);

      await controller.start(
        release,
        notificationTitle: 'Downloading update',
        notificationDone: 'Downloaded',
      );
      await controller.start(
        release,
        notificationTitle: 'Downloading update',
        notificationDone: 'Downloaded',
      );

      // The second start re-verified what was already on disk rather than
      // fetching it again.
      expect(server.requests, 1);
      expect(controller.state.phase, UpdateDownloadPhase.done);
    });

    test('an interrupted download leaves the controller waiting, not failed',
        () async {
      server.truncateNextResponseAt = 120000;
      final controller = UpdateDownloadNotifier(
        service,
        // Long enough that the auto-resume probe cannot fire during the test.
        retryDelay: const Duration(minutes: 5),
      );
      addTearDown(controller.dispose);

      await controller.start(
        _release(server),
        notificationTitle: 'Downloading update',
        notificationDone: 'Downloaded',
      );

      // Not `failed`: the bytes are intact and the controller is holding for
      // the network, which is what the screen renders as "Waiting for the
      // network" with no Retry required.
      expect(controller.state.phase, UpdateDownloadPhase.waitingForNetwork);
      expect(controller.state.failure?.isTransient, isTrue);
      expect(
        await File('${dir.path}/innocent-321.apk.part').length(),
        120000,
      );
    });
  });

  group('sha256', () {
    test('the streamed hash matches a one-shot hash', () async {
      // The download hashes in 1 MB slices; a mismatch here would mean every
      // large APK verified against the wrong digest.
      final file = await download(_release(server));
      final bytes = await file.readAsBytes();
      expect(sha256.convert(bytes).toString(), _hex(body));
    });
  });
}
