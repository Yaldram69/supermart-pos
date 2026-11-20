import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/services/secure_session.dart';

void main() {
  // These run the real Windows data-protection (DPAPI) calls on this PC.
  group('session encryption', () {
    test('a session survives a round trip and is not stored in clear text', () {
      final session = jsonEncode({
        'access_token': 'eyJhbGciOiJIUzI1NiJ9.test-token',
        'refresh_token': 'refresh-me',
        'user': {'email': 'cashier@example.com'},
      });
      final sealed = SecureSessionStorage.protectBytes(utf8.encode(session));

      expect(sealed, isNot(utf8.encode(session)));
      expect(latin1.decode(sealed).contains('test-token'), isFalse,
          reason: 'the access token must not appear in the file');

      final opened = utf8.decode(SecureSessionStorage.unprotectBytes(sealed));
      expect(opened, session);
    });

    test('an empty session still round trips', () {
      final sealed = SecureSessionStorage.protectBytes(const <int>[]);
      expect(SecureSessionStorage.unprotectBytes(sealed), isEmpty);
    });

    test('damaged data is refused, not returned as a session', () {
      final sealed = SecureSessionStorage.protectBytes(utf8.encode('{"access_token":"x"}'));
      final damaged = List<int>.from(sealed)..[sealed.length ~/ 2] ^= 0xFF;
      expect(() => SecureSessionStorage.unprotectBytes(damaged), throwsA(isA<StateError>()));
    });
  }, skip: Platform.isWindows ? null : 'DPAPI exists only on Windows');
}
