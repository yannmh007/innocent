import 'dart:async';

import 'package:flutter/material.dart';

import '../localization/app_strings.dart';
import '../theme/app_colors.dart';

/// How far a fetch out of Android/data has got: which file of how many, and
/// its bytes so far. [bytes] is the callback a pull's `onProgress` takes.
class AdbProgress extends ChangeNotifier {
  String name = '';
  int index = 0;
  int count = 1;
  int done = 0;
  int total = -1;

  /// Starting file [i] (0-based) of [n], called [fileName].
  void file(String fileName, int i, int n) {
    name = fileName;
    index = i;
    count = n;
    done = 0;
    total = -1;
    notifyListeners();
  }

  void bytes(int d, int t) {
    done = d;
    total = t;
    notifyListeners();
  }
}

/// Runs [body] behind a small modal that says what is being fetched from
/// Android/data and how far it has got.
///
/// THE WAIT USED TO BE INVISIBLE. "Send to Transfer", "Lock in Private
/// Folder" and sharing an Android/data file all copied it out over ADB
/// first, with nothing on screen: a 2 GB film was a minute or more of a
/// screen that seemed to have ignored the tap. The fetch also keeps going
/// (and resumes after a drop) under its own notification, so this only has
/// to tell the truth while the viewer is looking.
Future<T> withAdbProgress<T>(
  BuildContext context,
  Future<T> Function(AdbProgress progress) body,
) async {
  final progress = AdbProgress();
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: _AdbProgressDialog(progress),
    ),
  );
  unawaited(navigator.push(route));
  try {
    return await body(progress);
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    progress.dispose();
  }
}

class _AdbProgressDialog extends StatelessWidget {
  const _AdbProgressDialog(this.progress);

  final AdbProgress progress;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return AlertDialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: ListenableBuilder(
        listenable: progress,
        builder: (context, _) {
          final frac = progress.total > 0
              ? (progress.done / progress.total).clamp(0.0, 1.0)
              : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.downloading_rounded,
                      color: AppColors.accentBlueLight),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.hfFetching,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                progress.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.white70, fontSize: 13),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: frac, minHeight: 6),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  if (progress.count > 1)
                    Text(s.hfFileOf(progress.index + 1, progress.count),
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 12)),
                  const Spacer(),
                  if (frac != null)
                    Text('${(frac * 100).round()}%',
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 12)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
