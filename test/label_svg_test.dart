import 'package:barcode/barcode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// The shelf/product labels are built as a PDF in which each Code128 barcode is
/// an SVG picture. That is the one new piece of this update that would fail on
/// the shop PC *while printing* rather than at compile time, so it is pinned
/// here: the same calls `ReceiptPrinter.printLabels` makes are run headless.
void main() {
  /// Exactly what printLabels() does for one label.
  pw.Document buildLabelSheet(String code) {
    final svg = Barcode.code128().toSvg(code, width: 150, height: 40, drawText: false);
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) => pw.Column(children: [
          pw.SvgImage(svg: svg, height: 34), // throws if the SVG is not usable
          pw.Text(code),
        ]),
      ),
    );
    return doc;
  }

  group('barcode labels', () {
    test('a numeric product barcode becomes a printable label sheet', () async {
      final doc = buildLabelSheet('8964000100062');
      final bytes = await doc.save();
      expect(bytes.length, greaterThan(1000), reason: 'a real PDF came out');
    });

    test('letters and digits both work (SKU-style codes)', () async {
      final doc = buildLabelSheet('SUGAR-5KG');
      final bytes = await doc.save();
      expect(bytes.length, greaterThan(1000));
    });

    test('an empty code is NOT refused by the barcode library - it draws a blank '
        'sticker - so printLabels substitutes the product id (>= 4 characters), '
        'and that fallback prints a real barcode', () {
      // the trap this guards against: no exception, just an unscannable label
      final blank = Barcode.code128().toSvg('', width: 150, height: 40, drawText: false);
      expect(() => pw.SvgImage(svg: blank, height: 34), returnsNormally);
      expect(blank.length, lessThan(700), reason: 'no bars drawn for an empty code');

      // the shipped fallback: first 12 characters of the product uuid
      final id = '9f8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d';
      final fallback = id.substring(0, 12);
      final svg = Barcode.code128().toSvg(fallback, width: 150, height: 40, drawText: false);
      expect(svg.length, greaterThan(1000), reason: 'real bars are drawn');
      expect(() => pw.SvgImage(svg: svg, height: 34), returnsNormally);
    });
  });
}
