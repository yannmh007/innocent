import 'package:share_plus/share_plus.dart';

/// Share what a media address points at.
///
/// A file on the phone goes as the FILE. Sharing its path
/// ("/storage/emulated/0/Movies/a.mp4") hands the other app a string that
/// means nothing off this phone — which is what Share did for a song and for
/// the video in the player. Anything else (an http link) goes as text.
Future<void> shareMedia(String uri, {String? subject}) async {
  final path = localPathOf(uri);
  if (path != null) {
    await Share.shareXFiles(<XFile>[XFile(path)], subject: subject);
  } else {
    await Share.share(uri, subject: subject);
  }
}

/// The file path behind a `file://` URI or a bare absolute path; null for
/// anything that is not a file on this phone.
String? localPathOf(String uri) {
  if (uri.startsWith('file://')) {
    try {
      return Uri.parse(uri).toFilePath();
    } catch (_) {
      return null;
    }
  }
  if (uri.startsWith('/')) return uri;
  return null;
}
