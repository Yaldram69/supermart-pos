import 'dart:async';
import 'dart:typed_data';

import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../models.dart';
import '../services/raw_printer.dart';
import '../services/thermal_receipt.dart';

class ReceiptPreviewData {
  const ReceiptPreviewData({required this.title, required this.lines});

  final String title;
  final List<String> lines;
}

/// Prints receipts. Thermal receipts go out as raw ESC/POS (see ThermalReceipt);
/// A4 invoices, labels and the preview use PDF.
class ReceiptPrinter {
  static ReceiptPreviewData buildPreviewData({
    required SaleResult sale,
    required StoreSettings? store,
    bool reprint = false,
    String? offlineNote,
  }) {
    final lines = <String>[];
    final headerName = store?.name ?? 'Supermart';
    final footer = (store?.receiptFooter ?? 'Thank you!').trim();
    final header = (store?.receiptHeader ?? '').trim();

    lines.add(headerName);
    if ((store?.address ?? '').isNotEmpty) lines.add(store!.address);
    if ((store?.phone ?? '').isNotEmpty) lines.add('Tel: ${store!.phone}');
    if (header.isNotEmpty) lines.add(header);
    if (reprint) lines.add('*** DUPLICATE COPY ***');
    if (offlineNote != null && offlineNote.isNotEmpty) lines.add(offlineNote);
    lines.add('Invoice: ${sale.invoiceNo}');
    lines.add(
      'Date: ${sale.createdAt == null ? '' : pkFormat('dd/MM/yyyy hh:mm a', sale.createdAt!)}',
    );
    lines.add('Till: ${sale.device}');
    lines.add('Cashier: ${sale.cashier}');
    if (sale.customer.isNotEmpty) lines.add('Customer: ${sale.customer}');
    lines.add('');
    lines.add('Item');
    for (final line in sale.lines) {
      final name = (line['name_snapshot'] ?? '').toString();
      final qty = toD(line['qty']);
      final price = toD(line['unit_price']);
      final total = toD(line['line_total']);
      // full name on its own line, like the printed receipt
      lines.add(name);
      lines.add('  ${qtyStr(qty)} x ${num2(price)}  ${num2(total)}');
    }
    lines.add('');
    lines.add('Subtotal: ${num2(sale.subtotal)}');
    if (sale.discount > 0) lines.add('Discount: - ${num2(sale.discount)}');
    if (sale.tax > 0) lines.add('${store?.taxLabel ?? 'Tax'}: ${num2(sale.tax)}');
    lines.add('TOTAL: ${store?.currencySymbol ?? 'Rs'} ${num2(sale.total)}');
    lines.add('Paid: ${store?.currencySymbol ?? 'Rs'} ${num2(sale.paid)}');
    if (sale.change > 0) lines.add('Change: ${store?.currencySymbol ?? 'Rs'} ${num2(sale.change)}');
    if (footer.isNotEmpty) lines.add('');
    if (footer.isNotEmpty) lines.add(footer);

    return ReceiptPreviewData(
      title: reprint
          ? 'Duplicate copy preview — ${sale.invoiceNo}'
          : 'Receipt preview — ${sale.invoiceNo}',
      lines: lines,
    );
  }

  static Future<void> showPrintPreview(
    BuildContext context, {
    required SaleResult sale,
    required StoreSettings? store,
    bool reprint = false,
    String? offlineNote,
    Future<void> Function()? onPrint,
  }) async {
    final preview = buildPreviewData(
      sale: sale,
      store: store,
      reprint: reprint,
      offlineNote: offlineNote,
    );

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(preview.title),
        content: SizedBox(
          width: 500,
          height: 560,
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                preview.lines.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              // close the dialog first; `context` (the screen) stays mounted for the message
              Navigator.pop(c);
              if (onPrint != null) {
                try {
                  await onPrint();
                } catch (_) {
                  if (context.mounted) _showPrinterError(context);
                }
                return;
              }
              await printSale(
                context,
                result: sale.raw,
                store: store,
                reprint: reprint,
                offlineNote: offlineNote,
              );
            },
            icon: const Icon(Icons.print),
            label: Text(reprint ? 'Print duplicate' : 'Print receipt'),
          ),
        ],
      ),
    );
  }

  /// Prints one sale as a single thermal receipt, however many items it has.
  static Future<void> printSale(
    BuildContext? context, {
    required Map<String, dynamic> result,
    required StoreSettings? store,
    bool reprint = false,
    String? offlineNote,
  }) async {
    final sale = SaleResult(result);
    final ok = await _sendToThermal(
      ThermalReceipt.build(
        sale,
        store,
        paperMm: AppConfig.paperMm,
        reprint: reprint,
        offlineNote: offlineNote,
      ),
      docName: reprint ? '${sale.invoiceNo}_copy' : sale.invoiceNo,
    );
    if (!ok && context != null && context.mounted) _showPrinterError(context);
  }

  static Future<void> printTest(
    BuildContext context,
    StoreSettings? store,
  ) async {
    final ok = await _sendToThermal(
      ThermalReceipt.buildTest(
        store: store,
        paperMm: AppConfig.paperMm,
        deviceName: AppConfig.deviceName,
      ),
      docName: 'printer-test',
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Test receipt sent to the printer.'
              : 'Could not reach the thermal printer. Check its name in Settings.',
        ),
      ),
    );
  }

  /// Sends raw ESC/POS bytes to the thermal printer chosen in Settings,
  /// or to the Windows default printer when none is chosen.
  static Future<bool> _sendToThermal(Uint8List bytes, {required String docName}) async {
    final chosen = AppConfig.thermalPrinter;
    final printer = chosen.isNotEmpty ? chosen : RawPrinter.defaultPrinter();
    if (printer == null || printer.isEmpty) return false;
    return RawPrinter.send(printer, bytes, docName: docName);
  }

  static void _showPrinterError(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'The receipt could not be printed. Check that the thermal printer is on and its name in Settings is right. '
          'The sale is saved: reprint it from Invoices.',
        ),
      ),
    );
  }

  /// Shelf / product labels with a scannable Code128 barcode.
  /// Print on sticker paper - handy for loose goods and anything that has no
  /// printed barcode of its own.
  static Future<void> printLabels({
    required String storeName,
    required String symbol,
    required List<Map<String, dynamic>> labels,
  }) async {
    final doc = pw.Document();
    const perRow = 3;

    for (var start = 0; start < labels.length; start += perRow) {
      final row = labels.skip(start).take(perRow).toList();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (ctx) => pw.Wrap(
            spacing: 8,
            runSpacing: 8,
            children: row.map((l) {
              final code = (l['barcode'] ?? '') as String;
              final name = (l['name'] ?? '') as String;
              final price = toD(l['price']);
              final unit = (l['unit'] ?? '') as String;
              String priceLabel;
              if (unit.isEmpty) {
                priceLabel = '$symbol ${num2(price)}';
              } else {
                priceLabel = '$symbol ${num2(price)} / $unit';
              }
              var svg = '';
              try {
                svg = Barcode.code128().toSvg(
                  code,
                  width: 150,
                  height: 40,
                  drawText: false,
                );
              } catch (_) {
                svg = '';
              }

              return pw.Container(
                width: 178,
                padding: const pw.EdgeInsets.all(6),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.Text(
                      storeName,
                      style: const pw.TextStyle(
                        fontSize: 7,
                        color: PdfColors.grey700,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      name,
                      maxLines: 2,
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    if (svg.isNotEmpty) pw.SvgImage(svg: svg, height: 34),
                    if (svg.isNotEmpty) pw.SizedBox(height: 2),
                    pw.Text(
                      code,
                      style: const pw.TextStyle(
                        fontSize: 8,
                        letterSpacing: 0.6,
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(
                      priceLabel,
                      style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      );
    }

    await Printing.layoutPdf(
      name: 'supermart-labels-${DateTime.now().millisecondsSinceEpoch}.pdf',
      format: PdfPageFormat.a4,
      onLayout: (format) => doc.save(),
    );
  }

  // ==================================================== A4 tax-free invoice
  /// A full-page invoice for corporate customers who need one with the shop's
  /// NTN and terms on it. No tax line unless the shop has a tax rate set.
  static Future<void> printA4Invoice({
    required SaleResult sale,
    required StoreSettings store,
    String? customerPhone,
  }) async {
    final doc = pw.Document();
    final sym = store.currencySymbol;
    final raw = sale.raw;
    final taxLabel = store.taxLabel.isEmpty ? 'Tax' : store.taxLabel;
    final lines = ((raw['lines'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (ctx) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    store.name,
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (store.address.isNotEmpty) pw.Text(store.address),
                  if (store.phone.isNotEmpty) pw.Text('Phone: ${store.phone}'),
                  if (store.ntn.isNotEmpty) pw.Text('NTN: ${store.ntn}'),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'INVOICE',
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text('No: ${sale.invoiceNo}'),
                  pw.Text(
                    'Date: ${dateTimeFmt.format(DateTime.tryParse('${raw['created_at']}') ?? DateTime.now())}',
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'BILL TO',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text(
                    sale.customer.isEmpty ? 'Walk-in customer' : sale.customer,
                  ),
                  if (customerPhone != null && customerPhone.isNotEmpty)
                    pw.Text(customerPhone),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('Served by: ${sale.cashier}'),
                  pw.Text('Counter: ${sale.device}'),
                  pw.Text('Payment: ${sale.payment.toUpperCase()}'),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Item', 'Qty', 'Rate', 'Amount'],
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 10,
            ),
            cellStyle: const pw.TextStyle(fontSize: 10),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.centerRight,
            },
            data: [
              for (var i = 0; i < lines.length; i++)
                [
                  '${i + 1}',
                  '${lines[i]['name_snapshot']}',
                  '${lines[i]['qty']} ${lines[i]['unit'] ?? ''}',
                  toD(lines[i]['unit_price']).toStringAsFixed(2),
                  toD(lines[i]['line_total']).toStringAsFixed(2),
                ],
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              pw.SizedBox(
                width: 260,
                child: pw.Column(
                  children: [
                    _kv('Subtotal', '$sym ${sale.subtotal.toStringAsFixed(2)}'),
                    if (sale.discount > 0)
                      _kv(
                        'Discounts',
                        '- $sym ${sale.discount.toStringAsFixed(2)}',
                      ),
                    if (sale.tax > 0)
                      _kv(taxLabel, '$sym ${sale.tax.toStringAsFixed(2)}'),
                    pw.Divider(),
                    _kv(
                      'TOTAL',
                      '$sym ${sale.total.toStringAsFixed(2)}',
                      bold: true,
                    ),
                    _kv('Paid', '$sym ${sale.paid.toStringAsFixed(2)}'),
                    if (sale.change > 0)
                      _kv('Change', '$sym ${sale.change.toStringAsFixed(2)}'),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          if (store.invoiceNote.isNotEmpty)
            pw.Text(store.invoiceNote, style: const pw.TextStyle(fontSize: 10)),
          if (store.termsAndConditions.isNotEmpty) ...[
            pw.SizedBox(height: 6),
            pw.Text(
              store.termsAndConditions,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ],
          pw.SizedBox(height: 24),
          pw.Text(
            'Signature: ______________________',
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      name: 'invoice-${sale.invoiceNo}.pdf',
      format: PdfPageFormat.a4,
      onLayout: (format) => doc.save(),
    );
  }

  static pw.Widget _kv(String k, String v, {bool bold = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          k,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: bold ? pw.FontWeight.bold : null,
          ),
        ),
        pw.Text(
          v,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: bold ? pw.FontWeight.bold : null,
          ),
        ),
      ],
    ),
  );

  // ============================================================ gift voucher
  /// A small slip the customer keeps: the code, the value and the expiry.
  static Future<void> printVoucher({
    required String storeName,
    required String symbol,
    required String code,
    required double value,
    String issuedTo = '',
    String expiresOn = '',
    String phone = '',
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          120 * PdfPageFormat.mm,
        ),
        margin: const pw.EdgeInsets.all(8),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              storeName,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'GIFT VOUCHER',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              '$symbol ${num2(value)}',
              style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(border: pw.Border.all()),
              child: pw.Text(
                code,
                style: const pw.TextStyle(fontSize: 16, letterSpacing: 1.5),
              ),
            ),
            pw.SizedBox(height: 8),
            if (issuedTo.isNotEmpty)
              pw.Text('For: $issuedTo', style: const pw.TextStyle(fontSize: 9)),
            if (expiresOn.isNotEmpty)
              pw.Text(
                'Use by: $expiresOn',
                style: const pw.TextStyle(fontSize: 9),
              ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Show this slip at the counter. The balance can be used',
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 8),
            ),
            pw.Text(
              'on any purchase, in part or in full.',
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 8),
            ),
            pw.SizedBox(height: 6),
            if (phone.isNotEmpty)
              pw.Text(
                phone,
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey700,
                ),
              ),
          ],
        ),
      ),
    );
    await Printing.layoutPdf(
      name: 'voucher-$code.pdf',
      format: const PdfPageFormat(
        80 * PdfPageFormat.mm,
        120 * PdfPageFormat.mm,
      ),
      onLayout: (format) => doc.save(),
    );
  }

  // ======================================================= purchase order
  /// The order you send/hand to the supplier: what to send and how much.
  static Future<void> printPurchaseOrder({
    required Map<String, dynamic> order,
    required StoreSettings store,
    String supplierPhone = '',
    String supplierAddress = '',
  }) async {
    final doc = pw.Document();
    final sym = store.currencySymbol;
    final items = ((order['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final total = items.fold<double>(
      0,
      (a, i) => a + toD(i['qty']) * toD(i['unit_cost']),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (ctx) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    store.name,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (store.address.isNotEmpty)
                    pw.Text(
                      store.address,
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  if (store.phone.isNotEmpty)
                    pw.Text(
                      'Phone: ${store.phone}',
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'PURCHASE ORDER',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'No: ${order['po_no']}',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.Text(
                    'Date: ${order['order_date'] ?? ''}',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'TO',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 10,
                ),
              ),
              pw.Text(
                '${order['supplier_name'] ?? ''}',
                style: const pw.TextStyle(fontSize: 11),
              ),
              if (supplierAddress.isNotEmpty)
                pw.Text(
                  supplierAddress,
                  style: const pw.TextStyle(fontSize: 10),
                ),
              if (supplierPhone.isNotEmpty)
                pw.Text(
                  'Phone: $supplierPhone',
                  style: const pw.TextStyle(fontSize: 10),
                ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Item', 'Qty', 'Cost', 'Amount'],
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 10,
            ),
            cellStyle: const pw.TextStyle(fontSize: 10),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.centerRight,
            },
            data: [
              for (var i = 0; i < items.length; i++)
                [
                  '${i + 1}',
                  '${items[i]['name'] ?? ''}',
                  toD(items[i]['qty']).toStringAsFixed(2),
                  toD(items[i]['unit_cost']).toStringAsFixed(2),
                  (toD(items[i]['qty']) * toD(items[i]['unit_cost']))
                      .toStringAsFixed(2),
                ],
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Order value: $sym ${total.toStringAsFixed(2)}',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12),
            ),
          ),
          if ((order['note'] ?? '').toString().isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Text(
              'Note: ${order['note']}',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ],
          pw.SizedBox(height: 22),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Ordered by: ______________________',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.Text(
                'Supplier confirmation: ______________________',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Text(
            'Please deliver in the quantities above and mention the PO number on the bill.',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    );
    await Printing.layoutPdf(
      name: 'po-${order['po_no']}.pdf',
      format: PdfPageFormat.a4,
      onLayout: (format) => doc.save(),
    );
  }

  // ====================================================== membership card
  /// A small loyalty card the customer keeps in their wallet. The card number
  /// is a real barcode, so the cashier can scan it instead of typing a phone.
  static Future<void> printMembershipCard({
    required String storeName,
    required String customerName,
    required String cardNo,
    required String phone,
    String symbol = 'Rs',
  }) async {
    final doc = pw.Document();
    String svg = '';
    try {
      svg = Barcode.code128().toSvg(
        cardNo,
        width: 200,
        height: 40,
        drawText: false,
      );
    } catch (_) {
      svg = '';
    }
    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(
          90 * PdfPageFormat.mm,
          55 * PdfPageFormat.mm,
        ),
        margin: const pw.EdgeInsets.all(6),
        build: (ctx) => pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey500, width: 1),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    storeName,
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'MEMBER CARD',
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                customerName,
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(phone, style: const pw.TextStyle(fontSize: 8)),
              pw.SizedBox(height: 3),
              if (svg.isNotEmpty) pw.SvgImage(svg: svg, height: 26),
              pw.SizedBox(height: 1),
              pw.Text(
                cardNo,
                style: const pw.TextStyle(fontSize: 8, letterSpacing: 1),
              ),
            ],
          ),
        ),
      ),
    );
    await Printing.layoutPdf(
      name: 'member-$cardNo.pdf',
      format: const PdfPageFormat(90 * PdfPageFormat.mm, 55 * PdfPageFormat.mm),
      onLayout: (format) => doc.save(),
    );
  }
}
