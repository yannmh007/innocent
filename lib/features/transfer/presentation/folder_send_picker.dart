import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/localization/app_strings.dart';
import '../../../core/services/file_transfer/file_transfer_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../private_folder/data/picker_providers.dart';

/// Pick a folder and send the whole tree, structure intact.
///
/// WHY A SEPARATE BROWSER
/// The Private Folder's AddFilesPicker already walks storage, but it is 1750
/// lines shared with the vault import path and it selects FILES. Bending it to
/// also return a directory would put the vault's import at risk for a feature
/// that needs one screen and one button, so this is deliberately its own
/// small thing — the blast radius stays inside the Transfer tab.
class FolderSendPicker extends ConsumerStatefulWidget {
  /// Receives the files found under the chosen folder, each already carrying
  /// its position in the tree. [truncated] is true when the walk hit its cap.
  ///
  /// The truncation warning is reported UP rather than shown here: this route
  /// pops immediately afterwards, and a SnackBar on a dying scaffold is a
  /// warning nobody ever sees.
  final void Function(
      List<SharedFile> files, String folderName, bool truncated) onPicked;

  const FolderSendPicker({super.key, required this.onPicked});

  @override
  ConsumerState<FolderSendPicker> createState() => _FolderSendPickerState();
}

class _FolderSendPickerState extends ConsumerState<FolderSendPicker> {
  /// Breadcrumb of directories entered. Empty = the storage-roots level.
  final List<Directory> _stack = [];
  List<Directory> _subdirs = const [];
  bool _loading = false;
  bool _scanning = false;
  String? _error;

  /// Hard caps on a recursive walk.
  ///
  /// Someone will point this at the storage root sooner or later. Without a
  /// ceiling that is a multi-minute freeze that ends in an out-of-memory kill,
  /// and the person has no idea why — so stop at a number that is far past any
  /// real folder and say so plainly.
  static const int _maxFiles = 3000;
  static const int _maxDepth = 12;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRoots());
  }

  Future<void> _loadRoots() async {
    setState(() => _loading = true);
    try {
      final roots = await ref.read(pickerStorageRootsProvider.future);
      if (!mounted) return;
      if (roots.length == 1) {
        // One volume — skip a menu with a single item on it.
        _stack.add(roots.first);
        await _listCurrent();
        return;
      }
      setState(() {
        _subdirs = roots;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _listCurrent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = _stack.last;
      final entries = await dir.list(followLinks: false).toList();
      final dirs = <Directory>[];
      for (final e in entries) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        // Dot-folders here are caches and app data, never something a person
        // means to hand to a friend.
        if (name.startsWith('.')) continue;
        dirs.add(e);
      }
      dirs.sort((a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));
      if (!mounted) return;
      setState(() {
        _subdirs = dirs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A permission-denied folder is normal on Android, not a crash.
        _subdirs = const [];
        _error = '$e';
      });
    }
  }

  Future<void> _enter(Directory d) async {
    _stack.add(d);
    await _listCurrent();
  }

  Future<bool> _up() async {
    if (_stack.length <= 1) return true; // let the route pop
    _stack.removeLast();
    await _listCurrent();
    return false;
  }

  /// Walk the chosen folder and turn it into SharedFiles.
  ///
  /// Runs breadth-first with an explicit queue rather than a recursive
  /// `list(recursive: true)`: that call throws on the FIRST unreadable
  /// subdirectory and abandons everything after it, and on Android there is
  /// almost always one.
  Future<void> _sendFolder(Directory root) async {
    setState(() => _scanning = true);
    final rootName = p.basename(root.path);
    final out = <SharedFile>[];
    var truncated = false;
    final queue = <({Directory dir, String rel, int depth})>[
      (dir: root, rel: rootName, depth: 0)
    ];
    try {
      while (queue.isNotEmpty) {
        final item = queue.removeAt(0);
        List<FileSystemEntity> entries;
        try {
          entries = await item.dir.list(followLinks: false).toList();
        } catch (_) {
          continue; // unreadable subfolder — skip it, keep the rest
        }
        for (final e in entries) {
          final name = p.basename(e.path);
          if (name.startsWith('.')) continue;
          if (e is Directory) {
            if (item.depth + 1 <= _maxDepth) {
              queue.add((
                dir: e,
                rel: '${item.rel}/$name',
                depth: item.depth + 1
              ));
            }
            continue;
          }
          if (e is! File) continue;
          int size;
          try {
            size = await e.length();
          } catch (_) {
            continue;
          }
          if (size <= 0) continue;
          out.add(SharedFile(
            id: '${e.path.hashCode}',
            path: e.path,
            displayName: name,
            sizeBytes: size,
            relPath: '${item.rel}/$name',
          ));
          if (out.length >= _maxFiles) {
            truncated = true;
            break;
          }
        }
        if (truncated) break;
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted) return;
    if (out.isEmpty) {
      // Stays on this screen, so a SnackBar here is actually seen.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).folderEmpty)),
      );
      return;
    }
    widget.onPicked(out, rootName, truncated);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final current = _stack.isEmpty ? null : _stack.last;
    return PopScope(
      canPop: _stack.length <= 1,
      // onPopInvoked, not onPopInvokedWithResult: the latter arrived in a
      // later Flutter than this project builds against, and every other
      // PopScope in the codebase uses this one. Match the tree, not the
      // newest docs.
      onPopInvoked: (didPop) {
        if (!didPop) _up();
      },
      child: Scaffold(
        backgroundColor: AppColors.darkBackground,
        appBar: AppBar(
          backgroundColor: AppColors.darkBackground,
          title: Text(
            current == null ? s.sendFolder : p.basename(current.path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _up() && mounted) Navigator.of(context).pop();
            },
          ),
        ),
        body: Column(
          children: [
            if (current != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  current.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.white55,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _subdirs.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              _error == null ? s.noSubfolders : s.folderUnreadable,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.white55,
                                  fontSize: 13,
                                  height: 1.5),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _subdirs.length,
                          itemBuilder: (_, i) {
                            final d = _subdirs[i];
                            return ListTile(
                              leading: Icon(Icons.folder_outlined,
                                  color: AppColors.accentBlue, size: 24),
                              title: Text(
                                p.basename(d.path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                              ),
                              trailing: Icon(Icons.chevron_right,
                                  color: AppColors.white50, size: 20),
                              onTap: _scanning ? null : () => _enter(d),
                            );
                          },
                        ),
            ),
            if (current != null)
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          _scanning ? null : () => _sendFolder(current),
                      icon: _scanning
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.drive_folder_upload, size: 18),
                      label: Text(_scanning
                          ? s.scanningFolder
                          : '${s.sendThisFolder} "${p.basename(current.path)}"'),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
