import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/private_folder/private_folder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The vault's cooling-off after wrong PINs, on a clock nobody can set.
///
/// WHY THIS FILE EXISTS
///
/// The cooling-off was a wall-clock deadline, and the date is a setting. Five
/// wrong PINs, the date moved a quarter of an hour forward in Settings, five
/// more: the escalating limiter cost whoever held the phone a trip to
/// Settings and nothing else (OWASP MASTG: a local lockout must not rest on
/// a time the user controls). It now counts time since boot, which no
/// setting changes. These tests move the date and the boot clock apart and
/// check that only the boot clock decides — and that a reboot, which resets
/// it, starts the wait again rather than ending it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cooldownLeft — the arithmetic', () {
    test('same boot: the length less the time since the start', () {
      expect(
        PrivateFolderService.cooldownLeft(
            startMs: 1000000, lengthMs: 15000, nowMs: 1005000),
        const Duration(milliseconds: 10000),
      );
    });

    test('same boot, the length passed: attempts allowed', () {
      expect(
        PrivateFolderService.cooldownLeft(
            startMs: 1000000, lengthMs: 15000, nowMs: 1015000),
        isNull,
      );
    });

    test('rebooted since (now is before the start): counted from boot', () {
      // Locked 15 min at 10 h of uptime; the phone restarted and has been up
      // for 2 min. Nothing says how long it was off, so 13 min are left.
      expect(
        PrivateFolderService.cooldownLeft(
            startMs: 36000000, lengthMs: 900000, nowMs: 120000),
        const Duration(minutes: 13),
      );
    });

    test('rebooted and up longer than the wait: attempts allowed', () {
      expect(
        PrivateFolderService.cooldownLeft(
            startMs: 36000000, lengthMs: 900000, nowMs: 900000),
        isNull,
      );
    });
  });

  group('the service, with the date and the boot clock apart', () {
    const channel = MethodChannel('mx_clone/intruder_cam');
    late int bootMs;
    late bool clockAnswers;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      SharedPreferences.setMockInitialValues(<String, Object>{});
      bootMs = 50000000;
      clockAnswers = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'elapsedRealtime') {
          if (!clockAnswers) throw PlatformException(code: 'none');
          return bootMs;
        }
        return null; // 'capture': no camera here
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> missFive(PrivateFolderService svc) async {
      for (var i = 0; i < 5; i++) {
        await svc.registerFailedAttempt(attempted: '0000', method: 'pin');
      }
    }

    test('five misses lock for 15 s on the boot clock', () async {
      final svc = PrivateFolderService();
      await missFive(svc);
      final left = await svc.lockoutRemaining();
      expect(left, const Duration(seconds: 15));
      bootMs += 14000;
      expect(await svc.lockoutRemaining(), const Duration(seconds: 1));
      bootMs += 1000;
      expect(await svc.lockoutRemaining(), isNull);
    });

    test('moving the date forward does not end the wait', () async {
      final svc = PrivateFolderService();
      await missFive(svc);
      // What Settings > Date does: the stored wall-clock deadline is now in
      // the past. The boot clock has not moved.
      final st = await svc.loadLockout();
      await svc.saveLockout(
          st.failed, DateTime.now().subtract(const Duration(hours: 1)));
      // saveLockout with a deadline keeps the anchor; only a cleared lockout
      // drops it.
      expect(await svc.lockoutRemaining(), const Duration(seconds: 15));
    });

    test('a miss during the wait does not start a fresh count from zero',
        () async {
      final svc = PrivateFolderService();
      await missFive(svc);
      bootMs += 5000;
      final st = await svc.registerFailedAttempt(method: 'pin');
      expect(st.failed, 6);
      expect(st.until, isNotNull, reason: 'the running wait is kept');
      expect(await svc.lockoutRemaining(), const Duration(seconds: 10));
    });

    test('the next tier is a minute, counted on the boot clock too', () async {
      final svc = PrivateFolderService();
      await missFive(svc);
      bootMs += 15000;
      await missFive(svc);
      expect(await svc.lockoutRemaining(), const Duration(minutes: 1));
    });

    test('a reboot starts the wait again instead of ending it', () async {
      final svc = PrivateFolderService();
      await missFive(svc);
      await missFive(svc); // the second tier, a minute, from 50,000 s of uptime
      bootMs = 20000; // restarted, up for 20 s
      expect(await svc.lockoutRemaining(), const Duration(seconds: 40));
    });

    test('a right PIN clears the wait and its anchor', () async {
      final svc = PrivateFolderService();
      await missFive(svc);
      await svc.clearLockout();
      expect(await svc.lockoutRemaining(), isNull);
      // A later single miss is not a lockout.
      await svc.registerFailedAttempt(method: 'pin');
      expect(await svc.lockoutRemaining(), isNull);
    });

    test('no boot clock (platform silent): the old date deadline decides',
        () async {
      clockAnswers = false;
      final svc = PrivateFolderService();
      await missFive(svc);
      final left = await svc.lockoutRemaining();
      expect(left, isNotNull);
      expect(left!.inSeconds, inInclusiveRange(13, 15));
    });

    test('a lockout an older build began (no anchor) still holds', () async {
      final svc = PrivateFolderService();
      await svc.saveLockout(
          5, DateTime.now().add(const Duration(seconds: 30)));
      final left = await svc.lockoutRemaining();
      expect(left, isNotNull);
      expect(left!.inSeconds, inInclusiveRange(28, 30));
    });
  });
}
