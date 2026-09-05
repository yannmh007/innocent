import 'package:flutter/foundation.dart';

import '../data/tiktok_photo_extractor.dart';

/// How well a codec plays on the phones Innocent targets.
///
/// This matters more than it looks. Myanmar users run a wide spread of
/// hardware, and h264 is the only video codec with hardware decoding on
/// virtually every Android device ever shipped. VP9 is missing on many
/// pre-2017 chipsets and AV1 on almost everything before 2023 — libmpv will
/// still play them, but in software: hot phone, flat battery, dropped frames.
/// So the quality list marks them, and the default selection prefers h264.
enum CodecTier { compatible, modern, heavy, unknown }

/// One selectable row in the quality sheet.
@immutable
class MediaFormat {
  const MediaFormat({
    required this.id,
    required this.ext,
    this.height,
    this.width,
    this.fps,
    this.tbr,
    this.abr,
    this.filesize,
    this.vcodec,
    this.acodec,
    this.protocol,
    this.note,
    this.sizeIsEstimate = false,
    this.convertToMp3 = false,
    this.url,
    this.watermarked = false,
    this.httpHeaders = const <String, String>{},
  });

  final String id;
  final String ext;
  final int? height;
  final int? width;
  final double? fps;

  /// Total bitrate in kbps, as reported by yt-dlp.
  final double? tbr;

  /// Audio bitrate in kbps.
  final double? abr;

  /// Total bytes for this row INCLUDING the audio that will be merged into it
  /// for video-only formats. Null when nothing could be derived.
  final int? filesize;

  final String? vcodec;
  final String? acodec;
  final String? protocol;
  final String? note;

  /// True when [filesize] came from `filesize_approx` or a bitrate × duration
  /// calculation rather than an exact server-reported length.
  final bool sizeIsEstimate;

  /// Synthetic row: download the best audio, then transcode it to MP3 with
  /// ffmpeg. Not a real yt-dlp format.
  final bool convertToMp3;

  /// Direct media URL straight out of `yt-dlp -J`.
  ///
  /// Worth having because it removes an entire yt-dlp process spawn from the
  /// Stream path: the JSON we already parsed contains the resolved (and, on
  /// YouTube, already de-throttled) URL, so asking the engine again with `-g`
  /// was paying a second Python startup for something we were holding.
  final String? url;

  /// Headers the media server expects, straight from the engine.
  ///
  /// Not decoration: TikTok's CDN refuses a request for one of its video URLs
  /// that arrives without the Referer the page would have sent, which is why
  /// a link that downloads perfectly can fail to play — the downloader sends
  /// them and the player did not.
  final Map<String, String> httpHeaders;

  /// TikTok (and Douyin) publish the same video twice: `download_addr*` has the
  /// TikTok logo and username burned into the picture, `play_addr*` does not.
  /// Nobody wants the burned-in one, so it is kept out of the way.
  final bool watermarked;

  bool get hasVideo => vcodec != null && vcodec != 'none' && vcodec!.isNotEmpty;
  bool get hasAudio => acodec != null && acodec != 'none' && acodec!.isNotEmpty;

  /// Video and audio already interleaved in one file — no muxing needed, and
  /// the only kind of format that can be handed straight to the player.
  bool get isCombined => hasVideo && hasAudio;
  bool get isAudioOnly => hasAudio && !hasVideo;
  bool get isVideoOnly => hasVideo && !hasAudio;

  /// Fragmented protocols (HLS/DASH) can't be fetched by aria2c and are the
  /// ones that benefit from parallel fragments.
  bool get isFragmented {
    final String p = (protocol ?? '').toLowerCase();
    return p.contains('m3u8') || p.contains('dash') || p.contains('http_dash');
  }

  CodecTier get videoTier {
    if (!hasVideo) return CodecTier.unknown;
    final String v = vcodec!.toLowerCase();
    if (v.startsWith('avc') || v.startsWith('h264')) return CodecTier.compatible;
    if (v.startsWith('hev') || v.startsWith('hvc') || v.startsWith('h265')) {
      return CodecTier.modern;
    }
    if (v.startsWith('vp9') || v.startsWith('vp09') || v.startsWith('vp8')) {
      return CodecTier.modern;
    }
    if (v.startsWith('av01') || v.startsWith('av1')) return CodecTier.heavy;
    return CodecTier.unknown;
  }

  /// Short badge text, or null when the codec needs no warning.
  String? get codecBadge {
    if (!hasVideo) return null;
    switch (videoTier) {
      case CodecTier.compatible:
        return 'h264';
      case CodecTier.modern:
        final String v = vcodec!.toLowerCase();
        if (v.startsWith('vp')) return 'vp9';
        return 'hevc';
      case CodecTier.heavy:
        return 'av1';
      case CodecTier.unknown:
        return null;
    }
  }

  /// Playable without a second engine call.
  bool get hasDirectUrl =>
      isCombined && url != null && url!.startsWith('http');

  /// The number people mean by "1080p".
  ///
  /// Resolution is named after the SHORT side, which only matches `height` for
  /// landscape video. A TikTok clip is 1080x1920, and labelling that "1920p"
  /// — which the first build did — is wrong and reads as a bug to anyone who
  /// knows what 1080p means.
  int? get shortSide {
    if (width != null && width! > 0 && height != null && height! > 0) {
      return width! < height! ? width : height;
    }
    return (height != null && height! > 0) ? height : null;
  }

  /// "720p", "1080p60", or the extractor's own note when there is no size.
  String get qualityLabel {
    final int? side = shortSide;
    if (side != null && side > 0) {
      final String base = '${side}p';
      if (fps != null && fps! >= 50) return '$base${fps!.round()}';
      return base;
    }
    // BITRATE BEFORE NOTE. A bare playlist address — the kind our own browser
    // now hands over from sites the engine cannot extract — carries no height
    // at all, and yt-dlp's note for those is literally "0 - unknown". The
    // device trail showed that reaching the user as the name of their only
    // choice, which tells them nothing and looks broken.
    //
    // A bitrate is not a resolution, but it IS a real number that orders
    // correctly and lets somebody choose between two rows. Anything beats
    // repeating the word unknown back at them.
    final double? rate = tbr;
    if (rate != null && rate > 0) {
      return rate >= 1000
          ? '${(rate / 1000).toStringAsFixed(1)} Mbps'
          : '${rate.round()} kbps';
    }
    final String? n = note;
    if (n != null && n.isNotEmpty && !_looksEmpty(n)) return n;
    return _looksEmpty(id) ? 'Video' : id;
  }

  /// True for yt-dlp's placeholder labels — `unknown`, `0 - unknown`, `0`.
  ///
  /// These are the extractor saying it has nothing to tell us. Passing them
  /// through as a quality name dresses an absence up as an answer.
  static bool _looksEmpty(String v) {
    final String t = v.trim().toLowerCase();
    return t.isEmpty ||
        t == 'unknown' ||
        t == '0' ||
        t == 'none' ||
        t.endsWith('- unknown') ||
        t.endsWith('-unknown');
  }

  /// "128 kbps" for audio rows.
  String get audioLabel {
    final double? rate = abr ?? tbr;
    if (rate != null && rate > 0) return '${rate.round()} kbps';
    if (note != null && note!.isNotEmpty) return note!;
    return ext.toUpperCase();
  }

  /// What to pass to `yt-dlp -f` for a download.
  ///
  /// A video-only format needs audio attached. The `+bestaudio/<id>` form is
  /// yt-dlp's fallback syntax: try the merge, and if no audio stream can be
  /// paired fall back to the video alone rather than failing the whole job.
  String get downloadSelector {
    if (isVideoOnly) return '$id+bestaudio/$id';
    return id;
  }

  /// What to pass to `yt-dlp -f -g` for playback. Must resolve to exactly one
  /// stream, so a video-only row falls back to the best combined format
  /// instead of returning two URLs the player cannot use.
  /// `b`, not `best` — the same selector without the deprecation warning.
  /// yt-dlp nags about the long spelling on every single call, and that nag
  /// was filling the small window of engine output we keep for diagnosis.
  String get streamSelector => isCombined ? id : 'b';

  /// True when the download will invoke ffmpeg to join two streams.
  bool get needsMerge => isVideoOnly;
}

/// Everything the quality sheet needs about one link.
@immutable
class MediaProbe {
  const MediaProbe({
    required this.url,
    required this.title,
    required this.videoFormats,
    required this.audioFormats,
    this.thumbnail,
    this.durationSeconds,
    this.extractor,
    this.isLive = false,
    this.uploader,
    this.photos = const <PhotoItem>[],
  });

  final String url;
  final String title;

  /// One row per resolution, best-compatible codec first, highest first.
  final List<MediaFormat> videoFormats;

  /// Audio-only rows, highest bitrate first. May include a synthetic MP3 row.
  final List<MediaFormat> audioFormats;

  final String? thumbnail;
  final double? durationSeconds;
  final String? extractor;
  final bool isLive;
  final String? uploader;

  /// Pictures from a TikTok photo post. Empty for everything else.
  ///
  /// Kept beside the formats rather than folded into them because they are not
  /// formats: there is no choosing between them, the whole set is the thing
  /// being downloaded, and they don't come from the engine at all.
  final List<PhotoItem> photos;

  bool get isPhotoPost => photos.isNotEmpty;

  bool get isEmpty =>
      videoFormats.isEmpty && audioFormats.isEmpty && photos.isEmpty;

  /// Copy carrying the pictures, used once the photo extractor has run.
  MediaProbe withPhotos(List<PhotoItem> items, {String? betterTitle}) =>
      MediaProbe(
        url: url,
        title: (betterTitle != null && betterTitle.trim().isNotEmpty)
            ? betterTitle.trim()
            : title,
        videoFormats: videoFormats,
        audioFormats: audioFormats,
        thumbnail: thumbnail,
        durationSeconds: durationSeconds,
        extractor: extractor,
        isLive: isLive,
        uploader: uploader,
        photos: items,
      );

  /// Largest short side across the set, for a one-line "1080p" style summary.
  int? get photoShortSide {
    int best = 0;
    for (final PhotoItem p in photos) {
      final int side = p.shortSide ?? 0;
      if (side > best) best = side;
    }
    return best > 0 ? best : null;
  }

  /// The row to pre-select.
  ///
  /// Order of preference: never a watermarked copy; then the most compatible
  /// codec at or below 720p (the sweet spot for phone screens, data cost and
  /// old decoders); then anything at or below 720p; then the best clean copy
  /// there is.
  ///
  /// The last step used to be `videoFormats.last`, which on TikTok landed
  /// squarely on the watermarked row — every clip pre-selected the one copy
  /// with the logo burned into it.
  MediaFormat? get defaultChoice {
    if (videoFormats.isEmpty) {
      return audioFormats.isEmpty ? null : audioFormats.first;
    }
    final List<MediaFormat> clean = videoFormats
        .where((MediaFormat f) => !f.watermarked)
        .toList();
    final List<MediaFormat> pool = clean.isEmpty ? videoFormats : clean;

    for (final MediaFormat f in pool) {
      final int side = f.shortSide ?? 0;
      if (side > 0 && side <= 720 && f.videoTier == CodecTier.compatible) {
        return f;
      }
    }
    for (final MediaFormat f in pool) {
      final int side = f.shortSide ?? 0;
      if (side > 0 && side <= 720) return f;
    }
    // Highest first in this list, so the head is the best clean copy.
    return pool.first;
  }
}
