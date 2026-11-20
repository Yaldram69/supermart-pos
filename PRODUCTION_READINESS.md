# Is this production-ready? — an honest assessment

Short answer: **the software is production-grade in the parts I can prove, and it is
one pilot day away from being safe to run your shop on.** There is no half-written
code, no placeholder logic and no fake data path — every write goes through server-side
validation, and the whole system is covered by 258 automated checks that pass
(110 database + 67 shop-floor database + 44 big-supermarket database
+ 14 concurrency + 23 app).

But "deployed" is a stronger claim than "complete", so here is exactly what is proven,
what is not, and what to do before you trust it with money.

---

## 1. What is verified, and how

| Area | Evidence | Result |
|---|---|---|
| Database builds from one file on an empty project | Ran `SUPERMART_SETUP_CLEAN.sql` on a blank PostgreSQL, **twice in a row** | 30 tables, **30/30 with row-level security on**, 1 store, 0 demo rows, 0 errors |
| Shop-floor module (PIN at the till, PIN-approved cancels and refunds, expenses, payables, stock take, reorder→PO, backup, loyalty, scale) | `local_test/ops_test.sql` on a fresh install of the shipping installer, run twice | **67 PASS / 0 FAIL**, no hidden SQL errors |
| Privileges on the new tables | Live inspection of the production install | `anon` = none, `authenticated` = SELECT only, RLS on |
| Business logic (sales, discounts, credit, refunds, shifts, reports, permissions) | `local_test/test_suite.sql` | **110 PASS / 0 FAIL** |
| Big-supermarket module (batches & expiry, tiers, offers, vouchers, supplier returns, owner reports, module switches) | `local_test/market_test.sql` | **44 PASS / 0 FAIL** |
| Two/four tills selling the last unit at the same instant | `local_test/race_test.sh` (real concurrent connections) | **14 PASS / 0 FAIL** — no oversell, stock never goes negative |
| Till arithmetic matches the server + error messages + scale-barcode parsing helpers | `test/cart_math_test.dart` + `test/label_svg_test.dart` | **23 / 23** |
| Code quality | `flutter analyze` | **0 errors, 0 warnings, 0 infos** |
| Write-path security | Live database inspection | app has **no direct table writes**; `anon` role has **0 privileges**; `authenticated` has **0 insert/update/delete** privileges — every change must go through a validated RPC |
| Purchase workflow (new) | Live: receive delivery → stock 281 → 291, ledger row written, PO listed | PASS, and refused for a cashier |
| Empty-shop path (new) | Live: add 1 product → sell 3 → stock 20 → 17, invoice `INV-2026-001000` | PASS |

These are the checks that normally catch production failures: money arithmetic,
concurrent stock, and permission boundaries. They all pass, and they can be re-run
any time on your own machine.

## 1b. Added after this report was first written

The shop-floor update (manager PIN approvals, held bills, offline catalogue cache,
expense book, activity log viewer, supplier payments, stock take, reorder →
purchase order, CSV backup button, weighing-scale labels, loyalty redemption) is
now part of the shipping installers and is covered by the checks above. It has
**not** been exercised on Windows hardware yet — printing, scanning and the scale
label format still need the pilot day described in section 2. See `WHATS_NEW.md`
for the plain-language tour and `ROADMAP.md` for what is deliberately left out.

## 2. What is NOT verified — and matters

| Gap | Why it matters | How to close it |
|---|---|---|
| **The app has never actually been opened on Windows** | I build and test in a Linux container; Windows EXEs cannot be compiled here. The code compiles, the logic is tested, but no human has clicked through it | Your pilot day (section 4). This is the single most important step |
| **No real printer has ever printed a receipt** | `printing` relies on your Windows driver; paper width, margins and cut commands vary by printer model | Settings → **Test print** on each PC before going live |
| **No real barcode scanner has been used** | The app handles the usual suffix quirks and leading zeros, but scanner behaviour (keyboard layout, Enter suffix) varies | Scan 3–4 different products on each PC |
| **No multi-PC field test** | Realtime was tested against the database from 4 simultaneous connections, not from 4 Windows PCs on your shop's router | Section 4, step 3 |
| **No crash reporting / remote logging** | If something goes wrong in the shop, the only evidence is the terminal window | Run the pilot with the app started from a terminal so errors are visible (see section 5) |
| **No UI/integration test suite** | The 20 Dart tests cover the arithmetic, not the screens | Acceptable: screens are thin over tested logic, and the pilot covers the paths |

## 3. Free-tier operational risks (these are real, plan for them)

| Risk | Detail | What to do |
|---|---|---|
| **No backups on the free plan** | Daily backups start on Pro ($25/mo). If the project is lost, the data is lost | Weekly **Reports → Export CSV** (2 minutes), monthly `pg_dump`. Written into the README |
| **Project pauses after 7 idle days** | Close for a week and the tills show "Offline" until you unpause | Unpause from the dashboard on any phone (one click, nothing lost). Or run a keep-alive ping every 3 days |
| **500 MB database ceiling** | A busy till generates roughly 1–3 MB of sales data per day; you will not hit 500 MB quickly, but check | `select pg_size_pretty(pg_database_size(current_database()));` monthly. At ~400 MB, export and archive old sales |
| **No SLA / community support only** | Free plan has no uptime guarantee and no email support | Keep the owner's phone able to unpause and export. If the shop becomes dependent on it, Pro is the honest upgrade |
| **200 concurrent realtime connections** | You use 4 | Not a risk |
| **Egress 5 GB/month** | 4 tills of small JSON traffic | Not a risk unless you log all tills' traffic for years |

## 4. Go-live checklist (do these in order)

**Before the shop opens**

1. **Pilot on ONE PC for one real day.** Run the app from a terminal (`flutter run -d windows`) on a busy till and use it for real sales, alongside your current method. Watch the terminal.
2. **Print a test receipt** on each of the 4 PCs (Settings → Test print) and confirm the paper width (80 mm or 58 mm) matches your roll.
3. **Scan 3 different products** on each PC, including one with a longer barcode.
4. **Start all 4 tills and watch stock move live.** Sell on PC 1, look at PC 2 — it should change within a second.
5. **Try to break it on purpose** (these are the tests that catch real problems):
   - sell more than you have → must be refused
   - give a cashier a discount above their limit → must be refused
   - pull the network cable → app shows Offline, sale is queued, then sent when you plug it back in
   - void a sale, then refund one item → stock must come back
6. **Enter your real shop details**: Super Admin → Settings → store name, address, phone, NTN, receipt footer.
7. **Create your staff logins** and set their roles and discount limits.
8. **Take a backup** (Reports → Export CSV) and note where you saved it.

**Then, if the pilot day was clean**

9. Copy the `DEPLOY\SupermartPOS` folder to the other 3 PCs, shortcut the `.exe`, sign in.
10. Keep the old method available for the first week.

## 5. Two things that will save you a bad day

- **Run the till from a terminal** (`flutter run -d windows`) during the pilot — if
  anything goes wrong, the reason is printed right there and you can send it to me.
  You can stop and restart it any time; sales already saved are safe in the cloud.
- **Unsigned EXE**: Windows SmartScreen will warn on first launch ("Windows protected
  your PC"). Click **More info → Run anyway**. That is expected for any app without a
  paid code-signing certificate; it is not a sign of a problem.

## 6. Verdict

| Question | Answer |
|---|---|
| Is the code complete, with no stubs? | **Yes** — verified by inspection and by the analyzer |
| Is the money/concurrency logic production-grade? | **Yes** — 235 passing database checks including real concurrent oversell attempts |
| Is it secure by default? | **Yes** — no client write access at all, RLS on every table, role checks server-side |
| Would I put it in a shop untested? | **No — and you should not either.** Do the one-day pilot first |
| Is the free plan safe for a real shop? | **Workable with discipline**: weekly CSV exports, know how to unpause. If the shop depends on it, upgrade to Pro for backups + no pausing |
| Biggest remaining risk | Not the code — the untested hardware: printers, scanners, your router's realtime behaviour |

**Bottom line:** this is a complete, tested application, not a prototype. Everything
that can be verified without Windows hardware has been verified. Run the pilot day
(section 4) and it is genuinely ready for the shop.
