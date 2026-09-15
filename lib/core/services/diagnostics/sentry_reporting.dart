import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../app_version.dart';
import 'crash_redaction.dart';

/// Off unless a DSN is compiled in, and silent about everything personal when
/// it is on.
///
/// WHY IT IS OFF BY DEFAULT. Innocent has no Play Store listing, no crash
/// console and no way to see a stack trace from a user's phone — which is why
/// `CrashBreadcrumbs` exists at all, writing a trail to disk that someone then
/// has to read out of Settings → Diagnostics by hand. Sentry closes that gap.
/// But it is also the first thing in this app that sends anything off the
/// device, and the app has a PIN-locked Private Folder. So it does nothing
/// whatsoever until a DSN is supplied:
///
///     flutter build apk --release --dart-define=SENTRY_DSN=https://…
///
/// With no DSN the SDK is never initialised — no network, no permissions, no
/// background work, no measurable cost. A build made the way this project's
/// CI makes one is therefore unchanged by this file.
///
/// THE DSN IS A BUILD ARGUMENT, NOT A COMMITTED CONSTANT, so it never lands
/// in the repository. That matters more than usual here: this is a public
/// repo, and a leaked DSN lets anyone post events into the project's quota.
///
/// WHAT IS SENT. Only what [redactSensitive] leaves behind — see that file for
/// the reasoning, and `test/crash_redaction_test.dart` for what is proven.
/// `sendDefaultPii` is off, so no IP address and no device name. Breadcrumbs
/// are redacted as well as events, because a breadcrumb is where a path is
/// most likely to appear.
///
/// HOW IT ATTACHES. It CHAINS the app's existing handlers rather than
/// replacing them, which is the same rule `CrashDiagnostics.installErrorHooks`
/// follows and for the same reason: `main.dart` deliberately owns
/// `PlatformDispatcher.instance.onError` and returns `true` there to keep the
/// isolate alive after an unawaited failure. Sentry's `OnErrorIntegration`
/// calls the previous handler and returns its result, so that decision
/// survives — verified by reading the integration, not assumed.
///
/// **Order matters.** [start] must be called AFTER `main.dart` installs its
/// own hooks. Called before, the assignment in `main.dart` would overwrite
/// Sentry's handler and async errors would never be reported.
class SentryReporting {
  SentryReporting._();

  /// Supplied at build time. Empty in every build that does not pass it,
  /// including this project's CI.
  static const String _dsn = String.fromEnvironment('SENTRY_DSN');

  static bool _active = false;

  /// True once [start] has actually initialised the SDK.
  static bool get isActive => _active;

  /// Whether this build carries a DSN at all. Useful to a diagnostics screen
  /// that wants to say "crash reporting: not configured" rather than nothing.
  static bool get isConfigured => _dsn.isNotEmpty;

  /// Initialise, or do nothing at all. Never throws: a failure here must not
  /// be able to stop the app starting, which would invert the whole point.
  static Future<void> start() async {
    if (_dsn.isEmpty || _active) return;
    try {
      await SentryFlutter.init((SentryFlutterOptions options) {
        options.dsn = _dsn;
        options.release = 'innocent@${AppVersion.full}';
        options.environment = kReleaseMode ? 'release' : 'debug';

        // No IP address, no device name, no username. The default is false
        // already; stated because it is the setting a future reader will come
        // looking for.
        options.sendDefaultPii = false;

        // Crashes only. This app has no performance budget to spend on
        // tracing, and a trace carries screen names and timings that are not
        // worth the bytes on a phone that may be on mobile data.
        options.tracesSampleRate = 0.0;
        options.enableAutoPerformanceTracing = false;

        // Screenshots and view hierarchies would defeat every line of
        // crash_redaction.dart in one attachment — a screenshot of the
        // Private Folder is the whole thing this app exists to avoid.
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;

        options.beforeSend = _scrubEvent;
        options.beforeBreadcrumb = _scrubBreadcrumb;
      });
      _active = true;
    } catch (e) {
      // Deliberately swallowed, and deliberately not a breadcrumb: a failure
      // to start crash reporting is not itself worth a crash report.
      debugPrint('Sentry init skipped: $e');
    }
  }

  /// Report an error the app has already handled itself.
  ///
  /// A no-op when inactive, so call sites need no `if`. Never throws.
  static Future<void> capture(Object error, StackTrace? stack,
      {String? where}) async {
    if (!_active) return;
    try {
      await Sentry.captureException(
        error,
        stackTrace: stack,
        withScope: (Scope scope) {
          if (where != null) {
            scope.setTag('where', redactSensitive(where));
          }
        },
      );
    } catch (_) {
      // As above: reporting must never be able to break the thing it watches.
    }
  }

  /// Runs on every event on its way out.
  ///
  /// Mutates in place rather than using `copyWith`, which this version of the
  /// SDK deprecates in favour of direct assignment.
  static SentryEvent? _scrubEvent(SentryEvent event, Hint hint) {
    try {
      for (final SentryException e in event.exceptions ?? const []) {
        e.value = redactSensitive(e.value ?? '');
      }
      for (final Breadcrumb b in event.breadcrumbs ?? const []) {
        b.message = redactSensitive(b.message ?? '');
      }
      // The message itself, for events captured without an exception.
      // `formatted` is non-nullable in this SDK version; `template` is the
      // un-interpolated form and is redacted too, since it can carry a path
      // just as easily.
      final SentryMessage? m = event.message;
      if (m != null) {
        event.message = SentryMessage(
          redactSensitive(m.formatted),
          template: m.template == null ? null : redactSensitive(m.template!),
          params: m.params,
        );
      }
      return event;
    } catch (_) {
      // If scrubbing itself fails, DROP the event. Sending an unscrubbed one
      // is the failure this whole file exists to prevent, and a lost crash
      // report is the cheaper of the two.
      return null;
    }
  }

  /// Runs on every breadcrumb before it is recorded.
  static Breadcrumb? _scrubBreadcrumb(Breadcrumb? crumb, Hint hint) {
    if (crumb == null) return null;
    try {
      crumb.message = redactSensitive(crumb.message ?? '');
      return crumb;
    } catch (_) {
      return null;
    }
  }
}
