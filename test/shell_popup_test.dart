import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:innocent/core/ui/safe_popup_menu.dart';
import 'package:innocent/features/shell/shell_popup_guard.dart';

/// "Something didn't load" on the Me tab: a ⋮ menu opened on the Video tab,
/// then Me tapped in the bottom bar (which sits outside the tabs' navigator,
/// so it stayed live). Switching disposed the Video tab under the open menu,
/// and Flutter 3.32's PopupMenuButton asked its disposed State for a context
/// on the menu's next layout — a null-check crash in release, symbolized from
/// a real phone's report. These tests drive the same structure: a GoRouter
/// ShellRoute with its own navigator, and the bar outside it.
void main() {
  late ShellPopupGuard guard;
  late List<int> picked;

  GoRouter router({required Widget Function() tabA}) => GoRouter(
        initialLocation: '/a',
        routes: [
          ShellRoute(
            navigatorKey: GlobalKey<NavigatorState>(),
            observers: [guard],
            builder: (context, state, child) => Scaffold(
              body: child,
              bottomNavigationBar: PopupAwareBar(
                guard: guard,
                tabIndex: state.uri.path == '/a' ? 0 : 1,
                child: BottomNavigationBar(
                  currentIndex: state.uri.path == '/a' ? 0 : 1,
                  onTap: (i) => context.go(i == 0 ? '/a' : '/b'),
                  items: const [
                    BottomNavigationBarItem(
                        icon: Icon(Icons.video_library), label: 'Video'),
                    BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
                  ],
                ),
              ),
            ),
            routes: [
              GoRoute(
                  path: '/a',
                  pageBuilder: (c, s) => NoTransitionPage(child: tabA())),
              GoRoute(
                  path: '/b',
                  pageBuilder: (c, s) => const NoTransitionPage(
                      child: Scaffold(body: Text('Me screen')))),
            ],
          ),
        ],
      );

  Widget menuTab() => Scaffold(
        appBar: AppBar(actions: [
          SafePopupMenuButton<int>(
            onSelected: picked.add,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 1, child: Text('Sort by name')),
            ],
          ),
        ]),
        body: const Text('Video screen'),
      );

  setUp(() {
    guard = ShellPopupGuard();
    picked = <int>[];
  });

  testWidgets('a tap on the tab bar closes the open menu, and stays put',
      (t) async {
    await t.pumpWidget(MaterialApp.router(routerConfig: router(tabA: menuTab)));
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    expect(find.text('Sort by name'), findsOneWidget);
    // The menu is on the root navigator: its barrier is over the bar too.
    expect(guard.openCount, 0);

    await t.tap(find.text('Me'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Sort by name'), findsNothing, reason: 'menu closed');
    expect(find.text('Video screen'), findsOneWidget,
        reason: 'the tap closed the menu; it did not switch tabs under it');

    // With nothing open, the bar works as before.
    await t.tap(find.text('Me'));
    await t.pumpAndSettle();
    expect(find.text('Me screen'), findsOneWidget);
    expect(picked, isEmpty);
  });

  testWidgets('a bottom sheet over a tab: the bar closes it too', (t) async {
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router(
        tabA: () => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const SizedBox(height: 200, child: Text('Sheet')),
              ),
              child: const Text('Open sheet'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('Open sheet'));
    await t.pumpAndSettle();
    expect(find.text('Sheet'), findsOneWidget);
    await t.tap(find.text('Me'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Sheet'), findsNothing);
    expect(find.text('Open sheet'), findsOneWidget);
  });

  testWidgets('a menu whose button disappears while open does not crash',
      (t) async {
    late StateSetter setOuter;
    var showButton = true;
    await t.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, set) {
        setOuter = set;
        return Scaffold(
          appBar: AppBar(actions: [
            if (showButton)
              SafePopupMenuButton<int>(
                onSelected: picked.add,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 7, child: Text('Delete')),
                ],
              ),
          ]),
        );
      }),
    ));
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();

    // A refresh drops the button (a selection bar swapped back, say) while
    // the menu is up; then the screen relayouts.
    setOuter(() => showButton = false);
    await t.pump();
    t.view.physicalSize = const Size(1200, 2000);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);

    // The orphaned menu still closes, and its choice goes nowhere.
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(picked, isEmpty);
  });

  testWidgets('WHY: the stock PopupMenuButton crashes in that same case',
      (t) async {
    late StateSetter setOuter;
    var showButton = true;
    await t.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, set) {
        setOuter = set;
        return Scaffold(
          appBar: AppBar(actions: [
            if (showButton)
              // ignore: avoid_stock_popup_menu — this test shows why.
              PopupMenuButton<int>(
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 7, child: Text('Delete')),
                ],
              ),
          ]),
        );
      }),
    ));
    await t.tap(find.byIcon(Icons.more_vert));
    await t.pumpAndSettle();
    setOuter(() => showButton = false);
    await t.pump();
    t.view.physicalSize = const Size(1200, 2000);
    addTearDown(t.view.resetPhysicalSize);
    await t.pump();
    expect(t.takeException(), isNotNull,
        reason: 'Flutter 3.32: the menu asks the disposed button for context');
  });

  testWidgets('a page change with a sheet open is published after the frame',
      (t) async {
    final r = router(
      tabA: () => Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => const SizedBox(height: 200, child: Text('Sheet')),
            ),
            child: const Text('Open sheet'),
          ),
        ),
      ),
    );
    await t.pumpWidget(MaterialApp.router(routerConfig: r));
    await t.tap(find.text('Open sheet'));
    await t.pumpAndSettle();
    expect(guard.top.value, isNotNull);
    // Navigation from code (a deep link, a notification) while it is open:
    // the navigator drops the sheet during its rebuild.
    r.go('/b');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: 'no setState during build');
    expect(find.text('Me screen'), findsOneWidget);
    expect(find.text('Sheet'), findsNothing,
        reason: "the old tab's sheet does not float over the new tab");
    expect(guard.top.value, isNull);
  });
}
