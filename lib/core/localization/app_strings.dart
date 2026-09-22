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
  String get updateDownloadFailed => _s('updateDownloadFailed');
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
  String get aboutCloudDrive => _s('aboutCloudDrive');
  String get cloudDriveBody => _s('cloudDriveBody');
  String get connectCloudCaps => _s('connectCloudCaps');
  String get deviceStorage => _s('deviceStorage');
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
  String itemsCount(Object n) => _s('itemsCount').replaceFirst('{n}', '$n');
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
  String get vhPayPayee => _s('vhPayPayee');
  String get vhPayNumber => _s('vhPayNumber');
  String get vhPayAmount => _s('vhPayAmount');
  String get vhPayCopied => _s('vhPayCopied');
  String get vhPayReferenceHint => _s('vhPayReferenceHint');
  String get vhPaySenderHint => _s('vhPaySenderHint');
  String get vhPaySubmit => _s('vhPaySubmit');
  String get vhPayManualNote => _s('vhPayManualNote');
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
  String get vhLibraryDownloads => _s('vhLibraryDownloads');
  String get vhDeleteDownloadBody => _s('vhDeleteDownloadBody');
  String get vhLibraryDownloadsHint => _s('vhLibraryDownloadsHint');
  String get vhLibrarySoon => _s('vhLibrarySoon');

  static const Map<String, Map<String, String>> _byLocale =
      <String, Map<String, String>>{
    'en': _en,
    'my': _my,
    'th': _th,
  };

  static const Map<String, String> _en = <String, String>{
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
    'connectAdbToSend': 'Connect iADB to send Android/data videos',
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
    'vhLibraryDownloadsHint': 'Watch offline - Premium',
    'vhDeleteDownloadBody':
        'Remove this download from your device? You can download it again '
        'while your subscription is active.',
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
    'vhPayStep2': 'Keep the KPay transaction ID from your receipt',
    'vhPayStep3': 'Enter the details below',
    'vhPayPayee': 'Account name',
    'vhPayNumber': 'KPay number',
    'vhPayAmount': 'Amount',
    'vhPayCopied': 'Copied',
    'vhPayReferenceHint': 'KPay transaction ID',
    'vhPaySenderHint': 'Number you paid from',
    'vhPaySubmit': 'Submit payment',
    'vhPayManualNote': 'Payments are checked by hand against the KPay statement, so activation is not instant.',
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
    'aboutCloudDrive': 'About Cloud Drive',
    'cloudDriveBody': 'Stream videos and music directly from your cloud accounts without downloading. Connect a provider below to browse its files inside Innocent.',
    'connectCloudCaps': 'CONNECT YOUR CLOUD STORAGE',
    'deviceStorage': 'Device storage',
    'cleanUpSpace': 'Clean up for more space',
    'scanningCleanable': 'Scanning for cleanable files...',
    'openingRecentlyPlayed': 'Opening Recently Played',
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
    'updateDownloadFailed': 'The download did not finish. Try again.',
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
    'connectAdbToSend': 'Android/data ဗီဒီယိုများ ပို့ရန် iADB ချိတ်ဆက်ပါ',
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
    'vhLibraryDownloadsHint': 'အော့ဖ်လိုင်း ကြည့်ရန် - Premium',
    'vhDeleteDownloadBody':
        'ဤဒေါင်းလုဒ်ကို ဖုန်းထဲက ဖယ်ရှားမလား။ Premium သက်တမ်း ရှိနေသေးသ၍ '
        'ပြန်ဒေါင်းလုဒ် လုပ်လို့ ရပါတယ်။',
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
    'vhPayStep2': 'ပြေစာမှ KPay လွှဲပြောင်းမှု ID ကို သိမ်းထားပါ',
    'vhPayStep3': 'အောက်တွင် အချက်အလက် ဖြည့်ပါ',
    'vhPayPayee': 'အကောင့်အမည်',
    'vhPayNumber': 'KPay နံပါတ်',
    'vhPayAmount': 'ပမာဏ',
    'vhPayCopied': 'ကူးယူပြီး',
    'vhPayReferenceHint': 'KPay လွှဲပြောင်းမှု ID',
    'vhPaySenderHint': 'ငွေလွှဲသည့် နံပါတ်',
    'vhPaySubmit': 'ငွေပေးချေမှု တင်ရန်',
    'vhPayManualNote': 'ငွေပေးချေမှုများကို KPay စာရင်းနှင့် လူကိုယ်တိုင် တိုက်စစ်သဖြင့် ချက်ချင်း အသက်မဝင်ပါ။',
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
    'watchLater': 'မှ ကြည့်ရန်',
    'playlists': 'ဖွင့်စာရင်းများ',
    'recycleBin': 'အမှိုက်ပုံး',
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
    'noFilesHint': 'ဖိုင် မရှိသေးပါ။\n"Add files" ကိုနှိပ်ပြီး ပို့မယ့်ဖိုင် ရွေးပါ။',
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
    'aboutCloudDrive': 'Cloud Drive အကြောင်း',
    'cloudDriveBody': 'သင့် cloud account တွေထဲက ဗီဒီယိုနဲ့ သီချင်းတွေကို ဒေါင်းလုဒ်မလုပ်ဘဲ တိုက်ရိုက် ဖွင့်နိုင်ပါမယ်။ အောက်က provider တစ်ခုကို ချိတ်ပြီး Innocent ထဲကနေ ဖိုင်တွေ ကြည့်နိုင်ပါတယ်။',
    'connectCloudCaps': 'သင့် CLOUD STORAGE ကို ချိတ်ဆက်ပါ',
    'deviceStorage': 'စက်၏ သိုလှောင်မှု',
    'cleanUpSpace': 'နေရာလွတ်ရအောင် ရှင်းလင်းမယ်',
    'scanningCleanable': 'ရှင်းလင်းနိုင်တဲ့ဖိုင်များ ရှာနေသည်...',
    'openingRecentlyPlayed': 'မကြာသေးမီဖွင့်ခဲ့သည်များ ဖွင့်နေသည်',
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
    'updateDownloadFailed': 'ဒေါင်းလုဒ် မပြီးဆုံးပါ။ ထပ်ကြိုးစားကြည့်ပါ။',
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
    'connectAdbToSend': 'เชื่อมต่อ iADB เพื่อส่งวิดีโอ Android/data',
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
    'vhLibraryDownloadsHint': 'ดูออฟไลน์ - Premium',
    'vhDeleteDownloadBody':
        'ลบดาวน์โหลดนี้ออกจากเครื่องหรือไม่ คุณดาวน์โหลดใหม่ได้ '
        'ตราบใดที่สมาชิกยังใช้งานอยู่',
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
    'vhPayStep2': 'เก็บรหัสธุรกรรม KPay จากใบเสร็จไว้',
    'vhPayStep3': 'กรอกรายละเอียดด้านล่าง',
    'vhPayPayee': 'ชื่อบัญชี',
    'vhPayNumber': 'เบอร์ KPay',
    'vhPayAmount': 'จำนวนเงิน',
    'vhPayCopied': 'คัดลอกแล้ว',
    'vhPayReferenceHint': 'รหัสธุรกรรม KPay',
    'vhPaySenderHint': 'เบอร์ที่ใช้โอน',
    'vhPaySubmit': 'ส่งการชำระเงิน',
    'vhPayManualNote': 'การชำระเงินตรวจสอบด้วยคนเทียบกับรายการ KPay จึงไม่เปิดใช้งานทันที',
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
    'aboutCloudDrive': 'เกี่ยวกับ Cloud Drive',
    'cloudDriveBody': 'สตรีมวิดีโอและเพลงจากบัญชีคลาวด์โดยตรงไม่ต้องดาวน์โหลด เชื่อมต่อผู้ให้บริการด้านล่างเพื่อดูไฟล์ใน Innocent',
    'connectCloudCaps': 'เชื่อมต่อคลาวด์ของคุณ',
    'deviceStorage': 'พื้นที่จัดเก็บอุปกรณ์',
    'cleanUpSpace': 'ล้างเพื่อเพิ่มพื้นที่',
    'scanningCleanable': 'กำลังสแกนไฟล์ที่ล้างได้...',
    'openingRecentlyPlayed': 'กำลังเปิดเล่นล่าสุด',
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
    'updateDownloadFailed': 'ดาวน์โหลดไม่สำเร็จ ลองอีกครั้ง',
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
