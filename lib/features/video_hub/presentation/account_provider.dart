import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_account_repository.dart';
import '../data/api/api_client.dart';
import '../data/api/backend_config.dart';
import '../data/api/offline_library.dart';
import '../data/device_identity.dart';
import '../data/local_account_repository.dart';
import '../domain/access.dart';
import '../domain/account.dart';
import '../domain/account_repository.dart';
import '../domain/viewer.dart';

/// THE SWAP POINT for identity and billing.
///
/// One line changes the whole feature from the on-device stub to the real
/// backend. Nothing above this reads SharedPreferences or knows an endpoint.
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.close);
  return client;
});

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  // Configured -> real backend. Not configured -> the on-device stub, which
  // grants nothing. That fallback direction matters: a build with a missing
  // URL shows an empty-handed catalogue rather than quietly handing out
  // content.
  if (!BackendConfig.isConfigured) return const LocalAccountRepository();
  return ApiAccountRepository(ref.watch(apiClientProvider));
});

/// Session + entitlement, held together.
///
/// Deliberately ONE object rather than two providers. They change together —
/// signing out must drop the entitlement in the same frame, or a screen
/// rebuilt in between shows premium content to nobody in particular.
@immutable
class AccountState {
  final AuthUser? user;
  final Entitlement entitlement;
  final bool isLoading;

  /// Stable per-install id. Empty until the first load resolves.
  final String installId;

  const AccountState({
    this.user,
    this.entitlement = const Entitlement.free(),
    this.isLoading = true,
    this.installId = '',
  });

  bool get isSignedIn => user != null;

  AccountState copyWith({
    AuthUser? user,
    Entitlement? entitlement,
    bool? isLoading,
    String? installId,
    bool clearUser = false,
  }) {
    return AccountState(
      user: clearUser ? null : (user ?? this.user),
      entitlement: entitlement ?? this.entitlement,
      isLoading: isLoading ?? this.isLoading,
      installId: installId ?? this.installId,
    );
  }
}

class AccountNotifier extends StateNotifier<AccountState> {
  AccountNotifier(this._repo, {OfflineLibrary? offline})
      : _offline = offline ?? OfflineLibrary(),
        super(const AccountState()) {
    refresh();
  }

  final AccountRepository _repo;

  /// The offline shelf, so signing out can empty it.
  ///
  /// Injectable so a test can watch it being emptied without touching a
  /// filesystem — and defaulted so no call site has to know it exists.
  final OfflineLibrary _offline;

  /// Re-reads BOTH the session and the entitlement.
  ///
  /// Entitlement is never derived locally, and never cached across a sign-in
  /// change: it is the server's answer to "what has this account paid for",
  /// and the only party that can answer it honestly is the one holding the
  /// payment records.
  Future<void> refresh() async {
    final installId = await DeviceIdentity.get();
    final user = await _repo.currentUser();
    final entitlement =
        user == null ? const Entitlement.free() : await _repo.entitlement();
    if (!mounted) return;
    state = AccountState(
      user: user,
      entitlement: entitlement,
      isLoading: false,
      installId: installId,
    );
  }

  Future<void> verifyPhone({
    required String phoneE164,
    required String code,
  }) async {
    final anonId = await DeviceIdentity.get();
    final user =
        await _repo.verifyPhoneCode(phoneE164: phoneE164, code: code);
    // Hand the pre-sign-in id over so the server can attach what this person
    // watched BEFORE they registered. Without this the moment of signing up
    // is the moment their history disappears - and history is most of what
    // an account is for.
    await _repo.claimAnonymousHistory(anonId);
    if (!mounted) return;
    state = state.copyWith(user: user, isLoading: false);
    await refresh();
  }

  Future<void> signOut() async {
    await _repo.signOut();
    // THE DOWNLOADS GO WITH THE ACCOUNT, and this is the only enforcement
    // this side can honestly offer. A downloaded file is a plain file in
    // app-private storage — see the note on OfflineLibrary — so emptying the
    // shelf is a promise about what this app does, not about the bytes. It is
    // still worth keeping: the ordinary case is a person signing out, and in
    // the ordinary case their premium library should not stay behind.
    //
    // BEFORE the state assignment, so there is no frame in which the account
    // is gone and the shelf is still full. Awaited, because a sign-out that
    // returned while files were still being deleted would let the next screen
    // list titles that are on their way out.
    //
    // Failure is swallowed deliberately: a file the OS refuses to delete must
    // not be able to trap somebody in an account they are trying to leave.
    try {
      await _offline.dropAll();
    } catch (e) {
      if (kDebugMode) debugPrint('offline sweep on sign-out failed: $e');
    }
    if (!mounted) return;
    // Entitlement is cleared in the SAME assignment as the user. Doing it in
    // two steps leaves a frame where nobody is signed in and premium is still
    // on.
    // installId survives sign-out: it identifies the DEVICE, not the person,
    // and the concurrency cap still needs to know which device this is.
    state = AccountState(
      user: null,
      entitlement: const Entitlement.free(),
      isLoading: false,
      installId: state.installId,
    );
  }
}

final accountProvider =
    StateNotifierProvider<AccountNotifier, AccountState>((ref) {
  return AccountNotifier(ref.watch(accountRepositoryProvider));
});

/// Who is looking at the app, resolved from the account and the install id.
///
/// THE one thing screens should read. Every `isSignedIn && isActive` pair that
/// used to live in a widget is now this single ordered value, so no two
/// screens can disagree about what a viewer is.
final viewerProvider = Provider<Viewer>((ref) {
  final account = ref.watch(accountProvider);
  return Viewer(
    tier: ViewerTierX.from(
      account: account.user,
      entitlement: account.entitlement,
    ),
    account: account.user,
    entitlement: account.entitlement,
    installId: account.installId,
  );
});

/// Where to send the money and how much. Served by the backend so a KPay
/// number or a price can change without a release.
final paymentInstructionsProvider =
    FutureProvider<PaymentInstructions>((ref) {
  return ref.watch(accountRepositoryProvider).paymentInstructions();
});

/// This account's payment claims, newest first.
final myPremiumRequestsProvider =
    FutureProvider.autoDispose<List<PremiumRequest>>((ref) {
  // Depends on the session so signing out empties it rather than showing the
  // previous account's requests.
  final signedIn = ref.watch(accountProvider).isSignedIn;
  if (!signedIn) {
    return Future<List<PremiumRequest>>.value(
      const <PremiumRequest>[]);
  }
  return ref.watch(accountRepositoryProvider).myRequests();
});
