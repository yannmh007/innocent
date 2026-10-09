import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/cache/scan_gate.dart';
import 'library_provider.dart';

/// A VIDEO THAT ARRIVES ON THE PHONE IS IN THE LIBRARY SECONDS LATER — as on
/// MX Player, with nobody pulling to refresh.
///
/// Two signals, because neither alone covers every case:
///
/// * MediaStore says so (MediaChangeWatcher.kt: a ContentObserver on the
///   video tables, a burst folded into one event). While the app is in front
///   the library is rescanned at once; in the background the change is only
///   remembered, and the rescan waits for the app to come back — a phone
///   downloading a season overnight does not rescan the library forty times
///   for nobody.
/// * The app comes back to the front and MediaStore's generation has moved
///   since the last scan ([ScanGate.changedSince]): changes made while the
///   process was not running at all, which no observer can hear.
///
/// Signals landing together (a resume and an event) make one rescan; one
/// arriving while a scan runs restarts it, and Riverpod drops the stale run.
/// Kept alive for the session by a watch in the shell.
class LibraryWatcher with WidgetsBindingObserver {
  LibraryWatcher(this._rescan);

  final void Function() _rescan;
  static const EventChannel _events = EventChannel('mx_clone/media_changes');

  StreamSubscription<dynamic>? _sub;
  bool _pending = false;
  Timer? _settle;

  void start() {
    if (kIsWeb || !Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    _sub = _events.receiveBroadcastStream().listen(
          (_) => _changed(),
          onError: (Object _) {},
        );
  }

  bool get _inFront =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void _changed() {
    if (!_inFront) {
      _pending = true;
      return;
    }
    _run();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_pending) {
      _pending = false;
      _run();
      return;
    }
    unawaited(() async {
      if (await ScanGate.changedSince('all')) _run();
    }());
  }

  /// One rescan per moment: a resume and an event landing together are one.
  void _run() {
    if (_settle?.isActive ?? false) return;
    _settle = Timer(const Duration(milliseconds: 300), _rescan);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settle?.cancel();
    unawaited(_sub?.cancel());
  }
}

/// Watched by the shell for the life of the app.
final libraryWatcherProvider = Provider<LibraryWatcher>((ref) {
  final w = LibraryWatcher(() => rescanLibrary(ref));
  ref.onDispose(w.dispose);
  w.start();
  return w;
});
