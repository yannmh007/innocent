import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/app_version.dart';
import 'package:innocent/features/about/about_screen.dart';
import 'package:innocent/features/updater/data/update_check_service.dart';
import 'package:innocent/features/updater/domain/app_release.dart';

import 'harness.dart';

/// The release row, without the network.
class _Fixed extends UpdateCheckService {
  const _Fixed(this.release);
  final AppRelease? release;
  @override
  Future<AppRelease?> fetchLatest() async => release;
}

// Me → About: up to date (with this version's notes), and with an update.
void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  const notes = AppRelease(
    versionName: AppVersion.name,
    versionCode: AppVersion.build,
    notesEn: 'TalkBack reads every player control.\nResume where you left off.',
    notesMm: 'TalkBack က player ခလုတ်တိုင်းကို ဖတ်ပြပါပြီ။\nရပ်ခဲ့တဲ့နေရာကနေ ဆက်ကြည့်နိုင်ပါပြီ။',
  );
  const newer = AppRelease(versionName: '9.9.9', versionCode: 9999);

  screens('about', () => const AboutScreen(checkService: _Fixed(notes)),
      locales: const [Locale('my'), Locale('en')], scrolls: 1);
  screens('about_update', () => const AboutScreen(checkService: _Fixed(newer)),
      phones: const [small], locales: const [Locale('my')]);
}
