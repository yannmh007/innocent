import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One file this phone received.
class ReceivedItem {
  final String name;
  final String path;
  final int sizeBytes;
  final String? senderName;
  final DateTime receivedAt;

  const ReceivedItem({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.receivedAt,
    this.senderName,
  });

  Map<String, dynamic> toJson() => {
        'n': name,
        'p': path,
        's': sizeBytes,
        'f': senderName,
        't': receivedAt.millisecondsSinceEpoch,
      };

  factory ReceivedItem.fromJson(Map<String, dynamic> j) => ReceivedItem(
        name: j['n'] as String? ?? 'file',
        path: j['p'] as String? ?? '',
        sizeBytes: (j['s'] as num?)?.toInt() ?? 0,
        senderName: j['f'] as String?,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['t'] as num?)?.toInt() ?? 0),
      );
}

/// History of received files.
///
/// WHY IT EXISTS: a transfer used to vanish the moment the pane was closed.
/// Files landed in Innocent/Videos (or Photos, or Others) and the user had to
/// go hunting in a file manager to find what they had just been sent — which
/// is exactly the moment a share app either feels finished or doesn't.
///
/// Deliberately capped and deliberately cheap: [_maxItems] entries, one
/// SharedPreferences string, written once per batch rather than once per file.
/// The file itself is the source of truth; this list is only a pointer to it,
/// so an entry whose file has been deleted is shown as missing rather than
/// silently opening nothing.
class ReceivedHistoryNotifier extends StateNotifier<List<ReceivedItem>> {
  ReceivedHistoryNotifier() : super(const []) {
    _load();
  }

  static const String _key = 'transfer_received_history_v1';
  static const int _maxItems = 200;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List)
          .map((e) => ReceivedItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      state = list;
    } catch (e) {
      if (kDebugMode) debugPrint('ReceivedHistory.load: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode([for (final i in state) i.toJson()]));
    } catch (e) {
      if (kDebugMode) debugPrint('ReceivedHistory.persist: $e');
    }
  }

  /// Record a finished batch. One write, newest first, oldest trimmed.
  Future<void> addAll(List<ReceivedItem> items) async {
    if (items.isEmpty) return;
    // Re-receiving a file writes a new path (the "-<timestamp>" copy), so key
    // on the path rather than the name — two different files can share a name.
    final existing = state.map((e) => e.path).toSet();
    final fresh = items.where((i) => !existing.contains(i.path)).toList();
    if (fresh.isEmpty) return;
    final merged = [...fresh.reversed, ...state];
    state = merged.length > _maxItems
        ? merged.sublist(0, _maxItems)
        : merged;
    await _persist();
  }

  Future<void> remove(String path) async {
    state = state.where((e) => e.path != path).toList();
    await _persist();
  }

  Future<void> clear() async {
    state = const [];
    await _persist();
  }

  static const MethodChannel _channel =
      MethodChannel('mx_clone/transfer_service');

  /// Hand a received file to whichever app owns it.
  ///
  /// Returns false when nothing on the phone can open that type, which the UI
  /// turns into a sentence instead of a silent no-op. An APK goes to the
  /// package installer — that is the flow this whole feature exists for in
  /// this market: someone hands you the app over Wi-Fi and you install it.
  static Future<bool> openExternally(String path) async {
    if (kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openFile', {'path': path});
      return ok == true;
    } catch (e) {
      if (kDebugMode) debugPrint('ReceivedHistory.openExternally: $e');
      return false;
    }
  }

  /// Android 8+ gates sideloading behind a per-app switch. Checking first
  /// means we can explain, rather than dropping the user on a system screen.
  static Future<bool> canInstallApks() async {
    if (kIsWeb) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('canInstallApks');
      return ok == true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> openInstallPermission() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('openInstallPermission');
    } catch (_) {}
  }

  /// True when the file is still where we left it. Checked on tap, because a
  /// user can delete a received file from any file manager and an entry that
  /// opens a black player screen is worse than an honest "it's gone".
  static Future<bool> stillExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }
}

final receivedHistoryProvider =
    StateNotifierProvider<ReceivedHistoryNotifier, List<ReceivedItem>>(
        (ref) => ReceivedHistoryNotifier());
