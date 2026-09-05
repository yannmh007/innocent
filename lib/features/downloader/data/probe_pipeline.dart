import '../../../core/services/downloader/downloader_engine_service.dart';
import '../domain/diagnostics_log.dart';
import '../domain/media_probe.dart';
import 'probe_parser.dart';

/// Reading a link, once, for whoever is asking.
///
/// WHY THIS FILE EXISTS. The downloads screen had the whole reading sequence
/// inside a widget method, and the in-app browser — which cannot reach a
/// widget, and must work while that screen has never been built — grew its own
/// reader in Kotlin instead. The result was the thing THE RULES already forbid:
/// the same YouTube video gave a full sheet when pasted and a thin, soundless
/// one when found in the browser, because the second reader dropped audio-only
/// renditions and never paired a video-only one with a soundtrack.
///
/// So the sequence lives here, owned by nobody in particular and callable from
/// anywhere. The screen keeps what is genuinely its own — playlists, dialogs,
/// the storage prompt, the self-heal that talks to the user — and the part that
/// answers "what can this link be downloaded as" is asked in exactly one place.
class ProbePipeline {
  const ProbePipeline._();

  /// Reads [url] and returns what it can be downloaded as.
  ///
  /// [cookies] and [clients] are the caller's current settings rather than
  /// anything read here: this file must not become a second opinion about
  /// configuration, only about reading.
  ///
  /// Throws whatever the engine throws. A caller that wants a failure to be
  /// survivable must say so itself — swallowing it here would hide the
  /// extractor's own words, which is the one thing this project has learnt
  /// never to do.
  static Future<MediaProbe> read(
    String url, {
    required String? cookies,
    required String clients,
    bool escalateThinYouTube = true,
  }) async {
    // ASK THE SOURCE OF TRUTH ABOUT FFMPEG, NEVER A CACHE.
    //
    // This decides whether video-only renditions survive the parser, and
    // getting it wrong is invisible in the result: a one-row sheet looks
    // exactly like a stingy site. It cost a release once already.
    final EngineStatus status =
        await DownloaderEngineService.instance.ensureReady();

    final String json = await DownloaderEngineService.instance.probe(
      url,
      cookies: cookies,
      clients: clients,
    );
    MediaProbe parsed =
        ProbeParser.parse(json, url, ffmpegAvailable: status.ffmpeg);

    if (escalateThinYouTube) {
      final MediaProbe? better = await alternateYouTubeRead(
        url,
        current: parsed,
        cookies: cookies,
        clients: clients,
        ffmpegAvailable: status.ffmpeg,
      );
      if (better != null) parsed = better;
    }
    return parsed;
  }

  /// Asks YouTube again through the alternate players, when the first answer
  /// looks like one client rather than one video.
  ///
  /// A YouTube reply with a single resolution in it is almost never a video
  /// with a single resolution — it is a player client that only told us about
  /// one. Gated to YouTube because the argument is YouTube's; anywhere else it
  /// is a wasted round trip on a link that already answered.
  ///
  /// SHARED WITH THE DOWNLOADS SCREEN, which had this inline. Whichever of two
  /// copies is not being looked at is the one that goes stale, and the screen's
  /// copy is followed by an escalation the browser has no business running
  /// (harvesting a guest session involves the user), so the shapes were always
  /// going to drift apart.
  ///
  /// Returns a better read, or null to keep the one you have.
  static Future<MediaProbe?> alternateYouTubeRead(
    String url, {
    required MediaProbe current,
    required String? cookies,
    required String clients,
    required bool ffmpegAvailable,
  }) async {
    if (!_isYouTube(url)) return null;
    if (current.videoFormats.length > 1) return null;
    if (current.isLive) return null;
    if (clients.trim().isEmpty) return null;
    try {
      final String second = await DownloaderEngineService.instance.probe(
        url,
        cookies: cookies,
        clients: clients,
        forceClients: true,
      );
      final MediaProbe alternate =
          ProbeParser.parse(second, url, ffmpegAvailable: ffmpegAvailable);
      if (alternate.videoFormats.length > current.videoFormats.length) {
        return alternate;
      }
    } catch (_) {
      // The first answer stands; a thin list beats no list.
    }
    return null;
  }

  /// Flattens a read into rows a native sheet can draw.
  ///
  /// The browser's sheet is drawn in Kotlin because it sits over a native
  /// WebView, so the rows have to cross a channel. What crosses is the
  /// PARSER'S OWN ANSWER — the same ordering, the same collapsing, the same
  /// pairing of a silent rendition with its soundtrack — not a second opinion
  /// formed on the far side.
  ///
  /// Video first, then audio, because that is the order the Flutter sheet puts
  /// them in and somebody moving between the two should not have to relearn
  /// where things are.
  static List<Map<String, Object?>> rowsFor(MediaProbe probe) {
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

    void add(MediaFormat f, {required bool audio}) {
      final List<String> badges = <String>[];
      if (f.watermarked) badges.add('watermark');
      if (audio) badges.add('audio');
      if (f.convertToMp3) badges.add('mp3');
      rows.add(<String, Object?>{
        // `<id>+bestaudio/<id>` for a video-only rendition — THE SOUND FIX.
        // The browser's own reader sent the bare id, so YouTube's DASH video
        // arrived with no soundtrack at all. This is the same selector the
        // Flutter sheet has always sent; asking the format itself is the only
        // way the two can stay in step.
        'selector': f.downloadSelector,
        'label': audio ? f.audioLabel : f.qualityLabel,
        'ext': f.ext,
        'bytes': f.filesize ?? 0,
        'estimated': f.sizeIsEstimate,
        // The parser has already decided whether this rendition carries its
        // own sound. Recomputing it on the far side is how the browser ended
        // up downloading silent files.
        'merge': f.needsMerge,
        'badge': badges.join(' · '),
        'url': '',
        // Carried on every row rather than alongside them, because a channel
        // that hands back a list is simpler than one that hands back a list
        // and a header — and the far side only ever reads the first.
        'pageTitle': probe.title,
        'duration': probe.durationSeconds ?? 0.0,
      });
    }

    for (final MediaFormat f in probe.videoFormats) {
      add(f, audio: false);
    }
    for (final MediaFormat f in probe.audioFormats) {
      add(f, audio: true);
    }
    return rows;
  }

  static bool _isYouTube(String url) {
    final String host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.contains('youtube.') || host.contains('youtu.be');
  }

  /// Reads a link on the in-app browser's behalf and answers it.
  ///
  /// Every outcome is recorded, including the empty one. A browser that shows
  /// nothing and a browser that was never asked look identical from the trail,
  /// and this project has already paid twice for exactly that ambiguity.
  static Future<void> answerBrowser({
    required int reqId,
    required String url,
    required String? cookies,
    required String clients,
  }) async {
    try {
      final MediaProbe probe = await read(url, cookies: cookies, clients: clients);
      final List<Map<String, Object?>> rows = rowsFor(probe);
      DiagnosticsLog.instance.note(
        'browser',
        'read for the browser: ${probe.videoFormats.length} video + '
        '${probe.audioFormats.length} audio',
        url: url,
      );
      await DownloaderEngineService.instance.sendBrowserFormats(reqId, rows);
    } catch (e) {
      // The browser is in front and cannot show this, so it goes where every
      // other failure goes. An EMPTY answer is still an answer: it releases
      // the browser immediately instead of leaving it on its spinner until the
      // timeout, and it tells the browser to fall back to its own reader.
      DiagnosticsLog.instance.add('browser', 'read for the browser failed: $e',
          url: url);
      try {
        await DownloaderEngineService.instance
            .sendBrowserFormats(reqId, const <Map<String, Object?>>[]);
      } catch (_) {}
    }
  }
}
