import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/localization/app_strings.dart';
import '../../../../core/services/file_ops/file_ops_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/folder.dart';
import '../library_provider.dart';

/// What the user chose in [DestinationPicker].
@immutable
class DestinationChoice {
  final String path;
  final FileCollision collision;

  const DestinationChoice({required this.path, required this.collision});
}

/// Picks the folder a move or copy should write into.
///
/// Deliberately lists the folders the LIBRARY already knows about rather than
/// opening a filesystem browser. Those are the places the user keeps videos,
/// they are already scanned, and they are guaranteed readable — whereas a raw
/// tree walk on Android leads straight into directories the app cannot write
/// to, which turns a folder chooser into a way to pick a destination that
/// fails afterwards.
///
/// The collision rule is asked ONCE, up front, for the whole batch. Prompting
/// per file means a fifty-file move needs fifty answers, and answering the
/// same question fifty times is how people stop reading it.
class DestinationPicker extends ConsumerStatefulWidget {
  /// Folders to exclude — the source folder of the selection, because moving
  /// a file into the folder it already lives in is a no-op the user did not
  /// mean to ask for.
  final Set<String> excludePaths;

  /// Shown in the header, e.g. "Move 3 videos".
  final String title;

  const DestinationPicker({
    super.key,
    required this.title,
    this.excludePaths = const <String>{},
  });

  /// Returns null when dismissed.
  static Future<DestinationChoice?> show(
    BuildContext context, {
    required String title,
    Set<String> excludePaths = const <String>{},
  }) {
    return showModalBottomSheet<DestinationChoice>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DestinationPicker(
        title: title,
        excludePaths: excludePaths,
      ),
    );
  }

  @override
  ConsumerState<DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends ConsumerState<DestinationPicker> {
  FileCollision _collision = FileCollision.keepBoth;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final foldersAsync = ref.watch(foldersProvider);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            _CollisionSelector(
              value: _collision,
              onChanged: (v) => setState(() => _collision = v),
            ),
            const Divider(height: 1, color: Colors.white12),
            Flexible(
              child: foldersAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '$e',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
                data: (List<Folder> folders) {
                  final choices = folders
                      .where((f) => !widget.excludePaths.contains(f.path))
                      .toList();
                  if (choices.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        s.destinationNoneAvailable,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: choices.length,
                    itemBuilder: (context, i) {
                      final f = choices[i];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined,
                            color: AppColors.accentBlue),
                        title: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          // The parent path, not the full one: the folder name
                          // is already the title, and a full Android path is
                          // long enough to push the useful part off screen.
                          p.dirname(f.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.darkOnSurfaceMuted,
                            fontSize: 12,
                          ),
                        ),
                        trailing: Text(
                          '${f.videoCount}',
                          style: const TextStyle(
                            color: AppColors.darkOnSurfaceMuted,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(
                          DestinationChoice(
                            path: f.path,
                            collision: _collision,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollisionSelector extends StatelessWidget {
  final FileCollision value;
  final ValueChanged<FileCollision> onChanged;

  const _CollisionSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            s.destinationIfExists,
            style: const TextStyle(
              color: AppColors.darkOnSurfaceMuted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              _chip(context, FileCollision.keepBoth, s.destinationKeepBoth),
              _chip(context, FileCollision.skip, s.destinationSkip),
              _chip(context, FileCollision.overwrite, s.destinationOverwrite),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, FileCollision v, String label) {
    final selected = v == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onChanged(v),
      backgroundColor: AppColors.darkSurfaceVariant,
      selectedColor: AppColors.accentBlue,
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.white70,
        fontSize: 12.5,
      ),
      side: BorderSide(
        // Overwrite is the destructive one, so it is the one that has to look
        // different before it is chosen rather than after.
        color: v == FileCollision.overwrite && !selected
            ? AppColors.error.withValues(alpha: 0.5)
            : Colors.transparent,
      ),
    );
  }
}
