// Tests for the model behind audit_video_hub.md M2.
//
// The bug this guards against was not a crash. A failed fetch returned
// `PaymentInstructions.placeholder` — payee "Innocent", number
// `09-000-000-000` — and the screen rendered it exactly like a live answer:
// the number in bold, a Copy button beside it, "send the money here" above.
// `09-000-000-000` is not a KPay account, so the app was inventing a payment
// instruction and handing it to someone about to send real money.
//
// The fix is a source marker the UI branches on. That marker is a one-word
// default on a const, which is precisely the kind of thing a refactor flips
// without anybody noticing — so it is pinned here.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/account.dart';

void main() {
  group('PaymentInstructions.isPayable', () {
    test('the bundled placeholder is NOT payable', () {
      // The load-bearing assertion in this file. If this ever passes as true,
      // the payment screen goes back to offering a number nobody can pay.
      expect(PaymentInstructions.placeholder.source,
          PaymentSource.placeholder);
      expect(PaymentInstructions.placeholder.isPayable, isFalse);
    });

    test('a server answer is live and payable', () {
      const live = PaymentInstructions(
        payeeName: 'Ko Ko',
        payeeNumber: '09-777-000-111',
        prices: <String, String>{'monthly': 'MMK 3,500'},
      );
      expect(live.source, PaymentSource.live);
      expect(live.isPayable, isTrue);
    });

    test('a cached answer IS payable — real digits, possibly stale prices',
        () {
      // Deliberate: withholding a real number because the network is down
      // helps nobody. The screen warns instead.
      final cached = PaymentInstructions.fromJson(<String, dynamic>{
        'payee_name': 'Ko Ko',
        'payee_number': '09-777-000-111',
        'prices': <String, dynamic>{'monthly': 'MMK 3,500'},
      });
      expect(cached, isNotNull);
      expect(cached!.source, PaymentSource.cached);
      expect(cached.isPayable, isTrue);
    });
  });

  group('PaymentInstructions.fromJson refuses a half-filled object', () {
    // A wrong payee number is worse than no payee number, so every one of
    // these returns null rather than something the screen would render.
    test('missing number', () {
      expect(
        PaymentInstructions.fromJson(<String, dynamic>{
          'payee_name': 'Ko Ko',
          'prices': <String, dynamic>{'monthly': 'MMK 3,500'},
        }),
        isNull,
      );
    });

    test('empty number', () {
      expect(
        PaymentInstructions.fromJson(<String, dynamic>{
          'payee_name': 'Ko Ko',
          'payee_number': '',
          'prices': <String, dynamic>{'monthly': 'MMK 3,500'},
        }),
        isNull,
      );
    });

    test('number of the wrong type', () {
      expect(
        PaymentInstructions.fromJson(<String, dynamic>{
          'payee_name': 'Ko Ko',
          'payee_number': 9777000111,
          'prices': <String, dynamic>{'monthly': 'MMK 3,500'},
        }),
        isNull,
      );
    });

    test('no prices — a payee with no amount is not an instruction', () {
      expect(
        PaymentInstructions.fromJson(<String, dynamic>{
          'payee_name': 'Ko Ko',
          'payee_number': '09-777-000-111',
          'prices': <String, dynamic>{},
        }),
        isNull,
      );
    });
  });

  group('round trip', () {
    test('the digits and prices survive toJson -> fromJson', () {
      const original = PaymentInstructions(
        payeeName: 'Ko Ko',
        payeeNumber: '09-777-000-111',
        prices: <String, String>{
          'monthly': 'MMK 3,500',
          'yearly': 'MMK 34,000',
        },
        note: 'Open 9-5',
      );
      final back = PaymentInstructions.fromJson(original.toJson());
      expect(back, isNotNull);
      expect(back!.payeeName, original.payeeName);
      expect(back.payeeNumber, original.payeeNumber);
      expect(back.prices, original.prices);
      expect(back.note, original.note);
    });

    test('but the source does NOT survive — it comes back as cached', () {
      // The point of the round trip. Anything read off the disk is by
      // definition not a live answer, whatever it was when it was written.
      const original = PaymentInstructions(
        payeeName: 'Ko Ko',
        payeeNumber: '09-777-000-111',
        prices: <String, String>{'monthly': 'MMK 3,500'},
      );
      expect(original.source, PaymentSource.live);
      expect(PaymentInstructions.fromJson(original.toJson())!.source,
          PaymentSource.cached);
    });

    test('a non-string price is stringified rather than dropped', () {
      final back = PaymentInstructions.fromJson(<String, dynamic>{
        'payee_name': 'Ko Ko',
        'payee_number': '09-777-000-111',
        'prices': <String, dynamic>{'monthly': 3500},
      });
      expect(back!.prices['monthly'], '3500');
    });
  });

  group('copyWith', () {
    test('changes the source and nothing else', () {
      final promoted =
          PaymentInstructions.placeholder.copyWith(source: PaymentSource.live);
      expect(promoted.source, PaymentSource.live);
      expect(promoted.isPayable, isTrue);
      expect(promoted.payeeNumber, PaymentInstructions.placeholder.payeeNumber);
      expect(promoted.prices, PaymentInstructions.placeholder.prices);
      // The const is untouched — this matters, because the dev stub promotes
      // a copy and production must still see a refusal.
      expect(PaymentInstructions.placeholder.isPayable, isFalse);
    });
  });
}
