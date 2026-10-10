import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/services/network/connection_kind.dart';
import '../../data/api/download_copies.dart';
import '../../data/api/download_plan.dart';
import '../../domain/byte_size.dart';
import '../../domain/content_repository.dart';
import '../../domain/video_content.dart';
import '../video_hub_theme.dart';

/// The viewer's standing answer to "which copy should a download fetch".
///
/// `ask` until they tick "Remember my choice"; then a height or `original`,
/// used without asking. Changed back on the Downloads screen.
class DownloadQualityPreference {
  DownloadQualityPreference._();
  static const String _key = 'vh_download_quality';

  static Future<String> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      return DownloadQuality.normalise(p.getString(_key));
    } catch (_) {
      return DownloadQuality.ask;
    }
  }

  static Future<void> write(String choice) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, DownloadQuality.normalise(choice));
    } catch (_) {
      // Not remembered means asked again next time — never a lost download.
    }
  }
}

/// Which copy to download, asked the way YouTube asks: every size on the
/// table, the free space beside it, and "remember my choice".
///
/// Returns the quality to download ('original' or a height) and whether the
/// sheet was shown — it shows the sizes and the free space, so the size
/// question after it would be asking twice — or null when the viewer
/// cancelled. A film with no ladder, a refusal, or no connection to ask with
/// answer the ORIGINAL without showing anything; the download itself then
/// reports whatever went wrong, as it always has.
Future<({String quality, bool asked})?> chooseDownloadQuality(
  BuildContext context, {
  required ContentRepository repo,
  required VideoContent content,
  required MediaRef source,
  required String? deviceId,
  required Future<int> Function() freeSpace,
}) async {
  const original = (quality: DownloadQuality.original, asked: false);
  final standing = await DownloadQualityPreference.read();
  if (standing != DownloadQuality.ask) return (quality: standing, asked: false);

  final copies = await Future.wait<Object>(<Future<Object>>[
    downloadCopiesOf(
        repo: repo, content: content, source: source, deviceId: deviceId),
    freeSpace(),
  ]);
  final options = copies[0] as List<DownloadOption>;
  if (options.isEmpty) return original;
  final free = copies[1] as int;
  final kind = await ConnectionInfo.read();
  if (!context.mounted) return null;

  final picked = await showModalBottomSheet<({String id, bool remember})>(
    context: context,
    backgroundColor: VH.surface1,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(VH.rSheet)),
    ),
    builder: (_) => _QualitySheet(
      title: content.title,
      options: options,
      freeBytes: free,
      metered: kind.metered,
    ),
  );
  if (picked == null) return null;
  if (picked.remember) await DownloadQualityPreference.write(picked.id);
  return (quality: picked.id, asked: true);
}

class _QualitySheet extends StatefulWidget {
  final String title;
  final List<DownloadOption> options;
  final int freeBytes;
  final bool metered;

  const _QualitySheet({
    required this.title,
    required this.options,
    required this.freeBytes,
    required this.metered,
  });

  @override
  State<_QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends State<_QualitySheet> {
  // THE ORIGINAL IS PRESELECTED: tapping straight through downloads what a
  // download always was. A smaller copy is a choice the viewer makes.
  String _id = DownloadQuality.original;
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(VH.s4, VH.s4, VH.s4, VH.s3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(s.vhDlQualityTitle, style: VH.title),
            const SizedBox(height: VH.s1),
            Text(widget.title,
                style: VH.meta, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: VH.s3),
            for (final o in widget.options)
              RadioListTile<String>(
                value: o.id,
                groupValue: _id,
                onChanged: (v) => setState(() => _id = v ?? _id),
                dense: true,
                contentPadding: EdgeInsets.zero,
                activeColor: VH.accent,
                title: Text(
                  o.height == null ? s.vhDlQualityOriginal : '${o.height}p',
                  style: VH.label,
                ),
                secondary: Text(
                  o.bytes == null ? '' : formatBytes(o.bytes!),
                  style: VH.meta,
                ),
              ),
            const SizedBox(height: VH.s2),
            Text(
              <String>[
                s.vhDlQualityHint,
                if (widget.freeBytes >= 0)
                  s.vhDlQualityFree(formatBytes(widget.freeBytes)),
                if (widget.metered) s.vhDownloadOnMobile,
              ].join(' '),
              style: VH.meta,
            ),
            CheckboxListTile(
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: VH.accent,
              title: Text(s.vhDlQualityRemember, style: VH.body),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(s.cancel),
                ),
                const SizedBox(width: VH.s2),
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pop((id: _id, remember: _remember)),
                  child: Text(s.vhDownloadStart),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
