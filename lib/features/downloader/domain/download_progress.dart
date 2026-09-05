import 'package:flutter/foundation.dart';

/// One parsed progress line.
///
/// The engine hands us a raw stdout line plus a percentage float. That float is
/// enough for a bar and nothing else, and it is not even reliable: when aria2c
/// is doing the fetching, yt-dlp's own progress hooks never fire, so the float
/// sits at zero for the entire download while aria2c prints its own perfectly
/// good numbers to the same stream. Every downloader worth using shows total
/// size, live speed and time remaining, so we read them out of the line.
///
/// Two shapes have to be handled:
///
///   yt-dlp: `[download]  45.2% of ~ 123.45MiB at 2.34MiB/s ETA 00:32 (frag 12/300)`
///   aria2c: `[#8697a3 15MiB/100MiB(15%) CN:4 DL:2.5MiB ETA:34s]`
@immutable
class DownloadProgress {
  const DownloadProgress({
    this.percent,
    this.totalBytes,
    this.bytesPerSecond,
    this.etaSeconds,
    this.fragmentIndex,
    this.fragmentCount,
  });

  final double? percent;
  final int? totalBytes;
  final double? bytesPerSecond;
  final int? etaSeconds;
  final int? fragmentIndex;
  final int? fragmentCount;

  bool get isEmpty =>
      percent == null &&
      totalBytes == null &&
      bytesPerSecond == null &&
      etaSeconds == null;

  /// Keeps the last known value for anything this line didn't mention, so the
  /// row doesn't flicker between "2.3 MB/s" and blank on lines that happen to
  /// omit the speed.
  DownloadProgress mergeOnto(DownloadProgress? previous) {
    if (previous == null) return this;
    return DownloadProgress(
      percent: percent ?? previous.percent,
      totalBytes: totalBytes ?? previous.totalBytes,
      bytesPerSecond: bytesPerSecond ?? previous.bytesPerSecond,
      etaSeconds: etaSeconds ?? previous.etaSeconds,
      fragmentIndex: fragmentIndex ?? previous.fragmentIndex,
      fragmentCount: fragmentCount ?? previous.fragmentCount,
    );
  }
}

/// Multiplier for a yt-dlp / aria2c size suffix. Both tools print binary units
/// (MiB), and both are sometimes built to print the decimal spelling (MB) for
/// the same quantity, so the two are treated the same on purpose.
int _unitScale(String unit) {
  switch (unit.toLowerCase().replaceAll('i', '')) {
    case 'kb':
      return 1024;
    case 'mb':
      return 1024 * 1024;
    case 'gb':
      return 1024 * 1024 * 1024;
    case 'tb':
      return 1024 * 1024 * 1024 * 1024;
    default:
      return 1;
  }
}

final RegExp _percentRe = RegExp(r'(\d+(?:\.\d+)?)\s*%');
final RegExp _ytTotalRe =
    RegExp(r'of\s*~?\s*(\d+(?:\.\d+)?)\s*([KMGT]?i?B)', caseSensitive: false);
final RegExp _ytSpeedRe =
    RegExp(r'at\s+(\d+(?:\.\d+)?)\s*([KMGT]?i?B)/s', caseSensitive: false);
final RegExp _ytEtaRe = RegExp(r'ETA\s+(\d{1,2}):(\d{2})(?::(\d{2}))?');
final RegExp _fragRe = RegExp(r'frag\s+(\d+)/(\d+)');
final RegExp _ariaTotalRe = RegExp(
    r'\d+(?:\.\d+)?[KMGT]?i?B/(\d+(?:\.\d+)?)\s*([KMGT]?i?B)\s*\(',
    caseSensitive: false);
final RegExp _ariaSpeedRe =
    RegExp(r'DL:\s*(\d+(?:\.\d+)?)\s*([KMGT]?i?B)', caseSensitive: false);
final RegExp _ariaEtaRe = RegExp(r'ETA:\s*(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?');

/// Returns null when the line carries nothing useful (most of them don't —
/// yt-dlp also logs destinations, merges and warnings on this stream).
DownloadProgress? parseProgressLine(String raw) {
  final String line = raw.trim();
  if (line.isEmpty) return null;

  double? percent;
  int? total;
  double? speed;
  int? eta;
  int? fragIndex;
  int? fragCount;

  final Match? pm = _percentRe.firstMatch(line);
  if (pm != null) {
    final double? value = double.tryParse(pm.group(1)!);
    if (value != null && value >= 0 && value <= 100) percent = value;
  }

  // yt-dlp shape first; aria2c's own numbers are the fallback.
  final Match? tm = _ytTotalRe.firstMatch(line) ?? _ariaTotalRe.firstMatch(line);
  if (tm != null) {
    final double? value = double.tryParse(tm.group(1)!);
    if (value != null && value > 0) {
      total = (value * _unitScale(tm.group(2)!)).round();
    }
  }

  final Match? sm = _ytSpeedRe.firstMatch(line) ?? _ariaSpeedRe.firstMatch(line);
  if (sm != null) {
    final double? value = double.tryParse(sm.group(1)!);
    if (value != null && value >= 0) {
      speed = value * _unitScale(sm.group(2)!);
    }
  }

  final Match? em = _ytEtaRe.firstMatch(line);
  if (em != null) {
    final int a = int.tryParse(em.group(1)!) ?? 0;
    final int b = int.tryParse(em.group(2)!) ?? 0;
    final String? c = em.group(3);
    // "01:02:11" is h:m:s; "00:32" is m:s.
    eta = c != null
        ? a * 3600 + b * 60 + (int.tryParse(c) ?? 0)
        : a * 60 + b;
  } else {
    final Match? am = _ariaEtaRe.firstMatch(line);
    if (am != null &&
        (am.group(1) != null || am.group(2) != null || am.group(3) != null)) {
      eta = (int.tryParse(am.group(1) ?? '0') ?? 0) * 3600 +
          (int.tryParse(am.group(2) ?? '0') ?? 0) * 60 +
          (int.tryParse(am.group(3) ?? '0') ?? 0);
    }
  }

  final Match? fm = _fragRe.firstMatch(line);
  if (fm != null) {
    fragIndex = int.tryParse(fm.group(1)!);
    fragCount = int.tryParse(fm.group(2)!);
  }

  final DownloadProgress parsed = DownloadProgress(
    percent: percent,
    totalBytes: total,
    bytesPerSecond: speed,
    etaSeconds: eta,
    fragmentIndex: fragIndex,
    fragmentCount: fragCount,
  );
  return parsed.isEmpty ? null : parsed;
}

/// "2.3 MB/s".
String formatSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '';
  const List<String> units = <String>['B/s', 'KB/s', 'MB/s', 'GB/s'];
  double value = bytesPerSecond;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final String text =
      (unit >= 2 && value < 100) ? value.toStringAsFixed(1) : value.round().toString();
  return '$text ${units[unit]}';
}

/// "32s", "5m 12s", "1h 04m" — never a bare "00:04:03", which reads as a
/// timestamp rather than a countdown.
String formatEta(int? seconds) {
  if (seconds == null || seconds <= 0) return '';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }
  final int h = seconds ~/ 3600;
  final int m = (seconds % 3600) ~/ 60;
  return m == 0 ? '${h}h' : '${h}h ${m.toString().padLeft(2, '0')}m';
}
