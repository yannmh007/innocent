import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/adb/adb_service.dart';

/// WHICH FOLDERS THE VIDEO TAB SHOWS.
///
/// Folders inside Android/data come from the last ADB scan and stay in the
/// Video tab after the connection drops — useful for some, clutter for
/// others, who saw a Telegram cache folder they could not open sitting among
/// their own folders for good. MX Player's answer, and this one: a folder
/// can be HIDDEN (select it → Hide) and shown again from one list
/// (⋮ → Show / hide folders) — and Android/data's folders can be shown only
/// while ADB is connected.
///
/// A hidden folder is a rule about the folder, not about the files in it:
/// a video added to it later stays hidden too, and nothing on the phone is
/// moved, renamed or deleted. (Hide used to send each video to the Recycle
/// Bin one by one, which an Android/data folder could not even do — its
/// videos are not in the device library, so it said "no files".)
@immutable
class FolderVisibility {
  const FolderVisibility({
    this.hidden = const <String>{},
    this.appFoldersOnlyWhileConnected = false,
  });

  /// Paths of hidden folders, exactly as [Folder.path] / [Video.folderPath].
  final Set<String> hidden;

  /// Android/data folders show only while the ADB connection is up.
  final bool appFoldersOnlyWhileConnected;

  bool isHidden(String folderPath) => hidden.contains(folderPath);

  FolderVisibility copyWith({
    Set<String>? hidden,
    bool? appFoldersOnlyWhileConnected,
  }) =>
      FolderVisibility(
        hidden: hidden ?? this.hidden,
        appFoldersOnlyWhileConnected:
            appFoldersOnlyWhileConnected ?? this.appFoldersOnlyWhileConnected,
      );
}

/// True for a folder inside an app's private storage (Android/data or
/// Android/obb), which only an ADB scan can list.
bool isAppDataFolder(String path) =>
    path.contains('/Android/data/') || path.contains('/Android/obb/');

class FolderVisibilityNotifier extends StateNotifier<FolderVisibility> {
  FolderVisibilityNotifier() : super(const FolderVisibility()) {
    unawaited(_load());
  }

  static const String hiddenKey = 'video_tab_hidden_folders';
  static const String onlyWhileConnectedKey =
      'video_tab_app_folders_only_while_connected';

  // A change made before the saved state has loaded must not be overwritten
  // by it.
  bool _touched = false;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_touched || !mounted) return;
      state = FolderVisibility(
        hidden: (prefs.getStringList(hiddenKey) ?? const <String>[]).toSet(),
        appFoldersOnlyWhileConnected:
            prefs.getBool(onlyWhileConnectedKey) ?? false,
      );
    } catch (_) {
      // Nothing saved can be read: every folder shows, as before.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(hiddenKey, state.hidden.toList()..sort());
      await prefs.setBool(
          onlyWhileConnectedKey, state.appFoldersOnlyWhileConnected);
    } catch (_) {
      // Kept for this session; the next change tries to save again.
    }
  }

  Future<void> hide(Iterable<String> paths) async {
    _touched = true;
    state = state.copyWith(hidden: <String>{...state.hidden, ...paths});
    await _save();
  }

  Future<void> show(Iterable<String> paths) async {
    _touched = true;
    final drop = paths.toSet();
    state = state.copyWith(
        hidden: <String>{
      for (final p in state.hidden)
        if (!drop.contains(p)) p,
    });
    await _save();
  }

  Future<void> setAppFoldersOnlyWhileConnected(bool on) async {
    _touched = true;
    state = state.copyWith(appFoldersOnlyWhileConnected: on);
    await _save();
  }
}

final folderVisibilityProvider =
    StateNotifierProvider<FolderVisibilityNotifier, FolderVisibility>(
        (ref) => FolderVisibilityNotifier());

/// Whether the ADB connection worked the last time anything used it
/// ([AdbService.live]): null until something has.
final adbLiveProvider = Provider<bool?>((ref) {
  final live = AdbService.instance.live;
  void changed() => ref.invalidateSelf();
  live.addListener(changed);
  ref.onDispose(() => live.removeListener(changed));
  return live.value;
});
