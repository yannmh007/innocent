import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../local_browser/domain/video.dart';
import '../../local_browser/presentation/widgets/bulk_actions.dart';
import '../../video_hub/domain/byte_size.dart';

/// Photos inside Android/data, one screen each, swiped through like a
/// gallery. Each photo is fetched to the app's cache when it is first shown
/// (a photo is small; a page swiped past is not fetched), zoomable, and can
/// go to Transfer, the Private Folder or the share sheet from here.
class AdbImageViewer extends ConsumerStatefulWidget {
  const AdbImageViewer({super.key, required this.files, this.initial = 0});

  final List<AdbFileEntry> files;
  final int initial;

  @override
  ConsumerState<AdbImageViewer> createState() => _AdbImageViewerState();
}

class _AdbImageViewerState extends ConsumerState<AdbImageViewer> {
  late final PageController _pages = PageController(
      initialPage: widget.initial.clamp(0, widget.files.length - 1));
  late int _index = widget.initial.clamp(0, widget.files.length - 1);
  final Map<String, Future<String?>> _local = <String, Future<String?>>{};
  bool _chrome = true;

  Future<String?> _fetch(AdbFileEntry e) => _local[e.path] ??= () async {
        final r = await AdbService.instance.pullForPlayback(e.path);
        if (r.startsWith('ERROR')) {
          // Not remembered: swiping back to it tries again.
          _local.remove(e.path)?.ignore();
          return null;
        }
        return r;
      }();

  AdbFileEntry get _current => widget.files[_index];

  Video get _asVideo => Video(
        id: 'adb:${_current.path}',
        uri: 'adb://${_current.path}',
        title: _current.name,
        folderPath: _current.path.substring(0, _current.path.lastIndexOf('/')),
        duration: Duration.zero,
        sizeBytes: _current.sizeBytes,
        width: 0,
        height: 0,
        mimeType: null,
        dateAdded: null,
      );

  Future<void> _share() async {
    final s = AppStrings.of(context);
    final local = await _fetch(_current);
    if (local == null) {
      AppSnackbar.globalError(s.hfPullFailed);
      return;
    }
    try {
      await Share.shareXFiles(<XFile>[XFile(local)]);
    } catch (_) {
      AppSnackbar.globalError(s.shareFailed);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _chrome
          ? AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.45),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_current.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15)),
                  Text(
                    '${_index + 1} / ${widget.files.length}'
                    '${_current.sizeBytes > 0 ? '  ·  ${formatBytes(_current.sizeBytes)}' : ''}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w400,
                        color: AppColors.white60),
                  ),
                ],
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: s.hfSend,
                  icon: const Icon(Icons.send_rounded),
                  onPressed: () => BulkActions.sendToTransfer(context, ref,
                      videos: <Video>[_asVideo]),
                ),
                IconButton(
                  tooltip: s.lockInPrivateFolder,
                  icon: const Icon(Icons.lock_rounded),
                  onPressed: () => BulkActions.lockInPrivateFolder(context, ref,
                      videos: <Video>[_asVideo]),
                ),
                IconButton(
                  tooltip: s.share,
                  icon: const Icon(Icons.share_rounded),
                  onPressed: _share,
                ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: PageView.builder(
          controller: _pages,
          itemCount: widget.files.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) {
            final e = widget.files[i];
            return FutureBuilder<String?>(
              future: _fetch(e),
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final path = snap.data;
                if (path == null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(s.hfPullFailed,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.white70)),
                    ),
                  );
                }
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_rounded,
                          color: AppColors.white40,
                          size: 48),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
