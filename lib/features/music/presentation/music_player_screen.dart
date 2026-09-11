import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_colors.dart';
import '../../equalizer/presentation/equalizer_screen.dart';
import '../data/lrc_lyrics_service.dart';
import '../domain/song.dart';
import 'music_providers.dart';
import 'music_queue_sheet.dart';

import '../../../core/localization/app_strings.dart';
/// Full-screen Music Player matching MX Player (UI PDF page 5 right)
/// Vinyl record + controls + Lyrics/Playing Queue tabs
class MusicPlayerScreen extends ConsumerStatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  ConsumerState<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends ConsumerState<MusicPlayerScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _vinylController;

  @override
  void initState() {
    super.initState();
    _vinylController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    // Phase 32: Start spinning if already playing
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final p = ref.read(musicPlayingProvider);
        if (p.isPlaying) _vinylController.repeat();
      }
    });
  }

  @override
  void dispose() {
    _vinylController.dispose();
    super.dispose();
  }

  void _togglePlay() {
    // Phase 36: Just toggle. The build() ref.listen handles vinyl sync
    // reactively so we don't race the async state change.
    ref.read(musicPlayingProvider.notifier).togglePlay();
  }

  void _showEqualizer() {
    // Phase 38: open the real equalizer (was a placeholder snack).
    // Root navigator: the equalizer is a full-screen tool, and it is opened
    // from the now-playing screen which is itself full-screen — leaving the
    // tab bar under it is a visible seam.
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const EqualizerScreen()),
    );
  }

  /// Audit fix (real feature): bottom-sheet lyrics viewer that reads
  /// sidecar .lrc file from same folder as audio. Synced lines
  /// auto-scroll + highlight as song plays.
  void _showLyricsSheet(Song song) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _LyricsSheet(song: song),
    );
  }

  /// Audit fix (album art): icon-style fallback used when no embedded
  /// art exists, art bytes failed to decode, or art is still loading.
  Widget _albumArtFallback() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.darkSurface,
        border: Border.all(color: AppColors.white15, width: 1),
      ),
      child: const Icon(
        Icons.music_note,
        size: 40,
        color: AppColors.white50,
      ),
    );
  }

  /// Phase 38: real playback-speed picker (was a placeholder snack).
  String _fmtSpeed(double s) =>
      s == s.roundToDouble() ? s.toInt().toString() : s.toString();

  void _showSpeedPicker(double current) {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(AppStrings.of(context).playbackSpeed,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            for (final s in speeds)
              ListTile(
                title: Text(
                  '${_fmtSpeed(s)}x',
                  style: TextStyle(
                    color: (s - current).abs() < 0.001
                        ? AppColors.primaryBlue
                        : Colors.white,
                  ),
                ),
                trailing: (s - current).abs() < 0.001
                    ? const Icon(Icons.check, color: AppColors.primaryBlue)
                    : null,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  ref.read(musicPlayingProvider.notifier).setSpeed(s);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showSleepTimer() {
    final active = ref.read(musicPlayingProvider).sleepRemaining;
    showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).sleepTimer, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.timer_outlined,
                        color: AppColors.primaryBlue, size: 18),
                    const SizedBox(width: 8),
                    Text(AppStrings.of(context).stopsIn(_formatDuration(active)),
                      style: const TextStyle(
                          color: AppColors.primaryBlue, fontSize: 13),
                    ),
                  ],
                ),
              ),
            for (final mins in [15, 30, 45, 60, 90])
              ListTile(
                dense: true,
                title: Text('$mins minutes',
                    style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(dctx);
                  ref
                      .read(musicPlayingProvider.notifier)
                      .setSleepTimer(Duration(minutes: mins));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.of(context).sleepTimerSetMin(mins)),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ListTile(
              dense: true,
              title: Text(AppStrings.of(context).off, style: const TextStyle(color: Colors.white70)),
              onTap: () {
                Navigator.pop(dctx);
                ref.read(musicPlayingProvider.notifier).cancelSleepTimer();
                if (active != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.of(context).sleepTimerOff),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareSong(Song? song) async {
    if (song == null) return;
    try {
      await Share.share(song.uri, subject: song.title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppStrings.of(context).shareFailed}: $e')),
      );
    }
  }

  void _showSongInfo(Song? song) {
    if (song == null) return;
    final rows = <(String, String)>[
      ('Title', song.title),
      ('Artist', song.artist.isEmpty ? 'Unknown' : song.artist),
      ('Album', song.album.isEmpty ? 'Unknown' : song.album),
      ('Duration', _formatDuration(song.duration)),
      ('Size', song.formattedSize),
      ('Path', song.folderPath),
    ];
    showDialog<void>(
      context: context,
      builder: (dctx) => Dialog(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        color: AppColors.primaryBlue, size: 22),
                    const SizedBox(width: 12),
                    Text(AppStrings.of(context).information,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 80,
                              child: Text(
                                r.$1,
                                style: const TextStyle(
                                  color: AppColors.darkOnSurfaceMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                r.$2,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13),
                                softWrap: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(dctx).pop(),
                    child: Text(AppStrings.of(context).close,
                      style: const TextStyle(
                        color: AppColors.primaryBlue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _repeatLabelFor(MusicRepeatMode mode) {
    switch (mode) {
      case MusicRepeatMode.all:
        return 'Repeat all';
      case MusicRepeatMode.one:
        return 'Repeat one';
      case MusicRepeatMode.off:
        return 'Repeat off';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Phase 36: Reactive vinyl rotation — sync with actual isPlaying state
    ref.listen<MusicPlayingState>(musicPlayingProvider, (prev, next) {
      if (prev?.isPlaying == next.isPlaying) {
        // Audit fix (M3): even if isPlaying hasn't changed, surface
        // newly-arrived error messages via a brief snackbar so the
        // user knows why the song they tapped isn't actually playing
        // (codec missing, file moved, network failure for streams).
        final newErr = next.errorMessage;
        if (newErr != null &&
            newErr.isNotEmpty &&
            prev?.errorMessage != newErr) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text('${AppStrings.of(context).playbackError}: $newErr'),
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
            ));
        }
        return;
      }
      if (next.isPlaying) {
        if (!_vinylController.isAnimating) _vinylController.repeat();
      } else {
        _vinylController.stop();
      }
      // Audit fix (M3): also surface errors on isPlaying changes.
      final newErr = next.errorMessage;
      if (newErr != null &&
          newErr.isNotEmpty &&
          prev?.errorMessage != newErr) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('${AppStrings.of(context).playbackError}: $newErr'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ));
      }
    });

    final playing = ref.watch(musicPlayingProvider);
    final song = playing.song;
    final title = song?.title ?? 'Unknown Track';
    final artist = song?.displayArtist ?? 'Unknown artist';
    final duration = song?.duration ?? const Duration(minutes: 4, seconds: 13);
    final isPlaying = playing.isPlaying;
    final progress = duration.inSeconds == 0
        ? 0.0
        : playing.position.inSeconds / duration.inSeconds;
    final currentPos = playing.position;
    final favs = ref.watch(musicPlaylistProvider).firstWhere(
          (p) => p.id == 'favs',
          orElse: () => const MusicPlaylist(
              id: 'favs',
              name: 'My Favourites',
              songUris: [],
              builtIn: true),
        );
    final isFavourite = song != null && favs.songUris.contains(song.uri);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: SafeArea(
        child: Column(
          children: [
            // ─── TOP BAR ───
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Collapse',
                    icon: const Icon(Icons.keyboard_arrow_down,
                        color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          artist,
                          style: const TextStyle(
                            color: AppColors.white60,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Share',
                    icon: const Icon(Icons.share_outlined,
                        color: Colors.white, size: 22),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(AppStrings.of(context).shareTrack)),
                      );
                    },
                  ),
                ],
              ),
            ),

            const Spacer(flex: 1),

            // ─── VINYL DISC ───
            AnimatedBuilder(
              animation: _vinylController,
              builder: (_, child) {
                return Transform.rotate(
                  angle: _vinylController.value * 2 * pi,
                  child: child,
                );
              },
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1A1A2E),
                  border: Border.all(
                      color: AppColors.white10, width: 2),
                  boxShadow: const [
                    BoxShadow(
                      color: AppColors.black40,
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  // Audit fix (real album art): show embedded cover
                  // when available, falling back to music-note icon.
                  // Watched per-URI so swapping songs updates art.
                  child: Builder(builder: (ctx) {
                    final song = ref.watch(
                        musicPlayingProvider.select((s) => s.song));
                    if (song == null) return _albumArtFallback();
                    final asyncArt =
                        ref.watch(albumArtProvider(song.uri));
                    return asyncArt.when(
                      data: (bytes) {
                        if (bytes == null || bytes.isEmpty) {
                          return _albumArtFallback();
                        }
                        return ClipOval(
                          child: Image.memory(
                            Uint8List.fromList(bytes),
                            width: 160,
                            height: 160,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) =>
                                _albumArtFallback(),
                          ),
                        );
                      },
                      loading: () => _albumArtFallback(),
                      error: (_, __) => _albumArtFallback(),
                    );
                  }),
                ),
              ),
            ),

            const Spacer(flex: 1),

            // ─── 5 ACTION ICONS (Equalizer / A→B Repeat / Speed / Heart / ⋮) ───
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.equalizer,
                        color: AppColors.white70, size: 24),
                    onPressed: _showEqualizer,
                    tooltip: 'Equalizer',
                  ),
                  IconButton(
                    icon: Icon(Icons.swap_horiz,
                        color: playing.abPointA != null
                            ? AppColors.primaryBlue
                            : AppColors.white70,
                        size: 24),
                    onPressed: () {
                      ref.read(musicPlayingProvider.notifier).cycleAbRepeat();
                      final st = ref.read(musicPlayingProvider);
                      final s = AppStrings.of(context);
                      final msg = st.isAbArmed
                          ? s.abPointASet
                          : st.isAbActive
                              ? s.abRepeatOn
                              : s.abRepeatOff;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          duration: const Duration(milliseconds: 1400),
                        ),
                      );
                    },
                    tooltip: 'A-B Repeat',
                  ),
                  IconButton(
                    icon: Icon(Icons.speed,
                        color: playing.playbackSpeed != 1.0
                            ? AppColors.primaryBlue
                            : AppColors.white70,
                        size: 24),
                    onPressed: () => _showSpeedPicker(playing.playbackSpeed),
                    tooltip: 'Speed',
                  ),
                  IconButton(
                    icon: Icon(
                      isFavourite ? Icons.favorite : Icons.favorite_border,
                      color: isFavourite
                          ? Colors.redAccent
                          : AppColors.white70,
                      size: 24,
                    ),
                    onPressed: () {
                      if (song == null) return;
                      ref
                          .read(musicPlaylistProvider.notifier)
                          .toggleFavourite(song.uri);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(!isFavourite
                              ? AppStrings.of(context).addedToFavourites
                              : AppStrings.of(context).removedFromFavourites),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    tooltip: 'Favourite',
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert,
                        color: AppColors.white70, size: 24),
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: AppColors.darkSurface,
                        shape: const RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(16)),
                        ),
                        builder: (_) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.access_time,
                                    color: Colors.white70),
                                title: Text(AppStrings.of(context).sleepTimer,
                                    style: const TextStyle(color: Colors.white)),
                                onTap: () {
                                  Navigator.pop(context);
                                  _showSleepTimer();
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.share,
                                    color: Colors.white70),
                                title: Text(AppStrings.of(context).share,
                                    style: const TextStyle(color: Colors.white)),
                                onTap: () {
                                  Navigator.pop(context);
                                  _shareSong(song);
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.info_outline,
                                    color: Colors.white70),
                                title: Text(AppStrings.of(context).information,
                                    style: const TextStyle(color: Colors.white)),
                                onTap: () {
                                  Navigator.pop(context);
                                  _showSongInfo(song);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    tooltip: 'More',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ─── PROGRESS BAR ───
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  SliderTheme(
                    data: const SliderThemeData(
                      thumbShape:
                          RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          RoundSliderOverlayShape(overlayRadius: 14),
                      trackHeight: 3,
                      activeTrackColor: AppColors.primaryBlue,
                      inactiveTrackColor:
                          AppColors.white20,
                      thumbColor: AppColors.primaryBlue,
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (v) {
                        if (duration.inSeconds == 0) return;
                        final pos = Duration(
                            seconds: (duration.inSeconds * v).round());
                        ref
                            .read(musicPlayingProvider.notifier)
                            .setPosition(pos);
                      },
                      // Audit fix (Phase B): TalkBack-friendly position
                      // announcement instead of "50 %".
                      semanticFormatterCallback: (v) {
                        final pos = Duration(
                            seconds: (duration.inSeconds * v).round());
                        String fmt(Duration d) {
                          final m = d.inMinutes;
                          final s = d.inSeconds.remainder(60)
                              .toString()
                              .padLeft(2, '0');
                          return '$m min $s sec';
                        }
                        return 'Position ${fmt(pos)} of ${fmt(duration)}';
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(currentPos),
                          style: const TextStyle(
                            color: AppColors.white60,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: const TextStyle(
                            color: AppColors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ─── TRANSPORT CONTROLS ───
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Shuffle',
                    icon: Icon(
                      Icons.shuffle,
                      color: playing.isShuffled
                          ? AppColors.primaryBlue
                          : AppColors.white70,
                      size: 24,
                    ),
                    onPressed: () {
                      ref
                          .read(musicPlayingProvider.notifier)
                          .toggleShuffle();
                      final on = ref.read(musicPlayingProvider).isShuffled;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(on ? 'Shuffle on' : 'Shuffle off'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Previous',
                    icon: const Icon(Icons.skip_previous,
                        color: Colors.white, size: 36),
                    onPressed: () {
                      ref.read(musicPlayingProvider.notifier).previous();
                    },
                  ),
                  // Big play button — outlined white circle (MX parity)
                  GestureDetector(
                    onTap: _togglePlay,
                    child: Semantics(
                      // Audit fix (Phase B): the play/pause control is a
                      // GestureDetector (not IconButton) so it has no
                      // tooltip. Add explicit Semantics so TalkBack
                      // announces the action AND its current state.
                      button: true,
                      label: isPlaying ? 'Pause' : 'Play',
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.transparent,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Icon(
                          isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    icon: const Icon(Icons.skip_next,
                        color: Colors.white, size: 36),
                    onPressed: () {
                      ref.read(musicPlayingProvider.notifier).next();
                    },
                  ),
                  // Loop button with "1" badge in repeat-one mode (MX parity)
                  IconButton(
                    tooltip: 'Repeat',
                    icon: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          Icons.repeat,
                          color: playing.repeatMode != MusicRepeatMode.off
                              ? AppColors.primaryBlue
                              : AppColors.white70,
                          size: 24,
                        ),
                        // MX shows a tiny "1" badge for repeat-one
                        if (playing.repeatMode == MusicRepeatMode.one)
                          Positioned(
                            top: -2,
                            right: -4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 3, vertical: 0),
                              decoration: const BoxDecoration(
                                color: AppColors.primaryBlue,
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 12,
                                minHeight: 12,
                              ),
                              alignment: Alignment.center,
                              child: const Text(
                                '1',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    onPressed: () {
                      ref.read(musicPlayingProvider.notifier).cycleRepeat();
                      final mode = ref.read(musicPlayingProvider).repeatMode;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(_repeatLabelFor(mode)),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ─── LYRICS / PLAYING QUEUE TABS ───
            Container(
              height: 48,
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(
                      color: AppColors.white10),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        // Audit fix (real feature): open lyrics sheet
                        // reading sidecar .lrc file from same folder.
                        final song = ref
                            .read(musicPlayingProvider)
                            .song;
                        if (song == null) return;
                        _showLyricsSheet(song);
                      },
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.lyrics_outlined,
                              color: AppColors.white70,
                              size: 18),
                          const SizedBox(width: 8),
                          Text(AppStrings.of(context).lyrics,
                            style: const TextStyle(
                              color: AppColors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 24,
                    color: AppColors.white10,
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => MusicQueueSheet.show(context),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.queue_music,
                              color: AppColors.white70,
                              size: 18),
                          const SizedBox(width: 8),
                          Text(AppStrings.of(context).playingQueueTitle,
                            style: const TextStyle(
                              color: AppColors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Audit fix (real feature): synced lyrics sheet showing scrollable
/// list of [LyricLine]s with current timestamp highlighted.
class _LyricsSheet extends ConsumerStatefulWidget {
  final Song song;
  const _LyricsSheet({required this.song});

  @override
  ConsumerState<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends ConsumerState<_LyricsSheet> {
  final _scrollCtrl = ScrollController();
  int _lastActiveIndex = -1;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncLyrics =
        ref.watch(lyricsForSongProvider(widget.song.uri));
    final position = ref.watch(
        musicPlayingProvider.select((s) => s.position));

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.song.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(AppStrings.of(context).lyrics,
                          style: const TextStyle(
                            color: AppColors.white50,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white70, size: 22),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(color: AppColors.darkDivider, height: 24),
              Expanded(
                child: asyncLyrics.when(
                  loading: () => const Center(
                      child: CircularProgressIndicator()),
                  error: (_, __) =>
                      _emptyState('Error reading lyrics file.'),
                  data: (lines) {
                    if (lines == null || lines.isEmpty) {
                      return _emptyState(
                        'No lyrics found.\n\n'
                        'To add lyrics, place an .lrc file next to '
                        'your audio with the same filename — e.g. '
                        'song.mp3 → song.lrc. The file should contain '
                        'lines like [00:12.34]Lyric text.',
                      );
                    }
                    int activeIdx = -1;
                    for (int i = 0; i < lines.length; i++) {
                      final ts = lines[i].timestamp;
                      if (ts == null) continue;
                      if (ts <= position) {
                        activeIdx = i;
                      } else {
                        break;
                      }
                    }
                    if (activeIdx >= 0 && activeIdx != _lastActiveIndex) {
                      _lastActiveIndex = activeIdx;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!_scrollCtrl.hasClients) return;
                        final target = (activeIdx * 56.0) - 120;
                        _scrollCtrl.animateTo(
                          target.clamp(0.0,
                              _scrollCtrl.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      });
                    }
                    return ListView.builder(
                      controller: _scrollCtrl,
                      itemCount: lines.length,
                      itemBuilder: (_, i) {
                        final line = lines[i];
                        final isActive = i == activeIdx;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 4),
                          child: Text(
                            line.text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isActive
                                  ? Colors.white
                                  : AppColors.white50,
                              fontSize: isActive ? 17 : 14,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              height: 1.4,
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
        );
      },
    );
  }

  Widget _emptyState(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.white70,
            fontSize: 13,
            height: 1.55,
          ),
        ),
      ),
    );
  }
}
