import 'package:flutter/material.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../data/cache/catalogue_cache.dart';
import '../data/cache/stream_cache_store.dart';
import '../data/poster_cache.dart';

/// What the app is keeping, and the controls to change it.
///
/// WHY THIS SCREEN IS NOT OPTIONAL. The cache lives in the app's support
/// directory, which Android never empties on its own — so this app, and only
/// this app, decides how much of somebody's phone it occupies. A feature with
/// that power and no visible dial is the reason people uninstall media apps,
/// and "clear the app's data" is not an answer: it takes the viewer's
/// settings and watch history with it.
///
/// So: how much is held, what it is, what the ceiling is, and one button that
/// empties it. Nothing here requires an explanation of what a cache is.
class StreamCacheScreen extends StatefulWidget {
  const StreamCacheScreen({super.key});

  @override
  State<StreamCacheScreen> createState() => _StreamCacheScreenState();
}

class _StreamCacheScreenState extends State<StreamCacheScreen> {
  bool _busy = true;

  /// The ceilings offered, in gigabytes.
  ///
  /// A HALF-GIGABYTE FLOOR RATHER THAN ZERO. "Off" is a setting people pick
  /// to be safe and then forget, and what it actually buys them is every
  /// rewind costing a download on the connection that made them cautious.
  /// The smallest option still holds a film.
  static const List<int> _choices = <int>[1, 2, 5, 10, 20];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await StreamCacheStore.instance.load();
    if (mounted) setState(() => _busy = false);
  }

  String _size(int bytes) {
    if (bytes <= 0) return '0 MB';
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v >= 10 || i == 0 ? v.round() : v.toStringAsFixed(1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final store = StreamCacheStore.instance;
    final used = store.usedBytes;
    final budget = store.budgetBytes;

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.streamCacheTitle,
            style: const TextStyle(color: AppColors.darkOnSurface)),
        iconTheme: const IconThemeData(color: AppColors.darkOnSurface),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_size(used)} / ${_size(budget)}',
                        style: const TextStyle(
                            color: AppColors.darkOnSurface,
                            fontSize: 22,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: budget <= 0
                              ? 0
                              : (used / budget).clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: AppColors.darkSurface,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(s.streamCacheExplain,
                          style: const TextStyle(
                              color: AppColors.darkOnSurfaceMuted,
                              fontSize: 12.5,
                              height: 1.45)),
                    ],
                  ),
                ),
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(s.streamCacheLimit,
                      style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 4),
                for (final gb in _choices)
                  RadioListTile<int>(
                    value: gb,
                    groupValue: (budget / (1024 * 1024 * 1024)).round(),
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => _busy = true);
                      await store
                          .setBudgetBytes(v * 1024 * 1024 * 1024);
                      if (mounted) setState(() => _busy = false);
                    },
                    title: Text('$gb GB',
                        style: const TextStyle(
                            color: AppColors.darkOnSurface, fontSize: 15)),
                  ),
                const Divider(height: 24),
                ListTile(
                  leading: const Icon(Icons.delete_outline,
                      color: AppColors.darkOnSurface),
                  title: Text(s.streamCacheClear,
                      style: const TextStyle(
                          color: AppColors.darkOnSurface, fontSize: 15)),
                  subtitle: Text(s.streamCacheClearNote,
                      style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 12)),
                  onTap: used <= 0
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await store.clear();
                          if (mounted) setState(() => _busy = false);
                        },
                ),
                // THE OTHER TWO CACHES, and they belong on this screen rather
                // than a new one because the question a viewer arrives with is
                // "what is this app keeping and how do I get the space back".
                //
                // Separate from the video button above because they answer
                // opposite needs and clearing the wrong one is annoying: the
                // video cache is gigabytes and losing it costs a re-download,
                // while this is a few megabytes and losing it costs the ability
                // to browse at all with no signal. Someone reclaiming space
                // wants the first; only someone who suspects a stale listing
                // wants this.
                //
                // Always enabled: unlike the video cache there is no cheap
                // byte count to gate it on, and a button that does nothing
                // twice is better than one that looks broken when it would
                // have worked.
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined,
                      color: AppColors.darkOnSurface),
                  title: Text(s.streamCacheClearPages,
                      style: const TextStyle(
                          color: AppColors.darkOnSurface, fontSize: 15)),
                  subtitle: Text(s.streamCacheClearPagesNote,
                      style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted, fontSize: 12)),
                  onTap: () async {
                    setState(() => _busy = true);
                    await CatalogueCache.clear();
                    await PosterCache.clear();
                    if (mounted) setState(() => _busy = false);
                  },
                ),
                if (store.entries.isNotEmpty) ...[
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(s.streamCacheKept,
                        style: const TextStyle(
                            color: AppColors.darkOnSurfaceMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                  // Titles, never object keys. A list of keys is a map of the
                  // bucket, and it has no business on a viewer's screen.
                  for (final e in store.entries)
                    ListTile(
                      dense: true,
                      title: Text(
                        e.label.isEmpty ? s.streamCacheUnnamed : e.label,
                        style: const TextStyle(
                            color: AppColors.darkOnSurface, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        e.total > 0
                            ? '${_size(e.heldBytes)} · '
                                '${(e.fraction * 100).round()}%'
                            : _size(e.heldBytes),
                        style: const TextStyle(
                            color: AppColors.darkOnSurfaceMuted,
                            fontSize: 12),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: AppColors.darkOnSurfaceMuted),
                        onPressed: () async {
                          setState(() => _busy = true);
                          await store.remove(e.id);
                          if (mounted) setState(() => _busy = false);
                        },
                      ),
                    ),
                ],
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
