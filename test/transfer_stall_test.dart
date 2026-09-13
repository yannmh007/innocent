import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/file_transfer/download_isolate.dart';

/// The stall watchdog, proved against a real socket.
///
/// WHY A SERVER AND NOT A MOCK. The bug was not in logic anybody could reason
/// about — it was that `connectionTimeout` and `idleTimeout` sound like they
/// bound a download and do not. Only a peer that accepts, answers, sends some
/// bytes and then goes quiet reproduces it, so that is what these tests are.
///
/// The engine's own timeout is 30 s in production; these construct it with a
/// short one so the suite does not sit for minutes. Everything else — the
/// four-attempt retry loop, the backoff, the byte-count check — runs exactly
/// as it does on a phone.
void main() {
  late HttpServer server;
  late Directory tmp;
  late String base;

  /// Set by each test to decide how the server behaves.
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('innocent_stall_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    unawaited(() async {
      await for (final req in server) {
        // NOT awaited. A stalling handler parks forever by design, and
        // awaiting it here would stop the loop accepting — so the engine's
        // second retry got "connection refused" instead of a second stall,
        // and the test failed for the wrong reason. Each request is served
        // on its own future.
        unawaited(() async {
          try {
            await handler(req);
          } catch (_) {
            // A client that hung up mid-write is the normal end of these
            // tests.
          }
        }());
      }
    }());
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  TransferJob jobFor(int size) => TransferJob(
        baseUrl: base,
        index: 0,
        partPath: '${tmp.path}/file.bin',
        size: size,
        // 1 forces the sequential path. The parallel path is covered by its
        // own test below.
        segments: 1,
      );

  void noProgress(int a, int b, double c, bool d) {}

  test('a body that stops mid-stream fails instead of hanging forever', () async {
    // 1 MB promised, 16 KB delivered, then silence — and the connection is
    // deliberately NOT closed, because a closed connection is the case that
    // already worked. This is the sending phone freezing mid-share.
    handler = (HttpRequest req) async {
      req.response.headers.contentLength = 1024 * 1024;
      req.response.add(List<int>.filled(16 * 1024, 7));
      await req.response.flush();
      // Never closed. Held so the socket stays open and silent.
      await Completer<void>().future;
    };

    final engine = TransferEngine(
      stallTimeout: const Duration(milliseconds: 200),
    );

    // Asserted as a TimeoutException specifically, NOT `throwsA(isA<Object>())`.
    // The loose matcher was the first thing written here and it made the test
    // worthless: `fail()` throws a TestFailure, TestFailure is an Object, so
    // the test swallowed its own failure and passed with the watchdog removed.
    // Caught by mutating the fix away and watching the suite stay green.
    final Object? thrown = await _errorFrom(
      engine.run(jobFor(1024 * 1024), noProgress),
    );
    engine.closeClient();
    expect(thrown, isA<TimeoutException>(),
        reason: 'run() should end in a stall timeout, not hang or fail '
            'for another reason (got: $thrown)');
  });

  test('the parallel path is guarded too', () async {
    // Above parallelThreshold and with segments > 1, run() takes an entirely
    // different loop. Guarding one and not the other would leave the larger
    // files — the ones a stall costs most on — still hanging.
    handler = (HttpRequest req) async {
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.contentLength = 1024 * 1024;
      req.response.add(List<int>.filled(16 * 1024, 7));
      await req.response.flush();
      await Completer<void>().future;
    };

    final engine = TransferEngine(
      stallTimeout: const Duration(milliseconds: 200),
    );
    final job = TransferJob(
      baseUrl: base,
      index: 0,
      partPath: '${tmp.path}/big.bin',
      size: TransferEngine.parallelThreshold + 1,
      segments: 4,
    );

    final Object? thrown = await _errorFrom(engine.run(job, noProgress));
    engine.closeClient();
    expect(thrown, isA<TimeoutException>(),
        reason: 'the parallel loop should end in a stall timeout '
            '(got: $thrown)');
  });

  test('a healthy transfer is not cut off by the watchdog', () async {
    // The negative case, and the one that would catch a timeout set so tight
    // it breaks working transfers. Bytes arrive in bursts spaced wider than
    // half the timeout, so the clock is repeatedly reset and never expires.
    const int chunks = 6;
    const int chunkSize = 4 * 1024;
    handler = (HttpRequest req) async {
      req.response.headers.contentLength = chunks * chunkSize;
      for (var i = 0; i < chunks; i++) {
        req.response.add(List<int>.filled(chunkSize, 3));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await req.response.close();
    };

    final engine = TransferEngine(
      stallTimeout: const Duration(milliseconds: 400),
    );
    await engine.run(jobFor(chunks * chunkSize), noProgress);
    engine.closeClient();

    final part = File('${tmp.path}/file.bin');
    expect(await part.exists(), isTrue);
    expect(await part.length(), chunks * chunkSize);
  });

  test('a truncated body is a short read, not a stall', () async {
    // THE ONE THE FIX MUST NOT BREAK. The sender signals a pause by cutting
    // the response short (file_transfer_service.dart:861) — the stream ENDS
    // rather than going quiet, so it must land on the byte-count check and
    // the existing retry, never on the watchdog. If the watchdog ever started
    // catching this, a pause would burn the error budget and end the transfer.
    handler = (HttpRequest req) async {
      req.response.headers.contentLength = -1;
      req.response.add(List<int>.filled(8 * 1024, 5));
      await req.response.close();
    };

    final engine = TransferEngine(
      stallTimeout: const Duration(milliseconds: 200),
    );
    Object? thrown;
    try {
      await engine.run(jobFor(64 * 1024), noProgress);
    } catch (e) {
      thrown = e;
    }
    engine.closeClient();

    expect(thrown, isNotNull);
    expect(
      thrown,
      isNot(isA<TimeoutException>()),
      reason: 'a truncated body must not be reported as a stall',
    );
    expect('$thrown', contains('Incomplete download'));
  });
}

/// Await [work] and hand back whatever it threw.
///
/// The ceiling is a real part of the assertion: a hang is the bug, so it must
/// come back as something the caller can distinguish from a timeout the ENGINE
/// produced. `_Hung` is that something — it is not a TimeoutException, so a
/// hung run fails the expectation instead of satisfying it.
Future<Object?> _errorFrom(Future<void> work) async {
  try {
    await work.timeout(const Duration(seconds: 40),
        onTimeout: () => throw _Hung());
    return null;
  } catch (e) {
    return e;
  }
}

class _Hung implements Exception {
  @override
  String toString() => 'run() never returned — the watchdog did not fire';
}
