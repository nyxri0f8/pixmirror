import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// OS key protection for the device identity:
///  * Windows — DPAPI, bound to the current user account
///    (pm_protect in windows/runner/pixmirror_native.cpp)
///  * Android — AES-256-GCM with a non-exportable Android Keystore key
///    (Vault.kt)
/// Throws when unavailable (e.g. in unit tests); callers fall back.
abstract final class Vault {
  static const _channel = MethodChannel('pixmirror/native');

  static Future<Uint8List> seal(Uint8List data) => _run(data, unprotect: false);
  static Future<Uint8List> open(Uint8List blob) => _run(blob, unprotect: true);

  static Future<Uint8List> _run(Uint8List data, {required bool unprotect}) async {
    if (Platform.isAndroid) {
      final r = await _channel.invokeMethod<Uint8List>(unprotect ? 'vaultOpen' : 'vaultSeal', {'data': data});
      if (r == null) throw StateError('vault failed');
      return r;
    }
    if (Platform.isWindows) return _dpapi(data, unprotect);
    throw UnsupportedError('no vault on this platform');
  }

  static Uint8List _dpapi(Uint8List data, bool unprotect) {
    final fn = DynamicLibrary.executable().lookupFunction<
        Int32 Function(Pointer<Uint8>, Int32, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>),
        int Function(Pointer<Uint8>, int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)>('pm_protect');
    final free = DynamicLibrary.executable()
        .lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('pm_free');
    final input = calloc<Uint8>(data.length);
    final out = calloc<Pointer<Uint8>>();
    final len = calloc<Int32>();
    try {
      input.asTypedList(data.length).setAll(0, data);
      if (fn(input, data.length, unprotect ? 1 : 0, out, len) != 1) throw StateError('DPAPI failed');
      final result = Uint8List.fromList(out.value.asTypedList(len.value));
      free(out.value);
      return result;
    } finally {
      input.asTypedList(data.length).fillRange(0, data.length, 0);
      calloc
        ..free(input)
        ..free(out)
        ..free(len);
    }
  }
}
