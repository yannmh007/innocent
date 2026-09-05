import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/core_providers.dart';
import '../../../../core/services/resume/resume_storage.dart';
import '../../../user_data/domain/user_data_models.dart';
import '../../../user_data/user_data_providers.dart';

/// The provider objects a migration needs, captured in one go.
///
/// Exists so the migration can be handed everything it needs BEFORE its first
/// await and never touch the widget's `ref` again. See the note in
/// [MediaIdentityMigrator.migrate].
class _MigrationTargets {
  // REAL TYPES, NOT `dynamic`.
  //
  // `dynamic` would have compiled and then thrown at runtime on the first
  // mistake — and it would have hidden one that was already there:
  // `favouritesProvider` holds a `Set<String>`, not a `List<String>`. The
  // analyzer is the thing that catches that, and typing these fields
  // `dynamic` is how you switch it off exactly where it is needed most.
  final ResumeStorage resume;
  final Set<String> favourites;
  final FavouritesNotifier favouritesNotifier;
  final List<String> watchLater;
  final WatchLaterNotifier watchLaterNotifier;
  final List<Playlist> playlists;
  final PlaylistsNotifier playlistsNotifier;
  final List<Bookmark> bookmarks;
  final BookmarksNotifier bookmarksNotifier;
  final List<HistoryEntry> history;
  final HistoryNotifier historyNotifier;

  const _MigrationTargets({
    required this.resume,
    required this.favourites,
    required this.favouritesNotifier,
    required this.watchLater,
    required this.watchLaterNotifier,
    required this.playlists,
    required this.playlistsNotifier,
    required this.bookmarks,
    required this.bookmarksNotifier,
    required this.history,
    required this.historyNotifier,
  });
}

/// Carries everything the app has SAVED ABOUT A VIDEO from its old path to its
/// new one after a move or a rename.
///
/// ─── WHY THIS HAS TO EXIST ───────────────────────────────────────────────
///
/// Every piece of per-video state in this app is keyed by the video's URI, and
/// a file's URI is its path. So the moment a file moves, all of it silently
/// detaches:
///
///   * the resume position — the film restarts at 00:00
///   * the Continue Watching / history entry — still listed, now pointing at a
///     path with nothing at it, so tapping it fails
///   * favourites and Watch Later — a star that no longer marks anything
///   * every playlist containing it — a dead entry the user has to hunt down
///
/// None of that is visible at the moment of the move. The user sees "Moved 3"
/// and finds out days later, one video at a time, which is the worst way to
/// discover data loss: too late to connect it to what caused it.
///
/// Organising a library is the single most likely reason somebody selects
/// twenty files at once, so the operation that punishes organising is exactly
/// the wrong one to ship un-migrated.
///
/// Every step is best-effort and independent. A playlist that fails to update
/// must not stop the resume position from moving across — partial state is
/// better than the old state, and both are better than a crash mid-migration.
class MediaIdentityMigrator {
  const MediaIdentityMigrator();

  /// Re-key everything from [oldUri] to [newUri].
  ///
  /// Safe to call when nothing was stored: each step checks before it writes.
  static Future<void> migrate(
    WidgetRef ref, {
    required String oldUri,
    required String newUri,
  }) async {
    if (oldUri == newUri) return;

    // EVERYTHING IS READ OFF `ref` HERE, BEFORE THE FIRST AWAIT.
    //
    // A `WidgetRef` belongs to the widget that owns it, and reading one after
    // that widget is disposed throws. This method is a chain of a dozen awaits,
    // and `migrateAll` runs it once PER FILE — a fifty-file move is hundreds of
    // reads spread over seconds, with the user free to press Back at any point
    // in the middle of it. Half a migration is worse than none: the resume
    // position moves, the playlists do not, and the two disagree permanently.
    //
    // Notifiers and services live in the provider container, not in the
    // widget, so once captured they keep working no matter what happens to the
    // screen that started the move.
    final _MigrationTargets t;
    try {
      t = _MigrationTargets(
        resume: ref.read(resumeStorageProvider),
        favourites: ref.read(favouritesProvider),
        favouritesNotifier: ref.read(favouritesProvider.notifier),
        watchLater: ref.read(watchLaterProvider),
        watchLaterNotifier: ref.read(watchLaterProvider.notifier),
        playlists: ref.read(playlistsProvider),
        playlistsNotifier: ref.read(playlistsProvider.notifier),
        bookmarks: ref.read(bookmarksProvider),
        bookmarksNotifier: ref.read(bookmarksProvider.notifier),
        history: ref.read(historyProvider),
        historyNotifier: ref.read(historyProvider.notifier),
      );
    } catch (e) {
      // The ref is already gone. Nothing has been changed yet, so stopping
      // here leaves the saved state exactly as it was.
      if (kDebugMode) debugPrint('MediaIdentityMigrator.capture: $e');
      return;
    }

    // ── Resume position ──────────────────────────────────────────────────
    // Read before clearing. `savePosition` refuses positions under its
    // minimum and over 95%, which is correct for a save made while watching
    // and wrong for a migration — so a refused write is treated as "there was
    // nothing worth carrying", not as a failure.
    try {
      final resume = t.resume;
      final position = await resume.getPosition(oldUri);
      if (position != null && position > Duration.zero) {
        // Duration is unknown here, and passing zero disables the 95% rule,
        // which is what we want: the value was already judged worth saving
        // once.
        await resume.savePosition(
          uri: newUri,
          position: position,
          duration: Duration.zero,
        );
      }
      await resume.clearPosition(oldUri);

      // The crash-recovery marker points at whatever was last playing. If that
      // is the file being moved, it has to follow or the next cold start
      // offers to resume a path that no longer exists.
      final last = await resume.getLastPlaying();
      if (last?.uri == oldUri) {
        await resume.clearLastPlaying();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.resume: $e');
    }

    // ── Favourites ───────────────────────────────────────────────────────
    // `toggle` is the only mutator, so a migration is: if the old one was
    // starred, star the new one and un-star the old.
    try {
      final favourites = t.favourites;
      if (favourites.contains(oldUri)) {
        await t.favouritesNotifier.toggle(newUri);
        await t.favouritesNotifier.toggle(oldUri);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.favourites: $e');
    }

    // ── Watch Later ──────────────────────────────────────────────────────
    try {
      final later = t.watchLater;
      if (later.contains(oldUri)) {
        await t.watchLaterNotifier.add(newUri);
        await t.watchLaterNotifier.remove(oldUri);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.watchLater: $e');
    }

    // ── Playlists ────────────────────────────────────────────────────────
    // A video can sit in several, so every one is checked. Order matters
    // within a playlist, but `addVideo` appends and there is no reorder API —
    // a video landing at the end of a playlist is a far smaller loss than a
    // dead entry in the middle of it.
    try {
      final playlists = t.playlists;
      final notifier = t.playlistsNotifier;
      for (final playlist in playlists) {
        if (!playlist.videoUris.contains(oldUri)) continue;
        await notifier.addVideo(playlist.id, newUri);
        await notifier.removeVideo(playlist.id, oldUri);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.playlists: $e');
    }

    // ── Bookmarks ────────────────────────────────────────────────────────
    // Timestamps the user placed BY HAND. Of everything here these are the
    // least reproducible — a resume position regenerates itself the next time
    // the video is watched, a bookmark never does. Re-added at the new URI,
    // then the old ones removed; `delete` takes the bookmark's own id, so the
    // two cannot be confused.
    try {
      final marks = t.bookmarks;
      final notifier = t.bookmarksNotifier;
      final mine = marks.where((b) => b.videoUri == oldUri).toList();
      for (final b in mine) {
        await notifier.add(
          videoUri: newUri,
          videoTitle: b.videoTitle,
          position: b.position,
          label: b.label,
        );
      }
      for (final b in mine) {
        await notifier.delete(b.id);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.bookmarks: $e');
    }

    // ── History ──────────────────────────────────────────────────────────
    // RE-RECORDED, not just deleted.
    //
    // Deleting was the first attempt, on the grounds that `HistoryNotifier`
    // has no rename. But three separate views derive from history —
    // `watchProgressProvider` (the progress bar on every tile),
    // `lastWatchedProvider` (the "recently watched" sort) and
    // `playedUrisProvider` (the watched badge) — so dropping the entry threw
    // away the watched state of a video the user had merely reorganised. It
    // would come back looking unwatched.
    //
    // `record` recreates it at the new URI with the same position and
    // duration, and only then is the old one removed. It is not counted as a
    // new play: moving a file is not watching it.
    try {
      final history = t.history;
      final matches = history.where((e) => e.videoUri == oldUri);
      if (matches.isNotEmpty) {
        final entry = matches.first;
        await t.historyNotifier.record(
              videoUri: newUri,
              videoTitle: entry.videoTitle,
              position: entry.lastPosition,
              duration: entry.totalDuration,
            );
      }
      await t.historyNotifier.deleteEntry(oldUri);
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.history: $e');
    }
  }


  /// Remove every PUBLIC reference to [uri].
  ///
  /// For vaulting, not for moving. A move keeps the video in the library, so
  /// its saved state should follow it; vaulting takes it OUT of the library,
  /// so every list that would still name it has to let go.
  ///
  /// The bulk vault action already cleared history and the resume position —
  /// and stopped there, leaving the title sitting in Favourites, in every
  /// playlist that held it, in Watch Later, and in the bookmarks list. Those
  /// screens are one tap from the Me tab and show the title in plain text, so
  /// a video was "hidden" everywhere except the four places that spell out
  /// what it was called.
  ///
  /// The vault keeps its own index, so nothing is lost that the owner cannot
  /// see after unlocking.
  static Future<void> purgePublicTraces(WidgetRef ref, String uri) async {
    // Captured before the first await, for the same reason as [migrate]: this
    // runs once per video, and vaulting a folder full of them is a long chain
    // during which the screen can go away. A purge that stops half-done leaves
    // the video's title in the lists it did not reach.
    final Set<String> favourites;
    final FavouritesNotifier favouritesNotifier;
    final List<String> watchLater;
    final WatchLaterNotifier watchLaterNotifier;
    final List<Playlist> playlists;
    final PlaylistsNotifier playlistsNotifier;
    final List<Bookmark> bookmarks;
    final BookmarksNotifier bookmarksNotifier;
    try {
      favourites = ref.read(favouritesProvider);
      favouritesNotifier = ref.read(favouritesProvider.notifier);
      watchLater = ref.read(watchLaterProvider);
      watchLaterNotifier = ref.read(watchLaterProvider.notifier);
      playlists = ref.read(playlistsProvider);
      playlistsNotifier = ref.read(playlistsProvider.notifier);
      bookmarks = ref.read(bookmarksProvider);
      bookmarksNotifier = ref.read(bookmarksProvider.notifier);
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.purge-capture: $e');
      return;
    }

    try {
      if (favourites.contains(uri)) {
        await favouritesNotifier.toggle(uri);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.purge-fav: $e');
    }
    try {
      if (watchLater.contains(uri)) {
        await watchLaterNotifier.remove(uri);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.purge-later: $e');
    }
    try {
      for (final pl in playlists) {
        if (pl.videoUris.contains(uri)) {
          await playlistsNotifier.removeVideo(pl.id, uri);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.purge-playlists: $e');
    }
    try {
      for (final b in bookmarks.where((b) => b.videoUri == uri)) {
        await bookmarksNotifier.delete(b.id);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MediaIdentityMigrator.purge-marks: $e');
    }
  }

  /// [migrate] for a whole batch, given matched old/new pairs.
  static Future<void> migrateAll(
    WidgetRef ref, {
    required Map<String, String> oldToNew,
  }) async {
    for (final entry in oldToNew.entries) {
      await migrate(ref, oldUri: entry.key, newUri: entry.value);
    }
  }
}
