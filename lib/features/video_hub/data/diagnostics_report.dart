import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../../../core/app_version.dart';
import '../../../core/services/diagnostics/crash_breadcrumbs.dart';
import '../../../core/services/diagnostics/playback_log.dart';
import '../../../core/services/network/connection_kind.dart';
import 'api/api_client.dart';

/// What a viewer's phone sends when they tap "Report a problem".
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS EXISTS
/// ═══════════════════════════════════════════════════════════════════════
///
/// The device lab runs the app on an emulator over a network shaped like a
/// Myanmar line, and that found real problems — but a shaped network is not
/// the real one and an emulator has no real video decoder. Why a download
/// crawled on THIS line, why a film would not start on THIS phone, can only
/// be answered from the phone it happened on. The app already keeps that
/// record (PlaybackLog, persisted by CrashBreadcrumbs); this sends it, once,
/// when the viewer asks, to a table only the operator can read (migration
/// 037).
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT IS NOT SENT
/// ═══════════════════════════════════════════════════════════════════════
///
/// Links and anything shaped like a token or a key are cut out on the phone
/// ([redact]) — the trail is written to avoid them, and this is the second
/// lock. No file names from the phone's own storage, no location, no
/// contacts. The viewer sees this said in plain words before anything goes.
class DiagnosticsReport {
  DiagnosticsReport._();

  static const String _path = '/rest/v1/diagnostic_reports';

  /// The server caps the trail at 64 KB; this keeps well inside it, keeping
  /// the NEWEST lines — the problem is nearly always at the end.
  static const int maxTrail = 60000;

  // No 0/O or 1/I: the code is read aloud and typed back.
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// A short code the viewer can quote. Made here, because the phone cannot
  /// read its own row back (the table has no SELECT for anyone but the
  /// operator).
  static String newCode([Random? random]) {
    final r = random ?? Random.secure();
    return List<String>.generate(8, (_) => _alphabet[r.nextInt(_alphabet.length)])
        .join();
  }

  static final RegExp _url = RegExp(r'\b(?:https?|rtmp|rtsp|content|file)://\S+',
      caseSensitive: false);
  static final RegExp _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
  static final RegExp _longToken = RegExp(r'[A-Za-z0-9_\-+/=]{32,}');
  static final RegExp _storagePath = RegExp(r'/(?:storage|sdcard|data/user|data/data)/\S+');

  /// Everything shaped like something private, replaced by what it was.
  @visibleForTesting
  static String redact(String text) => text
      .replaceAll(_url, '<link>')
      .replaceAll(_email, '<email>')
      .replaceAll(_storagePath, '<path>')
      .replaceAll(_longToken, '<token>');

  /// The trail, newest kept when it is too long.
  @visibleForTesting
  static String buildTrail({
    required String playback,
    required String session,
    required String previous,
  }) {
    final parts = <String>[
      '== this session (breadcrumbs)',
      session.trim().isEmpty ? '(empty)' : session.trim(),
      '== playback and downloads (latest)',
      playback.trim().isEmpty ? '(empty)' : playback.trim(),
      if (previous.trim().isNotEmpty) ...<String>[
        '== previous session (it may have ended in a crash)',
        previous.trim(),
      ],
    ];
    final all = redact(parts.join('\n'));
    if (all.length <= maxTrail) return all;
    return '…(older lines cut)\n${all.substring(all.length - maxTrail)}';
  }

  static Future<Map<String, Object?>> _device() async {
    if (!Platform.isAndroid) return <String, Object?>{'os': Platform.operatingSystem};
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      return <String, Object?>{
        'maker': a.manufacturer,
        'model': a.model,
        'android': a.version.release,
        'sdk': a.version.sdkInt,
        'abis': a.supportedAbis.take(3).toList(),
        'ram_low': a.isLowRamDevice,
      };
    } catch (_) {
      return <String, Object?>{'os': 'android'};
    }
  }

  /// Sends a report and returns its code. Throws when it could not be sent.
  static Future<String> send(ApiClient api, {String? note}) async {
    final code = newCode();
    final conn = await ConnectionInfo.read(fresh: true);
    final trimmedNote = note?.trim();
    await api.postJson(
      _path,
      body: <String, Object?>{
        'code': code,
        'app_version': '${AppVersion.name} (${AppVersion.build})',
        'device': await _device(),
        'network': '${conn.transport}${conn.metered ? ', metered' : ''}',
        if (trimmedNote != null && trimmedNote.isNotEmpty)
          'note': redact(trimmedNote.length > 1000 ? trimmedNote.substring(0, 1000) : trimmedNote),
        'trail': buildTrail(
          playback: PlaybackLog.text,
          session: CrashBreadcrumbs.currentSession,
          previous: CrashBreadcrumbs.previousSession,
        ),
      },
      // Signed in: the row names the account (RLS allows only the caller).
      // Signed out: no bearer is attached and it goes as anonymous.
      extraHeaders: const <String, String>{'Prefer': 'return=minimal'},
    );
    PlaybackLog.add('diagnostics sent $code');
    return code;
  }
}
