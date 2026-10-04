import 'package:flutter_test/flutter_test.dart';
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
  screens('music', () => const ShellScreen(child: MusicScreen()),
      overrides: libraryOverrides);
  screens('transfer', () => const ShellScreen(child: TransferScreen()), scrolls: 1);
  screens('me', () => const ShellScreen(child: MeScreen()), scrolls: 2);
}
