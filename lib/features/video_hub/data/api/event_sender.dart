import 'dart:async';
import 'dart:math';
// `PlatformDispatcher` for the locale, imported prefixed rather than through
// flutter/foundation: what foundation re-exports from dart:ui is a short
// allow-list that has changed between versions, and an unprefixed import
// would also pull in dart:ui's own `Locale` alongside the framework's.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../../core/app_version.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// The one thing in this app whose value is entirely in the future.
///
/// WHY IT EXISTS AT ALL, WITH NOTHING READING IT YET. A ranking formula can be
/// rewritten in an afternoon, six months from now, against whatever data
/// exists. But if the app never recorded that a viewer opened a title and quit
/// after ninety seconds, that fact is gone permanently and no amount of later
/// work recovers it. `docs/movies_data_model_v2.md` §3 made this argument on
/// 2 Sep; this is it, finally built.
///
/// So: nothing on screen changes because of this file. "Trending" is still
/// `view_count desc` on the server and will be until there are two weeks of
/// events to rank with, because with three titles and a handful of viewers a
/// clever formula ranks noise. The switch-over is one line of SQL on the day
/// the data is worth reading.
///
/// ### The four rules this is written to
///
/// **It must never cost a frame.** Every method returns void, buffers in
/// memory and returns immediately. Nothing here is awaited by UI code.
///
/// **It must never break the app.** Every network failure is swallowed. An
/// analytics outage is invisible; an error toast over a title someone just
/// opened is not.
///
/// **It must never grow without bound.** A device that is offline for an hour
/// keeps tapping. The buffer is capped and drops the OLDEST events when full —
/// oldest, because if only some of an hour survives, the most recent minutes
/// are the ones still worth having.
///
/// **It must never carry a name.** The server attributes every event to
/// `auth.uid()` or the install id and ignores anything the client says about
/// identity. Nothing in [log]'s signature can carry a phone number or an
/// email, and that is on purpose rather than by accident.
class EventSender {
  EventSender(this._api);

  final ApiClient _api;

  /// How long a full buffer waits before going out.
  ///
  /// Thirty seconds is the number in the design note and it is a reasonable
  /// one: long enough that a burst of scrolling is one request, short enough
  /// that a user who opens the app and immediately kills it still contributes
  /// most of what they did.
  static const Duration flushEvery = Duration(seconds: 30);

  /// Flush early once this many are waiting, so a heavy session does not sit
  /// on thirty seconds of data it could have posted.
  static const int flushAt = 25;

  /// The ceiling. Beyond this the oldest are dropped.
  ///
  /// The server takes 200 in one call, so a buffer larger than that would
  /// post a batch whose tail is silently discarded — which is worse than
  /// dropping it here, where it is at least deliberate.
  static const int maxBuffered = 200;

  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
  Timer? _timer;
  bool _sending = false;

  /// One app run.
  ///
  /// This is what makes a journey legible: which row a card was clicked from,
  /// what was searched just before a play, where it stopped. Regenerated on
  /// every launch and never stored, so it identifies a SESSION and not a
  /// person — two runs by the same user are two ids.
  final String sessionId = _randomId();

  static String _randomId() {
    final r = Random();
    // 64 bits as hex. Not a uuid package for twelve characters of entropy.
    return List<int>.generate(8, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Queue one event.
  ///
  /// [kind] must be one the server knows; anything else is dropped there
  /// rather than stored, because one typo'd kind shipped in one release would
  /// split a metric in two forever with nothing to say which half is real.
  /// The constants on [Ev] exist so a call site cannot invent one.
  void log(
    String kind, {
    String? titleId,
    String? assetId,
    int? positionS,
    int? durationS,
    Map<String, dynamic>? meta,
  }) {
    final event = <String, dynamic>{
      'kind': kind,
      // The DEVICE's clock, not the server's. A batch flushed after thirty
      // seconds offline would otherwise record every event at the moment the
      // network came back, which destroys exactly the ordering that makes a
      // session worth reading. The server clamps this to its own now(), so a
      // wrong clock cannot write the future.
      'at': DateTime.now().toUtc().toIso8601String(),
      'session_id': sessionId,
      'app_version': '${AppVersion.name}+${AppVersion.build}',
      // Both reported by the device and therefore unaffected by a VPN, which
      // is the point: `cf-ipcountry` says where the CONNECTION comes from and
      // a tunnelled connection says the wrong thing. A phone at UTC+06:30
      // with a Burmese locale is a Myanmar viewer whatever the exit node
      // claims. The server's `event_geo` view uses these two to decide which
      // audience an event belongs to.
      'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      // NO `network_kind`. Telling Wi-Fi from mobile needs a plugin this app
      // deliberately does not have - see core/services/connectivity, which
      // makes the same call for the same reason. The column exists server-side
      // for the day that changes; sending a guess would be worse than sending
      // nothing, because a guess cannot be told from a measurement later.
      'device_kind': 'phone',
      if (titleId != null && titleId.isNotEmpty) 'title_id': titleId,
      if (assetId != null && assetId.isNotEmpty) 'asset_id': assetId,
      if (positionS != null) 'position_s': positionS,
      if (durationS != null) 'duration_s': durationS,
      if (meta != null && meta.isNotEmpty) 'meta': meta,
    };

    _buffer.add(event);
    // Oldest first. See the class note.
    while (_buffer.length > maxBuffered) {
      _buffer.removeAt(0);
    }

    if (_buffer.length >= flushAt) {
      // ignore: discarded_futures
      flush();
    } else {
      _arm();
    }
  }

  void _arm() {
    _timer ??= Timer(flushEvery, () {
      _timer = null;
      // ignore: discarded_futures
      flush();
    });
  }

  /// Sends whatever is buffered.
  ///
  /// Called on a timer, when the buffer fills, and when the app goes to the
  /// background — the last of which is the important one, because an app that
  /// only flushed on a timer would lose the final thirty seconds of every
  /// session, and the final thirty seconds is where people stop watching.
  ///
  /// EVENTS ARE NOT PUT BACK ON FAILURE. A retry queue for analytics is a way
  /// to turn one dead network into a buffer that never drains and a request
  /// that runs forever. Losing a batch loses a batch.
  Future<void> flush() async {
    if (_sending || _buffer.isEmpty) return;
    _timer?.cancel();
    _timer = null;
    _sending = true;

    final batch = List<Map<String, dynamic>>.unmodifiable(_buffer);
    _buffer.clear();

    try {
      await _api.postJson(
        '/rest/v1/rpc/record_events',
        body: <String, dynamic>{'batch': batch},
        // Signed in when there is a session, anonymous otherwise. Either way
        // ApiClient attaches `x-install-id`, which is what the server falls
        // back to - so an event from a signed-out viewer still attributes to
        // somebody rather than being thrown away.
        authenticated: true,
      );
    } on ApiException catch (e) {
      if (kDebugMode) debugPrint('events: dropped ${batch.length} (${e.kind})');
    } catch (e) {
      if (kDebugMode) debugPrint('events: dropped ${batch.length} ($e)');
    } finally {
      _sending = false;
    }
  }

  /// Visible for tests: how many are waiting.
  @visibleForTesting
  int get pending => _buffer.length;

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// The event kinds the server accepts.
///
/// Constants rather than bare strings at the call sites. The server drops a
/// kind it does not recognise, so a typo is not a crash and not a wrong
/// number — it is silence, which is the hardest of the three to notice.
class Ev {
  Ev._();

  /// A card was drawn on screen. The DENOMINATOR: without it, "popular" only
  /// ever measures what was already promoted.
  static const String impression = 'impression';

  /// A card was tapped. Impressions over clicks is how two candidate posters
  /// are compared — which is what the movable `is_primary` flag is for.
  static const String cardClick = 'card_click';

  /// The detail screen opened. Interest without commitment.
  static const String detailView = 'detail_view';

  static const String playStart = 'play_start';

  /// Every ~30s while playing. Where people stop is the most valuable signal
  /// in the whole schema.
  /// How long the screen stayed black before the first frame, in ms, in
  /// `meta.open_ms`.
  ///
  /// THE NUMBER THAT ENDS THE ARGUMENT. Start-up latency was previously
  /// something people described ("it spins for a while") and something we
  /// guessed at ("probably the moov atom"), and neither is a basis for
  /// changing anything. A distribution of real measurements from real phones
  /// on real Myanmar connections is: it says whether the fix worked, which
  /// titles are slow, and whether slow is the file or the network.
  ///
  /// Carried on its own event rather than folded into `play_start` because
  /// `play_start` is logged before the player screen even exists — the number
  /// does not exist yet at that point.
  static const String playOpen = 'play_open';

  static const String playProgress = 'play_progress';

  /// ≥90% watched.
  static const String playComplete = 'play_complete';

  /// A refusal. How often the paywall is HIT, which is the conversion funnel:
  /// many refusals and few subscriptions means the price or the free tier is
  /// wrong, and that is a business answer no amount of code produces.
  static const String playbackDenied = 'playback_denied';

  /// A query was submitted. `meta: {q, results}` — and a query with zero
  /// results is the audience naming what the catalogue is missing, in their
  /// own words.
  static const String search = 'search';

  static const String searchOpen = 'search_open';
  static const String filterApply = 'filter_apply';
  static const String bookmarkAdd = 'bookmark_add';
  static const String bookmarkRemove = 'bookmark_remove';
  static const String downloadStart = 'download_start';
  static const String downloadComplete = 'download_complete';
  static const String appOpen = 'app_open';
  static const String error = 'error';
}
