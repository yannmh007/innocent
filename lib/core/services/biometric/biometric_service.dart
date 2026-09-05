import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth/error_codes.dart' as auth_error;

/// Audit fix (standard high-quality): biometric authentication wrapper
/// for the Private Folder unlock flow.
///
/// Design choices:
/// - **Affordance, not secret**: the PIN remains the source of truth.
///   Biometric just bypasses PIN entry on devices where the user has
///   enrolled a fingerprint or face. Disabling biometric never
///   weakens security; it only adds back the PIN keystrokes.
/// - **Fail-open to PIN**: any error from local_auth (no hardware,
///   no enrollment, user cancelled, hardware glitch) returns false
///   and the PIN entry remains available. We never lock the user out.
/// - **Graceful no-op**: `canCheck()` returns false on platforms or
///   devices without biometric hardware, so the UI can hide the
///   biometric affordance instead of showing a button that always
///   fails.
class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// True if the device has biometric hardware AND the user has
  /// enrolled at least one biometric (fingerprint, face, iris).
  /// Returns false on any failure path — caller treats it as
  /// "biometric not available".
  Future<bool> canCheck() async {
    try {
      // canCheckBiometrics: hardware reports the capability exists.
      // isDeviceSupported: at OS level (Android 6+ etc).
      // Both must be true for the affordance to make sense.
      final hw = await _auth.canCheckBiometrics;
      if (!hw) return false;
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      // Also confirm at least one biometric is actually enrolled,
      // not just that the hardware exists. Without enrollment, the
      // OS dialog would just say "no biometrics set up" — better
      // to hide the button.
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  /// Prompt the user with the system biometric dialog. Returns true
  /// only on successful authentication.
  ///
  /// [reason] is shown in the dialog body ("Authenticate to unlock
  /// Private Folder"). Keep it short and specific to the action.
  Future<bool> authenticate({
    String reason = 'Authenticate to unlock',
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // stickyAuth: keep the dialog visible if the app
          // backgrounds momentarily (e.g., user pulls down the
          // notification shade to read a code). Without this the
          // dialog dismisses and we'd have to retry.
          stickyAuth: true,
          // biometricOnly: don't fall back to device PIN/pattern.
          // Falling back would let the user unlock our PIN-gated
          // folder with their phone lockscreen PIN, which is a
          // weaker security posture than the user expected when
          // they set up our PIN.
          biometricOnly: true,
          // useErrorDialogs: let the OS show the standard "enroll
          // biometric" dialog if the user has none. Skipping this
          // would mean a silent failure that confuses the user.
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (e) {
      // Recognised local_auth error codes are not bugs — they're
      // expected user actions or device states. Swallow them and
      // let the caller fall back to PIN entry.
      switch (e.code) {
        case auth_error.notAvailable:
        case auth_error.notEnrolled:
        case auth_error.passcodeNotSet:
        case auth_error.lockedOut:
        case auth_error.permanentlyLockedOut:
          return false;
        default:
          return false;
      }
    } catch (_) {
      return false;
    }
  }
}

final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});
