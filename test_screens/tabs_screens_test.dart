import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:innocent/features/local_browser/presentation/selection_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/local_browser/presentation/widgets/video_option_menu.dart';
import 'package:innocent/features/local_browser/presentation/widgets/bulk_actions.dart';
import 'package:innocent/features/local_browser/presentation/folder_detail_screen.dart';
import 'package:innocent/features/local_browser/presentation/local_screen.dart';
import 'package:innocent/features/me/presentation/me_screen.dart';
import 'package:innocent/features/music/presentation/music_screen.dart';
import 'package:innocent/features/shell/shell_screen.dart';
import 'package:innocent/features/transfer/presentation/transfer_screen.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  screens('local', () => const ShellScreen(child: LocalScreen()),
      overrides: libraryOverrides, scrolls: 1);
  // The Local tab's other shapes (ViewMode / LayoutMode indices, see
  // LibraryPreferencesNotifier): grid, all-videos list, all-videos grid.
  screens('local_grid', () => const ShellScreen(child: LocalScreen()),
      overrides: libraryOverrides, prefs: {'lib.layout': 1}, phones: [large]);
  screens('local_files', () => const ShellScreen(child: LocalScreen()),
      overrides: libraryOverrides, prefs: {'lib.viewMode': 1}, phones: [large]);
  screens('local_files_grid', () => const ShellScreen(child: LocalScreen()),
      overrides: libraryOverrides, prefs: {'lib.viewMode': 1, 'lib.layout': 1}, phones: [large]);
  screens('folder', () => const FolderDetailScreen(
          folderPath: '/storage/emulated/0/Movies', folderName: 'Movies'),
      overrides: libraryOverrides, phones: [large]);
  // The long-press sheet over the files list.
  screens('video_sheet', () => const _SheetHost(),
      overrides: libraryOverrides, prefs: {'lib.viewMode': 1}, phones: [large]);
  // Selection mode on the files list (MX p27).
  screens('video_select', () => const _SelectHost(),
      overrides: libraryOverrides, prefs: {'lib.viewMode': 1}, phones: [large]);
  screens('folder_select', () => const _SelectHost(folders: true),
      overrides: libraryOverrides, phones: [large]);
  screens('props_bulk', () => const _SelectHost(props: 1),
      overrides: libraryOverrides, prefs: {'lib.viewMode': 1}, phones: [large]);
  screens('props_video', () => const _SelectHost(props: 2),
      overrides: libraryOverrides, prefs: {'lib.viewMode': 1}, phones: [large]);
  screens('music', () => const ShellScreen(child: MusicScreen()),
      overrides: libraryOverrides);
  screens('transfer', () => const ShellScreen(child: TransferScreen()), scrolls: 1);
  screens('me', () => const ShellScreen(child: MeScreen()), scrolls: 2);
}

/// The files list with a video's long-press sheet open over it.
class _SheetHost extends StatefulWidget {
  const _SheetHost();
  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => VideoOptionMenu.show(context, videos().first));
  }

  @override
  Widget build(BuildContext context) =>
      const ShellScreen(child: LocalScreen());
}

/// The files list with two videos selected.
class _SelectHost extends ConsumerStatefulWidget {
  const _SelectHost({this.folders = false, this.props = 0});
  final bool folders;
  /// 1: the bulk Properties dialog, 2: one video's Properties.
  final int props;
  @override
  ConsumerState<_SelectHost> createState() => _SelectHostState();
}

class _SelectHostState extends ConsumerState<_SelectHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.props == 1) {
        BulkActions.properties(context, ref, videos: videos().take(3).toList());
        return;
      }
      if (widget.props == 2) {
        VideoInfoDialog.show(context, videos().first);
        return;
      }
      if (widget.folders) {
        ref
            .read(folderSelectionProvider.notifier)
            .toggle('/storage/emulated/0/Movies');
        return;
      }
      final n = ref.read(selectionProvider.notifier);
      for (final v in videos().take(2)) {
        n.toggle(v.uri);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      const ShellScreen(child: LocalScreen());
}
