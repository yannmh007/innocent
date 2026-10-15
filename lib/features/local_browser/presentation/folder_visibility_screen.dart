import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../../core/ui/nav_bar_space.dart';
import '../domain/app_data_names.dart';
import 'folder_visibility.dart';
import 'library_provider.dart';

/// SHOW / HIDE FOLDERS — the one place a hidden folder comes back from.
///
/// MX Player's model: a folder is hidden from its list (select → Hide) and
/// shown again from Settings → List → Folders. Here the list is one tap
/// away from where it matters — the Video tab's ⋮, the line under the
/// folders when some are hidden, and Hidden files' top bar — and it lists
/// every Android/data folder the last ADB scan found, shown or not, so one
/// that was never hidden can be put away from here too, without hunting
/// for it in the Video tab. Every row carries its own Hide / Show button:
/// one tap, no menu, and the row says which state it is in.
/// Takes [paths] out of the Video tab — the folder, not its files: nothing
/// is moved or deleted — and offers Undo. What select → Hide does, for a
/// phone folder and an Android/data one alike.
Future<void> hideFolders(
    WidgetRef ref, AppStrings s, Iterable<String> paths) async {
  final list = paths.toList();
  if (list.isEmpty) return;
  final notifier = ref.read(folderVisibilityProvider.notifier);
  await notifier.hide(list);
  AppSnackbar.globalAction(
      s.fvHiddenSnack(list.length), s.fvUndo, () => notifier.show(list));
}

class FolderVisibilityScreen extends ConsumerWidget {
  const FolderVisibilityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final choices = ref.watch(folderChoicesProvider);
    final vis = ref.watch(folderVisibilityProvider);
    final live = ref.watch(adbLiveProvider) == true;
    final notifier = ref.read(folderVisibilityProvider.notifier);
    final app = <FolderChoice>[for (final c in choices) if (c.appFolder) c];
    final other = <FolderChoice>[
      for (final c in choices)
        if (!c.appFolder && vis.isHidden(c.path)) c,
    ];
    final appHidden = app.where((c) => vis.isHidden(c.path)).length;

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.fvTitle)),
      body: app.isEmpty && other.isEmpty
          ? _Empty(text: s.fvEmpty)
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 24)
                  .plusNavBar(context),
              children: <Widget>[
                if (app.isNotEmpty) ...<Widget>[
                  _SectionHeader(
                    title: s.fvAppSection,
                    hint: s.fvAppSectionHint,
                    trailing: TextButton(
                      onPressed: () => appHidden == app.length
                          ? notifier.show(app.map((c) => c.path))
                          : notifier.hide(app.map((c) => c.path)),
                      child: Text(
                          appHidden == app.length ? s.fvShowAll : s.fvHideAll),
                    ),
                  ),
                  SwitchListTile(
                    value: vis.appFoldersOnlyWhileConnected,
                    onChanged: notifier.setAppFoldersOnlyWhileConnected,
                    activeColor: AppColors.specSwitchOn,
                    secondary: Icon(
                      live ? Icons.link_rounded : Icons.link_off_rounded,
                      color: live ? AppColors.success : AppColors.white55,
                    ),
                    title: Text(s.fvOnlyLive,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(s.fvOnlyLiveSub,
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 12.5)),
                  ),
                  const Divider(
                      height: 1, indent: 16, color: AppColors.darkDivider),
                  for (final c in app)
                    _FolderRow(
                      choice: c,
                      hidden: vis.isHidden(c.path),
                      away: vis.appFoldersOnlyWhileConnected && !live,
                      onHide: () => notifier.hide(<String>[c.path]),
                      onShow: () => notifier.show(<String>[c.path]),
                    ),
                ],
                if (other.isNotEmpty) ...<Widget>[
                  _SectionHeader(title: s.fvOtherSection),
                  for (final c in other)
                    _FolderRow(
                      choice: c,
                      hidden: true,
                      away: false,
                      onHide: () => notifier.hide(<String>[c.path]),
                      onShow: () => notifier.show(<String>[c.path]),
                    ),
                ],
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.hint, this.trailing});

  final String title;
  final String? hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: AppColors.specSelectedLabel,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(hint!,
                  style: const TextStyle(
                      color: AppColors.white55,
                      fontSize: 12.5,
                      height: 1.45)),
            ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.choice,
    required this.hidden,
    required this.away,
    required this.onHide,
    required this.onShow,
  });

  final FolderChoice choice;
  final bool hidden;

  /// Shown, but out of the Video tab for now: "only while ADB is connected"
  /// is on and ADB is not.
  final bool away;
  final VoidCallback onHide;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final pkg = choice.appFolder ? appDataPackage(choice.path) : null;
    final owner = pkg == null ? null : appLabelForPackage(pkg);
    final state = hidden
        ? s.fvHidden
        : away
            ? s.fvAwayNoAdb
            : s.fvShown;
    final detail = <String>[
      if (owner != null && !choice.name.contains(owner)) owner,
      if (choice.videoCount > 0) s.fvVideos(choice.videoCount),
    ].join(' · ');
    final stateColor = hidden
        ? AppColors.white40
        : away
            ? AppColors.warning
            : AppColors.success;

    return Semantics(
      container: true,
      label: '${choice.name}, $state',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: <Widget>[
            Opacity(
              opacity: hidden ? 0.45 : 1,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.specSurface.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  hidden ? Icons.folder_off_outlined : Icons.folder_rounded,
                  color: const Color(0xFF9AA4AD),
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(choice.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: hidden ? AppColors.white55 : Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600)),
                  if (detail.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.white55, fontSize: 12)),
                  ],
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            color: stateColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(state,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: stateColor, fontSize: 11.5)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            hidden
                ? FilledButton.tonalIcon(
                    onPressed: onShow,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor:
                          AppColors.primaryBlue.withValues(alpha: 0.22),
                      foregroundColor: AppColors.accentBlueLight,
                    ),
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: Text(s.fvShow),
                  )
                : OutlinedButton.icon(
                    onPressed: onHide,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: AppColors.white70,
                      side: const BorderSide(color: Color(0x33FFFFFF)),
                    ),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: Text(s.hide),
                  ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32).plusNavBar(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.visibility_outlined,
                size: 44, color: AppColors.white40),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 14, height: 1.5)),
          ],
        ),
      ),
    );
  }
}
