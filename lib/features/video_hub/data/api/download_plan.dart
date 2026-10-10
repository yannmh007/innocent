/// The three decisions an offline download has to make, as pure functions.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THESE ARE NOT INLINE IN THE DOWNLOADER
/// ═══════════════════════════════════════════════════════════════════════
///
/// Each of them was wrong, in a way that only shows up on the connection this
/// feature exists for — a Myanmar mobile link that drops every few minutes —
/// and none of them could be tested where they were. A wrong answer here does
/// not throw; it spends somebody's data allowance and produces a file that
/// says "downloaded" and plays as garbage. That is worth a file with tests.
library;

import '../../domain/rendition.dart';

/// How long to wait before trying again after a failure.
///
/// ─── THE BUG ────────────────────────────────────────────────────────────
///
/// There was no wait at all. The resume loop did `continue` on a network
/// error, so twenty attempts were spent in about a second — each one a fresh
/// `requestPlayback` call to the server — and the download then reported
/// `gave_up`. A ten-second tunnel was enough to end a download that had
/// forty minutes of progress on disk. The user saw a failure they could not
/// explain on a connection that came back moments later.
///
/// Doubling from two seconds to a one-minute ceiling covers the real shapes:
/// a lift or a tunnel is over inside the first few steps, and a link that is
/// down for an hour is retried sixty times rather than thousands. [attempt]
/// is the count of CONSECUTIVE failures and is 1-based; zero or less means no
/// failure has happened and there is nothing to wait for.
Duration retryDelay(int attempt) {
  if (attempt <= 0) return Duration.zero;
  if (attempt >= 6) return const Duration(seconds: 60);
  return Duration(seconds: 1 << attempt); // 2, 4, 8, 16, 32
}

/// What to do with the bytes already on disk.
enum ResumePlan {
  /// Append to what is there.
  keep,

  /// Throw it away and start from zero.
  restart,
}

/// Whether a part-file can still be appended to.
///
/// ─── THE BUG ────────────────────────────────────────────────────────────
///
/// Nothing checked. A resume sent `Range: bytes=N-` and appended whatever came
/// back, so if the operator had replaced the film behind the same key — a
/// re-encode, a fixed audio track, a different cut — the finished file was the
/// first N bytes of the old object followed by the rest of the new one. It
/// passed the length check, the shelf said "downloaded", and it played until
/// the seam. On a connection where the download took two hours, that is two
/// hours and a gigabyte of data for a file that has to be deleted.
///
/// [expectedTotal] is the object length recorded when the download began,
/// [freshTotal] the length the server is reporting now. They disagreeing is
/// the only cheap evidence available that the object is not the same one, and
/// it is enough: an encode that produces a byte-identical length is not a
/// different encode in any way that matters here.
ResumePlan planResume({
  required int onDisk,
  required int? expectedTotal,
  required int? freshTotal,
}) {
  // Nothing on disk is not a resume at all, and there is nothing to lose.
  if (onDisk <= 0) return ResumePlan.keep;
  // The object changed length. Everything on disk belongs to the old one.
  if (expectedTotal != null &&
      freshTotal != null &&
      expectedTotal != freshTotal) {
    return ResumePlan.restart;
  }
  // More on disk than the whole object: a previous run appended twice, or the
  // object shrank. Either way the file is not a prefix of anything.
  if (freshTotal != null && onDisk > freshTotal) return ResumePlan.restart;
  if (expectedTotal != null && onDisk > expectedTotal) return ResumePlan.restart;
  return ResumePlan.keep;
}

/// Free space to leave behind after a download finishes.
///
/// A phone with nothing free does not merely fail the next download: it
/// cannot take a photo, cannot update an app, and Android begins deleting
/// app caches to cope. Reserving a quarter of a gigabyte means a film that
/// only just fits is refused before it starts rather than filling the device
/// on the viewer's behalf.
const int kDownloadHeadroomBytes = 256 * 1024 * 1024;

/// Whether a download of [totalBytes] should be started or continued.
///
/// ─── THE BUG ────────────────────────────────────────────────────────────
///
/// Nothing looked at free space. A 900 MB film on a phone with 300 MB free
/// downloaded 300 MB — three hundred megabytes of a metered connection, paid
/// for — and then failed on a full disk with `gave_up`, which says nothing
/// about the actual reason and invites the viewer to try again and spend it
/// twice.
///
/// [freeBytes] is what the platform reported, and a NEGATIVE value means it
/// did not answer. That is not permission: a feature that can fill a phone
/// does not proceed on an unanswered question. [alreadyOnDisk] is the part
/// file, which does not have to be found again.
bool hasRoomFor({
  required int freeBytes,
  required int totalBytes,
  int alreadyOnDisk = 0,
}) {
  if (freeBytes < 0) return false;
  if (totalBytes <= 0) return true; // Nothing claimed; nothing to refuse.
  final remaining = totalBytes - alreadyOnDisk;
  if (remaining <= 0) return true;
  return freeBytes >= remaining + kDownloadHeadroomBytes;
}

/// WHICH COPY A DOWNLOAD FETCHES — the viewer's standing answer.
///
/// ─── WHY THIS IS A CHOICE NOW ───────────────────────────────────────────
///
/// A download used to be the original and nothing else, on the reasoning that
/// somebody who waits an hour wants the film as it was uploaded. For some of
/// them that is true. For the viewer on a 3 GB data bundle and a 32 GB phone
/// it is the opposite: Sintel's original is 1.1 GB and its 720p copy 187 MB,
/// the same story at a size they can afford. Netflix asks (Standard or
/// Higher), YouTube asks (by resolution, with sizes, "remember my settings").
/// So does this — and the ORIGINAL stays the default for anyone who never
/// answers, so nothing changes for a viewer who does not look.
///
/// `ask` shows the choice each time; `original` or a height ('720') is
/// remembered and used without asking.
class DownloadQuality {
  DownloadQuality._();

  static const String ask = 'ask';
  static const String original = 'original';

  /// Anything this version cannot read is [ask]: a stored value from a later
  /// version must never silently become a smaller download.
  static String normalise(String? raw) {
    if (raw == null || raw.isEmpty) return ask;
    if (raw == ask || raw == original) return raw;
    final h = int.tryParse(raw);
    return h != null && h > 0 ? '$h' : ask;
  }

  /// What one download actually asks for: never [ask] — a download in
  /// progress has already been answered, and an unanswered one is the
  /// original.
  static String forDownload(String? raw) {
    final q = normalise(raw);
    return q == ask ? original : q;
  }
}

/// The address a download fetches for [quality], and the height it is.
///
/// [originalUrl] is the grant's own URL, signed from the ORIGINAL object;
/// [ladder] its streaming copies. A height means that rung or the nearest one
/// BELOW it (somebody who chose 480p to save data is never handed 720p); a
/// film with no ladder is the original whatever was chosen, because there is
/// nothing smaller to give. `height` is null for the original.
///
/// DETERMINISTIC FOR A GIVEN LADDER, which is what makes a resume safe: every
/// renewal of a two-hour download asks again and must land on the SAME file,
/// or the part on disk and the bytes appended to it belong to two encodes.
/// (The length check in [planResume] is the second line of defence.)
({String? url, int? height}) downloadSource({
  required String? originalUrl,
  required List<Rendition> ladder,
  required String quality,
}) {
  final q = DownloadQuality.forDownload(quality);
  if (q == DownloadQuality.original || ladder.isEmpty) {
    return (url: originalUrl, height: null);
  }
  final r = chooseRendition(ladder, q);
  if (r == null) return (url: originalUrl, height: null);
  return (url: r.url, height: r.height);
}

/// One line of the "which quality" sheet.
typedef DownloadOption = ({String id, int? height, int? bytes});

/// The lines of the sheet, best first: every rung once (by height, the
/// smaller file when two share a height), then the original. EMPTY when there
/// is no ladder — one copy is no choice, and the sheet is not shown.
List<DownloadOption> downloadOptions(List<Rendition> ladder,
    {int? originalBytes}) {
  if (ladder.isEmpty) return const <DownloadOption>[];
  final byHeight = <int, Rendition>{};
  for (final r in ladder) {
    final had = byHeight[r.height];
    if (had == null || (r.bytes ?? 1 << 62) < (had.bytes ?? 1 << 62)) {
      byHeight[r.height] = r;
    }
  }
  final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
  return <DownloadOption>[
    for (final h in heights)
      (id: '$h', height: h, bytes: byHeight[h]!.bytes),
    (id: DownloadQuality.original, height: null, bytes: originalBytes),
  ];
}
