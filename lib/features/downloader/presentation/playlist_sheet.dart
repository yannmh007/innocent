import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/downloader/downloader_engine_service.dart';
import '../../../core/theme/app_colors.dart';
import '../data/probe_parser.dart';
import '../domain/quality_preset.dart';
import 'downloader_providers.dart';
import 'preflight_gate.dart';

/// Picks videos out of a collection and one quality for all of them.
///
/// The quality is chosen as a PRESET rather than a row from a format list,
/// because nothing here has been resolved yet — resolving fifty videos to draw
/// a list somebody may close would be minutes of requests to a site that is
/// already rationing them. A preset is an instruction ("720p if there is one")
/// that each download works out for itself as it starts.
class PlaylistSheet extends ConsumerStatefulWidget {
  const PlaylistSheet({super.key, required this.playlist});

  final PlaylistProbe playlist;

  static Future<void> show(BuildContext context, PlaylistProbe playlist) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext ctx) => PlaylistSheet(playlist: playlist),
    );
  }

  @override
  ConsumerState<PlaylistSheet> createState() => _PlaylistSheetState();
}

class _PlaylistSheetState extends ConsumerState<PlaylistSheet> {
  late final Set<int> _selected;
  QualityPreset _preset = QualityPreset.p720;

  @override
  void initState() {
    super.initState();
    // Everything selected: someone who pasted a playlist link wants the
    // playlist. Unticking a few is easier than ticking forty.
    _selected = <int>{
      for (int i = 0; i < widget.playlist.entries.length; i++) i,
    };
  }

  Future<void> _start() async {
    final AppStrings s = AppStrings.of(context);
    final String dir = ref.read(downloadDirProvider);
    final DownloadQueueNotifier queue =
        ref.read(downloadQueueProvider.notifier);
    final String? cookies = ref.read(cookiesPathProvider);
    final String clients = ref.read(playerClientsProvider);
    final DownloadExtras extras = ref.read(downloadExtrasProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<PlaylistEntry> chosen = <PlaylistEntry>[
      for (int i = 0; i < widget.playlist.entries.length; i++)
        if (_selected.contains(i)) widget.playlist.entries[i],
    ];
    if (chosen.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    // ASKED ONCE FOR THE WHOLE BATCH, and asked BEFORE the sheet closes.
    //
    // This path skipped the pre-flight entirely, which made it the worst of
    // the four: a person who had switched "Wi-Fi only" on could queue forty
    // items over mobile data without a word. See docs/audit_downloader.md F1.
    //
    // Once, not once per item — forty identical dialogs is not a warning, it
    // is an obstacle course, and the answer to the first is the answer to all
    // of them. No size is passed because a flat playlist read carries no
    // per-entry size (PlaylistEntry has url, title and duration), so the
    // free-space arm cannot fire here and does not pretend to.
    if (!await confirmPreflight(context, ref, dir: dir)) return;
    if (!mounted) return;
    Navigator.of(context).pop();

    // Registered and submitted one at a time, in order. The engine's queue is
    // single-file by design, so this simply fills it — the first starts now and
    // the rest wait their turn, which is what a queue is for.
    int index = 0;
    for (final PlaylistEntry entry in chosen) {
      final String id = 'pl_${DateTime.now().microsecondsSinceEpoch}_$index';
      index++;
      final DownloadSpec spec = DownloadSpec(
        id: id,
        url: entry.url,
        selector: _preset.selector,
        dir: dir,
        title: entry.title,
        audioOnly: _preset.isAudioOnly,
        merge: _preset.needsMerge,
      );
      queue.register(spec);
      try {
        await DownloaderEngineService.instance.startDownload(
          id: spec.id,
          url: spec.url,
          selector: spec.selector,
          dir: spec.dir,
          title: spec.title,
          audioOnly: spec.audioOnly,
          merge: spec.merge,
          cookies: cookies,
          clients: clients,
          subLangs: extras.subLangs.isEmpty ? null : extras.subLangs,
          embedThumbnail: extras.embedThumbnail,
          embedMetadata: extras.embedMetadata,
          rateLimit: extras.rateLimit.isEmpty ? null : extras.rateLimit,
        );
      } on DownloaderException catch (_) {
        queue.dismiss(spec.id);
      }
    }
    messenger.showSnackBar(SnackBar(
      content: Text('${chosen.length} ${s.downloaderQueuedCount}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = AppStrings.of(context);
    final PlaylistProbe p = widget.playlist;
    final double maxHeight = MediaQuery.of(context).size.height * 0.86;
    final double bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: AppColors.specSheetBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.white20,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
            child: Row(
              children: <Widget>[
                const Icon(Icons.playlist_play_rounded,
                    size: 20, color: AppColors.primaryBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${p.entries.length} ${s.downloaderVideos}'
                        '${p.uploader == null ? '' : '  ·  ${p.uploader}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.white50, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == p.entries.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(<int>[
                          for (int i = 0; i < p.entries.length; i++) i,
                        ]);
                    }
                  }),
                  child: Text(
                    _selected.length == p.entries.length
                        ? s.downloaderSelectNone
                        : s.downloaderSelectAll,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.white08),
          _presetRow(s),
          const Divider(height: 1, color: AppColors.white08),
          Flexible(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: p.entries.length,
              itemBuilder: (BuildContext ctx, int i) {
                final PlaylistEntry e = p.entries[i];
                final String meta = formatDuration(e.durationSeconds);
                return CheckboxListTile(
                  dense: true,
                  value: _selected.contains(i),
                  activeColor: AppColors.primaryBlue,
                  title: Text(
                    e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: meta.isEmpty
                      ? null
                      : Text(
                          meta,
                          style: const TextStyle(
                              color: AppColors.white40, fontSize: 11),
                        ),
                  onChanged: (bool? on) => setState(() {
                    if (on ?? false) {
                      _selected.add(i);
                    } else {
                      _selected.remove(i);
                    }
                  }),
                );
              },
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 14 + bottomInset),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.white08)),
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _selected.isEmpty ? null : _start,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text('${s.downloaderDownload}  ${_selected.length}'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primaryBlue,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _presetRow(AppStrings s) {
    const List<QualityPreset> options = <QualityPreset>[
      QualityPreset.best,
      QualityPreset.p1080,
      QualityPreset.p720,
      QualityPreset.p480,
      QualityPreset.p360,
      QualityPreset.audio,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          for (final QualityPreset option in options)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(presetLabel(s, option)),
                selected: _preset == option,
                onSelected: (_) => setState(() => _preset = option),
                labelStyle: TextStyle(
                  color: _preset == option ? Colors.white : AppColors.white60,
                  fontSize: 12.5,
                ),
                selectedColor: AppColors.primaryBlue,
                backgroundColor: AppColors.specInnerPanel,
                side: BorderSide.none,
                showCheckmark: false,
              ),
            ),
        ],
      ),
    );
  }
}

/// One place that names a preset, so the picker, the settings row and any
/// message about it never disagree.
String presetLabel(AppStrings s, QualityPreset preset) {
  switch (preset) {
    case QualityPreset.ask:
      return s.downloaderAskEveryTime;
    case QualityPreset.best:
      return s.downloaderBest;
    case QualityPreset.p1080:
      return '1080p';
    case QualityPreset.p720:
      return '720p';
    case QualityPreset.p480:
      return '480p';
    case QualityPreset.p360:
      return '360p';
    case QualityPreset.audio:
      return s.downloaderAudio;
  }
}
