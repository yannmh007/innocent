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
