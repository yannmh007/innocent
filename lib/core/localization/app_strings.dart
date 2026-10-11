import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
/// Lightweight, generation-free localization for Innocent.
///
/// The `.arb` files under `lib/l10n` remain the human-facing source of
/// truth, but to stay compatible with the FlutLab workflow (which can't run
/// `flutter gen-l10n` reliably) the strings also live here as plain Dart
/// maps and are looked up at runtime. Any key missing in the active locale
/// falls back to English, so a half-translated locale never shows a blank.
///
/// Usage:  `AppStrings.of(context).tabMusic`
class AppStrings {
  AppStrings(this.locale);

  final Locale locale;

  /// Strings for the active locale.
  ///
  /// This MUST NOT throw. `Localizations.of` returns null whenever the
  /// delegate isn't in scope for the calling context — a resolved locale
  /// outside en/my/th (so `isSupported` said no), a dialog or route built from
  /// a navigator context that sits above the Localizations widget, or a widget
  /// that outlives its subtree during a locale change. This used to end in
  /// `!` throwing a null-check error *during build*, which Flutter turns into
  /// the full-screen "Something didn't load" card — a missing translation
  /// taking out the entire screen.
  ///
  /// Falling back to English keeps the screen alive. A user seeing one English
  /// label is a cosmetic issue; losing the screen is not.
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ?? _fallback;

  /// Locale-independent fallback used when no delegate is in scope.
  static final AppStrings _fallback = AppStrings(const Locale('en'));

  /// Locales the app can display. Add a map below + a new [Locale] here to
  /// grow the list.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('my'), // Burmese / မြန်မာ
    Locale('th'), // Thai / ไทย
  ];

  /// Drop straight into `MaterialApp.localizationsDelegates`.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    _AppStringsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  /// Human-readable name of a locale, shown in the language picker (always
  /// in its own script so users recognise their language).
  static String localeName(Locale locale) {
    switch (locale.languageCode) {
      case 'my':
        return 'မြန်မာ';
      case 'th':
        return 'ไทย';
      case 'en':
      default:
        return 'English';
    }
  }

  String _s(String key) =>
      (_byLocale[locale.languageCode] ?? _en)[key] ?? _en[key] ?? key;

  // ── Typed accessors ────────────────────────────────────────────────
  // Bottom navigation
  String get tabLocal => _s('tabLocal');
  String get tabMusic => _s('tabMusic');
  String get tabTransfer => _s('tabTransfer');
  String get tabMe => _s('tabMe');

  // Me tab + common destinations
  String get me => _s('tabMe');
  String get settings => _s('settingsTitle');
  String get history => _s('history');
  String get favourites => _s('favourites');
  String get watchLater => _s('watchLater');
  String get chipCleaner => _s('chipCleaner');
  // Quick-access chip labels: one line at 10 sp in a 60 dp slot, so shorter
  // than the screen titles they open.
  String get chipPlaylists => _s('chipPlaylists');
  String get chipPrivate => _s('chipPrivate');
  String get images => _s('images');
  String get playlists => _s('playlists');
  String get recycleBin => _s('recycleBin');
  String get statistics => _s('statistics');
  String get about => _s('about');
  String get help => _s('help');
  String get language => _s('language');

  // Common actions / states
  String get retry => _s('retry');
  String get cancel => _s('cancel');
  String get ok => _s('ok');
  String get done => _s('done');
  String get comingSoon => _s('comingSoon');
  String get playbackFailed => _s('playbackFailed');
  String get grantPermission => _s('permissionGrant');
  String get openSettings => _s('permissionOpenSettings');
  String get pipOverAppsTitle => _s('pipOverAppsTitle');
  String get pipOverAppsBody => _s('pipOverAppsBody');

  // Settings sections
  String get settingsList => _s('settingsList');
  String get settingsPlayer => _s('settingsPlayer');
  String get settingsDecoder => _s('settingsDecoder');
  String get settingsAudio => _s('settingsAudio');
  String get settingsSubtitle => _s('settingsSubtitle');
  String get settingsGeneral => _s('settingsGeneral');
  String get settingsDevelopment => _s('settingsDevelopment');
  String get settingsAppLanguage => _s('language');
  String get settingsTitle => _s('settingsTitle');
  String get permissionGrant => _s('permissionGrant');
  String get permissionOpenSettings => _s('permissionOpenSettings');

  // v1.64.6 — Settings -> App update (docs/updater_plan.md step 2)
  String get settingsAppUpdate => _s('settingsAppUpdate');
  String get updateInstalledVersion => _s('updateInstalledVersion');
  String get updateLatestVersion => _s('updateLatestVersion');
  String get updateSize => _s('updateSize');
  String get updateReleased => _s('updateReleased');
  String get updateUpToDate => _s('updateUpToDate');
  String get updateAvailable => _s('updateAvailable');
  String get updateCheckNow => _s('updateCheckNow');
  String get updateChecking => _s('updateChecking');
  String get updateCheckFailed => _s('updateCheckFailed');
  String get updateNotConfigured => _s('updateNotConfigured');

  // v1.64.7 — the download half (docs/updater_plan.md step 3)
  String get updateDownload => _s('updateDownload');
  String get updateDownloading => _s('updateDownloading');
  String get updateVerifying => _s('updateVerifying');
  String get updateDownloaded => _s('updateDownloaded');
  String get updateDownloadDamaged => _s('updateDownloadDamaged');
  String get updateDownloadMismatch => _s('updateDownloadMismatch');
  String get updateDownloadFailed => _s('updateDownloadFailed');
  String get updateDownloadWriteFailed => _s('updateDownloadWriteFailed');
  String get updateDownloadRefused => _s('updateDownloadRefused');
  String get updateNotEnoughSpace => _s('updateNotEnoughSpace');
  String get updateRetry => _s('updateRetry');
  String get updateNotificationTitle => _s('updateNotificationTitle');

  // v1.64.8 — resumable download (docs/updater_plan.md step 3, follow-up)
  String get updateWaitingForNetwork => _s('updateWaitingForNetwork');
  String get updateKept => _s('updateKept');
  String get updateResumeNow => _s('updateResumeNow');

  // v1.64.8 — the install intent (docs/updater_plan.md step 4)
  String get updateInstall => _s('updateInstall');
  String get updateInstallChecking => _s('updateInstallChecking');
  String get updateInstallGone => _s('updateInstallGone');
  String get updateInstallNoHandler => _s('updateInstallNoHandler');
  String get updateInstallSignature => _s('updateInstallSignature');

  // v1.64.8 — the update prompt (docs/updater_plan.md step 5)
  String get updateNow => _s('updateNow');
  String get updateNotNow => _s('updateNotNow');

  // v1.64.9 — min_supported, the emergency brake (docs/updater_plan.md step 7)
  String get updateRequired => _s('updateRequired');
  String get updateRequiredBody => _s('updateRequiredBody');

  // v1.3 Downloader additions
  String get downloaderSavedFiles => _s('downloaderSavedFiles');
  String get downloaderShare => _s('downloaderShare');
  String get downloaderDeleteFile => _s('downloaderDeleteFile');
  String get downloaderDeleteConfirm => _s('downloaderDeleteConfirm');
  String get downloaderDeleted => _s('downloaderDeleted');
  String get downloaderMissing => _s('downloaderMissing');
  String get downloaderClearList => _s('downloaderClearList');

  // v1.2 Downloader additions
  String get downloaderNotifsBlocked => _s('downloaderNotifsBlocked');
  String get downloaderOpenSettings => _s('downloaderOpenSettings');

  // v1.1 Downloader additions
  String get downloaderVideos => _s('downloaderVideos');
  String get downloaderSelectAll => _s('downloaderSelectAll');
  String get downloaderSelectNone => _s('downloaderSelectNone');
  String get downloaderQueuedCount => _s('downloaderQueuedCount');
  String get downloaderAskEveryTime => _s('downloaderAskEveryTime');
  String get downloaderBest => _s('downloaderBest');
  String get downloaderDefaultQuality => _s('downloaderDefaultQuality');
  String get downloaderDefaultQualityNote => _s('downloaderDefaultQualityNote');
  String get downloaderSubtitles => _s('downloaderSubtitles');
  String get downloaderSubtitlesNote => _s('downloaderSubtitlesNote');
  String get downloaderEmbedThumbnail => _s('downloaderEmbedThumbnail');
  String get downloaderEmbedMetadata => _s('downloaderEmbedMetadata');
  String get downloaderSpeedLimit => _s('downloaderSpeedLimit');
  String get downloaderUnlimited => _s('downloaderUnlimited');
  String get downloaderExtras => _s('downloaderExtras');

  // v0.99.9 Downloader additions
  String get downloaderWifiOnly => _s('downloaderWifiOnly');
  String get downloaderWifiOnlyNote => _s('downloaderWifiOnlyNote');
  String get downloaderMetered => _s('downloaderMetered');
  String get downloaderDownloadAnyway => _s('downloaderDownloadAnyway');
  String get downloaderLowSpace => _s('downloaderLowSpace');
  String get downloaderTapResume => _s('downloaderTapResume');
  String get downloaderAutoUpdate => _s('downloaderAutoUpdate');
  String get downloaderAutoUpdateNote => _s('downloaderAutoUpdateNote');
  String get downloaderConfigUrl => _s('downloaderConfigUrl');
  String get downloaderConfigUrlNote => _s('downloaderConfigUrlNote');
  String get downloaderCopyDiagnostics => _s('downloaderCopyDiagnostics');
  String get downloaderCopied => _s('downloaderCopied');
  String get downloaderConfigNotSet => _s('downloaderConfigNotSet');

  // v0.99.8 Downloader additions
  String get downloaderFixAuto => _s('downloaderFixAuto');
  String get downloaderPreparingSession => _s('downloaderPreparingSession');

  // v0.99.7 Downloader additions
  String get downloaderSignIn => _s('downloaderSignIn');
  String get downloaderSignedIn => _s('downloaderSignedIn');
  String get downloaderSessions => _s('downloaderSessions');
  String get downloaderSessionsNote => _s('downloaderSessionsNote');
  String get downloaderSignOut => _s('downloaderSignOut');
  String get downloaderSignInFailed => _s('downloaderSignInFailed');

  // v0.99.3 Downloader additions
  String get downloaderPhotos => _s('downloaderPhotos');
  String get downloaderPhotoPost => _s('downloaderPhotoPost');
  String get downloaderSaveAll => _s('downloaderSaveAll');
  String get downloaderPhotosSaved => _s('downloaderPhotosSaved');

  // v0.99.2 Downloader additions
  String get downloaderWatermark => _s('downloaderWatermark');
  String get downloaderPause => _s('downloaderPause');
  String get downloaderResume => _s('downloaderResume');
  String get downloaderPaused => _s('downloaderPaused');
  String get downloaderRetrying => _s('downloaderRetrying');
  String get downloaderRemaining => _s('downloaderRemaining');
  String get downloaderInterrupted => _s('downloaderInterrupted');
  String get downloaderResumeAll => _s('downloaderResumeAll');
  String get downloaderOf => _s('downloaderOf');
  String get downloaderNoWatermark => _s('downloaderNoWatermark');

  // v0.99.1 Downloader additions
  String get downloaderSupportedSites => _s('downloaderSupportedSites');
  String get downloaderEdit => _s('downloaderEdit');
  String get downloaderUpdateEngine => _s('downloaderUpdateEngine');
  String get downloaderUpdating => _s('downloaderUpdating');
  String get downloaderUpdated => _s('downloaderUpdated');
  String get downloaderUpToDate => _s('downloaderUpToDate');
  String get downloaderUpdateFailed => _s('downloaderUpdateFailed');
  String get downloaderCookies => _s('downloaderCookies');
  String get downloaderCookiesNote => _s('downloaderCookiesNote');
  String get downloaderPickCookies => _s('downloaderPickCookies');
  String get downloaderRemove => _s('downloaderRemove');
  String get downloaderDetails => _s('downloaderDetails');
  String get downloaderAdvanced => _s('downloaderAdvanced');
  String get downloaderPlayerClients => _s('downloaderPlayerClients');
  String get downloaderPlayerClientsNote => _s('downloaderPlayerClientsNote');
  String get downloaderErrBot => _s('downloaderErrBot');
  String get downloaderErrAccount => _s('downloaderErrAccount');
  String get downloaderErrNetwork => _s('downloaderErrNetwork');
  String get downloaderErrExtractor => _s('downloaderErrExtractor');
  String get downloaderErrUnsupported => _s('downloaderErrUnsupported');
  String get downloaderErrUnknown => _s('downloaderErrUnknown');
  String get downloaderClearBar => _s('downloaderClearBar');

  // v0.99 Downloader
  String get downloaderTitle => _s('downloaderTitle');
  String get downloaderSettings => _s('downloaderSettings');
  String get downloaderPasteHint => _s('downloaderPasteHint');
  String get downloaderPaste => _s('downloaderPaste');
  String get downloaderClipboardFound => _s('downloaderClipboardFound');
  String get downloaderDismiss => _s('downloaderDismiss');
  String get downloaderActive => _s('downloaderActive');
  String get downloaderTabBrowse => _s('downloaderTabBrowse');
  String get downloaderEmptyDownloads => _s('downloaderEmptyDownloads');
  String get downloaderEmptyDownloadsHint => _s('downloaderEmptyDownloadsHint');
  String get downloaderClear => _s('downloaderClear');
  String get downloaderFavourite => _s('downloaderFavourite');
  String get downloaderRecommended => _s('downloaderRecommended');
  String get downloaderRestricted => _s('downloaderRestricted');
  String get downloaderQueued => _s('downloaderQueued');
  String get downloaderPreparing => _s('downloaderPreparing');
  String get downloaderFinalizing => _s('downloaderFinalizing');
  String get downloaderSetIcon => _s('downloaderSetIcon');
  String get downloaderRemoveIcon => _s('downloaderRemoveIcon');
  String get downloaderIconFailed => _s('downloaderIconFailed');
  String get downloaderIconHint => _s('downloaderIconHint');
  String get downloaderSaved => _s('downloaderSaved');
  String get downloaderCancelled => _s('downloaderCancelled');
  String get downloaderFailed => _s('downloaderFailed');
  String get downloaderPlay => _s('downloaderPlay');
  String get downloaderDownload => _s('downloaderDownload');
  String get downloaderEnginePreparing => _s('downloaderEnginePreparing');
  String get downloaderEngineFailed => _s('downloaderEngineFailed');
  String get downloaderNoMerger => _s('downloaderNoMerger');
  String get downloaderSavePath => _s('downloaderSavePath');
  String get downloaderChange => _s('downloaderChange');
  String get downloaderShowRestricted => _s('downloaderShowRestricted');
  String get downloaderRestrictedNote => _s('downloaderRestrictedNote');
  String get downloaderInvalidLink => _s('downloaderInvalidLink');
  String get downloaderFetching => _s('downloaderFetching');
  String get downloaderNoFormats => _s('downloaderNoFormats');
  String get downloaderSiteHint => _s('downloaderSiteHint');
  String get downloaderNoBrowser => _s('downloaderNoBrowser');
  String get downloaderDirFailed => _s('downloaderDirFailed');
  String get downloaderAudio => _s('downloaderAudio');
  String get downloaderVideo => _s('downloaderVideo');
  String get downloaderStream => _s('downloaderStream');
  String get downloaderStreamFailed => _s('downloaderStreamFailed');
  String get downloaderConvert => _s('downloaderConvert');
  String get downloaderLiveNote => _s('downloaderLiveNote');
  String get downloaderStreamOnlyBest => _s('downloaderStreamOnlyBest');
  String get downloaderStreamRefused => _s('downloaderStreamRefused');
  String get downloaderErrRateLimited => _s('downloaderErrRateLimited');
  String get downloaderRateLimitHint => _s('downloaderRateLimitHint');
  String get downloaderRateLimitWait => _s('downloaderRateLimitWait');
  String get downloaderBotWallHint => _s('downloaderBotWallHint');
  String get downloaderAnySiteHint => _s('downloaderAnySiteHint');
  String get downloaderBrowseDownload => _s('downloaderBrowseDownload');
  String get downloaderBrowseHint => _s('downloaderBrowseHint');
  String get downloaderBrowseWorking => _s('downloaderBrowseWorking');
  String get downloaderBrowsePick => _s('downloaderBrowsePick');
  String get downloaderBrowseStarted => _s('downloaderBrowseStarted');
  String get downloaderNeedsStorage => _s('downloaderNeedsStorage');
  String get downloaderNeedsStorageBody => _s('downloaderNeedsStorageBody');
  String get downloaderGrantAccess => _s('downloaderGrantAccess');
  String get downloaderNoSound => _s('downloaderNoSound');

  // v1.27 downloader lifecycle: history, per-row options, browser sheets
  String get downloaderViewPage => _s('downloaderViewPage');
  String get downloaderCopyLink => _s('downloaderCopyLink');
  String get downloaderNoSourcePage => _s('downloaderNoSourcePage');
  String get downloaderDownloadAgain => _s('downloaderDownloadAgain');
  String get downloaderRemoveFromList => _s('downloaderRemoveFromList');
  String get downloaderSeeAll => _s('downloaderSeeAll');
  String get downloaderHistoryTitle => _s('downloaderHistoryTitle');
  String get downloaderHistoryEmpty => _s('downloaderHistoryEmpty');
  String get downloaderRetryDownload => _s('downloaderRetryDownload');
  String get downloaderMoreOptions => _s('downloaderMoreOptions');
  String get downloaderBrowseStreams => _s('downloaderBrowseStreams');
  String get downloaderBrowseUnreadable => _s('downloaderBrowseUnreadable');
  String get downloaderBrowseRetry => _s('downloaderBrowseRetry');
  String get downloaderBrowseSendScreen => _s('downloaderBrowseSendScreen');
  String get downloaderBrowseBlocked => _s('downloaderBrowseBlocked');
  String get downloaderBrowseVpnHint => _s('downloaderBrowseVpnHint');
  String get downloaderBrowseDnsHint => _s('downloaderBrowseDnsHint');
  String get downloaderBrowseMore => _s('downloaderBrowseMore');
  String get downloaderNetworkVpnOff => _s('downloaderNetworkVpnOff');
  String get downloaderNetworkVpnOn => _s('downloaderNetworkVpnOn');
  String get downloaderNetworkVpnNow => _s('downloaderNetworkVpnNow');
  String get downloaderCheckNetwork => _s('downloaderCheckNetwork');
  String get downloaderNetworkChecking => _s('downloaderNetworkChecking');
  String get downloaderNetworkDnsBlocked => _s('downloaderNetworkDnsBlocked');
  String get downloaderNetworkDeeper => _s('downloaderNetworkDeeper');
  String get downloaderNetworkUnknown => _s('downloaderNetworkUnknown');
  String get downloaderNetworkPrivateOn => _s('downloaderNetworkPrivateOn');
  String get downloaderNetworkNoVpnNeeded => _s('downloaderNetworkNoVpnNeeded');
  String get downloaderBypassOpen => _s('downloaderBypassOpen');
  String get downloaderBypassHint => _s('downloaderBypassHint');
  String get downloaderVpnNotNeeded => _s('downloaderVpnNotNeeded');
  String get downloaderAlreadyHave => _s('downloaderAlreadyHave');
  String get downloaderYtWall => _s('downloaderYtWall');
  String get downloaderYtEmbed => _s('downloaderYtEmbed');
  String get downloaderYtSignInNow => _s('downloaderYtSignInNow');

  // Me tab
  String get downloads => _s('downloads');
  String get fileTransfer => _s('fileTransfer');
  String get privateFolder => _s('privateFolder');
  String get videoPlaylists => _s('videoPlaylists');
  String get mediaManager => _s('mediaManager');
  String get localNetwork => _s('localNetwork');
  String get networkStream => _s('networkStream');
  String get cloudDrive => _s('cloudDrive');
  String get appTheme => _s('appTheme');
  String get popupPlay => _s('popupPlay');
  String get watchInsights => _s('watchInsights');
  String get legal => _s('legal');
  String get backupRestore => _s('backupRestore');
  String get quit => _s('quit');
  String get quitConfirmTitle => _s('quitConfirmTitle');
  String get quitConfirmBody => _s('quitConfirmBody');
  String get statusSaver => _s('statusSaver');

  // Music tab
  String get musicTracks => _s('musicTracks');
  String get musicAlbums => _s('musicAlbums');
  String get musicArtists => _s('musicArtists');
  String get musicFolders => _s('musicFolders');
  String get noSongsToShuffle => _s('noSongsToShuffle');
  String get noAlbumsFound => _s('noAlbumsFound');
  String get noArtistsFound => _s('noArtistsFound');
  String get noMusicFoldersFound => _s('noMusicFoldersFound');
  String get errorLoadingAlbums => _s('errorLoadingAlbums');
  String get errorLoadingArtists => _s('errorLoadingArtists');
  String get errorLoadingFolders => _s('errorLoadingFolders');
  String get searchSongs => _s('searchSongs');
  String get newPlaylist => _s('newPlaylist');
  String get playlistName => _s('playlistName');
  String get create => _s('create');
  String get addToHomeScreen => _s('addToHomeScreen');
  String get addedToHomeScreen => _s('addedToHomeScreen');
  String get addWidget => _s('addWidget');
  String get widgetAdded => _s('widgetAdded');
  String get resumePlaySettings => _s('resumePlaySettings');
  String get alwaysResume => _s('alwaysResume');
  String get askEveryTime => _s('askEveryTime');
  String get startFromBeginning => _s('startFromBeginning');

  // Player + Local (Phase 4)
  String get playingQueue => _s('playingQueue');
  String get aspectRatioMenu => _s('aspectRatioMenu');
  String get displaySettings => _s('displaySettings');
  String get bookmark => _s('bookmark');
  String get cut => _s('cut');
  String get favourite => _s('favourite');
  String get addToPlaylistMenu => _s('addToPlaylistMenu');
  String get information => _s('information');
  String get share => _s('share');
  String get tutorial => _s('tutorial');
  String get subtitleDelayMenu => _s('subtitleDelayMenu');
  String get skipMarkers => _s('skipMarkers');
  String get customSpeed => _s('customSpeed');
  String get loopOff => _s('loopOff');
  String get loopOne => _s('loopOne');
  String get loopAll => _s('loopAll');
  String get subtitleOff => _s('subtitleOff');
  String get aspectRatioTitle => _s('aspectRatioTitle');
  String get pressBackAgain => _s('pressBackAgain');
  String get playerQuality => _s('playerQuality');
  String get playerQualityAutoHint => _s('playerQualityAutoHint');
  String get playerQualityFailed => _s('playerQualityFailed');

  // ─── ALBUM DOWNLOADS ─────────────────────────────────────────────────
  String get vhAlbumDownloadAll => _s('vhAlbumDownloadAll');
  String get vhAlbumDownloaded => _s('vhAlbumDownloaded');
  String get vhAlbumDownloadNew => _s('vhAlbumDownloadNew');

  /// "+2 Video" — what the admin added since this album was downloaded.
  String vhAlbumPlusVideos(int n) =>
      _s('vhAlbumPlusVideos').replaceFirst('{n}', '$n');
  String vhAlbumPlusPhotos(int n) =>
      _s('vhAlbumPlusPhotos').replaceFirst('{n}', '$n');

  /// "3 / 9" while an album is arriving.
  /// The album viewer's place: "3 of 10", Telegram's wording.
  String vhCountOf(int i, int n) =>
      _s('vhCountOf').replaceFirst('{i}', '$i').replaceFirst('{n}', '$n');
  String vhResumeAt(String t) => _s('vhResumeAt').replaceFirst('{t}', t);
  String get vhStartOver => _s('vhStartOver');
  String vhMinutesLeft(int m) => _s('vhMinutesLeft').replaceFirst('{m}', '$m');
  String get vhRemoveFromContinue => _s('vhRemoveFromContinue');
  String get vhRemovedFromContinue => _s('vhRemovedFromContinue');
  String get vhMoreLikeThis => _s('vhMoreLikeThis');
  String get vhUpNext => _s('vhUpNext');
  String vhUpNextIn(int s) => _s('vhUpNextIn').replaceFirst('{s}', '$s');
  String get vhPlayNow => _s('vhPlayNow');
  String get vhStillWatching => _s('vhStillWatching');
  String get vhKeepWatching => _s('vhKeepWatching');
  String vhAlbumProgress(int done, int total) => _s('vhAlbumProgress')
      .replaceFirst('{done}', '$done')
      .replaceFirst('{total}', '$total');
  // One of each is its own key: "1 videos + 5 photos" was on the size
  // question, seen in the device lab. Burmese and Thai do not inflect, so
  // their singular is the plural with n = 1.
  String vhAlbumVideos(int n) =>
      _s(n == 1 ? 'vhAlbumVideo1' : 'vhAlbumVideos').replaceFirst('{n}', '$n');
  String vhAlbumPhotos(int n) =>
      _s(n == 1 ? 'vhAlbumPhoto1' : 'vhAlbumPhotos').replaceFirst('{n}', '$n');

  /// "{items}, about {size}. You have {free} free. Carry on?"
  String vhAlbumAsk(Object items, Object size, Object free) =>
      _s('vhAlbumAsk')
          .replaceFirst('{items}', '$items')
          .replaceFirst('{size}', '$size')
          .replaceFirst('{free}', '$free');
  String vhAlbumAskNoSize(Object items, Object free) => _s('vhAlbumAskNoSize')
      .replaceFirst('{items}', '$items')
      .replaceFirst('{free}', '$free');
  String vhAlbumSomeFailed(int n) =>
      _s('vhAlbumSomeFailed').replaceFirst('{n}', '$n');
  String get vhSavedOffline => _s('vhSavedOffline');
  String get vhSaveOffline => _s('vhSaveOffline');
  String get vhAlbumDeleteBody => _s('vhAlbumDeleteBody');
  String get vhDeleteItemBody => _s('vhDeleteItemBody');
  String get vhDataSaver => _s('vhDataSaver');
  String get vhDataSaverHint => _s('vhDataSaverHint');
  String get vhDataSaverWifi => _s('vhDataSaverWifi');
  String get vhDataSaverWifiHint => _s('vhDataSaverWifiHint');
  String get vhDataSaverOn => _s('vhDataSaverOn');
  String get vhDataSaverOff => _s('vhDataSaverOff');
  String get vhSaverChip => _s('vhSaverChip');
  String get vhDiagTitle => _s('vhDiagTitle');
  String get vhDiagHint => _s('vhDiagHint');
  String get vhDiagBody => _s('vhDiagBody');
  String get vhDiagNoteHint => _s('vhDiagNoteHint');
  String get vhDiagSent => _s('vhDiagSent');
  String get vhDiagSentHint => _s('vhDiagSentHint');
  String get vhDiagFailed => _s('vhDiagFailed');
  String get vhDiagCopied => _s('vhDiagCopied');
  // Player notices (1.64.43): a half-downloaded file, a failed hardware
  // decoder, an engine that stopped answering.
  String playerNoticeIncomplete(String t) =>
      _s('playerNoticeIncomplete').replaceFirst('{t}', t);
  String playerNoticeSeekHeld(String t) =>
      _s('playerNoticeSeekHeld').replaceFirst('{t}', t);
  String get playerNoticeSoftware => _s('playerNoticeSoftware');
  String get playerNoticeHwUnavailable => _s('playerNoticeHwUnavailable');
  String get playerNoticeEngineRestarted => _s('playerNoticeEngineRestarted');
  String get playerEngineStuck => _s('playerEngineStuck');
  String get playerDamagedStretch => _s('playerDamagedStretch');
  String get close => _s('close');
  String get audioTrack => _s('audioTrack');
  String get subtitle => _s('subtitle');
  String get lockControls => _s('lockControls');
  String get refresh => _s('refresh');
  String get refreshingLibrary => _s('refreshingLibrary');
  String get noVideosFound => _s('noVideosFound');
  String get noVideosMatch => _s('noVideosMatch');
  String get resume => _s('resume');

  String resumePromptFor(String title) {
    switch (locale.languageCode) {
      case 'my':
        return '"$title" ဆက်ဖွင့်မလား?';
      case 'th':
        return 'เล่น "$title" ต่อ?';
      default:
        return 'Resume "$title"?';
    }
  }
  String get permissionRationale => _s('permissionRationale');
  String get permissionRationalePermanent => _s('permissionRationalePermanent');
  String get features => _s('features');
  String get faq => _s('faq');
  String get versionCheck => _s('versionCheck');
  String get sendBugReport => _s('sendBugReport');
  String get privacy => _s('privacy');
  String get whatsNew => _s('whatsNew');
  String get bugReportHint => _s('bugReportHint');

  String latestVersion(String v) {
    switch (locale.languageCode) {
      case 'my':
        return 'နောက်ဆုံးဗားရှင်း ($v) ကို သုံးနေပါသည်';
      case 'th':
        return 'คุณใช้เวอร์ชันล่าสุด ($v)';
      default:
        return "You're on the latest version ($v)";
    }
  }
  String get sortLabel => _s('sortLabel');
  String get ascending => _s('ascending');
  String get descending => _s('descending');
  String get sortName => _s('sortName');
  String get sortDate => _s('sortDate');
  String get sortSize => _s('sortSize');
  String get viewList => _s('viewList');
  String get viewGrid => _s('viewGrid');


  // ── v0.49 full-coverage getters ──────────────────────────────────
  String get appName => _s('appName');
  String get delete => _s('delete');
  String get clear => _s('clear');
  String get reset => _s('reset');
  String get save => _s('save');
  String get rename => _s('rename');
  String get restore => _s('restore');
  String get remove => _s('remove');
  String get apply => _s('apply');
  String get stop => _s('stop');
  String get start => _s('start');
  String get export => _s('export');
  String get importWord => _s('importWord');
  String get move => _s('move');
  String get hide => _s('hide');
  String get download => _s('download');
  String get play => _s('play');
  String get playAll => _s('playAll');
  String get shuffleAll => _s('shuffleAll');
  String get setWord => _s('setWord');
  String get add => _s('add');
  String get addNow => _s('addNow');
  String get connect => _s('connect');
  String get disconnect => _s('disconnect');
  String get gotIt => _s('gotIt');
  String get skip => _s('skip');
  String get emptyVerb => _s('emptyVerb');
  String get clean => _s('clean');
  String get copyPath => _s('copyPath');
  String get errorWord => _s('errorWord');
  String get off => _s('off');
  String get recent => _s('recent');
  String get properties => _s('properties');
  String get goBack => _s('goBack');
  String get unlock => _s('unlock');
  String get lock => _s('lock');
  String get path => _s('path');
  String get newBadge => _s('newBadge');
  String get failedToLoad => _s('failedToLoad');
  String get fullAccessAlready => _s('fullAccessAlready');
  String get fullAccessTitle => _s('fullAccessTitle');
  String get fullAccessEnabled => _s('fullAccessEnabled');
  String get permissionNotGranted => _s('permissionNotGranted');
  String get clearHistoryTitle => _s('clearHistoryTitle');
  String get clearHistoryBody => _s('clearHistoryBody');
  String get historyCleared => _s('historyCleared');
  String get clearThumbTitle => _s('clearThumbTitle');
  String get clearThumbBody => _s('clearThumbBody');
  String get thumbCleared => _s('thumbCleared');
  String get resetSettingsTitle => _s('resetSettingsTitle');
  String get resetSettingsBody => _s('resetSettingsBody');
  String get settingsResetDone => _s('settingsResetDone');
  String get clearFontCacheTitle => _s('clearFontCacheTitle');
  String get fontCacheCleared => _s('fontCacheCleared');
  String get languageRestartNote => _s('languageRestartNote');
  String get exportFailed => _s('exportFailed');
  String get importFailed => _s('importFailed');
  String get noExportFile => _s('noExportFile');
  String get moreLanguagesOnWay => _s('moreLanguagesOnWay');
  String get colorFormat => _s('colorFormat');
  String get screenTitle => _s('screenTitle');
  String get navigationTitle => _s('navigationTitle');
  String get controlsTitle => _s('controlsTitle');
  String get styleTitle => _s('styleTitle');
  String get subtitleTextTitle => _s('subtitleTextTitle');
  String get subtitleLayoutTitle => _s('subtitleLayoutTitle');
  String get soonBadge => _s('soonBadge');
  String get debugLogsExported => _s('debugLogsExported');
  String get findYourVideos => _s('findYourVideos');
  String get scanningVideos => _s('scanningVideos');
  String get errorLoadingFoldersPrefix => _s('errorLoadingFoldersPrefix');
  String get errorLoadingVideosPrefix => _s('errorLoadingVideosPrefix');
  String get loadingVideos => _s('loadingVideos');
  String get recentlyAdded => _s('recentlyAdded');
  String get continueWatching => _s('continueWatching');
  String get noContinueWatching => _s('noContinueWatching');
  String get removeContinueTitle => _s('removeContinueTitle');
  String get recentSearches => _s('recentSearches');
  String get eqDuringPlayback => _s('eqDuringPlayback');
  String get magicPenHint => _s('magicPenHint');
  String get featuresIntro => _s('featuresIntro');
  String get featuresBody => _s('featuresBody');
  String get faqQ1 => _s('faqQ1');
  String get faqA1 => _s('faqA1');
  String get faqQ2 => _s('faqQ2');
  String get faqA2 => _s('faqA2');
  String get faqQ3 => _s('faqQ3');
  String get faqA3 => _s('faqA3');
  String get faqQ4 => _s('faqQ4');
  String get faqA4 => _s('faqA4');
  String get privacyBody => _s('privacyBody');
  String get aboutBody => _s('aboutBody');
  String get addSubtitleFromUrl => _s('addSubtitleFromUrl');
  String get subtitleUrlTip => _s('subtitleUrlTip');
  String get downloadingSubtitle => _s('downloadingSubtitle');
  String get downloadFailed => _s('downloadFailed');
  String get moveToBinTitle => _s('moveToBinTitle');
  String get deleteVideoTitle => _s('deleteVideoTitle');
  String get addToPlaylist => _s('addToPlaylist');
  String get noPlaylistsYet => _s('noPlaylistsYet');
  String get createNewPlaylist => _s('createNewPlaylist');
  String get newPlaylistTitle => _s('newPlaylistTitle');
  String get playUsingHw => _s('playUsingHw');
  String get playUsingHwPlus => _s('playUsingHwPlus');
  String get playUsingSw => _s('playUsingSw');
  String get hideSelectedHint => _s('hideSelectedHint');
  String get rebuildThumbnail => _s('rebuildThumbnail');
  String get renamePlaylist => _s('renamePlaylist');
  String get playlistEmpty => _s('playlistEmpty');
  String get noCustomPlaylists => _s('noCustomPlaylists');
  String get emptyBinTitle => _s('emptyBinTitle');
  String get binEmpty => _s('binEmpty');
  String get permDeleteTitle => _s('permDeleteTitle');
  String get permDeleteBody => _s('permDeleteBody');
  String get clearWatchLaterTitle => _s('clearWatchLaterTitle');
  String get clearWatchLaterBody => _s('clearWatchLaterBody');
  String get watchLaterEmpty => _s('watchLaterEmpty');
  String get watchLaterHint => _s('watchLaterHint');
  String get noHistoryYet => _s('noHistoryYet');
  String get noFavouritesYet => _s('noFavouritesYet');
  String get yourWatchInsights => _s('yourWatchInsights');
  String get noInsightsYet => _s('noInsightsYet');
  String get totalTimeWatched => _s('totalTimeWatched');
  String get last7Days => _s('last7Days');
  String get mostRewatched => _s('mostRewatched');
  String get mostWatchedFolder => _s('mostWatchedFolder');
  String get averageCompletion => _s('averageCompletion');
  String get failedPickFiles => _s('failedPickFiles');
  String get send => _s('send');
  String get receive => _s('receive');
  String get howTransferWorksTitle => _s('howTransferWorksTitle');
  String get howTransferWorksBody => _s('howTransferWorksBody');
  String get filesToShare => _s('filesToShare');
  String get addFiles => _s('addFiles');
  String get noFilesHint => _s('noFilesHint');
  String get shareIsLive => _s('shareIsLive');
  String get shareScanHint => _s('shareScanHint');
  String get urlCopied => _s('urlCopied');
  String get stopSharing => _s('stopSharing');
  String trSharingNow(int n) => _s('trSharingNow').replaceFirst('{n}', '$n');
  String get trSharingComputer => _s('trSharingComputer');
  String get trViaWifi => _s('trViaWifi');
  String get trReceivingNow => _s('trReceivingNow');
  String get trConnectedTo => _s('trConnectedTo');
  String get trResumeReceiving => _s('trResumeReceiving');
  String get trShareWith => _s('trShareWith');
  String get trPc => _s('trPc');
  String get trTablet => _s('trTablet');
  String get trSendAppShort => _s('trSendAppShort');
  String get trTurboOnShort => _s('trTurboOnShort');
  String get trTurboOffShort => _s('trTurboOffShort');
  String get trSettings => _s('trSettings');
  String get trHistoryEmpty => _s('trHistoryEmpty');
  String get trPcTitle => _s('trPcTitle');
  String get trPcLead => _s('trPcLead');
  String get trPcStep1Turbo => _s('trPcStep1Turbo');
  String get trPcStep1Wifi => _s('trPcStep1Wifi');
  String get trPcStep2 => _s('trPcStep2');
  String get trPcStep3 => _s('trPcStep3');
  String trPcConnected(int n) => _s('trPcConnected').replaceFirst('{n}', '$n');
  String trPcSharingFiles(int n) =>
      _s('trPcSharingFiles').replaceFirst('{n}', '$n');
  String get trPcStart => _s('trPcStart');
  String get trScanTitle => _s('trScanTitle');
  String get trScanBody => _s('trScanBody');
  String get trSendTitle => _s('trSendTitle');
  String get trReceiveTitle => _s('trReceiveTitle');
  String get cameraPermissionNeeded => _s('cameraPermissionNeeded');
  String get scanQrCode => _s('scanQrCode');
  String get orEnterAddress => _s('orEnterAddress');
  String get downloadAll => _s('downloadAll');
  // --- v1.46 Transfer: nearby-device discovery + batch controls ---
  String get nearbyDevices => _s('nearbyDevices');
  String get lookingForPhones => _s('lookingForPhones');
  String get noPhonesFound => _s('noPhonesFound');
  String get tapDeviceToConnect => _s('tapDeviceToConnect');
  String get connectingToDevice => _s('connectingToDevice');
  String get thisPhoneName => _s('thisPhoneName');
  String get renameThisPhone => _s('renameThisPhone');
  String get askBeforeSending => _s('askBeforeSending');
  String get askBeforeSendingHint => _s('askBeforeSendingHint');
  String get wantsToReceive => _s('wantsToReceive');
  String get accept => _s('accept');
  String get decline => _s('decline');
  String get waitingForReceiver => _s('waitingForReceiver');
  String get overallProgress => _s('overallProgress');
  String get alreadyOnThisPhone => _s('alreadyOnThisPhone');
  String get cancelTransfer => _s('cancelTransfer');
  String get hotspotTipBody => _s('hotspotTipBody');
  String get directLinkActive => _s('directLinkActive');
  String get viaRouterSlower => _s('viaRouterSlower');
  String get allFilesReceived => _s('allFilesReceived');
  // --- v1.46 Turbo direct link + transfer history ---
  String get turboTitle => _s('turboTitle');
  String get turboSubtitle => _s('turboSubtitle');
  String get turboStarting => _s('turboStarting');
  String get turboBadge5 => _s('turboBadge5');
  String get turboBadge24 => _s('turboBadge24');
  String get turboUnavailable => _s('turboUnavailable');
  String get turboJoinManually => _s('turboJoinManually');
  String get turboWifiName => _s('turboWifiName');
  String get turboWifiPassword => _s('turboWifiPassword');
  String get turboJoining => _s('turboJoining');
  String get turboConnected => _s('turboConnected');
  String get turboLeave => _s('turboLeave');
  String get turboNoInternet => _s('turboNoInternet');
  String get turboReasonWifiOff => _s('turboReasonWifiOff');
  String get turboReasonLocationOff => _s('turboReasonLocationOff');
  String get turboReasonPermission => _s('turboReasonPermission');
  String get turboReasonUnsupported => _s('turboReasonUnsupported');
  String get turboReasonGeneric => _s('turboReasonGeneric');
  String get turboOpenWifiSettings => _s('turboOpenWifiSettings');
  String get turboOpenLocationSettings => _s('turboOpenLocationSettings');
  String get sendInnocentApp => _s('sendInnocentApp');
  String get sendInnocentAppHint => _s('sendInnocentAppHint');
  String get transferHistory => _s('transferHistory');
  String get clearHistory => _s('clearHistory');
  String get fileMissing => _s('fileMissing');
  String get receivedFromDevice => _s('receivedFromDevice');
  String get turboBandUnknown => _s('turboBandUnknown');
  String get turboSccExplain => _s('turboSccExplain');
  String get turboSccTip => _s('turboSccTip');
  String get turboReasonDeclined => _s('turboReasonDeclined');
  String get turboReasonNoAddress => _s('turboReasonNoAddress');
  String get turboOpenAppSettings => _s('turboOpenAppSettings');
  // --- v1.47 folder send, pause/resume, PIN, group send ---
  String get sendFolder => _s('sendFolder');
  String get sendThisFolder => _s('sendThisFolder');
  String get scanningFolder => _s('scanningFolder');
  String get noSubfolders => _s('noSubfolders');
  String get folderUnreadable => _s('folderUnreadable');
  String get folderEmpty => _s('folderEmpty');
  String get folderTooManyFiles => _s('folderTooManyFiles');
  String get folderAdded => _s('folderAdded');
  String get pauseShare => _s('pauseShare');
  String get resumeShare => _s('resumeShare');
  String get sharePaused => _s('sharePaused');
  String get pauseReceive => _s('pauseReceive');
  String get resumeReceive => _s('resumeReceive');
  String get receivePaused => _s('receivePaused');
  String get pausedBySender => _s('pausedBySender');
  String get protectWithPin => _s('protectWithPin');
  String get protectWithPinHint => _s('protectWithPinHint');
  String get enterSharePin => _s('enterSharePin');
  String get wrongPin => _s('wrongPin');
  String get receiversLabel => _s('receiversLabel');
  String get encryptionNote => _s('encryptionNote');
  String get connectAction => _s('connectAction');
  String get dismiss => _s('dismiss');
  String get addMoreFiles => _s('addMoreFiles');
  String get cannotOpenFile => _s('cannotOpenFile');
  String get allowInstallTitle => _s('allowInstallTitle');
  String get allowInstallBody => _s('allowInstallBody');
  String get allowInstallAction => _s('allowInstallAction');
  String get webUploadHint => _s('webUploadHint');
  String get filesAddedLive => _s('filesAddedLive');
  String get scanSenderQr => _s('scanSenderQr');
  String get scanQrHint => _s('scanQrHint');
  String get playbackSpeed => _s('playbackSpeed');
  String get sleepTimer => _s('sleepTimer');
  String get sleepTimerOff => _s('sleepTimerOff');
  String get shareTrack => _s('shareTrack');
  String get lyrics => _s('lyrics');
  String get playingQueueTitle => _s('playingQueueTitle');
  String get queueEmpty => _s('queueEmpty');
  String get playbackError => _s('playbackError');
  String get noSongsFound => _s('noSongsFound');
  String get errorReadingMusic => _s('errorReadingMusic');
  String get searchPlaylists => _s('searchPlaylists');
  String get searchAlbums => _s('searchAlbums');
  String get searchArtists => _s('searchArtists');
  String get searchFolders => _s('searchFolders');
  String get sortBy => _s('sortBy');
  String get errorLoadingSongs => _s('errorLoadingSongs');
  String get errorLoadingAlbum => _s('errorLoadingAlbum');
  String get errorLoadingPlaylist => _s('errorLoadingPlaylist');
  String get changePin => _s('changePin');
  String get pinChanged => _s('pinChanged');
  String get restoredToLibrary => _s('restoredToLibrary');
  String get restoreFailed => _s('restoreFailed');
  String get privateIntro => _s('privateIntro');
  String get setupPinTitle => _s('setupPinTitle');
  String get setupPinHint => _s('setupPinHint');
  String get useBiometric => _s('useBiometric');
  String get setPin => _s('setPin');
  String get enterPin => _s('enterPin');
  String get restoreBackupTitle => _s('restoreBackupTitle');
  String get clearLibraryCacheTitle => _s('clearLibraryCacheTitle');
  String get addNewServer => _s('addNewServer');
  String get networks => _s('networks');
  String get supportedProtocols => _s('supportedProtocols');
  String get howToUse => _s('howToUse');
  // Me tab
  String get meSettingsHint => _s('meSettingsHint');
  String get meBackupHint => _s('meBackupHint');
  String get meHelpHint => _s('meHelpHint');
  String get meAboutHint => _s('meAboutHint');
  String get meLibrary => _s('meLibrary');
  String get meInsights => _s('meInsights');
  String get meLibraryStats => _s('meLibraryStats');
  // Backup & Restore
  String get bkInfo => _s('bkInfo');
  String get bkSectionBackup => _s('bkSectionBackup');
  String get bkExport => _s('bkExport');
  String get bkExportSub => _s('bkExportSub');
  String get bkSectionRestore => _s('bkSectionRestore');
  String get bkRestoreFile => _s('bkRestoreFile');
  String get bkRestoreFileSub => _s('bkRestoreFileSub');
  String get bkSectionCloud => _s('bkSectionCloud');
  String get bkCloudSub => _s('bkCloudSub');
  String get bkSectionCache => _s('bkSectionCache');
  String get bkClearCache => _s('bkClearCache');
  String get bkClearCacheSub => _s('bkClearCacheSub');
  String get bkWhat => _s('bkWhat');
  String get bkItemSettings => _s('bkItemSettings');
  String get bkItemPlaylists => _s('bkItemPlaylists');
  String get bkItemFavourites => _s('bkItemFavourites');
  String get bkItemHistory => _s('bkItemHistory');
  String get bkItemLater => _s('bkItemLater');
  String get bkItemBookmarks => _s('bkItemBookmarks');
  String get bkRestoreWarn => _s('bkRestoreWarn');
  String get bkClearWarn => _s('bkClearWarn');
  String bkExported(String path) => _s('bkExported').replaceAll('{path}', path);
  String bkFailed(String e) => _s('bkFailed').replaceAll('{e}', e);
  String get bkNoFile => _s('bkNoFile');
  String bkRestored(String f, String p, String b, String h) => _s('bkRestored').replaceAll('{f}', f).replaceAll('{p}', p).replaceAll('{b}', b).replaceAll('{h}', h);
  String get bkCacheCleared => _s('bkCacheCleared');
  // Local Network (lib/features/network)
  String get netHowStep1 => _s('netHowStep1');
  String get netHowStep2 => _s('netHowStep2');
  String get netHowStep3 => _s('netHowStep3');
  String get netGotIt => _s('netGotIt');
  String netNewServer(String p) => _s('netNewServer').replaceAll('{p}', p);
  String netEditServer(String p) => _s('netEditServer').replaceAll('{p}', p);
  String get netScan => _s('netScan');
  String get netServer => _s('netServer');
  String get netServerIp => _s('netServerIp');
  String get netServerName => _s('netServerName');
  String get netServerNameHint => _s('netServerNameHint');
  String get netSharedPath => _s('netSharedPath');
  String get netSharedPathHint => _s('netSharedPathHint');
  String get netFolder => _s('netFolder');
  String get netFolderHint => _s('netFolderHint');
  String get netPort => _s('netPort');
  String get netUsername => _s('netUsername');
  String get netPassword => _s('netPassword');
  String get netAnonymous => _s('netAnonymous');
  String get netMode => _s('netMode');
  String get netActive => _s('netActive');
  String get netPassive => _s('netPassive');
  String get netEncoding => _s('netEncoding');
  String get netSecurityMode => _s('netSecurityMode');
  String get netImplicit => _s('netImplicit');
  String get netExplicit => _s('netExplicit');
  String get netUseKey => _s('netUseKey');
  String get netPrivateKey => _s('netPrivateKey');
  String get netPrivateKeyHint => _s('netPrivateKeyHint');
  String get netChooseKeyFile => _s('netChooseKeyFile');
  String get netPassphrase => _s('netPassphrase');
  String get netPassphraseHint => _s('netPassphraseHint');
  String get netConnect => _s('netConnect');
  String get netSave => _s('netSave');
  String get netConnecting => _s('netConnecting');
  String netErrUnreachable(String host) => _s('netErrUnreachable').replaceAll('{host}', host);
  String get netErrTimeout => _s('netErrTimeout');
  String get netErrAuth => _s('netErrAuth');
  String get netErrAuthAnon => _s('netErrAuthAnon');
  String get netErrDenied => _s('netErrDenied');
  String get netErrNotFound => _s('netErrNotFound');
  String get netErrTls => _s('netErrTls');
  String get netErrKey => _s('netErrKey');
  String netErrProtocol(String p) => _s('netErrProtocol').replaceAll('{p}', p);
  String get netErrHostKey => _s('netErrHostKey');
  String get netErrHostKeyBody => _s('netErrHostKeyBody');
  String get netTrustNew => _s('netTrustNew');
  String get netErrNeedHost => _s('netErrNeedHost');
  String get netErrBadPort => _s('netErrBadPort');
  String get netErrNeedKey => _s('netErrNeedKey');
  String get netErrUnsupported => _s('netErrUnsupported');
  String get netScanTitle => _s('netScanTitle');
  String netScanning(String p, String subnet) => _s('netScanning').replaceAll('{p}', p).replaceAll('{subnet}', subnet);
  String netScanNone(String p) => _s('netScanNone').replaceAll('{p}', p);
  String get netScanNoneHint => _s('netScanNoneHint');
  String get netScanAgain => _s('netScanAgain');
  String get netScanNoWifi => _s('netScanNoWifi');
  String get netMyServers => _s('netMyServers');
  String get netEdit => _s('netEdit');
  String get netDelete => _s('netDelete');
  String netDeleteConfirm(String name) => _s('netDeleteConfirm').replaceAll('{name}', name);
  String get netDeleteBody => _s('netDeleteBody');
  String get netEmptyFolder => _s('netEmptyFolder');
  String get netRetry => _s('netRetry');
  String get netSortName => _s('netSortName');
  String get netSortDate => _s('netSortDate');
  String get netSortSize => _s('netSortSize');
  String get netMediaOnly => _s('netMediaOnly');
  String get netNotPlayable => _s('netNotPlayable');
  String netItems(int n) => _s('netItems').replaceFirst('{n}', '$n');
  String get netAnonymousTag => _s('netAnonymousTag');
  String get netShares => _s('netShares');
  String get netShowPassword => _s('netShowPassword');
  String get aboutCloudDrive => _s('aboutCloudDrive');
  String get cloudDriveBody => _s('cloudDriveBody');
  String get connectCloudCaps => _s('connectCloudCaps');
  String get deviceStorage => _s('deviceStorage');
  /// "{used} of {total} used"
  String mmUsedOf(String used, String total) => _s('mmUsedOf')
      .replaceFirst('{used}', used)
      .replaceFirst('{total}', total);
  /// "{free} free"
  String mmFree(String free) => _s('mmFree').replaceFirst('{free}', free);
  String get mmVideos => _s('mmVideos');
  String get mmMusic => _s('mmMusic');
  String get mmNoAccess => _s('mmNoAccess');
  String get mmStorageUnknown => _s('mmStorageUnknown');
  String get mmRecentlyPlayed => _s('mmRecentlyPlayed');
  String get mmLargeFiles => _s('mmLargeFiles');
  String get mmLargestVideos => _s('mmLargestVideos');
  String get mmHaventPlayed => _s('mmHaventPlayed');
  String get mmAllPlayed => _s('mmAllPlayed');
  // The player's shortcut row and its checklist (MX's names).
  String get scNightMode => _s('scNightMode');
  String get scShuffle => _s('scShuffle');
  String get scMute => _s('scMute');
  String get scAbRepeat => _s('scAbRepeat');
  String get scMirrorMode => _s('scMirrorMode');
  String get scVerticalFlip => _s('scVerticalFlip');
  String get scAudioEffect => _s('scAudioEffect');
  String get scEqualizer => _s('scEqualizer');
  String get scSpeed => _s('scSpeed');
  String get scScreenshot => _s('scScreenshot');
  String get scBackgroundPlay => _s('scBackgroundPlay');
  String get scScreenRotation => _s('scScreenRotation');
  String get scLoop => _s('scLoop');
  String get scCustomiseItems => _s('scCustomiseItems');
  String get scVideoDisplay => _s('scVideoDisplay');
  String get scSleepTimer => _s('scSleepTimer');
  // Settings → Controls and the gesture guide (docs/player_gestures.md).
  String get gtSection => _s('gtSection');
  String get gtBrightness => _s('gtBrightness');
  String get gtBrightnessSub => _s('gtBrightnessSub');
  String get gtVolume => _s('gtVolume');
  String get gtVolumeSub => _s('gtVolumeSub');
  String get gtSeek => _s('gtSeek');
  String get gtSeekSub => _s('gtSeekSub');
  String get gtDoubleTap => _s('gtDoubleTap');
  String get gtDoubleTapSub => _s('gtDoubleTapSub');
  String get gtLongPress => _s('gtLongPress');
  String get gtLongPressSub => _s('gtLongPressSub');
  String get gtPinch => _s('gtPinch');
  String get gtPinchSub => _s('gtPinchSub');
  String get gtPan => _s('gtPan');
  String get gtPanSub => _s('gtPanSub');
  String get gtSpeed => _s('gtSpeed');
  String get gtSpeedSub => _s('gtSpeedSub');
  String get gtSubtitle => _s('gtSubtitle');
  String get gtSubtitleSub => _s('gtSubtitleSub');
  String get zmFit => _s('zmFit');
  String get zmStretch => _s('zmStretch');
  String get zmCrop => _s('zmCrop');
  String get zmOriginal => _s('zmOriginal');
  String get zmCustom => _s('zmCustom');
  String get zmCustomHint => _s('zmCustomHint');
  String get gtTap => _s('gtTap');
  String get gtTapSub => _s('gtTapSub');
  String get gtVolumeKey => _s('gtVolumeKey');
  String get gtVolumeKeySub => _s('gtVolumeKeySub');
  String get gtHeadset => _s('gtHeadset');
  String get gtHeadsetSub => _s('gtHeadsetSub');
  String get cleanUpSpace => _s('cleanUpSpace');
  String get scanningCleanable => _s('scanningCleanable');
  String get openingRecentlyPlayed => _s('openingRecentlyPlayed');
  String get storagePermissionNeeded => _s('storagePermissionNeeded');
  String get statusPermissionHint => _s('statusPermissionHint');
  String get openingPrivacyPolicy => _s('openingPrivacyPolicy');
  String get openingTerms => _s('openingTerms');
  String get personalPlayerApp => _s('personalPlayerApp');
  String get storageManagement => _s('storageManagement');
  String get storageUsage => _s('storageUsage');
  String get classicThemes => _s('classicThemes');
  String get noInternetThemes => _s('noInternetThemes');
  String get themeApplied => _s('themeApplied');
  String get openSourceLicenses => _s('openSourceLicenses');
  String get personalProject => _s('personalProject');
  String get personalVideoPlayer => _s('personalVideoPlayer');
  String get slowBuffering => _s('slowBuffering');
  /// Shown instead of [slowBuffering] while a stream is still OPENING.
  /// Start-up latency is not a slow connection and must not be described
  /// as one — see PlayerState.isOpening.
  String get openingVideo => _s('openingVideo');

  /// Shown when playback stops and the MEASUREMENT says the device, not the
  /// link, could not keep up — libmpv was holding plenty of data and the
  /// decoder was dropping frames. Blaming the connection there is a false
  /// statement that sends the viewer to restart a router that was never the
  /// problem. See StallCause.
  String get videoTooHeavy => _s('videoTooHeavy');

  /// The storage screen for the streaming cache. Its own strings rather than
  /// the thumbnail cache's, because the two hold very different things and a
  /// viewer deciding how much of their phone to give away needs to know
  /// which one they are looking at.
  String get streamCacheTitle => _s('streamCacheTitle');
  String get streamCacheExplain => _s('streamCacheExplain');
  String get streamCacheLimit => _s('streamCacheLimit');
  String get streamCacheClear => _s('streamCacheClear');
  String get streamCacheClearNote => _s('streamCacheClearNote');
  String get streamCacheClearPages => _s('streamCacheClearPages');
  String get streamCacheClearPagesNote => _s('streamCacheClearPagesNote');
  String get streamCacheKept => _s('streamCacheKept');
  String get streamCacheUnnamed => _s('streamCacheUnnamed');
  String get streamCacheSubtitle => _s('streamCacheSubtitle');
  String get durationLabel => _s('durationLabel');
  String get resumeTitle => _s('resumeTitle');
  String get resumeBody => _s('resumeBody');
  String get useByDefault => _s('useByDefault');
  String get startOver => _s('startOver');
  String get continueFromStopped => _s('continueFromStopped');
  String get customSpeedTitle => _s('customSpeedTitle');
  String get speedRangeHint => _s('speedRangeHint');
  String get playLastToEnd => _s('playLastToEnd');
  String get setStartFirst => _s('setStartFirst');
  String get endAfterStart => _s('endAfterStart');
  String get setBothPoints => _s('setBothPoints');
  String get markClipHint => _s('markClipHint');
  String get currentLabel => _s('currentLabel');
  String get clipLabel => _s('clipLabel');
  String get displaySettingsTitle => _s('displaySettingsTitle');
  String get playerGestures => _s('playerGestures');
  String get tapToDismiss => _s('tapToDismiss');
  String get skipIntroOutro => _s('skipIntroOutro');
  String get clearAllMarkers => _s('clearAllMarkers');
  String get noTracksAvailable => _s('noTracksAvailable');
  String get loadExternalSubtitle => _s('loadExternalSubtitle');
  String get onlineSubtitles => _s('onlineSubtitles');
  String get selectDecoder => _s('selectDecoder');
  String get bookmarksTitle => _s('bookmarksTitle');
  String get subtitleDelayTitle => _s('subtitleDelayTitle');

  // Subtitle Text / Subtitle Layout screens (localised 13 Sep 2026).
  String get subFont => _s('subFont');
  String get subFontDefault => _s('subFontDefault');
  String get subFontSansSerif => _s('subFontSansSerif');
  String get subFontSerif => _s('subFontSerif');
  String get subFontMonospace => _s('subFontMonospace');
  String get subFontCustomEnter => _s('subFontCustomEnter');
  String get subFontCustom => _s('subFontCustom');
  String get subFontCustomHint => _s('subFontCustomHint');
  String get subSize => _s('subSize');
  String get subFontSize => _s('subFontSize');
  String get subBold => _s('subBold');
  String get subBoldDesc => _s('subBoldDesc');
  String get subTextColor => _s('subTextColor');
  String get subTextColorTitle => _s('subTextColorTitle');
  String get subBorderStyle => _s('subBorderStyle');
  String get subBorderStyleTitle => _s('subBorderStyleTitle');
  String get subBorderColor => _s('subBorderColor');
  String get subBorderColorTitle => _s('subBorderColorTitle');
  String get subScale => _s('subScale');
  String get subScaleTitle => _s('subScaleTitle');
  String get subShadow => _s('subShadow');
  String get subBackground => _s('subBackground');
  String get subBackgroundColor => _s('subBackgroundColor');
  String get subAlignment => _s('subAlignment');
  String get subTextAlignment => _s('subTextAlignment');
  String get subBottomMargins => _s('subBottomMargins');
  String get subBottomMarginsTitle => _s('subBottomMarginsTitle');
  String get subImproveStroke => _s('subImproveStroke');
  String get subSecColor => _s('subSecColor');
  String get subSecBorder => _s('subSecBorder');
  String get subSecAppearance => _s('subSecAppearance');
  String get sizeTiny => _s('sizeTiny');
  String get sizeSmall => _s('sizeSmall');
  String get sizeMedium => _s('sizeMedium');
  String get sizeLarge => _s('sizeLarge');
  String get sizeHuge => _s('sizeHuge');
  String get colourWhite => _s('colourWhite');
  String get colourYellow => _s('colourYellow');
  String get colourCyan => _s('colourCyan');
  String get colourGreen => _s('colourGreen');
  String get colourRed => _s('colourRed');
  String get colourBlack => _s('colourBlack');
  String get borderNone => _s('borderNone');
  String get borderOutline => _s('borderOutline');
  String get borderDropShadow => _s('borderDropShadow');
  String get borderRaised => _s('borderRaised');
  String get borderDepressed => _s('borderDepressed');
  String get shadowSubtle => _s('shadowSubtle');
  String get shadowDefault => _s('shadowDefault');
  String get shadowStrong => _s('shadowStrong');
  String get bgTransparent => _s('bgTransparent');
  String get bgTranslucent => _s('bgTranslucent');
  String get bgOpaque => _s('bgOpaque');
  String get alignLeft => _s('alignLeft');
  String get alignCenter => _s('alignCenter');
  String get alignRight => _s('alignRight');
  String get subImproveStrokeDesc => _s('subImproveStrokeDesc');
  String get subVerticalPos => _s('subVerticalPos');
  String get subVerticalPosTitle => _s('subVerticalPosTitle');
  String get subVerticalPosDesc => _s('subVerticalPosDesc');
  String get subHorizontalAlign => _s('subHorizontalAlign');
  String get subHorizontalAlignTitle => _s('subHorizontalAlignTitle');
  String get subSidePadding => _s('subSidePadding');
  String get subSidePaddingTitle => _s('subSidePaddingTitle');
  String get subSidePaddingDesc => _s('subSidePaddingDesc');
  String get subBottomMargin => _s('subBottomMargin');
  String get subBottomMarginTitle => _s('subBottomMarginTitle');
  String get subBottomMarginDesc => _s('subBottomMarginDesc');
  String get subShowBackground => _s('subShowBackground');
  String get subBgBlack50 => _s('subBgBlack50');
  String get subBgBlack75 => _s('subBgBlack75');
  String get subBgDarkGray => _s('subBgDarkGray');
  String get subBgColorActiveWhen => _s('subBgColorActiveWhen');
  String get currently => _s('currently');
  String get shortcuts => _s('shortcuts');
  String get unknownTab => _s('unknownTab');
  String get invalidUrl => _s('invalidUrl');
  String get streamUrl => _s('streamUrl');
  String get equalizerTitle => _s('equalizerTitle');
  String get eqNotAvailable => _s('eqNotAvailable');
  String get audioFxNotAvailable => _s('audioFxNotAvailable');
  String get tapProfileHint => _s('tapProfileHint');
  String get profilesFineTuneHint => _s('profilesFineTuneHint');
  String get reverb => _s('reverb');
  String get kidsLock => _s('kidsLock');
  String get kidsLockOnMsg => _s('kidsLockOnMsg');
  String get kidsLockHoldHint => _s('kidsLockHoldHint');
  String get kidsLockOffMsg => _s('kidsLockOffMsg');

  // Template strings — placeholder {x} is substituted at call time.
  String versionOf(Object v) => _s('versionOf').replaceFirst('{v}', '$v');
  String exportedTo(Object path) => _s('exportedTo').replaceFirst('{path}', '$path');
  String importedFrom(Object path) => _s('importedFrom').replaceFirst('{path}', '$path');
  String createdPlaylist(Object name) => _s('createdPlaylist').replaceFirst('{name}', '$name');
  String deleteNameTitle(Object name) => _s('deleteNameTitle').replaceFirst('{name}', '$name');
  String deletedName(Object name) => _s('deletedName').replaceFirst('{name}', '$name');
  String restoredName(Object name) => _s('restoredName').replaceFirst('{name}', '$name');
  String removedName(Object name) => _s('removedName').replaceFirst('{name}', '$name');
  String unfavouritedName(Object name) => _s('unfavouritedName').replaceFirst('{name}', '$name');
  String savedToPath(Object path) => _s('savedToPath').replaceFirst('{path}', '$path');
  String stopsIn(Object t) => _s('stopsIn').replaceFirst('{t}', '$t');
  String sleepTimerSetMin(Object n) => _s('sleepTimerSetMin').replaceFirst('{n}', '$n');
  String noSongsBy(Object name) => _s('noSongsBy').replaceFirst('{name}', '$name');
  String noSongsIn(Object name) => _s('noSongsIn').replaceFirst('{name}', '$name');
  String playAllCount(Object n) => _s('playAllCount').replaceFirst('{n}', '$n');
  String sharingName(Object name) => _s('sharingName').replaceFirst('{name}', '$name');
  String playingName(Object name) => _s('playingName').replaceFirst('{name}', '$name');
  String shufflingName(Object name) => _s('shufflingName').replaceFirst('{name}', '$name');
  String propertiesForName(Object name) => _s('propertiesForName').replaceFirst('{name}', '$name');
  String savedAt(Object t) => _s('savedAt').replaceFirst('{t}', '$t');

  String get fullAccessBody => _s('fullAccessBody');
  String get resetSettingsBodyFull => _s('resetSettingsBodyFull');

  String get popupPlayControls => _s('popupPlayControls');

  String get storageRoot => _s('storageRoot');
  String get noFolders => _s('noFolders');
  String get couldNotLoadFiles => _s('couldNotLoadFiles');
  String get couldNotLoadFolders => _s('couldNotLoadFolders');
  String get noVideosInFolder => _s('noVideosInFolder');

  String get abPointASet => _s('abPointASet');
  String get abRepeatOn => _s('abRepeatOn');
  String get abRepeatOff => _s('abRepeatOff');
  String get addedToFavourites => _s('addedToFavourites');
  String get removedFromFavourites => _s('removedFromFavourites');

  String get catVideos => _s('catVideos');
  String get catImages => _s('catImages');
  String get catAudio => _s('catAudio');
  String get catFiles => _s('catFiles');
  String get catApps => _s('catApps');
  // English alone has a singular: "1 items" read wrong in the pickers.
  String itemsCount(Object n) => n == 1 && locale.languageCode == 'en'
      ? '1 item'
      : _s('itemsCount').replaceFirst('{n}', '$n');
  String filesCount(Object n) => _s('filesCount').replaceFirst('{n}', '$n');
  String appsCount(Object n) => _s('appsCount').replaceFirst('{n}', '$n');
  String get noItemsHere => _s('noItemsHere');
  String get loadingApps => _s('loadingApps');
  String get appsUnavailable => _s('appsUnavailable');
  String get shareFile => _s('shareFile');
  String get unlockToLibrary => _s('unlockToLibrary');
  String get addedToTransfer => _s('addedToTransfer');

  String get selectFilesToAdd => _s('selectFilesToAdd');
  String get selectFilesToSend => _s('selectFilesToSend');

  String get newPin => _s('newPin');
  String get confirmPin => _s('confirmPin');
  String get pinLabel => _s('pinLabel');
  String get currentPin => _s('currentPin');
  String get confirmNewPin => _s('confirmNewPin');
  String get pinMin4 => _s('pinMin4');
  String get pinsDontMatch => _s('pinsDontMatch');
  String get newPinMin4 => _s('newPinMin4');
  String get newPinsDontMatch => _s('newPinsDontMatch');
  String get currentPinIncorrect => _s('currentPinIncorrect');
  String get incorrectPin => _s('incorrectPin');
  String tooManyAttemptsWait(Object s) => _s('tooManyAttemptsWait').replaceFirst('{s}', '$s');
  String get biometricNotEnrolled => _s('biometricNotEnrolled');
  String get biometricEnrollFirst => _s('biometricEnrollFirst');
  String get unlockPrivateReason => _s('unlockPrivateReason');
  String get unlockHint => _s('unlockHint');
  String get biometricSubtitle => _s('biometricSubtitle');

  String get mediaPermissionNeeded => _s('mediaPermissionNeeded');
  String get mediaPermissionHint => _s('mediaPermissionHint');
  String get grantAccess => _s('grantAccess');

  String get layoutSection => _s('layoutSection');
  String get layoutList => _s('layoutList');
  String get layoutGrid => _s('layoutGrid');

  String get allFilesAccessNeeded => _s('allFilesAccessNeeded');
  String get allFilesAccessHint => _s('allFilesAccessHint');
  String get noFilesInFolder => _s('noFilesInFolder');

  String get allFiles => _s('allFiles');
  String get newFolder => _s('newFolder');
  String get createFolderTitle => _s('createFolderTitle');
  String get folderName => _s('folderName');
  String get renameFolderTitle => _s('renameFolderTitle');
  String get deleteFolderTitle => _s('deleteFolderTitle');
  String get deleteFolderBody => _s('deleteFolderBody');
  String get moveToFolder => _s('moveToFolder');
  String get moveHere => _s('moveHere');
  String get mainFolder => _s('mainFolder');
  String get chooseFolder => _s('chooseFolder');
  String get addToExisting => _s('addToExisting');
  String get verifyToLock => _s('verifyToLock');
  String get searchFilesHint => _s('searchFilesHint');
  String get emptyFolder => _s('emptyFolder');
  String get foldersHeader => _s('foldersHeader');
  String get catAll => _s('catAll');

  String get chooseFolderTitle => _s('chooseFolderTitle');
  String get mainFolderRoot => _s('mainFolderRoot');
  String get newFolderEllipsis => _s('newFolderEllipsis');
  String get lockCancelled => _s('lockCancelled');

  String get foldersTitle => _s('foldersTitle');
  String get refreshingVault => _s('refreshingVault');

  String get moreOptions => _s('moreOptions');

  String get resumeVault => _s('resumeVault');
  String get nothingToResume => _s('nothingToResume');

  String get viewModeFolders => _s('viewModeFolders');
  String get viewModeFiles => _s('viewModeFiles');

  String get deletePermanently => _s('deletePermanently');
  String get deletePermanentlyTitle => _s('deletePermanentlyTitle');
  String get deletePermanentlyBody => _s('deletePermanentlyBody');
  String get fileDeleted => _s('fileDeleted');

  String selectedCount(Object n) => _s('selectedCount').replaceFirst('{n}', '$n');
  String get selectAll => _s('selectAll');
  String get moveSelected => _s('moveSelected');
  String get unlockSelected => _s('unlockSelected');
  String get deleteSelected => _s('deleteSelected');
  String deleteSelectedTitle(Object n) => _s('deleteSelectedTitle').replaceFirst('{n}', '$n');
  String get deleteSelectedBody => _s('deleteSelectedBody');
  String itemsUnlocked(Object n) => _s('itemsUnlocked').replaceFirst('{n}', '$n');
  String itemsMovedFolder(Object n) => _s('itemsMovedFolder').replaceFirst('{n}', '$n');

  String get renameEntry => _s('renameEntry');
  String get renameEntryTitle => _s('renameEntryTitle');
  String get entryNameHint => _s('entryNameHint');

  String vaultStorageUsed(Object size) => _s('vaultStorageUsed').replaceFirst('{size}', '$size');

  String get viewModeLabel => _s('viewModeLabel');
  String get sortAndView => _s('sortAndView');

  String deleteFolderChoiceBody(Object n) => _s('deleteFolderChoiceBody').replaceFirst('{n}', '$n');

  String deleteFolderWithItemsTitle(Object n) => _s('deleteFolderWithItemsTitle').replaceFirst('{n}', '$n');
  String get unlockAndDeleteFolder => _s('unlockAndDeleteFolder');
  String get unlockAndDeleteFolderSub => _s('unlockAndDeleteFolderSub');
  String get deleteFolderAndFiles => _s('deleteFolderAndFiles');
  String get deleteFolderAndFilesSub => _s('deleteFolderAndFilesSub');
  String get folderDeleted => _s('folderDeleted');

  String get vaultFileMissing => _s('vaultFileMissing');

  String someFilesFailed(Object n) => _s('someFilesFailed').replaceFirst('{n}', '$n');
  String filesAddedOk(Object n) => _s('filesAddedOk').replaceFirst('{n}', '$n');

  String get forgotPin => _s('forgotPin');
  String get recoverVault => _s('recoverVault');
  String get chooseRecoveryMethod => _s('chooseRecoveryMethod');
  String get recoveryNotSetup => _s('recoveryNotSetup');
  String get securityQuestion => _s('securityQuestion');
  String get securityAnswer => _s('securityAnswer');
  String get setSecurityQuestion => _s('setSecurityQuestion');
  String get chooseAQuestion => _s('chooseAQuestion');
  String get wrongAnswer => _s('wrongAnswer');
  String get answerRequired => _s('answerRequired');
  String get recoveryKey => _s('recoveryKey');
  String get recoveryKeyGenerated => _s('recoveryKeyGenerated');
  String get recoveryKeyWarning => _s('recoveryKeyWarning');
  String get enterRecoveryKey => _s('enterRecoveryKey');
  String get wrongRecoveryKey => _s('wrongRecoveryKey');
  String get copiedToClipboard => _s('copiedToClipboard');
  String get iSavedIt => _s('iSavedIt');
  String get setNewPin => _s('setNewPin');
  String get pinResetSuccess => _s('pinResetSuccess');
  String get setUpRecovery => _s('setUpRecovery');
  String get recoveryOptions => _s('recoveryOptions');
  String get recoverySetupPrompt => _s('recoverySetupPrompt');
  String get skipForNow => _s('skipForNow');
  String get recoveryConfigured => _s('recoveryConfigured');
  String get notConfigured => _s('notConfigured');
  String get regenerateKey => _s('regenerateKey');

  String get antiTheft => _s('antiTheft');
  String get antiTheftDesc => _s('antiTheftDesc');
  String get decoyPin => _s('decoyPin');
  String get decoyPinDesc => _s('decoyPinDesc');
  String get setDecoyPin => _s('setDecoyPin');
  String get decoyPinSet => _s('decoyPinSet');
  String get decoySameAsReal => _s('decoySameAsReal');
  String get removeDecoyPin => _s('removeDecoyPin');
  String get intruderSelfie => _s('intruderSelfie');
  String get intruderSelfieDesc => _s('intruderSelfieDesc');
  String get breakInAttempts => _s('breakInAttempts');
  String get noBreakIns => _s('noBreakIns');
  String get clearLog => _s('clearLog');
  String get clearLogConfirm => _s('clearLogConfirm');
  String get photoUnavailable => _s('photoUnavailable');

  String get secQ1 => _s('secQ1');
  String get secQ2 => _s('secQ2');
  String get secQ3 => _s('secQ3');
  String get secQ4 => _s('secQ4');
  String get secQ5 => _s('secQ5');
  String get secQ6 => _s('secQ6');

  String get clearSelection => _s('clearSelection');
  String get lockInPrivateFolder => _s('lockInPrivateFolder');
  String get movingToPrivate => _s('movingToPrivate');
  String get deletingFiles => _s('deletingFiles');
  String get noVideosToLock => _s('noVideosToLock');
  String get videosQueued => _s('videosQueued');
  String get deleteFoldersTitle => _s('deleteFoldersTitle');
  String deleteFoldersBody() => _s('deleteFoldersBody');
  String lockFoldersBody() => _s('lockFoldersBody');

  String get propSectionFile => _s('propSectionFile');
  String get propSectionMedia => _s('propSectionMedia');
  String get propSectionPlayback => _s('propSectionPlayback');
  String get propFile => _s('propFile');
  String get propLocation => _s('propLocation');
  String get propSize => _s('propSize');
  String get propDate => _s('propDate');
  String get propFormat => _s('propFormat');
  String get propResolution => _s('propResolution');
  String get propLength => _s('propLength');
  String get propBitrate => _s('propBitrate');
  String get propFinished => _s('propFinished');
  String get propFinishedYes => _s('propFinishedYes');
  String get propFinishedNo => _s('propFinishedNo');
  String get propLastPosition => _s('propLastPosition');
  String get okay => _s('okay');

  String get cancelling => _s('cancelling');

  // ── v1.49 Private Folder: security + keypad + progress ──
  String get setupPinConfirmHint => _s('setupPinConfirmHint');
  String get pinSetFailed => _s('pinSetFailed');
  String get changePinCurrentHint => _s('changePinCurrentHint');
  String get changePinNewHint => _s('changePinNewHint');
  String get changePinConfirmHint => _s('changePinConfirmHint');
  String get changePinFailed => _s('changePinFailed');
  String get vaultTemporarilyLocked => _s('vaultTemporarilyLocked');
  String get decoyPinEntryHint => _s('decoyPinEntryHint');
  String get decoyPinConfirmHint => _s('decoyPinConfirmHint');
  String get vaultProgressSafeNote => _s('vaultProgressSafeNote');
  String get lockingFiles => _s('lockingFiles');
  String get notEnoughSpace => _s('notEnoughSpace');
  String get unlockingFiles => _s('unlockingFiles');
  String get importCancelled => _s('importCancelled');
  String get recoveryLockedOut => _s('recoveryLockedOut');
  String get autoLock => _s('autoLock');
  String get autoLockDesc => _s('autoLockDesc');
  String get autoLockImmediately => _s('autoLockImmediately');
  String get screenCaptureBlocked => _s('screenCaptureBlocked');
  String get screenCaptureBlockedDesc => _s('screenCaptureBlockedDesc');
  String get loadingMore => _s('loadingMore');
  String get clearAll => _s('clearAll');
  String vaultProgressCount(int i, int n) => locale.languageCode == 'my'
      ? 'ဖိုင် $i / $n'
      : locale.languageCode == 'th'
          ? 'ไฟล์ $i จาก $n'
          : 'File $i of $n';
  String autoLockAfterSeconds(int n) => locale.languageCode == 'my'
      ? '$n စက္ကန့် အကြာ'
      : locale.languageCode == 'th'
          ? 'หลังจาก $n วินาที'
          : 'After $n seconds';
  String autoLockAfterMinutes(int n) => locale.languageCode == 'my'
      ? '$n မိနစ် အကြာ'
      : locale.languageCode == 'th'
          ? 'หลังจาก $n นาที'
          : 'After $n minutes';


  // --- Video Hub (remote movie / series / reels vertical) ---
  String get vhVideoChip => _s('vhVideoChip');
  String get vhSearchHint => _s('vhSearchHint');
  String get vhCategoryAll => _s('vhCategoryAll');
  String get vhCategoryMovies => _s('vhCategoryMovies');
  String get vhCategorySeries => _s('vhCategorySeries');
  String get vhCategoryReels => _s('vhCategoryReels');
  String get vhMore => _s('vhMore');
  String get vhRowTrending => _s('vhRowTrending');
  String get vhRowNewReleases => _s('vhRowNewReleases');
  String get vhFilterGenre => _s('vhFilterGenre');
  String get vhFilterYear => _s('vhFilterYear');
  String get vhFilterQuality => _s('vhFilterQuality');
  String get vhFilterSort => _s('vhFilterSort');
  String get vhFilterClear => _s('vhFilterClear');
  String get vhFilterAny => _s('vhFilterAny');
  String get vhSortNewest => _s('vhSortNewest');
  String get vhSortTitle => _s('vhSortTitle');
  String get vhNoContent => _s('vhNoContent');
  String get vhNoMatchingContent => _s('vhNoMatchingContent');
  String get vhLoadFailed => _s('vhLoadFailed');
  String get vhOfflineBanner => _s('vhOfflineBanner');
  String get vhOfflineNothingSaved => _s('vhOfflineNothingSaved');
  String get vhOfflineHint => _s('vhOfflineHint');
  String get vhOfflineNotHeld => _s('vhOfflineNotHeld');
  String get vhBatteryDozeTitle => _s('vhBatteryDozeTitle');
  String vhBatteryDozeBody(String maker) =>
      _s('vhBatteryDozeBody').replaceAll('{maker}', maker);
  String get vhBatteryAllow => _s('vhBatteryAllow');
  String get vhBatteryBlockedTitle => _s('vhBatteryBlockedTitle');
  String get vhBatteryBlockedBody => _s('vhBatteryBlockedBody');
  String get vhBatteryOpenSettings => _s('vhBatteryOpenSettings');
  String get vhOfflineReplayPartial => _s('vhOfflineReplayPartial');
  String get vhOfflineReplayNotEnough => _s('vhOfflineReplayNotEnough');
  String get vhOfflineReplayWholeFileOnly => _s('vhOfflineReplayWholeFileOnly');
  String get vhRetry => _s('vhRetry');
  String get vhSearchPrompt => _s('vhSearchPrompt');
  String get vhSearchNoResults => _s('vhSearchNoResults');
  String get vhAlbum => _s('vhAlbum');
  String get vhPlay => _s('vhPlay');
  String get vhUnavailable => _s('vhUnavailable');
  String get vhWrongDevice => _s('vhWrongDevice');


  // --- Video Hub: see-all / ranked rows ---
  String get vhSeeAll => _s('vhSeeAll');
  String get vhSortPopular => _s('vhSortPopular');
  String vhTitlesCount(Object n) =>
      _s('vhTitlesCount').replaceFirst('{n}', '$n');


  // --- Video Hub: filter toolbar / hero ---
  String get vhFilters => _s('vhFilters');
  String get vhClearAll => _s('vhClearAll');
  String get vhMoreInfo => _s('vhMoreInfo');
  String vhShowResults(Object n) =>
      _s('vhShowResults').replaceFirst('{n}', '$n');
  String vhEpisodesCount(Object n) =>
      _s('vhEpisodesCount').replaceFirst('{n}', '$n');


  // --- Video Hub: premium / paywall ---
  String get vhPaywallTitle => _s('vhPaywallTitle');
  String get vhPaywallGeneric => _s('vhPaywallGeneric');
  String get vhPerkPlay => _s('vhPerkPlay');
  String get vhPerkMedia => _s('vhPerkMedia');
  String get vhPerkQuality => _s('vhPerkQuality');
  String get vhPlanYearly => _s('vhPlanYearly');
  String get vhPlanYearlyNote => _s('vhPlanYearlyNote');
  String get vhPlanMonthly => _s('vhPlanMonthly');
  String get vhPaywallFinePrint => _s('vhPaywallFinePrint');
  String get vhPaywallNotNow => _s('vhPaywallNotNow');
  String get vhPremiumBadge => _s('vhPremiumBadge');
  String get vhLockedItem => _s('vhLockedItem');
  String get vhFreePreview => _s('vhFreePreview');
  String get vhPremiumActive => _s('vhPremiumActive');
  String get vhUpgrade => _s('vhUpgrade');
  String vhPaywallLockedCount(Object n) =>
      _s('vhPaywallLockedCount').replaceFirst('{n}', '$n');
  String vhPaywallForTitle(Object n) =>
      _s('vhPaywallForTitle').replaceFirst('{n}', '$n');
  String vhLockedCountShort(Object n) =>
      _s('vhLockedCountShort').replaceFirst('{n}', '$n');


  // --- Video Hub: account / KPay payment ---
  String get vhSignInTitle => _s('vhSignInTitle');
  String get vhSignInWhy => _s('vhSignInWhy');
  String get vhSignInPhoneHint => _s('vhSignInPhoneHint');
  String get vhSignInCodeHint => _s('vhSignInCodeHint');
  String get vhSignInSendCode => _s('vhSignInSendCode');
  String get vhSignInVerify => _s('vhSignInVerify');
  String get vhSignInBadPhone => _s('vhSignInBadPhone');
  String get vhSignInBadCode => _s('vhSignInBadCode');
  String get vhSignInSendFailed => _s('vhSignInSendFailed');
  String get vhSignInNoConnection => _s('vhSignInNoConnection');
  String get vhSignOut => _s('vhSignOut');
  String get vhAccountTitle => _s('vhAccountTitle');
  String get vhAccountFreePlan => _s('vhAccountFreePlan');
  String get vhAccountRequests => _s('vhAccountRequests');
  String get vhRequestPending => _s('vhRequestPending');
  String get vhRequestApproved => _s('vhRequestApproved');
  String get vhRequestRejected => _s('vhRequestRejected');
  String get vhDevApprove => _s('vhDevApprove');
  String get vhPayTitle => _s('vhPayTitle');
  String get vhPayStep1 => _s('vhPayStep1');
  String get vhPayStep2 => _s('vhPayStep2');
  String get vhPayStep3 => _s('vhPayStep3');
  String get vhPayStep4 => _s('vhPayStep4');
  String get vhPayNoteHint => _s('vhPayNoteHint');
  String get vhPayPrivate => _s('vhPayPrivate');
  String get vhPayNextTitle => _s('vhPayNextTitle');
  String get vhPayNext1 => _s('vhPayNext1');
  String get vhPayNext2 => _s('vhPayNext2');
  String get vhPayNext3 => _s('vhPayNext3');
  String get vhRequestYouWrote => _s('vhRequestYouWrote');
  String get vhRequestReply => _s('vhRequestReply');
  String get vhPayPayee => _s('vhPayPayee');
  String get vhPayNumber => _s('vhPayNumber');
  String get vhPayAmount => _s('vhPayAmount');
  String get vhPayCopied => _s('vhPayCopied');
  String get vhPayReferenceHint => _s('vhPayReferenceHint');
  String get vhPaySenderHint => _s('vhPaySenderHint');
  String get vhPaySubmit => _s('vhPaySubmit');
  String get vhPayManualNote => _s('vhPayManualNote');
  String get vhPayOpenKpay => _s('vhPayOpenKpay');
  String get vhPayNoKpay => _s('vhPayNoKpay');
  String get vhPayRecentShots => _s('vhPayRecentShots');
  String get vhPayChooseShot => _s('vhPayChooseShot');
  String get aboutTagline => _s('aboutTagline');
  String aboutVersionFull(String v, String b) =>
      _s('aboutVersionFull').replaceFirst('{v}', v).replaceFirst('{b}', b);
  String get aboutCopied => _s('aboutCopied');
  String get aboutCopyHint => _s('aboutCopyHint');
  String get aboutSectionApp => _s('aboutSectionApp');
  String get aboutSectionSupport => _s('aboutSectionSupport');
  String get aboutSoftwareUpdate => _s('aboutSoftwareUpdate');
  String get aboutUpToDate => _s('aboutUpToDate');
  String get aboutUpdateReady => _s('aboutUpdateReady');
  String get aboutWhatsNew => _s('aboutWhatsNew');
  String aboutWhatsNewIn(String v) =>
      _s('aboutWhatsNewIn').replaceFirst('{v}', v);
  String get aboutHelpFaq => _s('aboutHelpFaq');
  String get aboutRights => _s('aboutRights');
  String get vhPayShotAttached => _s('vhPayShotAttached');
  String get vhPayShotCheck => _s('vhPayShotCheck');
  String get vhPayShotChange => _s('vhPayShotChange');
  String get vhPayAddTxn => _s('vhPayAddTxn');
  String get vhPayNeedProof => _s('vhPayNeedProof');
  String get vhPayTooMany => _s('vhPayTooMany');
  String get vhPayBadImage => _s('vhPayBadImage');
  String get vhPaySubmitFailed => _s('vhPaySubmitFailed');
  String get vhPayDetailsStale => _s('vhPayDetailsStale');
  String get vhPayDetailsUnavailable => _s('vhPayDetailsUnavailable');
  String get vhPayQueuedTitle => _s('vhPayQueuedTitle');
  String get vhPayQueuedBody => _s('vhPayQueuedBody');
  String get vhPayDone => _s('vhPayDone');
  String vhSignInDevCode(Object n) =>
      _s('vhSignInDevCode').replaceFirst('{n}', '$n');
  String vhAccountExpires(Object n) =>
      _s('vhAccountExpires').replaceFirst('{n}', '$n');


  // --- Video Hub: view counts ---
  String vhViewsCount(Object n) =>
      _s('vhViewsCount').replaceFirst('{n}', '$n');


  // --- Video Hub: age gate / library ---
  String get vhGateTitle => _s('vhGateTitle');
  String get vhGateLead => _s('vhGateLead');
  String get vhGateTermsHeading => _s('vhGateTermsHeading');
  String get vhGateTerm1 => _s('vhGateTerm1');
  String get vhGateTerm2 => _s('vhGateTerm2');
  String get vhGateTerm3 => _s('vhGateTerm3');
  String get vhGateTerm4 => _s('vhGateTerm4');
  String get vhGateTerm5 => _s('vhGateTerm5');
  String get vhGateTerm6 => _s('vhGateTerm6');
  String get vhGateEnter => _s('vhGateEnter');
  String get vhGateLeave => _s('vhGateLeave');
  String get vhGateBlockedTitle => _s('vhGateBlockedTitle');
  String get vhGateBlockedBody => _s('vhGateBlockedBody');
  String get vhGateMistake => _s('vhGateMistake');
  String get destinationNoneAvailable => _s('destinationNoneAvailable');
  String get noPlaylistsHint => _s('noPlaylistsHint');
  String confirmBinBody(Object n) =>
      _s('confirmBinBody').replaceFirst('{n}', '$n');
  String confirmLockBody(Object n) =>
      _s('confirmLockBody').replaceFirst('{n}', '$n');
  String movedToBin(Object n) =>
      _s('movedToBin').replaceFirst('{n}', '$n');
  String lockedCount(Object n) =>
      _s('lockedCount').replaceFirst('{n}', '$n');
  String addedToPlaylist(Object n, Object name) => _s('addedToPlaylist')
      .replaceFirst('{n}', '$n')
      .replaceFirst('{name}', '$name');
  String get shareFailed => _s('shareFailed');
  String get renamedOk => _s('renamedOk');
  String get deletedOk => _s('deletedOk');
  String get lockingNow => _s('lockingNow');
  String get movedToPrivate => _s('movedToPrivate');
  String get searchNoMatches => _s('searchNoMatches');
  String get search => _s('search');
  String get pickerShowHidden => _s('pickerShowHidden');
  String get pickerHideHidden => _s('pickerHideHidden');
  String get size => _s('size');
  String get duration => _s('duration');
  String get videos => _s('videos');
  String get folders => _s('folders');
  String get setPinFirst => _s('setPinFirst');
  String get connectAdbToSend => _s('connectAdbToSend');
  String get adbStepsTitle => _s('adbStepsTitle');
  String get adbStepDevOptions => _s('adbStepDevOptions');
  String get adbStepWifi => _s('adbStepWifi');
  String get adbStepWireless => _s('adbStepWireless');
  String get adbStepNotifications => _s('adbStepNotifications');
  String get adbStepPaired => _s('adbStepPaired');
  String get adbStepConnected => _s('adbStepConnected');
  String get adbStepOpen => _s('adbStepOpen');
  String get adbStepHow => _s('adbStepHow');
  String get adbWifiNeeded => _s('adbWifiNeeded');
  String get adbTipXiaomi => _s('adbTipXiaomi');
  String get adbTipOppo => _s('adbTipOppo');
  String get adbTipTranssion => _s('adbTipTranssion');
  String get adbNotSupported => _s('adbNotSupported');
  String get hfTitle => _s('hfTitle');
  String get hfHint => _s('hfHint');
  String get hfSettingsSub => _s('hfSettingsSub');
  String get hfApps => _s('hfApps');
  String get hfQuick => _s('hfQuick');
  String get hfAll => _s('hfAll');
  String get hfVideos => _s('hfVideos');
  String get hfPhotos => _s('hfPhotos');
  String get hfAudio => _s('hfAudio');
  String get hfDocs => _s('hfDocs');
  String get hfEmpty => _s('hfEmpty');
  String get hfSend => _s('hfSend');
  String get hfFetching => _s('hfFetching');
  String get hfNoApp => _s('hfNoApp');
  String get hfPullFailed => _s('hfPullFailed');
  String hfFileOf(int i, int n) =>
      _s('hfFileOf').replaceAll('{i}', '$i').replaceAll('{n}', '$n');
  String get hiddenBadge => _s('hiddenBadge');
  String get hfInApps => _s('hfInApps');
  String get hfBucketPhotos => _s('hfBucketPhotos');
  String get hfBucketAudio => _s('hfBucketAudio');
  String hfSkipped(int n) => _s('hfSkipped').replaceAll('{n}', '$n');
  String get hfConnectTitle => _s('hfConnectTitle');
  String get hfConnectBody => _s('hfConnectBody');
  String get hfOpenAdb => _s('hfOpenAdb');
  String get hfNotNow => _s('hfNotNow');
  String get hfLive => _s('hfLive');
  String get adbScreenTitle => _s('adbScreenTitle');
  String get adbHeroConnected => _s('adbHeroConnected');
  String get adbHeroConnectedSub => _s('adbHeroConnectedSub');
  String get adbHeroOff => _s('adbHeroOff');
  String get adbHeroOffSub => _s('adbHeroOffSub');
  String get adbHeroNew => _s('adbHeroNew');
  String get adbHeroNewSub => _s('adbHeroNewSub');
  String get adbHeroChecking => _s('adbHeroChecking');
  String get adbReconnect => _s('adbReconnect');
  String get adbCopyReport => _s('adbCopyReport');
  String get adbSendReport => _s('adbSendReport');
  String get adbClearLog => _s('adbClearLog');
  String get adbReportCopied => _s('adbReportCopied');
  String get adbReportSent => _s('adbReportSent');
  String get adbReportFailed => _s('adbReportFailed');
  String get adbReportCopyCode => _s('adbReportCopyCode');
  String get adbReconnecting => _s('adbReconnecting');
  String get adbPairedAlready => _s('adbPairedAlready');
  String get adbPairAgain => _s('adbPairAgain');
  String get adbOpenWireless => _s('adbOpenWireless');
  String get adbFindVideos => _s('adbFindVideos');
  String get adbPairTitle => _s('adbPairTitle');
  String get adbPairNotif => _s('adbPairNotif');
  String get adbPairNotifSub => _s('adbPairNotifSub');
  String get adbPairWaiting => _s('adbPairWaiting');
  String get adbPairInApp => _s('adbPairInApp');
  String get adbPairCodeLabel => _s('adbPairCodeLabel');
  String get adbPairConnect => _s('adbPairConnect');
  String get adbConnect => _s('adbConnect');
  String get adbStayTitle => _s('adbStayTitle');
  String get adbStayWifi => _s('adbStayWifi');
  String get adbStayBackground => _s('adbStayBackground');
  String get adbStayTile => _s('adbStayTile');
  String get adbStayBattery => _s('adbStayBattery');
  String get adbGuideTitle => _s('adbGuideTitle');
  String get adbGuideOnTitle => _s('adbGuideOnTitle');
  String get adbGuideOn1 => _s('adbGuideOn1');
  String get adbGuideOn2 => _s('adbGuideOn2');
  String get adbGuideOn3 => _s('adbGuideOn3');
  String get adbGuideOffTitle => _s('adbGuideOffTitle');
  String get adbGuideOff1 => _s('adbGuideOff1');
  String get adbGuideOff2 => _s('adbGuideOff2');
  String get adbGuideSafety => _s('adbGuideSafety');
  String get adbGuideWhereTitle => _s('adbGuideWhereTitle');
  String get adbGuideWhere => _s('adbGuideWhere');
  String get adbAdvanced => _s('adbAdvanced');
  String get adbDetails => _s('adbDetails');
  String get adbAndroidDataTitle => _s('adbAndroidDataTitle');
  String get adbAndroidDataSub => _s('adbAndroidDataSub');
  String get adbLostTitle => _s('adbLostTitle');
  String get adbLostBody => _s('adbLostBody');
  String get adbLostAction => _s('adbLostAction');
  String adbFound(int n) => _s('adbFound').replaceAll('{n}', '$n');
  String get destinationIfExists => _s('destinationIfExists');
  String get destinationKeepBoth => _s('destinationKeepBoth');
  String get destinationSkip => _s('destinationSkip');
  String get destinationOverwrite => _s('destinationOverwrite');
  String get selectionMove => _s('selectionMove');
  String get selectionCopy => _s('selectionCopy');
  String get selectionSelectAll => _s('selectionSelectAll');
  String get selectionDeselectAll => _s('selectionDeselectAll');
  String get selectionMoveTitle => _s('selectionMoveTitle');
  String get selectionCopyTitle => _s('selectionCopyTitle');
  String get selectionEditingOff => _s('selectionEditingOff');
  String get selectionNoFiles => _s('selectionNoFiles');
  String get selectionWorking => _s('selectionWorking');
  String get selectionMoved => _s('selectionMoved');
  String get selectionCopied => _s('selectionCopied');
  String get selectionRebuilt => _s('selectionRebuilt');
  String get selectionHidden => _s('selectionHidden');
  String get vhGateMistakeConfirmTitle => _s('vhGateMistakeConfirmTitle');
  String get vhGateMistakeConfirmBody => _s('vhGateMistakeConfirmBody');
  String get vhGateMistakeConfirmYes => _s('vhGateMistakeConfirmYes');
  String get vhSignInGoogle => _s('vhSignInGoogle');
  String get vhSignInGoogleSoon => _s('vhSignInGoogleSoon');
  String get vhSignInGoogleFailed => _s('vhSignInGoogleFailed');
  String get vhSignInOr => _s('vhSignInOr');
  String get vhLibraryBookmarks => _s('vhLibraryBookmarks');
  String get vhLibraryBookmarksHint => _s('vhLibraryBookmarksHint');
  String get vhSaverModeAll => _s('vhSaverModeAll');
  String get vhSaverModeAllHint => _s('vhSaverModeAllHint');
  String get vhSaverModeMobile => _s('vhSaverModeMobile');
  String get vhSaverModeMobileHint => _s('vhSaverModeMobileHint');
  String vhSaverNowOn(String conn) => _s('vhSaverNowOn').replaceFirst('{conn}', conn);
  String vhSaverNowOff(String conn) => _s('vhSaverNowOff').replaceFirst('{conn}', conn);
  String get vhConnWifi => _s('vhConnWifi');
  String get vhConnMobile => _s('vhConnMobile');
  String get vhConnOffline => _s('vhConnOffline');
  String get vhConnOther => _s('vhConnOther');
  String get vhSaverBanner => _s('vhSaverBanner');
  String get vhSaverTurnOff => _s('vhSaverTurnOff');
  String get vhSaverHowTitle => _s('vhSaverHowTitle');
  String get vhSaverHow1 => _s('vhSaverHow1');
  String get vhSaverHow2 => _s('vhSaverHow2');
  String get vhSaverHow3 => _s('vhSaverHow3');
  String get vhSaverHow4 => _s('vhSaverHow4');
  String get vhLibraryDataSaverHint => _s('vhLibraryDataSaverHint');
  String get vhBookmark => _s('vhBookmark');
  String get vhBookmarked => _s('vhBookmarked');
  String get vhBookmarkAdded => _s('vhBookmarkAdded');
  String get vhBookmarkRemoved => _s('vhBookmarkRemoved');
  String get vhUndo => _s('vhUndo');
  String get vhBookmarksEmpty => _s('vhBookmarksEmpty');
  String get vhBookmarksSignInHint => _s('vhBookmarksSignInHint');
  String get vhOn => _s('vhOn');
  String get vhEdit => _s('vhEdit');
  String get vhDownloadsActive => _s('vhDownloadsActive');
  String get vhDownloadYielding => _s('vhDownloadYielding');
  String get vhDownloadsDone => _s('vhDownloadsDone');
  String get vhDownloadsSettings => _s('vhDownloadsSettings');
  String vhBookmarksCount(int n) => _s('vhBookmarksCount').replaceFirst('{n}', '$n');
  String get vhLibraryDownloads => _s('vhLibraryDownloads');
  String get vhDeleteDownloadBody => _s('vhDeleteDownloadBody');
  String get vhDiscardDownloadBody => _s('vhDiscardDownloadBody');
  String get vhDownloadUnfinished => _s('vhDownloadUnfinished');
  String get vhDownloadQueued => _s('vhDownloadQueued');
  String get vhDownloadPaused => _s('vhDownloadPaused');
  String get vhDownloadResuming => _s('vhDownloadResuming');
  String get vhDownloadResume => _s('vhDownloadResume');
  String get vhDownloadPause => _s('vhDownloadPause');
  String get vhWatchNow => _s('vhWatchNow');
  String get vhWatchNotYet => _s('vhWatchNotYet');
  String get vhWatchIndexAtEnd => _s('vhWatchIndexAtEnd');
  String get vhWatchGone => _s('vhWatchGone');
  String get vhDownloadNoSpace => _s('vhDownloadNoSpace');
  String get vhDownloadGaveUp => _s('vhDownloadGaveUp');
  String get vhDownloadWaitingSignal => _s('vhDownloadWaitingSignal');
  String get vhDownloadReadyOffline => _s('vhDownloadReadyOffline');
  String get vhDownloadWifiOnly => _s('vhDownloadWifiOnly');
  String get vhDownloadWifiOnlyHint => _s('vhDownloadWifiOnlyHint');
  String get vhDownloadWifiOnlyBlocked => _s('vhDownloadWifiOnlyBlocked');
  String get vhDownloadOnMobile => _s('vhDownloadOnMobile');
  String get vhDownloadWillResume => _s('vhDownloadWillResume');

  /// "This film is {size}. You have {free} free." — shown BEFORE a byte of a
  /// metered connection is spent, which is the whole point of it.
  String vhDownloadSizeAsk(Object size, Object free) => _s('vhDownloadSizeAsk')
      .replaceFirst('{size}', '$size')
      .replaceFirst('{free}', '$free');
  String get vhDownloadStart => _s('vhDownloadStart');
  String get vhDlQualityTitle => _s('vhDlQualityTitle');
  String get vhDlQualityOriginal => _s('vhDlQualityOriginal');
  String get vhDlQualityRemember => _s('vhDlQualityRemember');
  String vhDlQualityFree(Object free) =>
      _s('vhDlQualityFree').replaceFirst('{free}', '$free');
  String get vhDlQualityHint => _s('vhDlQualityHint');
  String get vhDlQualityAsk => _s('vhDlQualityAsk');
  String get vhDownloadStorageLine => _s('vhDownloadStorageLine');

  /// "11 min left", built from unit words rather than from a format string, so
  /// Burmese reads as Burmese and not as English with the numbers swapped.
  ///
  /// THE NUMBER PEOPLE ACTUALLY WANT. A download shows how many megabytes have
  /// arrived, which is a fact about the file; how long is left is the answer to
  /// "can I watch this tonight", which is the question. Telegram — what this
  /// audience already uses for films — shows it, and it is most of why its
  /// downloads feel manageable on a bad line.
  String vhDownloadLeft(Duration d) {
    if (d.inMinutes < 1) return _s('vhDownloadLeftSoon');
    if (d.inHours < 1) {
      return _s('vhDownloadLeftMinutes').replaceFirst('{m}', '${d.inMinutes}');
    }
    // Beyond a day the estimate is not information, it is a warning.
    if (d.inHours >= 24) return _s('vhDownloadLeftAges');
    return _s('vhDownloadLeftHours')
        .replaceFirst('{h}', '${d.inHours}')
        .replaceFirst('{m}', '${d.inMinutes % 60}');
  }
  String vhDownloadStorage(Object used, Object free) =>
      _s('vhDownloadStorage')
          .replaceFirst('{used}', '$used')
          .replaceFirst('{free}', '$free');
  String get vhLibraryDownloadsHint => _s('vhLibraryDownloadsHint');
  String get vhLibrarySoon => _s('vhLibrarySoon');

  static const Map<String, Map<String, String>> _byLocale =
      <String, Map<String, String>>{
    'en': _en,
    'my': _my,
    'th': _th,
  };

  static const Map<String, String> _en = <String, String>{
    'trSharingNow': 'Sharing {n} file(s) — tap to see',
    'trSharingComputer': 'Sharing with a computer — tap to see',
    'trViaWifi': 'Over your Wi-Fi',
    'trReceivingNow': 'Receiving — tap to see',
    'trConnectedTo': 'Connected — tap to see',
    'trResumeReceiving': 'A download stopped part-way — tap to resume',
    'trShareWith': 'Share with',
    'trPc': 'PC',
    'trTablet': 'Tablet',
    'trSendAppShort': 'Give a friend the app — no internet needed',
    'trTurboOnShort': 'On — phone to phone, no router. Fastest.',
    'trTurboOffShort': 'Off — sends through your Wi-Fi router',
    'trSettings': 'Transfer settings',
    'trHistoryEmpty': 'Files you receive appear here.',
    'trPcTitle': 'Share with a computer, iPhone or tablet',
    'trPcLead': 'Nothing to install on the other side — just a web browser. Download from this phone, or drop files to send them to it.',
    'trPcStep1Turbo': 'On the computer or iPhone, join this Wi-Fi — or scan the code with its camera',
    'trPcStep1Wifi': 'Put the computer or iPhone on the same Wi-Fi as this phone',
    'trPcStep2': 'Open this address in its browser',
    'trPcStep3': 'Download files, or drop files on the page to send them here',
    'trPcConnected': '{n} connected',
    'trPcSharingFiles': 'Sharing {n} file(s) from this phone',
    'trPcStart': 'Start',
    'trScanTitle': 'Scan the sender\'s QR code',
    'trScanBody': 'On the other phone, tap Send — a QR code appears. Scan it and the two phones connect directly.',
    'trSendTitle': 'Send',
    'trReceiveTitle': 'Receive',
    'subSecColor': 'Color',
    'subSecBorder': 'Border',
    'subSecAppearance': 'Appearance',
    'sizeTiny': 'Tiny',
    'sizeSmall': 'Small',
    'sizeMedium': 'Medium',
    'sizeLarge': 'Large',
    'sizeHuge': 'Huge',
    'colourWhite': 'White',
    'colourYellow': 'Yellow',
    'colourCyan': 'Cyan',
    'colourGreen': 'Green',
    'colourRed': 'Red',
    'colourBlack': 'Black',
    'borderNone': 'None',
    'borderOutline': 'Outline',
    'borderDropShadow': 'Drop shadow',
    'borderRaised': 'Raised',
    'borderDepressed': 'Depressed',
    'shadowSubtle': 'Subtle',
    'shadowDefault': 'Default',
    'shadowStrong': 'Strong',
    'bgTransparent': 'Transparent',
    'bgTranslucent': 'Translucent',
    'bgOpaque': 'Opaque',
    'alignLeft': 'Left',
    'alignCenter': 'Center',
    'alignRight': 'Right',
    'subImproveStrokeDesc': 'Render subtitle stroke at higher quality. Slightly more CPU.',
    // Subtitle Text / Subtitle Layout screens.
    'subFont': 'Font',
    'subFontDefault': 'Default',
    'subFontSansSerif': 'Sans-serif',
    'subFontSerif': 'Serif',
    'subFontMonospace': 'Monospace',
    'subFontCustomEnter': 'Custom (enter name)…',
    'subFontCustom': 'Custom Font',
    'subFontCustomHint': 'Enter the font family name as installed on the device, or a full path to a .ttf / .otf file.',
    'subSize': 'Size',
    'subFontSize': 'Font Size',
    'subBold': 'Bold',
    'subBoldDesc': 'Use bold text for subtitles.',
    'subTextColor': 'Text color',
    'subTextColorTitle': 'Text Color',
    'subBorderStyle': 'Border style',
    'subBorderStyleTitle': 'Border Style',
    'subBorderColor': 'Border color',
    'subBorderColorTitle': 'Border Color',
    'subScale': 'Scale',
    'subScaleTitle': 'Subtitle Scale',
    'subShadow': 'Shadow',
    'subBackground': 'Background',
    'subBackgroundColor': 'Background Color',
    'subAlignment': 'Alignment',
    'subTextAlignment': 'Text Alignment',
    'subBottomMargins': 'Bottom margins',
    'subBottomMarginsTitle': 'Bottom Margins',
    'subImproveStroke': 'Improve stroke rendering',
    'subVerticalPos': 'Vertical position',
    'subVerticalPosTitle': 'Vertical Position',
    'subVerticalPosDesc': 'Distance from the top, as a percentage.',
    'subHorizontalAlign': 'Horizontal alignment',
    'subHorizontalAlignTitle': 'Horizontal Alignment',
    'subSidePadding': 'Left/Right padding',
    'subSidePaddingTitle': 'Left/Right Padding',
    'subSidePaddingDesc': 'Pixels of horizontal margin.',
    'subBottomMargin': 'Bottom margin',
    'subBottomMarginTitle': 'Bottom Margin',
    'subBottomMarginDesc': 'Pixels of bottom margin.',
    'subShowBackground': 'Show background',
    'subBgBlack50': 'Black (50% opacity)',
    'subBgBlack75': 'Black (75% opacity)',
    'subBgDarkGray': 'Dark gray',
    'subBgColorActiveWhen': 'Active only when "Show background" is on.',
    'currently': 'Currently',

    // --- Video Hub: age gate / library ---
    'vhGateTitle': 'This is an adult site',
    'vhGateLead': 'Everything inside is intended for adults only. Please confirm before you continue.',
    'vhGateTermsHeading': 'By entering, you confirm that',
    'vhGateTerm1': 'You are at least 18 years old, or the legal age of majority where you live - whichever is higher.',
    'vhGateTerm2': 'You are entering of your own free will. Nobody has sent, asked or pressured you to open this app, and you are not doing so on behalf of anyone else.',
    'vhGateTerm3': 'Adult material is lawful for you to view where you are, and you accept responsibility for knowing that.',
    'vhGateTerm4': 'You will not show this content to anyone under 18, and you will not leave the app open where a minor can reach it.',
    'vhGateTerm5': 'You will not copy, record, re-upload or redistribute anything from the app. All content is licensed and remains the property of its rights holders.',
    'vhGateTerm6': 'You will not treat anything here as a depiction of real events, and you accept that all performers are adults who consented to the recording.',
    'vhGateEnter': 'I am 18 or older - Enter',
    'vhGateLeave': 'I am under 18 - Leave',
    'vhGateBlockedTitle': 'Please come back when you are older',
    'vhGateBlockedBody': 'This app is for adults only, so it will not open. Nothing is wrong with your phone. We would rather turn away a hundred people than let one child in.',
    'vhGateMistake': 'I tapped that by mistake',
    'destinationNoneAvailable': 'No other folder to move into.',
    'noPlaylistsHint': 'No playlists yet. Create one from Me → Video Playlists.',
    'confirmBinBody': 'Move {n} to the Recycle Bin? You can restore them from Me.',
    'confirmLockBody': 'Move {n} into the Private Folder? They will be removed from your library and other lists.',
    'movedToBin': '{n} moved to the Recycle Bin',
    'lockedCount': '{n} moved to the Private Folder',
    'addedToPlaylist': '{n} added to “{name}”',
    'renamedOk': 'Renamed',
    'deletedOk': 'Deleted',
    'lockingNow': 'Moving to the Private Folder…',
    'movedToPrivate': 'Moved to the Private Folder',
    'searchNoMatches': 'Nothing matches that search',
    'search': 'Search',
    'pickerShowHidden': 'Show hidden folders',
    'pickerHideHidden': 'Hide hidden folders',
    'size': 'Size',
    'duration': 'Duration',
    'videos': 'Videos',
    'folders': 'Folders',
    'setPinFirst': 'Set up a Private Folder PIN first (Me → Private Folder)',
    'connectAdbToSend': 'Connect ADB to send Android/data videos',
    'adbStepsTitle': 'Setup — where you are',
    'adbStepDevOptions': 'Developer options on',
    'adbStepWifi': 'On Wi-Fi (no internet needed)',
    'adbStepWireless': 'Wireless debugging on',
    'adbStepNotifications': 'Notifications allowed — the code is typed into one',
    'adbStepPaired': 'Paired',
    'adbStepConnected': 'Connected',
    'adbStepOpen': 'Open',
    'adbStepHow': 'How',
    'adbWifiNeeded': 'Wireless debugging only works on a Wi-Fi network. Any Wi-Fi will do — it doesn\'t need internet.',
    'adbTipXiaomi': 'Xiaomi, Redmi and POCO: for “Stay connected after a reboot”, also turn on “USB debugging (Security settings)” in Developer options — it asks for a SIM card and a Mi account. If the notification has no reply box, pull it down to expand it.',
    'adbTipOppo': 'OPPO, realme and OnePlus: if pairing works but connecting stalls, turn Wireless debugging off and on again, then tap Connect.',
    'adbTipTranssion': 'TECNO, Infinix and itel: let Innocent run in the background (battery settings or Phone Master), or the pairing notification can be closed before you type the code.',
    'adbNotSupported': 'Wireless debugging needs Android 11 or newer.',
    'hfTitle': 'Hidden files',
    'hfHint': 'Telegram and other apps’ files',
    'hfSettingsSub': 'Pair once over Wireless debugging, then open Telegram’s and other apps’ files.',
    'hfApps': 'Apps',
    'hfQuick': 'Telegram downloads',
    'hfAll': 'All',
    'hfVideos': 'Videos',
    'hfPhotos': 'Photos',
    'hfAudio': 'Audio',
    'hfDocs': 'Documents',
    'hfEmpty': 'Nothing here',
    'hfSend': 'Send with Transfer',
    'hfFetching': 'Getting it from Android/data…',
    'hfFileOf': '{i} of {n}',
    'hiddenBadge': 'Hidden',
    'hfInApps': 'Inside apps (Android/data)',
    'hfBucketPhotos': 'Telegram’s and other apps’ photos',
    'hfBucketAudio': 'Telegram’s and other apps’ audio',
    'hfSkipped': '{n} file(s) from Android/data were skipped — connect ADB and try again.',
    'hfConnectTitle': 'Connect to see inside apps',
    'hfConnectBody': 'Hidden dot-folders are showing now. Telegram’s and other apps’ folders (Android/data) open through Innocent’s ADB connection — set it up once?',
    'hfOpenAdb': 'Set up ADB',
    'hfNotNow': 'Not now',
    'hfLive': 'Connected — shown in the Video tab too',
    'hfNoApp': 'No app on this phone opens this kind of file. Share it instead?',
    'hfPullFailed': 'Could not get it from Android/data — is ADB still connected?',
    'adbScreenTitle': 'Android/data access',
    'adbHeroConnected': 'Connected',
    'adbHeroConnectedSub': 'Android/data is open to Innocent. Copies keep going in the background, and pick up where they stopped if the connection drops.',
    'adbHeroOff': 'Not connected right now',
    'adbHeroOffSub': 'Wireless debugging usually turns itself off after a restart or when the phone changes Wi-Fi. Turn it on again and tap Reconnect — no new code needed.',
    'adbHeroNew': 'Set up once — about a minute',
    'adbHeroNewSub': 'Innocent connects to this phone\'s own Wireless debugging to open Android/data — no computer, no root.',
    'adbHeroChecking': 'Checking the connection…',
    'adbReconnect': 'Reconnect',
    'adbCopyReport': 'Copy report',
    'adbSendReport': 'Send report',
    'adbClearLog': 'Clear log',
    'adbReportCopied': 'Report copied — paste it into the chat',
    'adbReportSent': 'Report sent. Quote this code:',
    'adbReportFailed': 'Could not send — copy the report instead',
    'adbReportCopyCode': 'Copy code',
    'adbReconnecting': 'Reconnecting — finding Wireless debugging’s new port…',
    'adbPairedAlready': 'This phone is paired — no new code needed. If it dropped, turn Wireless debugging on and tap Reconnect.',
    'adbPairAgain': 'Pair again',
    'adbOpenWireless': 'Open Wireless debugging',
    'adbFindVideos': 'Find videos in Android/data',
    'adbPairTitle': 'Pair this phone (first time only)',
    'adbPairNotif': 'Pair from the notification',
    'adbPairNotifSub': 'Tap this, then in Wireless debugging tap “Pair device with pairing code” and type the 6 digits into Innocent’s notification. No split screen.',
    'adbPairWaiting': 'Waiting for the code in the notification…',
    'adbPairInApp': 'Or type the code here (keep the pairing dialog visible):',
    'adbPairCodeLabel': 'Pairing code (6 digits)',
    'adbPairConnect': 'Pair & connect',
    'adbConnect': 'Connect',
    'adbStayTitle': 'Staying connected',
    'adbStayWifi': 'Stay on the same Wi-Fi. Wireless debugging belongs to the network it was turned on for — changing Wi-Fi turns it off.',
    'adbStayBackground': 'Copies run in the background with a notification, and resume from where they stopped if the connection drops.',
    'adbStayTile': 'One-tap switch: Developer options → “Quick settings developer tiles” → Wireless debugging. It then sits in your quick settings panel.',
    'adbStayBattery': 'Some phones close it to save battery. On Xiaomi, OPPO, realme, vivo, TECNO and Infinix, set Innocent’s battery use to “Unrestricted” / “No restrictions”.',
    'adbGuideTitle': 'How to turn ADB on and off',
    'adbGuideOnTitle': 'Turn on',
    'adbGuideOn1': 'Settings → About phone → tap “Build number” 7 times (enter your screen lock if asked). “Developer options” appears.',
    'adbGuideOn2': 'Developer options → “Wireless debugging” → On, and allow it on this Wi-Fi.',
    'adbGuideOn3': 'First time only: “Pair device with pairing code”, then type the 6 digits into Innocent’s notification.',
    'adbGuideOffTitle': 'Turn off when you are done',
    'adbGuideOff1': 'Developer options → “Wireless debugging” → Off (or the quick settings tile). Innocent keeps its pairing: next time just turn it on and tap Reconnect.',
    'adbGuideOff2': 'To hide Developer options again, switch off its main switch at the top. Some phones reset other developer settings when you do.',
    'adbGuideSafety': 'Wireless debugging lets a paired device control this phone. Pair only on Wi-Fi you trust, and turn it off when you finish.',
    'adbGuideWhereTitle': 'Where to find them on your phone',
    'adbGuideWhere': 'Samsung — Build number: About phone → Software information. Developer options: at the bottom of Settings.\nXiaomi / Redmi / POCO — tap “OS version” (or “MIUI version”) in About phone. Developer options: Additional settings.\nOPPO / realme / OnePlus — About device → Version → Build number. Developer options: System settings / Additional settings.\nvivo / iQOO — About phone → Software version. Developer options: System management.\nTECNO / Infinix / itel, Pixel and most others — About phone → Build number. Developer options: System.',
    'adbAdvanced': 'Advanced',
    'adbDetails': 'Details',
    'adbAndroidDataTitle': 'Videos in Android/data',
    'adbAndroidDataSub': 'Telegram and other apps keep their videos in Android/data and Android/obb. Once connected, Innocent finds them and adds them to Local.',
    'adbFound': '{n} videos found',
    'adbLostTitle': 'Android/data needs the ADB connection',
    'adbLostBody': 'The connection dropped — usually Wireless debugging turned off. Turn it on again; this folder opens by itself as soon as the connection is back.',
    'adbLostAction': 'ADB settings',
    'destinationIfExists': 'If a file with the same name is already there',
    'destinationKeepBoth': 'Keep both',
    'destinationSkip': 'Skip',
    'destinationOverwrite': 'Overwrite',
    'selectionMove': 'Move',
    'selectionCopy': 'Copy',
    'selectionSelectAll': 'Select all',
    'selectionDeselectAll': 'Deselect all',
    'selectionMoveTitle': 'Move to',
    'selectionCopyTitle': 'Copy to',
    'selectionEditingOff': 'Editing is turned off in Settings → General → Allow editing',
    'selectionNoFiles': 'These are system-managed files and cannot be moved or copied.',
    'selectionWorking': 'Working…',
    'selectionMoved': 'Moved',
    'selectionCopied': 'Copied',
    'selectionRebuilt': 'Thumbnails will rebuild as you scroll',
    'selectionHidden': 'Hidden from the library',
    'vhGateMistakeConfirmTitle': 'Ask again?',
    'vhGateMistakeConfirmBody': 'Only continue if you tapped the wrong button. You must be 18 or older to use this part of the app.',
    'vhGateMistakeConfirmYes': 'Yes, I mis-tapped',
    'vhSignInGoogle': 'Continue with Google',
    'vhSignInGoogleSoon': 'Google sign-in is not available yet. Please use your phone number.',
    'vhSignInGoogleFailed': "Couldn't finish signing in with Google. Try again in a moment.",
    'vhSignInOr': 'or',
    'vhLibraryBookmarks': 'Bookmarks',
    'vhLibraryBookmarksHint': 'Titles you saved for later',
    'vhLibraryDownloads': 'Downloads',
    'vhLibraryDownloadsHint': 'Watch offline, no connection needed',
    'vhDeleteDownloadBody':
        'Remove this download from your device? You can download it again '
        'while your subscription is active.',
    'vhDiscardDownloadBody':
        'Throw away this unfinished download? The part already on your phone '
        'will be deleted.',
    'vhDownloadUnfinished': 'Not finished yet',
    'vhDownloadQueued': 'Waiting its turn',
    'vhDownloadPaused': 'Paused',
    'vhDownloadResuming': 'Downloading',
    'vhDownloadResume': 'Resume',
    'vhDownloadPause': 'Pause',
    'vhWatchNow': 'Watch now',
    'vhWatchNotYet':
        'Not enough of this film has arrived yet. Try again in a moment.',
    'vhWatchIndexAtEnd':
        'This one can only be watched once the download has finished.',
    'vhWatchGone': 'This download is no longer on the phone.',
    'vhDownloadNoSpace':
        'Not enough space on this phone. Free some up and start again - what '
        'has already downloaded is kept.',
    'vhDownloadGaveUp':
        'The connection kept dropping. Everything downloaded so far is kept - '
        'resume it from Downloads when you have signal.',
    'vhDownloadWaitingSignal': 'Waiting for the connection…',
    'vhDownloadReadyOffline': 'Ready to watch offline',
    'vhDownloadWifiOnly': 'Download over Wi-Fi only',
    'vhDownloadWifiOnlyHint':
        'Downloads wait for Wi-Fi instead of using mobile data. Off by '
        'default, because most people here have no Wi-Fi to wait for.',
    'vhDownloadWifiOnlyBlocked':
        'Waiting for Wi-Fi. Everything downloaded so far is kept - it carries '
        'on by itself, or turn off "Wi-Fi only" to use mobile data.',
    'vhDownloadOnMobile': 'You are on mobile data.',
    'vhDownloadWillResume': 'will carry on by itself',
    'vhDownloadSizeAsk':
        'This one is {size}, downloaded at full quality. You have {free} free '
        'on this phone. Carry on?',
    'vhDownloadStart': 'Download',
    'vhDlQualityTitle': 'Download quality',
    'vhDlQualityOriginal': 'Original (best)',
    'vhDlQualityRemember': 'Remember my choice',
    'vhDlQualityFree': '{free} free on this phone',
    'vhDlQualityHint': 'Smaller copies save data and storage; the original looks best.',
    'vhDlQualityAsk': 'Ask each time',
    'vhDownloadStorageLine': 'On this phone',
    'vhDownloadLeftSoon': 'less than a minute left',
    'vhDownloadLeftMinutes': '{m} min left',
    'vhDownloadLeftHours': '{h} hr {m} min left',
    'vhDownloadLeftAges': 'more than a day left',
    'vhDownloadStorage': '{used} used - {free} free',
    'vhLibrarySoon': 'Coming soon',

    // --- Video Hub: view counts ---
    'vhViewsCount': '{n} views',

    // --- Video Hub: account / KPay payment ---
    'vhSignInTitle': 'Sign in',
    'vhSignInWhy': 'Sign in so a payment can be matched to your account. We use your number only to confirm your subscription.',
    'vhSignInPhoneHint': '09xxxxxxxxx',
    'vhSignInCodeHint': '6-digit code',
    'vhSignInSendFailed': "Couldn't send the code. Try again in a moment.",
    'vhSignInNoConnection': 'No connection. Check your internet and try again.',
    'vhSignInSendCode': 'Send code',
    'vhSignInVerify': 'Verify',
    'vhSignInBadPhone': 'Enter a valid phone number',
    'vhSignInBadCode': 'That code is not correct',
    'vhSignOut': 'Sign out',
    'vhAccountTitle': 'Account',
    'vhAccountFreePlan': 'Free plan',
    'vhAccountRequests': 'Payment requests',
    'vhRequestPending': 'Submitted - under review',
    'vhRequestApproved': 'Approved',
    'vhRequestRejected': 'Rejected',
    'vhDevApprove': 'Approve locally (development only)',
    'vhPayTitle': 'Pay with KPay',
    'vhPayStep1': 'Send the amount to this KPay account',
    'vhPayStep2': 'Pay in KPay, then take a screenshot of the receipt',
    'vhPayStep3': 'Attach the receipt screenshot',
    'vhPayStep4': 'Add a note (optional)',
    'vhPayNoteHint': 'e.g. Paid from my sister\'s KPay around 9 pm. Anything we should know.',
    'vhPayPrivate': 'Only the Innocent team sees your receipt.',
    'vhPayNextTitle': 'What happens next',
    'vhPayNext1': 'Your receipt has been received.',
    'vhPayNext2': 'We check it against the KPay statement.',
    'vhPayNext3': 'Premium turns on by itself — you will see it in Account.',
    'vhRequestYouWrote': 'You wrote',
    'vhRequestReply': 'From Innocent',
    'vhPayPayee': 'Account name',
    'vhPayNumber': 'KPay number',
    'vhPayAmount': 'Amount',
    'vhPayCopied': 'Copied',
    'vhPayReferenceHint': 'KPay transaction ID',
    'vhPaySenderHint': 'Number you paid from',
    'vhPaySubmit': 'Send for review',
    'vhPayManualNote': 'Payments are checked by hand against the KPay statement, so activation is not instant.',
    'vhPayOpenKpay': 'Open KPay',
    'vhPayNoKpay': 'KPay is not installed on this phone.',
    'vhPayRecentShots': 'Recent screenshots — tap your receipt',
    'vhPayChooseShot': 'Choose the screenshot from your photos',
    'aboutTagline': 'Your videos, beautifully played.',
    'aboutVersionFull': 'Version {v} ({b})',
    'aboutCopied': 'Version copied',
    'aboutCopyHint': 'Double tap to copy',
    'aboutSectionApp': 'App',
    'aboutSectionSupport': 'Support',
    'aboutSoftwareUpdate': 'Software update',
    'aboutUpToDate': 'Up to date',
    'aboutUpdateReady': 'A new version is ready to install',
    'aboutWhatsNew': "What's new",
    'aboutWhatsNewIn': "What's new in {v}",
    'aboutHelpFaq': 'Help & FAQ',
    'aboutRights': '© 2026 Innocent. All rights reserved.',
    'vhPayShotAttached': 'Receipt attached',
    'vhPayShotCheck': 'Check that the amount and the transaction are visible.',
    'vhPayShotChange': 'Change',
    'vhPayAddTxn': 'Add the transaction ID (optional)',
    'vhPayNeedProof': 'Attach the receipt screenshot, or enter the transaction ID.',
    'vhPayTooMany': 'You already have payments waiting to be checked. Please wait for them.',
    'vhPayBadImage': 'That file is not a picture we can read. Choose the screenshot again.',
    'vhPaySubmitFailed': 'Could not send your payment details. Nothing was recorded - check your connection and try again.',
    'vhPayDetailsStale': 'Could not reach the server. These are the details saved on this device last time - check them before you send money.',
    'vhPayDetailsUnavailable': 'Could not load the payment details. Do not send money until they appear.',
    'vhPayQueuedTitle': 'Payment submitted',
    'vhPayQueuedBody': 'We will check it against the KPay statement and activate your account. You can close the app - it stays saved.',
    'vhPayDone': 'Done',
    'vhSignInDevCode': 'Development build: use code {n}',
    'vhAccountExpires': 'Valid until {n}',

    // --- Video Hub: premium / paywall ---
    'vhPaywallTitle': 'Innocent Premium',
    'vhPaywallGeneric': 'Unlock every video, the full gallery and top quality.',
    'vhPerkPlay': 'Play every video in the catalogue',
    'vhPerkMedia': 'See every photo and clip, not just a preview',
    'vhPerkQuality': 'Highest available quality',
    'vhPlanYearly': 'Yearly',
    'vhPlanYearlyNote': 'Best value',
    'vhPlanMonthly': 'Monthly',
    'vhPaywallFinePrint': 'A one-off payment for the period shown. Nothing renews automatically \u2014 pay again to extend.',
    'vhPaywallNotNow': 'Not now',
    'vhPremiumBadge': 'VIP',
    'vhLockedItem': 'Premium',
    'vhFreePreview': 'Preview',
    'vhPremiumActive': 'Premium active',
    'vhUpgrade': 'Upgrade',
    'vhPaywallLockedCount': 'Unlock {n} more photos and videos in this title.',
    'vhPaywallForTitle': 'Watch {n} in full.',
    'vhLockedCountShort': '{n} locked',

    // --- Video Hub: filter toolbar / hero ---
    'vhFilters': 'Filters',
    'vhClearAll': 'Clear all',
    'vhMoreInfo': 'More info',
    'vhShowResults': 'Show {n} titles',
    'vhEpisodesCount': '{n} episodes',

    // --- Video Hub: see-all ---
    'vhSeeAll': 'See all',
    'vhSortPopular': 'Most watched',
    'vhTitlesCount': '{n} titles',

    // --- Video Hub ---
    'vhVideoChip': 'Movies',
    'vhSearchHint': 'Search movies, series, clips',
    'vhCategoryAll': 'All',
    'vhCategoryMovies': 'Movies',
    'vhCategorySeries': 'Series',
    'vhCategoryReels': 'Reels',
    'vhMore': 'More',
    'vhRowTrending': 'Trending now',
    'vhRowNewReleases': 'New releases',
    'vhFilterGenre': 'Genre',
    'vhFilterYear': 'Year',
    'vhFilterQuality': 'Quality',
    'vhFilterSort': 'Sort by',
    'vhFilterClear': 'Clear',
    'vhFilterAny': 'Any',
    'vhSortNewest': 'Newest',
    'vhSortTitle': 'A-Z',
    'vhNoContent': 'Nothing here yet. Content appears once a source is connected.',
    'vhNoMatchingContent': 'No titles match these filters.',
    'vhLoadFailed': 'Could not load content',
    'vhOfflineBanner': 'You are offline — showing what was saved',
    'vhOfflineNothingSaved': 'No internet connection',
    'vhOfflineHint': 'Connect once and this page is kept for offline use. Downloads play without any connection.',
    'vhOfflineNotHeld': 'No connection, and none of this title is saved on the phone',
    'vhBatteryDozeTitle': 'Downloads may stop when the screen is off',
    'vhBatteryDozeBody': '{maker} phones pause background work to save battery, so a film can stop halfway with nothing to say why. Allowing this app to keep running lets a download finish while the phone is in your pocket.',
    'vhBatteryAllow': 'Allow background downloads',
    'vhBatteryBlockedTitle': 'Background activity is switched off for this app',
    'vhBatteryBlockedBody': 'Nothing will download while the app is not open. This is a setting on the phone, under Battery on this app page — it cannot be changed from here.',
    'vhBatteryOpenSettings': 'Open app settings',
    'vhOfflineReplayPartial': 'Playing what is saved. It will stop where the saved part ends.',
    'vhOfflineReplayNotEnough': 'Too little of this is saved to open it without a connection',
    'vhOfflineReplayWholeFileOnly': 'This video can only be watched offline once all of it is saved',
    'vhRetry': 'Retry',
    'vhSearchPrompt': 'Search across every category',
    'vhSearchNoResults': 'No titles found',
    'vhAlbum': 'Gallery',
    'vhPlay': 'Play',
    'vhUnavailable': 'This item is not available yet',
    'vhWrongDevice': 'Your subscription is active, but this phone is not on it. Sign out on a device you no longer use, then try again.',
    'clearAll': 'Clear all',
    'setupPinConfirmHint': 'Enter the same PIN once more to confirm it.',
    'pinSetFailed': 'Could not save the PIN. Please try again.',
    'changePinCurrentHint': 'Enter your current PIN to continue.',
    'changePinNewHint': 'Choose a new PIN of 4 to 6 digits.',
    'changePinConfirmHint': 'Enter the new PIN again to confirm.',
    'changePinFailed': 'Could not change the PIN. Please try again.',
    'vaultTemporarilyLocked': 'Too many wrong attempts. Wait for the timer to finish.',
    'decoyPinEntryHint': 'This PIN opens an empty vault instead of your real one.',
    'decoyPinConfirmHint': 'Enter the decoy PIN again to confirm.',
    'vaultProgressSafeNote': 'Your original files are kept until each copy is verified.',
    'lockingFiles': 'Locking files',
    'notEnoughSpace': 'Not enough space to lock these files. Free some space and try again.',
    'unlockingFiles': 'Restoring files',
    'importCancelled': 'Stopped. Files already locked stay in the vault.',
    'recoveryLockedOut': 'Too many attempts. Try again later.',
    'autoLock': 'Auto-lock',
    'autoLockDesc': 'How long the vault stays open after you leave the app.',
    'autoLockImmediately': 'Immediately',
    'screenCaptureBlocked': 'Screenshots blocked',
    'screenCaptureBlockedDesc': 'Screenshots, screen recording and the app-switcher preview are blocked while the vault is open. Always on.',
    'loadingMore': 'Loading more…',
    'appName': 'Innocent',
    'tabLocal': 'Video',
    'tabMusic': 'Music',
    'tabTransfer': 'Transfer',
    'tabMe': 'Me',
    'settingsTitle': 'Settings',
    'settingsList': 'List',
    'settingsPlayer': 'Player',
    'settingsDecoder': 'Decoder',
    'settingsAudio': 'Audio',
    'settingsSubtitle': 'Subtitle',
    'settingsGeneral': 'General',
    'settingsDevelopment': 'Development',
    'downloads': 'Downloads',
    'fileTransfer': 'File Transfer',
    'privateFolder': 'Private Folder',
    'videoPlaylists': 'Video Playlists',
    'mediaManager': 'Media Manager',
    'localNetwork': 'Local Network',
    'networkStream': 'Network Stream',
    'cloudDrive': 'Cloud Drive',
    'appTheme': 'App Theme',
    'popupPlay': 'Custom Pop-up Play',
    'watchInsights': 'Watch insights',
    'legal': 'Legal',
    'backupRestore': 'Backup & Restore',
    'quit': 'Quit',
    'quitConfirmTitle': 'Quit Innocent?',
    'quitConfirmBody':
        'This will terminate the app completely. Any current playback will stop.',
    'statusSaver': 'Status Saver',
    'musicTracks': 'Tracks',
    'musicAlbums': 'Albums',
    'musicArtists': 'Artists',
    'musicFolders': 'Folders',
    'noSongsToShuffle': 'No songs to shuffle',
    'noAlbumsFound': 'No albums found',
    'noArtistsFound': 'No artists found',
    'noMusicFoldersFound': 'No music folders found',
    'errorLoadingAlbums': 'Error loading albums',
    'errorLoadingArtists': 'Error loading artists',
    'errorLoadingFolders': 'Error loading folders',
    'searchSongs': 'Search Songs...',
    'newPlaylist': 'New Playlist',
    'playlistName': 'Playlist name',
    'create': 'CREATE',
    'addToHomeScreen': 'Add to Home Screen',
    'addedToHomeScreen': 'Added to Home Screen',
    'addWidget': 'Add Widget',
    'widgetAdded': 'Widget added',
    'resumePlaySettings': 'Resume Play Settings',
    'alwaysResume': 'Always resume',
    'askEveryTime': 'Ask every time',
    'startFromBeginning': 'Start from beginning',
    'playingQueue': 'Playing\nQueue',
    'aspectRatioMenu': 'Aspect\nRatio',
    'displaySettings': 'Display\nSettings',
    'bookmark': 'Bookmark',
    'cut': 'Cut',
    'favourite': 'Favourite',
    'addToPlaylistMenu': 'Add To\nPlaylist',
    'information': 'Information',
    'share': 'Share',
    'tutorial': 'Tutorial',
    'subtitleDelayMenu': 'Subtitle\nDelay',
    'skipMarkers': 'Skip\nMarkers',
    'customSpeed': 'Custom\nSpeed',
    'loopOff': 'Loop off',
    'loopOne': 'Loop one',
    'loopAll': 'Loop all',
    'subtitleOff': 'Subtitle off',
    'aspectRatioTitle': 'Aspect ratio',
    'pressBackAgain': 'Press back again to close',
    'playerQuality': 'Quality',
    'playerQualityAutoHint': 'Adjusts to your connection',
    'playerQualityFailed': 'Could not switch quality. Still playing the current copy.',
    'vhAlbumDownloadAll': 'Download all',
    'vhAlbumDownloaded': 'Downloaded',
    'vhAlbumDownloadNew': 'Download',
    'vhAlbumPlusVideos': '+{n} Video',
    'vhAlbumPlusPhotos': '+{n} Photo',
    'vhAlbumProgress': '{done} / {total}',
    'vhCountOf': '{i} of {n}',
    'vhResumeAt': 'Resume {t}',
    'vhStartOver': 'Start over',
    'vhMinutesLeft': '{m} min left',
    'vhRemoveFromContinue': 'Remove from Continue watching',
    'vhRemovedFromContinue': 'Removed from Continue watching',
    'vhMoreLikeThis': 'More like this',
    'vhUpNext': 'Up next',
    'vhUpNextIn': 'Next in {s}',
    'vhPlayNow': 'Play now',
    'vhStillWatching': 'Still watching?',
    'vhKeepWatching': 'Keep watching',
    'vhAlbumVideos': '{n} videos',
    'vhAlbumPhotos': '{n} photos',
    'vhAlbumVideo1': '1 video',
    'vhAlbumPhoto1': '1 photo',
    'vhAlbumAsk': '{items}, about {size} at full quality. You have {free} free on this phone. Carry on?',
    'vhAlbumAskNoSize': '{items} at full quality. You have {free} free on this phone. Carry on?',
    'vhAlbumSomeFailed': '{n} could not be downloaded. Tap Download to try them again.',
    'vhSavedOffline': 'Saved on this phone',
    'vhSaveOffline': 'Save for offline',
    'vhAlbumDeleteBody': 'Delete the photos and clips of this album from this phone? A downloaded film stays.',
    'vhDeleteItemBody': 'Delete this from the phone? You can download it again.',
    'vhDataSaver': 'Data saver',
    'vhDataSaverHint': 'Albums show blurred previews. Tap the download button on the ones you want.',
    'vhDataSaverWifi': 'Also on Wi-Fi',
    'vhDataSaverWifiHint': 'Off: on Wi-Fi albums load normally.',
    'vhDataSaverOn': 'Data saver is on — tap to show albums normally',
    'vhDataSaverOff': 'Turn on data saver',
    'vhSaverChip': 'Saver',
    'vhDiagTitle': 'Report a problem',
    'vhDiagHint': 'Send what the app saw, so it can be fixed',
    'vhDiagBody': 'This sends what the app recorded about downloads and playback on this phone, with the phone model and connection type. Links, passwords and your files are never included.',
    'vhDiagNoteHint': 'What went wrong? (optional)',
    'vhDiagSent': 'Sent. Your report code:',
    'vhDiagSentHint': 'Tell us this code when you describe the problem.',
    'vhDiagFailed': 'Could not send. Check the connection and try again.',
    'vhDiagCopied': 'Code copied',
    'vhSaverModeAll': 'All connections',
    'vhSaverModeAllHint': 'Wi-Fi too — for Wi-Fi bought by the gigabyte',
    'vhSaverModeMobile': 'Mobile data only',
    'vhSaverModeMobileHint': 'On Wi-Fi, albums load as usual',
    'vhSaverNowOn': 'Saving now · {conn}',
    'vhSaverNowOff': 'Not saving on {conn}',
    'vhConnWifi': 'Wi-Fi',
    'vhConnMobile': 'mobile data',
    'vhConnOffline': 'offline',
    'vhConnOther': 'this connection',
    'vhSaverBanner': 'Data saver is on — photos and videos load only when you tap them',
    'vhSaverTurnOff': 'Turn off',
    'vhSaverHowTitle': 'How it works',
    'vhSaverHow1': 'Albums show a soft blurred preview. Nothing is downloaded to draw it.',
    'vhSaverHow2': 'Each photo and clip shows its size. Tap only the ones you want.',
    'vhSaverHow3': 'What you open stays on the phone and never costs data twice.',
    'vhSaverHow4': 'Films on Auto quality stream at up to 480p.',
    'vhLibraryDataSaverHint': 'Albums load only what you tap',
    'vhBookmark': 'Save',
    'vhBookmarked': 'Saved',
    'vhBookmarkAdded': 'Saved to Bookmarks',
    'vhBookmarkRemoved': 'Removed from Bookmarks',
    'vhUndo': 'Undo',
    'vhBookmarksEmpty': 'Nothing saved yet. Tap the bookmark on any title to keep it here.',
    'vhBookmarksSignInHint': 'Sign in to keep your bookmarks on every phone you use.',
    'vhBookmarksCount': '{n} saved',
    'vhOn': 'On',
    'vhEdit': 'Edit',
    'vhDownloadsActive': 'Downloading',
    'vhDownloadYielding': 'slowed while you watch',
    'vhDownloadsDone': 'Downloaded',
    'vhDownloadsSettings': 'Download settings',
    'playerNoticeIncomplete': 'This file is not fully downloaded. It plays up to {t}.',
    'playerNoticeSeekHeld': 'Not downloaded past {t}.',
    'playerNoticeSoftware': 'The hardware decoder failed on this file. Playing with the software (SW) decoder.',
    'playerNoticeHwUnavailable': 'The hardware decoder stopped working after a damaged file. Videos play in software for now (slower, warmer). Close and reopen Innocent to bring it back.',
    'playerNoticeEngineRestarted': 'The player was restarted after the last video stopped responding.',
    'playerDamagedStretch': 'This part of the file is damaged or was never fully downloaded, so playback was stopped here to keep the app responsive. Tap Retry, or go back.',
    'playerEngineStuck': 'The player stopped responding on this file. It may be damaged or not fully downloaded. Tap Retry, or go back and open another video.',
    'close': 'Close',
    'audioTrack': 'Audio track',
    'subtitle': 'Subtitle',
    'lockControls': 'Lock controls',
    'refresh': 'Refresh',
    'refreshingLibrary': 'Refreshing media library...',
    'noVideosFound': 'No videos found',
    'noVideosMatch': 'No videos match',
    'resume': 'RESUME',
    'permissionRationale': 'Innocent needs permission to read videos on your device. We never collect or upload any of your data.',
    'permissionRationalePermanent':
        'Innocent needs videos permission to scan your library. The system request can no longer be shown from here — please enable it in app settings, then come back. No data ever leaves your device.',
    'features': 'Features',
    'faq': 'FAQ',
    'versionCheck': 'Version check',
    'sendBugReport': 'Send bug report',
    'privacy': 'Privacy',
    'whatsNew': 'What\'s new',
    'bugReportHint':
        'Use the thumbs-down in chat to send feedback to the developer.',
    'sortLabel': 'Sort',
    'ascending': 'Ascending',
    'descending': 'Descending',
    'sortName': 'Name',
    'sortDate': 'Date',
    'sortSize': 'Size',
    'viewList': 'List',
    'viewGrid': 'Grid',
    'history': 'History',
    'favourites': 'Favourites',
    'watchLater': 'Watch later',
    'playlists': 'Playlists',
    'recycleBin': 'Recycle bin',
    'chipCleaner': 'Cleaner',
    'chipPlaylists': 'Playlists',
    'chipPrivate': 'Private Folder',
    'images': 'Images',
    'statistics': 'Statistics',
    'about': 'About',
    'help': 'Help',
    'language': 'Language',
    'retry': 'Retry',
    'cancel': 'Cancel',
    'ok': 'OK',
    'done': 'Done',
    'comingSoon': 'Coming soon',
    'playbackFailed': 'Playback failed',
    'permissionGrant': 'Grant permission',
    'permissionOpenSettings': 'Open Settings',
    'pipOverAppsTitle': 'Play over other apps',
    'pipOverAppsBody': 'To keep the video playing over other apps after you leave Innocent, turn on the Picture-in-picture permission for Innocent in Settings.',
    // ── v0.49 full-coverage localization pass ──
    'delete': 'Delete',
    'clear': 'Clear',
    'reset': 'Reset',
    'save': 'Save',
    'rename': 'Rename',
    'restore': 'Restore',
    'remove': 'Remove',
    'apply': 'Apply',
    'stop': 'Stop',
    'start': 'Start',
    'export': 'Export',
    'importWord': 'Import',
    'move': 'Move',
    'hide': 'Hide',
    'download': 'Download',
    'play': 'Play',
    'playAll': 'Play All',
    'shuffleAll': 'Shuffle All',
    'setWord': 'Set',
    'add': 'Add',
    'addNow': 'Add Now',
    'connect': 'Connect',
    'disconnect': 'Disconnect',
    'gotIt': 'Got it',
    'skip': 'Skip',
    'emptyVerb': 'Empty',
    'clean': 'Clean',
    'copyPath': 'Copy path',
    'errorWord': 'Error',
    'off': 'Off',
    'recent': 'Recent',
    'properties': 'Properties',
    'goBack': 'Go Back',
    'unlock': 'Unlock',
    'lock': 'Lock',
    'path': 'Path',
    'newBadge': 'NEW',
    'failedToLoad': 'Failed to load',
    'versionOf': 'Version {v}',
    'fullAccessAlready': 'Full library access is already enabled.',
    'fullAccessTitle': 'Enable full library access?',
    'fullAccessEnabled': 'Full library access enabled.',
    'permissionNotGranted': 'Permission not granted. You can try again any time.',
    'clearHistoryTitle': 'Clear History?',
    'clearHistoryBody': 'This will remove all playback and search history.',
    'historyCleared': 'History cleared',
    'clearThumbTitle': 'Clear Thumbnail Cache?',
    'clearThumbBody': 'Thumbnails will be regenerated when media list is opened.',
    'thumbCleared': 'Thumbnail cache cleared',
    'resetSettingsTitle': 'Reset settings?',
    'resetSettingsBody': 'This will restore all settings to their default values.',
    'settingsResetDone': 'Settings reset to defaults',
    'clearFontCacheTitle': 'Clear Font Cache?',
    'fontCacheCleared': 'Font cache cleared',
    'languageRestartNote': 'Language will change on next app restart',
    'exportedTo': 'Exported to {path}',
    'exportFailed': 'Export failed',
    'importFailed': 'Import failed',
    'importedFrom': 'Imported settings from {path}',
    'noExportFile': 'No exported settings file found. Use Export first.',
    'moreLanguagesOnWay': 'More languages are on the way.',
    'colorFormat': 'Color Format',
    'screenTitle': 'Screen',
    'navigationTitle': 'Navigation',
    'controlsTitle': 'Controls',
    'styleTitle': 'Style',
    'subtitleTextTitle': 'Subtitle Text',
    'subtitleLayoutTitle': 'Subtitle Layout',
    'soonBadge': 'SOON',
    'debugLogsExported': 'Debug logs exported',
    'findYourVideos': 'Find your videos',
    'scanningVideos': 'Scanning videos…',
    'errorLoadingFoldersPrefix': 'Error loading folders',
    'errorLoadingVideosPrefix': 'Error loading videos',
    'loadingVideos': 'Loading videos…',
    'recentlyAdded': 'Recently Added',
    'continueWatching': 'Continue Watching',
    'noContinueWatching': 'Nothing to continue watching yet.',
    'removeContinueTitle': 'Remove from Continue Watching?',
    'recentSearches': 'Recent searches',
    'eqDuringPlayback': 'Equalizer available during playback',
    'magicPenHint': 'Magic Pen — AI features coming in pro version',
    'featuresIntro': 'Innocent supports:',
    'featuresBody': '• Hardware + Software decoding (HW/HW+/SW)\n• Resume from where you stopped\n• Background play + Picture-in-Picture\n• 10-band Equalizer + Bass Boost + Virtualizer + Reverb\n• Subtitle styling (Font, Size, Color, Border, Shadow)\n• Subtitle search + offline subtitle loading\n• Touch gestures (swipe seek/brightness/volume, pinch zoom)\n• Sleep timer + AB Repeat + Loop\n• Audio/Subtitle track switching\n• Per-video Remember selections\n• Multi-folder library + Recently Played\n• Favourites / Watch Later / Playlists\n• Music player with Shuffle / Sort / Folders\n• Tablet-responsive UI',
    'faqQ1': 'Q: Why doesn\'t my video play?',
    'faqA1': 'A: Try switching the decoder (long-press the player → Decoder → SW). Some codecs need software decoding.',
    'faqQ2': 'Q: How do I load external subtitles?',
    'faqA2': 'A: Place .srt files in the same folder as the video, or set Settings → Subtitle → Subtitle Folder to a global path.',
    'faqQ3': 'Q: Audio is out of sync — how do I fix it?',
    'faqA3': 'A: Settings → Audio → Audio delay. Or use the long-press menu in player → Audio sync.',
    'faqQ4': 'Q: Why is my screen dim after playing?',
    'faqA4': 'A: Fixed in build 56 — brightness is now restored when the player closes.',
    'privacyBody': 'Innocent runs entirely offline. It does not collect telemetry, analytics, or send any data to remote servers. All your video history, favourites, and playlists stay on this device.',
    'aboutBody': 'A faithful MX Player-style media player for Android, built with Flutter and media_kit.',
    'addSubtitleFromUrl': 'Add Subtitle from URL',
    'subtitleUrlTip': 'Tip: at OpenSubtitles.org, copy the direct "Download" link (not the page URL). For zipped subtitles, extract first.',
    'downloadingSubtitle': 'Downloading subtitle…',
    'downloadFailed': 'Download failed',
    'moveToBinTitle': 'Move to Recycle Bin?',
    'deleteVideoTitle': 'Delete video?',
    'addToPlaylist': 'Add to playlist',
    'noPlaylistsYet': 'No playlists yet',
    'createNewPlaylist': 'Create new playlist',
    'newPlaylistTitle': 'New playlist',
    'playUsingHw': 'Play using HW decoder',
    'playUsingHwPlus': 'Play using HW+ decoder',
    'playUsingSw': 'Play using SW decoder',
    'hideSelectedHint': 'Hide selected items from the library',
    'rebuildThumbnail': 'Rebuild thumbnail',
    'createdPlaylist': 'Created playlist "{name}"',
    'renamePlaylist': 'Rename playlist',
    'playlistEmpty': 'Playlist is empty',
    'deleteNameTitle': 'Delete "{name}"?',
    'deletedName': 'Deleted "{name}"',
    'noCustomPlaylists': 'No custom playlists yet',
    'emptyBinTitle': 'Empty recycle bin?',
    'binEmpty': 'Recycle Bin is empty.',
    'permDeleteTitle': 'Permanently delete?',
    'permDeleteBody': 'This entry will be permanently removed from the Recycle Bin.',
    'restoredName': 'Restored: {name}',
    'removedName': 'Removed: {name}',
    'clearWatchLaterTitle': 'Clear Watch Later?',
    'clearWatchLaterBody': 'Remove all videos from the queue?',
    'watchLaterEmpty': 'Watch Later queue is empty',
    'watchLaterHint': 'Tap ⋮ on a video → "Add to Watch Later" to queue it up.',
    'noHistoryYet': 'No watch history yet',
    'noFavouritesYet': 'No favourite videos yet.\nTap ⋮ on a video then "Favourite"',
    'unfavouritedName': 'Unfavourited: {name}',
    'yourWatchInsights': 'Your watch insights',
    'noInsightsYet': 'No insights yet',
    'totalTimeWatched': 'Total time watched',
    'last7Days': 'Last 7 days (minutes)',
    'mostRewatched': 'Most rewatched',
    'mostWatchedFolder': 'Most watched folder',
    'averageCompletion': 'Average completion',
    'failedPickFiles': 'Failed to pick files',
    'send': 'Send',
    'receive': 'Receive',
    'howTransferWorksTitle': 'How file transfer works',
    'howTransferWorksBody': 'This sends files over your Wi-Fi network to another device on the same network — no internet needed.\n\n1. Connect both devices to the same Wi-Fi.\n2. On THIS device, pick files and tap Start.\n3. On the OTHER device, open any browser and either:\n   - scan the QR code with the camera app, or\n   - type the URL shown on screen.\n4. The other device sees a list of files. Tap a file to download it.\n\nTap Stop on this device to end the share — the URL becomes invalid immediately.\n\nWhat it isn\'t:\n- Not encrypted (LAN-only). Anyone on your Wi-Fi who knows the full URL could download.\n- Doesn\'t work over cellular. Wi-Fi only.\n- Doesn\'t keep running in the background. Closing the app ends the share.',
    'filesToShare': 'Files to share',
    'addFiles': 'Add files',
    'noFilesHint': 'No files yet.\nTap "Add files" to pick something to share.',
    'shareIsLive': 'Share is live',
    'shareScanHint': 'On the other device, scan the QR or type the URL below into any browser.',
    'urlCopied': 'URL copied',
    'stopSharing': 'Stop sharing',
    'cameraPermissionNeeded': 'Camera permission is needed to scan the QR code',
    'scanQrCode': 'Scan QR code',
    'orEnterAddress': 'or enter address',
    'downloadAll': 'Download all',
    'nearbyDevices': 'Nearby devices',
    'lookingForPhones': 'Looking for nearby phones\u2026',
    'noPhonesFound': 'No phones found yet. On the other phone open File Transfer \u2192 Send and start the share.',
    'tapDeviceToConnect': 'Tap a phone to connect',
    'connectingToDevice': 'Connecting\u2026',
    'thisPhoneName': 'This phone',
    'renameThisPhone': 'Rename this phone',
    'askBeforeSending': 'Ask before sending',
    'askBeforeSendingHint': 'Other phones must be approved by you before they can download. Safer on shared Wi-Fi.',
    'wantsToReceive': 'wants to receive your files',
    'accept': 'Accept',
    'decline': 'Decline',
    'waitingForReceiver': 'Waiting for the other phone\u2026',
    'overallProgress': 'Overall',
    'alreadyOnThisPhone': 'Already on this phone',
    'cancelTransfer': 'Cancel transfer',
    'hotspotTipBody': 'Turn on this phone\u2019s hotspot and connect the other phone to it (no internet needed), then start the share. Through a router every byte crosses the air twice, so it can be several times slower.',
    'directLinkActive': 'Direct link \u2014 fastest mode',
    'viaRouterSlower': 'Via Wi-Fi router \u2014 hotspot is faster',
    'allFilesReceived': 'All files received',
    'turboTitle': 'Turbo \u2014 direct link',
    'turboSubtitle': 'Connects the two phones straight to each other instead of through a router, so data crosses the air once. Much faster, and no Wi-Fi network needed. This phone loses internet while it runs.',
    'turboStarting': 'Starting the direct link\u2026',
    'turboBadge5': 'Turbo 5 GHz \u2014 fastest',
    'turboBadge24': 'Turbo direct link (2.4 GHz)',
    'turboUnavailable': 'Turbo could not start \u2014 sharing over normal Wi-Fi instead.',
    'turboJoinManually': 'Phone without Innocent? Join this Wi-Fi by hand, then open the address above in a browser.',
    'turboWifiName': 'Wi-Fi name',
    'turboWifiPassword': 'Password',
    'turboJoining': 'Joining the other phone\u2019s link\u2026',
    'turboConnected': 'Direct link connected',
    'turboLeave': 'Disconnect direct link',
    'turboNoInternet': 'While the direct link is on, this phone has no internet. It comes back as soon as you disconnect.',
    'turboReasonWifiOff': 'Turn Wi-Fi on first \u2014 the direct link uses the Wi-Fi radio (it does not use your data).',
    'turboReasonLocationOff': 'Android needs Location switched on to set up a direct Wi-Fi link on this version. Innocent never reads your position.',
    'turboReasonPermission': 'Permission is needed to set up the direct Wi-Fi link.',
    'turboReasonUnsupported': 'This phone\u2019s Android version cannot create a direct link. Normal Wi-Fi sharing still works.',
    'turboReasonGeneric': 'The direct link could not start on this phone.',
    'turboOpenWifiSettings': 'Open Wi-Fi settings',
    'turboOpenLocationSettings': 'Open Location settings',
    'sendInnocentApp': 'Send the Innocent app',
    'sendInnocentAppHint': 'Adds Innocent\u2019s own APK to the share, so a phone without it can install it from you \u2014 no internet needed.',
    'transferHistory': 'Received files',
    'clearHistory': 'Clear list',
    'fileMissing': 'That file is no longer on this phone.',
    'receivedFromDevice': 'from',
    'turboBandUnknown': 'Turbo direct link',
    'turboSccExplain': 'This link is on 2.4 GHz because the phone is connected to a Wi-Fi network — most phones can only run the direct link on the same channel as their Wi-Fi. Disconnect from Wi-Fi (leave Wi-Fi switched ON) and start again for a 5 GHz link, which is several times faster.',
    'turboSccTip': 'Tip: for the fastest link, disconnect this phone from Wi-Fi first \u2014 but leave Wi-Fi switched on. Turbo needs the radio, not the network.',
    'turboReasonDeclined': 'The other phone\u2019s link was not found, or the connection was declined. Make sure it is still sharing and stay close to it.',
    'turboReasonNoAddress': 'The direct link came up but got no address on this phone. Sharing over normal Wi-Fi instead.',
    'turboOpenAppSettings': 'Open app settings',
    'sendFolder': 'Send a folder',
    'sendThisFolder': 'Send',
    'scanningFolder': 'Reading folder\u2026',
    'noSubfolders': 'No folders in here. You can still send this one.',
    'folderUnreadable': 'This folder can\u2019t be read. Try another one.',
    'folderEmpty': 'That folder has no files to send.',
    'folderTooManyFiles': 'Only the first 3000 files were added \u2014 that is a very large folder.',
    'folderAdded': 'Folder added \u2014 the structure is kept on the other phone.',
    'pauseShare': 'Pause',
    'resumeShare': 'Resume',
    'sharePaused': 'Paused \u2014 receivers are waiting. Nothing they downloaded is lost.',
    'pauseReceive': 'Pause',
    'resumeReceive': 'Resume',
    'receivePaused': 'Paused. Tap Resume to continue from where it stopped.',
    'pausedBySender': 'The other phone paused the transfer\u2026',
    'protectWithPin': 'Ask for a PIN',
    'protectWithPinHint': 'Shows a 4-digit code here that the other phone must enter. Worth it on shared Wi-Fi, where anyone nearby can see this phone in their list.',
    'enterSharePin': 'Enter the 4-digit PIN shown on the other phone',
    'wrongPin': 'That PIN did not match. Check the other phone\u2019s screen.',
    'receiversLabel': 'Receiving',
    'encryptionNote': 'On Turbo the link itself is WPA2-encrypted, so files are protected in the air. Over a normal Wi-Fi network the transfer is not encrypted \u2014 use a PIN, or Turbo, on networks you don\u2019t trust.',
    'connectAction': 'Connect',
    'dismiss': 'Dismiss',
    'addMoreFiles': 'Add more files',
    'cannotOpenFile': 'No app on this phone can open that file.',
    'allowInstallTitle': 'Allow installing apps',
    'allowInstallBody': 'Android needs your permission before Innocent can hand an APK to the installer. You only have to do this once.',
    'allowInstallAction': 'Open settings',
    'webUploadHint': 'A phone or computer with only a browser can open this address and send files back to you \u2014 nothing to install on their side.',
    'filesAddedLive': 'Added to the live share \u2014 the other phone can refresh to see them.',
    'savedToPath': 'Saved to: {path}',
    'scanSenderQr': 'Scan sender QR',
    'scanQrHint': 'Point the camera at the QR code shown on the sending phone',
    'playbackSpeed': 'Playback speed',
    'sleepTimer': 'Sleep Timer',
    'stopsIn': 'Stops in {t}',
    'sleepTimerSetMin': 'Sleep timer set: {n} min',
    'sleepTimerOff': 'Sleep timer off',
    'shareFailed': 'Share failed',
    'shareTrack': 'Share track',
    'lyrics': 'Lyrics',
    'playingQueueTitle': 'Playing Queue',
    'queueEmpty': 'Playing queue is empty',
    'playbackError': 'Playback error',
    'noSongsFound': 'No songs found on device',
    'errorReadingMusic': 'Error reading music',
    'searchPlaylists': 'Search Playlists...',
    'searchAlbums': 'Search Albums...',
    'searchArtists': 'Search Artists...',
    'searchFolders': 'Search Folders...',
    'sortBy': 'Sort by',
    'noSongsBy': 'No songs by {name}',
    'noSongsIn': 'No songs in {name}',
    'errorLoadingSongs': 'Error loading songs',
    'errorLoadingAlbum': 'Error loading album',
    'errorLoadingPlaylist': 'Error loading playlist',
    'playAllCount': 'Play All  ({n})',
    'sharingName': 'Sharing "{name}"',
    'playingName': 'Playing "{name}"',
    'shufflingName': 'Shuffling "{name}"',
    'propertiesForName': 'Properties for "{name}"',
    'changePin': 'Change PIN',
    'pinChanged': 'PIN changed',
    'restoredToLibrary': 'Restored to library',
    'restoreFailed': 'Restore failed',
    'privateIntro': 'Locked videos are moved into this app\'s private storage — not shown in the gallery or other file managers. Files the system won\'t let us move are hidden from the library only. Files are moved, not encrypted.',
    'setupPinTitle': 'Set up Private Folder PIN',
    'setupPinHint': 'Videos locked here will not appear in your library.',
    'useBiometric': 'Use biometric',
    'setPin': 'Set PIN',
    'enterPin': 'Enter PIN',
    'restoreBackupTitle': 'Restore backup?',
    'clearLibraryCacheTitle': 'Clear library cache?',
    'addNewServer': 'Add a new server',
    'networks': 'Networks',
    'supportedProtocols': 'SUPPORTED PROTOCOLS',
    'howToUse': 'How to use?',
    'meSettingsHint': 'Theme, pop-up play, language',
    'meBackupHint': 'Your lists, and Cloud Drive',
    'meHelpHint': 'Questions, and how to reach us',
    'meAboutHint': 'Version, updates, licences',
    'meLibrary': 'Your library',
    'meInsights': 'Insights',
    'meLibraryStats': 'Library statistics',
    'bkInfo': 'Back up your favourites, playlists, bookmarks and history, and restore them on any phone.',
    'bkSectionBackup': 'Backup',
    'bkExport': 'Export backup to file',
    'bkExportSub': 'Favourites, playlists, bookmarks and history as a JSON file',
    'bkSectionRestore': 'Restore',
    'bkRestoreFile': 'Restore from file',
    'bkRestoreFileSub': 'Bring back a backup file made by Innocent',
    'bkSectionCloud': 'Cloud',
    'bkCloudSub': 'Google Drive, OneDrive, Dropbox and more — back up and stream from the cloud',
    'bkSectionCache': 'Cache',
    'bkClearCache': 'Clear library cache',
    'bkClearCacheSub': 'Videos are scanned again the next time the app opens',
    'bkWhat': 'What gets backed up',
    'bkItemSettings': 'App settings & preferences',
    'bkItemPlaylists': 'Video playlists',
    'bkItemFavourites': 'Favourites',
    'bkItemHistory': 'Watch history',
    'bkItemLater': 'Watch later list',
    'bkItemBookmarks': 'Bookmarks',
    'bkRestoreWarn': 'This REPLACES your current favourites, playlists, bookmarks, history and recycle bin with the ones in the backup file.',
    'bkClearWarn': 'The next time the app opens it scans all videos again. Safe, just slower that once.',
    'bkExported': 'Saved to {path} — the path is copied',
    'bkFailed': 'Something went wrong: {e}',
    'bkNoFile': 'No file chosen',
    'bkRestored': 'Restored: {f} favourites, {p} playlists, {b} bookmarks, {h} history',
    'bkCacheCleared': 'Library cache cleared. Reopen the app to scan again.',
    'netHowStep1': 'Add a server by tapping the {+} button.',
    'netHowStep2': 'Access all your remote files directly from your device.',
    'netHowStep3': 'Use the same Wi-Fi as the computer or NAS — Scan finds it for you.',
    'netGotIt': 'GOT IT',
    'netNewServer': 'New {p} Server',
    'netEditServer': 'Edit {p} Server',
    'netScan': 'Scan',
    'netServer': 'Server',
    'netServerIp': 'Server IP',
    'netServerName': 'Server Name',
    'netServerNameHint': 'My Server Name (optional)',
    'netSharedPath': 'Shared Path',
    'netSharedPathHint': 'Shared Path (optional)',
    'netFolder': 'Folder',
    'netFolderHint': 'Start folder (optional)',
    'netPort': 'Port',
    'netUsername': 'Username',
    'netPassword': 'Password',
    'netAnonymous': 'Connect Anonymously',
    'netMode': 'Mode',
    'netActive': 'Active',
    'netPassive': 'Passive',
    'netEncoding': 'Encoding',
    'netSecurityMode': 'Security Mode',
    'netImplicit': 'Implicit',
    'netExplicit': 'Explicit',
    'netUseKey': 'Login With Private Key',
    'netPrivateKey': 'Private Key',
    'netPrivateKeyHint': 'Paste the key (-----BEGIN …)',
    'netChooseKeyFile': 'Choose key file',
    'netPassphrase': 'Passphrase',
    'netPassphraseHint': 'Passphrase (optional)',
    'netConnect': 'Connect',
    'netSave': 'Save',
    'netConnecting': 'Connecting…',
    'netErrUnreachable': 'Can\'t reach {host}. Is it switched on, and on the same Wi-Fi as this phone?',
    'netErrTimeout': 'The server took too long to answer. Try again.',
    'netErrAuth': 'Wrong username or password.',
    'netErrAuthAnon': 'This server does not allow anonymous access. Untick "Connect Anonymously" and sign in.',
    'netErrDenied': 'This account is not allowed to open that folder.',
    'netErrNotFound': 'That share or folder does not exist on the server.',
    'netErrTls': 'Secure connection failed. Check the port and the Security Mode.',
    'netErrKey': 'The private key could not be read. Check the key and its passphrase.',
    'netErrProtocol': 'The server answered, but not as {p}. Check the protocol and the port.',
    'netErrHostKey': 'This server\'s identity has changed since you last connected.',
    'netErrHostKeyBody': 'If you reinstalled or replaced the server, trust the new identity. If not, someone on this network may be pretending to be it.',
    'netTrustNew': 'Trust new identity',
    'netErrNeedHost': 'Enter the server address.',
    'netErrBadPort': 'Port must be between 1 and 65535.',
    'netErrNeedKey': 'Paste or choose a private key.',
    'netErrUnsupported': 'Local Network is not available on this device.',
    'netScanTitle': 'Servers on this Wi-Fi',
    'netScanning': 'Looking for {p} servers on {subnet}…',
    'netScanNone': 'No {p} servers found on this Wi-Fi.',
    'netScanNoneHint': 'Turn on file sharing on the computer, or type its address.',
    'netScanAgain': 'Scan again',
    'netScanNoWifi': 'Connect to Wi-Fi to scan.',
    'netMyServers': 'Servers',
    'netEdit': 'Edit',
    'netDelete': 'Delete',
    'netDeleteConfirm': 'Remove "{name}"?',
    'netDeleteBody': 'Its saved password is removed from this phone too.',
    'netEmptyFolder': 'This folder is empty',
    'netRetry': 'Retry',
    'netSortName': 'Name',
    'netSortDate': 'Date',
    'netSortSize': 'Size',
    'netMediaOnly': 'Media only',
    'netNotPlayable': 'This file can\'t be played here.',
    'netItems': '{n} items',
    'netAnonymousTag': 'Anonymous',
    'netShares': 'Shares',
    'netShowPassword': 'Show password',
    'aboutCloudDrive': 'About Cloud Drive',
    'cloudDriveBody': 'Stream videos and music directly from your cloud accounts without downloading. Connect a provider below to browse its files inside Innocent.',
    'connectCloudCaps': 'CONNECT YOUR CLOUD STORAGE',
    'deviceStorage': 'Device storage',
    'cleanUpSpace': 'Clean up for more space',
    'scanningCleanable': 'Scanning for cleanable files...',
    'openingRecentlyPlayed': 'Opening Recently Played',
    'mmUsedOf': '{used} of {total} used',
    'mmFree': '{free} free',
    'mmVideos': 'Videos',
    'mmMusic': 'Music',
    'mmNoAccess': 'No access',
    'mmStorageUnknown': 'Storage size unavailable',
    'mmRecentlyPlayed': 'Recently Played',
    'mmLargeFiles': 'Large Files',
    'mmLargestVideos': 'Largest videos',
    'mmHaventPlayed': "Haven't Played",
    'mmAllPlayed': "You've played every video on this phone.",
    'scNightMode': 'Night Mode',
    'scShuffle': 'Shuffle',
    'scMute': 'Mute',
    'scAbRepeat': 'A - B Repeat',
    'scMirrorMode': 'Mirror Mode',
    'scVerticalFlip': 'Vertical Flip',
    'scAudioEffect': 'Audio Effect',
    'scEqualizer': 'Equalizer',
    'scSpeed': 'Speed',
    'scScreenshot': 'Screenshot',
    'scBackgroundPlay': 'Background Play',
    'scScreenRotation': 'Screen Rotation',
    'scLoop': 'Loop',
    'scCustomiseItems': 'Customise Items',
    'scVideoDisplay': 'Video Display',
    'scSleepTimer': 'Sleep Timer',
    'gtSection': 'Touch gestures',
    'gtBrightness': 'Swipe for brightness',
    'gtBrightnessSub': 'Swipe up or down on the left half.',
    'gtVolume': 'Swipe for volume',
    'gtVolumeSub': 'Swipe up or down on the right half. With Volume boost on, keep going past 100 % up to 200 %.',
    'gtSeek': 'Swipe to seek',
    'gtSeekSub': 'Swipe left or right; the film follows your finger.',
    'gtDoubleTap': 'Double tap to seek',
    'gtDoubleTapSub': 'Double tap the left or right side. Keep tapping to go further (10, 20, 30 s…). Double tap the middle to play or pause.',
    'gtLongPress': 'Hold for speed',
    'gtLongPressSub': 'Press and hold, then slide left or right without lifting.',
    'gtPinch': 'Pinch to zoom',
    'gtPinchSub': 'Spread or pinch two fingers.',
    'gtPan': 'Move while zoomed',
    'gtPanSub': 'When zoomed in, drag with two fingers to move the picture.',
    'gtSpeed': 'Two fingers for speed',
    'gtSpeedSub': 'Swipe up or down with two fingers (0.25x – 4x).',
    'gtSubtitle': 'Subtitle gestures',
    'gtSubtitleSub': 'On the subtitle: drag up or down to move it, swipe left or right for the previous or next line, pinch to resize.',
    'zmFit': 'Fit to screen',
    'zmStretch': 'Stretch',
    'zmCrop': 'Crop',
    'zmOriginal': '100%',
    'zmCustom': 'Custom',
    'zmCustomHint': 'Pinch to zoom, two fingers to move',
    'gtTap': 'Tap to show or hide controls',
    'gtTapSub': 'Tap the screen once.',
    'gtVolumeKey': 'Volume keys',
    'gtVolumeKeySub': 'Change the volume.',
    'gtHeadset': 'Headset button',
    'gtHeadsetSub': 'Play or pause.',
    'storagePermissionNeeded': 'Storage permission needed',
    'statusPermissionHint': 'Allow media access so we can read WhatsApp statuses.',
    'openingPrivacyPolicy': 'Opening Privacy Policy...',
    'openingTerms': 'Opening Terms of Service...',
    'personalPlayerApp': 'Personal video player app.',
    'storageManagement': 'Storage management',
    'storageUsage': 'Storage Usage',
    'classicThemes': 'Classic Themes',
    'noInternetThemes': 'No internet connection. Tap to connect for fresh themes.',
    'themeApplied': 'Theme applied',
    'openSourceLicenses': 'Open source licenses',
    'personalProject': 'A personal Flutter project for learning and private use.',
    'personalVideoPlayer': 'Personal video player',
    'slowBuffering': 'Slow connection — buffering…',
    'openingVideo': 'Opening the video…',
    'videoTooHeavy': 'This video is heavy for this device…',
    'streamCacheTitle': 'Video storage',
    'streamCacheExplain':
        'Videos you watch are kept on this phone, so rewinding and watching '
        'again cost nothing and work without a signal. Only the parts you '
        'actually watched are kept. When the limit is reached, the videos you '
        'have not opened for longest go first.',
    'streamCacheLimit': 'LIMIT',
    'streamCacheClear': 'Clear kept videos',
    'streamCacheClearPages': 'Clear saved pages and artwork',
    'streamCacheClearPagesNote': 'The catalogue kept for offline browsing, and its posters. Frees space; needs a connection to fill again.',
    'streamCacheClearNote':
        'Frees the space now. Anything you watch again will be downloaded '
        'again.',
    'streamCacheKept': 'KEPT',
    'streamCacheUnnamed': 'Video',
    'streamCacheSubtitle': 'Keep watched videos on this phone',
    'durationLabel': 'Duration',
    'resumeTitle': 'Resume',
    'resumeBody': 'Do you wish to resume from where you stopped?',
    'savedAt': 'Saved at {t}',
    'useByDefault': 'Use by default',
    'startOver': 'Start over',
    'continueFromStopped': 'Continue from where you stopped.',
    'customSpeedTitle': 'Custom Speed',
    'speedRangeHint': 'Range: 0.25x - 4.00x',
    'playLastToEnd': 'Play last media to the end',
    'setStartFirst': 'Set start point first',
    'endAfterStart': 'End must come after start',
    'setBothPoints': 'Set both start and end points first',
    'markClipHint': 'Mark a clip by setting a start (A) and end (B) point.',
    'currentLabel': 'Current',
    'clipLabel': 'Clip',
    'displaySettingsTitle': 'Display Settings',
    'playerGestures': 'Player gestures',
    'tapToDismiss': 'Tap anywhere to dismiss',
    'skipIntroOutro': 'Skip Intro / Outro',
    'clearAllMarkers': 'Clear all markers',
    'noTracksAvailable': 'No tracks available',
    'loadExternalSubtitle': 'Load external subtitle...',
    'onlineSubtitles': 'Online subtitles',
    'selectDecoder': 'Select decoder',
    'bookmarksTitle': 'Bookmarks',
    'subtitleDelayTitle': 'Subtitle delay',
    'shortcuts': 'Shortcuts',
    'unknownTab': 'Unknown tab',
    'invalidUrl': 'Invalid URL',
    'streamUrl': 'Stream URL',
    'equalizerTitle': 'Equalizer',
    'eqNotAvailable': 'Equalizer not available',
    'audioFxNotAvailable': 'Audio effects are not available on this device.',
    'tapProfileHint': 'Tap a profile to turn on audio effects.',
    'profilesFineTuneHint': 'Profiles adjust the equalizer bands. Fine-tune them on the Equalizer tab.',
    'reverb': 'Reverb',
    'kidsLock': 'Kids\nLock',
    'kidsLockOnMsg': 'Kids Lock on — all controls are disabled',
    'kidsLockHoldHint': 'Hold to unlock',
    'kidsLockOffMsg': 'Kids Lock off',
    'fullAccessBody': 'Android will open a system screen titled "All files access". Flip the switch for Innocent, then tap back to return here. This lets the library scan folders outside the default Movies/DCIM/Downloads roots. You can revoke it any time from the same screen.',
    'resetSettingsBodyFull': 'All player, audio, subtitle, and general preferences will return to their defaults. History and playlists are not affected.',
    'popupPlayControls': 'Custom Pop-up Play Controls',
    'storageRoot': 'Storage',
    'noFolders': 'No folders',
    'couldNotLoadFiles': 'Could not load files',
    'couldNotLoadFolders': 'Could not load folders',
    'noVideosInFolder': 'No videos in this folder',
    'abPointASet': 'A point set — tap again to set B',
    'abRepeatOn': 'A-B repeat on',
    'abRepeatOff': 'A-B repeat off',
    'addedToFavourites': 'Added to favourites',
    'removedFromFavourites': 'Removed from favourites',
    'catVideos': 'Videos',
    'catImages': 'Images',
    'catAudio': 'Audio',
    'catFiles': 'Files',
    'catApps': 'Apps',
    'itemsCount': '{n} items',
    'filesCount': '{n} files',
    'appsCount': '{n} apps',
    'noItemsHere': 'Nothing here',
    'loadingApps': 'Reading installed apps…',
    'appsUnavailable': 'Couldn\'t read installed apps on this device.',
    'shareFile': 'Share',
    'unlockToLibrary': 'Unlock',
    'addedToTransfer': 'Added to Transfer',
    'selectFilesToAdd': 'Select Files To Add',
    'selectFilesToSend': 'Select Files To Send',
    'newPin': 'New PIN',
    'confirmPin': 'Confirm PIN',
    'pinLabel': 'PIN',
    'currentPin': 'Current PIN',
    'confirmNewPin': 'Confirm new PIN',
    'pinMin4': 'PIN must be at least 4 digits',
    'pinsDontMatch': 'PINs do not match',
    'newPinMin4': 'New PIN must be at least 4 digits',
    'newPinsDontMatch': 'New PINs do not match',
    'currentPinIncorrect': 'Current PIN incorrect',
    'incorrectPin': 'Incorrect PIN',
    'tooManyAttemptsWait': 'Too many attempts — wait {s}s',
    'biometricNotEnrolled': 'No biometric enrolled on this device',
    'biometricEnrollFirst': 'No biometric enrolled — set one in Android Settings first.',
    'unlockPrivateReason': 'Unlock Private Folder',
    'unlockHint': 'Enter your PIN to continue',
    'biometricSubtitle': 'Skip PIN entry with fingerprint or face. PIN remains as fallback.',
    'mediaPermissionNeeded': 'Allow access to your media',
    'mediaPermissionHint': 'Innocent needs permission to show your photos and audio here.',
    'grantAccess': 'Grant access',
    'layoutSection': 'Layout',
    'layoutList': 'List',
    'layoutGrid': 'Grid',
    'allFilesAccessNeeded': 'Allow access to all files',
    'allFilesAccessHint': 'To browse files here, Innocent needs "All files access". You\'ll flip a switch in Android settings, then tap back.',
    'noFilesInFolder': 'No files in this folder',
    'allFiles': 'All Files',
    'newFolder': 'New Folder',
    'createFolderTitle': 'Create folder',
    'folderName': 'Folder name',
    'renameFolderTitle': 'Rename folder',
    'deleteFolderTitle': 'Delete folder?',
    'deleteFolderBody': 'Items inside will move back to the main Private Folder — nothing is deleted.',
    'moveToFolder': 'Move to folder',
    'moveHere': 'Move here',
    'mainFolder': 'Private Folder',
    'chooseFolder': 'Choose a folder',
    'addToExisting': 'Add to existing folder',
    'verifyToLock': 'Verify to lock',
    'searchFilesHint': 'Search files…',
    'emptyFolder': 'This folder is empty',
    'foldersHeader': 'Folders',
    'catAll': 'All',
    'chooseFolderTitle': 'Add to which folder?',
    'mainFolderRoot': 'Main folder',
    'newFolderEllipsis': 'New folder…',
    'lockCancelled': 'Locking cancelled',
    'foldersTitle': 'Folders',
    'refreshingVault': 'Refreshing…',
    'moreOptions': 'More',
    'resumeVault': 'Resume',
    'nothingToResume': 'Nothing to resume yet',
    'viewModeFolders': 'View: Folders',
    'viewModeFiles': 'View: Files',
    'deletePermanently': 'Delete permanently',
    'deletePermanentlyTitle': 'Delete permanently?',
    'deletePermanentlyBody': 'This file will be permanently deleted from the vault and cannot be recovered.',
    'fileDeleted': 'File deleted',
    'selectedCount': '{n} selected',
    'selectAll': 'Select all',
    'moveSelected': 'Move',
    'unlockSelected': 'Unlock',
    'deleteSelected': 'Delete',
    'deleteSelectedTitle': 'Delete {n} files?',
    'deleteSelectedBody': 'These files will be permanently deleted from the vault and cannot be recovered.',
    'itemsUnlocked': '{n} files unlocked',
    'itemsMovedFolder': '{n} files moved',
    'renameEntry': 'Rename',
    'renameEntryTitle': 'Rename file',
    'entryNameHint': 'File name',
    'vaultStorageUsed': '{size} in vault',
    'viewModeLabel': 'View mode',
    'sortAndView': 'Sort & view',
    'deleteFolderChoiceBody': 'This folder contains {n} locked files. What would you like to do?',
    'deleteFolderWithItemsTitle': 'Delete folder with {n} items?',
    'unlockAndDeleteFolder': 'Keep files, delete folder',
    'unlockAndDeleteFolderSub': 'Files move back to the main vault',
    'deleteFolderAndFiles': 'Delete folder and files',
    'deleteFolderAndFilesSub': 'Everything inside is permanently erased',
    'folderDeleted': 'Folder deleted',
    'vaultFileMissing': 'File not found — it may have been removed',
    'someFilesFailed': '{n} file(s) couldn\'t be added',
    'filesAddedOk': '{n} file(s) added',
    'forgotPin': 'Forgot PIN?',
    'recoverVault': 'Recover vault access',
    'chooseRecoveryMethod': 'How would you like to recover?',
    'recoveryNotSetup': 'No recovery method is set up. The PIN can\'t be recovered.',
    'securityQuestion': 'Security question',
    'securityAnswer': 'Your answer',
    'setSecurityQuestion': 'Set security question',
    'chooseAQuestion': 'Choose a question',
    'wrongAnswer': 'That answer doesn\'t match',
    'answerRequired': 'Please enter your answer',
    'recoveryKey': 'Recovery key',
    'recoveryKeyGenerated': 'Save this recovery key',
    'recoveryKeyWarning': 'This is shown only once. Write it down and keep it somewhere safe — it\'s the only way back in if you forget your PIN and answer.',
    'enterRecoveryKey': 'Enter recovery key',
    'wrongRecoveryKey': 'That recovery key isn\'t valid',
    'copiedToClipboard': 'Copied',
    'iSavedIt': 'I\'ve saved it',
    'setNewPin': 'Set a new PIN',
    'pinResetSuccess': 'PIN reset. You\'re back in.',
    'setUpRecovery': 'Set up recovery',
    'recoveryOptions': 'Recovery options',
    'recoverySetupPrompt': 'Set up a way to recover your vault if you forget your PIN.',
    'skipForNow': 'Skip for now',
    'recoveryConfigured': 'Recovery is set up',
    'notConfigured': 'Not set up',
    'regenerateKey': 'Generate new key',
    'antiTheft': 'Anti-theft',
    'antiTheftDesc': 'Protect your vault if your phone is taken or forced open.',
    'decoyPin': 'Decoy PIN',
    'decoyPinDesc': 'A second PIN that opens an empty vault. Use it if someone forces you to unlock.',
    'setDecoyPin': 'Set decoy PIN',
    'decoyPinSet': 'Decoy PIN is set',
    'decoySameAsReal': 'Decoy PIN must differ from your real PIN',
    'removeDecoyPin': 'Remove decoy PIN',
    'intruderSelfie': 'Intruder selfie',
    'intruderSelfieDesc': 'Silently take a photo with the front camera after 3 wrong PIN attempts.',
    'breakInAttempts': 'Break-in attempts',
    'noBreakIns': 'No break-in attempts recorded',
    'clearLog': 'Clear log',
    'clearLogConfirm': 'Delete all break-in records and photos?',
    'photoUnavailable': 'No photo',
    'secQ1': 'What was the name of your first pet?',
    'secQ2': 'What is your mother\'s maiden name?',
    'secQ3': 'What city were you born in?',
    'secQ4': 'What was the name of your first school?',
    'secQ5': 'What is your favourite book?',
    'secQ6': 'What was your childhood nickname?',
    'clearSelection': 'Clear selection',
    'lockInPrivateFolder': 'Lock in Private Folder',
    'movingToPrivate': 'Moving to Private Folder',
    'deletingFiles': 'Deleting',
    'noVideosToLock': 'No videos in the selected folders',
    'videosQueued': 'videos queued',
    'deleteFoldersTitle': 'Delete videos?',
    'deleteFoldersBody': 'This permanently deletes all videos in the selected folders.',
    'lockFoldersBody': 'Move all videos in the selected folders into the Private Folder?',
    'propSectionFile': 'File',
    'propSectionMedia': 'Media',
    'propSectionPlayback': 'Playback history',
    'propFile': 'File',
    'propLocation': 'Location',
    'propSize': 'Size',
    'propDate': 'Date',
    'propFormat': 'Format',
    'propResolution': 'Resolution',
    'propLength': 'Length',
    'propBitrate': 'Bit rate',
    'propFinished': 'Finished',
    'propFinishedYes': 'Finished',
    'propFinishedNo': 'Not finished',
    'propLastPosition': 'Last position',
    'okay': 'Okay',
    'cancelling': 'Cancelling…',
    'downloaderTitle': 'Downloader',
    'downloaderSettings': 'Downloader settings',
    'downloaderPasteHint': 'Paste a video link',
    'downloaderPaste': 'Paste',
    'downloaderClipboardFound': 'Link found in clipboard',
    'downloaderDismiss': 'Dismiss',
    'downloaderActive': 'Downloads',
    'downloaderTabBrowse': 'Browse',
    'downloaderEmptyDownloads': 'No downloads yet',
    'downloaderEmptyDownloadsHint':
        'Paste a link above, or open Browse to pick a site.',
    'downloaderClear': 'Clear',
    'downloaderFavourite': 'Favourite',
    'downloaderRecommended': 'Recommended',
    'downloaderRestricted': 'Restricted sites',
    'downloaderQueued': 'Queued',
    'downloaderPreparing': 'Preparing',
    'downloaderFinalizing': 'Finalizing…',
    'downloaderSetIcon': 'Set icon',
    'downloaderRemoveIcon': 'Remove icon',
    'downloaderIconFailed': "Couldn't set the icon",
    'downloaderIconHint': 'Tip: long-press a site to set its own icon.',
    'downloaderSaved': 'Saved',
    'downloaderCancelled': 'Cancelled',
    'downloaderFailed': 'Failed',
    'downloaderPlay': 'Play',
    'downloaderDownload': 'Download',
    'downloaderEnginePreparing': 'Preparing download engine on first use…',
    'downloaderEngineFailed': 'Download engine unavailable',
    'downloaderNoMerger': 'Merger unavailable — only combined qualities are listed',
    'downloaderSavePath': 'Save to',
    'downloaderChange': 'Change',
    'downloaderShowRestricted': 'Show restricted sites',
    'downloaderRestrictedNote': 'Adult sites. Off by default.',
    'downloaderInvalidLink': 'That does not look like a link',
    'downloaderFetching': 'Reading link…',
    'downloaderNoFormats': 'No downloadable media found at this link',
    'downloaderSiteHint': 'Copy the video link there, then come back',
    'downloaderNoBrowser': 'No browser found to open this site',
    'downloaderDirFailed': 'Could not change the save folder',
    'downloaderAudio': 'Audio',
    'downloaderVideo': 'Video',
    'downloaderStream': 'Stream',
    'downloaderStreamFailed': 'Could not start streaming',
    'downloaderConvert': 'convert',
    'downloaderLiveNote': 'Live streams can be played but not downloaded',
    'downloaderStreamOnlyBest': 'Streaming uses the best combined quality',
    'downloaderStreamRefused':
        'This site would not let the video be played directly. Downloading it '
        'usually still works.',
    'downloaderErrRateLimited': 'Too many requests from this network',
    'downloaderRateLimitHint':
        'The site is asking us to slow down — this is about the network, not '
        'the video. Wait a few minutes, or switch between Wi-Fi and mobile '
        'data, then try again.',
    'downloaderRateLimitWait': 'Try again in about @m min',
    'downloaderAnySiteHint':
        'These are shortcuts, not limits — paste a link from almost any video '
        'site and it will be read the same way.',
    'downloaderBrowseDownload': 'Download video',
    'downloaderBrowseHint': 'Video found on this page.',
    'downloaderBrowseWorking': 'Reading the page…',
    'downloaderBrowsePick': 'Choose quality',
    'downloaderBrowseStarted': 'Added to downloads',
    'downloaderNeedsStorage': 'Allow saving to your Downloads folder',
    'downloaderNeedsStorageBody':
        'Android only lets an app write to the shared Downloads folder once '
        'you switch on All files access. Without it, videos are still saved — '
        'but into the app\'s own folder, where other apps cannot see them.',
    'downloaderGrantAccess': 'Open settings',
    'downloaderNoSound': 'no sound',
    'downloaderViewPage': 'View original page',
    'downloaderCopyLink': 'Copy link',
    'downloaderNoSourcePage': 'No source page was saved for this one',
    'downloaderDownloadAgain': 'Download again',
    'downloaderRemoveFromList': 'Remove from list',
    'downloaderSeeAll': 'See all',
    'downloaderHistoryTitle': 'Download history',
    'downloaderHistoryEmpty': 'Nothing has been downloaded yet',
    'downloaderRetryDownload': 'Try again',
    'downloaderMoreOptions': 'More',
    'downloaderBrowseStreams': 'Media found on this page',
    'downloaderBrowseUnreadable': 'This video could not be read',
    'downloaderBrowseRetry': 'Try again',
    'downloaderBrowseSendScreen': 'Open in Downloads instead',
    'downloaderBrowseBlocked': 'This site would not load',
    'downloaderBrowseVpnHint': 'A VPN is on. YouTube and TikTok often refuse VPN addresses.',
    'downloaderBrowseDnsHint': 'Private DNS can unblock sites without a VPN',
    'downloaderBrowseMore': 'Look for more qualities…',
    'downloaderNetworkVpnOff': 'This site last worked with the VPN off',
    'downloaderNetworkVpnOn': 'This site last worked with the VPN on',
    'downloaderNetworkVpnNow': 'A VPN is on. YouTube and TikTok usually refuse VPN addresses.',
    'downloaderCheckNetwork': 'Check this network',
    'downloaderNetworkChecking': 'Checking this network…',
    'downloaderNetworkDnsBlocked': 'This network blocks the site by name. Private DNS fixes that — no VPN needed.',
    'downloaderNetworkDeeper': 'The block is not in the name lookup, so Private DNS will not help here. A VPN is the way in.',
    'downloaderNetworkUnknown': 'Could not compare resolvers — check the connection and try again.',
    'downloaderNetworkPrivateOn': 'Private DNS is already on',
    'downloaderNetworkNoVpnNeeded': 'With Private DNS on you can leave the VPN off, so YouTube keeps working too.',
    'downloaderBypassOpen': 'Open it anyway, without a VPN',
    'downloaderBypassHint': 'Innocent looks the address up itself',
    'downloaderVpnNotNeeded': 'The blocked sites open without a VPN now — turn it off and YouTube works too',
    'downloaderAlreadyHave': 'You have already downloaded this one',
    'downloaderYtWall': 'This video will not play on this network',
    'downloaderYtEmbed': 'Play without signing in',
    'downloaderYtSignInNow': 'Sign in to YouTube',
    'downloaderBotWallHint':
        'YouTube does not trust this network address. This is common on a VPN, '
        'because many people share one address. Turn the VPN off for YouTube, '
        'or sign in below — a signed-in account is trusted either way.',
    'downloaderSupportedSites': 'Works with over a thousand sites',
    'downloaderEdit': 'Edit',
    'downloaderUpdateEngine': 'Update engine',
    'downloaderUpdating': 'Updating engine…',
    'downloaderUpdated': 'Engine updated',
    'downloaderUpToDate': 'Engine is already up to date',
    'downloaderUpdateFailed': 'Engine update failed',
    'downloaderCookies': 'Cookies file',
    'downloaderCookiesNote': 'A cookies.txt export, for links that need a signed-in account',
    'downloaderPickCookies': 'Choose file',
    'downloaderRemove': 'Remove',
    'downloaderDetails': 'Details',
    'downloaderAdvanced': 'Advanced',
    'downloaderPlayerClients': 'Fallback players',
    'downloaderPlayerClientsNote': 'Tried only if a YouTube link is refused. Leave empty to skip.',
    'downloaderErrBot': 'YouTube is asking this device to prove it is not a bot.',
    'downloaderErrAccount': 'This link needs a signed-in account.',
    'downloaderErrNetwork': 'Could not reach the site. Check your connection.',
    'downloaderErrExtractor': 'The engine could not read this site — it may be out of date.',
    'downloaderErrUnsupported': 'No downloadable media found at this link.',
    'downloaderErrUnknown': 'Could not read this link.',
    'downloaderClearBar': 'Clear',
    'downloaderWatermark': 'watermark',
    'downloaderPause': 'Pause',
    'downloaderResume': 'Resume',
    'downloaderPaused': 'Paused',
    'downloaderRetrying': 'Reconnecting…',
    'downloaderRemaining': 'left',
    'downloaderInterrupted': 'Interrupted — tap resume to continue',
    'downloaderResumeAll': 'Resume all',
    'downloaderOf': 'of',
    'downloaderNoWatermark': 'no watermark',
    'downloaderPhotos': 'photos',
    'downloaderPhotoPost': 'Photo post',
    'downloaderSaveAll': 'Save all',
    'downloaderPhotosSaved': 'Photos saved',
    'downloaderSignIn': 'Sign in',
    'downloaderSignedIn': 'Signed in — trying the link again',
    'downloaderSessions': 'Signed-in sites',
    'downloaderSessionsNote': 'Sign in inside Innocent so links that need an account work',
    'downloaderSignOut': 'Sign out',
    'downloaderSignInFailed': 'Could not open the sign-in page',
    'downloaderFixAuto': 'Fix automatically',
    'downloaderPreparingSession': 'Getting a guest session…',
    'downloaderWifiOnly': 'Download on Wi-Fi only',
    'downloaderSavedFiles': 'Saved files',
    'downloaderShare': 'Share',
    'downloaderDeleteFile': 'Delete',
    'downloaderDeleteConfirm': 'Delete this file from your phone?',
    'downloaderDeleted': 'Deleted',
    'downloaderMissing': 'This file is no longer on the phone',
    'downloaderClearList': 'Clear list',
    'downloaderNotifsBlocked': 'Notifications are turned off, so downloads will run invisibly',
    'downloaderOpenSettings': 'Settings',
    'downloaderVideos': 'videos',
    'downloaderSelectAll': 'Select all',
    'downloaderSelectNone': 'Select none',
    'downloaderQueuedCount': 'added to the queue',
    'downloaderAskEveryTime': 'Ask every time',
    'downloaderBest': 'Best',
    'downloaderDefaultQuality': 'Default quality',
    'downloaderDefaultQualityNote': 'Pick one and a pasted link downloads without asking',
    'downloaderSubtitles': 'Subtitle languages',
    'downloaderSubtitlesNote': 'Comma separated, e.g. en,my — empty for none',
    'downloaderEmbedThumbnail': 'Put the cover image in the file',
    'downloaderEmbedMetadata': 'Save title and author in the file',
    'downloaderSpeedLimit': 'Speed limit',
    'downloaderUnlimited': 'Unlimited',
    'downloaderExtras': 'Extras',
    'downloaderWifiOnlyNote': 'Never spend mobile data without asking',
    'downloaderMetered': 'You are on mobile data',
    'downloaderDownloadAnyway': 'Download anyway',
    'downloaderLowSpace': 'Not enough free space for this download',
    'downloaderTapResume': 'Tap resume to download anyway',
    'downloaderAutoUpdate': 'Keep the engine updated',
    'downloaderAutoUpdateNote': 'Checks weekly, and again whenever a link is refused',
    'downloaderConfigUrl': 'Settings source',
    'downloaderConfigUrlNote': 'A JSON address Innocent reads fixes from, so sites that change can be repaired without a new app',
    'downloaderCopyDiagnostics': 'Copy diagnostics',
    'downloaderCopied': 'Copied — paste it wherever you are reporting the problem',
    'downloaderConfigNotSet': 'Not set',

    // --- App update (updater plan step 2) ---
    'settingsAppUpdate': 'App update',
    'updateInstalledVersion': 'Installed version',
    'updateLatestVersion': 'Latest version',
    'updateSize': 'Download size',
    'updateReleased': 'Released',
    'updateUpToDate': "You're on the latest version",
    'updateAvailable': 'An update is available',
    'updateCheckNow': 'Check now',
    'updateChecking': 'Checking...',
    'updateCheckFailed': 'Could not check for updates. Try again.',
    'updateNotConfigured': 'Update checking is not set up in this build.',

    // --- App update: the download (updater plan step 3) ---
    'updateDownload': 'Download update',
    'updateDownloading': 'Downloading...',
    'updateVerifying': 'Checking the download...',
    'updateDownloaded': 'Downloaded',
    // Never "verification failed" — plan section 6: that reads as an accusation.
    'updateDownloadDamaged': 'Download was damaged. Try again.',
    'updateDownloadMismatch': 'This update file does not match what the '
        'app was told to expect. Nothing is wrong with your connection — '
        'downloading it again would fetch the same file. Tap Check now; '
        'if it says the same thing, the release needs fixing.',
    'updateDownloadFailed': 'The download did not finish. Try again.',
    'updateDownloadWriteFailed': 'The file could not be written. The phone '
        'may have run out of space, or another app cleared this one''s '
        'temporary storage while it was downloading. Free some space and '
        'try again.',
    'updateDownloadRefused': 'The server refused the download',
    'updateNotEnoughSpace': 'Not enough space for this update.',
    'updateRetry': 'Try again',
    'updateNotificationTitle': 'Downloading update',
    // The partial is kept and the download resumes by itself, so this is a
    // held state, not an error. Never "Download failed".
    'updateWaitingForNetwork': 'Waiting for the network...',
    'updateKept': 'kept',
    'updateResumeNow': 'Resume now',
    'updateInstall': 'Install',
    'updateInstallChecking': 'Checking the file...',
    'updateInstallGone': 'The downloaded file is gone. Download it again.',
    'updateInstallNoHandler': 'This phone has no installer to open the update.',
    // Plan section 6, word for word. The signing key drifted: the update can
    // never install over the current build, and no amount of retrying helps.
    'updateInstallSignature':
        'This update could not be installed. Contact support.',
    'updateNow': 'Update',
    // Not "Cancel" and not "Later": this answer is remembered for this
    // version and only this version, and "Not now" says that honestly.
    'updateNotNow': 'Not now',
    // The only screen in the app the user cannot leave. It says what happened
    // and what fixes it, and it does not apologise or explain itself twice —
    // someone reading this is already blocked and wants the button.
    'updateRequired': 'Update required',
    'updateRequiredBody':
        'This version of Innocent can no longer be used. Install the update '
            'below to carry on.',
  };

  static const Map<String, String> _my = <String, String>{
    'trSharingNow': 'ဖိုင် {n} ခု ပို့နေသည် — ကြည့်ရန် နှိပ်ပါ',
    'trSharingComputer': 'ကွန်ပျူတာနဲ့ မျှဝေနေသည် — ကြည့်ရန် နှိပ်ပါ',
    'trViaWifi': 'Wi-Fi router ကနေ',
    'trReceivingNow': 'လက်ခံနေသည် — ကြည့်ရန် နှိပ်ပါ',
    'trConnectedTo': 'ချိတ်ဆက်ထားသည် — ကြည့်ရန် နှိပ်ပါ',
    'trResumeReceiving': 'Download တစ်ဝက်တစ်ပျက် ရပ်သွားသည် — ဆက်ရန် နှိပ်ပါ',
    'trShareWith': 'မျှဝေရန်',
    'trPc': 'PC',
    'trTablet': 'Tablet',
    'trSendAppShort': 'သူငယ်ချင်းဆီ app ကို ပို့ပါ — အင်တာနက် မလို',
    'trTurboOnShort': 'ဖွင့်ထား — ဖုန်းချင်း တိုက်ရိုက်၊ router မလို။ အမြန်ဆုံး။',
    'trTurboOffShort': 'ပိတ်ထား — Wi-Fi router ကနေ ပို့ပါမယ်',
    'trSettings': 'ပို့ခြင်း ဆက်တင်များ',
    'trHistoryEmpty': 'လက်ခံရရှိတဲ့ ဖိုင်တွေ ဒီမှာ ပေါ်ပါမယ်။',
    'trPcTitle': 'ကွန်ပျူတာ၊ iPhone၊ Tablet နဲ့ မျှဝေရန်',
    'trPcLead': 'တစ်ဖက်မှာ ဘာမှ install မလုပ်ရ — browser တစ်ခုပဲ လိုပါတယ်။ ဒီဖုန်းထဲက ဖိုင်တွေ download ဆွဲပါ၊ ဒါမှမဟုတ် ဖိုင်တွေကို page ပေါ် ဆွဲချပြီး ဖုန်းဆီ ပို့ပါ။',
    'trPcStep1Turbo': 'ကွန်ပျူတာ (သို့) iPhone ကို ဒီ Wi-Fi နဲ့ ချိတ်ပါ — ဒါမှမဟုတ် ကင်မရာနဲ့ ဒီ QR ကို scan ဖတ်ပါ',
    'trPcStep1Wifi': 'ကွန်ပျူတာ (သို့) iPhone ကို ဒီဖုန်းနဲ့ Wi-Fi တစ်ခုတည်းမှာ ချိတ်ပါ',
    'trPcStep2': 'သူ့ browser မှာ ဒီလိပ်စာကို ဖွင့်ပါ',
    'trPcStep3': 'ဖိုင်တွေ download ဆွဲပါ၊ ဒါမှမဟုတ် page ပေါ်ကို ဖိုင်တွေ ဆွဲချပြီး ဒီဖုန်းဆီ ပို့ပါ',
    'trPcConnected': '{n} ခု ချိတ်ထားသည်',
    'trPcSharingFiles': 'ဒီဖုန်းကနေ ဖိုင် {n} ခု မျှဝေနေသည်',
    'trPcStart': 'စတင်မည်',
    'trScanTitle': 'ပို့သူရဲ့ QR ကို scan ဖတ်ပါ',
    'trScanBody': 'တစ်ဖက်ဖုန်းမှာ "ပို့မယ်" ကို နှိပ်ပါ — QR ပေါ်လာပါမယ်။ Scan ဖတ်လိုက်တာနဲ့ ဖုန်းနှစ်လုံး တိုက်ရိုက် ချိတ်ဆက်ပါမယ်။',
    'trSendTitle': 'ပို့မယ်',
    'trReceiveTitle': 'လက်ခံမယ်',
    'subSecColor': 'အရောင်',
    'subSecBorder': 'ဘောင်',
    'subSecAppearance': 'အသွင်အပြင်',
    'sizeTiny': 'အသေးဆုံး',
    'sizeSmall': 'သေး',
    'sizeMedium': 'အလတ်',
    'sizeLarge': 'ကြီး',
    'sizeHuge': 'အကြီးဆုံး',
    'colourWhite': 'အဖြူ',
    'colourYellow': 'အဝါ',
    'colourCyan': 'စိမ်းပြာ',
    'colourGreen': 'အစိမ်း',
    'colourRed': 'အနီ',
    'colourBlack': 'အနက်',
    'borderNone': 'မရှိ',
    'borderOutline': 'အနားသတ်',
    'borderDropShadow': 'အရိပ်ကျ',
    'borderRaised': 'ဖောင်းကြွ',
    'borderDepressed': 'ချိုင့်ဝင်',
    'shadowSubtle': 'သိမ်မွေ့',
    'shadowDefault': 'မူလ',
    'shadowStrong': 'ပြင်းထန်',
    'bgTransparent': 'ဖောက်ထွင်းမြင်ရ',
    'bgTranslucent': 'တစ်ဝက်ဖောက်ထွင်း',
    'bgOpaque': 'အလင်းပိတ်',
    'alignLeft': 'ဘယ်',
    'alignCenter': 'အလယ်',
    'alignRight': 'ညာ',
    'subImproveStrokeDesc': 'စာတန်းထိုး အနားသတ်ကို အရည်အသွေးမြင့် ဖော်ပြပါ။ CPU အနည်းငယ် ပိုသုံးပါသည်။',
    // Subtitle Text / Subtitle Layout screens.
    'subFont': 'ဖောင့်',
    'subFontDefault': 'မူလ',
    'subFontSansSerif': 'Sans-serif',
    'subFontSerif': 'Serif',
    'subFontMonospace': 'Monospace',
    'subFontCustomEnter': 'စိတ်ကြိုက် (နာမည် ရိုက်ထည့်ရန်)…',
    'subFontCustom': 'စိတ်ကြိုက် ဖောင့်',
    'subFontCustomHint': 'စက်ထဲမှာ တင်ထားတဲ့ ဖောင့်မိသားစု နာမည်၊ ဒါမှမဟုတ် .ttf / .otf ဖိုင်ရဲ့ လမ်းကြောင်း အပြည့်အစုံ ရိုက်ထည့်ပါ။',
    'subSize': 'အရွယ်အစား',
    'subFontSize': 'ဖောင့် အရွယ်အစား',
    'subBold': 'စာလုံးထူ',
    'subBoldDesc': 'စာတန်းထိုးကို စာလုံးထူနဲ့ ပြပါ။',
    'subTextColor': 'စာလုံး အရောင်',
    'subTextColorTitle': 'စာလုံး အရောင်',
    'subBorderStyle': 'ဘောင် ပုံစံ',
    'subBorderStyleTitle': 'ဘောင် ပုံစံ',
    'subBorderColor': 'ဘောင် အရောင်',
    'subBorderColorTitle': 'ဘောင် အရောင်',
    'subScale': 'အချိုးအစား',
    'subScaleTitle': 'စာတန်းထိုး အချိုးအစား',
    'subShadow': 'အရိပ်',
    'subBackground': 'နောက်ခံ',
    'subBackgroundColor': 'နောက်ခံ အရောင်',
    'subAlignment': 'နေရာချထားမှု',
    'subTextAlignment': 'စာလုံး နေရာချထားမှု',
    'subBottomMargins': 'အောက်ခြေ အကွာအဝေး',
    'subBottomMarginsTitle': 'အောက်ခြေ အကွာအဝေး',
    'subImproveStroke': 'အနားသတ် ဖော်ပြမှု တိုးတက်စေရန်',
    'subVerticalPos': 'ဒေါင်လိုက် တည်နေရာ',
    'subVerticalPosTitle': 'ဒေါင်လိုက် တည်နေရာ',
    'subVerticalPosDesc': 'အပေါ်ဘက်မှ အကွာအဝေး၊ ရာခိုင်နှုန်းအဖြစ်။',
    'subHorizontalAlign': 'အလျားလိုက် နေရာချထားမှု',
    'subHorizontalAlignTitle': 'အလျားလိုက် နေရာချထားမှု',
    'subSidePadding': 'ဘယ်/ညာ အကွာအဝေး',
    'subSidePaddingTitle': 'ဘယ်/ညာ အကွာအဝေး',
    'subSidePaddingDesc': 'အလျားလိုက် အကွာအဝေး၊ pixel အားဖြင့်။',
    'subBottomMargin': 'အောက်ခြေ အကွာအဝေး',
    'subBottomMarginTitle': 'အောက်ခြေ အကွာအဝေး',
    'subBottomMarginDesc': 'အောက်ခြေ အကွာအဝေး၊ pixel အားဖြင့်။',
    'subShowBackground': 'နောက်ခံ ပြရန်',
    'subBgBlack50': 'အနက် (၅၀% အလင်းပိတ်)',
    'subBgBlack75': 'အနက် (၇၅% အလင်းပိတ်)',
    'subBgDarkGray': 'မီးခိုးရင့်',
    'subBgColorActiveWhen': '"နောက်ခံ ပြရန်" ဖွင့်ထားမှသာ အလုပ်လုပ်ပါသည်။',
    'currently': 'လက်ရှိ',

    // --- Video Hub: age gate / library ---
    'vhGateTitle': 'ဤနေရာသည် အရွယ်ရောက်ပြီးသူများအတွက်သာ',
    'vhGateLead': 'အတွင်းရှိ အကြောင်းအရာအားလုံးသည် အရွယ်ရောက်ပြီးသူများအတွက်သာ ဖြစ်သည်။ ဆက်လက်မဝင်မီ အတည်ပြုပါ။',
    'vhGateTermsHeading': 'ဝင်ရောက်ခြင်းဖြင့် အောက်ပါတို့ကို အတည်ပြုသည်',
    'vhGateTerm1': 'သင်သည် အသက် ၁၈ နှစ် ပြည့်ပြီး ဖြစ်သည် (သို့) သင်နေထိုင်ရာဒေသ၏ တရားဝင်အရွယ်ရောက်ချိန် ပြည့်ပြီး ဖြစ်သည် - ပိုများသည့်အရာကို လိုက်နာသည်။',
    'vhGateTerm2': 'သင်ကိုယ်တိုင် ဆန္ဒအလျောက် ဝင်ရောက်ခြင်း ဖြစ်သည်။ မည်သူတစ်ဦးတစ်ယောက်၏ တွန်းအားပေးမှု၊ စေခိုင်းမှု၊ ဖိအားပေးမှုကြောင့် မဟုတ်ဘဲ အခြားသူတစ်ဦးအတွက် ကိုယ်စား ဝင်ရောက်ခြင်းလည်း မဟုတ်ပါ။',
    'vhGateTerm3': 'သင်ရှိရာဒေသတွင် အရွယ်ရောက်ပြီးသူဆိုင်ရာ အကြောင်းအရာများ ကြည့်ရှုခြင်းသည် တရားဝင်ကြောင်း သိရှိပြီး ထိုအတွက် တာဝန်ယူပါသည်။',
    'vhGateTerm4': 'အသက် ၁၈ နှစ်အောက် မည်သူ့ကိုမျှ ဤအကြောင်းအရာများ မပြသပါ။ ကလေးသူငယ် လက်လှမ်းမီရာနေရာတွင် app ကို ဖွင့်ထားခြင်း မပြုပါ။',
    'vhGateTerm5': 'app မှ အကြောင်းအရာများကို ကူးယူခြင်း၊ ရိုက်ကူးခြင်း၊ ပြန်လည်တင်ခြင်း၊ ဖြန့်ဝေခြင်း မပြုပါ။ အကြောင်းအရာအားလုံးသည် လိုင်စင်ရ ဖြစ်ပြီး မူပိုင်ရှင်များ၏ ပိုင်ဆိုင်မှုအဖြစ် ဆက်လက်တည်ရှိသည်။',
    'vhGateTerm6': 'ဤနေရာရှိ အကြောင်းအရာများကို အမှန်တကယ် ဖြစ်ရပ်များအဖြစ် မယူဆပါ။ ပါဝင်သူအားလုံးသည် အရွယ်ရောက်ပြီးသူများဖြစ်ပြီး ရိုက်ကူးမှုကို သဘောတူထားကြောင်း လက်ခံပါသည်။',
    'vhGateEnter': 'အသက် ၁၈ ပြည့်ပြီ - ဝင်မည်',
    'vhGateLeave': 'အသက် ၁၈ မပြည့်သေး - ထွက်မည်',
    'vhGateBlockedTitle': 'အရွယ်ရောက်မှ ပြန်လာပါ',
    'vhGateBlockedBody': 'ဤ app သည် အရွယ်ရောက်ပြီးသူများအတွက်သာ ဖြစ်၍ ဖွင့်၍မရပါ။ သင့်ဖုန်းတွင် ချွတ်ယွင်းချက် မရှိပါ။ ကလေးတစ်ဦး ဝင်ရောက်စေမည့်အစား လူတစ်ရာကို ငြင်းပယ်ရသည်က ပိုကောင်းပါသည်။',
    'vhGateMistake': 'မှားနှိပ်မိပါသည်',
    'destinationNoneAvailable': 'ရွှေ့ရန် အခြားဖိုလ်ဒါ မရှိပါ။',
    'noPlaylistsHint': 'Playlist မရှိသေးပါ။ Me → Video Playlists တွင် ဖန်တီးပါ။',
    'confirmBinBody': '{n} ကို Recycle Bin သို့ ပို့မလား။ Me မှ ပြန်ယူနိုင်ပါသည်။',
    'confirmLockBody': '{n} ကို Private Folder သို့ ပို့မလား။ စာရင်းများမှ ဖယ်ရှားသွားပါမည်။',
    'movedToBin': '{n} ကို Recycle Bin သို့ ပို့ပြီးပါပြီ',
    'lockedCount': '{n} ကို Private Folder သို့ ပို့ပြီးပါပြီ',
    'addedToPlaylist': '{n} ကို “{name}” သို့ ထည့်ပြီးပါပြီ',
    'renamedOk': 'အမည် ပြောင်းပြီးပါပြီ',
    'deletedOk': 'ဖျက်ပြီးပါပြီ',
    'lockingNow': 'Private Folder သို့ ပို့နေသည်…',
    'movedToPrivate': 'Private Folder သို့ ပို့ပြီးပါပြီ',
    'searchNoMatches': 'ရှာဖွေမှုနှင့် ကိုက်ညီသည့်အရာ မရှိပါ',
    'search': 'ရှာဖွေရန်',
    'pickerShowHidden': 'ဖျောက်ထားသော ဖိုလ်ဒါများ ပြရန်',
    'pickerHideHidden': 'ဖျောက်ထားသော ဖိုလ်ဒါများ ဖျောက်ရန်',
    'size': 'အရွယ်အစား',
    'duration': 'ကြာချိန်',
    'videos': 'ဗီဒီယို',
    'folders': 'ဖိုလ်ဒါ',
    'setPinFirst': 'Private Folder PIN ကို အရင်သတ်မှတ်ပါ (Me → Private Folder)',
    'connectAdbToSend': 'Android/data ဗီဒီယိုများ ပို့ရန် ADB ချိတ်ဆက်ပါ',
    'adbStepsTitle': 'ပြင်ဆင်မှု အခြေအနေ',
    'adbStepDevOptions': 'Developer options ဖွင့်ပြီး',
    'adbStepWifi': 'Wi-Fi ချိတ်ထားပြီး (internet မလိုပါ)',
    'adbStepWireless': 'Wireless debugging ဖွင့်ပြီး',
    'adbStepNotifications': 'Notification ခွင့်ပြုပြီး — code ကို notification ထဲမှာ ရိုက်ထည့်ရပါမယ်',
    'adbStepPaired': 'Pair လုပ်ပြီး',
    'adbStepConnected': 'ချိတ်ဆက်ပြီး',
    'adbStepOpen': 'ဖွင့်ရန်',
    'adbStepHow': 'လုပ်နည်း',
    'adbWifiNeeded': 'Wireless debugging က Wi-Fi network ပေါ်မှာပဲ အလုပ်လုပ်ပါတယ်။ ဘယ် Wi-Fi မဆို ရပါတယ် — internet မလိုပါ။',
    'adbTipXiaomi': 'Xiaomi၊ Redmi၊ POCO: “Stay connected after a reboot” အတွက် Developer options ထဲက “USB debugging (Security settings)” ကိုပါ ဖွင့်ပါ — SIM ကတ်နဲ့ Mi account လိုပါတယ်။ Notification မှာ reply box မပေါ်ရင် notification ကို အောက်ကို ဆွဲချပြီး ချဲ့ကြည့်ပါ။',
    'adbTipOppo': 'OPPO၊ realme၊ OnePlus: pair ရပြီး ချိတ်ရာမှာ ရပ်နေရင် Wireless debugging ကို ပိတ်ပြီး ပြန်ဖွင့်ကာ Connect ကို နှိပ်ပါ။',
    'adbTipTranssion': 'TECNO၊ Infinix၊ itel: Innocent ကို background မှာ run ခွင့်ပေးပါ (battery settings သို့မဟုတ် Phone Master)။ မပေးရင် code မရိုက်ခင် pairing notification ပိတ်သွားနိုင်ပါတယ်။',
    'adbNotSupported': 'Wireless debugging အတွက် Android 11 နဲ့ အထက် လိုပါတယ်။',
    'hfTitle': 'ဝှက်ထားသော ဖိုင်များ',
    'hfHint': 'Telegram နဲ့ အခြား app ဖိုင်များ',
    'hfSettingsSub': 'Wireless debugging နဲ့ တစ်ကြိမ် pair လုပ်ပြီး Telegram နဲ့ အခြား app တွေရဲ့ ဖိုင်တွေကို ဖွင့်ကြည့်ပါ။',
    'hfApps': 'App များ',
    'hfQuick': 'Telegram download များ',
    'hfAll': 'အားလုံး',
    'hfVideos': 'ဗီဒီယို',
    'hfPhotos': 'ဓာတ်ပုံ',
    'hfAudio': 'အသံ',
    'hfDocs': 'Document',
    'hfEmpty': 'ဒီမှာ ဘာမှ မရှိပါ',
    'hfSend': 'Transfer နဲ့ ပို့မယ်',
    'hfFetching': 'Android/data ကနေ ယူနေပါတယ်…',
    'hfFileOf': '{n} ခုထဲက {i}',
    'hiddenBadge': 'ဝှက်ထား',
    'hfInApps': 'App တွေထဲက (Android/data)',
    'hfBucketPhotos': 'Telegram စတဲ့ app တွေက ဓာတ်ပုံ',
    'hfBucketAudio': 'Telegram စတဲ့ app တွေက အသံဖိုင်',
    'hfSkipped': 'Android/data ထဲက ဖိုင် {n} ခု ယူမရလို့ ချန်ခဲ့ပါတယ် — ADB ပြန်ချိတ်ပြီး ထပ်စမ်းပါ။',
    'hfConnectTitle': 'App တွေထဲက ဖိုင်တွေ ကြည့်ဖို့ ချိတ်ပါ',
    'hfConnectBody': 'အစက် (.) နဲ့စတဲ့ ဝှက်ဖိုလ်ဒါတွေ အခု ပြနေပါပြီ။ Telegram နဲ့ အခြား app တွေရဲ့ ဖိုလ်ဒါ (Android/data) တွေကိုတော့ Innocent ရဲ့ ADB ချိတ်ဆက်မှုနဲ့ ဖွင့်ရပါတယ် — တစ်ကြိမ် ချိတ်မလား?',
    'hfOpenAdb': 'ADB ချိတ်မယ်',
    'hfNotNow': 'နောက်မှ',
    'hfLive': 'ချိတ်ထားပြီ — Video tab မှာ ပြပါတယ်',
    'hfNoApp': 'ဒီဖုန်းမှာ ဒီဖိုင်အမျိုးအစားကို ဖွင့်နိုင်တဲ့ app မရှိပါ။ Share လုပ်မလား?',
    'hfPullFailed': 'Android/data ကနေ ယူလို့ မရပါ — ADB ချိတ်ထားသေးလား?',
    'adbScreenTitle': 'Android/data ဝင်ကြည့်ခြင်း',
    'adbHeroConnected': 'ချိတ်ဆက်ထားပါပြီ',
    'adbHeroConnectedSub': 'Innocent က Android/data ကို ဖွင့်ကြည့်နိုင်ပါပြီ။ ဖိုင်ကူးတာတွေ background မှာ ဆက်လုပ်ပြီး connection ပြုတ်သွားရင် ရပ်သွားတဲ့နေရာကနေ ပြန်ဆက်ပါတယ်။',
    'adbHeroOff': 'ယခု ချိတ်ဆက်မထားပါ',
    'adbHeroOffSub': 'ဖုန်းပြန်ဖွင့်တဲ့အခါ ဒါမှမဟုတ် Wi-Fi ပြောင်းတဲ့အခါ Wireless debugging က အလိုလို ပိတ်သွားတတ်ပါတယ်။ ပြန်ဖွင့်ပြီး ပြန်ချိတ်မယ် ကို နှိပ်ပါ — code အသစ် မလိုပါ။',
    'adbHeroNew': 'တစ်ကြိမ်ပဲ ပြင်ဆင်ရပါတယ် — ၁ မိနစ်ခန့်',
    'adbHeroNewSub': 'Android/data ကို ဖွင့်ဖို့ Innocent က ဒီဖုန်းရဲ့ ကိုယ်ပိုင် Wireless debugging ကို ချိတ်ပါတယ် — ကွန်ပျူတာ မလို၊ root မလိုပါ။',
    'adbHeroChecking': 'ချိတ်ဆက်မှုကို စစ်နေပါတယ်…',
    'adbReconnect': 'ပြန်ချိတ်မယ်',
    'adbCopyReport': 'Report ကူးမယ်',
    'adbSendReport': 'Report ပို့မယ်',
    'adbClearLog': 'Log ရှင်းမယ်',
    'adbReportCopied': 'Report ကူးပြီးပါပြီ — chat ထဲမှာ paste လုပ်ပါ',
    'adbReportSent': 'Report ပို့ပြီးပါပြီ။ ဒီ code ကို ပြောပြပါ:',
    'adbReportFailed': 'ပို့လို့ မရပါ — Report ကို ကူးပြီး ပို့ပါ',
    'adbReportCopyCode': 'Code ကူးမယ်',
    'adbReconnecting': 'ပြန်ချိတ်နေတယ် — Wireless debugging ရဲ့ port အသစ်ကို ရှာနေပါတယ်…',
    'adbPairedAlready': 'ဒီဖုန်းကို pair ပြီးသားပါ — code အသစ် မလိုပါ။ ပြုတ်သွားရင် Wireless debugging ကိုဖွင့်ပြီး ပြန်ချိတ်မယ် ကိုနှိပ်ပါ။',
    'adbPairAgain': 'ထပ် pair မယ်',
    'adbOpenWireless': 'Wireless debugging ကို ဖွင့်မယ်',
    'adbFindVideos': 'Android/data ထဲက ဗီဒီယိုတွေ ရှာမယ်',
    'adbPairTitle': 'ဒီဖုန်းကို pair လုပ်ပါ (ပထမအကြိမ်သာ)',
    'adbPairNotif': 'Notification ကနေ pair လုပ်မယ်',
    'adbPairNotifSub': 'ဒါကို နှိပ်ပြီး Wireless debugging ထဲမှာ “Pair device with pairing code” ကို နှိပ်ပါ။ ပေါ်လာတဲ့ ဂဏန်း ၆ လုံးကို Innocent notification ထဲ ရိုက်ထည့်ပါ။ Split screen မလိုပါ။',
    'adbPairWaiting': 'Notification ထဲမှာ code ရိုက်တာကို စောင့်နေပါတယ်…',
    'adbPairInApp': 'ဒါမှမဟုတ် code ကို ဒီမှာ ရိုက်ပါ (pairing dialog ကို မြင်နေအောင် ထားပါ):',
    'adbPairCodeLabel': 'Pairing code (ဂဏန်း ၆ လုံး)',
    'adbPairConnect': 'Pair လုပ်ပြီး ချိတ်မယ်',
    'adbConnect': 'ချိတ်မယ်',
    'adbStayTitle': 'ချိတ်ဆက်မှု မပြုတ်အောင်',
    'adbStayWifi': 'Wi-Fi တစ်ခုတည်းပေါ်မှာပဲ နေပါ။ Wireless debugging က ဖွင့်ခဲ့တဲ့ Wi-Fi နဲ့ပဲ ဆိုင်ပါတယ် — Wi-Fi ပြောင်းရင် ပိတ်သွားပါတယ်။',
    'adbStayBackground': 'ဖိုင်ကူးတာတွေက notification နဲ့အတူ background မှာ run ပြီး connection ပြုတ်ရင် ရပ်တဲ့နေရာကနေ ပြန်ဆက်ပါတယ်။',
    'adbStayTile': 'တစ်ချက်နှိပ်ရုံ switch: Developer options → “Quick settings developer tiles” → Wireless debugging ကို ဖွင့်ပါ။ ပြီးရင် quick settings panel ထဲမှာ ပေါ်နေပါမယ်။',
    'adbStayBattery': 'ဖုန်းတချို့က battery ချွေတာဖို့ ပိတ်ပစ်တတ်ပါတယ်။ Xiaomi၊ OPPO၊ realme၊ vivo၊ TECNO၊ Infinix တွေမှာ Innocent ရဲ့ battery usage ကို “Unrestricted” / “No restrictions” လုပ်ထားပါ။',
    'adbGuideTitle': 'ADB ကို ဘယ်လို ဖွင့်/ပိတ်ရမလဲ',
    'adbGuideOnTitle': 'ဖွင့်နည်း',
    'adbGuideOn1': 'Settings → About phone → “Build number” ကို ၇ ချက် ဆက်တိုက်နှိပ်ပါ (screen lock တောင်းရင် ထည့်ပါ)။ “Developer options” ပေါ်လာပါမယ်။',
    'adbGuideOn2': 'Developer options → “Wireless debugging” → On လုပ်ပြီး ဒီ Wi-Fi ပေါ်မှာ ခွင့်ပြုပါ။',
    'adbGuideOn3': 'ပထမအကြိမ်သာ: “Pair device with pairing code” ကို နှိပ်ပြီး ဂဏန်း ၆ လုံးကို Innocent notification ထဲ ရိုက်ပါ။',
    'adbGuideOffTitle': 'သုံးပြီးရင် ပိတ်နည်း',
    'adbGuideOff1': 'Developer options → “Wireless debugging” → Off (ဒါမှမဟုတ် quick settings tile)။ Pairing က မပျက်ပါဘူး — နောက်တစ်ခါ ပြန်ဖွင့်ပြီး Reconnect ကို နှိပ်ရုံပါပဲ။',
    'adbGuideOff2': 'Developer options ကို ပြန်ဖျောက်ချင်ရင် အပေါ်ဆုံးက main switch ကို ပိတ်ပါ။ ဖုန်းတချို့မှာ အခြား developer settings တွေပါ reset ဖြစ်သွားတတ်ပါတယ်။',
    'adbGuideSafety': 'Wireless debugging က pair လုပ်ထားတဲ့ device ကို ဒီဖုန်းကို ထိန်းချုပ်ခွင့်ပေးပါတယ်။ ယုံကြည်ရတဲ့ Wi-Fi ပေါ်မှာပဲ pair လုပ်ပြီး သုံးပြီးရင် ပိတ်ထားပါ။',
    'adbGuideWhereTitle': 'သင့်ဖုန်းမှာ ဘယ်နေရာမှာ ရှိလဲ',
    'adbGuideWhere': 'Samsung — Build number: About phone → Software information။ Developer options: Settings အောက်ဆုံးမှာ။\nXiaomi / Redmi / POCO — About phone ထဲက “OS version” (ဒါမှမဟုတ် “MIUI version”) ကို နှိပ်ပါ။ Developer options: Additional settings ထဲမှာ။\nOPPO / realme / OnePlus — About device → Version → Build number။ Developer options: System settings / Additional settings ထဲမှာ။\nvivo / iQOO — About phone → Software version။ Developer options: System management ထဲမှာ။\nTECNO / Infinix / itel၊ Pixel နဲ့ အခြားဖုန်းအများစု — About phone → Build number။ Developer options: System ထဲမှာ။',
    'adbAdvanced': 'အဆင့်မြင့်',
    'adbDetails': 'အသေးစိတ်',
    'adbAndroidDataTitle': 'Android/data ထဲက ဗီဒီယိုများ',
    'adbAndroidDataSub': 'Telegram နဲ့ အခြား app တွေက ဗီဒီယိုတွေကို Android/data နဲ့ Android/obb ထဲမှာ သိမ်းပါတယ်။ ချိတ်ပြီးတာနဲ့ Innocent က ရှာပြီး Local ထဲ ထည့်ပေးပါတယ်။',
    'adbFound': 'ဗီဒီယို {n} ခု တွေ့ပါတယ်',
    'adbLostTitle': 'Android/data ကို ကြည့်ဖို့ ADB ချိတ်ဆက်မှု လိုပါတယ်',
    'adbLostBody': 'ချိတ်ဆက်မှု ပြုတ်သွားပါတယ် — များသောအားဖြင့် Wireless debugging ပိတ်သွားလို့ပါ။ ပြန်ဖွင့်လိုက်ပါ၊ ချိတ်ဆက်မှု ပြန်ရတာနဲ့ ဒီ folder က အလိုလို ပွင့်လာပါမယ်။',
    'adbLostAction': 'ADB settings',
    'destinationIfExists': 'အမည်တူဖိုင် ရှိနှင့်ပြီးဖြစ်ပါက',
    'destinationKeepBoth': 'နှစ်ခုလုံး ထားရန်',
    'destinationSkip': 'ကျော်ရန်',
    'destinationOverwrite': 'ဖိလိုက်ရန်',
    'selectionMove': 'ရွှေ့ရန်',
    'selectionCopy': 'ကူးရန်',
    'selectionSelectAll': 'အားလုံး ရွေးရန်',
    'selectionDeselectAll': 'ရွေးချယ်မှု ဖျက်ရန်',
    'selectionMoveTitle': 'ရွှေ့မည့်နေရာ',
    'selectionCopyTitle': 'ကူးမည့်နေရာ',
    'selectionEditingOff': 'Settings → General → Allow editing တွင် ပိတ်ထားပါသည်',
    'selectionNoFiles': 'ဤဖိုင်များသည် စနစ်စီမံဖိုင်များဖြစ်၍ ရွှေ့/ကူး၍ မရပါ။',
    'selectionWorking': 'လုပ်ဆောင်နေသည်…',
    'selectionMoved': 'ရွှေ့ပြီးပါပြီ',
    'selectionCopied': 'ကူးပြီးပါပြီ',
    'selectionRebuilt': 'Scroll လုပ်သည်နှင့် thumbnail ပြန်ဆောက်ပါမည်',
    'selectionHidden': 'စာရင်းမှ ဖျောက်ထားပါသည်',
    'vhGateMistakeConfirmTitle': 'ပြန်မေးရမလား။',
    'vhGateMistakeConfirmBody': 'ခလုတ်မှားနှိပ်မိသည်ဆိုမှသာ ဆက်လုပ်ပါ။ ဤအပိုင်းကို အသုံးပြုရန် အသက် ၁၈ နှစ် ပြည့်ပြီးသူ ဖြစ်ရပါမည်။',
    'vhGateMistakeConfirmYes': 'ဟုတ်ကဲ့၊ မှားနှိပ်မိပါသည်',
    'vhSignInGoogle': 'Google ဖြင့် ဆက်လက်ဆောင်ရွက်ရန်',
    'vhSignInGoogleSoon': 'Google ဖြင့် ဝင်ရောက်ခြင်း မရသေးပါ။ ဖုန်းနံပါတ်ဖြင့် ဝင်ပါ။',
    'vhSignInGoogleFailed': 'Google ဖြင့် ဝင်ရောက်၍ မပြီးမြောက်ပါ။ ခဏနေ ပြန်ကြိုးစားပါ။',
    'vhSignInOr': 'သို့မဟုတ်',
    'vhLibraryBookmarks': 'သိမ်းထားသည်များ',
    'vhLibraryBookmarksHint': 'နောက်မှကြည့်ရန် သိမ်းထားသော ခေါင်းစဉ်များ',
    'vhLibraryDownloads': 'ဒေါင်းလုဒ်များ',
    'vhLibraryDownloadsHint': 'အင်တာနက်မလိုဘဲ အော့ဖ်လိုင်း ကြည့်ရန်',
    'vhDeleteDownloadBody':
        'ဤဒေါင်းလုဒ်ကို ဖုန်းထဲက ဖယ်ရှားမလား။ Premium သက်တမ်း ရှိနေသေးသ၍ '
        'ပြန်ဒေါင်းလုဒ် လုပ်လို့ ရပါတယ်။',
    'vhDiscardDownloadBody':
        'မပြီးသေးတဲ့ ဒီဒေါင်းလုဒ်ကို ပစ်မလား။ ဖုန်းထဲ ရောက်ပြီးသား '
        'အပိုင်းကို ဖျက်ပါလိမ့်မယ်။',
    'vhDownloadUnfinished': 'မပြီးသေးသည်များ',
    'vhDownloadQueued': 'အလှည့် စောင့်နေသည်',
    'vhDownloadPaused': 'ရပ်ထားသည်',
    'vhDownloadResuming': 'ဒေါင်းလုဒ် လုပ်နေသည်',
    'vhDownloadResume': 'ဆက်လုပ်',
    'vhDownloadPause': 'ခဏရပ်',
    'vhWatchNow': 'အခုကြည့်',
    'vhWatchNotYet':
        'ဒီဇာတ်ကားရဲ့ အစပိုင်း လုံလောက်စွာ မရောက်သေးပါ။ ခဏနေပြီး ထပ်စမ်းပါ။',
    'vhWatchIndexAtEnd': 'ဒီဇာတ်ကားကို Download ပြီးမှသာ ကြည့်လို့ရပါမယ်။',
    'vhWatchGone': 'ဒီ Download ကို ဖုန်းပေါ်မှာ ရှာမတွေ့ပါ။',
    'vhDownloadNoSpace':
        'ဖုန်းထဲ နေရာ မလုံလောက်ပါ။ နေရာ လွတ်ပေးပြီး ပြန်စပါ - '
        'ရောက်ပြီးသား အပိုင်းကို သိမ်းထားပါတယ်။',
    'vhDownloadGaveUp':
        'အင်တာနက် ခဏခဏ ပြတ်နေပါတယ်။ ရောက်ပြီးသား အကုန် သိမ်းထားပါတယ် - '
        'လိုင်းရတဲ့အခါ ဒေါင်းလုဒ်များ ထဲကနေ ဆက်လုပ်ပါ။',
    'vhDownloadWaitingSignal': 'အင်တာနက် ပြန်ရအောင် စောင့်နေသည်…',
    'vhDownloadReadyOffline': 'အော့ဖ်လိုင်း ကြည့်လို့ ရပါပြီ',
    'vhDownloadWifiOnly': 'Wi-Fi နဲ့သာ ဒေါင်းလုဒ်',
    'vhDownloadWifiOnlyHint':
        'မိုဘိုင်းဒေတာ မသုံးဘဲ Wi-Fi ရမှ ဒေါင်းပါမယ်။ ပုံမှန် ပိတ်ထားပါတယ် — '
        'အများစုမှာ စောင့်ရမယ့် Wi-Fi မရှိတာမို့။',
    'vhDownloadWifiOnlyBlocked':
        'Wi-Fi ရအောင် စောင့်နေပါတယ်။ ရောက်ပြီးသား အကုန် သိမ်းထားပါတယ် — '
        'အလိုအလျောက် ဆက်လုပ်ပါမယ်၊ ဒါမှမဟုတ် "Wi-Fi နဲ့သာ" ကို ပိတ်လိုက်ပါ။',
    'vhDownloadOnMobile': 'မိုဘိုင်းဒေတာ သုံးနေပါတယ်။',
    'vhDownloadWillResume': 'အလိုအလျောက် ဆက်လုပ်ပါမယ်',
    'vhDownloadSizeAsk':
        'ဒီဇာတ်ကားက {size} ရှိပါတယ် — quality အပြည့်နဲ့ ဒေါင်းမှာပါ။ '
        'ဖုန်းထဲ {free} လွတ်ပါတယ်။ ဆက်လုပ်မလား?',
    'vhDownloadStart': 'ဒေါင်းလုဒ်',
    'vhDlQualityTitle': 'ဒေါင်းလုဒ် အရည်အသွေး',
    'vhDlQualityOriginal': 'မူရင်း (အကောင်းဆုံး)',
    'vhDlQualityRemember': 'ဒီရွေးချယ်မှုကို မှတ်ထားမယ်',
    'vhDlQualityFree': 'ဖုန်းထဲမှာ {free} လွတ်ပါသေးတယ်',
    'vhDlQualityHint': 'အရွယ်သေးတဲ့ ဖိုင်က ဒေတာနဲ့ နေရာ သက်သာပါတယ်။ မူရင်းက ရုပ်ထွက် အကောင်းဆုံးပါ။',
    'vhDlQualityAsk': 'အမြဲ မေးပါ',
    'vhDownloadStorageLine': 'ဖုန်းထဲမှာ',
    'vhDownloadLeftSoon': '၁ မိနစ်အောက် ကျန်',
    'vhDownloadLeftMinutes': '{m} မိနစ် ကျန်',
    'vhDownloadLeftHours': '{h} နာရီ {m} မိနစ် ကျန်',
    'vhDownloadLeftAges': '၁ ရက်ထက် ပိုကျန်',
    'vhDownloadStorage': '{used} သုံးပြီး - {free} လွတ်',
    'vhLibrarySoon': 'မကြာမီ ရရှိမည်',

    // --- Video Hub: view counts ---
    'vhViewsCount': 'ကြည့်ရှုမှု {n}',

    // --- Video Hub: account / KPay payment ---
    'vhSignInTitle': 'အကောင့်ဝင်ရန်',
    'vhSignInWhy': 'ငွေပေးချေမှုကို သင့်အကောင့်နှင့် တွဲနိုင်ရန် အကောင့်ဝင်ပါ။ ဖုန်းနံပါတ်ကို subscription အတည်ပြုရန်သာ သုံးပါသည်။',
    'vhSignInPhoneHint': '09xxxxxxxxx',
    'vhSignInCodeHint': 'ဂဏန်း ၆ လုံး ကုဒ်',
    'vhSignInSendFailed': 'ကုဒ် မပို့နိုင်ပါ။ ခဏနေ ထပ်ကြိုးစားပါ။',
    'vhSignInNoConnection': 'အင်တာနက် မရှိပါ။ ချိတ်ဆက်မှုကို စစ်ပြီး ထပ်ကြိုးစားပါ။',
    'vhSignInSendCode': 'ကုဒ် ပို့ရန်',
    'vhSignInVerify': 'အတည်ပြုရန်',
    'vhSignInBadPhone': 'ဖုန်းနံပါတ် မှန်ကန်စွာ ထည့်ပါ',
    'vhSignInBadCode': 'ကုဒ် မမှန်ပါ',
    'vhSignOut': 'ထွက်ရန်',
    'vhAccountTitle': 'အကောင့်',
    'vhAccountFreePlan': 'အခမဲ့ အစီအစဉ်',
    'vhAccountRequests': 'ငွေပေးချေမှု တောင်းဆိုချက်များ',
    'vhRequestPending': 'တင်ပြီး - စစ်ဆေးဆဲ',
    'vhRequestApproved': 'အတည်ပြုပြီး',
    'vhRequestRejected': 'ငြင်းပယ်ခံရ',
    'vhDevApprove': 'စက်တွင်း အတည်ပြုရန် (စမ်းသပ်ရန်သာ)',
    'vhPayTitle': 'KPay ဖြင့် ပေးချေရန်',
    'vhPayStep1': 'ဤ KPay အကောင့်သို့ ငွေလွှဲပါ',
    'vhPayStep2': 'KPay မှာ ငွေလွှဲပြီး ပြေစာကို screenshot ရိုက်ပါ',
    'vhPayStep3': 'ပြေစာ screenshot ကို ထည့်ပါ',
    'vhPayStep4': 'မှတ်ချက် ရေးရန် (မရေးလည်းရ)',
    'vhPayNoteHint': 'ဥပမာ — ညီမရဲ့ KPay ကနေ ည ၉ နာရီလောက်က လွှဲထားပါတယ်။ သိစေချင်တာ ရှိရင် ရေးပါ။',
    'vhPayPrivate': 'သင့်ပြေစာကို Innocent အဖွဲ့ကသာ မြင်ရပါသည်။',
    'vhPayNextTitle': 'နောက်ဘာဖြစ်မလဲ',
    'vhPayNext1': 'သင့်ပြေစာ ရောက်ရှိပါပြီ။',
    'vhPayNext2': 'KPay စာရင်းနဲ့ တိုက်စစ်ပါမယ်။',
    'vhPayNext3': 'Premium အလိုလို ပွင့်လာပါမယ် — Account မှာ မြင်ရပါမယ်။',
    'vhRequestYouWrote': 'သင်ရေးခဲ့သည်',
    'vhRequestReply': 'Innocent ထံမှ',
    'vhPayPayee': 'အကောင့်အမည်',
    'vhPayNumber': 'KPay နံပါတ်',
    'vhPayAmount': 'ပမာဏ',
    'vhPayCopied': 'ကူးယူပြီး',
    'vhPayReferenceHint': 'KPay လွှဲပြောင်းမှု ID',
    'vhPaySenderHint': 'ငွေလွှဲသည့် နံပါတ်',
    'vhPaySubmit': 'စစ်ဆေးရန် ပို့မည်',
    'vhPayManualNote': 'ငွေပေးချေမှုများကို KPay စာရင်းနှင့် လူကိုယ်တိုင် တိုက်စစ်သဖြင့် ချက်ချင်း အသက်မဝင်ပါ။',
    'vhPayOpenKpay': 'KPay ဖွင့်မည်',
    'vhPayNoKpay': 'ဒီဖုန်းမှာ KPay မရှိပါ။',
    'vhPayRecentShots': 'မကြာသေးခင်က screenshot များ — ပြေစာကို နှိပ်ပါ',
    'vhPayChooseShot': 'ဓာတ်ပုံထဲက screenshot ကို ရွေးမည်',
    'aboutTagline': 'သင့်ဗီဒီယိုတွေကို အကောင်းဆုံး ကြည့်ရှုနိုင်ဖို့',
    'aboutVersionFull': 'ဗားရှင်း {v} ({b})',
    'aboutCopied': 'ဗားရှင်းကို ကူးယူပြီးပါပြီ',
    'aboutCopyHint': 'ကူးယူရန် နှစ်ချက်နှိပ်ပါ',
    'aboutSectionApp': 'App',
    'aboutSectionSupport': 'အကူအညီ',
    'aboutSoftwareUpdate': 'App အပ်ဒိတ်',
    'aboutUpToDate': 'နောက်ဆုံးဗားရှင်းကို သုံးနေပါပြီ',
    'aboutUpdateReady': 'အသစ် ထွက်ပါပြီ',
    'aboutWhatsNew': 'ဒီဗားရှင်းမှာ ဘာအသစ်ပါလဲ',
    'aboutWhatsNewIn': '{v} မှာ ပါဝင်တဲ့ အသစ်များ',
    'aboutHelpFaq': 'အသုံးပြုနည်း လမ်းညွှန်',
    'aboutRights': '© 2026 Innocent — မူပိုင်ခွင့်အားလုံး ရယူထားသည်။',
    'vhPayShotAttached': 'ပြေစာ ထည့်ပြီးပါပြီ',
    'vhPayShotCheck': 'ငွေပမာဏနဲ့ လွှဲပြောင်းမှု မြင်ရရဲ့လား စစ်ပါ။',
    'vhPayShotChange': 'ပြောင်းမည်',
    'vhPayAddTxn': 'Transaction ID ထည့်မည် (မထည့်လည်းရ)',
    'vhPayNeedProof': 'ပြေစာ screenshot ထည့်ပါ၊ ဒါမှမဟုတ် Transaction ID ရိုက်ထည့်ပါ။',
    'vhPayTooMany': 'စစ်ဆေးဖို့ စောင့်နေတဲ့ ငွေပေးချေမှုတွေ ရှိနေပါပြီ။ ခဏစောင့်ပေးပါ။',
    'vhPayBadImage': 'ဒီဖိုင်ကို ဖတ်လို့မရပါ။ screenshot ကို ပြန်ရွေးပါ။',
    'vhPaySubmitFailed': 'ငွေပေးချေမှု အချက်အလက် မပို့နိုင်ပါ။ ဘာမှ မမှတ်တမ်းတင်ရသေးပါ - အင်တာနက် စစ်ပြီး ထပ်စမ်းပါ။',
    'vhPayDetailsStale': 'ဆာဗာသို့ မဆက်သွယ်နိုင်ပါ။ ဤအချက်အလက်များမှာ ဤဖုန်းတွင် နောက်ဆုံး သိမ်းထားသည့်များ ဖြစ်သည် - ငွေမပို့မီ သေချာစစ်ပါ။',
    'vhPayDetailsUnavailable': 'ငွေပေးချေမှု အချက်အလက်များ မရယူနိုင်ပါ။ ၎င်းတို့ မပေါ်မချင်း ငွေမပို့ပါနှင့်။',
    'vhPayQueuedTitle': 'ငွေပေးချေမှု တင်ပြီးပါပြီ',
    'vhPayQueuedBody': 'KPay စာရင်းနှင့် တိုက်စစ်ပြီး အကောင့်ကို အသက်သွင်းပေးပါမည်။ App ပိတ်ထားလည်း ရပါသည် - မှတ်တမ်း ကျန်နေပါမည်။',
    'vhPayDone': 'ပြီးပါပြီ',
    'vhSignInDevCode': 'စမ်းသပ် ဗားရှင်း: ကုဒ် {n} သုံးပါ',
    'vhAccountExpires': '{n} အထိ သက်တမ်းရှိ',

    // --- Video Hub: premium / paywall ---
    'vhPaywallTitle': 'Innocent Premium',
    'vhPaywallGeneric': 'ဗီဒီယိုအားလုံး၊ ပုံအားလုံးနှင့် အကောင်းဆုံး ကြည်လင်မှုကို ဖွင့်ပါ။',
    'vhPerkPlay': 'ဗီဒီယိုအားလုံး ကြည့်နိုင်သည်',
    'vhPerkMedia': 'နမူနာမဟုတ်ဘဲ ပုံနှင့် ကလစ် အားလုံး မြင်ရသည်',
    'vhPerkQuality': 'ရနိုင်သမျှ အကောင်းဆုံး ကြည်လင်မှု',
    'vhPlanYearly': 'တစ်နှစ်',
    'vhPlanYearlyNote': 'အတန်ဆုံး',
    'vhPlanMonthly': 'တစ်လ',
    'vhPaywallFinePrint': 'ဖော်ပြထားသည့် ကာလအတွက် တစ်ကြိမ်တည်း ပေးချေမှုဖြစ်သည်။ အလိုအလျောက် သက်တမ်း မတိုးပါ။ ဆက်လိုပါက ထပ်မံ ပေးချေပါ။',
    'vhPaywallNotNow': 'ယခု မလိုသေးပါ',
    'vhPremiumBadge': 'VIP',
    'vhLockedItem': 'Premium',
    'vhFreePreview': 'နမူနာ',
    'vhPremiumActive': 'Premium ဖွင့်ထားသည်',
    'vhUpgrade': 'အဆင့်မြှင့်ရန်',
    'vhPaywallLockedCount': 'ဤခေါင်းစဉ်တွင် ပုံနှင့် ဗီဒီယို {n} ခု ထပ်ဖွင့်ပါ။',
    'vhPaywallForTitle': '{n} ကို အပြည့်အစုံ ကြည့်ပါ။',
    'vhLockedCountShort': '{n} ခု ပိတ်ထား',

    // --- Video Hub: filter toolbar / hero ---
    'vhFilters': 'စစ်ထုတ်ရန်',
    'vhClearAll': 'အားလုံး ရှင်းရန်',
    'vhMoreInfo': 'အသေးစိတ်',
    'vhShowResults': '{n} ခု ကြည့်ရန်',
    'vhEpisodesCount': 'အပိုင်း {n} ပိုင်း',

    // --- Video Hub: see-all ---
    'vhSeeAll': 'အားလုံးကြည့်',
    'vhSortPopular': 'ကြည့်သူအများဆုံး',
    'vhTitlesCount': '{n} ခု',

    // --- Video Hub ---
    'vhVideoChip': 'ရုပ်ရှင်',
    'vhSearchHint': 'ရုပ်ရှင်၊ ဇာတ်လမ်းတွဲ၊ ကလစ် ရှာရန်',
    'vhCategoryAll': 'အားလုံး',
    'vhCategoryMovies': 'ရုပ်ရှင်',
    'vhCategorySeries': 'ဇာတ်လမ်းတွဲ',
    'vhCategoryReels': 'ကလစ်',
    'vhMore': 'ပိုမို',
    'vhRowTrending': 'လက်ရှိ ရေပန်းစား',
    'vhRowNewReleases': 'အသစ်ထွက်',
    'vhFilterGenre': 'အမျိုးအစား',
    'vhFilterYear': 'ခုနှစ်',
    'vhFilterQuality': 'ကြည်လင်ပြတ်သားမှု',
    'vhFilterSort': 'စီစဉ်ရန်',
    'vhFilterClear': 'ရှင်းရန်',
    'vhFilterAny': 'အားလုံး',
    'vhSortNewest': 'အသစ်ဆုံး',
    'vhSortTitle': 'အက္ခရာစဉ်',
    'vhNoContent': 'ဒီမှာ ဘာမှ မရှိသေးပါ။ အရင်းအမြစ် ချိတ်ဆက်ပြီးမှ ပေါ်လာပါမယ်။',
    'vhNoMatchingContent': 'ဒီ စစ်ထုတ်မှုနဲ့ ကိုက်ညီတာ မတွေ့ပါ။',
    'vhLoadFailed': 'အကြောင်းအရာ ဖွင့်၍ မရပါ',
    'vhOfflineBanner': 'အင်တာနက် မရှိပါ — သိမ်းထားသည့်အတိုင်း ပြထားသည်',
    'vhOfflineNothingSaved': 'အင်တာနက် မရှိပါ',
    'vhOfflineHint': 'တစ်ခါ ချိတ်ဆက်ပြီးရင် ဒီစာမျက်နှာကို သိမ်းထားပေးမှာပါ။ Download လုပ်ထားတာတွေက အင်တာနက် မလိုဘဲ ကြည့်လို့ရပါတယ်။',
    'vhOfflineNotHeld': 'အင်တာနက် မရှိပါ၊ ဒီဖလင်ကို ဖုန်းထဲမှာ သိမ်းထားတာ မရှိပါ',
    'vhBatteryDozeTitle': 'Screen ပိတ်ထားရင် Download ရပ်သွားနိုင်ပါတယ်',
    'vhBatteryDozeBody': '{maker} ဖုန်းတွေက ဘက်ထရီချွေတာဖို့ နောက်ကွယ်လုပ်ငန်းတွေကို ရပ်တန့်စေပါတယ်။ ဒါကြောင့် ဇာတ်ကားက အလယ်မှာ ရပ်သွားပြီး ဘာကြောင့်မှန်း မပြောပါဘူး။ ဒီ App ကို ဆက်လုပ်ခွင့်ပေးလိုက်ရင် ဖုန်းအိတ်ထဲထည့်ထားရင်းနဲ့ Download ပြီးအောင် ဆွဲပေးပါမယ်။',
    'vhBatteryAllow': 'နောက်ကွယ်မှာ Download ဆွဲခွင့်ပေးမည်',
    'vhBatteryBlockedTitle': 'ဒီ App အတွက် နောက်ကွယ်လုပ်ဆောင်ချက် ပိတ်ထားပါတယ်',
    'vhBatteryBlockedBody': 'App မဖွင့်ထားရင် ဘာမှ Download ဆွဲမှာ မဟုတ်ပါဘူး။ ဒါက ဖုန်းရဲ့ setting ဖြစ်ပြီး ဒီ App စာမျက်နှာထဲက Battery အောက်မှာ ရှိပါတယ် — ဒီကနေ ပြောင်းလို့ မရပါဘူး။',
    'vhBatteryOpenSettings': 'App setting ဖွင့်မည်',
    'vhOfflineReplayPartial': 'သိမ်းထားသလောက် ဖွင့်ပေးပါမည်။ သိမ်းထားတာ ကုန်သွားရင် ရပ်သွားပါမယ်။',
    'vhOfflineReplayNotEnough': 'အင်တာနက် မရှိဘဲ ဖွင့်ရန် သိမ်းထားတာ နည်းနေပါသည်',
    'vhOfflineReplayWholeFileOnly': 'ဒီဗီဒီယိုကို အကုန် သိမ်းမိမှသာ အင်တာနက် မရှိဘဲ ကြည့်လို့ရပါမည်',
    'vhRetry': 'ထပ်စမ်းရန်',
    'vhSearchPrompt': 'အမျိုးအစား အားလုံးထဲမှာ ရှာပါ',
    'vhSearchNoResults': 'ရှာမတွေ့ပါ',
    'vhAlbum': 'ပုံနှင့် ဗီဒီယို',
    'vhPlay': 'ဖွင့်ရန်',
    'vhUnavailable': 'ဒီအရာကို မဖွင့်နိုင်သေးပါ',
    'vhWrongDevice': 'သင့် subscription က အသက်ဝင်နေပါတယ်။ ဒါပေမယ့် ဒီဖုန်းက စာရင်းထဲ မပါသေးပါ။ မသုံးတော့တဲ့ စက်တစ်လုံးကနေ ထွက်ပြီးမှ ပြန်စမ်းကြည့်ပါ။',
    'clearAll': 'အားလုံး ရှင်းရန်',
    'setupPinConfirmHint': 'အတည်ပြုရန် တူညီတဲ့ PIN ကို နောက်တစ်ကြိမ် ထည့်ပါ။',
    'pinSetFailed': 'PIN သိမ်းဆည်းလို့ မရပါ။ ထပ်ကြိုးစားကြည့်ပါ။',
    'changePinCurrentHint': 'ဆက်လက်ဆောင်ရွက်ရန် လက်ရှိ PIN ကို ထည့်ပါ။',
    'changePinNewHint': 'ဂဏန်း ၄ လုံးမှ ၆ လုံးအထိ PIN အသစ် ရွေးပါ။',
    'changePinConfirmHint': 'PIN အသစ်ကို အတည်ပြုရန် ထပ်ထည့်ပါ။',
    'changePinFailed': 'PIN ပြောင်းလို့ မရပါ။ ထပ်ကြိုးစားကြည့်ပါ။',
    'vaultTemporarilyLocked': 'အမှားများစွာ ရိုက်ထည့်ခဲ့ပါတယ်။ အချိန်ကုန်သည်အထိ စောင့်ပါ။',
    'decoyPinEntryHint': 'ဒီ PIN က တကယ့် vault အစား ဗလာ vault ကို ဖွင့်ပေးပါမယ်။',
    'decoyPinConfirmHint': 'လှည့်စား PIN ကို အတည်ပြုရန် ထပ်ထည့်ပါ။',
    'vaultProgressSafeNote': 'မိတ္တူတစ်ခုချင်းစီ စစ်ဆေးပြီးသည်အထိ မူရင်းဖိုင်များ ဆက်ရှိနေပါမည်။',
    'lockingFiles': 'ဖိုင်များ လော့ချနေသည်',
    'notEnoughSpace': 'ဤဖိုင်များကို လော့ချရန် နေရာ မလုံလောက်ပါ။ နေရာလွတ်ပြီးမှ ပြန်စမ်းပါ။',
    'unlockingFiles': 'ဖိုင်များ ပြန်ထုတ်နေသည်',
    'importCancelled': 'ရပ်လိုက်ပါပြီ။ လော့ချပြီးသား ဖိုင်များ vault ထဲမှာ ရှိနေပါမည်။',
    'recoveryLockedOut': 'ကြိုးစားမှု များလွန်းပါပြီ။ နောက်မှ ပြန်ကြိုးစားပါ။',
    'autoLock': 'အလိုအလျောက် လော့ချခြင်း',
    'autoLockDesc': 'App မှ ထွက်ပြီးနောက် vault ဘယ်လောက်ကြာ ပွင့်နေမလဲ။',
    'autoLockImmediately': 'ချက်ချင်း',
    'screenCaptureBlocked': 'Screenshot ပိတ်ထားသည်',
    'screenCaptureBlockedDesc': 'Vault ဖွင့်ထားစဉ် screenshot ၊ screen record နှင့် app-switcher အစမ်းမြင်ကွင်းများကို ပိတ်ထားပါသည်။ အမြဲဖွင့်ထားသည်။',
    'loadingMore': 'ထပ်ဖွင့်နေသည်…',
    'appName': 'Innocent',
    'tabLocal': 'ဗီဒီယို',
    'tabMusic': 'ဂီတ',
    'tabTransfer': 'လွှဲပြောင်း',
    'tabMe': 'ကျွန်ုပ်',
    'settingsTitle': 'ဆက်တင်များ',
    'settingsList': 'စာရင်း',
    'settingsPlayer': 'ဖွင့်စက်',
    'settingsDecoder': 'Decoder',
    'settingsAudio': 'အသံ',
    'settingsSubtitle': 'စာတန်းထိုး',
    'settingsGeneral': 'အထွေထွေ',
    'settingsDevelopment': 'Development',
    'downloads': 'ဒေါင်းလုဒ်များ',
    'fileTransfer': 'ဖိုင်လွှဲပြောင်း',
    'privateFolder': 'ကိုယ်ရေးဖိုင်တွဲ',
    'videoPlaylists': 'ဗီဒီယို ဖွင့်စာရင်း',
    'mediaManager': 'မီဒီယာ စီမံခန့်ခွဲမှု',
    'localNetwork': 'ကွန်ရက်တွင်း',
    'networkStream': 'ကွန်ရက် Stream',
    'cloudDrive': 'Cloud Drive',
    'appTheme': 'အသွင်အပြင်',
    'popupPlay': 'Pop-up Play',
    'watchInsights': 'ကြည့်ရှုမှု အချက်အလက်',
    'legal': 'ဥပဒေရေးရာ',
    'backupRestore': 'အရန်သိမ်း/ပြန်ယူ',
    'quit': 'ထွက်ရန်',
    'quitConfirmTitle': 'Innocent မှ ထွက်မလား?',
    'quitConfirmBody': 'အက်ပ်ကို လုံးဝ ပိတ်ပါမည်။ လက်ရှိ ဖွင့်နေသည်များ ရပ်သွားပါမည်။',
    'statusSaver': 'Status Saver',
    'musicTracks': 'တေးသီချင်း',
    'musicAlbums': 'အယ်လ်ဘမ်',
    'musicArtists': 'အနုပညာရှင်',
    'musicFolders': 'ဖိုင်တွဲ',
    'noSongsToShuffle': 'ရောမွှေဖွင့်ရန် သီချင်းမရှိ',
    'noAlbumsFound': 'အယ်လ်ဘမ် မတွေ့ပါ',
    'noArtistsFound': 'အနုပညာရှင် မတွေ့ပါ',
    'noMusicFoldersFound': 'ဂီတဖိုင်တွဲ မတွေ့ပါ',
    'errorLoadingAlbums': 'အယ်လ်ဘမ် ဖွင့်၍မရ',
    'errorLoadingArtists': 'အနုပညာရှင် ဖွင့်၍မရ',
    'errorLoadingFolders': 'ဖိုင်တွဲ ဖွင့်၍မရ',
    'searchSongs': 'သီချင်း ရှာရန်...',
    'newPlaylist': 'ဖွင့်စာရင်းအသစ်',
    'playlistName': 'ဖွင့်စာရင်း အမည်',
    'create': 'ဖန်တီးရန်',
    'addToHomeScreen': 'ပင်မစာမျက်နှာသို့ ထည့်ရန်',
    'addedToHomeScreen': 'ပင်မစာမျက်နှာသို့ ထည့်ပြီး',
    'addWidget': 'Widget ထည့်ရန်',
    'widgetAdded': 'Widget ထည့်ပြီး',
    'resumePlaySettings': 'ဆက်ဖွင့် ဆက်တင်',
    'alwaysResume': 'အမြဲ ဆက်ဖွင့်',
    'askEveryTime': 'အမြဲ မေးရန်',
    'startFromBeginning': 'အစမှ ဖွင့်ရန်',
    'playingQueue': 'ဖွင့်နေသော စာရင်း',
    'aspectRatioMenu': 'အချိုး အစား',
    'displaySettings': 'ပြသမှု ဆက်တင်',
    'bookmark': 'မှတ်သား',
    'cut': 'ဖြတ်ရန်',
    'favourite': 'အကြိုက်',
    'addToPlaylistMenu': 'ဖွင့်စာရင်း ထည့်',
    'information': 'အချက်အလက်',
    'share': 'မျှဝေ',
    'tutorial': 'သင်ခန်းစာ',
    'subtitleDelayMenu': 'စာတန်းထိုး နှောင့်',
    'skipMarkers': 'အမှတ် ကျော်',
    'customSpeed': 'စိတ်ကြိုက် အမြန်',
    'loopOff': 'ထပ်ဖွင့် ပိတ်',
    'loopOne': 'တစ်ခု ထပ်ဖွင့်',
    'loopAll': 'အားလုံး ထပ်ဖွင့်',
    'subtitleOff': 'စာတန်းထိုး ပိတ်',
    'aspectRatioTitle': 'အချိုးအစား',
    'pressBackAgain': 'ပိတ်ရန် နောက်တစ်ကြိမ် နှိပ်ပါ',
    'playerQuality': 'အရည်အသွေး',
    'playerQualityAutoHint': 'အင်တာနက်လိုင်းအလိုက် အလိုအလျောက် ချိန်ပေးသည်',
    'playerQualityFailed': 'အရည်အသွေး မပြောင်းနိုင်ပါ။ လက်ရှိအတိုင်း ဆက်ပြနေပါသည်။',
    'vhAlbumDownloadAll': 'အားလုံး ဒေါင်းမည်',
    'vhAlbumDownloaded': 'ဒေါင်းပြီး',
    'vhAlbumDownloadNew': 'ဒေါင်းမည်',
    'vhAlbumPlusVideos': '+{n} Video',
    'vhAlbumPlusPhotos': '+{n} ပုံ',
    'vhAlbumProgress': '{done} / {total}',
    'vhCountOf': '{n} ခုမှ {i}',
    'vhResumeAt': '{t} ကနေ ဆက်ကြည့်',
    'vhStartOver': 'အစကပြန်ကြည့်',
    'vhMinutesLeft': 'ကျန် {m} မိနစ်',
    'vhRemoveFromContinue': 'ဆက်ကြည့်ရန်ထဲက ဖယ်မည်',
    'vhRemovedFromContinue': 'ဆက်ကြည့်ရန်ထဲက ဖယ်ပြီးပါပြီ',
    'vhMoreLikeThis': 'ဒီလိုမျိုး နောက်ထပ်',
    'vhUpNext': 'နောက်တစ်ခု',
    'vhUpNextIn': '{s} စက္ကန့်နေရင် နောက်တစ်ခု',
    'vhPlayNow': 'အခုဖွင့်မည်',
    'vhStillWatching': 'ဆက်ကြည့်နေတုန်းလား?',
    'vhKeepWatching': 'ဆက်ကြည့်မည်',
    'vhAlbumVideos': 'ဗီဒီယို {n} ခု',
    'vhAlbumPhotos': 'ဓာတ်ပုံ {n} ပုံ',
    'vhAlbumVideo1': 'ဗီဒီယို 1 ခု',
    'vhAlbumPhoto1': 'ဓာတ်ပုံ 1 ပုံ',
    'vhAlbumAsk': '{items}၊ မူရင်းအရည်အသွေးနဲ့ {size} ခန့်ရှိပါတယ်။ ဖုန်းထဲမှာ {free} ကျန်ပါတယ်။ ဆက်ဒေါင်းမလား?',
    'vhAlbumAskNoSize': '{items} ကို မူရင်းအရည်အသွေးနဲ့ ဒေါင်းပါမယ်။ ဖုန်းထဲမှာ {free} ကျန်ပါတယ်။ ဆက်ဒေါင်းမလား?',
    'vhAlbumSomeFailed': '{n} ခု ဒေါင်းမရပါ။ ပြန်ကြိုးစားရန် ဒေါင်းမည် ကို နှိပ်ပါ။',
    'vhSavedOffline': 'ဖုန်းထဲ သိမ်းပြီး',
    'vhSaveOffline': 'အော့ဖ်လိုင်းအတွက် သိမ်းမည်',
    'vhAlbumDeleteBody': 'ဒီ album ရဲ့ ဓာတ်ပုံနဲ့ ဗီဒီယိုတွေကို ဖုန်းထဲက ဖျက်မလား? ဒေါင်းထားတဲ့ ဇာတ်ကားကတော့ ကျန်ပါမယ်။',
    'vhDeleteItemBody': 'ဖုန်းထဲက ဖျက်မလား? နောက်မှ ပြန်ဒေါင်းလို့ ရပါတယ်။',
    'vhDataSaver': 'ဒေတာ ချွေတာမုဒ်',
    'vhDataSaverHint': 'Album တွေမှာ ဝါးဝါးလေးပဲ ပြပါမယ်။ လိုချင်တာကိုပဲ download ခလုတ်နှိပ်ပြီး ဖွင့်ပါ။',
    'vhDataSaverWifi': 'Wi-Fi မှာလည်း',
    'vhDataSaverWifiHint': 'ပိတ်ထားရင် Wi-Fi မှာ album တွေ ပုံမှန်အတိုင်း ပြပါမယ်။',
    'vhDataSaverOn': 'ဒေတာ ချွေတာမုဒ် ဖွင့်ထားသည် — ပုံမှန်ပြရန် နှိပ်ပါ',
    'vhDataSaverOff': 'ဒေတာ ချွေတာမုဒ် ဖွင့်မည်',
    'vhSaverChip': 'ချွေတာ',
    'vhDiagTitle': 'ပြဿနာ ပို့မယ်',
    'vhDiagHint': 'ပြင်ဆင်နိုင်ဖို့ app မှတ်ထားတာကို ပို့ပါ',
    'vhDiagBody': 'ဒီဖုန်းပေါ်က ဒေါင်းလုဒ်နဲ့ ဗီဒီယိုဖွင့်တာနဲ့ပတ်သက်ပြီး app မှတ်ထားတာ၊ ဖုန်းအမျိုးအစားနဲ့ အင်တာနက်အမျိုးအစားကို ပို့ပါမယ်။ Link၊ စကားဝှက်နဲ့ သင့်ဖိုင်တွေ ဘယ်တော့မှ မပါပါ။',
    'vhDiagNoteHint': 'ဘာဖြစ်သွားလဲ? (မရေးလည်းရ)',
    'vhDiagSent': 'ပို့ပြီးပါပြီ။ သင့် report code:',
    'vhDiagSentHint': 'ပြဿနာကို ပြောပြတဲ့အခါ ဒီ code ကို ပြောပေးပါ။',
    'vhDiagFailed': 'မပို့နိုင်ပါ။ အင်တာနက်စစ်ပြီး ပြန်စမ်းပါ။',
    'vhDiagCopied': 'Code ကူးပြီးပါပြီ',
    'vhSaverModeAll': 'အင်တာနက် အားလုံး',
    'vhSaverModeAllHint': 'WiFi ပါ — GB နဲ့ ဝယ်ရတဲ့ WiFi အတွက်',
    'vhSaverModeMobile': 'ဖုန်းဒေတာ သုံးချိန်သာ',
    'vhSaverModeMobileHint': 'WiFi ဆိုရင် album ကို ပုံမှန်အတိုင်း ပြပါမယ်',
    'vhSaverNowOn': 'ယခု ချွေတာနေသည် · {conn}',
    'vhSaverNowOff': '{conn} မှာ မချွေတာပါ',
    'vhConnWifi': 'WiFi',
    'vhConnMobile': 'ဖုန်းဒေတာ',
    'vhConnOffline': 'အော့ဖ်လိုင်း',
    'vhConnOther': 'ဒီ connection',
    'vhSaverBanner': 'ဒေတာ ချွေတာမုဒ် ဖွင့်ထားသည် — ပုံ/ဗီဒီယိုကို နှိပ်မှသာ ဖွင့်ပါမယ်',
    'vhSaverTurnOff': 'ပိတ်မယ်',
    'vhSaverHowTitle': 'ဘယ်လို အလုပ်လုပ်လဲ',
    'vhSaverHow1': 'Album တွေကို ဝေဝေဝါးဝါး preview လေးပဲ ပြပါမယ်။ အဲ့ဒါပြဖို့ ဘာမှ download မလုပ်ပါ။',
    'vhSaverHow2': 'ပုံနဲ့ ဗီဒီယိုတိုင်းမှာ size ပြထားပါတယ်။ လိုချင်တာကိုပဲ နှိပ်ပါ။',
    'vhSaverHow3': 'ဖွင့်ပြီးသားဟာ ဖုန်းထဲ ကျန်နေလို့ ဒုတိယအကြိမ် ဒေတာ မကုန်တော့ပါ။',
    'vhSaverHow4': 'Auto quality နဲ့ ကြည့်တဲ့ ရုပ်ရှင်တွေကို 480p အထိပဲ stream လုပ်ပါတယ်။',
    'vhLibraryDataSaverHint': 'Album မှာ နှိပ်တာကိုပဲ ဖွင့်ပါမယ်',
    'vhBookmark': 'သိမ်းမယ်',
    'vhBookmarked': 'သိမ်းပြီး',
    'vhBookmarkAdded': 'သိမ်းထားသည်များထဲ ထည့်ပြီးပါပြီ',
    'vhBookmarkRemoved': 'သိမ်းထားသည်များမှ ဖယ်ပြီးပါပြီ',
    'vhUndo': 'ပြန်ထည့်',
    'vhBookmarksEmpty': 'ဘာမှ မသိမ်းရသေးပါ။ ကြိုက်တဲ့ ဇာတ်ကားရဲ့ သိမ်းမယ် ခလုတ်ကိုနှိပ်ပြီး ဒီမှာ စုထားလို့ရပါတယ်။',
    'vhBookmarksSignInHint': 'အကောင့်ဝင်ထားရင် သိမ်းထားတာတွေ ဖုန်းတိုင်းမှာ ရှိနေပါမယ်။',
    'vhBookmarksCount': '{n} ခု သိမ်းထားသည်',
    'vhOn': 'ဖွင့်ထား',
    'vhEdit': 'ပြင်မယ်',
    'vhDownloadsActive': 'ဒေါင်းနေဆဲ',
    'vhDownloadYielding': 'ကြည့်နေတာကို ဦးစားပေးထားသည်',
    'vhDownloadsDone': 'ဒေါင်းပြီး',
    'vhDownloadsSettings': 'ဒေါင်းလုဒ် ဆက်တင်',
    'playerNoticeIncomplete': 'ဒီဖိုင်က အပြည့် download မဆွဲရသေးပါ။ {t} အထိပဲ ကြည့်လို့ရပါမယ်။',
    'playerNoticeSeekHeld': '{t} နောက်ပိုင်း download မဆွဲရသေးပါ။',
    'playerNoticeSoftware': 'ဒီဖိုင်မှာ Hardware decoder အလုပ်မလုပ်လို့ Software (SW) decoder နဲ့ ဆက်ဖွင့်ထားပါတယ်။',
    'playerNoticeHwUnavailable': 'ပျက်နေတဲ့ ဖိုင်ကြောင့် Hardware decoder ရပ်သွားပါတယ်။ ခဏ Software နဲ့ ဖွင့်ထားပါတယ် (နှေးပြီး ပူနိုင်ပါတယ်)။ Innocent ကို ပိတ်ပြီး ပြန်ဖွင့်ရင် ပြန်ကောင်းပါမယ်။',
    'playerNoticeEngineRestarted': 'အရင် video က တုံ့ပြန်မှု ရပ်သွားလို့ player ကို အသစ်ပြန်စထားပါတယ်။',
    'playerDamagedStretch': 'ဖိုင်ရဲ့ ဒီအပိုင်းက ပျက်နေတာ (သို့) download အပြည့် မဆွဲရသေးတာမို့ app မရပ်သွားအောင် ဒီနေရာမှာ ရပ်လိုက်ပါတယ်။ Retry နှိပ်ပါ (သို့) နောက်ပြန်ထွက်ပါ။',
    'playerEngineStuck': 'ဒီဖိုင်မှာ player တုံ့ပြန်မှု ရပ်သွားပါတယ်။ ဖိုင် ပျက်နေတာ (သို့) အပြည့် download မဆွဲရသေးတာ ဖြစ်နိုင်ပါတယ်။ Retry နှိပ်ပါ (သို့) နောက်ပြန်ထွက်ပြီး တခြား video ဖွင့်ပါ။',
    'close': 'ပိတ်ရန်',
    'audioTrack': 'အသံ လိုင်း',
    'subtitle': 'စာတန်းထိုး',
    'lockControls': 'ခလုတ်များ လော့ခ်',
    'refresh': 'ပြန်လည်ရယူ',
    'refreshingLibrary': 'မီဒီယာ ပြန်ရယူနေသည်...',
    'noVideosFound': 'ဗီဒီယို မတွေ့ပါ',
    'noVideosMatch': 'ကိုက်ညီသော ဗီဒီယို မရှိ',
    'resume': 'ဆက်ဖွင့်',
    'permissionRationale': 'သင့်စက်ရှိ ဗီဒီယိုများ ဖတ်ရန် Innocent သည် ခွင့်ပြုချက် လိုအပ်သည်။ သင့်ဒေတာကို ကျွန်ုပ်တို့ ဘယ်တော့မှ မစုဆောင်း၊ မတင်ပါ။',
    'permissionRationalePermanent':
        'သင့်စာကြည့်တိုက် စကင်ဖတ်ရန် Innocent သည် ဗီဒီယို ခွင့်ပြုချက် လိုအပ်သည်။ ဤနေရာမှ တောင်းဆိုချက် ပြန်မပြနိုင်တော့ပါ — အက်ပ် ဆက်တင်တွင် ဖွင့်ပြီး ပြန်လာပါ။ ဒေတာ မည်သည့်အခါမျှ သင့်စက်မှ ထွက်မသွားပါ။',
    'features': 'ဝိသေသများ',
    'faq': 'မေးလေ့ရှိသည်များ',
    'versionCheck': 'ဗားရှင်း စစ်ရန်',
    'sendBugReport': 'အမှား တင်ပြရန်',
    'privacy': 'ကိုယ်ရေးလုံခြုံမှု',
    'whatsNew': 'အသစ်များ',
    'bugReportHint':
        'developer ထံ feedback ပို့ရန် chat ရှိ thumbs-down ကို သုံးပါ။',
    'sortLabel': 'စီစဉ်ရန်',
    'ascending': 'ငယ်စဉ်ကြီးလိုက်',
    'descending': 'ကြီးစဉ်ငယ်လိုက်',
    'sortName': 'အမည်',
    'sortDate': 'ရက်စွဲ',
    'sortSize': 'အရွယ်အစား',
    'viewList': 'စာရင်း',
    'viewGrid': 'ဇယားကွက်',
    'history': 'မှတ်တမ်း',
    'favourites': 'အကြိုက်ဆုံးများ',
    'watchLater': 'နောက်မှ ကြည့်ရန်',
    'playlists': 'ဖွင့်စာရင်းများ',
    'recycleBin': 'အမှိုက်ပုံး',
    'chipCleaner': 'ရှင်းလင်းရန်',
    'chipPlaylists': 'ဖွင့်စာရင်း',
    'chipPrivate': 'လျှို့ဝှက်',
    'images': 'ဓာတ်ပုံ',
    'statistics': 'စာရင်းအင်း',
    'about': 'အကြောင်း',
    'help': 'အကူအညီ',
    'language': 'ဘာသာစကား',
    'retry': 'ပြန်ကြိုးစားရန်',
    'cancel': 'မလုပ်တော့ပါ',
    'ok': 'အိုကေ',
    'done': 'ပြီးပါပြီ',
    'comingSoon': 'မကြာမီ လာမည်',
    'playbackFailed': 'ဖွင့်၍မရပါ',
    'permissionGrant': 'ခွင့်ပြုချက် ပေးရန်',
    'permissionOpenSettings': 'ဆက်တင်ဖွင့်ရန်',
    'pipOverAppsTitle': 'အခြား App များပေါ်တွင် ဖွင့်ရန်',
    'pipOverAppsBody': 'Innocent မှ ထွက်ပြီးနောက် အခြား App များပေါ်တွင် ဗီဒီယိုကို ဆက်ဖွင့်ထားနိုင်ရန် ဆက်တင်ထဲက Innocent အတွက် Picture-in-picture ခွင့်ပြုချက်ကို ဖွင့်ပေးပါ။',
    // ── v0.49 full-coverage localization pass ──
    'delete': 'ဖျက်မယ်',
    'clear': 'ရှင်းမယ်',
    'reset': 'ပြန်လည်သတ်မှတ်',
    'save': 'သိမ်းမယ်',
    'rename': 'အမည်ပြောင်း',
    'restore': 'ပြန်ယူမယ်',
    'remove': 'ဖယ်ရှားမယ်',
    'apply': 'အသုံးပြုမယ်',
    'stop': 'ရပ်မယ်',
    'start': 'စတင်မယ်',
    'export': 'ထုတ်ယူမယ်',
    'importWord': 'ထည့်သွင်းမယ်',
    'move': 'ရွှေ့မယ်',
    'hide': 'ဖျောက်မယ်',
    'download': 'ဒေါင်းလုဒ်',
    'play': 'ဖွင့်မယ်',
    'playAll': 'အားလုံးဖွင့်မယ်',
    'shuffleAll': 'အားလုံးရောဖွင့်မယ်',
    'setWord': 'သတ်မှတ်',
    'add': 'ထည့်မယ်',
    'addNow': 'အခုထည့်မယ်',
    'connect': 'ချိတ်ဆက်မယ်',
    'disconnect': 'ချိတ်ဆက်မှုဖြုတ်မယ်',
    'gotIt': 'နားလည်ပါပြီ',
    'skip': 'ကျော်မယ်',
    'emptyVerb': 'ရှင်းလင်းမယ်',
    'clean': 'ရှင်းလင်းမယ်',
    'copyPath': 'လမ်းကြောင်းကူးမယ်',
    'errorWord': 'အမှား',
    'off': 'ပိတ်',
    'recent': 'မကြာသေးမီ',
    'properties': 'အချက်အလက်များ',
    'goBack': 'နောက်သို့',
    'unlock': 'သော့ဖွင့်မယ်',
    'lock': 'သော့ခတ်မယ်',
    'path': 'လမ်းကြောင်း',
    'newBadge': 'အသစ်',
    'failedToLoad': 'ဖတ်၍မရပါ',
    'versionOf': 'ဗားရှင်း {v}',
    'fullAccessAlready': 'Library အပြည့်ဝင်ရောက်ခွင့် ဖွင့်ထားပြီးသားပါ။',
    'fullAccessTitle': 'Library အပြည့် ဝင်ရောက်ခွင့် ဖွင့်မလား?',
    'fullAccessEnabled': 'Library အပြည့်ဝင်ရောက်ခွင့် ဖွင့်ပြီးပါပြီ။',
    'permissionNotGranted': 'ခွင့်ပြုချက် မရရှိပါ။ အချိန်မရွေး ပြန်ကြိုးစားနိုင်ပါတယ်။',
    'clearHistoryTitle': 'History ရှင်းမလား?',
    'clearHistoryBody': 'ဖွင့်ခဲ့တဲ့မှတ်တမ်းနဲ့ ရှာဖွေမှုမှတ်တမ်း အားလုံး ပျက်သွားပါမယ်။',
    'historyCleared': 'History ရှင်းပြီးပါပြီ',
    'clearThumbTitle': 'Thumbnail Cache ရှင်းမလား?',
    'clearThumbBody': 'Media စာရင်း ပြန်ဖွင့်တဲ့အခါ Thumbnail တွေ အသစ်ပြန်ဆွဲပါမယ်။',
    'thumbCleared': 'Thumbnail cache ရှင်းပြီးပါပြီ',
    'resetSettingsTitle': 'Settings ပြန်လည်သတ်မှတ်မလား?',
    'resetSettingsBody': 'Settings အားလုံး မူလအတိုင်း ပြန်ဖြစ်သွားပါမယ်။',
    'settingsResetDone': 'Settings မူလအတိုင်း ပြန်သတ်မှတ်ပြီးပါပြီ',
    'clearFontCacheTitle': 'Font Cache ရှင်းမလား?',
    'fontCacheCleared': 'Font cache ရှင်းပြီးပါပြီ',
    'languageRestartNote': 'App ပြန်ဖွင့်တဲ့အခါ ဘာသာစကား ပြောင်းပါမယ်',
    'exportedTo': '{path} သို့ ထုတ်ယူပြီးပါပြီ',
    'exportFailed': 'ထုတ်ယူ၍မရပါ',
    'importFailed': 'ထည့်သွင်း၍မရပါ',
    'importedFrom': '{path} မှ settings ထည့်သွင်းပြီးပါပြီ',
    'noExportFile': 'ထုတ်ယူထားတဲ့ settings ဖိုင် မတွေ့ပါ။ Export ကို အရင်သုံးပါ။',
    'moreLanguagesOnWay': 'နောက်ထပ် ဘာသာစကားများ ထပ်ထည့်ပေးသွားပါမယ်။',
    'colorFormat': 'အရောင် Format',
    'screenTitle': 'မျက်နှာပြင်',
    'navigationTitle': 'လမ်းညွှန်မှု',
    'controlsTitle': 'ထိန်းချုပ်မှုများ',
    'styleTitle': 'ပုံစံ',
    'subtitleTextTitle': 'စာတန်းထိုး စာသား',
    'subtitleLayoutTitle': 'စာတန်းထိုး နေရာချထားမှု',
    'soonBadge': 'မကြာမီ',
    'debugLogsExported': 'Debug log များ ထုတ်ယူပြီးပါပြီ',
    'findYourVideos': 'သင့်ဗီဒီယိုများကို ရှာပါ',
    'scanningVideos': 'ဗီဒီယိုများ ရှာဖွေနေသည်…',
    'errorLoadingFoldersPrefix': 'Folder များ ဖတ်၍မရပါ',
    'errorLoadingVideosPrefix': 'ဗီဒီယိုများ ဖတ်၍မရပါ',
    'loadingVideos': 'ဗီဒီယိုများ ဖတ်နေသည်…',
    'recentlyAdded': 'အသစ်ထည့်ထားသော',
    'continueWatching': 'ဆက်ကြည့်ရန်',
    'noContinueWatching': 'ဆက်ကြည့်ရန် ဗီဒီယို မရှိသေးပါ။',
    'removeContinueTitle': 'ဆက်ကြည့်ရန်စာရင်းမှ ဖယ်မလား?',
    'recentSearches': 'မကြာသေးမီက ရှာဖွေမှုများ',
    'eqDuringPlayback': 'Equalizer ကို ဖွင့်နေစဥ်အတွင်း သုံးနိုင်ပါတယ်',
    'magicPenHint': 'Magic Pen — AI လုပ်ဆောင်ချက်များ pro version တွင် ပါဝင်လာပါမယ်',
    'featuresIntro': 'Innocent တွင် ပါဝင်သည်များ:',
    'featuresBody': '• Hardware + Software decoding (HW/HW+/SW)\n• ရပ်ခဲ့တဲ့နေရာမှ ဆက်ကြည့်နိုင်ခြင်း\n• Background ဖွင့်ခြင်း + Picture-in-Picture\n• 10-band Equalizer + Bass Boost + Virtualizer + Reverb\n• စာတန်းထိုး ပုံစံပြင်ခြင်း (Font, Size, Color, Border, Shadow)\n• စာတန်းထိုး ရှာဖွေခြင်း + offline စာတန်းထိုး ထည့်ခြင်း\n• Touch gestures (ဆွဲ၍ seek/အလင်း/အသံ၊ ချုံ့ချဲ့ zoom)\n• Sleep timer + AB Repeat + Loop\n• Audio/Subtitle track ပြောင်းခြင်း\n• ဗီဒီယိုတစ်ခုချင်း ရွေးချယ်မှုများ မှတ်ထားခြင်း\n• Folder စုံ library + မကြာသေးမီဖွင့်ခဲ့သည်များ\n• Favourites / Watch Later / Playlists\n• Shuffle / Sort / Folders ပါ Music player\n• Tablet အတွက် တုံ့ပြန် UI',
    'faqQ1': 'မေး: ဗီဒီယို ဘာလို့ မဖွင့်တာလဲ?',
    'faqA1': 'ဖြေ: Decoder ပြောင်းကြည့်ပါ (player ကို ကြာကြာနှိပ် → Decoder → SW)။ တချို့ codec တွေက software decoding လိုပါတယ်။',
    'faqQ2': 'မေး: ပြင်ပ စာတန်းထိုးတွေ ဘယ်လိုထည့်ရမလဲ?',
    'faqA2': 'ဖြေ: .srt ဖိုင်တွေကို ဗီဒီယိုနဲ့ folder တစ်ခုတည်းမှာ ထားပါ၊ ဒါမှမဟုတ် Settings → Subtitle → Subtitle Folder မှာ လမ်းကြောင်း သတ်မှတ်ပါ။',
    'faqQ3': 'မေး: အသံနဲ့ရုပ် မကိုက်ရင် ဘယ်လိုပြင်ရမလဲ?',
    'faqA3': 'ဖြေ: Settings → Audio → Audio delay။ ဒါမှမဟုတ် player ထဲမှာ ကြာကြာနှိပ်ပြီး → Audio sync ကို သုံးပါ။',
    'faqQ4': 'မေး: ဖွင့်ပြီးရင် မျက်နှာပြင် ဘာလို့ မှိန်နေတာလဲ?',
    'faqA4': 'ဖြေ: Build 56 မှာ ပြင်ပြီးပါပြီ — player ပိတ်တဲ့အခါ အလင်းရောင် ပြန်ကောင်းသွားပါပြီ။',
    'privacyBody': 'Innocent သည် အင်တာနက်မလိုဘဲ လုံးဝ offline အလုပ်လုပ်ပါသည်။ Telemetry၊ analytics မကောက်ယူသလို ဘယ် server ကိုမှ data မပို့ပါ။ သင့် history၊ favourites နဲ့ playlists အားလုံး ဒီစက်ထဲမှာပဲ ရှိနေပါမယ်။',
    'aboutBody': 'MX Player ပုံစံအတိုင်း တည်ဆောက်ထားတဲ့ Android media player ဖြစ်ပြီး Flutter နဲ့ media_kit ကို အသုံးပြုထားပါတယ်။',
    'addSubtitleFromUrl': 'URL မှ စာတန်းထိုး ထည့်မယ်',
    'subtitleUrlTip': 'အကြံပြုချက်: OpenSubtitles.org မှာ "Download" link တိုက်ရိုက်ကို ကူးပါ (page URL မဟုတ်ပါ)။ Zip ဖိုင်ဆိုရင် အရင်ဖြည်ပါ။',
    'downloadingSubtitle': 'စာတန်းထိုး ဒေါင်းလုဒ်လုပ်နေသည်…',
    'downloadFailed': 'ဒေါင်းလုဒ် မအောင်မြင်ပါ',
    'moveToBinTitle': 'Recycle Bin ထဲ ရွှေ့မလား?',
    'deleteVideoTitle': 'ဗီဒီယို ဖျက်မလား?',
    'addToPlaylist': 'Playlist ထဲ ထည့်မယ်',
    'noPlaylistsYet': 'Playlist မရှိသေးပါ',
    'createNewPlaylist': 'Playlist အသစ် ဖန်တီးမယ်',
    'newPlaylistTitle': 'Playlist အသစ်',
    'playUsingHw': 'HW decoder နဲ့ ဖွင့်မယ်',
    'playUsingHwPlus': 'HW+ decoder နဲ့ ဖွင့်မယ်',
    'playUsingSw': 'SW decoder နဲ့ ဖွင့်မယ်',
    'hideSelectedHint': 'ရွေးထားတာတွေကို library မှ ဖျောက်မယ်',
    'rebuildThumbnail': 'Thumbnail ပြန်ဆွဲမယ်',
    'createdPlaylist': 'Playlist "{name}" ဖန်တီးပြီးပါပြီ',
    'renamePlaylist': 'Playlist အမည်ပြောင်းမယ်',
    'playlistEmpty': 'Playlist ထဲမှာ ဘာမှမရှိပါ',
    'deleteNameTitle': '"{name}" ကို ဖျက်မလား?',
    'deletedName': '"{name}" ကို ဖျက်ပြီးပါပြီ',
    'noCustomPlaylists': 'ကိုယ်ပိုင် playlist မရှိသေးပါ',
    'emptyBinTitle': 'Recycle bin ရှင်းမလား?',
    'binEmpty': 'Recycle Bin ထဲမှာ ဘာမှမရှိပါ။',
    'permDeleteTitle': 'အပြီးအပိုင် ဖျက်မလား?',
    'permDeleteBody': 'ဒီဖိုင်ကို Recycle Bin ထဲကနေ အပြီးအပိုင် ဖျက်ပါမယ်။',
    'restoredName': 'ပြန်ယူပြီး: {name}',
    'removedName': 'ဖယ်ရှားပြီး: {name}',
    'clearWatchLaterTitle': 'Watch Later ရှင်းမလား?',
    'clearWatchLaterBody': 'စာရင်းထဲက ဗီဒီယိုအားလုံး ဖယ်မလား?',
    'watchLaterEmpty': 'Watch Later စာရင်း ဗလာဖြစ်နေပါတယ်',
    'watchLaterHint': 'ဗီဒီယိုပေါ်က ⋮ ကိုနှိပ်ပြီး "Add to Watch Later" နဲ့ စာရင်းသွင်းနိုင်ပါတယ်။',
    'noHistoryYet': 'ကြည့်ရှုမှုမှတ်တမ်း မရှိသေးပါ',
    'noFavouritesYet': 'Favourite ဗီဒီယို မရှိသေးပါ။\nဗီဒီယိုပေါ်က ⋮ ကိုနှိပ်ပြီး "Favourite" ရွေးပါ',
    'unfavouritedName': 'Favourite မှ ဖယ်ပြီး: {name}',
    'yourWatchInsights': 'သင့် ကြည့်ရှုမှု အချက်အလက်များ',
    'noInsightsYet': 'အချက်အလက် မရှိသေးပါ',
    'totalTimeWatched': 'စုစုပေါင်း ကြည့်ရှုချိန်',
    'last7Days': 'နောက်ဆုံး ၇ ရက် (မိနစ်)',
    'mostRewatched': 'အပြန်ကြည့်အများဆုံး',
    'mostWatchedFolder': 'အကြည့်အများဆုံး folder',
    'averageCompletion': 'ပျမ်းမျှ ပြီးမြောက်မှု',
    'failedPickFiles': 'ဖိုင်ရွေး၍မရပါ',
    'send': 'ပို့မယ်',
    'receive': 'လက်ခံမယ်',
    'howTransferWorksTitle': 'ဖိုင်ပို့ခြင်း ဘယ်လိုအလုပ်လုပ်သလဲ',
    'howTransferWorksBody': 'Wi-Fi ကွန်ရက်တစ်ခုတည်းပေါ်က တခြားစက်ဆီ ဖိုင်ပို့တာဖြစ်ပြီး အင်တာနက် မလိုပါ။\n\n၁။ စက်နှစ်လုံးကို Wi-Fi တစ်ခုတည်း ချိတ်ပါ။\n၂။ ဒီစက်မှာ ဖိုင်ရွေးပြီး Start နှိပ်ပါ။\n၃။ တခြားစက်မှာ browser ဖွင့်ပြီး:\n   - ကင်မရာနဲ့ QR ကို scan လုပ်ပါ၊ ဒါမှမဟုတ်\n   - မျက်နှာပြင်ပေါ်က URL ကို ရိုက်ထည့်ပါ။\n၄။ တခြားစက်မှာ ဖိုင်စာရင်း ပေါ်လာပါမယ်။ ဖိုင်ကိုနှိပ်ပြီး ဒေါင်းလုဒ်လုပ်ပါ။\n\nဒီစက်မှာ Stop နှိပ်ရင် ပို့တာရပ်ပြီး URL ချက်ချင်း အလုပ်မလုပ်တော့ပါ။\n\nသတိပြုရန်:\n- Encrypt မလုပ်ထားပါ (LAN အတွင်းသာ)။ URL အပြည့်သိတဲ့ Wi-Fi ပေါ်ကလူတိုင်း ဒေါင်းလုဒ်လုပ်နိုင်ပါတယ်။\n- Mobile data နဲ့ အလုပ်မလုပ်ပါ။ Wi-Fi သာ။\n- Background မှာ ဆက်မလုပ်ပါ။ App ပိတ်ရင် ပို့တာလည်း ရပ်ပါတယ်။',
    'filesToShare': 'ပို့မယ့် ဖိုင်များ',
    'addFiles': 'ဖိုင်ထည့်မယ်',
    'noFilesHint': 'ဖိုင် မရှိသေးပါ။\n"ဖိုင်ထည့်မယ်" ကိုနှိပ်ပြီး ပို့မယ့်ဖိုင် ရွေးပါ။',
    'shareIsLive': 'ပို့နေပါပြီ',
    'shareScanHint': 'တခြားစက်မှာ QR ကို scan လုပ်ပါ ဒါမှမဟုတ် အောက်က URL ကို browser ထဲ ရိုက်ထည့်ပါ။',
    'urlCopied': 'URL ကူးပြီးပါပြီ',
    'stopSharing': 'ပို့တာ ရပ်မယ်',
    'cameraPermissionNeeded': 'QR scan ဖတ်ဖို့ ကင်မရာခွင့်ပြုချက် လိုပါတယ်',
    'scanQrCode': 'QR code ကို scan ဖတ်မယ်',
    'orEnterAddress': 'ဒါမှမဟုတ် လိပ်စာ ရိုက်ထည့်ပါ',
    'downloadAll': 'အားလုံး ဒေါင်းလုဒ်',
    'nearbyDevices': 'အနီးအနားက စက်များ',
    'lookingForPhones': 'အနီးအနားက ဖုန်းများကို ရှာနေသည်\u2026',
    'noPhonesFound': 'ဖုန်း မတွေ့သေးပါ။ တစ်ဖက်ဖုန်းမှာ File Transfer \u2192 Send ဖွင့်ပြီး share စတင်ပါ။',
    'tapDeviceToConnect': 'ချိတ်ဆက်ရန် ဖုန်းတစ်လုံးကို နှိပ်ပါ',
    'connectingToDevice': 'ချိတ်ဆက်နေသည်\u2026',
    'thisPhoneName': 'ဤဖုန်း',
    'renameThisPhone': 'ဤဖုန်းအမည် ပြောင်းရန်',
    'askBeforeSending': 'မပို့ခင် အတည်ပြုခိုင်းမည်',
    'askBeforeSendingHint': 'အခြားဖုန်းများ ဒေါင်းလုဒ်မလုပ်ခင် သင့်ခွင့်ပြုချက် လိုအပ်သည်။ အများသုံး Wi-Fi တွင် ပိုစိတ်ချရသည်။',
    'wantsToReceive': 'က သင့်ဖိုင်များကို လက်ခံလိုပါသည်',
    'accept': 'လက်ခံမည်',
    'decline': 'ငြင်းပယ်မည်',
    'waitingForReceiver': 'တစ်ဖက်ဖုန်းကို စောင့်နေသည်\u2026',
    'overallProgress': 'စုစုပေါင်း',
    'alreadyOnThisPhone': 'ဤဖုန်းတွင် ရှိပြီးသား',
    'cancelTransfer': 'ပို့ခြင်း ရပ်မည်',
    'hotspotTipBody': 'ဤဖုန်းမှာ hotspot ဖွင့်ပြီး တစ်ဖက်ဖုန်းကို ချိတ်ပါ (အင်တာနက် မလိုပါ)၊ ပြီးမှ share စတင်ပါ။ Router ကနေဆိုရင် ဒေတာက လေထဲမှာ နှစ်ကြိမ် ဖြတ်သန်းရလို့ အဆမတန် နှေးနိုင်သည်။',
    'directLinkActive': 'တိုက်ရိုက် ချိတ်ဆက်မှု \u2014 အမြန်ဆုံး',
    'viaRouterSlower': 'Wi-Fi router မှတဆင့် \u2014 hotspot က ပိုမြန်သည်',
    'allFilesReceived': 'ဖိုင်အားလုံး လက်ခံပြီးပါပြီ',
    'turboTitle': 'Turbo \u2014 တိုက်ရိုက် ချိတ်ဆက်မှု',
    'turboSubtitle': 'Router မှတဆင့်မဟုတ်ဘဲ ဖုန်းနှစ်လုံး တိုက်ရိုက်ချိတ်ပေးသည်၊ ဒေတာက လေထဲမှာ တစ်ကြိမ်ပဲ ဖြတ်ရသည်။ များစွာပိုမြန်ပြီး Wi-Fi ကွန်ရက် မလိုပါ။ ဖွင့်ထားစဉ် ဤဖုန်းတွင် အင်တာနက် ရမည်မဟုတ်ပါ။',
    'turboStarting': 'တိုက်ရိုက် ချိတ်ဆက်မှု စတင်နေသည်\u2026',
    'turboBadge5': 'Turbo 5 GHz \u2014 အမြန်ဆုံး',
    'turboBadge24': 'Turbo တိုက်ရိုက် ချိတ်ဆက်မှု (2.4 GHz)',
    'turboUnavailable': 'Turbo မစတင်နိုင်ပါ \u2014 ပုံမှန် Wi-Fi ဖြင့် ဆက်လက် share နေပါသည်။',
    'turboJoinManually': 'Innocent မရှိတဲ့ ဖုန်းလား။ ဤ Wi-Fi ကို လက်ဖြင့် ချိတ်ပြီး အထက်ကလိပ်စာကို browser မှာ ဖွင့်ပါ။',
    'turboWifiName': 'Wi-Fi အမည်',
    'turboWifiPassword': 'စကားဝှက်',
    'turboJoining': 'တစ်ဖက်ဖုန်း၏ လင့်ခ်သို့ ဝင်နေသည်\u2026',
    'turboConnected': 'တိုက်ရိုက် ချိတ်ဆက်ပြီး',
    'turboLeave': 'တိုက်ရိုက် ချိတ်ဆက်မှု ဖြုတ်မည်',
    'turboNoInternet': 'တိုက်ရိုက် ချိတ်ဆက်ထားစဉ် ဤဖုန်းတွင် အင်တာနက် မရပါ။ ဖြုတ်လိုက်သည်နှင့် ပြန်ရပါမည်။',
    'turboReasonWifiOff': 'Wi-Fi ကို အရင်ဖွင့်ပါ \u2014 တိုက်ရိုက်လင့်ခ်က Wi-Fi ရေဒီယိုကို သုံးသည် (ဒေတာ မကုန်ပါ)။',
    'turboReasonLocationOff': 'ဤ Android ဗားရှင်းတွင် တိုက်ရိုက် Wi-Fi လင့်ခ် ဖန်တီးရန် Location ဖွင့်ထားရန် လိုအပ်သည်။ Innocent သည် သင့်တည်နေရာကို ဘယ်တော့မှ မဖတ်ပါ။',
    'turboReasonPermission': 'တိုက်ရိုက် Wi-Fi လင့်ခ် ဖန်တီးရန် ခွင့်ပြုချက် လိုအပ်သည်။',
    'turboReasonUnsupported': 'ဤဖုန်း၏ Android ဗားရှင်းက တိုက်ရိုက်လင့်ခ် မဖန်တီးနိုင်ပါ။ ပုံမှန် Wi-Fi share က အလုပ်လုပ်ပါသေးသည်။',
    'turboReasonGeneric': 'ဤဖုန်းတွင် တိုက်ရိုက်လင့်ခ် မစတင်နိုင်ပါ။',
    'turboOpenWifiSettings': 'Wi-Fi settings ဖွင့်မည်',
    'turboOpenLocationSettings': 'Location settings ဖွင့်မည်',
    'sendInnocentApp': 'Innocent app ကို ပို့မည်',
    'sendInnocentAppHint': 'Innocent ရဲ့ APK ကို share ထဲ ထည့်ပေးသည်၊ မရှိသေးတဲ့ဖုန်းက သင့်ဆီကနေ တင်နိုင်သည် \u2014 အင်တာနက် မလိုပါ။',
    'transferHistory': 'လက်ခံရရှိသော ဖိုင်များ',
    'clearHistory': 'စာရင်း ရှင်းမည်',
    'fileMissing': 'ထိုဖိုင်သည် ဤဖုန်းတွင် မရှိတော့ပါ။',
    'receivedFromDevice': 'မှ',
    'turboBandUnknown': 'Turbo တိုက်ရိုက် ချိတ်ဆက်မှု',
    'turboSccExplain': 'ဖုန်းက Wi-Fi ကွန်ရက်တစ်ခုနဲ့ ချိတ်ထားလို့ ဤလင့်ခ်က 2.4 GHz ဖြစ်နေသည် \u2014 ဖုန်းအများစုက တိုက်ရိုက်လင့်ခ်ကို Wi-Fi နဲ့ channel တူမှ သုံးနိုင်သည်။ Wi-Fi ကွန်ရက်မှ ဖြုတ်ပြီး (Wi-Fi ကိုတော့ ဖွင့်ထားပါ) ပြန်စလျှင် 5 GHz ရနိုင်ပြီး အဆများစွာ ပိုမြန်ပါသည်။',
    'turboSccTip': 'အကြံပြုချက် - အမြန်ဆုံးရဖို့ ဤဖုန်းကို Wi-Fi ကွန်ရက်မှ အရင်ဖြုတ်ပါ \u2014 ဒါပေမဲ့ Wi-Fi ကိုတော့ ဖွင့်ထားပါ။ Turbo က ရေဒီယိုကို လိုတာဖြစ်ပြီး ကွန်ရက်ကို မလိုပါ။',
    'turboReasonDeclined': 'တစ်ဖက်ဖုန်း၏ လင့်ခ်ကို ရှာမတွေ့ပါ၊ သို့မဟုတ် ချိတ်ဆက်ခြင်း ငြင်းပယ်ခံရသည်။ တစ်ဖက်က share လုပ်နေဆဲဟုတ်မဟုတ် စစ်ပြီး အနီးကပ် နေပါ။',
    'turboReasonNoAddress': 'တိုက်ရိုက်လင့်ခ် ပေါ်လာသော်လည်း ဤဖုန်းတွင် လိပ်စာ မရပါ။ ပုံမှန် Wi-Fi ဖြင့် ဆက်လုပ်ပါမည်။',
    'turboOpenAppSettings': 'App settings ဖွင့်မည်',
    'sendFolder': 'ဖိုလ်ဒါ ပို့မည်',
    'sendThisFolder': 'ပို့မည်',
    'scanningFolder': 'ဖိုလ်ဒါ ဖတ်နေသည်\u2026',
    'noSubfolders': 'ဒီအထဲမှာ ဖိုလ်ဒါ မရှိပါ။ ဒီဖိုလ်ဒါကိုတော့ ပို့နိုင်ပါသည်။',
    'folderUnreadable': 'ဒီဖိုလ်ဒါကို ဖတ်လို့မရပါ။ အခြားတစ်ခု စမ်းပါ။',
    'folderEmpty': 'ထိုဖိုလ်ဒါတွင် ပို့ရန် ဖိုင် မရှိပါ။',
    'folderTooManyFiles': 'ပထမ ဖိုင် ၃၀၀၀ ကိုသာ ထည့်ပါသည် \u2014 အလွန်ကြီးတဲ့ ဖိုလ်ဒါ ဖြစ်နေသည်။',
    'folderAdded': 'ဖိုလ်ဒါ ထည့်ပြီး \u2014 တစ်ဖက်ဖုန်းမှာ ဖွဲ့စည်းမှု အတိုင်း ရမည်။',
    'pauseShare': 'ခဏရပ်မည်',
    'resumeShare': 'ဆက်မည်',
    'sharePaused': 'ခဏရပ်ထားသည် \u2014 လက်ခံသူများ စောင့်နေသည်။ ဒေါင်းပြီးသားတွေ မပျက်ပါ။',
    'pauseReceive': 'ခဏရပ်မည်',
    'resumeReceive': 'ဆက်မည်',
    'receivePaused': 'ခဏရပ်ထားသည်။ ရပ်ထားတဲ့နေရာက ဆက်ရန် Resume နှိပ်ပါ။',
    'pausedBySender': 'တစ်ဖက်ဖုန်းက ခဏရပ်ထားသည်\u2026',
    'protectWithPin': 'PIN ခိုင်းမည်',
    'protectWithPinHint': 'ဤမှာ ၄ လုံး ကုဒ်ပြပြီး တစ်ဖက်ဖုန်းက ရိုက်ထည့်ရမည်။ အများသုံး Wi-Fi မှာ အနီးအနားက လူတိုင်း ဤဖုန်းကို မြင်နိုင်လို့ သုံးသင့်သည်။',
    'enterSharePin': 'တစ်ဖက်ဖုန်းမှာ ပြထားတဲ့ ၄ လုံး PIN ကို ရိုက်ထည့်ပါ',
    'wrongPin': 'PIN မကိုက်ပါ။ တစ်ဖက်ဖုန်း၏ မြင်ကွင်းကို ပြန်စစ်ပါ။',
    'receiversLabel': 'လက်ခံနေသူ',
    'encryptionNote': 'Turbo မှာ လင့်ခ်ကိုယ်တိုင် WPA2 encryption ရှိလို့ ဖိုင်များ လေထဲမှာ လုံခြုံသည်။ ပုံမှန် Wi-Fi ကနေဆိုရင် encryption မရှိပါ \u2014 မယုံရတဲ့ ကွန်ရက်တွေမှာ PIN ဒါမှမဟုတ် Turbo ကို သုံးပါ။',
    'connectAction': 'ချိတ်မည်',
    'dismiss': 'ပယ်မည်',
    'addMoreFiles': 'ဖိုင် ထပ်ထည့်မည်',
    'cannotOpenFile': 'ဤဖိုင်ကို ဖွင့်နိုင်တဲ့ app ဤဖုန်းတွင် မရှိပါ။',
    'allowInstallTitle': 'App တင်ခွင့် ပေးရန်',
    'allowInstallBody': 'APK ကို installer ဆီ လွှဲမပေးခင် Android က သင့်ခွင့်ပြုချက် လိုအပ်သည်။ တစ်ကြိမ်သာ လုပ်ရပါမည်။',
    'allowInstallAction': 'Settings ဖွင့်မည်',
    'webUploadHint': 'Browser ပဲရှိတဲ့ ဖုန်း/ကွန်ပျူတာက ဤလိပ်စာကို ဖွင့်ပြီး သင့်ဆီ ဖိုင်ပြန်ပို့နိုင်သည် \u2014 သူတို့ဘက်မှာ ဘာမှ တင်စရာမလိုပါ။',
    'filesAddedLive': 'Share ထဲ ထပ်ထည့်ပြီး \u2014 တစ်ဖက်ဖုန်းက refresh လုပ်ရင် မြင်ရပါမည်။',
    'savedToPath': '{path} တွင် သိမ်းပြီးပါပြီ',
    'scanSenderQr': 'ပို့သူ QR ကို scan ဖတ်ပါ',
    'scanQrHint': 'ပို့တဲ့ဖုန်းပေါ်က QR code ကို ကင်မရာနဲ့ ချိန်ပါ',
    'playbackSpeed': 'ဖွင့်နှုန်း',
    'sleepTimer': 'Sleep Timer',
    'stopsIn': '{t} အကြာတွင် ရပ်ပါမယ်',
    'sleepTimerSetMin': 'Sleep timer သတ်မှတ်ပြီး: {n} မိနစ်',
    'sleepTimerOff': 'Sleep timer ပိတ်ပြီး',
    'shareFailed': 'မျှဝေ၍မရပါ',
    'shareTrack': 'သီချင်း မျှဝေမယ်',
    'lyrics': 'စာသား',
    'playingQueueTitle': 'ဖွင့်မည့်စာရင်း',
    'queueEmpty': 'ဖွင့်မည့်စာရင်း ဗလာဖြစ်နေပါတယ်',
    'playbackError': 'ဖွင့်၍မရပါ',
    'noSongsFound': 'စက်ထဲမှာ သီချင်း မတွေ့ပါ',
    'errorReadingMusic': 'သီချင်းဖတ်၍မရပါ',
    'searchPlaylists': 'Playlist ရှာမယ်...',
    'searchAlbums': 'Album ရှာမယ်...',
    'searchArtists': 'အဆိုတော် ရှာမယ်...',
    'searchFolders': 'Folder ရှာမယ်...',
    'sortBy': 'စီမည့်ပုံစံ',
    'noSongsBy': '{name} ရဲ့ သီချင်း မရှိပါ',
    'noSongsIn': '{name} ထဲမှာ သီချင်း မရှိပါ',
    'errorLoadingSongs': 'သီချင်းများ ဖတ်၍မရပါ',
    'errorLoadingAlbum': 'Album ဖတ်၍မရပါ',
    'errorLoadingPlaylist': 'Playlist ဖတ်၍မရပါ',
    'playAllCount': 'အားလုံးဖွင့်မယ်  ({n})',
    'sharingName': '"{name}" ကို မျှဝေနေသည်',
    'playingName': '"{name}" ကို ဖွင့်နေသည်',
    'shufflingName': '"{name}" ကို ရောဖွင့်နေသည်',
    'propertiesForName': '"{name}" ရဲ့ အချက်အလက်များ',
    'changePin': 'PIN ပြောင်းမယ်',
    'pinChanged': 'PIN ပြောင်းပြီးပါပြီ',
    'restoredToLibrary': 'Library ထဲ ပြန်ထည့်ပြီးပါပြီ',
    'restoreFailed': 'ပြန်ယူ၍မရပါ',
    'privateIntro': 'သော့ခတ်ထားတဲ့ ဗီဒီယိုတွေကို app ရဲ့ သီးသန့်နေရာထဲ ရွှေ့ထားတာဖြစ်ပြီး gallery နဲ့ တခြား file manager တွေမှာ မမြင်ရတော့ပါ။ စနစ်က ရွှေ့ခွင့်မပေးတဲ့ ဖိုင်တွေကိုတော့ library မှာသာ ဖျောက်ထားပါတယ်။ ဖိုင်တွေကို ရွှေ့ထားတာသာဖြစ်ပြီး encrypt မလုပ်ထားပါ။',
    'setupPinTitle': 'Private Folder PIN သတ်မှတ်ပါ',
    'setupPinHint': 'ဒီမှာ သော့ခတ်ထားတဲ့ ဗီဒီယိုတွေ library မှာ ပေါ်မှာမဟုတ်ပါ။',
    'useBiometric': 'လက်ဗွေ/မျက်နှာ သုံးမယ်',
    'setPin': 'PIN သတ်မှတ်မယ်',
    'enterPin': 'PIN ရိုက်ထည့်ပါ',
    'restoreBackupTitle': 'Backup ပြန်ယူမလား?',
    'clearLibraryCacheTitle': 'Library cache ရှင်းမလား?',
    'addNewServer': 'Server အသစ် ထည့်မယ်',
    'networks': 'ကွန်ရက်များ',
    'supportedProtocols': 'ပံ့ပိုးထားသော PROTOCOL များ',
    'howToUse': 'ဘယ်လိုသုံးရမလဲ?',
    'meSettingsHint': 'အသွင်အပြင်၊ Pop-up၊ ဘာသာစကား',
    'meBackupHint': 'သင့်စာရင်းများ နှင့် Cloud Drive',
    'meHelpHint': 'မေးခွန်းများ နှင့် ဆက်သွယ်ရန်',
    'meAboutHint': 'Version၊ Update၊ License',
    'meLibrary': 'သင့် Library',
    'meInsights': 'စာရင်းဇယား',
    'meLibraryStats': 'Library စာရင်းဇယား',
    'bkInfo': 'အကြိုက်ဆုံး၊ playlist၊ bookmark နဲ့ ကြည့်ခဲ့သမျှ မှတ်တမ်းတွေကို အရန်သိမ်းပြီး ဘယ်ဖုန်းမှာမဆို ပြန်ယူနိုင်ပါတယ်။',
    'bkSectionBackup': 'အရန်သိမ်း',
    'bkExport': 'ဖိုင်အဖြစ် အရန်သိမ်းမည်',
    'bkExportSub': 'အကြိုက်ဆုံး၊ playlist၊ bookmark၊ မှတ်တမ်း — JSON ဖိုင်တစ်ခုအဖြစ်',
    'bkSectionRestore': 'ပြန်ယူ',
    'bkRestoreFile': 'ဖိုင်ကနေ ပြန်ယူမည်',
    'bkRestoreFileSub': 'Innocent နဲ့ သိမ်းခဲ့တဲ့ backup ဖိုင်ကို ပြန်ထည့်မည်',
    'bkSectionCloud': 'Cloud',
    'bkCloudSub': 'Google Drive, OneDrive, Dropbox စသည် — cloud ထဲ အရန်သိမ်းခြင်းနဲ့ တိုက်ရိုက်ကြည့်ခြင်း',
    'bkSectionCache': 'Cache',
    'bkClearCache': 'Library cache ရှင်းမည်',
    'bkClearCacheSub': 'App နောက်တစ်ခါဖွင့်ရင် ဗီဒီယိုတွေကို ပြန်ရှာပါမယ်',
    'bkWhat': 'ဘာတွေ အရန်သိမ်းမလဲ',
    'bkItemSettings': 'App settings များ',
    'bkItemPlaylists': 'Video playlist များ',
    'bkItemFavourites': 'အကြိုက်ဆုံးများ',
    'bkItemHistory': 'ကြည့်ခဲ့သော မှတ်တမ်း',
    'bkItemLater': 'နောက်မှကြည့်မည့် စာရင်း',
    'bkItemBookmarks': 'Bookmark များ',
    'bkRestoreWarn': 'လက်ရှိ အကြိုက်ဆုံး၊ playlist၊ bookmark၊ မှတ်တမ်း နဲ့ Recycle Bin တွေကို backup ဖိုင်ထဲကဟာတွေနဲ့ အစားထိုးပါမယ်။',
    'bkClearWarn': 'App နောက်တစ်ခါဖွင့်ရင် ဗီဒီယိုအားလုံးကို ပြန်ရှာပါမယ်။ ဘေးကင်းပါတယ်၊ အဲဒီတစ်ခါပဲ နည်းနည်းကြာပါမယ်။',
    'bkExported': '{path} မှာ သိမ်းပြီးပါပြီ — လမ်းကြောင်းကို copy ကူးထားပါတယ်',
    'bkFailed': 'မအောင်မြင်ပါ: {e}',
    'bkNoFile': 'ဖိုင် မရွေးရသေးပါ',
    'bkRestored': 'ပြန်ယူပြီး: အကြိုက်ဆုံး {f}၊ playlist {p}၊ bookmark {b}၊ မှတ်တမ်း {h}',
    'bkCacheCleared': 'Library cache ရှင်းပြီးပါပြီ။ App ကို ပြန်ဖွင့်ရင် ပြန်ရှာပါမယ်။',
    'netHowStep1': '{+} ခလုတ်ကို နှိပ်ပြီး server တစ်ခု ထည့်ပါ။',
    'netHowStep2': 'ကွန်ပျူတာ / NAS ထဲက ဖိုင်တွေကို ဖုန်းကနေ တိုက်ရိုက် ကြည့်နိုင်ပါတယ်။',
    'netHowStep3': 'ကွန်ပျူတာ / NAS နဲ့ Wi-Fi တစ်ခုတည်းမှာ ရှိပါစေ — Scan က ရှာပေးပါမယ်။',
    'netGotIt': 'နားလည်ပြီ',
    'netNewServer': '{p} Server အသစ်',
    'netEditServer': '{p} Server ပြင်ရန်',
    'netScan': 'Scan',
    'netServer': 'Server',
    'netServerIp': 'Server IP',
    'netServerName': 'အမည်',
    'netServerNameHint': 'ကိုယ်ပိုင်အမည် (မထည့်လည်းရ)',
    'netSharedPath': 'Shared Path',
    'netSharedPathHint': 'Share အမည် (မထည့်လည်းရ)',
    'netFolder': 'Folder',
    'netFolderHint': 'စဖွင့်မည့် folder (မထည့်လည်းရ)',
    'netPort': 'Port',
    'netUsername': 'Username',
    'netPassword': 'Password',
    'netAnonymous': 'အကောင့်မပါဘဲ ချိတ်မည်',
    'netMode': 'Mode',
    'netActive': 'Active',
    'netPassive': 'Passive',
    'netEncoding': 'Encoding',
    'netSecurityMode': 'Security Mode',
    'netImplicit': 'Implicit',
    'netExplicit': 'Explicit',
    'netUseKey': 'Private Key ဖြင့် ဝင်မည်',
    'netPrivateKey': 'Private Key',
    'netPrivateKeyHint': 'Key ကို ကူးထည့်ပါ (-----BEGIN …)',
    'netChooseKeyFile': 'Key ဖိုင် ရွေးမည်',
    'netPassphrase': 'Passphrase',
    'netPassphraseHint': 'Passphrase (မထည့်လည်းရ)',
    'netConnect': 'ချိတ်မည်',
    'netSave': 'သိမ်းမည်',
    'netConnecting': 'ချိတ်ဆက်နေသည်…',
    'netErrUnreachable': '{host} ကို မရောက်နိုင်ပါ။ စက်ဖွင့်ထားလား၊ ဒီဖုန်းနဲ့ Wi-Fi တစ်ခုတည်းမှာ ရှိလား စစ်ပါ။',
    'netErrTimeout': 'Server က အဖြေပြန်တာ ကြာလွန်းပါတယ်။ ထပ်စမ်းပါ။',
    'netErrAuth': 'Username သို့မဟုတ် Password မှားနေပါတယ်။',
    'netErrAuthAnon': 'ဒီ server က အကောင့်မပါဘဲ ဝင်ခွင့်မပေးပါ။ "အကောင့်မပါဘဲ ချိတ်မည်" ကို ဖြုတ်ပြီး Username/Password ထည့်ပါ။',
    'netErrDenied': 'ဒီအကောင့်နဲ့ အဲဒီ folder ကို ဖွင့်ခွင့် မရှိပါ။',
    'netErrNotFound': 'အဲဒီ share / folder က server ပေါ်မှာ မရှိပါ။',
    'netErrTls': 'လုံခြုံသော ချိတ်ဆက်မှု မအောင်မြင်ပါ။ Port နဲ့ Security Mode ကို စစ်ပါ။',
    'netErrKey': 'Private key ကို ဖတ်မရပါ။ Key နဲ့ passphrase ကို စစ်ပါ။',
    'netErrProtocol': 'Server က ပြန်ဖြေပေမယ့် {p} မဟုတ်ပါ။ Protocol နဲ့ Port ကို စစ်ပါ။',
    'netErrHostKey': 'နောက်ဆုံးချိတ်ခဲ့ချိန်ကနေ ဒီ server ရဲ့ identity ပြောင်းသွားပါပြီ။',
    'netErrHostKeyBody': 'Server ကို ပြန်တင်ထား/အသစ်လဲထားတာဆိုရင် identity အသစ်ကို ယုံကြည်ပါ။ မဟုတ်ရင် ဒီ network ပေါ်မှာ တစ်ယောက်ယောက်က အယောင်ဆောင်နေတာ ဖြစ်နိုင်ပါတယ်။',
    'netTrustNew': 'Identity အသစ်ကို ယုံမည်',
    'netErrNeedHost': 'Server လိပ်စာ ထည့်ပါ။',
    'netErrBadPort': 'Port က 1 မှ 65535 ကြား ဖြစ်ရပါမယ်။',
    'netErrNeedKey': 'Private key ကူးထည့်ပါ သို့မဟုတ် ဖိုင်ရွေးပါ။',
    'netErrUnsupported': 'ဒီစက်မှာ Local Network မရနိုင်ပါ။',
    'netScanTitle': 'ဒီ Wi-Fi ပေါ်က Server များ',
    'netScanning': '{subnet} ပေါ်မှာ {p} server ရှာနေသည်…',
    'netScanNone': 'ဒီ Wi-Fi ပေါ်မှာ {p} server မတွေ့ပါ။',
    'netScanNoneHint': 'ကွန်ပျူတာမှာ file sharing ဖွင့်ပါ၊ သို့မဟုတ် လိပ်စာကို ကိုယ်တိုင် ရိုက်ထည့်ပါ။',
    'netScanAgain': 'ထပ်ရှာမည်',
    'netScanNoWifi': 'Scan ဖို့ Wi-Fi ချိတ်ပါ။',
    'netMyServers': 'Server များ',
    'netEdit': 'ပြင်မည်',
    'netDelete': 'ဖျက်မည်',
    'netDeleteConfirm': '"{name}" ကို ဖယ်ရှားမလား?',
    'netDeleteBody': 'သိမ်းထားတဲ့ password ကိုပါ ဒီဖုန်းထဲကနေ ဖျက်ပါမယ်။',
    'netEmptyFolder': 'ဒီ folder ထဲမှာ ဘာမှမရှိပါ',
    'netRetry': 'ထပ်စမ်းမည်',
    'netSortName': 'အမည်',
    'netSortDate': 'ရက်စွဲ',
    'netSortSize': 'အရွယ်အစား',
    'netMediaOnly': 'Media သာ',
    'netNotPlayable': 'ဒီဖိုင်ကို ဒီမှာ ဖွင့်လို့ မရပါ။',
    'netItems': '{n} ခု',
    'netAnonymousTag': 'Anonymous',
    'netShares': 'Share များ',
    'netShowPassword': 'Password ပြမည်',
    'aboutCloudDrive': 'Cloud Drive အကြောင်း',
    'cloudDriveBody': 'သင့် cloud account တွေထဲက ဗီဒီယိုနဲ့ သီချင်းတွေကို ဒေါင်းလုဒ်မလုပ်ဘဲ တိုက်ရိုက် ဖွင့်နိုင်ပါမယ်။ အောက်က provider တစ်ခုကို ချိတ်ပြီး Innocent ထဲကနေ ဖိုင်တွေ ကြည့်နိုင်ပါတယ်။',
    'connectCloudCaps': 'သင့် CLOUD STORAGE ကို ချိတ်ဆက်ပါ',
    'deviceStorage': 'စက်၏ သိုလှောင်မှု',
    'cleanUpSpace': 'နေရာလွတ်ရအောင် ရှင်းလင်းမယ်',
    'scanningCleanable': 'ရှင်းလင်းနိုင်တဲ့ဖိုင်များ ရှာနေသည်...',
    'openingRecentlyPlayed': 'မကြာသေးမီဖွင့်ခဲ့သည်များ ဖွင့်နေသည်',
    'mmUsedOf': '{total} အနက် {used} သုံးထားသည်',
    'mmFree': '{free} လွတ်',
    'mmVideos': 'ဗီဒီယို',
    'mmMusic': 'သီချင်း',
    'mmNoAccess': 'ခွင့်မရှိ',
    'mmStorageUnknown': 'သိုလှောင်မှု ပမာဏ မသိရပါ',
    'mmRecentlyPlayed': 'မကြာသေးမီ ကြည့်ခဲ့သည်',
    'mmLargeFiles': 'ဖိုင်အကြီးများ',
    'mmLargestVideos': 'အကြီးဆုံး ဗီဒီယိုများ',
    'mmHaventPlayed': 'မကြည့်ရသေးသော',
    'mmAllPlayed': 'ဒီဖုန်းထဲက ဗီဒီယိုအားလုံး ကြည့်ပြီးပါပြီ။',
    'scNightMode': 'ညမုဒ်',
    'scShuffle': 'ရောမွှေ',
    'scMute': 'အသံပိတ်',
    'scAbRepeat': 'A-B ထပ်ဖွင့်',
    'scMirrorMode': 'မှန်ပုံစံ',
    'scVerticalFlip': 'အပေါ်အောက်လှန်',
    'scAudioEffect': 'အသံအထူးပြု',
    'scEqualizer': 'အသံညှိ',
    'scSpeed': 'အမြန်နှုန်း',
    'scScreenshot': 'ဖန်သားပြင်ရိုက်',
    'scBackgroundPlay': 'နောက်ခံဖွင့်',
    'scScreenRotation': 'မျက်နှာပြင်လှည့်',
    'scLoop': 'ထပ်ခါဖွင့်',
    'scCustomiseItems': 'စိတ်ကြိုက်ပြင်',
    'scVideoDisplay': 'ဗီဒီယိုပြသမှု',
    'scSleepTimer': 'အိပ်ချိန်မှတ်',
    'gtSection': 'လက်ဟန်များ (Gestures)',
    'gtBrightness': 'ပွတ်ဆွဲ၍ အလင်းချိန်',
    'gtBrightnessSub': 'ဘယ်ဘက်ခြမ်းကို အပေါ်/အောက် ပွတ်ဆွဲပါ။',
    'gtVolume': 'ပွတ်ဆွဲ၍ အသံချိန်',
    'gtVolumeSub': 'ညာဘက်ခြမ်းကို အပေါ်/အောက် ပွတ်ဆွဲပါ။ Volume boost ဖွင့်ထားရင် 100% ကျော်ပြီး 200% ထိ ဆက်တင်နိုင်ပါတယ်။',
    'gtSeek': 'ပွတ်ဆွဲ၍ ရှေ့/နောက် ရွှေ့',
    'gtSeekSub': 'ဘယ်/ညာ ပွတ်ဆွဲပါ။ ဆွဲသလောက် ရုပ်ရှင်က လိုက်ရွှေ့ပါတယ်။',
    'gtDoubleTap': 'နှစ်ချက်တို့၍ ခုန်ကျော်',
    'gtDoubleTapSub': 'ဘယ် သို့မဟုတ် ညာဘက်ကို နှစ်ချက်တို့ပါ။ ဆက်တို့လေ ပိုခုန်လေ (10၊ 20၊ 30 စက္ကန့်…)။ အလယ်ကို နှစ်ချက်တို့ရင် ရပ်/ဖွင့်။',
    'gtLongPress': 'ဖိထား၍ အမြန်နှုန်း',
    'gtLongPressSub': 'ဖိထားပြီး လက်မကြွဘဲ ဘယ်/ညာ ဆွဲပါ။',
    'gtPinch': 'လက်နှစ်ချောင်းဖြင့် Zoom',
    'gtPinchSub': 'လက်နှစ်ချောင်းကို ဆွဲချဲ့ သို့မဟုတ် ချုံ့ပါ။',
    'gtPan': 'Zoom ထားစဉ် ရွှေ့',
    'gtPanSub': 'Zoom ထားတုန်း လက်နှစ်ချောင်းနဲ့ ဆွဲပြီး ရုပ်ပုံကို ရွှေ့ပါ။',
    'gtSpeed': 'လက်နှစ်ချောင်းဖြင့် အမြန်နှုန်း',
    'gtSpeedSub': 'လက်နှစ်ချောင်းနဲ့ အပေါ်/အောက် ပွတ်ဆွဲပါ (0.25x – 4x)။',
    'gtSubtitle': 'စာတန်းထိုး လက်ဟန်',
    'gtSubtitleSub': 'စာတန်းပေါ်မှာ အပေါ်/အောက်ဆွဲရင် နေရာရွှေ့၊ ဘယ်/ညာဆွဲရင် ရှေ့/နောက် စာကြောင်း၊ ဆွဲချဲ့/ချုံ့ရင် အရွယ်ပြောင်း။',
    'zmFit': 'မျက်နှာပြင်နဲ့ကိုက် (Fit)',
    'zmStretch': 'ဆွဲဆန့် (Stretch)',
    'zmCrop': 'ချဲ့ဖြည့် (Crop)',
    'zmOriginal': '100%',
    'zmCustom': 'စိတ်ကြိုက် (Custom)',
    'zmCustomHint': 'လက်နှစ်ချောင်းနဲ့ ချဲ့/ချုံ့၊ ရွှေ့ကြည့်ပါ',
    'gtTap': 'တစ်ချက်တို့၍ ခလုတ်များ ပြ/ဖျောက်',
    'gtTapSub': 'စခရင်ကို တစ်ချက်တို့ပါ။',
    'gtVolumeKey': 'အသံခလုတ်များ',
    'gtVolumeKeySub': 'အသံ အတိုး/အလျှော့။',
    'gtHeadset': 'နားကြပ် ခလုတ်',
    'gtHeadsetSub': 'ရပ်/ဖွင့်။',
    'storagePermissionNeeded': 'သိုလှောင်မှုခွင့်ပြုချက် လိုအပ်ပါတယ်',
    'statusPermissionHint': 'WhatsApp status တွေဖတ်နိုင်ဖို့ media ဝင်ရောက်ခွင့် ပေးပါ။',
    'openingPrivacyPolicy': 'Privacy Policy ဖွင့်နေသည်...',
    'openingTerms': 'Terms of Service ဖွင့်နေသည်...',
    'personalPlayerApp': 'ကိုယ်ပိုင်သုံး ဗီဒီယို player app။',
    'storageManagement': 'သိုလှောင်မှု စီမံခန့်ခွဲရေး',
    'storageUsage': 'သိုလှောင်မှု အသုံးပြုမှု',
    'classicThemes': 'Classic Theme များ',
    'noInternetThemes': 'အင်တာနက် မရှိပါ။ Theme အသစ်တွေအတွက် နှိပ်ပြီး ချိတ်ပါ။',
    'themeApplied': 'Theme သုံးပြီးပါပြီ',
    'openSourceLicenses': 'Open source လိုင်စင်များ',
    'personalProject': 'သင်ယူရေးနဲ့ ကိုယ်ပိုင်သုံးအတွက် Flutter project တစ်ခုပါ။',
    'personalVideoPlayer': 'ကိုယ်ပိုင် ဗီဒီယို player',
    'slowBuffering': 'ချိတ်ဆက်မှုနှေးနေသည် — buffering…',
    'openingVideo': 'ဗီဒီယိုကို ဖွင့်နေသည်…',
    'videoTooHeavy': 'ဒီဗီဒီယိုက ဖုန်းအတွက် လေးနေပါတယ်…',
    'streamCacheTitle': 'ဗီဒီယို သိမ်းဆည်းမှု',
    'streamCacheExplain':
        'ကြည့်ပြီးသား ဗီဒီယိုတွေကို ဒီဖုန်းထဲမှာ သိမ်းထားပေးပါတယ်။ '
        'နောက်ပြန်ဆွဲတာ၊ ပြန်ကြည့်တာတွေမှာ data မကုန်တော့ဘဲ '
        'အင်တာနက်မရှိလည်း ကြည့်လို့ရပါတယ်။ တကယ်ကြည့်ပြီးသား အပိုင်းကိုပဲ '
        'သိမ်းပါတယ်။ ကန့်သတ်ချက်ပြည့်ရင် အကြာဆုံး မဖွင့်ဖြစ်တာကို '
        'အရင်ဖျက်ပါတယ်။',
    'streamCacheLimit': 'ကန့်သတ်ချက်',
    'streamCacheClear': 'သိမ်းထားတာတွေ ဖျက်မည်',
    'streamCacheClearPages': 'သိမ်းထားသည့် စာမျက်နှာနှင့် ပုံများ ဖျက်မည်',
    'streamCacheClearPagesNote': 'အင်တာနက်မရှိချိန် ကြည့်ရန် သိမ်းထားသည့် ကာတာလောက်နှင့် ပိုစတာပုံများ။ ဖျက်လိုက်ရင် နေရာလွတ်ရမည်၊ ပြန်ရဖို့ အင်တာနက် လိုအပ်ပါမည်။',
    'streamCacheClearNote':
        'နေရာ ချက်ချင်းပြန်ရပါမယ်။ ပြန်ကြည့်မယ်ဆိုရင်တော့ ထပ်ဒေါင်းရပါမယ်။',
    'streamCacheKept': 'သိမ်းထားသည်',
    'streamCacheUnnamed': 'ဗီဒီယို',
    'streamCacheSubtitle': 'ကြည့်ပြီးသား ဗီဒီယိုကို ဖုန်းထဲသိမ်းထားမည်',
    'durationLabel': 'ကြာချိန်',
    'resumeTitle': 'ဆက်ဖွင့်မယ်',
    'resumeBody': 'ရပ်ခဲ့တဲ့နေရာကနေ ဆက်ဖွင့်မလား?',
    'savedAt': '{t} တွင် သိမ်းထားသည်',
    'useByDefault': 'ပုံသေအဖြစ် သုံးမယ်',
    'startOver': 'အစကပြန်စမယ်',
    'continueFromStopped': 'ရပ်ခဲ့တဲ့နေရာကနေ ဆက်ကြည့်ပါ။',
    'customSpeedTitle': 'စိတ်ကြိုက် နှုန်း',
    'speedRangeHint': 'အပိုင်းအခြား: 0.25x - 4.00x',
    'playLastToEnd': 'နောက်ဆုံးဖိုင် ပြီးဆုံးသည်အထိ ဖွင့်မယ်',
    'setStartFirst': 'အစမှတ်ကို အရင်သတ်မှတ်ပါ',
    'endAfterStart': 'အဆုံးမှတ်က အစမှတ်နောက်မှာ ရှိရပါမယ်',
    'setBothPoints': 'အစမှတ်နဲ့ အဆုံးမှတ် နှစ်ခုလုံး အရင်သတ်မှတ်ပါ',
    'markClipHint': 'အစ (A) နဲ့ အဆုံး (B) မှတ်သတ်မှတ်ပြီး clip မှတ်ပါ။',
    'currentLabel': 'လက်ရှိ',
    'clipLabel': 'Clip',
    'displaySettingsTitle': 'ပြသမှု Settings',
    'playerGestures': 'Player လက်ဟန်များ',
    'tapToDismiss': 'ပိတ်ရန် နေရာမရွေး နှိပ်ပါ',
    'skipIntroOutro': 'Intro / Outro ကျော်မယ်',
    'clearAllMarkers': 'မှတ်အားလုံး ရှင်းမယ်',
    'noTracksAvailable': 'Track မရှိပါ',
    'loadExternalSubtitle': 'ပြင်ပ စာတန်းထိုး ထည့်မယ်...',
    'onlineSubtitles': 'Online စာတန်းထိုးများ',
    'selectDecoder': 'Decoder ရွေးပါ',
    'bookmarksTitle': 'Bookmark များ',
    'subtitleDelayTitle': 'စာတန်းထိုး နှေးမြန်ချိန်',
    'shortcuts': 'Shortcut များ',
    'unknownTab': 'မသိသော tab',
    'invalidUrl': 'URL မမှန်ပါ',
    'streamUrl': 'Stream URL',
    'equalizerTitle': 'Equalizer',
    'eqNotAvailable': 'Equalizer မရနိုင်ပါ',
    'audioFxNotAvailable': 'ဒီစက်မှာ audio effect တွေ မရနိုင်ပါ။',
    'tapProfileHint': 'Audio effect ဖွင့်ရန် profile တစ်ခုကို နှိပ်ပါ။',
    'profilesFineTuneHint': 'Profile တွေက equalizer band တွေကို ချိန်ပေးပါတယ်။ Equalizer tab မှာ အသေးစိတ် ချိန်နိုင်ပါတယ်။',
    'reverb': 'Reverb',
    'kidsLock': 'ကလေး\nသော့',
    'kidsLockOnMsg': 'Kids Lock ဖွင့်ပြီး — ထိန်းချုပ်မှုအားလုံး ပိတ်ထားပါတယ်',
    'kidsLockHoldHint': 'သော့ဖွင့်ရန် ဖိထားပါ',
    'kidsLockOffMsg': 'Kids Lock ပိတ်ပြီး',
    'fullAccessBody': 'Android က "All files access" ဆိုတဲ့ system screen ကို ဖွင့်ပေးပါမယ်။ Innocent အတွက် switch ကိုဖွင့်ပြီး back နှိပ်ပြီး ပြန်လာပါ။ ဒါက Movies/DCIM/Downloads ပြင်ပ folder တွေကိုပါ scan လုပ်ခွင့်ပေးတာပါ။ အဲဒီ screen ကနေပဲ အချိန်မရွေး ပြန်ပိတ်နိုင်ပါတယ်။',
    'resetSettingsBodyFull': 'Player၊ audio၊ subtitle နဲ့ general preference အားလုံး မူလအတိုင်း ပြန်ဖြစ်ပါမယ်။ History နဲ့ playlists တွေတော့ မထိပါ။',
    'popupPlayControls': 'စိတ်ကြိုက် Pop-up Play ထိန်းချုပ်မှုများ',
    'storageRoot': 'သိုလှောင်ခန်း',
    'noFolders': 'Folder မရှိပါ',
    'couldNotLoadFiles': 'ဖိုင်များ ဖတ်၍မရပါ',
    'couldNotLoadFolders': 'Folder များ ဖတ်၍မရပါ',
    'noVideosInFolder': 'ဒီ folder ထဲမှာ ဗီဒီယို မရှိပါ',
    'abPointASet': 'A မှတ် သတ်မှတ်ပြီး — B မှတ်အတွက် ထပ်နှိပ်ပါ',
    'abRepeatOn': 'A-B ထပ်ဖွင့်ခြင်း ဖွင့်ပြီး',
    'abRepeatOff': 'A-B ထပ်ဖွင့်ခြင်း ပိတ်ပြီး',
    'addedToFavourites': 'Favourites ထဲ ထည့်ပြီးပါပြီ',
    'removedFromFavourites': 'Favourites မှ ဖယ်ပြီးပါပြီ',
    'catVideos': 'ဗီဒီယိုများ',
    'catImages': 'ဓာတ်ပုံများ',
    'catAudio': 'အသံဖိုင်များ',
    'catFiles': 'ဖိုင်များ',
    'catApps': 'App များ',
    'itemsCount': '{n} ခု',
    'filesCount': 'ဖိုင် {n} ခု',
    'appsCount': 'App {n} ခု',
    'noItemsHere': 'ဒီမှာ ဘာမှမရှိပါ',
    'loadingApps': 'ထည့်ထားတဲ့ app များ ဖတ်နေသည်…',
    'appsUnavailable': 'ဒီစက်မှာ app စာရင်း ဖတ်၍မရပါ။',
    'shareFile': 'မျှဝေမယ်',
    'unlockToLibrary': 'သော့ဖွင့်မယ်',
    'addedToTransfer': 'Transfer ထဲ ထည့်ပြီးပါပြီ',
    'selectFilesToAdd': 'ထည့်ရန် ဖိုင်များ ရွေးပါ',
    'selectFilesToSend': 'ပို့ရန် ဖိုင်များ ရွေးပါ',
    'newPin': 'PIN အသစ်',
    'confirmPin': 'PIN အတည်ပြု',
    'pinLabel': 'PIN',
    'currentPin': 'လက်ရှိ PIN',
    'confirmNewPin': 'PIN အသစ် အတည်ပြု',
    'pinMin4': 'PIN သည် အနည်းဆုံး ဂဏန်း ၄ လုံး ရှိရမည်',
    'pinsDontMatch': 'PIN နှစ်ခု မတူညီပါ',
    'newPinMin4': 'PIN အသစ်သည် အနည်းဆုံး ဂဏန်း ၄ လုံး ရှိရမည်',
    'newPinsDontMatch': 'PIN အသစ် နှစ်ခု မတူညီပါ',
    'currentPinIncorrect': 'လက်ရှိ PIN မမှန်ပါ',
    'incorrectPin': 'PIN မမှန်ပါ',
    'tooManyAttemptsWait': 'အကြိမ်များစွာ မှားနေသည် — {s} စက္ကန့် စောင့်ပါ',
    'biometricNotEnrolled': 'ဒီစက်မှာ လက်ဗွေ/မျက်နှာ မှတ်ပုံတင်ထားခြင်း မရှိပါ',
    'biometricEnrollFirst': 'လက်ဗွေ/မျက်နှာ မှတ်ပုံတင်ထားခြင်း မရှိပါ — Android Settings မှာ အရင်သတ်မှတ်ပါ။',
    'unlockPrivateReason': 'Private Folder သော့ဖွင့်ရန်',
    'unlockHint': 'ရှေ့ဆက်ရန် PIN ရိုက်ထည့်ပါ',
    'biometricSubtitle': 'PIN ရိုက်စရာမလိုဘဲ လက်ဗွေ/မျက်နှာနဲ့ ဖွင့်နိုင်သည်။ PIN က အရန်အဖြစ် ရှိနေမည်။',
    'mediaPermissionNeeded': 'သင့် media ကို ဝင်ရောက်ခွင့် ပေးပါ',
    'mediaPermissionHint': 'သင့် ဓာတ်ပုံနဲ့ အသံဖိုင်တွေ ဒီမှာ ပြဖို့ ခွင့်ပြုချက် လိုအပ်ပါတယ်။',
    'grantAccess': 'ခွင့်ပြုချက် ပေးမယ်',
    'layoutSection': 'ပုံစံ',
    'layoutList': 'စာရင်း',
    'layoutGrid': 'ဇယားကွက်',
    'allFilesAccessNeeded': 'ဖိုင်အားလုံးကို ဝင်ရောက်ခွင့် ပေးပါ',
    'allFilesAccessHint': 'ဖိုင်တွေ ဒီမှာ ကြည့်ဖို့ Innocent က "All files access" လိုအပ်ပါတယ်။ Android settings မှာ switch ဖွင့်ပြီး back နှိပ်ပါ။',
    'noFilesInFolder': 'ဒီ folder ထဲမှာ ဖိုင်မရှိပါ',
    'allFiles': 'ဖိုင်အားလုံး',
    'newFolder': 'Folder အသစ်',
    'createFolderTitle': 'Folder ဖန်တီးမယ်',
    'folderName': 'Folder အမည်',
    'renameFolderTitle': 'Folder အမည်ပြောင်း',
    'deleteFolderTitle': 'Folder ဖျက်မလား?',
    'deleteFolderBody': 'ထဲက file တွေ Private Folder ပင်မထဲ ပြန်ရွှေ့ပါမယ် — ဘာမှ မဖျက်ပါ။',
    'moveToFolder': 'Folder ထဲ ရွှေ့မယ်',
    'moveHere': 'ဒီကို ရွှေ့မယ်',
    'mainFolder': 'Private Folder',
    'chooseFolder': 'Folder ရွေးပါ',
    'addToExisting': 'ရှိပြီးသား folder ထဲ ထည့်မယ်',
    'verifyToLock': 'သော့ခတ်ရန် အတည်ပြုပါ',
    'searchFilesHint': 'ဖိုင်များ ရှာမယ်…',
    'emptyFolder': 'ဒီ folder ဗလာဖြစ်နေတယ်',
    'foldersHeader': 'Folder များ',
    'catAll': 'အားလုံး',
    'chooseFolderTitle': 'ဘယ် Folder ထဲ ထည့်မလဲ?',
    'mainFolderRoot': 'ပင်မ Folder',
    'newFolderEllipsis': 'Folder အသစ်…',
    'lockCancelled': 'Lock လုပ်ခြင်း ပယ်ဖျက်လိုက်သည်',
    'foldersTitle': 'Folder များ',
    'refreshingVault': 'ပြန်လည်စစ်ဆေးနေသည်…',
    'moreOptions': 'နောက်ထပ်',
    'resumeVault': 'ဆက်ကြည့်ရန်',
    'nothingToResume': 'ဆက်ကြည့်စရာ မရှိသေးပါ',
    'viewModeFolders': 'မြင်ကွင်း: Folder များ',
    'viewModeFiles': 'မြင်ကွင်း: ဖိုင်များ',
    'deletePermanently': 'အပြီးအပိုင် ဖျက်မယ်',
    'deletePermanentlyTitle': 'အပြီးအပိုင် ဖျက်မလား?',
    'deletePermanentlyBody': 'ဒီဖိုင်ကို vault မှ အပြီးအပိုင် ဖျက်မှာဖြစ်ပြီး ပြန်လည်ရယူ၍ မရတော့ပါ။',
    'fileDeleted': 'ဖိုင် ဖျက်ပြီးပါပြီ',
    'selectedCount': '{n} ခု ရွေးထားသည်',
    'selectAll': 'အားလုံး ရွေးမယ်',
    'moveSelected': 'ရွှေ့မယ်',
    'unlockSelected': 'သော့ဖွင့်မယ်',
    'deleteSelected': 'ဖျက်မယ်',
    'deleteSelectedTitle': 'ဖိုင် {n} ခု ဖျက်မလား?',
    'deleteSelectedBody': 'ဤဖိုင်များကို vault မှ အပြီးအပိုင် ဖျက်မှာဖြစ်ပြီး ပြန်လည်ရယူ၍ မရတော့ပါ။',
    'itemsUnlocked': 'ဖိုင် {n} ခု သော့ဖွင့်ပြီးပါပြီ',
    'itemsMovedFolder': 'ဖိုင် {n} ခု ရွှေ့ပြီးပါပြီ',
    'renameEntry': 'အမည်ပြောင်းမယ်',
    'renameEntryTitle': 'ဖိုင် အမည်ပြောင်း',
    'entryNameHint': 'ဖိုင် အမည်',
    'vaultStorageUsed': 'vault ထဲ {size}',
    'viewModeLabel': 'မြင်ကွင်း',
    'sortAndView': 'စီစဉ် & ကြည့်ရှု',
    'deleteFolderChoiceBody': 'ဒီ folder ထဲမှာ lock ထားတဲ့ ဖိုင် {n} ခု ရှိပါတယ်။ ဘာလုပ်ချင်ပါသလဲ?',
    'deleteFolderWithItemsTitle': 'ဖိုင် {n} ခုပါတဲ့ folder ဖျက်မလား?',
    'unlockAndDeleteFolder': 'ဖိုင်တွေ သိမ်း၊ folder ဖျက်',
    'unlockAndDeleteFolderSub': 'ဖိုင်တွေ ပင်မ vault ထဲ ပြန်ရွှေ့',
    'deleteFolderAndFiles': 'folder နဲ့ ဖိုင်တွေ ဖျက်',
    'deleteFolderAndFilesSub': 'ထဲက အားလုံး အပြီးအပိုင် ဖျက်',
    'folderDeleted': 'Folder ဖျက်ပြီးပါပြီ',
    'vaultFileMissing': 'ဖိုင် မတွေ့ပါ — ဖယ်ရှားခံရနိုင်ပါသည်',
    'someFilesFailed': 'ဖိုင် {n} ခု ထည့်၍ မရပါ',
    'filesAddedOk': 'ဖိုင် {n} ခု ထည့်ပြီးပါပြီ',
    'forgotPin': 'PIN မေ့သွားပါသလား?',
    'recoverVault': 'Vault ကို ပြန်ဖွင့်ရန်',
    'chooseRecoveryMethod': 'ဘယ်လို ပြန်ဖွင့်ချင်ပါသလဲ?',
    'recoveryNotSetup': 'Recovery နည်းလမ်း မသတ်မှတ်ရသေးပါ။ PIN ကို ပြန်ရ၍ မရပါ။',
    'securityQuestion': 'လုံခြုံရေး မေးခွန်း',
    'securityAnswer': 'သင့်ရဲ့ အဖြေ',
    'setSecurityQuestion': 'လုံခြုံရေး မေးခွန်း သတ်မှတ်ရန်',
    'chooseAQuestion': 'မေးခွန်း ရွေးပါ',
    'wrongAnswer': 'အဖြေ မကိုက်ညီပါ',
    'answerRequired': 'အဖြေ ထည့်ပါ',
    'recoveryKey': 'Recovery key',
    'recoveryKeyGenerated': 'ဒီ recovery key ကို သိမ်းထားပါ',
    'recoveryKeyWarning': 'တစ်ကြိမ်သာ ပြပါမည်။ ချရေး၍ လုံခြုံတဲ့နေရာ သိမ်းထားပါ — PIN နဲ့ အဖြေ မေ့ရင် ဒါ တစ်ခုတည်းသာ နည်းလမ်းပါ။',
    'enterRecoveryKey': 'Recovery key ထည့်ပါ',
    'wrongRecoveryKey': 'Recovery key မမှန်ကန်ပါ',
    'copiedToClipboard': 'ကူးယူပြီး',
    'iSavedIt': 'သိမ်းပြီးပါပြီ',
    'setNewPin': 'PIN အသစ် သတ်မှတ်ပါ',
    'pinResetSuccess': 'PIN ပြန်သတ်မှတ်ပြီး။ ပြန်ဝင်လို့ရပါပြီ။',
    'setUpRecovery': 'Recovery သတ်မှတ်ရန်',
    'recoveryOptions': 'Recovery ရွေးချယ်စရာများ',
    'recoverySetupPrompt': 'PIN မေ့ရင် vault ပြန်ဖွင့်နိုင်ဖို့ နည်းလမ်း သတ်မှတ်ထားပါ။',
    'skipForNow': 'အခုမလုပ်သေးပါ',
    'recoveryConfigured': 'Recovery သတ်မှတ်ပြီးပါပြီ',
    'notConfigured': 'မသတ်မှတ်ရသေးပါ',
    'regenerateKey': 'key အသစ် ထုတ်ရန်',
    'antiTheft': 'ခိုးမှု ကာကွယ်ရေး',
    'antiTheftDesc': 'ဖုန်း အခိုးခံရ/အတင်းဖွင့်ခံရရင် vault ကို ကာကွယ်ပါ။',
    'decoyPin': 'လှည့်စား PIN',
    'decoyPinDesc': 'empty vault ဖွင့်ပေးတဲ့ ဒုတိယ PIN။ တစ်စုံတစ်ယောက်က အတင်းဖွင့်ခိုင်းရင် သုံးပါ။',
    'setDecoyPin': 'လှည့်စား PIN သတ်မှတ်ရန်',
    'decoyPinSet': 'လှည့်စား PIN သတ်မှတ်ပြီး',
    'decoySameAsReal': 'လှည့်စား PIN က တကယ့် PIN နဲ့ မတူရပါ',
    'removeDecoyPin': 'လှည့်စား PIN ဖယ်ရှားရန်',
    'intruderSelfie': 'ကျူးကျော်သူ ဓာတ်ပုံ',
    'intruderSelfieDesc': 'PIN ၃ ကြိမ် မှားရင် ရှေ့ကင်မရာနဲ့ တိတ်တဆိတ် ဓာတ်ပုံရိုက်။',
    'breakInAttempts': 'ဖောက်ဖျက်ဝင်ရန် ကြိုးစားမှုများ',
    'noBreakIns': 'ဖောက်ဖျက်ဝင်ရန် ကြိုးစားမှု မှတ်တမ်း မရှိပါ',
    'clearLog': 'မှတ်တမ်း ရှင်းရန်',
    'clearLogConfirm': 'ဖောက်ဖျက်မှု မှတ်တမ်း နဲ့ ဓာတ်ပုံ အားလုံး ဖျက်မလား?',
    'photoUnavailable': 'ဓာတ်ပုံ မရှိ',
    'secQ1': 'သင့်ရဲ့ ပထမဆုံး အိမ်မွေးတိရစ္ဆာန် နာမည်က ဘာလဲ?',
    'secQ2': 'သင့်အမေရဲ့ မိဘအမည်ရင်းက ဘာလဲ?',
    'secQ3': 'သင် ဘယ်မြို့မှာ မွေးခဲ့တာလဲ?',
    'secQ4': 'သင့်ရဲ့ ပထမဆုံး ကျောင်း နာမည်က ဘာလဲ?',
    'secQ5': 'သင် အကြိုက်ဆုံး စာအုပ်က ဘာလဲ?',
    'secQ6': 'ငယ်ဘဝက သင့်ရဲ့ အလိုချ နာမည်က ဘာလဲ?',
    'clearSelection': 'ရွေးချယ်မှု ရှင်းရန်',
    'lockInPrivateFolder': 'Private Folder ထဲ သိမ်းရန်',
    'movingToPrivate': 'Private Folder ထဲ ရွှေ့နေသည်',
    'deletingFiles': 'ဖျက်နေသည်',
    'noVideosToLock': 'ရွေးထားတဲ့ folder တွေမှာ video မရှိပါ',
    'videosQueued': 'ဗီဒီယို စီထားသည်',
    'deleteFoldersTitle': 'ဗီဒီယိုများ ဖျက်မလား?',
    'deleteFoldersBody': 'ရွေးထားတဲ့ folder တွေထဲက ဗီဒီယို အားလုံးကို အပြီးအပိုင် ဖျက်ပါမည်။',
    'lockFoldersBody': 'ရွေးထားတဲ့ folder တွေထဲက ဗီဒီယို အားလုံးကို Private Folder ထဲ ရွှေ့မလား?',
    'propSectionFile': 'ဖိုင်',
    'propSectionMedia': 'မီဒီယာ',
    'propSectionPlayback': 'ဖွင့်ခဲ့သည့် မှတ်တမ်း',
    'propFile': 'ဖိုင်',
    'propLocation': 'တည်နေရာ',
    'propSize': 'အရွယ်အစား',
    'propDate': 'ရက်စွဲ',
    'propFormat': 'ဖော်မတ်',
    'propResolution': 'ကြည်လင်ပြတ်သားမှု',
    'propLength': 'ကြာချိန်',
    'propBitrate': 'Bit rate',
    'propFinished': 'ပြီးဆုံးပြီး',
    'propFinishedYes': 'ပြီးဆုံးပြီး',
    'propFinishedNo': 'မပြီးသေးပါ',
    'propLastPosition': 'နောက်ဆုံး နေရာ',
    'okay': 'အိုကေ',
    'cancelling': 'ရပ်နေသည်…',
    'downloaderTitle': 'ဒေါင်းလုဒ်',
    'downloaderSettings': 'ဒေါင်းလုဒ် ဆက်တင်',
    'downloaderPasteHint': 'ဗီဒီယို လင့်ခ် ကူးထည့်ပါ',
    'downloaderPaste': 'ကူးထည့်ရန်',
    'downloaderClipboardFound': 'ကလစ်ဘုတ်တွင် လင့်ခ် တွေ့ရှိသည်',
    'downloaderDismiss': 'ဖျောက်ရန်',
    'downloaderActive': 'ဒေါင်းလုဒ်များ',
    'downloaderTabBrowse': 'ရှာဖွေ',
    'downloaderEmptyDownloads': 'ဒေါင်းလုဒ် မရှိသေးပါ',
    'downloaderEmptyDownloadsHint':
        'အပေါ်မှာ လင့်ခ်ကူးထည့်ပါ၊ သို့မဟုတ် ရှာဖွေ ကိုဖွင့်၍ ဆိုက်ရွေးပါ။',
    'downloaderClear': 'ရှင်းရန်',
    'downloaderFavourite': 'အကြိုက်ဆုံး',
    'downloaderRecommended': 'အကြံပြုချက်',
    'downloaderRestricted': 'ကန့်သတ် ဝဘ်ဆိုဒ်များ',
    'downloaderQueued': 'စောင့်ဆိုင်းနေသည်',
    'downloaderPreparing': 'ပြင်ဆင်နေသည်',
    'downloaderFinalizing': 'အပြီးသတ်နေသည်…',
    'downloaderSetIcon': 'Icon ရွေးရန်',
    'downloaderRemoveIcon': 'Icon ဖယ်ရှားရန်',
    'downloaderIconFailed': 'Icon သတ်မှတ်၍ မရပါ',
    'downloaderIconHint': 'အကြံ — site တစ်ခုကို ဖိထားပြီး ကိုယ်ပိုင် icon သတ်မှတ်ပါ။',
    'downloaderSaved': 'သိမ်းဆည်းပြီး',
    'downloaderCancelled': 'ပယ်ဖျက်လိုက်သည်',
    'downloaderFailed': 'မအောင်မြင်ပါ',
    'downloaderPlay': 'ဖွင့်ရန်',
    'downloaderDownload': 'ဒေါင်းလုဒ်',
    'downloaderEnginePreparing': 'ပထမဆုံးအသုံးပြုမှုအတွက် အင်ဂျင် ပြင်ဆင်နေသည်…',
    'downloaderEngineFailed': 'ဒေါင်းလုဒ် အင်ဂျင် အသုံးပြုလို့မရပါ',
    'downloaderNoMerger': 'ပေါင်းစပ်စနစ် မရနိုင်ပါ — အသံပါပြီးသား quality များသာ ပြသည်',
    'downloaderSavePath': 'သိမ်းမည့်နေရာ',
    'downloaderChange': 'ပြောင်းရန်',
    'downloaderShowRestricted': 'ကန့်သတ် ဝဘ်ဆိုဒ်များ ပြရန်',
    'downloaderRestrictedNote': 'အရွယ်ရောက်သူသာ။ မူရင်းအနေနဲ့ ပိတ်ထားသည်။',
    'downloaderInvalidLink': 'ဒါက လင့်ခ် ဟန် မတူပါ',
    'downloaderFetching': 'လင့်ခ်ကို ဖတ်နေသည်…',
    'downloaderNoFormats': 'ဒီလင့်ခ်တွင် ဒေါင်းလုဒ်ဆွဲနိုင်သည့် ဖိုင် မတွေ့ပါ',
    'downloaderSiteHint': 'ဗီဒီယို လင့်ခ်ကို ကူးယူပြီး ဒီကို ပြန်လာပါ',
    'downloaderNoBrowser': 'ဒီဆိုဒ်ကို ဖွင့်နိုင်မယ့် ဘရောက်ဇာ မတွေ့ပါ',
    'downloaderDirFailed': 'သိမ်းမည့် ဖိုလ်ဒါ ပြောင်းလို့မရပါ',
    'downloaderAudio': 'အသံ',
    'downloaderVideo': 'ဗီဒီယို',
    'downloaderStream': 'တိုက်ရိုက်ဖွင့်',
    'downloaderStreamFailed': 'တိုက်ရိုက်ဖွင့်လို့မရပါ',
    'downloaderConvert': 'ပြောင်းရန်',
    'downloaderLiveNote': 'တိုက်ရိုက်လွှင့်မှုကို ဖွင့်ကြည့်နိုင်ပေမယ့် ဒေါင်းလုဒ်ဆွဲလို့မရပါ',
    'downloaderStreamOnlyBest': 'တိုက်ရိုက်ဖွင့်ရာတွင် အသံပါအကောင်းဆုံး quality ကို အသုံးပြုသည်',
    'downloaderStreamRefused':
        'ဤဆိုက်က ဗီဒီယိုကို တိုက်ရိုက်ဖွင့်ခွင့် မပြုပါ။ Download လုပ်ခြင်းကတော့ '
        'များသောအားဖြင့် ရနိုင်ပါသည်။',
    'downloaderErrRateLimited': 'ဤကွန်ရက်မှ တောင်းဆိုမှု များလွန်းနေပါသည်',
    'downloaderRateLimitHint':
        'ဆိုက်က နှေးနှေးလုပ်ဖို့ တောင်းဆိုနေပါသည် — ဗီဒီယိုနှင့် မဆိုင်ဘဲ '
        'ကွန်ရက်နှင့်သာ ဆိုင်ပါသည်။ မိနစ်အနည်းငယ် စောင့်ပါ၊ သို့မဟုတ် Wi-Fi နှင့် '
        'မိုဘိုင်းဒေတာ လဲလှယ်ပြီး ပြန်စမ်းပါ။',
    'downloaderRateLimitWait': 'ခန့်မှန်း @m မိနစ်အကြာတွင် ပြန်စမ်းပါ',
    'downloaderAnySiteHint':
        'ဤတို့သည် ဖြတ်လမ်းများသာဖြစ်ပြီး ကန့်သတ်ချက် မဟုတ်ပါ — ဗီဒီယိုဆိုက် '
        'အများစုမှ လင့်ခ်ကို ကူးထည့်လိုက်ရုံဖြင့် အတူတူပင် ဖတ်ပေးပါသည်။',
    'downloaderBrowseDownload': 'ဗီဒီယို Download လုပ်ရန်',
    'downloaderBrowseHint': 'ဤစာမျက်နှာတွင် ဗီဒီယို တွေ့ရှိပါသည်။',
    'downloaderBrowseWorking': 'စာမျက်နှာကို ဖတ်နေသည်…',
    'downloaderBrowsePick': 'Quality ရွေးပါ',
    'downloaderBrowseStarted': 'Download စာရင်းထဲ ထည့်ပြီးပါပြီ',
    'downloaderNeedsStorage': 'Downloads ဖိုလ်ဒါသို့ သိမ်းခွင့် ပေးပါ',
    'downloaderNeedsStorageBody':
        'Android သည် All files access ဖွင့်ထားမှသာ shared Downloads ဖိုလ်ဒါသို့ '
        'ရေးခွင့်ပြုပါသည်။ မဖွင့်ထားလျှင်လည်း ဗီဒီယိုများ သိမ်းဆည်းပါသည် — '
        'သို့သော် အက်ပ်၏ ကိုယ်ပိုင်ဖိုလ်ဒါထဲသို့ဖြစ်ပြီး အခြားအက်ပ်များ မမြင်ရပါ။',
    'downloaderGrantAccess': 'Settings ဖွင့်ရန်',
    'downloaderNoSound': 'အသံမပါ',
    'downloaderViewPage': 'မူရင်းစာမျက်နှာ ဖွင့်ရန်',
    'downloaderCopyLink': 'လင့်ခ် ကူးရန်',
    'downloaderNoSourcePage': 'ဤဖိုင်အတွက် မူရင်းစာမျက်နှာ သိမ်းထားခြင်း မရှိပါ',
    'downloaderDownloadAgain': 'ထပ်မံ ဒေါင်းလုဒ်ရန်',
    'downloaderRemoveFromList': 'စာရင်းမှ ဖယ်ရှားရန်',
    'downloaderSeeAll': 'အားလုံး ကြည့်ရန်',
    'downloaderHistoryTitle': 'ဒေါင်းလုဒ် မှတ်တမ်း',
    'downloaderHistoryEmpty': 'ဒေါင်းလုဒ် မှတ်တမ်း မရှိသေးပါ',
    'downloaderRetryDownload': 'ပြန်စရန်',
    'downloaderMoreOptions': 'နောက်ထပ်',
    'downloaderBrowseStreams': 'ဤစာမျက်နှာတွင် တွေ့ရှိသော ဗီဒီယိုများ',
    'downloaderBrowseUnreadable': 'ဤဗီဒီယိုကို ဖတ်လို့မရပါ',
    'downloaderBrowseRetry': 'ထပ်စမ်းရန်',
    'downloaderBrowseSendScreen': 'Downloads စခရင်တွင် ဖွင့်ရန်',
    'downloaderBrowseBlocked': 'ဤဆိုက်ကို ဖွင့်လို့မရပါ',
    'downloaderBrowseVpnHint': 'VPN ဖွင့်ထားပါသည်။ YouTube နှင့် TikTok သည် VPN လိပ်စာများကို ငြင်းပယ်လေ့ရှိသည်။',
    'downloaderBrowseDnsHint': 'Private DNS သုံးလျှင် VPN မလိုဘဲ ပိတ်ထားသောဆိုက်များ ဖွင့်နိုင်သည်',
    'downloaderBrowseMore': 'အခြား Quality များ ရှာရန်…',
    'downloaderNetworkVpnOff': 'ဤဆိုက်ကို VPN ပိတ်ထားစဉ်က ရခဲ့ပါသည်',
    'downloaderNetworkVpnOn': 'ဤဆိုက်ကို VPN ဖွင့်ထားစဉ်က ရခဲ့ပါသည်',
    'downloaderNetworkVpnNow': 'VPN ဖွင့်ထားပါသည်။ YouTube နှင့် TikTok သည် VPN လိပ်စာများကို ငြင်းလေ့ရှိသည်။',
    'downloaderCheckNetwork': 'ဤကွန်ရက်ကို စစ်ရန်',
    'downloaderNetworkChecking': 'ကွန်ရက်ကို စစ်နေသည်…',
    'downloaderNetworkDnsBlocked': 'ဤကွန်ရက်သည် ဆိုက်နာမည်ဖြင့် ပိတ်ထားသည်။ Private DNS ဖြင့် ဖြေရှင်းနိုင်ပြီး VPN မလိုပါ။',
    'downloaderNetworkDeeper': 'ပိတ်ဆို့မှုသည် နာမည်ရှာဖွေမှုတွင် မဟုတ်ပါ။ Private DNS အထောက်အကူ မဖြစ်ပါ။ VPN သာ လမ်းကြောင်းဖြစ်သည်။',
    'downloaderNetworkUnknown': 'Resolver နှစ်ခုကို နှိုင်းယှဉ်၍ မရပါ — ကွန်ရက်ကို စစ်ပြီး ထပ်စမ်းပါ။',
    'downloaderNetworkPrivateOn': 'Private DNS ဖွင့်ထားပြီးဖြစ်သည်',
    'downloaderNetworkNoVpnNeeded': 'Private DNS ဖွင့်ထားလျှင် VPN ပိတ်ထားလို့ရပြီး YouTube လည်း ဆက်အလုပ်လုပ်ပါမည်။',
    'downloaderBypassOpen': 'VPN မလိုဘဲ ဖွင့်ရန်',
    'downloaderBypassHint': 'Innocent က လိပ်စာကို ကိုယ်တိုင် ရှာပါမည်',
    'downloaderVpnNotNeeded': 'ပိတ်ထားသောဆိုက်များ VPN မလိုဘဲ ပွင့်ပါပြီ — VPN ပိတ်လိုက်လျှင် YouTube လည်း အလုပ်လုပ်ပါမည်',
    'downloaderAlreadyHave': 'ဤဗီဒီယိုကို ဒေါင်းလုဒ်လုပ်ပြီးသား ဖြစ်ပါသည်',
    'downloaderYtWall': 'ဤဗီဒီယိုကို ဤကွန်ရက်တွင် ဖွင့်၍မရပါ',
    'downloaderYtEmbed': 'Sign in မလိုဘဲ ဖွင့်ရန်',
    'downloaderYtSignInNow': 'YouTube သို့ Sign in ဝင်ရန်',
    'downloaderBotWallHint':
        'YouTube က ဤကွန်ရက်လိပ်စာကို မယုံကြည်ပါ။ VPN သုံးနေချိန်တွင် '
        'အများအားဖြင့် ဖြစ်တတ်ပါသည် — လိပ်စာတစ်ခုကို လူများစွာ မျှသုံးနေလို့ပါ။ '
        'YouTube အတွက် VPN ကို ပိတ်ပါ၊ သို့မဟုတ် အောက်တွင် Sign in လုပ်ပါ — '
        'အကောင့်ဝင်ထားလျှင် နှစ်မျိုးလုံးတွင် အဆင်ပြေပါသည်။',
    'downloaderSupportedSites': 'ဝဘ်ဆိုဒ် တစ်ထောင်ကျော်နှင့် အသုံးပြုနိုင်သည်',
    'downloaderEdit': 'ပြင်ရန်',
    'downloaderUpdateEngine': 'အင်ဂျင် အပ်ဒိတ်လုပ်ရန်',
    'downloaderUpdating': 'အင်ဂျင် အပ်ဒိတ်လုပ်နေသည်…',
    'downloaderUpdated': 'အင်ဂျင် အပ်ဒိတ်ပြီးပါပြီ',
    'downloaderUpToDate': 'အင်ဂျင်မှာ နောက်ဆုံးဗားရှင်း ဖြစ်နေပါပြီ',
    'downloaderUpdateFailed': 'အင်ဂျင် အပ်ဒိတ် မအောင်မြင်ပါ',
    'downloaderCookies': 'Cookies ဖိုင်',
    'downloaderCookiesNote': 'အကောင့်ဝင်ရန် လိုအပ်သည့် လင့်ခ်များအတွက် cookies.txt ဖိုင်',
    'downloaderPickCookies': 'ဖိုင်ရွေးရန်',
    'downloaderRemove': 'ဖယ်ရှားရန်',
    'downloaderDetails': 'အသေးစိတ်',
    'downloaderAdvanced': 'အဆင့်မြင့်',
    'downloaderPlayerClients': 'အရံ ပလေယာများ',
    'downloaderPlayerClientsNote': 'YouTube က ငြင်းပယ်မှသာ စမ်းသည်။ မလိုချင်ရင် ဗလာထားပါ။',
    'downloaderErrBot': 'ဤစက်ကို လူသားမှန်ကြောင်း အတည်ပြုရန် YouTube က တောင်းဆိုနေသည်။',
    'downloaderErrAccount': 'ဤလင့်ခ်အတွက် အကောင့်ဝင်ထားရန် လိုအပ်သည်။',
    'downloaderErrNetwork': 'ဆိုဒ်ကို မရောက်နိုင်ပါ။ အင်တာနက် ချိတ်ဆက်မှု စစ်ပါ။',
    'downloaderErrExtractor': 'ဤဆိုဒ်ကို အင်ဂျင်က မဖတ်နိုင်ပါ — ဗားရှင်း အဟောင်း ဖြစ်နိုင်သည်။',
    'downloaderErrUnsupported': 'ဤလင့်ခ်တွင် ဒေါင်းလုဒ်ဆွဲနိုင်သည့် ဖိုင် မတွေ့ပါ။',
    'downloaderErrUnknown': 'ဤလင့်ခ်ကို ဖတ်လို့မရပါ။',
    'downloaderClearBar': 'ရှင်းရန်',
    'downloaderWatermark': 'ရေစာပါ',
    'downloaderPause': 'ခဏရပ်',
    'downloaderResume': 'ဆက်လုပ်',
    'downloaderPaused': 'ရပ်ထားသည်',
    'downloaderRetrying': 'ပြန်ချိတ်ဆက်နေသည်…',
    'downloaderRemaining': 'ကျန်',
    'downloaderInterrupted': 'ပြတ်တောက်သွားသည် — ဆက်လုပ်ရန် နှိပ်ပါ',
    'downloaderResumeAll': 'အားလုံး ဆက်လုပ်ရန်',
    'downloaderOf': '/',
    'downloaderNoWatermark': 'ရေစာမပါ',
    'downloaderPhotos': 'ပုံ',
    'downloaderPhotoPost': 'ဓာတ်ပုံ ပို့စ်',
    'downloaderSaveAll': 'အားလုံး သိမ်းရန်',
    'downloaderPhotosSaved': 'ဓာတ်ပုံများ သိမ်းပြီးပါပြီ',
    'downloaderSignIn': 'အကောင့်ဝင်ရန်',
    'downloaderSignedIn': 'အကောင့်ဝင်ပြီးပါပြီ — လင့်ခ်ကို ပြန်စမ်းနေသည်',
    'downloaderSessions': 'ဝင်ထားသည့် ဆိုဒ်များ',
    'downloaderSessionsNote': 'အကောင့်လိုအပ်သည့် လင့်ခ်များအတွက် Innocent ထဲမှာပဲ ဝင်ပါ',
    'downloaderSignOut': 'ထွက်ရန်',
    'downloaderSignInFailed': 'အကောင့်ဝင်သည့် စာမျက်နှာ မဖွင့်နိုင်ပါ',
    'downloaderFixAuto': 'အလိုအလျောက် ပြင်ရန်',
    'downloaderPreparingSession': 'ဧည့်သည် session ရယူနေသည်…',
    'downloaderWifiOnly': 'WiFi ဖြင့်သာ ဒေါင်းလုဒ်ဆွဲရန်',
    'downloaderSavedFiles': 'သိမ်းထားသော ဖိုင်များ',
    'downloaderShare': 'မျှဝေရန်',
    'downloaderDeleteFile': 'ဖျက်ရန်',
    'downloaderDeleteConfirm': 'ဤဖိုင်ကို ဖုန်းထဲမှ ဖျက်မလား။',
    'downloaderDeleted': 'ဖျက်ပြီးပါပြီ',
    'downloaderMissing': 'ဤဖိုင် ဖုန်းထဲတွင် မရှိတော့ပါ',
    'downloaderClearList': 'စာရင်း ရှင်းရန်',
    'downloaderNotifsBlocked': 'အသိပေးချက် ပိတ်ထားသည် — ဒေါင်းလုဒ်များ မမြင်ရဘဲ အလုပ်လုပ်မည်',
    'downloaderOpenSettings': 'ဆက်တင်',
    'downloaderVideos': 'ဗီဒီယို',
    'downloaderSelectAll': 'အားလုံး ရွေးရန်',
    'downloaderSelectNone': 'အားလုံး ဖြုတ်ရန်',
    'downloaderQueuedCount': 'ခု စောင့်စာရင်းသို့ ထည့်ပြီး',
    'downloaderAskEveryTime': 'အမြဲ မေးရန်',
    'downloaderBest': 'အကောင်းဆုံး',
    'downloaderDefaultQuality': 'ပုံမှန် quality',
    'downloaderDefaultQualityNote': 'တစ်ခု ရွေးထားရင် လင့်ခ်ချတာနဲ့ မမေးဘဲ ဆွဲသည်',
    'downloaderSubtitles': 'စာတမ်းထိုး ဘာသာစကားများ',
    'downloaderSubtitlesNote': 'ကော်မာခြား၊ ဥပမာ en,my — ဗလာဆိုရင် မထည့်ပါ',
    'downloaderEmbedThumbnail': 'ဖုံးပုံကို ဖိုင်ထဲ ထည့်ရန်',
    'downloaderEmbedMetadata': 'ခေါင်းစဉ်နှင့် ရေးသားသူကို ဖိုင်ထဲ သိမ်းရန်',
    'downloaderSpeedLimit': 'အမြန်နှုန်း ကန့်သတ်ချက်',
    'downloaderUnlimited': 'အကန့်အသတ်မရှိ',
    'downloaderExtras': 'အပိုများ',
    'downloaderWifiOnlyNote': 'မမေးဘဲ မိုဘိုင်းဒေတာ မသုံးပါ',
    'downloaderMetered': 'မိုဘိုင်းဒေတာ သုံးနေပါသည်',
    'downloaderDownloadAnyway': 'ဒါပေမယ့် ဆွဲမည်',
    'downloaderLowSpace': 'ဤဒေါင်းလုဒ်အတွက် နေရာလွတ် မလုံလောက်ပါ',
    'downloaderTapResume': 'ဆက်ဆွဲရန် resume ကို နှိပ်ပါ',
    'downloaderAutoUpdate': 'အင်ဂျင်ကို အလိုအလျောက် အပ်ဒိတ်လုပ်ရန်',
    'downloaderAutoUpdateNote': 'တစ်ပတ်တစ်ခါ၊ လင့်ခ် ငြင်းပယ်ခံရတိုင်း ထပ်စစ်သည်',
    'downloaderConfigUrl': 'ဆက်တင် ရင်းမြစ်',
    'downloaderConfigUrlNote': 'Innocent က ပြင်ဆင်ချက်ဖတ်မည့် JSON လိပ်စာ — app အသစ်မလိုဘဲ ဆိုဒ်ပြောင်းလဲမှုများကို ပြင်နိုင်စေသည်',
    'downloaderCopyDiagnostics': 'အချက်အလက် ကူးယူရန်',
    'downloaderCopied': 'ကူးပြီးပါပြီ — ပြဿနာတင်ပြသည့်နေရာတွင် ကူးထည့်ပါ',
    'downloaderConfigNotSet': 'မသတ်မှတ်ရသေးပါ',

    // --- App update (updater plan step 2) ---
    'settingsAppUpdate': 'အက်ပ် အပ်ဒိတ်',
    'updateInstalledVersion': 'သွင်းထားသည့် ဗားရှင်း',
    'updateLatestVersion': 'နောက်ဆုံး ဗားရှင်း',
    'updateSize': 'ဒေါင်းလုဒ် အရွယ်အစား',
    'updateReleased': 'ထုတ်ပြန်သည့်ရက်',
    'updateUpToDate': 'နောက်ဆုံးဗားရှင်းကို သုံးနေပါပြီ',
    'updateAvailable': 'အပ်ဒိတ်အသစ် ရရှိနိုင်ပါပြီ',
    'updateCheckNow': 'အခု စစ်ဆေးရန်',
    'updateChecking': 'စစ်ဆေးနေသည်...',
    'updateCheckFailed': 'အပ်ဒိတ် စစ်ဆေး၍ မရပါ။ ထပ်ကြိုးစားကြည့်ပါ။',
    'updateNotConfigured': 'ဤဗားရှင်းတွင် အပ်ဒိတ်စစ်ဆေးမှု မဖွင့်ထားပါ။',

    // --- App update: the download (updater plan step 3) ---
    'updateDownload': 'အပ်ဒိတ် ဒေါင်းလုဒ်ဆွဲရန်',
    'updateDownloading': 'ဒေါင်းလုဒ်ဆွဲနေသည်...',
    'updateVerifying': 'ဒေါင်းလုဒ်ကို စစ်ဆေးနေသည်...',
    'updateDownloaded': 'ဒေါင်းလုဒ် ပြီးပါပြီ',
    'updateDownloadDamaged': 'ဒေါင်းလုဒ် ပျက်စီးသွားပါသည်။ ထပ်ကြိုးစားကြည့်ပါ။',
    'updateDownloadMismatch': 'ဤ update ဖိုင်သည် app မျှော်လင့်ထားသည့်အရာနှင့် '
        'မကိုက်ညီပါ။ ခင်ဗျားရဲ့ အင်တာနက်ကြောင့် မဟုတ်ပါ — ပြန်ဆွဲလည်း '
        'ဖိုင်အတူတူပဲ ရပါမည်။ "ယခုစစ်ရန်" ကို နှိပ်ကြည့်ပါ၊ အတူတူပဲ '
        'ပြနေပါက release ကို ပြင်ရန် လိုအပ်ပါသည်။',
    'updateDownloadFailed': 'ဒေါင်းလုဒ် မပြီးဆုံးပါ။ ထပ်ကြိုးစားကြည့်ပါ။',
    'updateDownloadWriteFailed': 'ဖိုင် ရေးလို့ မရပါ။ ဖုန်းမှာ နေရာ ကုန်နေခြင်း၊ '
        'ဒါမှမဟုတ် တခြား app တစ်ခုက ဒီ app ရဲ့ ယာယီဖိုင်တွေကို ဖျက်ပစ်ခြင်း '
        'ဖြစ်နိုင်ပါတယ်။ နေရာ အနည်းငယ် ရှင်းပြီး ထပ်ကြိုးစားပါ။',
    'updateDownloadRefused': 'Server က ဒေါင်းလုဒ်ကို ငြင်းပယ်လိုက်ပါတယ်',
    'updateNotEnoughSpace': 'ဤအပ်ဒိတ်အတွက် နေရာ မလုံလောက်ပါ။',
    'updateRetry': 'ထပ်ကြိုးစားရန်',
    'updateNotificationTitle': 'အပ်ဒိတ် ဒေါင်းလုဒ်ဆွဲနေသည်',
    'updateWaitingForNetwork': 'အင်တာနက် ပြန်ရလာရန် စောင့်နေသည်...',
    'updateKept': 'သိမ်းထားပြီး',
    'updateResumeNow': 'အခု ဆက်ဆွဲရန်',
    'updateInstall': 'သွင်းယူရန်',
    'updateInstallChecking': 'ဖိုင်ကို စစ်ဆေးနေသည်...',
    'updateInstallGone': 'ဒေါင်းလုဒ်ဆွဲထားသည့် ဖိုင် ပျောက်နေပါသည်။ ပြန်ဆွဲပါ။',
    'updateInstallNoHandler': 'ဤဖုန်းတွင် အပ်ဒိတ်ကို ဖွင့်ပေးမည့် installer မရှိပါ။',
    'updateInstallSignature':
        'ဤအပ်ဒိတ်ကို သွင်းယူ၍ မရပါ။ support ကို ဆက်သွယ်ပါ။',
    'updateNow': 'အပ်ဒိတ်လုပ်မည်',
    'updateNotNow': 'အခု မလုပ်သေးပါ',
    'updateRequired': 'အပ်ဒိတ် လုပ်ရန် လိုအပ်ပါသည်',
    'updateRequiredBody':
        'ဤဗားရှင်းကို ဆက်လက်အသုံးပြု၍ မရတော့ပါ။ ဆက်လက်အသုံးပြုရန် '
            'အောက်ပါ အပ်ဒိတ်ကို ထည့်သွင်းပါ။',
  };

  static const Map<String, String> _th = <String, String>{
    'trSharingNow': 'กำลังส่ง {n} ไฟล์ — แตะเพื่อดู',
    'trSharingComputer': 'กำลังแชร์กับคอมพิวเตอร์ — แตะเพื่อดู',
    'trViaWifi': 'ผ่าน Wi-Fi ของคุณ',
    'trReceivingNow': 'กำลังรับ — แตะเพื่อดู',
    'trConnectedTo': 'เชื่อมต่อแล้ว — แตะเพื่อดู',
    'trResumeReceiving': 'การดาวน์โหลดหยุดกลางคัน — แตะเพื่อทำต่อ',
    'trShareWith': 'แชร์กับ',
    'trPc': 'PC',
    'trTablet': 'แท็บเล็ต',
    'trSendAppShort': 'ส่งแอปให้เพื่อน — ไม่ต้องใช้อินเทอร์เน็ต',
    'trTurboOnShort': 'เปิด — ส่งตรงระหว่างโทรศัพท์ ไม่ผ่านเราเตอร์ เร็วที่สุด',
    'trTurboOffShort': 'ปิด — ส่งผ่านเราเตอร์ Wi-Fi',
    'trSettings': 'การตั้งค่าการส่ง',
    'trHistoryEmpty': 'ไฟล์ที่คุณได้รับจะแสดงที่นี่',
    'trPcTitle': 'แชร์กับคอมพิวเตอร์ iPhone หรือแท็บเล็ต',
    'trPcLead': 'ไม่ต้องติดตั้งอะไรอีกฝั่ง แค่มีเบราว์เซอร์ ดาวน์โหลดจากโทรศัพท์นี้ หรือลากไฟล์มาวางเพื่อส่งมาที่นี่',
    'trPcStep1Turbo': 'ให้คอมพิวเตอร์หรือ iPhone เชื่อม Wi-Fi นี้ — หรือสแกนโค้ดด้วยกล้อง',
    'trPcStep1Wifi': 'ให้คอมพิวเตอร์หรือ iPhone อยู่ใน Wi-Fi เดียวกับโทรศัพท์นี้',
    'trPcStep2': 'เปิดที่อยู่นี้ในเบราว์เซอร์',
    'trPcStep3': 'ดาวน์โหลดไฟล์ หรือลากไฟล์วางบนหน้าเพื่อส่งมาที่นี่',
    'trPcConnected': 'เชื่อมต่อแล้ว {n}',
    'trPcSharingFiles': 'กำลังแชร์ {n} ไฟล์จากโทรศัพท์นี้',
    'trPcStart': 'เริ่ม',
    'trScanTitle': 'สแกน QR ของผู้ส่ง',
    'trScanBody': 'บนโทรศัพท์อีกเครื่อง แตะส่ง — จะมี QR ขึ้นมา สแกนแล้วโทรศัพท์ทั้งสองจะเชื่อมต่อกันโดยตรง',
    'trSendTitle': 'ส่ง',
    'trReceiveTitle': 'รับ',
    'subSecColor': 'สี',
    'subSecBorder': 'ขอบ',
    'subSecAppearance': 'ลักษณะ',
    'sizeTiny': 'เล็กที่สุด',
    'sizeSmall': 'เล็ก',
    'sizeMedium': 'กลาง',
    'sizeLarge': 'ใหญ่',
    'sizeHuge': 'ใหญ่ที่สุด',
    'colourWhite': 'ขาว',
    'colourYellow': 'เหลือง',
    'colourCyan': 'ฟ้าอมเขียว',
    'colourGreen': 'เขียว',
    'colourRed': 'แดง',
    'colourBlack': 'ดำ',
    'borderNone': 'ไม่มี',
    'borderOutline': 'เส้นขอบ',
    'borderDropShadow': 'เงาตกกระทบ',
    'borderRaised': 'นูน',
    'borderDepressed': 'บุ๋ม',
    'shadowSubtle': 'บางเบา',
    'shadowDefault': 'ค่าเริ่มต้น',
    'shadowStrong': 'เข้ม',
    'bgTransparent': 'โปร่งใส',
    'bgTranslucent': 'โปร่งแสง',
    'bgOpaque': 'ทึบแสง',
    'alignLeft': 'ซ้าย',
    'alignCenter': 'กึ่งกลาง',
    'alignRight': 'ขวา',
    'subImproveStrokeDesc': 'วาดเส้นขอบคำบรรยายคุณภาพสูงขึ้น ใช้ CPU เพิ่มเล็กน้อย',
    // Subtitle Text / Subtitle Layout screens.
    'subFont': 'ฟอนต์',
    'subFontDefault': 'ค่าเริ่มต้น',
    'subFontSansSerif': 'Sans-serif',
    'subFontSerif': 'Serif',
    'subFontMonospace': 'Monospace',
    'subFontCustomEnter': 'กำหนดเอง (พิมพ์ชื่อ)…',
    'subFontCustom': 'ฟอนต์กำหนดเอง',
    'subFontCustomHint': 'พิมพ์ชื่อตระกูลฟอนต์ที่ติดตั้งในเครื่อง หรือพาธเต็มของไฟล์ .ttf / .otf',
    'subSize': 'ขนาด',
    'subFontSize': 'ขนาดฟอนต์',
    'subBold': 'ตัวหนา',
    'subBoldDesc': 'ใช้ตัวหนาสำหรับคำบรรยาย',
    'subTextColor': 'สีข้อความ',
    'subTextColorTitle': 'สีข้อความ',
    'subBorderStyle': 'รูปแบบขอบ',
    'subBorderStyleTitle': 'รูปแบบขอบ',
    'subBorderColor': 'สีขอบ',
    'subBorderColorTitle': 'สีขอบ',
    'subScale': 'อัตราส่วน',
    'subScaleTitle': 'อัตราส่วนคำบรรยาย',
    'subShadow': 'เงา',
    'subBackground': 'พื้นหลัง',
    'subBackgroundColor': 'สีพื้นหลัง',
    'subAlignment': 'การจัดวาง',
    'subTextAlignment': 'การจัดวางข้อความ',
    'subBottomMargins': 'ระยะขอบล่าง',
    'subBottomMarginsTitle': 'ระยะขอบล่าง',
    'subImproveStroke': 'ปรับปรุงการวาดเส้นขอบ',
    'subVerticalPos': 'ตำแหน่งแนวตั้ง',
    'subVerticalPosTitle': 'ตำแหน่งแนวตั้ง',
    'subVerticalPosDesc': 'ระยะห่างจากด้านบน เป็นเปอร์เซ็นต์',
    'subHorizontalAlign': 'การจัดวางแนวนอน',
    'subHorizontalAlignTitle': 'การจัดวางแนวนอน',
    'subSidePadding': 'ระยะขอบซ้าย/ขวา',
    'subSidePaddingTitle': 'ระยะขอบซ้าย/ขวา',
    'subSidePaddingDesc': 'ระยะขอบแนวนอน หน่วยพิกเซล',
    'subBottomMargin': 'ระยะขอบล่าง',
    'subBottomMarginTitle': 'ระยะขอบล่าง',
    'subBottomMarginDesc': 'ระยะขอบล่าง หน่วยพิกเซล',
    'subShowBackground': 'แสดงพื้นหลัง',
    'subBgBlack50': 'ดำ (ทึบ 50%)',
    'subBgBlack75': 'ดำ (ทึบ 75%)',
    'subBgDarkGray': 'เทาเข้ม',
    'subBgColorActiveWhen': 'ใช้ได้เฉพาะเมื่อเปิด "แสดงพื้นหลัง" เท่านั้น',
    'currently': 'ปัจจุบัน',

    // --- Video Hub: age gate / library ---
    'vhGateTitle': 'เนื้อหาสำหรับผู้ใหญ่',
    'vhGateLead': 'เนื้อหาทั้งหมดภายในมีไว้สำหรับผู้ใหญ่เท่านั้น กรุณายืนยันก่อนดำเนินการต่อ',
    'vhGateTermsHeading': 'การเข้าใช้งานถือว่าคุณยืนยันว่า',
    'vhGateTerm1': 'คุณมีอายุอย่างน้อย 18 ปี หรือบรรลุนิติภาวะตามกฎหมายในพื้นที่ของคุณ แล้วแต่ว่าอายุใดมากกว่า',
    'vhGateTerm2': 'คุณเข้าใช้งานด้วยความสมัครใจของตนเอง ไม่มีผู้ใดส่ง ขอร้อง หรือกดดันให้คุณเปิดแอปนี้ และคุณไม่ได้ทำแทนผู้อื่น',
    'vhGateTerm3': 'การรับชมเนื้อหาสำหรับผู้ใหญ่ถูกกฎหมายในพื้นที่ของคุณ และคุณรับผิดชอบในการรับรู้ข้อนี้',
    'vhGateTerm4': 'คุณจะไม่แสดงเนื้อหานี้แก่ผู้ที่อายุต่ำกว่า 18 ปี และจะไม่เปิดแอปทิ้งไว้ในที่ที่ผู้เยาว์เข้าถึงได้',
    'vhGateTerm5': 'คุณจะไม่คัดลอก บันทึก อัปโหลดซ้ำ หรือเผยแพร่เนื้อหาใดจากแอป เนื้อหาทั้งหมดมีลิขสิทธิ์และยังคงเป็นทรัพย์สินของเจ้าของสิทธิ์',
    'vhGateTerm6': 'คุณจะไม่ถือว่าเนื้อหาในที่นี้เป็นภาพเหตุการณ์จริง และยอมรับว่าผู้แสดงทุกคนเป็นผู้ใหญ่ที่ยินยอมให้บันทึก',
    'vhGateEnter': 'ฉันอายุ 18 ปีขึ้นไป - เข้าสู่แอป',
    'vhGateLeave': 'ฉันอายุต่ำกว่า 18 ปี - ออก',
    'vhGateBlockedTitle': 'กลับมาใหม่เมื่อคุณโตพอ',
    'vhGateBlockedBody': 'แอปนี้สำหรับผู้ใหญ่เท่านั้นจึงไม่สามารถเปิดได้ โทรศัพท์ของคุณไม่ได้มีปัญหา เรายอมปฏิเสธคนร้อยคนดีกว่าปล่อยให้เด็กเข้ามาหนึ่งคน',
    'vhGateMistake': 'ฉันกดผิด',
    'destinationNoneAvailable': 'ไม่มีโฟลเดอร์อื่นให้ย้ายไป',
    'noPlaylistsHint': 'ยังไม่มีเพลย์ลิสต์ สร้างได้ที่ Me → Video Playlists',
    'confirmBinBody': 'ย้าย {n} ไปถังรีไซเคิลหรือไม่ กู้คืนได้จาก Me',
    'confirmLockBody': 'ย้าย {n} ไปโฟลเดอร์ส่วนตัวหรือไม่ จะถูกนำออกจากรายการทั้งหมด',
    'movedToBin': 'ย้าย {n} ไปถังรีไซเคิลแล้ว',
    'lockedCount': 'ย้าย {n} ไปโฟลเดอร์ส่วนตัวแล้ว',
    'addedToPlaylist': 'เพิ่ม {n} ไปยัง “{name}” แล้ว',
    'renamedOk': 'เปลี่ยนชื่อแล้ว',
    'deletedOk': 'ลบแล้ว',
    'lockingNow': 'กำลังย้ายไปโฟลเดอร์ส่วนตัว…',
    'movedToPrivate': 'ย้ายไปโฟลเดอร์ส่วนตัวแล้ว',
    'searchNoMatches': 'ไม่พบรายการที่ตรงกับการค้นหา',
    'search': 'ค้นหา',
    'pickerShowHidden': 'แสดงโฟลเดอร์ที่ซ่อน',
    'pickerHideHidden': 'ซ่อนโฟลเดอร์ที่ซ่อน',
    'size': 'ขนาด',
    'duration': 'ความยาว',
    'videos': 'วิดีโอ',
    'folders': 'โฟลเดอร์',
    'setPinFirst': 'ตั้ง PIN ของ Private Folder ก่อน (Me → Private Folder)',
    'connectAdbToSend': 'เชื่อมต่อ ADB เพื่อส่งวิดีโอ Android/data',
    'adbStepsTitle': 'สถานะการตั้งค่า',
    'adbStepDevOptions': 'เปิดตัวเลือกสำหรับนักพัฒนาแล้ว',
    'adbStepWifi': 'เชื่อมต่อ Wi-Fi แล้ว (ไม่ต้องมีอินเทอร์เน็ต)',
    'adbStepWireless': 'เปิดการแก้ไขข้อบกพร่องผ่าน Wi-Fi แล้ว',
    'adbStepNotifications': 'อนุญาตการแจ้งเตือนแล้ว — พิมพ์รหัสในการแจ้งเตือน',
    'adbStepPaired': 'จับคู่แล้ว',
    'adbStepConnected': 'เชื่อมต่อแล้ว',
    'adbStepOpen': 'เปิด',
    'adbStepHow': 'วิธีทำ',
    'adbWifiNeeded': 'การแก้ไขข้อบกพร่องผ่าน Wi-Fi ใช้ได้เฉพาะบนเครือข่าย Wi-Fi เท่านั้น Wi-Fi ใดก็ได้ ไม่จำเป็นต้องมีอินเทอร์เน็ต',
    'adbTipXiaomi': 'Xiaomi, Redmi และ POCO: สำหรับ “Stay connected after a reboot” ให้เปิด “USB debugging (Security settings)” ในตัวเลือกสำหรับนักพัฒนาด้วย — ต้องใช้ซิมการ์ดและบัญชี Mi หากการแจ้งเตือนไม่มีช่องตอบกลับ ให้ดึงลงเพื่อขยาย',
    'adbTipOppo': 'OPPO, realme และ OnePlus: หากจับคู่ได้แต่เชื่อมต่อค้าง ให้ปิดแล้วเปิดการแก้ไขข้อบกพร่องผ่าน Wi-Fi อีกครั้ง แล้วแตะ Connect',
    'adbTipTranssion': 'TECNO, Infinix และ itel: อนุญาตให้ Innocent ทำงานเบื้องหลัง (การตั้งค่าแบตเตอรี่หรือ Phone Master) มิฉะนั้นการแจ้งเตือนการจับคู่อาจถูกปิดก่อนที่คุณจะพิมพ์รหัส',
    'adbNotSupported': 'การแก้ไขข้อบกพร่องผ่าน Wi-Fi ต้องใช้ Android 11 ขึ้นไป',
    'hfTitle': 'ไฟล์ที่ซ่อนอยู่',
    'hfHint': 'ไฟล์ของ Telegram และแอปอื่น',
    'hfSettingsSub': 'จับคู่ครั้งเดียวผ่านการแก้ไขข้อบกพร่องผ่าน Wi-Fi แล้วเปิดไฟล์ของ Telegram และแอปอื่น',
    'hfApps': 'แอป',
    'hfQuick': 'ดาวน์โหลดของ Telegram',
    'hfAll': 'ทั้งหมด',
    'hfVideos': 'วิดีโอ',
    'hfPhotos': 'รูปภาพ',
    'hfAudio': 'เสียง',
    'hfDocs': 'เอกสาร',
    'hfEmpty': 'ไม่มีอะไรที่นี่',
    'hfSend': 'ส่งด้วย Transfer',
    'hfFetching': 'กำลังดึงจาก Android/data…',
    'hfFileOf': '{i} จาก {n}',
    'hiddenBadge': 'ซ่อน',
    'hfInApps': 'ในแอป (Android/data)',
    'hfBucketPhotos': 'รูปของ Telegram และแอปอื่น',
    'hfBucketAudio': 'เสียงของ Telegram และแอปอื่น',
    'hfSkipped': 'ข้ามไฟล์จาก Android/data {n} ไฟล์ — เชื่อมต่อ ADB แล้วลองอีกครั้ง',
    'hfConnectTitle': 'เชื่อมต่อเพื่อดูไฟล์ในแอป',
    'hfConnectBody': 'ตอนนี้แสดงโฟลเดอร์ที่ซ่อน (ขึ้นต้นด้วยจุด) แล้ว โฟลเดอร์ของ Telegram และแอปอื่น (Android/data) เปิดผ่านการเชื่อมต่อ ADB ของ Innocent — ตั้งค่าครั้งเดียวไหม',
    'hfOpenAdb': 'ตั้งค่า ADB',
    'hfNotNow': 'ไว้ทีหลัง',
    'hfLive': 'เชื่อมต่อแล้ว — แสดงในแท็บวิดีโอด้วย',
    'hfNoApp': 'ไม่มีแอปในโทรศัพท์นี้ที่เปิดไฟล์ประเภทนี้ได้ แชร์แทนไหม',
    'hfPullFailed': 'ดึงจาก Android/data ไม่ได้ — ยังเชื่อมต่อ ADB อยู่ไหม',
    'adbScreenTitle': 'เข้าถึง Android/data',
    'adbHeroConnected': 'เชื่อมต่อแล้ว',
    'adbHeroConnectedSub': 'Innocent เปิด Android/data ได้แล้ว การคัดลอกทำงานต่อในเบื้องหลัง และทำต่อจากจุดที่หยุดหากการเชื่อมต่อหลุด',
    'adbHeroOff': 'ยังไม่ได้เชื่อมต่อ',
    'adbHeroOffSub': 'การแก้ไขข้อบกพร่องผ่าน Wi-Fi มักปิดเองหลังรีสตาร์ทหรือเมื่อเปลี่ยน Wi-Fi เปิดอีกครั้งแล้วแตะเชื่อมต่อใหม่ ไม่ต้องใช้รหัสใหม่',
    'adbHeroNew': 'ตั้งค่าครั้งเดียว ประมาณหนึ่งนาที',
    'adbHeroNewSub': 'Innocent เชื่อมต่อกับการแก้ไขข้อบกพร่องผ่าน Wi-Fi ของโทรศัพท์เครื่องนี้เพื่อเปิด Android/data ไม่ต้องใช้คอมพิวเตอร์หรือรูท',
    'adbHeroChecking': 'กำลังตรวจสอบการเชื่อมต่อ…',
    'adbReconnect': 'เชื่อมต่อใหม่',
    'adbCopyReport': 'คัดลอกรายงาน',
    'adbSendReport': 'ส่งรายงาน',
    'adbClearLog': 'ล้างบันทึก',
    'adbReportCopied': 'คัดลอกรายงานแล้ว — วางในแชท',
    'adbReportSent': 'ส่งรายงานแล้ว แจ้งรหัสนี้:',
    'adbReportFailed': 'ส่งไม่ได้ — คัดลอกรายงานแทน',
    'adbReportCopyCode': 'คัดลอกรหัส',
    'adbReconnecting': 'กำลังเชื่อมต่อใหม่ — กำลังหาพอร์ตใหม่ของการแก้ไขข้อบกพร่องไร้สาย…',
    'adbPairedAlready': 'จับคู่โทรศัพท์นี้แล้ว — ไม่ต้องใช้รหัสใหม่ ถ้าหลุด ให้เปิดการแก้ไขข้อบกพร่องไร้สายแล้วแตะเชื่อมต่อใหม่',
    'adbPairAgain': 'จับคู่อีกครั้ง',
    'adbOpenWireless': 'เปิดการแก้ไขข้อบกพร่องผ่าน Wi-Fi',
    'adbFindVideos': 'ค้นหาวิดีโอใน Android/data',
    'adbPairTitle': 'จับคู่โทรศัพท์นี้ (ครั้งแรกเท่านั้น)',
    'adbPairNotif': 'จับคู่จากการแจ้งเตือน',
    'adbPairNotifSub': 'แตะที่นี่ จากนั้นในการแก้ไขข้อบกพร่องผ่าน Wi-Fi แตะ “จับคู่อุปกรณ์ด้วยรหัส” แล้วพิมพ์ตัวเลข 6 หลักในการแจ้งเตือนของ Innocent ไม่ต้องแยกหน้าจอ',
    'adbPairWaiting': 'กำลังรอรหัสในการแจ้งเตือน…',
    'adbPairInApp': 'หรือพิมพ์รหัสที่นี่ (ให้หน้าต่างจับคู่ยังแสดงอยู่):',
    'adbPairCodeLabel': 'รหัสจับคู่ (6 หลัก)',
    'adbPairConnect': 'จับคู่และเชื่อมต่อ',
    'adbConnect': 'เชื่อมต่อ',
    'adbStayTitle': 'การเชื่อมต่อให้ต่อเนื่อง',
    'adbStayWifi': 'อยู่บน Wi-Fi เดิม การแก้ไขข้อบกพร่องผ่าน Wi-Fi ผูกกับเครือข่ายที่เปิดไว้ การเปลี่ยน Wi-Fi จะปิดมัน',
    'adbStayBackground': 'การคัดลอกทำงานในเบื้องหลังพร้อมการแจ้งเตือน และทำต่อจากจุดที่หยุดหากการเชื่อมต่อหลุด',
    'adbStayTile': 'สวิตช์แตะครั้งเดียว: ตัวเลือกสำหรับนักพัฒนา → “ไทล์การตั้งค่าด่วนสำหรับนักพัฒนา” → การแก้ไขข้อบกพร่องผ่าน Wi-Fi แล้วจะอยู่ในแผงการตั้งค่าด่วน',
    'adbStayBattery': 'โทรศัพท์บางรุ่นปิดเพื่อประหยัดแบตเตอรี่ บน Xiaomi, OPPO, realme, vivo, TECNO และ Infinix ให้ตั้งการใช้แบตเตอรี่ของ Innocent เป็น “ไม่จำกัด”',
    'adbGuideTitle': 'วิธีเปิดและปิด ADB',
    'adbGuideOnTitle': 'เปิด',
    'adbGuideOn1': 'การตั้งค่า → เกี่ยวกับโทรศัพท์ → แตะ “หมายเลขบิลด์” 7 ครั้ง (ใส่รหัสล็อกหน้าจอถ้าถูกถาม) “ตัวเลือกสำหรับนักพัฒนา” จะปรากฏ',
    'adbGuideOn2': 'ตัวเลือกสำหรับนักพัฒนา → “การแก้ไขข้อบกพร่องผ่าน Wi-Fi” → เปิด และอนุญาตบน Wi-Fi นี้',
    'adbGuideOn3': 'ครั้งแรกเท่านั้น: “จับคู่อุปกรณ์ด้วยรหัส” แล้วพิมพ์ตัวเลข 6 หลักในการแจ้งเตือนของ Innocent',
    'adbGuideOffTitle': 'ปิดเมื่อใช้งานเสร็จ',
    'adbGuideOff1': 'ตัวเลือกสำหรับนักพัฒนา → “การแก้ไขข้อบกพร่องผ่าน Wi-Fi” → ปิด (หรือไทล์การตั้งค่าด่วน) Innocent ยังจำการจับคู่ไว้ ครั้งหน้าแค่เปิดแล้วแตะเชื่อมต่อใหม่',
    'adbGuideOff2': 'หากต้องการซ่อนตัวเลือกสำหรับนักพัฒนา ให้ปิดสวิตช์หลักด้านบน โทรศัพท์บางรุ่นจะรีเซ็ตการตั้งค่านักพัฒนาอื่นด้วย',
    'adbGuideSafety': 'การแก้ไขข้อบกพร่องผ่าน Wi-Fi ให้อุปกรณ์ที่จับคู่ควบคุมโทรศัพท์นี้ได้ จับคู่เฉพาะบน Wi-Fi ที่ไว้ใจได้ และปิดเมื่อใช้งานเสร็จ',
    'adbGuideWhereTitle': 'หาได้ที่ไหนในโทรศัพท์ของคุณ',
    'adbGuideWhere': 'Samsung — หมายเลขบิลด์: เกี่ยวกับโทรศัพท์ → ข้อมูลซอฟต์แวร์ ตัวเลือกสำหรับนักพัฒนา: ด้านล่างสุดของการตั้งค่า\nXiaomi / Redmi / POCO — แตะ “เวอร์ชัน OS” (หรือ “เวอร์ชัน MIUI”) ในเกี่ยวกับโทรศัพท์ ตัวเลือกสำหรับนักพัฒนา: การตั้งค่าเพิ่มเติม\nOPPO / realme / OnePlus — เกี่ยวกับอุปกรณ์ → เวอร์ชัน → หมายเลขบิลด์ ตัวเลือกสำหรับนักพัฒนา: การตั้งค่าระบบ / การตั้งค่าเพิ่มเติม\nvivo / iQOO — เกี่ยวกับโทรศัพท์ → เวอร์ชันซอฟต์แวร์ ตัวเลือกสำหรับนักพัฒนา: การจัดการระบบ\nTECNO / Infinix / itel, Pixel และรุ่นอื่นส่วนใหญ่ — เกี่ยวกับโทรศัพท์ → หมายเลขบิลด์ ตัวเลือกสำหรับนักพัฒนา: ระบบ',
    'adbAdvanced': 'ขั้นสูง',
    'adbDetails': 'รายละเอียด',
    'adbAndroidDataTitle': 'วิดีโอใน Android/data',
    'adbAndroidDataSub': 'Telegram และแอปอื่นเก็บวิดีโอไว้ใน Android/data และ Android/obb เมื่อเชื่อมต่อแล้ว Innocent จะค้นหาและเพิ่มลงใน Local',
    'adbFound': 'พบวิดีโอ {n} รายการ',
    'adbLostTitle': 'Android/data ต้องใช้การเชื่อมต่อ ADB',
    'adbLostBody': 'การเชื่อมต่อหลุด ส่วนใหญ่เพราะการแก้ไขข้อบกพร่องผ่าน Wi-Fi ปิดลง เปิดอีกครั้ง โฟลเดอร์นี้จะเปิดเองทันทีที่เชื่อมต่อได้',
    'adbLostAction': 'การตั้งค่า ADB',
    'destinationIfExists': 'หากมีไฟล์ชื่อเดียวกันอยู่แล้ว',
    'destinationKeepBoth': 'เก็บทั้งคู่',
    'destinationSkip': 'ข้าม',
    'destinationOverwrite': 'เขียนทับ',
    'selectionMove': 'ย้าย',
    'selectionCopy': 'คัดลอก',
    'selectionSelectAll': 'เลือกทั้งหมด',
    'selectionDeselectAll': 'ยกเลิกการเลือก',
    'selectionMoveTitle': 'ย้ายไปที่',
    'selectionCopyTitle': 'คัดลอกไปที่',
    'selectionEditingOff': 'ปิดการแก้ไขอยู่ใน Settings → General → Allow editing',
    'selectionNoFiles': 'ไฟล์เหล่านี้ระบบจัดการ ย้ายหรือคัดลอกไม่ได้',
    'selectionWorking': 'กำลังทำงาน…',
    'selectionMoved': 'ย้ายแล้ว',
    'selectionCopied': 'คัดลอกแล้ว',
    'selectionRebuilt': 'ภาพย่อจะสร้างใหม่เมื่อเลื่อน',
    'selectionHidden': 'ซ่อนจากคลังแล้ว',
    'vhGateMistakeConfirmTitle': 'ถามอีกครั้งไหม',
    'vhGateMistakeConfirmBody': 'ดำเนินการต่อเฉพาะเมื่อคุณกดปุ่มผิดเท่านั้น คุณต้องมีอายุ 18 ปีขึ้นไปจึงจะใช้ส่วนนี้ได้',
    'vhGateMistakeConfirmYes': 'ใช่ ฉันกดผิด',
    'vhSignInGoogle': 'ดำเนินการต่อด้วย Google',
    'vhSignInGoogleSoon': 'ยังไม่รองรับการเข้าสู่ระบบด้วย Google กรุณาใช้เบอร์โทรศัพท์',
    'vhSignInGoogleFailed': 'เข้าสู่ระบบด้วย Google ไม่สำเร็จ กรุณาลองใหม่อีกครั้ง',
    'vhSignInOr': 'หรือ',
    'vhLibraryBookmarks': 'บุ๊กมาร์ก',
    'vhLibraryBookmarksHint': 'รายการที่คุณบันทึกไว้',
    'vhLibraryDownloads': 'ดาวน์โหลด',
    'vhLibraryDownloadsHint': 'ดูออฟไลน์ ไม่ต้องใช้เน็ต',
    'vhDeleteDownloadBody':
        'ลบดาวน์โหลดนี้ออกจากเครื่องหรือไม่ คุณดาวน์โหลดใหม่ได้ '
        'ตราบใดที่สมาชิกยังใช้งานอยู่',
    'vhDiscardDownloadBody':
        'ทิ้งดาวน์โหลดที่ยังไม่เสร็จนี้หรือไม่ ส่วนที่อยู่ในเครื่องแล้ว'
        'จะถูกลบ',
    'vhDownloadUnfinished': 'ยังไม่เสร็จ',
    'vhDownloadQueued': 'รอคิว',
    'vhDownloadPaused': 'หยุดไว้',
    'vhDownloadResuming': 'กำลังดาวน์โหลด',
    'vhDownloadResume': 'ทำต่อ',
    'vhDownloadPause': 'หยุดพัก',
    'vhWatchNow': 'ดูเลย',
    'vhWatchNotYet': 'ยังได้ไฟล์มาไม่พอ ลองอีกครั้งในอีกสักครู่',
    'vhWatchIndexAtEnd': 'เรื่องนี้ดูได้เมื่อดาวน์โหลดเสร็จแล้วเท่านั้น',
    'vhWatchGone': 'ไม่พบไฟล์ดาวน์โหลดนี้บนเครื่องแล้ว',
    'vhDownloadNoSpace':
        'พื้นที่ในเครื่องไม่พอ ลบไฟล์บางส่วนแล้วเริ่มใหม่ '
        'ส่วนที่ดาวน์โหลดแล้วยังอยู่',
    'vhDownloadGaveUp':
        'การเชื่อมต่อหลุดบ่อย ส่วนที่ดาวน์โหลดแล้วยังอยู่ '
        'ทำต่อได้จากหน้าดาวน์โหลดเมื่อมีสัญญาณ',
    'vhDownloadWaitingSignal': 'กำลังรอการเชื่อมต่อ…',
    'vhDownloadReadyOffline': 'ดูออฟไลน์ได้แล้ว',
    'vhDownloadWifiOnly': 'ดาวน์โหลดผ่าน Wi-Fi เท่านั้น',
    'vhDownloadWifiOnlyHint':
        'รอ Wi-Fi แทนการใช้เน็ตมือถือ ปิดไว้เป็นค่าเริ่มต้น '
        'เพราะผู้ใช้ส่วนใหญ่ที่นี่ไม่มี Wi-Fi ให้รอ',
    'vhDownloadWifiOnlyBlocked':
        'กำลังรอ Wi-Fi ส่วนที่ดาวน์โหลดแล้วยังอยู่ - จะทำต่อเอง '
        'หรือปิด "Wi-Fi เท่านั้น" เพื่อใช้เน็ตมือถือ',
    'vhDownloadOnMobile': 'คุณกำลังใช้เน็ตมือถือ',
    'vhDownloadWillResume': 'จะทำต่อเอง',
    'vhDownloadSizeAsk':
        'เรื่องนี้ขนาด {size} ดาวน์โหลดแบบคุณภาพเต็ม '
        'เครื่องนี้เหลือพื้นที่ {free} ดำเนินการต่อหรือไม่',
    'vhDownloadStart': 'ดาวน์โหลด',
    'vhDlQualityTitle': 'คุณภาพการดาวน์โหลด',
    'vhDlQualityOriginal': 'ต้นฉบับ (ดีที่สุด)',
    'vhDlQualityRemember': 'จำตัวเลือกนี้',
    'vhDlQualityFree': 'พื้นที่ว่างในเครื่อง {free}',
    'vhDlQualityHint': 'ไฟล์ที่เล็กกว่าช่วยประหยัดเน็ตและพื้นที่ ส่วนต้นฉบับภาพสวยที่สุด',
    'vhDlQualityAsk': 'ถามทุกครั้ง',
    'vhDownloadStorageLine': 'ในเครื่องนี้',
    'vhDownloadLeftSoon': 'เหลือไม่ถึงหนึ่งนาที',
    'vhDownloadLeftMinutes': 'เหลือ {m} นาที',
    'vhDownloadLeftHours': 'เหลือ {h} ชม. {m} นาที',
    'vhDownloadLeftAges': 'เหลือมากกว่าหนึ่งวัน',
    'vhDownloadStorage': 'ใช้ {used} - เหลือ {free}',
    'vhLibrarySoon': 'เร็ว ๆ นี้',

    // --- Video Hub: view counts ---
    'vhViewsCount': '{n} ครั้ง',

    // --- Video Hub: account / KPay payment ---
    'vhSignInTitle': 'เข้าสู่ระบบ',
    'vhSignInWhy': 'เข้าสู่ระบบเพื่อให้จับคู่การชำระเงินกับบัญชีของคุณได้ เราใช้เบอร์เพื่อยืนยันการสมัครสมาชิกเท่านั้น',
    'vhSignInPhoneHint': '09xxxxxxxxx',
    'vhSignInCodeHint': 'รหัส 6 หลัก',
    'vhSignInSendFailed': 'ส่งรหัสไม่สำเร็จ ลองใหม่อีกครั้งในอีกสักครู่',
    'vhSignInNoConnection': 'ไม่มีการเชื่อมต่อ ตรวจสอบอินเทอร์เน็ตแล้วลองใหม่',
    'vhSignInSendCode': 'ส่งรหัส',
    'vhSignInVerify': 'ยืนยัน',
    'vhSignInBadPhone': 'กรอกเบอร์โทรให้ถูกต้อง',
    'vhSignInBadCode': 'รหัสไม่ถูกต้อง',
    'vhSignOut': 'ออกจากระบบ',
    'vhAccountTitle': 'บัญชี',
    'vhAccountFreePlan': 'แผนฟรี',
    'vhAccountRequests': 'คำขอชำระเงิน',
    'vhRequestPending': 'ส่งแล้ว - กำลังตรวจสอบ',
    'vhRequestApproved': 'อนุมัติแล้ว',
    'vhRequestRejected': 'ถูกปฏิเสธ',
    'vhDevApprove': 'อนุมัติในเครื่อง (สำหรับพัฒนาเท่านั้น)',
    'vhPayTitle': 'ชำระด้วย KPay',
    'vhPayStep1': 'โอนยอดไปยังบัญชี KPay นี้',
    'vhPayStep2': 'โอนใน KPay แล้วแคปหน้าจอใบเสร็จ',
    'vhPayStep3': 'แนบภาพหน้าจอใบเสร็จ',
    'vhPayStep4': 'เพิ่มหมายเหตุ (ไม่บังคับ)',
    'vhPayNoteHint': 'เช่น โอนจาก KPay ของน้องสาวราว 3 ทุ่ม หรือสิ่งที่อยากให้เรารู้',
    'vhPayPrivate': 'ใบเสร็จของคุณจะเห็นได้เฉพาะทีม Innocent',
    'vhPayNextTitle': 'ขั้นตอนถัดไป',
    'vhPayNext1': 'ได้รับใบเสร็จของคุณแล้ว',
    'vhPayNext2': 'เราจะตรวจสอบกับรายการ KPay',
    'vhPayNext3': 'Premium จะเปิดเอง — ดูได้ที่บัญชี',
    'vhRequestYouWrote': 'คุณเขียนว่า',
    'vhRequestReply': 'จาก Innocent',
    'vhPayPayee': 'ชื่อบัญชี',
    'vhPayNumber': 'เบอร์ KPay',
    'vhPayAmount': 'จำนวนเงิน',
    'vhPayCopied': 'คัดลอกแล้ว',
    'vhPayReferenceHint': 'รหัสธุรกรรม KPay',
    'vhPaySenderHint': 'เบอร์ที่ใช้โอน',
    'vhPaySubmit': 'ส่งให้ตรวจสอบ',
    'vhPayManualNote': 'การชำระเงินตรวจสอบด้วยคนเทียบกับรายการ KPay จึงไม่เปิดใช้งานทันที',
    'vhPayOpenKpay': 'เปิด KPay',
    'vhPayNoKpay': 'เครื่องนี้ไม่มี KPay',
    'vhPayRecentShots': 'ภาพหน้าจอล่าสุด — แตะใบเสร็จ',
    'vhPayChooseShot': 'เลือกภาพหน้าจอจากรูปภาพ',
    'aboutTagline': 'ดูวิดีโอของคุณได้อย่างสวยงาม',
    'aboutVersionFull': 'เวอร์ชัน {v} ({b})',
    'aboutCopied': 'คัดลอกเวอร์ชันแล้ว',
    'aboutCopyHint': 'แตะสองครั้งเพื่อคัดลอก',
    'aboutSectionApp': 'แอป',
    'aboutSectionSupport': 'ความช่วยเหลือ',
    'aboutSoftwareUpdate': 'อัปเดตซอฟต์แวร์',
    'aboutUpToDate': 'เป็นเวอร์ชันล่าสุด',
    'aboutUpdateReady': 'มีเวอร์ชันใหม่พร้อมติดตั้ง',
    'aboutWhatsNew': 'มีอะไรใหม่',
    'aboutWhatsNewIn': 'มีอะไรใหม่ใน {v}',
    'aboutHelpFaq': 'ความช่วยเหลือและคำถามที่พบบ่อย',
    'aboutRights': '© 2026 Innocent สงวนลิขสิทธิ์',
    'vhPayShotAttached': 'แนบใบเสร็จแล้ว',
    'vhPayShotCheck': 'ตรวจว่ามองเห็นยอดเงินและรายการ',
    'vhPayShotChange': 'เปลี่ยน',
    'vhPayAddTxn': 'ใส่รหัสธุรกรรม (ไม่บังคับ)',
    'vhPayNeedProof': 'แนบภาพใบเสร็จ หรือใส่รหัสธุรกรรม',
    'vhPayTooMany': 'คุณมีการชำระเงินที่รอตรวจอยู่แล้ว โปรดรอสักครู่',
    'vhPayBadImage': 'อ่านไฟล์นี้ไม่ได้ โปรดเลือกภาพหน้าจออีกครั้ง',
    'vhPaySubmitFailed': 'ส่งรายละเอียดการชำระเงินไม่สำเร็จ ยังไม่มีการบันทึกใด ๆ - ตรวจสอบการเชื่อมต่อแล้วลองใหม่',
    'vhPayDetailsStale': 'ติดต่อเซิร์ฟเวอร์ไม่ได้ นี่คือรายละเอียดที่บันทึกไว้ในเครื่องครั้งล่าสุด - ตรวจสอบก่อนโอนเงิน',
    'vhPayDetailsUnavailable': 'โหลดรายละเอียดการชำระเงินไม่ได้ อย่าโอนเงินจนกว่าจะแสดงขึ้น',
    'vhPayQueuedTitle': 'ส่งการชำระเงินแล้ว',
    'vhPayQueuedBody': 'เราจะตรวจสอบกับรายการ KPay แล้วเปิดใช้งานบัญชีให้ ปิดแอปได้ ข้อมูลจะยังอยู่',
    'vhPayDone': 'เสร็จสิ้น',
    'vhSignInDevCode': 'เวอร์ชันพัฒนา: ใช้รหัส {n}',
    'vhAccountExpires': 'ใช้ได้ถึง {n}',

    // --- Video Hub: premium / paywall ---
    'vhPaywallTitle': 'Innocent Premium',
    'vhPaywallGeneric': 'ปลดล็อกวิดีโอทั้งหมด แกลเลอรีเต็ม และคุณภาพสูงสุด',
    'vhPerkPlay': 'เล่นวิดีโอได้ทุกเรื่อง',
    'vhPerkMedia': 'ดูรูปและคลิปทั้งหมด ไม่ใช่แค่ตัวอย่าง',
    'vhPerkQuality': 'คุณภาพสูงสุดที่มี',
    'vhPlanYearly': 'รายปี',
    'vhPlanYearlyNote': 'คุ้มที่สุด',
    'vhPlanMonthly': 'รายเดือน',
    'vhPaywallFinePrint': 'ชำระครั้งเดียวสำหรับระยะเวลาที่แสดง ไม่ต่ออายุอัตโนมัติ ชำระอีกครั้งเพื่อขยายเวลา',
    'vhPaywallNotNow': 'ไว้ก่อน',
    'vhPremiumBadge': 'VIP',
    'vhLockedItem': 'Premium',
    'vhFreePreview': 'ตัวอย่าง',
    'vhPremiumActive': 'เปิดใช้ Premium แล้ว',
    'vhUpgrade': 'อัปเกรด',
    'vhPaywallLockedCount': 'ปลดล็อกรูปและวิดีโออีก {n} รายการในเรื่องนี้',
    'vhPaywallForTitle': 'ดู {n} แบบเต็ม',
    'vhLockedCountShort': 'ล็อก {n} รายการ',

    // --- Video Hub: filter toolbar / hero ---
    'vhFilters': 'ตัวกรอง',
    'vhClearAll': 'ล้างทั้งหมด',
    'vhMoreInfo': 'ข้อมูลเพิ่มเติม',
    'vhShowResults': 'ดู {n} รายการ',
    'vhEpisodesCount': '{n} ตอน',

    // --- Video Hub: see-all ---
    'vhSeeAll': 'ดูทั้งหมด',
    'vhSortPopular': 'ดูมากที่สุด',
    'vhTitlesCount': '{n} รายการ',

    // --- Video Hub ---
    'vhVideoChip': 'ภาพยนตร์',
    'vhSearchHint': 'ค้นหาหนัง ซีรีส์ คลิป',
    'vhCategoryAll': 'ทั้งหมด',
    'vhCategoryMovies': 'ภาพยนตร์',
    'vhCategorySeries': 'ซีรีส์',
    'vhCategoryReels': 'คลิป',
    'vhMore': 'เพิ่มเติม',
    'vhRowTrending': 'กำลังมาแรง',
    'vhRowNewReleases': 'มาใหม่',
    'vhFilterGenre': 'ประเภท',
    'vhFilterYear': 'ปี',
    'vhFilterQuality': 'ความคมชัด',
    'vhFilterSort': 'เรียงตาม',
    'vhFilterClear': 'ล้าง',
    'vhFilterAny': 'ทั้งหมด',
    'vhSortNewest': 'ใหม่ล่าสุด',
    'vhSortTitle': 'A-Z',
    'vhNoContent': 'ยังไม่มีเนื้อหา จะแสดงเมื่อเชื่อมต่อแหล่งข้อมูลแล้ว',
    'vhNoMatchingContent': 'ไม่พบรายการที่ตรงกับตัวกรองนี้',
    'vhLoadFailed': 'โหลดเนื้อหาไม่สำเร็จ',
    'vhOfflineBanner': 'ออฟไลน์ — กำลังแสดงข้อมูลที่บันทึกไว้',
    'vhOfflineNothingSaved': 'ไม่มีการเชื่อมต่ออินเทอร์เน็ต',
    'vhOfflineHint': 'เชื่อมต่อหนึ่งครั้งแล้วหน้านี้จะถูกบันทึกไว้ใช้งานออฟไลน์ ส่วนรายการที่ดาวน์โหลดไว้เล่นได้โดยไม่ต้องเชื่อมต่อ',
    'vhOfflineNotHeld': 'ไม่มีการเชื่อมต่อ และไม่มีส่วนใดของรายการนี้บันทึกไว้ในเครื่อง',
    'vhBatteryDozeTitle': 'การดาวน์โหลดอาจหยุดเมื่อปิดหน้าจอ',
    'vhBatteryDozeBody': 'เครื่อง {maker} จะหยุดงานเบื้องหลังเพื่อประหยัดแบตเตอรี่ ไฟล์จึงอาจหยุดกลางคันโดยไม่มีคำอธิบาย การอนุญาตให้แอปนี้ทำงานต่อจะช่วยให้ดาวน์โหลดจบขณะเครื่องอยู่ในกระเป๋า',
    'vhBatteryAllow': 'อนุญาตให้ดาวน์โหลดเบื้องหลัง',
    'vhBatteryBlockedTitle': 'กิจกรรมเบื้องหลังถูกปิดสำหรับแอปนี้',
    'vhBatteryBlockedBody': 'จะไม่มีการดาวน์โหลดขณะไม่ได้เปิดแอป นี่เป็นการตั้งค่าของเครื่อง อยู่ใต้หัวข้อแบตเตอรี่ในหน้าแอปนี้ และเปลี่ยนจากที่นี่ไม่ได้',
    'vhBatteryOpenSettings': 'เปิดการตั้งค่าแอป',
    'vhOfflineReplayPartial': 'กำลังเล่นส่วนที่บันทึกไว้ จะหยุดเมื่อถึงจุดสิ้นสุดของส่วนนั้น',
    'vhOfflineReplayNotEnough': 'บันทึกไว้น้อยเกินกว่าจะเปิดได้โดยไม่เชื่อมต่อ',
    'vhOfflineReplayWholeFileOnly': 'วิดีโอนี้ดูออฟไลน์ได้เมื่อบันทึกไว้ครบทั้งไฟล์แล้วเท่านั้น',
    'vhRetry': 'ลองอีกครั้ง',
    'vhSearchPrompt': 'ค้นหาจากทุกหมวดหมู่',
    'vhSearchNoResults': 'ไม่พบรายการ',
    'vhAlbum': 'รูปและวิดีโอ',
    'vhPlay': 'เล่น',
    'vhUnavailable': 'ยังไม่สามารถเล่นรายการนี้ได้',
    'vhWrongDevice': 'บัญชีของคุณยังใช้งานได้ แต่เครื่องนี้ยังไม่อยู่ในรายการ โปรดออกจากระบบในเครื่องที่ไม่ได้ใช้แล้ว จากนั้นลองอีกครั้ง',
    'clearAll': 'ล้างทั้งหมด',
    'setupPinConfirmHint': 'ป้อน PIN เดิมอีกครั้งเพื่อยืนยัน',
    'pinSetFailed': 'บันทึก PIN ไม่สำเร็จ โปรดลองอีกครั้ง',
    'changePinCurrentHint': 'ป้อน PIN ปัจจุบันเพื่อดำเนินการต่อ',
    'changePinNewHint': 'เลือก PIN ใหม่ 4 ถึง 6 หลัก',
    'changePinConfirmHint': 'ป้อน PIN ใหม่อีกครั้งเพื่อยืนยัน',
    'changePinFailed': 'เปลี่ยน PIN ไม่สำเร็จ โปรดลองอีกครั้ง',
    'vaultTemporarilyLocked': 'ป้อนผิดหลายครั้งเกินไป โปรดรอจนหมดเวลา',
    'decoyPinEntryHint': 'PIN นี้จะเปิดตู้นิรภัยเปล่าแทนของจริง',
    'decoyPinConfirmHint': 'ป้อน PIN ลวงอีกครั้งเพื่อยืนยัน',
    'vaultProgressSafeNote': 'ไฟล์ต้นฉบับจะถูกเก็บไว้จนกว่าสำเนาจะผ่านการตรวจสอบ',
    'lockingFiles': 'กำลังล็อกไฟล์',
    'notEnoughSpace': 'พื้นที่ไม่เพียงพอสำหรับล็อกไฟล์เหล่านี้ กรุณาเพิ่มพื้นที่ว่างแล้วลองใหม่',
    'unlockingFiles': 'กำลังกู้คืนไฟล์',
    'importCancelled': 'หยุดแล้ว ไฟล์ที่ล็อกไปแล้วยังอยู่ในตู้นิรภัย',
    'recoveryLockedOut': 'พยายามหลายครั้งเกินไป โปรดลองใหม่ภายหลัง',
    'autoLock': 'ล็อกอัตโนมัติ',
    'autoLockDesc': 'ตู้นิรภัยจะเปิดอยู่นานเท่าใดหลังคุณออกจากแอป',
    'autoLockImmediately': 'ทันที',
    'screenCaptureBlocked': 'บล็อกภาพหน้าจอ',
    'screenCaptureBlockedDesc': 'ภาพหน้าจอ การบันทึกหน้าจอ และตัวอย่างในตัวสลับแอปถูกบล็อกขณะเปิดตู้นิรภัย เปิดใช้งานตลอด',
    'loadingMore': 'กำลังโหลดเพิ่ม…',
    'appName': 'Innocent',
    'tabLocal': 'วิดีโอ',
    'tabMusic': 'เพลง',
    'tabTransfer': 'ส่งไฟล์',
    'tabMe': 'ฉัน',
    'settingsTitle': 'การตั้งค่า',
    'settingsList': 'รายการ',
    'settingsPlayer': 'เครื่องเล่น',
    'settingsDecoder': 'ตัวถอดรหัส',
    'settingsAudio': 'เสียง',
    'settingsSubtitle': 'คำบรรยาย',
    'settingsGeneral': 'ทั่วไป',
    'settingsDevelopment': 'การพัฒนา',
    'downloads': 'ดาวน์โหลด',
    'fileTransfer': 'ส่งไฟล์',
    'privateFolder': 'โฟลเดอร์ส่วนตัว',
    'videoPlaylists': 'เพลย์ลิสต์วิดีโอ',
    'mediaManager': 'จัดการสื่อ',
    'localNetwork': 'เครือข่ายในเครื่อง',
    'networkStream': 'สตรีมเครือข่าย',
    'cloudDrive': 'คลาวด์ไดรฟ์',
    'appTheme': 'ธีมแอป',
    'popupPlay': 'ป๊อปอัปเล่น',
    'watchInsights': 'ข้อมูลการดู',
    'legal': 'กฎหมาย',
    'backupRestore': 'สำรอง & กู้คืน',
    'quit': 'ออก',
    'quitConfirmTitle': 'ออกจาก Innocent?',
    'quitConfirmBody': 'แอปจะปิดสมบูรณ์ การเล่นปัจจุบันจะหยุด',
    'statusSaver': 'บันทึกสถานะ',
    'musicTracks': 'เพลง',
    'musicAlbums': 'อัลบั้ม',
    'musicArtists': 'ศิลปิน',
    'musicFolders': 'โฟลเดอร์',
    'noSongsToShuffle': 'ไม่มีเพลงให้สุ่ม',
    'noAlbumsFound': 'ไม่พบอัลบั้ม',
    'noArtistsFound': 'ไม่พบศิลปิน',
    'noMusicFoldersFound': 'ไม่พบโฟลเดอร์เพลง',
    'errorLoadingAlbums': 'โหลดอัลบั้มไม่สำเร็จ',
    'errorLoadingArtists': 'โหลดศิลปินไม่สำเร็จ',
    'errorLoadingFolders': 'โหลดโฟลเดอร์ไม่สำเร็จ',
    'searchSongs': 'ค้นหาเพลง...',
    'newPlaylist': 'เพลย์ลิสต์ใหม่',
    'playlistName': 'ชื่อเพลย์ลิสต์',
    'create': 'สร้าง',
    'addToHomeScreen': 'เพิ่มไปหน้าจอหลัก',
    'addedToHomeScreen': 'เพิ่มไปหน้าจอหลักแล้ว',
    'addWidget': 'เพิ่มวิดเจ็ต',
    'widgetAdded': 'เพิ่มวิดเจ็ตแล้ว',
    'resumePlaySettings': 'ตั้งค่าเล่นต่อ',
    'alwaysResume': 'เล่นต่อเสมอ',
    'askEveryTime': 'ถามทุกครั้ง',
    'startFromBeginning': 'เริ่มจากต้น',
    'playingQueue': 'คิว ที่เล่น',
    'aspectRatioMenu': 'อัตราส่วน ภาพ',
    'displaySettings': 'ตั้งค่า จอภาพ',
    'bookmark': 'บุ๊กมาร์ก',
    'cut': 'ตัด',
    'favourite': 'รายการโปรด',
    'addToPlaylistMenu': 'เพิ่มไป เพลย์ลิสต์',
    'information': 'ข้อมูล',
    'share': 'แชร์',
    'tutorial': 'บทเรียน',
    'subtitleDelayMenu': 'ดีเลย์ คำบรรยาย',
    'skipMarkers': 'ข้าม มาร์กเกอร์',
    'customSpeed': 'ความเร็ว กำหนดเอง',
    'loopOff': 'ปิดวนซ้ำ',
    'loopOne': 'วนซ้ำ หนึ่ง',
    'loopAll': 'วนซ้ำ ทั้งหมด',
    'subtitleOff': 'ปิดคำบรรยาย',
    'aspectRatioTitle': 'อัตราส่วนภาพ',
    'pressBackAgain': 'กดย้อนกลับอีกครั้งเพื่อปิด',
    'playerQuality': 'คุณภาพ',
    'playerQualityAutoHint': 'ปรับตามการเชื่อมต่อ',
    'playerQualityFailed': 'เปลี่ยนคุณภาพไม่ได้ ยังเล่นสำเนาเดิมอยู่',
    'vhAlbumDownloadAll': 'ดาวน์โหลดทั้งหมด',
    'vhAlbumDownloaded': 'ดาวน์โหลดแล้ว',
    'vhAlbumDownloadNew': 'ดาวน์โหลด',
    'vhAlbumPlusVideos': '+{n} วิดีโอ',
    'vhAlbumPlusPhotos': '+{n} รูป',
    'vhAlbumProgress': '{done} / {total}',
    'vhCountOf': '{i} จาก {n}',
    'vhResumeAt': 'ดูต่อ {t}',
    'vhStartOver': 'เริ่มใหม่',
    'vhMinutesLeft': 'เหลือ {m} นาที',
    'vhRemoveFromContinue': 'นำออกจากดูต่อ',
    'vhRemovedFromContinue': 'นำออกจากดูต่อแล้ว',
    'vhMoreLikeThis': 'เรื่องที่คล้ายกัน',
    'vhUpNext': 'ถัดไป',
    'vhUpNextIn': 'ถัดไปใน {s}',
    'vhPlayNow': 'เล่นเลย',
    'vhStillWatching': 'ยังดูอยู่ไหม?',
    'vhKeepWatching': 'ดูต่อ',
    'vhAlbumVideos': 'วิดีโอ {n} รายการ',
    'vhAlbumPhotos': 'รูป {n} รูป',
    'vhAlbumVideo1': 'วิดีโอ 1 รายการ',
    'vhAlbumPhoto1': 'รูป 1 รูป',
    'vhAlbumAsk': '{items} ประมาณ {size} ที่คุณภาพเต็ม เหลือพื้นที่ {free} ดำเนินการต่อไหม?',
    'vhAlbumAskNoSize': '{items} ที่คุณภาพเต็ม เหลือพื้นที่ {free} ดำเนินการต่อไหม?',
    'vhAlbumSomeFailed': 'ดาวน์โหลดไม่ได้ {n} รายการ แตะดาวน์โหลดเพื่อลองอีกครั้ง',
    'vhSavedOffline': 'บันทึกไว้ในเครื่องแล้ว',
    'vhSaveOffline': 'บันทึกไว้ดูออฟไลน์',
    'vhAlbumDeleteBody': 'ลบรูปและคลิปของอัลบั้มนี้ออกจากเครื่องไหม? ภาพยนตร์ที่ดาวน์โหลดไว้ยังอยู่',
    'vhDeleteItemBody': 'ลบออกจากเครื่องไหม? ดาวน์โหลดใหม่ได้ภายหลัง',
    'vhDataSaver': 'ประหยัดเน็ต',
    'vhDataSaverHint': 'อัลบั้มแสดงภาพเบลอ แตะปุ่มดาวน์โหลดเฉพาะรายการที่ต้องการ',
    'vhDataSaverWifi': 'บน Wi-Fi ด้วย',
    'vhDataSaverWifiHint': 'ปิดไว้: บน Wi-Fi อัลบั้มโหลดตามปกติ',
    'vhDataSaverOn': 'เปิดประหยัดเน็ตอยู่ — แตะเพื่อแสดงตามปกติ',
    'vhDataSaverOff': 'เปิดประหยัดเน็ต',
    'vhSaverChip': 'ประหยัด',
    'vhDiagTitle': 'แจ้งปัญหา',
    'vhDiagHint': 'ส่งสิ่งที่แอปบันทึกไว้ เพื่อให้แก้ไขได้',
    'vhDiagBody': 'จะส่งสิ่งที่แอปบันทึกเกี่ยวกับการดาวน์โหลดและการเล่นบนเครื่องนี้ พร้อมรุ่นเครื่องและประเภทการเชื่อมต่อ ไม่มีลิงก์ รหัสผ่าน หรือไฟล์ของคุณ',
    'vhDiagNoteHint': 'เกิดอะไรขึ้น? (ไม่บังคับ)',
    'vhDiagSent': 'ส่งแล้ว รหัสรายงานของคุณ:',
    'vhDiagSentHint': 'แจ้งรหัสนี้เมื่อเล่าปัญหาให้เราฟัง',
    'vhDiagFailed': 'ส่งไม่ได้ ตรวจสอบการเชื่อมต่อแล้วลองอีกครั้ง',
    'vhDiagCopied': 'คัดลอกรหัสแล้ว',
    'vhSaverModeAll': 'ทุกการเชื่อมต่อ',
    'vhSaverModeAllHint': 'รวม Wi-Fi — สำหรับ Wi-Fi ที่คิดตาม GB',
    'vhSaverModeMobile': 'เฉพาะเน็ตมือถือ',
    'vhSaverModeMobileHint': 'บน Wi-Fi อัลบั้มโหลดตามปกติ',
    'vhSaverNowOn': 'กำลังประหยัด · {conn}',
    'vhSaverNowOff': 'ไม่ประหยัดบน {conn}',
    'vhConnWifi': 'Wi-Fi',
    'vhConnMobile': 'เน็ตมือถือ',
    'vhConnOffline': 'ออฟไลน์',
    'vhConnOther': 'การเชื่อมต่อนี้',
    'vhSaverBanner': 'เปิดประหยัดเน็ตอยู่ — รูปและคลิปโหลดเมื่อแตะเท่านั้น',
    'vhSaverTurnOff': 'ปิด',
    'vhSaverHowTitle': 'ทำงานอย่างไร',
    'vhSaverHow1': 'อัลบั้มแสดงภาพเบลอ ไม่มีการดาวน์โหลดเพื่อแสดงภาพนี้',
    'vhSaverHow2': 'รูปและคลิปแต่ละรายการแสดงขนาด แตะเฉพาะที่ต้องการ',
    'vhSaverHow3': 'สิ่งที่เปิดแล้วเก็บไว้ในเครื่อง ไม่เสียเน็ตซ้ำ',
    'vhSaverHow4': 'หนังที่ตั้งคุณภาพเป็นอัตโนมัติจะสตรีมไม่เกิน 480p',
    'vhLibraryDataSaverHint': 'อัลบั้มโหลดเฉพาะที่แตะ',
    'vhBookmark': 'บันทึก',
    'vhBookmarked': 'บันทึกแล้ว',
    'vhBookmarkAdded': 'บันทึกในบุ๊กมาร์กแล้ว',
    'vhBookmarkRemoved': 'นำออกจากบุ๊กมาร์กแล้ว',
    'vhUndo': 'เลิกทำ',
    'vhBookmarksEmpty': 'ยังไม่มีรายการที่บันทึก แตะบุ๊กมาร์กบนเรื่องใดก็ได้เพื่อเก็บไว้ที่นี่',
    'vhBookmarksSignInHint': 'ลงชื่อเข้าใช้เพื่อเก็บบุ๊กมาร์กไว้ทุกเครื่อง',
    'vhBookmarksCount': 'บันทึกไว้ {n} รายการ',
    'vhOn': 'เปิด',
    'vhEdit': 'แก้ไข',
    'vhDownloadsActive': 'กำลังดาวน์โหลด',
    'vhDownloadYielding': 'ลดความเร็วระหว่างที่ดูอยู่',
    'vhDownloadsDone': 'ดาวน์โหลดแล้ว',
    'vhDownloadsSettings': 'ตั้งค่าดาวน์โหลด',
    'playerNoticeIncomplete': 'ไฟล์นี้ดาวน์โหลดไม่ครบ เล่นได้ถึง {t}',
    'playerNoticeSeekHeld': 'ยังไม่ได้ดาวน์โหลดหลัง {t}',
    'playerNoticeSoftware': 'ตัวถอดรหัสฮาร์ดแวร์ใช้กับไฟล์นี้ไม่ได้ กำลังเล่นด้วยตัวถอดรหัสซอฟต์แวร์ (SW)',
    'playerNoticeHwUnavailable': 'ตัวถอดรหัสฮาร์ดแวร์หยุดทำงานหลังจากไฟล์เสีย ตอนนี้เล่นด้วยซอฟต์แวร์ ปิดแล้วเปิด Innocent ใหม่เพื่อให้กลับมา',
    'playerNoticeEngineRestarted': 'เริ่มเครื่องเล่นใหม่แล้ว หลังจากวิดีโอก่อนหน้าไม่ตอบสนอง',
    'playerDamagedStretch': 'ส่วนนี้ของไฟล์เสียหรือดาวน์โหลดไม่ครบ จึงหยุดเล่นตรงนี้ แตะลองอีกครั้ง หรือกลับไป',
    'playerEngineStuck': 'เครื่องเล่นไม่ตอบสนองกับไฟล์นี้ ไฟล์อาจเสียหรือดาวน์โหลดไม่ครบ แตะลองอีกครั้ง หรือกลับไปเปิดวิดีโออื่น',
    'close': 'ปิด',
    'audioTrack': 'แทร็กเสียง',
    'subtitle': 'คำบรรยาย',
    'lockControls': 'ล็อกการควบคุม',
    'refresh': 'รีเฟรช',
    'refreshingLibrary': 'กำลังรีเฟรชสื่อ...',
    'noVideosFound': 'ไม่พบวิดีโอ',
    'noVideosMatch': 'ไม่พบวิดีโอที่ตรงกับ',
    'resume': 'เล่นต่อ',
    'permissionRationale': 'Innocent ต้องการสิทธิ์เพื่ออ่านวิดีโอบนอุปกรณ์ของคุณ เราไม่เก็บหรืออัปโหลดข้อมูลของคุณ',
    'permissionRationalePermanent':
        'Innocent ต้องการสิทธิ์วิดีโอเพื่อสแกนคลัง คำขอจากระบบไม่สามารถแสดงจากที่นี่ได้อีก โปรดเปิดใช้ในการตั้งค่าแอปแล้วกลับมา ไม่มีข้อมูลออกจากอุปกรณ์ของคุณ',
    'features': 'คุณสมบัติ',
    'faq': 'คำถามที่พบบ่อย',
    'versionCheck': 'ตรวจสอบเวอร์ชัน',
    'sendBugReport': 'ส่งรายงานข้อผิดพลาด',
    'privacy': 'ความเป็นส่วนตัว',
    'whatsNew': 'มีอะไรใหม่',
    'bugReportHint':
        'ใช้ thumbs-down ในแชทเพื่อส่งความคิดเห็นถึงผู้พัฒนา',
    'sortLabel': 'เรียงลำดับ',
    'ascending': 'น้อยไปมาก',
    'descending': 'มากไปน้อย',
    'sortName': 'ชื่อ',
    'sortDate': 'วันที่',
    'sortSize': 'ขนาด',
    'viewList': 'รายการ',
    'viewGrid': 'ตาราง',
    'history': 'ประวัติ',
    'favourites': 'รายการโปรด',
    'watchLater': 'ดูภายหลัง',
    'playlists': 'เพลย์ลิสต์',
    'recycleBin': 'ถังขยะ',
    'chipCleaner': 'ล้างไฟล์',
    'chipPlaylists': 'เพลย์ลิสต์',
    'chipPrivate': 'ส่วนตัว',
    'images': 'รูปภาพ',
    'statistics': 'สถิติ',
    'about': 'เกี่ยวกับ',
    'help': 'ช่วยเหลือ',
    'language': 'ภาษา',
    'retry': 'ลองใหม่',
    'cancel': 'ยกเลิก',
    'ok': 'ตกลง',
    'done': 'เสร็จสิ้น',
    'comingSoon': 'เร็ว ๆ นี้',
    'playbackFailed': 'เล่นไม่สำเร็จ',
    'permissionGrant': 'ให้สิทธิ์',
    'permissionOpenSettings': 'เปิดการตั้งค่า',
    'pipOverAppsTitle': 'เล่นทับแอปอื่น',
    'pipOverAppsBody': 'เพื่อให้วิดีโอเล่นต่อทับแอปอื่นหลังจากออกจาก Innocent โปรดเปิดสิทธิ์ Picture-in-picture สำหรับ Innocent ในการตั้งค่า',
    // ── v0.49 full-coverage localization pass ──
    'delete': 'ลบ',
    'clear': 'ล้าง',
    'reset': 'รีเซ็ต',
    'save': 'บันทึก',
    'rename': 'เปลี่ยนชื่อ',
    'restore': 'กู้คืน',
    'remove': 'นำออก',
    'apply': 'นำไปใช้',
    'stop': 'หยุด',
    'start': 'เริ่ม',
    'export': 'ส่งออก',
    'importWord': 'นำเข้า',
    'move': 'ย้าย',
    'hide': 'ซ่อน',
    'download': 'ดาวน์โหลด',
    'play': 'เล่น',
    'playAll': 'เล่นทั้งหมด',
    'shuffleAll': 'สุ่มเล่นทั้งหมด',
    'setWord': 'ตั้ง',
    'add': 'เพิ่ม',
    'addNow': 'เพิ่มเลย',
    'connect': 'เชื่อมต่อ',
    'disconnect': 'ยกเลิกการเชื่อมต่อ',
    'gotIt': 'เข้าใจแล้ว',
    'skip': 'ข้าม',
    'emptyVerb': 'ล้าง',
    'clean': 'ล้างข้อมูล',
    'copyPath': 'คัดลอกพาธ',
    'errorWord': 'ข้อผิดพลาด',
    'off': 'ปิด',
    'recent': 'ล่าสุด',
    'properties': 'คุณสมบัติ',
    'goBack': 'ย้อนกลับ',
    'unlock': 'ปลดล็อก',
    'lock': 'ล็อก',
    'path': 'พาธ',
    'newBadge': 'ใหม่',
    'failedToLoad': 'โหลดไม่สำเร็จ',
    'versionOf': 'เวอร์ชัน {v}',
    'fullAccessAlready': 'เปิดสิทธิ์เข้าถึงคลังทั้งหมดอยู่แล้ว',
    'fullAccessTitle': 'เปิดสิทธิ์เข้าถึงคลังทั้งหมด?',
    'fullAccessEnabled': 'เปิดสิทธิ์เข้าถึงคลังทั้งหมดแล้ว',
    'permissionNotGranted': 'ยังไม่ได้รับสิทธิ์ ลองใหม่ได้ทุกเมื่อ',
    'clearHistoryTitle': 'ล้างประวัติ?',
    'clearHistoryBody': 'จะลบประวัติการเล่นและการค้นหาทั้งหมด',
    'historyCleared': 'ล้างประวัติแล้ว',
    'clearThumbTitle': 'ล้างแคชภาพย่อ?',
    'clearThumbBody': 'ภาพย่อจะถูกสร้างใหม่เมื่อเปิดรายการสื่อ',
    'thumbCleared': 'ล้างแคชภาพย่อแล้ว',
    'resetSettingsTitle': 'รีเซ็ตการตั้งค่า?',
    'resetSettingsBody': 'การตั้งค่าทั้งหมดจะกลับเป็นค่าเริ่มต้น',
    'settingsResetDone': 'รีเซ็ตการตั้งค่าเป็นค่าเริ่มต้นแล้ว',
    'clearFontCacheTitle': 'ล้างแคชฟอนต์?',
    'fontCacheCleared': 'ล้างแคชฟอนต์แล้ว',
    'languageRestartNote': 'ภาษาจะเปลี่ยนเมื่อเปิดแอปใหม่',
    'exportedTo': 'ส่งออกไปที่ {path} แล้ว',
    'exportFailed': 'ส่งออกไม่สำเร็จ',
    'importFailed': 'นำเข้าไม่สำเร็จ',
    'importedFrom': 'นำเข้าการตั้งค่าจาก {path} แล้ว',
    'noExportFile': 'ไม่พบไฟล์ตั้งค่าที่ส่งออก กรุณาส่งออกก่อน',
    'moreLanguagesOnWay': 'ภาษาอื่น ๆ กำลังจะตามมา',
    'colorFormat': 'รูปแบบสี',
    'screenTitle': 'หน้าจอ',
    'navigationTitle': 'การนำทาง',
    'controlsTitle': 'การควบคุม',
    'styleTitle': 'สไตล์',
    'subtitleTextTitle': 'ข้อความซับไตเติล',
    'subtitleLayoutTitle': 'เลย์เอาต์ซับไตเติล',
    'soonBadge': 'เร็ว ๆ นี้',
    'debugLogsExported': 'ส่งออกบันทึกดีบักแล้ว',
    'findYourVideos': 'ค้นหาวิดีโอของคุณ',
    'scanningVideos': 'กำลังสแกนวิดีโอ…',
    'errorLoadingFoldersPrefix': 'โหลดโฟลเดอร์ไม่สำเร็จ',
    'errorLoadingVideosPrefix': 'โหลดวิดีโอไม่สำเร็จ',
    'loadingVideos': 'กำลังโหลดวิดีโอ…',
    'recentlyAdded': 'เพิ่มล่าสุด',
    'continueWatching': 'ดูต่อ',
    'noContinueWatching': 'ยังไม่มีวิดีโอให้ดูต่อ',
    'removeContinueTitle': 'นำออกจากรายการดูต่อ?',
    'recentSearches': 'การค้นหาล่าสุด',
    'eqDuringPlayback': 'อีควอไลเซอร์ใช้ได้ระหว่างเล่น',
    'magicPenHint': 'Magic Pen — ฟีเจอร์ AI จะมาในเวอร์ชันโปร',
    'featuresIntro': 'Innocent รองรับ:',
    'featuresBody': '• ถอดรหัสฮาร์ดแวร์ + ซอฟต์แวร์ (HW/HW+/SW)\n• เล่นต่อจากจุดที่หยุด\n• เล่นเบื้องหลัง + Picture-in-Picture\n• อีควอไลเซอร์ 10 แบนด์ + Bass Boost + Virtualizer + Reverb\n• ปรับแต่งซับไตเติล (ฟอนต์ ขนาด สี ขอบ เงา)\n• ค้นหาซับไตเติล + โหลดซับออฟไลน์\n• เจสเจอร์สัมผัส (ปัดเลื่อน/ความสว่าง/เสียง บีบซูม)\n• ตั้งเวลานอน + AB Repeat + วนซ้ำ\n• สลับแทร็กเสียง/ซับไตเติล\n• จำการตั้งค่าแยกตามวิดีโอ\n• คลังหลายโฟลเดอร์ + เล่นล่าสุด\n• รายการโปรด / ดูภายหลัง / เพลย์ลิสต์\n• เครื่องเล่นเพลงพร้อมสุ่ม / เรียง / โฟลเดอร์\n• UI รองรับแท็บเล็ต',
    'faqQ1': 'ถาม: ทำไมวิดีโอไม่เล่น?',
    'faqA1': 'ตอบ: ลองสลับตัวถอดรหัส (กดค้างที่เพลเยอร์ → Decoder → SW) บาง codec ต้องใช้ซอฟต์แวร์ถอดรหัส',
    'faqQ2': 'ถาม: โหลดซับไตเติลภายนอกอย่างไร?',
    'faqA2': 'ตอบ: วางไฟล์ .srt ในโฟลเดอร์เดียวกับวิดีโอ หรือกำหนดใน Settings → Subtitle → Subtitle Folder',
    'faqQ3': 'ถาม: เสียงไม่ตรงภาพ แก้อย่างไร?',
    'faqA3': 'ตอบ: Settings → Audio → Audio delay หรือกดค้างในเพลเยอร์ → Audio sync',
    'faqQ4': 'ถาม: ทำไมหน้าจอมืดหลังเล่นเสร็จ?',
    'faqA4': 'ตอบ: แก้แล้วใน build 56 — ความสว่างจะกลับคืนเมื่อปิดเพลเยอร์',
    'privacyBody': 'Innocent ทำงานออฟไลน์ทั้งหมด ไม่เก็บ telemetry หรือ analytics และไม่ส่งข้อมูลไปยังเซิร์ฟเวอร์ใด ๆ ประวัติ รายการโปรด และเพลย์ลิสต์ทั้งหมดอยู่ในเครื่องนี้เท่านั้น',
    'aboutBody': 'เครื่องเล่นสื่อสไตล์ MX Player สำหรับ Android สร้างด้วย Flutter และ media_kit',
    'addSubtitleFromUrl': 'เพิ่มซับไตเติลจาก URL',
    'subtitleUrlTip': 'เคล็ดลับ: ที่ OpenSubtitles.org ให้คัดลอกลิงก์ "Download" โดยตรง (ไม่ใช่ URL ของหน้า) ถ้าเป็น zip ให้แตกไฟล์ก่อน',
    'downloadingSubtitle': 'กำลังดาวน์โหลดซับไตเติล…',
    'downloadFailed': 'ดาวน์โหลดไม่สำเร็จ',
    'moveToBinTitle': 'ย้ายไปถังรีไซเคิล?',
    'deleteVideoTitle': 'ลบวิดีโอ?',
    'addToPlaylist': 'เพิ่มลงเพลย์ลิสต์',
    'noPlaylistsYet': 'ยังไม่มีเพลย์ลิสต์',
    'createNewPlaylist': 'สร้างเพลย์ลิสต์ใหม่',
    'newPlaylistTitle': 'เพลย์ลิสต์ใหม่',
    'playUsingHw': 'เล่นด้วยตัวถอดรหัส HW',
    'playUsingHwPlus': 'เล่นด้วยตัวถอดรหัส HW+',
    'playUsingSw': 'เล่นด้วยตัวถอดรหัส SW',
    'hideSelectedHint': 'ซ่อนรายการที่เลือกจากคลัง',
    'rebuildThumbnail': 'สร้างภาพย่อใหม่',
    'createdPlaylist': 'สร้างเพลย์ลิสต์ "{name}" แล้ว',
    'renamePlaylist': 'เปลี่ยนชื่อเพลย์ลิสต์',
    'playlistEmpty': 'เพลย์ลิสต์ว่างเปล่า',
    'deleteNameTitle': 'ลบ "{name}"?',
    'deletedName': 'ลบ "{name}" แล้ว',
    'noCustomPlaylists': 'ยังไม่มีเพลย์ลิสต์ที่สร้างเอง',
    'emptyBinTitle': 'ล้างถังรีไซเคิล?',
    'binEmpty': 'ถังรีไซเคิลว่างเปล่า',
    'permDeleteTitle': 'ลบถาวร?',
    'permDeleteBody': 'รายการนี้จะถูกลบออกจากถังรีไซเคิลอย่างถาวร',
    'restoredName': 'กู้คืนแล้ว: {name}',
    'removedName': 'นำออกแล้ว: {name}',
    'clearWatchLaterTitle': 'ล้างรายการดูภายหลัง?',
    'clearWatchLaterBody': 'นำวิดีโอทั้งหมดออกจากคิว?',
    'watchLaterEmpty': 'คิวดูภายหลังว่างเปล่า',
    'watchLaterHint': 'แตะ ⋮ บนวิดีโอ → "Add to Watch Later" เพื่อเพิ่มลงคิว',
    'noHistoryYet': 'ยังไม่มีประวัติการดู',
    'noFavouritesYet': 'ยังไม่มีวิดีโอโปรด\nแตะ ⋮ บนวิดีโอแล้วเลือก "Favourite"',
    'unfavouritedName': 'เอาออกจากโปรดแล้ว: {name}',
    'yourWatchInsights': 'ข้อมูลเชิงลึกการดูของคุณ',
    'noInsightsYet': 'ยังไม่มีข้อมูลเชิงลึก',
    'totalTimeWatched': 'เวลาดูรวม',
    'last7Days': '7 วันล่าสุด (นาที)',
    'mostRewatched': 'ดูซ้ำมากที่สุด',
    'mostWatchedFolder': 'โฟลเดอร์ที่ดูมากที่สุด',
    'averageCompletion': 'ค่าเฉลี่ยการดูจบ',
    'failedPickFiles': 'เลือกไฟล์ไม่สำเร็จ',
    'send': 'ส่ง',
    'receive': 'รับ',
    'howTransferWorksTitle': 'การส่งไฟล์ทำงานอย่างไร',
    'howTransferWorksBody': 'ส่งไฟล์ผ่านเครือข่าย Wi-Fi ไปยังอีกเครื่องในเครือข่ายเดียวกัน — ไม่ต้องใช้อินเทอร์เน็ต\n\n1. เชื่อมต่อทั้งสองเครื่องกับ Wi-Fi เดียวกัน\n2. ที่เครื่องนี้ เลือกไฟล์แล้วแตะ Start\n3. ที่อีกเครื่อง เปิดเบราว์เซอร์แล้ว:\n   - สแกน QR ด้วยกล้อง หรือ\n   - พิมพ์ URL ที่แสดงบนหน้าจอ\n4. อีกเครื่องจะเห็นรายการไฟล์ แตะไฟล์เพื่อดาวน์โหลด\n\nแตะ Stop ที่เครื่องนี้เพื่อจบการแชร์ — URL จะใช้ไม่ได้ทันที\n\nข้อจำกัด:\n- ไม่เข้ารหัส (เฉพาะ LAN) ใครก็ตามใน Wi-Fi ที่รู้ URL เต็มสามารถดาวน์โหลดได้\n- ใช้กับเน็ตมือถือไม่ได้ Wi-Fi เท่านั้น\n- ไม่ทำงานเบื้องหลัง ปิดแอปแล้วการแชร์จะจบ',
    'filesToShare': 'ไฟล์ที่จะแชร์',
    'addFiles': 'เพิ่มไฟล์',
    'noFilesHint': 'ยังไม่มีไฟล์\nแตะ "Add files" เพื่อเลือกไฟล์ที่จะแชร์',
    'shareIsLive': 'กำลังแชร์อยู่',
    'shareScanHint': 'ที่อีกเครื่อง สแกน QR หรือพิมพ์ URL ด้านล่างในเบราว์เซอร์',
    'urlCopied': 'คัดลอก URL แล้ว',
    'stopSharing': 'หยุดแชร์',
    'cameraPermissionNeeded': 'ต้องการสิทธิ์กล้องเพื่อสแกน QR',
    'scanQrCode': 'สแกน QR โค้ด',
    'orEnterAddress': 'หรือป้อนที่อยู่',
    'downloadAll': 'ดาวน์โหลดทั้งหมด',
    'nearbyDevices': 'อุปกรณ์ใกล้เคียง',
    'lookingForPhones': 'กำลังค้นหาโทรศัพท์ใกล้เคียง\u2026',
    'noPhonesFound': 'ยังไม่พบโทรศัพท์ ที่เครื่องอีกฝั่งให้เปิด File Transfer \u2192 Send แล้วเริ่มแชร์',
    'tapDeviceToConnect': 'แตะที่โทรศัพท์เพื่อเชื่อมต่อ',
    'connectingToDevice': 'กำลังเชื่อมต่อ\u2026',
    'thisPhoneName': 'เครื่องนี้',
    'renameThisPhone': 'เปลี่ยนชื่อเครื่องนี้',
    'askBeforeSending': 'ขออนุญาตก่อนส่ง',
    'askBeforeSendingHint': 'เครื่องอื่นต้องได้รับอนุมัติจากคุณก่อนจึงจะดาวน์โหลดได้ ปลอดภัยกว่าบน Wi-Fi สาธารณะ',
    'wantsToReceive': 'ต้องการรับไฟล์ของคุณ',
    'accept': 'ยอมรับ',
    'decline': 'ปฏิเสธ',
    'waitingForReceiver': 'กำลังรอเครื่องอีกฝั่ง\u2026',
    'overallProgress': 'รวมทั้งหมด',
    'alreadyOnThisPhone': 'มีอยู่ในเครื่องนี้แล้ว',
    'cancelTransfer': 'ยกเลิกการโอน',
    'hotspotTipBody': 'เปิดฮอตสปอตของเครื่องนี้แล้วให้อีกเครื่องเชื่อมต่อ (ไม่ต้องใช้อินเทอร์เน็ต) จากนั้นเริ่มแชร์ การผ่านเราเตอร์ทำให้ข้อมูลวิ่งผ่านอากาศสองครั้ง จึงช้ากว่าหลายเท่า',
    'directLinkActive': 'เชื่อมต่อโดยตรง \u2014 โหมดเร็วที่สุด',
    'viaRouterSlower': 'ผ่านเราเตอร์ Wi-Fi \u2014 ฮอตสปอตเร็วกว่า',
    'allFilesReceived': 'รับไฟล์ครบแล้ว',
    'turboTitle': 'Turbo \u2014 เชื่อมต่อโดยตรง',
    'turboSubtitle': 'เชื่อมสองเครื่องเข้าหากันโดยตรงแทนการผ่านเราเตอร์ ข้อมูลจึงวิ่งผ่านอากาศเพียงครั้งเดียว เร็วกว่ามากและไม่ต้องมีเครือข่าย Wi-Fi ระหว่างใช้งานเครื่องนี้จะไม่มีอินเทอร์เน็ต',
    'turboStarting': 'กำลังเริ่มการเชื่อมต่อโดยตรง\u2026',
    'turboBadge5': 'Turbo 5 GHz \u2014 เร็วที่สุด',
    'turboBadge24': 'Turbo เชื่อมต่อโดยตรง (2.4 GHz)',
    'turboUnavailable': 'เริ่ม Turbo ไม่ได้ \u2014 กำลังแชร์ผ่าน Wi-Fi ปกติแทน',
    'turboJoinManually': 'เครื่องที่ไม่มี Innocent? เชื่อม Wi-Fi นี้ด้วยตนเอง แล้วเปิดที่อยู่ด้านบนในเบราว์เซอร์',
    'turboWifiName': 'ชื่อ Wi-Fi',
    'turboWifiPassword': 'รหัสผ่าน',
    'turboJoining': 'กำลังเข้าร่วมลิงก์ของอีกเครื่อง\u2026',
    'turboConnected': 'เชื่อมต่อโดยตรงแล้ว',
    'turboLeave': 'ตัดการเชื่อมต่อโดยตรง',
    'turboNoInternet': 'ระหว่างเปิดการเชื่อมต่อโดยตรง เครื่องนี้จะไม่มีอินเทอร์เน็ต และจะกลับมาทันทีที่ตัดการเชื่อมต่อ',
    'turboReasonWifiOff': 'เปิด Wi-Fi ก่อน \u2014 การเชื่อมต่อโดยตรงใช้คลื่น Wi-Fi (ไม่ใช้เน็ตมือถือ)',
    'turboReasonLocationOff': 'Android เวอร์ชันนี้ต้องเปิดตำแหน่งเพื่อสร้างลิงก์ Wi-Fi โดยตรง Innocent ไม่เคยอ่านตำแหน่งของคุณ',
    'turboReasonPermission': 'ต้องได้รับอนุญาตเพื่อสร้างลิงก์ Wi-Fi โดยตรง',
    'turboReasonUnsupported': 'Android ของเครื่องนี้สร้างลิงก์โดยตรงไม่ได้ การแชร์ผ่าน Wi-Fi ปกติยังใช้ได้',
    'turboReasonGeneric': 'เริ่มการเชื่อมต่อโดยตรงบนเครื่องนี้ไม่ได้',
    'turboOpenWifiSettings': 'เปิดการตั้งค่า Wi-Fi',
    'turboOpenLocationSettings': 'เปิดการตั้งค่าตำแหน่ง',
    'sendInnocentApp': 'ส่งแอป Innocent',
    'sendInnocentAppHint': 'เพิ่มไฟล์ APK ของ Innocent เข้าไปในรายการแชร์ เครื่องที่ยังไม่มีจะติดตั้งจากคุณได้ โดยไม่ต้องใช้อินเทอร์เน็ต',
    'transferHistory': 'ไฟล์ที่ได้รับ',
    'clearHistory': 'ล้างรายการ',
    'fileMissing': 'ไม่พบไฟล์นั้นในเครื่องนี้แล้ว',
    'receivedFromDevice': 'จาก',
    'turboBandUnknown': 'Turbo เชื่อมต่อโดยตรง',
    'turboSccExplain': 'ลิงก์นี้อยู่บน 2.4 GHz เพราะเครื่องเชื่อมต่อ Wi-Fi อยู่ โทรศัพท์ส่วนใหญ่ใช้ลิงก์โดยตรงได้เฉพาะบนช่องสัญญาณเดียวกับ Wi-Fi ให้ตัดการเชื่อมต่อ Wi-Fi (แต่เปิด Wi-Fi ไว้) แล้วเริ่มใหม่เพื่อให้ได้ 5 GHz ซึ่งเร็วกว่าหลายเท่า',
    'turboSccTip': 'เคล็ดลับ: เพื่อความเร็วสูงสุด ให้ตัดการเชื่อมต่อ Wi-Fi ของเครื่องนี้ก่อน \u2014 แต่เปิด Wi-Fi ไว้ Turbo ต้องการคลื่น ไม่ใช่เครือข่าย',
    'turboReasonDeclined': 'ไม่พบลิงก์ของอีกเครื่อง หรือการเชื่อมต่อถูกปฏิเสธ ตรวจสอบว่าอีกเครื่องยังแชร์อยู่และอยู่ใกล้กัน',
    'turboReasonNoAddress': 'ลิงก์โดยตรงเริ่มทำงานแต่เครื่องนี้ไม่ได้รับที่อยู่ กำลังแชร์ผ่าน Wi-Fi ปกติแทน',
    'turboOpenAppSettings': 'เปิดการตั้งค่าแอป',
    'sendFolder': 'ส่งโฟลเดอร์',
    'sendThisFolder': 'ส่ง',
    'scanningFolder': 'กำลังอ่านโฟลเดอร์\u2026',
    'noSubfolders': 'ไม่มีโฟลเดอร์ในนี้ แต่คุณยังส่งโฟลเดอร์นี้ได้',
    'folderUnreadable': 'อ่านโฟลเดอร์นี้ไม่ได้ ลองโฟลเดอร์อื่น',
    'folderEmpty': 'โฟลเดอร์นั้นไม่มีไฟล์ให้ส่ง',
    'folderTooManyFiles': 'เพิ่มเฉพาะ 3000 ไฟล์แรก \u2014 โฟลเดอร์นี้ใหญ่มาก',
    'folderAdded': 'เพิ่มโฟลเดอร์แล้ว \u2014 โครงสร้างจะคงอยู่บนเครื่องอีกฝั่ง',
    'pauseShare': 'หยุดชั่วคราว',
    'resumeShare': 'ดำเนินต่อ',
    'sharePaused': 'หยุดชั่วคราว \u2014 ผู้รับกำลังรอ ไฟล์ที่ดาวน์โหลดแล้วไม่สูญหาย',
    'pauseReceive': 'หยุดชั่วคราว',
    'resumeReceive': 'ดำเนินต่อ',
    'receivePaused': 'หยุดชั่วคราว แตะดำเนินต่อเพื่อไปต่อจากจุดที่หยุด',
    'pausedBySender': 'เครื่องอีกฝั่งหยุดการโอนชั่วคราว\u2026',
    'protectWithPin': 'ขอรหัส PIN',
    'protectWithPinHint': 'แสดงรหัส 4 หลักที่นี่ ซึ่งเครื่องอีกฝั่งต้องกรอก ควรใช้บน Wi-Fi สาธารณะที่ใครก็เห็นเครื่องนี้ในรายการได้',
    'enterSharePin': 'กรอกรหัส PIN 4 หลักที่แสดงบนเครื่องอีกฝั่ง',
    'wrongPin': 'รหัส PIN ไม่ตรงกัน ตรวจสอบหน้าจอเครื่องอีกฝั่ง',
    'receiversLabel': 'กำลังรับ',
    'encryptionNote': 'บน Turbo ลิงก์เข้ารหัส WPA2 อยู่แล้ว ไฟล์จึงปลอดภัยระหว่างส่ง แต่ผ่าน Wi-Fi ปกติการโอนไม่ได้เข้ารหัส \u2014 ให้ใช้ PIN หรือ Turbo บนเครือข่ายที่ไม่น่าเชื่อถือ',
    'connectAction': 'เชื่อมต่อ',
    'dismiss': 'ปิด',
    'addMoreFiles': 'เพิ่มไฟล์',
    'cannotOpenFile': 'ไม่มีแอปในเครื่องนี้ที่เปิดไฟล์นั้นได้',
    'allowInstallTitle': 'อนุญาตให้ติดตั้งแอป',
    'allowInstallBody': 'Android ต้องได้รับอนุญาตก่อนที่ Innocent จะส่ง APK ให้ตัวติดตั้ง ทำเพียงครั้งเดียว',
    'allowInstallAction': 'เปิดการตั้งค่า',
    'webUploadHint': 'เครื่องที่มีแค่เบราว์เซอร์เปิดที่อยู่นี้แล้วส่งไฟล์กลับมาหาคุณได้ \u2014 ไม่ต้องติดตั้งอะไรฝั่งนั้น',
    'filesAddedLive': 'เพิ่มเข้าการแชร์แล้ว \u2014 อีกเครื่องรีเฟรชเพื่อดูได้',
    'savedToPath': 'บันทึกที่: {path}',
    'scanSenderQr': 'สแกน QR ของผู้ส่ง',
    'scanQrHint': 'เล็งกล้องไปที่ QR บนเครื่องผู้ส่ง',
    'playbackSpeed': 'ความเร็วการเล่น',
    'sleepTimer': 'ตั้งเวลานอน',
    'stopsIn': 'จะหยุดใน {t}',
    'sleepTimerSetMin': 'ตั้งเวลานอนแล้ว: {n} นาที',
    'sleepTimerOff': 'ปิดตั้งเวลานอนแล้ว',
    'shareFailed': 'แชร์ไม่สำเร็จ',
    'shareTrack': 'แชร์เพลง',
    'lyrics': 'เนื้อเพลง',
    'playingQueueTitle': 'คิวการเล่น',
    'queueEmpty': 'คิวการเล่นว่างเปล่า',
    'playbackError': 'เล่นผิดพลาด',
    'noSongsFound': 'ไม่พบเพลงในเครื่อง',
    'errorReadingMusic': 'อ่านเพลงไม่สำเร็จ',
    'searchPlaylists': 'ค้นหาเพลย์ลิสต์...',
    'searchAlbums': 'ค้นหาอัลบั้ม...',
    'searchArtists': 'ค้นหาศิลปิน...',
    'searchFolders': 'ค้นหาโฟลเดอร์...',
    'sortBy': 'เรียงตาม',
    'noSongsBy': 'ไม่มีเพลงของ {name}',
    'noSongsIn': 'ไม่มีเพลงใน {name}',
    'errorLoadingSongs': 'โหลดเพลงไม่สำเร็จ',
    'errorLoadingAlbum': 'โหลดอัลบั้มไม่สำเร็จ',
    'errorLoadingPlaylist': 'โหลดเพลย์ลิสต์ไม่สำเร็จ',
    'playAllCount': 'เล่นทั้งหมด  ({n})',
    'sharingName': 'กำลังแชร์ "{name}"',
    'playingName': 'กำลังเล่น "{name}"',
    'shufflingName': 'กำลังสุ่มเล่น "{name}"',
    'propertiesForName': 'คุณสมบัติของ "{name}"',
    'changePin': 'เปลี่ยน PIN',
    'pinChanged': 'เปลี่ยน PIN แล้ว',
    'restoredToLibrary': 'กู้คืนสู่คลังแล้ว',
    'restoreFailed': 'กู้คืนไม่สำเร็จ',
    'privateIntro': 'วิดีโอที่ล็อกจะถูกย้ายไปยังพื้นที่ส่วนตัวของแอป — ไม่แสดงในแกลเลอรีหรือตัวจัดการไฟล์อื่น ไฟล์ที่ระบบไม่ให้ย้ายจะถูกซ่อนจากคลังเท่านั้น ไฟล์ถูกย้าย ไม่ได้เข้ารหัส',
    'setupPinTitle': 'ตั้งค่า PIN โฟลเดอร์ส่วนตัว',
    'setupPinHint': 'วิดีโอที่ล็อกไว้ที่นี่จะไม่แสดงในคลังของคุณ',
    'useBiometric': 'ใช้ไบโอเมตริก',
    'setPin': 'ตั้ง PIN',
    'enterPin': 'ป้อน PIN',
    'restoreBackupTitle': 'กู้คืนข้อมูลสำรอง?',
    'clearLibraryCacheTitle': 'ล้างแคชคลัง?',
    'addNewServer': 'เพิ่มเซิร์ฟเวอร์ใหม่',
    'networks': 'เครือข่าย',
    'supportedProtocols': 'โปรโตคอลที่รองรับ',
    'howToUse': 'ใช้อย่างไร?',
    'meSettingsHint': 'ธีม ป๊อปอัป ภาษา',
    'meBackupHint': 'รายการของคุณ และคลาวด์ไดรฟ์',
    'meHelpHint': 'คำถาม และการติดต่อเรา',
    'meAboutHint': 'เวอร์ชัน อัปเดต ใบอนุญาต',
    'meLibrary': 'คลังของคุณ',
    'meInsights': 'สถิติ',
    'meLibraryStats': 'สถิติคลัง',
    'bkInfo': 'สำรองรายการโปรด เพลย์ลิสต์ บุ๊กมาร์ก และประวัติ แล้วกู้คืนบนโทรศัพท์เครื่องใดก็ได้',
    'bkSectionBackup': 'สำรองข้อมูล',
    'bkExport': 'ส่งออกข้อมูลสำรองเป็นไฟล์',
    'bkExportSub': 'รายการโปรด เพลย์ลิสต์ บุ๊กมาร์ก และประวัติเป็นไฟล์ JSON',
    'bkSectionRestore': 'กู้คืน',
    'bkRestoreFile': 'กู้คืนจากไฟล์',
    'bkRestoreFileSub': 'นำไฟล์สำรองที่สร้างโดย Innocent กลับมา',
    'bkSectionCloud': 'คลาวด์',
    'bkCloudSub': 'Google Drive, OneDrive, Dropbox และอื่นๆ — สำรองและสตรีมจากคลาวด์',
    'bkSectionCache': 'แคช',
    'bkClearCache': 'ล้างแคชไลบรารี',
    'bkClearCacheSub': 'สแกนวิดีโอใหม่เมื่อเปิดแอปครั้งถัดไป',
    'bkWhat': 'สิ่งที่สำรองไว้',
    'bkItemSettings': 'การตั้งค่าแอป',
    'bkItemPlaylists': 'เพลย์ลิสต์วิดีโอ',
    'bkItemFavourites': 'รายการโปรด',
    'bkItemHistory': 'ประวัติการดู',
    'bkItemLater': 'รายการดูภายหลัง',
    'bkItemBookmarks': 'บุ๊กมาร์ก',
    'bkRestoreWarn': 'การดำเนินการนี้จะแทนที่รายการโปรด เพลย์ลิสต์ บุ๊กมาร์ก ประวัติ และถังขยะปัจจุบันด้วยข้อมูลในไฟล์สำรอง',
    'bkClearWarn': 'เมื่อเปิดแอปครั้งถัดไปจะสแกนวิดีโอทั้งหมดใหม่ ปลอดภัย แค่ช้ากว่าปกติครั้งเดียว',
    'bkExported': 'บันทึกที่ {path} — คัดลอกตำแหน่งแล้ว',
    'bkFailed': 'เกิดข้อผิดพลาด: {e}',
    'bkNoFile': 'ไม่ได้เลือกไฟล์',
    'bkRestored': 'กู้คืนแล้ว: รายการโปรด {f} เพลย์ลิสต์ {p} บุ๊กมาร์ก {b} ประวัติ {h}',
    'bkCacheCleared': 'ล้างแคชแล้ว เปิดแอปใหม่เพื่อสแกนอีกครั้ง',
    'netHowStep1': 'เพิ่มเซิร์ฟเวอร์โดยแตะปุ่ม {+}',
    'netHowStep2': 'เข้าถึงไฟล์ระยะไกลทั้งหมดได้โดยตรงจากอุปกรณ์ของคุณ',
    'netHowStep3': 'ใช้ Wi-Fi เดียวกับคอมพิวเตอร์หรือ NAS — กด Scan เพื่อค้นหา',
    'netGotIt': 'เข้าใจแล้ว',
    'netNewServer': 'เซิร์ฟเวอร์ {p} ใหม่',
    'netEditServer': 'แก้ไขเซิร์ฟเวอร์ {p}',
    'netScan': 'สแกน',
    'netServer': 'เซิร์ฟเวอร์',
    'netServerIp': 'IP เซิร์ฟเวอร์',
    'netServerName': 'ชื่อเซิร์ฟเวอร์',
    'netServerNameHint': 'ชื่อเซิร์ฟเวอร์ของฉัน (ไม่บังคับ)',
    'netSharedPath': 'พาธที่แชร์',
    'netSharedPathHint': 'พาธที่แชร์ (ไม่บังคับ)',
    'netFolder': 'โฟลเดอร์',
    'netFolderHint': 'โฟลเดอร์เริ่มต้น (ไม่บังคับ)',
    'netPort': 'พอร์ต',
    'netUsername': 'ชื่อผู้ใช้',
    'netPassword': 'รหัสผ่าน',
    'netAnonymous': 'เชื่อมต่อแบบไม่ระบุตัวตน',
    'netMode': 'โหมด',
    'netActive': 'Active',
    'netPassive': 'Passive',
    'netEncoding': 'การเข้ารหัส',
    'netSecurityMode': 'โหมดความปลอดภัย',
    'netImplicit': 'Implicit',
    'netExplicit': 'Explicit',
    'netUseKey': 'เข้าสู่ระบบด้วย Private Key',
    'netPrivateKey': 'Private Key',
    'netPrivateKeyHint': 'วางคีย์ (-----BEGIN …)',
    'netChooseKeyFile': 'เลือกไฟล์คีย์',
    'netPassphrase': 'Passphrase',
    'netPassphraseHint': 'Passphrase (ไม่บังคับ)',
    'netConnect': 'เชื่อมต่อ',
    'netSave': 'บันทึก',
    'netConnecting': 'กำลังเชื่อมต่อ…',
    'netErrUnreachable': 'เข้าถึง {host} ไม่ได้ เปิดเครื่องอยู่และใช้ Wi-Fi เดียวกับโทรศัพท์นี้หรือไม่?',
    'netErrTimeout': 'เซิร์ฟเวอร์ตอบช้าเกินไป ลองอีกครั้ง',
    'netErrAuth': 'ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง',
    'netErrAuthAnon': 'เซิร์ฟเวอร์นี้ไม่อนุญาตการเข้าถึงแบบไม่ระบุตัวตน เอาเครื่องหมายออกแล้วลงชื่อเข้าใช้',
    'netErrDenied': 'บัญชีนี้ไม่มีสิทธิ์เปิดโฟลเดอร์นั้น',
    'netErrNotFound': 'ไม่มีแชร์หรือโฟลเดอร์นั้นบนเซิร์ฟเวอร์',
    'netErrTls': 'การเชื่อมต่อที่ปลอดภัยล้มเหลว ตรวจสอบพอร์ตและโหมดความปลอดภัย',
    'netErrKey': 'อ่าน Private key ไม่ได้ ตรวจสอบคีย์และ passphrase',
    'netErrProtocol': 'เซิร์ฟเวอร์ตอบกลับ แต่ไม่ใช่ {p} ตรวจสอบโปรโตคอลและพอร์ต',
    'netErrHostKey': 'ข้อมูลระบุตัวตนของเซิร์ฟเวอร์นี้เปลี่ยนไปตั้งแต่การเชื่อมต่อครั้งล่าสุด',
    'netErrHostKeyBody': 'หากคุณติดตั้งใหม่หรือเปลี่ยนเซิร์ฟเวอร์ ให้เชื่อถือข้อมูลใหม่ หากไม่ใช่ อาจมีผู้ปลอมตัวบนเครือข่ายนี้',
    'netTrustNew': 'เชื่อถือข้อมูลใหม่',
    'netErrNeedHost': 'ใส่ที่อยู่เซิร์ฟเวอร์',
    'netErrBadPort': 'พอร์ตต้องอยู่ระหว่าง 1 ถึง 65535',
    'netErrNeedKey': 'วางหรือเลือก Private key',
    'netErrUnsupported': 'อุปกรณ์นี้ใช้ Local Network ไม่ได้',
    'netScanTitle': 'เซิร์ฟเวอร์บน Wi-Fi นี้',
    'netScanning': 'กำลังค้นหาเซิร์ฟเวอร์ {p} บน {subnet}…',
    'netScanNone': 'ไม่พบเซิร์ฟเวอร์ {p} บน Wi-Fi นี้',
    'netScanNoneHint': 'เปิดการแชร์ไฟล์บนคอมพิวเตอร์ หรือพิมพ์ที่อยู่เอง',
    'netScanAgain': 'สแกนอีกครั้ง',
    'netScanNoWifi': 'เชื่อมต่อ Wi-Fi เพื่อสแกน',
    'netMyServers': 'เซิร์ฟเวอร์',
    'netEdit': 'แก้ไข',
    'netDelete': 'ลบ',
    'netDeleteConfirm': 'ลบ "{name}" หรือไม่?',
    'netDeleteBody': 'รหัสผ่านที่บันทึกไว้จะถูกลบออกจากโทรศัพท์นี้ด้วย',
    'netEmptyFolder': 'โฟลเดอร์นี้ว่างเปล่า',
    'netRetry': 'ลองอีกครั้ง',
    'netSortName': 'ชื่อ',
    'netSortDate': 'วันที่',
    'netSortSize': 'ขนาด',
    'netMediaOnly': 'เฉพาะสื่อ',
    'netNotPlayable': 'ไม่สามารถเล่นไฟล์นี้ได้',
    'netItems': '{n} รายการ',
    'netAnonymousTag': 'ไม่ระบุตัวตน',
    'netShares': 'แชร์',
    'netShowPassword': 'แสดงรหัสผ่าน',
    'aboutCloudDrive': 'เกี่ยวกับ Cloud Drive',
    'cloudDriveBody': 'สตรีมวิดีโอและเพลงจากบัญชีคลาวด์โดยตรงไม่ต้องดาวน์โหลด เชื่อมต่อผู้ให้บริการด้านล่างเพื่อดูไฟล์ใน Innocent',
    'connectCloudCaps': 'เชื่อมต่อคลาวด์ของคุณ',
    'deviceStorage': 'พื้นที่จัดเก็บอุปกรณ์',
    'cleanUpSpace': 'ล้างเพื่อเพิ่มพื้นที่',
    'scanningCleanable': 'กำลังสแกนไฟล์ที่ล้างได้...',
    'openingRecentlyPlayed': 'กำลังเปิดเล่นล่าสุด',
    'mmUsedOf': 'ใช้ไป {used} จาก {total}',
    'mmFree': 'ว่าง {free}',
    'mmVideos': 'วิดีโอ',
    'mmMusic': 'เพลง',
    'mmNoAccess': 'ไม่มีสิทธิ์',
    'mmStorageUnknown': 'ไม่ทราบขนาดพื้นที่',
    'mmRecentlyPlayed': 'เล่นล่าสุด',
    'mmLargeFiles': 'ไฟล์ขนาดใหญ่',
    'mmLargestVideos': 'วิดีโอที่ใหญ่ที่สุด',
    'mmHaventPlayed': 'ยังไม่ได้เล่น',
    'mmAllPlayed': 'คุณเล่นวิดีโอทั้งหมดในเครื่องนี้แล้ว',
    'scNightMode': 'โหมดกลางคืน',
    'scShuffle': 'สุ่ม',
    'scMute': 'ปิดเสียง',
    'scAbRepeat': 'เล่นซ้ำ A-B',
    'scMirrorMode': 'โหมดกระจก',
    'scVerticalFlip': 'พลิกแนวตั้ง',
    'scAudioEffect': 'เอฟเฟกต์เสียง',
    'scEqualizer': 'อีควอไลเซอร์',
    'scSpeed': 'ความเร็ว',
    'scScreenshot': 'ภาพหน้าจอ',
    'scBackgroundPlay': 'เล่นเบื้องหลัง',
    'scScreenRotation': 'หมุนหน้าจอ',
    'scLoop': 'วนซ้ำ',
    'scCustomiseItems': 'ปรับแต่งรายการ',
    'scVideoDisplay': 'การแสดงวิดีโอ',
    'scSleepTimer': 'ตั้งเวลาปิด',
    'gtSection': 'ท่าทางสัมผัส',
    'gtBrightness': 'ปัดเพื่อปรับความสว่าง',
    'gtBrightnessSub': 'ปัดขึ้นหรือลงที่ครึ่งซ้าย',
    'gtVolume': 'ปัดเพื่อปรับเสียง',
    'gtVolumeSub': 'ปัดขึ้นหรือลงที่ครึ่งขวา เมื่อเปิดเพิ่มเสียง ปัดต่อเกิน 100% ได้ถึง 200%',
    'gtSeek': 'ปัดเพื่อเลื่อน',
    'gtSeekSub': 'ปัดซ้ายหรือขวา วิดีโอเลื่อนตามนิ้ว',
    'gtDoubleTap': 'แตะสองครั้งเพื่อข้าม',
    'gtDoubleTapSub': 'แตะสองครั้งที่ด้านซ้ายหรือขวา แตะต่อเพื่อข้ามเพิ่ม (10, 20, 30 วินาที…) แตะสองครั้งตรงกลางเพื่อเล่นหรือหยุด',
    'gtLongPress': 'กดค้างเพื่อปรับความเร็ว',
    'gtLongPressSub': 'กดค้างแล้วเลื่อนซ้ายหรือขวาโดยไม่ยกนิ้ว',
    'gtPinch': 'บีบเพื่อซูม',
    'gtPinchSub': 'กางหรือบีบสองนิ้ว',
    'gtPan': 'เลื่อนภาพขณะซูม',
    'gtPanSub': 'ขณะซูม ลากด้วยสองนิ้วเพื่อเลื่อนภาพ',
    'gtSpeed': 'สองนิ้วเพื่อปรับความเร็ว',
    'gtSpeedSub': 'ปัดขึ้นหรือลงด้วยสองนิ้ว (0.25x – 4x)',
    'gtSubtitle': 'ท่าทางคำบรรยาย',
    'gtSubtitleSub': 'บนคำบรรยาย: ลากขึ้นลงเพื่อย้าย ปัดซ้ายขวาเพื่อไปบรรทัดก่อนหน้าหรือถัดไป บีบเพื่อปรับขนาด',
    'zmFit': 'พอดีหน้าจอ',
    'zmStretch': 'ยืด',
    'zmCrop': 'ครอบตัด',
    'zmOriginal': '100%',
    'zmCustom': 'กำหนดเอง',
    'zmCustomHint': 'บีบเพื่อซูม ใช้สองนิ้วเพื่อเลื่อน',
    'gtTap': 'แตะเพื่อแสดงหรือซ่อนปุ่ม',
    'gtTapSub': 'แตะหน้าจอหนึ่งครั้ง',
    'gtVolumeKey': 'ปุ่มปรับเสียง',
    'gtVolumeKeySub': 'เพิ่มหรือลดเสียง',
    'gtHeadset': 'ปุ่มหูฟัง',
    'gtHeadsetSub': 'เล่นหรือหยุด',
    'storagePermissionNeeded': 'ต้องการสิทธิ์พื้นที่จัดเก็บ',
    'statusPermissionHint': 'อนุญาตการเข้าถึงสื่อเพื่ออ่านสถานะ WhatsApp',
    'openingPrivacyPolicy': 'กำลังเปิดนโยบายความเป็นส่วนตัว...',
    'openingTerms': 'กำลังเปิดข้อกำหนดการใช้งาน...',
    'personalPlayerApp': 'แอปเครื่องเล่นวิดีโอส่วนตัว',
    'storageManagement': 'จัดการพื้นที่จัดเก็บ',
    'storageUsage': 'การใช้พื้นที่',
    'classicThemes': 'ธีมคลาสสิก',
    'noInternetThemes': 'ไม่มีอินเทอร์เน็ต แตะเพื่อเชื่อมต่อรับธีมใหม่',
    'themeApplied': 'ใช้ธีมแล้ว',
    'openSourceLicenses': 'ใบอนุญาตโอเพนซอร์ส',
    'personalProject': 'โปรเจกต์ Flutter ส่วนตัวเพื่อการเรียนรู้',
    'personalVideoPlayer': 'เครื่องเล่นวิดีโอส่วนตัว',
    'slowBuffering': 'การเชื่อมต่อช้า — กำลังบัฟเฟอร์…',
    'openingVideo': 'กำลังเปิดวิดีโอ…',
    'videoTooHeavy': 'วิดีโอนี้หนักเกินไปสำหรับเครื่องนี้…',
    'streamCacheTitle': 'พื้นที่เก็บวิดีโอ',
    'streamCacheExplain':
        'วิดีโอที่คุณดูจะถูกเก็บไว้ในเครื่องนี้ การย้อนกลับและการดูซ้ำจึงไม่เสียเน็ต '
        'และใช้ได้แม้ไม่มีสัญญาณ เก็บเฉพาะส่วนที่ดูไปแล้วเท่านั้น '
        'เมื่อถึงขีดจำกัด รายการที่ไม่ได้เปิดนานที่สุดจะถูกลบก่อน',
    'streamCacheLimit': 'ขีดจำกัด',
    'streamCacheClear': 'ล้างวิดีโอที่เก็บไว้',
    'streamCacheClearPages': 'ล้างหน้าและภาพที่บันทึกไว้',
    'streamCacheClearPagesNote': 'แคตตาล็อกที่บันทึกไว้สำหรับดูออฟไลน์ และภาพโปสเตอร์ คืนพื้นที่ แต่ต้องเชื่อมต่อเพื่อโหลดใหม่',
    'streamCacheClearNote': 'คืนพื้นที่ทันที สิ่งที่ดูซ้ำจะต้องโหลดใหม่',
    'streamCacheKept': 'เก็บไว้',
    'streamCacheUnnamed': 'วิดีโอ',
    'streamCacheSubtitle': 'เก็บวิดีโอที่ดูแล้วไว้ในเครื่อง',
    'durationLabel': 'ระยะเวลา',
    'resumeTitle': 'เล่นต่อ',
    'resumeBody': 'ต้องการเล่นต่อจากจุดที่หยุดไหม?',
    'savedAt': 'บันทึกไว้ที่ {t}',
    'useByDefault': 'ใช้เป็นค่าเริ่มต้น',
    'startOver': 'เริ่มใหม่',
    'continueFromStopped': 'เล่นต่อจากจุดที่หยุด',
    'customSpeedTitle': 'ความเร็วกำหนดเอง',
    'speedRangeHint': 'ช่วง: 0.25x - 4.00x',
    'playLastToEnd': 'เล่นไฟล์สุดท้ายจนจบ',
    'setStartFirst': 'ตั้งจุดเริ่มต้นก่อน',
    'endAfterStart': 'จุดจบต้องอยู่หลังจุดเริ่ม',
    'setBothPoints': 'ตั้งทั้งจุดเริ่มและจุดจบก่อน',
    'markClipHint': 'กำหนดคลิปโดยตั้งจุดเริ่ม (A) และจุดจบ (B)',
    'currentLabel': 'ปัจจุบัน',
    'clipLabel': 'คลิป',
    'displaySettingsTitle': 'การตั้งค่าการแสดงผล',
    'playerGestures': 'เจสเจอร์เพลเยอร์',
    'tapToDismiss': 'แตะที่ใดก็ได้เพื่อปิด',
    'skipIntroOutro': 'ข้ามอินโทร / เอาต์โทร',
    'clearAllMarkers': 'ล้างมาร์กเกอร์ทั้งหมด',
    'noTracksAvailable': 'ไม่มีแทร็ก',
    'loadExternalSubtitle': 'โหลดซับไตเติลภายนอก...',
    'onlineSubtitles': 'ซับไตเติลออนไลน์',
    'selectDecoder': 'เลือกตัวถอดรหัส',
    'bookmarksTitle': 'บุ๊กมาร์ก',
    'subtitleDelayTitle': 'หน่วงเวลาซับไตเติล',
    'shortcuts': 'ทางลัด',
    'unknownTab': 'แท็บไม่รู้จัก',
    'invalidUrl': 'URL ไม่ถูกต้อง',
    'streamUrl': 'URL สตรีม',
    'equalizerTitle': 'อีควอไลเซอร์',
    'eqNotAvailable': 'อีควอไลเซอร์ใช้ไม่ได้',
    'audioFxNotAvailable': 'อุปกรณ์นี้ใช้เอฟเฟกต์เสียงไม่ได้',
    'tapProfileHint': 'แตะโปรไฟล์เพื่อเปิดเอฟเฟกต์เสียง',
    'profilesFineTuneHint': 'โปรไฟล์ปรับแบนด์อีควอไลเซอร์ ปรับละเอียดได้ที่แท็บ Equalizer',
    'reverb': 'รีเวิร์บ',
    'kidsLock': 'ล็อก\nเด็ก',
    'kidsLockOnMsg': 'เปิด Kids Lock — ปิดการควบคุมทั้งหมด',
    'kidsLockHoldHint': 'กดค้างเพื่อปลดล็อก',
    'kidsLockOffMsg': 'ปิด Kids Lock แล้ว',
    'fullAccessBody': 'Android จะเปิดหน้าจอระบบชื่อ "All files access" เปิดสวิตช์ให้ Innocent แล้วกดย้อนกลับ ระบบจะสแกนโฟลเดอร์นอก Movies/DCIM/Downloads ได้ ยกเลิกได้ทุกเมื่อจากหน้าจอเดิม',
    'resetSettingsBodyFull': 'การตั้งค่าเพลเยอร์ เสียง ซับไตเติล และทั่วไปจะกลับเป็นค่าเริ่มต้น ประวัติและเพลย์ลิสต์ไม่ได้รับผลกระทบ',
    'popupPlayControls': 'การควบคุม Pop-up Play กำหนดเอง',
    'storageRoot': 'ที่เก็บข้อมูล',
    'noFolders': 'ไม่มีโฟลเดอร์',
    'couldNotLoadFiles': 'โหลดไฟล์ไม่สำเร็จ',
    'couldNotLoadFolders': 'โหลดโฟลเดอร์ไม่สำเร็จ',
    'noVideosInFolder': 'ไม่มีวิดีโอในโฟลเดอร์นี้',
    'abPointASet': 'ตั้งจุด A แล้ว — แตะอีกครั้งเพื่อตั้ง B',
    'abRepeatOn': 'เปิดเล่นซ้ำ A-B แล้ว',
    'abRepeatOff': 'ปิดเล่นซ้ำ A-B แล้ว',
    'addedToFavourites': 'เพิ่มในรายการโปรดแล้ว',
    'removedFromFavourites': 'นำออกจากรายการโปรดแล้ว',
    'catVideos': 'วิดีโอ',
    'catImages': 'รูปภาพ',
    'catAudio': 'เสียง',
    'catFiles': 'ไฟล์',
    'catApps': 'แอป',
    'itemsCount': '{n} รายการ',
    'filesCount': '{n} ไฟล์',
    'appsCount': '{n} แอป',
    'noItemsHere': 'ไม่มีอะไรที่นี่',
    'loadingApps': 'กำลังอ่านแอปที่ติดตั้ง…',
    'appsUnavailable': 'อ่านรายชื่อแอปในเครื่องนี้ไม่ได้',
    'shareFile': 'แชร์',
    'unlockToLibrary': 'ปลดล็อก',
    'addedToTransfer': 'เพิ่มลงการส่งไฟล์แล้ว',
    'selectFilesToAdd': 'เลือกไฟล์ที่จะเพิ่ม',
    'selectFilesToSend': 'เลือกไฟล์ที่จะส่ง',
    'newPin': 'PIN ใหม่',
    'confirmPin': 'ยืนยัน PIN',
    'pinLabel': 'PIN',
    'currentPin': 'PIN ปัจจุบัน',
    'confirmNewPin': 'ยืนยัน PIN ใหม่',
    'pinMin4': 'PIN ต้องมีอย่างน้อย 4 หลัก',
    'pinsDontMatch': 'PIN ไม่ตรงกัน',
    'newPinMin4': 'PIN ใหม่ต้องมีอย่างน้อย 4 หลัก',
    'newPinsDontMatch': 'PIN ใหม่ไม่ตรงกัน',
    'currentPinIncorrect': 'PIN ปัจจุบันไม่ถูกต้อง',
    'incorrectPin': 'PIN ไม่ถูกต้อง',
    'tooManyAttemptsWait': 'พยายามหลายครั้งเกินไป — รอ {s} วินาที',
    'biometricNotEnrolled': 'ยังไม่ได้ลงทะเบียนไบโอเมตริกในเครื่องนี้',
    'biometricEnrollFirst': 'ยังไม่ได้ลงทะเบียนไบโอเมตริก — ตั้งค่าใน Android Settings ก่อน',
    'unlockPrivateReason': 'ปลดล็อกโฟลเดอร์ส่วนตัว',
    'unlockHint': 'ป้อน PIN เพื่อดำเนินการต่อ',
    'biometricSubtitle': 'ข้าม PIN ด้วยลายนิ้วมือหรือใบหน้า PIN ยังใช้สำรองได้',
    'mediaPermissionNeeded': 'อนุญาตให้เข้าถึงสื่อของคุณ',
    'mediaPermissionHint': 'Innocent ต้องการสิทธิ์เพื่อแสดงรูปภาพและเสียงของคุณที่นี่',
    'grantAccess': 'ให้สิทธิ์',
    'layoutSection': 'เลย์เอาต์',
    'layoutList': 'รายการ',
    'layoutGrid': 'ตาราง',
    'allFilesAccessNeeded': 'อนุญาตให้เข้าถึงไฟล์ทั้งหมด',
    'allFilesAccessHint': 'หากต้องการเรียกดูไฟล์ที่นี่ Innocent ต้องการ "All files access" คุณจะเปิดสวิตช์ในการตั้งค่า Android แล้วกดย้อนกลับ',
    'noFilesInFolder': 'ไม่มีไฟล์ในโฟลเดอร์นี้',
    'allFiles': 'ไฟล์ทั้งหมด',
    'newFolder': 'โฟลเดอร์ใหม่',
    'createFolderTitle': 'สร้างโฟลเดอร์',
    'folderName': 'ชื่อโฟลเดอร์',
    'renameFolderTitle': 'เปลี่ยนชื่อโฟลเดอร์',
    'deleteFolderTitle': 'ลบโฟลเดอร์?',
    'deleteFolderBody': 'รายการข้างในจะย้ายกลับไปที่โฟลเดอร์ส่วนตัวหลัก — ไม่มีการลบ',
    'moveToFolder': 'ย้ายไปโฟลเดอร์',
    'moveHere': 'ย้ายมาที่นี่',
    'mainFolder': 'โฟลเดอร์ส่วนตัว',
    'chooseFolder': 'เลือกโฟลเดอร์',
    'addToExisting': 'เพิ่มลงโฟลเดอร์ที่มีอยู่',
    'verifyToLock': 'ยืนยันเพื่อล็อก',
    'searchFilesHint': 'ค้นหาไฟล์…',
    'emptyFolder': 'โฟลเดอร์นี้ว่างเปล่า',
    'foldersHeader': 'โฟลเดอร์',
    'catAll': 'ทั้งหมด',
    'chooseFolderTitle': 'เพิ่มลงโฟลเดอร์ใด?',
    'mainFolderRoot': 'โฟลเดอร์หลัก',
    'newFolderEllipsis': 'โฟลเดอร์ใหม่…',
    'lockCancelled': 'ยกเลิกการล็อกแล้ว',
    'foldersTitle': 'โฟลเดอร์',
    'refreshingVault': 'กำลังรีเฟรช…',
    'moreOptions': 'เพิ่มเติม',
    'resumeVault': 'ดูต่อ',
    'nothingToResume': 'ยังไม่มีอะไรให้ดูต่อ',
    'viewModeFolders': 'มุมมอง: โฟลเดอร์',
    'viewModeFiles': 'มุมมอง: ไฟล์',
    'deletePermanently': 'ลบถาวร',
    'deletePermanentlyTitle': 'ลบถาวรหรือไม่?',
    'deletePermanentlyBody': 'ไฟล์นี้จะถูกลบออกจากตู้เซฟถาวรและกู้คืนไม่ได้',
    'fileDeleted': 'ลบไฟล์แล้ว',
    'selectedCount': 'เลือกแล้ว {n}',
    'selectAll': 'เลือกทั้งหมด',
    'moveSelected': 'ย้าย',
    'unlockSelected': 'ปลดล็อก',
    'deleteSelected': 'ลบ',
    'deleteSelectedTitle': 'ลบ {n} ไฟล์?',
    'deleteSelectedBody': 'ไฟล์เหล่านี้จะถูกลบถาวรและกู้คืนไม่ได้',
    'itemsUnlocked': 'ปลดล็อก {n} ไฟล์แล้ว',
    'itemsMovedFolder': 'ย้าย {n} ไฟล์แล้ว',
    'renameEntry': 'เปลี่ยนชื่อ',
    'renameEntryTitle': 'เปลี่ยนชื่อไฟล์',
    'entryNameHint': 'ชื่อไฟล์',
    'vaultStorageUsed': '{size} ในตู้เซฟ',
    'viewModeLabel': 'มุมมอง',
    'sortAndView': 'จัดเรียงและมุมมอง',
    'deleteFolderChoiceBody': 'โฟลเดอร์นี้มีไฟล์ที่ล็อกไว้ {n} ไฟล์ คุณต้องการทำอะไร?',
    'deleteFolderWithItemsTitle': 'ลบโฟลเดอร์ที่มี {n} รายการ?',
    'unlockAndDeleteFolder': 'เก็บไฟล์ ลบโฟลเดอร์',
    'unlockAndDeleteFolderSub': 'ไฟล์ย้ายกลับตู้เซฟหลัก',
    'deleteFolderAndFiles': 'ลบโฟลเดอร์และไฟล์',
    'deleteFolderAndFilesSub': 'ทุกอย่างข้างในถูกลบถาวร',
    'folderDeleted': 'ลบโฟลเดอร์แล้ว',
    'vaultFileMissing': 'ไม่พบไฟล์ — อาจถูกลบไปแล้ว',
    'someFilesFailed': 'เพิ่มไฟล์ไม่ได้ {n} ไฟล์',
    'filesAddedOk': 'เพิ่มไฟล์แล้ว {n} ไฟล์',
    'forgotPin': 'ลืม PIN?',
    'recoverVault': 'กู้คืนการเข้าถึงตู้เซฟ',
    'chooseRecoveryMethod': 'คุณต้องการกู้คืนอย่างไร?',
    'recoveryNotSetup': 'ยังไม่ได้ตั้งค่าการกู้คืน กู้ PIN ไม่ได้',
    'securityQuestion': 'คำถามความปลอดภัย',
    'securityAnswer': 'คำตอบของคุณ',
    'setSecurityQuestion': 'ตั้งคำถามความปลอดภัย',
    'chooseAQuestion': 'เลือกคำถาม',
    'wrongAnswer': 'คำตอบไม่ตรงกัน',
    'answerRequired': 'กรุณาใส่คำตอบ',
    'recoveryKey': 'คีย์กู้คืน',
    'recoveryKeyGenerated': 'บันทึกคีย์กู้คืนนี้',
    'recoveryKeyWarning': 'แสดงเพียงครั้งเดียว จดไว้และเก็บให้ปลอดภัย',
    'enterRecoveryKey': 'ใส่คีย์กู้คืน',
    'wrongRecoveryKey': 'คีย์กู้คืนไม่ถูกต้อง',
    'copiedToClipboard': 'คัดลอกแล้ว',
    'iSavedIt': 'บันทึกแล้ว',
    'setNewPin': 'ตั้ง PIN ใหม่',
    'pinResetSuccess': 'รีเซ็ต PIN แล้ว',
    'setUpRecovery': 'ตั้งค่าการกู้คืน',
    'recoveryOptions': 'ตัวเลือกการกู้คืน',
    'recoverySetupPrompt': 'ตั้งค่าวิธีกู้คืนตู้เซฟหากลืม PIN',
    'skipForNow': 'ข้ามไปก่อน',
    'recoveryConfigured': 'ตั้งค่าการกู้คืนแล้ว',
    'notConfigured': 'ยังไม่ได้ตั้งค่า',
    'regenerateKey': 'สร้างคีย์ใหม่',
    'antiTheft': 'ป้องกันการโจรกรรม',
    'antiTheftDesc': 'ปกป้องตู้เซฟหากโทรศัพท์ถูกขโมย',
    'decoyPin': 'PIN ล่อ',
    'decoyPinDesc': 'PIN ที่สองที่เปิดตู้เซฟว่าง',
    'setDecoyPin': 'ตั้ง PIN ล่อ',
    'decoyPinSet': 'ตั้ง PIN ล่อแล้ว',
    'decoySameAsReal': 'PIN ล่อต้องต่างจาก PIN จริง',
    'removeDecoyPin': 'ลบ PIN ล่อ',
    'intruderSelfie': 'ภาพผู้บุกรุก',
    'intruderSelfieDesc': 'ถ่ายภาพเงียบๆ หลังใส่ PIN ผิด 3 ครั้ง',
    'breakInAttempts': 'ความพยายามบุกรุก',
    'noBreakIns': 'ไม่มีบันทึกการบุกรุก',
    'clearLog': 'ล้างบันทึก',
    'clearLogConfirm': 'ลบบันทึกและภาพทั้งหมด?',
    'photoUnavailable': 'ไม่มีภาพ',
    'secQ1': 'สัตว์เลี้ยงตัวแรกของคุณชื่ออะไร?',
    'secQ2': 'นามสกุลเดิมของแม่คุณคืออะไร?',
    'secQ3': 'คุณเกิดที่เมืองใด?',
    'secQ4': 'โรงเรียนแรกของคุณชื่ออะไร?',
    'secQ5': 'หนังสือเล่มโปรดของคุณคืออะไร?',
    'secQ6': 'ชื่อเล่นตอนเด็กของคุณคืออะไร?',
    'clearSelection': 'ล้างการเลือก',
    'lockInPrivateFolder': 'ล็อคในโฟลเดอร์ส่วนตัว',
    'movingToPrivate': 'กำลังย้ายไปโฟลเดอร์ส่วนตัว',
    'deletingFiles': 'กำลังลบ',
    'noVideosToLock': 'ไม่มีวิดีโอในโฟลเดอร์ที่เลือก',
    'videosQueued': 'วิดีโอในคิว',
    'deleteFoldersTitle': 'ลบวิดีโอ?',
    'deleteFoldersBody': 'จะลบวิดีโอทั้งหมดในโฟลเดอร์ที่เลือกอย่างถาวร',
    'lockFoldersBody': 'ย้ายวิดีโอทั้งหมดในโฟลเดอร์ที่เลือกไปยังโฟลเดอร์ส่วนตัว?',
    'propSectionFile': 'ไฟล์',
    'propSectionMedia': 'สื่อ',
    'propSectionPlayback': 'ประวัติการเล่น',
    'propFile': 'ไฟล์',
    'propLocation': 'ตำแหน่ง',
    'propSize': 'ขนาด',
    'propDate': 'วันที่',
    'propFormat': 'รูปแบบ',
    'propResolution': 'ความละเอียด',
    'propLength': 'ความยาว',
    'propBitrate': 'อัตราบิต',
    'propFinished': 'เล่นจบ',
    'propFinishedYes': 'เล่นจบแล้ว',
    'propFinishedNo': 'ยังเล่นไม่จบ',
    'propLastPosition': 'ตำแหน่งล่าสุด',
    'okay': 'ตกลง',
    'cancelling': 'กำลังยกเลิก…',
    'downloaderTitle': 'ตัวดาวน์โหลด',
    'downloaderSettings': 'ตั้งค่าตัวดาวน์โหลด',
    'downloaderPasteHint': 'วางลิงก์วิดีโอ',
    'downloaderPaste': 'วาง',
    'downloaderClipboardFound': 'พบลิงก์ในคลิปบอร์ด',
    'downloaderDismiss': 'ปิด',
    'downloaderActive': 'การดาวน์โหลด',
    'downloaderTabBrowse': 'เรียกดู',
    'downloaderEmptyDownloads': 'ยังไม่มีการดาวน์โหลด',
    'downloaderEmptyDownloadsHint':
        'วางลิงก์ด้านบน หรือเปิดเรียกดูเพื่อเลือกเว็บไซต์',
    'downloaderClear': 'ล้าง',
    'downloaderFavourite': 'รายการโปรด',
    'downloaderRecommended': 'แนะนำ',
    'downloaderRestricted': 'เว็บไซต์ที่จำกัด',
    'downloaderQueued': 'อยู่ในคิว',
    'downloaderPreparing': 'กำลังเตรียม',
    'downloaderFinalizing': 'กำลังทำให้เสร็จ…',
    'downloaderSetIcon': 'ตั้งไอคอน',
    'downloaderRemoveIcon': 'ลบไอคอน',
    'downloaderIconFailed': 'ตั้งไอคอนไม่สำเร็จ',
    'downloaderIconHint': 'เคล็ดลับ — กดค้างที่เว็บไซต์เพื่อตั้งไอคอนเอง',
    'downloaderSaved': 'บันทึกแล้ว',
    'downloaderCancelled': 'ยกเลิกแล้ว',
    'downloaderFailed': 'ล้มเหลว',
    'downloaderPlay': 'เล่น',
    'downloaderDownload': 'ดาวน์โหลด',
    'downloaderEnginePreparing': 'กำลังเตรียมเอนจินสำหรับการใช้ครั้งแรก…',
    'downloaderEngineFailed': 'เอนจินดาวน์โหลดใช้งานไม่ได้',
    'downloaderNoMerger': 'ไม่มีตัวรวมไฟล์ — แสดงเฉพาะคุณภาพที่มีเสียงรวมอยู่',
    'downloaderSavePath': 'บันทึกไปที่',
    'downloaderChange': 'เปลี่ยน',
    'downloaderShowRestricted': 'แสดงเว็บไซต์ที่จำกัด',
    'downloaderRestrictedNote': 'เว็บไซต์สำหรับผู้ใหญ่ ปิดไว้เป็นค่าเริ่มต้น',
    'downloaderInvalidLink': 'ดูเหมือนจะไม่ใช่ลิงก์',
    'downloaderFetching': 'กำลังอ่านลิงก์…',
    'downloaderNoFormats': 'ไม่พบสื่อที่ดาวน์โหลดได้จากลิงก์นี้',
    'downloaderSiteHint': 'คัดลอกลิงก์วิดีโอที่นั่น แล้วกลับมา',
    'downloaderNoBrowser': 'ไม่พบเบราว์เซอร์สำหรับเปิดเว็บไซต์นี้',
    'downloaderDirFailed': 'เปลี่ยนโฟลเดอร์บันทึกไม่ได้',
    'downloaderAudio': 'เสียง',
    'downloaderVideo': 'วิดีโอ',
    'downloaderStream': 'สตรีม',
    'downloaderStreamFailed': 'เริ่มสตรีมไม่ได้',
    'downloaderConvert': 'แปลง',
    'downloaderLiveNote': 'สตรีมสดเล่นได้แต่ดาวน์โหลดไม่ได้',
    'downloaderStreamOnlyBest': 'การสตรีมใช้คุณภาพรวมเสียงที่ดีที่สุด',
    'downloaderStreamRefused':
        'เว็บไซต์นี้ไม่อนุญาตให้เล่นวิดีโอโดยตรง '
        'แต่การดาวน์โหลดมักยังใช้งานได้',
    'downloaderErrRateLimited': 'มีคำขอจากเครือข่ายนี้มากเกินไป',
    'downloaderRateLimitHint':
        'เว็บไซต์ขอให้ชะลอลง — เป็นเรื่องของเครือข่าย ไม่ใช่ตัววิดีโอ '
        'รอสักครู่ หรือสลับระหว่าง Wi-Fi กับเน็ตมือถือ แล้วลองใหม่',
    'downloaderRateLimitWait': 'ลองใหม่ในอีกประมาณ @m นาที',
    'downloaderAnySiteHint':
        'เหล่านี้เป็นทางลัด ไม่ใช่ข้อจำกัด — วางลิงก์จากเว็บวิดีโอเกือบทุกแห่ง '
        'แล้วระบบจะอ่านให้เหมือนกัน',
    'downloaderBrowseDownload': 'ดาวน์โหลดวิดีโอ',
    'downloaderBrowseHint': 'พบวิดีโอในหน้านี้',
    'downloaderBrowseWorking': 'กำลังอ่านหน้านี้…',
    'downloaderBrowsePick': 'เลือกคุณภาพ',
    'downloaderBrowseStarted': 'เพิ่มลงในรายการดาวน์โหลดแล้ว',
    'downloaderNeedsStorage': 'อนุญาตให้บันทึกลงโฟลเดอร์ดาวน์โหลด',
    'downloaderNeedsStorageBody':
        'Android จะให้เขียนลงโฟลเดอร์ดาวน์โหลดที่ใช้ร่วมกันได้ '
        'ก็ต่อเมื่อเปิด All files access หากไม่เปิด วิดีโอยังถูกบันทึกอยู่ '
        'แต่จะอยู่ในโฟลเดอร์ของแอปเองซึ่งแอปอื่นมองไม่เห็น',
    'downloaderGrantAccess': 'เปิดการตั้งค่า',
    'downloaderNoSound': 'ไม่มีเสียง',
    'downloaderViewPage': 'เปิดหน้าต้นทาง',
    'downloaderCopyLink': 'คัดลอกลิงก์',
    'downloaderNoSourcePage': 'ไม่ได้บันทึกหน้าต้นทางของไฟล์นี้ไว้',
    'downloaderDownloadAgain': 'ดาวน์โหลดอีกครั้ง',
    'downloaderRemoveFromList': 'ลบออกจากรายการ',
    'downloaderSeeAll': 'ดูทั้งหมด',
    'downloaderHistoryTitle': 'ประวัติการดาวน์โหลด',
    'downloaderHistoryEmpty': 'ยังไม่มีรายการดาวน์โหลด',
    'downloaderRetryDownload': 'ลองอีกครั้ง',
    'downloaderMoreOptions': 'เพิ่มเติม',
    'downloaderBrowseStreams': 'สื่อที่พบในหน้านี้',
    'downloaderBrowseUnreadable': 'อ่านวิดีโอนี้ไม่ได้',
    'downloaderBrowseRetry': 'ลองอีกครั้ง',
    'downloaderBrowseSendScreen': 'เปิดในหน้าดาวน์โหลด',
    'downloaderBrowseBlocked': 'เปิดเว็บนี้ไม่ได้',
    'downloaderBrowseVpnHint': 'เปิด VPN อยู่ YouTube และ TikTok มักปฏิเสธที่อยู่ VPN',
    'downloaderBrowseDnsHint': 'Private DNS ปลดบล็อกเว็บได้โดยไม่ต้องใช้ VPN',
    'downloaderBrowseMore': 'ค้นหาคุณภาพเพิ่มเติม…',
    'downloaderNetworkVpnOff': 'เว็บนี้เคยใช้ได้ตอนปิด VPN',
    'downloaderNetworkVpnOn': 'เว็บนี้เคยใช้ได้ตอนเปิด VPN',
    'downloaderNetworkVpnNow': 'เปิด VPN อยู่ YouTube และ TikTok มักปฏิเสธที่อยู่ VPN',
    'downloaderCheckNetwork': 'ตรวจสอบเครือข่ายนี้',
    'downloaderNetworkChecking': 'กำลังตรวจสอบเครือข่าย…',
    'downloaderNetworkDnsBlocked': 'เครือข่ายนี้บล็อกเว็บด้วยชื่อโดเมน Private DNS แก้ได้ ไม่ต้องใช้ VPN',
    'downloaderNetworkDeeper': 'การบล็อกไม่ได้อยู่ที่การค้นหาชื่อ Private DNS จึงช่วยไม่ได้ ต้องใช้ VPN',
    'downloaderNetworkUnknown': 'เปรียบเทียบ resolver ไม่ได้ — ตรวจสอบการเชื่อมต่อแล้วลองใหม่',
    'downloaderNetworkPrivateOn': 'เปิด Private DNS อยู่แล้ว',
    'downloaderNetworkNoVpnNeeded': 'เมื่อเปิด Private DNS สามารถปิด VPN ได้ YouTube จึงยังใช้งานได้',
    'downloaderBypassOpen': 'เปิดเลยโดยไม่ใช้ VPN',
    'downloaderBypassHint': 'Innocent จะค้นหาที่อยู่เอง',
    'downloaderVpnNotNeeded': 'ตอนนี้เว็บที่ถูกบล็อกเปิดได้โดยไม่ใช้ VPN แล้ว ปิด VPN แล้ว YouTube ก็ใช้ได้',
    'downloaderAlreadyHave': 'คุณดาวน์โหลดวิดีโอนี้ไปแล้ว',
    'downloaderYtWall': 'วิดีโอนี้เล่นไม่ได้บนเครือข่ายนี้',
    'downloaderYtEmbed': 'เล่นโดยไม่ต้องลงชื่อเข้าใช้',
    'downloaderYtSignInNow': 'ลงชื่อเข้าใช้ YouTube',
    'downloaderBotWallHint':
        'YouTube ไม่ไว้ใจที่อยู่เครือข่ายนี้ ซึ่งพบบ่อยเมื่อใช้ VPN '
        'เพราะหลายคนใช้ที่อยู่เดียวกัน ปิด VPN สำหรับ YouTube '
        'หรือลงชื่อเข้าใช้ด้านล่าง — บัญชีที่ลงชื่อเข้าใช้แล้วใช้ได้ทั้งสองแบบ',
    'downloaderSupportedSites': 'ใช้ได้กับเว็บไซต์กว่าพันแห่ง',
    'downloaderEdit': 'แก้ไข',
    'downloaderUpdateEngine': 'อัปเดตเอนจิน',
    'downloaderUpdating': 'กำลังอัปเดตเอนจิน…',
    'downloaderUpdated': 'อัปเดตเอนจินแล้ว',
    'downloaderUpToDate': 'เอนจินเป็นเวอร์ชันล่าสุดแล้ว',
    'downloaderUpdateFailed': 'อัปเดตเอนจินไม่สำเร็จ',
    'downloaderCookies': 'ไฟล์คุกกี้',
    'downloaderCookiesNote': 'ไฟล์ cookies.txt สำหรับลิงก์ที่ต้องเข้าสู่ระบบ',
    'downloaderPickCookies': 'เลือกไฟล์',
    'downloaderRemove': 'ลบออก',
    'downloaderDetails': 'รายละเอียด',
    'downloaderAdvanced': 'ขั้นสูง',
    'downloaderPlayerClients': 'ตัวเล่นสำรอง',
    'downloaderPlayerClientsNote': 'ใช้เมื่อ YouTube ปฏิเสธเท่านั้น เว้นว่างเพื่อข้าม',
    'downloaderErrBot': 'YouTube ขอให้อุปกรณ์นี้ยืนยันว่าไม่ใช่บอท',
    'downloaderErrAccount': 'ลิงก์นี้ต้องเข้าสู่ระบบ',
    'downloaderErrNetwork': 'เข้าถึงเว็บไซต์ไม่ได้ ตรวจสอบการเชื่อมต่อ',
    'downloaderErrExtractor': 'เอนจินอ่านเว็บไซต์นี้ไม่ได้ อาจเป็นเวอร์ชันเก่า',
    'downloaderErrUnsupported': 'ไม่พบสื่อที่ดาวน์โหลดได้จากลิงก์นี้',
    'downloaderErrUnknown': 'อ่านลิงก์นี้ไม่ได้',
    'downloaderClearBar': 'ล้าง',
    'downloaderWatermark': 'มีลายน้ำ',
    'downloaderPause': 'หยุดชั่วคราว',
    'downloaderResume': 'ทำต่อ',
    'downloaderPaused': 'หยุดไว้',
    'downloaderRetrying': 'กำลังเชื่อมต่อใหม่…',
    'downloaderRemaining': 'เหลือ',
    'downloaderInterrupted': 'ถูกขัดจังหวะ — แตะทำต่อเพื่อดำเนินการ',
    'downloaderResumeAll': 'ทำต่อทั้งหมด',
    'downloaderOf': '/',
    'downloaderNoWatermark': 'ไม่มีลายน้ำ',
    'downloaderPhotos': 'รูป',
    'downloaderPhotoPost': 'โพสต์รูปภาพ',
    'downloaderSaveAll': 'บันทึกทั้งหมด',
    'downloaderPhotosSaved': 'บันทึกรูปแล้ว',
    'downloaderSignIn': 'เข้าสู่ระบบ',
    'downloaderSignedIn': 'เข้าสู่ระบบแล้ว — กำลังลองลิงก์อีกครั้ง',
    'downloaderSessions': 'เว็บไซต์ที่เข้าสู่ระบบ',
    'downloaderSessionsNote': 'เข้าสู่ระบบใน Innocent เพื่อให้ลิงก์ที่ต้องมีบัญชีใช้งานได้',
    'downloaderSignOut': 'ออกจากระบบ',
    'downloaderSignInFailed': 'เปิดหน้าเข้าสู่ระบบไม่ได้',
    'downloaderFixAuto': 'แก้ไขอัตโนมัติ',
    'downloaderPreparingSession': 'กำลังรับเซสชันผู้เยี่ยมชม…',
    'downloaderWifiOnly': 'ดาวน์โหลดผ่าน Wi-Fi เท่านั้น',
    'downloaderSavedFiles': 'ไฟล์ที่บันทึกไว้',
    'downloaderShare': 'แชร์',
    'downloaderDeleteFile': 'ลบ',
    'downloaderDeleteConfirm': 'ลบไฟล์นี้ออกจากเครื่องหรือไม่',
    'downloaderDeleted': 'ลบแล้ว',
    'downloaderMissing': 'ไม่พบไฟล์นี้ในเครื่องแล้ว',
    'downloaderClearList': 'ล้างรายการ',
    'downloaderNotifsBlocked': 'การแจ้งเตือนถูกปิด ดาวน์โหลดจะทำงานแบบมองไม่เห็น',
    'downloaderOpenSettings': 'ตั้งค่า',
    'downloaderVideos': 'วิดีโอ',
    'downloaderSelectAll': 'เลือกทั้งหมด',
    'downloaderSelectNone': 'ไม่เลือกเลย',
    'downloaderQueuedCount': 'รายการเข้าคิวแล้ว',
    'downloaderAskEveryTime': 'ถามทุกครั้ง',
    'downloaderBest': 'ดีที่สุด',
    'downloaderDefaultQuality': 'คุณภาพเริ่มต้น',
    'downloaderDefaultQualityNote': 'เลือกไว้แล้ววางลิงก์จะดาวน์โหลดทันที',
    'downloaderSubtitles': 'ภาษาคำบรรยาย',
    'downloaderSubtitlesNote': 'คั่นด้วยจุลภาค เช่น en,th — เว้นว่างคือไม่เอา',
    'downloaderEmbedThumbnail': 'ใส่ภาพปกในไฟล์',
    'downloaderEmbedMetadata': 'บันทึกชื่อและผู้สร้างในไฟล์',
    'downloaderSpeedLimit': 'จำกัดความเร็ว',
    'downloaderUnlimited': 'ไม่จำกัด',
    'downloaderExtras': 'ส่วนเสริม',
    'downloaderWifiOnlyNote': 'ไม่ใช้เน็ตมือถือโดยไม่ถาม',
    'downloaderMetered': 'คุณกำลังใช้เน็ตมือถือ',
    'downloaderDownloadAnyway': 'ดาวน์โหลดต่อไป',
    'downloaderLowSpace': 'พื้นที่ว่างไม่พอสำหรับการดาวน์โหลดนี้',
    'downloaderTapResume': 'แตะเล่นต่อเพื่อดาวน์โหลดต่อไป',
    'downloaderAutoUpdate': 'อัปเดตเอนจินอัตโนมัติ',
    'downloaderAutoUpdateNote': 'ตรวจทุกสัปดาห์ และอีกครั้งเมื่อลิงก์ถูกปฏิเสธ',
    'downloaderConfigUrl': 'แหล่งการตั้งค่า',
    'downloaderConfigUrlNote': 'ที่อยู่ JSON ที่ Innocent อ่านการแก้ไข ทำให้ซ่อมได้โดยไม่ต้องอัปเดตแอป',
    'downloaderCopyDiagnostics': 'คัดลอกข้อมูลวินิจฉัย',
    'downloaderCopied': 'คัดลอกแล้ว — วางในที่ที่คุณรายงานปัญหา',
    'downloaderConfigNotSet': 'ยังไม่ได้ตั้ง',

    // --- App update (updater plan step 2) ---
    'settingsAppUpdate': 'อัปเดตแอป',
    'updateInstalledVersion': 'เวอร์ชันที่ติดตั้ง',
    'updateLatestVersion': 'เวอร์ชันล่าสุด',
    'updateSize': 'ขนาดดาวน์โหลด',
    'updateReleased': 'วันที่เผยแพร่',
    'updateUpToDate': 'คุณใช้เวอร์ชันล่าสุดอยู่แล้ว',
    'updateAvailable': 'มีอัปเดตใหม่',
    'updateCheckNow': 'ตรวจสอบตอนนี้',
    'updateChecking': 'กำลังตรวจสอบ...',
    'updateCheckFailed': 'ตรวจสอบอัปเดตไม่ได้ ลองอีกครั้ง',
    'updateNotConfigured': 'บิลด์นี้ไม่ได้ตั้งค่าการตรวจสอบอัปเดต',

    // --- App update: the download (updater plan step 3) ---
    'updateDownload': 'ดาวน์โหลดอัปเดต',
    'updateDownloading': 'กำลังดาวน์โหลด...',
    'updateVerifying': 'กำลังตรวจสอบไฟล์ที่ดาวน์โหลด...',
    'updateDownloaded': 'ดาวน์โหลดแล้ว',
    'updateDownloadDamaged': 'ไฟล์ที่ดาวน์โหลดเสียหาย ลองอีกครั้ง',
    'updateDownloadMismatch': 'ไฟล์อัปเดตนี้ไม่ตรงกับที่แอปคาดไว้ '
        'ไม่ใช่ปัญหาการเชื่อมต่อของคุณ — ดาวน์โหลดใหม่ก็จะได้ไฟล์เดิม '
        'กด "ตรวจสอบตอนนี้" หากยังเหมือนเดิม แปลว่าต้องแก้ที่ตัวรีลีส',
    'updateDownloadFailed': 'ดาวน์โหลดไม่สำเร็จ ลองอีกครั้ง',
    'updateDownloadWriteFailed': 'เขียนไฟล์ไม่ได้ เครื่องอาจมีพื้นที่ไม่พอ '
        'หรือแอปอื่นล้างไฟล์ชั่วคราวของแอปนี้ระหว่างดาวน์โหลด '
        'กรุณาเพิ่มพื้นที่แล้วลองใหม่',
    'updateDownloadRefused': 'เซิร์ฟเวอร์ปฏิเสธการดาวน์โหลด',
    'updateNotEnoughSpace': 'พื้นที่ไม่เพียงพอสำหรับอัปเดตนี้',
    'updateRetry': 'ลองอีกครั้ง',
    'updateNotificationTitle': 'กำลังดาวน์โหลดอัปเดต',
    'updateWaitingForNetwork': 'กำลังรอเครือข่าย...',
    'updateKept': 'เก็บไว้แล้ว',
    'updateResumeNow': 'ดาวน์โหลดต่อตอนนี้',
    'updateInstall': 'ติดตั้ง',
    'updateInstallChecking': 'กำลังตรวจสอบไฟล์...',
    'updateInstallGone': 'ไฟล์ที่ดาวน์โหลดหายไป กรุณาดาวน์โหลดใหม่',
    'updateInstallNoHandler': 'โทรศัพท์เครื่องนี้ไม่มีตัวติดตั้งสำหรับเปิดอัปเดต',
    'updateInstallSignature':
        'ติดตั้งอัปเดตนี้ไม่ได้ กรุณาติดต่อฝ่ายสนับสนุน',
    'updateNow': 'อัปเดต',
    'updateNotNow': 'ไว้ก่อน',
    'updateRequired': 'ต้องอัปเดต',
    'updateRequiredBody':
        'เวอร์ชันนี้ใช้งานต่อไม่ได้แล้ว ติดตั้งอัปเดตด้านล่างเพื่อใช้งานต่อ',
  };
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  @override
  // Accept EVERY locale, not just en/my/th. Returning false here removes the
  // delegate from scope for that locale, which made `Localizations.of` return
  // null and took the screen down. Per-key lookup in [_s] already falls back
  // to English, so loading for an unsupported locale is harmless and simply
  // yields English text — a far better outcome than no screen at all.
  // (`supportedLocales` on MaterialApp still drives which locale is chosen;
  // this only guarantees the delegate is always available once one is.)
  bool isSupported(Locale locale) => true;

  @override
  Future<AppStrings> load(Locale locale) =>
      // Strings are in-memory, so resolve synchronously — no first-frame
      // flash of the fallback locale.
      SynchronousFuture<AppStrings>(AppStrings(locale));

  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}
