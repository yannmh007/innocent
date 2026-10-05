import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/backend_config.dart';
import '../data/api/event_sender.dart';
import '../data/watch_state_store.dart';
import 'account_provider.dart';
import 'video_hub_provider.dart';

/// Where the viewer stopped in each catalogue video — on this phone at once,
/// and from the server (the account's other phones) when it answers. See
/// [WatchPoint] for why the Movies feature keeps this rather than the player.
///
/// Read by the detail page ("Resume 12:34" / "Start over"), the Continue
/// watching row's progress bars, and [playMedia], which opens a stream at the
/// held position. Written by the player screen every progress sample.
class WatchPointsNotifier extends StateNotifier<WatchLedger> {
  WatchPointsNotifier(this._ref, {WatchStateStore store = const WatchStateStore()})
      : _store = store,
        super(WatchLedger.empty) {
    unawaited(_boot());
  }

  final Ref _ref;
  final WatchStateStore _store;
  Timer? _saveSoon;

  Future<void> _boot() async {
    final saved = await _store.load();
    if (!mounted) return;
    // Anything recorded before the load landed is kept on top of it.
    var merged = saved;
    for (final p in state.points) {
      merged = merged.record(p);
    }
    state = merged;
    if (!BackendConfig.isConfigured) return;
    _ref.listen<AccountState>(accountProvider, (prev, next) {
      if (next.isLoading) return;
      if (prev?.user?.id != next.user?.id || prev?.isLoading == true) {
        unawaited(pull());
      }
    }, fireImmediately: true);
  }

  /// Takes the server's copy. Silent on failure: the phone's own copy is
  /// still right for this phone.
  Future<void> pull() async {
    try {
      final server = await WatchStateStore.pull(_ref.read(apiClientProvider));
      if (!mounted || server.isEmpty) return;
      state = state.merge(server);
      _persistSoon();
    } catch (_) {}
  }

  /// One progress sample from the player.
  void record({
    required String titleId,
    String? assetId,
    required Duration position,
    required Duration duration,
    bool finished = false,
  }) {
    if (titleId.isEmpty) return;
    state = state.record(WatchPoint(
      titleId: titleId,
      assetId: assetId,
      positionS: position.inSeconds,
      durationS: duration.inSeconds,
      at: DateTime.now(),
      finished: finished,
    ));
    _persistSoon();
  }

  /// "Remove from Continue watching", as on Netflix: out of the row here at
  /// once, and on the server until the title is played again.
  void hide(String titleId) {
    state = state.hide(titleId);
    _persistSoon();
    try {
      _ref.read(eventSenderProvider).log(Ev.cwRemove, titleId: titleId);
    } catch (_) {}
  }

  /// Undo of [hide]: the ledger as it was.
  void restore(WatchLedger before) {
    state = before;
    _persistSoon();
  }

  void _persistSoon() {
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(milliseconds: 600), () {
      unawaited(_store.save(state));
    });
  }

  @override
  void dispose() {
    _saveSoon?.cancel();
    unawaited(_store.save(state));
    super.dispose();
  }
}

final watchPointsProvider =
    StateNotifierProvider<WatchPointsNotifier, WatchLedger>(
        (ref) => WatchPointsNotifier(ref));
