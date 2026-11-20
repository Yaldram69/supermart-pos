# Project manifest — one project, every module

**There is only ONE project: this folder.** There is no "old project" and "new
project". Everything the system can do lives in the same `lib/` + `supabase/`
tree below, is wired into the same side menu, and is built into the same
`SupermartPOS.exe` by `BUILD_EXE.bat`.

If you have an earlier ZIP (or an extracted folder) on your PC, **throw it
away** and use this one only — otherwise you will build an old copy of the app
that is missing the newer modules.

---

## 1. Every module → its screen → its server function → the test that proves it

| # | Module (what the shop uses it for) | Screen / where in the app | Server RPC(s) | Proven by |
|---|---|---|---|---|
| 1 | **Billing / till** — scan, quantity, change | Billing | `pos_sale` → `create_sale` | main suite (sales, totals, change), app tests |
| 2 | **Barcode scanning** incl. leading zeros, scale labels, weighed items | Billing | — (client) + `set_product_weighed`, `save_scale_settings` | app tests, ops suite (scale prefix/mode rules) |
| 3 | **Manager PIN approval** (discount over a cashier's limit, cancel, refund) | Billing + Invoices | `pos_sale`, `pos_void_sale`, `pos_create_return`, `fx_elevate`, `set_manager_pin` | ops suite: 8 checks (sale, void, refund, wrong PIN, audit row) |
| 4 | **Hold & resume a bill** (F8 / F9) | Billing | — (stored on the PC) | app tests |
| 5 | **Invoices** — history, reprint, cancel, refund with reason | Invoices | `pos_void_sale`, `pos_create_return`, `v_sales_list`, `v_returns_list` | main suite (void puts stock back, refund limits), ops suite (PIN) |
| 6 | **Products / catalogue** — add, edit, tax-free pricing, categories, bulk paste-a-list import | Products | `save_product`, `bulk_import_products`, `delete_product`, `save_category`, `set_product_weighed` | main suite, ops suite (weighed flag) |
| 7 | **Barcode label printing** (Code128 sheet for loose/unbarcoded goods) | Products → Print labels | — (client PDF) | app tests (real PDF built headlessly) |
| 8 | **Stock & ledger** — every movement: sold, received, adjusted, returned | Stock & Purchases → Ledger | `adjust_stock`, `v_stock_movements` | main suite (ledger-driven stock) |
| 9 | **Reorder → purchase order** — low-stock list, suggested order, draft PO | Stock & Purchases → Reorder | `reorder_list`, `create_purchase_order`, `draft_purchases` | ops suite (draft created, grouped by supplier) |
| 10 | **Receiving a delivery** — stock in, weighted-average cost, one paper trail per delivery | Stock & Purchases → Purchases | `receive_purchase` (patched for draft orders), `purchases` | main suite + ops suite (draft → received) |
| 11 | **Supplier payables** — who you owe, pay, per-supplier ledger | Suppliers | `supplier_payables`, `pay_supplier`, `supplier_ledger` | ops suite (only received orders count as debt) |
| 12 | **Stock take** — count the shelves, post the differences | Stock take | `start_stock_take`, `stock_take_count`, `stock_take_detail`, `complete_stock_take`, `cancel_stock_take` | ops suite (variance posting, cancel is a no-op) |
| 13 | **Expenses** — rent, bills, transport with categories and totals | Expenses | `list_expenses`, `save_expense`, `delete_expense` | ops suite (totals, delete) |
| 14 | **Customers & udhaar** — credit sales, balances, take a payment, credit limit | Customers | `save_customer`, `receive_customer_payment` | main suite (credit limits, payments) |
| 15 | **Loyalty points** — earned on attached sales, balance shown, redeemed at the till | Billing + Customers | `loyalty_balance`, `redeem_loyalty_points` | ops suite (cannot spend more than held) |
| 16 | **Discounts** — percent, spend-X-get-Y, date windows, codes, manager-only rules | Discounts (admin) | `save_discount`, `delete_discount`, `check_discount_code` | main suite (limits per role) |
| 17 | **Employees & roles** — cashier / manager / admin / super admin, discount ceiling | Employees (super admin) | `save_employee`, `list_devices` | main suite (role refusals) |
| 18 | **Reports** — dashboard, best sellers, low stock, daily chart, credit owed, CSV | Reports (manager) | `dashboard_stats`, `sales_report` | main suite (report maths) |
| 19 | **Activity log** — who did what, on which PC, when | Activity log (admin) | `list_activity` | ops suite (PIN approval rows appear) |
| 20 | **Backup** — dated CSV folder of the whole shop | Settings → Backup | `backup_bundle` | ops suite (every table readable, phone + CSV row written) |
| 21 | **Offline cache + sales queue** — prices stay visible, sales are queued and re-sent | automatic | `pos_sale` (idempotent via `client_uuid`) | main suite (duplicate sale returns the same invoice) |
| 22 | **Live 4-PC stock** — a sale on PC 1 shows on PCs 2–4 in about a second | automatic (realtime) | — | race test: 4 tills selling the last unit |
| 23 | **Security** — RLS everywhere, no direct writes, anon locked out | automatic | `fx_require_role`, RLS policies | main suite (20/20 policies) + live privilege inspection |
| 24 | **Batch & expiry tracking** — every delivery can carry a batch number, made-on and expiry date; the shop is warned before goods go off; expired stock cannot be sold | Expiry & batches | `receive_purchase` (batch fields), `list_batches`, `expiring_stock`, `write_off_stock`, `save_product` (opening batch) | market suite (12 checks: batch created, expiry shown, money at risk, write-off, sale blocked) |
| 25 | **First-expire-first-out** — selling takes stock off the oldest-dated batch by itself, so the expiry list stays truthful | automatic (database trigger) | `fx_consume_batches` trigger | market suite (selling 5 took 5 off the batch) |
| 26 | **Quantity price tiers** — "10+ at 900 each" for shopkeepers, caterers, bulk buyers | Products → Bulk / quantity prices | `save_price_tier`, `delete_price_tier`, `price_tiers` (read) | market suite (tier price applied at 10, not at 9, and switchable off) |
| 27 | **Buy X get Y free offers** — per product or whole category, with dates, switch on/off, and a usage counter | Offers | `save_offer`, `delete_offer`, `list_offers` | market suite (3 for the price of 2, free value in the audit trail, switch works) |
| 28 | **Gift vouchers & store credit** — issue, print a slip, spend at the till as a part-payment, cancel | Gift vouchers | `issue_voucher`, `list_vouchers`, `voucher_balance`, `cancel_voucher` | market suite (issue, balance, part-payment, used-up refused, made-up code refused) |
| 29 | **Returns to supplier** — damaged or short-dated goods going back, credited off what you owe | Returns to supplier | `create_purchase_return`, `list_purchase_returns` | market suite (return note numbered, payable reduced by exactly the return value) |
| 30 | **Owner reports** — profit per product, cashier scoreboard, dead stock | Owner reports | `profit_by_product`, `cashier_performance`, `dead_stock` | market suite (all three return real rows for the day's sales) |
| 31 | **A4 invoice, purchase order and voucher printing** — company invoice with NTN and terms, printable supplier order, printable voucher slip, wallet-size member card with a scannable barcode | Invoices → A4 invoice, Stock & Purchases → Print order, Gift vouchers → Print slip, Customers → card | client-side PDFs (same printing path as receipts) | app tests cover the PDF path; the four new documents build on it |
| 24 | **Store settings** — name, NTN, receipt footer, printer width, till name, scale, loyalty rate | Settings | `save_store_settings`, `save_scale_settings` | main suite, ops suite |

Nothing in that table is a stub: every row has a screen (or is automatic), a
server function, and at least one automated check behind it.

## 2. Files in this project

### App (Flutter) — `lib/`

| Folder | Files |
|---|---|
| `lib/` | `main.dart`, `models.dart`, `theme.dart` |
| `lib/core/` | `app_config.dart` (PC identity, settings, offline cache, held bills, backup marker), `format.dart` (money/quantity/dates, `AppError`) |
| `lib/services/` | `api.dart` (every server call in one place, RPC-only writes) |
| `lib/state/` | `app_state.dart` (the till's brain: catalogue, cart, realtime, offline queue, held bills, scale parsing, loyalty) |
| `lib/screens/` | `shell.dart` (menu), `login_screen.dart`, `setup_screen.dart`, `pos_screen.dart`, `invoices_screen.dart`, `products_screen.dart`, `stock_screen.dart`, `stock_take_screen.dart`, `suppliers_screen.dart`, `expenses_screen.dart`, `customers_screen.dart`, `reports_screen.dart`, `discounts_screen.dart`, `employees_screen.dart`, `activity_screen.dart`, `settings_screen.dart` |
| `lib/widgets/` | `common.dart` (dialogs, cards, `askManagerPin`), `receipt.dart` (receipt + label PDFs) |

### Database — `supabase/`

| File | What it is |
|---|---|
| `SUPERMART_SETUP_CLEAN.sql` | **The file you paste for your real shop** — whole database, empty catalogue. Safe to re-run; already includes everything below. |
| `SUPERMART_SETUP.sql` | The same thing **plus 61 demo products** for practice. |
| `00` → `07`.sql | The same SQL split into readable sections (enums, tables, triggers/views, RPCs, security, seed, shop-floor module, big-supermarket module). `06_operations.sql` holds PIN, expenses, activity, payables, stock take, reorder, backup, loyalty, scale. `07_supermarket.sql` holds batches & expiry, price tiers, offers, vouchers, supplier returns and the owner reports. |
| `local_test/` | `test_suite.sql` (110 checks), `ops_test.sql` (67 checks), `market_test.sql` (44 checks for the big-supermarket module), `race_test.sh` (14 checks), `auth_shim.sql` (local-only helper). |

### Everything else

`START_HERE.md` (beginner guide) · `README.md` · `WHATS_NEW.md` (this round's
features) · `ROADMAP.md` (what's next) · `PROJECT_FILES.md` (file-by-file detail)
· `REQUIREMENTS_MAP.md` (requirement → code map) · `PRODUCTION_READINESS.md`
(what is proven and what is not) · `BUILD_EXE.bat` (builds the .exe) ·
`server_config.txt` (your two Supabase values) · `DEPLOY/README-FIRST.txt` ·
`android/`, `windows/`, `test/`, `pubspec.yaml`.

## 3. Current verification totals

| Suite | Result |
|---|---|
| `local_test/test_suite.sql` (core shop) | 110 PASS / 0 FAIL |
| `local_test/ops_test.sql` (shop-floor module) | 67 PASS / 0 FAIL |
| `local_test/market_test.sql` (big-supermarket module) | 44 PASS / 0 FAIL |
| `local_test/race_test.sh` (4 tills, last unit) | 14 PASS / 0 FAIL |
| `flutter test` (till arithmetic + label PDFs) | 23 PASS |
| `flutter analyze` | no issues |
| One-paste installer on a blank database, run twice | 0 errors, 30 tables, all with security rules, no demo data on the clean path |
| The same SQL as readable parts `00` → `07`, in order, on a blank database | 0 errors, and the same 110 / 67 / 44 / 14 results |

**258 automated checks, 0 failures.**

## 4. How to be sure your copy is the complete one

In the project folder you extracted, you should see all of these:

```
lib\screens\   ->  21 files (the list in section 2 above)
lib\models.dart, lib\services\api.dart, lib\widgets\common.dart, lib\widgets\receipt.dart
supabase\      ->  00..07 .sql  +  SUPERMART_SETUP.sql  +  SUPERMART_SETUP_CLEAN.sql  +  local_test\
```

Open the app and look at the side menu as an administrator. You must see, top to
bottom:
**Billing, Invoices, Products, Stock & Purchases, Stock take, Expiry & batches,
Offers, Returns to supplier, Suppliers, Expenses, Customers, Gift vouchers,
Reports, Owner reports, Discounts, Activity log, Employees, Settings.**
(What each person sees depends on their role — a cashier sees fewer.)

If any of those menu items is missing, you are running an old copy: delete the
folder, extract this ZIP again, run `flutter pub get`, then `BUILD_EXE.bat`.
