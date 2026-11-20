import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/services/diagnostics/playback_log.dart';
import 'event_sender.dart';

/// Playback summaries kept on the phone until the server is known to have
/// them (14 Nov 2026).
///
/// WHY. The last playback of a session is often the longest, and its
/// `play_summary` was the one most often lost: queued in memory as the player
/// closed (EventSender, sent within 30 s or at the background's flush), its
/// kept copy deleted the moment it was queued. Leaving the app soon after
/// left the post to an app Android freezes or ends at will: 1.64.84 lost the
/// summaries of 2 of 3 playbacks (one at 08:18:57 while the app itself lived
/// on — the batch that carried it never arrived), 1.64.85 the last of 5
/// (13:54:22). Now every summary is written here first and deleted only when
/// the batch it went in was taken (EventSender.enqueue's `onDone`); a send
/// that fails is tried again in the same run ([triesPerRun]), and whatever is
/// still here goes out at the next start ([sendEarlier]).
///
/// ONE ROW PER PLAYBACK. Every copy of a summary carries the playback's
/// `summary_id` (PlaybackReporter.summaryId): the copy kept at the
/// background, the one sent as the screen closes, the one sent again at a
/// later start. A send can reach the server and its answer still be lost
/// (the app frozen or ended mid-post): the copy is then sent again, and a
/// reader keeps one row per `summary_id`.
///
/// Kept in SharedPreferences, at most [maxKept], none older than [maxAge];
/// dropped with the account on sign-out ([clear]); never a failure — a
/// summary not kept is one row lost, as before.
class SummaryOutbox {
  SummaryOutbox._();

  /// The kept summaries, a JSON list of events as EventSender.build made
  /// them.
  static const String key = 'play_summary_outbox';

  /// 1.64.81–1.64.85 kept one summary (the background's) under this key;
  /// read once at the next start like the rest.
  static const String legacyKey = 'play_summary_kept';

  /// Enough for a run of short playbacks on a dead line; the oldest go first.
  static const int maxKept = 8;

  /// record_events takes an event's own time back at most 7 days: an older
  /// copy would be filed at the wrong time, so it is dropped instead.
  static const Duration maxAge = Duration(days: 7);

  /// Posts tried for one copy in one run (the first and two more, each with
  /// the sender's next flush) before it waits for the next start.
  static const int triesPerRun = 3;

  /// The meta field that names a playback's summary in every copy.
  static const String idField = 'summary_id';

  /// Every read and write here in the order asked: a delete asked for after
  /// a write always finds that write done.
  static Future<void> _chain = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() op) {
    final next = _chain.then((_) => op());
    _chain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// The summary id an event carries, or null.
  static String? idOf(Object? event) {
    if (event is! Map) return null;
    final meta = event['meta'];
    if (meta is! Map) return null;
    final id = meta[idField];
    return id is String && id.isNotEmpty ? id : null;
  }

  static List<Map<String, dynamic>> _read(SharedPreferences sp) {
    final raw = sp.getString(key);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return <Map<String, dynamic>>[];
      return <Map<String, dynamic>>[
        for (final e in list)
          if (e is Map<String, dynamic> &&
              e['kind'] == Ev.playSummary &&
              idOf(e) != null)
            e,
      ];
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _write(
      SharedPreferences sp, List<Map<String, dynamic>> list) async {
    if (list.isEmpty) {
      await sp.remove(key);
    } else {
      await sp.setString(key, jsonEncode(list));
    }
  }

  /// Keeps [event] (it carries a summary id), in place of any earlier copy
  /// of the same playback.
  static Future<void> put(Map<String, dynamic> event) {
    final id = idOf(event);
    if (id == null) return Future<void>.value();
    return _serial(() async {
      try {
        final sp = await SharedPreferences.getInstance();
        final list = _read(sp)
          ..removeWhere((e) => idOf(e) == id)
          ..add(event);
        while (list.length > maxKept) {
          list.removeAt(0);
        }
        await _write(sp, list);
      } catch (_) {}
    });
  }

  /// Forgets the playback [id]: its summary has gone.
  static Future<void> remove(String id) => _serial(() async {
        try {
          final sp = await SharedPreferences.getInstance();
          final list = _read(sp);
          final before = list.length;
          list.removeWhere((e) => idOf(e) == id);
          if (list.length != before) await _write(sp, list);
        } catch (_) {}
      });

  /// Forgets every kept summary. On sign-out and account deletion: an event
  /// takes the account it is SENT under, so one kept under an account that
  /// has since gone would go out as the next person's (review of 13 Nov).
  static Future<void> clear() => _serial(() async {
        try {
          final sp = await SharedPreferences.getInstance();
          await sp.remove(key);
          await sp.remove(legacyKey);
        } catch (_) {}
      });

  /// What is kept, for tests and the lab's look.
  static Future<List<Map<String, dynamic>>> kept() => _serial(() async {
        try {
          return _read(await SharedPreferences.getInstance());
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      });

  /// Queues [event] on [events]: deleted here once it has gone, tried again
  /// with the next flush if its post failed, left for the next start after
  /// [triesPerRun].
  static void send(EventSender events, Map<String, dynamic> event,
      {int attempt = 1}) {
    final id = idOf(event);
    final tag =
        id == null ? '?' : id.substring(0, id.length < 6 ? id.length : 6);
    events.enqueue(event, onDone: (sent) {
      if (sent) {
        PlaybackLog.add('summary $tag sent'
            '${attempt > 1 ? ' on post $attempt' : ''}'
            '${event['meta'] is Map && (event['meta'] as Map)['stashed'] == 1 ? ' (kept from an earlier run)' : ''}');
        if (id != null) unawaited(remove(id));
      } else if (attempt < triesPerRun) {
        send(events, event, attempt: attempt + 1);
      } else {
        PlaybackLog.add('summary $tag kept for the next start '
            '($triesPerRun posts failed)');
      }
    });
  }

  /// Senders that have had [sendEarlier]: once per app run.
  static final Expando<bool> _sentFor = Expando<bool>('summary outbox');

  /// At start: queues every summary kept by an EARLIER run (its session is
  /// not this sender's), each marked `stashed: 1` — sent at a later start
  /// than its own, from the phone's copy. One kept under [legacyKey] by an
  /// older version is given its id here, from what it already holds, so a
  /// second start cannot make it two rows.
  static Future<void> sendEarlier(EventSender events, {DateTime? now}) async {
    if (_sentFor[events] == true) return;
    _sentFor[events] = true;
    final List<Map<String, dynamic>> earlier = await _serial(() async {
      try {
        final sp = await SharedPreferences.getInstance();
        final list = _read(sp);
        var changed = false;
        final legacy = sp.getString(legacyKey);
        if (legacy != null) {
          final adopted = _adopt(legacy);
          if (adopted != null && !list.any((e) => idOf(e) == idOf(adopted))) {
            list.insert(0, adopted);
          }
          changed = true;
        }
        final cutoff = (now ?? DateTime.now()).toUtc().subtract(maxAge);
        final before = list.length;
        list.removeWhere((e) {
          final at = DateTime.tryParse('${e['at']}');
          return at == null || at.isBefore(cutoff);
        });
        if (list.length != before) changed = true;
        if (changed) {
          await _write(sp, list);
          if (legacy != null) await sp.remove(legacyKey);
        }
        return <Map<String, dynamic>>[
          for (final e in list)
            if (e['session_id'] != events.sessionId) e,
        ];
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });
    if (earlier.isNotEmpty) {
      PlaybackLog.add(
          'summaries kept by an earlier run: ${earlier.length} queued');
    }
    for (final e in earlier) {
      final meta = e['meta'];
      send(events, <String, dynamic>{
        ...e,
        'meta': <String, dynamic>{
          if (meta is Map) ...meta.cast<String, dynamic>(),
          'stashed': 1,
        },
      });
    }
  }

  /// The older versions' single kept summary, with an id made from its own
  /// time and session (the same every time it is read).
  static Map<String, dynamic>? _adopt(String raw) {
    try {
      final e = jsonDecode(raw);
      if (e is! Map<String, dynamic> || e['kind'] != Ev.playSummary) {
        return null;
      }
      final meta = e['meta'];
      return <String, dynamic>{
        ...e,
        'meta': <String, dynamic>{
          if (meta is Map) ...meta.cast<String, dynamic>(),
          idField: _stableId('${e['at']}|${e['session_id']}|${e['title_id']}'),
        },
      };
    } catch (_) {
      return null;
    }
  }

  /// FNV-1a, 64 bits, as 16 hex digits.
  static String _stableId(String s) {
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final b in utf8.encode(s)) {
      h = ((h ^ BigInt.from(b)) * prime) & mask;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }
}
