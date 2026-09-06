import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/downloader/downloader_engine_service.dart';
import '../../../core/services/file_transfer/file_receiver_service.dart';
import '../../downloader/presentation/downloader_providers.dart';
import '../../music/presentation/music_providers.dart';
import '../data/update_check_service.dart';
import '../data/update_download_controller.dart';
import '../data/update_prompt_store.dart';
import '../domain/app_release.dart';
import '../domain/update_prompt_decision.dart';
import 'app_update_screen.dart';

/// The proactive update prompt. Step 5 of `docs/updater_plan.md` §4B.
///
/// Until now the only way to learn about an update was to go looking for it in
/// Settings, which nobody does. This is the one surface that goes to the user
/// instead — and precisely because it does, it is the one that has to be
/// careful. §3's cadence, §4B's placement rules and §7's list of things not to
/// build are all restrictions on when it may open its mouth.
///
/// It decides NOTHING itself. [UpdatePromptDecision] holds the rules, this
/// gathers the facts and renders the result.
class UpdatePrompt {
  const UpdatePrompt._();

  /// Ask, if today is a day for asking. Safe to call on every resume.
  ///
  /// Returns without touching the network in the common case: the throttle is
  /// checked first, so an app opened thirty times a day makes one manifest
  /// request, not thirty.
  static Future<void> maybeShow(
    BuildContext context,
    WidgetRef ref, {
    UpdatePromptStore store = const UpdatePromptStore(),
    UpdateCheckService checkService = const UpdateCheckService(),
  }) async {
    final now = DateTime.now();

    if (!UpdatePromptDecision.mayCheckNow(
      lastPromptAt: await store.lastShownAt(),
      now: now,
      busy: isBusy(ref),
    )) {
      return;
    }

    // §5's rule, and requirement 5 of this step: ONE manifest path. The same
    // service the screen uses, with the same failure handling — a version
    // check that cannot be answered is silence, never an error. §6: "Manifest
    // unreachable: nothing. A version check is not worth an error."
    AppRelease? release;
    try {
      release = await checkService.fetchLatest();
    } catch (_) {
      return;
    }

    if (!UpdatePromptDecision.shouldPrompt(
      release: release,
      installedBuild: AppVersion.build,
      dismissedVersionCode: await store.dismissedVersionCode(),
      // Re-read: the fetch took time, and the throttle may have been consumed
      // by another resume that raced this one.
      lastPromptAt: await store.lastShownAt(),
      now: DateTime.now(),
      busy: isBusy(ref),
    )) {
      return;
    }

    if (!context.mounted) return;
    await _show(context, release!, store);
  }

  /// Everything that means "not now, they are doing something".
  ///
  /// The player is NOT listed, and does not need to be: it is pushed on the
  /// root navigator above the shell, and the shell only calls this while it is
  /// the current route. §4B's "never over the player" is enforced by where
  /// this is called from, which is stronger than a flag that can go stale.
  @visibleForTesting
  static bool isBusy(WidgetRef ref) {
    // The updater's own download — prompting to update mid-update is absurd.
    if (ref.read(updateDownloadProvider).isBusy) return true;

    // A Wi-Fi transfer in flight. §4B: never during a transfer.
    if (ref.read(receiverProvider).batchRunning) return true;

    // Music playing in the background, with the user on a list screen. The
    // fullscreen video player is handled by the caller (see above).
    if (ref.read(musicPlayingProvider).isPlaying) return true;

    // A yt-dlp download working. `queued` counts: the queue is about to run,
    // and a dialog would land on top of it starting.
    final queue = ref.read(downloadQueueProvider);
    for (final task in queue) {
      switch (task.phase) {
        case DownloadPhase.queued:
        case DownloadPhase.preparing:
        case DownloadPhase.progress:
        case DownloadPhase.retrying:
          return true;
        case DownloadPhase.paused:
        case DownloadPhase.done:
        case DownloadPhase.cancelled:
        case DownloadPhase.error:
          break;
      }
    }
    return false;
  }

  static Future<void> _show(
    BuildContext context,
    AppRelease release,
    UpdatePromptStore store,
  ) async {
    final s = AppStrings.of(context);
    final notes = release.notesFor(
      Localizations.localeOf(context).languageCode,
    );

    // Recorded BEFORE awaiting the dialog. A prompt that is up has already
    // spent the day's interruption, however the user answers it — including
    // by killing the app.
    await store.recordShown(DateTime.now());
    if (!context.mounted) return;

    final update = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(
          s.updateAvailable,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _versionLine(release),
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
            // ONE line of notes. §7: no "what's new" carousel — and a dialog
            // that has to scroll is a dialog nobody reads.
            if (notes != null && notes.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                notes.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
            ],
          ],
        ),
        actions: [
          // Always present at this step. Priority and min_supported can drop
          // it in step 7; nothing here is ever un-dismissible.
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(
              s.updateNotNow,
              style: const TextStyle(color: AppColors.white70),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(s.updateNow),
          ),
        ],
      ),
    );

    if (!context.mounted) return;

    if (update == true) {
      // Straight to the screen that already knows how to download, verify and
      // install. The prompt's whole job was to get them here.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AppUpdateScreen()),
      );
      return;
    }

    // "Not now", or dismissed by tapping outside. Both are a no for THIS
    // version, and a later one asks again.
    await store.recordDismissed(release.versionCode);
  }

  /// "1.64.8 (321) · 88 MB", or without the size when none is published.
  static String _versionLine(AppRelease release) {
    final size = release.sizeLabel;
    final version = '${release.versionName} (${release.versionCode})';
    return size == null ? version : '$version  ·  $size';
  }
}
