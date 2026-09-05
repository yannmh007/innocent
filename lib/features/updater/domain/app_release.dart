/// One row of `public.app_releases` — the update manifest.
///
/// Step 1-2 of `docs/updater_plan.md`. The app has no Play Store, so this row
/// is the only way an installed build learns that a newer one exists.
///
/// Only the fields the CHECK needs are parsed. `apk_url` and `apk_sha256`
/// arrive with step 3, when there is something to download; selecting a column
/// that does not exist makes PostgREST reject the whole request, so the select
/// list in `UpdateCheckService` and the fields here are kept in step.
class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.versionCode,
    this.apkBytes,
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

  /// Download size. Null until an APK is actually published.
  final int? apkBytes;

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

    return AppRelease(
      versionName: name,
      versionCode: code,
      apkBytes: bytes is int ? bytes : null,
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
