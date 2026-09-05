import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';

/// Extension on Riverpod's [AsyncValue] that supplies standard
/// loading and error widgets so call sites don't have to repeat the
/// same boilerplate. Use [whenOrFallback] when the data view should
/// fade in from a spinner rather than render blank space.
///
/// The defaults are:
/// - **Loading**: a centred CircularProgressIndicator in the accent
///   colour, matched to the app's dark surface.
/// - **Error**: a centred Text showing the exception, intended to be
///   visible in debug builds and graceful in release.
///
/// Callers can still override either branch if they need a custom
/// presentation (e.g. shimmer skeletons, retry buttons).
extension AsyncValueX<T> on AsyncValue<T> {
  Widget whenOrFallback({
    required Widget Function(T data) data,
    Widget Function()? loading,
    Widget Function(Object error, StackTrace stackTrace)? error,
  }) {
    return when(
      data: data,
      loading: loading ?? _defaultLoading,
      error: error ?? _defaultError,
    );
  }
}

Widget _defaultLoading() {
  return const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor:
              AlwaysStoppedAnimation<Color>(AppColors.accentBlue),
        ),
      ),
    ),
  );
}

Widget _defaultError(Object e, StackTrace st) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.error, size: 32),
          const SizedBox(height: 12),
          Text(
            '$e',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.darkOnSurfaceMuted,
              fontSize: 13,
            ),
          ),
        ],
      ),
    ),
  );
}
