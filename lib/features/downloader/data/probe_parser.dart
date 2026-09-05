import 'dart:convert';

import '../domain/media_probe.dart';

/// "1.4 GB" / "26 MB" / "—" for an unknown size.
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '—';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal only where it carries information: "1.4 GB" is useful,
  // "1.4 KB" is noise and "1024.0 MB" never appears because of the loop above.
  final String text =
      (unit >= 2 && value < 100) ? value.toStringAsFixed(1) : value.round().toString();
  return '$text ${units[unit]}';
}

/// "3:37" / "1:02:11".
String formatDuration(double? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final int total = seconds.round();
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final int s = total % 60;
  final String mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  final String ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Parses `yt-dlp -J` output.
///
/// Everything here is defensive on purpose: this JSON comes from ~1800
/// different site extractors and the shape genuinely varies. Fields that are
/// documented as numbers arrive as strings on some sites, `formats` is missing
/// entirely on others (a direct .mp4 link, which is most of the long tail),
/// and `vcodec`/`acodec` are sometimes null rather than the documented "none".
/// A parse failure would strand the user on a spinner, so every branch has a
/// fallback and the worst case is a shorter list, never an exception.
class ProbeParser {
  ProbeParser._();

  /// [ffmpegAvailable] gates two things: the synthetic MP3 row (it is a
  /// transcode, so it needs ffmpeg) and video-only formats (they need muxing).
  /// With no muxer the list is limited to combined formats, which on YouTube
  /// means 360p is the ceiling — correct, and far better than offering 1080p
  /// and silently producing a silent file.
  static MediaProbe parse(
    String rawJson,
    String requestedUrl, {
    bool ffmpegAvailable = true,
  }) {
    final Object? decoded = jsonDecode(rawJson);
    Map<String, Object?> root = _asMap(decoded);

    // Some extractors ignore --no-playlist and hand back a playlist wrapper.
    // Fall through to its first entry instead of showing "no media found".
    if (root['_type'] == 'playlist') {
      final Object? entries = root['entries'];
      if (entries is List && entries.isNotEmpty) {
        final Map<String, Object?> first = _asMap(entries.first);
        if (first.isNotEmpty) root = first;
      }
    }

    final String title = _firstString(
          <Object?>[root['title'], root['fulltitle'], root['id']],
        ) ??
        'Video';
    final double? duration = _toDouble(root['duration']);
    final bool isLive =
        root['is_live'] == true || root['live_status'] == 'is_live';

    // Several extractors — TikTok among them — put the headers their CDN
    // insists on at the TOP level and leave the individual formats bare. Read
    // only the per-format ones and playback fails on a link that downloads
    // perfectly, because the downloader sends what the player never got.
    final Map<String, String> rootHeaders = _headers(root['http_headers']);

    final List<MediaFormat> parsed = <MediaFormat>[];
    final Object? rawFormats = root['formats'];
    if (rawFormats is List && rawFormats.isNotEmpty) {
      for (final Object? entry in rawFormats) {
        final MediaFormat? f =
            _format(_asMap(entry), duration, fallbackHeaders: rootHeaders);
        if (f != null) parsed.add(f);
      }
    }
    if (parsed.isEmpty) {
      // No `formats` array: a single-stream response. Build one row from the
      // top-level fields so plain-mp4 sites work like any other.
      final MediaFormat? single = _format(
        root,
        duration,
        fallbackNote: 'Original',
        fallbackHeaders: rootHeaders,
      );
      if (single != null) parsed.add(single);
    }

    final List<MediaFormat> audioOnly =
        parsed.where((MediaFormat f) => f.isAudioOnly).toList();
    final MediaFormat? bestAudio = _bestAudio(audioOnly);
    final int? bestAudioBytes = bestAudio?.filesize;

    // Video rows. Video-only formats are only offered when a muxer exists.
    final List<MediaFormat> videoCandidates = parsed
        .where((MediaFormat f) =>
            f.hasVideo && (f.isCombined || ffmpegAvailable))
        .map((MediaFormat f) =>
            // A video-only row will be merged with audio, so the number the
            // user sees has to include both — otherwise a 1080p download
            // reliably lands ~10% larger than advertised. Guarded on the video
            // size being known: adding audio to an unknown total would turn
            // "size unknown" into a confidently wrong 3 MB.
            (f.isVideoOnly && bestAudioBytes != null && f.filesize != null)
                ? _withSize(f, f.filesize! + bestAudioBytes, estimate: true)
                : f)
        .toList();

    // If ANY clean copy exists, the watermarked ones are not a choice worth
    // offering — they are the same video with a logo burned in. They are only
    // kept when they are all there is.
    final List<MediaFormat> cleanVideo = videoCandidates
        .where((MediaFormat f) => !f.watermarked)
        .toList();
    final List<MediaFormat> offeredVideo =
        cleanVideo.isEmpty ? videoCandidates : cleanVideo;

    return MediaProbe(
      url: requestedUrl,
      title: title,
      thumbnail: _firstString(<Object?>[root['thumbnail']]),
      durationSeconds: duration,
      extractor: _firstString(
        <Object?>[root['extractor_key'], root['extractor']],
      ),
      uploader: _firstString(<Object?>[root['uploader'], root['channel']]),
      isLive: isLive,
      videoFormats: _dedupeVideo(offeredVideo),
      audioFormats: _dedupeAudio(audioOnly, bestAudio, ffmpegAvailable),
    );
  }

  // ---------------------------------------------------------------- formats

  static MediaFormat? _format(
    Map<String, Object?> raw,
    double? duration, {
    String? fallbackNote,
    Map<String, String> fallbackHeaders = const <String, String>{},
  }) {
    if (raw.isEmpty) return null;

    String? vcodec = _firstString(<Object?>[raw['vcodec']]);
    String? acodec = _firstString(<Object?>[raw['acodec']]);

    final String id = _firstString(
          <Object?>[raw['format_id'], raw['id']],
        ) ??
        'best';

    // Explicitly-none on both sides means it carries no media at all —
    // storyboard/mhtml thumbnail tracks. Drop those rows.
    if (vcodec == 'none' && acodec == 'none') return null;

    // Both unknown (null) is the common shape for a direct file link. Treating
    // it as "has both" is the right guess: it is a playable file, and marking
    // it audio-only or video-only would hide it from the video list or make us
    // try to mux a file that needs no muxing.
    if (vcodec == null && acodec == null) {
      vcodec = 'unknown';
      acodec = 'unknown';
    }

    final int? exact = _toInt(raw['filesize']);
    final int? approx = _toInt(raw['filesize_approx']);
    final double? tbr = _toDouble(raw['tbr']);
    final double? abr = _toDouble(raw['abr']);

    int? size = exact ?? approx;
    if (size == null && duration != null && duration > 0) {
      final double? rate = tbr ?? abr;
      if (rate != null && rate > 0) {
        // kbps → bytes: rate * 1000 bits/s ÷ 8 × seconds.
        size = (rate * 1000 / 8 * duration).round();
      }
    }

    // TikTok/Douyin mark the logo-burned copy two ways depending on the yt-dlp
    // version: format_id "download_addr*", or "watermarked" in format_note.
    // Check both — matching only one of them lets the bad copy through on
    // whichever version we happen to be running.
    final String note = _firstString(
          <Object?>[raw['format_note'], raw['resolution'], raw['format']],
        ) ??
        (fallbackNote ?? '');
    final bool watermarked = id.startsWith('download_addr') ||
        note.toLowerCase().contains('watermark');

    return MediaFormat(
      id: id,
      ext: _firstString(<Object?>[raw['ext']]) ?? 'mp4',
      height: _toInt(raw['height']),
      width: _toInt(raw['width']),
      fps: _toDouble(raw['fps']),
      tbr: tbr,
      abr: abr,
      filesize: size,
      vcodec: vcodec,
      acodec: acodec,
      protocol: _firstString(<Object?>[raw['protocol']]),
      note: note.isEmpty ? null : note,
      sizeIsEstimate: exact == null,
      url: _firstString(<Object?>[raw['url']]),
      watermarked: watermarked,
      // MERGED, not chosen between. See [_mergeHeaders] -- picking one set
      // and discarding the other is the bug that stopped TikTok playing.
      httpHeaders: _mergeHeaders(fallbackHeaders, _headers(raw['http_headers'])),
    );
  }

  static MediaFormat _withSize(
    MediaFormat f,
    int bytes, {
    required bool estimate,
  }) =>
      MediaFormat(
        id: f.id,
        ext: f.ext,
        height: f.height,
        width: f.width,
        fps: f.fps,
        tbr: f.tbr,
        abr: f.abr,
        filesize: bytes,
        vcodec: f.vcodec,
        acodec: f.acodec,
        protocol: f.protocol,
        note: f.note,
        sizeIsEstimate: estimate || f.sizeIsEstimate,
        convertToMp3: f.convertToMp3,
        url: f.url,
        watermarked: f.watermarked,
        httpHeaders: f.httpHeaders,
      );

  /// Highest-bitrate audio, preferring m4a because it muxes into an mp4
  /// container without a re-encode and plays on every Android build.
  static MediaFormat? _bestAudio(List<MediaFormat> audioOnly) {
    if (audioOnly.isEmpty) return null;
    final List<MediaFormat> sorted = List<MediaFormat>.of(audioOnly)
      ..sort((MediaFormat a, MediaFormat b) {
        final int extScore = _audioExtScore(b.ext) - _audioExtScore(a.ext);
        if (extScore != 0) return extScore;
        return _rate(b).compareTo(_rate(a));
      });
    return sorted.first;
  }

  static int _audioExtScore(String ext) {
    switch (ext.toLowerCase()) {
      case 'm4a':
        return 3;
      case 'mp3':
        return 2;
      case 'opus':
      case 'webm':
        return 1;
      default:
        return 0;
    }
  }

  static double _rate(MediaFormat f) => f.abr ?? f.tbr ?? 0;

  static int _tierScore(MediaFormat f) {
    switch (f.videoTier) {
      case CodecTier.compatible:
        return 3;
      case CodecTier.modern:
        return 2;
      case CodecTier.heavy:
        return 1;
      case CodecTier.unknown:
        return 0;
    }
  }

  /// One row per resolution — the reference downloaders all do this, and a raw
  /// yt-dlp list for a YouTube video is 25+ rows of near-duplicates. Within a
  /// resolution the most compatible codec wins, then mp4, then bitrate.
  static List<MediaFormat> _dedupeVideo(List<MediaFormat> formats) {
    final Map<String, MediaFormat> best = <String, MediaFormat>{};
    for (final MediaFormat f in formats) {
      final int? side = f.shortSide;
      final String key = (side != null && side > 0)
          ? 's$side'
          : 'n${f.note ?? f.id}';
      final MediaFormat? current = best[key];
      if (current == null || _betterVideo(f, current)) best[key] = f;
    }
    final List<MediaFormat> out = best.values.toList()
      ..sort((MediaFormat a, MediaFormat b) {
        // Unknown-resolution rows sort last rather than pretending to be 0p.
        final int ah = a.shortSide ?? -1;
        final int bh = b.shortSide ?? -1;
        if (ah != bh) return bh.compareTo(ah);
        return _rate(b).compareTo(_rate(a));
      });
    return out;
  }

  static bool _betterVideo(MediaFormat candidate, MediaFormat current) {
    final int tier = _tierScore(candidate) - _tierScore(current);
    if (tier != 0) return tier > 0;
    final int ext = (candidate.ext == 'mp4' ? 1 : 0) - (current.ext == 'mp4' ? 1 : 0);
    if (ext != 0) return ext > 0;
    return (candidate.tbr ?? 0) > (current.tbr ?? 0);
  }

  static List<MediaFormat> _dedupeAudio(
    List<MediaFormat> audioOnly,
    MediaFormat? bestAudio,
    bool ffmpegAvailable,
  ) {
    final Map<int, MediaFormat> byRate = <int, MediaFormat>{};
    for (final MediaFormat f in audioOnly) {
      // Bucket to the nearest 16 kbps: 127.9 and 129.2 are the same choice to
      // a human, and listing both is just noise.
      final int bucket = (_rate(f) / 16).round();
      final MediaFormat? current = byRate[bucket];
      if (current == null || _audioExtScore(f.ext) > _audioExtScore(current.ext)) {
        byRate[bucket] = f;
      }
    }
    final List<MediaFormat> out = byRate.values.toList()
      ..sort((MediaFormat a, MediaFormat b) => _rate(b).compareTo(_rate(a)));

    // Keep the list short — four bitrates is already more choice than any
    // reference app offers.
    final List<MediaFormat> trimmed =
        out.length > 4 ? out.sublist(0, 4) : out;

    if (ffmpegAvailable && bestAudio != null) {
      // MP3 is not a format any of these sites serves; it is a transcode of the
      // best audio track. Flagged so the UI can label the extra wait.
      trimmed.add(MediaFormat(
        id: bestAudio.id,
        ext: 'mp3',
        abr: bestAudio.abr ?? bestAudio.tbr,
        tbr: bestAudio.tbr,
        filesize: bestAudio.filesize,
        vcodec: 'none',
        acodec: 'mp3',
        protocol: bestAudio.protocol,
        note: bestAudio.note,
        sizeIsEstimate: true,
        convertToMp3: true,
      ));
    }
    return trimmed;
  }

  // ------------------------------------------------------------- coercions

  /// Root headers as the base, the format's own on top.
  ///
  /// This is how yt-dlp itself treats an info dict: `http_headers` at the top
  /// level is the default for every format, and a format's own entries extend
  /// it rather than replace it. We were replacing it, and the cost was paid
  /// only by the player: the downloader hands the whole info dict back to
  /// yt-dlp, which merges correctly on its own, so a file could download
  /// perfectly and then refuse to play from the very same address. Two code
  /// paths disagreeing about what a header set IS looks, from outside, exactly
  /// like a site that permits downloading but not streaming — and that is a
  /// story convincing enough that we believed it for three versions.
  ///
  /// Case-insensitive: a root `User-Agent` and a format `user-agent` are the
  /// same header, and sending both lets the server pick, which is not a thing
  /// to leave to chance.
  static Map<String, String> _mergeHeaders(
    Map<String, String> base,
    Map<String, String> own,
  ) {
    if (own.isEmpty) return base;
    if (base.isEmpty) return own;
    final Map<String, String> out = <String, String>{};
    final Map<String, String> byLower = <String, String>{};
    base.forEach((String k, String v) {
      out[k] = v;
      byLower[k.toLowerCase()] = k;
    });
    own.forEach((String k, String v) {
      final String? existing = byLower[k.toLowerCase()];
      if (existing != null) {
        out[existing] = v;
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  static Map<String, String> _headers(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final Map<String, String> out = <String, String>{};
    raw.forEach((Object? k, Object? v) {
      if (k is String && v is String && k.isNotEmpty) out[k] = v;
    });
    return out;
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      );
    }
    return const <String, Object?>{};
  }

  /// First non-empty string in [candidates], coercing numbers along the way
  /// (several extractors report `format_id` as an int).
  static String? _firstString(List<Object?> candidates) {
    for (final Object? c in candidates) {
      if (c is String && c.trim().isNotEmpty) return c.trim();
      if (c is num) return c.toString();
    }
    return null;
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.round();
    return null;
  }

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
