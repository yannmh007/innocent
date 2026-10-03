import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/network/connection_kind.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../domain/blurhash.dart';
import '../domain/byte_size.dart';
import '../data/api/offline_downloader.dart';
import '../domain/offline_key.dart';
import '../domain/video_content.dart';
import 'album_downloads.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';

/// The data saver for albums, the way Telegram does it.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT IT DOES
/// ═══════════════════════════════════════════════════════════════════════
///
/// On: every photo and clip in an album is drawn as frosted glass — its
/// blurhash, thirty characters that came inside the album response, so NO
/// IMAGE IS FETCHED to draw it — with a download button in the middle. The
/// viewer taps the ones they want; each arrives on the phone and from then on
/// draws as itself, here and offline. Nothing is fetched that was not chosen.
///
/// When everything they wanted is down, the album's own Download button
/// counts it like any other download — and dims once the whole album is here.
///
/// ON MOBILE DATA ONLY, unless the viewer says otherwise. The point is the
/// data bundle. A connection Android cannot classify counts as metered — the
/// mistake that costs a toggle, not the one that costs a bundle.

/// True while albums should be frosted.
final albumSaverProvider = FutureProvider.autoDispose<bool>((ref) async {
  final settings = ref.watch(playerSettingsProvider);
  if (!settings.get(PlayerSetting.albumDataSaver)) return false;
  if (settings.get(PlayerSetting.albumDataSaverOnWifi)) return true;
  return (await ConnectionInfo.read()).metered;
});

/// Turns the saver on or off, from wherever the switch is drawn.
void setAlbumSaver(WidgetRef ref, bool on) {
  ref
      .read(playerSettingsProvider.notifier)
      .setValue(PlayerSetting.albumDataSaver, on);
}

/// Frosted glass from a blurhash, or a plain dark tile without one. NEVER an
/// image fetch: this is what the saver draws instead of one.
class BlurPreview extends StatelessWidget {
  final String? hash;
  final BoxFit fit;

  const BlurPreview({super.key, required this.hash, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final h = hash;
    final bytes = h == null ? null : BlurHash.bmpFor(h);
    if (bytes == null) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF3A3F4B), Color(0xFF23262E)],
          ),
        ),
      );
    }
    return Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      // A 32-pixel picture stretched over a tile: smoothing is the effect.
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF2A2D35)),
    );
  }
}

/// Decides, for one album item, whether it is frosted — and draws the frost.
///
/// Frosted when the saver is on and the item is NOT on the phone. A locked
/// item is frosted too, with its lock: drawing the locked tile normally would
/// fetch the picture just to blur it, which is the cost the saver exists to
/// avoid. Anything else draws [normal], untouched.
class AlbumSaverGate extends ConsumerWidget {
  final VideoContent content;
  final AlbumItem item;
  final bool locked;

  /// Small (a grid tile) or large (a page in the viewer). Sizes the controls.
  final bool large;

  /// What is drawn when the item is not frosted.
  final Widget normal;

  /// Opens the item: a frosted VIDEO still plays on tap, as in Telegram —
  /// pressing play is the choice to spend the data.
  final VoidCallback? onPlay;

  const AlbumSaverGate({
    super.key,
    required this.content,
    required this.item,
    required this.normal,
    this.locked = false,
    this.large = false,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The switch is read synchronously; only the "is this mobile data"
    // question is asynchronous. While it is being answered, a saver that is
    // ON frosts — drawing the normal tile for that first frame would start
    // exactly the fetch the saver exists to prevent.
    final enabled =
        ref.watch(playerSettingsProvider).get(PlayerSetting.albumDataSaver);
    if (!enabled) return normal;
    final saver = ref.watch(albumSaverProvider).valueOrNull ?? true;
    if (!saver) return normal;
    final held = ref.watch(albumHeldKeysProvider(content.id)).valueOrNull;
    // Not read yet: frosted, not normal. Drawing normally for one frame would
    // start the very fetch this exists to prevent.
    final key = albumItemKey(content.id, item);
    if (held != null && held.contains(key)) return normal;

    final downloader = ref.read(offlineDownloaderProvider);
    final s = AppStrings.of(context);
    final big = large ? 64.0 : 40.0;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        BlurPreview(
            hash: item.preview, fit: large ? BoxFit.contain : BoxFit.cover),
        if (locked)
          Center(
            child: Icon(Icons.lock_rounded,
                size: large ? 40 : 18, color: VH.textPrimary),
          )
        else
          ValueListenableBuilder<int>(
            valueListenable: downloader.activity,
            builder: (context, _, __) {
              final running = downloader.isRunning(key);
              final download = _Circle(
                key: ValueKey('saver-dl-${item.id}'),
                size: item.isVideo ? big * 0.55 : big,
                tooltip: running ? s.vhDownloadPause : s.vhSaveOffline,
                onTap: running
                    ? () => downloader.cancel(key)
                    : () => downloadAlbumItem(context, ref,
                        content: content, item: item),
                child: running
                    // A RING THAT FILLS, as in Telegram, not a spinner: on a
                    // slow line "is it moving?" is the question, and an
                    // indeterminate spinner cannot answer it. Tapping it
                    // stops the download (the partial is kept).
                    ? Padding(
                        padding: EdgeInsets.all(big * 0.1),
                        child: StreamBuilder<OfflineProgress>(
                          stream: downloader.watch(key),
                          builder: (context, snap) => Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              CircularProgressIndicator(
                                value: snap.data?.fraction,
                                strokeWidth: 2.2,
                                color: Colors.white,
                                backgroundColor: const Color(0x33FFFFFF),
                              ),
                              Icon(Icons.close_rounded,
                                  size: (item.isVideo ? big * 0.55 : big) * 0.38,
                                  color: Colors.white),
                            ],
                          ),
                        ),
                      )
                    : Icon(Icons.arrow_downward_rounded,
                        size: (item.isVideo ? big * 0.55 : big) * 0.55,
                        color: Colors.white),
              );
              if (!item.isVideo) {
                if (!large) return Center(child: download);
                // The full-screen page: the button with its cost under it,
                // in words, because this is where the decision is made.
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      download,
                      if ((item.bytes ?? 0) > 0) ...<Widget>[
                        const SizedBox(height: VH.s3),
                        _SizePill(
                            bytes: item.bytes!, large: true, label: s.vhSaveOffline),
                      ],
                    ],
                  ),
                );
              }
              // A clip: play in the middle, download tucked against it —
              // the layout of the screenshot this was asked for from.
              return Center(
                child: SizedBox(
                  width: big * 1.35,
                  height: big * 1.35,
                  child: Stack(
                    children: <Widget>[
                      Align(
                        alignment: Alignment.topLeft,
                        child: _Circle(
                          key: ValueKey('saver-play-${item.id}'),
                          size: big,
                          tooltip: s.vhPlay,
                          onTap: onPlay,
                          child: Icon(Icons.play_arrow_rounded,
                              size: big * 0.6, color: Colors.white),
                        ),
                      ),
                      Align(alignment: Alignment.bottomRight, child: download),
                    ],
                  ),
                ),
              );
            },
          ),
        // WHAT IT COSTS, before it is spent. Telegram prints the size on
        // every undownloaded item for exactly this reader: someone deciding
        // which of these is worth the data. A 450 MB clip and a 180 KB photo
        // looked the same here.
        if (!locked && !large && !item.isVideo && (item.bytes ?? 0) > 0)
          Positioned(
            left: 4,
            bottom: 4,
            child: _SizePill(bytes: item.bytes!),
          ),
        if (large && item.isVideo && !locked && (item.bytes ?? 0) > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: VH.s6,
            child: Center(child: _SizePill(bytes: item.bytes!, large: true)),
          ),
        if (item.isVideo && item.durationLabel.isNotEmpty)
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xA6000000),
                borderRadius: BorderRadius.circular(3),
              ),
              // A clip's size rides in its duration pill — two pills side by
              // side collided on a narrow tile ("114 MB 18:29").
              child: Text(
                !locked && !large && (item.bytes ?? 0) > 0
                    ? '${item.durationLabel} · ${formatBytes(item.bytes!)}'
                    : item.durationLabel,
                maxLines: 1,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ],
    );
  }
}

/// "1.2 MB", on frosted glass. With [label], a wider pill for the viewer.
class _SizePill extends StatelessWidget {
  final int bytes;
  final bool large;
  final String? label;

  const _SizePill({required this.bytes, this.large = false, this.label});

  @override
  Widget build(BuildContext context) {
    final size = formatBytes(bytes);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: large ? 10 : 4, vertical: large ? 5 : 1),
      decoration: BoxDecoration(
        color: const Color(0xA6000000),
        borderRadius: BorderRadius.circular(large ? VH.rPill : 3),
      ),
      child: Text(
        label == null ? size : '$label · $size',
        maxLines: 1,
        style: TextStyle(
          color: Colors.white,
          fontSize: large ? 12.5 : 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  final double size;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  const _Circle({
    super.key,
    required this.size,
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0x8C000000),
        shape: const CircleBorder(
            side: BorderSide(color: Color(0x40FFFFFF), width: 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Center(child: child)),
        ),
      ),
    );
  }
}

/// The saver's switch beside an album's heading: on and off in one tap, where
/// the effect is visible.
class AlbumSaverToggle extends ConsumerWidget {
  const AlbumSaverToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final on = ref.watch(playerSettingsProvider).get(PlayerSetting.albumDataSaver);
    return IconButton(
      key: const ValueKey('album-saver-toggle'),
      visualDensity: VisualDensity.compact,
      tooltip: on ? s.vhDataSaverOn : s.vhDataSaverOff,
      onPressed: () => setAlbumSaver(ref, !on),
      icon: Icon(
        on ? Icons.data_saver_on_rounded : Icons.data_saver_off_rounded,
        size: 19,
        color: on ? VH.textPrimary : VH.textTertiary,
      ),
    );
  }
}
