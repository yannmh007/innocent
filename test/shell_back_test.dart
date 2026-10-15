import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:innocent/features/shell/shell_back.dart';

/// Back undoes what a tab is in the middle of before it leaves: with videos
/// selected, Back used to leave the app (a real phone, 11 Oct 2026). These
/// drive a real system Back through GoRouter, the way Android sends it.
final _selected = StateProvider<bool>((ref) => false);

class _Tab extends ConsumerStatefulWidget {
  const _Tab(this.index, {super.key});
  final int index;
  @override
  ConsumerState<_Tab> createState() => _TabState();
}

class _TabState extends ConsumerState<_Tab> with TabBack<_Tab> {
  bool searching = false;

  @override
  int get tabIndex => widget.index;

  @override
  Widget build(BuildContext context) {
    final selected = widget.index == 0 && ref.watch(_selected);
    tabBack(selected
        ? () => ref.read(_selected.notifier).state = false
        : searching
            ? () => setState(() => searching = false)
            : null);
    return Scaffold(
      body: Column(children: [
        Text('tab ${widget.index}'),
        if (selected) const Text('selecting'),
        if (searching) const Text('searching'),
        TextButton(
            onPressed: () => setState(() => searching = true),
            child: const Text('search')),
      ]),
    );
  }
}

void main() {
  late List<String> exits;
  late GoRouter router;

  Future<void> start(WidgetTester t) async {
    exits = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits.add('left the app');
      return null;
    });
    router = GoRouter(initialLocation: '/0', routes: [
      ShellRoute(
        navigatorKey: GlobalKey<NavigatorState>(),
        builder: (context, state, child) {
          final index = int.parse(state.uri.path.substring(1));
          return Consumer(
            builder: (context, ref, _) => ShellBackScope(
              onFirstTab: index == 0,
              undo: ref.watch(tabBackProvider(index)),
              toFirstTab: () => context.go('/0'),
              child: Scaffold(body: child),
            ),
          );
        },
        routes: [
          for (final i in [0, 1])
            GoRoute(
                path: '/$i',
                pageBuilder: (c, s) => NoTransitionPage(
                    key: s.pageKey, child: _Tab(i, key: ValueKey(i)))),
        ],
      ),
    ]);
    await t.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)));
  }

  Future<void> back(WidgetTester t) async {
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
  }

  testWidgets('Video tab: Back clears the selection, then leaves', (t) async {
    await start(t);
    final container = ProviderScope.containerOf(t.element(find.text('tab 0')));
    container.read(_selected.notifier).state = true;
    await t.pumpAndSettle();
    expect(find.text('selecting'), findsOneWidget);

    await back(t);
    expect(find.text('selecting'), findsNothing, reason: 'selection cleared');
    expect(exits, isEmpty, reason: 'still in the app');

    await back(t);
    expect(exits, ['left the app'], reason: 'nothing left to undo');
  });

  testWidgets('selection, then search, then out', (t) async {
    await start(t);
    await t.tap(find.text('search'));
    await t.pumpAndSettle();
    final container = ProviderScope.containerOf(t.element(find.text('tab 0')));
    container.read(_selected.notifier).state = true;
    await t.pumpAndSettle();

    await back(t);
    expect(find.text('selecting'), findsNothing);
    expect(find.text('searching'), findsOneWidget);
    await back(t);
    expect(find.text('searching'), findsNothing);
    expect(exits, isEmpty);
    await back(t);
    expect(exits, hasLength(1));
  });

  testWidgets('another tab: search closes, then the first tab, then out',
      (t) async {
    await start(t);
    router.go('/1');
    await t.pumpAndSettle();
    await t.tap(find.text('search'));
    await t.pumpAndSettle();

    await back(t);
    expect(find.text('searching'), findsNothing);
    expect(find.text('tab 1'), findsOneWidget);
    await back(t);
    expect(find.text('tab 0'), findsOneWidget);
    expect(exits, isEmpty);
    await back(t);
    expect(exits, hasLength(1));
  });

  testWidgets('a tab that goes away takes its undo with it', (t) async {
    await start(t);
    await t.tap(find.text('search'));
    await t.pumpAndSettle();
    final container = ProviderScope.containerOf(t.element(find.text('tab 0')));
    expect(container.read(tabBackProvider(0)), isNotNull);
    router.go('/1');
    await t.pumpAndSettle();
    expect(container.read(tabBackProvider(0)), isNull);
  });
}
