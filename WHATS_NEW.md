# What's new — the shop-floor update, then the big-supermarket module

> **Round 3 (this version): the big-supermarket module.** Part 7 of the SQL adds
> **batches & expiry dates**, **quantity price tiers**, **buy-X-get-Y offers**,
> **gift vouchers / store credit**, **returns to the supplier**, and three
> **owner reports** — with five new screens in the side menu and the shop-wide
> switches to turn each one on or off. Details in section 7 below.

**One project, not two.** Everything described here is inside the same project
as the Billing, Invoices, Products, Customers, Discounts, Employees and Reports
screens you already had — same folder, same `BUILD_EXE.bat`, same `.exe`, same
side menu. See `PROJECT_MANIFEST.md` for the module-by-module proof. If you have
an older ZIP or extracted folder on your PC, delete it: use this one only.

This is the round of work you approved after the deployment-readiness report:
everything that was on the "not built yet" list is now **built, wired into the
app and tested**. Nothing here is a mock-up or a placeholder.

If your database is already set up, re-run the one-paste SQL once
(`SUPERMART_SETUP_CLEAN.sql` — it is safe on top of an existing shop, it only
adds things) and rebuild the app; your products, sales and users are untouched.

---

## 1. Manager PIN — approve without leaving the bill

**The problem:** a cashier with a 5% limit cannot finish a sale where the
customer got 8% off. Until now that meant signing out, losing the bill, and
re-ringing everything.

**Now:** the till asks for a manager PIN *inside* the sale. The manager types
4–8 digits, presses Approve, and the same bill continues. The PIN is checked on
the server (never stored on the PC), it is stored as a bcrypt hash, and every
single approval lands in the Activity log with the manager's name and the PC it
happened on.

*Where:* **Settings → Manager PIN** to set it once per manager.

## 2. Hold & resume a bill (F8 / F9)

Park a half-rung bill (customer ran back for milk) and serve the next person.
**F8** holds it, **F9** brings it back — with a name/note if you want one.
Held bills live on that PC only, and nothing reaches the server until you
actually charge it.

## 3. Weighing scale + barcode labels (for loose items)

You said you sell a lot of atta, rice, sugar and fresh produce, so this got
built properly:

* **Scale labels:** tell the app in **Settings → Weighing scale** which digits
  your scale prints first and whether the label carries the **weight** or the
  **price**. Scanning one of those labels then bills the exact weight — no
  typing at the counter. Partial/re-weighed labels are handled too.
* **Sold by weight:** tick this on a product and the till asks for the weight
  instead of assuming "1 piece". Prices stay per kg.
* **Print labels:** **Products → Print labels** prints Code128 sticker labels
  with a scannable barcode for anything that has none.

## 4. Stock take mode

**Stock take** starts a count without stopping sales. You scan/type what is
really on the shelf (scale labels work here too). Nothing changes in the books
until you press **Finish & correct stock** — then every difference is posted to
the stock ledger in one go, with your name on it, and you see what the shortage
or extra stock is worth.

## 5. Expenses, activity log, suppliers, reorder → purchase order

* **Expenses:** record rent, electricity, tea, transport with a category, and
  see totals for today / 7 / 30 / 365 days. Delete a wrong entry (recorded).
* **Activity log:** every sensitive action (sale voids, refunds, PIN approvals,
  stock corrections, expense edits, backup runs, role changes) in plain English
  — who, what, which PC, when.
* **Suppliers:** who you owe money to, how much, **Pay** (cash / bank /
  JazzCash / Easypaisa / cheque) and a per-supplier **ledger** feeding from
  deliveries and payments. Payables only count deliveries that were actually
  received — no phantom debts.
* **Reorder → purchase order:** the low-stock list now has **Create purchase
  order**: pick the supplier, edit the suggested quantities, save it as a draft.
  A draft shows on the Purchases tab; when the delivery arrives press
  **Receive**, correct what actually came and confirm — stock, weighted-average
  cost and what you owe all update in one step.

## 6. Never lose the shop

* **Offline catalogue cache:** the till keeps your products, prices and
  customers on the PC, so the app opens and shows the right prices even if the
  internet is down at 7 am. Sales rung while offline are still queued and sent
  automatically when the link returns.
* **Backup button:** Supabase's free plan has **no automatic backups**. The new
  **Settings → Backup → Back up now** writes a dated folder of CSV files
  (products, customers, sales, suppliers, purchases, expenses, stock history)
  that opens in Excel — copy it to Google Drive or a USB stick weekly. The
  screen shows when you last backed up.
* **Loyalty redemption:** customers can now spend their points at the till, not
  just collect them.

---

## 7. The big-supermarket module (round 3)

Everything a chain does that a corner shop does not — and each piece can be
switched off in **Settings → Big-shop rules** if you do not want it.

### Expiry dates on everything you buy and sell
* When you **book in a delivery** every line now takes a **batch number**, a
  **made-on date** and an **expiry date**. There are one-tap shelf-life buttons
  (+1, +2, +3 months, 6 months, 1 year) so the staff do not count on a calendar.
* Add a new product with opening stock and the same three boxes are on the
  product form — the opening stock becomes its own batch, with its expiry.
* The till then follows **first-expire-first-out**: selling takes the stock off
  the oldest-dated batch, so the expiry report never lies about what is left.
* **Expiry & batches** screen shows three figures in plain money: already
  expired, expiring soon (7/15/30/60/90-day filter, warning days set by you),
  and *money at risk*. Each batch can be **written off** with a reason
  (expired / damaged / theft / used as sample / other) — stock and value leave
  the books together, and the reason is recorded against the staff member.
* Switch on **"Refuse to sell stock past its expiry date"** and the till stops
  the sale and tells the cashier to write it off instead (dairy, bakery,
  medicine, baby food). It is off by default so a first-week mistake cannot lock
  a busy counter.

### Bulk / quantity pricing
* Any product can have price breaks — *1–11 at Rs 150, 12 or more at Rs 138* —
  or a simple wholesale price from a quantity. Set it with **Products → Bulk /
  quantity prices**; the till applies it by itself, and the receipt shows it.
* Price breaks never count against the cashier's discount limit — the shop set
  them, the cashier did not.

### Buy X get Y free offers
* **Offers** screen: pick a product *or a whole category*, say "buy 2 get 1
  free", give it start/end dates, switch it on. The till does the maths while
  the cashier scans, the offer never eats into the cashier's own discount
  allowance, and every use is written to the Activity log with the free value,
  so the screen can show *"used 34 times, Rs 12,400 given away"*.

### Gift vouchers and store credit
* **Gift vouchers** screen: issue a voucher (birthday gift, apology for a
  mistake, store credit after a return without a receipt), print a small slip
  with the code, and hand it over. The till takes the code as a **part-payment**
  — it is money the shop already holds, not a discount, so it does not touch the
  discount limits. Balances, expiry dates, cancellation and a "still to be
  spent" total are all on the screen.

### Returns to the supplier
* **Returns to supplier**: damaged cartons, wrong item, or short-dated stock the
  supplier agreed to take back. You pick the products, the quantity and the cost
  you paid, choose whether the money comes back as *reduced payable*, *cash*, or
  *replacement goods*, and the stock and what you owe that supplier both move.
  Each note gets a number (`PRT-…`) and shows its lines.

### Owner reports
* **Owner reports** screen with a date range (7 / 30 / 90 days / 1 year or any
  window) and three tabs:
  * **Profit per product** — what actually makes money after cost and discounts;
    switch between "by profit" and "by quantity".
  * **Cashier scoreboard** — bills, items, average bill, discounts given,
    cancelled bills and refunds per staff member.
  * **Dead stock** — money asleep on the shelf: what has not sold in 30 / 60 /
    90 / 180 days, and its value. Stock that never sold is flagged too.

### Printing that a business customer will accept
* **A4 invoice** from any bill (Invoices → A4 invoice): shop name, address,
  NTN, bill-to, line table, totals, signature line, your note and terms — and
  **no tax line** unless you set a tax rate.
* **Print order** for any draft purchase order, with the supplier's name,
  address and phone.
* **Voucher slip** and a wallet-size **membership card** with a scannable
  barcode (Customers → card icon), so the cashier can scan a customer instead
  of typing a phone number.

### The switches (Settings → Big-shop rules)
Warning days before expiry · refuse expired stock · demand an expiry date on
every delivery line · batch tracking on/off · price tiers on/off · offers
on/off · vouchers on/off · the note and the terms printed on the invoice.
Switching a module off really does stop it at the till — that is tested.

---

## How it was checked

| Check | Result |
|---|---|
| Database test suite (sales, stock, discounts, refunds, roles, RLS) | **110 passed / 0 failed** |
| Shop-floor test suite (PIN at the till, cancels and refunds with a PIN, expenses, payables, stock take, reorder, backup, loyalty, scale) | **67 passed / 0 failed** |
| Big-supermarket test suite (batches & expiry, price tiers, offers, vouchers, supplier returns, owner reports, the on/off switches) | **44 passed / 0 failed** |
| 4-PC oversell race test (two tills selling the last item at once) | **14 passed / 0 failed** |
| One-paste installer on a blank database, run twice in a row | **0 errors**, 30 tables, security rules on everywhere |
| App code analysis | **No issues found** |
| App unit tests | **23 passed** |
| App code compile | clean |
| Barcode label PDFs (the new printing path) | built headlessly in a test: numeric and SKU codes both produce a real PDF; empty codes are guarded because the barcode library silently draws a *blank* sticker |

What has **not** been proven, honestly: none of this has been run on your
Windows PCs, with your printer/scanner, or with a real weighing scale yet —
I have no Windows machine here. The database logic is proven and the label PDFs
are proven to build, but the hardware side is a first-day job for you:

1. **Print one test receipt** (Settings → test print) and one **label sheet**
   (Products → Print labels) on the real printer.
2. **Scan a real shelf label and, if you have one, one scale label** — check the
   weight lands on the bill automatically.
3. **Set a manager PIN and try one over-limit discount** at a cashier login.
4. **Do one Back up now** and open the CSV folder to confirm Excel opens it.

If any of those four misbehave, send me what you see and I will fix it. Also note:
product names with unusual symbols (Urdu script, emoji) can print as boxes on
thermal printers — keep names plain English/numbers for clean receipts.

---

## If you already set up your database and PCs

1. Supabase → SQL Editor → paste **`SUPERMART_SETUP_CLEAN.sql`** (all of it) → **RUN**.
   It adds the new tables and functions; your products, sales and users are not touched.
2. On the PC where you build: **delete the old project folder**, extract this
   project fresh (it replaces the old one completely — it is not an add-on),
   run `flutter pub get`, then `BUILD_EXE.bat` again.
3. Copy the new `DEPLOY\SupermartPOS` folder to the other PCs (overwrite the old one).
4. Sign in as manager → **Settings → Manager PIN → Set my PIN**.
5. **Settings → Weighing scale** if you have a scale printer, then set your
   loose items to **Sold by weight** in Products.
6. Do one **Back up now** so you have a clean copy before the next trading day.
