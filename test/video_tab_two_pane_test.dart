// The Video tab on a wide window: the folders, and beside them the open
// folder's videos (core/ui/list_detail.dart, docs/devices_2026_11.md Phase
// 2) — and the search and Back rules that come with two panes, on a phone
// too. Driven through GoRouter and a real system Back, as Android sends it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/router/routes.dart';
import 'package:innocent/core/services/cache/media_prewarm_service.dart';
import 'package:innocent/core/theme/app_theme.dart';
import 'package:innocent/core/ui/list_detail.dart';
import 'package:innocent/features/local_browser/domain/folder.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/folder_detail_screen.dart';
import 'package:innocent/features/local_browser/presentation/folder_list_item.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:innocent/features/local_browser/presentation/local_screen.dart';
import 'package:innocent/features/local_browser/presentation/selection_provider.dart';
import 'package:innocent/features/local_browser/presentation/widgets/selection_app_bar.dart';
import 'package:innocent/features/shell/shell_back.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _camera = '/storage/emulated/0/DCIM/Camera';
const _movies = '/storage/emulated/0/Movies';
const _download = '/storage/emulated/0/Download';

const _folders = <Folder>[
  Folder(path: _camera, name: 'Camera', videoCount: 2),
  Folder(path: _download, name: 'Download', videoCount: 1),
  Folder(path: _movies, name: 'Movies', videoCount: 2),
];

Video _video(String folder, String title) => Video(
      id: title,
      uri: '$folder/$title',
      title: title,
      folderPath: folder,
      duration: const Duration(minutes: 3),
      sizeBytes: 1000000,
      width: 1920,
      height: 1080,
      dateAdded: DateTime(2026, 11, 1),
    );

final _videos = <Video>[
  _video(_camera, 'VID_20261012_190755.mp4'),
  _video(_camera, 'PXL_20261012_093011.mp4'),
  _video(_download, 'clip.mp4'),
  _video(_movies, 'Inception.2010.mkv'),
  _video(_movies, 'Arrival.2016.mkv'),
];

/// No background scan in a test.
class _NoWarm extends MediaPrewarmService {
  _NoWarm(super.ref);
  @override
  void start({String? priorityFolder}) {}
}

late GoRouter _router;
late ProviderContainer _container;

/// The Video tab in a shell with the shell's Back rule (ShellBackScope),
/// on a window [size] dp; a folder page and a player as routes over it.
Future<void> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  _router = GoRouter(initialLocation: Routes.local, routes: [
    ShellRoute(
      builder: (context, state, child) => Consumer(
        builder: (context, ref, _) => ShellBackScope(
          onFirstTab: true,
          undo: ref.watch(tabBackProvider(0)),
          toFirstTab: () {},
          child: Scaffold(
            body: Row(children: [
              const SizedBox(width: 80), // the rail
              Expanded(child: child),
            ]),
          ),
        ),
      ),
      routes: [
        GoRoute(
          path: Routes.local,
          pageBuilder: (c, s) => const NoTransitionPage(child: LocalScreen()),
        ),
      ],
    ),
    GoRoute(
      path: Routes.folderDetail,
      builder: (c, s) => FolderDetailScreen(
        folderPath: s.uri.queryParameters['path']!,
        folderName: s.uri.queryParameters['name']!,
      ),
    ),
    GoRoute(
      path: Routes.player,
      builder: (c, s) => const Scaffold(body: Text('the player')),
    ),
  ]);
  _container = ProviderContainer(overrides: [
    foldersProvider.overrideWith((ref) async => _folders),
    allVideosProvider.overrideWith((ref) async => _videos),
    videosInFolderProvider.overrideWith((ref, path) async =>
        _videos.where((v) => v.folderPath == path).toList()),
    mediaPrewarmProvider.overrideWith((ref) => _NoWarm(ref)),
  ]);
  addTearDown(_container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: _container,
    child: MaterialApp.router(
      theme: AppTheme.dark,
      locale: const Locale('en'),
      localizationsDelegates: AppStrings.localizationsDelegates,
      supportedLocales: AppStrings.supportedLocales,
      routerConfig: _router,
    ),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await _settle(tester);
}

/// Take the tree down and let one-shot timers run out.
Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

/// The folder as a page of its own, over the list (a phone).
Finder _folderPage([String? path]) => find.byWidgetPredicate(
    (w) =>
        w is FolderDetailScreen &&
        !w.embedded &&
        (path == null || w.folderPath == path),
    description: 'the folder page');

Finder _pane() =>
    find.byWidgetPredicate((w) => w is FolderDetailScreen && w.embedded,
        description: 'the open folder beside the list');

String _query() => _container.read(searchQueryProvider);

/// A folder's row in the list (its name is also a chip's, or the open
/// folder's title).
Finder _row(String name) =>
    find.byWidgetPredicate((w) => w is FolderListItem && w.folder.name == name,
        description: 'the $name folder row');

void main() {
  testWidgets('wide: the folders, and the first folder\'s videos beside them',
      (tester) async {
    await _pump(tester, const Size(1280, 800));
    expect(find.byType(ListDetailPanes), findsOneWidget);
    expect(_pane(), findsOneWidget);
    expect(tester.widget<FolderDetailScreen>(_pane()).folderPath, _camera);
    expect(find.text('VID_20261012_190755'), findsOneWidget);
    // Beside the list: no way back, no search of its own.
    expect(find.descendant(of: _pane(), matching: find.byIcon(Icons.search)),
        findsNothing);
    expect(
        find.descendant(
            of: _pane(), matching: find.byIcon(Icons.folder_copy_outlined)),
        findsNothing);
    await _end(tester);
  });

  testWidgets('wide: a folder tapped opens beside the list, not over it',
      (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(_row('Movies'));
    await _settle(tester);
    expect(tester.widget<FolderDetailScreen>(_pane()).folderPath, _movies);
    expect(find.text('Inception.2010'), findsOneWidget);
    expect(_folderPage(), findsNothing);
    await _end(tester);
  });

  testWidgets(
      'wide: a selection of the open folder\'s videos is the pane\'s; '
      'Back clears it, and so does opening another folder', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.longPress(find.text('VID_20261012_190755'));
    await _settle(tester);
    expect(_container.read(selectionProvider), isNotEmpty);
    // The selection's bar is the pane's, not the list's as well.
    expect(find.byType(SelectionAppBar), findsOneWidget);
    expect(find.descendant(of: _pane(), matching: find.byType(SelectionAppBar)),
        findsOneWidget);
    await _back(tester);
    expect(_container.read(selectionProvider), isEmpty);

    await tester.longPress(find.text('VID_20261012_190755'));
    await _settle(tester);
    await tester.tap(_row('Movies'));
    await _settle(tester);
    expect(_container.read(selectionProvider), isEmpty);
    await _end(tester);
  });

  testWidgets(
      'wide: a search that takes the open folder away takes its selection '
      'too', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byIcon(Icons.search));
    await _settle(tester);
    await tester.longPress(find.text('VID_20261012_190755'));
    await _settle(tester);
    expect(_container.read(selectionProvider), isNotEmpty);
    await tester.enterText(find.byType(TextField), 'inception');
    await _settle(tester);
    expect(tester.widget<FolderDetailScreen>(_pane()).folderPath, _movies);
    expect(_container.read(selectionProvider), isEmpty);
    await _end(tester);
  });

  testWidgets(
      'a folder found by its name shows all its videos; one found by a '
      'video\'s name shows that video', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.byIcon(Icons.search));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'camera');
    await _settle(tester);
    expect(tester.widget<FolderDetailScreen>(_pane()).folderPath, _camera);
    expect(find.text('VID_20261012_190755'), findsOneWidget);
    expect(find.text('PXL_20261012_093011'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'inception');
    await _settle(tester);
    // Camera is not in the results: the first folder that is opens.
    expect(tester.widget<FolderDetailScreen>(_pane()).folderPath, _movies);
    expect(find.text('Inception.2010'), findsOneWidget);
    expect(find.text('Arrival.2016'), findsNothing);
    await _end(tester);
  });

  testWidgets('Back closes the search and its query goes with it',
      (tester) async {
    await _pump(tester, const Size(400, 800));
    await tester.tap(find.byIcon(Icons.search));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'inception');
    await _settle(tester);
    expect(_row('Camera'), findsNothing);
    await _back(tester);
    expect(find.byType(TextField), findsNothing);
    expect(_query(), isEmpty);
    // The list is whole again, not silently filtered.
    expect(_row('Camera'), findsOneWidget);
    await _end(tester);
  });

  testWidgets(
      'a phone: a folder opens as a page; its own search keeps to itself '
      'and Back closes it before the folder', (tester) async {
    await _pump(tester, const Size(400, 800));
    expect(find.byType(ListDetailPanes), findsNothing);
    await tester.tap(_row('Movies'));
    await _settle(tester);
    expect(_folderPage(_movies), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'arrival');
    await _settle(tester);
    expect(find.text('Arrival.2016'), findsWidgets);
    expect(find.text('Inception.2010'), findsNothing);
    // The folder list behind it is not filtered by the folder's search.
    expect(_query(), isEmpty);
    await _back(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Inception.2010'), findsOneWidget);
    await _back(tester);
    expect(_folderPage(), findsNothing);
    expect(_row('Camera'), findsOneWidget);
    await _end(tester);
  });

  testWidgets(
      'a window narrowed to one pane keeps the folder the person opened — '
      'and not when the player is over the tab', (tester) async {
    await _pump(tester, const Size(1280, 800));
    // The first folder, shown by default, is not pushed.
    tester.view.physicalSize = const Size(700, 800);
    await _settle(tester);
    expect(_folderPage(), findsNothing);

    tester.view.physicalSize = const Size(1280, 800);
    await _settle(tester);
    await tester.tap(_row('Movies'));
    await _settle(tester);
    tester.view.physicalSize = const Size(700, 800);
    await _settle(tester);
    expect(_folderPage(_movies), findsOneWidget);
    expect(find.text('Inception.2010'), findsOneWidget);
    await _back(tester);
    expect(_folderPage(), findsNothing);

    // Wide again, Movies still open beside the list; the player opens.
    tester.view.physicalSize = const Size(1280, 800);
    await _settle(tester);
    expect(tester.widget<FolderDetailScreen>(_pane()).folderPath, _movies);
    await tester.tap(_row('Movies'));
    await _settle(tester);
    unawaited(_router.push(Routes.player));
    await _settle(tester);
    tester.view.physicalSize = const Size(700, 800);
    await _settle(tester);
    // Nothing pushed over the film.
    expect(find.text('the player'), findsOneWidget);
    expect(_folderPage(), findsNothing);
    await _end(tester);
  });
}
