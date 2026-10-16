import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/transient_prompt.dart';

// The Resume prompt has an action, so under TalkBack (accessibleNavigation)
// Flutter never times it out. It must close when the user moves on instead:
// another route opens, or the screen says so (a selection started).
void main() {
  Widget app(GlobalKey<NavigatorState> nav) => MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [TransientPromptObserver()],
        builder: (context, child) => MediaQuery(
          // As with TalkBack on.
          data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => TransientPrompt.show(
                  ScaffoldMessenger.of(context),
                  SnackBar(
                    duration: const Duration(seconds: 6),
                    content: const Text('Resume "film"?'),
                    action: SnackBarAction(label: 'RESUME', onPressed: () {}),
                  ),
                ),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );

  testWidgets('under TalkBack it outlives its 6 s, as Flutter intends',
      (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(app(nav));
    await t.tap(find.text('show'));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 30));
    expect(find.text('Resume "film"?'), findsOneWidget);
    expect(TransientPrompt.isShowing, isTrue);
  });

  testWidgets('another screen opening closes it', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(app(nav));
    await t.tap(find.text('show'));
    await t.pumpAndSettle();
    expect(find.text('Resume "film"?'), findsOneWidget);

    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('next'))));
    await t.pumpAndSettle();
    expect(find.text('Resume "film"?'), findsNothing);
    expect(TransientPrompt.isShowing, isFalse);
  });

  testWidgets('close() from the screen closes it (a selection started)',
      (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(app(nav));
    await t.tap(find.text('show'));
    await t.pumpAndSettle();

    TransientPrompt.close();
    await t.pumpAndSettle();
    expect(find.text('Resume "film"?'), findsNothing);
  });

  testWidgets('close() with nothing up does nothing', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(app(nav));
    TransientPrompt.close();
    await t.pumpAndSettle();
    expect(TransientPrompt.isShowing, isFalse);
  });

  testWidgets('a tab switch (the page swapped, as in a ShellRoute) closes it',
      (t) async {
    final tab = ValueNotifier<int>(0);
    late BuildContext tabContext;
    await t.pumpWidget(MaterialApp(
      // As with TalkBack on, so no timer can be what closed it.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
        child: child!,
      ),
      home: ValueListenableBuilder<int>(
        valueListenable: tab,
        builder: (context, i, _) => Navigator(
          observers: [TransientPromptObserver()],
          onDidRemovePage: (_) {},
          pages: <Page<void>>[
            MaterialPage<void>(
              key: ValueKey<int>(i),
              child: Builder(builder: (c) {
                tabContext = c;
                return Scaffold(body: Text('tab $i'));
              }),
            ),
          ],
        ),
      ),
    ));
    TransientPrompt.show(
      ScaffoldMessenger.of(tabContext),
      SnackBar(
        content: const Text('Resume "film"?'),
        action: SnackBarAction(label: 'RESUME', onPressed: () {}),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Resume "film"?'), findsOneWidget);

    tab.value = 1;
    await t.pumpAndSettle();
    expect(find.text('tab 1'), findsOneWidget);
    expect(find.text('Resume "film"?'), findsNothing);
  });
}
