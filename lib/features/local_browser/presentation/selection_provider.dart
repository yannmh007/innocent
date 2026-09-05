import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Multi-select selection state for the Local browser (Phase 13).
/// When non-empty, the UI enters "selection mode" with checkboxes
/// and a contextual app bar showing bulk actions.
class SelectionNotifier extends StateNotifier<Set<String>> {
  SelectionNotifier() : super(const {});

  bool get isActive => state.isNotEmpty;
  int get count => state.length;

  void toggle(String videoUri) {
    final next = {...state};
    if (next.contains(videoUri)) {
      next.remove(videoUri);
    } else {
      next.add(videoUri);
    }
    state = next;
  }

  void selectAll(List<String> uris) {
    state = uris.toSet();
  }

  void clear() {
    state = const {};
  }

  bool contains(String uri) => state.contains(uri);
}

/// Provider for selection state in the local browser
final selectionProvider =
    StateNotifierProvider<SelectionNotifier, Set<String>>((ref) {
  return SelectionNotifier();
});

/// Multi-select state for FOLDERS (keyed by folder path). Kept separate
/// from the video [selectionProvider] because folders are identified by
/// path, not by media URI, and the two selection modes are mutually
/// exclusive in the UI (you're either picking videos or picking folders).
class FolderSelectionNotifier extends StateNotifier<Set<String>> {
  FolderSelectionNotifier() : super(const {});

  bool get isActive => state.isNotEmpty;
  int get count => state.length;

  void toggle(String folderPath) {
    final next = {...state};
    if (next.contains(folderPath)) {
      next.remove(folderPath);
    } else {
      next.add(folderPath);
    }
    state = next;
  }

  void selectAll(List<String> paths) {
    state = paths.toSet();
  }

  void clear() {
    state = const {};
  }

  bool contains(String path) => state.contains(path);
}

final folderSelectionProvider =
    StateNotifierProvider<FolderSelectionNotifier, Set<String>>((ref) {
  return FolderSelectionNotifier();
});
