// Crash reporting must be OFF in any build that does not ask for it.
//
// This is the contract that makes the feature safe to merge before anyone has
// decided whether to use it, and it is worth a test rather than a comment
// because it is invisible: nothing on screen changes either way, and the
// difference between "off" and "on and quietly failing to send" is a network
// trace nobody will take.
//
// CI builds with no `--dart-define=SENTRY_DSN`, so these run in exactly the
// configuration the shipped APK is built in today.
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/sentry_reporting.dart';

void main() {
  test('a build with no SENTRY_DSN is not configured', () {
    // If this ever fails, a DSN has been committed into the repository — which
    // is the thing sentry_reporting.dart's doc comment says must not happen,
    // because this is a public repo and a leaked DSN is someone else's events
    // in your quota.
    expect(SentryReporting.isConfigured, isFalse);
  });

  test('start() is a no-op and never throws without a DSN', () async {
    await SentryReporting.start();
    expect(SentryReporting.isActive, isFalse);
  });

  test('capture() is a no-op and never throws while inactive', () async {
    // Call sites are written without an `if`, so this has to hold — otherwise
    // adding a report line to an error path would itself be an error path.
    await SentryReporting.capture(
      StateError('a test error that must not be sent'),
      StackTrace.current,
      where: '/storage/emulated/0/Movies/private.mp4',
    );
    expect(SentryReporting.isActive, isFalse);
  });

  test('start() twice is still a no-op', () async {
    await SentryReporting.start();
    await SentryReporting.start();
    expect(SentryReporting.isActive, isFalse);
  });
}
