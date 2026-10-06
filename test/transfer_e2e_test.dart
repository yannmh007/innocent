import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:innocent/core/services/file_transfer/download_isolate.dart';
import 'package:innocent/core/services/file_transfer/file_receiver_service.dart';
import 'package:innocent/core/services/file_transfer/file_transfer_service.dart';

/// Phone to phone, for real: the sender's HTTP server (FileTransferService)
/// and the receiver's download engine (TransferEngine, also in its isolate)
/// talking over a socket on this machine — every byte compared.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HTTP request with a fake 400; these are
  // real sockets to a real server, so hand HTTP back to dart:io.
  setUpAll(() => HttpOverrides.global = null);

  late Directory tmp;
  late FileTransferService svc;
  late String base;
  late Map<String, List<int>> content;
  late List<SharedFile> shared;

  List<int> randomBytes(int n, int seed) {
    final r = Random(seed);
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xfer');
    final src = Directory('${tmp.path}/src')..createSync();
    content = <String, List<int>>{
      'film.mkv': randomBytes(21 * 1024 * 1024 + 333, 1), // 3 parallel ranges
      'ငါ့ဓာတ်ပုံ.jpg': randomBytes(150000, 2),
      'empty.txt': <int>[],
      'big.mp4': randomBytes(5 * 1024 * 1024 + 1, 3), // just over the split
    };
    shared = <SharedFile>[];
    var i = 0;
    for (final e in content.entries) {
      final f = File('${src.path}/${e.key}')..writeAsBytesSync(e.value);
      shared.add(SharedFile(
          id: '${i++}',
          path: f.path,
          displayName: e.key,
          sizeBytes: e.value.length));
    }
    svc = FileTransferService();
    final r = await svc.start(shared, preferredIp: '127.0.0.1');
    base = 'http://127.0.0.1:${r.port}/${svc.token}';
  });

  tearDown(() async {
    await svc.stop();
    await tmp.delete(recursive: true);
  });

  Future<List<RemoteFile>> manifest() =>
      FileReceiverService().fetchManifest(base);

  Future<List<int>> pull(RemoteFile f,
      {bool isolate = false, String? part}) async {
    final path = part ?? '${tmp.path}/${f.index}.part';
    final job = TransferJob(
      baseUrl: base,
      index: f.index,
      partPath: path,
      size: f.size,
      segments: FileReceiverService.segmentsFor(f.size),
    );
    if (isolate) {
      final w = await IsolateDownloader.spawn();
      expect(w, isNotNull, reason: 'the isolate engine should spawn here');
      await w!.run(job, (_, __, ___, ____) {});
      await w.dispose();
    } else {
      await TransferEngine().run(job, (_, __, ___, ____) {});
    }
    return File(path).readAsBytesSync();
  }

  test('the manifest lists every file with its exact size', () async {
    final m = await manifest();
    expect(m.map((f) => f.name).toList(), content.keys.toList());
    for (final f in m) {
      expect(f.size, content[f.name]!.length, reason: f.name);
    }
  });

  test('every file arrives byte for byte (in-process engine)', () async {
    for (final f in await manifest()) {
      expect(await pull(f), content[f.name], reason: f.name);
    }
  });

  test('…and through the background-isolate engine the app really uses',
      () async {
    final m = await manifest();
    final film = m.firstWhere((f) => f.name == 'film.mkv');
    expect(await pull(film, isolate: true), content['film.mkv']);
  });

  test('an interrupted download resumes from its .part', () async {
    final film = (await manifest()).firstWhere((f) => f.name == 'film.mkv');
    final part = '${tmp.path}/resume.part';
    final head = content['film.mkv']!.sublist(0, 7 * 1024 * 1024 + 17);
    File(part).writeAsBytesSync(head);
    expect(await pull(film, part: part), content['film.mkv']);
  });

  test('a sender pause holds the receiver, which then finishes', () async {
    final big = (await manifest()).firstWhere((f) => f.name == 'big.mp4');
    svc.paused = true;
    final paused = <bool>[];
    final job = TransferJob(
        baseUrl: base,
        index: big.index,
        partPath: '${tmp.path}/p.part',
        size: big.size,
        segments: 2);
    final run = TransferEngine().run(job, (_, __, ___, p) => paused.add(p));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    svc.paused = false;
    await run.timeout(const Duration(seconds: 60));
    expect(paused, contains(true),
        reason: 'the UI must be told it is a pause, not a stall');
    expect(File('${tmp.path}/p.part').readAsBytesSync(), content['big.mp4']);
  });

  test('files added mid-share appear in the manifest, old indices unchanged',
      () async {
    final extra = File('${tmp.path}/src/late.mp3')
      ..writeAsBytesSync(randomBytes(4000, 9));
    final before = await manifest();
    expect(
        svc.appendFiles([
          SharedFile(
              id: 'x',
              path: extra.path,
              displayName: 'late.mp3',
              sizeBytes: 4000)
        ]),
        1);
    final after = await manifest();
    expect(after.length, before.length + 1);
    for (var i = 0; i < before.length; i++) {
      expect(after[i].name, before[i].name);
    }
    expect(await pull(after.last), extra.readAsBytesSync());
  });

  test('ranges: a seek, the tail, and past the end', () async {
    final m = await manifest();
    final film = m.firstWhere((f) => f.name == 'film.mkv');
    final url = Uri.parse('$base/${film.index}');
    final mid = await http.get(url, headers: {'range': 'bytes=1000-1999'});
    expect(mid.statusCode, 206);
    expect(mid.bodyBytes, content['film.mkv']!.sublist(1000, 2000));
    final tail = await http.get(url, headers: {'range': 'bytes=-100'});
    expect(tail.statusCode, 206);
    expect(tail.bodyBytes,
        content['film.mkv']!.sublist(content['film.mkv']!.length - 100));
    final past =
        await http.get(url, headers: {'range': 'bytes=${film.size + 5}-'});
    expect(past.statusCode, 416);
  });

  test('without the token nothing is served', () async {
    final port = Uri.parse(base).port;
    expect(
        (await http
                .get(Uri.parse('http://127.0.0.1:$port/wrongtoken/manifest')))
            .statusCode,
        404);
    expect(
        (await http.get(Uri.parse('http://127.0.0.1:$port/wrongtoken/0')))
            .statusCode,
        404);
    expect(
        (await http.get(Uri.parse('http://127.0.0.1:$port/ping'))).statusCode,
        200);
  });

  test(
      'PIN: none / wrong are refused alike, five misses lock, the right one pairs',
      () async {
    final origin = 'http://127.0.0.1:${Uri.parse(base).port}';
    svc.pin = '4821';
    Future<http.Response> pair(String pin) =>
        http.get(Uri.parse('$origin/pair?id=a&name=Phone&pin=$pin'));
    expect(
        (await http.get(Uri.parse('$origin/pair?id=a&name=Phone'))).statusCode,
        401);
    expect((await pair('1111')).statusCode, 401);
    final ok = await pair('4821');
    expect(ok.statusCode, 200);
    final j = jsonDecode(ok.body) as Map<String, dynamic>;
    expect(j['token'], svc.token);
    expect((j['files'] as List).length, content.length);
    for (var i = 0; i < 5; i++) {
      await pair('0000');
    }
    expect((await pair('4821')).statusCode, 429,
        reason: 'locked out after five misses');
  });

  test('ask before sending: the sender decides, the receiver is told',
      () async {
    final origin = 'http://127.0.0.1:${Uri.parse(base).port}';
    svc.requireApproval = true;
    final decisions = <bool>[true, false];
    final sub = svc.pairRequests
        .listen((r) => r.decision.complete(decisions.removeAt(0)));
    final yes = await http.get(Uri.parse('$origin/pair?id=b&name=Ko%20Aung'));
    expect(yes.statusCode, 200);
    expect(svc.peers.single.name, 'Ko Aung');
    final no = await http.get(Uri.parse('$origin/pair?id=c&name=Stranger'));
    expect(no.statusCode, 403);
    await sub.cancel();
  });

  test('a browser upload lands in the folder, and cannot climb out of it',
      () async {
    final inbox = Directory('${tmp.path}/inbox')..createSync();
    svc.uploadDir = inbox;
    Future<http.Response> up(String name, List<int> body) =>
        http.post(Uri.parse('$base/up?name=${Uri.encodeQueryComponent(name)}'),
            body: body);
    final r1 = await up('holiday.mp4', randomBytes(70000, 5));
    expect(r1.statusCode, 200);
    expect(File('${inbox.path}/holiday.mp4').lengthSync(), 70000);
    for (final evil in <String>[
      '../escape.txt',
      '..',
      '/etc/passwd',
      r'..\win.txt'
    ]) {
      expect((await up(evil, <int>[1, 2, 3])).statusCode, 200, reason: evil);
    }
    expect(File('${tmp.path}/escape.txt').existsSync(), isFalse);
    for (final f in inbox.listSync()) {
      expect(f.parent.path, inbox.path, reason: f.path);
    }
    expect(inbox.listSync().length, 5);
  });
}
