import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/account.dart';
import 'package:innocent/features/video_hub/domain/account_repository.dart';
import 'package:innocent/features/video_hub/presentation/account/delete_account_screen.dart';
import 'package:innocent/features/video_hub/presentation/account_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Delete my account", from the phone's side (the server's rules are in
/// tool/js/delete_account_test.mjs).
///
/// What must hold: the account deleted is the one the screen showed, after
/// the person chose it again at Google's prompt; any other answer at that
/// prompt deletes nothing; a refusal leaves them signed in and says why; and
/// a deletion ends with this phone signed out, exactly as signing out does.
const _me = AuthUser(id: 'user-a', method: AuthMethod.google, email: 'a@example.com');
const _other = AuthUser(id: 'user-b', method: AuthMethod.google, email: 'b@example.com');

class _Repo implements AccountRepository {
  _Repo({this.user = _me});

  AuthUser? user;
  Object reauth = _me; // an AuthUser to return, or something to throw
  Object? refuse;
  final List<String> deleted = <String>[];
  int signOuts = 0;

  @override
  Future<AuthUser?> currentUser() async => user;

  @override
  Future<Entitlement> entitlement() async => const Entitlement.free();

  @override
  Future<AuthUser> signInWithGoogle() async {
    final r = reauth;
    if (r is AuthUser) {
      user = r;
      return r;
    }
    throw r;
  }

  @override
  Future<void> deleteAccount({required String expectUserId}) async {
    final r = refuse;
    if (r != null) throw r;
    deleted.add(expectUserId);
    user = null;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    user = null;
  }

  @override
  Future<void> claimAnonymousHistory(String anonymousId) async {}

  @override
  Future<List<PremiumRequest>> myRequests() async => const <PremiumRequest>[];

  @override
  Future<void> recordAgeConsent({required int version, required DateTime acceptedAt}) async {}

  @override
  Future<void> startPhoneSignIn(String phoneE164) async {}

  @override
  Future<AuthUser> verifyPhoneCode({required String phoneE164, required String code}) =>
      throw UnimplementedError();

  @override
  Future<PaymentInstructions> paymentInstructions() => throw UnimplementedError();

  @override
  Future<PremiumRequest> submitPremiumRequest({
    required String planId,
    String reference = '',
    String? senderPhone,
    Uint8List? proof,
    String? priceShown,
    String? message,
  }) =>
      throw UnimplementedError();
}

/// The shelf, without a filesystem: what matters here is that sign-out ran.
class _NoShelf extends OfflineLibrary {
  int drops = 0;

  @override
  Future<void> dropEntitled({void Function(String key)? stop}) async => drops++;
}

Future<(AccountNotifier, _Repo, _NoShelf)> _signedIn({AuthUser user = _me}) async {
  final repo = _Repo(user: user);
  final shelf = _NoShelf();
  final n = AccountNotifier(repo, offline: shelf);
  await n.refresh();
  return (n, repo, shelf);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('deletes the account the screen showed, after choosing it again, and signs out', () async {
    final (n, repo, shelf) = await _signedIn();
    expect(n.state.user?.id, 'user-a');
    await n.deleteAccount();
    expect(repo.deleted, <String>['user-a']);
    expect(n.state.user, isNull);
    expect(shelf.drops, 1, reason: 'premium downloads go, as on sign-out');
  });

  test('a different account chosen at the prompt deletes nothing', () async {
    final (n, repo, _) = await _signedIn();
    repo.reauth = _other;
    await expectLater(n.deleteAccount(),
        throwsA(isA<AccountDeletionRefused>().having((e) => e.reason, 'reason', 'other_account')));
    expect(repo.deleted, isEmpty);
    expect(n.state.user?.id, 'user-b', reason: 'signed in to the one they picked');
  });

  test('backing out of the prompt deletes nothing', () async {
    final (n, repo, _) = await _signedIn();
    repo.reauth = const SignInCancelled();
    await expectLater(n.deleteAccount(), throwsA(isA<SignInCancelled>()));
    expect(repo.deleted, isEmpty);
    expect(n.state.user?.id, 'user-a');
  });

  test('a refusal leaves the person signed in', () async {
    final (n, repo, shelf) = await _signedIn();
    repo.refuse = const AccountDeletionRefused('admin');
    await expectLater(n.deleteAccount(), throwsA(isA<AccountDeletionRefused>()));
    expect(n.state.user?.id, 'user-a');
    expect(repo.signOuts, 0);
    expect(shelf.drops, 0);
  });

  test('a phone account is not asked for Google', () async {
    const phone = AuthUser(id: 'user-p', method: AuthMethod.phone, phone: '+959000000');
    final (n, repo, _) = await _signedIn(user: phone);
    repo.reauth = StateError('Google must not be asked');
    await n.deleteAccount();
    expect(repo.deleted, <String>['user-p']);
  });

  group('the screen', () {
    Future<_Repo> open(WidgetTester tester, {Object? refuse}) async {
      final repo = _Repo()..refuse = refuse;
      final shelf = _NoShelf();
      // Signed in before the screen opens: the load reads stores that only
      // answer outside the test's fake clock.
      final notifier = AccountNotifier(repo, offline: shelf);
      await tester.runAsync(notifier.refresh);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          accountProvider.overrideWith((ref) => notifier),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: AppStrings.localizationsDelegates,
          home: Scaffold(body: SizedBox()),
        ),
      ));
      await tester.pumpAndSettle();
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const DeleteAccountScreen())));
      await tester.pumpAndSettle();
      return repo;
    }

    FilledButton button(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byType(FilledButton));

    testWidgets('says what goes and what stays, and waits for "I understand"', (tester) async {
      await open(tester);
      final s = AppStrings(const Locale('en'));
      expect(find.text(s.vhDeleteAccountGone), findsOneWidget);
      expect(find.text(s.vhDeleteAccountKept), findsOneWidget);
      expect(find.text(s.vhDeleteAccountReauth), findsOneWidget);
      expect(button(tester).onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(button(tester).onPressed, isNotNull);
    });

    testWidgets('an admin account is told why, and stays', (tester) async {
      final repo = await open(tester, refuse: const AccountDeletionRefused('admin'));
      final s = AppStrings(const Locale('en'));
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.text(s.vhDeleteAccountAdmin), findsOneWidget);
      expect(repo.deleted, isEmpty);
      expect(find.byType(DeleteAccountScreen), findsOneWidget);
    });

    testWidgets('a deletion closes the screen and says it is done', (tester) async {
      final repo = await open(tester);
      final s = AppStrings(const Locale('en'));
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      // Signing out after the deletion empties stores that answer outside
      // the fake clock; the spinner turns until it is done.
      for (var i = 0; i < 40 && find.byType(DeleteAccountScreen).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.deleted, <String>['user-a']);
      expect(find.byType(DeleteAccountScreen), findsNothing);
      expect(find.text(s.vhDeleteAccountDone), findsOneWidget);
    });
  });
}
