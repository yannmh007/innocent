import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';

/// Where one viewing of a catalogue video stands.
///
/// WHY THE MOVIES FEATURE KEEPS ITS OWN, rather than the player's resume
/// store. A stream is opened at a signed URL that is different every time,
/// so the player cannot key a position on it (player_provider.dart,
/// `_isEphemeral`) — and it must not try: the player's Continue watching,
/// Resume button and cold-start prompt are on the Local tab, in front of the
/// age gate. So every film used to reopen at 00:00. This is keyed on what
/// does not change — the title and the clip — and lives behind the gate, in
/// the Movies feature, where Netflix and YouTube put the same thing.
@immutable
class WatchPoint {
  const WatchPoint({
    required this.titleId,
    this.assetId,
    required this.positionS,
    required this.durationS,
    required this.at,
    this.finished = false,
  });

  final String titleId;

  /// The clip, or null for the title's main film.
  final String? assetId;
  final int positionS;

  /// 0 while unknown.
  final int durationS;
  final DateTime at;
  final bool finished;

  String get key => keyOf(titleId, assetId);
  static String keyOf(String titleId, String? assetId) =>
      '$titleId|${assetId ?? ''}';

  /// Worth offering to continue: past the opening (30 s), not finished, and
  /// not inside the last 30 s — reopening there would show the credits.
  bool get resumable =>
      !finished &&
      positionS >= 30 &&
      (durationS <= 0 || durationS - positionS > 30);

  /// How far through, 0..1, or null when the length is unknown.
  double? get fraction =>
      durationS > 0 ? (positionS / durationS).clamp(0.0, 1.0) : null;

  Duration get position => Duration(seconds: positionS);

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': titleId,
        if (assetId != null) 'a': assetId,
        'p': positionS,
        'd': durationS,
        'at': at.toUtc().toIso8601String(),
        if (finished) 'f': true,
      };

  static WatchPoint? fromJson(Object? o) {
    if (o is! Map) return null;
    final t = o['t'];
    final at = DateTime.tryParse('${o['at']}');
    final p = o['p'];
    if (t is! String || t.isEmpty || at == null || p is! int) return null;
    final a = o['a'];
    final d = o['d'];
    return WatchPoint(
      titleId: t,
      assetId: a is String && a.isNotEmpty ? a : null,
      positionS: p,
      durationS: d is int ? d : 0,
      at: at,
      finished: o['f'] == true,
    );
  }

  /// A row of `my_watch_state()`.
  static WatchPoint? fromServer(Object? o) {
    if (o is! Map) return null;
    final t = o['title_id'];
    final at = DateTime.tryParse('${o['last_at']}');
    final p = o['position_s'];
    if (t is! String || at == null || p is! num) return null;
    final a = o['asset_id'];
    final d = o['duration_s'];
    return WatchPoint(
      titleId: t,
      assetId: a is String && a.isNotEmpty ? a : null,
      positionS: p.toInt(),
      durationS: d is num ? d.toInt() : 0,
      at: at.toLocal(),
      finished: o['finished'] == true,
    );
  }
}

/// Every viewing this phone knows about, newest first, at most [cap].
///
/// Immutable, so a notifier can hold it and a test can assert on it.
@immutable
class WatchLedger {
  const WatchLedger([this._points = const <String, WatchPoint>{}, this.hidden = const <String>{}]);

  static const int cap = 300;
  static const WatchLedger empty = WatchLedger();

  final Map<String, WatchPoint> _points;

  /// Titles taken out of Continue watching by hand. A new viewing of the
  /// title brings it back, as on Netflix.
  final Set<String> hidden;

  Iterable<WatchPoint> get points => _points.values;

  WatchPoint? pointFor(String titleId, String? assetId) =>
      _points[WatchPoint.keyOf(titleId, assetId)];

  /// The title's most recent viewing, of any clip.
  WatchPoint? latestFor(String titleId) {
    WatchPoint? best;
    for (final p in _points.values) {
      if (p.titleId != titleId) continue;
      if (best == null || p.at.isAfter(best.at)) best = p;
    }
    return best;
  }

  /// Newest first, resumable, not hidden, one per title.
  List<WatchPoint> get continueWatching {
    final byTitle = <String, WatchPoint>{};
    for (final p in _points.values) {
      if (hidden.contains(p.titleId)) continue;
      final cur = byTitle[p.titleId];
      if (cur == null || p.at.isAfter(cur.at)) byTitle[p.titleId] = p;
    }
    final list = byTitle.values.where((p) => p.resumable).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  /// This phone saw [p]: the newer of it and what is held wins.
  WatchLedger record(WatchPoint p) {
    final cur = _points[p.key];
    if (cur != null && cur.at.isAfter(p.at)) return this;
    final next = <String, WatchPoint>{..._points, p.key: p};
    return WatchLedger(_trim(next), {...hidden}..remove(p.titleId));
  }

  /// The server's view, from this account's other phones too. Per point,
  /// the newer wins; nothing held here is lost.
  WatchLedger merge(Iterable<WatchPoint> server) {
    final next = <String, WatchPoint>{..._points};
    for (final p in server) {
      final cur = next[p.key];
      if (cur == null || p.at.isAfter(cur.at)) next[p.key] = p;
    }
    return WatchLedger(_trim(next), hidden);
  }

  WatchLedger hide(String titleId) =>
      WatchLedger(_points, {...hidden, titleId});

  static Map<String, WatchPoint> _trim(Map<String, WatchPoint> m) {
    if (m.length <= cap) return m;
    final sorted = m.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    return {for (final p in sorted.take(cap)) p.key: p};
  }

  String encode() => jsonEncode(<String, dynamic>{
        'v': 1,
        'points': [for (final p in _points.values) p.toJson()],
        'hidden': hidden.toList(),
      });

  static WatchLedger decode(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final o = jsonDecode(raw);
      if (o is! Map) return empty;
      final pts = <String, WatchPoint>{};
      for (final e in (o['points'] as List? ?? const [])) {
        final p = WatchPoint.fromJson(e);
        if (p != null) pts[p.key] = p;
      }
      final hidden = <String>{
        for (final h in (o['hidden'] as List? ?? const [])) if (h is String) h,
      };
      return WatchLedger(_trim(pts), hidden);
    } catch (_) {
      // A corrupt blob costs the resume points, never the screen.
      return empty;
    }
  }
}

/// The ledger on the phone, and the server's copy of it.
class WatchStateStore {
  const WatchStateStore();

  static const String _key = 'vh.watch_points.v1';

  Future<WatchLedger> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return WatchLedger.decode(p.getString(_key));
    } catch (_) {
      return WatchLedger.empty;
    }
  }

  Future<void> save(WatchLedger l) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, l.encode());
    } catch (_) {
      // A missed write costs one resume point.
    }
  }

  /// `my_watch_state()`: this viewer's viewings as the server knows them
  /// (migration 039). Throws on a network failure; the caller keeps what it
  /// has.
  static Future<List<WatchPoint>> pull(ApiClient api) async {
    final body = await api.postJson('/rest/v1/rpc/my_watch_state',
        body: const <String, dynamic>{});
    if (body is! List) return const <WatchPoint>[];
    return <WatchPoint>[
      for (final r in body)
        if (WatchPoint.fromServer(r) case final p?) p,
    ];
  }
}
