import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_crypto.dart';

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

  /// Whether this title needed an entitlement to download.
  ///
  /// ─── THE BUG THIS FIELD EXISTS TO FIX ────────────────────────────────
  ///
  /// The Downloads screen opened every item with `premium: true`, on the
  /// strength of a comment saying "nothing free is ever downloaded". That was
  /// simply not true: [AccessPolicy.canDownload] returns true for a FREE title
  /// whatever the viewer's tier, so the Download button is drawn for a free
  /// film on an anonymous account — and `playOffline` then asked for the
  /// premium capability and showed the paywall. The viewer spent an hour of
  /// mobile data on a film the app refused to open, and there was no way past
  /// it short of paying for something that was free.
  ///
  /// DEFAULTS TO TRUE FOR A ROW WRITTEN BEFORE THIS FIELD EXISTED. Every such
  /// row belongs to a premium subscriber (they were the only people the button
  /// was reliably drawn for), and treating an unknown row as premium keeps the
  /// capture protection and the entitlement re-check that it has today. The
  /// wrong default here would either strip protection from paid content or
  /// lock somebody out of their own download, and only one of those is
  /// recoverable by watching the film again online.
  final bool premium;

  /// Whether the file is ciphertext with a trailer rather than a plain MP4.
  ///
  /// RECORDED RATHER THAN SNIFFED, for two reasons that both cost a viewer
  /// their film when they are wrong. The file's own length has to be judged
  /// against something — a sealed film is thirty-two bytes longer than the
  /// object it came from — and without knowing which kind it is, the
  /// verification in [OfflineLibrary.items] would read every sealed film as a
  /// stale row and quietly record the wrong size. And a sealed film whose
  /// trailer has been lost is DAMAGE: the row saying it should be there is the
  /// only thing that can tell that apart from a plain MP4, which would
  /// otherwise be handed to the player and drawn as noise.
  ///
  /// FALSE FOR EVERY ROW WRITTEN BEFORE THIS FIELD EXISTED, which is correct
  /// rather than merely safe: they are all plain MP4s, because nothing had
  /// sealed anything yet.
  final bool sealed;

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
    this.premium = true,
    this.sealed = false,
  });

  /// The same entry with a corrected byte count.
  ///
  /// Used when the file on disk is longer than the row says, which means the
  /// row is stale rather than the film broken — see [OfflineLibrary.items].
  OfflineItem copyWithBytes(int newBytes) => OfflineItem(
        titleId: titleId,
        title: title,
        path: path,
        bytes: newBytes,
        addedAt: addedAt,
        titleMm: titleMm,
        posterUrl: posterUrl,
        durationS: durationS,
        assetId: assetId,
        premium: premium,
        sealed: sealed,
      );

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
        'premium': premium,
        'sealed': sealed,
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
      // Absent means a row written before the field existed — see the note on
      // [premium] for why the unknown case is the protected one.
      premium: m['premium'] as bool? ?? true,
      sealed: m['sealed'] as bool? ?? false,
    );
  }
}

/// A download that was started and has not finished.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS HAD TO BE WRITTEN DOWN BEFORE THE FIRST BYTE
/// ═══════════════════════════════════════════════════════════════════════
///
/// The shelf only learned a title's name when its download FINISHED — which
/// is precisely the case where the name is not needed. An interrupted
/// download left a `.part` file named by a uuid and nothing else: the
/// Downloads screen showed an empty shelf, the bytes were invisible and
/// undeletable through the UI, and the only way to carry on was to remember
/// which title it had been and find it in the catalogue again.
///
/// On the connection this whole feature exists for — Myanmar mobile data, a
/// film that takes an hour or two — a download being interrupted is not the
/// unusual case. It is most of them. So the row is written when the download
/// starts, carries enough to draw itself with no network, and is removed when
/// the download finishes or the viewer throws it away.
@immutable
class PendingDownload {
  final String titleId;
  final String title;
  final String? titleMm;
  final String? posterUrl;
  final String? assetId;
  final DateTime startedAt;

  /// Whether this title needed an entitlement — see [OfflineItem.premium].
  /// Carried here as well so a sign-out can throw away a half-finished PAID
  /// download without touching a half-finished free one.
  final bool premium;

  /// True when the VIEWER stopped this, rather than the network or the app.
  ///
  /// ─── THE WHOLE BASIS OF AUTOMATIC RESUMING ───────────────────────────
  ///
  /// A download that was interrupted should carry on by itself: the viewer
  /// asked for it, agreed to its size, and nothing since then was their
  /// decision. A download they PAUSED must not, and resuming it would be the
  /// app overruling them and spending their data to do it. Chrome draws the
  /// line in exactly this place, and it is the only line that can be drawn
  /// honestly — "interrupted" and "paused" look identical on disk.
  final bool pausedByUser;

  const PendingDownload({
    required this.titleId,
    required this.title,
    required this.startedAt,
    this.titleMm,
    this.posterUrl,
    this.assetId,
    this.premium = true,
    this.pausedByUser = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'titleId': titleId,
        'title': title,
        if (titleMm != null) 'titleMm': titleMm,
        if (posterUrl != null) 'posterUrl': posterUrl,
        if (assetId != null) 'assetId': assetId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'premium': premium,
        'pausedByUser': pausedByUser,
      };

  static PendingDownload? fromJson(Map<String, dynamic> m) {
    final id = '${m['titleId'] ?? ''}';
    if (id.isEmpty) return null;
    return PendingDownload(
      titleId: id,
      title: '${m['title'] ?? ''}',
      titleMm: m['titleMm'] as String?,
      posterUrl: m['posterUrl'] as String?,
      assetId: m['assetId'] as String?,
      startedAt:
          DateTime.tryParse('${m['startedAt']}')?.toLocal() ?? DateTime.now(),
      premium: m['premium'] as bool? ?? true,
      // Absent reads as NOT paused, so a row written before this field existed
      // is eligible to carry on. That is the right default: those rows were all
      // left behind by an interruption, because there was no way to pause one.
      pausedByUser: m['pausedByUser'] as bool? ?? false,
    );
  }
}

/// A pending row plus what is actually on disk for it right now.
@immutable
class PendingProgress {
  final PendingDownload item;

  /// Bytes in the `.part` file.
  final int received;

  /// The object length, when a previous attempt got as far as learning it.
  final int? total;

  const PendingProgress({
    required this.item,
    required this.received,
    this.total,
  });

  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    // `.toDouble()` written out rather than relied on: `clamp` is declared on
    // `num`, and a `num` where a `double` is wanted is a compile error the
    // first reader of this file will not expect.
    return (received / t).clamp(0.0, 1.0).toDouble();
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
    final rows = await _rows();
    final out = <OfflineItem>[];
    var changed = false;
    for (final row in rows) {
      var item = row;
      final f = File(item.path);
      if (!await f.exists()) {
        changed = true;
        continue;
      }
      // AND THE LENGTH IS CHECKED, not only the existence — but the two
      // directions of a mismatch mean opposite things and only one of them is
      // damage.
      //
      // SHORTER THAN RECORDED is a film that stops in the middle. "Downloaded"
      // is a promise the app makes OFFLINE, where it cannot go back and look,
      // and the viewer finds out on a bus with no signal having done nothing
      // wrong. The row goes and the file with it: a truncated film is not
      // worth a gigabyte, and leaving it after removing the only reference to
      // it is a gigabyte nothing in the app can ever reclaim.
      //
      // LONGER THAN RECORDED IS A STALE ROW, NOT A BROKEN FILE, and treating
      // it as damage deleted a perfectly good download. A re-download writes
      // `<id>.mp4.part` and renames it over `<id>.mp4`, so between the rename
      // and the index write the file is the NEW one and the row still
      // describes the old — which is exactly the moment `put` reads the index.
      // The first version of this check deleted the film that had just
      // finished downloading. (`put` now reads the raw rows so it cannot
      // trigger this at all; the row is corrected here as well, because
      // self-healing beats being right only about the order of two writes.)
      if (item.bytes > 0) {
        int onDisk;
        try {
          onDisk = await f.length();
        } catch (_) {
          changed = true;
          continue;
        }
        // AGAINST THE LENGTH THE FILE SHOULD BE, which for a sealed film is the
        // object's length plus its trailer. `bytes` stays the length of the
        // ORIGINAL throughout — it is what the viewer paid data for and what
        // the shelf shows — so the trailer is added here rather than being
        // folded into the row.
        final expected =
            OfflineCrypto.fileLengthFor(item.bytes, sealed: item.sealed);
        if (onDisk < expected) {
          if (kDebugMode) {
            debugPrint('offline entry truncated: ${item.titleId} '
                '$onDisk < $expected');
          }
          try {
            await f.delete();
          } catch (_) {}
          changed = true;
          continue;
        }
        if (onDisk > expected) {
          if (kDebugMode) {
            debugPrint('offline row stale: ${item.titleId} '
                '$onDisk > $expected — correcting');
          }
          item = item.copyWithBytes(onDisk - (expected - item.bytes));
          changed = true;
        }
      }
      out.add(item);
    }
    out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (changed) await _write(out);
    return out;
  }

  /// The stored rows, exactly as written, with NO filesystem check.
  ///
  /// SEPARATE FROM [items] BECAUSE VERIFYING IS DESTRUCTIVE. [items] deletes a
  /// truncated file, and a write path that read the shelf through it would run
  /// that judgement against a file it is in the middle of replacing — which is
  /// how the first version of the length check deleted a download at the
  /// instant it finished. Anything that is about to WRITE the index reads the
  /// rows; anything that is about to SHOW it reads [items].
  Future<List<OfflineItem>> _rows() async {
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
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final item = OfflineItem.fromJson(entry.cast<String, dynamic>());
      if (item != null) out.add(item);
    }
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
    final current = await _rows();
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
    // The RAW row, not the verified one: deleting a download must work whether
    // or not the file passes verification, and going through [items] would
    // make a delete depend on a judgement about damage.
    OfflineItem? item;
    for (final row in await _rows()) {
      if (row.titleId == titleId) item = row;
    }
    if (item != null) {
      try {
        final f = File(item.path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        if (kDebugMode) debugPrint('offline delete failed: $e');
      }
    }
    final next = <OfflineItem>[
      for (final o in await _rows())
        if (o.titleId != titleId) o,
    ];
    await _write(next);
  }

  /// Empties the shelf of everything the ACCOUNT paid for, and keeps the rest.
  ///
  /// ─── WHY THIS IS NOT [dropAll] ───────────────────────────────────────
  ///
  /// Signing out used to delete every download, free ones included. A free
  /// title needs no account to watch and no entitlement to download — that is
  /// what free means — so deleting it on sign-out enforced nothing and cost
  /// somebody an hour of mobile data they had already spent. On a metered
  /// Myanmar connection that is real money, taken for a rule that does not
  /// exist.
  ///
  /// What premium downloads keep is the promise worth keeping: a lapsed or
  /// abandoned subscription should not leave a paid library behind. That is
  /// still a promise about this app's behaviour rather than about the bytes —
  /// see the class note.
  ///
  /// Orphan files are swept as well, but only files nothing kept refers to, so
  /// a free download is never collected as litter.
  Future<void> dropEntitled() async {
    final keep = <OfflineItem>[];
    final keepPaths = <String>{};
    for (final item in await _rows()) {
      if (item.premium) {
        try {
          final f = File(item.path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
        continue;
      }
      keep.add(item);
      keepPaths.add(item.path);
    }
    // Pending downloads of premium titles go too, and their size notes with
    // them. A free one stays resumable, which is the same rule as above.
    final keptPending = <PendingDownload>[];
    try {
      final dir = await directory();
      for (final row in await _pendingRows()) {
        final part = File('${dir.path}/${row.titleId}.mp4$partSuffix');
        if (row.premium) {
          try {
            if (await part.exists()) await part.delete();
            final note = File('${part.path}.total');
            if (await note.exists()) await note.delete();
            final iv = File('${part.path}.iv');
            if (await iv.exists()) await iv.delete();
          } catch (_) {}
          continue;
        }
        keptPending.add(row);
        keepPaths.add(part.path);
        keepPaths.add('${part.path}.total');
        // AND THE IV, or the sweep below deletes the one thing that says which
        // keystream the bytes already on disk belong to — and a resume that
        // cannot read it starts the whole film again, on a metered connection.
        keepPaths.add('${part.path}.iv');
      }
      // Anything else in the folder is litter: a part file from a download
      // nothing recorded, or a file whose row has just gone.
      await for (final e in dir.list()) {
        if (e is File && !keepPaths.contains(e.path)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('offline entitled sweep failed: $e');
    }
    await _write(keep);
    await _writePending(keptPending);
  }

  /// Empties the shelf completely, free titles included.
  ///
  /// Kept for a full wipe — clearing app data, a factory reset of the feature.
  /// Sign-out uses [dropEntitled], which is the narrower and correct rule.
  ///
  /// Sweeps the DIRECTORY as well as the index, so a `.part` file from a
  /// download that was interrupted mid-flight goes too. Those are the entries
  /// no index ever knew about.
  Future<void> dropAll() async {
    for (final item in await _rows()) {
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
    // The pending index describes files the sweep above has just deleted.
    // Leaving it would fill the Downloads screen with rows that resume
    // nothing.
    await (await _store).remove(_pendingKey);
  }

  // ─── UNFINISHED DOWNLOADS ──────────────────────────────────────────────

  static const String _pendingKey = 'vh_offline_pending';

  /// Record that a download has begun. Replaces any earlier row for the title.
  Future<void> putPending(PendingDownload item) async {
    final next = <PendingDownload>[
      item,
      for (final o in await _pendingRows())
        if (o.titleId != item.titleId) o,
    ];
    await _writePending(next);
  }

  /// Record that the VIEWER stopped this download, so nothing resumes it for
  /// them. See [PendingDownload.pausedByUser].
  ///
  /// A no-op when there is no row: a cancel that arrives after the download
  /// finished has nothing to mark, and inventing a row for it would put a
  /// finished film in the unfinished list.
  Future<void> markPaused(String titleId) async {
    final rows = await _pendingRows();
    var found = false;
    final next = <PendingDownload>[];
    for (final row in rows) {
      if (row.titleId == titleId) {
        found = true;
        next.add(PendingDownload(
          titleId: row.titleId,
          title: row.title,
          startedAt: row.startedAt,
          titleMm: row.titleMm,
          posterUrl: row.posterUrl,
          assetId: row.assetId,
          premium: row.premium,
          pausedByUser: true,
        ));
      } else {
        next.add(row);
      }
    }
    if (found) await _writePending(next);
  }

  /// Forget a pending row WITHOUT touching the part file.
  ///
  /// Called when a download finishes: the file has already been renamed and
  /// the shelf entry written, so the row has nothing left to describe.
  Future<void> dropPending(String titleId) async {
    final next = <PendingDownload>[
      for (final o in await _pendingRows())
        if (o.titleId != titleId) o,
    ];
    await _writePending(next);
  }

  /// Throw away an unfinished download: the part file, its size note, and the
  /// row. The order is file first, as in [drop], so nothing is left occupying
  /// a gigabyte with no way to reach it.
  Future<void> discardPending(String titleId) async {
    try {
      final dir = await directory();
      final part = File('${dir.path}/$titleId.mp4$partSuffix');
      if (await part.exists()) await part.delete();
      final note = File('${part.path}.total');
      if (await note.exists()) await note.delete();
      final iv = File('${part.path}.iv');
      if (await iv.exists()) await iv.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('offline discard failed: $e');
    }
    await dropPending(titleId);
  }

  /// Unfinished downloads, newest first, each with what is on disk for it.
  ///
  /// A row whose part file has vanished — Android reclaiming app-private
  /// storage, or a finished download whose row was not cleaned up — is dropped
  /// rather than shown, for the same reason [items] verifies against the
  /// filesystem: a row that cannot be resumed is a row that spins forever.
  Future<List<PendingProgress>> pending() async {
    final dir = await directory();
    final out = <PendingProgress>[];
    var pruned = false;
    for (final row in await _pendingRows()) {
      // PRUNED ONLY WHEN IT PROVABLY FINISHED. The first version dropped any
      // row whose part file was missing — which is every row for the first few
      // seconds of its own download, because `putPending` is written before
      // the first byte. Opening this screen at that moment deleted the record
      // of a live download, and if the app was then killed the part file went
      // back to being an anonymous uuid. A row with nothing behind it is
      // dropped by the downloader itself when it ends with no bytes written,
      // which is precise where a filesystem guess is not.
      final finished = File('${dir.path}/${row.titleId}.mp4');
      if (await finished.exists()) {
        pruned = true;
        continue;
      }
      final part = File('${dir.path}/${row.titleId}.mp4$partSuffix');
      int received = 0;
      if (await part.exists()) {
        try {
          received = await part.length();
        } catch (_) {
          received = 0;
        }
      }
      int? total;
      try {
        final note = File('${part.path}.total');
        if (await note.exists()) {
          total = int.tryParse((await note.readAsString()).trim());
          if (total != null && total <= 0) total = null;
        }
      } catch (_) {
        total = null;
      }
      out.add(PendingProgress(item: row, received: received, total: total));
    }
    out.sort((a, b) => b.item.startedAt.compareTo(a.item.startedAt));
    if (pruned) {
      await _writePending(<PendingDownload>[for (final p in out) p.item]);
    }
    return out;
  }

  Future<List<PendingDownload>> _pendingRows() async {
    final raw = (await _store).getString(_pendingKey);
    if (raw == null || raw.isEmpty) return const <PendingDownload>[];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final out = <PendingDownload>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final row = PendingDownload.fromJson(e.cast<String, dynamic>());
        if (row != null) out.add(row);
      }
      return out;
    } catch (e) {
      if (kDebugMode) debugPrint('offline pending index unreadable: $e');
      return const <PendingDownload>[];
    }
  }

  Future<void> _writePending(List<PendingDownload> rows) async {
    await (await _store).setString(
      _pendingKey,
      jsonEncode(rows.map((r) => r.toJson()).toList()),
    );
  }

  /// Bytes on disk, for the line the Downloads screen shows.
  ///
  /// COUNTS UNFINISHED DOWNLOADS TOO. A part file occupies exactly as much of
  /// the viewer's phone as a finished one, and a "used" figure that leaves out
  /// the 700 MB of a film that stalled last night is not a figure about
  /// storage — it is a figure about the index.
  Future<int> totalBytes() async {
    var sum = 0;
    for (final item in await items()) {
      sum += item.bytes;
    }
    for (final p in await pending()) {
      sum += p.received;
    }
    return sum;
  }

  /// Free bytes on the volume holding the downloads folder, or -1 when the
  /// platform did not answer. Same channel the player's disk cache uses; a
  /// second implementation of this would be a second answer to one question.
  Future<int> freeBytes() async {
    try {
      final dir = await directory();
      final v = await const MethodChannel('mx_clone/media_scan')
          .invokeMethod<int>('freeBytes', <String, dynamic>{'dir': dir.path});
      return v ?? -1;
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineLibrary.freeBytes: $e');
      return -1;
    }
  }

  Future<void> _write(List<OfflineItem> items) async {
    await (await _store).setString(
      _key,
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }
}
