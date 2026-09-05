import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../app_version.dart';
import '../saf/saf_service.dart';
import 'crash_breadcrumbs.dart';
import 'playback_log.dart';

/// Did `AudioService.init()` succeed at startup, and if not, why?
///
/// A single global rather than a provider: it is written in `main()` before
/// the Riverpod container exists, and read once by a screen. Making it a
/// provider would mean threading it through an override for no gain.
class AudioServiceStatus {
  AudioServiceStatus._();

  /// null = init has not been attempted yet.
  static bool? ok;
  static String? error;

  static String get summary {
    if (ok == null) return 'not attempted';
    if (ok == true) return 'OK — music has its own media session';
    return 'FAILED — no music notification, no lock-screen or Bluetooth '
        'controls, no widget buttons\n  $error';
  }
}

/// Reads the crash / environment information the platform keeps about us.
///
/// See `Diagnostics.kt` for what Android actually provides and from which
/// version.
class CrashDiagnostics {
  CrashDiagnostics._();

  static const MethodChannel _channel = MethodChannel('mx_clone/diagnostics');

  static Future<String> deviceInfo() async {
    try {
      return await _channel.invokeMethod<String>('deviceInfo') ?? '';
    } catch (e) {
      return 'deviceInfo unavailable: $e\n';
    }
  }

  static Future<String> exitReasons({int max = 10}) async {
    try {
      return await _channel
              .invokeMethod<String>('exitReasons', {'max': max}) ??
          '';
    } catch (e) {
      return 'exitReasons unavailable: $e\n';
    }
  }

  /// Catch what Dart itself throws, so an error that does NOT kill the process
  /// still leaves a mark. Installed from `main()`.
  ///
  /// Both hooks are needed and they catch different things: `FlutterError`
  /// covers errors raised inside the framework's own build/layout/paint work,
  /// while `PlatformDispatcher.onError` catches everything that reaches the
  /// zone uncaught — including a failed Future nobody awaited. Neither one
  /// sees a native crash; that is what the exit-reason history is for.
  /// CHAINS, never replaces. main.dart already owns
  /// `PlatformDispatcher.instance.onError` — it returns true there on purpose,
  /// to keep the isolate alive after an unawaited failure — so that hook is
  /// left alone and records its own breadcrumb in place. Overwriting it here
  /// would have quietly undone that decision.
  static void installErrorHooks() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      CrashBreadcrumbs.addError(
        'flutter ${details.library ?? ""}',
        details.exception,
        details.stack,
      );
      previous?.call(details);
    };
  }

  /// How many folder grants are live.
  ///
  /// Worth a line in the report because "Local shows nothing" and "the grant
  /// went away" look identical from the outside, and a grant does go away —
  /// it belongs to the installed app, so a reinstall or a change of
  /// application id clears every one of them.
  static Future<String> _safSummary() async {
    try {
      final trees = await SafService.instance.grantedTrees();
      if (trees.isEmpty) {
        return 'none granted (restricted folders such as Android/data will '
            'appear empty until one is granted in Settings → List)';
      }
      return '${trees.length} granted:\n  ${trees.join("\n  ")}';
    } catch (e) {
      return 'could not be read: $e';
    }
  }

  /// Everything, as one block of text for the clipboard.
  static Future<String> report() async {
    final sb = _ReportBuilder();
    sb.line('===== INNOCENT DIAGNOSTICS =====');
    sb.line('app         : ${AppVersion.displayName} ${AppVersion.full}');
    sb.line('generated   : ${DateTime.now()}');
    sb.line('');
    sb.line('--- device ---');
    sb.line(await deviceInfo());
    sb.line('--- audio service ---');
    sb.line(AudioServiceStatus.summary);
    sb.line('');
    sb.line('--- restricted-folder (SAF) grants ---');
    sb.line(await _safSummary());
    sb.line('');
    sb.line('--- process exit history ---');
    sb.line(await exitReasons());
    sb.line('');
    sb.line('--- previous session, last actions before it ended ---');
    sb.line(CrashBreadcrumbs.previousSession.isEmpty
        ? '(nothing recorded — this may be the first run since installing)'
        : CrashBreadcrumbs.previousSession);
    sb.line('');
    sb.line('--- this session so far ---');
    sb.line(CrashBreadcrumbs.currentSession);
    sb.line('');
    sb.line('--- playback log (in memory) ---');
    sb.line(PlaybackLog.text);
    sb.line('===== END =====');
    return sb.toString();
  }
}

/// A three-line helper rather than repeated `buffer.writeln`, so the report
/// above reads as a list of sections. PRIVATE on purpose: a top-level type
/// with a name this generic is the latent ambiguous-import bug that
/// `tool/collision.py` exists to catch.
class _ReportBuilder {
  final StringBuffer _b = StringBuffer();
  void line(String s) => _b.writeln(s);
  @override
  String toString() => _b.toString();
}
