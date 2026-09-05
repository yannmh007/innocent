import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of `ensureReady` — what the yt-dlp engine can actually do right now.
///
/// [ffmpeg] and [aria2c] are reported separately because the feature degrades
/// gracefully without them rather than failing: no ffmpeg means DASH
/// video-only streams cannot be muxed with audio (so only combined qualities
/// are offered, and MP3 conversion is hidden), and no aria2c only costs speed.
@immutable
class EngineStatus {
  const EngineStatus({
    required this.ok,
    this.version,
    this.error,
    this.ffmpeg = false,
    this.ffmpegError,
    this.aria2c = false,
    this.aria2cError,
    this.active = 0,
    this.nativeLibs = const <String>[],
    this.cookieHosts = const <String>[],
    this.jsRuntime = false,
    this.jsRuntimeError,
    this.lastWarning,
    this.deadClients = const <String>[],
  });

  final bool ok;
  final String? version;
  final String? error;
  final bool ffmpeg;
  final String? ffmpegError;
  final bool aria2c;
  final String? aria2cError;
  final int active;

  /// The native libraries actually packaged in the APK.
  ///
  /// Distinguishes "the merger wasn't built in" from "the merger is there and
  /// we failed to reach it" — two problems with completely different fixes,
  /// which look identical from the outside.
  final List<String> nativeLibs;

  /// Sites the cookie jar actually holds cookies for.
  ///
  /// Worth reporting because "cookies present" hid the half that mattered:
  /// WHICH site they belonged to. A jar full of YouTube cookies was being
  /// handed to TikTok, and the report said only "present".
  final List<String> cookieHosts;

  /// Whether yt-dlp was given a JavaScript runtime it can actually use.
  ///
  /// From engine 2025.11.12 onward this is not an optional extra: YouTube
  /// hands out a JS challenge, and an extractor that cannot run JavaScript
  /// gets no solvable URLs back. The failure mode is cruel, because it does
  /// not look like a missing dependency — it looks like YouTube refusing us,
  /// which sends you off hunting for sessions and tokens instead.
  final bool jsRuntime;

  /// Why there is no runtime, when there isn't one.
  final String? jsRuntimeError;

  /// The last thing yt-dlp said on stderr. Usually empty; priceless when not.
  final String? lastWarning;

  /// Player clients this engine has told us it does not recognise.
  ///
  /// YouTube's usable clients are renamed and retired every few months, so a
  /// list that was right when it shipped can quietly go bad. Showing which
  /// names the engine rejected turns "the fallback did nothing" into a fact
  /// somebody can read.
  final List<String> deadClients;

  /// True when the ffmpeg module shipped but never initialised.
  bool get ffmpegShippedButDead =>
      !ffmpeg && nativeLibs.any((String n) => n.contains('ffmpeg'));

  /// Placeholder used before the first `ensureReady` completes.
  static const EngineStatus unknown = EngineStatus(ok: false);

  factory EngineStatus.fromMap(Map<Object?, Object?> map) => EngineStatus(
        ok: map['ok'] == true,
        version: map['version'] as String?,
        error: map['error'] as String?,
        ffmpeg: map['ffmpeg'] == true,
        ffmpegError: map['ffmpegError'] as String?,
        aria2c: map['aria2c'] == true,
        aria2cError: map['aria2cError'] as String?,
        active: (map['active'] as num?)?.toInt() ?? 0,
        nativeLibs: (map['nativeLibs'] as List<Object?>?)
                ?.whereType<String>()
                .toList() ??
            const <String>[],
        cookieHosts: (map['cookieHosts'] as List<Object?>?)
                ?.whereType<String>()
                .toList() ??
            const <String>[],
        jsRuntime: map['jsRuntime'] == true,
        jsRuntimeError: map['jsRuntimeError'] as String?,
        lastWarning: map['lastWarning'] as String?,
        deadClients: ((map['deadClients'] as String?) ?? '')
            .split(',')
            .map((String e) => e.trim())
            .where((String e) => e.isNotEmpty)
            .toList(),
      );
}

/// Lifecycle of one download job, as reported by the native engine.
///
/// [paused] and [retrying] both come out of the same place natively — killing
/// the yt-dlp process — but they mean opposite things to the user, so they are
/// separate states rather than one "stopped".
enum DownloadPhase {
  queued,
  preparing,
  progress,
  retrying,
  paused,
  done,
  cancelled,
  error,
}

@immutable
/// A download asked for from inside the browser.
///
/// Carries only what the browser legitimately knows — the address, the format
/// somebody picked, and the title the engine reported. Everything else (where
/// to save, which cookies, the extras) stays with Dart, so there is one
/// answer to those questions rather than two that can drift apart.
@immutable
/// What the two resolvers said about one name.
///
/// The point of keeping both answers rather than only the verdict is that a
/// verdict cannot be argued with and two lists can. If this is ever wrong, the
/// evidence for why is right here in the report.
class HostCheck {
  const HostCheck(this.host, this.verdict, this.system, this.doh);
  final String host;

  /// `ok`, `dns`, `deeper` or `unknown` — see the native side for what each
  /// one is allowed to mean.
  final String verdict;
  final List<String> system;
  final List<String> doh;

  bool get blockedByDns => verdict == 'dns';
}

/// What this network does to the names the app needs.
class NetworkCheck {
  const NetworkCheck({
    required this.privateDns,
    required this.privateDnsHost,
    required this.hosts,
  });

  /// `on`, `off` or `unknown` — read from the LIVE connection, because the
  /// setting can say one thing while the network refuses it.
  final String privateDns;
  final String? privateDnsHost;
  final List<HostCheck> hosts;

  /// True when at least one name is being blocked at the resolver.
  ///
  /// THE QUESTION THE WHOLE CLASS EXISTS TO ANSWER. A resolver block is the
  /// one kind that Private DNS removes outright — which would let the VPN stay
  /// off, and then the sites that need it and the sites that refuse it can all
  /// work at the same time.
  bool get dnsBlockFound => hosts.any((HostCheck h) => h.blockedByDns);

  /// True when nothing could be compared, so nothing should be claimed.
  bool get inconclusive =>
      hosts.isEmpty || hosts.every((HostCheck h) => h.verdict == 'unknown');

  static NetworkCheck? tryFrom(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? rows = raw['hosts'];
    if (rows is! List<Object?>) return null;
    final List<HostCheck> parsed = <HostCheck>[];
    for (final Object? r in rows) {
      if (r is! Map<Object?, Object?>) continue;
      final Object? host = r['host'];
      final Object? verdict = r['verdict'];
      if (host is! String || verdict is! String) continue;
      parsed.add(HostCheck(
        host,
        verdict,
        (r['system'] as List<Object?>? ?? <Object?>[]).whereType<String>().toList(),
        (r['doh'] as List<Object?>? ?? <Object?>[]).whereType<String>().toList(),
      ));
    }
    return NetworkCheck(
      privateDns: raw['privateDns'] is String ? raw['privateDns'] as String : 'unknown',
      privateDnsHost:
          raw['privateDnsHost'] is String ? raw['privateDnsHost'] as String : null,
      hosts: parsed,
    );
  }
}

/// The browser asking for a page to be read on its behalf.
class BrowserProbeRequest {
  const BrowserProbeRequest(this.reqId, this.url);
  final int reqId;
  final String url;
}

class BrowserPick {
  const BrowserPick({
    required this.url,
    required this.selector,
    required this.title,
    required this.merge,
    this.rawFormats = 0,
    this.offered = 0,
    this.sourceUrl,
  });

  final String url;
  final String selector;
  final String title;

  /// True when the chosen format has no sound of its own and needs muxing.
  final bool merge;

  /// How many formats the engine returned, and how many were offered.
  ///
  /// A short quality list looks the same whether the site offered one or our
  /// own filter ate the rest. These two numbers separate those cases without
  /// anybody having to reproduce it.
  final int rawFormats;
  final int offered;

  /// The page the video was found on, for the history list's "View".
  final String? sourceUrl;

  /// Returns null for a malformed payload rather than throwing — one bad
  /// message must never take the stream down and with it every later pick.
  /// A diagnostic line rather than a pick, or null.
  ///
  /// The browser and the trail live on opposite sides of the channel, so a
  /// note is how the browser explains itself. Kept on the SAME channel as the
  /// picks because both come from the same screen and a third channel would be
  /// a third thing to keep alive.
  static String? noteFrom(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? note = raw['note'];
    return (note is String && note.trim().isNotEmpty) ? note.trim() : null;
  }

  /// A read request, or null. Same defensive shape as [tryFrom]: one
  /// malformed message must never take the stream down and with it every
  /// later pick.
  /// A job id the notification asked to be resumed, or null.
  static String? resumeRequestFrom(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? id = raw['resumeRequest'];
    if (id is! String || id.trim().isEmpty) return null;
    return id.trim();
  }

  static BrowserProbeRequest? probeRequestFrom(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? url = raw['probeRequest'];
    final Object? id = raw['reqId'];
    if (url is! String || url.trim().isEmpty) return null;
    if (id is! int || id <= 0) return null;
    return BrowserProbeRequest(id, url.trim());
  }

  static BrowserPick? tryFrom(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? url = raw['url'];
    final Object? selector = raw['selector'];
    if (url is! String || url.isEmpty) return null;
    if (selector is! String || selector.isEmpty) return null;
    return BrowserPick(
      url: url,
      selector: selector,
      title: (raw['title'] as String?) ?? '',
      merge: raw['merge'] == true,
      rawFormats: (raw['rawFormats'] as int?) ?? 0,
      offered: (raw['offered'] as int?) ?? 0,
      sourceUrl: (raw['sourceUrl'] as String?)?.trim().isNotEmpty == true
          ? (raw['sourceUrl'] as String).trim()
          : null,
    );
  }
}

class DownloadEvent {
  const DownloadEvent({
    required this.id,
    required this.phase,
    this.progress = 0,
    this.etaSeconds,
    this.line,
    this.path,
    this.title,
    this.error,
  });

  final String id;
  final DownloadPhase phase;
  final int progress;
  final int? etaSeconds;
  final String? line;
  final String? path;
  final String? title;
  final String? error;

  bool get isTerminal =>
      phase == DownloadPhase.done ||
      phase == DownloadPhase.cancelled ||
      phase == DownloadPhase.error;

  static DownloadPhase _phaseOf(String? raw) {
    switch (raw) {
      case 'queued':
        return DownloadPhase.queued;
      case 'preparing':
        return DownloadPhase.preparing;
      case 'progress':
        return DownloadPhase.progress;
      case 'retrying':
        return DownloadPhase.retrying;
      case 'paused':
        return DownloadPhase.paused;
      case 'done':
        return DownloadPhase.done;
      case 'cancelled':
        return DownloadPhase.cancelled;
      default:
        return DownloadPhase.error;
    }
  }

  /// Returns null for a malformed payload rather than throwing — a bad event
  /// must never take the stream (and with it every future download) down.
  static DownloadEvent? tryFrom(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return DownloadEvent(
      id: id,
      phase: _phaseOf(raw['phase'] as String?),
      progress: ((raw['progress'] as num?)?.toInt() ?? 0).clamp(0, 100),
      etaSeconds: (raw['eta'] as num?)?.toInt(),
      line: raw['line'] as String?,
      path: raw['path'] as String?,
      title: raw['title'] as String?,
      error: raw['error'] as String?,
    );
  }
}

/// Outcome of a yt-dlp self-update.
@immutable
class EngineUpdateResult {
  const EngineUpdateResult({
    required this.ok,
    this.status,
    this.version,
    this.before,
    this.error,
    this.detail,
    this.deferred = false,
  });

  final bool ok;

  /// The library's own word for what happened (e.g. already up to date).
  final String? status;
  final String? version;

  /// Engine version before the attempt, so the UI can prove it moved.
  final String? before;
  final String? error;

  /// Which reflective step ran or broke. Shown on failure only — it exists so
  /// a screenshot of the failure is enough to diagnose it.
  final String? detail;

  /// True when the engine stepped aside because a link was being read. Not a
  /// failure — it simply hasn't happened yet.
  final bool deferred;

  /// True when the version string actually changed.
  bool get changed =>
      ok && version != null && before != null && version != before;

  /// True when the library reported the binary was already current.
  bool get alreadyCurrent =>
      ok && (status ?? '').toLowerCase().contains('already');
}

/// What the phone can do right now.
@immutable
class DeviceStatus {
  const DeviceStatus({
    this.online = false,
    this.unmetered = false,
    this.freeBytes = -1,
    this.notificationsEnabled = true,
    this.vpn = false,
    this.privateDns = 'unknown',
    this.dnsVerdict,
    this.bypassRunning = false,
  });

  final bool online;

  /// A connection the user is not paying by the megabyte for.
  ///
  /// The question is metered-or-not, NOT Wi-Fi-or-not: a phone hotspot reports
  /// itself as Wi-Fi while costing money, and plenty of mobile plans are
  /// unlimited. Android answers the useful question directly, so we ask that
  /// one.
  final bool unmetered;

  /// Free space on the save volume, or -1 when it couldn't be measured.
  final int freeBytes;

  /// `on`, `off` or `unknown` — whether encrypted DNS is in force RIGHT NOW,
  /// read from the live connection rather than from the setting.
  final String privateDns;

  /// A one-line summary of the last resolver measurement, or null if none has
  /// been taken.
  ///
  /// CARRIED ON THE DEVICE because that is what it describes, and because the
  /// report is assembled by a class that never runs a check itself. The first
  /// version kept it on whichever half of the app happened to measure — so the
  /// browser could diagnose a poisoned name while the report still said
  /// `dns unknown`, which is the report failing at its one job.
  final String? dnsVerdict;

  /// True when the app's own resolver is carrying this phone's connections.
  final bool bypassRunning;

  /// A short name for "which network is this", for comparing across runs.
  ///
  /// Deliberately COARSE — just whether a VPN is carrying the connection. The
  /// exact address would be better and is not available to an app without
  /// asking somebody else for it, which is a privacy cost this does not need
  /// to pay: the only distinction that has ever mattered here is the one the
  /// person is actually toggling.
  String get networkKey => vpn ? 'vpn' : 'direct';

  /// True when a VPN is carrying this connection.
  ///
  /// Worth reporting because it changes what a failure MEANS. A blocked site
  /// needs a VPN to be reachable at all; YouTube and TikTok refuse a shared
  /// exit address precisely because a bot wall is looking for one. So the same
  /// phone, on the same Wi-Fi, has two different sets of working sites
  /// depending on this one bit — and a report that omitted it left every
  /// "YouTube does not work" ambiguous between two opposite causes.
  final bool vpn;

  /// False when the system will silently drop our notifications.
  ///
  /// Worth knowing because a download running with notifications blocked is
  /// indistinguishable, from the outside, from a download that never started:
  /// the foreground service is alive and completely invisible.
  final bool notificationsEnabled;

  static const DeviceStatus unknown = DeviceStatus();
}

/// Thrown for engine-side failures so callers can show the real reason.
class DownloaderException implements Exception {
  DownloaderException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Single point of contact with [DownloadEngine.kt].
///
/// The event stream is created once and shared: `receiveBroadcastStream` opens
/// the native side on first listen, and re-subscribing to a fresh instance per
/// listener would tear that down for everyone else.
class DownloaderEngineService {
  DownloaderEngineService._();

  static final DownloaderEngineService instance = DownloaderEngineService._();

  static const MethodChannel _channel = MethodChannel('mx_clone/downloader');
  static const EventChannel _events = EventChannel('mx_clone/downloader/events');

  /// Choices made in the in-app browser.
  ///
  /// A channel of its own rather than a new phase on [_events]: that stream is
  /// a progress contract, and DownloadEvent maps any phase it does not know to
  /// `error`. A pick sent down it would arrive looking like a download that
  /// had already failed.
  static const EventChannel _browserEvents =
      EventChannel('mx_clone/downloader/browser');

  Stream<BrowserPick>? _browserStream;

  /// Where a browser diagnostic line goes. Wired to the trail by the screen,
  /// for the same layering reason StreamProxy.onEvent is.
  static void Function(String message)? onBrowserNote;

  /// The in-app browser asking to have a page read for it.
  ///
  /// Wired by the download queue rather than by a screen, for exactly the
  /// reason the picks are: somebody browsing has the downloads screen in the
  /// background, and possibly never built at all.
  static void Function(int reqId, String url)? onBrowserProbeRequest;

  /// The notification's Resume button, asking for a job to start again.
  ///
  /// Wired by the download queue, like the probe requests and for the same
  /// reason: somebody pressing Resume in the shade may not have the downloads
  /// screen built at all.
  static void Function(String jobId)? onResumeRequest;

  /// Hands rows back to a waiting in-app browser.
  ///
  /// The browser is blocked on a latch behind this call, so an EMPTY list is a
  /// meaningful and important answer — it releases it at once to fall back on
  /// its own reader, instead of leaving somebody watching a spinner until the
  /// timeout expires.
  Future<void> sendBrowserFormats(
    int reqId,
    List<Map<String, Object?>> rows,
  ) async {
    try {
      await _channel.invokeMethod<bool>('browserFormats', <String, Object?>{
        'reqId': reqId,
        'rows': rows,
      });
    } catch (_) {
      // The browser times out and reads for itself. Worth no more than this.
    }
  }

  /// Quality choices made over a page in the in-app browser.
  Stream<BrowserPick> get browserPicks {
    _browserStream ??= _browserEvents
        .receiveBroadcastStream()
        .map((Object? raw) {
          // Notes are logged here and filtered out; picks continue on. One
          // channel, two kinds of message, and the trail gets both.
          final String? note = BrowserPick.noteFrom(raw);
          if (note != null) onBrowserNote?.call(note);
          // A THIRD KIND OF MESSAGE ON THE SAME CHANNEL, for the same reason
          // the notes are here: both come from the one screen, and a separate
          // channel would be a separate thing to keep alive and to get wrong.
          final BrowserProbeRequest? ask = BrowserPick.probeRequestFrom(raw);
          if (ask != null) onBrowserProbeRequest?.call(ask.reqId, ask.url);
          // A FOURTH SHAPE ON THE SAME CHANNEL, and deliberately not on the
          // download event stream: that one turns any phase it does not
          // recognise into `error`, so a resume request sent there would mark
          // the very job being revived as failed.
          final String? resumeId = BrowserPick.resumeRequestFrom(raw);
          if (resumeId != null) onResumeRequest?.call(resumeId);
          return BrowserPick.tryFrom(raw);
        })
        .where((BrowserPick? p) => p != null)
        .cast<BrowserPick>();
    return _browserStream!;
  }

  Stream<DownloadEvent>? _stream;

  Stream<DownloadEvent> get events {
    _stream ??= _events
        .receiveBroadcastStream()
        .map(DownloadEvent.tryFrom)
        .where((DownloadEvent? e) => e != null)
        .cast<DownloadEvent>();
    return _stream!;
  }

  /// Initializes the engine if needed (first call unpacks the bundled Python
  /// runtime, which can take a few seconds) and reports what is available.
  /// Never throws: an unavailable engine is a status, not an exception, so the
  /// screen can render a diagnostic instead of an error boundary.
  Future<EngineStatus> ensureReady() async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('ensureReady');
      if (raw is Map<Object?, Object?>) return EngineStatus.fromMap(raw);
      return const EngineStatus(ok: false, error: 'bad response');
    } on PlatformException catch (e) {
      return EngineStatus(ok: false, error: e.message ?? e.code);
    } on MissingPluginException {
      return const EngineStatus(ok: false, error: 'engine not built in');
    } catch (e) {
      return EngineStatus(ok: false, error: '$e');
    }
  }

  /// Raw `yt-dlp -J` JSON for [url]. Parsing lives in `probe_parser.dart`.
  ///
  /// [cookies] is a Netscape cookies.txt path (optional) and [clients] a
  /// YouTube player-client list used only if the first attempt hits the bot
  /// wall — see DownloadEngine.kt for why the retry is second, not first.
  /// How long a single read is allowed to take before it is called off.
  ///
  /// There must be an upper bound. Without one, anything that stalls on the
  /// native side leaves a spinner turning with no explanation and no way out —
  /// which is exactly what a queued engine update used to cause. A timeout
  /// turns an unbounded wait into an error the user can act on.
  //
  // RAISED from 45s in v1.5.0. Solving YouTube's JavaScript challenge on a
  // phone is real work — QuickJS is an interpreter, not a browser engine, and
  // the first solve after an engine update has nothing cached to lean on. 45
  // seconds was killing reads that were seconds away from succeeding, and a
  // killed read looks exactly like a site that refused us. The elapsed counter
  // on the card means a long wait is visible rather than mysterious, and one
  // slow first read beats a fast failure every time.
  static const Duration probeTimeout = Duration(seconds: 75);

  Future<String> probe(
    String url, {
    String? cookies,
    String? clients,
    bool forceClients = false,
    bool flatPlaylist = false,
  }) async {
    try {
      final String? out = await _channel
          .invokeMethod<String>('probe', <String, Object?>{
        'url': url,
        'cookies': cookies,
        'clients': clients,
        'forceClients': forceClients,
        'flatPlaylist': flatPlaylist,
      }).timeout(
        probeTimeout,
        onTimeout: () {
          // Stop the process too, or it keeps running with nobody waiting.
          cancel('innocent-probe');
          throw DownloaderException('TIMEOUT', 'timed out reading the link');
        },
      );
      if (out == null || out.isEmpty) {
        throw DownloaderException('PROBE', 'empty response');
      }
      return out;
    } on PlatformException catch (e) {
      throw DownloaderException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw DownloaderException('ENGINE', 'engine not built in');
    }
  }

  /// Direct playable URL for [selector]. The selector must resolve to ONE
  /// stream — see [MediaFormat.streamSelector].
  /// The host's cookies as a ready-made `Cookie:` header value, or null.
  ///
  /// The engine gets `--cookies` on every call, so a DOWNLOAD always carries
  /// the session the address was extracted with. The player fetches through
  /// our own loopback server, which had no idea the cookie jar existed — and
  /// a CDN that checks the session answers a request without one with 403.
  /// Never throws: a stream without cookies is worth attempting, a stream
  /// that never starts because looking them up failed is not.
  /// Opens [url] in Innocent's own browser.
  ///
  /// Returns true when the screen opened. The chosen link comes back the same
  /// way a shared link does, so nothing here needs to wait for a result.
  Future<bool> browse(
    String url, {
    String title = '',
    required String labelDownload,
    required String labelHint,
    required String labelWorking,
    required String labelPick,
    required String labelStarted,
    required String labelNoSound,
    required String labelStreams,
    required String labelUnreadable,
    required String labelRetry,
    required String labelSendScreen,
    required String clients,
    required String labelBlocked,
    required String labelVpnHint,
    required String labelDnsHint,
    required String labelOpenSettings,
    required String labelMore,
    required String labelDnsFound,
    required String labelDeeper,
    required String labelBypass,
    required String labelBypassHint,
    required String labelVpnGone,
    required String labelYtWall,
    required String labelYtEmbed,
    required String labelYtSignIn,
  }) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'browse',
        <String, Object?>{
          'url': url,
          'title': title,
          'labelDownload': labelDownload,
          'labelHint': labelHint,
          'labelWorking': labelWorking,
          'labelPick': labelPick,
          'labelStarted': labelStarted,
          'labelNoSound': labelNoSound,
          'labelStreams': labelStreams,
          'labelUnreadable': labelUnreadable,
          'labelRetry': labelRetry,
          'labelSendScreen': labelSendScreen,
          // NOT A LABEL, carried alongside them because it has the same
          // lifetime. Without it the browser's own read asks YouTube as
          // whatever yt-dlp defaults to -- which needs a PO token, which is
          // the bot wall. See probeForBrowser.
          'clients': clients,
          'labelBlocked': labelBlocked,
          'labelVpnHint': labelVpnHint,
          'labelDnsHint': labelDnsHint,
          'labelOpenSettings': labelOpenSettings,
          'labelMore': labelMore,
          'labelDnsFound': labelDnsFound,
          'labelDeeper': labelDeeper,
          'labelBypass': labelBypass,
          'labelBypassHint': labelBypassHint,
          'labelVpnGone': labelVpnGone,
          'labelYtWall': labelYtWall,
          'labelYtEmbed': labelYtEmbed,
          'labelYtSignIn': labelYtSignIn,
        },
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> cookieHeader(String url, {String? cookies}) async {
    try {
      return await _channel
          .invokeMethod<String>('cookieHeader', <String, Object?>{
        'url': url,
        'cookies': cookies,
      });
    } catch (_) {
      return null;
    }
  }

  Future<String> resolveStream(
    String url,
    String selector, {
    String? cookies,
    String? clients,
  }) async {
    try {
      final String? out = await _channel
          .invokeMethod<String>('resolveStream', <String, Object?>{
        'url': url,
        'selector': selector,
        'cookies': cookies,
        'clients': clients,
      });
      if (out == null || out.isEmpty) {
        throw DownloaderException('RESOLVE', 'no playable url');
      }
      return out;
    } on PlatformException catch (e) {
      throw DownloaderException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw DownloaderException('ENGINE', 'engine not built in');
    }
  }

  /// Enqueues a download. Returns as soon as the job is accepted; progress
  /// arrives on [events]. Downloads run one at a time on the native side.
  Future<void> startDownload({
    required String id,
    required String url,
    required String selector,
    required String dir,
    required String title,
    bool audioOnly = false,
    bool toMp3 = false,
    bool merge = false,
    String? cookies,
    String? clients,
    String? subLangs,
    bool embedThumbnail = false,
    bool embedMetadata = false,
    String? rateLimit,
  }) async {
    try {
      await _channel.invokeMethod<Object?>('startDownload', <String, Object?>{
        'id': id,
        'url': url,
        'selector': selector,
        'dir': dir,
        'title': title,
        'audioOnly': audioOnly,
        'toMp3': toMp3,
        'merge': merge,
        'cookies': cookies,
        'clients': clients,
        'subLangs': subLangs,
        'embedThumbnail': embedThumbnail,
        'embedMetadata': embedMetadata,
        'rateLimit': rateLimit,
      });
    } on PlatformException catch (e) {
      throw DownloaderException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw DownloaderException('ENGINE', 'engine not built in');
    }
  }

  /// Replaces the bundled yt-dlp binary with the current stable release.
  ///
  /// The one real answer to YouTube's bot wall: the check moves, the fix ships
  /// in yt-dlp within days, and the bundled copy is frozen at the library's
  /// release date. Never throws — a failed update is a message, not a crash.
  Future<EngineUpdateResult> updateEngine() async {
    try {
      final Object? raw =
          await _channel.invokeMethod<Object?>('updateEngine');
      if (raw is Map<Object?, Object?>) {
        return EngineUpdateResult(
          ok: raw['ok'] == true,
          status: raw['status'] as String?,
          version: raw['version'] as String?,
          before: raw['before'] as String?,
          error: raw['error'] as String?,
          detail: raw['detail'] as String?,
          deferred: raw['deferred'] == true,
        );
      }
      return const EngineUpdateResult(ok: false, error: 'bad response');
    } catch (e) {
      return EngineUpdateResult(ok: false, error: '$e');
    }
  }

  /// Saves a set of images as one job.
  ///
  /// [urlGroups] is one candidate-mirror list per picture; the engine walks
  /// each list until something serves an actual image.
  Future<void> downloadPhotos({
    required String id,
    required List<List<String>> urlGroups,
    required String dir,
    required String title,
  }) async {
    try {
      await _channel.invokeMethod<Object?>('downloadPhotos', <String, Object?>{
        'id': id,
        'urls': urlGroups,
        'dir': dir,
        'title': title,
      });
    } on PlatformException catch (e) {
      throw DownloaderException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw DownloaderException('ENGINE', 'engine not built in');
    }
  }

  /// Stops the running process but keeps the partial file, so resuming
  /// continues instead of starting over.
  Future<void> pause(String id) async {
    try {
      await _channel.invokeMethod<Object?>('pause', <String, Object?>{'id': id});
    } catch (_) {
      // Pausing something already gone is not worth surfacing.
    }
  }

  /// Restarts a paused job from the engine's own record of it. Throws when the
  /// engine no longer has that record — after the app process was killed, for
  /// instance — so the caller can fall back to [startDownload] with its own
  /// copy of the spec.
  Future<void> resume(String id) async {
    try {
      await _channel.invokeMethod<Object?>('resume', <String, Object?>{'id': id});
    } on PlatformException catch (e) {
      throw DownloaderException(e.code, e.message ?? e.code);
    } on MissingPluginException {
      throw DownloaderException('ENGINE', 'engine not built in');
    }
  }

  Future<void> cancel(String id) async {
    try {
      await _channel.invokeMethod<Object?>('cancel', <String, Object?>{
        'id': id,
      });
    } catch (_) {
      // Cancelling something already gone is not an error worth surfacing.
    }
  }

  /// Opens the in-app sign-in screen for [url].
  ///
  /// [cookieUrls] are every origin worth harvesting when the session ends —
  /// signing into Google leaves state on accounts.google.com as well as on
  /// youtube.com, and reading only the page you landed on would miss half of
  /// what makes the session work.
  /// [autoClose] runs the no-login path: the page loads, the anonymous guest
  /// cookies every first-time visitor receives are captured, and the screen
  /// closes itself. Nothing is typed and no account is involved.
  Future<bool> signIn({
    required String url,
    required String label,
    required List<String> cookieUrls,
    bool autoClose = false,
  }) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'signIn',
        <String, Object?>{
          'url': url,
          'label': label,
          'cookieUrls': cookieUrls,
          'autoClose': autoClose,
        },
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Gets an anonymous session from [url] with nothing on screen.
  ///
  /// No account, no window, no tap. Returns true when cookies were captured.
  Future<bool> guestSession({
    required String url,
    required List<String> cookieUrls,
  }) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'guestSession',
        <String, Object?>{'url': url, 'cookieUrls': cookieUrls},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Path of the cookie jar the sign-in screen wrote, or null if there is
  /// none yet.
  Future<String?> cookieJar() async {
    try {
      return await _channel.invokeMethod<String>('cookieJar');
    } catch (_) {
      return null;
    }
  }

  /// Forgets every saved session.
  Future<void> clearCookieJar() async {
    try {
      await _channel.invokeMethod<Object?>('clearCookieJar');
    } catch (_) {}
  }

  /// Connection type and free space on the volume holding [dir].
  /// Asks both resolvers about these names and reports what differs.
  ///
  /// Seconds, not milliseconds — a DNS lookup and an HTTPS round trip per
  /// host — so never on a path somebody is waiting on without being told.
  /// Opens a system settings screen by action name.
  Future<bool> openSettings(String action) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openSettings',
            <String, Object?>{'action': action},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<NetworkCheck?> networkCheck(List<String> hosts) async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>(
        'networkCheck',
        <String, Object?>{'hosts': hosts},
      );
      // The device keeps the authoritative copy — see DeviceStatus.dnsVerdict.
      // What comes back here is for whoever asked, and nothing else.
      return NetworkCheck.tryFrom(raw);
    } catch (_) {
      return null;
    }
  }

  Future<DeviceStatus> deviceStatus(String dir) async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>(
        'deviceStatus',
        <String, Object?>{'dir': dir},
      );
      if (raw is! Map) return DeviceStatus.unknown;
      return DeviceStatus(
        online: raw['online'] == true,
        unmetered: raw['unmetered'] == true,
        freeBytes: (raw['freeBytes'] as num?)?.toInt() ?? -1,
        notificationsEnabled: raw['notifications'] != false,
        vpn: raw['vpn'] == true,
        privateDns:
            raw['privateDns'] is String ? raw['privateDns'] as String : 'unknown',
        dnsVerdict: raw['dnsVerdict'] is String && (raw['dnsVerdict'] as String).isNotEmpty
            ? raw['dnsVerdict'] as String
            : null,
        bypassRunning: raw['bypassRunning'] == true,
      );
    } catch (_) {
      return DeviceStatus.unknown;
    }
  }

  /// Deletes a saved file and removes it from the media index.
  Future<bool> deleteFile(String path) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'deleteFile',
        <String, Object?>{'path': path},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Registers the weekly background update. Idempotent.
  Future<bool> scheduleUpdates() async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>('scheduleUpdates');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's notification settings.
  Future<bool> openNotificationSettings() async {
    try {
      final bool? ok =
          await _channel.invokeMethod<bool>('openNotificationSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens [url] in whatever browser the user has. Returns false if nothing
  /// could handle it.
  Future<bool> openExternal(String url) async {
    try {
      final bool? ok = await _channel
          .invokeMethod<bool>('openExternal', <String, Object?>{'url': url});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
