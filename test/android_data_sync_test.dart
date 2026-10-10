import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/local_browser/presentation/android_data_sync.dart';

/// Android/data's videos reach the Video tab when ADB comes up, however it
/// came up: connecting from Me → Hidden files used to leave the tab empty.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ValueNotifier<bool?> live;
  late DateTime clock;
  late int scans;
  late int probes;
  late int refreshed;
  late bool everConnected;
  late bool probeAnswer;
  late Duration idle;
  Completer<List<String>>? gate;

  AndroidDataSync make() => AndroidDataSync(
        onScanned: () => refreshed++,
        everConnected: () async => everConnected,
        probe: () async {
          probes++;
          return probeAnswer;
        },
        scan: () async {
          scans++;
          final g = gate;
          if (g != null) return g.future;
          return <String>['/storage/emulated/0/Android/data/a/v.mp4'];
        },
        live: live,
        now: () => clock,
        idleFor: () => idle,
        tick: const Duration(milliseconds: 1),
      );

  setUp(() {
    live = ValueNotifier<bool?>(null);
    clock = DateTime(2026, 10, 10, 9);
    scans = 0;
    probes = 0;
    refreshed = 0;
    everConnected = true;
    probeAnswer = false;
    idle = const Duration(hours: 1);
    gate = null;
  });

  // Long enough for the 1 ms wait-for-a-pause ticks and the scan after them.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('a connection made anywhere is followed by a scan and a refresh',
      () async {
    final sync = make()..start(observeLifecycle: false);
    await settle();
    expect(scans, 0, reason: 'not connected at start');

    // The Hidden files browser lists a folder: the connection is up.
    live.value = true;
    await settle();
    expect(scans, 1);
    expect(refreshed, 1, reason: 'the Video tab reads the scan again');
    expect(sync.lastFound, hasLength(1));
    sync.dispose();
  });

  test('a connection made while the start-up probe is asking is scanned',
      () async {
    // The probe at start is still out (answering "no") when Hidden files
    // lists its first folder.
    final sync = make()..start(observeLifecycle: false);
    live.value = true;
    await settle();
    await settle();
    expect(scans, 1);
    expect(refreshed, 1);
    sync.dispose();
  });

  test('while the connection is in use, the scan waits for a pause',
      () async {
    // Somebody is going through folders in Hidden files.
    idle = Duration.zero;
    final sync = make()..start(observeLifecycle: false);
    live.value = true;
    await settle();
    expect(scans, 0, reason: 'their next folder would wait for the scan');
    expect(sync.waiting, isTrue);

    idle = AndroidDataSync.quiet;
    await settle();
    expect(scans, 1);
    expect(sync.waiting, isFalse);
    sync.dispose();
  });

  test('already connected at start: scanned at once', () async {
    probeAnswer = true;
    final sync = make()..start(observeLifecycle: false);
    await settle();
    await settle();
    expect(probes, 1);
    expect(scans, 1);
    sync.dispose();
  });

  test('down and up again within two minutes does not scan twice', () async {
    final sync = make()..start(observeLifecycle: false);
    live.value = true;
    await settle();
    live.value = false;
    live.value = true;
    await settle();
    expect(scans, 1);

    clock = clock.add(AndroidDataSync.fresh);
    live.value = false;
    live.value = true;
    await settle();
    expect(scans, 2, reason: 'a reconnect later is scanned again');
    sync.dispose();
  });

  test('the Scan button forces one', () async {
    final sync = make()..start(observeLifecycle: false);
    live.value = true;
    await settle();
    final found = await sync.sync(connected: true, force: true);
    expect(scans, 2);
    expect(found, isNotNull);
    sync.dispose();
  });

  test('callers at the same moment share one scan', () async {
    gate = Completer<List<String>>();
    final sync = make();
    final a = sync.sync(connected: true);
    final b = sync.sync(connected: true);
    final c = sync.sync(connected: true, force: true);
    gate!.complete(<String>['/x.mp4']);
    expect(await a, <String>['/x.mp4']);
    expect(await b, <String>['/x.mp4']);
    expect(await c, <String>['/x.mp4']);
    expect(scans, 1);
  });

  test('nobody who never connected is probed', () async {
    everConnected = false;
    final sync = make();
    expect(await sync.sync(), isNull);
    expect(probes, 0);
    expect(scans, 0);
  });

  test('no connection: no scan, and the next try is not held back', () async {
    final sync = make();
    expect(await sync.sync(), isNull);
    expect(probes, 1);
    expect(scans, 0);
    probeAnswer = true;
    expect(await sync.sync(), isNotNull);
    expect(scans, 1);
  });

  test('a failing scan is reported as null and not retried at once',
      () async {
    final sync = AndroidDataSync(
      onScanned: () => refreshed++,
      everConnected: () async => true,
      probe: () async => true,
      scan: () async {
        scans++;
        throw Exception('ERROR: connection dropped');
      },
      live: live,
      now: () => clock,
    );
    expect(await sync.sync(connected: true), isNull);
    expect(refreshed, 0, reason: 'the videos already shown are kept');
    await sync.sync(connected: true);
    expect(scans, 1);
  });

  test('a return to the app scans only when the last scan is old', () async {
    probeAnswer = true;
    final sync = make();
    await sync.sync();
    expect(scans, 1);

    sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(scans, 1);

    clock = clock.add(AndroidDataSync.resumeEvery);
    sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    await settle();
    expect(scans, 2);
  });
}
