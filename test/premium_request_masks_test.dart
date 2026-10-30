import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_account_repository.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A payer's own requests once the server keeps their numbers sealed
/// (migration 054, docs/edge/pii.ts): the list asks for the masks, and a
/// sealed request shows them where the numbers were. One filed before the
/// sealing still shows its numbers as they were typed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The session as an older build left it: SessionStore reads it from here
    // when the Keystore is not there, as in a test.
    SharedPreferences.setMockInitialValues(<String, Object>{'vh_session_access': 'token'});
  });

  test('a sealed request shows its masks; one from before shows its numbers', () async {
    Uri? asked;
    final client = ApiClient(
      httpClient: MockClient((http.Request request) async {
        asked = request.url;
        return http.Response(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'a', 'plan_id': 'month', 'status': 'pending',
              'submitted_at': '2026-10-30T03:00:00Z',
              'reference': null, 'sender_phone': null,
              'reference_mask': '••••••0098', 'sender_phone_mask': '09••••••789',
            },
            <String, Object?>{
              'id': 'b', 'plan_id': 'month', 'status': 'approved',
              'submitted_at': '2026-10-01T03:00:00Z',
              'reference': '0100 3945 7712 0098', 'sender_phone': '09123456789',
              'reference_mask': null, 'sender_phone_mask': null,
            },
          ]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final rows = await ApiAccountRepository(client).myRequests();
    final select = asked!.queryParameters['select']!.split(',');
    expect(select, containsAll(<String>['reference_mask', 'sender_phone_mask']));
    expect(rows[0].reference, '••••••0098');
    expect(rows[0].senderPhone, '09••••••789');
    expect(rows[1].reference, '0100 3945 7712 0098');
    expect(rows[1].senderPhone, '09123456789');
  });
}
