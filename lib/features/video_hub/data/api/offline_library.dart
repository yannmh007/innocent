import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One title kept on this device for offline viewing.
@immutable
class OfflineItem {
  /// The catalogue title. Also the key: one download per title.
  final String titleId;

  /// What to show in the list. Copied at download time rather than looked up,
  /// because the whole point is that this works with no network.
  final String title;
  final String? titleMm;

  /// The poster, as a URL. Left as a URL and not copied: the poster cache
  /// already holds the bytes from browsing, and a title whose artwork fails
  /// to draw offline is a cosmetic problem, not a broken download.
  final String? posterUrl;

  /// Absolute path of the finished file.
  final String path;

  final int bytes;
  final int? durationS;
  final DateTime addedAt;

  /// The album clip this is, when it is not the title's main film.
  final String? assetId;

  const OfflineItem({
    required this.titleId,
    required this.title,
    required this.path,
    required this.bytes,
    required this.addedAt,
    this.titleMm,
    this.posterUrl,
    this.durationS,
    this.assetId,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'titleId': titleId,
        'title': title,
        if (titleMm != null) 'titleMm': titleMm,
        if (posterUrl != null) 'posterUrl': posterUrl,
        'path': path,
        'bytes': bytes,
        if (durationS != null) 'durationS': durationS,
        'addedAt': addedAt.toUtc().toIso8601String(),
        if (assetId != null) 'assetId': assetId,
      };

  static OfflineItem? fromJson(Map<String, dynamic> m) {
    final id = '${m['titleId'] ?? ''}';
    final path = '${m['path'] ?? ''}';
    // A row with no id addresses nothing and a row with no path plays
    // nothing. Dropping beats keeping a shelf entry that cannot open.
    if (id.isEmpty || path.isEmpty) return null;
    return OfflineItem(
      titleId: id,
      title: '${m['title'] ?? ''}',
      titleMm: m['titleMm'] as String?,
      posterUrl: m['posterUrl'] as String?,
      path: path,
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      durationS: (m['durationS'] as num?)?.toInt(),
      addedAt: DateTime.tryParse('${m['addedAt']}')?.toLocal() ?? DateTime.now(),
      assetId: m['assetId'] as String?,
    );
  }
}

/// Where downloaded titles live, and what is on the shelf.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT THIS IS, SAID PLAINLY
/// ═══════════════════════════════════════════════════════════════════════
///
/// A downloaded file is a PLAIN FILE. It is in app-private storage, which
/// keeps it out of the gallery and out of other apps' reach on an unrooted
/// device — and that is the whole of the protection. A rooted phone, `adb
/// run-as` on a debuggable build, or a backup extraction gets the bytes.
///
/// This is decision B1(a), taken deliberately: plain files now, encryption at
/// rest as the upgrade path. The Private Folder vault in this app already
/// does Keystore-backed encryption, so the primitive exists and the work is a
/// custom data source in the player rather than new cryptography.
///
/// THE THING THAT MUST NOT HAPPEN is shipping (a) while describing it as (b).
/// A signed URL expires in ten minutes; a file on disk does not expire at
/// all. Downloading moves the bytes out of the protected path permanently,
/// and the only thing between a premium download and a file shared over
/// Bluetooth is that the app put it somewhere awkward. That is friction, not
/// enforcement, and it should be called friction.
///
/// What the app DOES enforce, because it can: the shelf is emptied when the
/// subscription lapses — see [dropAll]. That is a promise about this app's
/// behaviour, not about the bytes.
class OfflineLibrary {
  OfflineLibrary({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;

  static const String _key = 'vh_offline_index';

  /// Suffix for a download in progress.
  ///
  /// A partial file MUST NOT be named like a finished one. The index is what
  /// says a title is available, but a crash between the last byte and the
  /// index write would otherwise leave a full-length file the next version of
  /// this code might trust. `.part` makes an unfinished download obvious to
  /// every reader, including a human with a file browser.
  static const String partSuffix = '.part';

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// The folder downloads live in.
  ///
  /// Application SUPPORT, not Documents: on Android, Documents is included in
  /// auto-backup by default and a 900 MB film has no business in a Google
  /// Drive backup. Support is app-private and excluded.
  Future<Directory> directory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Everything on the shelf, newest first.
  ///
  /// VERIFIED AGAINST THE FILESYSTEM on every read, not trusted. Android
  /// deletes app-private files to reclaim space without telling the app, and
  /// an index entry whose file is gone is a row that spins forever when
  /// tapped. Checking costs one `stat` per item on a list of tens.
  Future<List<OfflineItem>> items() async {
    final raw = (await _store).getString(_key);
    if (raw == null || raw.isEmpty) return const <OfflineItem>[];

    List<dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } catch (e) {
      if (kDebugMode) debugPrint('offline index unreadable: $e');
      return const <OfflineItem>[];
    }

    final out = <OfflineItem>[];
    var pruned = false;
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final item = OfflineItem.fromJson(entry.cast<String, dynamic>());
      if (item == null) {
        pruned = true;
        continue;
      }
      if (!await File(item.path).exists()) {
        pruned = true;
        continue;
      }
      out.add(item);
    }
    out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (pruned) await _write(out);
    return out;
  }

  Future<OfflineItem?> find(String titleId) async {
    for (final item in await items()) {
      if (item.titleId == titleId) return item;
    }
    return null;
  }

  Future<bool> has(String titleId) async => (await find(titleId)) != null;

  /// Adds or replaces one entry.
  Future<void> put(OfflineItem item) async {
    final current = await items();
    final next = <OfflineItem>[
      item,
      for (final o in current)
        if (o.titleId != item.titleId) o,
    ];
    await _write(next);
  }

  /// Removes one title and its file.
  ///
  /// The FILE FIRST, then the index. The other order can leave a file nothing
  /// references — invisible, undeletable through the UI, and still occupying
  /// a gigabyte.
  Future<void> drop(String titleId) async {
    final item = await find(titleId);
    if (item != null) {
      try {
        final f = File(item.path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        if (kDebugMode) debugPrint('offline delete failed: $e');
      }
    }
    final next = <OfflineItem>[
      for (final o in await items())
        if (o.titleId != titleId) o,
    ];
    await _write(next);
  }

  /// Empties the shelf.
  ///
  /// CALLED WHEN THE SUBSCRIPTION LAPSES OR THE VIEWER SIGNS OUT, and it is
  /// the one enforcement this side can honestly make. It is a promise about
  /// what this app does, not about the bytes — see the class note.
  ///
  /// Sweeps the DIRECTORY as well as the index, so a `.part` file from a
  /// download that was interrupted mid-flight goes too. Those are the entries
  /// no index ever knew about.
  Future<void> dropAll() async {
    for (final item in await items()) {
      try {
        final f = File(item.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      final dir = await directory();
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('offline sweep failed: $e');
    }
    await (await _store).remove(_key);
  }

  /// Bytes on disk, for the line the Downloads screen shows.
  Future<int> totalBytes() async {
    var sum = 0;
    for (final item in await items()) {
      sum += item.bytes;
    }
    return sum;
  }

  Future<void> _write(List<OfflineItem> items) async {
    await (await _store).setString(
      _key,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }
}
