# Upgrade notes

Two passes are described here. Pass 2 is the latest. Pass 1 is kept below for the record.
The original source is in `POSApp\_backup_before_upgrade` (one folder up), so any change can be reverted.

## Pass 4 - product export

The Products screen has an **Export** button. It exports every product, not just the page on screen,
as an Excel workbook (.xlsx) or a CSV file. You choose the format, then where to save it.

Columns, in order: `CATEGORY`, `ITEM_TYPE` (unit: pcs, ltr, kg), `ITEM_NAME` (the subcategory),
`VARIANT_NAME` (the rest of the product name), `PRICE` (sale price), `COST_PRICE`, `STOCK`, `BARCODE`, `SKU`.

- The file has a plain column-name row, then one row per product, oldest product first. No title or styling.
- `CATEGORY` is the **main** category (parent). `ITEM_NAME` is the **subcategory** the product sits in.
  A product filed directly under a main category exports with a blank `ITEM_NAME`.
- `VARIANT_NAME` is the product name with the subcategory name removed from its start, so
  "Bisconni Candi" in subcategory Bisconni exports as `Candi`.
- The CSV starts with a byte-order mark, so Excel shows Urdu and other scripts correctly.
- Text cells cannot run as spreadsheet formulas.
- Covered by `test/product_export_test.dart`.

## Pass 3 - light and dark, accuracy, speed and spacing

**Light and dark mode.** The sun/moon button in the top bar switches between Light, Dark and
Match Windows. The choice is remembered on this PC. Both looks are full designs with their own
surfaces, text and accents. The sidebar and hero panels keep the ink-green gradient in both modes.
Semantic colours (good, warn, danger, info) switch with the look, so they stay readable on dark
surfaces. No screen uses a fixed light-only colour any more, except the always-dark sidebar and
the printed receipt.

**Accuracy.** Till money now follows the database to the paisa. Each line's net and tax are rounded
per line, the invoice discount is rounded before it is taken off, and the total is rounded last,
the same steps the server uses. Covered by tests (`test/regression_fixes_test.dart`).

**Speed.** Product search was about 400 ms per keystroke on 10,000 products in debug mode. Each
product's text is now normalised once and cached, and the query once per search. The same search
now takes roughly 20-90 ms in debug (faster in release). The 20-second background tick redraws the
till only when something visible changed.

**Spacing.** Off-grid spacing values were moved onto a 4-point grid (6, 10, 14, 18 and 22 became
8, 12, 16, 20 and 24). The till's panels use a 16 px gap. The receipt layout is unchanged.
Every screen was rendered again without layout errors.

**Not done.** Settings has no appearance row yet, so the switch lives in the top bar. Printed receipts
stay light by design.

## Pass 2 — security, reliability and the new look

### How it was verified

| Check | Result |
|---|---|
| `flutter analyze` | No issues (was 42 at the start of pass 1, 0 errors/warnings since) |
| `flutter test` | 98 pass, including 9 regression tests, 6 widget tests (PIN pad, command palette) and 3 real Windows DPAPI round-trip tests |
| SQL, on a real PostgreSQL 17.5 server (not a mock) | Core suite 110/110, shop-floor suite 67/67, big-supermarket suite 44/44, security suite 17/17 |
| Two-tills oversell race test | 14/14 |
| Single-file installer (`SUPERMART_SETUP.sql`) | Installs with zero errors, and every suite above passes against it |
| Clean installer (`SUPERMART_SETUP_CLEAN.sql`) | Installs with zero errors |
| Every screen rendered in the real shell | All 16 lay out without errors (with empty data; see "not checked") |
| Windows release build | Builds (`build\windows\x64\runner\Release\supermart_pos.exe`). The app was launched and its first-run screen captured from the real executable |

Build note: the icon font is shipped whole (`flutter build windows --release --no-tree-shake-icons`).
The tree-shaken font dropped some icons the new screens use (for example `link` and `key_outlined`),
which showed as empty tiles. The full font is about 1.6 MB, which is fine for a till.

The earlier baseline showed one core-suite failure that encoded the old "cashiers can't see cost"
rule. That expectation was updated to your decision (below).

### Decisions you gave, and how they were applied

1. **Cashiers see cost prices and margins.** Kept as the policy (RLS allows staff to read products).
   The test that asserted the opposite now asserts the policy.
2. **Refunds and managers.** Read as: a card, JazzCash or credit refund does not need a manager
   *because of its payment method*. The refund goes back the same way it was paid. Manager approval
   for refunds is unchanged: the server still requires a manager role or a checked PIN. Removing that
   would let a cashier refund without oversight. If you meant something else, tell me.
3. **No deployment.** The `DEPLOY` folder was not changed. The new build is at
   `build\windows\x64\runner\Release\supermart_pos.exe`, for you to package.

### Security

- **Manager PIN lockout (server, `supabase/09_security_hardening.sql`).** Five wrong PINs in 15
  minutes lock that cashier out of approvals for 15 minutes. Every attempt is recorded. The till checks
  the PIN with `verify_manager_pin` before it sends any action, so a wrong PIN never reaches a sale.
  *Limit:* someone who has a staff login and scripts calls straight at the sale RPCs skips the counter.
  Those calls are still audited. This is protection against casual guessing at the till, not a hard boundary.
- **PIN entry at the till** is now a touch keypad. Digits show as dots, not numbers. The PIN is
  checked on the server before the dialog returns, and the dialog shows attempts left or the lockout time.
- **Session storage.** The signed-in session (a live access token) is encrypted with Windows' own
  data protection (DPAPI), tied to the Windows account, in the app's support folder. It is not in a
  plain preferences file any more. Implemented with pure-Dart FFI bindings (`win32`), so no native
  build step is needed. The first sign-in after this update asks for the password again.
- **HTTPS only.** A pasted `http://` server address is upgraded to `https://`, except for localhost.
- **PIN rules** match the server: 4 to 8 digits, numbers only.
- **Login errors** show plain text, never raw exception output.
- **Changing the server** on the sign-in screen and the account menu now asks first.

### Money and reporting (pass 1 items, still in force)

- Refunds use the original payment method and have a restock switch (default on).
- The dashboard shows "Not counted" until a drawer count exists, instead of a made-up balance.
- Trend charts sort by date, not by label.
- CSV exports neutralise spreadsheet formulas, and the button says CSV.
- Supplier payments default to the exact balance (was rounded to whole rupees, which could overpay).
- Expenses and tax settings refuse blank or invalid input instead of saving zero.
- Receipts and shelf labels print paisa, not rounded rupees.

### Speed

- Live stock sync sends one changed row at a time, applied in batches of 150 ms. The full catalogue
  reloads every 5 minutes (was every 20 seconds, on every till).
- After a sale only the products sold are re-fetched.
- Product search compiles its regular expressions once. The barcode index does too.
- Reports load their requests together. The customer ledger filters by customer id on the server.
- The invoices table draws 200 rows and adds more as you scroll, instead of building the whole history.

### Look and feel

- **Sidebar:** grouped by Sell, Stock, Insight and Team. The active screen has an emerald glow.
  Collapses to icons on narrow windows.
- **Top bar:** page title, a search trigger, and status pills (Live, shift, pending sync).
- **Command palette (Ctrl+K):** jump to any screen, or run an action: open or cash up a shift,
  refresh stock, sync waiting sales, sign out. Type to filter by name or keyword; Enter runs the top result.
  Arrow-key selection is not included, because the search box takes the arrow keys.
- **Amount due:** the POS total is a hero panel with a large figure that counts to its new value.
- **Page changes** fade and slide.
- **Sign-in and first-run setup** share a branded panel (store mark, three reasons the till is trustworthy)
  beside a calm form. The setup screen now uses the same theme and the same encrypted-session start-up
  as a normal launch. Before this fix, first-run setup would have stored the session in the old plain file.
- **Theme:** the till is light-only (dark mode had hard-coded black text that became unreadable).
  Headings are heavier and tighter; buttons and chips name their font.
- **Dashboard tiles** count up to their figures.

### Layout bugs found by rendering every screen (and fixed)

The old billing screen threw a layout error on load (the totals panel's `Spacer` sat in a column
with unbounded height). That would have crashed the till on its first use. Fixed with `SectionCard(expand: true)`.
Other fixes from the same sweep:

- A header passed as `Expanded` was wrapped in a second `Expanded` (products screen).
- Stat cards placed directly in a row threw. The label no longer needs bounded width.
- The shortcut strip used `RichText`, which does not inherit the app font. Now `Text.rich`.
- Filled buttons and chips rendered in the engine's fallback font. They now name the theme font.
- Stock take showed "no count open" when the check failed, which invites a second count. Now it says
  the check failed and offers a retry.
- Purchase-return and refund fields kept another row's figures after a row was removed. Now keyed.
- Several screens had `TextEditingController`s that were never disposed, or created during `build()`.

### Database: run this once on an existing project

**Use `supabase/SUPERMART_SETUP_CLEAN.sql` as the one file for the database.** It holds the whole
schema including files 08 and 09, has no demo data, and ends with the owner step: create the login in
Authentication -> Users, replace `owner@your-shop.example` in the last `UPDATE`, and run it. The file
installs with zero errors on an empty PostgreSQL 17 database. Its PIN helpers are locked to signed-in staff.

For an existing project, run `supabase/08_performance_indexes.sql` and then
`supabase/09_security_hardening.sql` in the Supabase SQL editor. Both are safe to re-run.
Without 08 the search is slower on large catalogues. Without 09 there is no PIN lockout.

### Decisions I made for you (change any of these)

1. The PIN lockout counts per cashier login, not per till, so one person can't lock the whole shop.
2. The 5-in-15-minutes limit and 15-minute lockout are fixed. They are in `09_security_hardening.sql`
   (`fx_pin_max_failures`, `fx_pin_window`).
3. Reorder items are always high priority, which the existing reporting test already requires.
4. Realtime sends single rows; the 5-minute full reconcile is the safety net for a dropped connection.

### Not done yet, and why

- **Visual check on a real Windows screen.** I rendered every screen with empty data and checked the
  shell and the new widgets as images. Real data (long names, many rows, Urdu text, tiny or large
  windows) has not been looked at. Please walk through the till once before it goes live.
- **Customer PDF and the whole-shop backup run on the main thread.** Long lists can briefly freeze the till.
- **The settings backup CSV is unencrypted** (it contains customers and sales). Encrypting it needs a
  password decision from you.
- **Activity log** is still a single list up to 5000 rows (it could be paged the same way as invoices).
- **A few screens still show "Rs" directly** rather than the store's currency symbol.
- **Duplicate installer files.** `SUPERMART_SETUP.sql` and `SUPERMART_SETUP_CLEAN.sql` both exist and both
  now include 08 and 09. Keep both in step, or pick one as the source of truth.
- **Clutter in the project root** (`output.txt`, `test_out.txt`, `flutter_01.log`, `DEPLOY/*.rar`) was left alone, since it may be your data.

---

## Pass 1 — correctness, speed and reliability (summary)

- Refund method, cash variance, trend order, CSV injection, Excel label, clamp crash, print twice,
  cash-short completion, Esc and Enter in the till, quantity stepper, pager counts, stock-take scale
  labels, purchase-return reasons and batches, stock-screen load failures, price-break confirmation.
- Realtime per-row sync, search regex hoisting, parameterised product search filter, PostgREST quoting,
  invoices and ledger filtering on the server.
- Settings: PIN rules, HTTPS-only setup, receipt rounding and column fit, toast clearing.
- The 42 analyzer issues were cleared.
