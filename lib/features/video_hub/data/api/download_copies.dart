import 'dart:async';

import 'package:http/http.dart' as http;

import '../../domain/content_repository.dart';
import '../../domain/video_content.dart';
import 'download_plan.dart';

/// The copies a title can be downloaded as, with their sizes — what the
/// quality sheet puts in front of the viewer before any byte moves.
///
/// IN THE DATA LAYER because learning them means asking for a playback grant,
/// and no screen may interpret a grant (`tool/security_invariants.py`, rule
/// 2). What leaves here is a list of sizes, not an entitlement.
///
/// EMPTY means "nothing to choose between": no ladder, a refusal, or no
/// connection to ask with. The caller then downloads the original without a
/// sheet, and the download reports whatever went wrong, as it always has.
Future<List<DownloadOption>> downloadCopiesOf({
  required ContentRepository repo,
  required VideoContent content,
  required MediaRef source,
  required String? deviceId,
}) async {
  try {
    final grant = await repo
        .requestPlayback(content: content, source: source, deviceId: deviceId)
        .timeout(const Duration(seconds: 15));
    if (!grant.isGranted || grant.renditions.isEmpty) {
      return const <DownloadOption>[];
    }
    return downloadOptions(grant.renditions,
        originalBytes: await _lengthOf(grant.url));
  } catch (_) {
    return const <DownloadOption>[];
  }
}

/// The object's length from one byte of it — the original's size, which the
/// grant does not carry. Null when it cannot be learned in a few seconds: the
/// line is then shown without a size rather than holding the sheet back.
Future<int?> _lengthOf(String? url) async {
  if (url == null || url.isEmpty) return null;
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['Range'] = 'bytes=0-0';
    final res = await client.send(req).timeout(const Duration(seconds: 6));
    unawaited(res.stream.drain<void>().catchError((_) {}));
    final range = res.headers['content-range'];
    if (range != null) {
      final total = int.tryParse(range.split('/').last.trim());
      if (total != null && total > 0) return total;
    }
    return res.statusCode == 200 ? res.contentLength : null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}
