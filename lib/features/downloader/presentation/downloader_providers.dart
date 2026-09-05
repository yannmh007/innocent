import 'dart:async';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/downloader/downloader_engine_service.dart';
import '../data/probe_pipeline.dart';
import '../data/site_catalog.dart';
import '../data/remote_config_service.dart';
import '../domain/diagnostics_log.dart';
import '../domain/download_progress.dart';
import '../domain/media_probe.dart';
import '../domain/quality_preset.dart';

/// Default save location.
///
/// `/storage/emulated/0/Download/Innocent` on purpose, not a folder at the
/// storage root: the public Download directory is writable on every Android
/// version even WITHOUT all-files access (scoped storage carves it out
/// explicitly), it is indexed by the MediaStore, and it survives an uninstall.
/// The library's filesystem scan walks /storage/emulated/0 recursively, so
/// finished downloads turn up in the Videos tab with no extra wiring.
const String kDefaultDownloadDir = '/storage/emulated/0/Download/Innocent';

const String _kFavouritesKey = 'downloader_favourites_v1';
const String _kShowRestrictedKey = 'downloader_show_restricted_v1';
const String _kDirKey = 'downloader_dir_v1';
const String _kCookiesKey = 'downloader_cookies_v1';
const String _kClientsKey = 'downloader_clients_v1';
const String _kQueueKey = 'downloader_queue_v1';
const String _kHistoryKey = 'downloader_history_v1';
const String _kClientsUserSetKey = 'downloader_clients_user_v1';
const String _kConfigUrlKey = 'downloader_config_url_v1';
const String _kConfigBodyKey = 'downloader_config_body_v1';
const String _kConfigAtKey = 'downloader_config_at_v1';
const String _kAutoUpdateKey = 'downloader_auto_update_v1';
const String _kWifiOnlyKey = 'downloader_wifi_only_v1';
const String _kQualityKey = 'downloader_quality_v1';
const String _kSubLangsKey = 'downloader_sublangs_v1';
const String _kThumbKey = 'downloader_thumb_v1';
const String _kMetaKey = 'downloader_meta_v1';
const String _kRateKey = 'downloader_rate_v1';

/// YouTube player clients tried when the default one is refused.
///
/// THIS LIST IS NOT ARBITRARY — it is the set that needs no Proof-of-Origin
/// token, taken from yt-dlp's own PO Token Guide (revised July 2026). That
/// distinction is the whole ballgame for an app that must work without asking
/// anyone to log in:
///
///   android_vr   — no PO token required. The only thing it cannot fetch is
///                  videos marked "made for kids".
///   web_safari   — serves HLS formats, which are exempt from the GVS token.
///   web_embedded — no PO token required, but only for embeddable videos.
///   mweb         — needs one for streaming, so it sits last as a long shot.
///
/// The previous default was 'android,web_embedded,tv_embedded', which was
/// wrong twice over: `android` needs a PO token for either streaming or the
/// player call, and `tv_embedded` is no longer a client name in the table at
/// all. Asking through those is a request that cannot succeed unaided, which
/// is a large part of why YouTube returned nothing at all.
///
/// Editable in settings on purpose: YouTube changes which clients work every
/// few months, and typing a new list beats waiting for a rebuild. Empty
/// disables the retry.
const String kDefaultPlayerClients =
    'android_vr,web_embedded,web_safari,tv_downgraded';

// ---------------------------------------------------------------- engine

/// Engine readiness. Kept as a notifier rather than a FutureProvider so the
/// screen can retry after a failure without rebuilding the whole subtree.
class EngineStatusNotifier extends StateNotifier<EngineStatus> {
  EngineStatusNotifier() : super(EngineStatus.unknown) {
    refresh();
  }

  bool _inFlight = false;

  Future<void> refresh() async {
    // First call unpacks the Python runtime — slow, and re-entering it would
    // just queue duplicate work behind the same native lock.
    if (_inFlight) return;
    _inFlight = true;
    try {
      final EngineStatus next =
          await DownloaderEngineService.instance.ensureReady();
      if (mounted) state = next;
    } finally {
      _inFlight = false;
    }
  }
}

final StateNotifierProvider<EngineStatusNotifier, EngineStatus>
    engineStatusProvider =
    StateNotifierProvider<EngineStatusNotifier, EngineStatus>(
  (ref) => EngineStatusNotifier(),
);

// ------------------------------------------------------------- favourites

class FavouriteSitesNotifier extends StateNotifier<List<String>> {
  FavouriteSitesNotifier() : super(SiteCatalog.defaultFavourites) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final List<String>? saved = sp.getStringList(_kFavouritesKey);
      if (saved == null) return;
      // Drop ids that no longer exist in the catalog so a renamed or removed
      // site can't leave a permanently broken tile behind.
      final List<String> valid = saved
          .where((String id) => SiteCatalog.byId(id) != null)
          .toList();
      if (mounted) state = valid;
    } catch (_) {
      // Keep the defaults.
    }
  }

  Future<void> _save() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kFavouritesKey, state);
    } catch (_) {}
  }

  Future<void> toggle(String id) async {
    if (SiteCatalog.byId(id) == null) return;
    final List<String> next = List<String>.of(state);
    if (next.remove(id)) {
      state = next;
    } else {
      state = <String>[...next, id];
    }
    await _save();
  }

  bool contains(String id) => state.contains(id);
}

final StateNotifierProvider<FavouriteSitesNotifier, List<String>>
    favouriteSitesProvider =
    StateNotifierProvider<FavouriteSitesNotifier, List<String>>(
  (ref) => FavouriteSitesNotifier(),
);

// -------------------------------------------------------- simple settings

class ShowRestrictedNotifier extends StateNotifier<bool> {
  ShowRestrictedNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final bool? saved = sp.getBool(_kShowRestrictedKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setBool(_kShowRestrictedKey, value);
    } catch (_) {}
  }
}

final StateNotifierProvider<ShowRestrictedNotifier, bool>
    showRestrictedProvider =
    StateNotifierProvider<ShowRestrictedNotifier, bool>(
  (ref) => ShowRestrictedNotifier(),
);

class DownloadDirNotifier extends StateNotifier<String> {
  DownloadDirNotifier() : super(kDefaultDownloadDir) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? saved = sp.getString(_kDirKey);
      if (saved != null && saved.trim().isNotEmpty && mounted) {
        state = saved;
      }
    } catch (_) {}
  }

  Future<void> set(String dir) async {
    final String trimmed = dir.trim();
    if (trimmed.isEmpty) return;
    state = trimmed;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kDirKey, trimmed);
    } catch (_) {}
  }
}

final StateNotifierProvider<DownloadDirNotifier, String> downloadDirProvider =
    StateNotifierProvider<DownloadDirNotifier, String>(
  (ref) => DownloadDirNotifier(),
);

/// Optional Netscape cookies.txt path.
///
/// The escape hatch for anything that needs to be signed in: export cookies
/// from a browser once, point Innocent at the file, and age-gated,
/// members-only and bot-walled links start resolving. An in-app browser will
/// be able to produce this file itself later; until then the user supplies it.
class CookiesPathNotifier extends StateNotifier<String?> {
  CookiesPathNotifier() : super(null) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? saved = sp.getString(_kCookiesKey);
      if (saved == null || saved.trim().isEmpty) return;
      // A file the user has since deleted must not keep being passed to
      // yt-dlp, which would fail every call with a confusing error.
      if (!File(saved).existsSync()) {
        await sp.remove(_kCookiesKey);
        return;
      }
      if (mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(String? path) async {
    state = (path != null && path.trim().isEmpty) ? null : path;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      if (state == null) {
        await sp.remove(_kCookiesKey);
      } else {
        await sp.setString(_kCookiesKey, state!);
      }
    } catch (_) {}
  }
}

final StateNotifierProvider<CookiesPathNotifier, String?> cookiesPathProvider =
    StateNotifierProvider<CookiesPathNotifier, String?>(
  (ref) => CookiesPathNotifier(),
);

class PlayerClientsNotifier extends StateNotifier<String> {
  /// True once the user has typed their own list, after which a remote config
  /// must never overwrite it — an explicit choice outranks a suggestion.
  bool userSet = false;

  PlayerClientsNotifier() : super(kDefaultPlayerClients) {
    _load();
  }

  /// Client lists that shipped as defaults in earlier builds.
  ///
  /// Someone who installed an older version has one of these saved, and a
  /// saved value beats the new default forever — so an upgrade would silently
  /// keep asking YouTube through clients that cannot work. Retired defaults
  /// are replaced; anything the user typed themselves is left alone.
  /// Client sets we once shipped as the default and no longer believe in.
  ///
  /// Anyone still carrying one of these is moved to the current default on
  /// next launch, WITHOUT touching a set the person chose themselves. A stale
  /// default is not a preference; it is our old opinion wearing their name.
  static const Set<String> _retiredDefaults = <String>{
    'android,web_embedded,tv_embedded',
    // Retired Aug 2026. The device report named the fault directly: mweb's
    // formats now need a GVS PO Token and get skipped, and web_safari is
    // pushed onto SABR. Three of these four had stopped yielding anything
    // usable, so falling back to them made a struggling read worse rather
    // than better.
    'android_vr,web_safari,web_embedded,mweb',
    // Retired the same week it shipped. `visionos` is in yt-dlp's master
    // README but NOT in the stable engine we run, which answered with
    // `Skipping unsupported client "visionos"`. Reading documentation from a
    // branch we do not ship is the mistake; the self-healing below is so the
    // consequence cannot outlive one read next time.
    'visionos,android_vr,tv_downgraded',
    // Retired Aug 2026 after a device report. `android_vr` answered
    // LOGIN_REQUIRED and there was nothing behind it that could help: yt-dlp's
    // own documentation says `tv_downgraded` is the client it picks when
    // LOGGED-IN cookies are present, so pairing it with a guest session asks
    // the one client that most expects an account to work without one. The
    // engine's stated default for a guest is `android_vr` then `web`, and we
    // have the JS runtime `web` needs, so `web` goes in the middle and
    // `tv_downgraded` stays as the documented last resort.
    'android_vr,tv_downgraded',
    // Retired Aug 2026 on a flagged address. Under a VPN this list had ONE
    // client that could work unaided: `web` needs a PO token for its media
    // server, and `tv_downgraded` is the client yt-dlp reaches for when
    // LOGGED-IN cookies are present. So when `android_vr` came back
    // LOGIN_REQUIRED there was nothing behind it.
    //
    // The wiki's own table lists exactly three clients that need no token:
    // `android_vr` (nearly unrestricted), `web_embedded` (embeddable videos,
    // no token at all) and `web_safari` (its HLS formats are exempt). Those go
    // first now, and `tv_downgraded` stays last where it is genuinely the
    // right answer — once somebody has signed in.
    'android_vr,web,tv_downgraded',
  };

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? saved = sp.getString(_kClientsKey);
      if (saved == null) return;
      if (_retiredDefaults.contains(saved.trim())) {
        await sp.setString(_kClientsKey, kDefaultPlayerClients);
        if (mounted) state = kDefaultPlayerClients;
        return;
      }
      userSet = sp.getBool(_kClientsUserSetKey) ?? true;
      if (mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(String value) async {
    state = value.trim();
    userSet = true;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kClientsKey, state);
      await sp.setBool(_kClientsUserSetKey, true);
    } catch (_) {}
  }

  /// Applies a list that came from the remote config. Ignored once the user
  /// has set their own.
  void applyRemote(String? value) {
    if (userSet) return;
    final String next = (value == null || value.trim().isEmpty)
        ? kDefaultPlayerClients
        : value.trim();
    if (mounted && next != state) state = next;
  }
}

// ------------------------------------------------------------ remote config

/// Fetches, caches and applies the remote config.
///
/// The point of this is repair speed. Everything else in the downloader can
/// only be changed by building a new APK and getting it onto a phone, which in
/// practice means most installs never receive the fix at all. A small JSON
/// file turns "wait for the next release" into "edit one line", and the values
/// it can change are exactly the ones that go stale when a site changes its
/// mind.
class RemoteConfigNotifier extends StateNotifier<DownloaderConfig> {
  RemoteConfigNotifier(this._ref) : super(const DownloaderConfig()) {
    _loadCached();
  }

  final Ref _ref;
  DateTime? _lastAttempt;
  String _url = kDefaultConfigUrl;

  String get url => _url;

  Future<void> _loadCached() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      _url = sp.getString(_kConfigUrlKey) ?? kDefaultConfigUrl;
      final String? body = sp.getString(_kConfigBodyKey);
      if (body == null) return;
      final DownloaderConfig? cached = DownloaderConfig.tryParse(body);
      if (cached == null || !mounted) return;
      state = cached;
      _apply(cached);
    } catch (_) {}
    // A cached config is applied instantly; a fresh one is asked for after.
    unawaited(refresh());
  }

  Future<void> setUrl(String value) async {
    _url = value.trim();
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kConfigUrlKey, _url);
    } catch (_) {}
    await refresh(force: true);
  }

  /// [force] skips the six-hour freshness window but not the one-minute floor
  /// — a failing link should be allowed to ask again, not to hammer.
  Future<void> refresh({bool force = false}) async {
    if (_url.trim().isEmpty) return;
    final DateTime now = DateTime.now();
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(minutes: 1)) {
      return;
    }
    if (!force && state.fetchedAt != null &&
        now.difference(state.fetchedAt!) < const Duration(hours: 6)) {
      return;
    }
    _lastAttempt = now;
    final DownloaderConfig? fresh =
        await RemoteConfigService.instance.fetch(_url);
    if (fresh == null || !mounted) return;
    state = fresh;
    _apply(fresh);
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kConfigBodyKey, jsonEncode(fresh.toJson()));
      await sp.setString(_kConfigAtKey, now.toIso8601String());
    } catch (_) {}
  }

  void _apply(DownloaderConfig config) {
    _ref.read(playerClientsProvider.notifier).applyRemote(config.youtubeClients);
  }
}

final StateNotifierProvider<RemoteConfigNotifier, DownloaderConfig>
    remoteConfigProvider =
    StateNotifierProvider<RemoteConfigNotifier, DownloaderConfig>(
  (ref) => RemoteConfigNotifier(ref),
);

// -------------------------------------------------------- simple toggles 2

/// Keep the engine current without being asked.
class AutoUpdateNotifier extends StateNotifier<bool> {
  AutoUpdateNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final bool? saved = sp.getBool(_kAutoUpdateKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setBool(_kAutoUpdateKey, value);
    } catch (_) {}
  }
}

final StateNotifierProvider<AutoUpdateNotifier, bool> autoUpdateProvider =
    StateNotifierProvider<AutoUpdateNotifier, bool>(
  (ref) => AutoUpdateNotifier(),
);

/// Don't spend mobile data without being told to.
///
/// Worth more here than almost any feature: a downloader that quietly eats a
/// data bundle is one nobody opens twice.
class WifiOnlyNotifier extends StateNotifier<bool> {
  WifiOnlyNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final bool? saved = sp.getBool(_kWifiOnlyKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setBool(_kWifiOnlyKey, value);
    } catch (_) {}
  }
}

final StateNotifierProvider<WifiOnlyNotifier, bool> wifiOnlyProvider =
    StateNotifierProvider<WifiOnlyNotifier, bool>(
  (ref) => WifiOnlyNotifier(),
);

final StateNotifierProvider<PlayerClientsNotifier, String> playerClientsProvider =
    StateNotifierProvider<PlayerClientsNotifier, String>(
  (ref) => PlayerClientsNotifier(),
);

/// Small in-memory cache of parsed links.
///
/// Re-pasting a link you just looked at is extremely common — you check the
/// sizes, back out, change your mind — and re-running yt-dlp for it costs the
/// full network round trip again. Capped and process-lifetime only: format
/// URLs expire server-side within hours, so persisting this would eventually
/// hand out dead links.
class ProbeCache {
  ProbeCache._();

  static final ProbeCache instance = ProbeCache._();

  static const int _maxEntries = 12;
  static const Duration _ttl = Duration(minutes: 20);

  final Map<String, _CacheEntry> _entries = <String, _CacheEntry>{};

  MediaProbe? get(String url) {
    final _CacheEntry? hit = _entries[url];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.at) > _ttl) {
      _entries.remove(url);
      return null;
    }
    return hit.probe;
  }

  void put(String url, MediaProbe probe) {
    if (_entries.length >= _maxEntries) {
      // Oldest first — Dart maps preserve insertion order.
      _entries.remove(_entries.keys.first);
    }
    _entries[url] = _CacheEntry(probe, DateTime.now());
  }

  void clear() => _entries.clear();
}

class _CacheEntry {
  _CacheEntry(this.probe, this.at);

  final MediaProbe probe;
  final DateTime at;
}

/// How to download when the user has already decided.
///
/// "Ask every time" stays the default because a first-time user has no idea
/// what 1080p costs on their connection. Once they do know, answering the same
/// question on every link is the most repetitive thing about this screen — so
/// the answer becomes a setting and the sheet stops appearing.
class DefaultQualityNotifier extends StateNotifier<QualityPreset> {
  DefaultQualityNotifier() : super(QualityPreset.ask) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? saved = sp.getString(_kQualityKey);
      if (saved != null && mounted) state = QualityPresetX.fromId(saved);
    } catch (_) {}
  }

  Future<void> set(QualityPreset value) async {
    state = value;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kQualityKey, value.id);
    } catch (_) {}
  }
}

final StateNotifierProvider<DefaultQualityNotifier, QualityPreset>
    defaultQualityProvider =
    StateNotifierProvider<DefaultQualityNotifier, QualityPreset>(
  (ref) => DefaultQualityNotifier(),
);

/// Extras that are one yt-dlp flag each, grouped because they share a shape:
/// a boolean or a short string, saved, read again when a download starts.
@immutable
class DownloadExtras {
  const DownloadExtras({
    this.subLangs = '',
    this.embedThumbnail = false,
    this.embedMetadata = false,
    this.rateLimit = '',
  });

  /// Comma-separated languages; empty means no subtitles.
  final String subLangs;
  final bool embedThumbnail;
  final bool embedMetadata;

  /// yt-dlp --limit-rate syntax ("500K", "1M"); empty means unlimited.
  final String rateLimit;

  DownloadExtras copyWith({
    String? subLangs,
    bool? embedThumbnail,
    bool? embedMetadata,
    String? rateLimit,
  }) =>
      DownloadExtras(
        subLangs: subLangs ?? this.subLangs,
        embedThumbnail: embedThumbnail ?? this.embedThumbnail,
        embedMetadata: embedMetadata ?? this.embedMetadata,
        rateLimit: rateLimit ?? this.rateLimit,
      );
}

class DownloadExtrasNotifier extends StateNotifier<DownloadExtras> {
  DownloadExtrasNotifier() : super(const DownloadExtras()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      if (!mounted) return;
      state = DownloadExtras(
        subLangs: sp.getString(_kSubLangsKey) ?? '',
        embedThumbnail: sp.getBool(_kThumbKey) ?? false,
        embedMetadata: sp.getBool(_kMetaKey) ?? false,
        rateLimit: sp.getString(_kRateKey) ?? '',
      );
    } catch (_) {}
  }

  Future<void> update(DownloadExtras next) async {
    state = next;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_kSubLangsKey, next.subLangs);
      await sp.setBool(_kThumbKey, next.embedThumbnail);
      await sp.setBool(_kMetaKey, next.embedMetadata);
      await sp.setString(_kRateKey, next.rateLimit);
    } catch (_) {}
  }
}

final StateNotifierProvider<DownloadExtrasNotifier, DownloadExtras>
    downloadExtrasProvider =
    StateNotifierProvider<DownloadExtrasNotifier, DownloadExtras>(
  (ref) => DownloadExtrasNotifier(),
);


// --------------------------------------------------------------- history

/// A file this app actually put on the phone.
@immutable
class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.title,
    required this.path,
    required this.at,
    this.host,
    this.sourceUrl,
    this.sizeBytes,
  });

  final String id;
  final String title;
  final String path;
  final DateTime at;
  final String? host;

  /// The PAGE this file came from, so the row can offer to reopen it.
  ///
  /// This is the whole reason a history list beats a folder listing. A file
  /// on disk answers "what did I download"; only the page answers "where
  /// was I", which is what somebody actually wants when they come back to a
  /// video they liked -- to see the rest of it, or to take it again at a
  /// different quality.
  final String? sourceUrl;

  /// Size when it finished, so a row can say something readable without
  /// stat-ing a file on every rebuild.
  final int? sizeBytes;

  String get fileName => path.split('/').last;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'path': path,
        'at': at.toIso8601String(),
        'host': host,
        'sourceUrl': sourceUrl,
        'sizeBytes': sizeBytes,
      };

  static DownloadRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? path = raw['path'];
    if (id is! String || path is! String || path.isEmpty) return null;
    return DownloadRecord(
      id: id,
      title: raw['title'] is String ? raw['title'] as String : path.split('/').last,
      path: path,
      at: DateTime.tryParse('${raw['at']}') ?? DateTime.now(),
      host: raw['host'] is String ? raw['host'] as String : null,
      sourceUrl:
          raw['sourceUrl'] is String && (raw['sourceUrl'] as String).isNotEmpty
              ? raw['sourceUrl'] as String
              : null,
      sizeBytes: raw['sizeBytes'] is int ? raw['sizeBytes'] as int : null,
    );
  }
}

/// What has been saved, kept after the row is cleared.
///
/// Until now a finished download existed only as a row in a list that the
/// Clear button wiped — so the one question people actually ask afterwards,
/// "where did that go", had no answer inside the app at all. This is the
/// answer, and it survives restarts.
///
/// Capped: a history that grows without limit is a preferences file that grows
/// without limit.
class DownloadHistoryNotifier extends StateNotifier<List<DownloadRecord>> {
  DownloadHistoryNotifier() : super(const <DownloadRecord>[]) {
    _load();
  }

  static const int _max = 200;

  Future<void> _load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? raw = sp.getString(_kHistoryKey);
      if (raw == null || raw.isEmpty || !mounted) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      state = decoded
          .map(DownloadRecord.fromJson)
          .whereType<DownloadRecord>()
          .toList();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kHistoryKey,
        jsonEncode(state.map((DownloadRecord r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// A file already downloaded from this same page, or null.
  ///
  /// WHY THE PAGE AND NOT THE FILE. Somebody about to download something is
  /// looking at a page, not at a path, and the media address behind it is
  /// signed and changes every few hours — comparing those would say "new" to
  /// the same video every time. The page is what stays the same, which is why
  /// `sourceUrl` was worth persisting in the first place.
  ///
  /// Returns the record so the caller can say WHICH file and offer to play it,
  /// because "you already have this" is only useful with somewhere to go.
  DownloadRecord? alreadyHave(String? sourceUrl) {
    final String key = (sourceUrl ?? '').trim();
    if (key.isEmpty) return null;
    for (final DownloadRecord r in state) {
      if ((r.sourceUrl ?? '').trim() == key) return r;
    }
    return null;
  }

  void add(DownloadRecord record) {
    // Newest first, and never the same file twice — re-downloading something
    // should move it up the list, not duplicate it.
    final List<DownloadRecord> next = <DownloadRecord>[
      record,
      ...state.where((DownloadRecord r) => r.path != record.path),
    ];
    state = next.length > _max ? next.sublist(0, _max) : next;
    unawaited(_persist());
  }

  void forget(String id) {
    state = state.where((DownloadRecord r) => r.id != id).toList();
    unawaited(_persist());
  }

  void clear() {
    state = const <DownloadRecord>[];
    unawaited(_persist());
  }
}

final StateNotifierProvider<DownloadHistoryNotifier, List<DownloadRecord>>
    downloadHistoryProvider =
    StateNotifierProvider<DownloadHistoryNotifier, List<DownloadRecord>>(
  (ref) => DownloadHistoryNotifier(),
);

// ----------------------------------------------------------------- tasks

/// Everything needed to (re)start one download.
///
/// Persisted, because the partial file on disk outlives the app process: if
/// Android kills Innocent mid-download, the bytes are still there and the only
/// thing missing is the recipe for continuing. Storing it turns "your download
/// vanished" into a Resume button.
@immutable
class DownloadSpec {
  const DownloadSpec({
    required this.id,
    required this.url,
    required this.selector,
    required this.dir,
    required this.title,
    this.audioOnly = false,
    this.toMp3 = false,
    this.merge = false,
    this.isPhotoSet = false,
    this.sourceUrl,
  });

  final String id;
  final String url;
  final String selector;
  final String dir;
  final String title;
  final bool audioOnly;
  final bool toMp3;
  final bool merge;

  /// The PAGE this came from, not the media address it was fetched with.
  ///
  /// These are almost never the same thing: a video found in the browser is
  /// downloaded from a content-delivery host, while the page somebody was
  /// actually looking at lives on the site. Keeping only the media address
  /// means a finished download can never be traced back to where it came from
  /// — and "open the video I got this from" is the one thing a person wants
  /// from a history list. Null for a pasted link, where the two ARE the same.
  final String? sourceUrl;

  /// A TikTok photo set: fetched by us rather than by yt-dlp, all-or-nothing
  /// per picture, and therefore neither resumable nor replayable.
  final bool isPhotoSet;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'url': url,
        'selector': selector,
        'dir': dir,
        'title': title,
        'audioOnly': audioOnly,
        'toMp3': toMp3,
        'merge': merge,
        'isPhotoSet': isPhotoSet,
        // WRITTEN AT LAST. This field has existed since v1.22.0 and was
        // never persisted, so it survived exactly until the app was
        // restarted or a download was resumed -- and then came back null.
        // A bug that only appears after a restart is one that passes every
        // test and fails every user.
        'sourceUrl': sourceUrl,
      };

  static DownloadSpec? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? url = raw['url'];
    final Object? selector = raw['selector'];
    final Object? dir = raw['dir'];
    if (id is! String || url is! String || selector is! String || dir is! String) {
      return null;
    }
    return DownloadSpec(
      id: id,
      url: url,
      selector: selector,
      dir: dir,
      title: raw['title'] is String ? raw['title'] as String : '',
      audioOnly: raw['audioOnly'] == true,
      toMp3: raw['toMp3'] == true,
      merge: raw['merge'] == true,
      isPhotoSet: raw['isPhotoSet'] == true,
      sourceUrl:
          raw['sourceUrl'] is String && (raw['sourceUrl'] as String).isNotEmpty
              ? raw['sourceUrl'] as String
              : null,
    );
  }
}

/// One row in the downloads list.
@immutable
class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.title,
    required this.phase,
    this.spec,
    this.progress = 0,
    this.etaSeconds,
    this.line,
    this.path,
    this.error,
    this.stats,
    this.attempt = 0,
  });

  final String id;
  final String title;
  final DownloadPhase phase;
  final DownloadSpec? spec;
  final int progress;
  final int? etaSeconds;
  final String? line;
  final String? path;
  final String? error;

  /// Size, speed and time remaining read out of the engine's output.
  final DownloadProgress? stats;

  /// Which automatic reconnect attempt we are on, 0 when none.
  final int attempt;

  bool get isRunning =>
      phase == DownloadPhase.queued ||
      phase == DownloadPhase.preparing ||
      phase == DownloadPhase.progress ||
      phase == DownloadPhase.retrying;

  bool get isPaused => phase == DownloadPhase.paused;

  /// True for a TikTok photo set, which behaves differently everywhere.
  bool get isPhotoSet => spec?.isPhotoSet ?? false;

  /// Resumable while we still hold a recipe the engine can actually replay.
  bool get canResume =>
      spec != null && !spec!.isPhotoSet && (isPaused || phase == DownloadPhase.error);

  int? get totalBytes => stats?.totalBytes;

  /// Bytes fetched so far, derived rather than reported — yt-dlp gives a
  /// percentage and a total, not a running count.
  int? get downloadedBytes {
    final int? total = totalBytes;
    if (total == null || total <= 0) return null;
    return (total * (progress.clamp(0, 100) / 100)).round();
  }

  DownloadTask applyEvent(DownloadEvent e) {
    // A terminal event doesn't repeat the title or the numbers; keep ours.
    final DownloadProgress? nextStats = e.line == null
        ? stats
        : (parseProgressLine(e.line!)?.mergeOnto(stats) ?? stats);
    final int nextProgress;
    if (e.phase == DownloadPhase.done) {
      nextProgress = 100;
    } else if (e.phase == DownloadPhase.progress) {
      // The engine's percentage can sit at 0 when an external downloader owns
      // the transfer; the parsed line is the better source when it has one.
      final double? parsed = nextStats?.percent;
      nextProgress = e.progress > 0
          ? e.progress
          : (parsed != null ? parsed.round().clamp(0, 100) : progress);
    } else {
      nextProgress = progress;
    }
    return DownloadTask(
      id: id,
      title: (e.title != null && e.title!.isNotEmpty) ? e.title! : title,
      phase: e.phase,
      spec: spec,
      progress: nextProgress,
      etaSeconds: nextStats?.etaSeconds ?? e.etaSeconds ?? etaSeconds,
      line: e.line ?? line,
      path: e.path ?? path,
      error: e.error,
      stats: nextStats,
      attempt: e.phase == DownloadPhase.retrying ? attempt + 1 : attempt,
    );
  }
}

/// Live view of the download queue, driven by the native event stream.
///
/// Finished rows stay in the list (so the user sees "Saved" and can tap to
/// play) until they dismiss them. Unfinished rows are persisted with their
/// spec so a killed app process leaves a Resume button rather than a hole.
class DownloadQueueNotifier extends StateNotifier<List<DownloadTask>> {
  DownloadQueueNotifier(this._ref) : super(const <DownloadTask>[]) {
    _restore();
    _sub = DownloaderEngineService.instance.events.listen(
      _onEvent,
      // A stream error must not kill the subscription: without this a single
      // malformed platform message would silently stop every future progress
      // update for the rest of the app's life.
      onError: (Object _) {},
      cancelOnError: false,
    );
    // THE BROWSER'S PICKS LAND HERE, NOT ON A SCREEN.
    //
    // This notifier lives for as long as the app does, which is exactly what
    // the in-app browser needs: somebody choosing a quality over a page is
    // doing it while the downloads screen is in the background and may not
    // even be built. Listening from a widget would mean the choice quietly
    // going nowhere depending on what the person happened to open first.
    _pickSub = DownloaderEngineService.instance.browserPicks.listen(
      _onBrowserPick,
      onError: (Object _) {},
      cancelOnError: false,
    );
    // AND ITS QUESTIONS LAND HERE TOO, for the same reason and in the same
    // place. The browser asks to have a page read; this notifier is the only
    // thing that is certain to be alive to answer, and it already holds the
    // cookies and client settings the read needs.
    DownloaderEngineService.onBrowserProbeRequest = _onBrowserProbeRequest;
    // The shade's Resume button lands here for the same reason: this notifier
    // outlives every screen, and the spec a resume needs lives in it.
    DownloaderEngineService.onResumeRequest = resume;
  }

  /// Reads a page the in-app browser is looking at, and hands back rows.
  ///
  /// Routed through the SHARED pipeline rather than a second sequence, which
  /// is the entire point: the sheet drawn over a web page is then built from
  /// the same parse — the same collapsing, the same ordering, the same
  /// `<id>+bestaudio` selector — as the sheet a pasted link gets. A YouTube
  /// video downloaded from the browser had no sound because that was NOT true.
  void _onBrowserProbeRequest(int reqId, String url) {
    unawaited(ProbePipeline.answerBrowser(
      reqId: reqId,
      url: url,
      cookies: _ref.read(cookiesPathProvider),
      clients: _ref.read(playerClientsProvider),
    ));
  }

  final Ref _ref;
  StreamSubscription<DownloadEvent>? _sub;
  StreamSubscription<BrowserPick>? _pickSub;

  /// Starts a download chosen in the in-app browser.
  ///
  /// Deliberately routed through exactly the same spec-register-start sequence
  /// the quality sheet uses. The browser supplies only what it can know — the
  /// address, the chosen format, the title — and everything else is answered
  /// here, once: where files go, which cookies apply, which extras are set. A
  /// second place answering those questions is a second place to get them
  /// wrong, and the person would never know which one had.
  Future<void> _onBrowserPick(BrowserPick pick) async {
    try {
      final String dir = _ref.read(downloadDirProvider);
      final String id = DateTime.now().microsecondsSinceEpoch.toString();
      final DownloadSpec spec = DownloadSpec(
        id: id,
        url: pick.url,
        selector: pick.selector,
        dir: dir,
        title: pick.title,
        audioOnly: false,
        toMp3: false,
        merge: pick.merge,
        sourceUrl: pick.sourceUrl,
      );
      register(spec);
      DiagnosticsLog.instance.note(
        'tap',
        'browser pick — ${pick.selector}'
        '${pick.merge ? ' (needs muxing)' : ''}'
        '${pick.rawFormats > 0 ? ' · engine sent ${pick.rawFormats}, offered ${pick.offered}' : ''}',
        url: pick.url,
      );
      await DownloaderEngineService.instance.startDownload(
        id: spec.id,
        url: spec.url,
        selector: spec.selector,
        dir: spec.dir,
        title: spec.title,
        audioOnly: spec.audioOnly,
        toMp3: spec.toMp3,
        merge: spec.merge,
        cookies: _ref.read(cookiesPathProvider),
        clients: _ref.read(playerClientsProvider),
      );
    } catch (e) {
      // The browser is in front and cannot show this, so it goes where every
      // other failure goes rather than vanishing.
      DiagnosticsLog.instance.add('download', 'browser pick failed: $e');
    }
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? raw = sp.getString(_kQueueKey);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final List<DownloadTask> restored = <DownloadTask>[];
      for (final Object? entry in decoded) {
        final DownloadSpec? spec = DownloadSpec.fromJson(entry);
        if (spec == null) continue;
        restored.add(DownloadTask(
          id: spec.id,
          title: spec.title,
          // Interrupted, not running: the process died with the app.
          phase: DownloadPhase.paused,
          spec: spec,
        ));
      }
      if (restored.isEmpty || !mounted) return;
      // Anything the engine has already told us about this session wins.
      final Set<String> known = state.map((DownloadTask t) => t.id).toSet();
      state = <DownloadTask>[
        ...state,
        ...restored.where((DownloadTask t) => !known.contains(t.id)),
      ];
    } catch (_) {
      // A corrupt record is not worth failing the screen over.
    }
  }

  Future<void> _persist() async {
    try {
      final List<Map<String, Object?>> specs = state
          .where((DownloadTask t) =>
              t.spec != null &&
              !t.spec!.isPhotoSet &&
              (t.isRunning || t.isPaused))
          .map((DownloadTask t) => t.spec!.toJson())
          .toList();
      final SharedPreferences sp = await SharedPreferences.getInstance();
      if (specs.isEmpty) {
        await sp.remove(_kQueueKey);
      } else {
        await sp.setString(_kQueueKey, jsonEncode(specs));
      }
    } catch (_) {}
  }

  void _onEvent(DownloadEvent e) {
    if (!mounted) return;
    // A FAILED DOWNLOAD LEFT NO TRACE. The report kept saying "no faults"
    // while a download plainly was not working, because the trail only ever
    // heard about reads — downloads reported to the queue and nowhere else.
    // That is the same blindness the reads had before they were instrumented,
    // and it cost exactly as much: a person saying "it does not download" and
    // no way to tell them why.
    if (e.phase == DownloadPhase.error) {
      DiagnosticsLog.instance.add(
        'download',
        e.error?.trim().isNotEmpty == true
            ? e.error!.trim()
            : (e.line?.trim().isNotEmpty == true
                ? e.line!.trim()
                : 'failed with no message'),
      );
    } else if (e.phase == DownloadPhase.done) {
      DiagnosticsLog.instance.note('download', 'finished');
    }
    final List<DownloadTask> next = List<DownloadTask>.of(state);
    final int index = next.indexWhere((DownloadTask t) => t.id == e.id);
    if (index >= 0) {
      next[index] = next[index].applyEvent(e);
    } else {
      next.insert(
        0,
        DownloadTask(
          id: e.id,
          title: e.title ?? '',
          phase: e.phase,
          progress: e.progress,
          etaSeconds: e.etaSeconds,
          line: e.line,
          path: e.path,
          error: e.error,
        ),
      );
    }
    state = next;
    if (e.isTerminal || e.phase == DownloadPhase.paused) _persist();

    // Recorded HERE, in the notifier, not in DownloadTask.applyEvent. That is
    // where this went first, and it could not compile: `state` and `_ref`
    // belong to the notifier, and a task knows nothing about either. The
    // notifier is also the right place on the merits — it is the only thing
    // that sees a completion at all, since the screen that started the
    // download may be long gone by the time it finishes.
    if (e.phase == DownloadPhase.done) {
      final String? finishedPath = e.path;
      if (finishedPath != null && finishedPath.isNotEmpty) {
        // A plain loop rather than firstOrNull: that extension comes from
        // package:collection, not dart:core, and using it without the import
        // is an error that only shows up at build time.
        DownloadTask? done;
        for (final DownloadTask t in next) {
          if (t.id == e.id) {
            done = t;
            break;
          }
        }
        _ref.read(downloadHistoryProvider.notifier).add(DownloadRecord(
              id: e.id,
              title: (done != null && done.title.isNotEmpty)
                  ? done.title
                  : finishedPath.split('/').last,
              path: finishedPath,
              at: DateTime.now(),
              // The page's host, not the delivery host: `pornhub.com` is
              // what somebody recognises, `phncdn.com` is what a row said
              // before.
              host: Uri.tryParse(
                      done?.spec?.sourceUrl ?? done?.spec?.url ?? '')
                  ?.host,
              // Falls back to the media address on purpose. For a pasted
              // link the two ARE the same thing, and a row that reopens at
              // the file's own address beats one that cannot reopen at all.
              sourceUrl: done?.spec?.sourceUrl ?? done?.spec?.url,
              sizeBytes: done?.totalBytes,
            ));
      }
    }
  }

  /// Registers a job locally the moment the user taps Download, so the row
  /// appears immediately instead of waiting for the first platform event.
  void register(DownloadSpec spec) {
    if (!mounted) return;
    if (state.any((DownloadTask t) => t.id == spec.id)) return;
    state = <DownloadTask>[
      DownloadTask(
        id: spec.id,
        title: spec.title,
        phase: DownloadPhase.queued,
        spec: spec,
      ),
      ...state,
    ];
    _persist();
  }

  Future<void> pause(String id) => DownloaderEngineService.instance.pause(id);

  /// Resume prefers the engine's own record; if that is gone (the app process
  /// was killed and restarted) it replays our persisted spec, which continues
  /// from the partial file exactly the same way.
  Future<void> resume(String id) async {
    final int index = state.indexWhere((DownloadTask t) => t.id == id);
    if (index < 0) return;
    final DownloadTask task = state[index];
    try {
      await DownloaderEngineService.instance.resume(id);
      return;
    } catch (_) {
      // Fall through to replaying the spec.
    }
    final DownloadSpec? spec = task.spec;
    if (spec == null) return;
    try {
      await DownloaderEngineService.instance.startDownload(
        id: spec.id,
        url: spec.url,
        selector: spec.selector,
        dir: spec.dir,
        title: spec.title,
        audioOnly: spec.audioOnly,
        toMp3: spec.toMp3,
        merge: spec.merge,
      );
    } catch (_) {}
  }

  Future<void> cancel(String id) async {
    await DownloaderEngineService.instance.cancel(id);
    _persist();
  }

  void dismiss(String id) {
    if (!mounted) return;
    state = state.where((DownloadTask t) => t.id != id).toList();
    _persist();
  }

  void clearFinished() {
    if (!mounted) return;
    state = state.where((DownloadTask t) => t.isRunning || t.isPaused).toList();
    _persist();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pickSub?.cancel();
    _sub = null;
    super.dispose();
  }
}

final StateNotifierProvider<DownloadQueueNotifier, List<DownloadTask>>
    downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, List<DownloadTask>>(
  (ref) => DownloadQueueNotifier(ref),
);
