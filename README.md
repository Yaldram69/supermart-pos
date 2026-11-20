# Supermart POS

A Windows desktop point-of-sale and inventory system for a supermarket, built with
Flutter and Supabase (PostgreSQL). It runs on several tills at once, shares live stock
between them, and keeps selling when the internet drops, then syncs automatically.

**Features**

| Area | What it does |
|---|---|
| Billing | Barcode scan or name search, quantity changes, per-line or whole-bill discount, cash / card / credit, change due, receipt printing (58 mm or 80 mm) |
| Invoices | Past bills, reprint, cancel a wrong bill, refund a whole bill or one item |
| Products | Add and edit items, cost and selling price, barcode, category, supplier, reorder level, bulk paste |
| Stock & purchases | Reorder list, full movement history, receive supplier deliveries, purchase returns |
| Customers | Phone-based accounts, credit (udhaar) balances, payments, history |
| Discounts | Promo codes, "spend X get Y off", happy-hour windows; staff are capped at their own discount limit |
| Employees | Cashier, manager and admin roles with individual discount limits |
| Reports | Sales and profit for the day, best sellers, low stock, daily chart, credit owed, CSV export |
| Settings | Till name, printer width, test print, store name and tax number on the receipt, offline queue |

Roles: a **cashier** rings up sales; a **manager** also manages products, stock, reports and
refunds; an **admin** also sets up discounts; the **super admin** manages employees and store
details. Discount limits are enforced on the server, not only in the app.

---

## What you need

- Windows 10 or 11 (64-bit)
- A free [Supabase](https://supabase.com) account
- For building the app yourself: the [Flutter SDK for Windows](https://docs.flutter.dev/get-started/install/windows)
  and Visual Studio with the **Desktop development with C++** workload

## Setup

### 1. Create the database (once, about 5 minutes)

1. Create a Supabase project. Pick the region closest to you. Wait until it has finished starting.
2. Open **SQL Editor → New query**.
3. Open `supabase/SUPERMART_SETUP.sql`, copy everything, paste it into the query box and press **Run**.
   This builds the whole database and loads demo products. It is safe to run again.
4. Create your login: **Authentication → Users → Add user**. Enter your email and a password and tick
   **Auto Confirm User**.
5. Make that account the super admin. In the SQL Editor run this, with your email:

   ```sql
   update public.profiles
      set role = 'super_admin'
    where email = 'you@example.com';
   ```

6. Go to **Settings → API** and copy the **Project URL** and the **anon public** key.

### 2. Add your server details (once)

1. Copy `server_config.example.txt` to `server_config.txt` in the project folder.
2. Paste your two values into `server_config.txt`:

   ```
   SB_URL=https://your-project-ref.supabase.co
   SB_KEY=your-anon-public-key
   ```

`server_config.txt` is git-ignored. Do not commit it, and never put the **service_role** key
anywhere in this project. Only the anon public key belongs here.

### 3. Build the app (once, about 10 minutes)

Double-click `BUILD_EXE.bat` and wait for it to finish. It reads your server details, builds
the app and places the finished program in `DEPLOY\SupermartPOS\`.

If it reports that Flutter is missing, install Flutter as described above, open a new terminal
and run the script again.

### 4. Set up each till

Copy the `DEPLOY\SupermartPOS` folder to each PC (a USB stick is fine), create a desktop shortcut
to `supermart_pos.exe`, and start it. The server details are already built into the app, so
nothing else needs configuring. Sign in with your super admin account.

Each till names itself after the computer. You can change the name under **Settings → This till**.

## Developing

```bash
flutter pub get          # download packages
flutter run -d windows   # run the app from source
flutter test             # app unit and widget tests
```

The database tests live in `supabase/local_test/`. They run against a scratch PostgreSQL
database (not your Supabase project):

```bash
psql -d smtest -f test_suite.sql
psql -d smtest -f ops_test.sql
psql -d smtest -f market_test.sql
```

Project notes (module manifest, requirements map, roadmap) are in the root `*.md` files.

## Project layout

```
lib/           Flutter app (screens, state, services)
supabase/      SQL: tables, functions, row-level security, demo data, local tests
windows/       Windows runner
android/       Android runner
test/          Flutter tests
BUILD_EXE.bat  Builds DEPLOY\SupermartPOS\supermart_pos.exe
```

## Troubleshooting

| Symptom | What to do |
|---|---|
| "Cannot reach the server" | The internet is down. Keep selling: bills are queued and sent when the connection returns. The queue counter in the top bar shows how many are waiting. |
| "Not enough stock" | Correct. Two tills cannot sell the same last unit. Check **Stock & Purchases**. |
| "Not allowed" when saving a discount | Your role cannot do that action. Ask a manager or admin to do it. |
| Receipt does not print | **Settings** → choose 58 mm or 80 mm → **Test print**. Make sure the printer is the Windows default. |
| Two tills show different stock | Wait a second; it is live. If it stays wrong, press the refresh arrow in the top bar. |
| Build script says `server_config.txt` is missing or unreadable | Create it from `server_config.example.txt` and check the `SB_URL=` and `SB_KEY=` lines. |
| Everything shows Offline and the dashboard says "Project paused" | Supabase's free plan pauses projects after a period of inactivity. Open the project in the Supabase dashboard and resume it. |
| Forgot password | Supabase → Authentication → Users → reset it there. |

## Security notes

- Row-level security policies are in `supabase/04_rls_policies.sql` and `supabase/09_security_hardening.sql`.
- Destructive reset scripts are deliberately not included in this repository.
- If a key is ever exposed, rotate it in Supabase → Settings → API, then rebuild the app.
