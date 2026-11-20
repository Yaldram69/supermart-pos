# START HERE — from the ZIP file to a working shop

Follow this in order. Nothing here needs programming knowledge — every step is
click, paste, or type one line. Total time: **about 1 hour** the first time
(most of it is downloads).

There are 3 things to do:

- **Part 1** — make the database (in the cloud, free) ~10 minutes
- **Part 2 / 3** — create your login and get 2 keys ~5 minutes
- **Part 5** — run the app on your PC ~15 minutes
- **Part 6** — make the .exe and copy it to the 4 shop PCs ~10 minutes

---

# PART 0 — One-time tools check

You already have Android Studio and Visual Studio, so this should be quick.

### 0.1 Check Flutter

1. Press the **Windows key**, type `cmd`, press **Enter**. A black window opens
   (the "Command Prompt" — you'll use it again later).
2. Type this and press Enter:

   ```
   flutter doctor
   ```

**If you see `'flutter' is not recognized as an internal or external command`:**
Flutter is not installed yet (or not on your PATH):

1. Download the Flutter SDK for Windows: <https://docs.flutter.dev/get-started/install/windows>
2. Unzip it to **`C:\flutter`** (not inside `C:\Program Files`, not on OneDrive).
3. Press **Windows key** → type `environment variables` → click
   **"Edit the system environment variables"** → button **Environment Variables...**
4. In the top box ("User variables") click the row **Path** → **Edit...** →
   **New** → type `C:\flutter\bin` → **OK** → **OK** → **OK**.
5. Close the black window, open a **new** `cmd` window (important), type
   `flutter doctor` again.

**Good output looks like this** (Chrome/Android lines may differ — ignore them):

```
[✓] Flutter (Channel stable, 3.4x.x, on Microsoft Windows ...)
[✓] Windows Version (Windows 11 ...)
[✓] Visual Studio - develop Windows apps (Visual Studio Community 2022 ...)
```

**If `Visual Studio` shows a red ✗ or complains about a C++ workload:**

1. Open **Visual Studio Installer** from the Start menu → **Modify**.
2. Tick the workload **"Desktop development with C++"** (it is sometimes shown
   as *Desktop & Mobile → Desktop development with C++*).
3. Click **Modify/Install** and wait. Then run `flutter doctor` again.

You do **not** need the Android parts for this — ignore any ✗ about Android
toolchain, Android licenses or Xcode.

---

# PART 1 — Create the free database (Supabase)

Your 4 PCs do not talk to each other directly. They all talk to one free
database in the cloud — that is what makes stock live on all 4 tills.

### 1.1 Make an account and a project

1. Go to **<https://supabase.com>** and click **Start your project**.
   Sign in with Google or GitHub (or an email + password).
2. In the dashboard click **New project**.
3. Fill in:
   - **Organization** — if it asks, create one, name it anything (e.g. `SuperMart`).
   - **Name** — `supermart-pos`
   - **Database Password** — click **Generate a password**, then **copy it into a
     note and keep it**. (You will probably never need it, but don't lose it.)
   - **Region** — choose **Singapore** (fastest for Pakistan).
   - **Plan** — **Free**.
4. Click **Create new project** and wait ~2 minutes while it says *"Setting up project"*.

### 1.2 Put all the tables in (one file, one click)

1. In the left menu click **SQL Editor**.
2. Click **+ New query**.
3. Open the ZIP you downloaded and find **`supabase\SUPERMART_SETUP.sql`**.
   Right-click it → **Open with** → **Notepad**.
   ⚠️ Use Notepad, **not** Microsoft Word.
4. In Notepad press **Ctrl+A** (select all), then **Ctrl+C** (copy).
5. Click inside the big empty box on the Supabase page, press **Ctrl+V**.
6. Click the green **Run** button (or press Ctrl+Enter). Wait 5–20 seconds.
7. You should see **"Success. No rows returned"**. Yellow `NOTICE` lines are
   normal and harmless. (If you see red `ERROR` text instead, stop and send me
   that text.)

### 1.3 Check it worked (10 seconds)

1. In the left menu click **Table Editor**.
2. On the left you will see a list of tables: `products`, `sales`,
   `stock_levels`, `categories`…
3. Click **products** and check the row count:
   - **Real shop (`SUPERMART_SETUP_CLEAN.sql`)** → **0 rows** is correct, the shop is empty.
     Click **categories** instead: you should see **12 rows**. That proves the setup ran.
   - **Practice (`SUPERMART_SETUP.sql`)** → **61 rows** of sample items (Sunridge Atta,
     Lays, Coca-Cola…) that you can start selling immediately.

If the count you expected is missing, the file did not run — go back to 1.2 and try again.

> Whichever file you used, that one paste built the whole database: 30 tables, the
> stock ledger, the selling logic and the security rules. `SUPERMART_SETUP_CLEAN.sql`
> just leaves the catalogue empty for your own products.

---

# PART 2 — Create your own login and make yourself the boss

The app needs a real login user (this is the account you will sign in with every
day).

### 2.1 Create the user

1. Left menu → **Authentication** → **Users**.
2. Click **Add user** → **Create new user**.
3. **Email** — your email address (e.g. `you@example.com`). It does not have to
   be a real mailbox, but write it down exactly.
4. **Password** — something you'll remember, at least 8 characters.
5. ✅ Tick **Auto Confirm User** — **this is important**, otherwise you cannot
   sign in.
6. Click **Create user**.

### 2.2 Give yourself the owner (Super Admin) role

1. Left menu → **SQL Editor** → **+ New query**.
2. Paste this, replacing the email with the one you just used, then click **Run**:

   ```sql
   update public.profiles
      set role = 'super_admin'
    where email = 'you@example.com';
   ```

3. It must say **"Success. 1 row affected"**.
   - If it says **0 rows affected**, the email does not match any user — check
     it letter by letter against the Users page, fix it and run again.

### 2.3 (Recommended) Stop requiring email confirmation for staff

So new cashier logins work immediately:

1. Left menu → **Authentication** → **Sign In / Providers** (on some accounts:
   *Providers* → *Email*).
2. Switch **Confirm email** to **OFF**, click **Save**.

---

# PART 3 — Copy your 2 keys

The app needs two short pieces of text to know which database is yours.

1. Left menu → **Project Settings** (the gear ⚙ at the bottom) → **API**
   (sometimes called **API Keys**).
2. Copy these two values into a Notepad window:
   - **Project URL** — looks like `https://abcdefghijklm.supabase.co`
   - **Publishable key** — starts with `sb_publishable_...`
     *(If you don't see a Publishable key, open the **Legacy API keys** tab and
     copy the **anon public** key instead — it starts with `eyJ...`. Either one
     works.)*
3. ⚠️ **Never** copy the **service_role** key or a **secret** key into the app.

Keep this Notepad open — you need these in Part 5.

---

# PART 4 — Unzip the project (this is the whole project)

> **One project only.** This single ZIP contains every module — Billing,
> Invoices, Products, Stock & Purchases, Stock take, Suppliers, Expenses,
> Customers, Reports, Discounts, Activity log, Employees, Settings. It is not an
> add-on to an older download. If you still have an earlier ZIP or an old
> extracted folder, **delete it** and use this one, or you will build an app
> that is missing screens. `PROJECT_MANIFEST.md` lists every module if you want
> to check.

1. Right-click the downloaded file **`SupermartPOS-FULL-PROJECT.zip`** →
   **Extract All...**
2. Extract it to **`C:\dev`** so you end up with the folder
   **`C:\dev\SupermartPOS`**.
   - Keep it out of OneDrive and avoid long paths — it makes the build faster
     and avoids weird errors.

---

# PART 5 — Run the app on your PC (first test)

### 5.1 Open a command window inside the folder

1. Open File Explorer and go into **`C:\dev\SupermartPOS`**.
2. Click once in the **address bar** at the top, type `cmd`, press **Enter**.
   A black window opens already pointing at your project folder.

### 5.2 Download and build (first time: 5–15 minutes, be patient)

Type each line, press Enter, and wait for it to finish before the next:

```
flutter pub get
```

```
flutter run -d windows
```

- `flutter pub get` downloads the libraries. You should see
  **"Got dependencies!"**
- `flutter run -d windows` builds and opens the app. The **first** build is slow
  (5–15 min) and prints a lot of text — that's normal. Later runs take seconds.

> Prefer clicking instead of typing? Open **Android Studio** → **File → Open** →
> choose `C:\dev\SupermartPOS` → wait for it to finish indexing → at the top,
> pick the device **`windows (desktop)`** → press the green **▶ Run** button.

### 5.3 The setup screen (only on the very first run)

The app opens with a card titled **"Set up this till"**:

- **Server URL** — paste your **Project URL**
- **Anon key** — paste your **Publishable key** (or the legacy anon key)
- **Till name** — e.g. `Counter-1`
- **Terminal number** — `1`

Click **Save & continue**.

### 5.4 Sign in

- Email + password = the login you made in **Part 2**.
- You land on the **Billing** screen. Done — you are running your shop system.

### 5.5 Try a sale (2 minutes, uses demo data)

1. In the search box type `lays` and press Enter → the item appears in the cart.
2. Press **F12** (or click **Charge**).
3. Choose **Cash** → click **Exact** → **Charge**.
4. A print window appears — you can pick a printer now, or just close it.
5. The sale is saved and the cart is empty. Open the **Invoices** menu on the
   left — your bill is there, with a number like `INV-000001`.

That was a real sale, stored in the cloud. **If you run these same steps on a
second PC with this same ZIP, you will see the stock go down on both** — that is
the live 4-till sharing.

---

# PART 6 — Make the .exe for the 4 shop PCs

`flutter run` is for testing. For the shop you want a normal program you
double-click.

### 6.1 Put your keys in the project once

1. In `C:\dev\SupermartPOS` open **`server_config.txt`** with Notepad.
2. Replace the two lines (no quotes, no spaces around the `=`), save and close:

   ```
   SB_URL=https://abcdefghijklm.supabase.co
   SB_KEY=sb_publishable_xxxxxxxxxxxx
   ```

### 6.2 Build it

1. Double-click **`BUILD_EXE.bat`** in the same folder.
2. Leave the window open until it says **DONE**. (First time: ~10 minutes.)
3. The finished app appears in **`C:\dev\SupermartPOS\DEPLOY\SupermartPOS`**.
   That folder contains `supermart_pos.exe` plus the files it needs.

### 6.3 Put it on each of the 4 PCs

1. Copy the whole **`DEPLOY\SupermartPOS`** folder to the PC (USB stick, or just
   copy the folder into `C:\SupermartPOS`).
2. Right-click **`supermart_pos.exe`** → **Send to** → **Desktop (create
   shortcut)**.
3. Double-click the shortcut and sign in. **No setup screen, no keys to type** —
   they are already inside the app.

Each PC names its own till after the computer (e.g. `COUNTER-PC2`). Put it right
any time: **Settings → This till** → change the name, press Save.

> When you change something in the code later and rebuild, just replace the
> whole `SupermartPOS` folder on the 4 PCs with the new one. Your data is in the
> cloud, so nothing is lost.

---

# PART 7 — Put your real shop in

### 7.1 Your products

Menu **Products** → **Add product**:

| Field | What to type |
|---|---|
| Barcode | scan the item's barcode, or type your own number |
| Name | e.g. `Tapal Danedar Tea 430g` |
| Category | create your own categories first, or pick one |
| Unit | `pcs`, `kg`, `bag`, `litre` |
| Cost price | what you pay the supplier (cashiers cannot see this) |
| Sale price | what the customer pays |
| Reorder level | warn me when stock drops below this |
| Opening stock | how many are on the shelf right now |

In a hurry with a big list? Use **Products → Bulk import** and paste many items
at once.

**To remove the 61 demo items** (do this *before* you start adding your own, or
just delete them one by one from the Products screen): paste this in Supabase →
SQL Editor → Run.

```sql
-- archives the demo products (safe: old bills keep their history)
update public.products p
   set is_deleted = true, is_active = false
 where p.supplier_id in (select id from public.suppliers
                          where name in ('Al-Karam Traders',
                                         'Nestle Distributor',
                                         'Unilever Distributor'));
```

### 7.2 Your staff

1. **Supabase → Authentication → Users → Add user → Create new user** — their
   email and a password, ✅ **Auto Confirm User**. (One login per person.)
2. In the app: **Employees** → their name appears in the list → set **Role**,
   **Max discount %**, **Salary**, and **Save**.
   - **Cashier** — sells only, and cannot discount more than their % limit.
   - **Manager** — products, stock, reports, refunds.
   - **Admin** — everything except staff and store settings.
3. They sign in on any till with that email and password.

### 7.3 Your shop details on the receipt

Menu **Settings** (Super Admin only):

- Store name, address, phone, NTN — printed on every receipt
- Receipt footer text (e.g. *"No exchange without receipt"*)
- Paper width: **80 mm** (normal thermal) or **58 mm** (small) → then click
  **Test print** to confirm your printer works

> Receipts have **no tax line** — just items, discount, total in Rs, exactly as
> you asked.

---

# PART 8 — The extra tools (set these up once)

These are the shop-floor tools added in this version. Everything here is
optional, but each one saves you real time at the counter.

## 8.1 Manager PIN — approve a discount without leaving the bill

A cashier has a discount limit (5% by default). When a customer haggles for
more, the cashier no longer has to sign out and lose the bill — a manager
types a short PIN and the sale continues.

1. Sign in as the manager (or owner), open **Settings**.
2. In **Manager PIN (approve at the till)**, press **Set my PIN** and type
   4–8 digits twice. Remember it — nobody, including me, can read it back.
3. At the till: the cashier rings the bill, tries the discount, and a
   **Manager approval** box appears. The manager types the PIN, presses
   **Approve**, done.

Every single approval is written into the **Activity log** with the manager's
name, so you always know who allowed what.

## 8.2 Hold a bill, serve the next customer (F8 / F9)

Someone runs back to the shelf for one more item? Don't keep the queue waiting.

* **F8** — park the whole bill (you can type a name or note).
* **F9** — pick it up again from the list, or throw it away.

Held bills are stored on that one PC only. The bill itself is not sent to the
server until you charge it, so nothing is half-sold.

## 8.3 Weighing scale + labels (for atta, sugar, fruit)

If your scale prints its own barcode label, the till can read the weight out of
it — no typing.

1. **Settings → Weighing scale & loyalty**: type the digits your scale prints
   first (the "prefix", e.g. `22`) and choose whether the label carries the
   **weight** or the **price**. Press **Save**.
2. **Products → Edit** a loose item and switch on **Sold by weight (loose item)**.
   Now the till asks for the weight instead of counting pieces.
3. Scanning a scale label then bills the exact weight automatically.
4. No scale? Use **Products → Print labels** to print barcode stickers for
   anything that has no barcode of its own (print on sticker sheets).

## 8.4 Stock take — check the shelves against the books

**Stock take** in the menu:

1. Press **Start a count** (selling can continue the whole time).
2. Scan or type each item and type how many are really on the shelf.
   For loose items just scan the scale label — the weight comes with it.
3. Press **Finish & correct stock**. Only then does anything change: every
   difference is written into the stock history with your name on it, and the
   value of the shortage/extra is shown.

## 8.5 Expense book, suppliers you owe, reorder

* **Expenses** — record shop running costs (rent, electricity, tea, transport)
  with a category, then see the total per day/week/month.
* **Suppliers** — see who you owe money to (from deliveries booked in without
  full payment), press **Pay** to record a payment, and open **Ledger** for the
  whole history with that supplier.
* **Stock & Purchases → Reorder** — the low-stock list with a suggested order.
  Press **Create purchase order**, pick the supplier, adjust the quantities and
  save it as a draft. When the truck arrives, open it under **Purchases**,
  press **Receive**, correct what actually came and confirm — stock, cost price
  and what you owe all update together.

## 8.6 Backups — do this every week

Supabase's free plan does **not** take automatic backups for you, so:

**Settings → Backup → Back up now.** It writes a dated folder of CSV files
(products, customers, sales, stock history, purchases, expenses…) into
`C:\Users\<you>\SupermartPOS Backups`. Copy that folder to Google Drive or a
USB stick once a week. The Settings screen always shows when you last did it.

## 8.7 Expiry dates — where they go and what they do

This is the part most shops get wrong, so it is built into the normal flow in
three places:

1. **When a delivery arrives** (Stock & Purchases → Book in a delivery): every
   line has a **Batch no.**, a **Made on** date and an **Expiry date** box. Type
   the date, or use the ⚡ button beside it to fill "+1 month, +3 months,
   +6 months, +1 year". Leave them empty for things that do not expire (soap,
   detergent) — nothing is forced on you.
2. **When you add a brand-new product** (Products → Add product) that already
   has stock on the shelf: fill the same three boxes next to *Opening stock* and
   the first batch is created for you, with its expiry date.
3. **When the stock leaves**: the till takes it off the oldest-dated batch by
   itself (first expire, first out), so the expiry screen always tells the truth.

Then check **Expiry & batches** in the menu. You get:
* **Already expired** — how many batches and what they are worth (throw them out).
* **Expiring soon** — everything going off in the next 7 / 15 / 30 / 60 / 90
  days (change the warning from Settings).
* **Money at risk** — the total value of stock you are about to lose.
* **Write off** on each line: choose *expired / damaged / theft / used as sample
  / other*, and the stock and its value leave the books together, recorded in
  the Activity log with the staff member's name.

If you want the till to **refuse** to sell anything past its date (dairy,
bakery, medicine, baby food), switch on **Settings → Big-shop rules → Refuse to
sell stock that is past its expiry date**. The cashier then gets a clear
message telling them to write the stock off instead.

## 8.8 The other shop-wide tools (all optional)

| Screen | What it does |
|---|---|
| **Offers** | Buy 2 get 1 free on a product or a whole category, with dates. The till applies it; staff cannot forget it. |
| **Gift vouchers** | Issue a voucher or store credit, print the slip, take the code at the till as a part-payment. |
| **Returns to supplier** | Damaged or short-dated goods going back — stock and what you owe the supplier both move. |
| **Owner reports** | Profit per product, a cashier scoreboard, and the money asleep on your shelves (dead stock). |
| **Settings → Big-shop rules** | Warning days before expiry, the expired-stock guard, whether a delivery must carry an expiry date, and on/off switches for batch tracking, price tiers, offers and vouchers. |

Printing beyond the receipt: **A4 invoice** (Invoices → open a bill → A4
invoice), **Print order** for a supplier (Stock & Purchases → Purchases →
Print order), a **voucher slip**, and a wallet-size **membership card**
(Customers → the badge icon).

---

# PART 9 — The daily routine

| When | What you do |
|---|---|
| Morning | Open the app. (Optional: click the shift pill in the top bar → **Open shift** → enter the cash you start with. The system also opens one automatically on the first sale.) |
| All day | Scan → **F12** → choose Cash / Card / Credit(udhaar) → Charge → receipt prints |
| Cash up at night | Top bar → shift pill → **Cash up** → it shows cash taken, card, credit, expected in drawer |
| Any time | **Reports** for the day's sales/profit, **Stock & Purchases → Reorder** for what to buy, **Customers** to collect udhaar |

**If the internet goes down:** keep selling. The top bar shows **Offline** and a
counter of bills waiting; they are sent automatically when the internet comes
back. Nothing is lost.

---

# PART 10 — If something goes wrong

| What you see | What it means / what to do |
|---|---|
| `'flutter' is not recognized...` | Flutter is not on your PATH. Redo Part 0.1 and open a **new** cmd window. |
| Error mentioning **CMake** or **Visual Studio** while building | Visual Studio is missing the **Desktop development with C++** workload (Part 0.1). |
| Supabase red error: `relation "public.profiles" does not exist` | The SQL file did not run. Re-do Part 1.2. |
| `0 rows affected` in Part 2.2 | The email in your UPDATE does not match the user. Copy it exactly from **Authentication → Users**. |
| Login says **Email not confirmed** | Recreate that user and tick **Auto Confirm User**, or turn off **Confirm email** (Part 2.3) and try again. |
| Login says **Invalid login credentials** | Wrong password. Supabase → **Authentication → Users** → click the user → **Reset password** / send recovery, or create a new user. |
| Login says **no profile** / **Account disabled** | The user was created before the SQL ran, or is switched off. Create the user again (after Part 1), or turn them back on in **Employees**. |
| App says **Offline** but the internet works | Check the URL/key in **Settings → Server info** — one wrong character breaks it. Re-run Part 6.1 and rebuild, or fix it on the Setup screen. |
| The window looks frozen and the terminal repeats **"Cannot hit test a render box that has never been laid out"** | You clicked the window before it had drawn its first frame (usually while the server URL was still wrong, so startup was slow). Nothing is damaged: press **q** in the terminal, then `flutter run -d windows` again and wait for the sign-in screen to appear before clicking. Fixed in this version of the code — the window now stays hidden until it has painted, and every server call has a 25-second timeout instead of hanging. |
| Everything says **Offline** and the dashboard shows "Project paused" | The free plan pauses a project after 7 days with no sales (e.g. after a holiday). Open supabase.com on any phone → your project → **Restore project**. Nothing is lost; the tills reconnect in about a minute. |
| Build seems stuck for 10+ minutes | The first build really is that slow. Leave it; don't close the window. |
| A cashier's sale is refused: *discount limit* | Correct — their % limit is lower than the discount. A manager signs in, or raise the limit in **Employees**. |
| Receipt doesn't print | Windows **Settings → Bluetooth & devices → Printers** → set your thermal printer as **default**. Then in the app: **Settings → Test print**. |
| Two tills briefly show different stock | Wait one second (it's live) or press the ↻ refresh icon in the top bar. |

---

# PART 11 — Quick reference

**Folder map**

```
C:\dev\SupermartPOS\
   START_HERE.md          <- this guide
   README.md              <- the same steps, more technical
   PROJECT_FILES.md       <- what every file in the project does
   server_config.txt      <- paste your 2 Supabase values here (Part 6.1)
   BUILD_EXE.bat          <- double-click to make the .exe
   lib\                   <- the app code (screens, printing, logic)
   test\                  <- automatic tests (you can ignore these)
   supabase\              <- the database files
      SUPERMART_SETUP.sql              <- the ONE file you paste into Supabase
      SUPERMART_SETUP_CLEAN.sql        <- the same thing for your REAL shop (no demo goods)
      local_test\                      <- the automatic database tests (you can ignore these)
   DEPLOY\SupermartPOS\   <- appears after building: copy this to each PC
```

**Useful commands** (type in a cmd window opened in `C:\dev\SupermartPOS`)

```
flutter pub get                 # download libraries (after any ZIP update)
flutter run -d windows          # run for testing
flutter build windows --release # build the .exe directly
flutter test                    # run the automatic tests (19 app checks)
```

**Keyboard shortcuts in the billing screen**

| Key | Does |
|---|---|
| **F2** | jump the cursor back to the barcode box |
| **F4** | attach a customer (needed for udhaar / credit sales) |
| **F6** | whole-bill discount |
| **F8** | hold (park) the current bill |
| **F9** | bring back a held bill |
| **F12** | charge / payment screen |
| **Esc** | close a dialog |

**Where the new screens are** (left-hand menu)

| Menu item | Who sees it | What it does |
|---|---|---|
| Stock take | manager and up | count the shelves, correct the stock |
| Suppliers | manager and up | who you owe, pay them, ledger |
| Expenses | manager and up | rent, bills, tea, transport |
| Activity log | admin and up | every sensitive action, in plain English |

**If you get stuck:** copy the exact red error text (from the black window or
from Supabase) and send it to me — I'll tell you the one thing to fix.
