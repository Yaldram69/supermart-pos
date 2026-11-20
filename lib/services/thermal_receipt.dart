import 'dart:typed_data';

import '../core/format.dart';
import '../models.dart';

/// Builds one sale as ESC/POS commands for a thermal printer.
///
/// The output is plain text plus a few printer commands, so it has no page
/// height limit: a sale with 1 item or 200 items prints on one receipt. The
/// bytes go to the printer in RAW mode (see RawPrinter).
class ThermalReceipt {
  ThermalReceipt._();

  /// Characters per line for the Font A text of each paper width.
  static int columnsFor(int paperMm) => (paperMm == 57 || paperMm == 58) ? 32 : 48;

  static Uint8List build(
    SaleResult sale,
    StoreSettings? store, {
    required int paperMm,
    bool reprint = false,
    String? offlineNote,
  }) {
    final t = _Ticket(columnsFor(paperMm));
    final sym = store?.currencySymbol ?? 'Rs';

    // header
    t.align(1);
    t.bold(true);
    t.line(store?.name ?? 'Supermart');
    t.bold(false);
    if ((store?.address ?? '').isNotEmpty) t.line(store!.address);
    if ((store?.phone ?? '').isNotEmpty) t.line('Tel: ${store!.phone}');
    if ((store?.ntn ?? '').isNotEmpty) t.line('NTN: ${store!.ntn}');
    if ((store?.receiptHeader ?? '').trim().isNotEmpty) t.line(store!.receiptHeader.trim());
    t.align(0);
    t.rule();

    if (reprint) {
      t.align(1);
      t.bold(true);
      t.line('*** DUPLICATE COPY ***');
      t.bold(false);
      t.align(0);
    }
    if (offlineNote != null && offlineNote.isNotEmpty) {
      t.align(1);
      t.bold(true);
      t.line(offlineNote);
      t.bold(false);
      t.align(0);
    }

    t.pair('Invoice', sale.invoiceNo);
    t.pair('Date', sale.createdAt == null ? '' : pkFormat('dd/MM/yyyy hh:mm a', sale.createdAt!));
    t.pair('Till', sale.device);
    t.pair('Cashier', sale.cashier);
    if (sale.customer.isNotEmpty) t.pair('Customer', sale.customer);
    t.rule();

    // items: every line, however many there are
    t.line('Item');
    for (final l in sale.lines) {
      final name = (l['name_snapshot'] ?? '').toString();
      final qty = toD(l['qty']);
      final price = toD(l['unit_price']);
      final total = toD(l['line_total']);
      final disc = toD(l['line_discount']);
      t.line(name);
      final detail = disc > 0
          ? '  ${qtyStr(qty)} x ${num2(price)}  -${num2(disc)}'
          : '  ${qtyStr(qty)} x ${num2(price)}';
      t.pair(detail, num2(total));
    }
    t.rule();

    // totals
    t.pair('Subtotal', num2(sale.subtotal));
    if (sale.discount > 0) t.pair('Discount', '- ${num2(sale.discount)}');
    if (sale.tax > 0) t.pair(store?.taxLabel ?? 'Tax', num2(sale.tax));
    t.bold(true);
    t.pair('TOTAL', '$sym ${num2(sale.total)}');
    t.bold(false);
    t.rule();

    t.pair(sale.payment.toUpperCase(), num2(sale.paid));
    t.pair('Change', num2(sale.change));
    if (sale.customer.isNotEmpty) {
      t.pair('Balance on account', num2(toD(sale.raw['customer_balance'])));
    }
    t.rule();

    t.align(1);
    final footer = (store?.receiptFooter ?? '').trim();
    t.line(footer.isEmpty ? 'Thank you!' : footer);
    t.line('Items: ${sale.lines.length}   Powered by Supermart POS');
    t.align(0);

    // feed past the cutter, then cut
    t.feed(4);
    t.cut();
    return t.bytes();
  }

  /// A printer test slip with the same header, so the real path is exercised.
  static Uint8List buildTest({
    required StoreSettings? store,
    required int paperMm,
    required String deviceName,
  }) {
    final t = _Ticket(columnsFor(paperMm));
    t.align(1);
    t.bold(true);
    t.line(store?.name ?? 'Supermart');
    t.bold(false);
    t.line('Printer test - ${paperMm}mm paper');
    t.line('Till: $deviceName');
    t.line(pkFormat('dd MMM yyyy  hh:mm a', DateTime.now()));
    t.align(0);
    t.feed(4);
    t.cut();
    return t.bytes();
  }
}

/// Collects ESC/POS bytes for one ticket.
class _Ticket {
  _Ticket(this.width);

  final int width;
  final List<int> _out = [0x1B, 0x40]; // ESC @: reset the printer

  Uint8List bytes() => Uint8List.fromList(_out);

  void align(int a) => _out.addAll([0x1B, 0x61, a]); // 0 left, 1 centre, 2 right

  void bold(bool on) => _out.addAll([0x1B, 0x45, on ? 1 : 0]);

  void feed(int lines) => _out.addAll([0x1B, 0x64, lines]);

  /// Partial cut. GS V 66 0: feed, then cut.
  void cut() => _out.addAll([0x1D, 0x56, 0x42, 0x00]);

  void line([String text = '']) {
    for (final chunk in _wrap(text, width)) {
      _out.addAll(_ascii(chunk));
      _out.add(0x0A);
    }
  }

  /// Left text on the left, right text on the right of the same line.
  void pair(String left, String right) {
    final room = (width - right.length - 1).clamp(1, width).toInt();
    final parts = _wrap(left, room);
    for (var i = 0; i < parts.length - 1; i++) {
      _out.addAll(_ascii(parts[i]));
      _out.add(0x0A);
    }
    final last = parts.isEmpty ? '' : parts.last;
    line(last.padRight(width - right.length) + right);
  }

  void rule() => line('-' * width);

  /// Word-wrap text to [columns]. A word longer than a line is split.
  static List<String> _wrap(String text, int columns) {
    final clean = text.trim();
    if (clean.length <= columns) return [clean];
    final out = <String>[];
    var current = '';
    for (final word in clean.split(' ')) {
      var w = word;
      while (w.length > columns) {
        if (current.isNotEmpty) {
          out.add(current);
          current = '';
        }
        out.add(w.substring(0, columns));
        w = w.substring(columns);
      }
      if (current.isEmpty) {
        current = w;
      } else if (current.length + 1 + w.length <= columns) {
        current = '$current $w';
      } else {
        out.add(current);
        current = w;
      }
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }

  /// The printer's default code page is ASCII-safe; anything else prints as '?'.
  static List<int> _ascii(String s) => [
        for (final c in s.codeUnits) (c >= 0x20 && c < 0x7F) ? c : 0x3F,
      ];
}
