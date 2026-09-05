import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

class LyricLine {
  final Duration? timestamp;
  final String text;
  const LyricLine({this.timestamp, required this.text});
}

/// Audit fix (real feature, was a fake "No lyrics available" snackbar):
/// offline lyrics reader. Looks for a sidecar `.lrc` file next to the
/// audio file — convention every major desktop player supports.
class LrcLyricsService {
  Future<List<LyricLine>?> readFor(String audioUri) async {
    if (kIsWeb) return null;
    try {
      if (!audioUri.startsWith('/') && !audioUri.startsWith('file://')) {
        return null;
      }
      final audioPath = audioUri.startsWith('file://')
          ? Uri.parse(audioUri).toFilePath()
          : audioUri;
      final dir = p.dirname(audioPath);
      final base = p.basenameWithoutExtension(audioPath);
      for (final ext in ['.lrc', '.LRC']) {
        final candidate = File(p.join(dir, '$base$ext'));
        if (await candidate.exists()) {
          final raw = await candidate.readAsString();
          final lines = _parse(raw);
          if (lines.isNotEmpty) return lines;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static List<LyricLine> _parse(String raw) {
    final out = <LyricLine>[];
    final tsPat = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?\]');
    final tagPat = RegExp(r'^\[[a-zA-Z]+:[^\]]*\]$');

    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (tagPat.hasMatch(line.trim())) continue;
      final matches = tsPat.allMatches(line).toList();
      if (matches.isEmpty) {
        out.add(LyricLine(text: line.trim()));
        continue;
      }
      int textStart = 0;
      for (final m in matches) {
        if (m.start == textStart) {
          textStart = m.end;
        } else {
          break;
        }
      }
      final text = line.substring(textStart).trim();
      if (text.isEmpty) continue;
      for (final m in matches.takeWhile((m) => m.start < textStart)) {
        final mins = int.tryParse(m.group(1) ?? '') ?? 0;
        final secs = int.tryParse(m.group(2) ?? '') ?? 0;
        final fracStr = m.group(3) ?? '0';
        int ms;
        if (fracStr.length == 1) {
          ms = int.parse(fracStr) * 100;
        } else if (fracStr.length == 2) {
          ms = int.parse(fracStr) * 10;
        } else {
          ms = int.parse(fracStr);
        }
        out.add(LyricLine(
          timestamp: Duration(
              minutes: mins, seconds: secs, milliseconds: ms),
          text: text,
        ));
      }
    }
    final synced = out.where((l) => l.timestamp != null).toList()
      ..sort((a, b) => a.timestamp!.compareTo(b.timestamp!));
    final unsynced = out.where((l) => l.timestamp == null).toList();
    return [...unsynced, ...synced];
  }
}

final lrcLyricsServiceProvider = Provider<LrcLyricsService>((ref) {
  return LrcLyricsService();
});

final lyricsForSongProvider =
    FutureProvider.family<List<LyricLine>?, String>((ref, uri) async {
  final svc = ref.watch(lrcLyricsServiceProvider);
  return svc.readFor(uri);
});
