import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../features/user_data/domain/user_data_models.dart';
import '../user_data/user_data_service.dart';

/// Backup/restore service for user data (favourites/playlists/bookmarks/history/recycle bin)
class BackupService {
  static const String _kVersion = '1.0';
  final UserDataService _userData;

  BackupService(this._userData);

  /// Export all user data to a JSON file in documents directory.
  /// Returns the file path on success.
  Future<String> exportToFile() async {
    final favourites = await _userData.loadFavourites();
    final playlists = await _userData.loadPlaylists();
    final bookmarks = await _userData.loadBookmarks();
    final history = await _userData.loadHistory();
    final recycle = await _userData.loadRecycleBin();

    final payload = {
      'version': _kVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'favourites': favourites.toList(),
      'playlists': playlists.map((p) => p.toJson()).toList(),
      'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
      'history': history.map((h) => h.toJson()).toList(),
      'recycleBin': recycle.map((r) => r.toJson()).toList(),
    };

    final json = const JsonEncoder.withIndent('  ').convert(payload);
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'innocent_backup_$ts.json'));
    await file.writeAsString(json);
    return file.path;
  }

  /// Restore from a JSON file picked by user.
  /// Returns counts of restored items, or null if user cancelled.
  Future<RestoreResult?> importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;

    final raw = await File(path).readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;

    if (data['version'] != _kVersion) {
      throw FormatException('Unsupported backup version: ${data['version']}');
    }

    final favourites = (data['favourites'] as List).cast<String>().toSet();
    final playlists = (data['playlists'] as List)
        .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
        .toList();
    final bookmarks = (data['bookmarks'] as List)
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
    final history = (data['history'] as List)
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    final recycle = (data['recycleBin'] as List)
        .map((e) => RecycleBinEntry.fromJson(e as Map<String, dynamic>))
        .toList();

    await _userData.saveFavourites(favourites);
    await _userData.savePlaylists(playlists);
    await _userData.saveBookmarks(bookmarks);
    await _userData.saveHistory(history);
    await _userData.saveRecycleBin(recycle);

    return RestoreResult(
      favourites: favourites.length,
      playlists: playlists.length,
      bookmarks: bookmarks.length,
      history: history.length,
      recycleBin: recycle.length,
    );
  }
}

class RestoreResult {
  final int favourites;
  final int playlists;
  final int bookmarks;
  final int history;
  final int recycleBin;

  const RestoreResult({
    required this.favourites,
    required this.playlists,
    required this.bookmarks,
    required this.history,
    required this.recycleBin,
  });

  int get total =>
      favourites + playlists + bookmarks + history + recycleBin;
}
