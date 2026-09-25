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
