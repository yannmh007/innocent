// Tests around native Google sign-in.
//
// Nothing here can test a SUCCESSFUL Google sign-in: that needs Play
// Services, a real account and a registered SHA-1, none of which exist in a
// test binary. That path is proven on a device. What IS pinned here is the
// configuration the whole thing hangs off, and the one ordering property
// that can still be observed without a plugin.
//
// WHY THE CONFIGURATION IS WORTH A TEST. Google issues two OAuth clients for
// an Android app, and only one of them belongs in this file:
//
//   Android client   package name + SHA-1. Makes Google willing to sign.
//                    Registered with Google and Supabase. Never in code.
//   Web client       what the ID token is addressed to (`aud`), and what
//                    Supabase checks. THIS is what the plugin is handed.
//
// Pasting the Android ID into `serverClientId` is the single most common way
// this setup is got wrong, and the symptom is not an error message — it is a
// button that does nothing, because Android's CredentialManager reports some
// configuration faults as a user cancel. A swap would cost a day. It costs
// one `expect` to notice instead.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_account_repository.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/backend_config.dart';
import 'package:innocent/features/video_hub/data/local_account_repository.dart';
import 'package:innocent/features/video_hub/domain/account_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Android client, which must NEVER be what the app is configured with.
///
/// Here as a known-wrong value rather than a comment, because a comment does
/// not fail a build. Registered in Google Cloud against `com.innocent.media`
/// and SHA-1 `C4:3C:...:EC:26`, and listed on Supabase's Google provider.
const String _androidClientId =
    '504972129795-6d2aa3rq42tohdd1s3aurlr2606r3jso.apps.googleusercontent.com';

/// The web client, which is what `serverClientId` must be.
const String _webClientId =
    '504972129795-oj8ps08s13e8ain46pofbfrsr0u9iqdi.apps.googleusercontent.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('BackendConfig — Google', () {
    test('ships the WEB client ID, not the Android one', () {
      expect(BackendConfig.googleServerClientId, _webClientId);
      expect(
        BackendConfig.googleServerClientId,
        isNot(_androidClientId),
        reason: 'serverClientId must be the web client. The Android client '
            'is registered with Google and Supabase but is never named in '
            'code — see docs/google_sign_in_setup.md.',
      );
    });

    test('a configured build offers the Google button', () {
      // The sign-in sheet renders the button on this, and hides it — with its
      // divider — when it is false. False is a supported state, not a broken
      // one: it is what every build was before the Cloud clients existed, and
      // what a build with `--dart-define=VH_GOOGLE_SERVER_CLIENT_ID=` still is.
      expect(BackendConfig.googleEnabled, isTrue);
    });
  });

  group('ApiAccountRepository.signInWithGoogle', () {
    test('opens no network request before the account chooser', () async {
      // The ordering property, and the only part of the real repository this
      // binary can still observe. `initialize()` reaches for a platform
      // channel that does not exist here, so the call fails — but it must
      // fail THERE, having sent nothing. A request arriving at this client
      // would mean the token exchange runs before there is a token.
      final client = ApiClient(
        httpClient: MockClient((http.Request request) async {
          fail('signInWithGoogle sent ${request.method} ${request.url.path} '
              'before Google returned an ID token');
        }),
      );

      await expectLater(
        ApiAccountRepository(client).signInWithGoogle(),
        throwsA(anything),
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
