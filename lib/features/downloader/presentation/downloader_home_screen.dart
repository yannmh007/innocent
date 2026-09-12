import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/downloader/downloader_engine_service.dart';
import '../../../core/app_version.dart';
import '../../../core/theme/app_colors.dart';
import '../data/probe_parser.dart';
import '../data/probe_pipeline.dart';
import '../data/site_network_memory.dart';
import '../data/site_catalog.dart';
import '../data/remote_config_service.dart';
import '../data/tiktok_photo_extractor.dart';
import '../domain/diagnostics_log.dart';
import '../domain/download_progress.dart';
import '../domain/media_probe.dart';
import '../../../core/services/downloader/engine_readiness.dart';
import '../../../core/services/downloader/stream_proxy.dart';
import '../../../core/services/video_player/media_kit_player_service.dart';
import '../domain/probe_failure.dart';
import '../domain/quality_preset.dart';
import 'downloader_providers.dart';
import 'storage_access.dart';
import 'package:share_plus/share_plus.dart';

import 'playlist_sheet.dart';
import 'quality_sheet.dart';

/// Home of the downloader.
///
/// Three ways in, on purpose — the cheapest of the three is the one nobody
/// designs for:
///
///  1. Paste a link into the bar.
///  2. The clipboard chip, which appears whenever the user comes back to this
///     screen with a URL already copied. Copying a link in the browser and
///     switching back is the single most common real-world flow.
///  3. A site tile, which opens that site in the user's browser. Copy a link
///     there, come back, and (2) catches it instantly.
///
/// v0.99.1 reworked the presentation after the first build looked sparse and
/// unfinished on a real phone. The substantive changes:
///
///  • Tiles are drawn like launcher icons (gradient fill, white monogram)
///    rather than tinted outlines, and the grid is sized to its content — the
///    old cells were roughly four times taller than what was in them, which is
///    what made the screen feel empty.
///  • "Add" moved out of the grid into the section header. As a tile it was
///    stranded alone on a second row with three empty cells beside it.
///  • Reading a link no longer blocks behind a modal dialog. It reports inline,
///    with elapsed seconds, and the rest of the screen stays usable.
///  • A failure is a card with the one sentence that matters and the actions
///    that fix it — not a nine-line wall of yt-dlp text in a snackbar.
class DownloaderHomeScreen extends ConsumerStatefulWidget {
  const DownloaderHomeScreen({super.key, this.initialUrl});

  /// A link the screen was opened FOR — from the system share sheet. Read once
  /// on first build; the clipboard path handles everything after that.
  final String? initialUrl;

  @override
  ConsumerState<DownloaderHomeScreen> createState() =>
      _DownloaderHomeScreenState();
}

class _DownloaderHomeScreenState extends ConsumerState<DownloaderHomeScreen>
    with WidgetsBindingObserver {
  final TextEditingController _linkController = TextEditingController();
  final FocusNode _linkFocus = FocusNode();

  String? _clipboardLink;

  /// URLs already acted on or dismissed, so the chip doesn't nag about the
  /// same link every time the screen regains focus.
  final Set<String> _handledLinks = <String>{};

  /// Links a silent repair has already been attempted for.
  final Set<String> _selfHealed = <String>{};

  /// One automatic session attempt per visit to this screen.
  bool _guestSessionTried = false;

  /// Which network this site last worked on, when that is not the one in use.
  ///
  /// Null whenever there is nothing worth saying — either the phone has never
  /// seen this site work, or it is already on the network that worked. Advice
  /// offered when it might be wrong is advice that stops being read.
  String? _networkHint;

  /// The last measured verdict about this network, if one has been taken.
  NetworkCheck? _netCheck;
  bool _netChecking = false;

  /// Measures what this network does to a name, and says which remedy applies.
  ///
  /// THE POINT IS THAT IT MEASURES. Telling somebody to try Private DNS is a
  /// suggestion; telling them "this network answers this name with nothing
  /// while an encrypted resolver answers it with three addresses" is a finding,
  /// and only one of those is worth acting on. It also protects against the
  /// opposite error: when the block is NOT in the name lookup, Private DNS
  /// cannot help and saying it might would send somebody down a dead end.
  Future<void> _runNetworkCheck(String? url) async {
    if (_netChecking) return;
    setState(() => _netChecking = true);
    final List<String> hosts = <String>[
      if (Uri.tryParse(url ?? '')?.host.isNotEmpty ?? false)
        Uri.parse(url!).host,
      // A known-good name alongside the suspect one, so "everything is broken"
      // can be told apart from "this site is blocked".
      'www.youtube.com',
    ];
    final NetworkCheck? result =
        await DownloaderEngineService.instance.networkCheck(hosts);
    if (!mounted) return;
    setState(() {
      _netChecking = false;
      _netCheck = result;
    });
    if (result == null) return;
    DiagnosticsLog.instance.note(
      'network',
      'private DNS ${result.privateDns}'
      '${result.privateDnsHost != null ? ' (${result.privateDnsHost})' : ''} · ' +
          result.hosts
              .map((HostCheck h) => '${h.host}=${h.verdict}')
              .join(' · '),
    );
  }

  /// Says so when this page has already been downloaded, and offers the file.
  ///
  /// NOT A BLOCK — AN ANSWER TO A QUESTION SOMEBODY WOULD OTHERWISE ASK LATER.
  /// A second copy at a different quality is a perfectly reasonable thing to
  /// want, so this never refuses; it says what is already there and lets the
  /// download proceed if that is what was meant. The alternative is a phone
  /// quietly filling up with the same film.
  void _warnIfAlreadyHave(AppStrings s, String? sourceUrl) {
    final DownloadRecord? had =
        ref.read(downloadHistoryProvider.notifier).alreadyHave(sourceUrl);
    if (had == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.downloaderAlreadyHave),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: s.downloaderPlay,
          onPressed: () => _playSaved(s, had),
        ),
      ),
    );
  }

  /// Links already rescued by warming a session, so a wall cannot loop.
  final Set<String> _wallRescued = <String>{};

  /// Warms a YouTube session by VISITING THE VIDEO, then reads again.
  ///
  /// THE DEVICE TRAIL HANDED THIS ONE OVER. In a single session the same app
  /// failed a shared YouTube link twice with "Sign in to confirm you're not a
  /// bot" — and then, seven minutes later, read a YouTube video perfectly from
  /// the in-app browser. Nothing about the network or the clients had changed.
  /// What had changed is that the browser had LOADED A WATCH PAGE first, and
  /// the cookies it collected went into the same jar the reader is handed.
  ///
  /// The existing rescue could not do that for two reasons, and both are the
  /// point of this method. It only ran when a read came back THIN, so a wall —
  /// which arrives as a thrown error — never reached it at all. And it visited
  /// the HOME page, which earns a weaker visitor session than the page for the
  /// video actually being asked about.
  ///
  /// Off-screen, no account, nothing typed. At most once per link.
  Future<bool> _warmYouTubeSession(String url) async {
    if (!_isYouTube(url)) return false;
    if (!_wallRescued.add(url)) return false;
    DiagnosticsLog.instance.note(
      'session',
      'bot wall — visiting the video to earn a session, then retrying',
      url: url,
    );
    const SignInTarget target = SignInTargets.youtubeGuest;
    final bool ok = await DownloaderEngineService.instance.guestSession(
      // THE VIDEO'S OWN PAGE, not the home page. This is the whole difference
      // between the session the browser earned and the one we were collecting.
      url: url,
      cookieUrls: target.cookieUrls,
    );
    if (!ok || !mounted) return false;
    final String? jar = await DownloaderEngineService.instance.cookieJar();
    if (jar == null || !mounted) return false;
    await ref.read(cookiesPathProvider.notifier).set(jar);
    return true;
  }

  /// Which network this phone is on right now: `vpn` or `direct`.
  ///
  /// Cached rather than asked for on demand, because the two places that need
  /// it — recording a success and explaining a failure — are both in the middle
  /// of a read, and a channel round trip there would be a pause nobody asked
  /// for. Refreshed at the start of every read, which is the moment it could
  /// have changed since anyone last looked.
  String _networkKey = 'direct';

  /// Asks the device which network is carrying this, and remembers the answer.
  Future<void> _refreshNetworkKey() async {
    try {
      final DeviceStatus device = await DownloaderEngineService.instance
          .deviceStatus(ref.read(downloadDirProvider));
      if (!mounted) return;
      _networkKey = device.networkKey;
    } catch (_) {
      // An unknown network is the one we last knew about. Never a reason to
      // interrupt a read.
    }
  }

  /// The network the saved guest session was collected on.
  ///
  /// A SESSION BELONGS TO AN ADDRESS AS WELL AS TO A SITE. YouTube issues a
  /// visitor session against the address that asked for it, and presenting it
  /// later from a completely different one is not a neutral act — it is one of
  /// the shapes its bot check is watching for. So a session harvested without
  /// the VPN is worse than useless once the VPN is on, and the fix is simply
  /// to notice and collect another.
  String? _sessionNetwork;

  /// Hosts that have asked us to slow down, and until when.
  ///
  /// A rate limit is the one failure a person makes worse by doing the obvious
  /// thing. The screen says "failed", so they press it again, and each press
  /// is another burst at a server already refusing bursts. Blocking the read
  /// here — with the reason and the remaining wait shown plainly — is the only
  /// way to be on their side about it, because the alternative is an app that
  /// politely lets them dig deeper.
  ///
  /// Per host: TikTok being throttled says nothing about YouTube.
  static final Map<String, DateTime> _slowDownUntil = <String, DateTime>{};

  /// host → cached icon file, for sites this person has actually visited.
  ///
  /// Scanned ONCE per screen rather than checked per tile: forty tiles doing
  /// their own asynchronous file lookup on every rebuild is exactly the kind
  /// of thing that makes a grid feel cheap on a slow phone.
  Map<String, String> _siteIcons = const <String, String>{};

  /// Set when a shared link deferred its session harvest until after the read.
  ///
  /// v1.5.0 skipped the harvest outright on the share path to keep a WebView
  /// off the main thread while somebody was watching a spinner. That was right
  /// about the thread and wrong about the outcome: the device report came back
  /// saying `cookies none`, because a share is the one entry point that may
  /// never open this screen again, so "later" turned into "never". Deferring
  /// keeps the thread clear AND still leaves a session behind for next time.
  bool _harvestAfterRead = false;

  /// Bumped for every read. A superseded read still finishes eventually and
  /// must not write its result over the newer one's — a counter rather than a
  /// flag because both are briefly in flight together.
  int _probeGeneration = 0;

  /// When the current read started, for the timing diagnostic.
  DateTime? _probeStartedAt;

  /// True only when the person pressed Cancel. A "cancelled" result that
  /// nobody asked for is a fault, not a choice, and must be shown.
  bool _cancelledByUser = false;

  bool _probing = false;
  int _probeSeconds = 0;
  Timer? _probeTimer;

  ProbeFailure? _failure;
  String? _failedUrl;
  bool _showFailureDetail = false;
  bool _updatingEngine = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The streaming proxy lives in core and must not reach into the feature
    // layer itself, so the screen hands it somewhere to report. Set here
    // rather than in main() because it is only ever meaningful once the
    // downloader exists.
    StreamProxy.onEvent = (String stage, String message, {String? url}) =>
        DiagnosticsLog.instance.add(stage, message, url: url);
    DiagnosticsLog.instance.note('app', 'downloader opened');
    DownloaderEngineService.onBrowserNote =
        (String m) => DiagnosticsLog.instance.note('browser', m);
    unawaited(_loadSiteIcons());
    // And the player's own words, which have never been written down before.
    MediaKitPlayerService.onPlaybackError =
        (String message) => DiagnosticsLog.instance.add('player', message);
    _linkController.addListener(_onLinkChanged);
    // The paste bar draws a blue border while focused; without this listener
    // that border would only appear on the next unrelated rebuild.
    _linkFocus.addListener(_onLinkChanged);
    final String? shared = widget.initialUrl;
    if (shared != null && shared.trim().isNotEmpty) {
      // Opened from a share sheet: go straight to reading it. Deferred to the
      // first frame because _handleLink shows UI, and initState is too early
      // to put anything on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          DiagnosticsLog.instance.note('tap', 'link arrived from share sheet');
          _handleLink(shared);
        }
      });
    } else {
      _checkClipboard();
    }
    // THE GUEST SESSION IS NO LONGER FETCHED EAGERLY ON A SHARE.
    //
    // Harvesting it builds an off-screen WebView, and a WebView's first
    // creation in a process is heavy, main-thread work — the same main thread
    // that has to paint this screen and carry every method-channel reply back
    // from the engine. On a warm open that is invisible. On a share, where the
    // app is cold-starting AND reading a link in the same instant, it is a
    // background chore sitting on the one lane a person is watching, which is
    // the exact mistake this feature has now made three times (the updater on
    // probeExec, then ensureReady on probeExec, now this).
    //
    // Nothing is lost by waiting: a session is only needed when a site answers
    // thin, and the read already forces one at that point, on demand and with
    // evidence rather than on the chance it might help.
    if (shared == null || shared.trim().isEmpty) {
      unawaited(_ensureGuestSession());
    } else {
      // Deferred, not dropped — see [_harvestAfterRead].
      _harvestAfterRead = true;
    }
    // The update check LAST and late. It is a background chore that can take
    // half a minute, and starting it in the same breath as reading a shared
    // link is what made sharing appear broken while pasting worked.
    unawaited(_syncEngineReadiness());
    unawaited(_warnIfNotificationsBlocked());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _probeTimer?.cancel();
    _linkController.removeListener(_onLinkChanged);
    _linkFocus.removeListener(_onLinkChanged);
    _linkController.dispose();
    _linkFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android only lets the focused app read the clipboard, so this is the
    // moment it can succeed: the user has just come back from the browser.
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      _adoptCookieJar();
    }
  }

  /// Picks up a session created by the in-app sign-in screen.
  ///
  /// Polled on resume rather than returned as a result, because the sign-in
  /// screen is a separate activity started from the application context —
  /// which keeps the engine free of any reference to the Activity, at the cost
  /// of having to ask afterwards rather than being told.
  Future<void> _adoptCookieJar() async {
    final String? jar = await DownloaderEngineService.instance.cookieJar();
    if (jar == null || jar.isEmpty || !mounted) return;
    if (ref.read(cookiesPathProvider) == jar) return;
    await ref.read(cookiesPathProvider.notifier).set(jar);
    if (!mounted) return;
    // Signing in is only ever done BECAUSE a link failed, so finish the job
    // rather than making them paste it again.
    final String? retry = _failedUrl;
    if (retry != null && _failure != null) {
      _toast(AppStrings.of(context).downloaderSignedIn);
      _handledLinks.remove(retry);
      await _handleLink(retry);
    }
  }

  /// The no-login repair.
  ///
  /// Offered FIRST, and worded as a repair rather than a login, because for
  /// most people the whole problem is being treated as a script instead of a
  /// browser — and that is fixed by visiting the site once as an ordinary
  /// anonymous visitor. Nothing is typed, no account exists, and the screen
  /// closes itself. Signing in stays available for the minority of links that
  /// genuinely need an account (members-only, age-gated).
  Future<void> _fixAutomatically(String url) async {
    final AppStrings s = AppStrings.of(context);
    final SignInTarget? guest = SignInTargets.guestForUrl(url);
    if (guest == null) {
      await _signIn(url);
      return;
    }
    _toast(s.downloaderPreparingSession);
    final bool ok = await DownloaderEngineService.instance.signIn(
      url: guest.url,
      label: guest.label,
      cookieUrls: guest.cookieUrls,
      autoClose: true,
    );
    if (!ok && mounted) _toast(s.downloaderSignInFailed);
  }

  Future<void> _signIn(String url) async {
    final AppStrings s = AppStrings.of(context);
    final SignInTarget? target = SignInTargets.forUrl(url);
    final bool ok = await DownloaderEngineService.instance.signIn(
      url: target?.url ?? url,
      label: target?.label ?? '',
      cookieUrls: target?.cookieUrls ?? <String>[url],
    );
    if (!ok && mounted) _toast(s.downloaderSignInFailed);
  }

  void _onLinkChanged() {
    // Only rebuilt for the clear button and the focus border.
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------- clipboard

  Future<void> _checkClipboard() async {
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? normalized = _normalizeUrl(data?.text);
      if (!mounted) return;
      if (normalized == null || _handledLinks.contains(normalized)) {
        if (_clipboardLink != null) setState(() => _clipboardLink = null);
        return;
      }
      if (_clipboardLink != normalized) {
        setState(() => _clipboardLink = normalized);
      }
    } catch (_) {
      // Clipboard access can be denied; the paste bar still works.
    }
  }

  static bool _isYouTube(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    final String host = uri.host.toLowerCase();
    return host.endsWith('youtube.com') ||
        host.endsWith('youtu.be') ||
        host.endsWith('youtube-nocookie.com');
  }

  /// Accepts what people actually paste — with or without a scheme, with
  /// surrounding whitespace, and with trailing text after the URL (share
  /// sheets add it). Returns null when there is no usable http(s) URL.
  static String? _normalizeUrl(String? raw) {
    if (raw == null) return null;
    String text = raw.trim();
    if (text.isEmpty || text.length > 2048) return null;
    final int schemeAt = text.indexOf('http');
    if (schemeAt > 0) text = text.substring(schemeAt);
    text = text.split(RegExp(r'\s')).first;
    if (text.isEmpty) return null;
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      // Bare "youtube.com/watch?v=x" is a link to a human; make it one.
      if (!text.contains('.') || text.contains(' ')) return null;
      text = 'https://$text';
    }
    final Uri? uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.host.isEmpty || !uri.host.contains('.')) return null;
    return uri.toString();
  }

  // -------------------------------------------------------------- probe

  Future<void> _handleLink(String raw) async {
    DiagnosticsLog.instance.note('read', 'link handed to reader');
    if (_blockedBySlowDown(raw)) return;
    final AppStrings s = AppStrings.of(context);
    final String? url = _normalizeUrl(raw);
    if (url == null) {
      _toast(s.downloaderInvalidLink);
      return;
    }
    if (_probing) {
      // Superseding, not ignoring. A bare `return` here is why pasting a link
      // while something was already being read appeared to do nothing at all:
      // the request was dropped on the floor and the only way out was Cancel.
      // A newer link is a clearer statement of intent than an older one.
      _cancelProbe(byUser: false);
    }

    // A link looked at moments ago is served straight from memory. Re-running
    // yt-dlp for it would cost the whole network round trip again.
    final MediaProbe? cached = ProbeCache.instance.get(url);
    if (cached != null) {
      _handledLinks.add(url);
      setState(() {
        _clipboardLink = null;
        _failure = null;
      });
      _linkController.clear();
      _linkFocus.unfocus();
      await QualitySheet.show(context, cached);
      return;
    }

    _linkFocus.unfocus();
    _cancelledByUser = false;
    setState(() {
      _probing = true;
      _probeSeconds = 0;
      _failure = null;
      _showFailureDetail = false;
      _handledLinks.add(url);
      // Bounded: this only exists to stop the clipboard chip re-offering a
      // link, and an unbounded set in a screen that lives as long as the app
      // is a slow leak for no benefit.
      if (_handledLinks.length > 40) {
        _handledLinks.remove(_handledLinks.first);
      }
      _clipboardLink = null;
    });
    final int generation = ++_probeGeneration;
    _probeStartedAt = DateTime.now();
    // Visible in the report WHILE it runs, not only once it ends — a read
    // that never ends is the one worth seeing.
    DiagnosticsLog.instance.readStarted(url);
    DiagnosticsLog.instance.note('read', 'probe requested', url: url);
    // The clock starts BEFORE the engine wait, not after it. Waiting is the
    // right behaviour, but a card frozen at "0s" for up to forty seconds is
    // not — and since only this timer rebuilds the card while a read is in
    // flight, starting it late also meant the "updating engine" line could
    // never appear at all.
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _probeSeconds++);
    });

    // Wait for the engine to be current before reading anything. This is the
    // difference between the two paths that had baffled us: a link pasted a
    // few seconds after opening the screen happened to arrive after the update
    // finished, while a shared link arrived before it and was read by an
    // engine eight months out of date. Racing it was never going to be
    // reliable for anyone; waiting is. Capped inside ensureCurrent, so a
    // failing update degrades into "try anyway" rather than "never try".
    EngineReadiness.instance
        .configure(autoUpdate: ref.read(autoUpdateProvider));
    DiagnosticsLog.instance.note(
      'engine',
      'waiting for readiness (${EngineReadiness.instance.phase.value.name})',
    );
    await EngineReadiness.instance.ensureCurrent();
    // A newer link took over while we waited; it owns _probing and the timer.
    if (!mounted || generation != _probeGeneration) return;

    MediaProbe? probe;
    String? error;
    try {
      // ASKED, NOT REMEMBERED — and this one line was the whole "360p only".
      //
      // The parser drops every video-only rendition when ffmpeg is absent,
      // because without a muxer they cannot be joined to audio and offering
      // them would be a lie. That is correct. What was wrong is WHERE the
      // answer came from: a cached status that, on a cold start, has not been
      // filled in yet. So a shared link read while the engine was still waking
      // was told there is no muxer, threw away everything except the one
      // pre-merged rendition YouTube offers, and produced a 360p-only list —
      // from the SAME 37 formats that gave eight rows seconds later. The
      // engine had ffmpeg the whole time; nobody had asked it yet.
      //
      // ensureReady() is idempotent and returns immediately once initialised,
      // which by this point it is: ensureCurrent() has already been awaited
      // just above. Being certain costs nothing here and a lie costs the
      // person every quality above 360p.
      final EngineStatus status =
          await DownloaderEngineService.instance.ensureReady();
      if (!mounted || generation != _probeGeneration) return;
      // Keep the rest of the screen honest too, now that we know.
      ref.read(engineStatusProvider.notifier).refresh();

      // A link whose subject IS a collection is read flat first. Note what
      // this deliberately excludes: `watch?v=…&list=…` is a video that happens
      // to sit in a playlist, and treating that as a playlist would override
      // what the person plainly meant.
      if (PlaylistParser.looksLikePlaylist(url)) {
        final String listJson = await DownloaderEngineService.instance.probe(
          url,
          cookies: ref.read(cookiesPathProvider),
          clients: ref.read(playerClientsProvider),
          flatPlaylist: true,
        );
        final PlaylistProbe? list = PlaylistParser.tryParse(listJson, url);
        if (list != null && !list.isEmpty) {
          _probeTimer?.cancel();
          _probeTimer = null;
          if (!mounted) return;
          DiagnosticsLog.instance.readFinished();
          setState(() => _probing = false);
          _linkController.clear();
          await PlaylistSheet.show(context, list);
          return;
        }
        // Not really a collection after all — fall through and read it as one
        // video rather than telling the user their link is bad.
      }
      // ONE READER, SHARED WITH THE IN-APP BROWSER.
      //
      // This sequence — read, parse with the real ffmpeg answer, and ask
      // YouTube again through the alternate players when it offers a suspicious
      // single rung — used to live only here, inside a widget. The browser
      // cannot reach a widget and must work when this screen has never been
      // built, so it grew its own reader in Kotlin, and the two drifted until
      // the same YouTube video gave a full sheet when pasted and a thin,
      // soundless one when found while browsing.
      //
      // The `json` local below is kept because the trail line reports the RAW
      // format count, which is a fact about the reply rather than about the
      // parse, and losing it would undo the v1.21.0 diagnosis.
      // ASKED NOW, NOT REMEMBERED FROM STARTUP. Somebody toggling a VPN
      // between two reads is the whole situation this exists for, so a value
      // collected when the app opened would be wrong exactly when it matters.
      await _refreshNetworkKey();

      final String json = await DownloaderEngineService.instance.probe(
        url,
        cookies: ref.read(cookiesPathProvider),
        clients: ref.read(playerClientsProvider),
      );
      MediaProbe parsed =
          ProbeParser.parse(json, url, ffmpegAvailable: status.ffmpeg);

      // WHAT THE ENGINE SENT vs WHAT WE KEPT.
      //
      // "got 1 video option" has been read four times as "YouTube only
      // offered one", and nobody has ever checked. Our parser deliberately
      // collapses twenty-odd near-duplicate renditions down to one row per
      // resolution, so a thin list could just as easily be the collapse going
      // wrong as the site being stingy. These two numbers side by side settle
      // it in one glance and cost one line.
      DiagnosticsLog.instance.note(
        'read',
        'engine sent ${_rawFormatCount(json)} formats → kept '
        '${parsed.videoFormats.length} video + ${parsed.audioFormats.length} audio'
        // Recorded because it is the single input that decides whether
        // video-only renditions survive, and getting it wrong is invisible in
        // the result — a short list looks exactly like a stingy site.
        '  (ffmpeg ${status.ffmpeg ? 'ok' : 'MISSING'})',
        url: url,
      );

      // A YouTube answer with one resolution in it is not a video with one
      // resolution — it is a client that only told us about one. Ask again
      // through the alternate players and keep whichever ladder is longer.
      // Gated to YouTube because the alternate-client argument is YouTube's;
      // everywhere else it would be a wasted round trip.
      if (_isYouTube(url) &&
          parsed.videoFormats.length <= 1 &&
          !parsed.isLive &&
          ref.read(playerClientsProvider).trim().isNotEmpty) {
        // MOVED, NOT COPIED. The in-app browser needs this exact escalation
        // and cannot reach a widget to get it, so it now lives in the shared
        // pipeline and both callers ask the same function. What stays here is
        // the part that is genuinely this screen's: the guest-session rescue
        // below, which involves the user.
        final MediaProbe? better = await ProbePipeline.alternateYouTubeRead(
          url,
          current: parsed,
          cookies: ref.read(cookiesPathProvider),
          clients: ref.read(playerClientsProvider),
          ffmpegAvailable: status.ffmpeg,
        );
        if (better != null) parsed = better;

        // Still thin. A missing session is the usual reason a site answers
        // with one rendition instead of the ladder, so get one and ask once
        // more — this is the case the earlier build left to the user to
        // notice, which they cannot be expected to do.
        // THE `cookies == null` GATE IS GONE, and it was the whole bug.
        //
        // This escalation was written believing a missing session is why a
        // site answers with one rendition instead of a ladder. That was true
        // once. But once a session HAS been collected the gate is permanently
        // shut, so the retry could only ever fire on a phone that had never
        // signed in — and the device report proves the cost: cookies present,
        // one video format offered, and no second attempt made. The rescue
        // was disabled precisely when it was needed.
        //
        // Thin is thin. Retry on the evidence in front of us, not on a guess
        // about the cause: harvest a session if we lack one, and ask again
        // through the alternate players either way.
        if (parsed.videoFormats.length <= 1) {
          DiagnosticsLog.instance.note(
            'read',
            'thin ladder (${parsed.videoFormats.length} video) — retrying',
            url: url,
          );
          if (ref.read(cookiesPathProvider) == null) {
            await _ensureGuestSession(force: true);
          }
          if (mounted) {
            try {
              // forceClients: ask through the alternate players explicitly.
              // Without it this re-runs the identical command that just came
              // back thin, which is the same wasted round trip the non-YouTube
              // hosts were making until v1.6.0.
              final String third = await DownloaderEngineService.instance.probe(
                url,
                cookies: ref.read(cookiesPathProvider),
                clients: ref.read(playerClientsProvider),
                forceClients: true,
              );
              final MediaProbe withSession =
                  ProbeParser.parse(third, url, ffmpegAvailable: status.ffmpeg);
              if (withSession.videoFormats.length > parsed.videoFormats.length) {
                parsed = withSession;
              }
            } catch (_) {}
          }
        }
        if (parsed.videoFormats.length <= 1) {
          DiagnosticsLog.instance.add(
            'probe',
            'only ${parsed.videoFormats.length} video format offered',
            url: url,
          );
        }
      }
      probe = parsed;
    } on DownloaderException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    }

    // TikTok photo posts. yt-dlp has no pictures to give for these — its
    // extractor falls through to the post's music track and returns that alone
    // — so a post with no video behind a TikTok link is the signal to go and
    // read the images out of the page ourselves.
    //
    // Gated on "TikTok AND no video" so an ordinary clip never pays for it.
    if (TikTokPhotoExtractor.isTikTok(url) &&
        (probe == null || probe.videoFormats.isEmpty)) {
      final TikTokPhotoPost? post = await TikTokPhotoExtractor.fetch(url);
      if (post == null || post.images.isEmpty) {
        DiagnosticsLog.instance.add(
          'photos',
          TikTokPhotoExtractor.lastError ?? 'no photos found',
          url: url,
        );
      }
      if (post != null && post.images.isNotEmpty) {
        probe = (probe ??
                MediaProbe(
                  url: url,
                  title: post.title ?? '',
                  videoFormats: const <MediaFormat>[],
                  audioFormats: const <MediaFormat>[],
                  uploader: post.author,
                ))
            .withPhotos(post.images, betterTitle: post.title);
        error = null;
      }
    }

    _probeTimer?.cancel();
    _probeTimer = null;
    if (!mounted) return;
    // A newer link took over while this one was still finishing.
    if (generation != _probeGeneration) return;

    // Slow reads are the whole complaint, so record how long and for which
    // site — one paste of the diagnostics then says where the time went
    // instead of leaving it to be guessed at.
    DiagnosticsLog.instance.readFinished();
    final DateTime? startedAt = _probeStartedAt;
    if (startedAt != null) {
      final int seconds = DateTime.now().difference(startedAt).inSeconds;
      if (seconds >= 10) {
        DiagnosticsLog.instance.add('probe', 'took ${seconds}s', url: url);
      }
    }

    // The read is over, so the lane is free. A share deferred its session
    // harvest to here rather than skipping it — see _harvestAfterRead. Placed
    // after the timing block because BOTH the empty path and the success path
    // pass through it, and a session that only gets collected when a read
    // succeeds is one that is never collected when it is most needed.
    if (_harvestAfterRead) {
      _harvestAfterRead = false;
      unawaited(_ensureGuestSession());
    }

    // The probe may have been the call that finished first-run initialization,
    // which changes what the sheet can offer.
    ref.read(engineStatusProvider.notifier).refresh();

    if (probe == null || probe.isEmpty) {
      // An empty result that FOLLOWED an engine error is not "this link has
      // nothing in it" — it is the error, and the error is the thing the user
      // can act on. Only call it unsupported when the engine genuinely
      // succeeded and simply found nothing, otherwise a broken TikTok
      // extractor reads as an empty post and the Update button looks pointless.
      final ProbeFailure failure = (error != null && error.isNotEmpty)
          ? ProbeFailure.classify(error)
          : const ProbeFailure(ProbeFailureKind.unsupported, 'no formats');

      // A WALL IS NOT A DEAD END WHILE A SESSION IS STILL UNTRIED. Attempted
      // once per link, before anything is shown, because a failure card that
      // could have been a quality sheet is the worst thing this screen does.
      if ((failure.kind == ProbeFailureKind.botWall ||
              failure.kind == ProbeFailureKind.needsAccount) &&
          await _warmYouTubeSession(url)) {
        if (!mounted) return;
        if (generation != _probeGeneration) return;
        setState(() => _probing = false);
        await _handleLink(url);
        return;
      }
      // Recorded even when it says "cancelled". Keeping a cancel out of the
      // UI is kindness; keeping it out of the REPORT hid a real bug for an
      // entire round of testing, because the one symptom — reads quietly
      // producing nothing — left no trace anywhere.
      DiagnosticsLog.instance.add(
        'probe',
        failure.kind == ProbeFailureKind.cancelled && !_cancelledByUser
            ? 'cancelled without being asked: ${failure.raw}'
            : failure.raw,
        url: url,
      );
      if (error != null && error.contains('timed out')) {
        DiagnosticsLog.instance.add(
          'probe',
          'gave up after ${DownloaderEngineService.probeTimeout.inSeconds}s',
          url: url,
        );
      }
      // SAY THE NETWORK THING FIRST, because on this connection it is the
      // likeliest single cause and the slowest one to discover by guessing.
      // Only when the phone has actually SEEN this site work on the other
      // network — a guess dressed as a memory would be worse than silence.
      if (failure.kind == ProbeFailureKind.botWall ||
          failure.kind == ProbeFailureKind.network ||
          failure.kind == ProbeFailureKind.needsAccount) {
        final String? worked = await SiteNetworkMemory.lastWorkingNetwork(url);
        if (worked != null && worked != _networkKey) {
          DiagnosticsLog.instance.add(
            'network',
            worked == 'direct'
                ? 'this site last worked with the VPN OFF (it is ON now)'
                : 'this site last worked with the VPN ON (it is OFF now)',
            url: url,
          );
          _networkHint = worked;
        } else {
          _networkHint = null;
        }
      } else {
        _networkHint = null;
      }

      final bool silent =
          failure.kind == ProbeFailureKind.cancelled && _cancelledByUser;
      setState(() {
        _probing = false;
        // A cancel the user ASKED for is their own doing, and an error card
        // would be scolding them for pressing the button we offered. One they
        // did not ask for is a fault and gets shown like any other.
        _failure = silent ? null : failure;
        _failedUrl = url;
      });
      // A RATE LIMIT IS NOT SOMETHING TO HEAL FROM — it is something to stop
      // doing. Self-healing here means updating the engine and reading again,
      // which is another burst at a server that just asked for fewer. The
      // device report caught exactly that: a 429, then an automatic re-read
      // six seconds later, then the same 429.
      if (failure.kind == ProbeFailureKind.rateLimited) {
        _startSlowDown(url);
      } else {
        unawaited(_selfHeal(url, failure));
      }
      return;
    }

    // A read that worked means the limit has lifted; do not keep somebody
    // waiting out a clock for a problem that is already over.
    final String? okHost = Uri.tryParse(url)?.host.toLowerCase();
    if (okHost != null && okHost.isNotEmpty) _slowDownUntil.remove(okHost);

    DiagnosticsLog.instance.note(
      'read',
      'got ${probe.videoFormats.length} video + '
      '${probe.audioFormats.length} audio options',
      url: url,
    );
    ProbeCache.instance.put(url, probe);
    _warnIfAlreadyHave(AppStrings.of(context), url);
    // WRITE DOWN WHICH NETWORK THIS WORKED ON — and only HERE, past every
    // early return. This used to sit above the failure branch, so a bot wall
    // was recorded as a success. That is worse than not recording at all: the
    // memory exists so a later failure can say "this site last worked with the
    // VPN off", and one that learns from failures will eventually say it about
    // a network where the site never worked.
    unawaited(SiteNetworkMemory.remember(url, _networkKey));
    // AUDIT FIX (v1.55.1) — a probe can take tens of seconds, and leaving the
    // screen during one is the normal thing to do when it is slow. Everything
    // below this point runs after several awaits, so the widget may well be
    // gone: setState would then throw, and the BuildContext reads that follow
    // would be reading a dead tree.
    if (!mounted) return;
    setState(() => _probing = false);
    _linkController.clear();

    // A saved preset means the question has already been answered. Asking it
    // again on every link is the most repetitive thing about this screen.
    final QualityPreset preset = ref.read(defaultQualityProvider);
    if (preset != QualityPreset.ask && !probe.isPhotoPost && !probe.isLive) {
      await _quickDownload(probe, preset);
      return;
    }
    await QualitySheet.show(context, probe);
  }

  /// The repairs that can be attempted without asking.
  ///
  /// Only the invisible ones belong here: re-reading the settings file and
  /// updating the engine happen in the background and change nothing the user
  /// can see, so doing them unprompted is a kindness. Anything that opens a
  /// window stays behind a button — a screen appearing on its own is alarming
  /// even when it would have helped.
  ///
  /// Runs at most once per link, so a site that is simply down cannot turn
  /// into a loop.
  Future<void> _selfHeal(String url, ProbeFailure failure) async {
    if (!failure.updateMayHelp) return;
    if (!_selfHealed.add(url)) return;

    // A newer settings file may already name the player list that works.
    await ref.read(remoteConfigProvider.notifier).refresh(force: true);
    if (!mounted) return;

    // A failure is the strongest single signal that the engine has fallen
    // behind, so it goes to the coordinator rather than being handled here.
    final String? before = ref.read(engineStatusProvider).version;
    await EngineReadiness.instance.noteFailure();
    if (!mounted) return;
    ref.read(engineStatusProvider.notifier).refresh();
    final String? after = EngineReadiness.instance.status.version;

    // Only retry when something actually changed; otherwise the second
    // attempt is the first attempt with extra waiting.
    if (before == after) return;
    if (_failedUrl != url || _failure == null) return;
    _handledLinks.remove(url);
    await _handleLink(url);
  }

  /// Makes sure a session exists, before anything has had a chance to fail.
  ///
  /// The device's own report showed why this belongs here rather than behind a
  /// button: the first link came back with the full quality ladder and every
  /// one after it with a single entry, while cookies read "none". A site with
  /// no session for you gives a short leash. Waiting for a failure and then
  /// offering a fix means the failure happens first — every time, to everyone.
  ///
  /// Silent, and nothing is asked of the user. If it doesn't work, nothing is
  /// lost; the manual paths are still there.
  /// True when the saved jar holds a signed-in YouTube session.
  ///
  /// THE DISTINCTION THAT DECIDES WHETHER TO THROW IT AWAY. A visitor session
  /// is judged by the address it was issued to, so replaying one from a
  /// different network is worse than having none — which is why a network
  /// change forces a fresh one. An ACCOUNT session is judged by whose it is
  /// and travels anywhere, so discarding it on a network change would replace
  /// something that works everywhere with something that works nowhere. The
  /// research is blunt about the cost, too: frequent cookie clearing is itself
  /// one of the things that provokes the check.
  Future<bool> _hasSignedInYouTube() async {
    try {
      final String? jar = await DownloaderEngineService.instance.cookieJar();
      if (jar == null || jar.isEmpty) return false;
      final File file = File(jar);
      if (!await file.exists()) return false;
      final String text = await file.readAsString();
      return text.contains('LOGIN_INFO') || text.contains('__Secure-3PSID');
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureGuestSession({bool force = false}) async {
    // THE NETWORK CHANGED, SO THE SESSION IS STALE. Not an optimisation: a
    // visitor session collected on one address and replayed from another is
    // one of the patterns YouTube's check exists to catch, so reusing it is
    // actively worse than having none. Noticing costs one string comparison.
    final String nowNetwork = _networkKey;
    bool networkChanged =
        _sessionNetwork != null && _sessionNetwork != nowNetwork;
    if (networkChanged && await _hasSignedInYouTube()) {
      // An account session is not the network's to invalidate.
      DiagnosticsLog.instance.note(
        'network',
        'network changed but the saved session is signed in — keeping it',
      );
      _sessionNetwork = nowNetwork;
      networkChanged = false;
    }
    if (networkChanged) {
      DiagnosticsLog.instance.note(
        'network',
        'network changed ($_sessionNetwork to $nowNetwork) — collecting a fresh session',
      );
      _guestSessionTried = false;
    }
    final bool must = force || networkChanged;
    if (!must && ref.read(cookiesPathProvider) != null) return;
    if (_guestSessionTried && !must) return;
    _guestSessionTried = true;
    _sessionNetwork = nowNetwork;

    // Something may already be saved from a previous run or a sign-in.
    final String? existing = await DownloaderEngineService.instance.cookieJar();
    if (existing != null && existing.isNotEmpty) {
      if (!mounted) return;
      if (ref.read(cookiesPathProvider) != existing) {
        await ref.read(cookiesPathProvider.notifier).set(existing);
      }
      if (!must) return;
    }

    const SignInTarget target = SignInTargets.youtubeGuest;
    final bool ok = await DownloaderEngineService.instance.guestSession(
      url: target.url,
      cookieUrls: target.cookieUrls,
    );
    if (!ok || !mounted) return;
    final String? jar = await DownloaderEngineService.instance.cookieJar();
    if (jar == null || !mounted) return;
    await ref.read(cookiesPathProvider.notifier).set(jar);
  }

  /// Says so when the system will swallow our notifications.
  ///
  /// Reported as a real problem rather than left silent: with notifications
  /// blocked, a download runs to completion behind a foreground service that
  /// nobody can see, which from the outside is identical to a download that
  /// never started at all.
  Future<void> _warnIfNotificationsBlocked() async {
    final String dir = ref.read(downloadDirProvider);
    final DeviceStatus device =
        await DownloaderEngineService.instance.deviceStatus(dir);
    if (device.notificationsEnabled || !mounted) return;
    final AppStrings s = AppStrings.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(s.downloaderNotifsBlocked),
      action: SnackBarAction(
        label: s.downloaderOpenSettings,
        onPressed: DownloaderEngineService.instance.openNotificationSettings,
      ),
    ));
  }

  /// Hands the schedule to the one place that owns it.
  ///
  /// This function used to contain its own copy of the rules — a delay, a
  /// staleness test, a due test, a metered test — while the failure handler
  /// and the settings button each had their own. Three implementations of
  /// "when should the engine update" is how a phone ends up running an
  /// eight-month-old one with the setting switched on.
  Future<void> _syncEngineReadiness() async {
    EngineReadiness.instance
        .configure(autoUpdate: ref.read(autoUpdateProvider));
    await EngineReadiness.instance.ensureCurrent();
    if (mounted) ref.read(engineStatusProvider.notifier).refresh();
  }

  /// Downloads straight away using the saved preset — no sheet.
  ///
  /// The preset is a format EXPRESSION rather than a chosen row, so it needs
  /// nothing from the format list; the probe was only ever needed for a title.
  ///
  /// (This method was silently deleted once, by an edit that replaced a range
  /// between two landmarks and swallowed the function that had been inserted
  /// between them. Nothing in the balance or contract checks noticed, because
  /// the file was still perfectly well-formed — it simply called something
  /// that no longer existed.)
  Future<void> _quickDownload(MediaProbe probe, QualityPreset preset) async {
    final AppStrings s = AppStrings.of(context);
    final String dir = ref.read(downloadDirProvider);
    final DownloadExtras extras = ref.read(downloadExtrasProvider);
    final DownloadQueueNotifier queue =
        ref.read(downloadQueueProvider.notifier);
    final DownloadSpec spec = DownloadSpec(
      id: 'q_${DateTime.now().microsecondsSinceEpoch}',
      url: probe.url,
      selector: preset.selector,
      dir: dir,
      title: probe.title,
      audioOnly: preset.isAudioOnly,
      merge: preset.needsMerge,
    );
    queue.register(spec);
    try {
      await DownloaderEngineService.instance.startDownload(
        id: spec.id,
        url: spec.url,
        selector: spec.selector,
        dir: spec.dir,
        title: spec.title,
        audioOnly: spec.audioOnly,
        merge: spec.merge,
        cookies: ref.read(cookiesPathProvider),
        clients: ref.read(playerClientsProvider),
        subLangs: extras.subLangs.isEmpty ? null : extras.subLangs,
        embedThumbnail: extras.embedThumbnail,
        embedMetadata: extras.embedMetadata,
        rateLimit: extras.rateLimit.isEmpty ? null : extras.rateLimit,
      );
    } on DownloaderException catch (e) {
      queue.dismiss(spec.id);
      if (mounted) _toast('${s.downloaderFailed}: ${e.message}');
    }
  }

  /// [byUser] separates the two very different reasons a read stops.
  ///
  /// Pressing Cancel is a decision and deserves silence. A newer link taking
  /// over is not, and if that path ends up reporting "cancelled" the screen
  /// would go quiet for a reason nobody chose — which is exactly how a real
  /// fault stayed invisible for a whole round of testing.
  /// How many formats the engine actually returned, before our parser reduced
  /// them. Counted from the JSON rather than parsed: this is a diagnostic, and
  /// a diagnostic that can fail to parse is a diagnostic that can hide the
  /// thing it was added to reveal.
  static int _rawFormatCount(String json) {
    try {
      return RegExp(r'"format_id"\s*:').allMatches(json).length;
    } catch (_) {
      return -1;
    }
  }

  /// True when this host has asked us to wait, and the wait is not over.
  ///
  /// Shows the failure card rather than failing silently: a person who is
  /// told nothing assumes the app is broken and reaches for the button again,
  /// which is precisely the behaviour that keeps the limit alive.
  bool _blockedBySlowDown(String raw) {
    final String? host = Uri.tryParse(raw.trim())?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;
    final DateTime? until = _slowDownUntil[host];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _slowDownUntil.remove(host);
      return false;
    }
    final int mins = until.difference(DateTime.now()).inMinutes + 1;
    DiagnosticsLog.instance.note(
      'read',
      'held back — $host asked us to slow down, ~${mins}m left',
      url: raw,
    );
    if (mounted) {
      // The remaining wait, in their own language. A countdown turns "it is
      // broken" into "it is coming back", which is the difference between
      // someone waiting and someone hammering the button.
      final String wait =
          AppStrings.of(context).downloaderRateLimitWait.replaceAll(
                '@m',
                '$mins',
              );
      setState(() {
        _probing = false;
        _failure = ProbeFailure(ProbeFailureKind.rateLimited, wait);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(wait)));
    }
    return true;
  }

  /// Records that a host wants us to stop asking for a while.
  void _startSlowDown(String raw) {
    final String? host = Uri.tryParse(raw.trim())?.host.toLowerCase();
    if (host == null || host.isEmpty) return;
    // Ten minutes: long enough for a short burst limit to clear, short enough
    // that nobody feels punished. Cleared early if a read later succeeds.
    _slowDownUntil[host] = DateTime.now().add(const Duration(minutes: 10));
    DiagnosticsLog.instance.add(
      'read',
      'rate limited — pausing reads for $host for 10 min',
      url: raw,
    );
  }

  void _cancelProbe({bool byUser = true}) {
    // A cancelled read is a finished read as far as the report is concerned;
    // leaving the marker set would make the next report claim something is
    // still running when nothing is.
    DiagnosticsLog.instance.readFinished();
    DiagnosticsLog.instance.note(
      'tap',
      byUser ? 'cancel pressed' : 'read superseded by a newer link',
    );
    _cancelledByUser = byUser;
    DownloaderEngineService.instance.cancel('innocent-probe');
    _probeTimer?.cancel();
    _probeTimer = null;
    if (mounted) setState(() => _probing = false);
  }

  // ------------------------------------------------------------ recovery

  Future<void> _updateEngine({bool thenRetry = false}) async {
    if (_updatingEngine) return;
    final AppStrings s = AppStrings.of(context);
    setState(() => _updatingEngine = true);
    final EngineUpdateResult result =
        await DownloaderEngineService.instance.updateEngine();
    if (!mounted) return;
    setState(() => _updatingEngine = false);
    ref.read(engineStatusProvider.notifier).refresh();

    await _showUpdateResult(context, s, result);
    if (!result.ok) return;
    if (!mounted) return;
    if (thenRetry && _failedUrl != null) {
      // A newer extractor is exactly what the failed link needed, so don't
      // make the user paste it again — but drop it from the handled set first
      // or the retry would be treated as a repeat.
      final String retry = _failedUrl!;
      _handledLinks.remove(retry);
      await _handleLink(retry);
    }
  }

  Future<void> _pickCookies({bool thenRetry = false}) async {
    final AppStrings s = AppStrings.of(context);
    final CookiesPathNotifier cookies = ref.read(cookiesPathProvider.notifier);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final FilePickerResult? picked = await FilePicker.platform.pickFiles();
      final String? path = picked?.files.single.path;
      if (path == null) return;
      await cookies.set(path);
      if (!mounted) return;
      if (thenRetry && _failedUrl != null) {
        final String retry = _failedUrl!;
        _handledLinks.remove(retry);
        await _handleLink(retry);
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(s.downloaderDirFailed)));
    }
  }

  // -------------------------------------------------------------- sites

  /// Picks up whatever the in-app browser has saved so far.
  ///
  /// Deliberately forgiving: no directory, no icons, no problem — every tile
  /// falls back to its monogram, which is what the grid looked like before and
  /// is perfectly good.
  Future<void> _loadSiteIcons() async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      // filesDir on Android, which is where the browser writes them.
      final Directory dir =
          Directory('${support.parent.path}/files/site_icons');
      if (!dir.existsSync()) return;
      final Map<String, String> found = <String, String>{};
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File || !e.path.endsWith('.png')) continue;
        final String host =
            e.path.split('/').last.replaceAll('.png', '').toLowerCase();
        if (host.isNotEmpty) found[host] = e.path;
      }
      if (mounted && found.isNotEmpty) setState(() => _siteIcons = found);
    } catch (_) {
      // Monograms it is.
    }
  }

  /// The cached icon for a site, if this person has ever opened it.
  String? _iconFor(DownloadSite site) {
    if (_siteIcons.isEmpty) return null;
    final String? host = Uri.tryParse(site.url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    return _siteIcons[host];
  }

  /// Long-press a tile to give a site a real icon — an image YOU choose,
  /// copied into the app's own folder. Nothing is bundled (the app stays
  /// small) and nothing is fetched (which sites you open is never sent
  /// anywhere) — which is the whole reason tiles are monograms by default.
  Future<void> _siteIconMenu(DownloadSite site) async {
    final AppStrings s = AppStrings.of(context);
    final bool hasIcon = _iconFor(site) != null;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.specSheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.white20,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  site.name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined,
                  color: AppColors.primaryBlue),
              title: Text(s.downloaderSetIcon,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(ctx).pop('set'),
            ),
            if (hasIcon)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: AppColors.white60),
                title: Text(s.downloaderRemoveIcon,
                    style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(ctx).pop('remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'set') {
      await _setSiteIcon(site);
    } else if (action == 'remove') {
      await _removeSiteIcon(site);
    }
  }

  /// Copies a chosen image into `site_icons/<host>.png`. The bytes are copied
  /// as-is: Flutter decodes an image by its content, not its extension, so a
  /// JPEG or WebP saved under the `.png` name the loader looks for still
  /// renders. Cover-cropped to the square tile by the tile itself.
  Future<void> _setSiteIcon(DownloadSite site) async {
    final AppStrings s = AppStrings.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? host = Uri.tryParse(site.url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return;
    try {
      final FilePickerResult? picked =
          await FilePicker.platform.pickFiles(type: FileType.image);
      final String? src = picked?.files.single.path;
      if (src == null) return;
      final Directory support = await getApplicationSupportDirectory();
      final Directory dir =
          Directory('${support.parent.path}/files/site_icons');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File dest = File('${dir.path}/$host.png');
      await File(src).copy(dest.path);
      // Flutter caches decoded images by (path, scale); drop the old entry so
      // a replaced icon shows the new image, not the one already in memory.
      await FileImage(dest).evict();
      await _loadSiteIcons();
      if (mounted) setState(() {});
    } catch (_) {
      messenger
          .showSnackBar(SnackBar(content: Text(s.downloaderIconFailed)));
    }
  }

  /// Deletes a site's custom icon so its tile falls back to the monogram.
  Future<void> _removeSiteIcon(DownloadSite site) async {
    final String? host = Uri.tryParse(site.url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return;
    try {
      final Directory support = await getApplicationSupportDirectory();
      final File f =
          File('${support.parent.path}/files/site_icons/$host.png');
      if (f.existsSync()) f.deleteSync();
      await FileImage(f).evict();
    } catch (_) {
      // Already gone — either way the tile returns to its monogram.
    }
    // _loadSiteIcons only ADDS files it finds and skips setState when none are
    // left, so a removal is applied to the in-memory map here directly.
    if (mounted) {
      final Map<String, String> next = Map<String, String>.from(_siteIcons)
        ..remove(host);
      setState(() => _siteIcons = next);
    }
  }

  Future<void> _openSite(DownloadSite site) async {
    DiagnosticsLog.instance.note('tap', 'site tile: ${site.name}');
    final AppStrings s = AppStrings.of(context);
    // INSIDE THE APP, NOT OUT TO CHROME.
    //
    // Handing someone to another browser is where this app used to stop being
    // useful: they find a video somewhere else, then have to remember to copy
    // the address, come back, and paste it. Every one of those steps is a
    // place to give up, and none of them exist in the downloaders this one is
    // measured against.
    //
    // It also buys something the reader cannot get for itself — a real
    // browsing session. Sites like PornHub answer a plain request with 403
    // because they inspect how the connection is made, not what it asks for;
    // the engine's answer to that is a library Android does not have. A page
    // opened here passes that check by being an actual browser, and the
    // cookies it collects are handed on.
    // ASK BEFORE THE BROWSER, NOT AFTER THE DOWNLOAD.
    //
    // The storage prompt lives in the quality sheet, and the browser flow
    // never touches the quality sheet — it picks natively and enqueues
    // straight through. So the one path most likely to need the permission
    // was the one path that never asked, which is exactly what the device
    // reported: no dialog, and a download that quietly went somewhere else.
    // Here is the last Flutter moment before the browser takes over.
    await ensureStorageAccess(context, ref);
    if (!mounted) return;
    final bool ok = await DownloaderEngineService.instance.browse(
      site.url,
      title: site.name,
      labelDownload: s.downloaderBrowseDownload,
      labelHint: s.downloaderBrowseHint,
      labelWorking: s.downloaderBrowseWorking,
      labelPick: s.downloaderBrowsePick,
      labelStarted: s.downloaderBrowseStarted,
      labelNoSound: s.downloaderNoSound,
      labelStreams: s.downloaderBrowseStreams,
      labelUnreadable: s.downloaderBrowseUnreadable,
      labelRetry: s.downloaderBrowseRetry,
      labelSendScreen: s.downloaderBrowseSendScreen,
      clients: ref.read(playerClientsProvider),
      labelBlocked: s.downloaderBrowseBlocked,
      labelVpnHint: s.downloaderBrowseVpnHint,
      labelDnsHint: s.downloaderBrowseDnsHint,
      labelOpenSettings: s.downloaderOpenSettings,
      labelMore: s.downloaderBrowseMore,
      labelDnsFound: s.downloaderNetworkDnsBlocked,
      labelDeeper: s.downloaderNetworkDeeper,
      labelBypass: s.downloaderBypassOpen,
      labelBypassHint: s.downloaderBypassHint,
      labelVpnGone: s.downloaderVpnNotNeeded,
      labelYtWall: s.downloaderYtWall,
      labelYtEmbed: s.downloaderYtEmbed,
      labelYtSignIn: s.downloaderYtSignInNow,
    );
    if (!mounted) return;
    // RECORDED EITHER WAY. The device trail showed this tile being tapped four
    // times in fifteen seconds with nothing happening after it, and there was
    // no way to tell whether the browser refused to open or opened and came
    // straight back — because the only thing written down was the tap.
    DiagnosticsLog.instance.note(
      'tap',
      ok ? 'in-app browser opened' : 'in-app browser refused to open',
      url: site.url,
    );
    // Falling back to an external browser is better than a dead tile on a
    // phone whose WebView is missing or disabled.
    if (!ok) {
      final bool out =
          await DownloaderEngineService.instance.openExternal(site.url);
      if (!mounted) return;
      _toast(out ? s.downloaderSiteHint : s.downloaderNoBrowser);
    }
  }

  Future<void> _openSettings() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.specSheetBg,
        isScrollControlled: true,
        useSafeArea: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (BuildContext ctx) => const _SettingsSheet(),
      );

  Future<void> _pickFavourites() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.specSheetBg,
        isScrollControlled: true,
        useSafeArea: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (BuildContext ctx) => const _FavouritePickerSheet(),
      );

  /// Reopens the page a download came from, inside Innocent's own browser.
  ///
  /// The one thing a person wants from a history row and the one thing it could
  /// not do. Note that the address is the PAGE, not the media: a stream URL
  /// from a delivery host is signed and expires, so reopening that would show
  /// an error a few hours later, while the page it came from keeps working and
  /// is where they actually wanted to be.
  ///
  /// Storage is asked for first, for the same reason the site tiles ask: the
  /// browser enqueues downloads natively without ever passing through the
  /// quality sheet, so this is the last Flutter moment before it can happen.
  Future<void> _openSource(AppStrings s, String? url) async {
    final String target = (url ?? '').trim();
    if (target.isEmpty) {
      _toast(s.downloaderNoSourcePage);
      return;
    }
    await ensureStorageAccess(context, ref);
    if (!mounted) return;
    DiagnosticsLog.instance.note('tap', 'view source page', url: target);
    final bool ok = await DownloaderEngineService.instance.browse(
      target,
      labelDownload: s.downloaderBrowseDownload,
      labelHint: s.downloaderBrowseHint,
      labelWorking: s.downloaderBrowseWorking,
      labelPick: s.downloaderBrowsePick,
      labelStarted: s.downloaderBrowseStarted,
      labelNoSound: s.downloaderNoSound,
      labelStreams: s.downloaderBrowseStreams,
      labelUnreadable: s.downloaderBrowseUnreadable,
      labelRetry: s.downloaderBrowseRetry,
      labelSendScreen: s.downloaderBrowseSendScreen,
      clients: ref.read(playerClientsProvider),
      labelBlocked: s.downloaderBrowseBlocked,
      labelVpnHint: s.downloaderBrowseVpnHint,
      labelDnsHint: s.downloaderBrowseDnsHint,
      labelOpenSettings: s.downloaderOpenSettings,
      labelMore: s.downloaderBrowseMore,
      labelDnsFound: s.downloaderNetworkDnsBlocked,
      labelDeeper: s.downloaderNetworkDeeper,
      labelBypass: s.downloaderBypassOpen,
      labelBypassHint: s.downloaderBypassHint,
      labelVpnGone: s.downloaderVpnNotNeeded,
      labelYtWall: s.downloaderYtWall,
      labelYtEmbed: s.downloaderYtEmbed,
      labelYtSignIn: s.downloaderYtSignInNow,
    );
    if (!mounted) return;
    // RECORDED EITHER WAY, like the tiles: a browser that refused to open and
    // one that opened and came straight back look identical from the outside.
    if (!ok) {
      DiagnosticsLog.instance.add('browser', 'browser refused to open');
      _toast(s.downloaderMissing);
    }
  }

  /// Puts an address on the clipboard, so it can be sent somewhere else.
  Future<void> _copyLink(AppStrings s, String? url) async {
    final String target = (url ?? '').trim();
    if (target.isEmpty) {
      _toast(s.downloaderNoSourcePage);
      return;
    }
    await Clipboard.setData(ClipboardData(text: target));
    if (!mounted) return;
    _toast(s.urlCopied);
  }

  /// Opens the system network settings, where Private DNS lives.
  ///
  /// Two fallbacks deep on purpose: the private-DNS screen has moved between
  /// Android versions and manufacturers, and landing somebody one tap away is
  /// far better than landing them on a crash.
  Future<void> _openPrivateDns() async {
    for (final String action in const <String>[
      'android.settings.WIRELESS_SETTINGS',
      'android.settings.SETTINGS',
    ]) {
      final bool ok =
          await DownloaderEngineService.instance.openSettings(action);
      if (ok) return;
    }
    if (mounted) _toast(AppStrings.of(context).downloaderMissing);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final AppStrings s = AppStrings.of(context);
    final List<String> favouriteIds = ref.watch(favouriteSitesProvider);
    final bool showRestricted = ref.watch(showRestrictedProvider);
    final List<DownloadTask> tasks = ref.watch(downloadQueueProvider);
    final List<DownloadTask> paused =
        tasks.where((DownloadTask t) => t.canResume).toList();
    // Only nag about an interruption when nothing is moving — a paused row
    // sitting next to an active download is the user's own doing.
    final bool interrupted =
        paused.isNotEmpty && !tasks.any((DownloadTask t) => t.isRunning);
    // Shown on the Downloads tab so the count is visible from the Browse tab
    // too — someone picking their next site can still see the last one landing.
    final int activeCount =
        tasks.where((DownloadTask t) => t.isRunning).length;

    final List<DownloadSite> favourites = favouriteIds
        .map(SiteCatalog.byId)
        .whereType<DownloadSite>()
        .toList();
    final Set<String> favouriteSet = favouriteIds.toSet();
    final List<DownloadSite> recommended = SiteCatalog.general
        .where((DownloadSite site) => !favouriteSet.contains(site.id))
        .toList();
    final List<DownloadSite> restricted = SiteCatalog.restricted
        .where((DownloadSite site) => !favouriteSet.contains(site.id))
        .toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        // The bar's background is hardcoded dark, so its foreground must be
        // too. Left to the theme, `AppTheme.light` — which declares no
        // `appBarTheme` — resolves the title and both icons to #212121 on
        // this #0F0F0F bar: a contrast ratio of 1.19:1, effectively
        // invisible for anyone on Light or Adaptive.
        //
        // BOTH lines are needed. `foregroundColor` alone fixes the icons but
        // not the title, because `AppTheme.dark.appBarTheme.titleTextStyle`
        // carries its own colour (#E0E0E0) and outranks it — which would
        // leave dark-mode users with white icons above a grey title.
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Text(
          s.downloaderTitle,
          style: const TextStyle(
              color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: s.downloaderSettings,
            icon: const Icon(Icons.tune_rounded, size: 22),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: <Widget>[
          _pasteBar(s),
          _caption(s),
          if (_clipboardLink != null) _clipboardChip(s, _clipboardLink!),
          if (_probing) _probingCard(s),
          if (_failure != null && !_probing) _failureCard(s, _failure!),
          const SizedBox(height: 10),
          // ONE SCREEN WAS DOING THREE JOBS. The queue you are watching, the
          // history you are keeping, and eighteen hundred sites to browse were
          // stacked in a single scroll, so the thing you came for sat in the
          // middle of the thing you were only glancing at. Two tabs give the
          // work its own surface and the browsing its own; the paste bar, which
          // feeds both, stays above them.
          TabBar(
            indicatorColor: AppColors.primaryBlue,
            indicatorWeight: 2.5,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: Colors.white,
            unselectedLabelColor: AppColors.white40,
            dividerColor: Colors.transparent,
            labelStyle:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            unselectedLabelStyle:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
            tabs: <Widget>[
              Tab(
                height: 44,
                text: activeCount > 0
                    ? '${s.downloaderActive}  ($activeCount)'
                    : s.downloaderActive,
              ),
              Tab(height: 44, text: s.downloaderTabBrowse),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _downloadsTab(s, tasks, paused, interrupted),
                _browseTab(
                    s, favourites, recommended, restricted, showRestricted),
              ],
            ),
          ),
        ],
      ),
    ));
  }

  /// The working surface: what is downloading now and what has finished.
  ///
  /// When there is nothing on either, a calm empty state points at the two
  /// ways to start — rather than a blank tab, which reads as broken.
  Widget _downloadsTab(
    AppStrings s,
    List<DownloadTask> tasks,
    List<DownloadTask> paused,
    bool interrupted,
  ) {
    final bool hasHistory = ref.watch(downloadHistoryProvider).isNotEmpty;
    if (tasks.isEmpty && !hasHistory) {
      return _emptyDownloads(s);
    }
    return ListView(
      padding: const EdgeInsets.only(top: 2, bottom: 32),
      children: <Widget>[
        const _RemoteNotice(),
        const _EngineBanner(),
        if (tasks.isNotEmpty) ...<Widget>[
          _sectionHeader(
            s.downloaderActive,
            // Resume-all takes priority over Clear: a queue that came back
            // paused after the app was killed is the situation that most needs
            // one tap, and offering both at once is clutter.
            actionLabel: paused.isNotEmpty
                ? s.downloaderResumeAll
                : (tasks.any((DownloadTask t) => !t.isRunning && !t.isPaused)
                    ? s.downloaderClear
                    : null),
            onAction: () {
              final DownloadQueueNotifier queue =
                  ref.read(downloadQueueProvider.notifier);
              if (paused.isNotEmpty) {
                for (final DownloadTask t in paused) {
                  queue.resume(t.id);
                }
              } else {
                queue.clearFinished();
              }
            },
          ),
          if (interrupted)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                s.downloaderInterrupted,
                style: const TextStyle(
                    color: AppColors.white40, fontSize: 11, height: 1.35),
              ),
            ),
          ...tasks.map((DownloadTask t) => _taskRow(s, t)),
        ],
        _savedSection(s),
      ],
    );
  }

  /// The discovery surface: the person's own favourites, then a broader set of
  /// sites, then the restricted set when it is switched on. Kept OFF the
  /// downloads tab so browsing never competes with the queue.
  Widget _browseTab(
    AppStrings s,
    List<DownloadSite> favourites,
    List<DownloadSite> recommended,
    List<DownloadSite> restricted,
    bool showRestricted,
  ) {
    return ListView(
      padding: const EdgeInsets.only(top: 2, bottom: 32),
      children: <Widget>[
        _sectionHeader(
          s.downloaderFavourite,
          actionLabel: s.downloaderEdit,
          onAction: _pickFavourites,
        ),
        _panel(favourites.isEmpty
            ? _emptyFavourites(s)
            : _grid(favourites.map(_tile).toList())),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Text(
            s.downloaderIconHint,
            style: const TextStyle(
                color: AppColors.white40, fontSize: 11, height: 1.4),
          ),
        ),
        // THE GRID IS DISCOVERY, NOT CAPABILITY.
        //
        // Any link the engine understands already works when pasted, which is
        // roughly eighteen hundred sites — but a screen showing a dozen tiles
        // teaches the opposite, and someone with a link from a site that is not
        // pictured will reasonably assume it is not supported and stop. One
        // sentence is the difference between a downloader people think handles
        // twelve sites and one they know handles almost anything.
        if (recommended.isNotEmpty) ...<Widget>[
          _sectionHeader(s.downloaderRecommended),
          _panel(_grid(recommended.map(_tile).toList())),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              s.downloaderAnySiteHint,
              style: const TextStyle(
                  color: AppColors.white50, fontSize: 11.5, height: 1.4),
            ),
          ),
        ],
        if (showRestricted && restricted.isNotEmpty) ...<Widget>[
          _sectionHeader(s.downloaderRestricted),
          _panel(_grid(restricted.map(_tile).toList())),
        ],
      ],
    );
  }

  /// Shown on the Downloads tab when there is nothing to show yet.
  Widget _emptyDownloads(AppStrings s) => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 76,
                height: 76,
                decoration: const BoxDecoration(
                  color: AppColors.white05,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.download_rounded,
                    size: 34, color: AppColors.white30),
              ),
              const SizedBox(height: 18),
              Text(
                s.downloaderEmptyDownloads,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                s.downloaderEmptyDownloadsHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.white40, fontSize: 12.5, height: 1.45),
              ),
            ],
          ),
        ),
      );

  // ----------------------------------------------------------- fragments

  Widget _pasteBar(AppStrings s) {
    final bool hasText = _linkController.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 50,
        decoration: BoxDecoration(
          color: AppColors.specInnerPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _linkFocus.hasFocus
                ? AppColors.primaryBlue.withValues(alpha: 0.6)
                : AppColors.white08,
            width: 1,
          ),
        ),
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: <Widget>[
            const Icon(Icons.link_rounded, size: 19, color: AppColors.white40),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _linkController,
                focusNode: _linkFocus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 1,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: s.downloaderPasteHint,
                  hintStyle:
                      const TextStyle(color: AppColors.white40, fontSize: 13.5),
                ),
                onSubmitted: _handleLink,
              ),
            ),
            if (hasText)
              IconButton(
                tooltip: s.downloaderClearBar,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded,
                    size: 17, color: AppColors.white40),
                onPressed: () {
                  _linkController.clear();
                  setState(() {});
                },
              ),
            hasText
                ? IconButton(
                    tooltip: s.downloaderDownload,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_forward_rounded,
                        size: 19, color: AppColors.primaryBlue),
                    onPressed: () {
                      DiagnosticsLog.instance.note('tap', 'paste bar submitted');
                      _handleLink(_linkController.text);
                    },
                  )
                : IconButton(
                    tooltip: s.downloaderPaste,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.content_paste_rounded,
                        size: 18, color: AppColors.primaryBlue),
                    onPressed: () async {
                      final ClipboardData? data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (!mounted) return;
                      final String text = data?.text?.trim() ?? '';
                      if (text.isEmpty) return;
                      _linkController.text = text;
                      await _handleLink(text);
                    },
                  ),
          ],
        ),
      ),
    );
  }

  Widget _caption(AppStrings s) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
        child: Row(
          children: <Widget>[
            const Icon(Icons.public_rounded, size: 12, color: AppColors.white30),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                s.downloaderSupportedSites,
                style: const TextStyle(color: AppColors.white30, fontSize: 11),
              ),
            ),
          ],
        ),
      );

  Widget _clipboardChip(AppStrings s, String url) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Material(
          color: AppColors.primaryBlue.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _handleLink(url),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.content_paste_go_rounded,
                      size: 17, color: AppColors.primaryBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          s.downloaderClipboardFound,
                          style: const TextStyle(
                            color: AppColors.primaryBlue,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.white50, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: s.downloaderDismiss,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded,
                        size: 16, color: AppColors.white40),
                    onPressed: () => setState(() {
                      _handledLinks.add(url);
                      _clipboardLink = null;
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// Inline, not a modal dialog.
  ///
  /// The first build blocked the whole screen behind an alert, which turns a
  /// slow network into a frozen app. The elapsed counter matters too: a
  /// progress spinner with no number reads as "stuck" after about five
  /// seconds, and the very first read of a link is genuinely slow because the
  /// engine is still unpacking itself.
  Widget _probingCard(AppStrings s) {
    final EngineStatus status = ref.watch(engineStatusProvider);
    final EnginePhase enginePhase = EngineReadiness.instance.phase.value;
    final bool firstRun = !status.ok;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: AppColors.specInnerPanel,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    // Naming what is actually happening. A spinner that says
                    // "reading link" while the engine is being replaced is not
                    // wrong so much as unhelpful — the wait has a reason and
                    // the reason is worth a word.
                    enginePhase == EnginePhase.updating
                        ? s.downloaderUpdating
                        : (firstRun || enginePhase == EnginePhase.preparing)
                            ? s.downloaderEnginePreparing
                            : s.downloaderFetching,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  if (_probeSeconds > 2) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      '${_probeSeconds}s',
                      style: const TextStyle(
                          color: AppColors.white40, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            TextButton(
              onPressed: _cancelProbe,
              child: Text(s.cancel),
            ),
          ],
        ),
      ),
    );
  }

  /// One sentence and the buttons that actually fix it.
  Widget _failureCard(AppStrings s, ProbeFailure failure) {
    final String headline = failureHeadline(s, failure.kind);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.error_outline_rounded,
                    size: 17, color: AppColors.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    headline,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, height: 1.35),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() {
                    _failure = null;
                    _showFailureDetail = false;
                  }),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 16, color: AppColors.white40),
                  ),
                ),
              ],
            ),
            // THE ADVICE COMES FIRST, AND WITHOUT BEING ASKED FOR.
            //
            // For every other failure the raw detail is for whoever is
            // debugging, and it stays folded away. A rate limit is different:
            // the person can actually do something about it, and what they
            // would do untold — press the button again — is the one action
            // that keeps it going. So this one explains itself up front, in
            // their language, and says what to try instead.
            // Same reasoning as the rate limit below: these two are the only
            // failures a person can actually act on, so they explain
            // themselves up front instead of hiding behind a details toggle.
            //
            // The device trail settled what this one is. On a VPN, YouTube
            // answers "Sign in to confirm you're not a bot" while TikTok is
            // perfectly happy — so it is not the connection and not this app.
            // It is YouTube distrusting an address shared by very many people,
            // which is exactly what a VPN exit is. Nothing here can talk it
            // round; saying so plainly, and pointing at the two things that DO
            // work, is worth more than another silent retry.
            if (failure.kind == ProbeFailureKind.botWall) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                s.downloaderBotWallHint,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 12, height: 1.45),
              ),
            ],
            if (failure.kind == ProbeFailureKind.rateLimited) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                s.downloaderRateLimitHint,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 12, height: 1.45),
              ),
            ],
            if (_showFailureDetail) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                failure.shortRaw,
                style: const TextStyle(
                    color: AppColors.white50, fontSize: 11, height: 1.4),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: <Widget>[
                if (failure.updateMayHelp)
                  TextButton.icon(
                    onPressed: _updatingEngine
                        ? null
                        : () => _updateEngine(thenRetry: true),
                    icon: _updatingEngine
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.system_update_alt_rounded, size: 15),
                    label: Text(_updatingEngine
                        ? s.downloaderUpdating
                        : s.downloaderUpdateEngine),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryBlue),
                  ),
                if (failure.cookiesMayHelp &&
                    _failedUrl != null &&
                    SignInTargets.guestForUrl(_failedUrl!) != null)
                  TextButton.icon(
                    onPressed: () => _fixAutomatically(_failedUrl!),
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                    label: Text(s.downloaderFixAuto),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryBlue),
                  ),
                // THE NETWORK LINE COMES FIRST, above the buttons, because on
                // this connection it is the likeliest cause and the one nobody
                // would think to check. Shown ONLY when the phone has actually
                // seen this site work on the other network — see
                // site_network_memory.dart on why a guess would be worse.
                if (_networkHint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Icon(Icons.vpn_key_outlined,
                            size: 14, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _networkHint == 'direct'
                                ? s.downloaderNetworkVpnOff
                                : s.downloaderNetworkVpnOn,
                            style: const TextStyle(
                                color: AppColors.warning, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                // A MEASUREMENT, NOT A SUGGESTION. Offered on any failure
                // that could be the network, because on this connection it
                // usually is — and because the answer decides between two
                // opposite remedies that cost real time to try blindly.
                if (_netCheck == null &&
                    (failure.kind == ProbeFailureKind.network ||
                        failure.kind == ProbeFailureKind.botWall))
                  TextButton.icon(
                    onPressed: _netChecking
                        ? null
                        : () => _runNetworkCheck(_failedUrl),
                    icon: const Icon(Icons.wifi_find_outlined, size: 15),
                    label: Text(_netChecking
                        ? s.downloaderNetworkChecking
                        : s.downloaderCheckNetwork),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryBlue),
                  ),
                if (_netCheck != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _netCheck!.inconclusive
                              ? s.downloaderNetworkUnknown
                              : _netCheck!.dnsBlockFound
                                  ? s.downloaderNetworkDnsBlocked
                                  : s.downloaderNetworkDeeper,
                          style: TextStyle(
                            color: _netCheck!.dnsBlockFound
                                ? AppColors.warning
                                : AppColors.white70,
                            fontSize: 12,
                          ),
                        ),
                        // Only where it is both true and useful. A phone that
                        // already has encrypted DNS on and is still blocked has
                        // nothing to gain from being told to turn it on.
                        if (_netCheck!.dnsBlockFound &&
                            _netCheck!.privateDns != 'on')
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              s.downloaderNetworkNoVpnNeeded,
                              style: const TextStyle(
                                  color: AppColors.white70, fontSize: 12),
                            ),
                          ),
                        if (_netCheck!.privateDns == 'on')
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              s.downloaderNetworkPrivateOn,
                              style: const TextStyle(
                                  color: AppColors.white40, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_netCheck != null &&
                    _netCheck!.dnsBlockFound &&
                    _netCheck!.privateDns != 'on')
                  TextButton.icon(
                    onPressed: _openPrivateDns,
                    icon: const Icon(Icons.dns_outlined, size: 15),
                    label: Text(s.downloaderOpenSettings),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryBlue),
                  ),
                if (failure.cookiesMayHelp && _failedUrl != null)
                  TextButton.icon(
                    // A sign-in inside the app, not a file to go and find:
                    // exporting cookies.txt from a desktop browser is not
                    // something a phone user is going to do, and that gap was
                    // the whole reason the account route went unused.
                    onPressed: () => _signIn(_failedUrl!),
                    icon: const Icon(Icons.account_circle_outlined, size: 15),
                    label: Text(s.downloaderSignIn),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryBlue),
                  ),
                if (failure.kind == ProbeFailureKind.network &&
                    _failedUrl != null)
                  TextButton.icon(
                    onPressed: () {
                      final String retry = _failedUrl!;
                      _handledLinks.remove(retry);
                      _handleLink(retry);
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 15),
                    label: Text(s.retry),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.primaryBlue),
                  ),
                TextButton(
                  onPressed: () => setState(
                      () => _showFailureDetail = !_showFailureDetail),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.white50),
                  child: Text(s.downloaderDetails),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(
    String text, {
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      Padding(
        padding: EdgeInsets.fromLTRB(18, 20, actionLabel == null ? 18 : 8, 8),
        child: Row(
          children: <Widget>[
            Text(
              text,
              style: const TextStyle(
                color: AppColors.white50,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
            const Spacer(),
            if (actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryBlue,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(actionLabel,
                    style: const TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
      );

  /// Groups a grid on its own surface so the tiles read as a set instead of
  /// floating loose on the background.
  Widget _panel(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.white05,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: child,
        ),
      );

  /// Sized close to its content: a 52dp tile, a 7dp gap and one label line
  /// (~71dp), leaving about 10dp of breathing room top and bottom.
  ///
  /// The first build used 0.82, which on a 360dp-wide phone produced cells over
  /// 100dp tall around that same ~71dp of content — the dead space was most of
  /// why the screen looked unfinished. 0.88 rather than a tighter value on
  /// purpose: on a 320dp phone with the system font scaled up, a tighter ratio
  /// leaves the label with less height than it needs and Flutter paints the
  /// overflow stripe. The Flexible below is the second half of that guard.
  /// Everything this app has actually put on the phone.
  ///
  /// A finished download used to exist only as a row in a list that Clear
  /// wiped, so the one question people ask afterwards — "where did that go" —
  /// had no answer inside the app. Now it does, it survives restarts, and each
  /// entry can be played, shared or deleted without going hunting through a
  /// file manager.
  Widget _savedSection(AppStrings s) {
    final List<DownloadRecord> records = ref.watch(downloadHistoryProvider);
    if (records.isEmpty) return const SizedBox.shrink();
    final List<DownloadRecord> shown =
        records.length > 6 ? records.sublist(0, 6) : records;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionHeader(
          '${s.downloaderSavedFiles}  (${records.length})',
          actionLabel: s.downloaderClearList,
          onAction: () => ref.read(downloadHistoryProvider.notifier).clear(),
        ),
        _panel(Column(
          children: <Widget>[
            for (final DownloadRecord r in shown) _savedRow(s, r),
            // A CAP THAT ADMITS IT IS A CAP. Six rows with nothing after them
            // reads as "that is everything", so the other hundred and ninety
            // four might as well not have been kept.
            if (records.length > shown.length)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _showAllHistory(s),
                  child: Text(
                    '${s.downloaderSeeAll}  (${records.length})',
                    style: const TextStyle(
                        color: AppColors.primaryBlue, fontSize: 12.5),
                  ),
                ),
              ),
          ],
        )),
      ],
    );
  }

  /// Every saved file, with the same row and the same options.
  ///
  /// Built from the SAME `_savedRow` the panel uses rather than a second list
  /// widget: two lists of the same thing drift, and the one nobody scrolls is
  /// the one that keeps the old options. Watched through a Consumer so
  /// deleting inside the sheet updates the sheet.
  Future<void> _showAllHistory(AppStrings s) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.specSheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext ctx) => SafeArea(
        child: Consumer(
          builder: (BuildContext _, WidgetRef inner, Widget? __) {
            final List<DownloadRecord> all =
                inner.watch(downloadHistoryProvider);
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                    child: Text(
                      '${s.downloaderHistoryTitle}  (${all.length})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (all.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                      child: Text(
                        s.downloaderHistoryEmpty,
                        style: const TextStyle(
                            color: AppColors.white40, fontSize: 12.5),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: all.length,
                        itemBuilder: (BuildContext _, int i) =>
                            _savedRow(s, all[i]),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _savedRow(AppStrings s, DownloadRecord r) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.insert_drive_file_outlined,
          size: 20, color: AppColors.white40),
      title: Text(
        r.title.isEmpty ? r.fileName : r.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
      // WHERE IT CAME FROM, HOW BIG IT IS, AND WHEN. The row used to say the
      // host or, failing that, the file name -- which is the one fact already
      // on the line above it. These three are what somebody scanning a list of
      // fifty files actually sorts by.
      subtitle: Text(
        <String>[
          if ((r.host ?? '').isNotEmpty) r.host!,
          if ((r.sizeBytes ?? 0) > 0) formatBytes(r.sizeBytes),
          _shortDate(r.at),
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.white40, fontSize: 11),
      ),
      onTap: () => _playSaved(s, r),
      trailing: PopupMenuButton<String>(
        tooltip: s.downloaderMoreOptions,
        icon: const Icon(Icons.more_vert, size: 18, color: AppColors.white40),
        color: AppColors.specSheetBg,
        onSelected: (String action) => _savedAction(s, r, action),
        itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'play',
            child: Text(s.downloaderPlay,
                style: const TextStyle(color: Colors.white)),
          ),
          // THE ONE THE LIST EXISTED FOR. A finished file answers "what did I
          // download"; only this answers "where was I", which is the question
          // people come back with.
          PopupMenuItem<String>(
            value: 'view',
            child: Text(s.downloaderViewPage,
                style: const TextStyle(color: Colors.white)),
          ),
          PopupMenuItem<String>(
            value: 'again',
            child: Text(s.downloaderDownloadAgain,
                style: const TextStyle(color: Colors.white)),
          ),
          PopupMenuItem<String>(
            value: 'copy',
            child: Text(s.downloaderCopyLink,
                style: const TextStyle(color: Colors.white)),
          ),
          PopupMenuItem<String>(
            value: 'share',
            child: Text(s.downloaderShare,
                style: const TextStyle(color: Colors.white)),
          ),
          // TWO DIFFERENT THINGS, NAMED DIFFERENTLY. Taking a row off the list
          // and erasing the film are not the same act, and offering only the
          // second one means somebody tidying a list destroys a file.
          PopupMenuItem<String>(
            value: 'forget',
            child: Text(s.downloaderRemoveFromList,
                style: const TextStyle(color: Colors.white)),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            child: Text(s.downloaderDeleteFile,
                style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  /// `14/06` this year, `14/06/25` otherwise. No new strings and no ambiguity.
  String _shortDate(DateTime at) {
    final String d = at.day.toString().padLeft(2, '0');
    final String m = at.month.toString().padLeft(2, '0');
    if (at.year == DateTime.now().year) return '$d/$m';
    return '$d/$m/${at.year % 100}';
  }

  Future<void> _savedAction(
      AppStrings s, DownloadRecord r, String action) async {
    switch (action) {
      case 'play':
        await _playSaved(s, r);
        break;
      case 'view':
        await _openSource(s, r.sourceUrl);
        break;
      case 'copy':
        await _copyLink(s, r.sourceUrl);
        break;
      case 'again':
        // Straight back through the reader, which means the quality sheet the
        // rest of the app uses -- so taking the same video at a different
        // resolution costs one tap rather than finding the page again.
        final String again = (r.sourceUrl ?? '').trim();
        if (again.isEmpty) {
          _toast(s.downloaderNoSourcePage);
          break;
        }
        await _handleLink(again);
        break;
      case 'share':
        // The same call the rest of the app already uses to share a file.
        try {
          await Share.shareXFiles(<XFile>[XFile(r.path)]);
        } catch (_) {
          if (mounted) _toast(s.downloaderMissing);
        }
        break;
      case 'forget':
        ref.read(downloadHistoryProvider.notifier).forget(r.id);
        break;
      case 'delete':
        await _deleteSaved(s, r);
        break;
    }
  }

  /// What the running-row menu does.
  ///
  /// Routed through the SAME notifier methods the icon buttons use rather
  /// than a second path to pausing: two ways to pause a download is two
  /// places for the queue to be left in a state only one of them knows how
  /// to leave.
  Future<void> _taskAction(
      AppStrings s, DownloadTask task, String action) async {
    final String? page = task.spec?.sourceUrl ?? task.spec?.url;
    switch (action) {
      case 'view':
        await _openSource(s, page);
        break;
      case 'copy':
        await _copyLink(s, page);
        break;
      case 'retry':
        ref.read(downloadQueueProvider.notifier).resume(task.id);
        break;
      case 'pause':
        ref.read(downloadQueueProvider.notifier).pause(task.id);
        break;
      case 'cancel':
        ref.read(downloadQueueProvider.notifier).cancel(task.id);
        break;
    }
  }

  Future<void> _playSaved(AppStrings s, DownloadRecord r) async {
    if (!await File(r.path).exists()) {
      if (!mounted) return;
      _toast(s.downloaderMissing);
      // Gone from disk — leaving it listed would be a lie, and the next tap
      // would fail exactly the same way.
      ref.read(downloadHistoryProvider.notifier).forget(r.id);
      return;
    }
    if (!mounted) return;
    context.push(
      Routes.player,
      extra: <String, String>{'uri': r.path, 'title': r.title},
    );
  }

  Future<void> _deleteSaved(AppStrings s, DownloadRecord r) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.specSheetBg,
        content: Text(s.downloaderDeleteConfirm,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.downloaderDeleteFile,
                style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (go != true) return;
    await DownloaderEngineService.instance.deleteFile(r.path);
    if (!mounted) return;
    ref.read(downloadHistoryProvider.notifier).forget(r.id);
    _toast(s.downloaderDeleted);
  }

  Widget _grid(List<Widget> children) => GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 0.88,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        padding: EdgeInsets.zero,
        children: children,
      );

  Widget _emptyFavourites(AppStrings s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        child: Center(
          child: Text(
            s.downloaderEdit,
            style: const TextStyle(color: AppColors.white40, fontSize: 12),
          ),
        ),
      );

  Widget _tile(DownloadSite site) => InkWell(
        onTap: () => _openSite(site),
        onLongPress: () => _siteIconMenu(site),
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                // Built the way a launcher icon is built: light source top-left
                // (so the gradient runs bright-to-dark down the diagonal), a
                // hairline rim to lift it off a black background, and a NEUTRAL
                // drop shadow.
                //
                // v0.99.1 used a coloured glow instead, which is what made the
                // grid read as neon rather than premium — a red halo around the
                // red tile is a look no shipped launcher uses, because real
                // light doesn't take the colour of the object casting it.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    Color.lerp(site.color, Colors.white, 0.18) ?? site.color,
                    Color.lerp(site.color, Colors.black, 0.30) ?? site.color,
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                  width: 0.6,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 9,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              alignment: Alignment.center,
              // The site's own icon once it has one, its letter until then.
              // ClipRRect matches the container's radius so a square favicon
              // does not sit proud of the rounded tile.
              child: _iconFor(site) != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(_iconFor(site)!),
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, __, ___) => Text(
                          site.initial,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    )
                  : Text(
                site.initial,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  height: 1,
                  shadows: <Shadow>[
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.white60,
                    fontSize: 11,
                    height: 1.1,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  /// A download row that says what a download row should say.
  ///
  /// v0.99.1 showed a bar and a bare percentage. Every downloader people
  /// compare this to shows how much of how big, how fast, and how long is
  /// left — without those three the bar is the only feedback there is, and a
  /// stalled transfer looks identical to a slow one.
  Widget _taskRow(AppStrings s, DownloadTask task) {
    final String status;
    final Color statusColor;
    switch (task.phase) {
      case DownloadPhase.queued:
        status = s.downloaderQueued;
        statusColor = AppColors.white50;
        break;
      case DownloadPhase.preparing:
        status = s.downloaderPreparing;
        statusColor = AppColors.white50;
        break;
      case DownloadPhase.progress:
        // AT 100% WITH NOTHING FLOWING, THE BYTES ARE DOWN AND IT IS WRAPPING
        // UP — merging audio and video, or embedding a thumbnail, which on a
        // big clip is several seconds where the bar would otherwise read a
        // frozen "100%". Say "Finalizing…" so it reads as work, matching what
        // the notification already shows.
        {
          final bool finalizing =
              task.progress >= 100 && (task.stats?.bytesPerSecond ?? 0) == 0;
          status = finalizing ? s.downloaderFinalizing : '${task.progress}%';
          statusColor = AppColors.primaryBlue;
        }
        break;
      case DownloadPhase.retrying:
        status = s.downloaderRetrying;
        statusColor = AppColors.warning;
        break;
      case DownloadPhase.paused:
        status = s.downloaderPaused;
        statusColor = AppColors.white50;
        break;
      case DownloadPhase.done:
        status = task.isPhotoSet ? s.downloaderPhotosSaved : s.downloaderSaved;
        statusColor = AppColors.success;
        break;
      case DownloadPhase.cancelled:
        status = s.downloaderCancelled;
        statusColor = AppColors.white50;
        break;
      case DownloadPhase.error:
        status = s.downloaderFailed;
        statusColor = AppColors.error;
        break;
    }

    final bool playable =
        task.phase == DownloadPhase.done && (task.path?.isNotEmpty ?? false);
    final DownloadProgress? stats = task.stats;

    // "12.4 MB of 45.6 MB · 2.3 MB/s · 32s left" — each part appears only once
    // it is actually known, so the line grows as the transfer settles instead
    // of showing placeholder dashes.
    final List<String> detail = <String>[];
    if (task.totalBytes != null && task.totalBytes! > 0) {
      detail.add(
        '${formatBytes(task.downloadedBytes)} ${s.downloaderOf} '
        '${formatBytes(task.totalBytes)}',
      );
    }
    if (task.isRunning && (stats?.bytesPerSecond ?? 0) > 0) {
      detail.add(formatSpeed(stats!.bytesPerSecond));
    }
    if (task.isRunning && (task.etaSeconds ?? 0) > 0) {
      detail.add('${formatEta(task.etaSeconds)} ${s.downloaderRemaining}');
    }
    if (stats?.fragmentCount != null && stats!.fragmentCount! > 1) {
      detail.add('${stats.fragmentIndex ?? 0}/${stats.fragmentCount}');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
        decoration: BoxDecoration(
          color: AppColors.specInnerPanel,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    task.title.isEmpty ? s.downloaderDownload : task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  if (task.isRunning || task.isPaused) ...<Widget>[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        // Indeterminate only while there is genuinely nothing
                        // to report; a paused bar must hold its position so the
                        // user can see how much is already banked.
                        value: (task.progress > 0 ||
                                task.isPaused ||
                                task.phase == DownloadPhase.retrying)
                            ? task.progress / 100
                            : null,
                        minHeight: 3,
                        backgroundColor: AppColors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          task.isPaused
                              ? AppColors.white40
                              : task.phase == DownloadPhase.retrying
                                  ? AppColors.warning
                                  : AppColors.primaryBlue,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Text(
                        status,
                        style: TextStyle(color: statusColor, fontSize: 11),
                      ),
                      if (detail.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            detail.join('  ·  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.white40, fontSize: 11),
                          ),
                        ),
                      ] else
                        const Spacer(),
                    ],
                  ),
                  if (task.phase == DownloadPhase.error &&
                      (task.error?.isNotEmpty ?? false)) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      // Same treatment the link-reading card gets: the reason
                      // in plain words, not nine lines of engine output.
                      failureHeadline(
                        s,
                        ProbeFailure.classify(task.error!).kind,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.white40, fontSize: 10.5, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (playable)
              IconButton(
                tooltip: s.downloaderPlay,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.play_circle_outline_rounded,
                    color: AppColors.primaryBlue),
                onPressed: () => context.push(
                  Routes.player,
                  extra: <String, String>{
                    'uri': task.path!,
                    'title': task.title,
                  },
                ),
              ),
            // No Pause for a photo set: it cannot be resumed, so the button
            // would only ever lead somewhere the user can't come back from.
            if (task.isRunning && !task.isPhotoSet)
              IconButton(
                tooltip: s.downloaderPause,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.pause_rounded,
                    size: 20, color: AppColors.white60),
                onPressed: () =>
                    ref.read(downloadQueueProvider.notifier).pause(task.id),
              )
            else if (task.canResume)
              IconButton(
                tooltip: s.downloaderResume,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.play_arrow_rounded,
                    size: 22, color: AppColors.primaryBlue),
                onPressed: () =>
                    ref.read(downloadQueueProvider.notifier).resume(task.id),
              ),
            IconButton(
              tooltip: (task.isRunning || task.isPaused)
                  ? s.cancel
                  : s.downloaderDismiss,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                (task.isRunning || task.isPaused)
                    ? Icons.close_rounded
                    : Icons.clear_all_rounded,
                size: 19,
                color: AppColors.white40,
              ),
              onPressed: () => (task.isRunning || task.isPaused)
                  ? ref.read(downloadQueueProvider.notifier).cancel(task.id)
                  : ref.read(downloadQueueProvider.notifier).dismiss(task.id),
            ),
            // THE SAME OPTIONS A FINISHED FILE GETS, WHILE IT IS STILL
            // RUNNING. A download in flight had exactly two buttons and no
            // way to answer the question people ask most about it -- what
            // page is this from, and did I pick the right video? Reopening
            // the page is how somebody checks without cancelling first, and
            // it costs nothing to offer: the address is already in the spec.
            PopupMenuButton<String>(
              tooltip: s.downloaderMoreOptions,
              icon: const Icon(Icons.more_vert,
                  size: 18, color: AppColors.white40),
              color: AppColors.specSheetBg,
              onSelected: (String action) => _taskAction(s, task, action),
              itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'view',
                  child: Text(s.downloaderViewPage,
                      style: const TextStyle(color: Colors.white)),
                ),
                PopupMenuItem<String>(
                  value: 'copy',
                  child: Text(s.downloaderCopyLink,
                      style: const TextStyle(color: Colors.white)),
                ),
                // Only where it can do something. A retry offered on a
                // healthy download is a button whose only use is to break
                // one, and on a photo set there is nothing to resume.
                if (task.canResume)
                  PopupMenuItem<String>(
                    value: 'retry',
                    child: Text(s.downloaderRetryDownload,
                        style: const TextStyle(color: Colors.white)),
                  ),
                if (task.isRunning && !task.isPhotoSet)
                  PopupMenuItem<String>(
                    value: 'pause',
                    child: Text(s.downloaderPause,
                        style: const TextStyle(color: Colors.white)),
                  ),
                if (task.isRunning || task.isPaused)
                  PopupMenuItem<String>(
                    value: 'cancel',
                    child: Text(s.cancel,
                        style: const TextStyle(color: AppColors.error)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The one place a failure kind becomes a sentence.
///
/// Shared by the link-reading card and the download rows: a download that dies
/// mid-flight fails for the same reasons a link fails to read, and showing the
/// engine's raw text in one place and a plain sentence in the other would be
/// two different apps.
String failureHeadline(AppStrings s, ProbeFailureKind kind) {
  switch (kind) {
    case ProbeFailureKind.botWall:
      return s.downloaderErrBot;
    case ProbeFailureKind.needsAccount:
      return s.downloaderErrAccount;
    case ProbeFailureKind.network:
      return s.downloaderErrNetwork;
    case ProbeFailureKind.extractorBroken:
      return s.downloaderErrExtractor;
    case ProbeFailureKind.unsupported:
      return s.downloaderErrUnsupported;
    case ProbeFailureKind.rateLimited:
      return s.downloaderErrRateLimited;
    case ProbeFailureKind.cancelled:
    case ProbeFailureKind.unknown:
      return s.downloaderErrUnknown;
  }
}

/// Shows what an engine update actually did.
///
/// Success is a one-line snackbar with the version before and after, which is
/// the only proof that anything moved. Failure gets a dialog instead, because
/// the useful part is the reason and which reflective step reached it — that
/// text has to stay on screen long enough to be read and screenshotted, and a
/// snackbar truncates it and then disappears.
Future<void> _showUpdateResult(
  BuildContext context,
  AppStrings s,
  EngineUpdateResult result,
) async {
  if (result.ok) {
    final String headline = result.changed
        ? s.downloaderUpdated
        : (result.alreadyCurrent ? s.downloaderUpToDate : s.downloaderUpdated);
    final String versions = result.changed
        ? '  ${result.before ?? '?'} → ${result.version ?? '?'}'
        : (result.version != null ? '  ${result.version}' : '');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$headline$versions')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      backgroundColor: AppColors.specSheetBg,
      title: Text(
        s.downloaderUpdateFailed,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              result.error ?? '',
              style: const TextStyle(
                  color: AppColors.white70, fontSize: 13, height: 1.4),
            ),
            if ((result.detail ?? '').isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                result.detail!,
                style: const TextStyle(
                    color: AppColors.white40, fontSize: 11, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(s.close),
        ),
      ],
    ),
  );
}

/// A message from the settings file.
///
/// The point of being able to say something to every install at once: when a
/// site breaks for everyone, one line here beats a thousand people each
/// discovering it alone and assuming the app is broken.
class _RemoteNotice extends ConsumerWidget {
  const _RemoteNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? notice = ref.watch(remoteConfigProvider).notice;
    if (notice == null || notice.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.campaign_outlined,
                size: 15, color: AppColors.warning),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                notice,
                style: const TextStyle(
                    color: AppColors.warning, fontSize: 11.5, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Engine diagnostics strip. Silent while everything is fine — a permanent
/// "ready" banner is clutter — and explicit when something is off, because
/// "download failed" with no reason is the worst possible outcome.
class _EngineBanner extends ConsumerWidget {
  const _EngineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings s = AppStrings.of(context);
    final EngineStatus status = ref.watch(engineStatusProvider);

    if (status.ok && status.ffmpeg) return const SizedBox.shrink();

    final bool preparing = !status.ok && status.error == null;
    final String message;
    final Color color;
    if (preparing) {
      message = s.downloaderEnginePreparing;
      color = AppColors.white50;
    } else if (!status.ok) {
      message = '${s.downloaderEngineFailed}: ${status.error}';
      color = AppColors.error;
    } else {
      message = s.downloaderNoMerger;
      color = AppColors.warning;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
      child: Row(
        children: <Widget>[
          if (preparing)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          else
            Icon(Icons.info_outline_rounded, size: 14, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 11, height: 1.3),
            ),
          ),
          if (!status.ok && !preparing)
            TextButton(
              onPressed: () =>
                  ref.read(engineStatusProvider.notifier).refresh(),
              child: Text(s.retry),
            ),
        ],
      ),
    );
  }
}

/// Save location, adult-site visibility, engine info and the two recovery
/// levers (update, cookies) in one place.
class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  bool _updating = false;
  bool _advanced = false;
  TextEditingController? _clientsController;
  TextEditingController? _configController;
  TextEditingController? _subsController;

  @override
  void dispose() {
    _clientsController?.dispose();
    _configController?.dispose();
    _subsController?.dispose();
    super.dispose();
  }

  /// One list of choices, shown the same way for both settings.
  Future<T?> _pickOne<T>(
    BuildContext context,
    String title,
    List<T> options,
    String Function(T) label,
  ) =>
      showModalBottomSheet<T>(
        context: context,
        backgroundColor: AppColors.specSheetBg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (BuildContext ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 14),
              Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              const SizedBox(height: 6),
              ...options.map((T option) => ListTile(
                    title: Text(label(option),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14)),
                    onTap: () => Navigator.of(ctx).pop(option),
                  )),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );

  Future<void> _pickDefaultQuality(BuildContext context) async {
    final AppStrings s = AppStrings.of(context);
    final QualityPreset? picked = await _pickOne<QualityPreset>(
      context,
      s.downloaderDefaultQuality,
      QualityPreset.values,
      (QualityPreset p) => presetLabel(s, p),
    );
    if (picked == null) return;
    await ref.read(defaultQualityProvider.notifier).set(picked);
  }

  Future<void> _pickRateLimit(BuildContext context) async {
    final AppStrings s = AppStrings.of(context);
    const List<String> options = <String>['', '300K', '500K', '1M', '2M', '5M'];
    final String? picked = await _pickOne<String>(
      context,
      s.downloaderSpeedLimit,
      options,
      (String v) => v.isEmpty ? s.downloaderUnlimited : '$v/s',
    );
    if (picked == null) return;
    await ref
        .read(downloadExtrasProvider.notifier)
        .update(ref.read(downloadExtrasProvider).copyWith(rateLimit: picked));
  }

  /// Everything a bug report needs, on the clipboard.
  Future<void> _copyDiagnostics(BuildContext context) async {
    final AppStrings s = AppStrings.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final EngineStatus status = ref.read(engineStatusProvider);
    final DownloaderConfig config = ref.read(remoteConfigProvider);
    final String dir = ref.read(downloadDirProvider);
    final DeviceStatus device =
        await DownloaderEngineService.instance.deviceStatus(dir);
    // FROM THE DEVICE, WHICH IS THE ONE PLACE THAT KEEPS IT. The browser and
    // the downloads screen both run checks; reading whichever half of the app
    // happened to measure is how the report ended up saying `dns unknown`
    // while the browser had just diagnosed a poisoned name.
    final String report = DiagnosticsLog.instance.build(
      appVersion: '${AppVersion.name}+${AppVersion.build}',
      engineVersion: status.version ?? 'unknown',
      ffmpeg: status.ffmpeg,
      aria2c: status.aria2c,
      nativeLibs: status.nativeLibs,
      playerClients: ref.read(playerClientsProvider),
      clientsCustom: ref.read(playerClientsProvider.notifier).userSet,
      hasCookies: ref.read(cookiesPathProvider) != null ||
          status.cookieHosts.isNotEmpty,
      cookieHosts: status.cookieHosts,
      configVersion: config.version,
      configSource: ref.read(remoteConfigProvider.notifier).url,
      configFetchedAt: config.fetchedAt,
      saveDir: dir,
      freeBytes: device.freeBytes,
      unmetered: device.unmetered,
      vpn: device.vpn,
      // From the last measurement if one has been taken. NOT measured here:
      // opening diagnostics must not stall on a DNS lookup, and a stale honest
      // answer beats a fresh one nobody waited for.
      privateDns: device.privateDns,
      bypassRunning: device.bypassRunning,
      netVerdict: device.dnsVerdict,
      notificationsEnabled: device.notificationsEnabled,
      lastEngineCheck: await EngineReadiness.instance.lastCheckedLabel(),
      jsRuntime: status.jsRuntime,
      jsRuntimeError: status.jsRuntimeError,
      lastWarning: status.lastWarning,
      deadClients: status.deadClients,
    );
    await Clipboard.setData(ClipboardData(text: report));
    messenger.showSnackBar(SnackBar(content: Text(s.downloaderCopied)));
  }

  Future<void> _pickDir() async {
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

  /// Lets the user choose which site to sign into, then opens it.
  Future<void> _openSignIn(BuildContext context) async {
    final AppStrings s = AppStrings.of(context);
    const List<SignInTarget> targets = <SignInTarget>[
      SignInTargets.youtube,
      SignInTargets.tiktok,
      SignInTargets.instagram,
      SignInTargets.facebook,
    ];
    final SignInTarget? picked = await showModalBottomSheet<SignInTarget>(
      context: context,
      backgroundColor: AppColors.specSheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 14),
            Text(s.downloaderSignIn,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 6),
            ...targets.map((SignInTarget t) => ListTile(
                  title: Text(t.label,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14)),
                  onTap: () => Navigator.of(ctx).pop(t),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await DownloaderEngineService.instance.signIn(
      url: picked.url,
      label: picked.label,
      cookieUrls: picked.cookieUrls,
    );
  }

  Future<void> _pickCookies() async {
    final CookiesPathNotifier cookies = ref.read(cookiesPathProvider.notifier);
    try {
      final FilePickerResult? picked = await FilePicker.platform.pickFiles();
      final String? path = picked?.files.single.path;
      if (path == null) return;
      await cookies.set(path);
    } catch (_) {
      // Nothing selected or the picker was unavailable.
    }
  }

  Future<void> _update() async {
    if (_updating) return;
    final AppStrings s = AppStrings.of(context);
    setState(() => _updating = true);
    final EngineUpdateResult result =
        await DownloaderEngineService.instance.updateEngine();
    if (!mounted) return;
    setState(() => _updating = false);
    ref.read(engineStatusProvider.notifier).refresh();
    await _showUpdateResult(context, s, result);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = AppStrings.of(context);
    final String dir = ref.watch(downloadDirProvider);
    final bool showRestricted = ref.watch(showRestrictedProvider);
    final EngineStatus status = ref.watch(engineStatusProvider);
    final String? cookies = ref.watch(cookiesPathProvider);
    final String clients = ref.watch(playerClientsProvider);
    _clientsController ??= TextEditingController(text: clients);
    _configController ??= TextEditingController(
      text: ref.read(remoteConfigProvider.notifier).url,
    );
    _subsController ??=
        TextEditingController(text: ref.read(downloadExtrasProvider).subLangs);

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.white20,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.folder_outlined,
                  color: AppColors.primaryBlue),
              title: Text(s.downloaderSavePath,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(dir,
                  maxLines: 2,
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 11)),
              trailing: Text(s.downloaderChange,
                  style: const TextStyle(
                      color: AppColors.primaryBlue, fontSize: 12)),
              onTap: _pickDir,
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt_rounded,
                  color: AppColors.primaryBlue),
              title: Text(s.downloaderUpdateEngine,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                _engineDetail(s, status),
                style:
                    const TextStyle(color: AppColors.white50, fontSize: 11),
              ),
              isThreeLine: !status.ffmpeg,
              trailing: _updating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right_rounded,
                      color: AppColors.white40),
              onTap: _updating ? null : _update,
            ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined,
                  color: AppColors.primaryBlue),
              title: Text(s.downloaderSessions,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(s.downloaderSessionsNote,
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 11)),
              trailing: cookies == null
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await DownloaderEngineService.instance.clearCookieJar();
                        await ref.read(cookiesPathProvider.notifier).set(null);
                      },
                      child: Text(s.downloaderSignOut),
                    ),
              onTap: () => _openSignIn(context),
            ),
            ListTile(
              leading:
                  const Icon(Icons.cookie_outlined, color: AppColors.white40),
              title: Text(s.downloaderCookies,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                cookies ?? s.downloaderCookiesNote,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: AppColors.white50, fontSize: 11),
              ),
              trailing: cookies == null
                  ? Text(s.downloaderPickCookies,
                      style: const TextStyle(
                          color: AppColors.primaryBlue, fontSize: 12))
                  : IconButton(
                      tooltip: s.downloaderRemove,
                      icon: const Icon(Icons.close_rounded,
                          color: AppColors.white40, size: 18),
                      onPressed: () =>
                          ref.read(cookiesPathProvider.notifier).set(null),
                    ),
              onTap: cookies == null ? _pickCookies : null,
            ),
            SwitchListTile(
              value: ref.watch(wifiOnlyProvider),
              activeColor: AppColors.primaryBlue,
              title: Text(s.downloaderWifiOnly,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(s.downloaderWifiOnlyNote,
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 11)),
              onChanged: (bool v) =>
                  ref.read(wifiOnlyProvider.notifier).set(v),
            ),
            SwitchListTile(
              value: ref.watch(autoUpdateProvider),
              activeColor: AppColors.primaryBlue,
              title: Text(s.downloaderAutoUpdate,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(s.downloaderAutoUpdateNote,
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 11)),
              onChanged: (bool v) =>
                  ref.read(autoUpdateProvider.notifier).set(v),
            ),
            ListTile(
              leading: const Icon(Icons.high_quality_outlined,
                  color: AppColors.primaryBlue),
              title: Text(s.downloaderDefaultQuality,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                '${presetLabel(s, ref.watch(defaultQualityProvider))}  ·  '
                '${s.downloaderDefaultQualityNote}',
                style: const TextStyle(
                    color: AppColors.white50, fontSize: 11),
              ),
              onTap: () => _pickDefaultQuality(context),
            ),
            const Divider(height: 1, color: AppColors.white08),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
              child: Text(s.downloaderExtras,
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 12)),
            ),
            SwitchListTile(
              value: ref.watch(downloadExtrasProvider).embedThumbnail,
              activeColor: AppColors.primaryBlue,
              title: Text(s.downloaderEmbedThumbnail,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              onChanged: (bool v) => ref
                  .read(downloadExtrasProvider.notifier)
                  .update(ref.read(downloadExtrasProvider)
                      .copyWith(embedThumbnail: v)),
            ),
            SwitchListTile(
              value: ref.watch(downloadExtrasProvider).embedMetadata,
              activeColor: AppColors.primaryBlue,
              title: Text(s.downloaderEmbedMetadata,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              onChanged: (bool v) => ref
                  .read(downloadExtrasProvider.notifier)
                  .update(ref.read(downloadExtrasProvider)
                      .copyWith(embedMetadata: v)),
            ),
            ListTile(
              leading: const Icon(Icons.speed_rounded,
                  color: AppColors.white40),
              title: Text(s.downloaderSpeedLimit,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                ref.watch(downloadExtrasProvider).rateLimit.isEmpty
                    ? s.downloaderUnlimited
                    : ref.watch(downloadExtrasProvider).rateLimit,
                style: const TextStyle(
                    color: AppColors.white50, fontSize: 11),
              ),
              onTap: () => _pickRateLimit(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(s.downloaderSubtitles,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(s.downloaderSubtitlesNote,
                      style: const TextStyle(
                          color: AppColors.white50,
                          fontSize: 11,
                          height: 1.35)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _subsController,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: AppColors.specInnerPanel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      hintText: 'en,my',
                      hintStyle: const TextStyle(
                          color: AppColors.white30, fontSize: 12.5),
                    ),
                    onSubmitted: (String v) => ref
                        .read(downloadExtrasProvider.notifier)
                        .update(ref.read(downloadExtrasProvider)
                            .copyWith(subLangs: v.trim())),
                    onTapOutside: (_) => ref
                        .read(downloadExtrasProvider.notifier)
                        .update(ref.read(downloadExtrasProvider)
                            .copyWith(subLangs: _subsController!.text.trim())),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.white08),
            ListTile(
              leading: const Icon(Icons.content_copy_rounded,
                  color: AppColors.white40),
              title: Text(s.downloaderCopyDiagnostics,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () => _copyDiagnostics(context),
            ),
            SwitchListTile(
              value: showRestricted,
              activeColor: AppColors.primaryBlue,
              title: Text(s.downloaderShowRestricted,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(s.downloaderRestrictedNote,
                  style: const TextStyle(
                      color: AppColors.white50, fontSize: 11)),
              onChanged: (bool value) =>
                  ref.read(showRestrictedProvider.notifier).set(value),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded, color: AppColors.white40),
              title: Text(s.downloaderAdvanced,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              trailing: Icon(
                _advanced
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                color: AppColors.white40,
              ),
              onTap: () => setState(() => _advanced = !_advanced),
            ),
            if (_advanced)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(s.downloaderConfigUrl,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(s.downloaderConfigUrlNote,
                        style: const TextStyle(
                            color: AppColors.white50,
                            fontSize: 11,
                            height: 1.35)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _configController,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.specInnerPanel,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        hintText: s.downloaderConfigNotSet,
                        hintStyle: const TextStyle(
                            color: AppColors.white30, fontSize: 12.5),
                      ),
                      onSubmitted: (String v) =>
                          ref.read(remoteConfigProvider.notifier).setUrl(v),
                      onTapOutside: (_) => ref
                          .read(remoteConfigProvider.notifier)
                          .setUrl(_configController!.text),
                    ),
                    const SizedBox(height: 16),
                    Text(s.downloaderPlayerClients,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(s.downloaderPlayerClientsNote,
                        style: const TextStyle(
                            color: AppColors.white50,
                            fontSize: 11,
                            height: 1.35)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _clientsController,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.specInnerPanel,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        hintText: kDefaultPlayerClients,
                        hintStyle: const TextStyle(
                            color: AppColors.white30, fontSize: 12.5),
                      ),
                      onSubmitted: (String value) => ref
                          .read(playerClientsProvider.notifier)
                          .set(value),
                      onTapOutside: (_) => ref
                          .read(playerClientsProvider.notifier)
                          .set(_clientsController!.text),
                    ),
                  ],
                ),
              ),
            if (_advanced) const SizedBox(height: 4),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _engineDetail(AppStrings s, EngineStatus status) {
    if (!status.ok) return status.error ?? s.downloaderEnginePreparing;
    final List<String> parts = <String>[
      status.version ?? 'yt-dlp',
      'ffmpeg ${status.ffmpeg ? 'ok' : 'off'}',
      'aria2c ${status.aria2c ? 'ok' : 'off'}',
    ];
    // When the merger is off, say whether its library is even in the build.
    // "shipped but unreachable" and "not shipped" look the same on screen and
    // are entirely different faults, and this line is the difference.
    if (!status.ffmpeg) {
      parts.add(status.ffmpegShippedButDead
          ? 'lib present'
          : 'lib missing');
    }
    if (status.nativeLibs.isNotEmpty) {
      parts.add(status.nativeLibs.join(', '));
    }
    return parts.join(' · ');
  }
}

/// Toggle which sites appear in the Favourite row.
class _FavouritePickerSheet extends ConsumerWidget {
  const _FavouritePickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings s = AppStrings.of(context);
    final List<String> favourites = ref.watch(favouriteSitesProvider);
    final bool showRestricted = ref.watch(showRestrictedProvider);
    final List<DownloadSite> sites = <DownloadSite>[
      ...SiteCatalog.general,
      if (showRestricted) ...SiteCatalog.restricted,
    ];

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.white20,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
            child: Row(
              children: <Widget>[
                Text(
                  s.downloaderFavourite,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.white50),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: sites.length,
              itemBuilder: (BuildContext ctx, int i) {
                final DownloadSite site = sites[i];
                return CheckboxListTile(
                  value: favourites.contains(site.id),
                  activeColor: AppColors.primaryBlue,
                  title: Text(site.name,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14)),
                  onChanged: (_) => ref
                      .read(favouriteSitesProvider.notifier)
                      .toggle(site.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
