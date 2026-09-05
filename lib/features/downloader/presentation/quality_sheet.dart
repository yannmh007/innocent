import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/downloader/downloader_engine_service.dart';
import '../../../core/services/downloader/stream_proxy.dart';
import '../../../core/services/video_player/media_kit_player_service.dart';
import '../../../core/theme/app_colors.dart';
import '../data/probe_parser.dart';
import '../data/tiktok_photo_extractor.dart';
import '../domain/diagnostics_log.dart';
import 'storage_access.dart';
import '../domain/media_probe.dart';
import 'downloader_providers.dart';

/// Quality picker for a probed link.
///
/// Shown with `isScrollControlled: true` so the format list can scroll while
/// the header and the action row stay put — the list is long on YouTube and
/// short on a direct file link, and both have to look deliberate.
class QualitySheet extends ConsumerStatefulWidget {
  const QualitySheet({super.key, required this.probe});

  final MediaProbe probe;

  static Future<void> show(BuildContext context, MediaProbe probe) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext ctx) => QualitySheet(probe: probe),
    );
  }

  @override
  ConsumerState<QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends ConsumerState<QualitySheet> {
  MediaFormat? _selected;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.probe.defaultChoice;
    DiagnosticsLog.instance.note(
      'tap',
      'quality sheet opened — ${widget.probe.videoFormats.length} video + '
      '${widget.probe.audioFormats.length} audio rows',
      url: widget.probe.url,
    );
  }

  // ------------------------------------------------------------- actions

  Future<void> _stream() async {
    // Built as a plain variable rather than nested inside an interpolation:
    // an expression that has to be decoded before it can be checked is one
    // that gets shipped unchecked.
    final MediaFormat? picked = _selected;
    final String what = picked == null
        ? 'Stream pressed'
        : 'Stream pressed — ${picked.qualityLabel} '
            '${picked.isCombined ? '(combined)' : '(video-only)'}';
    DiagnosticsLog.instance.note('tap', what, url: widget.probe.url);
    final MediaFormat? format = _selected;
    if (format == null || _resolving) return;
    setState(() => _resolving = true);
    final AppStrings s = AppStrings.of(context);
    // Captured BEFORE the pop below. After Navigator.pop this State starts
    // tearing down, and reaching through `context` (or `ref`) once that has
    // happened throws. Holding the router/messenger objects is safe — they
    // outlive this sheet.
    final GoRouter router = GoRouter.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      // The probe JSON already carries the resolved media URL for combined
      // formats, so the common case needs no engine call at all: Play becomes
      // instant instead of paying another Python startup and network round
      // trip. `-g` stays as the fallback for rows without one (a video-only
      // selection, where the selector resolves to "best" instead).
      Future<String> resolveFresh() =>
          DownloaderEngineService.instance.resolveStream(
            widget.probe.url,
            format.streamSelector,
            cookies: ref.read(cookiesPathProvider),
            clients: ref.read(playerClientsProvider),
          );

      final Stopwatch clock = Stopwatch()..start();
      String url = format.hasDirectUrl ? format.url! : await resolveFresh();
      if (!mounted) return;
      DiagnosticsLog.instance.note(
        'stream',
        format.hasDirectUrl
            ? 'using the address from the read'
            : 'asked the engine for a fresh address (${clock.elapsedMilliseconds}ms)',
        url: url,
      );

      // TEST THE ADDRESS BEFORE OPENING THE PLAYER.
      //
      // An address that came out of the probe may be minutes old by the time a
      // quality is chosen, and several sites tie one to the session that asked
      // for it. Finding that out inside the player means a black screen and
      // the word "error"; finding it out here means we can simply ask the
      // engine for a new one and carry on, and the person never learns that
      // anything happened.
      Map<String, String> headers =
          await _streamHeadersWithSession(format, url);
      if (!mounted) return;
      clock.reset();
      int status = await StreamProxy.instance.check(url, headers);
      if (!mounted) return;
      // Recorded even when it PASSES. A silent success is why the last report
      // showed nothing at all for a stream that visibly failed — the check was
      // fine, so it said nothing, so the trail stopped exactly where it got
      // interesting.
      DiagnosticsLog.instance.note(
        'stream',
        'check ${status == 0 ? 'unreachable' : status} '
        'in ${clock.elapsedMilliseconds}ms · '
        // NAMES, not values. "5 headers" told us a count and nothing else;
        // which five is the question that actually needed answering, and no
        // header NAME is a secret.
        '${(headers.keys.toList()..sort()).join(', ')}',
        url: url,
      );
      if ((status == 0 || status >= 400) && format.hasDirectUrl) {
        DiagnosticsLog.instance.add(
          'stream',
          'saved address refused ($status), re-resolving',
          url: widget.probe.url,
        );
        url = await resolveFresh();
        if (!mounted) return;
        headers = await _streamHeadersWithSession(format, url);
        if (!mounted) return;
        status = await StreamProxy.instance.check(url, headers);
        if (!mounted) return;
      }
      if (status == 0 || status >= 400) {
        // TWO INDEPENDENT REFUSALS — the saved address and a freshly resolved
        // one, each tried with and without a range request. That is no longer
        // a shaky guess, it is evidence, so the person deserves to hear it and
        // to be offered the thing that DOES work on this site rather than a
        // black screen and the word "error".
        //
        // Still not a veto: "Play anyway" remains, and is the default action
        // if they simply dismiss. A check may advise; it may not decide.
        final bool? goDownload = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: AppColors.specSheetBg,
            title: Text(
              '${s.downloaderStreamFailed} ($status)',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            content: Text(
              s.downloaderStreamRefused,
              style: const TextStyle(
                  color: AppColors.white70, fontSize: 13, height: 1.4),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(s.downloaderStream,
                    style: const TextStyle(color: AppColors.white70)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(s.downloaderDownload,
                    style: const TextStyle(color: AppColors.primaryBlue)),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (goDownload == true) {
          DiagnosticsLog.instance.note(
            'tap',
            'streaming refused ($status) — chose Download instead',
            url: widget.probe.url,
          );
          setState(() => _resolving = false);
          await _download();
          return;
        }
        // RECORDED, AND THEN WE PLAY ANYWAY.
        //
        // A check that can veto playback is a check that can invent a
        // failure, and some CDNs genuinely refuse a two-byte range request
        // while serving the real one perfectly. v1.6.0 let this test hold the
        // Play button shut, which turned a diagnostic into an outage. Its job
        // is to tell us what happened and to have earned us a fresh address
        // along the way -- not to decide. If the stream really is dead the
        // player will say so a second later, and the report will already know
        // why.
        DiagnosticsLog.instance.add(
          'stream',
          status == 0
              ? 'check unreachable — playing anyway'
              : 'check refused with $status — playing anyway',
          url: widget.probe.url,
        );
      }
      // The headers no longer travel with the request — they ARE the request.
      // A loopback server fetches the media with them attached and hands the
      // player an ordinary local address, so nothing depends on whether the
      // headers survive the route, the screen, two controllers and the
      // player's own network layer. Falls back to the direct URL if the server
      // cannot start, because a proxy that won't run must not become a player
      // that won't play.
      final String playable = await StreamProxy.instance.wrap(url, headers);
      DiagnosticsLog.instance.note(
        'stream',
        StreamProxy.isManifest(url)
            ? 'playlist address — going direct, headers on every segment'
            : (playable == url
                ? 'proxy unavailable — going direct'
                : 'serving through the local proxy'),
        url: url,
      );
      if (!mounted) return;
      // Attached against whichever address the player is actually going to
      // open. For a proxied file that is the loopback address and the headers
      // are redundant; for a manifest, which deliberately bypasses the proxy,
      // this is the ONLY thing that gets a Referer onto the segment requests,
      // so it is load-bearing rather than belt-and-braces.
      MediaKitPlayerService.attachHeaders(playable, headers);
      DiagnosticsLog.instance.note(
        'player',
        'handing off to the player — anything after this line is libmpv',
        url: widget.probe.url,
      );
      // Close the sheet BEFORE pushing so Back from the player returns to the
      // downloader home rather than re-opening a stale sheet over it.
      Navigator.of(context).pop();
      router.push(
        Routes.player,
        extra: <String, String>{'uri': playable, 'title': widget.probe.title},
      );
    } on DownloaderException catch (e) {
      if (!mounted) return;
      setState(() => _resolving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('${s.downloaderStreamFailed}: ${e.message}')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _resolving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(s.downloaderStreamFailed)),
      );
    }
  }

  /// Mobile data and free space, asked about before anything starts.
  ///
  /// Both are cheap to check and expensive to get wrong: a downloader that
  /// quietly spends someone's data bundle, or fills the last of their storage
  /// halfway through a file, is one they stop trusting. Neither is a hard
  /// block — the user can override — but neither happens silently.
  Future<bool> _clearedToStart(
    MediaFormat format,
    String dir,
    AppStrings s,
  ) async {
    final bool wifiOnly = ref.read(wifiOnlyProvider);
    final DeviceStatus device =
        await DownloaderEngineService.instance.deviceStatus(dir);
    if (!mounted) return false;

    if (wifiOnly && device.online && !device.unmetered) {
      final bool go = await _confirm(s.downloaderMetered, s) ?? false;
      if (!go || !mounted) return false;
    }

    final int? size = format.filesize;
    if (size != null && device.freeBytes > 0) {
      // A margin, not a bare comparison: finishing with nothing left over is
      // its own kind of failure, and the size is often an estimate anyway.
      const int margin = 200 * 1024 * 1024;
      if (size + margin > device.freeBytes) {
        final bool go = await _confirm(s.downloaderLowSpace, s) ?? false;
        if (!go || !mounted) return false;
      }
    }
    return true;
  }

  Future<bool?> _confirm(String message, AppStrings s) => showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          backgroundColor: AppColors.specSheetBg,
          content: Text(
            message,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(s.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(s.downloaderDownloadAnyway),
            ),
          ],
        ),
      );

  /// Headers to play a media URL with.
  ///
  /// Starts from whatever the engine reported, then fills the two that a CDN
  /// most often insists on and that are missing surprisingly often: the page
  /// the link came from, and a browser to be. TikTok refuses its own video
  /// addresses without the first — which is why a file that downloads cleanly
  /// could fail to play, since the downloader sends them and the player was
  /// sending nothing.
  /// [_streamHeaders] plus the session cookies for the address being fetched.
  ///
  /// Separate and async because the cookies live in the engine's jar and only
  /// the native side knows which of them belong to this host. Skipped when the
  /// extractor already supplied a Cookie header of its own — it knows better
  /// than the jar does.
  Future<Map<String, String>> _streamHeadersWithSession(
    MediaFormat format,
    String mediaUrl,
  ) async {
    final Map<String, String> out = _streamHeaders(format);
    final bool already =
        out.keys.any((String k) => k.toLowerCase() == 'cookie');
    if (already) return out;
    final String? jar = await DownloaderEngineService.instance
        .cookieHeader(mediaUrl, cookies: ref.read(cookiesPathProvider));
    if (jar != null && jar.isNotEmpty) out['Cookie'] = jar;
    return out;
  }

  Map<String, String> _streamHeaders(MediaFormat format) {
    final Map<String, String> out = Map<String, String>.of(format.httpHeaders);
    final Set<String> present =
        out.keys.map((String k) => k.toLowerCase()).toSet();
    final Uri? page = Uri.tryParse(widget.probe.url);
    if (!present.contains('referer') && page != null && page.host.isNotEmpty) {
      out['Referer'] = '${page.scheme}://${page.host}/';
    }
    if (!present.contains('user-agent')) {
      out['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
    }
    return out;
  }

  Future<void> _downloadPhotos() async {
    final AppStrings s = AppStrings.of(context);
    final String dir = ref.read(downloadDirProvider);
    final String id = 'ph_${DateTime.now().microsecondsSinceEpoch}';
    final DownloadQueueNotifier queue = ref.read(downloadQueueProvider.notifier);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<List<String>> groups = widget.probe.photos
        .map((PhotoItem p) => p.candidates)
        .toList();

    // Registered without a spec: a photo set is not resumable the way a single
    // file is (each picture is all-or-nothing and they are small), so offering
    // Resume for it would be a button that lies.
    queue.register(DownloadSpec(
      id: id,
      url: widget.probe.url,
      selector: 'photos',
      dir: dir,
      title: widget.probe.title,
      // Not resumable, and it must say so. A photo set has no partial file to
      // continue from, and its spec is not something the engine can replay —
      // 'photos' is not a yt-dlp format selector. Left unmarked, an app kill
      // would restore this as a paused job with a Resume button that fails
      // every single time it is pressed.
      isPhotoSet: true,
    ));
    Navigator.of(context).pop();
    try {
      await DownloaderEngineService.instance.downloadPhotos(
        id: id,
        urlGroups: groups,
        dir: dir,
        title: widget.probe.title,
      );
    } on DownloaderException catch (e) {
      queue.dismiss(id);
      messenger.showSnackBar(
        SnackBar(content: Text('${s.downloaderFailed}: ${e.message}')),
      );
    }
  }

  Future<void> _download() async {
    final MediaFormat? format = _selected;
    if (format == null) return;
    if (!await ensureStorageAccess(context, ref)) return;
    DiagnosticsLog.instance.note(
      'tap',
      'Download pressed — ${format.qualityLabel} '
      '${format.isCombined ? '(combined)' : '(needs muxing)'}',
      url: widget.probe.url,
    );
    final AppStrings s = AppStrings.of(context);
    final String dir = ref.read(downloadDirProvider);
    final String id = 'dl_${DateTime.now().microsecondsSinceEpoch}';
    // Same reason as _stream: everything reached through `ref`/`context` is
    // resolved before the pop. The queue notifier is a root-scope provider, so
    // holding it past this sheet's lifetime is intended, not a leak.
    final DownloadQueueNotifier queue = ref.read(downloadQueueProvider.notifier);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? cookies = ref.read(cookiesPathProvider);
    final String clients = ref.read(playerClientsProvider);
    final DownloadExtras extras = ref.read(downloadExtrasProvider);
    // Checked BEFORE the sheet closes, so a refusal can still be explained
    // and reconsidered here rather than turning into a failed row later.
    if (!await _clearedToStart(format, dir, s)) return;

    final DownloadSpec spec = DownloadSpec(
      id: id,
      url: widget.probe.url,
      selector: format.downloadSelector,
      dir: dir,
      title: widget.probe.title,
      audioOnly: format.isAudioOnly,
      toMp3: format.convertToMp3,
      merge: format.needsMerge,
    );
    // Show the row immediately; the native side confirms with its own events.
    queue.register(spec);
    Navigator.of(context).pop();
    try {
      await DownloaderEngineService.instance.startDownload(
        id: spec.id,
        url: spec.url,
        selector: spec.selector,
        dir: spec.dir,
        title: spec.title,
        audioOnly: spec.audioOnly,
        toMp3: spec.toMp3,
        merge: spec.merge,
        cookies: cookies,
        clients: clients,
        subLangs: extras.subLangs.isEmpty ? null : extras.subLangs,
        embedThumbnail: extras.embedThumbnail,
        embedMetadata: extras.embedMetadata,
        rateLimit: extras.rateLimit.isEmpty ? null : extras.rateLimit,
      );
    } on DownloaderException catch (e) {
      // The job never started, so no terminal event is coming — clear the row
      // ourselves, otherwise it would sit on "Queued" forever.
      queue.dismiss(id);
      messenger.showSnackBar(
        SnackBar(content: Text('${s.downloaderFailed}: ${e.message}')),
      );
    }
  }

  Future<void> _changeDir() async {
    // Resolved before the picker's round trip: the sheet can be gone by the
    // time it returns.
    final DownloadDirNotifier dirs = ref.read(downloadDirProvider.notifier);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String failed = AppStrings.of(context).downloaderDirFailed;
    try {
      final String? picked = await FilePicker.platform.getDirectoryPath();
      if (picked == null || picked.trim().isEmpty) return;
      await dirs.set(picked);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final AppStrings s = AppStrings.of(context);
    final MediaProbe p = widget.probe;
    final double maxHeight = MediaQuery.of(context).size.height * 0.86;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: AppColors.specSheetBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _Grabber(),
          _header(p),
          const Divider(height: 1, color: AppColors.white08),
          _pathRow(s),
          const Divider(height: 1, color: AppColors.white08),
          Flexible(
            child: p.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 28),
                    child: Text(
                      s.downloaderNoFormats,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.white50, fontSize: 13),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    shrinkWrap: true,
                    children: <Widget>[
                      if (p.isPhotoPost) _photoCard(s, p),
                      _mergerNote(s),
                      if (p.audioFormats.isNotEmpty)
                        _sectionLabel(Icons.music_note_outlined, s.downloaderAudio),
                      ...p.audioFormats.map(_audioRow),
                      if (p.videoFormats.isNotEmpty)
                        _sectionLabel(Icons.videocam_outlined, s.downloaderVideo),
                      ...p.videoFormats.map(_videoRow),
                    ],
                  ),
          ),
          _actions(s, p),
        ],
      ),
    );
  }

  Widget _header(MediaProbe p) {
    final String meta = <String>[
      if (formatDuration(p.durationSeconds).isNotEmpty)
        formatDuration(p.durationSeconds),
      if (p.uploader != null && p.uploader!.isNotEmpty) p.uploader!,
      if (p.extractor != null && p.extractor!.isNotEmpty) p.extractor!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 76,
              height: 48,
              color: AppColors.specInnerPanel,
              child: p.thumbnail == null
                  ? const Icon(Icons.play_arrow_rounded,
                      color: AppColors.white40, size: 22)
                  : Image.network(
                      p.thumbnail!,
                      fit: BoxFit.cover,
                      // A dead thumbnail URL must never blank the sheet.
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.play_arrow_rounded,
                        color: AppColors.white40,
                        size: 22,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  p.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, height: 1.3),
                ),
                if (meta.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.white50, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pathRow(AppStrings s) {
    final String dir = ref.watch(downloadDirProvider);
    return InkWell(
      onTap: _changeDir,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: <Widget>[
            const Icon(Icons.folder_outlined,
                color: AppColors.white40, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                dir,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: AppColors.white50, fontSize: 11),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              s.downloaderChange,
              style: const TextStyle(
                color: AppColors.primaryBlue,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A photo post is one thing, not a list of choices, so it gets a single
  /// card that says what will be saved rather than a row per picture.
  Widget _photoCard(AppStrings s, MediaProbe p) {
    final int? side = p.photoShortSide;
    final String detail = <String>[
      '${p.photos.length} ${s.downloaderPhotos}',
      if (side != null) '${side}p',
      s.downloaderNoWatermark,
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.primaryBlue.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.photo_library_outlined,
                size: 20, color: AppColors.primaryBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    s.downloaderPhotoPost,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(
                        color: AppColors.white50, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _downloadPhotos,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryBlue,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: Text(s.downloaderSaveAll),
            ),
          ],
        ),
      ),
    );
  }

  /// Explains a short list instead of leaving the user to wonder.
  ///
  /// Most resolutions above 360p arrive as separate video and audio streams
  /// and have to be joined. With no merger available they cannot be offered at
  /// all — so the sheet collapses to whatever single combined stream the site
  /// publishes, and without a word of explanation that reads as the app being
  /// broken rather than a missing component.
  Widget _mergerNote(AppStrings s) {
    final EngineStatus status = ref.watch(engineStatusProvider);
    if (status.ffmpeg || !status.ok) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline_rounded,
              size: 14, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.downloaderNoMerger,
              style: const TextStyle(
                  color: AppColors.warning, fontSize: 11, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(IconData icon, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 14, color: AppColors.white50),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(color: AppColors.white50, fontSize: 12),
            ),
          ],
        ),
      );

  Widget _audioRow(MediaFormat f) => _formatRow(
        format: f,
        primary: f.audioLabel,
        secondary: f.ext.toUpperCase(),
        badge: f.convertToMp3 ? AppStrings.of(context).downloaderConvert : null,
        badgeIsWarning: f.convertToMp3,
      );

  Widget _videoRow(MediaFormat f) => _formatRow(
        format: f,
        primary: f.qualityLabel,
        secondary: f.ext.toUpperCase(),
        // Watermarked rows are filtered out whenever a clean copy exists, so
        // this only shows when the logo-burned version is genuinely all the
        // site offers — and then the user deserves to be told.
        badge: f.watermarked
            ? AppStrings.of(context).downloaderWatermark
            : f.codecBadge,
        badgeIsWarning: f.watermarked || f.videoTier == CodecTier.heavy,
      );

  Widget _formatRow({
    required MediaFormat format,
    required String primary,
    required String secondary,
    String? badge,
    bool badgeIsWarning = false,
  }) {
    // Identity is (id + ext + convert flag): the MP3 row reuses the best audio
    // id, so comparing ids alone would highlight two rows at once.
    final MediaFormat? sel = _selected;
    final bool active = sel != null &&
        sel.id == format.id &&
        sel.ext == format.ext &&
        sel.convertToMp3 == format.convertToMp3;
    final String size = formatBytes(format.filesize);
    final String sizeText = format.filesize == null
        ? size
        : (format.sizeIsEstimate ? '~$size' : size);

    return InkWell(
      onTap: () => setState(() => _selected = format),
      child: Container(
        color: active ? AppColors.white08 : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: <Widget>[
            Icon(
              active
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: active ? AppColors.primaryBlue : AppColors.white30,
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 68,
              child: Text(
                primary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? AppColors.primaryBlue : Colors.white,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              child: Text(
                secondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.white50, fontSize: 12),
              ),
            ),
            if (badge != null) _badge(badge, badgeIsWarning),
            const Spacer(),
            Text(
              sizeText,
              style:
                  const TextStyle(color: AppColors.white50, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, bool warning) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: warning
              ? AppColors.warning.withValues(alpha: 0.18)
              : AppColors.white08,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: warning ? AppColors.warning : AppColors.white50,
            fontSize: 10,
          ),
        ),
      );

  Widget _actions(AppStrings s, MediaProbe p) {
    final MediaFormat? sel = _selected;
    final bool canAct = sel != null;
    // A live stream has no finite file to write, and yt-dlp would record it
    // until the phone filled up. Streaming it is fine.
    // A photo post has its own button in the card above; the format actions
    // below it only exist for the music track, if there even is one.
    final bool canDownload = canAct && !p.isLive;
    // Nothing selectable at all — a photo post whose music track yt-dlp could
    // not read. The photo card above carries its own button, so rendering this
    // bar anyway would leave a stray top border and a band of padding under it.
    if (!canAct) return const SizedBox.shrink();
    // The sheet's own SafeArea does not cover this row on every device: with
    // gesture navigation the inset is small, with a three-button bar it is
    // ~48dp, and on the reporter's phone the Download button was sitting
    // underneath it. Reading viewPadding directly is the only thing that is
    // right for both.
    final double bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 14 + bottomInset),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.white08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (p.isLive)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                s.downloaderLiveNote,
                style: const TextStyle(
                    color: AppColors.warning, fontSize: 11),
              ),
            )
          else if (sel != null && !sel.isCombined && sel.hasVideo)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                s.downloaderStreamOnlyBest,
                style: const TextStyle(
                    color: AppColors.white40, fontSize: 11),
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (!canAct || _resolving) ? null : _stream,
                  icon: _resolving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(s.downloaderStream),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: AppColors.white20),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canDownload ? _download : null,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(s.downloaderDownload),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.white20,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}
