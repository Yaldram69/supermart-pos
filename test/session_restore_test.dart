import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:supermart_pos/core/app_config.dart';
import 'package:supermart_pos/core/format.dart';
import 'package:supermart_pos/services/api.dart';
import 'package:supermart_pos/state/app_state.dart';

/// A till with a sign-in saved on this PC that cannot be confirmed (no internet).
class _SavedButUnconfirmedApi extends Api {
  _SavedButUnconfirmedApi() : super(SupabaseClient('https://example.supabase.co', 'test-key'));

  @override
  Future<bool> hasSavedSession() async => true;

  @override
  Future<bool> restoreSavedSession() async => false;

  @override
  bool get isSignedIn => false;
}

/// A till with no sign-in saved at all.
class _NothingSavedApi extends Api {
  _NothingSavedApi() : super(SupabaseClient('https://example.supabase.co', 'test-key'));

  @override
  Future<bool> hasSavedSession() async => false;

  @override
  Future<bool> restoreSavedSession() async => false;

  @override
  bool get isSignedIn => false;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();
  });

  test('a saved sign-in that cannot be confirmed keeps the till signed in for offline work', () async {
    final state = AppState(_SavedButUnconfirmedApi());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(state.sessionPending, isFalse);
    expect(state.signedIn, isTrue);
  });

  test('with nothing saved the till shows the sign-in screen', () async {
    final state = AppState(_NothingSavedApi());
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(state.sessionPending, isFalse);
    expect(state.signedIn, isFalse);
  });

  test('the server is not asked for anything until the sign-in is confirmed', () {
    final api = Api(SupabaseClient('https://example.supabase.co', 'test-key'));
    expect(
      () => api.requireSignIn(),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'OFFLINE')),
    );
  });
}
