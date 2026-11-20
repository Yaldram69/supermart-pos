import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/models.dart';
import 'package:supermart_pos/services/thermal_receipt.dart';

const _cut = [0x1D, 0x56, 0x42, 0x00];

SaleResult _sale(int items, {String name = 'Item', bool numbered = true}) {
  final lines = [
    for (var i = 1; i <= items; i++)
      {
        'name_snapshot': numbered ? '$name-$i' : name,
        'qty': 1,
        'unit_price': 100,
        'line_total': 100,
        'line_discount': 0,
      },
  ];
  return SaleResult({
    'invoice_no': 'INV-1',
    'subtotal': 100.0 * items,
    'total': 100.0 * items,
    'paid_amount': 100.0 * items,
    'change_amount': 0,
    'lines': lines,
    'payment_method': 'cash',
    'cashier_name': 'Ali',
    'device_name': 'Till 1',
    'customer_name': '',
    'created_at': '2026-10-22T10:00:00Z',
  });
}

/// The text a printer would print: command bytes removed, one entry per line.
List<String> _printed(List<int> bytes) {
  var s = String.fromCharCodes(bytes);
  s = s.replaceAll(RegExp(r'\x1B@|\x1B[aEd][\s\S]|\x1D\x56\x42\x00'), '');
  s = s.replaceAll(RegExp(r'[\x00-\x09\x0B-\x1F]'), '');
  return s.split('\n');
}

int _count(List<int> bytes, List<int> pattern) {
  var n = 0;
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) n++;
  }
  return n;
}

void main() {
  for (final n in [1, 10, 20, 200]) {
    test('a sale with $n item(s) prints every item on one receipt', () {
      final bytes = ThermalReceipt.build(_sale(n), null, paperMm: 80);
      final lines = _printed(bytes);

      for (var i = 1; i <= n; i++) {
        expect(lines, contains('Item-$i'), reason: 'item $i is missing from the receipt');
      }
      expect(lines, contains('Items: $n   Powered by Supermart POS'));

      // exactly one cut, and it is the last thing sent
      expect(_count(bytes, _cut), 1);
      expect(bytes.sublist(bytes.length - 4), _cut);
    });
  }

  test('no printed line is wider than the paper (80mm and 58mm)', () {
    final wide = _printed(ThermalReceipt.build(_sale(30, name: 'LongerProductName'), null, paperMm: 80));
    expect(wide.every((l) => l.length <= 48), isTrue, reason: 'longest: ${wide.map((l) => l.length).reduce((a, b) => a > b ? a : b)}');

    final narrow = _printed(ThermalReceipt.build(_sale(30, name: 'LongerProductName'), null, paperMm: 58));
    expect(narrow.every((l) => l.length <= 32), isTrue);
  });

  test('a very long item name is split across lines without losing characters', () {
    const name = 'ABCDEFGHIJ';
    final long = name * 10; // 100 characters
    final lines = _printed(ThermalReceipt.build(_sale(1, name: long, numbered: false), null, paperMm: 80));
    final pieces = lines.where((l) => RegExp(r'^[A-J]+$').hasMatch(l)).join();
    expect(pieces, long);
  });

  test('a long basket still totals and shows the payment', () {
    final lines = _printed(ThermalReceipt.build(_sale(120), null, paperMm: 80));
    // amounts use the app's money format: whole amounts have no decimals
    expect(lines.any((l) => l.startsWith('TOTAL') && l.endsWith('Rs 12,000')), isTrue);
    expect(lines.any((l) => l.startsWith('CASH') && l.endsWith('12,000')), isTrue);
  });

  test('the printer test slip ends with a cut', () {
    final bytes = ThermalReceipt.buildTest(store: null, paperMm: 80, deviceName: 'Till 1');
    expect(bytes.sublist(bytes.length - 4), _cut);
    expect(_printed(bytes).any((l) => l.contains('Printer test')), isTrue);
  });
}
