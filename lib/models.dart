// Plain data objects. Every screen works with these instead of raw maps, so a
// typo in a field name shows up at build time rather than at the counter.
import 'core/format.dart';

double d(Map m, String k) => toD(m[k]);
String s(Map? m, String k, [String fallback = '']) =>
    m == null ? fallback : (m[k]?.toString() ?? fallback);
bool b(Map? m, String k, [bool fallback = false]) {
  if (m == null) return fallback;
  final v = m[k];
  if (v == null) return fallback;
  if (v is bool) return v;
  return v.toString().toLowerCase() == 'true';
}

DateTime? dt(Map? m, String k) => parseDate(m?[k]);

class PermissionSet {
  const PermissionSet({
    required this.role,
    required this.canSell,
    required this.canApproveDiscount,
    required this.canVoidSale,
    required this.canRefundSale,
    required this.canAdjustStock,
    required this.canManageStaff,
    required this.canOpenSettings,
    required this.canCloseShift,
  });

  final String role;
  final bool canSell;
  final bool canApproveDiscount;
  final bool canVoidSale;
  final bool canRefundSale;
  final bool canAdjustStock;
  final bool canManageStaff;
  final bool canOpenSettings;
  final bool canCloseShift;

  bool canPerform(String action) {
    switch (action) {
      case 'sell':
        return canSell;
      case 'approve_discount':
        return canApproveDiscount;
      case 'void_sale':
        return canVoidSale;
      case 'refund_sale':
        return canRefundSale;
      case 'adjust_stock':
        return canAdjustStock;
      case 'manage_staff':
        return canManageStaff;
      case 'open_settings':
        return canOpenSettings;
      case 'close_shift':
        return canCloseShift;
      default:
        return false;
    }
  }

  factory PermissionSet.forRole(String role) {
    final normalized = role.toLowerCase();
    switch (normalized) {
      case 'cashier':
        return const PermissionSet(
          role: 'cashier',
          canSell: true,
          canApproveDiscount: false,
          canVoidSale: false,
          canRefundSale: false,
          canAdjustStock: false,
          canManageStaff: false,
          canOpenSettings: false,
          canCloseShift: false,
        );
      case 'manager':
        return const PermissionSet(
          role: 'manager',
          canSell: true,
          canApproveDiscount: true,
          canVoidSale: true,
          canRefundSale: true,
          canAdjustStock: true,
          canManageStaff: false,
          canOpenSettings: false,
          canCloseShift: true,
        );
      case 'admin':
        return const PermissionSet(
          role: 'admin',
          canSell: true,
          canApproveDiscount: true,
          canVoidSale: true,
          canRefundSale: true,
          canAdjustStock: true,
          canManageStaff: true,
          canOpenSettings: true,
          canCloseShift: true,
        );
      case 'super_admin':
        return const PermissionSet(
          role: 'super_admin',
          canSell: true,
          canApproveDiscount: true,
          canVoidSale: true,
          canRefundSale: true,
          canAdjustStock: true,
          canManageStaff: true,
          canOpenSettings: true,
          canCloseShift: true,
        );
      default:
        return const PermissionSet(
          role: 'cashier',
          canSell: true,
          canApproveDiscount: false,
          canVoidSale: false,
          canRefundSale: false,
          canAdjustStock: false,
          canManageStaff: false,
          canOpenSettings: false,
          canCloseShift: false,
        );
    }
  }
}

class Identity {
  Identity(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get fullName => s(raw, 'full_name');
  String get username => s(raw, 'username');
  String get email => s(raw, 'email');
  String get phone => s(raw, 'phone');
  String get role => s(raw, 'role', 'cashier');
  String get roleLabel => role.replaceAll('_', ' ').toUpperCase();
  bool get isManager => b(raw, 'is_manager') || role.toLowerCase() == 'manager';
  bool get isAdmin => b(raw, 'is_admin') || role.toLowerCase() == 'admin';
  bool get isSuperAdmin => b(raw, 'is_super_admin') || role.toLowerCase() == 'super_admin';
  double get maxDiscountPercent => d(raw, 'max_discount_percent');
  PermissionSet get permissions => PermissionSet.forRole(role)
      .copyWith(
        canSell: true,
        canApproveDiscount: isManager || isAdmin || isSuperAdmin,
        canVoidSale: isManager || isAdmin || isSuperAdmin,
        canRefundSale: isManager || isAdmin || isSuperAdmin,
        canAdjustStock: isManager || isAdmin || isSuperAdmin,
        canManageStaff: isAdmin || isSuperAdmin,
        canOpenSettings: isAdmin || isSuperAdmin,
        canCloseShift: isManager || isAdmin || isSuperAdmin,
      );
}

extension PermissionSetCopy on PermissionSet {
  PermissionSet copyWith({
    String? role,
    bool? canSell,
    bool? canApproveDiscount,
    bool? canVoidSale,
    bool? canRefundSale,
    bool? canAdjustStock,
    bool? canManageStaff,
    bool? canOpenSettings,
    bool? canCloseShift,
  }) {
    return PermissionSet(
      role: role ?? this.role,
      canSell: canSell ?? this.canSell,
      canApproveDiscount: canApproveDiscount ?? this.canApproveDiscount,
      canVoidSale: canVoidSale ?? this.canVoidSale,
      canRefundSale: canRefundSale ?? this.canRefundSale,
      canAdjustStock: canAdjustStock ?? this.canAdjustStock,
      canManageStaff: canManageStaff ?? this.canManageStaff,
      canOpenSettings: canOpenSettings ?? this.canOpenSettings,
      canCloseShift: canCloseShift ?? this.canCloseShift,
    );
  }
}

class StoreSettings {
  StoreSettings(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name', 'Supermart');
  String get address => s(raw, 'address');
  String get phone => s(raw, 'phone');
  String get ntn => s(raw, 'ntn');
  String get currencySymbol => s(raw, 'currency_symbol', 'Rs');
  double get taxPercent => d(raw, 'tax_percent');
  bool get taxInclusive => b(raw, 'tax_inclusive');
  String get taxLabel => s(raw, 'tax_label', 'GST');
  bool get showTax => taxPercent > 0;
  String get receiptHeader => s(raw, 'receipt_header');
  String get receiptFooter => s(raw, 'receipt_footer');
  int get paperMm => (toD(raw['receipt_paper_mm'] ?? 80)).toInt();
  bool get allowNegativeStock => b(raw, 'allow_negative_stock');
  double get maxCashierDiscountPercent => d(raw, 'max_cashier_discount_percent');
  double get loyaltyPointsPer100 => d(raw, 'loyalty_points_per_100');
  double get loyaltyPointValue => d(raw, 'loyalty_point_value');
  String get scaleBarcodePrefix => s(raw, 'scale_barcode_prefix');
  String get scaleBarcodeMode => s(raw, 'scale_barcode_mode', 'weight');
  String get invoicePrefix => s(raw, 'invoice_prefix', 'INV');
  int get expiryAlertDays => d(raw, 'expiry_alert_days').toInt();
  bool get blockExpiredSales => raw['block_expired_sales'] == true;
  bool get requireExpiry => raw['require_expiry'] == true;
  bool get enableBatches => raw['enable_batches'] != false;
  bool get enableTiers => raw['enable_tiers'] != false;
  // Offers and vouchers removed from UI.
  bool get enableOffers => false;
  bool get enableVouchers => false;
  String get invoiceNote => s(raw, 'invoice_note');
  String get termsAndConditions => s(raw, 'terms_and_conditions');
}

class PosProduct {
  PosProduct(this.raw);
  static const Set<String> _weightUnits = {
    'kg', 'kilogram', 'kilograms', 'kilo', 'g', 'gram', 'grams', 'gm',
    'ltr', 'liter', 'litre', 'litres', 'liters', 'ml', 'lb', 'lbs', 'oz', 'ounce', 'ounces'
  };

  final Map<String, dynamic> raw;
  String get id => s(raw, 'id', s(raw, 'product_id'));
  String get barcode => s(raw, 'barcode');
  String get sku => s(raw, 'sku');
  String get name => s(raw, 'name');
  String get unit => s(raw, 'unit', 'pcs');
  double get salePrice => d(raw, 'sale_price');
  double? get taxPercent => raw['tax_percent'] == null ? null : d(raw, 'tax_percent');
  double get stockQty => d(raw, 'stock_qty');
  double get reorderLevel => d(raw, 'reorder_level');
  String get categoryName => s(raw, 'category_name');
  String? get categoryId => raw['category_id']?.toString();
  bool get isActive => b(raw, 'is_active', true);
  bool get isWeighed => b(raw, 'is_weighed', false);
  bool get isWeightLike {
    final normalized = unit.trim().toLowerCase();
    return isWeighed || _weightUnits.contains(normalized);
  }
  bool get isLow => stockQty <= reorderLevel;
  bool get isOut => stockQty <= 0;
  String get shelf => s(raw, 'shelf_location');
  double get costPrice => d(raw, 'cost_price');
  double get wholesalePrice => d(raw, 'wholesale_price');
  double get wholesaleMinQty => d(raw, 'wholesale_min_qty');
  String get pluCode => s(raw, 'plu_code');
  bool get isExpiryTracked => raw['is_expiry_tracked'] == true;
  String get brand => s(raw, 'brand');
  String get packSize => s(raw, 'pack_size');
  /// The price this quantity actually sells at, including any bulk buyer price
  /// and any quantity-break tiers. The system always uses the lowest valid rate.
  double priceFor(double qty) => priceForQty(qty, fallback: salePrice);

  List<Map<String, dynamic>> get priceTiers {
    final rawTiers = raw['price_tiers'];
    if (rawTiers is! List) return const [];
    return rawTiers
        .whereType<Map>()
        .map((tier) => Map<String, dynamic>.from(tier))
        .toList();
  }

  double priceForQty(double qty, {double fallback = 0}) {
    final base = fallback > 0 ? fallback : salePrice;
    var best = base;

    if (wholesaleMinQty > 0 && wholesalePrice > 0 && qty >= wholesaleMinQty && wholesalePrice < best) {
      best = wholesalePrice;
    }

    for (final tier in priceTiers) {
      final minQty = toD(tier['min_qty']);
      final tierPrice = toD(tier['price']);
      if (minQty > 0 && qty >= minQty && tierPrice > 0 && tierPrice < best) {
        best = tierPrice;
      }
    }
    return best;
  }

  /// Loose goods are always priced by weight. The app stores the unit as kg,
  /// but the cashier sometimes enters grams or a rupee amount.
  double priceForWeightKg(double kg) => salePrice * kg;

  double weightKgForPrice(double rupees) {
    if (salePrice <= 0) return 0;
    return rupees / salePrice;
  }

  double priceForGrams(double grams) => priceForWeightKg(grams / 1000);

  double gramsForPrice(double rupees) => weightKgForPrice(rupees) * 1000;
}

class AdminProduct {
  AdminProduct(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get sku => s(raw, 'sku');
  String get barcode => s(raw, 'barcode');
  String get name => s(raw, 'name');
  String get unit => s(raw, 'unit', 'pcs');
  String get categoryName => s(raw, 'category_name');
  String get supplierName => s(raw, 'supplier_name');
  double get costPrice => d(raw, 'cost_price');
  double get salePrice => d(raw, 'sale_price');
  double get stockQty => d(raw, 'stock_qty');
  double get reorderLevel => d(raw, 'reorder_level');
  double get stockValue => d(raw, 'stock_value');
  double get marginPercent => d(raw, 'margin_percent');
  bool get isActive => b(raw, 'is_active', true);
  bool get isLow => b(raw, 'is_low_stock') || stockQty <= reorderLevel;
  String get expiry => s(raw, 'expiry_date');
  double get wholesalePrice => d(raw, 'wholesale_price');
  double get wholesaleMinQty => d(raw, 'wholesale_min_qty');
  String get pluCode => s(raw, 'plu_code');
  bool get isExpiryTracked => raw['is_expiry_tracked'] == true;
  String get brand => s(raw, 'brand');
  String get packSize => s(raw, 'pack_size');
  String get countryOfOrigin => s(raw, 'country_of_origin');
  String get expiryDate => s(raw, 'expiry_date');
}

class CartLine {
  CartLine({required this.product, this.qty = 1, double? unitPrice, this.lineDiscount = 0})
      : unitPrice = unitPrice ?? product.salePrice;

  final PosProduct product;
  double qty;
  double unitPrice;
  double lineDiscount;

  double get effectiveUnitPrice {
    if (unitPrice > 0 && unitPrice != product.salePrice) return unitPrice;
    return product.priceForQty(qty, fallback: product.salePrice);
  }

  // Rounded per line to paisa, as the server does, so totals match the saved sale.
  double get gross => round2(effectiveUnitPrice * qty);
  double get net => round2(gross - lineDiscount);

  /// This line's tax, in paisa, for the store's rate (inclusive or added on top).
  double taxFor(double? pct, {required bool inclusive}) {
    if (pct == null || pct <= 0) return 0;
    if (inclusive) return round2(net - net / (1 + pct / 100));
    return round2(net * pct / 100);
  }

  Map<String, dynamic> toPayload() {
    final pid = product.id.trim();
    final isCustomLine = pid.isEmpty;
    final effectivePrice = effectiveUnitPrice;
    final payload = <String, dynamic>{
      'qty': qty,
      'name': product.name,
      'name_snapshot': product.name,
      'barcode': product.barcode,
      'barcode_snapshot': product.barcode,
      'unit': product.unit,
      'cost_price': product.costPrice,
      'tax_percent': product.taxPercent ?? 0,
      'unit_price': effectivePrice,
      if (lineDiscount > 0) 'line_discount': lineDiscount,
    };

    if (!isCustomLine) {
      payload['product_id'] = pid;
    }
    return payload;
  }
}

class Customer {
  Customer(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name');
  String get phone => s(raw, 'phone');
  double get balance => d(raw, 'balance');
  double get creditLimit => d(raw, 'credit_limit');
  int get loyaltyPoints => 0;
  bool get isActive => b(raw, 'is_active', true);
  String get cnic => s(raw, 'cnic');
  String get cardNo => s(raw, 'card_no');
  String get area => s(raw, 'area');
}

class DiscountRule {
  DiscountRule(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get code => s(raw, 'code');
  String get name => s(raw, 'name');
  String get kind => s(raw, 'kind', 'percent');
  double get value => d(raw, 'value');
  String get scope => s(raw, 'scope', 'all');
  double get minSubtotal => d(raw, 'min_subtotal');
  double? get maxDiscount => raw['max_discount'] == null ? null : d(raw, 'max_discount');
  bool get requiresManager => b(raw, 'requires_manager');
  bool get auto => b(raw, 'applies_automatically');
  bool get isActive => b(raw, 'is_active', true);
  int get usedCount => (toD(raw['used_count'])).toInt();
  int? get maxUses => raw['max_uses'] == null ? null : (toD(raw['max_uses'])).toInt();
  String get endsAt => s(raw, 'ends_at');
  String get label => kind == 'percent' ? '${num2(value)}%' : 'Rs ${num2(value)}';
}

class Employee {
  Employee(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get username => s(raw, 'username');
  String get fullName => s(raw, 'full_name');
  String get role => s(raw, 'role', 'cashier');
  bool get isActive => b(raw, 'is_active', true);
  double get maxDiscountPercent => d(raw, 'max_discount_percent');
  String get phone => s(raw, 'phone');
  String get salary => s(raw, 'salary');
  String get hiredOn => s(raw, 'hired_on');
  String get email => s(raw, 'email');
  DateTime? get lastLogin => dt(raw, 'last_login_at');
  String get cnic => s(raw, 'cnic');
  String get address => s(raw, 'address');
  String get designation => s(raw, 'designation');
}

class DeviceRow {
  DeviceRow(this.raw);
  final Map<String, dynamic> raw;
  String get name => s(raw, 'name');
  String get hostname => s(raw, 'hostname');
  int get terminalNo => (toD(raw['terminal_no'])).toInt();
  String get appVersion => s(raw, 'app_version');
  bool get isActive => b(raw, 'is_active', true);
  DateTime? get lastSeen => dt(raw, 'last_seen');
  bool get isRecent => lastSeen != null && DateTime.now().difference(lastSeen!).inMinutes < 3;
}

class Shift {
  Shift(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get shiftNo => s(raw, 'shift_no');
  String get status => s(raw, 'status', 'open');
  String get device => s(raw, 'device_name');
  DateTime? get openedAt => dt(raw, 'opened_at');
  double get openingFloat => d(raw, 'opening_float');
  bool get isOpen => status == 'open';
}

class SaleRow {
  SaleRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get invoiceNo => s(raw, 'invoice_no');
  DateTime? get createdAt => dt(raw, 'created_at') ?? dt(raw, 'at');
  double get total => d(raw, 'total');
  double get profit => d(raw, 'profit');
  double get subtotal => d(raw, 'subtotal');
  double get discount => d(raw, 'line_discount_total') + d(raw, 'invoice_discount_amount');
  double get tax => d(raw, 'tax_amount');
  double get refunded => d(raw, 'refunded_amount');
  String get status => s(raw, 'status', 'completed');
  String get payment => s(raw, 'payment_method', 'cash');
  String get cashier => s(raw, 'cashier_name');
  String get customer => s(raw, 'customer_name');
  String get device => s(raw, 'device_name');
  String get note => s(raw, 'note');
  int get itemCount => (toD(raw['item_count'])).toInt();
  double get paid => d(raw, 'paid_amount');
  double get change => d(raw, 'change_amount');
  bool get isVoid => status == 'void';
  bool get hasRefund => status == 'refunded' || status == 'partially_refunded';
  /// Rung up on this PC while offline and not yet on the server.
  bool get isQueued => id.startsWith('queued:');
  String get statusLabel => switch (status) {
        'void' => 'CANCELLED',
        'refunded' => 'REFUNDED',
        'partially_refunded' => 'PART REFUNDED',
        'queued' => 'WAITING TO SYNC',
        _ => 'PAID',
      };
}

class SaleLine {
  SaleLine(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name_snapshot');
  String get barcode => s(raw, 'barcode_snapshot');
  String get unit => s(raw, 'unit', 'pcs');
  double get qty => d(raw, 'qty');
  double get refundedQty => d(raw, 'refunded_qty');
  double get unitPrice => d(raw, 'unit_price');
  double get lineDiscount => d(raw, 'line_discount');
  double get tax => d(raw, 'tax_amount');
  double get lineTotal => d(raw, 'line_total');
  double get returnable => qty - refundedQty;
}

class LowStockRow {
  LowStockRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name');
  String get unit => s(raw, 'unit');
  String get categoryName => s(raw, 'category_name');
  String get supplierName => s(raw, 'supplier_name');
  String get supplierPhone => s(raw, 'supplier_phone');
  double get stockQty => d(raw, 'stock_qty');
  double get reorderLevel => d(raw, 'reorder_level');
  double get suggested => d(raw, 'suggested_order_qty');
  double get costPrice => d(raw, 'cost_price');
}

class MovementRow {
  MovementRow(this.raw);
  final Map<String, dynamic> raw;
  String get productName => s(raw, 'product_name');
  double get qtyChange => d(raw, 'qty_change');
  double get balanceAfter => d(raw, 'balance_after');
  String get type => s(raw, 'movement_type');
  String get note => s(raw, 'note');
  String get user => s(raw, 'actor');
  DateTime? get at => dt(raw, 'created_at');
}

class PurchaseRow {
  PurchaseRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get poNo => s(raw, 'po_no');
  String get supplierName => s(raw, 'supplier_name');
  String get status => s(raw, 'status');
  DateTime? get orderDate => dt(raw, 'order_date') ?? dt(raw, 'created_at');
  double get total => d(raw, 'total');
  double get paid => d(raw, 'paid_amount');
  double get unpaid => d(raw, 'unpaid');
  int get itemCount => (toD(raw['item_count'])).toInt();
}

class ExpenseRow {
  ExpenseRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get category => s(raw, 'category');
  String get description => s(raw, 'description');
  double get amount => d(raw, 'amount');
  DateTime? get spentAt => dt(raw, 'spent_at');
}

class Dashboard {
  Dashboard(this.raw);
  final Map<String, dynamic> raw;
  Map<String, dynamic> get today => (raw['today'] as Map?)?.cast<String, dynamic>() ?? {};
  Map<String, dynamic> get month => (raw['month'] as Map?)?.cast<String, dynamic>() ?? {};
  Map<String, dynamic> get cashierToday => (raw['cashier_today'] as Map?)?.cast<String, dynamic>() ?? {};
  double get todaySales => toD(today['sales']);
  double get todayProfit => toD(today['profit']);
  int get todayInvoices => toD(today['invoice_count']).toInt();
  double get todayCash => toD(today['cash']);
  double get monthSales => toD(month['sales']);
  double get monthProfit => toD(month['profit']);
  double get stockValue => toD(raw['stock_value']);
  double get stockRetail => toD(raw['stock_retail']);
  double get expensesToday => toD(raw['expenses_today']);
  double get customerDebt => toD(raw['customer_debt']);
  int get productCount => toD(raw['product_count']).toInt();
  int get lowStockCount => toD(raw['low_stock_count']).toInt();
  int get outOfStockCount => toD(raw['out_of_stock_count']).toInt();
  double get mySalesToday => toD(cashierToday['sales']);
  int get myInvoicesToday => toD(cashierToday['invoices']).toInt();
  List<Map<String, dynamic>> get series =>
      (raw['sales_series'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get recentSales =>
      (raw['recent_sales'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get topProducts =>
      (raw['top_products_today'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get devices =>
      (raw['devices'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get openShifts =>
      (raw['open_shifts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get lowStock =>
      (raw['low_stock_sample'] as List?)?.cast<Map<String, dynamic>>() ?? [];
}

class ShiftReport {
  ShiftReport(this.raw);
  final Map<String, dynamic> raw;
  double get invoices => toD(raw['invoice_count']);
  double get itemsSold => toD(raw['items_sold']);
  double get grossSales => toD(raw['gross_sales']);
  double get cashSales => toD(raw['cash_sales']);
  double get cardSales => toD(raw['card_sales']);
  double get otherSales => toD(raw['other_sales']);
  double get creditSales => toD(raw['credit_sales']);
  double get refunds => toD(raw['refunds']);
  double get expenses => toD(raw['expenses']);
  double get discount => toD(raw['total_discount']);
  double get tax => toD(raw['tax_collected']);
  double get profit => toD(raw['gross_profit']);
  double get expectedCash => toD(raw['expected_cash']);
  double get difference => toD(raw['difference']);
  List<Map<String, dynamic>> get topItems =>
      (raw['top_items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get paymentMix =>
      (raw['payment_mix'] as List?)?.cast<Map<String, dynamic>>() ?? [];
}

class SalesReport {
  SalesReport(this.raw);
  final Map<String, dynamic> raw;
  Map<String, dynamic> get totals => (raw['totals'] as Map?)?.cast<String, dynamic>() ?? {};
  double get sales => toD(totals['sales']);
  double get profit => toD(totals['profit']);
  double get tax => toD(totals['tax']);
  double get discounts => toD(totals['discounts']);
  double get refunds => toD(totals['refunds']);
  double get avgBasket => toD(totals['avg_basket']);
  int get invoiceCount => toD(totals['invoice_count']).toInt();
  List<Map<String, dynamic>> _l(String k) => (raw[k] as List?)?.cast<Map<String, dynamic>>() ?? [];
  List<Map<String, dynamic>> get daily => _l('daily');
  List<Map<String, dynamic>> get byPayment => _l('by_payment');
  List<Map<String, dynamic>> get byCashier => _l('by_cashier');
  List<Map<String, dynamic>> get byDevice => _l('by_device');
  List<Map<String, dynamic>> get topProducts => _l('top_products');
  List<Map<String, dynamic>> get byCategory => _l('by_category');
  List<Map<String, dynamic>> get hourly => _l('hourly');
  List<Map<String, dynamic>> get refundList => _l('refunds');
  Map<String, dynamic> get inventory => (raw['inventory'] as Map?)?.cast<String, dynamic>() ?? {};
}

class SaleResult {
  SaleResult(this.raw);
  final Map<String, dynamic> raw;
  String get saleId => s(raw, 'sale_id');
  String get invoiceNo => s(raw, 'invoice_no');
  double get total => d(raw, 'total');
  double get subtotal => d(raw, 'subtotal');
  double get discount => d(raw, 'line_discount_total') + d(raw, 'invoice_discount_amount');
  double get tax => d(raw, 'tax_amount');
  double get paid => d(raw, 'paid_amount');
  double get change => d(raw, 'change_amount');
  String get payment => s(raw, 'payment_method', 'cash');
  String get cashier => s(raw, 'cashier_name');
  String get customer => s(raw, 'customer_name');
  String get device => s(raw, 'device_name');
  bool get duplicate => b(raw, 'duplicate');
  DateTime? get createdAt => dt(raw, 'created_at');
  List<Map<String, dynamic>> get lines =>
      (raw['lines'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  Map<String, dynamic> get store =>
      (raw['store'] as Map?)?.cast<String, dynamic>() ?? {};

  bool _isMiscLine(Map<String, dynamic> line) {
    if (line['is_misc_item'] == true) return true;
    final productId = (line['product_id'] ?? line['product_id_snapshot'] ?? '').toString().trim();
    final name = (line['name_snapshot'] ?? line['name'] ?? '').toString().trim();
    return productId.isEmpty && name.isNotEmpty;
  }

  double get miscItemQty =>
      lines.where(_isMiscLine).fold<double>(0, (total, line) => total + toD(line['qty']));

  double get miscItemTotal =>
      lines.where(_isMiscLine).fold<double>(0, (total, line) => total + toD(line['line_total']));

  bool get hasMiscItems => miscItemQty > 0;

  String miscItemSummary(String symbol) {
    if (!hasMiscItems) return '';
    return 'Custom items: ${qtyStr(miscItemQty)} • ${money(miscItemTotal, symbol: symbol)}';
  }
}

class DeviceStats {
  DeviceStats(this.raw);
  final Map<String, dynamic> raw;
  String get name => s(raw, 'device');
  double get sales => d(raw, 'sales');
  int get invoices => toD(raw['invoices']).toInt();
}

class ActivityRow {
  ActivityRow(this.raw);
  final Map<String, dynamic> raw;
  String get action => s(raw, 'action');
  String get actorName => s(raw, 'actor_name', 'system');
  String get actorRole => s(raw, 'actor_role', '-');
  String get entity => s(raw, 'entity');
  String get deviceName => s(raw, 'device_name');
  DateTime? get at => dt(raw, 'at');
  Map<String, dynamic> get detail =>
      (raw['detail'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// Plain english for the log line, so the owner does not need to know SQL.
  String get label {
    switch (action) {
      case 'sale.create': return 'Sale';
      case 'sale.void': return 'Sale cancelled';
      case 'return.create': return 'Refund';
      case 'override.pin': return 'Manager approval (PIN)';
      case 'product.save': return 'Product saved';
      case 'product.delete': return 'Product removed';
      case 'stock.adjust': return 'Stock adjusted';
      case 'stocktake.start': return 'Stock take started';
      case 'stocktake.complete': return 'Stock take finished';
      case 'stocktake.cancel': return 'Stock take cancelled';
      case 'supplier.paid': return 'Paid a supplier';
      case 'expense.save': return 'Expense recorded';
      case 'expense.delete': return 'Expense deleted';
      case 'staff.save': return 'Staff details changed';
      case 'staff.pin_set': return 'Manager PIN set';
      case 'staff.pin_clear': return 'Manager PIN removed';
      case 'purchase.create': return 'Purchase order created';
      case 'purchase.receive': return 'Delivery received';
      case 'purchase.delete': return 'Draft order deleted';
      case 'loyalty.redeem': return 'Loyalty points used';
      case 'shift.open': return 'Shift opened';
      case 'shift.close': return 'Shift closed';
      case 'settings.save': return 'Shop settings changed';
      case 'settings.scale': return 'Scale settings changed';
      case 'customer.save': return 'Customer saved';
      case 'customer.payment': return 'Customer paid';
      default: return action.replaceAll('_', ' ').replaceAll('.', ' - ');
    }
  }

  String get summary {
    final d = detail;
    if (action == 'override.pin') {
      return 'approved for ${d['for_user'] ?? 'cashier'} (${d['about'] ?? 'override'})';
    }
    if (action.startsWith('sale.')) return '${d['invoice'] ?? ''} ${d['total'] ?? ''}'.trim();
    if (action == 'stock.adjust') return '${d['name'] ?? ''} by ${d['change'] ?? d['qty_change'] ?? ''}'.trim();
    if (action == 'product.save' || action == 'product.delete') return '${d['name'] ?? ''}'.trim();
    if (action == 'supplier.paid') return '${d['supplier'] ?? ''} ${d['amount'] ?? ''}'.trim();
    if (action == 'expense.save') return '${d['category'] ?? ''} ${d['amount'] ?? ''}'.trim();
    return '';
  }
}

class SupplierPayable {
  SupplierPayable(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'supplier_id');
  String get name => s(raw, 'name');
  String get phone => s(raw, 'phone');
  String get city => s(raw, 'city');
  double get purchases => d(raw, 'purchases');
  double get paid => d(raw, 'paid');
  double get outstanding => d(raw, 'outstanding');
  int get unpaidOrders => (toD(raw['unpaid_orders'])).toInt();
  DateTime? get lastAt => dt(raw, 'last_purchase_at');
}

class StockTakeRow {
  StockTakeRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get takeNo => s(raw, 'take_no');
  String get status => s(raw, 'status');
  String get note => s(raw, 'note');
  int get counted => (toD(raw['counted_rows'])).toInt();
  double get varianceValue => d(raw, 'variance_value');
  DateTime? get startedAt => dt(raw, 'started_at');
  DateTime? get completedAt => dt(raw, 'completed_at');
}

class StockTakeItemRow {
  StockTakeItemRow(this.raw);
  final Map<String, dynamic> raw;
  String get productId => s(raw, 'product_id');
  String get name => s(raw, 'name');
  String get barcode => s(raw, 'barcode');
  double get expected => d(raw, 'expected');
  double? get counted => raw['counted'] == null ? null : d(raw, 'counted');
  double get variance => d(raw, 'variance');
}

class ReorderRow {
  ReorderRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name');
  String get barcode => s(raw, 'barcode');
  String get unit => s(raw, 'unit', 'pcs');
  String get supplierId => s(raw, 'supplier_id');
  String get supplierName => s(raw, 'supplier_name', 'No supplier set');
  double get stockQty => d(raw, 'stock_qty');
  double get reorderLevel => d(raw, 'reorder_level');
  double get shortfall => d(raw, 'shortfall');
  double get suggested => d(raw, 'suggested_order_qty');
  double get costPrice => d(raw, 'cost_price');
}

// ======================================================= expiry & batches
class BatchRow {
  BatchRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get productId => s(raw, 'product_id');
  String get productName => s(raw, 'product_name');
  String get barcode => s(raw, 'barcode');
  String get unit => s(raw, 'unit', 'pcs');
  String get batchNo => s(raw, 'batch_no');
  String get supplierName => s(raw, 'supplier_name');
  String get poNo => s(raw, 'po_no');
  double get qtyReceived => d(raw, 'qty_received');
  double get qtyRemaining => d(raw, 'qty_remaining');
  double get unitCost => d(raw, 'unit_cost');
  double get value => d(raw, 'value');
  DateTime? get expiryDate => dt(raw, 'expiry_date');
  int? get daysLeft => raw['days_left'] == null ? null : d(raw, 'days_left').toInt();
  String get status => s(raw, 'status', 'fresh');
  bool get isExpired => status == 'expired';
  bool get isExpiring => status == 'expiring';
}

// ============================================================== offers
class OfferRow {
  OfferRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name');
  String get target => s(raw, 'target');
  String get productId => s(raw, 'product_id');
  String get categoryId => s(raw, 'category_id');
  double get buyQty => d(raw, 'buy_qty');
  double get freeQty => d(raw, 'free_qty');
  String get startsOn => s(raw, 'starts_on');
  String get endsOn => s(raw, 'ends_on');
  bool get isActive => raw['is_active'] == true;
  bool get isRunning => raw['running'] == true;
  int get timesUsed => d(raw, 'times_used').toInt();
  double get freeValueGiven => d(raw, 'free_value_given');
  String get summary => 'Buy ${num2(buyQty)} get ${num2(freeQty)} free';
}

// ============================================================ vouchers
class VoucherRow {
  VoucherRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get code => s(raw, 'code');
  String get kind => s(raw, 'kind', 'gift');
  double get value => d(raw, 'value');
  double get balance => d(raw, 'balance');
  double get used => d(raw, 'used');
  String get issuedTo => s(raw, 'issued_to');
  String get phone => s(raw, 'phone');
  String get reason => s(raw, 'reason');
  String get customerName => s(raw, 'customer_name');
  String get status => s(raw, 'status', 'active');
  String get expiresOn => s(raw, 'expires_on');
  bool get isActive => raw['is_active'] == true;
  DateTime? get createdAt => dt(raw, 'created_at');
}

// =================================================== purchase returns
class PurchaseReturnRow {
  PurchaseReturnRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get returnNo => s(raw, 'return_no');
  String get supplierName => s(raw, 'supplier_name');
  String get reason => s(raw, 'reason');
  String get note => s(raw, 'note');
  double get total => d(raw, 'total');
  String get settledBy => s(raw, 'settled_by', 'payable');
  int get itemCount => d(raw, 'item_count').toInt();
  DateTime? get createdAt => dt(raw, 'created_at');
  List<Map<String, dynamic>> get items =>
      ((raw['items'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

// ============================================================ analytics
class ProfitRow {
  ProfitRow(this.raw);
  final Map<String, dynamic> raw;
  String get name => s(raw, 'name');
  String get unit => s(raw, 'unit', 'pcs');
  double get qtySold => d(raw, 'qty_sold');
  double get gross => d(raw, 'gross');
  double get discount => d(raw, 'discount');
  double get cost => d(raw, 'cost');
  double get profit => d(raw, 'profit');
  double get margin => d(raw, 'margin');
  int get invoices => d(raw, 'invoices').toInt();
}

class CashierPerfRow {
  CashierPerfRow(this.raw);
  final Map<String, dynamic> raw;
  String get cashier => s(raw, 'cashier', 'Unknown');
  double get sales => d(raw, 'sales');
  int get invoices => d(raw, 'invoices').toInt();
  double get items => d(raw, 'items');
  double get discountsGiven => d(raw, 'discounts_given');
  double get averageBill => d(raw, 'average_bill');
  int get voids => d(raw, 'voids').toInt();
  double get refunds => d(raw, 'refunds');
  double get profit => d(raw, 'profit');
}

class DeadStockRow {
  DeadStockRow(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  String get name => s(raw, 'name');
  String get barcode => s(raw, 'barcode');
  String get unit => s(raw, 'unit', 'pcs');
  String get categoryName => s(raw, 'category_name');
  double get stockQty => d(raw, 'stock_qty');
  double get costPrice => d(raw, 'cost_price');
  double get salePrice => d(raw, 'sale_price');
  double get value => d(raw, 'value');
  int get daysIdle => d(raw, 'days_idle').toInt();
  String get expiryDate => s(raw, 'expiry_date');
}

class PriceTier {
  PriceTier(this.raw);
  final Map<String, dynamic> raw;
  String get id => s(raw, 'id');
  double get minQty => d(raw, 'min_qty');
  double get price => d(raw, 'price');
  String get label => s(raw, 'label');
}
