/// One way to print a number of bytes, for every screen that shows one.
///
/// There were three, and they disagreed: the shelf rounded megabytes to whole
/// numbers, the cache screen used one decimal, and the download dialog had
/// none at all. The same 1.47 GB film read as "1.5 GB", "1505 MB" and "1 GB"
/// on three screens of one app, which makes a viewer deciding whether to spend
/// their data allowance trust none of them.
///
/// GIGABYTES CARRY A DECIMAL AND MEGABYTES DO NOT. The difference between
/// 1.4 GB and 1.9 GB is half an hour of somebody's evening and a third of a
/// data bundle; the difference between 412 MB and 413 MB is nothing anyone
/// can act on.
library;

/// Binary units, because that is what the filesystem and the phone's own
/// storage screen count in — showing 1.9 GB beside Android's 1.8 GB for the
/// same file invites the conclusion that one of them is lying.
String formatBytes(int bytes) {
  if (bytes < 0) return '0 MB';
  const kb = 1024;
  const mb = 1024 * kb;
  const gb = 1024 * mb;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}
