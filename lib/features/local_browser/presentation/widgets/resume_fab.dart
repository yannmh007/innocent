import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../user_data/user_data_providers.dart';

/// Phase 15: Floating Resume play button.
/// - Bottom-right of Local tab + folder detail
/// - Hides on scroll-up gesture, shows on scroll-down (MX Player parity)
/// - Tap: play the most recent in-progress (5%-95%) video, else last-watched
/// - Hidden entirely if no watch history at all
class ResumeFab extends ConsumerWidget {
  /// Listenable that emits scroll direction events (true = scrolling down, false = up).
  /// When null, the FAB is always visible.
  final ValueListenable<bool>? visibilityListenable;

  /// Long-press handler. Used by the Local tab to reveal the "Continue
  /// Watching" strip on demand (it's hidden by default). Tap keeps its normal
  /// "resume playback" behaviour.
  final VoidCallback? onLongPress;

  const ResumeFab({super.key, this.visibilityListenable, this.onLongPress});

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

  void _onTap(BuildContext context, WidgetRef ref) {
    final history = ref.read(publicHistoryProvider);
    if (history.isEmpty) return;

    // Most-recent first.
    final sorted = [...history]
      ..sort((a, b) => b.lastWatched.compareTo(a.lastWatched));

    // Prefer the most-recently-watched video that is still mid-way through,
    // so "Resume" actually resumes something rather than reopening a video
    // the user already finished (whose saved position has been cleared) at
    // 0:00. Only if every recent video is effectively finished do we fall
    // back to the single most-recent entry. The 0.95 ceiling matches the
    // threshold ResumeStorage uses to treat a video as "done".
    final entry = sorted.firstWhere(
      (e) => e.progress > 0.0 && e.progress < 0.95,
      orElse: () => sorted.first,
    );

    context.push(
      Routes.player,
      extra: {
        'uri': entry.videoUri,
        'title': entry.videoTitle.isNotEmpty
            ? entry.videoTitle
            : _displayName(entry.videoUri),
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(publicHistoryProvider);
    if (history.isEmpty) return const SizedBox.shrink();

    final fab = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onTap(context, ref),
        onLongPress: onLongPress == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onLongPress!();
              },
        customBorder: const CircleBorder(),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.specPrimary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.specPrimary.withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.play_arrow,
            color: Colors.white,
            size: 38,
          ),
        ),
      ),
    );

    if (visibilityListenable == null) return fab;

    return ValueListenableBuilder<bool>(
      valueListenable: visibilityListenable!,
      builder: (context, visible, child) {
        return AnimatedSlide(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          offset: visible ? Offset.zero : const Offset(0, 1.2),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: visible ? 1.0 : 0.0,
            child: child,
          ),
        );
      },
      child: fab,
    );
  }
}

/// Helper: Track scroll direction for hide-on-scroll-up behavior.
/// Attach to a ScrollController; visibility ValueNotifier flips false on
/// scrollDown direction (i.e. user dragged up) and true on scrollUp.
class FabScrollVisibility {
  final ValueNotifier<bool> visible = ValueNotifier(true);
  late final ScrollController controller;
  /// Phase 45: track whether we own the controller so dispose only
  /// tears it down when we created it. When the caller passes their
  /// own ScrollController they keep ownership.
  final bool _ownsController;

  FabScrollVisibility([ScrollController? existing])
      : _ownsController = existing == null {
    controller = existing ?? ScrollController();
    controller.addListener(_listener);
  }

  void _listener() {
    if (!controller.hasClients) return;
    // ScrollDirection.reverse = user dragged up (content moves up, list reveals more below)
    // We want: dragging up → hide FAB; dragging down → show FAB
    final dir = controller.position.userScrollDirection;
    if (dir.toString().contains('reverse')) {
      // Scrolling up (revealing below) → hide
      if (visible.value) visible.value = false;
    } else if (dir.toString().contains('forward')) {
      // Scrolling down (revealing above) → show
      if (!visible.value) visible.value = true;
    }
  }

  void dispose() {
    controller.removeListener(_listener);
    if (_ownsController) {
      controller.dispose();
    }
    visible.dispose();
  }
}
