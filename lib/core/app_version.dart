/// Phase 40: centralized app version constants.
///
/// We don't depend on `package_info_plus` to keep pubspec lightweight, so
/// these values are updated alongside `pubspec.yaml` on each phase. About
/// screen and any other version-displaying surface should import from here
/// rather than hard-coding the string.
class AppVersion {
  AppVersion._();

  /// Public-facing display name. Internal dart package is still
  /// `mx_clone` to avoid a sweeping import refactor across ~150 files,
  /// but everything the user sees uses this constant. Changing this
  /// here updates About, Legal, MediaSession, notifications, app bar
  /// titles, and external-intent dialogs in one go.
  static const String displayName = 'Innocent';

  /// Public-facing version (matches `version:` in pubspec.yaml without build).
  static const String name = '1.64.34';

  /// Build number (matches the `+NN` suffix in pubspec.yaml).
  static const int build = 347;

  /// Combined string, e.g. "0.45.0 (55)".
  static String get full => '$name ($build)';
}
