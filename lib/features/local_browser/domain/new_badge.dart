import 'video.dart';

/// The "NEW" tag rule, in one place.
///
/// MX Player documents this exactly, in its own FAQ, and it is worth quoting
/// because half of it was missing here:
///
/// > NEW: Copied or modified files within 7 days, **which have no playback
/// > record**. (Display period can be changed in Settings → List → 'New'
/// > tagged period)
///
/// So the tag is the AND of two conditions, and the badge disappears the
/// moment either one stops holding:
///
///  1. the file arrived or changed recently — within the user's chosen window,
///     seven days by default; and
///  2. the app has no record of it ever being played.
///
/// The second condition was not implemented, which is why a video kept its
/// NEW tag for a week after being watched. It is also why MX Player's FAQ
/// warns that the tag can come back: the record, not the file, is what clears
/// it, so uninstalling the app or using "Clear history" makes previously
/// watched files look new again. That behaviour falls out of this rule
/// naturally and is the correct thing to inherit — the badge means "you have
/// not watched this", and if the app genuinely no longer knows, saying so is
/// more honest than pretending otherwise.
///
/// Both halves matter on their own. Without the time window, every file you
/// have never opened is permanently tagged and the tag means nothing; without
/// the playback check, the tag survives being watched, which is what makes it
/// feel broken.
class NewBadge {
  const NewBadge._();

  /// Whether [video] should carry the NEW tag right now.
  ///
  /// [periodDays] comes from `IntSetting.newTaggedPeriod` (0–90, default 7).
  /// Zero switches the tag off entirely, which is the documented way to
  /// disable it.
  ///
  /// [playedUris] must contain NORMALISED uris — see `normalizeMediaUri` in
  /// user_data_providers.dart. History entries and library entries spell the
  /// same file differently often enough (`file://` prefix, trailing slashes)
  /// that comparing raw strings silently fails to match, which would leave the
  /// tag on a watched video and look exactly like the bug this replaces.
  static bool applies({
    required Video video,
    required int periodDays,
    required Set<String> playedUris,
    required String Function(String) normalize,
    DateTime? now,
  }) {
    if (periodDays <= 0) return false;
    final arrived = video.freshestDate;
    if (arrived == null) return false;
    final at = now ?? DateTime.now();
    // A file dated in the future (bad clock, or a copy that preserved a
    // timestamp from a machine running fast) is treated as brand new rather
    // than as "negative days old", which would otherwise fail the test below
    // and hide the tag on exactly the freshly-copied files it exists for.
    final age = at.difference(arrived);
    if (!age.isNegative && age.inDays >= periodDays) return false;
    return !playedUris.contains(normalize(video.uri));
  }

  /// How many videos in [videos] currently qualify. Used for the count bubble
  /// on folder tiles, which is the same rule applied to a folder's contents.
  static int countIn({
    required Iterable<Video> videos,
    required int periodDays,
    required Set<String> playedUris,
    required String Function(String) normalize,
    DateTime? now,
  }) {
    if (periodDays <= 0) return 0;
    final at = now ?? DateTime.now();
    var n = 0;
    for (final v in videos) {
      if (applies(
        video: v,
        periodDays: periodDays,
        playedUris: playedUris,
        normalize: normalize,
        now: at,
      )) {
        n++;
      }
    }
    return n;
  }
}
