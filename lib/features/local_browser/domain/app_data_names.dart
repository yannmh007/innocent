/// NAMES FOR FOLDERS INSIDE ANDROID/DATA, read over ADB.
///
/// The folder that holds an app's videos is usually called something like
/// `cache`, `files` or `video` — three apps' caches all read "cache" in the
/// Local list, with nothing to tell them apart. The package directory above
/// it says whose it is (`org.telegram.messenger`), and that is turned into
/// the app's name: "Telegram · cache". A folder whose own name already says
/// what it is ("Telegram Video") keeps it.
library;

/// The app a folder inside Android/data or Android/obb belongs to, by its
/// package name — or null when the path is not inside either.
String? appDataPackage(String path) {
  final m = RegExp(r'/Android/(?:data|obb)/([^/]+)').firstMatch(path);
  return m?.group(1);
}

/// A person's name for [package]: the app's own name for the ones people in
/// Myanmar keep videos in, otherwise the most telling word of the package.
String appLabelForPackage(String package) {
  final known = _known[package];
  if (known != null) return known;
  final words = package
      .split('.')
      .where((w) => w.isNotEmpty && !_noise.contains(w.toLowerCase()))
      .toList();
  if (words.isEmpty) return package;
  final w = words.last;
  return w[0].toUpperCase() + w.substring(1);
}

/// The Local list's name for an Android/data (or obb) folder at [path].
String appDataFolderName(String path) {
  final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final base = trimmed.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
  final pkg = appDataPackage(trimmed);
  if (pkg == null) return base;
  final label = appLabelForPackage(pkg);
  if (base == pkg) return label;
  // A dot folder (".temp", ".cache") says no more about whose it is than
  // its plain name would; it read as a bare ".temp" in the pickers.
  if (base.startsWith('.') ||
      _generic.contains(base.toLowerCase()) ||
      !RegExp(r'[A-Za-z]{3}').hasMatch(base)) {
    return '$label · $base';
  }
  return base;
}

const Map<String, String> _known = <String, String>{
  'org.telegram.messenger': 'Telegram',
  'org.telegram.messenger.web': 'Telegram',
  'org.telegram.messenger.beta': 'Telegram Beta',
  'org.thunderdog.challegram': 'Telegram X',
  'org.telegram.plus': 'Plus Messenger',
  'com.facebook.katana': 'Facebook',
  'com.facebook.lite': 'Facebook Lite',
  'com.facebook.orca': 'Messenger',
  'com.facebook.mlite': 'Messenger Lite',
  'com.viber.voip': 'Viber',
  'com.zhiliaoapp.musically': 'TikTok',
  'com.ss.android.ugc.trill': 'TikTok',
  'com.zhiliaoapp.musically.go': 'TikTok Lite',
  'com.ss.android.ugc.aweme': 'Douyin',
  'com.instagram.android': 'Instagram',
  'com.whatsapp': 'WhatsApp',
  'com.whatsapp.w4b': 'WhatsApp Business',
  'jp.naver.line.android': 'LINE',
  'com.google.android.youtube': 'YouTube',
  'com.android.chrome': 'Chrome',
  'com.UCMobile.intl': 'UC Browser',
  'com.opera.browser': 'Opera',
  'com.opera.mini.native': 'Opera Mini',
  'com.mxtech.videoplayer.ad': 'MX Player',
  'com.mxtech.videoplayer.pro': 'MX Player Pro',
  'com.snaptube.premium': 'Snaptube',
  'com.nemo.vidmate': 'VidMate',
  'org.videolan.vlc': 'VLC',
  'com.tencent.mm': 'WeChat',
  'com.imo.android.imoim': 'imo',
  'com.discord': 'Discord',
  'org.thoughtcrime.securesms': 'Signal',
  'com.twitter.android': 'X',
  'com.zing.zalo': 'Zalo',
};

/// Package words that name nobody: domains, platforms, and filler.
const Set<String> _noise = <String>{
  'com', 'org', 'net', 'io', 'co', 'me', 'tv', 'in', 'jp', 'ru', 'cn', 'mm',
  'android', 'app', 'apps', 'mobile', 'client', 'free', 'pro', 'lite', 'beta',
};

/// Folder names that say nothing about whose they are.
const Set<String> _generic = <String>{
  'cache', 'caches', 'files', 'file', 'video', 'videos', 'media', 'movie',
  'movies', 'temp', 'tmp', 'download', 'downloads', 'data', 'documents',
  'document', 'shared', 'exo', 'exoplayer', 'exocache', 'stream', 'streams',
  'http', 'okhttp', 'video_cache', 'videocache', 'image_cache', 'save',
  'saved', 'offline', 'record', 'records',
};
