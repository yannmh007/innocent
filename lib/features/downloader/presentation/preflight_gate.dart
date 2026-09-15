import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/downloader/downloader_engine_service.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/download_preflight.dart';
import 'downloader_providers.dart';

/// Ask the pre-flight questions, and let the person answer them.
///
/// The counterpart to [decidePreflight] for the three start paths that have a
/// widget tree in front of them: the quality sheet, the quick-quality preset
/// and the playlist sheet. The browser's pick has no context and takes the
/// other route — see `DownloadQueueNotifier.holdBeforeStart`.
///
/// Returns true when the download should proceed. Neither warning is a hard
/// block; "Download anyway" is always offered, because the check exists to
/// stop a download being a surprise, not to stop it being a choice.
Future<bool> confirmPreflight(
  BuildContext context,
  WidgetRef ref, {
  required String dir,
  int? totalBytes,
}) async {
  // Read everything that needs a context or a ref BEFORE the await, so
  // nothing here reaches across the gap for them. The dialog below still
  // needs the context itself, which is why `context.mounted` is checked the
  // moment the await returns.
  final AppStrings s = AppStrings.of(context);
  final bool wifiOnly = ref.read(wifiOnlyProvider);

  final DeviceStatus device =
      await DownloaderEngineService.instance.deviceStatus(dir);
  if (!context.mounted) return false;

  final PreflightVerdict verdict = decidePreflight(
    wifiOnly: wifiOnly,
    online: device.online,
    unmetered: device.unmetered,
    freeBytes: device.freeBytes,
    totalBytes: totalBytes,
  );
  if (verdict == PreflightVerdict.clear) return true;

  final bool go = await _confirm(context, s, messageFor(s, verdict)) ?? false;
  return go;
}

/// The sentence shown for a verdict, in the active language.
///
/// Shared with the browser path, which cannot show a dialog but still has to
/// say why a download is waiting.
String messageFor(AppStrings s, PreflightVerdict verdict) {
  switch (verdict) {
    case PreflightVerdict.metered:
      return s.downloaderMetered;
    case PreflightVerdict.lowSpace:
      return s.downloaderLowSpace;
    case PreflightVerdict.clear:
      return '';
  }
}

Future<bool?> _confirm(BuildContext context, AppStrings s, String message) =>
    showDialog<bool>(
      context: context,
      builder: (BuildContext dialogCtx) => AlertDialog(
        backgroundColor: AppColors.specSheetBg,
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(s.downloaderDownloadAnyway),
          ),
        ],
      ),
    );
