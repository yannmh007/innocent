import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';

/// Progress + cancellation for a batch of vault file moves.
///
/// WHY THIS EXISTS
/// ───────────────
/// Locking files into the vault is a physical copy of every byte, then a
/// verification pass, then a delete. On the phones this app targets that is
/// tens of seconds for one video and several minutes for a batch. The old
/// import showed none of it: the Add button greyed out and the screen sat
/// there. Users reasonably concluded the app had hung — and the one thing a
/// person must never do while a vault import is running is force-quit it.
///
/// There was also no way to stop. Start a 6 GB import by accident and the
/// only exit was killing the app mid-copy.
///
/// A [ChangeNotifier] rather than setState in the caller, because the same
/// controller drives both the import path (in the picker) and the restore
/// path (in the vault screen), and neither should own the sheet's rebuilds.
class VaultProgressController extends ChangeNotifier {
  VaultProgressController({required this.total, required this.title});

  /// How many files are in this batch.
  final int total;

  /// Sheet heading, resolved by the caller so this file needs no context.
  final String title;

  int _index = 0;
  String _currentName = '';
  int _bytesDone = 0;
  int _bytesTotal = 0;
  bool _cancelled = false;
  bool _done = false;

  /// Bytes copied across the whole batch, for the speed readout.
  int _batchBytes = 0;
  final Stopwatch _clock = Stopwatch();

  /// Rebuilds are throttled: a 64 KB chunk stream at real disk speed fires
  /// hundreds of callbacks a second, and repainting a progress bar that often
  /// costs more CPU than the copy it is reporting on.
  final Stopwatch _sinceNotify = Stopwatch();

  int get index => _index;
  String get currentName => _currentName;
  bool get cancelled => _cancelled;
  bool get isDone => _done;

  /// 0..1 within the current file (0 when its size is unknown).
  double get itemFraction =>
      _bytesTotal > 0 ? (_bytesDone / _bytesTotal).clamp(0.0, 1.0) : 0.0;

  /// 0..1 across the batch, counting the in-flight file's own progress so the
  /// bar moves smoothly through a single large file instead of jumping.
  double get overallFraction =>
      total > 0 ? ((_index + itemFraction) / total).clamp(0.0, 1.0) : 0.0;

  /// Bytes per second across the batch so far, or null before it is meaningful.
  double? get bytesPerSecond {
    final secs = _clock.elapsedMilliseconds / 1000.0;
    if (secs < 1.0 || _batchBytes <= 0) return null;
    return _batchBytes / secs;
  }

  void beginItem(int i, String name) {
    if (!_clock.isRunning) _clock.start();
    _index = i;
    _currentName = name;
    _bytesDone = 0;
    _bytesTotal = 0;
    _sinceNotify
      ..reset()
      ..start();
    notifyListeners();
  }

  /// Byte callback handed straight to the service's streamed copy.
  void onBytes(int copied, int totalBytes) {
    _batchBytes += copied - _bytesDone;
    _bytesDone = copied;
    _bytesTotal = totalBytes;
    if (!_sinceNotify.isRunning || _sinceNotify.elapsedMilliseconds >= 100) {
      _sinceNotify
        ..reset()
        ..start();
      notifyListeners();
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    notifyListeners();
  }

  void finish() {
    _done = true;
    _clock.stop();
    notifyListeners();
  }
}

/// Show the blocking progress sheet. Deliberately NOT awaited by callers —
/// the returned Future completes only when the sheet closes, and the caller
/// closes it itself once the batch ends.
///
/// Non-dismissible on purpose: a tap outside must not leave a multi-gigabyte
/// copy running with nothing on screen to stop it. Cancel is the only exit,
/// and cancel is honoured between chunks, so it takes effect within a
/// fraction of a second rather than at the end of the current file.
Future<void> showVaultProgressSheet(
  BuildContext context,
  VaultProgressController controller,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: AppColors.black75,
    builder: (_) => _VaultProgressSheet(controller: controller),
  );
}

class _VaultProgressSheet extends StatelessWidget {
  final VaultProgressController controller;
  const _VaultProgressSheet({required this.controller});

  static String _rate(double bps) {
    if (bps >= 1024 * 1024) {
      return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.darkSurface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final cancelling = controller.cancelled && !controller.isDone;
            final rate = controller.bytesPerSecond;
            return Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: AppColors.accentBlue),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          cancelling ? s.cancelling : controller.title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  // The file being moved right now. Shown because a batch
                  // that names nothing is indistinguishable from a batch
                  // that is stuck.
                  Text(
                    controller.currentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.white70, fontSize: 12.5),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: controller.itemFraction > 0
                          ? controller.itemFraction
                          : null,
                      minHeight: 5,
                      backgroundColor: AppColors.white08,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.accentBlue),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        s.vaultProgressCount(
                            controller.index + 1, controller.total),
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 11.5),
                      ),
                      if (rate != null)
                        Text(
                          _rate(rate),
                          style: const TextStyle(
                              color: AppColors.white40, fontSize: 11.5),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: controller.overallFraction,
                      minHeight: 3,
                      backgroundColor: AppColors.white06,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.white30),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: cancelling
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              controller.cancel();
                            },
                      child: Text(
                        s.cancel,
                        style: TextStyle(
                            color: cancelling
                                ? AppColors.white30
                                : AppColors.white70,
                            fontSize: 13.5),
                      ),
                    ),
                  ),
                  // Set expectations honestly: a cancelled import keeps the
                  // originals, and the user needs to know that before they
                  // decide whether to cancel.
                  Text(
                    s.vaultProgressSafeNote,
                    style: const TextStyle(
                        color: AppColors.white30, fontSize: 10.5, height: 1.3),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
