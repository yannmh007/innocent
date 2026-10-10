/// One row of `public.app_releases` — the update manifest.
///
/// Step 1-2 of `docs/updater_plan.md`. The app has no Play Store, so this row
/// is the only way an installed build learns that a newer one exists.
///
/// `apk_url` and `apk_sha256` arrived with step 3. Selecting a column that
/// does not exist makes PostgREST reject the whole request, so the select list
/// in `UpdateCheckService` and the fields here are kept in step.
///
/// Both are nullable in the migration and null in the row today: the table
/// exists before any APK has been published. Nothing may assume otherwise —
/// [canDownload] is the only sanctioned way to ask.
class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.versionCode,
    this.apkUrl,
    this.apkSha256,
    this.apkBytes,
    this.minSupported,
    this.priority,
    this.notesEn,
    this.notesMm,
    this.releasedAt,
    this.playerFlags = const <String>{},
  });

  /// Shown to the user: '1.64.6'.
  final String versionName;

  /// Compared against [AppVersion.build]. THE INTEGER, never the name.
  ///
  /// Comparing '1.64.5' with '1.9.0' as text says 1.9.0 is newer, because '9'
  /// sorts after '6'. Every project makes that mistake once. The integer
  /// cannot be got wrong.
  final int versionCode;

  /// Where the APK lives. Null until an APK is actually published.
  final String? apkUrl;

  /// Lowercase hex SHA-256 of the APK, 64 characters. Null until published.
  ///
  /// The download is checked against this and nothing else. It is the only
  /// thing standing between a truncated or tampered file and the installer.
  final String? apkSha256;

  /// Download size. Null until an APK is actually published.
  final int? apkBytes;

  /// §2's emergency brake: below this build, the app must not keep running.
  ///
  /// NULLABLE HERE THOUGH `not null default 0` IN THE MIGRATION, and that is
  /// the whole safety design. Null means "the server did not tell us" — an
  /// older schema, a column that failed to parse, a row read by a build that
  /// asked for a column that is not there. Every one of those must read as
  /// "no minimum", never as "block". See [UpdatePromptDecision.isBlocked],
  /// which is the only thing allowed to act on this.
  final int? minSupported;

  /// §2's urgency dial, 1..5. Null when the server did not say.
  ///
  /// Changes how loudly the prompt speaks and NOTHING else. It cannot block,
  /// cannot remove "Not now", and cannot make a prompt un-dismissible; only
  /// [minSupported] can do that, and it is deliberately a separate column
  /// answering a separate question.
  final int? priority;

  final String? notesEn;
  final String? notesMm;
  final DateTime? releasedAt;

  /// Remote player switches (migration 038), e.g. `legacy_surface`.
  final Set<String> playerFlags;

  /// Builds a release from one PostgREST row, or null if the row is unusable.
  ///
  /// Returns null rather than throwing on a malformed row: a broken manifest
  /// must read as "no update", never as a crash on a settings screen.
  ///
  /// [abis] is what the phone can run, best first (`Build.SUPPORTED_ABIS`).
  /// It decides WHICH APK the release offers: the arm64 one, or — on a phone
  /// whose Android is 32-bit — the armeabi-v7a one (migration 044). See
  /// [phoneRuns32BitOnly]. Empty means "not known", which keeps the arm64 APK,
  /// as every build before 1.64.60 did.
  static AppRelease? fromJson(Map<String, dynamic> json,
      {List<String> abis = const <String>[]}) {
    final name = json['version_name'];
    final code = json['version_code'];
    if (name is! String || name.isEmpty) return null;
    if (code is! int) return null;

    final released = json['released_at'];
    // THE FILE THIS PHONE CAN INSTALL, and only that one. A 32-bit phone is
    // never offered the arm64 APK: the installer would refuse it after the
    // whole download ("App not installed"). With no 32-bit file published —
    // or one left over from an earlier version — it has nothing to download,
    // which is the truth for that phone.
    final arm32 = phoneRuns32BitOnly(abis);
    final Object? bytes, url, sha;
    if (arm32) {
      final u = json['apk_url_arm32'];
      final fresh = u is String && !_namesOtherBuild(u, code);
      url = fresh ? u : null;
      sha = fresh ? json['apk_sha256_arm32'] : null;
      bytes = fresh ? json['apk_bytes_arm32'] : null;
    } else {
      url = json['apk_url'];
      sha = json['apk_sha256'];
      bytes = json['apk_bytes'];
    }
    // `is int` and nothing else. A string '319', a double, a null or a missing
    // key all become null, which reads as "no minimum set" — the safe answer.
    // Coercing here (int.tryParse on a string, say) would be a way for a typo
    // in the SQL editor to lock every install out of the app.
    final min = json['min_supported'];
    final prio = json['priority'];

    return AppRelease(
      versionName: name,
      versionCode: code,
      apkUrl: url is String && url.trim().isNotEmpty ? url.trim() : null,
      apkSha256: sha is String && sha.trim().isNotEmpty
          ? sha.trim().toLowerCase()
          : null,
      apkBytes: bytes is int ? bytes : null,
      minSupported: min is int ? min : null,
      priority: prio is int ? prio : null,
      notesEn: json['notes_en'] is String ? json['notes_en'] as String : null,
      notesMm: json['notes_mm'] is String ? json['notes_mm'] as String : null,
      releasedAt: released is String ? DateTime.tryParse(released) : null,
      playerFlags: parsePlayerFlags(json['player_flags']),
    );
  }

  /// Whether a phone with these ABIs can run 32-bit ARM code and NOT 64-bit:
  /// the phones the armeabi-v7a APK exists for. A phone listing arm64-v8a
  /// takes the arm64 APK even if it also lists armeabi-v7a (nearly all do);
  /// an unknown list, or one with neither, keeps the arm64 APK.
  static bool phoneRuns32BitOnly(List<String> abis) =>
      !abis.contains('arm64-v8a') && abis.contains('armeabi-v7a');

  /// A 32-bit URL whose file name carries another build's number — the
  /// column left at the last release while the row moved on. Installed, it
  /// would be the old version again, offered for ever.
  static bool _namesOtherBuild(String url, int code) {
    final m = RegExp(r'-(\d+)-arm32\.apk$').firstMatch(url.trim());
    return m != null && int.parse(m.group(1)!) != code;
  }

  /// Words of `player_flags`: lower-case `[a-z0-9_]` only, at most 16, so a
  /// stray value in the SQL editor cannot turn into anything but "no flag".
  static Set<String> parsePlayerFlags(Object? raw) {
    if (raw is! String) return const <String>{};
    final ok = RegExp(r'^[a-z0-9_]{1,40}$');
    return raw
        .toLowerCase()
        .split(RegExp(r'[\s,]+'))
        .where(ok.hasMatch)
        .take(16)
        .toSet();
  }

  /// True only when the server build is strictly higher than the installed one.
  ///
  /// Strictly higher, so an installed build that is AHEAD of the server (which
  /// is the normal state right after a build, before the row is updated) reads
  /// as up to date. The updater must never offer a downgrade.
  bool isNewerThan(int installedBuild) => versionCode > installedBuild;

  /// True only when there is a real APK to fetch AND a hash to check it with.
  ///
  /// THE DOWNLOAD BUTTON'S ONLY GATE. Both columns are nullable and both are
  /// null in the row today, so a build that shipped this code before any APK
  /// was published must show no button at all — not a button that fails.
  ///
  /// The hash is required, not optional. A download with no hash to check
  /// against cannot be verified, and an unverifiable APK is exactly the file
  /// this feature must never hand to the installer. A row carrying a URL and
  /// no hash is a publishing mistake, and reads here as "not ready".
  ///
  /// The shape of the hash is checked too. `apk_sha256` is a free-text column;
  /// a truncated or placeholder value would otherwise fail verification much
  /// later, after the user has spent 88 MB of a data bundle finding out.
  bool get canDownload {
    final url = apkUrl;
    final sha = apkSha256;
    if (url == null || sha == null) return false;
    if (!url.startsWith('https://')) return false;
    return _isSha256Hex(sha);
  }

  /// 64 lowercase hex characters, and nothing else.
  static bool _isSha256Hex(String value) {
    if (value.length != 64) return false;
    for (var i = 0; i < 64; i++) {
      final c = value.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLowerAF = c >= 0x61 && c <= 0x66;
      if (!isDigit && !isLowerAF) return false;
    }
    return true;
  }

  /// '42 MB', or null when no APK is published yet.
  ///
  /// MB and not MiB: this number exists so a Myanmar user can weigh it against
  /// a data bundle, and bundles are sold in MB.
  String? get sizeLabel {
    final bytes = apkBytes;
    if (bytes == null || bytes <= 0) return null;
    final mb = bytes / 1000000;
    if (mb < 10) return '${mb.toStringAsFixed(1)} MB';
    return '${mb.round()} MB';
  }

  /// '1.64.8 (321) · 88 MB', or '1.64.8 (321)' when no size is published.
  ///
  /// ONE definition, because the dialog and the notification are two views of
  /// the same fact and must not disagree about it. A user who sees '88 MB' in
  /// the shade and a different number in the dialog has been given a reason to
  /// distrust both.
  ///
  /// The build number is kept. It is the only value that is actually compared
  /// (see [isNewerThan]), and it is what a user reads back when asking for
  /// help.
  String get headline {
    final version = '$versionName ($versionCode)';
    final size = sizeLabel;
    return size == null ? version : '$version  ·  $size';
  }

  /// Release notes in the reader's language, falling back to English.
  ///
  /// There is no `notes_th` column. Thai falls back to English rather than
  /// showing Burmese, which would be worse than showing a language the reader
  /// is at least likely to have seen.
  String? notesFor(String languageCode) {
    final mm = notesMm;
    if (languageCode == 'my' && mm != null && mm.trim().isNotEmpty) return mm;
    final en = notesEn;
    if (en != null && en.trim().isNotEmpty) return en;
    return mm != null && mm.trim().isNotEmpty ? mm : null;
  }
}
