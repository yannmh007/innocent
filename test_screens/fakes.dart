// Sample content for screenshots: the shapes real phones hold, including
// the awkward ones (long Burmese names, a 3-hour film, a 4 GB file).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:innocent/features/local_browser/domain/folder.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:innocent/features/music/domain/song.dart';
import 'package:innocent/features/music/presentation/music_providers.dart';
import 'package:innocent/features/video_hub/data/demo_content_datasource.dart';
import 'package:innocent/features/video_hub/data/demo_content_repository.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';

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
      videosInFolderProvider.overrideWith((ref, path) async =>
          videos().where((v) => v.folderPath == path).toList()),
    ];

/// A real album's shape (from the live catalogue, 2026-10-03): portrait and
/// square stills, a long portrait clip, landscape clips — with the blurhash
/// previews the server sends, so the data saver's frost is the real frost.
List<AlbumItem> albumItems() {
  const photos = <(String, int, int)>[
    ('TGCsBf%M?b~Wt7%MHrRPIUIARjD%', 1080, 2096),
    ('TSEMB=Mdxa?^WmR*I:xtjFsqV@s:', 719, 1280),
    ('LCFYV|Mwpc9Z.lI.sCjbof?bI9?a', 960, 960),
    ('T8CP9V?H0~L2Nc={-;\$Mw]%MsmIp', 960, 1280),
    ('TB7__=xEEk9FNKrqmPoJxCT|axSh', 957, 1280),
    ('TML4H8xs~W?ct7NGNdWXIBRkRjRj', 962, 1280),
    ('TaGuK|%2gN~Vt7%MtlR*-V%LfkxG', 719, 1280),
    ('ThH2o}xu?v~pIUxuW.RkxaE1M|M_', 763, 1280),
  ];
  const clips = <(String, int, int, int)>[
    ('TXCGPtxaoz~qspt7-;WBt7t7R+of', 720, 1280, 1109),
    ('LZHBoC\$%S4X900tRaeMx%gozRjM{', 640, 360, 4279),
    ('LTH.B8I]J9?w?c%h-?WD-;WCM{a#', 1280, 720, 630),
  ];
  return <AlbumItem>[
    for (final (i, c) in clips.indexed)
      AlbumItem(
        id: 'clip$i',
        kind: MediaKind.video,
        source: MediaRef(provider: 'url', locator: 'https://media.test/c$i.mp4'),
        thumbnail: MediaRef(provider: 'url', locator: 'https://media.test/c$i.jpg'),
        width: c.$2,
        height: c.$3,
        durationSec: c.$4,
        bytes: 120000000 + i * 90000000,
        preview: c.$1,
      ),
    for (final (i, p) in photos.indexed)
      AlbumItem(
        id: 'photo$i',
        kind: MediaKind.photo,
        source: MediaRef(provider: 'url', locator: 'https://media.test/p$i.jpg'),
        width: p.$2,
        height: p.$3,
        bytes: 150000 + i * 20000,
        preview: p.$1,
      ),
  ];
}

/// The demo catalogue, except that every title's detail carries [albumItems].
class AlbumDemoRepository extends DemoContentRepository {
  @override
  Future<VideoContent?> getById(String id) async {
    final c = await super.getById(id);
    return c?.withAlbum(albumItems());
  }
}

VideoContent albumTitle() =>
    const DemoContentDataSource().all().first.withAlbum(albumItems());

/// A shelf with what a real one holds: two films, an album's photos and a
/// clip, one download half-way and one paused.
List<Override> downloadsOverrides() {
  final now = DateTime(2026, 10, 3, 12);
  OfflineItem film(String id, String t, int mb, int mins, {String? mm}) => OfflineItem(
        titleId: id,
        key: id,
        title: t,
        titleMm: mm,
        path: '/data/$id.mp4',
        bytes: mb * 1024 * 1024,
        durationS: mins * 60,
        addedAt: now.subtract(Duration(hours: mins)),
      );
  final items = <OfflineItem>[
    film('f1', 'Inception', 1450, 148),
    film('f2', 'The Lord of the Rings: The Return of the King (Extended)', 3900, 263),
    film('f3', 'Chit Thu Eain', 820, 95, mm: 'ချစ်သူ့အိမ် — ဇာတ်ကားအပြည့်'),
    for (var i = 0; i < 5; i++)
      OfflineItem(
        titleId: 'a1',
        key: 'a1.p$i',
        kind: 'photo',
        title: 'Yangon Evening',
        titleMm: 'ရန်ကုန် ညနေခင်း',
        path: '/data/a1.p$i.jpg',
        bytes: 180000 + i * 20000,
        addedAt: now,
      ),
    OfflineItem(
      titleId: 'a1',
      key: 'a1.c0',
      title: 'Yangon Evening',
      titleMm: 'ရန်ကုန် ညနေခင်း',
      path: '/data/a1.c0.mp4',
      bytes: 120 * 1024 * 1024,
      durationS: 630,
      assetId: 'c0',
      addedAt: now,
    ),
  ];
  final pending = <PendingProgress>[
    PendingProgress(
      item: PendingDownload(titleId: 'p1', title: 'Interstellar', startedAt: now),
      received: 640 * 1024 * 1024,
      total: 1700 * 1024 * 1024,
    ),
    PendingProgress(
      item: PendingDownload(
          titleId: 'p2', title: 'Myanmar Drama Ep 1', startedAt: now, pausedByUser: true),
      received: 90 * 1024 * 1024,
      total: 400 * 1024 * 1024,
    ),
  ];
  return [
    offlineItemsProvider.overrideWith((ref) async => items),
    offlinePendingProvider.overrideWith((ref) async => pending),
    offlineStorageProvider.overrideWith(
        (ref) async => (used: 6400 * 1024 * 1024, free: 23 * 1024 * 1024 * 1024)),
  ];
}
