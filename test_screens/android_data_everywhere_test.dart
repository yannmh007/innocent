import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';
import 'package:innocent/features/android_data/domain/file_kind.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:innocent/features/local_browser/presentation/local_screen.dart';
import 'package:innocent/features/me/presentation/me_screen.dart';
import 'package:innocent/features/private_folder/data/picker_media_source.dart';
import 'package:innocent/features/private_folder/data/picker_providers.dart';
import 'package:innocent/features/private_folder/presentation/add_files_picker.dart';
import 'package:innocent/features/shell/shell_screen.dart';

import 'fakes.dart';
import 'harness.dart';

/// Android/data's media where people look for media — the Video tab and the
/// pickers — once ADB is up, each marked Hidden.
const _tg = '$kAndroidDataRoot/org.telegram.messenger/files/Telegram';
const _tgCache = '$kAndroidDataRoot/org.telegram.messenger/cache';

List<Video> _adbVideos() => <Video>[
      for (final (i, t) in <String>[
        'ဇာတ်ကား အပိုင်း ၁.mp4',
        'Episode 12 1080p.mkv',
        'trailer.mp4',
      ].indexed)
        Video(
          id: 'adb:$_tg/Telegram Video/$t',
          uri: 'adb://$_tg/Telegram Video/$t',
          title: t,
          folderPath: '$_tg/Telegram Video',
          duration: Duration.zero,
          sizeBytes: <int>[734003200, 1288490188, 52428800][i],
          width: 0,
          height: 0,
        ),
    ];

/// The images an ADB `find` would turn up: Telegram's downloads, and its
/// cache of small previews, which is why the bucket groups by folder.
final List<String> _images = <String>[
  for (var i = 1; i <= 6; i++) '2457600|$_tg/Telegram Images/IMG_2026100$i.jpg',
  for (var i = 1; i <= 14; i++) '8192|$_tgCache/-60${i}1234_99.jpg',
  '1048576|$kAndroidDataRoot/com.viber.voip/files/.temp/photo.jpg',
];

void _fakeAdb() {
  // Photos permission granted, as on a phone that has used the picker.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.fluttercandies/photo_manager'),
          (call) async => call.method.contains('ermission') ? 3 : null);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('mx_clone/adb'),
          (call) async {
    switch (call.method) {
      case 'lastConnect':
        return '127.0.0.1:37123';
      case 'shell':
        final cmd = (call.arguments as Map)['command'] as String;
        if (cmd.startsWith('echo ok')) return 'ok';
        if (cmd.contains("-iname '*.jpg'")) return _images.join('\n');
        return '';
      default:
        return null;
    }
  });
}

List<Override> _overrides() => <Override>[
      ...libraryOverrides(),
      adbVideosProvider.overrideWith((ref) async => _adbVideos()),
      // The fakes' folder contents, plus Android/data's as the app merges
      // them in.
      videosInFolderProvider.overrideWith((ref, path) async => <Video>[
            ...videos().where((v) => v.folderPath == path),
            ..._adbVideos().where((v) => v.folderPath == path),
          ]),
      pickerImageFoldersProvider.overrideWith((ref) async => const [
            PickerMediaFolder(
                id: '1',
                path: '/storage/emulated/0/DCIM/Camera',
                name: 'Camera',
                count: 412,
                type: PickerAssetType.image),
            PickerMediaFolder(
                id: '2',
                path: '/storage/emulated/0/Pictures/Screenshots',
                name: 'Screenshots',
                count: 88,
                type: PickerAssetType.image),
          ]),
    ];

Widget _picker() {
  _fakeAdb();
  AdbService.instance.live.value = true;
  return AddFilesPicker(onCommit: (_) async {}, title: 'Send');
}

Future<void> _openImages(WidgetTester t) async {
  await t.tap(find.byIcon(Icons.image_outlined).first);
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  // The Video tab: Telegram's folder among the phone's own, marked Hidden.
  screens('adb_everywhere_video_tab', () {
    _fakeAdb();
    return const ShellScreen(child: LocalScreen());
  }, overrides: _overrides, scrolls: 1);

  // A picker's Videos: the same folder, with its badge and cover.
  screens('adb_everywhere_picker_videos', _picker, overrides: _overrides);

  // Inside it: the videos, each marked.
  screens('adb_everywhere_picker_videos_in', _picker,
      overrides: _overrides, act: (t) async {
    await t.tap(find.text('Telegram Video').last);
  });

  // Images: "Inside apps" first, then the phone's own albums.
  screens('adb_everywhere_picker_images', _picker,
      overrides: _overrides, act: _openImages);

  // Inside "Inside apps": its folders, the fullest first.
  screens('adb_everywhere_picker_images_apps', _picker,
      overrides: _overrides, act: (t) async {
    await _openImages(t);
    await t.tap(find.textContaining('Android/data').first);
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  });

  // Me: the Hidden files row says it is connected.
  screens('adb_everywhere_me_live', () {
    _fakeAdb();
    AdbService.instance.live.value = true;
    return const MeScreen();
  });
}
