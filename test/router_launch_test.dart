import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/router/app_router.dart';
import 'package:innocent/core/router/routes.dart';

/// "Open with Innocent" and Firebase Test Lab's game loop both launch the
/// app with an address in the intent. Flutter (3.27 on) offers that address
/// to the router as the first screen; the router has no such screen, and a
/// router on its "not found" page ignores every later push — the player
/// never appeared on a real phone (Test Lab, run 37967931084).
void main() {
  testWidgets('a launch address never becomes the first screen',
      (tester) async {
    tester.platformDispatcher.defaultRouteNameTestValue =
        'content://com.android.externalstorage.documents/document/'
        'primary%3AMovies%2Fa.mp4';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final router = container.read(routerProvider);

    expect(router.routeInformationProvider.value.uri.path, Routes.local);
  });

  test('Flutter deep linking stays off on the main activity', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      RegExp(r'android:name="flutter_deeplinking_enabled"\s+'
              r'android:value="false"')
          .hasMatch(manifest),
      isTrue,
    );
  });
}
