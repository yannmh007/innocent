import 'access.dart';
import 'content_category.dart';
import 'content_filters.dart';

/// WHERE a piece of media physically lives, expressed so the app never needs
/// to know.
///
/// This is the whole point of the storage-adapter design: the UI holds a
/// [MediaRef], asks the repository to turn it into a playable URL, and the
/// repository picks whichever backend is healthy. Swapping the backend — or
/// failing over from one to another — changes the adapter behind the
/// repository and touches NO widget.
///
/// [provider] is an opaque key ('telegram', 'bunny', 'storj', ...). [locator]
/// is whatever that provider needs (a Telegram message id, an object key, a
/// video id). [meta] carries the extra bits one provider needs and another
/// does not (e.g. Telegram's chat id) without leaking those fields into every
/// other provider's shape.
class MediaRef {
  final String provider;
  final String locator;
  final Map<String, String> meta;

  const MediaRef({
    required this.provider,
    required this.locator,
    this.meta = const <String, String>{},
  });

  /// A ref that points at nothing — used by mock/demo entries so the UI can
  /// be built and reviewed before any backend exists.
  static const MediaRef none = MediaRef(provider: 'none', locator: '');

  bool get isEmpty => provider == 'none' || locator.isEmpty;

  MediaRef copyWith({
    String? provider,
    String? locator,
    Map<String, String>? meta,
  }) {
    return MediaRef(
      provider: provider ?? this.provider,
      locator: locator ?? this.locator,
      meta: meta ?? this.meta,
    );
  }

  @override
  String toString() => 'MediaRef($provider:$locator)';
}

/// What a single item inside a content album is.
enum MediaKind { video, photo }

/// One entry inside a content detail album — the Telegram-style mixed grid of
/// stills and clips that sits behind a poster.
class AlbumItem {
  final String id;
  final MediaKind kind;

  /// Full-size / playable source.
  final MediaRef source;

  /// Small still used in the grid. Kept SEPARATE from [source] on purpose:
  /// a grid of thirty items must never fetch thirty full-size files, and the
  /// thumbnail may well live on a different provider from the video.
  final MediaRef thumbnail;

  /// Duration in seconds for [MediaKind.video]; null for photos.
  final int? durationSec;

  /// Free to open even inside a premium title - the trailer slot.
  ///
  /// One explicit flag rather than a rule like "the first clip is free":
  /// which clip is the taste is an editorial choice, and the shortest or
  /// first-uploaded one is rarely the one that sells the title.
  final bool isPreview;

  final int? width;
  final int? height;

  const AlbumItem({
    required this.id,
    required this.kind,
    required this.source,
    this.thumbnail = MediaRef.none,
    this.durationSec,
    this.isPreview = false,
    this.width,
    this.height,
  });

  bool get isVideo => kind == MediaKind.video;

  /// mm:ss badge for the grid corner; empty for photos and unknown lengths.
  String get durationLabel {
    final d = durationSec;
    if (d == null || d <= 0) return '';
    final h = d ~/ 3600;
    final m = (d % 3600) ~/ 60;
    final s = d % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// A catalogue entry — one poster in the grid, one card in a row.
class VideoContent {
  final String id;
  final String title;

  /// Localized title shown when the active locale has one. Null falls back to
  /// [title] rather than showing a blank.
  final String? titleMm;

  final String? synopsis;
  final ContentCategory category;

  /// Poster art. A [MediaRef] like everything else, so posters can move
  /// providers independently of the video they advertise.
  final MediaRef poster;

  final int? year;

  /// 0-10, as shown on the poster corner. Null hides the badge.
  final double? rating;

  /// '4K', 'HD', 'CAM' — shown as the top-left corner badge. Null hides it.
  final String? qualityLabel;

  final List<String> genres;

  /// Total episodes for a series; null for a single film.
  final int? episodeCount;

  /// How many times this entry has been opened, by anyone - free or premium.
  ///
  /// THE definition, kept in one place because a view count means nothing
  /// until somebody says what a view is: opening this title's detail screen,
  /// counted once per title per app session. Not a scroll past it, not a
  /// second look ten seconds later.
  ///
  /// It replaced a star rating on the cards. A rating answers "was it good?",
  /// which needs a crowd to have voted before it means anything, and a new
  /// catalogue has nobody. This answers "are people watching it?", which is
  /// true from the first tap.
  final int? viewCount;

  /// The primary playable source (a film, or a series' first episode).
  final MediaRef source;

  /// What this title requires of the viewer.
  ///
  /// Data, not code: which titles are free changes for commercial reasons and
  /// must never require a rebuild.
  final AccessTier accessTier;

  /// The mixed photo/video album behind this entry. May be empty — a plain
  /// film has a poster and a stream and nothing else.
  ///
  /// Loaded only on the detail screen. Grid cards never carry it: fetching
  /// thirty albums to draw thirty cards is thirty times the payload for two
  /// small numbers.
  final List<AlbumItem> items;

  /// How many stills and clips this title holds.
  ///
  /// SERVER-SUPPLIED, not counted from [items], for two reasons. A grid card
  /// has no items to count. And the album GROWS - the operator adds stills and
  /// short clips to a title long after publishing it - so a number derived
  /// from whatever the client happens to have loaded would be a different
  /// number on every screen.
  ///
  /// Null means unknown; the card then shows nothing rather than a confident
  /// zero, because "0 photos" and "we have not been told" look identical to a
  /// user and only one of them is true.
  final int? photoCount;
  final int? videoCount;

  const VideoContent({
    required this.id,
    required this.title,
    required this.category,
    this.titleMm,
    this.synopsis,
    this.poster = MediaRef.none,
    this.year,
    this.rating,
    this.qualityLabel,
    this.genres = const <String>[],
    this.episodeCount,
    this.viewCount,
    this.source = MediaRef.none,
    this.items = const <AlbumItem>[],
    this.accessTier = AccessTier.free,
    this.photoCount,
    this.videoCount,
  });

  /// Counts to display: the server's numbers when it gave any, otherwise a
  /// count of what IS loaded. Never a zero invented out of nothing.
  int? get displayPhotoCount =>
      photoCount ?? (items.isEmpty ? null : items.where((i) => !i.isVideo).length);

  int? get displayVideoCount =>
      videoCount ?? (items.isEmpty ? null : items.where((i) => i.isVideo).length);

  /// Returns this entry with its album attached.
  ///
  /// A second narrow copier rather than a general `copyWith`, for the reason
  /// the next comment gives: a wide copyWith invites call sites to rebuild the
  /// whole entity and quietly drop a field. This one touches [items] and
  /// nothing else.
  ///
  /// [photoCount] and [videoCount] are deliberately NOT recomputed from the
  /// album. The server's numbers count everything in the folder; the album
  /// holds only what this screen loaded. Overwriting the first with the second
  /// would make the card's badge shrink when the detail screen opens.
  VideoContent withAlbum(List<AlbumItem> album) {
    if (album.isEmpty) return this;
    return VideoContent(
      id: id,
      title: title,
      category: category,
      titleMm: titleMm,
      synopsis: synopsis,
      poster: poster,
      year: year,
      rating: rating,
      qualityLabel: qualityLabel,
      genres: genres,
      episodeCount: episodeCount,
      viewCount: viewCount,
      source: source,
      items: album,
      accessTier: accessTier,
      photoCount: photoCount,
      videoCount: videoCount,
    );
  }

  /// Only the view count changes - deliberately not a general copyWith.
  ///
  /// A full copyWith on an entity this wide invites call sites to rebuild it
  /// with three fields changed and one silently dropped. This can only do the
  /// one thing that legitimately changes while the app is open.
  VideoContent copyWithViews(int views) => VideoContent(
        id: id,
        title: title,
        category: category,
        titleMm: titleMm,
        synopsis: synopsis,
        poster: poster,
        year: year,
        rating: rating,
        qualityLabel: qualityLabel,
        genres: genres,
        episodeCount: episodeCount,
        viewCount: views,
        source: source,
        items: items,
        accessTier: accessTier,
        photoCount: photoCount,
        videoCount: videoCount,
      );

  bool get isSeries => category == ContentCategory.series;
  bool get hasAlbum => items.isNotEmpty;

  /// True when this entry is playable straight from the poster (no album to
  /// choose from first).
  bool get isDirectlyPlayable => !items.isNotEmpty && !source.isEmpty;

  /// The title to SHOW, given the language the app is running in.
  ///
  /// audit_video_hub.md M5. `titleMm` was selected from the server, arrived on
  /// every catalogue request, was parsed into this class — and rendered by
  /// nothing. Every render site used [title]. So the app fetched the Burmese
  /// title on every request and showed the English one to an audience that is
  /// mostly Burmese.
  ///
  /// Takes the language code rather than a BuildContext so it stays pure and
  /// testable, and so a widget cannot accidentally read a different locale
  /// than the one the rest of the screen is using.
  ///
  /// Falls back to [title] on a blank or whitespace-only `title_mm`, because a
  /// row where somebody saved an empty string must not render as a nameless
  /// card.
  String displayTitle(String? languageCode) {
    if (languageCode != 'my') return title;
    final mm = titleMm?.trim();
    return (mm == null || mm.isEmpty) ? title : mm;
  }

  /// Lowercased haystack used by search. Built once per entry rather than per
  /// keystroke — a 3000-title catalogue re-lowercasing four fields on every
  /// character is the classic search stutter.
  String get searchHaystack => <String>[
        title,
        titleMm ?? '',
        genres.join(' '),
        year?.toString() ?? '',
        category.fallbackLabel,
      ].join(' ').toLowerCase();
}

/// Stable identifiers for the landing rows.
///
/// Constants rather than bare strings: the key is the identity of a row across
/// the repository, the localized heading lookup, the See-all screen and the
/// paging cache. A typo in any one of those is a silently empty screen, and a
/// typo in a `const` is a compile error.
const String kRowTrending = 'rowTrending';
const String kRowNewReleases = 'rowNewReleases';
const String kRowMovies = 'rowMovies';
const String kRowSeries = 'rowSeries';
const String kRowReels = 'rowReels';

/// One horizontally-scrolling row on the "All" tab.
///
/// The row's title is carried as a [key] rather than as text so the row can be
/// localized at build time — a row labelled from the server would be stuck in
/// whatever language the server chose.
class ContentRow {
  final String key;
  final String fallbackTitle;
  final List<VideoContent> items;

  /// Order the full list should open in when the user taps See all. A row is
  /// a sample of a specific ordering, so opening it in a different one would
  /// show a different set of titles than the row advertised.
  final ContentSort defaultSort;

  /// Draw 1..n numerals on the cards. True for rows whose whole point is the
  /// ordering (trending); false where the order is incidental.
  final bool ranked;

  const ContentRow({
    required this.key,
    required this.fallbackTitle,
    required this.items,
    this.defaultSort = ContentSort.newest,
    this.ranked = false,
  });

  bool get isEmpty => items.isEmpty;
}

/// A page of catalogue results. Carries [hasMore] so the grid can page without
/// the caller having to compare lengths against a page size it doesn't own.
class ContentPage {
  final List<VideoContent> items;
  final bool hasMore;
  final int totalCount;

  const ContentPage({
    required this.items,
    this.hasMore = false,
    this.totalCount = 0,
  });

  static const ContentPage empty =
      ContentPage(items: <VideoContent>[], hasMore: false, totalCount: 0);
}
