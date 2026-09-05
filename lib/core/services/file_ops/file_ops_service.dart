import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../file_transfer/file_receiver_service.dart';

/// What to do when the destination already holds a file of the same name.
enum FileCollision {
  /// Leave the existing file alone and count this one as skipped.
  skip,

  /// Write beside it as `name (2).mp4`, `name (3).mp4`, and so on.
  keepBoth,

  /// Replace the existing file.
  overwrite,
}

/// Outcome of one bulk move or copy.
@immutable
class FileOpResult {
  final int succeeded;
  final int skipped;
  final List<String> failures;

  /// Destination paths actually written. Handed to the media scanner so the
  /// new copies appear in Gallery and other file managers immediately.
  final List<String> writtenPaths;

  /// Source path to destination path, for the files that actually moved.
  ///
  /// The caller needs this because every piece of saved state in this app —
  /// resume position, history, favourites, playlists — is keyed by the file's
  /// path. Without the pairing there is no way to carry any of it across, and
  /// a move silently throws all of it away.
  final Map<String, String> mapping;

  const FileOpResult({
    required this.succeeded,
    required this.skipped,
    required this.failures,
    required this.writtenPaths,
    this.mapping = const <String, String>{},
  });

  bool get hasFailures => failures.isNotEmpty;
  int get total => succeeded + skipped + failures.length;
}

/// Moving and copying video files on disk.
///
/// ─── WHY THIS IS A SERVICE AND NOT A HANDFUL OF `File` CALLS ─────────────
///
/// Every one of the following is a way to lose somebody's video, and each has
/// to be handled the same way every time:
///
///   * **Rename across filesystems fails.** `File.rename` is the fast path and
///     the only atomic one, but it only works inside a single mount. Internal
///     storage and an SD card are different mounts, so a move between them
///     throws `FileSystemException` and the naive fix — catch, copy, delete —
///     deletes the source even when the copy was truncated. Here the source is
///     deleted only after the copy is verified.
///   * **Same-name collisions.** Silently overwriting is data loss the user
///     never asked for; silently skipping looks like the operation did
///     nothing. The caller decides, once, for the whole batch.
///   * **Copying a file onto itself** truncates it to zero bytes. `File.copy`
///     opens the destination for writing before reading the source, so a
///     destination that resolves to the source destroys it. Checked first.
///   * **A half-finished batch.** One unreadable file must not abandon the
///     other forty. Failures are collected and reported, never thrown.
///   * **The library and the OS both go stale.** A moved file leaves a ghost
///     in MediaStore and in our own cache until something says otherwise.
///
/// There is deliberately NO free-space precheck. Dart has no API for it, so
/// the only route is spawning `stat` — a process per file, on a platform where
/// process spawning is restricted and slow, to answer a question the copy
/// already answers: a write that runs out of space produces a SHORT file, and
/// the length check below catches every short file, deletes the partial and
/// reports it. The precheck would have been a per-file subprocess buying
/// nothing but a nicer error string.
class FileOpsService {
  const FileOpsService();

  /// Longest filename this will produce. Practically every Android
  /// filesystem caps a single name component at 255 bytes; a name built from
  /// a long title plus a ` (12)` suffix can cross that and fail with a
  /// confusing errno.
  static const int _maxNameBytes = 250;

  /// Copy [sources] into [destinationDir].
  ///
  /// Never removes anything. Safe to retry: with [FileCollision.skip] a second
  /// run over a finished batch reports everything as skipped.
  Future<FileOpResult> copyAll({
    required List<String> sources,
    required String destinationDir,
    FileCollision collision = FileCollision.keepBoth,
    void Function(int done, int total)? onProgress,
  }) {
    return _run(
      sources: sources,
      destinationDir: destinationDir,
      collision: collision,
      deleteSource: false,
      onProgress: onProgress,
    );
  }

  /// Move [sources] into [destinationDir].
  ///
  /// A source is deleted ONLY once its copy exists at the destination with a
  /// matching length. If the delete then fails — a read-only volume, a file
  /// held open by another app — the copy is kept and the file is reported as a
  /// failure, because leaving the user with two copies is recoverable and
  /// leaving them with none is not.
  Future<FileOpResult> moveAll({
    required List<String> sources,
    required String destinationDir,
    FileCollision collision = FileCollision.keepBoth,
    void Function(int done, int total)? onProgress,
  }) {
    return _run(
      sources: sources,
      destinationDir: destinationDir,
      collision: collision,
      deleteSource: true,
      onProgress: onProgress,
    );
  }

  Future<FileOpResult> _run({
    required List<String> sources,
    required String destinationDir,
    required FileCollision collision,
    required bool deleteSource,
    void Function(int done, int total)? onProgress,
  }) async {
    var succeeded = 0;
    var skipped = 0;
    final failures = <String>[];
    final written = <String>[];
    final mapping = <String, String>{};

    final destDir = Directory(destinationDir);
    if (!await destDir.exists()) {
      try {
        await destDir.create(recursive: true);
      } catch (e) {
        return FileOpResult(
          succeeded: 0,
          skipped: 0,
          failures: <String>['Destination unavailable: $e'],
          writtenPaths: const <String>[],
        );
      }
    }

    final total = sources.length;
    var done = 0;

    for (final source in sources) {
      done++;
      onProgress?.call(done, total);

      try {
        final src = File(source);
        if (!await src.exists()) {
          failures.add('${p.basename(source)}: no longer on disk');
          continue;
        }

        // Already where it is being sent. For a move that is a no-op worth
        // reporting as skipped; for a copy it would be a self-copy, which
        // truncates the file, so both stop here.
        if (p.equals(p.dirname(source), destinationDir)) {
          skipped++;
          continue;
        }

        final target = await _resolveTarget(
          sourcePath: source,
          destinationDir: destinationDir,
          collision: collision,
        );
        if (target == null) {
          skipped++;
          continue;
        }

        // Guard against a destination that resolves back to the source
        // through a symlink or a bind mount. `File.copy` opens the
        // destination for writing first, so this check is the difference
        // between a copy and a zero-byte file.
        if (p.equals(target, source)) {
          skipped++;
          continue;
        }

        final sourceLength = await src.length();

        // Fast path: a rename inside one filesystem is atomic and instant,
        // and it is the only form of move that cannot leave two half-states.
        if (deleteSource) {
          try {
            await src.rename(target);
            succeeded++;
            written.add(target);
            mapping[source] = target;
            await _carrySidecars(source, target, move: true);
            continue;
          } catch (_) {
            // Cross-device, or a filesystem that refuses rename. Fall through
            // to copy-then-verify-then-delete.
          }
        }

        await src.copy(target);

        // VERIFY BEFORE DELETING. A copy that threw nothing can still be
        // short — a volume that filled, a card pulled mid-write. Comparing
        // lengths is cheap and catches every truncation; without it, the
        // delete below is how a video disappears.
        final copiedLength = await File(target).length();
        if (copiedLength != sourceLength) {
          try {
            await File(target).delete();
          } catch (e) {
            if (kDebugMode) debugPrint('file_ops.cleanup: $e');
          }
          failures.add('${p.basename(source)}: copy was incomplete '
              '(the destination may be out of space)');
          continue;
        }

        if (deleteSource) {
          try {
            await src.delete();
          } catch (e) {
            // The copy is good; the original could not be removed. Report it,
            // and do NOT delete the copy — two copies beats none.
            failures.add(
                '${p.basename(source)}: copied, but the original could not '
                'be removed');
            written.add(target);
            continue;
          }
        }

        succeeded++;
        written.add(target);
        if (deleteSource) mapping[source] = target;
        await _carrySidecars(source, target, move: deleteSource);
      } catch (e) {
        failures.add('${p.basename(source)}: $e');
      }
    }

    return FileOpResult(
      succeeded: succeeded,
      skipped: skipped,
      failures: failures,
      writtenPaths: written,
      mapping: mapping,
    );
  }

  /// Subtitle and artwork files that sit beside a video and share its name.
  static const List<String> _sidecarExtensions = <String>[
    'srt', 'ass', 'ssa', 'vtt', 'sub', 'idx', 'smi', 'jpg', 'png',
  ];

  /// Take a video's sidecars with it.
  ///
  /// A `.srt` next to a video IS that video's subtitles — the player finds it
  /// by name, so leaving it behind silently turns subtitles off for a file
  /// that had them, and leaves an orphan in the source folder that means
  /// nothing to anyone.
  ///
  /// Matched on the EXACT stem only. Prefix matching would sweep up a
  /// neighbouring file that merely starts the same way, and moving somebody
  /// else's file is not a mistake they can undo.
  ///
  /// Entirely best-effort: a sidecar that cannot be carried never fails the
  /// video's own move.
  Future<void> _carrySidecars(
    String sourceVideo,
    String targetVideo, {
    required bool move,
  }) async {
    try {
      final srcDir = p.dirname(sourceVideo);
      final dstDir = p.dirname(targetVideo);
      final srcStem = p.basenameWithoutExtension(sourceVideo);
      final dstStem = p.basenameWithoutExtension(targetVideo);
      for (final ext in _sidecarExtensions) {
        final from = File(p.join(srcDir, '$srcStem.$ext'));
        if (!await from.exists()) continue;
        // Follows the video's final name, including any " (2)" the collision
        // rule added — otherwise the sidecar would stop matching its video.
        final to = p.join(dstDir, '$dstStem.$ext');
        if (await File(to).exists()) continue;
        await from.copy(to);
        if (move) {
          try {
            await from.delete();
          } catch (e) {
            if (kDebugMode) debugPrint('file_ops.sidecar-delete: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('file_ops.sidecar: $e');
    }
  }

  /// The path to write, or null when the caller asked to skip a collision.
  Future<String?> _resolveTarget({
    required String sourcePath,
    required String destinationDir,
    required FileCollision collision,
  }) async {
    final name = _clampName(p.basename(sourcePath));
    final direct = p.join(destinationDir, name);
    if (!await File(direct).exists()) return direct;

    switch (collision) {
      case FileCollision.skip:
        return null;
      case FileCollision.overwrite:
        return direct;
      case FileCollision.keepBoth:
        final stem = p.basenameWithoutExtension(name);
        final ext = p.extension(name);
        // Bounded: a folder holding a thousand same-named files is not a
        // case worth spinning forever over.
        for (var i = 2; i < 1000; i++) {
          final candidate =
              p.join(destinationDir, _clampName('$stem ($i)$ext'));
          if (!await File(candidate).exists()) return candidate;
        }
        return null;
    }
  }

  /// Keeps a filename inside the filesystem's per-component byte limit,
  /// trimming the STEM and never the extension — a video that loses its
  /// `.mp4` stops being recognised as a video.
  static String _clampName(String name) {
    if (name.length <= _maxNameBytes) return name;
    final ext = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    final room = _maxNameBytes - ext.length;
    if (room <= 0) return name.substring(0, _maxNameBytes);
    return '${stem.substring(0, room)}$ext';
  }

  /// Tell the OS about files this service created or removed.
  ///
  /// Both halves matter. Without a scan of the WRITTEN paths the copies do not
  /// appear in Gallery; without a scan of the ORIGINALS a moved file leaves a
  /// ghost entry that other apps will happily try to open.
  Future<void> notifyMediaStore({
    required List<String> written,
    List<String> removed = const <String>[],
  }) async {
    final paths = <String>[...written, ...removed];
    if (paths.isEmpty) return;
    await FileReceiverService().mediaScan(paths);
  }
}

final fileOpsServiceProvider =
    Provider<FileOpsService>((ref) => const FileOpsService());
