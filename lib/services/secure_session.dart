import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:win32/win32.dart';

/// Keeps the signed-in session encrypted on this PC.
///
/// The session holds a live access token, which is what lets someone act as a
/// staff member. Supabase's default store is a plain preferences file. Here the
/// session is encrypted with Windows' own data protection (DPAPI), tied to the
/// Windows account that signed in, so copying the file to another PC or user
/// does not give access. No native build step is needed: the calls go through
/// pure-Dart FFI bindings.
///
/// The project URL and publishable key are not secret (they ship in every app
/// that talks to the project), so they stay in ordinary settings.
class SecureSessionStorage extends LocalStorage {
  static const _fileName = 'auth_session.bin';

  /// CRYPTPROTECT_UI_FORBIDDEN: never pop a dialog from a background call.
  static const _uiForbidden = 0x1;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  @override
  Future<void> initialize() async {}

  /// Always false: the library must not restore the session by itself at start-up.
  /// The till restores it on purpose (Api.restoreSavedSession), so an expired sign-in
  /// can wait for the internet instead of being thrown away.
  @override
  Future<bool> hasAccessToken() async => false;

  /// True when a session is saved on this PC, whether or not its token is still valid.
  Future<bool> hasSavedSession() async => (await _file()).exists();

  /// The saved session exactly as it was stored, or null when there is none.
  Future<String?> savedSession() => _read();

  @override
  Future<String?> accessToken() async {
    final raw = await _read();
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded['access_token'] as String? : null;
    } catch (_) {
      // a damaged file is treated as signed out, never as an error on the till
      return null;
    }
  }

  @override
  Future<void> removePersistedSession() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    final file = await _file();
    await file.writeAsBytes(protectBytes(utf8.encode(persistSessionString)));
  }

  Future<String?> _read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      return utf8.decode(unprotectBytes(await file.readAsBytes()));
    } catch (_) {
      // written by another Windows account, or damaged: start signed out
      return null;
    }
  }

  // ------------------------------------------------------------ DPAPI calls

  static Uint8List protectBytes(List<int> plain) {
    if (!Platform.isWindows) return Uint8List.fromList(plain);
    return _dpapi(plain, protect: true);
  }

  static Uint8List unprotectBytes(List<int> encrypted) {
    if (!Platform.isWindows) return Uint8List.fromList(encrypted);
    return _dpapi(encrypted, protect: false);
  }

  static Uint8List _dpapi(List<int> input, {required bool protect}) {
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final inData = calloc<Uint8>(input.length);
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    try {
      inData.asTypedList(input.length).setAll(0, input);
      inBlob.ref
        ..cbData = input.length
        ..pbData = inData;

      final ok = protect
          ? CryptProtectData(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob)
          : CryptUnprotectData(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob);
      if (ok == 0) {
        throw StateError(
          protect
              ? 'Windows could not protect the sign-in (error ${GetLastError()}).'
              : 'Windows could not open the saved sign-in (error ${GetLastError()}).',
        );
      }

      final out = Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      LocalFree(outBlob.ref.pbData.cast<Void>());
      return out;
    } finally {
      calloc.free(inData);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}
