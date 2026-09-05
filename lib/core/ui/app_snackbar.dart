import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Centralized snackbar helper for consistent durations + styling across the app.
///
/// Phase 38: Added a global [messengerKey]. Some flows (e.g. the video option
/// bottom sheet) pop their route BEFORE showing a confirmation toast — at that
/// point their `BuildContext` is defunct and `ScaffoldMessenger.of(context)`
/// would throw or silently no-op. The global key lets those flows surface a
/// toast on the root messenger regardless of which route is on top.
class AppSnackbar {
  AppSnackbar._();

  /// Attach this to `MaterialApp.scaffoldMessengerKey` so [global] works
  /// even after the originating route has been popped.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Short transient message (1.5s) — for ack like "Added"
  static void show(BuildContext context, String message) {
    _show(context, message, const Duration(milliseconds: 1500));
  }

  /// Standard message (2s) — for confirmations
  static void info(BuildContext context, String message) {
    _show(context, message, const Duration(seconds: 2));
  }

  /// Longer message (3s) — for messages with action info
  static void detail(BuildContext context, String message) {
    _show(context, message, const Duration(seconds: 3));
  }

  /// Error message (3s)
  static void error(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(_errorSnackBar(message));
  }

  /// Context-free toast — safe to call after the originating route is popped.
  /// Used by modal sheets/dialogs that dismiss themselves before confirming.
  static void global(String message,
      {Duration duration = const Duration(seconds: 2)}) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Context-free error toast.
  static void globalError(String message) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(_errorSnackBar(message));
  }

  static SnackBar _errorSnackBar(String message) {
    return SnackBar(
      content: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 18),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
      backgroundColor: AppColors.error,
      duration: const Duration(seconds: 3),
    );
  }

  static void _show(BuildContext context, String message, Duration duration) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
