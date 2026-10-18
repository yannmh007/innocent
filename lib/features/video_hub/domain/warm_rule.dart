/// Whether to fetch a film's opening before Play is pressed — the warm start
/// (`StreamCacheServer.warmOpening`).
///
/// WHY IT IS ASKED AT ALL. TikTok and YouTube start a video the instant it
/// is tapped because its first seconds are already on the phone. Here that
/// means fetching a couple of megabytes of the film whose page the viewer is
/// looking at, before they decide to watch it.
///
/// WHY THE ANSWER IS USUALLY NO. Those megabytes are the viewer's data, spent
/// on a film they have not chosen. So a warm-up happens only when it costs
/// them nothing they would notice:
///
///   * not offline — there is nothing to fetch from;
///   * not on a metered line — mobile data is somebody's money, and the
///     saver they did not switch on is no permission to spend it;
///   * not with the data saver on — they asked for exactly this not to
///     happen;
///   * not when the film is already on the phone — Play opens the download
///     and never reads the stream.
///
/// Whether another film is playing is the cache server's own check, made at
/// the moment it would start: that line is never taken.
///
/// PURE, AND IN ITS OWN FILE, so the rule is one statement that a test can
/// hold to, without a network, a player or a device.
library;

bool warmAllowed({
  required bool offline,
  required bool metered,
  required bool dataSaver,
  required bool heldOnPhone,
}) =>
    !offline && !metered && !dataSaver && !heldOnPhone;
