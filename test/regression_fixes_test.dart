import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/core/app_config.dart';
import 'package:supermart_pos/core/format.dart';
import 'package:supermart_pos/core/reporting.dart';
import 'package:supermart_pos/models.dart';

void main() {
  group('cash-up variance is only reported when a drawer count exists', () {
    OperationalDashboardSummary summary({double? counted}) =>
        buildOperationalDashboardSummary(
          openingFloat: 1000,
          cashSales: 2000,
          refunds: 0,
          expenses: 0,
          countedCash: counted,
          pendingOffline: 0,
          lowStockCount: 0,
          openShiftCount: 0,
          onlineDeviceCount: 1,
          totalDeviceCount: 1,
        );

    test('no count means no balanced claim and no variance', () {
      final s = summary();
      expect(s.countedCash, isNull);
      expect(s.status, 'not counted');
      expect(s.variance, 0);
      expect(s.reasons.join(' '), contains('not counted yet'));
    });

    test('a real count is compared with the expected drawer total', () {
      expect(summary(counted: 2950).status, 'short');
      expect(summary(counted: 3050).status, 'over');
      expect(summary(counted: 3000).status, 'balanced');
      expect(summary(counted: 2950).variance, -50);
    });
  });

  group('trend buckets are ordered by date, not by label', () {
    test('month labels wrap the year correctly', () {
      final points = aggregateTrendByPeriod([
        {'day': '2026-12-01', 'sales': 10},
        {'day': '2027-01-01', 'sales': 5},
        {'day': '2026-08-01', 'sales': 3},
      ], 'month');

      expect(points.map((p) => p.label).toList(), ['Aug', 'Dec', 'Jan']);
      expect(points.map((p) => p.value).toList(), [3, 10, 5]);
    });
  });

  group('CSV cells are safe to open in a spreadsheet', () {
    test('text is quoted and inner quotes are doubled', () {
      expect(csvCell('12" Pizza'), '"12"" Pizza"');
      expect(csvCell('Tea, Milk'), '"Tea, Milk"');
    });

    test('formula starters are neutralised', () {
      expect(csvCell('=HYPERLINK("http://x")'), startsWith("\"'="));
      expect(csvCell('+1'), startsWith("\"'+"));
      expect(csvCell('-cmd'), startsWith("\"'-"));
      expect(csvCell('@SUM'), startsWith("\"'@"));
    });

    test('numbers are written as plain numbers, including negatives', () {
      expect(csvCell(12.5), '12.5');
      expect(csvCell(-40), '-40');
      expect(csvCell(null), '');
    });
  });

  group('till money matches the database to the paisa', () {
    test('rounds half away from zero, as PostgreSQL round(x, 2) does', () {
      expect(round2(1.005), 1.01);
      expect(round2(2.345), 2.35);
      expect(round2(-2.345), -2.35);
      expect(round2(12.5), 12.5);
      expect(round2(0.1 + 0.2), 0.3);
    });

    test('a line keeps its own paisa: 3 x 33.33 at 17% tax is 99.99 + 17.00', () {
      final product = PosProduct({
        'id': 'p3',
        'name': 'Sugar 1kg',
        'sale_price': 33.33,
        'tax_percent': 17,
        'stock_qty': 50,
        'is_active': true,
      });
      final line = CartLine(product: product, qty: 3);
      expect(line.gross, 99.99);
      expect(line.net, 99.99);
      expect(line.taxFor(17, inclusive: false), 17.0);
    });
  });

  group('the server address is never plain http, except for localhost', () {
    test('a pasted http address is upgraded to https', () {
      expect(AppConfig.normalizeUrl('http://abc.supabase.co/rest/v1/'),
          'https://abc.supabase.co');
    });

    test('a bare host gets https', () {
      expect(AppConfig.normalizeUrl('abc.supabase.co'), 'https://abc.supabase.co');
    });

    test('local development servers keep http', () {
      expect(AppConfig.normalizeUrl('http://localhost:54321'),
          'http://localhost:54321');
      expect(AppConfig.normalizeUrl('http://127.0.0.1:54321'),
          'http://127.0.0.1:54321');
    });
  });
}
