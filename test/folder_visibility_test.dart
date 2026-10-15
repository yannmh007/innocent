import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';
import 'package:innocent/features/local_browser/domain/folder.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/folder_visibility.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hiding a folder from the Video tab, and Android/data's folders shown
/// only while ADB is connected.
const _movies = '/storage/emulated/0/Movies';
const _tg = '/storage/emulated/0/Android/data/org.telegram.messenger/files/'
    'Telegram/Telegram Video';

Video _v(String folder, String name, {bool adb = false}) => Video(
      id: '${adb ? 'adb:' : ''}$folder/$name',
      uri: '${adb ? 'adb://' : 'file://'}$folder/$name',
      title: name,
      folderPath: folder,
      duration: const Duration(minutes: 3),
      sizeBytes: 1000,
      width: 1280,
      height: 720,
    );

final _phone = <Video>[_v(_movies, 'a.mp4'), _v(_movies, 'b.mp4')];
final _app = <Video>[_v(_tg, 'film.mp4', adb: true)];

ProviderContainer _container() {
  final c = ProviderContainer(overrides: <Override>[
    foldersProvider.overrideWith((ref) async => const <Folder>[
          Folder(path: _movies, name: 'Movies', videoCount: 2),
        ]),
    allVideosProvider.overrideWith((ref) async => _phone),
    adbVideosProvider.overrideWith((ref) async => _app),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<List<String>> _folders(ProviderContainer c) async {
  await c.read(foldersProvider.future);
  await c.read(allVideosProvider.future);
  await c.read(adbVideosProvider.future);
  await pumpEventQueue();
  return <String>[
    for (final f in c.read(filteredFoldersProvider).requireValue) f.path,
  ];
}

List<String> _videos(ProviderContainer c) => <String>[
      for (final v in c.read(filteredAllVideosProvider).requireValue) v.title,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdbService.instance.live.value = null;
  });

  test('a hidden folder leaves the folder list and the Files view', () async {
    final c = _container();
    expect(await _folders(c), containsAll(<String>[_movies, _tg]));

    await c.read(folderVisibilityProvider.notifier).hide(<String>[_tg]);
    expect(await _folders(c), <String>[_movies]);
    expect(_videos(c), isNot(contains('film.mp4')));

    await c.read(folderVisibilityProvider.notifier).show(<String>[_tg]);
    expect(await _folders(c), contains(_tg));
    expect(_videos(c), contains('film.mp4'));
  });

  test('a phone folder can be hidden too, and is remembered', () async {
    final c = _container();
    await c.read(folderVisibilityProvider.notifier).hide(<String>[_movies]);
    expect(await _folders(c), <String>[_tg]);
    expect(_videos(c), <String>['film.mp4']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(FolderVisibilityNotifier.hiddenKey),
        <String>[_movies]);

    // A new start of the app reads it back.
    final again = _container();
    again.read(folderVisibilityProvider);
    await pumpEventQueue();
    expect(again.read(folderVisibilityProvider).hidden, <String>{_movies});
    expect(await _folders(again), <String>[_tg]);
  });

  test('"only while connected" follows the ADB connection', () async {
    final c = _container();
    await c
        .read(folderVisibilityProvider.notifier)
        .setAppFoldersOnlyWhileConnected(true);

    // Not known to be up: Android/data's folders are out of the list.
    expect(await _folders(c), <String>[_movies]);

    AdbService.instance.live.value = true;
    expect(await _folders(c), containsAll(<String>[_movies, _tg]));

    AdbService.instance.live.value = false;
    expect(await _folders(c), <String>[_movies]);
    // The phone's own folders never depend on ADB.
    expect(_videos(c), containsAll(<String>['a.mp4', 'b.mp4']));
  });

  test('the Show / hide list offers every Android/data folder', () async {
    final c = _container();
    await _folders(c);
    var rows = c.read(folderChoicesProvider);
    expect(rows.map((r) => r.path), <String>[_tg]);
    expect(rows.single.appFolder, isTrue);
    expect(rows.single.videoCount, 1);

    // A hidden phone folder joins it, so it can be shown again.
    await c.read(folderVisibilityProvider.notifier).hide(<String>[_movies]);
    rows = c.read(folderChoicesProvider);
    expect(rows.map((r) => r.path), containsAll(<String>[_movies, _tg]));
    expect(rows.firstWhere((r) => r.path == _movies).appFolder, isFalse);
  });

  test('a selection can name an Android/data video', () async {
    final c = _container();
    await _folders(c);
    final uris = c.read(selectableVideosProvider).map((v) => v.uri);
    expect(uris, contains('adb://$_tg/film.mp4'));
    expect(uris, contains('file://$_movies/a.mp4'));
  });
}
