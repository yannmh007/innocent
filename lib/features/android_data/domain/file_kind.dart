/// What a file inside Android/data is, by its name — which decides how the
/// Hidden files browser opens it: a video or a song streams, a photo opens
/// in the viewer, anything else goes to whichever app on the phone opens it.
library;

enum FileKind { video, image, audio, document, archive, apk, other }

const Set<String> _video = <String>{
  'mp4',
  'mkv',
  'webm',
  'mov',
  'avi',
  '3gp',
  'm4v',
  'ts',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
};
const Set<String> _image = <String>{
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
};
const Set<String> _audio = <String>{
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
  'oga',
  'opus',
  'wma',
  'amr',
};
const Set<String> _document = <String>{
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'txt',
  'csv',
  'rtf',
  'odt',
  'epub',
  'srt',
  'ass',
  'vtt',
  'json',
  'xml',
  'html',
  'htm',
};
const Set<String> _archive = <String>{'zip', 'rar', '7z', 'tar', 'gz', 'xz'};

/// The kind of the file called [name]. Telegram names a file it is still
/// downloading `<name>.temp`; that is not openable as what it will become.
FileKind kindOf(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return FileKind.other;
  final ext = lower.substring(dot + 1);
  if (_video.contains(ext)) return FileKind.video;
  if (_image.contains(ext)) return FileKind.image;
  if (_audio.contains(ext)) return FileKind.audio;
  if (_document.contains(ext)) return FileKind.document;
  if (_archive.contains(ext)) return FileKind.archive;
  if (ext == 'apk' || ext == 'apks' || ext == 'xapk') return FileKind.apk;
  return FileKind.other;
}

/// Where the phone keeps every app's private folder — the browser's root.
const String kAndroidDataRoot = '/storage/emulated/0/Android/data';

/// The Telegram apps whose downloads the browser offers as shortcuts. Since
/// Android 11 Telegram keeps what it downloads in its own folder,
/// `<package>/files/Telegram/Telegram Video` and so on.
const List<String> kTelegramPackages = <String>[
  'org.telegram.messenger',
  'org.telegram.messenger.web',
  'org.telegram.messenger.beta',
  'org.thunderdog.challegram',
];

/// The folder holding [package]'s Telegram downloads.
String telegramDownloads(String package) =>
    '$kAndroidDataRoot/$package/files/Telegram';
