// Sample content for screenshots: the shapes real phones hold, including
// the awkward ones (long Burmese names, a 3-hour film, a 4 GB file).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:innocent/features/local_browser/domain/folder.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:innocent/features/music/domain/song.dart';
import 'package:innocent/features/music/presentation/music_providers.dart';

final _now = DateTime(2026, 10, 3, 12);

const folders = <Folder>[
  Folder(path: '/storage/emulated/0/Movies', name: 'Movies', videoCount: 42, newCount: 3, totalSizeBytes: 38654705664),
  Folder(path: '/storage/emulated/0/Download', name: 'Download', videoCount: 17, totalSizeBytes: 9663676416),
  Folder(path: '/storage/emulated/0/Telegram/Telegram Video', name: 'Telegram Video', videoCount: 128, newCount: 12, totalSizeBytes: 21474836480),
  Folder(path: '/storage/emulated/0/DCIM/Camera', name: 'Camera', videoCount: 9, totalSizeBytes: 2147483648),
  Folder(path: '/storage/emulated/0/Bioscope', name: 'မြန်မာ ဇာတ်ကားကောင်းများ စုစည်းမှု 2026', videoCount: 6, totalSizeBytes: 12884901888),
  Folder(path: '/storage/emulated/0/WhatsApp/Media/WhatsApp Video', name: 'WhatsApp Video', videoCount: 61, totalSizeBytes: 1073741824),
];

List<Video> videos() => [
      for (final (i, t) in [
        'Inception.2010.1080p.BluRay.x264.mkv',
        'ချစ်သူ့အိမ် (2025) — အပိုင်း ၁ မှ ၁၀ အထိ အပြည့်အစုံ.mp4',
        'VID_20261001_183244.mp4',
        'The.Lord.of.the.Rings.The.Return.of.the.King.Extended.2160p.mkv',
        'ရန်ကုန် ညနေခင်း.mp4',
        'Screen_Recording_20260930.mp4',
      ].indexed)
        Video(
          id: 'v$i',
          uri: '/storage/emulated/0/Movies/$t',
          title: t,
          folderPath: '/storage/emulated/0/Movies',
          duration: Duration(minutes: [148, 52, 1, 263, 7, 3][i], seconds: 12),
          sizeBytes: [2400000000, 900000000, 24000000, 4200000000, 61000000, 15000000][i],
          width: [1920, 1280, 1080, 3840, 720, 1080][i],
          height: [1080, 720, 1920, 2160, 1280, 2400][i],
          dateAdded: _now.subtract(Duration(days: i * 3)),
        ),
    ];

List<Song> songs() => [
      for (final (i, t) in [
        ('မင်းမရှိတဲ့ ညတွေ', 'Bobby Soxer'),
        ('Shape of You', 'Ed Sheeran'),
        ('ရင်ခုန်သံ (Acoustic Version) — တိုက်ရိုက်ဖျော်ဖြေမှု', 'ဝိုင်ဝိုင်း'),
        ('Blinding Lights', 'The Weeknd'),
        ('အမေ့ရင်ခွင်', 'Lay Phyu'),
      ].indexed)
        Song(
          id: 's$i',
          uri: '/storage/emulated/0/Music/${t.$1}.mp3',
          title: t.$1,
          artist: t.$2,
          album: 'Album $i',
          folderPath: '/storage/emulated/0/Music',
          duration: Duration(minutes: 3 + i, seconds: 21),
          sizeBytes: 8000000,
          dateAdded: _now.subtract(Duration(days: i)),
        ),
    ];

List<Override> libraryOverrides() => [
      foldersProvider.overrideWith((ref) async => folders),
      allVideosProvider.overrideWith((ref) async => videos()),
      allSongsProvider.overrideWith((ref) async => songs()),
    ];
