/// One rung of a video's streaming ladder, and the rule for picking one.
///
/// WHY THE CHOICE IS MADE HERE AND NOT ON THE SERVER. The one fact that
/// decides which copy of a film somebody should receive is what their
/// connection is delivering RIGHT NOW, and that exists only on their phone.
/// A server can guess from a country and be wrong about a person in a lift,
/// on a train, or sharing a tower with a stadium.
///
/// WHY IT IS A PURE FUNCTION IN ITS OWN FILE. This rule decides whether a
/// viewer sees a picture or a spinner, and it is the kind of arithmetic that
/// looks obviously right and is off by a factor of eight — bits against
/// bytes, kilo against kibi. It is testable here without a network, a player
/// or a device, and there is exactly one statement of it.
library;

class Rendition {
  const Rendition({
    required this.height,
    required this.kbps,
    required this.url,
    this.bytes,
  });

  /// The short side: 360, 480, 720, 1080, 2160.
  final int height;

  /// What this copy demands, in kilobits per second, measured from the
  /// encoded file rather than from what the encoder was asked for.
  final int kbps;

  final String url;
  final int? bytes;

  static Rendition? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final h = raw['height'];
    final k = raw['kbps'];
    if (url is! String || url.isEmpty) return null;
    if (h is! num || k is! num || k <= 0) return null;
    return Rendition(
      height: h.toInt(),
      kbps: k.toInt(),
      url: url,
      bytes: raw['bytes'] is num ? (raw['bytes'] as num).toInt() : null,
    );
  }
}

/// How much of the measured link a stream may ask for.
///
/// SIXTY PER CENT, AND THE MARGIN IS THE POINT. A stream needs its bitrate
/// delivered continuously, and a measurement is a snapshot of a link that is
/// about to pass a building, share a tower with someone else's video call,
/// or be interrupted by the phone's own background sync. Picking the rung
/// that exactly fits the measurement guarantees a stall on the first dip —
/// which is precisely the failure this whole ladder exists to end.
const double kBandwidthHeadroom = 0.6;

/// The rung to open with when nothing has ever been measured.
///
/// 720p rather than the best or the worst available. The worst insults a
/// viewer on fibre with a picture they did not need; the best hands someone
/// on a bus the stutter that started all of this. 720p is watchable on a
/// phone screen, and the first measurement arrives seconds later anyway.
const int kDefaultHeight = 720;

/// The tallest rung Auto picks while the data saver is on — YouTube's Data
/// saver tops out at 480p, and Netflix's "Save data" is SD. A viewer who
/// picks a height in the Quality menu still gets that height: the saver is a
/// ceiling on Auto, not on a choice somebody made by hand.
const int kDataSaverMaxHeight = 480;

/// Choose the rung to play.
///
/// [measuredKbps] is what the link last delivered, or null when nothing has
/// been measured yet. [ceilingKbps] caps the choice regardless — it is how a
/// downgrade after a stall is expressed, by passing the failing rung's
/// bitrate.
///
/// Returns null when there is no ladder, which the caller reads as "play the
/// original", and that is the honest answer for everything uploaded before
/// the pipeline existed.
Rendition? pickRendition(
  List<Rendition> ladder, {
  int? measuredKbps,
  int? ceilingKbps,
  int? maxHeight,
}) {
  if (ladder.isEmpty) return null;

  // Cheapest first, so "the last one that fits" is also the best one.
  var sorted = [...ladder]..sort((a, b) => a.kbps.compareTo(b.kbps));
  if (maxHeight != null) {
    // The data saver's ceiling. Every rung taller than it: the smallest is
    // the nearest thing to what was asked.
    final under = sorted.where((r) => r.height <= maxHeight).toList();
    sorted = under.isEmpty ? <Rendition>[sorted.first] : under;
  }

  Iterable<Rendition> allowed = sorted;
  if (ceilingKbps != null) {
    allowed = sorted.where((r) => r.kbps < ceilingKbps);
    // Everything is above the ceiling: the cheapest rung is the only honest
    // answer left. Returning null here would hand back the ORIGINAL, which
    // is the most expensive copy there is — the exact opposite of what a
    // downgrade means.
    if (allowed.isEmpty) return sorted.first;
  }

  if (measuredKbps == null || measuredKbps <= 0) {
    // No measurement: the rung nearest the default height, biased downwards.
    Rendition best = allowed.first;
    for (final r in allowed) {
      if (r.height <= kDefaultHeight) best = r;
    }
    return best;
  }

  final budget = measuredKbps * kBandwidthHeadroom;
  Rendition? fits;
  for (final r in allowed) {
    if (r.kbps <= budget) fits = r;
  }
  // Nothing fits the budget — the connection is worse than the smallest copy
  // we have. Send the smallest anyway: it is the best chance there is, and
  // refusing to play is not better than playing badly.
  return fits ?? allowed.first;
}

/// The viewer's own choice in the player's Quality menu.
///
/// 'auto' — the rule above, measured, stepping down on a stall.
/// 'original' — the file as it was uploaded, whatever the connection.
/// '720' (any height) — that rung, or the nearest one below it that exists.
class QualityChoice {
  QualityChoice._();
  static const String auto = 'auto';
  static const String original = 'original';

  /// Anything stored that this version cannot read is Auto, never an error.
  static String normalise(String? raw) {
    if (raw == null || raw.isEmpty) return auto;
    if (raw == auto || raw == original) return raw;
    final h = int.tryParse(raw);
    return h != null && h > 0 ? '$h' : auto;
  }
}

/// Which copy to play for [choice]. Null means the ORIGINAL.
///
/// A fixed height that this film does not have is answered with the nearest
/// rung BELOW it, the way YouTube does: somebody who chose 1080p on one film
/// and opens a 720p one wants the best there is, not a refusal; somebody who
/// chose 480p to save data must never be handed something heavier. When
/// every rung is above the choice, the smallest is the closest to what was
/// asked.
Rendition? chooseRendition(
  List<Rendition> ladder,
  String choice, {
  int? measuredKbps,
  int? ceilingKbps,
  int? maxHeight,
}) {
  final c = QualityChoice.normalise(choice);
  if (c == QualityChoice.auto) {
    return pickRendition(ladder,
        measuredKbps: measuredKbps,
        ceilingKbps: ceilingKbps,
        maxHeight: maxHeight);
  }
  if (c == QualityChoice.original || ladder.isEmpty) return null;
  final want = int.parse(c);
  final byHeight = [...ladder]..sort((a, b) => a.height.compareTo(b.height));
  Rendition? below;
  for (final r in byHeight) {
    if (r.height <= want) below = r;
  }
  return below ?? byHeight.first;
}

/// The menu for a film with this [ladder]: Auto, each rung from the
/// highest down, and the original. EMPTY when there is no ladder — a film
/// with one copy has nothing to choose between, and a menu with a single
/// line is a control that does nothing.
///
/// [originalHeight] is the master's short side when known, shown as '4K' /
/// '1080p' beside "Original" so the choice says what it costs.
List<({String id, String label, String? detail})> qualityMenuFor(
  List<Rendition> ladder, {
  int? originalHeight,
}) {
  if (ladder.isEmpty) return const [];
  final seen = <int>{};
  final rungs = [...ladder]..sort((a, b) => b.height.compareTo(a.height));
  final out = <({String id, String label, String? detail})>[
    (id: QualityChoice.auto, label: 'Auto', detail: null),
  ];
  for (final r in rungs) {
    if (!seen.add(r.height)) continue;
    out.add((id: '${r.height}', label: '${r.height}p', detail: _mbps(r.kbps)));
  }
  out.add((
    id: QualityChoice.original,
    label: 'Original',
    detail: originalHeight == null || originalHeight <= 0
        ? null
        : heightLabel(originalHeight),
  ));
  return out;
}

/// '4K', '1440p', '1080p' — what people call a short side.
String heightLabel(int h) => h >= 2000 ? '4K' : h >= 1400 ? '1440p' : '${h}p';

String _mbps(int kbps) =>
    kbps >= 1000 ? '${(kbps / 1000).toStringAsFixed(1)} Mbps' : '$kbps kbps';
