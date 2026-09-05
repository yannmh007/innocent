import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/router/routes.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../user_data_providers.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
class FavouritesScreen extends ConsumerWidget {
  const FavouritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favs = ref.watch(favouritesProvider).toList();

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).favourites)),
      body: favs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.favorite_outline,
                      color: AppColors.darkOnSurfaceMuted,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    Text(AppStrings.of(context).noFavouritesYet,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.darkOnSurfaceMuted,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(favouritesProvider);
              },
              child: ListView.builder(
              itemCount: favs.length,
              itemBuilder: (_, i) {
                final uri = favs[i];
                final name = _displayName(uri);
                return Dismissible(
                  key: ValueKey('fav_$uri'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: AppColors.error,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: const Icon(Icons.heart_broken_outlined,
                        color: Colors.white, size: 24),
                  ),
                  onDismissed: (_) {
                    ref.read(favouritesProvider.notifier).toggle(uri);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(AppStrings.of(context).unfavouritedName(name)),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                        action: SnackBarAction(
                          label: 'UNDO',
                          textColor: AppColors.accentBlue,
                          onPressed: () => ref
                              .read(favouritesProvider.notifier)
                              .toggle(uri),
                        ),
                      ),
                    );
                  },
                  child: _FavTile(
                    uri: uri,
                    name: name,
                    onTap: () => context.push(
                      Routes.player,
                      extra: {'uri': uri, 'title': name},
                    ),
                    onRemove: () =>
                        ref.read(favouritesProvider.notifier).toggle(uri),
                  ),
                );
              },
            ),
            ),
    );
  }

  String _displayName(String uri) {
    try {
      if (uri.startsWith('file://')) {
        return p.basename(Uri.parse(uri).toFilePath());
      }
      return p.basename(uri);
    } catch (_) {
      return uri;
    }
  }
}

class _FavTile extends StatefulWidget {
  final String uri;
  final String name;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _FavTile({
    required this.uri,
    required this.name,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_FavTile> createState() => _FavTileState();
}

class _FavTileState extends State<_FavTile> {
  Uint8List? _thumb;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _loadThumbnail() async {
    try {
      var path = widget.uri;
      if (path.startsWith('file://')) {
        path = Uri.parse(path).toFilePath();
      }
      if (!path.startsWith('/')) return;
      if (!await File(path).exists()) return;
      final bytes = await ThumbnailCache.instance.get(path);
      if (!_disposed && mounted) {
        setState(() => _thumb = bytes);
      }
    } catch (e) { if (kDebugMode) debugPrint('favourites_screen.best-effort: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 64,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: _thumb != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  SafeThumbnail(bytes: _thumb!),
                  Container(color: Colors.black.withOpacity(0.15)),
                  const Center(
                    child: Icon(Icons.favorite,
                        color: AppColors.error, size: 18),
                  ),
                ],
              )
            : const Icon(Icons.favorite, color: AppColors.error),
      ),
      title: Text(
        widget.name,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Close',
        icon: const Icon(
          Icons.close,
          color: AppColors.darkOnSurfaceMuted,
          size: 18,
        ),
        onPressed: widget.onRemove,
      ),
      onTap: widget.onTap,
    );
  }
}
