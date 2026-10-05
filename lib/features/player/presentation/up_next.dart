/// What plays after the current video, handed to the player by whoever
/// opened it (the Movies feature: the next clip of an album or series).
///
/// THE PLAYER DOES NOT KNOW WHAT A TITLE IS, and this keeps it so: it learns
/// a name to show and a function to call. It is the same seam as
/// StreamRenewal and QualityMenu — keyed on the URI the player was opened
/// with, so an offer can never be applied to another video.
class UpNextOffer {
  const UpNextOffer({required this.title, required this.play});

  /// Shown on the card: "Up next · <title>".
  final String title;

  /// Opens it. Called after the player has closed.
  final Future<void> Function() play;
}

class UpNext {
  UpNext._();

  static String? _uri;
  static UpNextOffer? _offer;

  /// Videos started by the countdown in a row, with nobody touching the
  /// phone. After [askAfter] the next one waits for a tap ("Still
  /// watching?"), as Netflix asks after three episodes: autoplay should
  /// serve someone watching, not run on for someone who fell asleep —
  /// burning their data and the night.
  static int _unattended = 0;
  static const int askAfter = 3;

  static void register(String uri, UpNextOffer? offer) {
    _uri = offer == null ? null : uri;
    _offer = offer;
  }

  static UpNextOffer? offerFor(String? uri) =>
      uri != null && uri == _uri ? _offer : null;

  /// Takes the offer for [uri] out, so it is used once.
  static UpNextOffer? take(String? uri) {
    final o = offerFor(uri);
    if (o != null) {
      _uri = null;
      _offer = null;
    }
    return o;
  }

  static bool get askStillWatching => _unattended >= askAfter;

  /// The countdown ran out and started the next video by itself.
  static void noteUnattended() => _unattended++;

  /// Somebody chose: Play now, Keep watching, or any open from a screen.
  static void noteChosen() => _unattended = 0;
}
