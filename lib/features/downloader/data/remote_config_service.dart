import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Where the config is fetched from.
///
/// SET THIS BEFORE BUILDING and the whole update problem changes shape. Host a
/// small JSON file anywhere static — a GitHub raw URL costs nothing and needs
/// no server — and from then on, when a site changes what it accepts, editing
/// that one file fixes every installed copy within hours. No rebuild, no new
/// APK, nothing for the user to do.
///
/// Left empty on purpose rather than pointed at a guessed address: an app that
/// quietly polls a URL its owner does not control is worse than one that does
/// nothing. While it is empty the feature simply sleeps and the values
/// compiled into the app are used. It can also be set at runtime in
/// Settings → Advanced, which is the quickest way to test a config before
/// committing to it.
const String kDefaultConfigUrl = '';

/// The settings a remote config is allowed to change.
///
/// Deliberately a SHORT list. Everything here is a value the app would have
/// hardcoded anyway, and nothing here can change what the app DOES — there is
/// no code, no script, no download location, no executable path. The worst a
/// hostile config can achieve is a list of player names that don't work, which
/// is the situation it exists to repair.
@immutable
class DownloaderConfig {
  const DownloaderConfig({
    this.version = 0,
    this.youtubeClients,
    this.tiktokApiHosts = const <String>[],
    this.notice,
    this.noticeUrl,
    this.minEngineVersion,
    this.fetchedAt,
  });

  final int version;

  /// Replacement for the built-in player-client list.
  final String? youtubeClients;

  /// Replacement for the built-in TikTok app-API hosts.
  final List<String> tiktokApiHosts;

  /// A short message to show on the downloader screen — for telling everyone
  /// at once that a site is having a bad week, without pushing an update.
  final String? notice;
  final String? noticeUrl;

  /// Engines older than this are offered (or given) an update.
  final String? minEngineVersion;

  final DateTime? fetchedAt;

  bool get isEmpty =>
      youtubeClients == null &&
      tiktokApiHosts.isEmpty &&
      notice == null &&
      minEngineVersion == null;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'youtubeClients': youtubeClients,
        'tiktokApiHosts': tiktokApiHosts,
        'notice': notice,
        'noticeUrl': noticeUrl,
        'minEngineVersion': minEngineVersion,
        'fetchedAt': fetchedAt?.toIso8601String(),
      };

  /// Parses a config, keeping only what is recognised and well-formed.
  ///
  /// Every field is validated rather than trusted. Unknown keys are ignored,
  /// strings are length-capped, the client list must look like a client list,
  /// and hosts must be bare hostnames — so a config cannot smuggle in a URL,
  /// a path, or an argument of its own.
  static DownloaderConfig? tryParse(String body) {
    try {
      if (body.length > 64 * 1024) return null;
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final Map<Object?, Object?> map = decoded;

      String? clients = _string(map['youtubeClients'], 200);
      if (clients != null && !RegExp(r'^[a-z0-9_,\- ]+$').hasMatch(clients)) {
        clients = null;
      }

      final List<String> hosts = <String>[];
      final Object? rawHosts = map['tiktokApiHosts'];
      if (rawHosts is List) {
        for (final Object? h in rawHosts.take(6)) {
          final String? host = _string(h, 120);
          // A hostname and nothing else: no scheme, no slash, no query.
          if (host != null &&
              RegExp(r'^[a-z0-9.\-]+\.[a-z]{2,}$').hasMatch(host)) {
            hosts.add(host);
          }
        }
      }

      String? noticeUrl = _string(map['noticeUrl'], 400);
      if (noticeUrl != null && !noticeUrl.startsWith('https://')) {
        noticeUrl = null;
      }

      return DownloaderConfig(
        version: _int(map['version']) ?? 0,
        youtubeClients: clients,
        tiktokApiHosts: hosts,
        notice: _string(map['notice'], 300),
        noticeUrl: noticeUrl,
        minEngineVersion: _string(map['minEngineVersion'], 40),
        fetchedAt: _date(map['fetchedAt']) ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  static String? _string(Object? value, int max) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > max) return null;
    return trimmed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return null;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// Fetches and caches the config.
class RemoteConfigService {
  RemoteConfigService._();

  static final RemoteConfigService instance = RemoteConfigService._();

  static const Duration _timeout = Duration(seconds: 10);

  /// Downloads and parses the config at [url]. Returns null on any problem —
  /// a config that cannot be read must leave the app exactly as it was, never
  /// half-applied.
  Future<DownloaderConfig?> fetch(String url) async {
    if (url.trim().isEmpty) return null;
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isScheme('https')) return null;
    try {
      final http.Response res = await http.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return DownloaderConfig.tryParse(
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }
}
