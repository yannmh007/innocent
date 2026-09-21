// Tests for the guard in front of native Google sign-in.
//
// WHAT THIS PINS, and why it is worth a file: Google sign-in needs a web
// OAuth client ID compiled into the build (`BackendConfig.googleServerClientId`).
// Until that ID exists, the method cannot work — and the failure mode that
// matters is not "it throws", it is WHERE it throws.
//
// The previous version of this code threw `UnimplementedError` from the first
// line, which was honest. The new version does real work: it initialises a
// platform plugin, opens a system account chooser, and posts an ID token to
// GoTrue. If the "is this build configured" check ever drifts below any of
// that, an unconfigured build would open Google's account sheet, let someone
// pick an account, and only then discover it has nowhere to send the token —
// after the user has handed over their identity. Worse, in a test binary or
// on a device without Play Services, it would fail inside a MethodChannel
// with a message nobody can act on.
//
// So the assertion here is not merely that it throws. It is that it throws
// WITHOUT the HTTP client ever being called, which is the observable proxy
// for "nothing happened yet".
//
// Nothing here can test a SUCCESSFUL Google sign-in: that needs Play
// Services, a real account and a registered SHA-1, none of which exist in a
// test binary. That path is proven on a device, and the repository's
// `_adoptSession` — the part a wrong token would break — is shared with phone
// sign-in, which is exercised for real.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_account_repository.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/backend_config.dart';
import 'package:innocent/features/video_hub/data/local_account_repository.dart';
import 'package:innocent/features/video_hub/domain/account_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('BackendConfig.googleEnabled', () {
    test('a build with no client ID does not offer Google', () {
      // A test binary is compiled without `--dart-define`, so this exercises
      // exactly the state every build is in until the Google Cloud clients
      // are created. The sign-in sheet reads this to decide whether to render
      // the button at all.
      expect(BackendConfig.googleServerClientId, isEmpty);
      expect(BackendConfig.googleEnabled, isFalse);
    });
  });

  group('ApiAccountRepository.signInWithGoogle', () {
    test('refuses before touching the network when unconfigured', () async {
      // Fails the test rather than returning a canned response: a request
      // reaching here means the guard ran too late.
      final client = ApiClient(
        httpClient: MockClient((http.Request request) async {
          fail('signInWithGoogle sent ${request.method} ${request.url.path} '
              'on an unconfigured build');
        }),
      );

      await expectLater(
        ApiAccountRepository(client).signInWithGoogle(),
        throwsA(isA<SignInNotConfigured>()
            .having((e) => e.method, 'method', 'google')),
      );
    });
  });

  group('LocalAccountRepository.signInWithGoogle', () {
    test('reports the method as unavailable rather than faking a user',
        () async {
      // The demo path has no server to create a session on. Returning a fake
      // AuthUser here would leave the app believing in someone the backend
      // has never heard of — and the screens downstream would then ask that
      // account about its subscription.
      await expectLater(
        const LocalAccountRepository().signInWithGoogle(),
        throwsA(isA<SignInNotConfigured>()),
      );
    });
  });
}
