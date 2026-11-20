import 'package:intl/intl.dart';

/// A friendly error the UI can show, split out of the server's "CODE|message".
class AppError implements Exception {
  AppError(this.code, this.message);
  final String code;
  final String message;

  bool get isOffline => code == 'OFFLINE';

  /// The database raises errors as 'CODE|human readable text'. Anything else
  /// (a real Postgres error, a network drop) is shown as-is.
  factory AppError.parse(Object e) {
    final text = e.toString();
    final match = RegExp(r'^([A-Z_]{3,})\|(.+)$', dotAll: true).firstMatch(text.trim());
    if (match != null) {
      return AppError(match.group(1)!, match.group(2)!.trim());
    }
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('ClientException') ||
        text.contains('TimeoutException')) {
      return AppError('OFFLINE', 'No connection to the server. The sale will be saved and sent automatically.');
    }
    // The classic paste mistake: the URL has /rest/v1 or /auth/v1 on the end.
    if (text.contains('Invalid Path specified') || text.contains('statusCode: 404')) {
      return AppError(
          'BAD_SERVER_URL',
          'The Server URL is wrong. It must be only  https://your-project.supabase.co  '
          '- with no /rest/v1 or /auth/v1 on the end and no trailing slash. '
          'Open "Fix server details" on this screen (or Settings > Server) and paste it again.');
    }
    if (text.contains('Invalid API key') || text.contains('No API key found')) {
      return AppError('BAD_KEY',
          'The key does not belong to this project. Copy the anon / publishable key again.');
    }
    if (text.contains('Invalid login credentials')) {
      return AppError('BAD_LOGIN', 'Wrong email or password.');
    }
    if (text.contains('Email not confirmed')) {
      return AppError('BAD_LOGIN', 'This login has not been confirmed yet. Confirm it in Supabase.');
    }
    return AppError('ERROR', text.replaceFirst('Exception: ', ''));
  }

  @override
  String toString() => message;
}

final _money = NumberFormat('#,##0.##');
final _qty = NumberFormat('#,##0.###');

String money(Object? v, {String symbol = 'Rs'}) {
  final n = _toNum(v);
  return '$symbol ${_money.format(n)}';
}

String num2(Object? v) => _money.format(_toNum(v));
String qtyStr(Object? v) => _qty.format(_toNum(v));
num _toNum(Object? v) {
  if (v == null) return 0;
  if (v is num) return v;
  final s = v.toString().trim().replaceAll(',', '');
  if (s.isEmpty) return 0;
  return num.tryParse(s) ?? 0;
}

double toD(Object? v) => _toNum(v).toDouble();

/// Rounds money to paisa (2 decimals), half away from zero, exactly as the
/// database does (PostgreSQL round(x, 2)). Every till figure goes through this,
/// so the screen, the receipt and the saved sale agree to the paisa.
double round2(double value) {
  final scaled = value * 100;
  // the tiny nudge stops 1.005 (stored as 1.00499999...) from rounding down
  final nudged = scaled + (scaled >= 0 ? 1e-7 : -1e-7);
  return nudged.roundToDouble() / 100;
}

/// Reads a number a person typed or pasted, e.g. "1,250", " Rs 40 ", "1,250.50".
/// Returns null when it is not a number, so the caller decides what to do.
double? parseAmount(String? raw) {
  if (raw == null) return null;
  final cleaned = raw
      .replaceAll(',', '')
      .replaceAll(RegExp(r'Rs|PKR', caseSensitive: false), '')
      .trim();
  return double.tryParse(cleaned);
}

/// One CSV cell that is safe to open in Excel or Sheets.
/// - Text is always quoted, with inner quotes doubled, so a name like
///   `12" Pizza` or `Tea, Milk` cannot break the row.
/// - Text starting with = + - @ (or a tab / CR) is prefixed with an apostrophe,
///   so a product name cannot run as a formula (CSV injection).
/// Numbers are written as they are.
String csvCell(Object? value) {
  if (value == null) return '';
  if (value is num) return value.toString();
  var text = value.toString();
  if (text.isNotEmpty && '=+-@\t\r'.contains(text[0])) text = "'$text";
  return '"${text.replaceAll('"', '""')}"';
}

// ---------------------------------------------------------------- Pakistan time
// Rawalpindi is on PKT, UTC+5, with no daylight saving. Every date the shop sees
// or sends to the server is worked out in PKT, whatever the Windows clock says.
const Duration pkOffset = Duration(hours: 5);

/// The wall-clock time in Pakistan for this instant.
DateTime toPk(DateTime t) => t.toUtc().add(pkOffset);

extension PkDay on DateTime {
  /// yyyy-mm-dd of this instant in Pakistan time, for server date filters.
  String get pkDay {
    final p = toPk(this);
    return '${p.year.toString().padLeft(4, '0')}-'
        '${p.month.toString().padLeft(2, '0')}-'
        '${p.day.toString().padLeft(2, '0')}';
  }
}

/// The instant at which the Pakistan calendar day containing [instant] began
/// (midnight PKT). Use this for "today" filters.
DateTime pkStartOfDay([DateTime? instant]) {
  final p = toPk(instant ?? DateTime.now());
  return DateTime.utc(p.year, p.month, p.day).subtract(pkOffset);
}

/// Formats an instant as Pakistan wall-clock time.
class PkFormat {
  PkFormat(String pattern) : _f = DateFormat(pattern);
  final DateFormat _f;
  String format(DateTime t) => _f.format(toPk(t));
}

String pkFormat(String pattern, DateTime t) => DateFormat(pattern).format(toPk(t));

final PkFormat dateTimeFmt = PkFormat('dd MMM yyyy  hh:mm a');
final PkFormat dateFmt = PkFormat('dd MMM yyyy');
final PkFormat timeFmt = PkFormat('hh:mm a');
final DateFormat fileStamp = DateFormat('yyyyMMdd_HHmm');

DateTime? parseDate(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

String agoLabel(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} hr ago';
  return '${d.inDays} day(s) ago';
}
