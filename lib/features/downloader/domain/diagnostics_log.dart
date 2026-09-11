import 'package:flutter/foundation.dart';

/// One thing that happened, kept so it can be reported.
@immutable
class DiagnosticEvent {
  const DiagnosticEvent({
    required this.at,
    required this.stage,
    required this.message,
    this.host,
    this.bad = false,
  });

  final DateTime at;

  /// 'tap', 'read', 'stream', 'player', 'download', 'engine', 'session' …
  final String stage;
  final String message;

  /// Host of the link involved, never the full URL — see [redact].
  final String? host;

  /// Whether this entry is a fault rather than a step.
  ///
  /// Both live in ONE list. Keeping failures in a separate record meant the
  /// report could describe an outcome without the sequence that produced it,
  /// and a sequence is usually the whole answer — "tapped Stream, check
  /// returned 206, player opened, player said X" is a diagnosis, while "X"
  /// on its own is a riddle.
  final bool bad;
}

/// A rolling record of recent failures.
///
/// This exists because of how every problem in this feature has actually been
/// diagnosed: a screenshot arrives, and the answer has to be guessed from one
/// truncated error line. Half the questions that then need asking — which
/// engine version, is the muxer alive, which player list is in use, did the
/// config ever load — are things the app already knows and could simply have
/// said. One paste replaces a round trip.
class DiagnosticsLog {
  DiagnosticsLog._();

  static final DiagnosticsLog instance = DiagnosticsLog._();

  /// Long enough to hold a whole session of ordinary use.
  ///
  /// Was 12, which held about one failed read. A person testing a build taps
  /// through five or six links before copying the report, and the interesting
  /// part is almost always something that happened several steps before the
  /// thing that finally broke.
  static const int _max = 80;
  final List<DiagnosticEvent> _events = <DiagnosticEvent>[];

  /// When this session began, so every line can be stamped relative to it.
  final DateTime _startedAt = DateTime.now();

  List<DiagnosticEvent> get events => List<DiagnosticEvent>.unmodifiable(_events);

  /// The read happening right now, if any, and when it started.
  ///
  /// Reports are copied most often at the exact moment something is stuck,
  /// and until now that moment produced `no failures recorded` — the log only
  /// ever heard about a read once it had ENDED. A read that never ends is
  /// precisely the one worth seeing.
  String? _inFlightHost;
  DateTime? _inFlightSince;

  void readStarted(String url) {
    try {
      _inFlightHost = _hostOf(url);
      _inFlightSince = DateTime.now();
    } catch (_) {
      _inFlightHost = null;
      _inFlightSince = DateTime.now();
    }
  }

  void readFinished() {
    _inFlightHost = null;
    _inFlightSince = null;
  }

  /// Records a FAULT. Unchanged signature — every existing caller still means
  /// what it always meant.
  void add(String stage, String message, {String? url}) =>
      _write(stage, message, url: url, bad: true);

  /// Records a STEP: something the person did, or something the app did next.
  ///
  /// Deliberately as cheap to call as a comment, because an instrument nobody
  /// bothers to reach for is not an instrument. If in doubt, note it — a line
  /// too many costs a line of scrolling, and a line too few has now cost this
  /// project three round trips.
  void note(String stage, String message, {String? url}) =>
      _write(stage, message, url: url, bad: false);

  void _write(String stage, String message, {String? url, required bool bad}) {
    // AN INSTRUMENT MUST NOT BE ABLE TO BREAK WHAT IT MEASURES.
    //
    // This is the same rule the stream check was made to obey after it held
    // the Play button shut, and it is not a precaution here — it is a
    // post-mortem. A throw inside redact() escaped this method, escaped the
    // read that called it, and left every link spinning forever with nothing
    // written down anywhere, because the thing that writes down what went
    // wrong was what went wrong.
    //
    // Recording a fault must be the safest operation in the app. If it cannot
    // be done, the correct outcome is one missing line — never a dead read.
    try {
      if (message.trim().isEmpty) return;
      _events.add(DiagnosticEvent(
        at: DateTime.now(),
        stage: stage,
        message: redact(message),
        host: _hostOf(url),
        bad: bad,
      ));
      while (_events.length > _max) {
        _events.removeAt(0);
      }
    } catch (_) {
      // Deliberately silent: there is nowhere left to report a failure of the
      // reporting system, and a second throw here would defeat the point.
    }
  }

  /// `+m:ss` since the session started.
  String _since(DateTime t) {
    final Duration d = t.difference(_startedAt);
    final int m = d.inMinutes;
    final int sec = d.inSeconds - m * 60;
    return '+$m:${sec.toString().padLeft(2, '0')}';
  }

  void clear() => _events.clear();

  /// Puts back the order of lines collected from the end.
  static String _reverseLines(String v) => v.split('\n').reversed.join('\n');

  static String? _hostOf(String? url) {
    if (url == null) return null;
    final Uri? uri = Uri.tryParse(url);
    final String? host = uri?.host;
    return (host == null || host.isEmpty) ? null : host;
  }

  /// Strips anything that shouldn't leave the phone.
  ///
  /// A diagnostic is written to be pasted into a chat, which means it may be
  /// read by someone other than its owner. Full media URLs carry signed
  /// tokens, and the site someone was visiting is their business — so URLs are
  /// reduced to a host, and anything resembling a token or cookie is dropped
  /// outright. Being useful and being nosy are not the same thing.
  static String redact(String raw) {
    String text = raw;
    text = text.replaceAllMapped(
      RegExp(r'https?://([^\s/]+)[^\s]*'),
      (Match m) => '<${m.group(1)}>',
    );
    // TWO FAULTS LIVED IN THESE THREE LINES, AND BOTH WERE SILENT.
    //
    // 1. `(?i)` is not a thing in Dart. Dart's regular expressions follow
    //    JavaScript's, which has no inline modifiers, so that is read as a
    //    group beginning `?i` and the CONSTRUCTOR throws. Every call to this
    //    function has thrown since the day it was written, which is why every
    //    report this project has ever produced said "no failures recorded" —
    //    a line we read as good news four separate times while the log was
    //    incapable of holding anything. Case-insensitivity is a named
    //    argument here, not a prefix.
    //
    // 2. `replaceAll` does not expand \$1. Only `replaceAllMapped` does, so
    //    even a valid pattern would have written the literal characters
    //    `\$1=<redacted>` into the report.
    text = text.replaceAllMapped(
      RegExp(
        r'(cookie|token|authorization|sid|password)\s*[=:]\s*\S+',
        caseSensitive: false,
      ),
      (Match m) => '${m.group(1)}=<redacted>',
    );
    // KEEP THE END, NOT THE BEGINNING.
    //
    // A tool prints what it is doing first and what went wrong last. Cutting
    // at 300 characters from the front therefore keeps the chatter and throws
    // away the answer — the device trail showed exactly that: three lines of
    // ffmpeg opening a stream, then an ellipsis where the actual failure was.
    // Unreadable, and worse than a shorter message, because it looks like a
    // report while telling you nothing.
    //
    // Whole lines from the end, so the last thing said survives intact.
    if (text.length > 300) {
      final List<String> lines =
          text.split('\n').where((String l) => l.trim().isNotEmpty).toList();
      final StringBuffer tail = StringBuffer();
      for (int i = lines.length - 1; i >= 0; i--) {
        if (tail.length + lines[i].length > 300) break;
        tail.write(tail.isEmpty ? lines[i] : '\n${lines[i]}');
      }
      // A single line longer than the budget still has to be cut somewhere;
      // the end is still the informative half.
      text = tail.isEmpty
          ? '…${text.substring(text.length - 300)}'
          : '…\n${_reverseLines(tail.toString())}';
    }
    return text.trim();
  }

  /// The report itself.
  ///
  /// Deliberately plain text with short lines: it is going to be pasted into a
  /// chat window and read by a human, not machine-parsed.
  String build({
    required String appVersion,
    required String engineVersion,
    required bool ffmpeg,
    required bool aria2c,
    required List<String> nativeLibs,
    required String playerClients,
    required bool clientsCustom,
    required bool hasCookies,
    required List<String> cookieHosts,
    required int configVersion,
    required String configSource,
    required DateTime? configFetchedAt,
    required String saveDir,
    required int freeBytes,
    required bool unmetered,
    required bool vpn,
    required String privateDns,
    required bool bypassRunning,
    required String? netVerdict,
    required bool notificationsEnabled,
    required String lastEngineCheck,
    required bool jsRuntime,
    required String? jsRuntimeError,
    required String? lastWarning,
    required List<String> deadClients,
  }) {
    final StringBuffer out = StringBuffer();
    out.writeln('Innocent downloader diagnostics');
    out.writeln('app        $appVersion');
    out.writeln('engine     $engineVersion');
    out.writeln('ffmpeg     ${ffmpeg ? 'ok' : 'OFF'}   aria2c ${aria2c ? 'ok' : 'OFF'}');
    // Printed on its own line, and printed even when it is fine, because for
    // months this report said everything was healthy while the one thing
    // YouTube actually requires was absent and unmentioned.
    out.writeln(
      'js engine  ${jsRuntime ? 'ok (quickjs)' : 'MISSING'}'
      '${jsRuntimeError == null ? '' : '  — $jsRuntimeError'}',
    );
    if (!ffmpeg || !aria2c) {
      out.writeln('libs       ${nativeLibs.join(', ')}');
    }
    out.writeln('clients    $playerClients${clientsCustom ? '  (custom)' : ''}');
    out.writeln(
      'cookies    ${hasCookies ? 'present' : 'none'}'
      '${cookieHosts.isEmpty ? '' : '  (${cookieHosts.join(', ')})'}',
    );
    out.writeln(
      'config     ${configSource.isEmpty ? 'not set' : 'v$configVersion'}'
      '${configFetchedAt == null ? '' : '  ${_short(configFetchedAt)}'}',
    );
    out.writeln('storage    ${_mb(freeBytes)} free  ·  $saveDir');
    // THE VPN BIT SITS ON THE NETWORK LINE, where somebody reading the report
    // is already looking. It changes what a failure means more than anything
    // else on this page: a site the router blocks needs a VPN to be reachable
    // at all, and YouTube refuses a shared exit address for exactly the reason
    // a bot wall exists. Same phone, same Wi-Fi, two different sets of working
    // sites depending on this one word.
    out.writeln(
      'network    ${unmetered ? 'unmetered' : 'metered'}'
      '${vpn ? '  ·  VPN ON' : ''}',
    );
    // THE RESOLVER LINE. On a connection where sites are blocked by name, this
    // single word decides which of two opposite remedies applies — and it is
    // the one thing nobody thinks to mention when describing a problem.
    out.writeln(
      'dns        ${privateDns == 'on' ? 'private DNS ON' : privateDns == 'off' ? 'system resolver' : 'unknown'}'
      '${netVerdict != null ? '  ·  $netVerdict' : ''}'
      '${bypassRunning ? '  ·  app resolver ON' : ''}',
    );
    out.writeln('notifs     ${notificationsEnabled ? 'allowed' : 'BLOCKED'}');
    out.writeln('engine chk $lastEngineCheck');

    if (deadClients.isNotEmpty) {
      out.writeln('rejected   ${deadClients.join(', ')} (engine does not know these)');
    }

    if (lastWarning != null && lastWarning.trim().isNotEmpty) {
      // yt-dlp's own words, verbatim. It names causes we would otherwise have
      // to infer, and inferring is what cost this feature three releases.
      out.writeln('engine says:');
      for (final String line in lastWarning.trim().split('\n')) {
        if (line.trim().isEmpty) continue;
        out.writeln('  ${line.trim()}');
      }
    }

    final DateTime? since = _inFlightSince;
    // Five minutes is far longer than any read is allowed to take, so a marker
    // older than that is a leak rather than a fact. Better to say nothing than
    // to tell somebody a read is running when it is not — this report only has
    // authority for as long as everything on it is true.
    if (since != null &&
        DateTime.now().difference(since) < const Duration(minutes: 5)) {
      out.writeln(
        'IN FLIGHT  reading ${_inFlightHost ?? 'link'} — '
        '${DateTime.now().difference(since).inSeconds}s so far',
      );
    }

    if (_events.isEmpty) {
      out.writeln('activity   nothing recorded yet');
    } else {
      final int faults = _events.where((DiagnosticEvent e) => e.bad).length;
      out.writeln(
        'activity   ${_events.length} step${_events.length == 1 ? '' : 's'}'
        '${faults == 0 ? ', no faults' : ', $faults marked !'}'
        '  (oldest first)',
      );
      for (final DiagnosticEvent e in _events) {
        out.writeln(
          '  ${e.bad ? '!' : ' '} ${_since(e.at)}  ${e.stage.padRight(8)}'
          '${e.host == null ? '' : ' @${e.host}'}  ${e.message}',
        );
      }
    }
    return out.toString();
  }

  static String _short(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  static String _mb(int bytes) {
    if (bytes <= 0) return 'unknown';
    final double gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}
