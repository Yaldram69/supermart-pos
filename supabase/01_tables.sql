-- =====================================================================
--  SUPERMART POS  --  01 : TABLES + INDEXES + CONSTRAINTS
--  Run AFTER 00_extensions_and_enums.sql
--  Safe to re-run (create table if not exists / add column if not exists).
-- =====================================================================

-- =====================  STORE SETTINGS  ==============================
create table if not exists public.stores (
  id                          uuid primary key default gen_random_uuid(),
  is_default                  boolean not null default true,
  name                        text not null default 'Supermart',
  legal_name                  text,
  address                     text,
  phone                       text,
  email                       text,
  ntn                         text,                       -- tax number (Pakistan)
  currency_code               text not null default 'PKR',
  currency_symbol             text not null default 'Rs',
  tax_percent                 numeric(5,2)  not null default 0,   -- 0 = no tax line
  tax_inclusive               boolean       not null default false,
  tax_label                   text          not null default 'GST',
  invoice_prefix              text          not null default 'INV',
  po_prefix                   text          not null default 'PO',
  return_prefix               text          not null default 'RET',
  receipt_header              text,
  receipt_footer              text default 'Thank you for shopping with us!',
  receipt_paper_mm            int           not null default 80,   -- 58 or 80
  print_logo                  boolean       not null default false,
  logo_url                    text,
  max_cashier_discount_percent numeric(5,2) not null default 5,    -- cashier may discount up to this %
  allow_price_override        boolean       not null default false,-- can cashier change the unit price?
  allow_negative_stock        boolean       not null default false,-- block overselling by default
  loyalty_points_per_100      numeric(6,2)  not null default 1,
  created_at                  timestamptz   not null default now(),
  updated_at                  timestamptz   not null default now()
);
create unique index if not exists stores_one_default_idx
  on public.stores ((is_default)) where is_default;

-- =====================  STAFF / USERS  ===============================
-- Mirrors auth.users. A trigger on auth.users creates the row automatically.
create table if not exists public.profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  username              text unique,
  full_name             text not null default '',
  phone                 text,
  email                 text,
  role                  public.user_role not null default 'cashier',
  is_active             boolean not null default true,
  max_discount_percent  numeric(5,2) not null default 5,
  hired_on              date,
  salary                numeric(12,2),
  emergency_contact     text,
  notes                 text,
  last_login_at         timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index if not exists profiles_role_idx on public.profiles(role);

-- =====================  DEVICES (the 4 PCs)  =========================
create table if not exists public.devices (
  id            uuid primary key default gen_random_uuid(),
  name          text unique not null,               -- "Counter-1"
  hostname      text,
  terminal_no   int,
  app_version   text,
  last_seen     timestamptz not null default now(),
  ip_hint       text,
  is_active     boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now()
);

-- =====================  CATALOGUE  ===================================
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text unique not null,
  description text,
  parent_id   uuid references public.categories(id) on delete set null,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.suppliers (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  contact_person  text,
  phone           text,
  email           text,
  address         text,
  city            text,
  ntn             text,
  opening_balance numeric(14,2) not null default 0,
  is_active       boolean not null default true,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists suppliers_name_idx on public.suppliers(lower(name));

create table if not exists public.customers (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  phone          text,
  email          text,
  address        text,
  credit_limit   numeric(14,2) not null default 0,
  balance        numeric(14,2) not null default 0,   -- positive = customer owes us
  loyalty_points int not null default 0,
  is_active      boolean not null default true,
  notes          text,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists customers_phone_uniq on public.customers(phone) where phone is not null;
create index if not exists customers_name_idx on public.customers(lower(name));

create table if not exists public.products (
  id             uuid primary key default gen_random_uuid(),
  sku            text unique,
  barcode        text unique,
  name           text not null,
  brand          text,
  category_id    uuid references public.categories(id) on delete set null,
  supplier_id    uuid references public.suppliers(id) on delete set null,
  unit           text not null default 'pcs',        -- pcs / kg / ltr / pack / dozen
  pack_size      text,
  cost_price     numeric(12,2) not null default 0,
  sale_price     numeric(12,2) not null default 0,
  wholesale_price numeric(12,2),
  tax_percent    numeric(5,2),                       -- null = use store default
  stock_qty      numeric(12,3) not null default 0,
  reorder_level  numeric(12,3) not null default 5,
  is_weighed     boolean not null default false,
  shelf_location text,
  expiry_date    date,
  image_url      text,
  is_active      boolean not null default true,
  is_deleted     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid references public.profiles(id) on delete set null,
  updated_by     uuid references public.profiles(id) on delete set null
);
create index if not exists products_barcode_idx  on public.products(barcode)  where barcode is not null;
create index if not exists products_sku_idx      on public.products(sku)      where sku is not null;
create index if not exists products_name_idx     on public.products(lower(name));
create index if not exists products_category_idx on public.products(category_id);
create index if not exists products_active_idx   on public.products(is_active, is_deleted);

-- Column-level security mirror for the general catalogue.
-- The POS still uses the stock mirror for normal sales flow, but real cost data
-- is read from public.products so staff can see cost / profit details when needed.
create table if not exists public.stock_levels (
  product_id   uuid primary key references public.products(id) on delete cascade,
  barcode      text,
  name         text,
  unit         text,
  sale_price   numeric(12,2) not null default 0,
  tax_percent  numeric(5,2),
  stock_qty    numeric(12,3) not null default 0,
  reorder_level numeric(12,3) not null default 0,
  category_id  uuid references public.categories(id) on delete set null,
  category_name text,
  is_active    boolean not null default true,
  is_deleted   boolean not null default false,
  is_weighed   boolean not null default false,
  expiry_date  date,
  shelf_location text,
  updated_at   timestamptz not null default now()
);
create index if not exists stock_levels_barcode_idx on public.stock_levels(barcode);

-- =====================  INVENTORY LEDGER  ============================
-- Every stock change in the system writes exactly one row here.
-- A trigger keeps products.stock_qty in sync with this ledger.
create table if not exists public.inventory_movements (
  id             bigserial primary key,
  product_id     uuid not null references public.products(id) on delete cascade,
  qty_change     numeric(12,3) not null,             -- negative = stock out
  balance_after  numeric(12,3),
  movement_type  public.movement_type not null,
  reference_type text,                               -- 'sale' | 'purchase_order' | 'return' | 'adjustment'
  reference_id   uuid,
  unit_cost      numeric(12,2),
  note           text,
  device_name    text,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists inv_mov_product_idx on public.inventory_movements(product_id, created_at desc);
create index if not exists inv_mov_ref_idx     on public.inventory_movements(reference_type, reference_id);
create index if not exists inv_mov_created_idx on public.inventory_movements(created_at desc);

-- =====================  SHIFTS (cash sessions)  ======================
create table if not exists public.shifts (
  id                uuid primary key default gen_random_uuid(),
  shift_no          text,
  cashier_id        uuid not null references public.profiles(id) on delete restrict,
  device_name       text,
  status            public.shift_status not null default 'open',
  opened_at         timestamptz not null default now(),
  opening_float     numeric(14,2) not null default 0,
  closed_at         timestamptz,
  closed_by         uuid references public.profiles(id) on delete set null,
  invoice_count     int not null default 0,
  total_sales       numeric(14,2) not null default 0,
  total_cash_sales  numeric(14,2) not null default 0,
  total_card_sales  numeric(14,2) not null default 0,
  total_other_sales numeric(14,2) not null default 0,
  total_credit_sales numeric(14,2) not null default 0,
  total_refunds     numeric(14,2) not null default 0,
  expected_cash     numeric(14,2) not null default 0,
  counted_cash      numeric(14,2),
  difference        numeric(14,2),
  note              text
);
create index if not exists shifts_cashier_idx on public.shifts(cashier_id, opened_at desc);
create index if not exists shifts_open_idx on public.shifts(status) where status = 'open';

-- =====================  SALES  =======================================
create table if not exists public.sales (
  id                     uuid primary key default gen_random_uuid(),
  client_uuid            text unique,                -- idempotency for offline replay
  invoice_no             text unique not null,
  store_id               uuid references public.stores(id) on delete set null,
  cashier_id             uuid not null references public.profiles(id) on delete restrict,
  cashier_name           text,
  shift_id               uuid references public.shifts(id) on delete set null,
  customer_id            uuid references public.customers(id) on delete set null,
  customer_name          text,
  device_name            text,
  item_count             int not null default 0,
  subtotal               numeric(14,2) not null default 0,
  line_discount_total    numeric(14,2) not null default 0,
  invoice_discount_type  public.invoice_discount_type not null default 'none',
  invoice_discount_value numeric(12,2) not null default 0,
  invoice_discount_amount numeric(14,2) not null default 0,
  discount_code          text,
  tax_amount             numeric(14,2) not null default 0,
  total                  numeric(14,2) not null default 0,
  cost_total             numeric(14,2) not null default 0,
  profit                 numeric(14,2) not null default 0,
  paid_amount            numeric(14,2) not null default 0,
  change_amount          numeric(14,2) not null default 0,
  payment_method         public.payment_method not null default 'cash',
  payment_ref            text,
  status                 public.sale_status not null default 'completed',
  refunded_amount        numeric(14,2) not null default 0,
  note                   text,
  offline_created        boolean not null default false,
  created_at             timestamptz not null default now(),
  voided_at              timestamptz,
  voided_by              uuid references public.profiles(id) on delete set null,
  void_reason            text
);
create index if not exists sales_created_idx on public.sales(created_at desc);
create index if not exists sales_cashier_idx on public.sales(cashier_id, created_at desc);
create index if not exists sales_status_idx  on public.sales(status);
create index if not exists sales_customer_idx on public.sales(customer_id);

create table if not exists public.sale_items (
  id                uuid primary key default gen_random_uuid(),
  sale_id           uuid not null references public.sales(id) on delete cascade,
  product_id        uuid references public.products(id) on delete set null,
  name_snapshot     text not null,
  barcode_snapshot  text,
  unit              text not null default 'pcs',
  qty               numeric(12,3) not null check (qty > 0),
  unit_price        numeric(12,2) not null default 0,
  cost_price        numeric(12,2) not null default 0,
  line_discount     numeric(14,2) not null default 0,
  tax_percent       numeric(5,2) not null default 0,
  tax_amount        numeric(14,2) not null default 0,
  line_total        numeric(14,2) not null default 0,
  refunded_qty      numeric(12,3) not null default 0
);
create index if not exists sale_items_sale_idx on public.sale_items(sale_id);
create index if not exists sale_items_product_idx on public.sale_items(product_id);

-- =====================  PURCHASING  ==================================
create table if not exists public.purchase_orders (
  id            uuid primary key default gen_random_uuid(),
  po_no         text unique not null,
  supplier_id   uuid references public.suppliers(id) on delete set null,
  supplier_name text,
  status        public.po_status not null default 'draft',
  order_date    date not null default current_date,
  expected_date date,
  received_at   timestamptz,
  received_by   uuid references public.profiles(id) on delete set null,
  subtotal      numeric(14,2) not null default 0,
  discount      numeric(14,2) not null default 0,
  tax_amount    numeric(14,2) not null default 0,
  total         numeric(14,2) not null default 0,
  paid_amount   numeric(14,2) not null default 0,
  payment_method public.payment_method default 'cash',
  invoice_ref   text,
  note          text,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists po_supplier_idx on public.purchase_orders(supplier_id);
create index if not exists po_date_idx on public.purchase_orders(order_date desc);

create table if not exists public.purchase_items (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references public.purchase_orders(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete restrict,
  name_snapshot text,
  qty_ordered  numeric(12,3) not null default 0,
  qty_received numeric(12,3) not null default 0,
  unit_cost    numeric(12,2) not null default 0,
  line_total   numeric(14,2) not null default 0
);
create index if not exists purchase_items_po_idx on public.purchase_items(purchase_id);

-- =====================  RETURNS / REFUNDS  ===========================
create table if not exists public.returns (
  id             uuid primary key default gen_random_uuid(),
  return_no      text unique not null,
  sale_id        uuid references public.sales(id) on delete set null,
  invoice_no     text,
  customer_id    uuid references public.customers(id) on delete set null,
  reason         text,
  refund_amount  numeric(14,2) not null default 0,
  refund_method  public.payment_method not null default 'cash',
  restocked      boolean not null default true,
  device_name    text,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists returns_sale_idx on public.returns(sale_id);

create table if not exists public.return_items (
  id           uuid primary key default gen_random_uuid(),
  return_id    uuid not null references public.returns(id) on delete cascade,
  sale_item_id uuid references public.sale_items(id) on delete set null,
  product_id   uuid references public.products(id) on delete set null,
  name_snapshot text,
  qty          numeric(12,3) not null check (qty > 0),
  unit_price   numeric(12,2) not null default 0,
  line_total   numeric(14,2) not null default 0
);
create index if not exists return_items_return_idx on public.return_items(return_id);

-- =====================  DISCOUNTS (super-admin rules)  ===============
create table if not exists public.discounts (
  id             uuid primary key default gen_random_uuid(),
  code           text unique,                       -- null = automatic rule
  name           text not null,
  kind           public.discount_kind not null default 'percent',
  value          numeric(12,2) not null default 0,
  scope          public.discount_scope not null default 'all',
  category_id    uuid references public.categories(id) on delete cascade,
  product_id     uuid references public.products(id) on delete cascade,
  min_subtotal   numeric(14,2) not null default 0,
  max_discount   numeric(14,2),                     -- cap on the discount amount
  requires_manager boolean not null default false,  -- cashier may not apply it alone
  applies_automatically boolean not null default false,
  starts_at      timestamptz not null default now(),
  ends_at        timestamptz,
  max_uses       int,
  used_count     int not null default 0,
  is_active      boolean not null default true,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists discounts_code_uniq on public.discounts(upper(code)) where code is not null;

-- =====================  EXPENSES  ====================================
create table if not exists public.expenses (
  id             uuid primary key default gen_random_uuid(),
  category       text not null default 'General',
  description    text,
  amount         numeric(14,2) not null default 0,
  payment_method public.payment_method not null default 'cash',
  spent_at       timestamptz not null default now(),
  shift_id       uuid references public.shifts(id) on delete set null,
  reference_no   text,
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists expenses_date_idx on public.expenses(spent_at desc);

-- =====================  AUDIT LOG  ===================================
create table if not exists public.audit_logs (
  id          bigserial primary key,
  actor_id    uuid,
  actor_name  text,
  actor_role  public.user_role,
  action      text not null,
  entity      text,
  entity_id   text,
  details     jsonb,
  device_name text,
  created_at  timestamptz not null default now()
);
create index if not exists audit_created_idx on public.audit_logs(created_at desc);
create index if not exists audit_entity_idx  on public.audit_logs(entity, entity_id);

-- =====================  KEY/VALUE APP SETTINGS  ======================
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null
);

-- =====================  NUMBER SEQUENCES  ============================
-- Server-side sequences: two PCs selling at the exact same moment can never
-- produce the same invoice number.
create sequence if not exists public.invoice_seq  start 1000;
create sequence if not exists public.po_seq       start 1000;
create sequence if not exists public.return_seq   start 1000;
create sequence if not exists public.shift_seq    start 1000;
