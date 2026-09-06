// Tests for the pre-install checks behind Settings → App update → Install.
// Step 4 of docs/updater_plan.md.
//
// THE ONE THAT MATTERS is the re-hash. The download already verified this
// file, so it is tempting to treat "Downloaded" as permanently trustworthy —
// but the APK then sits in a cache directory that the OS prunes, that any file
// manager can reach, and that another app with storage access could write to.
// The installer must never be handed bytes that have not just been agreed
// with, and if they have changed the file has to GO, or the next tap offers to
// install the same bad bytes again.
//
// The install intent itself is not tested here and cannot usefully be: it is
// one platform call whose whole job is to hand control to Android. What is
// tested is every decision made BEFORE that call, which is where the damage
// would be done.

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/data/update_install_service.dart';

const MethodChannel _channel = MethodChannel('mx_clone/transfer_service');

String _hex(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File apk;
  late List<int> body;

  /// Every platform call the install path makes, in order, so a test can prove
  /// that the intent was NOT fired.
  late List<String> calls;

  /// What the stubbed platform answers.
  late bool canInstall;
  late bool? certMatches;
  late bool openSucceeds;

  void installPlatform() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'canInstallApks':
          return canInstall;
        case 'apkCertMatchesInstalled':
          return certMatches;
        case 'openFile':
          return openSucceeds;
        case 'openInstallPermission':
          return true;
      }
      return null;
    });
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('install_test');
    body = List<int>.generate(2048, (i) => i % 256);
    apk = File('${dir.path}/innocent-321.apk');
    await apk.writeAsBytes(body);

    calls = [];
    canInstall = true;
    certMatches = true;
    openSucceeds = true;
    installPlatform();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<UpdateInstallOutcome> install({String? sha}) =>
      const UpdateInstallService().install(
        filePath: apk.path,
        expectedSha256: sha ?? _hex(body),
      );

  group('the pre-install re-hash', () {
    test('an intact file reaches the installer', () async {
      expect(await install(), UpdateInstallOutcome.handedToInstaller);
      expect(calls, contains('openFile'));
      expect(await apk.exists(), isTrue);
    });

    test('a file changed since the download is refused and deleted', () async {
      // Exactly the case the second verification exists for: the download
      // verified these bytes, and something replaced them afterwards.
      await apk.writeAsBytes(List<int>.filled(2048, 9));

      expect(await install(), UpdateInstallOutcome.damaged);

      // NOT handed over. This is the assertion the whole file is here for.
      expect(calls, isNot(contains('openFile')));
      // And gone, so the next tap cannot offer the same bad bytes.
      expect(await apk.exists(), isFalse);
    });

    test('a truncated file is refused and deleted', () async {
      await apk.writeAsBytes(body.sublist(0, 1000));

      expect(await install(), UpdateInstallOutcome.damaged);
      expect(calls, isNot(contains('openFile')));
      expect(await apk.exists(), isFalse);
    });

    test('the hash is checked before anything else is asked of the platform',
        () async {
      await apk.writeAsBytes(List<int>.filled(2048, 9));
      await install();

      // No permission check, no certificate check, no intent — a file that
      // fails the hash is not worth another question.
      expect(calls, isEmpty);
    });

    test('a missing file is reported, not installed', () async {
      await apk.delete();

      expect(await install(), UpdateInstallOutcome.missing);
      expect(calls, isNot(contains('openFile')));
    });
  });

  group('the signing-key emergency', () {
    test('a mismatched certificate never reaches the installer', () async {
      certMatches = false;

      expect(await install(), UpdateInstallOutcome.signatureMismatch);
      expect(calls, contains('apkCertMatchesInstalled'));
      // Android would refuse this update with no override and no recovery.
      // Firing the intent would show a generic "App not installed" and teach
      // the user nothing.
      expect(calls, isNot(contains('openFile')));
      // The file stays: it is not corrupt, and deleting it would hide the
      // evidence of a signing mistake worth investigating.
      expect(await apk.exists(), isTrue);
    });

    test('an unanswerable certificate check proceeds', () async {
      // null means the platform would not say. Refusing on an unknown would
      // block every legitimate update on any device we cannot read.
      certMatches = null;

      expect(await install(), UpdateInstallOutcome.handedToInstaller);
      expect(calls, contains('openFile'));
    });
  });

  group('install unknown apps', () {
    test('a blocked switch asks for permission instead of failing silently',
        () async {
      canInstall = false;

      expect(await install(), UpdateInstallOutcome.permissionNeeded);
      expect(calls, isNot(contains('openFile')));
      // The file is untouched — the download was fine, the switch was not.
      expect(await apk.exists(), isTrue);
    });

    test('openInstallPermission reaches the platform', () async {
      await const UpdateInstallService().openInstallPermission();
      expect(calls, contains('openInstallPermission'));
    });

    test('the permission is checked only after the file is proven good',
        () async {
      await install();
      expect(
        calls.indexOf('apkCertMatchesInstalled'),
        lessThan(calls.indexOf('canInstallApks')),
      );
      expect(
        calls.indexOf('canInstallApks'),
        lessThan(calls.indexOf('openFile')),
      );
    });
  });

  group('no installer', () {
    test('a phone that cannot open an APK is reported', () async {
      openSucceeds = false;
      expect(await install(), UpdateInstallOutcome.noHandler);
    });
  });
}
