import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/services/file_transfer/received_history.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/adb_lost_card.dart';
import '../../../core/ui/adb_progress_dialog.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../local_browser/domain/app_data_names.dart';
import '../../local_browser/domain/video.dart';
import '../../local_browser/presentation/widgets/bulk_actions.dart';
import '../../video_hub/domain/byte_size.dart';
import '../domain/file_kind.dart';
import 'adb_image_viewer.dart';

/// HIDDEN FILES — every app's private folder (Android/data), read over
/// Innocent's own ADB connection, as a file browser.
///
/// Before this, Android/data showed up in two places only: its VIDEOS in the
/// Video tab (after a scan), and every file inside the pickers of Transfer
/// and the Private Folder, where it could be chosen but not looked at. A
/// photo or a PDF from a Telegram channel could not be opened at all.
///
/// Here: the apps by name (Telegram first, with its download folders as
/// shortcuts), any folder inside them, and per file the obvious thing — a
/// video or a song STREAMS (nothing copied), a photo opens in the viewer,
/// anything else goes to the phone's app for it. Long-press selects; the
/// selection goes to Transfer, the Private Folder or the share sheet. The
/// originals are never moved or deleted: they belong to the app that wrote
/// them.
class AndroidDataScreen extends ConsumerStatefulWidget {
  const AndroidDataScreen({super.key, this.startAt});

  /// A folder to open at, instead of the list of apps.
  final String? startAt;

  @override
  ConsumerState<AndroidDataScreen> createState() => _AndroidDataScreenState();
}

/// A folder that could not be read: the ADB connection is down.
class _Lost implements Exception {
  const _Lost();
}

enum _Filter { all, video, image, audio, document }

class _AndroidDataScreenState extends ConsumerState<AndroidDataScreen> {
  final List<String> _stack = <String>[kAndroidDataRoot];
  final Map<String, Future<List<AdbFileEntry>>> _listings =
      <String, Future<List<AdbFileEntry>>>{};
  final Set<String> _selected = <String>{};
  _Filter _filter = _Filter.all;

  /// Telegram's download folders found on this phone, for the shortcuts.
  List<AdbFileEntry> _telegram = const <AdbFileEntry>[];

  /// ADB has never connected on this phone: the card says "set up once".
  bool _neverSetUp = false;

  String get _here => _stack.last;
  bool get _atRoot => _stack.length == 1;
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final start = widget.startAt;
    if (start != null && start != kAndroidDataRoot) _stack.add(start);
    unawaited(_findTelegram());
    unawaited(AdbService.instance.lastConnect().then((last) {
      if (mounted && last.isEmpty) setState(() => _neverSetUp = true);
    }));
  }

  Future<List<AdbFileEntry>> _list(String path) =>
      _listings[path] ??= () async {
        var out = await AdbService.instance.listAdbDirOrNull(path);
        // A dropped connection is re-established by the engine on the next
        // command: one more try before calling the folder unreadable.
        if (out == null) {
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          out = await AdbService.instance.listAdbDirOrNull(path);
        }
        // Kept as it failed: the lost card's reconnect calls [_reload], which
        // clears every listing.
        if (out == null) throw const _Lost();
        return out;
      }();

  Future<void> _findTelegram() async {
    final found = <AdbFileEntry>[];
    for (final pkg in kTelegramPackages) {
      final dirs =
          await AdbService.instance.listAdbDirOrNull(telegramDownloads(pkg));
      if (dirs == null) continue;
      found.addAll(dirs.where((e) => e.isDir));
      if (found.isNotEmpty) break;
    }
    if (mounted) setState(() => _telegram = found);
  }

  void _reload() {
    setState(() {
      _listings.clear();
    });
    unawaited(_findTelegram());
  }

  void _open(String path) {
    setState(() {
      _stack.add(path);
      _selected.clear();
      _filter = _Filter.all;
    });
  }

  bool _back() {
    if (_selecting) {
      setState(_selected.clear);
      return false;
    }
    if (_stack.length > 1) {
      setState(() {
        _stack.removeLast();
        _filter = _Filter.all;
      });
      return false;
    }
    return true;
  }

  String _title(AppStrings s) {
    if (_selecting) return s.selectedCount(_selected.length);
    if (_atRoot) return s.hfTitle;
    return appDataFolderName(_here);
  }

  /// The path below Android/data, for the line under the title.
  String _crumb() {
    final rel = _here.startsWith(kAndroidDataRoot)
        ? _here.substring(kAndroidDataRoot.length)
        : _here;
    return 'Android/data$rel';
  }

  // ---- what a tap does ----

  Future<void> _tapFile(AdbFileEntry e, List<AdbFileEntry> folder) async {
    final kind = kindOf(e.name);
    switch (kind) {
      case FileKind.video:
      case FileKind.audio:
        // STREAMED: the player reads the ranges it needs over ADB.
        unawaited(context.push(Routes.player, extra: <String, dynamic>{
          'uri': 'adb://${e.path}',
          'title': e.name,
        }));
      case FileKind.image:
        final images = folder
            .where((f) => !f.isDir && kindOf(f.name) == FileKind.image)
            .toList();
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => AdbImageViewer(
            files: images,
            initial: images.indexWhere((f) => f.path == e.path),
          ),
        ));
      default:
        await _openElsewhere(e);
    }
  }

  /// A document, an archive, an APK: fetched to the app's own cache (an app
  /// cannot be handed a file inside another app's folder), then given to
  /// whichever app opens that kind of file — or the share sheet.
  Future<void> _openElsewhere(AdbFileEntry e) async {
    final s = AppStrings.of(context);
    final local = await withAdbProgress<String?>(context, (p) async {
      p.file(e.name, 0, 1);
      final r = await AdbService.instance
          .pullForPlayback(e.path, onProgress: p.bytes);
      return r.startsWith('ERROR') ? null : r;
    });
    if (!mounted) return;
    if (local == null) {
      AppSnackbar.globalError(s.hfPullFailed);
      return;
    }
    if (await ReceivedHistoryNotifier.openExternally(local)) return;
    if (!mounted) return;
    final share = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        content: Text(s.hfNoApp,
            style: const TextStyle(color: AppColors.white70, fontSize: 14)),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(s.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true), child: Text(s.share)),
        ],
      ),
    );
    if (share == true) {
      try {
        await Share.shareXFiles(<XFile>[XFile(local)]);
      } catch (_) {
        AppSnackbar.globalError(s.shareFailed);
      }
    }
  }

  // ---- what the selection does ----

  List<Video> _selectedAsVideos(List<AdbFileEntry> folder) => <Video>[
        for (final e in folder)
          if (_selected.contains(e.path))
            Video(
              id: 'adb:${e.path}',
              uri: 'adb://${e.path}',
              title: e.name,
              folderPath: _here,
              duration: Duration.zero,
              sizeBytes: e.sizeBytes,
              width: 0,
              height: 0,
              mimeType: null,
              dateAdded: null,
            ),
      ];

  Future<void> _send(List<AdbFileEntry> folder) async {
    final items = _selectedAsVideos(folder);
    setState(_selected.clear);
    await BulkActions.sendToTransfer(context, ref, videos: items);
  }

  Future<void> _lock(List<AdbFileEntry> folder) async {
    final items = _selectedAsVideos(folder);
    setState(_selected.clear);
    await BulkActions.lockInPrivateFolder(context, ref, videos: items);
  }

  Future<void> _share(List<AdbFileEntry> folder) async {
    final items = _selectedAsVideos(folder);
    setState(_selected.clear);
    await BulkActions.share(context, ref, videos: items);
  }

  // ---- layout ----

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_back()) Navigator.of(context).pop();
      },
      child: FutureBuilder<List<AdbFileEntry>>(
        future: _list(_here),
        builder: (context, snap) {
          final entries = snap.data ?? const <AdbFileEntry>[];
          return Scaffold(
            appBar: AppBar(
              leading: _selecting
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_selected.clear),
                    )
                  : null,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_title(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (!_selecting && !_atRoot)
                    Text(_crumb(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                            color: AppColors.white55)),
                ],
              ),
              actions: _selecting
                  ? <Widget>[
                      IconButton(
                        tooltip: s.hfSend,
                        icon: const Icon(Icons.send_rounded),
                        onPressed: () => _send(entries),
                      ),
                      IconButton(
                        tooltip: s.lockInPrivateFolder,
                        icon: const Icon(Icons.lock_rounded),
                        onPressed: () => _lock(entries),
                      ),
                      IconButton(
                        tooltip: s.share,
                        icon: const Icon(Icons.share_rounded),
                        onPressed: () => _share(entries),
                      ),
                      IconButton(
                        tooltip: s.selectAll,
                        icon: const Icon(Icons.select_all_rounded),
                        onPressed: () => setState(() {
                          _selected.addAll(_visible(entries)
                              .where((e) => !e.isDir)
                              .map((e) => e.path));
                        }),
                      ),
                    ]
                  : <Widget>[
                      IconButton(
                        tooltip: s.refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: _reload,
                      ),
                    ],
            ),
            body: _body(s, snap, entries),
          );
        },
      ),
    );
  }

  Widget _body(AppStrings s, AsyncSnapshot<List<AdbFileEntry>> snap,
      List<AdbFileEntry> entries) {
    if (snap.error is _Lost) {
      return AdbLostCard(
        firstTime: _neverSetUp,
        onBack: () {
          if (mounted) _reload();
        },
      );
    }
    if (snap.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_atRoot) return _apps(s, entries);
    final hasFiles = entries.any((e) => !e.isDir);
    final visible = _visible(entries);
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: CustomScrollView(
        slivers: <Widget>[
          if (hasFiles) SliverToBoxAdapter(child: _filters(s)),
          if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(s.hfEmpty,
                    style: const TextStyle(color: AppColors.white55)),
              ),
            )
          else if (_filter == _Filter.image)
            SliverPadding(
              padding: const EdgeInsets.all(4),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 130,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: visible.length,
                itemBuilder: (_, i) => _photoTile(visible[i], entries),
              ),
            )
          else
            SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (_, i) => _row(visible[i], entries),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  List<AdbFileEntry> _visible(List<AdbFileEntry> entries) {
    bool keep(AdbFileEntry e) {
      if (e.isDir) return _filter == _Filter.all;
      final k = kindOf(e.name);
      return switch (_filter) {
        _Filter.all => true,
        _Filter.video => k == FileKind.video,
        _Filter.image => k == FileKind.image,
        _Filter.audio => k == FileKind.audio,
        _Filter.document => k == FileKind.document,
      };
    }

    return entries.where(keep).toList();
  }

  Widget _filters(AppStrings s) {
    final labels = <_Filter, String>{
      _Filter.all: s.hfAll,
      _Filter.video: s.hfVideos,
      _Filter.image: s.hfPhotos,
      _Filter.audio: s.hfAudio,
      _Filter.document: s.hfDocs,
    };
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        children: <Widget>[
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(labels[f]!),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }

  /// The list of apps, with Telegram's download folders as shortcuts.
  Widget _apps(AppStrings s, List<AdbFileEntry> entries) {
    final apps = entries.where((e) => e.isDir).toList()
      ..sort((a, b) {
        final ta = kTelegramPackages.contains(a.name);
        final tb = kTelegramPackages.contains(b.name);
        if (ta != tb) return ta ? -1 : 1;
        return appLabelForPackage(a.name)
            .toLowerCase()
            .compareTo(appLabelForPackage(b.name).toLowerCase());
      });
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          if (_telegram.isNotEmpty) ...<Widget>[
            _sectionLabel(s.hfQuick),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final t in _ordered(_telegram))
                  ActionChip(
                    avatar: Icon(_iconForTelegram(t.name),
                        size: 18, color: const Color(0xFF2AABEE)),
                    label: Text(_telegramLabel(s, t.name)),
                    onPressed: () => _open(t.path),
                  ),
              ],
            ),
            const SizedBox(height: 18),
          ],
          _sectionLabel(s.hfApps),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.045),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (var i = 0; i < apps.length; i++) ...<Widget>[
                  if (i > 0)
                    Divider(
                        height: 1,
                        indent: 64,
                        color: Colors.white.withValues(alpha: 0.06)),
                  _appRow(apps[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10, top: 6),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.white60,
                fontSize: 12.5,
                fontWeight: FontWeight.w600)),
      );

  /// Telegram's folders in the order people look for them.
  List<AdbFileEntry> _ordered(List<AdbFileEntry> dirs) {
    int rank(String n) {
      final l = n.toLowerCase();
      if (l.contains('video')) return 0;
      if (l.contains('image')) return 1;
      if (l.contains('document') || l.contains('files')) return 2;
      if (l.contains('audio') || l.contains('music')) return 3;
      return 4;
    }

    return dirs.toList()..sort((a, b) => rank(a.name).compareTo(rank(b.name)));
  }

  /// "Telegram Video" → the reader's word for videos; other folders by name.
  String _telegramLabel(AppStrings s, String name) {
    final l = name.toLowerCase();
    if (l == 'telegram video') return s.hfVideos;
    if (l == 'telegram images') return s.hfPhotos;
    if (l == 'telegram documents') return s.hfDocs;
    if (l == 'telegram audio') return s.hfAudio;
    return name.replaceFirst('Telegram ', '');
  }

  IconData _iconForTelegram(String name) {
    final n = name.toLowerCase();
    if (n.contains('video')) return Icons.movie_rounded;
    if (n.contains('image')) return Icons.image_rounded;
    if (n.contains('audio') || n.contains('music')) {
      return Icons.music_note_rounded;
    }
    if (n.contains('document') || n.contains('files')) {
      return Icons.description_rounded;
    }
    return Icons.folder_rounded;
  }

  Widget _appRow(AdbFileEntry e) {
    final label = appLabelForPackage(e.name);
    final telegram = kTelegramPackages.contains(e.name);
    final color = telegram
        ? const Color(0xFF2AABEE)
        : Colors.primaries[e.name.hashCode.abs() % Colors.primaries.length];
    return InkWell(
      onTap: () => _open(e.path),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(11),
              ),
              child: telegram
                  ? Icon(Icons.send_rounded, color: color, size: 20)
                  : Text(label.isEmpty ? '?' : label[0].toUpperCase(),
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 17)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500)),
                  Text(e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.white50, fontSize: 11.5)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.white40),
          ],
        ),
      ),
    );
  }

  void _toggle(AdbFileEntry e) {
    if (e.isDir) return;
    setState(() {
      if (!_selected.remove(e.path)) _selected.add(e.path);
    });
  }

  Widget _row(AdbFileEntry e, List<AdbFileEntry> folder) {
    final kind = e.isDir ? null : kindOf(e.name);
    final picked = _selected.contains(e.path);
    return InkWell(
      onTap: () {
        if (_selecting) {
          _toggle(e);
        } else if (e.isDir) {
          _open(e.path);
        } else {
          unawaited(_tapFile(e, folder));
        }
      },
      onLongPress: () => _toggle(e),
      child: Container(
        color: picked ? AppColors.accentBlue.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: <Widget>[
            SizedBox(width: 52, height: 52, child: _leading(e, kind)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(e.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14, height: 1.3)),
                  if (!e.isDir && e.sizeBytes > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(formatBytes(e.sizeBytes),
                          style: const TextStyle(
                              color: AppColors.white50, fontSize: 12)),
                    ),
                ],
              ),
            ),
            if (_selecting && !e.isDir)
              Icon(
                picked
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: picked ? AppColors.accentBlue : AppColors.white40,
              )
            else if (e.isDir)
              const Icon(Icons.chevron_right_rounded, color: AppColors.white40),
          ],
        ),
      ),
    );
  }

  Widget _leading(AdbFileEntry e, FileKind? kind) {
    if (e.isDir) {
      return _iconBox(Icons.folder_rounded, const Color(0xFFFFB74D));
    }
    final icon = switch (kind) {
      FileKind.video => Icons.movie_rounded,
      FileKind.image => Icons.image_rounded,
      FileKind.audio => Icons.music_note_rounded,
      FileKind.document => Icons.description_rounded,
      FileKind.archive => Icons.folder_zip_rounded,
      FileKind.apk => Icons.android_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
    final color = switch (kind) {
      FileKind.video => const Color(0xFFFF6B6B),
      FileKind.image => const Color(0xFF4FC3F7),
      FileKind.audio => const Color(0xFFBA68C8),
      FileKind.document => const Color(0xFF81C784),
      FileKind.apk => const Color(0xFFA5D6A7),
      _ => AppColors.white60,
    };
    final box = _iconBox(icon, color);
    if (kind != FileKind.video && kind != FileKind.image) return box;
    return _Thumb(path: e.path, placeholder: box, play: kind == FileKind.video);
  }

  Widget _iconBox(IconData icon, Color color) => Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 24),
      );

  Widget _photoTile(AdbFileEntry e, List<AdbFileEntry> folder) {
    final picked = _selected.contains(e.path);
    return GestureDetector(
      onTap: () {
        if (_selecting) {
          _toggle(e);
        } else {
          unawaited(_tapFile(e, folder));
        }
      },
      onLongPress: () => _toggle(e),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _Thumb(
              path: e.path,
              placeholder:
                  _iconBox(Icons.image_rounded, const Color(0xFF4FC3F7)),
            ),
          ),
          if (_selecting)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                picked
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: picked ? AppColors.accentBlue : Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}

/// A thumbnail read over ADB (a video's frame or a photo, made natively and
/// cached like every other thumbnail), the icon until it arrives.
class _Thumb extends StatefulWidget {
  const _Thumb({
    required this.path,
    required this.placeholder,
    this.play = false,
  });

  final String path;
  final Widget placeholder;
  final bool play;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _bytes =
      ThumbnailCache.instance.get('adb://${widget.path}');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (_, snap) {
        final b = snap.data;
        if (b == null) return widget.placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true),
              if (widget.play)
                const Center(
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white70, size: 22),
                ),
            ],
          ),
        );
      },
    );
  }
}
