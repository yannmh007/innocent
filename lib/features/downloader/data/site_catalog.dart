import 'package:flutter/material.dart';

/// A tile on the downloader home grid.
///
/// There is deliberately NO icon asset and no favicon fetch here. Two reasons,
/// both practical:
///
///  1. Bundling YouTube/TikTok/Instagram logos in the APK is someone else's
///     trademark sitting in our binary, and it grows the app for decoration.
///  2. Pulling favicons at runtime means sending the list of sites the user
///     cares about to a third-party icon service. With adult sites in the same
///     grid that is a real privacy leak, not a theoretical one.
///
/// So tiles are monograms in the site's own brand colour: zero assets, zero
/// network, no leak, and they render instantly on a cold start.
@immutable
class DownloadSite {
  const DownloadSite({
    required this.id,
    required this.name,
    required this.url,
    required this.color,
    this.restricted = false,
  });

  final String id;
  final String name;

  /// Mobile-friendly landing page. Opened in the user's browser so they can
  /// find a video and copy its link.
  final String url;

  final Color color;

  /// Adult sites. Hidden unless the user turns them on.
  final bool restricted;

  /// Monogram shown on the tile.
  String get initial => name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
}

/// Where to send someone to sign in, and whose cookies to keep afterwards.
@immutable
class SignInTarget {
  const SignInTarget({
    required this.label,
    required this.url,
    required this.cookieUrls,
  });

  final String label;
  final String url;
  final List<String> cookieUrls;
}

/// Sign-in destinations, chosen by the host of the link that failed.
///
/// Each one lists more origins than the page you land on, because a session is
/// rarely confined to a single domain — Google's lives across accounts.google
/// and youtube, and TikTok's across the www and m hosts.
class SignInTargets {
  SignInTargets._();

  /// The no-login destination: just the site's front page. Loading it is
  /// enough to be issued a guest session.
  static const SignInTarget youtubeGuest = SignInTarget(
    label: 'YouTube',
    url: 'https://m.youtube.com',
    cookieUrls: <String>[
      'https://www.youtube.com',
      'https://m.youtube.com',
    ],
  );

  static const SignInTarget tiktokGuest = SignInTarget(
    label: 'TikTok',
    url: 'https://www.tiktok.com',
    cookieUrls: <String>[
      'https://www.tiktok.com',
      'https://m.tiktok.com',
    ],
  );

  /// The guest destination for a link, or null when we know of none.
  static SignInTarget? guestForUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    final String host = uri.host.toLowerCase();
    if (host.endsWith('youtube.com') ||
        host.endsWith('youtu.be') ||
        host.endsWith('youtube-nocookie.com')) {
      return youtubeGuest;
    }
    if (host.endsWith('tiktok.com')) return tiktokGuest;
    return null;
  }

  static const SignInTarget youtube = SignInTarget(
    label: 'YouTube',
    url: 'https://m.youtube.com',
    cookieUrls: <String>[
      'https://www.youtube.com',
      'https://m.youtube.com',
      'https://accounts.google.com',
      'https://www.google.com',
    ],
  );

  static const SignInTarget tiktok = SignInTarget(
    label: 'TikTok',
    url: 'https://www.tiktok.com/login',
    cookieUrls: <String>[
      'https://www.tiktok.com',
      'https://m.tiktok.com',
    ],
  );

  static const SignInTarget instagram = SignInTarget(
    label: 'Instagram',
    url: 'https://www.instagram.com/accounts/login/',
    cookieUrls: <String>['https://www.instagram.com'],
  );

  static const SignInTarget facebook = SignInTarget(
    label: 'Facebook',
    url: 'https://m.facebook.com/login',
    cookieUrls: <String>[
      'https://www.facebook.com',
      'https://m.facebook.com',
    ],
  );

  /// The right destination for a link, or null when the site isn't one we
  /// know a sign-in page for — in which case the generic browser is offered
  /// instead of a guess.
  static SignInTarget? forUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    final String host = uri.host.toLowerCase();
    if (host.endsWith('youtube.com') ||
        host.endsWith('youtu.be') ||
        host.endsWith('youtube-nocookie.com')) {
      return youtube;
    }
    if (host.endsWith('tiktok.com')) return tiktok;
    if (host.endsWith('instagram.com')) return instagram;
    if (host.endsWith('facebook.com') || host.endsWith('fb.watch')) {
      return facebook;
    }
    return null;
  }
}

/// The built-in list. Every entry is a site yt-dlp has a dedicated extractor
/// for, so a link copied from any of them resolves with a real quality list
/// rather than falling back to guesswork.
class SiteCatalog {
  SiteCatalog._();

  static const List<DownloadSite> general = <DownloadSite>[
    DownloadSite(
      id: 'youtube',
      name: 'YouTube',
      url: 'https://m.youtube.com',
      color: Color(0xFFE53935),
    ),
    DownloadSite(
      id: 'facebook',
      name: 'Facebook',
      url: 'https://m.facebook.com/watch',
      color: Color(0xFF1877F2),
    ),
    DownloadSite(
      id: 'tiktok',
      name: 'TikTok',
      url: 'https://www.tiktok.com',
      color: Color(0xFF25F4EE),
    ),
    DownloadSite(
      id: 'instagram',
      name: 'Instagram',
      url: 'https://www.instagram.com',
      color: Color(0xFFE1306C),
    ),
    DownloadSite(
      id: 'x',
      name: 'X',
      url: 'https://x.com',
      color: Color(0xFF9E9E9E),
    ),
    DownloadSite(
      id: 'dailymotion',
      name: 'Dailymotion',
      url: 'https://www.dailymotion.com',
      color: Color(0xFF0066DC),
    ),
    DownloadSite(
      id: 'vimeo',
      name: 'Vimeo',
      url: 'https://vimeo.com',
      color: Color(0xFF1AB7EA),
    ),
    DownloadSite(
      id: 'soundcloud',
      name: 'SoundCloud',
      url: 'https://m.soundcloud.com',
      color: Color(0xFFFF5500),
    ),
    DownloadSite(
      id: 'reddit',
      name: 'Reddit',
      url: 'https://www.reddit.com',
      color: Color(0xFFFF4500),
    ),
    DownloadSite(
      id: 'twitch',
      name: 'Twitch',
      url: 'https://m.twitch.tv',
      color: Color(0xFF9146FF),
    ),
    DownloadSite(
      id: 'bilibili',
      name: 'Bilibili',
      url: 'https://m.bilibili.com',
      color: Color(0xFF00A1D6),
    ),
    DownloadSite(
      id: 'pinterest',
      name: 'Pinterest',
      url: 'https://www.pinterest.com',
      color: Color(0xFFBD081C),
    ),
    // ---- added Aug 2026 --------------------------------------------------
    // The grid is DISCOVERY, not capability. Any link this engine understands
    // already works when pasted — roughly eighteen hundred sites — and the
    // twelve tiles here were quietly teaching people the opposite. These are
    // the platforms most likely to be in a Myanmar phone's browser history,
    // plus the ones people arrive expecting a downloader to handle.
    DownloadSite(
      id: 'likee',
      name: 'Likee',
      url: 'https://likee.video',
      color: Color(0xFFFFCC00),
    ),
    DownloadSite(
      id: 'kuaishou',
      name: 'Kwai',
      url: 'https://www.kwai.com',
      color: Color(0xFFFF6600),
    ),
    DownloadSite(
      id: 'snapchat',
      name: 'Snapchat',
      url: 'https://www.snapchat.com/spotlight',
      color: Color(0xFFFFFC00),
    ),
    DownloadSite(
      id: 'linkedin',
      name: 'LinkedIn',
      url: 'https://www.linkedin.com/feed',
      color: Color(0xFF0A66C2),
    ),
    DownloadSite(
      id: 'tumblr',
      name: 'Tumblr',
      url: 'https://www.tumblr.com',
      color: Color(0xFF36465D),
    ),
    DownloadSite(
      id: 'rumble',
      name: 'Rumble',
      url: 'https://rumble.com',
      color: Color(0xFF85C742),
    ),
    DownloadSite(
      id: 'odysee',
      name: 'Odysee',
      url: 'https://odysee.com',
      color: Color(0xFFFA6165),
    ),
    DownloadSite(
      id: 'ok',
      name: 'OK.ru',
      url: 'https://ok.ru/video',
      color: Color(0xFFEE8208),
    ),
    DownloadSite(
      id: 'vk',
      name: 'VK',
      url: 'https://vk.com/video',
      color: Color(0xFF0077FF),
    ),
    DownloadSite(
      id: 'nicovideo',
      name: 'Niconico',
      url: 'https://www.nicovideo.jp',
      color: Color(0xFF252525),
    ),
    DownloadSite(
      id: 'youku',
      name: 'Youku',
      url: 'https://www.youku.com',
      color: Color(0xFF1CC0F3),
    ),
    DownloadSite(
      id: 'iqiyi',
      name: 'iQIYI',
      url: 'https://www.iq.com',
      color: Color(0xFF00BE06),
    ),
    DownloadSite(
      id: 'mixcloud',
      name: 'Mixcloud',
      url: 'https://www.mixcloud.com',
      color: Color(0xFF314359),
    ),
    DownloadSite(
      id: 'bandcamp',
      name: 'Bandcamp',
      url: 'https://bandcamp.com',
      color: Color(0xFF629AA9),
    ),
    DownloadSite(
      id: 'archive',
      name: 'Archive',
      url: 'https://archive.org/details/movies',
      color: Color(0xFF666666),
    ),
    DownloadSite(
      id: 'ted',
      name: 'TED',
      url: 'https://www.ted.com/talks',
      color: Color(0xFFE62B1E),
    ),
  ];

  /// Off by default; revealed by a switch in the downloader's own settings.
  static const List<DownloadSite> restricted = <DownloadSite>[
    DownloadSite(
      id: 'pornhub',
      name: 'Pornhub',
      url: 'https://www.pornhub.com',
      color: Color(0xFFFF9000),
      restricted: true,
    ),
    DownloadSite(
      id: 'xvideos',
      name: 'XVideos',
      url: 'https://www.xvideos.com',
      color: Color(0xFFC9382B),
      restricted: true,
    ),
    DownloadSite(
      id: 'xnxx',
      name: 'XNXX',
      url: 'https://www.xnxx.com',
      color: Color(0xFF3F6FB0),
      restricted: true,
    ),
    DownloadSite(
      id: 'xhamster',
      name: 'xHamster',
      url: 'https://xhamster.com',
      color: Color(0xFFE58C24),
      restricted: true,
    ),
    DownloadSite(
      id: 'redtube',
      name: 'RedTube',
      url: 'https://www.redtube.com',
      color: Color(0xFFD32F2F),
      restricted: true,
    ),
    DownloadSite(
      id: 'youporn',
      name: 'YouPorn',
      url: 'https://www.youporn.com',
      color: Color(0xFF8E24AA),
      restricted: true,
    ),
    DownloadSite(
      id: 'spankbang',
      name: 'SpankBang',
      url: 'https://spankbang.com',
      color: Color(0xFFEE7700),
      restricted: true,
    ),
    DownloadSite(
      id: 'eporner',
      name: 'Eporner',
      url: 'https://www.eporner.com',
      color: Color(0xFFE95C20),
      restricted: true,
    ),
    DownloadSite(
      id: 'tnaflix',
      name: 'TNAFlix',
      url: 'https://www.tnaflix.com',
      color: Color(0xFF9B59B6),
      restricted: true,
    ),
    DownloadSite(
      id: 'motherless',
      name: 'Motherless',
      url: 'https://motherless.com',
      color: Color(0xFF5A5A5A),
      restricted: true,
    ),
    DownloadSite(
      id: 'txxx',
      name: 'TXXX',
      url: 'https://txxx.com',
      color: Color(0xFFD32F2F),
      restricted: true,
    ),
    DownloadSite(
      id: 'hqporner',
      name: 'HQporner',
      url: 'https://hqporner.com',
      color: Color(0xFF00A6A6),
      restricted: true,
    ),
  ];

  static List<DownloadSite> get all =>
      <DownloadSite>[...general, ...restricted];

  /// Default favourites for a first run — the four most-asked-for sites.
  static const List<String> defaultFavourites = <String>[
    'youtube',
    'facebook',
    'tiktok',
    'instagram',
  ];

  static DownloadSite? byId(String id) {
    for (final DownloadSite s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}
