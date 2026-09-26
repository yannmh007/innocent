import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// THE CATALOGUE, ON DISK, so the app still has a shop window with the radio
/// off.
///
/// ─── WHAT WAS WRONG ──────────────────────────────────────────────────────
///
/// Every catalogue read went straight to the network and nothing kept the
/// answer. With no connection that made the app almost blank: the landing tab
/// threw and drew an error card INSTEAD OF the rows, so there was no layout to
/// look at; a category grid threw and drew an error state; and the detail
/// screen kept its poster and synopsis only because the card object had been
/// handed to it by the screen behind, while the album — which comes from a
/// second request — silently disappeared. Posters survived, because
/// [PosterCache] already writes them to disk; the text and the structure
/// around them did not.
///
/// The phones this app is used on lose their connection constantly, and the
/// apps it is judged against do not go blank when that happens. Telegram and
/// Facebook both show the last thing they were showing, marked as old. That is
/// what this file makes possible.
///
/// ─── WHAT IS STORED, AND WHAT IS NOT ─────────────────────────────────────
///
/// RAW RESPONSE BODIES, keyed by the request that produced them. Not parsed
/// objects: a second copy of the parser would have to be kept in step with
/// [VideoContent] by hand, and the copy that goes stale is always the one some
/// screen happens to read. Keeping the JSON means the one parser in
/// `ApiContentRepository` stays the only one, and a column added to the
/// catalogue tomorrow is cached correctly today.
///
/// NEVER A PLAYBACK GRANT. `request-playback` does not pass through here at
/// all — the signed URL it returns expires in ten minutes and is the one thing
/// in the whole feature the client must not be able to produce on its own. A
/// cache that could answer it would make every other measure decoration. The
/// rule is enforced by `tool/security_invariants.py`, not by this comment.
///
/// ─── WHERE, AND WHY NOT THE CACHE DIRECTORY ──────────────────────────────
///
/// `getApplicationSupportDirectory()/vh_catalogue/`. Posters live in the CACHE
/// directory on purpose — Android empties that under storage pressure and
/// "Clear cache" wipes it, which is right for artwork that can always be
/// fetched again. This is the opposite case: it is the only copy of the
/// catalogue a phone with no signal has, and having Android delete it without
/// asking would restore exactly the blank screen it exists to prevent. Same
/// reasoning as the stream cache, which lives there for the same reason.
///
/// It is therefore excluded from Android's Auto Backup and from device
/// transfer — an adult catalogue must not travel to the user's Google Drive.
/// `tool/security_invariants.py` rule 10 fails the build if that exclusion is
/// missing.
///
/// File names are SHA-1 of the request key, so a directory listing says
/// nothing about what this person has been looking at.
class CatalogueCache {
  const CatalogueCache._();

  /// One line turns the whole thing off and the app goes back to
  /// network-or-nothing.
  static bool enabled = true;

  /// Named here rather than inline because `tool/security_invariants.py` reads
  /// it to check the backup rules.
  static const String dirName = 'vh_catalogue';

  /// Responses older than this are ignored and deleted.
  ///
  /// Generous on purpose. A stale row title is a cosmetic problem; an empty
  /// screen is not, and someone who has been without data for a month is
  /// exactly the person this is for. Anything actually protected — what plays,
  /// what a subscription covers — is decided elsewhere and is not in here.
  static const Duration maxAge = Duration(days: 45);

  /// Bounds. The catalogue is text, so these are small: a few hundred
  /// kilobytes covers every screen the app has.
  static const int maxEntries = 200;
  static const int maxBytes = 8 * 1024 * 1024;

  /// Refuses a single oversized body rather than letting one enormous response
  /// fill the budget on its own.
  static const int maxEntryBytes = 1024 * 1024;

  /// True while the most recent catalogue answer came from this cache rather
  /// than from the server.
  ///
  /// A UI HINT AND NOTHING ELSE. It exists so the hub can put a line at the top
  /// saying what the user is looking at is saved rather than current — which is
  /// what Telegram and Facebook do, and what makes an old listing honest
  /// instead of merely convenient. Nothing decides access from it, and it is
  /// deliberately not persisted: a fresh launch has made no request yet, so it
  /// has no opinion yet.
  ///
  /// A [ValueNotifier] rather than a provider so that [CatalogueCache] stays a
  /// plain static store with no dependency on Riverpod, exactly like
  /// [PosterCache].
  static final ValueNotifier<bool> servedFromCache = ValueNotifier<bool>(false);

  /// Say that what is about to be drawn came from here.
  ///
  /// Separate from [read] because reading and USING are no longer the same
  /// thing: every catalogue call reads the cache first now, and only the ones
  /// whose network attempt was too slow or unreachable actually show it.
  static void noteServedFromCache() => servedFromCache.value = true;

  /// Say that what is about to be drawn came from the server.
  static void noteServedLive() => servedFromCache.value = false;

  static Directory? _dir;

  /// Decoded bodies, kept for the life of the process.
  ///
  /// WHY A SECOND CACHE IN FRONT OF THE CACHE. Reading an entry is a file
  /// existence check, a whole-file read and a `jsonDecode`, and the decode is
  /// the expensive one: a landing payload is a few hundred kilobytes of JSON
  /// and it is parsed ON THE UI ISOLATE, so the cost is not throughput, it is
  /// frames not drawn. Opening the hub pays it for the rows, the facets and
  /// the categories; opening a card pays it again, and `titleDetailProvider`
  /// is `autoDispose`, so backing out and tapping the same card pays it a
  /// third time. None of that reaches the disk twice for a reason — it just
  /// was not being remembered.
  ///
  /// This is what made offline "work but feel slow", which is its own kind of
  /// broken: Telegram shows what it has instantly and so must this.
  ///
  /// THE BODY IS SHARED, NOT COPIED, and that relies on callers not mutating
  /// what they are handed. They already must: `_serve` hands the same decoded
  /// object to the mapper and to `write`, so a mapper that edited it would
  /// have been writing its edits to disk since the day the cache was added.
  /// Copying instead would cost exactly what this exists to avoid.
  static final Map<String, dynamic> _hot = <String, dynamic>{};

  /// Small on purpose. The hub touches a handful of keys and a body can be
  /// hundreds of kilobytes; this is a working set, not a second store. Oldest
  /// insertion goes first, which for this access pattern is the card opened
  /// longest ago.
  static const int hotEntries = 12;

  static void _remember(String key, dynamic body) {
    _hot.remove(key);
    _hot[key] = body;
    while (_hot.length > hotEntries) {
      _hot.remove(_hot.keys.first);
    }
  }
  static bool _pruned = false;

  /// A stable key for one request. Query order must not produce two entries
  /// for the same question, so the pairs are sorted.
  static String keyFor(String path, [Map<String, dynamic>? query]) {
    if (query == null || query.isEmpty) return path;
    final pairs = query.entries
        .map((e) => '${e.key}=${e.value}')
        .toList(growable: false)
      ..sort();
    return '$path?${pairs.join('&')}';
  }

  /// The stored body for [key], or null when there is none, it is too old, or
  /// it cannot be read.
  ///
  /// [quiet] reads WITHOUT claiming the screen is showing saved data.
  ///
  /// The caller now reads the cache BEFORE the network rather than after it
  /// fails — that is what makes an offline launch instant instead of a
  /// twenty-second wait — so a read no longer means the saved copy was used.
  /// Only the caller knows that, and it says so with [noteServedFromCache].
  /// Without this the banner appeared on a perfectly good connection, on every
  /// screen, because every screen reads the cache first now.
  static Future<dynamic> read(String key, {bool quiet = false}) async {
    if (!enabled) return null;
    // Answered without touching the disk when this process has already read
    // or written it. The disk copy is what survives a restart; this is what
    // keeps the second look at the same screen free.
    final hot = _hot[key];
    if (hot != null) {
      if (!quiet) servedFromCache.value = true;
      return hot;
    }
    try {
      final dir = await _directory();
      if (dir == null) return null;
      final file = File(p.join(dir.path, _nameFor(key)));
      if (!await file.exists()) return null;

      final entry = jsonDecode(await file.readAsString());
      if (entry is! Map<String, dynamic>) return null;
      if (entry['v'] != 1) return null;
      final at = entry['at'];
      if (at is! int) return null;
      final written = DateTime.fromMillisecondsSinceEpoch(at, isUtc: true);
      final age = DateTime.now().toUtc().difference(written);
      // A negative age means the clock moved, not that the entry is fresh.
      if (age.isNegative || age > maxAge) {
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      final body = entry['body'];
      // Only a read that ACTUALLY ANSWERS counts as stale data on screen. A
      // miss leaves the flag alone, because the caller is about to rethrow the
      // original failure and the user will get a retry button — an error card
      // under a banner promising saved content would be the worst of both.
      if (body == null) return null;
      _remember(key, body);
      if (!quiet) servedFromCache.value = true;
      return body;
    } catch (e) {
      if (kDebugMode) debugPrint('CatalogueCache.read: $e');
      return null;
    }
  }

  /// Stores [body] under [key], replacing whatever was there.
  ///
  /// Best effort in every direction: a full disk, a denied directory or a body
  /// that will not encode must cost the offline case and nothing else. The
  /// caller never awaits this on the path that matters.
  static Future<void> write(String key, dynamic body) async {
    if (!enabled) return;
    try {
      // Nothing to serve later, and writing it would shadow a good older entry
      // with an empty one.
      if (body == null) return;
      // Before the disk, and not after: this is the copy the next read on
      // this screen will answer from, and the write below is best-effort. A
      // full disk must not leave the process reading last hour's rows.
      _remember(key, body);
      // A WRITE NO LONGER CLEARS THE BANNER, and that is a correction rather
      // than an omission. Since the caller shows the saved copy after a couple
      // of seconds and lets the request carry on in the background, the write
      // that eventually lands happens while the STALE copy is still on screen
      // — so clearing the banner here would take the notice away and leave the
      // old listing under it, which is the one combination that misleads.
      // Only the caller knows which answer it actually returned, and it says
      // so on both paths.
      final encoded = jsonEncode(<String, dynamic>{
        'v': 1,
        'at': DateTime.now().toUtc().millisecondsSinceEpoch,
        'body': body,
      });
      if (encoded.length > maxEntryBytes) return;

      final dir = await _directory();
      if (dir == null) return;
      final file = File(p.join(dir.path, _nameFor(key)));
      // Write-then-rename, so a kill mid-write cannot leave a truncated entry
      // that later parses as half a catalogue.
      final part = File('${file.path}.part');
      await part.writeAsString(encoded, flush: true);
      await part.rename(file.path);
      unawaited(_pruneOnce());
    } catch (e) {
      if (kDebugMode) debugPrint('CatalogueCache.write: $e');
    }
  }

  /// Empties the cache. Called on sign-out.
  ///
  /// THE CATALOGUE IS SCOPED TO AN ACCOUNT by row-level security, so what is
  /// in here is what the previous user was allowed to see. Leaving it behind
  /// would show the next person that list, offline, with no request made.
  static Future<void> clear() async {
    // FIRST, AND OUTSIDE THE TRY. Sign-out calls this, and a decoded body
    // left in memory after it would be the previous account's listing, ready
    // to be handed to whoever signs in next — which is the one thing the
    // whole cache is not allowed to do. A directory that cannot be opened
    // must not be the reason it stays.
    _hot.clear();
    try {
      final dir = await _directory();
      if (dir == null) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
      _pruned = false;
      // Nothing left to serve, so nothing on screen can be claimed as saved.
      servedFromCache.value = false;
    } catch (e) {
      if (kDebugMode) debugPrint('CatalogueCache.clear: $e');
    }
  }

  /// Every title-shaped row anywhere in the cache, newest entry first,
  /// de-duplicated by id.
  ///
  /// What makes offline SEARCH possible. `search_titles` is a Postgres
  /// function and there is no local equivalent, so with no connection the
  /// choice is between searching what has already been seen and refusing to
  /// search at all — and someone looking for a film they were watching
  /// yesterday is the likeliest searcher on a phone with no signal.
  ///
  /// Deliberately SHAPE-BASED rather than key-based: it walks whatever JSON is
  /// stored and collects any object carrying an `id` and a `title`. That means
  /// a row nested inside `landing_rows`' envelope is found without this file
  /// knowing what that envelope looks like, and a new endpoint added later
  /// contributes its titles for free.
  static Future<List<Map<String, dynamic>>> titleRows({int limit = 1500}) async {
    final found = <String, Map<String, dynamic>>{};
    try {
      final dir = await _directory();
      if (dir == null) return const <Map<String, dynamic>>[];
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.part')) files.add(entity);
      }
      // Newest first, so if the cap is hit it is hit on the oldest entries.
      files.sort((a, b) =>
          b.statSync().modified.compareTo(a.statSync().modified));

      for (final file in files) {
        if (found.length >= limit) break;
        try {
          final entry = jsonDecode(await file.readAsString());
          if (entry is! Map<String, dynamic>) continue;
          collectTitles(entry['body'], found, limit);
        } catch (_) {
          // One unreadable entry must not cost the whole search.
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CatalogueCache.titleRows: $e');
    }
    return found.values.toList(growable: false);
  }

  /// Walks [node] adding every title-shaped object to [into].
  ///
  /// Depth-limited. The input is JSON this app wrote, but it is still parsed
  /// data being walked recursively, and a bound is cheaper than trusting it.
  ///
  /// Public so `test/catalogue_cache_test.dart` can check the shape test
  /// directly. It is the part with a real decision in it — a still from a
  /// title's album also carries an `id`, and letting one through would put a
  /// photo in the search results — and the alternative would be a test that
  /// needs a filesystem and a plugin to reach one `if`.
  @visibleForTesting
  static void collectTitles(
    dynamic node,
    Map<String, Map<String, dynamic>> into,
    int limit, [
    int depth = 0,
  ]) {
    if (depth > 8 || into.length >= limit) return;
    if (node is List) {
      for (final child in node) {
        collectTitles(child, into, limit, depth + 1);
      }
      return;
    }
    if (node is! Map) return;
    final m = node.cast<String, dynamic>();
    final id = '${m['id'] ?? ''}';
    if (id.isNotEmpty && m.containsKey('title') && m.containsKey('category')) {
      // `category` as well as `title`, because an album row also has an id and
      // a photo has neither a category nor a poster — the extra key is what
      // keeps a still out of the search results.
      into.putIfAbsent(id, () => m);
    }
    for (final value in m.values) {
      collectTitles(value, into, limit, depth + 1);
    }
  }

  static Future<Directory?> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, dirName));
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } catch (e) {
      if (kDebugMode) debugPrint('CatalogueCache.dir: $e');
      return null;
    }
  }

  /// SHA-1 of the key, over UTF-8 bytes — not `codeUnits`, which masks a UTF-16
  /// unit down to a byte and would let two keys differing only outside ASCII
  /// collide onto one file and serve each other's answer. A Burmese category
  /// label in a filter is exactly that case.
  static String _nameFor(String key) =>
      '${sha1.convert(utf8.encode(key))}.json';

  /// Evicts oldest-first until the directory fits, once per session.
  static Future<void> _pruneOnce() async {
    if (_pruned) return;
    _pruned = true;
    try {
      final dir = _dir;
      if (dir == null) return;
      final files = <File>[];
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        files.add(entity);
        total += await entity.length();
      }
      if (files.length <= maxEntries && total <= maxBytes) return;

      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      var count = files.length;
      for (final file in files) {
        if (count <= maxEntries && total <= maxBytes) break;
        final size = await file.length();
        try {
          await file.delete();
          total -= size;
          count -= 1;
        } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CatalogueCache.prune: $e');
    }
  }
}
