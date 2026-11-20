import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Sends bytes straight to a Windows printer queue in RAW mode.
///
/// The printer driver is bypassed, so it does not impose its own paper-length
/// limit on a long receipt. Use this only for printers that understand the
/// bytes (ESC/POS thermal printers).
class RawPrinter {
  RawPrinter._();

  /// The name of the Windows default printer, or null if there is none.
  static String? defaultPrinter() {
    if (!Platform.isWindows) return null;
    final size = calloc<Uint32>()..value = 512;
    final buffer = calloc<Uint16>(512);
    try {
      if (GetDefaultPrinter(buffer.cast<Utf16>(), size) == 0) return null;
      return buffer.cast<Utf16>().toDartString();
    } finally {
      calloc.free(buffer);
      calloc.free(size);
    }
  }

  /// Returns true only when every byte was accepted by the spooler.
  static bool send(String printerName, Uint8List bytes, {String docName = 'Receipt'}) {
    if (!Platform.isWindows || bytes.isEmpty) return false;

    final name = printerName.toNativeUtf16();
    final doc = docName.toNativeUtf16();
    final rawType = 'RAW'.toNativeUtf16();
    final handle = calloc<IntPtr>();
    final docInfo = calloc<DOC_INFO_1>();
    final data = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    try {
      if (OpenPrinter(name, handle, nullptr) == 0) return false;
      final printer = handle.value;
      try {
        docInfo.ref
          ..pDocName = doc
          ..pOutputFile = nullptr
          ..pDatatype = rawType;
        if (StartDocPrinter(printer, 1, docInfo) == 0) return false;
        try {
          if (StartPagePrinter(printer) == 0) return false;
          data.asTypedList(bytes.length).setAll(0, bytes);
          final ok = WritePrinter(printer, data.cast(), bytes.length, written) != 0 &&
              written.value == bytes.length;
          EndPagePrinter(printer);
          return ok;
        } finally {
          EndDocPrinter(printer);
        }
      } finally {
        ClosePrinter(printer);
      }
    } finally {
      calloc.free(name);
      calloc.free(doc);
      calloc.free(rawType);
      calloc.free(handle);
      calloc.free(docInfo);
      calloc.free(data);
      calloc.free(written);
    }
  }
}
