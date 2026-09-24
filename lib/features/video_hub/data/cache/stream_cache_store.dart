import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'range_set.dart';

/// What the phone has kept of the videos it has played.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY A CACHE AT ALL
/// ═══════════════════════════════════════════════════════════════════════
///
/// Bytes a viewer has already received are the cheapest bytes in the system:
/// they cost nothing to serve, they work with the phone in a lift, and they
/// are already paid for. Without a cache, dragging the bar back thirty
/// seconds re-downloads thirty seconds, and watching a clip twice downloads
/// it twice — over exactly the connections this whole project has spent
/// weeks apologising to.
///
/// It is affordable NOW in a way it was not last week. A camera clip at its
/// original bitrate was sixty megabits a second and keeping one was absurd.
/// The same clip at the rung a phone actually receives is 575 kilobits, so a
/// whole film is fifty megabytes. The ladder is what makes this sane.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE FILE LAYOUT IS THE SAFETY PROPERTY
/// ═══════════════════════════════════════════════════════════════════════
///
/// A cache that fills while it streams does not hold a neat prefix. Someone
/// watches four minutes, drags to the middle, watches two more. On disk that
/// is two islands with a hole between them, and the one thing this must
/// never do is serve the hole: unwritten bytes read back as zeros, which is
/// not an error and not a short read, so the player cannot tell.
///
/// The obvious shape — one sparse file plus a note saying which parts are
/// real — puts that guarantee in the note. A note can be stale: written
/// before a flush, or after a kill, or simply wrong. So there is no note.
/// EACH UNBROKEN RUN IS ITS OWN FILE, named for the offset it starts at, and
/// the run's length is the file's length. Nothing can claim bytes it does not
/// have, because the claim IS the file. A process killed mid-write leaves a
/// shorter file, which is exactly and automatically the truth about what it
/// holds.
///
/// It also removes a question this code should not have to answer: whether a
/// Dart file opened for appending honours `setPosition`. Writes here are only
/// ever appends to the end of a run, or the first bytes of a new one.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHERE IT LIVES, AND WHY NOT THE CACHE DIRECTORY
/// ═══════════════════════════════════════════════════════════════════════
///
/// Android's own cache directory is emptied by the system whenever storage
/// runs low, oldest first, without asking. Correct for thumbnails, wrong for
/// this: a viewer told "you already have this film" would find it gone
/// halfway through a rewatch, on exactly the cheap, nearly-full phones this
/// app is for.
///
/// So it lives in the app's support directory, where nothing deletes it but
/// this class — which makes the budget below the only thing between a viewer
/// and a full phone. That is the trade: we take responsibility for the space
/// in exchange for being able to promise that what we kept is still there.
///
/// IT IS EXCLUDED FROM BACKUP. `backup_rules.xml` and
/// `data_extraction_rules.xml` both name this directory. Without that, Auto
/// Backup would upload the catalogue to the viewer's Google Drive and the
/// new-phone transfer would clone it — premium video leaving the device by a
/// route nobody chose.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT IT IS NOT
/// ═══════════════════════════════════════════════════════════════════════
///
/// NOT ENCRYPTED, and that is stated rather than hidden. App-private storage
/// is unreadable by other apps and backup is closed off above, so the
/// realistic remaining reader is the phone's own rooted owner — who can
/// already screen-record. The downloaded-for-offline files this app has
/// shipped for months are plaintext on the same disk; encrypting the cache
/// while leaving those in the clear would be effort spent on the appearance
/// of a guarantee rather than the guarantee.
///
/// NOT A DOWNLOAD. It holds what was played and nothing more. A viewer who
/// wants a whole film offline uses the download button, which fetches the
/// parts nobody watched too.
class StreamCacheStore {
  StreamCacheStore._();
  static final StreamCacheStore instance = StreamCacheStore._();

  static const String _dirName = 'stream_cache';
  static const String _budgetKey = 'cache.stream_budget_bytes';

  /// The default ceiling.
  ///
  /// TWO GIGABYTES: around forty films at the rung most viewers receive, and
  /// a small fraction of the smallest phone this app targets. Telegram
  /// offers 5, 16 and 32 GB and defaults to unlimited; this defaults lower
  /// on purpose, because a viewer who has to go and find a setting to get
  /// their storage back has already been let down.
  static const int defaultBudget = 2 * 1024 * 1024 * 1024;

  /// Never fill the disk past this, whatever the budget says.
  ///
  /// The budget is what the viewer asked for; this is what the phone can
  /// stand. Android starts failing installs, updates and photo saves well
  /// before a disk is actually full, and none of those failures look like
  /// this app's fault to the person holding the phone.
  static const int freeFloor = 1024 * 1024 * 1024;

  Directory? _dir;
  final Map<String, CacheEntry> _entries = <String, CacheEntry>{};

  /// Entries with a writer open right now.
  ///
  /// ONE WRITER PER FILM, AND THIS IS NOT AN OPTIMISATION. A demuxer opens
  /// several connections at once, so two fetches can reach [openWriter] for
  /// the same film in the same instant. A brand-new run has length zero, so
  /// the overlap check below cannot see the other one coming — both would
  /// open the same path and append into it, interleaving two different
  /// stretches of film into one file. The second caller is refused and its
  /// bytes simply are not cached, which costs a re-download and never a
  /// corrupted video.
  final Set<String> _writing = <String>{};
  bool _loaded = false;
  int _budget = defaultBudget;

  Future<Directory> _root() async {
    final have = _dir;
    if (have != null) return have;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _dirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Read the index from disk. A few dozen directories at most, and the
  /// ranges come from the files' own lengths rather than from any record.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _root();
      try {
        final sp = await SharedPreferences.getInstance();
        _budget = sp.getInt(_budgetKey) ?? defaultBudget;
      } catch (_) {}

      await for (final d in dir.list()) {
        if (d is! Directory) continue;
        final e = await _readEntry(d);
        if (e != null) _entries[e.id] = e;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheStore.load: $e');
    }
  }

  Future<CacheEntry?> _readEntry(Directory d) async {
    try {
      final id = p.basename(d.path);
      var total = 0;
      var label = '';
      var used = DateTime.fromMillisecondsSinceEpoch(0);
      final meta = File(p.join(d.path, 'meta.json'));
      if (await meta.exists()) {
        final j = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
        total = (j['total'] as num?)?.toInt() ?? 0;
        label = (j['label'] as String?) ?? '';
        used = DateTime.fromMillisecondsSinceEpoch(
            (j['used'] as num?)?.toInt() ?? 0);
      }

      // THE PARTS ARE READ FROM THE FILES THEMSELVES. Their names give the
      // offsets and their lengths give the extents, so nothing here can
      // claim a byte that is not on disk — which is the whole reason for
      // this layout.
      final parts = <CachePart>[];
      await for (final f in d.list()) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        if (!name.startsWith('p') || !name.endsWith('.bin')) continue;
        final start = int.tryParse(name.substring(1, name.length - 4));
        if (start == null || start < 0) continue;
        final len = await f.length();
        if (len <= 0) {
          await f.delete();
          continue;
        }
        parts.add(CachePart(start: start, length: len, file: f));
      }
      if (parts.isEmpty && total <= 0) {
        await d.delete(recursive: true);
        return null;
      }
      parts.sort((a, b) => a.start.compareTo(b.start));
      return CacheEntry(
          id: id, total: total, label: label, usedAt: used, parts: parts);
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheStore._readEntry: $e');
      // A directory this cannot read is a directory this cannot serve.
      try {
        await d.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  int get budgetBytes => _budget;

  Future<void> setBudgetBytes(int bytes) async {
    _budget = bytes < 0 ? 0 : bytes;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_budgetKey, _budget);
    } catch (_) {}
    await enforceBudget();
  }

  /// Bytes actually held — the sum of the parts' lengths.
  int get usedBytes {
    var n = 0;
    for (final e in _entries.values) {
      n += e.heldBytes;
    }
    return n;
  }

  int get entryCount => _entries.length;

  /// Most recently played first, which is the order the storage screen wants.
  List<CacheEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.usedAt.compareTo(a.usedAt));
    return List<CacheEntry>.unmodifiable(list);
  }

  Future<CacheEntry> entryFor(String id, {int? total, String? label}) async {
    await load();
    final have = _entries[id];
    if (have != null) {
      if (total != null && total > 0 && have.total > 0 && have.total != total) {
        // THE OBJECT BEHIND THIS ID CHANGED LENGTH, so what is on disk is
        // some other file. Ids come from the object key and keys are never
        // reused here, so this should not happen — and if it does, the only
        // safe reading is that the cache is wrong.
        await remove(id);
      } else {
        if (total != null && total > 0) have.total = total;
        if (label != null && label.isNotEmpty) have.label = label;
        have.usedAt = DateTime.now();
        await _saveMeta(have);
        return have;
      }
    }
    final dir = Directory(p.join((await _root()).path, id));
    if (!await dir.exists()) await dir.create(recursive: true);
    final e = CacheEntry(
      id: id,
      total: total ?? 0,
      label: label ?? '',
      usedAt: DateTime.now(),
      parts: <CachePart>[],
    );
    _entries[id] = e;
    await _saveMeta(e);
    return e;
  }

  Future<Directory> entryDir(String id) async =>
      Directory(p.join((await _root()).path, id));

  /// Open the run that ends exactly at [at] for appending, or start a new
  /// one there. Returns null when there is no room to write.
  ///
  /// APPEND-ONLY BY CONSTRUCTION. A write either extends a run at its end or
  /// begins a run of its own, so the file's length is always exactly what it
  /// holds, and no record has to be kept in step with it.
  Future<CacheWriter?> openWriter(CacheEntry e, int at) async {
    if (_writing.contains(e.id)) return null;
    try {
      final dir = await entryDir(e.id);
      if (!await dir.exists()) await dir.create(recursive: true);
      for (final part in e.parts) {
        if (part.start + part.length == at) {
          // THE CLAIM IS TAKEN AFTER THE HANDLE IS OPEN, never before. An
          // open that throws between the two would leave a claim nothing
          // ever releases, and this film would be uncacheable for the rest
          // of the session with no way to tell why.
          final handle = await part.file.open(mode: FileMode.writeOnlyAppend);
          _writing.add(e.id);
          return CacheWriter(
            entry: e,
            part: part,
            handle: handle,
            onClose: () => _closed(e, part),
          );
        }
      }
      // A run that starts inside one we already hold would duplicate bytes
      // and confuse the reader about which file owns an offset.
      for (final part in e.parts) {
        if (part.start <= at && at < part.start + part.length) return null;
      }
      final f = File(p.join(dir.path, 'p$at.bin'));
      final part = CachePart(start: at, length: 0, file: f);
      e.parts.add(part);
      e.parts.sort((a, b) => a.start.compareTo(b.start));
      // `writeOnly` truncates, which is right for a path that does not exist
      // yet and would be catastrophic for one that does — hence the two
      // checks above, which between them prove this is a new run.
      final handle = await f.open(mode: FileMode.writeOnly);
      _writing.add(e.id);
      return CacheWriter(
        entry: e,
        part: part,
        handle: handle,
        onClose: () => _closed(e, part),
      );
    } catch (err) {
      if (kDebugMode) debugPrint('StreamCacheStore.openWriter: $err');
      return null;
    }
  }

  /// A run that never received a byte is a file that will be read as the
  /// start of something and is not. Removed rather than left at zero length,
  /// where the next `openWriter` would see a run at that offset and refuse
  /// to start one.
  void _closed(CacheEntry e, CachePart part) {
    _writing.remove(e.id);
    if (part.length > 0) return;
    e.parts.remove(part);
    // Best effort and unawaited: the load path deletes zero-length files
    // anyway, so a failure here costs nothing but an empty file until the
    // next start-up.
    unawaited(part.file.delete().then<void>((_) {}, onError: (Object _) {}));
  }

  Future<void> touch(CacheEntry e) async {
    e.usedAt = DateTime.now();
    await _saveMeta(e);
  }

  Future<void> _saveMeta(CacheEntry e) async {
    try {
      final dir = await entryDir(e.id);
      if (!await dir.exists()) await dir.create(recursive: true);
      // Written to a temporary name and renamed. Only the total, the label
      // and the last-played time live here — never the extents, which are
      // the files themselves — so a metadata file lost to a kill costs a
      // sort order, not a corrupted film.
      final tmp = File(p.join(dir.path, 'meta.json.tmp'));
      await tmp.writeAsString(
          jsonEncode(<String, dynamic>{
            'v': 1,
            'total': e.total,
            'label': e.label,
            'used': e.usedAt.millisecondsSinceEpoch,
          }),
          flush: true);
      await tmp.rename(p.join(dir.path, 'meta.json'));
    } catch (err) {
      if (kDebugMode) debugPrint('StreamCacheStore._saveMeta: $err');
    }
  }

  Future<void> remove(String id) async {
    _entries.remove(id);
    try {
      final dir = await entryDir(id);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheStore.remove: $e');
    }
  }

  Future<void> clear() async {
    final ids = _entries.keys.toList();
    for (final id in ids) {
      await remove(id);
    }
  }

  /// Delete least-recently-played entries until the cache is inside both the
  /// viewer's budget and the phone's free space.
  ///
  /// [protecting] is the entry being played. Evicting that would delete the
  /// files underneath an open read — the one way a storage policy turns into
  /// a playback failure.
  Future<void> enforceBudget({String? protecting}) async {
    await load();
    try {
      var used = usedBytes;
      var free = await freeBytes();

      bool over() => used > _budget || (free >= 0 && free < freeFloor);
      if (!over()) return;

      final byAge = _entries.values.toList()
        ..sort((a, b) => a.usedAt.compareTo(b.usedAt));
      for (final e in byAge) {
        if (!over()) break;
        if (e.id == protecting) continue;
        final freed = e.heldBytes;
        await remove(e.id);
        used -= freed;
        if (free >= 0) free += freed;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheStore.enforceBudget: $e');
    }
  }

  /// True when there is room to write more.
  ///
  /// Asked before each run rather than once at the start: a film is written
  /// over an hour, and the phone's free space in that hour is not this app's
  /// to assume.
  Future<bool> hasRoom({String? protecting}) async {
    await enforceBudget(protecting: protecting);
    if (usedBytes >= _budget) return false;
    final free = await freeBytes();
    // A failed measurement is not permission.
    if (free < 0 || free < freeFloor) return false;
    return true;
  }

  Future<int> freeBytes() async {
    try {
      final dir = await _root();
      final v = await const MethodChannel('mx_clone/media_scan')
          .invokeMethod<int>('freeBytes', <String, dynamic>{'dir': dir.path});
      return v ?? -1;
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheStore.freeBytes: $e');
      return -1;
    }
  }
}

/// One unbroken run of a film, as one file.
class CachePart {
  CachePart({required this.start, required this.length, required this.file});

  final int start;

  /// Kept in step with the file by [CacheWriter] and nowhere else. It is a
  /// mirror of `file.lengthSync()`, never a claim that outruns it.
  int length;

  final File file;

  int get end => start + length;
}

/// One cached video, or the parts of it this phone has.
class CacheEntry {
  CacheEntry({
    required this.id,
    required this.total,
    required this.label,
    required this.usedAt,
    required this.parts,
  });

  /// Opaque and stable, minted by the server from the object key. The client
  /// never learns the key itself — that was the point of moving off signed
  /// S3 URLs — so it cannot derive this, and does not need to.
  final String id;

  /// The object's full length. Zero until the first response says.
  int total;

  /// What to call this on the storage screen. A title, not a key: an object
  /// key is a map of the bucket and has no business on a viewer's screen.
  String label;

  DateTime usedAt;

  /// Sorted by [CachePart.start], never overlapping.
  final List<CachePart> parts;

  int get heldBytes {
    var n = 0;
    for (final part in parts) {
      n += part.length;
    }
    return n;
  }

  /// The extents, for the arithmetic that decides what can be served.
  RangeSet get ranges {
    final s = RangeSet();
    for (final part in parts) {
      s.add(part.start, part.end);
    }
    return s;
  }

  /// The run holding [at], or null.
  CachePart? partAt(int at) {
    for (final part in parts) {
      if (part.start <= at && at < part.end) return part;
      if (part.start > at) break;
    }
    return null;
  }

  /// Where the next run begins after [at], or [limit] when there is none.
  /// Bounds how far ahead a fetch is worth reading: past it the bytes are
  /// already here.
  int nextPartStart(int at, int limit) {
    for (final part in parts) {
      if (part.start > at) return part.start;
    }
    return limit;
  }

  double get fraction {
    if (total <= 0) return 0;
    return (heldBytes / total).clamp(0.0, 1.0);
  }
}

/// An open append to one run.
class CacheWriter {
  CacheWriter({
    required this.entry,
    required this.part,
    required this.handle,
    required this.onClose,
  });

  final CacheEntry entry;
  final CachePart part;
  final RandomAccessFile handle;

  /// Releases the film's single-writer claim. Must run exactly once, which
  /// is why [close] guards against being called twice.
  final void Function() onClose;
  bool _closed = false;

  Future<void> write(List<int> bytes) async {
    await handle.writeFrom(bytes);
    part.length += bytes.length;
  }

  /// Flushed before the length is believed anywhere else.
  Future<void> flush() => handle.flush();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await handle.flush();
    } catch (_) {}
    try {
      await handle.close();
    } catch (_) {}
    onClose();
  }
}
