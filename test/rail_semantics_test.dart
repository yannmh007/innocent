import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tablet / TV shell: a rail, then the router's nested Navigator. Every
/// page of a Navigator has a ModalBarrier, and a ModalBarrier is wrapped in
/// BlockSemantics — which drops the semantics of everything painted BEFORE it
/// in the same container. The rail is painted before the page, so on a tablet
/// TalkBack could not reach Video / Music / Transfer / Me at all (seen on the
/// Pixel C emulator: the rail missing from Android's accessibility tree). The
/// bottom bar on a phone is painted after the page, which is why phones were
/// fine. The shell gives the page its own container (shell_screen.dart).
Widget _shell({required bool pageContained}) {
  final Widget pages = Navigator(
    pages: const <Page<void>>[
      MaterialPage<void>(child: Scaffold(body: Text('first'))),
      MaterialPage<void>(child: Scaffold(body: Text('second'))),
    ],
    onDidRemovePage: (_) {},
  );
  return MaterialApp(
    home: Scaffold(
      body: Row(children: <Widget>[
        NavigationRail(
          selectedIndex: 0,
          labelType: NavigationRailLabelType.all,
          onDestinationSelected: (_) {},
          destinations: const <NavigationRailDestination>[
            NavigationRailDestination(icon: Icon(Icons.folder), label: Text('Video')),
            NavigationRailDestination(icon: Icon(Icons.person), label: Text('Me')),
          ],
        ),
        Expanded(
          child: pageContained ? Semantics(container: true, child: pages) : pages,
        ),
      ]),
    ),
  );
}

void main() {
  testWidgets('without a container the pages hide the rail from TalkBack',
      (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(_shell(pageContained: false));
    expect(find.bySemanticsLabel(RegExp('Video')), findsNothing);
    h.dispose();
  });

  testWidgets('with the page in its own container the rail is reachable',
      (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(_shell(pageContained: true));
    expect(find.bySemanticsLabel(RegExp('Video')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Me')), findsOneWidget);
    expect(find.bySemanticsLabel('second'), findsOneWidget);
    h.dispose();
  });
}
