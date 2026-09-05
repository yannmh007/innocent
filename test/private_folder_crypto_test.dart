import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/private_folder/private_folder_service.dart';

/// Tests for the vault's cryptography.
///
/// WHY THIS FILE EXISTS
///
/// `private_folder_service.dart` is 1,600 lines and had ZERO tests, which made
/// it the largest untested surface in the project and also the most sensitive:
/// it holds the PIN hashing, the decoy-PIN decision and the lockout state that
/// stand between a borrowed phone and someone's private files.
///
/// The PBKDF2 in it is HAND-WRITTEN rather than taken from a package - a
/// deliberate choice, so the function stays auditable. But a hand-written
/// primitive that has never been checked against a reference implementation is
/// a hope, not a control. One transposed index in the XOR loop produces a hash
/// that is perfectly self-consistent, verifies every PIN it wrote, and offers
/// a fraction of the intended resistance. Nothing in the app would look wrong.
///
/// WHERE THE EXPECTED VALUES COME FROM
///
/// Not from this implementation. They were produced by Python's
/// `hashlib.pbkdf2_hmac('sha256', …, dklen=32)` - a separate, standards-
/// conformant implementation - and the first three also match the widely
/// published PBKDF2-HMAC-SHA256 vectors. A test whose expectations came from
/// the code under test proves only that the code is consistent with itself.
void main() {
  group('PBKDF2-HMAC-SHA256 — published vectors', () {
    test('password/salt, 1 round', () {
      expect(
        PrivateFolderService.pbkdf2ForTest('password', 'salt', 1),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('password/salt, 2 rounds', () {
      expect(
        PrivateFolderService.pbkdf2ForTest('password', 'salt', 2),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('password/salt, 4096 rounds', () {
      expect(
        PrivateFolderService.pbkdf2ForTest('password', 'salt', 4096),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('long password and salt, 4096 rounds', () {
      expect(
        PrivateFolderService.pbkdf2ForTest(
          'passwordPASSWORDpassword',
          'saltSALTsaltSALTsaltSALTsaltSALTsalt',
          4096,
        ),
        '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1',
      );
    });
  });

  group('PBKDF2 — edges that a real vault actually meets', () {
    test('empty password', () {
      // Reachable: a keypad bug, or a caller that trims to nothing. It must
      // still derive rather than throw, or the vault becomes unopenable.
      expect(
        PrivateFolderService.pbkdf2ForTest('', 'salt', 1),
        'f135c27993baf98773c5cdb40a5706ce6a345cde61b000a67858650cd6a324d7',
      );
    });

    test('empty salt', () {
      // Reachable if _ensureSalt is ever read before it is written.
      expect(
        PrivateFolderService.pbkdf2ForTest('pin', '', 1),
        'ef6f2b3c2dd715df5aa5939705f739fcf2b38f148be663ce7c0734413aa3de83',
      );
    });

    test('multi-byte UTF-8 PIN (Burmese digits)', () {
      // The keypad is digits today, but the PIN is a String and this app is
      // Burmese-first. A byte-vs-code-unit slip in the encoding would show up
      // here and nowhere else.
      expect(
        PrivateFolderService.pbkdf2ForTest('\u1041\u1042\u1043\u1044', 'salt', 100),
        '9b62e0158f71a108daa0c5473de802423dda2b0ea3d2d1c6b24b54d387f9bf9d',
      );
    });

    test('a realistic PIN against a base64 salt at the minimum round count', () {
      expect(
        PrivateFolderService.pbkdf2ForTest('1234', 'aGVsbG9zYWx0MTIzNA==', 20000),
        'f7964f853eca5962ae5a48f42760747bf9fe5a7624ab1bf32a5267ebd3a516f7',
      );
    });

    test('output is always 32 bytes of hex, whatever the input', () {
      for (final pin in <String>['', '1', '1234', 'a very long passphrase']) {
        final hex = PrivateFolderService.pbkdf2ForTest(pin, 'salt', 1);
        expect(hex.length, 64, reason: 'pin: "$pin"');
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hex), isTrue, reason: hex);
      }
    });

    test('more rounds changes the output', () {
      // Guards the loop bound. `i = 1; i < rounds` is off-by-one-shaped, and
      // a version that ignored `rounds` would still pass every test above
      // that uses a single round count.
      final a = PrivateFolderService.pbkdf2ForTest('pin', 'salt', 100);
      final b = PrivateFolderService.pbkdf2ForTest('pin', 'salt', 101);
      expect(a, isNot(b));
    });
  });

  group('roundsOf — the lockout risk', () {
    // A v2 hash carries the round count it was written with, so the cost can
    // be raised later without stranding anyone. If this parse returns the
    // WRONG number, verification derives a different hash from the correct
    // PIN and the user is locked out of their own vault permanently - with
    // nothing on screen to explain it.

    test('reads the embedded count', () {
      expect(PrivateFolderService.roundsOfForTest('v2\$200000\$abcdef'), 200000);
      expect(PrivateFolderService.roundsOfForTest('v2\$20000\$abcdef'), 20000);
    });

    test('falls back to the minimum rather than crashing', () {
      for (final bad in <String>[
        'v2\$\$abcdef',        // no number
        'v2\$notanumber\$ab',  // not numeric
        'v2\$200000',          // truncated
        'v2',                  // prefix only
        '',                    // empty
      ]) {
        expect(PrivateFolderService.roundsOfForTest(bad), 20000,
            reason: 'input: "$bad"');
      }
    });

    test('a large but legitimate count survives the round trip', () {
      // The calibrator clamps at 400 000; a fast phone really will write one.
      expect(PrivateFolderService.roundsOfForTest('v2\$400000\$ff'), 400000);
    });
  });

  group('constantTimeEquals', () {
    test('equal strings match', () {
      expect(PrivateFolderService.constantTimeEqualsForTest('abc', 'abc'), isTrue);
      expect(PrivateFolderService.constantTimeEqualsForTest('', ''), isTrue);
    });

    test('a difference anywhere is caught', () {
      // Both ends, because an early-exit comparison behaves differently at
      // each and this one must not.
      expect(PrivateFolderService.constantTimeEqualsForTest('abc', 'xbc'), isFalse);
      expect(PrivateFolderService.constantTimeEqualsForTest('abc', 'abx'), isFalse);
    });

    test('different lengths never match', () {
      // The length is folded into the same accumulator as the bytes, so a
      // prefix cannot pass. Without that, 'abc' vs 'abcdef' would compare
      // only the first three.
      expect(PrivateFolderService.constantTimeEqualsForTest('abc', 'abcdef'), isFalse);
      expect(PrivateFolderService.constantTimeEqualsForTest('abcdef', 'abc'), isFalse);
      expect(PrivateFolderService.constantTimeEqualsForTest('', 'a'), isFalse);
    });

    test('agrees with == on real hash values', () {
      final h = PrivateFolderService.pbkdf2ForTest('1234', 'salt', 20000);
      final same = PrivateFolderService.pbkdf2ForTest('1234', 'salt', 20000);
      final other = PrivateFolderService.pbkdf2ForTest('1235', 'salt', 20000);
      expect(PrivateFolderService.constantTimeEqualsForTest(h, same), isTrue);
      expect(PrivateFolderService.constantTimeEqualsForTest(h, other), isFalse);
    });
  });
}
