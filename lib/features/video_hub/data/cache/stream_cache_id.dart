import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The stable name a cached film is filed under.
///
/// WHY IT IS DERIVED AND NOT HANDED OVER. The client is deliberately never
/// told the object key — that was the whole point of moving playback off
/// signed S3 URLs, which spelled out the account, the bucket and the folder
/// scheme. So the id is built from what the client legitimately knows: which
/// title, which asset inside it, and which rung of the ladder. Those three
/// identify one file in the bucket exactly, and they say nothing about where
/// it lives.
///
/// HASHED RATHER THAN CONCATENATED so the cache directory carries no title
/// ids either. A directory listing of somebody's phone should not be a list
/// of what they have watched.
///
/// WHAT HAPPENS IF THE OPERATOR REPLACES A FILE. The id does not change —
/// the title and the rung are the same — so a stale copy could in principle
/// be served. It cannot in practice: the store compares the object's total
/// length on every open and discards the entry when it differs, and two
/// different videos with byte-identical lengths do not occur. This is
/// written down because it is the one assumption this scheme rests on.
String streamCacheId({
  required String titleId,
  String? assetId,
  int height = 0,
}) {
  final raw = '$titleId/${assetId ?? 'main'}/${height}p';
  return sha256.convert(utf8.encode(raw)).toString().substring(0, 32);
}

/// The rung heights `tool/transcode.sh` produces, plus 0 for the original.
///
/// WHY THE CLIENT HAS TO KNOW THEM. A cache id is a hash of the title, the
/// asset and the rung, which is what keeps a directory listing from being a
/// list of what somebody has watched — and it also means the mapping only goes
/// one way. Online that is fine: the rung is chosen before anything is cached.
/// OFFLINE THERE IS NOBODY TO ASK WHICH RUNG WAS PLAYED, so the only way to
/// find what is on disk is to compute every id it could have been and look for
/// those. Seven hashes is nothing; the alternative was writing the title id
/// into the cache directory, which is the property this scheme exists to keep.
///
/// `LADDER_H` in `tool/transcode.sh` is the original, and
/// `tool/security_invariants.py` rule 12 fails the build if the two disagree.
/// Out of step, the cost is small and self-healing: a rung missing from here
/// simply cannot be found offline, and nothing plays that should not.
const List<int> kStreamCacheRungs = <int>[0, 360, 480, 720, 1080, 1440, 2160];

/// Every id the given title and asset could have been cached under.
///
/// Order is the ladder's, so a caller that wants the best copy first can
/// reverse it — but the one that matters is "which of these actually has bytes",
/// which only the store can answer.
List<String> streamCacheCandidates({
  required String titleId,
  String? assetId,
}) {
  return <String>[
    for (final h in kStreamCacheRungs)
      streamCacheId(titleId: titleId, assetId: assetId, height: h),
  ];
}
