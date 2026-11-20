# Roadmap — what is done, what is next

Last updated with the shop-floor update (Tier 1 + Tier 2). Everything marked
**Done** is in the ZIP, in the one-paste SQL and covered by the tests listed in
`WHATS_NEW.md`.

## Done — core shop system

| Area | State |
|---|---|
| Billing with barcode scanning, quantity, line/whole-bill discounts, discount codes | Done |
| Live shared stock across the 4 PCs (Supabase realtime) | Done |
| Invoices, reprint, returns/refunds with manager rules | Done |
| Products, categories, bulk CSV import, stock adjustments | Done |
| Customers with udhaar (credit) balances and payments | Done |
| Employees, roles (cashier / manager / admin / super admin), device list | Done |
| Reports: day close, sales, profit, stock value, shift cash-up | Done |
| Offline queue for sales rung while the internet is down | Done |
| Row-level security, RPC-only writes, audit trail | Done |

## Done — big-supermarket module (round 3, part 7 of the SQL)

| Area | State |
|---|---|
| Batch tracking on deliveries and on new products (batch no, made-on, expiry) | Done |
| Expiry alerts, money-at-risk figure and write-offs with reasons | Done |
| First-expire-first-out: sales consume the oldest batch automatically | Done |
| Refuse to sell out-of-date stock (switchable, off by default) | Done |
| Quantity / wholesale price breaks per product | Done |
| Buy-X-get-Y-free offers (product or whole category, dated, switchable) | Done |
| Gift vouchers & store credit, printable slip, part-payment at the till | Done |
| Returns to the supplier with payable/cash/replacement settlement | Done |
| Owner reports: profit per product, cashier scoreboard, dead stock | Done |
| A4 invoice with terms, printable purchase order, membership card | Done |

## Done — shop-floor update (Tier 1 + Tier 2)

| Area | State |
|---|---|
| Offline catalogue cache (products/prices/customers on the PC) | Done |
| Manager PIN approval at the till | Done |
| Hold & resume bill (F8 / F9) | Done |
| CSV backup button + last-backup reminder | Done |
| Expense book with categories and period totals | Done |
| Activity log viewer in plain English | Done |
| Supplier payables, payments and per-supplier ledger | Done |
| Stock take mode with variance posting | Done |
| Reorder list → draft purchase order → receive | Done |
| Weighing-scale barcode reading + label printing | Done |
| Loyalty points redemption at the till | Done |

## Next candidates (Tier 3) — pick when you need them

Ordered by what usually pays off first in a Pakistani superstore of this size:

1. **Expiry & batch tracking on screen** — the database already stores expiry
   dates; a "nearly expired" report and a warning at the till would finish it.
2. **Purchase return to supplier** — send damaged/near-expiry goods back and
   reduce what you owe.
3. **Customer WhatsApp/SMS bill** — send the invoice as a picture/link instead
   of printing, useful when the printer jams or the customer asks for a copy.
4. **Shelf-label batch printing by category** — currently you print after a
   search; a "print a whole category's labels" flow saves an hour at setup.
5. **Multi-warehouse / storeroom transfer** — one back-room location with a
   transfer document.
6. **Owner dashboard on the phone** — the same numbers as Reports, read-only,
   so you can check the day's sales from home. Android build included.
7. **Android till** — the code supports it; it needs a real phone/tablet test
   with a Bluetooth scanner before I would call it done.
8. **GST / FBR tax invoice format** — only worth building if you register; the
   current bills are deliberately tax-line-free as you asked.

## Ground rules I keep

* Anything new has to work on a bad internet day (offline cache + queue).
* No feature ships without a printed test result (SQL suites + app tests).
* No demo data on the production install path.
* Anything a cashier can abuse needs a server-side check, not just a hidden button.
