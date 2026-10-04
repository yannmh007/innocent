import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/about/about_screen.dart';
import 'package:innocent/features/downloader/presentation/downloader_home_screen.dart';
import 'package:innocent/features/me/presentation/app_theme_screen.dart';
import 'package:innocent/features/me/presentation/backup_restore_screen.dart';
import 'package:innocent/features/me/presentation/help_screen.dart';
import 'package:innocent/features/me/presentation/media_manager_screen.dart';
import 'package:innocent/features/me/presentation/statistics_screen.dart';
import 'package:innocent/features/me/presentation/status_saver_screen.dart';
import 'package:innocent/features/private_folder/presentation/private_folder_screen.dart';
import 'package:innocent/features/settings/presentation/settings_audio_screen.dart';
import 'package:innocent/features/settings/presentation/settings_decoder_screen.dart';
import 'package:innocent/features/settings/presentation/settings_general_screen.dart';
import 'package:innocent/features/settings/presentation/settings_language_screen.dart';
import 'package:innocent/features/settings/presentation/settings_list_screen.dart';
import 'package:innocent/features/settings/presentation/settings_player_screen.dart';
import 'package:innocent/features/settings/presentation/settings_screen.dart';
import 'package:innocent/features/settings/presentation/settings_subtitle_screen.dart';
import 'package:innocent/features/settings/presentation/player_controls_screen.dart';
import 'package:innocent/features/settings/presentation/player_style_screen.dart';
import 'package:innocent/features/settings/presentation/subtitle_text_screen.dart';
import 'package:innocent/features/updater/presentation/app_update_screen.dart';
import 'package:innocent/features/video_hub/data/demo_content_datasource.dart';
import 'package:innocent/features/video_hub/data/demo_content_repository.dart';
import 'package:innocent/features/video_hub/presentation/content_detail_screen.dart';
import 'package:innocent/features/video_hub/presentation/downloads_screen.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:innocent/features/video_hub/presentation/video_search_screen.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  setUpAll(loadScreenFonts);

  List<Override> hub() => [
        contentRepositoryProvider.overrideWithValue(DemoContentRepository()),
        ...libraryOverrides(),
      ];
  final demo = const DemoContentDataSource().all();
  final series = demo.firstWhere((c) => c.episodeCount != null, orElse: () => demo.first);
  final film = demo.firstWhere((c) => c.episodeCount == null, orElse: () => demo.last);

  const one = [small];
  screens('detail_series', () => ContentDetailScreen(content: series), overrides: hub, scrolls: 1);
  screens('detail_film', () => ContentDetailScreen(content: film), overrides: hub, phones: one);
  screens('search', () => const VideoSearchScreen(), overrides: hub, phones: one);
  screens('downloads', () => const DownloadsScreen(), overrides: hub, phones: one);

  screens('settings', () => const SettingsScreen(), scrolls: 1);
  screens('settings_general', () => const SettingsGeneralScreen(), phones: one, scrolls: 2);
  screens('settings_player', () => const SettingsPlayerScreen(), phones: one, scrolls: 2);
  screens('settings_decoder', () => const SettingsDecoderScreen(), phones: one, scrolls: 1);
  screens('settings_audio', () => const SettingsAudioScreen(), phones: one, scrolls: 1);
  screens('settings_subtitle', () => const SettingsSubtitleScreen(), phones: one, scrolls: 1);
  screens('settings_list', () => const SettingsListScreen(), phones: one, scrolls: 1);
  screens('settings_language', () => const SettingsLanguageScreen(), phones: one);
  screens('player_controls', () => const PlayerControlsScreen(), phones: one, scrolls: 1);
  screens('player_style', () => const PlayerStyleScreen(), phones: one, scrolls: 1);
  screens('subtitle_text', () => const SubtitleTextScreen(), phones: one, scrolls: 1);

  screens('about', () => const AboutScreen(), phones: one, scrolls: 1);
  screens('help', () => const HelpScreen(), phones: one, scrolls: 1);
  screens('theme', () => const AppThemeScreen(), phones: one);
  screens('backup', () => const BackupRestoreScreen(), phones: one);
  // Synthetic storage figures: a 128 GB phone, 41 GB free.
  screens('media_manager', () => const MediaManagerScreen(),
      overrides: () => [
            ...libraryOverrides(),
            storageSummaryProvider.overrideWith((ref) async => const StorageSummary(
                total: 128 << 30, free: 41 << 30, video: 52 << 30, audio: 3 << 30, image: -1)),
          ],
      phones: one);
  screens('statistics', () => const StatisticsScreen(), overrides: libraryOverrides, phones: one);
  screens('status_saver', () => const StatusSaverScreen(), phones: one);
  screens('private_folder', () => const PrivateFolderScreen());
  screens('downloader', () => const DownloaderHomeScreen(), phones: one);
  screens('update', () => const AppUpdateScreen(), phones: one);
}
