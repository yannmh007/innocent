import '../domain/access.dart';
import '../domain/content_category.dart';
import '../domain/video_content.dart';

/// A bundled, offline demo catalogue.
///
/// WHY THIS EXISTS: the Video Hub UI can be built, reviewed on a real phone
/// and signed off BEFORE any storage backend is chosen or paid for. Nothing
/// here touches the network, so the screens can be judged on layout, feel and
/// navigation alone.
///
/// Entries carry [MediaRef.none], so posters render as generated placeholder
/// tiles and playback shows the normal "unavailable" state. That is the
/// correct demo behaviour — a fake video URL would prove nothing and would
/// hide the real failure path.
///
/// Titles are deliberately generic placeholders, not real films.
class DemoContentDataSource {
  const DemoContentDataSource();

  static const List<String> _genrePool = <String>[
    'Action',
    'Drama',
    'Comedy',
    'Thriller',
    'Romance',
    'Horror',
    'Documentary',
    'Animation',
  ];

  /// The whole demo catalogue, generated once and cached for the process.
  static List<VideoContent>? _cache;

  List<VideoContent> all() => _cache ??= _build();

  static List<VideoContent> _build() {
    final out = <VideoContent>[];

    // --- Movies -----------------------------------------------------------
    for (int i = 0; i < 18; i++) {
      out.add(VideoContent(
        id: 'movie_$i',
        title: 'Demo Feature ${i + 1}',
        category: ContentCategory.movies,
        synopsis:
            'Placeholder synopsis for demo feature ${i + 1}. Replace with real '
            'catalogue data once a content backend is connected.',
        year: 2020 + (i % 7),
        rating: 5.0 + ((i * 7) % 50) / 10.0,
        qualityLabel: i % 4 == 0 ? '4K' : (i % 3 == 0 ? 'HD' : null),
        // Spread across the formatting thresholds on purpose, so the demo
        // shows 842, 4.1K, 37K and 1.2M side by side and the compact label is
        // actually exercised instead of always printing four digits.
        viewCount: _demoViews(i, 3),
        // Roughly one in three free, so both sides of the paywall are
        // reviewable without flipping a setting.
        accessTier: i % 3 == 0 ? AccessTier.free : AccessTier.premium,
        // Counts a real backend would supply per title. Varied so the card
        // layout is exercised at one, two and three digits.
        photoCount: 6 + (i * 3) % 40,
        videoCount: 1 + i % 5,
        genres: <String>[
          _genrePool[i % _genrePool.length],
          _genrePool[(i + 3) % _genrePool.length],
        ],
      ));
    }

    // --- Series -----------------------------------------------------------
    for (int i = 0; i < 12; i++) {
      out.add(VideoContent(
        id: 'series_$i',
        title: 'Demo Series ${i + 1}',
        category: ContentCategory.series,
        synopsis:
            'Placeholder synopsis for demo series ${i + 1}. Episodes appear '
            'here once the catalogue is wired to a backend.',
        year: 2021 + (i % 6),
        rating: 6.0 + ((i * 5) % 40) / 10.0,
        qualityLabel: i % 3 == 0 ? 'HD' : null,
        episodeCount: 6 + (i % 10),
        viewCount: _demoViews(i, 5),
        accessTier: i % 4 == 0 ? AccessTier.free : AccessTier.premium,
        photoCount: 10 + (i * 7) % 60,
        videoCount: 6 + (i % 10),
        genres: <String>[
          _genrePool[(i + 1) % _genrePool.length],
          _genrePool[(i + 5) % _genrePool.length],
        ],
      ));
    }

    // --- Reels — short clips, and the one category that shows a mixed album
    for (int i = 0; i < 10; i++) {
      out.add(VideoContent(
        id: 'reel_$i',
        title: 'Demo Clip ${i + 1}',
        category: ContentCategory.reels,
        year: 2025 + (i % 2),
        rating: i % 3 == 0 ? 7.0 + (i % 3) : null,
        viewCount: _demoViews(i, 7),
        accessTier: i % 2 == 0 ? AccessTier.free : AccessTier.premium,
        genres: <String>[_genrePool[(i + 2) % _genrePool.length]],
        items: _demoAlbum('reel_$i', photos: 8 + (i % 6), clips: 2 + (i % 3)),
        photoCount: 8 + (i % 6),
        videoCount: 2 + (i % 3),
      ));
    }

    return out;
  }

  /// Pseudo-random but STABLE view counts spanning 3 orders of magnitude.
  ///
  /// Stable matters: a count that changes on every rebuild makes it impossible
  /// to tell a real increment (someone opened a title) from noise.
  static int _demoViews(int i, int salt) {
    final n = (i * 7919 + salt * 104729) % 1000;
    if (i % 7 == 0) return 400 + n * 2;
    if (i % 3 == 0) return 1200 + n * 47;
    if (i % 5 == 0) return 90000 + n * 900;
    return 12000 + n * 130;
  }

  /// A Telegram-style mixed album: a run of stills with a few clips folded in.
  static List<AlbumItem> _demoAlbum(
    String parentId, {
    required int photos,
    required int clips,
  }) {
    final items = <AlbumItem>[];
    for (int p = 0; p < photos; p++) {
      items.add(AlbumItem(
        id: '${parentId}_p$p',
        kind: MediaKind.photo,
        source: MediaRef.none,
        width: 1080,
        height: 1350,
      ));
    }
    for (int v = 0; v < clips; v++) {
      items.insert(
        // Spread clips through the grid instead of trailing them, so the
        // mixed-media layout is actually exercised.
        ((v + 1) * items.length ~/ (clips + 1)).clamp(0, items.length),
        AlbumItem(
          id: '${parentId}_v$v',
          kind: MediaKind.video,
          source: MediaRef.none,
          // The first clip of every album is the trailer slot.
          isPreview: v == 0,
          durationSec: 25 + v * 40,
          width: 1080,
          height: 1920,
        ),
      );
    }
    return items;
  }
}
