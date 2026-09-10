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

  /// Builds a release from one PostgREST row, or null if the row is unusable.
  ///
  /// Returns null rather than throwing on a malformed row: a broken manifest
  /// must read as "no update", never as a crash on a settings screen.
  static AppRelease? fromJson(Map<String, dynamic> json) {
    final name = json['version_name'];
    final code = json['version_code'];
    if (name is! String || name.isEmpty) return null;
    if (code is! int) return null;

    final bytes = json['apk_bytes'];
    final released = json['released_at'];
    final url = json['apk_url'];
    final sha = json['apk_sha256'];
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
    );
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
