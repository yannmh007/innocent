import 'package:flutter_test/flutter_test.dart';
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
  screens('music', () => const ShellScreen(child: MusicScreen()),
      overrides: libraryOverrides);
  screens('transfer', () => const ShellScreen(child: TransferScreen()), scrolls: 1);
  screens('me', () => const ShellScreen(child: MeScreen()), scrolls: 2);
}
