/// Where the backend lives.
///
/// THE ONLY FILE THAT NEEDS EDITING TO GO LIVE. Fill these in (or pass them at
/// build time) and every repository switches from the on-device stubs to the
/// real server. Nothing else in the app changes.
///
/// ```
/// flutter build apk \
///   --dart-define=VH_BASE_URL=https://xxxx.supabase.co \
///   --dart-define=VH_ANON_KEY=eyJhbGciOi...
/// ```
///
/// `--dart-define` is preferred over editing the defaults, because a value
/// typed into source gets committed, and a repo is a place secrets go to be
/// found. Editing [_baseUrlDefault] works too if the build tooling makes
/// defines awkward.
///
/// ### About the anon key
///
/// It is NOT a secret and is not treated as one. It ships inside the APK,
/// anyone can extract it, and that is by design: it identifies the project,
/// it does not authorise anything. What protects data is Row Level Security
/// plus the playback function's own checks - see
/// `docs/premium_backend_spec.md`.
///
/// The key that IS a secret is the service-role key, and it must never appear
/// in this app, in this repository, or in any string the app can reach.
class BackendConfig {
  BackendConfig._();

  // ─── WIRED TO THE LIVE PROJECT, 1 Sep 2026 (v1.63.6) ──────────────────
  //
  // These were empty, which made every build run on the bundled demo data and
  // never touch a server. They are FALLBACKS: a `--dart-define` of the same
  // name still wins, so a future staging build overrides them without editing
  // this file.
  //
  // Filled in rather than left to the build command because the build runs in
  // FlutLab, where a custom define may not be reachable at all. A value that
  // has to be typed correctly into a web IDE on a phone, every single build,
  // is a value that will one day be typed wrong - and the failure looks like
  // an empty catalogue, not like a missing setting.
  //
  // NEITHER IS A SECRET. The publishable key identifies the project; it does
  // not authorise anything. What protects the catalogue is RLS plus the column
  // grants, and what protects the media is `request-playback` - both proven
  // on 1 Sep 2026 by watching `anon` be refused `titles.locator`, and by
  // watching a signed URL expire after ten minutes.
  //
  // `sb_publishable_...` and not the legacy `anon` JWT: the legacy keys are
  // deprecated at the end of 2026. Verified compatible with THIS client -
  // `api_client.dart` sends the key only as the `apikey` header and never as
  // `Authorization: Bearer`, which is the one place the new opaque keys are
  // documented not to work.
  static const String _baseUrlDefault =
      'https://yqonvmuiezqvyqmexrft.supabase.co';
  static const String _anonKeyDefault =
      'sb_publishable_vTiAxBAhnZL_BqFcZD4m9A_Rb8Q8PHj';

  static const String baseUrl =
      String.fromEnvironment('VH_BASE_URL', defaultValue: _baseUrlDefault);

  static const String anonKey =
      String.fromEnvironment('VH_ANON_KEY', defaultValue: _anonKeyDefault);

  /// True when a real backend is reachable.
  ///
  /// When false the app uses the bundled demo repositories, which grant
  /// nothing: every playback request is refused. That is the correct
  /// fail-safe - a misconfigured build shows an empty-handed catalogue rather
  /// than quietly handing out content.
  static bool get isConfigured =>
      baseUrl.trim().isNotEmpty && anonKey.trim().isNotEmpty;

  /// How long any single request may take.
  ///
  /// Deliberately short. This app is used on Myanmar mobile networks, where a
  /// dead connection does not fail - it hangs. A request with no timeout is a
  /// spinner that never stops, which users read as the app being broken.
  static const Duration timeout = Duration(seconds: 20);

  /// Playback authorization is worth waiting a little longer for: the server
  /// has to check the subscription AND mint a signed URL.
  static const Duration playbackTimeout = Duration(seconds: 30);
}
