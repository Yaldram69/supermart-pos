-- #####################################################################
--  SUPERMART POS  --  PRODUCTION DATABASE SETUP  (empty shop, no demo data)
--
--  USE THIS ONE FOR YOUR REAL SHOP.  It creates every table, the stock
--  ledger, the selling logic and the security rules - and starts with an
--  EMPTY catalogue, so nothing fake ever gets mixed into your real sales.
--  (For practice/demo data, use SUPERMART_SETUP.sql instead.)
--
--  HOW TO USE (about 3 minutes):
--    1. supabase.com -> your project -> SQL Editor -> New query
--    2. paste this ENTIRE file
--    3. press RUN   (wait for "Success. No rows returned")
--    4. create your owner login:  Authentication -> Users -> Add user
--       (tick "Auto Confirm User"), then run the one UPDATE statement
--       printed at the very bottom of this file.
--
--  It is safe to run twice.
--  #####################################################################

-- =====================================================================
--  SECTION: 00_extensions_and_enums.sql
-- =====================================================================
-- =====================================================================
--  SUPERMART POS  --  00 : EXTENSIONS + ENUM TYPES
--  Run this FIRST in the Supabase SQL Editor.
--  Safe to re-run.
-- =====================================================================

create extension if not exists pgcrypto;      -- gen_random_uuid()
create extension if not exists "uuid-ossp";   -- uuid_generate_v4() (legacy safety)

-- ---------------------------------------------------------------------
-- ENUMS (wrapped so the file can be re-run without errors)
-- ---------------------------------------------------------------------
do $$ begin
  create type public.user_role as enum ('cashier','manager','admin','super_admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_method as enum
    ('cash','card','jazzcash','easypaisa','bank_transfer','credit');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.sale_status as enum
    ('completed','void','partially_refunded','refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.movement_type as enum
    ('opening','purchase','sale','sale_void','refund','adjustment','damage','transfer_in','transfer_out','return_supplier');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.discount_scope as enum ('all','category','product');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.discount_kind as enum ('percent','amount');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.po_status as enum ('draft','ordered','received','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.shift_status as enum ('open','closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.invoice_discount_type as enum ('none','percent','amount','code');
exception when duplicate_object then null; end $$;

-- =====================================================================
--  SECTION: 01_tables.sql
-- =====================================================================
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

-- =====================================================================
--  SECTION: 02_functions_triggers_views.sql
-- =====================================================================
-- =====================================================================
--  SUPERMART POS  --  02 : HELPERS, TRIGGERS, VIEWS
--  Run AFTER 01_tables.sql
-- =====================================================================
set check_function_bodies = off;

-- ---------------------------------------------------------------------
--  ROLE HELPERS  (SECURITY DEFINER so RLS policies can ask "who is this?"
--  without recursing back into the profiles RLS policy.)
-- ---------------------------------------------------------------------
create or replace function public.fx_role()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select p.role::text from public.profiles p
                    where p.id = auth.uid() and p.is_active), 'none');
$$;

create or replace function public.fx_is_staff()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.fx_role() <> 'none';
$$;

create or replace function public.fx_is_manager()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.fx_role() in ('manager','admin','super_admin');
$$;

create or replace function public.fx_is_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.fx_role() in ('admin','super_admin');
$$;

create or replace function public.fx_is_super_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.fx_role() = 'super_admin';
$$;

-- Raise a friendly, machine-readable error the Flutter app can parse.
create or replace function public.fx_fail(p_code text, p_message text)
returns void language plpgsql as $$
begin
  raise exception '%|%', p_code, p_message using errcode = 'P0001';
end $$;

create or replace function public.fx_require_role(p_roles text[])
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role text := public.fx_role();
begin
  if v_role = 'none' then
    perform public.fx_fail('NOT_AUTHENTICATED', 'Your session has expired. Please sign in again.');
  end if;
  if not (v_role = any(p_roles)) then
    perform public.fx_fail('NOT_ALLOWED',
      'Your role (' || initcap(replace(v_role,'_',' ')) || ') is not allowed to do this. Ask a manager.');
  end if;
end $$;

create or replace function public.fx_allow_negative_stock()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select s.allow_negative_stock
       from public.stores s
      where s.is_default = true
      order by s.created_at desc
      limit 1),
    false
  );
$$;

create or replace function public.fx_store()
returns public.stores language sql stable security definer set search_path = public, pg_temp as $$
  select *
    from public.stores
   where is_default = true
   order by created_at desc
   limit 1;
$$;

create or replace function public.fx_actor_name()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select p.full_name from public.profiles p where p.id = auth.uid()), 'system');
$$;

-- ---------------------------------------------------------------------
--  AUDIT  -- every mutation in this system goes through an RPC, and every
--  RPC calls this, so the audit trail is complete by construction.
-- ---------------------------------------------------------------------
create or replace function public.fx_audit(
  p_action text, p_entity text default null, p_entity_id text default null,
  p_details jsonb default '{}'::jsonb, p_device text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.audit_logs(actor_id, actor_name, actor_role)
  select auth.uid(), null, null where false; -- no-op keeps planner happy
  insert into public.audit_logs(actor_id, actor_name, actor_role, action, entity, entity_id, details, device_name)
  values (auth.uid(), public.fx_actor_name(), nullif(public.fx_role(),'none')::public.user_role,
          p_action, p_entity, p_entity_id, coalesce(p_details,'{}'::jsonb), p_device);
end $$;

create or replace function public.fx_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
--  STOCK LEDGER TRIGGER
--  products.stock_qty is updated ONLY through inventory_movements.
--  Two PCs selling the same last item can never oversell: the row is
--  locked FOR UPDATE, re-checked, and the loser of the race gets a clean
--  INSUFFICIENT_STOCK error instead of corrupt stock.
-- ---------------------------------------------------------------------
create or replace function public.fx_apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_stock     numeric(12,3);
  v_new       numeric(12,3);
  v_name      text;
  v_unit      text;
begin
  if coalesce(new.qty_change, 0) = 0 then
    return new;
  end if;

  select stock_qty, name, unit into v_stock, v_name, v_unit
    from public.products where id = new.product_id for update;

  if not found then
    perform public.fx_fail('PRODUCT_NOT_FOUND', 'That product no longer exists.');
  end if;

  v_new := v_stock + new.qty_change;

  if v_new < 0 and not public.fx_allow_negative_stock() then
    perform public.fx_fail('INSUFFICIENT_STOCK',
      v_name || ' — only ' || trim(to_char(v_stock, 'FM999999990.###')) || ' ' || v_unit ||
      ' in stock, this sale needs ' || trim(to_char(abs(new.qty_change), 'FM999999990.###')) || ' ' || v_unit);
  end if;

  update public.products
     set stock_qty = v_new, updated_at = now()
   where id = new.product_id;

  new.balance_after := v_new;
  return new;
end $$;

drop trigger if exists trg_apply_stock_movement on public.inventory_movements;
create trigger trg_apply_stock_movement
  before insert on public.inventory_movements
  for each row execute function public.fx_apply_stock_movement();

-- ---------------------------------------------------------------------
--  CASHIER-SAFE MIRROR
--  Cashiers must not see cost_price. Postgres RLS is row-level only, so
--  the cost-free columns live in public.stock_levels, which every staff
--  member may read (and realtime-subscribe to).
-- ---------------------------------------------------------------------
create or replace function public.fx_sync_stock_levels()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_category text;
begin
  if tg_op = 'DELETE' then
    delete from public.stock_levels where product_id = old.id;
    return old;
  end if;

  select c.name into v_category from public.categories c where c.id = new.category_id;

  insert into public.stock_levels (
    product_id, barcode, name, unit, sale_price, tax_percent, stock_qty, reorder_level,
    category_id, category_name, is_active, is_deleted, expiry_date, shelf_location, updated_at)
  values (
    new.id, new.barcode, new.name, new.unit, new.sale_price, new.tax_percent, new.stock_qty,
    new.reorder_level, new.category_id, v_category, new.is_active, new.is_deleted,
    new.expiry_date, new.shelf_location, now())
  on conflict (product_id) do update set
    barcode = excluded.barcode, name = excluded.name, unit = excluded.unit,
    sale_price = excluded.sale_price, tax_percent = excluded.tax_percent,
    stock_qty = excluded.stock_qty, reorder_level = excluded.reorder_level,
    category_id = excluded.category_id, category_name = excluded.category_name,
    is_active = excluded.is_active, is_deleted = excluded.is_deleted,
    expiry_date = excluded.expiry_date, shelf_location = excluded.shelf_location,
    updated_at = now();
  return new;
end $$;

drop trigger if exists trg_sync_stock_levels on public.products;
create trigger trg_sync_stock_levels
  after insert or update or delete on public.products
  for each row execute function public.fx_sync_stock_levels();

-- keep the mirror's category name fresh when a category is renamed
create or replace function public.fx_sync_category_name()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.stock_levels set category_name = new.name, updated_at = now()
   where category_id = new.id;
  return new;
end $$;

drop trigger if exists trg_sync_category_name on public.categories;
create trigger trg_sync_category_name
  after update of name on public.categories
  for each row execute function public.fx_sync_category_name();

-- updated_at bookkeeping
drop trigger if exists trg_touch_stores on public.stores;
create trigger trg_touch_stores before update on public.stores
  for each row execute function public.fx_touch_updated_at();

drop trigger if exists trg_touch_products on public.products;
create trigger trg_touch_products before update on public.products
  for each row execute function public.fx_touch_updated_at();

drop trigger if exists trg_touch_profiles on public.profiles;
create trigger trg_touch_profiles before update on public.profiles
  for each row execute function public.fx_touch_updated_at();

drop trigger if exists trg_touch_customers on public.customers;
create trigger trg_touch_customers before update on public.customers
  for each row execute function public.fx_touch_updated_at();

drop trigger if exists trg_touch_suppliers on public.suppliers;
create trigger trg_touch_suppliers before update on public.suppliers
  for each row execute function public.fx_touch_updated_at();

drop trigger if exists trg_touch_discounts on public.discounts;
create trigger trg_touch_discounts before update on public.discounts
  for each row execute function public.fx_touch_updated_at();

-- ---------------------------------------------------------------------
--  AUTO-CREATE A PROFILE FOR EVERY NEW AUTH USER
-- ---------------------------------------------------------------------
create or replace function public.fx_unique_username(p_base text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_base text := nullif(regexp_replace(lower(coalesce(p_base,'staff')), '[^a-z0-9._-]', '', 'g'), '');
  v_try  text;
  v_i    int := 0;
begin
  v_base := coalesce(v_base, 'staff');
  v_try  := v_base;
  while exists (select 1 from public.profiles p where p.username = v_try) loop
    v_i := v_i + 1;
    v_try := v_base || v_i::text;
  end loop;
  return v_try;
end $$;

create or replace function public.fx_handle_new_user()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role     public.user_role := 'cashier';
  v_username text;
  v_fullname text;
begin
  begin
    if new.raw_app_meta_data ? 'role' then
      v_role := (new.raw_app_meta_data->>'role')::public.user_role;
    end if;
  exception when others then
    v_role := 'cashier';
  end;

  v_fullname := coalesce(nullif(new.raw_user_meta_data->>'full_name',''),
                         split_part(coalesce(new.email,'staff'), '@', 1));
  v_username := coalesce(nullif(new.raw_app_meta_data->>'username',''),
                         public.fx_unique_username(split_part(coalesce(new.email,'staff'),'@',1)));

  insert into public.profiles (id, email, username, full_name, role, phone)
  values (new.id, new.email, v_username, v_fullname, v_role,
          nullif(new.raw_user_meta_data->>'phone',''))
  on conflict (id) do update
    set email = excluded.email,
        username = coalesce(public.profiles.username, excluded.username),
        full_name = case when public.profiles.full_name = '' then excluded.full_name else public.profiles.full_name end;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.fx_handle_new_user();

-- ---------------------------------------------------------------------
--  INVOICE / DOCUMENT NUMBERING  (server-side sequences = collision proof)
-- ---------------------------------------------------------------------
create or replace function public.fx_next_no(p_prefix text, p_seq regclass, p_width int default 6)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n bigint;
begin
  execute format('select nextval(%L)', p_seq::text) into v_n;
  return p_prefix || '-' || to_char(now(), 'YYYY') || '-' || lpad(v_n::text, p_width, '0');
end $$;

-- ---------------------------------------------------------------------
--  VIEWS
--  security_invoker = the caller's RLS on the base tables still applies,
--  so the same view is automatically safe for every role.
-- ---------------------------------------------------------------------
drop view if exists public.v_products_pos;
create view public.v_products_pos with (security_invoker = true) as
  select sl.product_id as id, sl.barcode, sl.name, sl.unit, sl.sale_price, sl.tax_percent,
         sl.stock_qty, sl.reorder_level, sl.category_id, sl.category_name,
         sl.is_active, sl.expiry_date, sl.shelf_location, sl.is_weighed, sl.updated_at,
         (sl.stock_qty <= sl.reorder_level) as is_low_stock
    from public.stock_levels sl
   where sl.is_deleted = false and sl.is_active = true;

-- A slimmer version of the same idea, but cashier-friendly:
-- the Flutter app caches this at login and keeps it fresh over realtime.
drop view if exists public.v_products_admin;
create view public.v_products_admin with (security_invoker = true) as
  select p.*, c.name as category_name, s.name as supplier_name,
         (p.stock_qty * p.cost_price) as stock_value,
         (p.sale_price - p.cost_price) as margin_per_unit,
         case when p.sale_price > 0
              then round(((p.sale_price - p.cost_price) / p.sale_price) * 100, 1) else 0 end as margin_percent,
         (p.stock_qty <= p.reorder_level) as is_low_stock
    from public.products p
    left join public.categories c on c.id = p.category_id
    left join public.suppliers  s on s.id = p.supplier_id
   where p.is_deleted = false;

drop view if exists public.v_low_stock;
create view public.v_low_stock with (security_invoker = true) as
  select p.id, p.name, p.barcode, p.sku, c.name as category_name, p.unit,
         p.stock_qty, p.reorder_level, p.cost_price, p.sale_price,
         (p.reorder_level - p.stock_qty) as shortfall,
         round(greatest(p.reorder_level * 2 - p.stock_qty, 0))::numeric as suggested_order_qty,
         p.supplier_id, s.name as supplier_name, s.phone as supplier_phone
    from public.products p
    left join public.categories c on c.id = p.category_id
    left join public.suppliers  s on s.id = p.supplier_id
   where p.is_deleted = false and p.is_active = true
     and p.stock_qty <= p.reorder_level
   order by (p.stock_qty - p.reorder_level) asc, p.name;

drop view if exists public.v_sales_list;
create view public.v_sales_list with (security_invoker = true) as
  select s.id, s.invoice_no, s.created_at, s.status, s.cashier_id, s.cashier_name,
         s.customer_id, s.customer_name, s.device_name, s.item_count,
         s.subtotal, s.line_discount_total, s.invoice_discount_amount, s.tax_amount,
         s.total, s.profit, s.paid_amount, s.change_amount, s.refunded_amount,
         s.payment_method, s.offline_created,
         (select count(*) from public.sale_items si where si.sale_id = s.id) as lines
    from public.sales s;

drop view if exists public.v_daily_sales;
create view public.v_daily_sales with (security_invoker = true) as
  select date_trunc('day', s.created_at)::date as sale_date,
         count(*)                              as invoice_count,
         sum(s.item_count)                     as items_sold,
         sum(s.subtotal)                       as gross_sales,
         sum(s.line_discount_total + s.invoice_discount_amount) as total_discount,
         sum(s.tax_amount)                     as tax_collected,
         sum(s.total)                          as net_sales,
         sum(s.cost_total)                     as total_cost,
         sum(s.profit)                         as gross_profit,
         sum(case when s.payment_method = 'cash'   then s.total else 0 end) as cash_sales,
         sum(case when s.payment_method = 'card'   then s.total else 0 end) as card_sales,
         sum(case when s.payment_method = 'credit' then s.total else 0 end) as credit_sales
    from public.sales s
   where s.status <> 'void'
   group by 1;

drop view if exists public.v_stock_valuation;
create view public.v_stock_valuation with (security_invoker = true) as
  select count(*) as product_count,
         sum(p.stock_qty) as total_units,
         sum(p.stock_qty * p.cost_price) as stock_at_cost,
         sum(p.stock_qty * p.sale_price) as stock_at_retail
    from public.products p
   where p.is_deleted = false and p.is_active = true;

drop view if exists public.v_stock_movements;
create view public.v_stock_movements with (security_invoker = true) as
  select m.id, m.product_id, p.name as product_name, p.barcode, p.unit,
         m.qty_change, m.balance_after, m.movement_type, m.reference_type, m.reference_id,
         m.unit_cost, m.note, m.device_name, m.created_at,
         coalesce(pr.full_name, pr.username, 'system') as actor
    from public.inventory_movements m
    left join public.products p on p.id = m.product_id
    left join public.profiles pr on pr.id = m.created_by;

drop view if exists public.v_returns_list;
create view public.v_returns_list with (security_invoker = true) as
  select r.id, r.return_no, r.invoice_no, r.sale_id, r.reason, r.refund_amount,
         r.refund_method, r.restocked, r.device_name, r.created_at,
         c.name as customer_name,
         coalesce(pr.full_name, pr.username, 'system') as actor
    from public.returns r
    left join public.customers c on c.id = r.customer_id
    left join public.profiles pr on pr.id = r.created_by;

set check_function_bodies = on;

-- =====================================================================
--  SECTION: 03_rpc_api.sql
-- =====================================================================
-- =====================================================================
--  SUPERMART POS  --  03 : RPC API  (all business logic lives here)
--  Run AFTER 02_functions_triggers_views.sql
--
--  Rule of the system: the Flutter app NEVER writes to tables directly.
--  Every mutation goes through one of these functions, which validates the
--  role, validates the data, writes the audit trail and returns the exact
--  numbers the receipt should print. That is why 4 PCs can never disagree.
-- =====================================================================
set check_function_bodies = off;

-- ------------------------- small helpers -----------------------------
create or replace function public.fx_num(p jsonb, p_key text, p_default numeric default 0)
returns numeric language sql immutable as $$
  select case
    when p is null then p_default
    when trim(coalesce(p->>p_key, '')) = '' then p_default
    when trim(coalesce(p->>p_key, '')) !~ '^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$' then p_default
    else trim(p->>p_key)::numeric
  end;
$$;

create or replace function public.fx_txt(p jsonb, p_key text, p_default text default null)
returns text language sql immutable as $$
  select nullif(trim(coalesce(p->>p_key, p_default)), '');
$$;

create or replace function public.fx_bool(p jsonb, p_key text, p_default boolean default false)
returns boolean language sql immutable as $$
  select case
    when p is null then p_default
    when trim(coalesce(p->>p_key, '')) = '' then p_default
    else case lower(trim(p->>p_key))
      when 'true','1','yes','y','t','on' then true
      when 'false','0','no','n','f','off' then false
      else p_default
    end
  end;
$$;

create or replace function public.fx_uuid(p jsonb, p_key text)
returns uuid language sql immutable as $$
  select case
    when p is null then null
    when trim(coalesce(p->>p_key, '')) = '' then null
    when trim(coalesce(p->>p_key, '')) !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then null
    else trim(p->>p_key)::uuid
  end;
$$;

create or replace function public.fx_date(p jsonb, p_key text, p_default date default null)
returns date language sql immutable as $$
  select case
    when p is null then p_default
    when trim(coalesce(p->>p_key, '')) = '' then p_default
    when trim(coalesce(p->>p_key, '')) !~ '^\d{4}-\d{2}-\d{2}$' then p_default
    else trim(p->>p_key)::date
  end;
$$;

-- =====================================================================
--  1. IDENTITY / PERMISSIONS  -- called once at login, cached in the app
-- =====================================================================
create or replace function public.my_identity()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_p public.profiles;
  v_s public.stores;
begin
  select * into v_p from public.profiles where id = auth.uid();
  if not found then
    perform public.fx_fail('NO_PROFILE', 'Your login has no staff profile yet. Ask the Super Admin to set you up.');
  end if;
  if not v_p.is_active then
    perform public.fx_fail('ACCOUNT_DISABLED', 'This account has been disabled. Contact the Super Admin.');
  end if;

  select * into v_s from public.stores order by is_default desc, created_at limit 1;

  update public.profiles set last_login_at = now() where id = v_p.id;

  return jsonb_build_object(
    'id', v_p.id, 'username', v_p.username, 'full_name', v_p.full_name, 'phone', v_p.phone,
    'email', v_p.email, 'role', v_p.role, 'is_active', v_p.is_active,
    'max_discount_percent', v_p.max_discount_percent,
    'is_manager', public.fx_is_manager(), 'is_admin', public.fx_is_admin(),
    'is_super_admin', public.fx_is_super_admin(),
    'store', to_jsonb(v_s)
  );
end $$;

-- =====================================================================
--  2. DEVICES  -- the 4 PCs register themselves and leave a heartbeat
-- =====================================================================
create or replace function public.register_device(
  p_name text, p_hostname text default null, p_terminal_no int default null,
  p_app_version text default null, p_ip text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_d public.devices;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);

  insert into public.devices(name, hostname, terminal_no, app_version, ip_hint, last_seen)
  values (trim(p_name), p_hostname, p_terminal_no, p_app_version, p_ip, now())
  on conflict (name) do update
    set hostname = coalesce(excluded.hostname, public.devices.hostname),
        terminal_no = coalesce(excluded.terminal_no, public.devices.terminal_no),
        app_version = coalesce(excluded.app_version, public.devices.app_version),
        last_seen = now()
  returning * into v_d;

  return to_jsonb(v_d);
end $$;

create or replace function public.list_devices()
returns setof jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(d) from public.devices d order by d.terminal_no nulls last, d.name;
$$;

-- =====================================================================
--  3. CATALOGUE
-- =====================================================================
create or replace function public.save_product(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.products;
  v_barcode text := public.fx_txt(p,'barcode');
  v_sku text := public.fx_txt(p,'sku');
  v_opening numeric := public.fx_num(p,'opening_stock',0);
  v_category_name text := trim(public.fx_txt(p,'category_name'));
  v_subcategory_name text := trim(public.fx_txt(p,'subcategory_name'));
  v_supplier_name text := trim(public.fx_txt(p,'supplier_name'));
  v_category_id uuid := public.fx_uuid(p,'category_id');
  v_supplier_id uuid := public.fx_uuid(p,'supplier_id');
  v_parent_id uuid := null;
  v_subcategory_id uuid := null;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  if v_category_name is not null and v_category_name <> '' then
    select c.id into v_parent_id
    from public.categories c
    where lower(trim(c.name)) = lower(v_category_name) and c.parent_id is null
    limit 1;

    if v_parent_id is null then
      insert into public.categories(name, description, parent_id, sort_order, is_active)
      values (v_category_name, public.fx_txt(p,'category_description'), null, 0, true)
      returning id into v_parent_id;
    end if;
  end if;

  if v_subcategory_name is not null and v_subcategory_name <> '' then
    if v_category_name is not null and v_category_name <> '' then
      select c.id into v_subcategory_id
      from public.categories c
      where lower(trim(c.name)) = lower(v_subcategory_name)
        and c.parent_id = v_parent_id
      limit 1;
    else
      select c.id into v_subcategory_id
      from public.categories c
      where lower(trim(c.name)) = lower(v_subcategory_name)
        and c.parent_id is null
      limit 1;
    end if;

    if v_subcategory_id is null then
      insert into public.categories(name, description, parent_id, sort_order, is_active)
      values (v_subcategory_name, public.fx_txt(p,'subcategory_description'), v_parent_id, 0, true)
      returning id into v_subcategory_id;
    end if;

    v_category_id := v_subcategory_id;
  elsif v_category_id is null and v_category_name is not null and v_category_name <> '' then
    v_category_id := v_parent_id;
  end if;

  if v_supplier_id is null and v_supplier_name is not null and v_supplier_name <> '' then
    select s.id into v_supplier_id
    from public.suppliers s
    where lower(trim(s.name)) = lower(v_supplier_name)
    limit 1;

    if v_supplier_id is null then
      insert into public.suppliers(name, is_active)
      values (v_supplier_name, true)
      returning id into v_supplier_id;
    end if;
  end if;

  if public.fx_txt(p,'name') is null then
    perform public.fx_fail('NAME_REQUIRED','Product name is required.');
  end if;
  if v_barcode is not null and exists (select 1 from public.products x where x.barcode = v_barcode and x.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_BARCODE','Barcode ' || v_barcode || ' is already used by another product.');
  end if;
  if v_sku is not null and exists (select 1 from public.products x where x.sku = v_sku and x.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_SKU','SKU ' || v_sku || ' is already used by another product.');
  end if;

  if v_id is null then
    insert into public.products (
      sku, barcode, name, brand, category_id, supplier_id, unit, pack_size,
      cost_price, sale_price, wholesale_price, tax_percent, reorder_level,
      shelf_location, expiry_date, is_active, created_by, updated_by)
    values (
      v_sku, v_barcode, public.fx_txt(p,'name'), public.fx_txt(p,'brand'),
      v_category_id, v_supplier_id,
      coalesce(public.fx_txt(p,'unit'),'pcs'), public.fx_txt(p,'pack_size'),
      public.fx_num(p,'cost_price',0), public.fx_num(p,'sale_price',0),
      nullif(public.fx_txt(p,'wholesale_price'),'')::numeric,
      nullif(public.fx_txt(p,'tax_percent'),'')::numeric,
      public.fx_num(p,'reorder_level',5), public.fx_txt(p,'shelf_location'),
      public.fx_date(p,'expiry_date'),
      public.fx_bool(p,'is_active',true), auth.uid(), auth.uid())
    returning * into v_row;

    if v_opening <> 0 then
      insert into public.inventory_movements(product_id, qty_change, movement_type, note, device_name, created_by)
      values (v_row.id, v_opening, 'opening', 'Opening stock', p_device, auth.uid());
    end if;
  else
    update public.products set
      sku = v_sku, barcode = v_barcode, name = public.fx_txt(p,'name'),
      brand = public.fx_txt(p,'brand'),
      category_id = v_category_id,
      supplier_id = v_supplier_id,
      unit = coalesce(public.fx_txt(p,'unit'),'pcs'),
      pack_size = public.fx_txt(p,'pack_size'),
      cost_price = public.fx_num(p,'cost_price',0),
      sale_price = public.fx_num(p,'sale_price',0),
      wholesale_price = nullif(public.fx_txt(p,'wholesale_price'),'')::numeric,
      tax_percent = nullif(public.fx_txt(p,'tax_percent'),'')::numeric,
      reorder_level = public.fx_num(p,'reorder_level',5),
      shelf_location = public.fx_txt(p,'shelf_location'),
      expiry_date = public.fx_date(p,'expiry_date'),
      is_active = public.fx_bool(p,'is_active',true),
      updated_by = auth.uid()
    where id = v_id
    returning * into v_row;

    if not found then
      perform public.fx_fail('NOT_FOUND','Product not found.');
    end if;
  end if;

  perform public.fx_audit(case when v_id is null then 'product.create' else 'product.update' end,
    'products', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'barcode', v_row.barcode,
                       'category_id', v_row.category_id,
                       'cost_price', v_row.cost_price, 'sale_price', v_row.sale_price), p_device);

  return to_jsonb(v_row);
end $$;

create or replace function public.delete_product(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.products;
begin
  perform public.fx_require_role(array['admin','super_admin']);
  -- the row stays so old invoices and purchases still point at something, but
  -- its barcode and SKU are freed so a new product can use them
  update public.products set is_deleted = true, is_active = false, barcode = null, sku = null,
         updated_by = auth.uid()
   where id = p_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;
  perform public.fx_audit('product.delete','products', p_id::text, jsonb_build_object('name', v_row.name), p_device);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.adjust_stock(
  p_product_id uuid, p_new_qty numeric, p_reason text, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_cur numeric; v_diff numeric; v_name text;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if p_new_qty < 0 then perform public.fx_fail('BAD_QTY','Stock cannot be negative.'); end if;

  select stock_qty, name into v_cur, v_name from public.products where id = p_product_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;

  v_diff := p_new_qty - v_cur;
  if v_diff = 0 then return jsonb_build_object('ok', true, 'changed', false, 'stock_qty', v_cur); end if;

  insert into public.inventory_movements(product_id, qty_change, movement_type, note, device_name, created_by)
  values (p_product_id, v_diff, 'adjustment', coalesce(p_reason,'Manual adjustment'), p_device, auth.uid());

  perform public.fx_audit('stock.adjust','products', p_product_id::text,
    jsonb_build_object('name', v_name, 'from', v_cur, 'to', p_new_qty, 'reason', p_reason), p_device);

  return jsonb_build_object('ok', true, 'changed', true, 'stock_qty', p_new_qty, 'difference', v_diff);
end $$;

create or replace function public.bulk_import_products(p_rows jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; v_ok int := 0; v_fail int := 0; v_errors jsonb := '[]'::jsonb; v_res jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    begin
      v_res := public.save_product(r, p_device);
      v_ok := v_ok + 1;
    exception when others then
      v_fail := v_fail + 1;
      v_errors := v_errors || jsonb_build_object('row', r, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('imported', v_ok, 'failed', v_fail, 'errors', v_errors);
end $$;

create or replace function public.save_category(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_parent_id uuid := public.fx_uuid(p,'parent_id');
  v_row public.categories;
  v_name text := trim(public.fx_txt(p,'name'));
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_name is null or v_name = '' then perform public.fx_fail('NAME_REQUIRED','Category name is required.'); end if;

  if v_parent_id is not null and exists (
    select 1 from public.categories c where c.id = v_parent_id and c.parent_id is not null
  ) then
    perform public.fx_fail('BAD_PARENT','Subcategories cannot be nested more than one level deep.');
  end if;

  if v_id is null then
    insert into public.categories(name, description, parent_id, sort_order, is_active)
    values (v_name, public.fx_txt(p,'description'), v_parent_id, public.fx_num(p,'sort_order',0), public.fx_bool(p,'is_active',true))
    returning * into v_row;
  else
    update public.categories set name = v_name, description = public.fx_txt(p,'description'),
           parent_id = v_parent_id, sort_order = public.fx_num(p,'sort_order',0),
           is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('category.save','categories', v_row.id::text, jsonb_build_object('name', v_row.name, 'parent_id', v_row.parent_id), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_category(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_name text;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  select name into v_name from public.categories where id = p_id;
  if not found then
    perform public.fx_fail('NOT_FOUND','Category not found.');
  end if;

  delete from public.categories where id = p_id;
  perform public.fx_audit('category.delete','categories', p_id::text, jsonb_build_object('name', v_name), p_device);
  return jsonb_build_object('ok', true, 'deleted_id', p_id::text, 'name', v_name);
end $$;

create or replace function public.save_supplier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.suppliers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Supplier name is required.'); end if;

  if v_id is null then
    insert into public.suppliers(name, contact_person, phone, email, address, city, ntn, opening_balance, notes, is_active)
    values (public.fx_txt(p,'name'), public.fx_txt(p,'contact_person'), public.fx_txt(p,'phone'),
            public.fx_txt(p,'email'), public.fx_txt(p,'address'), public.fx_txt(p,'city'),
            public.fx_txt(p,'ntn'), public.fx_num(p,'opening_balance',0), public.fx_txt(p,'notes'),
            public.fx_bool(p,'is_active',true))
    returning * into v_row;
  else
    update public.suppliers set name = public.fx_txt(p,'name'), contact_person = public.fx_txt(p,'contact_person'),
      phone = public.fx_txt(p,'phone'), email = public.fx_txt(p,'email'), address = public.fx_txt(p,'address'),
      city = public.fx_txt(p,'city'), ntn = public.fx_txt(p,'ntn'),
      opening_balance = public.fx_num(p,'opening_balance',0), notes = public.fx_txt(p,'notes'),
      is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('supplier.save','suppliers', v_row.id::text, jsonb_build_object('name', v_row.name), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_customer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.customers; v_phone text := public.fx_txt(p,'phone');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Customer name is required.'); end if;
  if v_phone is not null and exists (select 1 from public.customers c where c.phone = v_phone and c.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_PHONE','Another customer already uses phone ' || v_phone || '.');
  end if;

  if v_id is null then
    insert into public.customers(name, phone, email, address, credit_limit, notes, created_by)
    values (public.fx_txt(p,'name'), v_phone, public.fx_txt(p,'email'), public.fx_txt(p,'address'),
            public.fx_num(p,'credit_limit',0), public.fx_txt(p,'notes'), auth.uid())
    returning * into v_row;
  else
    update public.customers set name = public.fx_txt(p,'name'), phone = v_phone, email = public.fx_txt(p,'email'),
      address = public.fx_txt(p,'address'), credit_limit = public.fx_num(p,'credit_limit',0),
      notes = public.fx_txt(p,'notes'), is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('customer.save','customers', v_row.id::text, jsonb_build_object('name', v_row.name), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.receive_customer_payment(
  p_customer_id uuid, p_amount numeric, p_method public.payment_method default 'cash',
  p_note text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bal numeric; v_name text;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if p_amount <= 0 then perform public.fx_fail('BAD_AMOUNT','Amount must be greater than zero.'); end if;

  update public.customers set balance = balance - p_amount
   where id = p_customer_id returning balance, name into v_bal, v_name;
  if not found then perform public.fx_fail('NOT_FOUND','Customer not found.'); end if;

  perform public.fx_audit('customer.payment','customers', p_customer_id::text,
    jsonb_build_object('amount', p_amount, 'method', p_method, 'balance_after', v_bal, 'note', p_note), p_device);
  return jsonb_build_object('ok', true, 'customer_name', v_name, 'balance', v_bal);
end $$;

-- =====================================================================
--  4. DISCOUNTS  (Super Admin controls the rules)
-- =====================================================================
create or replace function public.save_discount(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.discounts; v_code text := upper(public.fx_txt(p,'code'));
begin
  perform public.fx_require_role(array['admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Discount name is required.'); end if;
  if public.fx_num(p,'value',0) < 0 then perform public.fx_fail('BAD_VALUE','Discount value cannot be negative.'); end if;
  if public.fx_txt(p,'kind') = 'percent' and public.fx_num(p,'value',0) > 100 then
    perform public.fx_fail('BAD_VALUE','A percentage discount cannot exceed 100%.');
  end if;
  if v_code is not null and exists (select 1 from public.discounts d where upper(d.code) = v_code and d.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_CODE','Discount code ' || v_code || ' already exists.');
  end if;

  if v_id is null then
    insert into public.discounts(code, name, kind, value, scope, category_id, product_id, min_subtotal,
      max_discount, requires_manager, applies_automatically, starts_at, ends_at, max_uses, is_active, created_by)
    values (v_code, public.fx_txt(p,'name'),
      coalesce(public.fx_txt(p,'kind'),'percent')::public.discount_kind, public.fx_num(p,'value',0),
      coalesce(public.fx_txt(p,'scope'),'all')::public.discount_scope,
      public.fx_uuid(p,'category_id'), public.fx_uuid(p,'product_id'), public.fx_num(p,'min_subtotal',0),
      nullif(public.fx_txt(p,'max_discount'),'')::numeric,
      public.fx_bool(p,'requires_manager',false), public.fx_bool(p,'applies_automatically',false),
      coalesce(nullif(public.fx_txt(p,'starts_at'),'')::timestamptz, now()),
      nullif(public.fx_txt(p,'ends_at'),'')::timestamptz,
      nullif(public.fx_txt(p,'max_uses'),'')::int, public.fx_bool(p,'is_active',true), auth.uid())
    returning * into v_row;
  else
    update public.discounts set code = v_code, name = public.fx_txt(p,'name'),
      kind = coalesce(public.fx_txt(p,'kind'),'percent')::public.discount_kind, value = public.fx_num(p,'value',0),
      scope = coalesce(public.fx_txt(p,'scope'),'all')::public.discount_scope,
      category_id = public.fx_uuid(p,'category_id'), product_id = public.fx_uuid(p,'product_id'),
      min_subtotal = public.fx_num(p,'min_subtotal',0),
      max_discount = nullif(public.fx_txt(p,'max_discount'),'')::numeric,
      requires_manager = public.fx_bool(p,'requires_manager',false),
      applies_automatically = public.fx_bool(p,'applies_automatically',false),
      starts_at = coalesce(nullif(public.fx_txt(p,'starts_at'),'')::timestamptz, now()),
      ends_at = nullif(public.fx_txt(p,'ends_at'),'')::timestamptz,
      max_uses = nullif(public.fx_txt(p,'max_uses'),'')::int,
      is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;

  perform public.fx_audit('discount.save','discounts', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'name', v_row.name, 'value', v_row.value, 'kind', v_row.kind), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_discount(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.fx_require_role(array['admin','super_admin']);
  delete from public.discounts where id = p_id;
  perform public.fx_audit('discount.delete','discounts', p_id::text, '{}'::jsonb, p_device);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.check_discount_code(p_code text, p_subtotal numeric)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_d public.discounts;
  v_amount numeric := 0;
  v_eff numeric := 100;
begin
  select * into v_d from public.discounts
   where upper(coalesce(code,'')) = upper(trim(p_code)) and is_active
     and starts_at <= now() and (ends_at is null or ends_at >= now())
   limit 1;
  if not found then
    perform public.fx_fail('CODE_INVALID','That discount code is not valid or has expired.');
  end if;
  if v_d.min_subtotal > 0 and p_subtotal < v_d.min_subtotal then
    perform public.fx_fail('CODE_MIN_SUBTOTAL',
      'Code ' || v_d.code || ' needs a minimum bill of ' || to_char(v_d.min_subtotal,'FM999999990.00') || '.');
  end if;
  if v_d.max_uses is not null and v_d.used_count >= v_d.max_uses then
    perform public.fx_fail('CODE_EXHAUSTED','That discount code has been fully used.');
  end if;
  if v_d.requires_manager and not public.fx_is_manager() then
    perform public.fx_fail('CODE_NEEDS_MANAGER','Code ' || v_d.code || ' needs a manager to apply it.');
  end if;

  v_amount := case when v_d.kind = 'percent' then round(p_subtotal * v_d.value / 100.0, 2) else v_d.value end;
  if v_d.max_discount is not null then v_amount := least(v_amount, v_d.max_discount); end if;
  v_amount := least(v_amount, p_subtotal);
  if p_subtotal > 0 then v_eff := round(v_amount / p_subtotal * 100, 2); end if;

  return jsonb_build_object(
    'id', v_d.id, 'code', v_d.code, 'name', v_d.name, 'kind', v_d.kind,
    'value', v_d.value, 'scope', v_d.scope, 'amount', v_amount,
    'effective_percent', v_eff, 'requires_manager', v_d.requires_manager,
    'product_id', v_d.product_id, 'category_id', v_d.category_id);
end $$;

-- =====================================================================
--  5. SHIFTS
-- =====================================================================
create or replace function public.open_shift(p_opening_float numeric, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_s public.shifts; v_existing public.shifts; v_store public.stores;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);

  select * into v_existing from public.shifts where cashier_id = auth.uid() and status = 'open' limit 1;
  if found then
    perform public.fx_fail('SHIFT_ALREADY_OPEN','You already have shift ' || coalesce(v_existing.shift_no,'') || ' open on ' || coalesce(v_existing.device_name,'another till') || '.');
  end if;

  select * into v_store from public.stores order by is_default desc, created_at limit 1;

  insert into public.shifts(shift_no, cashier_id, device_name, opening_float)
  values (public.fx_next_no('SHF','public.shift_seq',5), auth.uid(), p_device, coalesce(p_opening_float,0))
  returning * into v_s;

  perform public.fx_audit('shift.open','shifts', v_s.id::text,
    jsonb_build_object('opening_float', p_opening_float, 'device', p_device), p_device);

  return to_jsonb(v_s) || jsonb_build_object(
    'cashier_name', public.fx_actor_name(),
    'store', to_jsonb(v_store));
end $$;

create or replace function public.current_shift()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(s) from public.shifts s
   where s.cashier_id = auth.uid() and s.status = 'open'
   order by s.opened_at desc limit 1;
$$;

create or replace function public.shift_summary(p_shift_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_s public.shifts;
  v_sales numeric := 0; v_cash numeric := 0; v_card numeric := 0; v_other numeric := 0;
  v_credit numeric := 0; v_refunds numeric := 0; v_expenses numeric := 0; v_inv int := 0;
  v_items numeric := 0; v_disc numeric := 0; v_tax numeric := 0; v_profit numeric := 0;
begin
  select * into v_s from public.shifts where id = p_shift_id;
  if not found then perform public.fx_fail('NOT_FOUND','Shift not found.'); end if;
  if not (v_s.cashier_id = auth.uid() or public.fx_is_manager()) then
    perform public.fx_fail('NOT_ALLOWED','You can only view your own shift.');
  end if;

  select coalesce(count(*),0), coalesce(sum(total),0),
         coalesce(sum(case when payment_method='cash' then total else 0 end),0),
         coalesce(sum(case when payment_method='card' then total else 0 end),0),
         coalesce(sum(case when payment_method in ('jazzcash','easypaisa','bank_transfer') then total else 0 end),0),
         coalesce(sum(case when payment_method='credit' then total else 0 end),0),
         coalesce(sum(refunded_amount),0), coalesce(sum(item_count),0),
         coalesce(sum(line_discount_total + invoice_discount_amount),0),
         coalesce(sum(tax_amount),0), coalesce(sum(profit),0)
    into v_inv, v_sales, v_cash, v_card, v_other, v_credit, v_refunds, v_items, v_disc, v_tax, v_profit
    from public.sales
   where shift_id = p_shift_id and status <> 'void' and created_at >= v_s.opened_at;

  select coalesce(sum(amount),0) into v_expenses
    from public.expenses where shift_id = p_shift_id;

  return jsonb_build_object(
    'shift', to_jsonb(v_s),
    'cashier_name', (select full_name from public.profiles where id = v_s.cashier_id),
    'invoice_count', v_inv, 'items_sold', v_items, 'gross_sales', v_sales,
    'total_discount', v_disc, 'tax_collected', v_tax, 'gross_profit', v_profit,
    'cash_sales', v_cash, 'card_sales', v_card, 'other_sales', v_other,
    'credit_sales', v_credit, 'refunds', v_refunds, 'expenses', v_expenses,
    'expected_cash', v_s.opening_float + v_cash - v_refunds - v_expenses,
    'payment_mix', coalesce((select jsonb_agg(x) from (
        select payment_method as method, count(*) as invoices, sum(total) as amount
          from public.sales where shift_id = p_shift_id and status <> 'void'
         group by 1 order by 3 desc) x), '[]'::jsonb),
    'top_items', coalesce((select jsonb_agg(t) from (
        select si.name_snapshot as name, sum(si.qty) as qty, sum(si.line_total) as amount
          from public.sale_items si join public.sales s on s.id = si.sale_id
         where s.shift_id = p_shift_id and s.status <> 'void'
         group by 1 order by 3 desc limit 10) t), '[]'::jsonb));
end $$;

create or replace function public.close_shift(p_shift_id uuid, p_counted_cash numeric, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_s public.shifts; v_sum jsonb; v_expected numeric; v_diff numeric; v_role text := public.fx_role();
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);

  select * into v_s from public.shifts where id = p_shift_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','Shift not found.'); end if;
  if v_s.status = 'closed' then perform public.fx_fail('ALREADY_CLOSED','That shift was already closed.'); end if;
  if v_s.cashier_id <> auth.uid() and not public.fx_is_manager() then
    perform public.fx_fail('NOT_ALLOWED','You can only close your own shift.');
  end if;

  v_sum := public.shift_summary(p_shift_id);
  v_expected := coalesce((v_sum->>'expected_cash')::numeric, 0);
  v_diff := coalesce(p_counted_cash,0) - v_expected;

  update public.shifts set
    status = 'closed', closed_at = now(), closed_by = auth.uid(),
    invoice_count = coalesce((v_sum->>'invoice_count')::int,0),
    total_sales = coalesce((v_sum->>'gross_sales')::numeric,0),
    total_cash_sales = coalesce((v_sum->>'cash_sales')::numeric,0),
    total_card_sales = coalesce((v_sum->>'card_sales')::numeric,0),
    total_other_sales = coalesce((v_sum->>'other_sales')::numeric,0),
    total_credit_sales = coalesce((v_sum->>'credit_sales')::numeric,0),
    total_refunds = coalesce((v_sum->>'refunds')::numeric,0),
    expected_cash = v_expected, counted_cash = p_counted_cash, difference = v_diff,
    note = p_note
   where id = p_shift_id
  returning * into v_s;

  perform public.fx_audit('shift.close','shifts', p_shift_id::text,
    jsonb_build_object('expected_cash', v_expected, 'counted_cash', p_counted_cash, 'difference', v_diff), v_s.device_name);

  return public.shift_summary(p_shift_id) || jsonb_build_object('closed', true, 'difference', v_diff);
end $$;

-- =====================================================================
--  6. THE SALE  -- the single entry point for every POS transaction
-- =====================================================================
create or replace function public.create_sale(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_store public.stores;
  v_cuuid text := public.fx_txt(p,'client_uuid');
  v_exist public.sales;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_lines jsonb := '[]'::jsonb;
  v_line record;        -- rows from the staged cart
  v_prod public.products;
  v_qty numeric; v_price numeric; v_line_disc numeric; v_sell numeric;
  v_tax_pct numeric; v_tax numeric; v_line_total numeric; v_line_base numeric;
  v_subtotal numeric := 0; v_line_disc_total numeric := 0; v_tax_total numeric := 0;
  v_cost_total numeric := 0; v_profit_total numeric := 0; v_item_count int := 0;
  v_inv_type public.invoice_discount_type := 'none';
  v_inv_value numeric := 0; v_inv_amount numeric := 0;
  v_code text := upper(public.fx_txt(p,'discount_code'));
  v_disc public.discounts;
  v_total numeric := 0; v_paid numeric := 0; v_change numeric := 0;
  v_method public.payment_method;
  v_customer public.customers;
  v_customer_id uuid := public.fx_uuid(p,'customer_id');
  v_sale_id uuid; v_invoice_no text; v_shift_id uuid := public.fx_uuid(p,'shift_id');
  v_role text := public.fx_role();
  v_max_disc numeric;
  v_disc_percent numeric := 0;
  v_device text := coalesce(p_device, public.fx_txt(p,'device_name'));
  v_bad record;
  v_allow_negative boolean := public.fx_allow_negative_stock();
  v_auto_disc public.discounts;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);

  -- ---- idempotency: an offline sale replayed twice must not double-bill --
  if v_cuuid is not null then
    select * into v_exist from public.sales where client_uuid = v_cuuid;
    if found then
      return jsonb_build_object('sale_id', v_exist.id, 'invoice_no', v_exist.invoice_no,
        'total', v_exist.total, 'duplicate', true, 'created_at', v_exist.created_at);
    end if;
  end if;

  select * into v_profile from public.profiles where id = v_uid;
  select * into v_store from public.stores order by is_default desc, created_at limit 1;
  v_max_disc := coalesce(v_profile.max_discount_percent, v_store.max_cashier_discount_percent, 0);

  if jsonb_array_length(v_items) = 0 then
    perform public.fx_fail('EMPTY_CART','The cart is empty.');
  end if;

  -- ---- shift: attach to the cashier's open shift, or auto-open one ------
  if v_shift_id is null then
    select id into v_shift_id from public.shifts
     where cashier_id = v_uid and status = 'open' order by opened_at desc limit 1;
  end if;
  if v_shift_id is null then
    insert into public.shifts(shift_no, cashier_id, device_name, opening_float)
    values (public.fx_next_no('SHF','public.shift_seq',5), v_uid, v_device, 0)
    returning id into v_shift_id;
  end if;

  -- ---- stage the cart (set-based, deadlock-free) -----------------------
  create temp table if not exists _pos_lines (
    product_id uuid, qty numeric, unit_price numeric, line_discount numeric,
    name_snapshot text, barcode_snapshot text, unit text, cost_price numeric, tax_percent numeric
  ) on commit drop;
  delete from _pos_lines where true;

  insert into _pos_lines(product_id, qty, unit_price, line_discount, name_snapshot, barcode_snapshot, unit, cost_price, tax_percent)
  select public.fx_uuid(jsonb_build_object('product_id', x.product_id), 'product_id'),
         x.qty, x.unit_price, coalesce(x.line_discount,0),
         nullif(trim(coalesce(x.name_snapshot,'')),'') ,
         nullif(trim(coalesce(x.barcode_snapshot,'')),'') ,
         nullif(trim(coalesce(x.unit,'')),'') ,
         coalesce(x.cost_price,0), coalesce(x.tax_percent,0)
    from jsonb_to_recordset(v_items) as x(
      product_id text, qty numeric, unit_price numeric, line_discount numeric,
      name_snapshot text, barcode_snapshot text, unit text, cost_price numeric, tax_percent numeric
    );

  if exists (select 1 from _pos_lines where qty is null or qty <= 0) then
    perform public.fx_fail('BAD_LINE','Every sale line needs a quantity greater than zero.');
  end if;

  -- lock every product row in a deterministic order: two tills selling at the
  -- same instant queue up here instead of deadlocking
  perform 1 from public.products pr
     join (select product_id, sum(qty) as q from _pos_lines where product_id is not null group by product_id) g on g.product_id = pr.id
    order by pr.id
      for update of pr;

  -- validate the cart against live data
  for v_bad in
    select pr.id, pr.name, pr.unit, pr.stock_qty, g.q as want, pr.is_active, pr.is_deleted, pr.sale_price, pr.cost_price
      from public.products pr
      join (select product_id, sum(qty) as q from _pos_lines where product_id is not null group by product_id) g on g.product_id = pr.id
  loop
    if v_bad.is_deleted or not v_bad.is_active then
      perform public.fx_fail('PRODUCT_INACTIVE', v_bad.name || ' is no longer for sale. Remove it from the cart.');
    end if;
    if not v_allow_negative and v_bad.stock_qty < v_bad.want then
      perform public.fx_fail('INSUFFICIENT_STOCK',
        v_bad.name || ' — only ' || trim(to_char(v_bad.stock_qty,'FM999999990.###')) || ' ' || v_bad.unit ||
        ' in stock, the cart needs ' || trim(to_char(v_bad.want,'FM999999990.###')));
    end if;
  end loop;

  -- price the cart from the live database (never trust the till's own numbers)
  for v_line in
    select l.product_id, l.qty, l.unit_price, l.line_discount, l.name_snapshot, l.barcode_snapshot, l.unit, l.cost_price, l.tax_percent,
           pr.name, pr.barcode, pr.unit as product_unit, pr.sale_price, pr.cost_price as product_cost_price, pr.tax_percent as product_tax_percent,
           pr.category_id, pr.is_active, pr.is_deleted
      from _pos_lines l
      left join public.products pr on pr.id = l.product_id
  loop
    v_qty := v_line.qty;
    v_price := coalesce(nullif(v_line.unit_price,0), coalesce(v_line.sale_price,0));

    if v_line.product_id is not null then
      -- a till may charge less than the shelf price, but never more, unless a
      -- manager is signed in or the store allows price override
      if v_price > v_line.sale_price and not public.fx_is_manager() and not v_store.allow_price_override then
        perform public.fx_fail('PRICE_OVERRIDE_NOT_ALLOWED',
          'Price of ' || v_line.name || ' was changed from ' || to_char(v_line.sale_price,'FM999999990.00') ||
          '. Only a manager can override prices.');
      end if;
    end if;

    v_line_disc := least(coalesce(v_line.line_discount,0), v_price * v_qty);
    v_line_base := v_price * v_qty;
    v_sell := v_line_base - v_line_disc;

    v_tax_pct := coalesce(v_line.tax_percent, v_line.product_tax_percent,
                          case when v_store.tax_inclusive then 0 else v_store.tax_percent end, 0);
    v_tax := round(v_sell * v_tax_pct / 100.0, 2);
    if v_store.tax_inclusive then
      v_tax := round(v_sell - (v_sell / (1 + v_tax_pct/100.0)), 2);
      v_line_total := round(v_sell, 2);
    else
      v_line_total := round(v_sell + v_tax, 2);
    end if;

    v_subtotal := v_subtotal + round(v_sell, 2);
    v_line_disc_total := v_line_disc_total + v_line_disc;
    v_tax_total := v_tax_total + v_tax;
    if v_line.product_id is not null then
      v_cost_total := v_cost_total + round(coalesce(v_line.product_cost_price, v_line.cost_price, 0) * v_qty, 2);
      v_profit_total := v_profit_total + round(v_line_total - v_tax - (coalesce(v_line.product_cost_price, v_line.cost_price, 0) * v_qty), 2);
    end if;
    v_item_count := v_item_count + 1;

    v_lines := v_lines || jsonb_build_object(
      'product_id', v_line.product_id,
      'name_snapshot', coalesce(v_line.name, v_line.name_snapshot, 'Custom item'),
      'barcode_snapshot', coalesce(v_line.barcode, v_line.barcode_snapshot),
      'unit', coalesce(v_line.product_unit, v_line.unit, 'pcs'),
      'qty', v_qty,
      'unit_price', v_price,
      'cost_price', coalesce(v_line.product_cost_price, v_line.cost_price, 0),
      'line_discount', v_line_disc,
      'tax_percent', v_tax_pct,
      'tax_amount', v_tax,
      'line_total', v_line_total);
  end loop;

  -- ---- invoice-level discount -----------------------------------------
  v_inv_type := coalesce(public.fx_txt(p,'invoice_discount_type'),'none')::public.invoice_discount_type;
  v_inv_value := public.fx_num(p,'invoice_discount_value',0);

  if v_code is not null then
    select * into v_disc from public.discounts
     where upper(coalesce(code,'')) = v_code and is_active
       and starts_at <= now() and (ends_at is null or ends_at >= now()) limit 1;
    if not found then
      perform public.fx_fail('CODE_INVALID','Discount code ' || v_code || ' is not valid or has expired.');
    end if;
    if v_disc.min_subtotal > 0 and v_subtotal < v_disc.min_subtotal then
      perform public.fx_fail('CODE_MIN_SUBTOTAL','Code ' || v_code || ' needs a minimum bill of ' || to_char(v_disc.min_subtotal,'FM999999990.00'));
    end if;
    if v_disc.max_uses is not null and v_disc.used_count >= v_disc.max_uses then
      perform public.fx_fail('CODE_EXHAUSTED','That discount code has been fully used.');
    end if;
    if v_disc.requires_manager and not public.fx_is_manager() then
      perform public.fx_fail('CODE_NEEDS_MANAGER','Code ' || v_code || ' needs a manager to authorise it.');
    end if;

    v_inv_type := 'code';
    v_inv_value := v_disc.value;
    if v_disc.kind = 'percent' then
      v_inv_amount := round(v_subtotal * v_disc.value / 100.0, 2);
    else
      v_inv_amount := v_disc.value;
    end if;
    if v_disc.max_discount is not null then v_inv_amount := least(v_inv_amount, v_disc.max_discount); end if;
    v_inv_amount := least(v_inv_amount, v_subtotal);

    update public.discounts set used_count = used_count + 1 where id = v_disc.id;
  elsif v_inv_type = 'percent' then
    if v_inv_value < 0 or v_inv_value > 100 then
      perform public.fx_fail('BAD_DISCOUNT','Discount percent must be between 0 and 100.');
    end if;
    v_inv_amount := round(v_subtotal * v_inv_value / 100.0, 2);
  elsif v_inv_type = 'amount' then
    if v_inv_value < 0 then perform public.fx_fail('BAD_DISCOUNT','Discount cannot be negative.'); end if;
    v_inv_amount := least(v_inv_value, v_subtotal);
  else
    -- automatic store-wide promotions the Super Admin switched on
    select * into v_auto_disc from public.discounts
     where is_active and applies_automatically and scope = 'all'
       and starts_at <= now() and (ends_at is null or ends_at >= now())
       and min_subtotal <= v_subtotal
       and (max_uses is null or used_count < max_uses)
     order by (case when kind = 'percent' then value else (value / greatest(v_subtotal,1) * 100) end) desc
     limit 1;
    if found then
      v_inv_type := 'code';
      v_code := v_auto_disc.code;
      v_inv_value := v_auto_disc.value;
      v_inv_amount := case when v_auto_disc.kind = 'percent'
                           then round(v_subtotal * v_auto_disc.value / 100.0, 2) else v_auto_disc.value end;
      if v_auto_disc.max_discount is not null then v_inv_amount := least(v_inv_amount, v_auto_disc.max_discount); end if;
      v_inv_amount := least(v_inv_amount, v_subtotal);
      update public.discounts set used_count = used_count + 1 where id = v_auto_disc.id;
    end if;
  end if;

  -- ---- cashier discount ceiling ---------------------------------------
  -- measured against the GROSS bill (before any line discounts), so a cashier
  -- giving exactly their limit is not refused for "rounding" reasons
  if v_role = 'cashier' and (v_subtotal + v_line_disc_total) > 0 then
    v_disc_percent := round((v_line_disc_total + v_inv_amount) /
                            (v_subtotal + v_line_disc_total) * 100, 2);
    if v_disc_percent > v_max_disc then
      perform public.fx_fail('DISCOUNT_LIMIT',
        'That is a ' || trim(to_char(v_disc_percent,'FM990.0')) || '% discount but your limit is ' ||
        trim(to_char(v_max_disc,'FM990.0')) || '%. Ask a manager to authorise it.');
    end if;
  end if;

  v_total := round(greatest(v_subtotal - v_inv_amount, 0), 2);

  -- ---- payment ---------------------------------------------------------
  v_method := coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method;

  if v_customer_id is not null then
    select * into v_customer from public.customers where id = v_customer_id;
    if not found then perform public.fx_fail('NOT_FOUND','Customer not found.'); end if;
  end if;

  if v_method = 'credit' then
    if v_customer_id is null then
      perform public.fx_fail('CREDIT_NEEDS_CUSTOMER','Choose a customer account for a credit (udhaar) sale.');
    end if;
    if v_customer.credit_limit > 0 and (v_customer.balance + v_total) > v_customer.credit_limit then
      perform public.fx_fail('CREDIT_LIMIT',
        v_customer.name || ' already owes ' || to_char(v_customer.balance,'FM999999990.00') ||
        ' and the credit limit is ' || to_char(v_customer.credit_limit,'FM999999990.00') || '.');
    end if;
    v_paid := 0;
    update public.customers set balance = balance + v_total where id = v_customer_id;
  else
    v_paid := coalesce(nullif(public.fx_num(p,'paid_amount',0),0), v_total);
    if v_method <> 'cash' then v_paid := greatest(v_paid, v_total); end if;
    if v_method = 'cash' and v_paid < v_total then
      perform public.fx_fail('INSUFFICIENT_PAYMENT',
        'Cash received (' || to_char(v_paid,'FM999999990.00') || ') is less than the bill (' || to_char(v_total,'FM999999990.00') || ').');
    end if;
    v_change := greatest(round(v_paid - v_total, 2), 0);
  end if;

  -- ---- write the invoice ----------------------------------------------
  v_invoice_no := public.fx_next_no(coalesce(v_store.invoice_prefix,'INV'), 'public.invoice_seq', 6);

  insert into public.sales (
    client_uuid, invoice_no, store_id, cashier_id, cashier_name, shift_id, customer_id, customer_name,
    device_name, item_count, subtotal, line_discount_total, invoice_discount_type, invoice_discount_value,
    invoice_discount_amount, discount_code, tax_amount, total, cost_total, profit, paid_amount, change_amount,
    payment_method, payment_ref, status, note, offline_created)
  values (
    v_cuuid, v_invoice_no, v_store.id, v_uid, coalesce(v_profile.full_name, v_profile.username), v_shift_id,
    v_customer_id, v_customer.name, v_device, v_item_count, round(v_subtotal,2), round(v_line_disc_total,2),
    v_inv_type, v_inv_value, round(v_inv_amount,2), v_code, round(v_tax_total,2), v_total,
    round(v_cost_total,2), round(v_profit_total,2), round(v_paid,2), v_change,
    v_method, public.fx_txt(p,'payment_ref'), 'completed', public.fx_txt(p,'note'),
    public.fx_bool(p,'offline_created',false))
  returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, product_id, name_snapshot, barcode_snapshot, unit, qty, unit_price, cost_price,
    line_discount, tax_percent, tax_amount, line_total)
    select v_sale_id,
      public.fx_uuid(jsonb_build_object('product_id', l->>'product_id'),'product_id'), l->>'name_snapshot', l->>'barcode_snapshot', l->>'unit',
         public.fx_num(jsonb_build_object('qty', l->>'qty'), 'qty', 0),
         public.fx_num(jsonb_build_object('unit_price', l->>'unit_price'), 'unit_price', 0),
         public.fx_num(jsonb_build_object('cost_price', l->>'cost_price'), 'cost_price', 0),
         public.fx_num(jsonb_build_object('line_discount', l->>'line_discount'), 'line_discount', 0),
         public.fx_num(jsonb_build_object('tax_percent', l->>'tax_percent'), 'tax_percent', 0),
         public.fx_num(jsonb_build_object('tax_amount', l->>'tax_amount'), 'tax_amount', 0),
         public.fx_num(jsonb_build_object('line_total', l->>'line_total'), 'line_total', 0)
    from jsonb_array_elements(v_lines) l;

  -- every product-backed line writes an inventory movement; custom misc items are
  -- not stocked and therefore do not touch the stock ledger.
  insert into public.inventory_movements (
    product_id, qty_change, movement_type, reference_type, reference_id, unit_cost, note, device_name, created_by)
  select public.fx_uuid(jsonb_build_object('product_id', l->>'product_id'),'product_id'),
         -(public.fx_num(jsonb_build_object('qty', l->>'qty'), 'qty', 0)), 'sale', 'sale', v_sale_id,
         public.fx_num(jsonb_build_object('cost_price', l->>'cost_price'), 'cost_price', 0), v_invoice_no, v_device, v_uid
    from jsonb_array_elements(v_lines) l
    where l->>'product_id' is not null and trim(l->>'product_id') <> '';

  -- loyalty points
  if v_customer_id is not null and coalesce(v_store.loyalty_points_per_100,0) > 0 then
    update public.customers
       set loyalty_points = loyalty_points + floor(v_total / 100.0 * v_store.loyalty_points_per_100)::int
     where id = v_customer_id;
  end if;

  perform public.fx_audit('sale.create','sales', v_sale_id::text,
    jsonb_build_object('invoice_no', v_invoice_no, 'total', v_total, 'items', v_item_count,
                       'payment_method', v_method, 'discount', v_inv_amount + v_line_disc_total), v_device);

  return jsonb_build_object(
    'sale_id', v_sale_id, 'invoice_no', v_invoice_no, 'created_at', now(),
    'item_count', v_item_count, 'subtotal', round(v_subtotal,2),
    'line_discount_total', round(v_line_disc_total,2), 'invoice_discount_amount', round(v_inv_amount,2),
    'discount_code', v_code, 'tax_amount', round(v_tax_total,2), 'total', v_total,
    'paid_amount', round(v_paid,2), 'change_amount', v_change,
    'payment_method', v_method, 'profit', round(v_profit_total, 2),
    'cashier_name', coalesce(v_profile.full_name, v_profile.username),
    'customer_name', v_customer.name, 'device_name', v_device,
    'shift_id', v_shift_id,
    'customer_balance', v_customer.balance,
    'duplicate', false,
    'lines', v_lines,
    'store', to_jsonb(v_store));
end $$;

-- =====================================================================
--  7. VOID (cancel) AN INVOICE
-- =====================================================================
create or replace function public.void_sale(p_sale_id uuid, p_reason text, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_s public.sales; v_line record;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if coalesce(trim(p_reason),'') = '' then
    perform public.fx_fail('REASON_REQUIRED','Please give a reason for cancelling this invoice.');
  end if;

  select * into v_s from public.sales where id = p_sale_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','Invoice not found.'); end if;
  if v_s.status = 'void' then perform public.fx_fail('ALREADY_VOID','That invoice is already cancelled.'); end if;
  if v_s.refunded_amount > 0 then
    perform public.fx_fail('HAS_REFUNDS','This invoice has refunds against it — handle it with a return instead.');
  end if;

  for v_line in select * from public.sale_items where sale_id = p_sale_id loop
    insert into public.inventory_movements (product_id, qty_change, movement_type, reference_type, reference_id,
                                            unit_cost, note, device_name, created_by)
    values (v_line.product_id, v_line.qty, 'sale_void', 'sale', p_sale_id, v_line.cost_price,
            'Void ' || v_s.invoice_no, p_device, auth.uid());
  end loop;

  if v_s.customer_id is not null and v_s.payment_method = 'credit' then
    update public.customers set balance = balance - v_s.total where id = v_s.customer_id;
  end if;

  update public.sales set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
   where id = p_sale_id;

  perform public.fx_audit('sale.void','sales', p_sale_id::text,
    jsonb_build_object('invoice_no', v_s.invoice_no, 'total', v_s.total, 'reason', p_reason), p_device);

  return jsonb_build_object('ok', true, 'invoice_no', v_s.invoice_no, 'total', v_s.total, 'reason', p_reason);
end $$;

-- =====================================================================
--  8. RETURNS / REFUNDS
-- =====================================================================
create or replace function public.create_return(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sale public.sales;
  v_sale_id uuid := public.fx_uuid(p,'sale_id');
  v_return_id uuid;
  v_return_no text;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_restock boolean := public.fx_bool(p,'restock',true);
  v_method public.payment_method := coalesce(public.fx_txt(p,'refund_method'),'cash')::public.payment_method;
  v_amount numeric := 0;
  v_line jsonb;
  v_si public.sale_items;
  v_refunded numeric;
  v_status public.sale_status;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  select * into v_sale from public.sales where id = v_sale_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','That invoice does not exist.'); end if;
  if v_sale.status = 'void' then perform public.fx_fail('SALE_VOID','That invoice was cancelled, so there is nothing to return.'); end if;

  create temp table if not exists _pos_returns (sale_item_id uuid, qty numeric) on commit drop;
  delete from _pos_returns where true;
  insert into _pos_returns(sale_item_id, qty)
  select public.fx_uuid(jsonb_build_object('sale_item_id', x.sale_item_id), 'sale_item_id'), x.qty
    from jsonb_to_recordset(v_items) as x(sale_item_id text, qty numeric) where x.qty > 0;

  if not exists (select 1 from _pos_returns) then
    perform public.fx_fail('EMPTY_RETURN','Choose at least one line to return.');
  end if;

  v_return_no := public.fx_next_no(coalesce((select return_prefix from public.stores order by is_default desc, created_at limit 1),'RET'),
                                   'public.return_seq', 5);

  insert into public.returns(return_no, sale_id, invoice_no, customer_id, reason, refund_method, restocked, device_name, created_by)
  values (v_return_no, v_sale_id, v_sale.invoice_no, v_sale.customer_id, public.fx_txt(p,'reason'),
          v_method, v_restock, p_device, auth.uid())
  returning id into v_return_id;

  for v_line in select * from jsonb_array_elements(v_items) loop
    select * into v_si from public.sale_items
    where id = public.fx_uuid(jsonb_build_object('sale_item_id', v_line->>'sale_item_id'), 'sale_item_id') and sale_id = v_sale_id for update;
    if not found then
      perform public.fx_fail('BAD_LINE','A returned line does not belong to that invoice.');
    end if;

    if (v_line->>'qty')::numeric > (v_si.qty - v_si.refunded_qty) then
      perform public.fx_fail('OVER_RETURN',
        v_si.name_snapshot || ': you can return at most ' ||
        trim(to_char(v_si.qty - v_si.refunded_qty,'FM999999990.###')) || ' more.');
    end if;

    insert into public.return_items(return_id, sale_item_id, product_id, name_snapshot, qty, unit_price, line_total)
    values (v_return_id, v_si.id, v_si.product_id, v_si.name_snapshot, (v_line->>'qty')::numeric,
            v_si.unit_price, round((v_line->>'qty')::numeric * v_si.unit_price, 2));

    update public.sale_items set refunded_qty = refunded_qty + (v_line->>'qty')::numeric where id = v_si.id;

    if v_restock and v_si.product_id is not null then
      insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, reference_id,
                                             note, device_name, created_by)
      values (v_si.product_id, (v_line->>'qty')::numeric, 'refund', 'return', v_return_id,
              'Return ' || v_return_no, p_device, auth.uid());
    end if;

    v_amount := v_amount + round((v_line->>'qty')::numeric * v_si.unit_price, 2);
  end loop;

  update public.returns set refund_amount = v_amount where id = v_return_id;

  select case when sum(refunded_qty) >= sum(qty) then 'refunded'::public.sale_status
              else 'partially_refunded'::public.sale_status end
    into v_status from public.sale_items where sale_id = v_sale_id;

  update public.sales set status = v_status, refunded_amount = refunded_amount + v_amount where id = v_sale_id;

  if v_method = 'credit' and v_sale.customer_id is not null then
    update public.customers set balance = balance - v_amount where id = v_sale.customer_id;
  end if;

  perform public.fx_audit('sale.return','returns', v_return_id::text,
    jsonb_build_object('return_no', v_return_no, 'invoice_no', v_sale.invoice_no,
                       'amount', v_amount, 'restocked', v_restock), p_device);

  return jsonb_build_object('return_id', v_return_id, 'return_no', v_return_no,
    'invoice_no', v_sale.invoice_no, 'refund_amount', v_amount, 'restocked', v_restock,
    'sale_status', v_status, 'lines', v_items);
end $$;

-- =====================================================================
--  9. PURCHASES  (stock in)
-- =====================================================================
create or replace function public.receive_purchase(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_po_id uuid := public.fx_uuid(p,'id');
  v_po public.purchase_orders;
  v_supplier public.suppliers;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_subtotal numeric := 0; v_total numeric := 0; v_disc numeric := public.fx_num(p,'discount',0);
  v_tax numeric := public.fx_num(p,'tax_amount',0);
  v_qty numeric; v_cost numeric; v_sale numeric; v_new_cost numeric;
  v_po_no text;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  if jsonb_array_length(v_items) = 0 then perform public.fx_fail('EMPTY_PO','Add at least one item to the purchase.'); end if;

  select * into v_supplier from public.suppliers where id = public.fx_uuid(p,'supplier_id');
  if not found then perform public.fx_fail('NOT_FOUND','Supplier not found.'); end if;

  v_po_no := coalesce(public.fx_txt(p,'po_no'),
    public.fx_next_no(coalesce((select po_prefix from public.stores order by is_default desc, created_at limit 1),'PO'),
                      'public.po_seq', 5));

  create temp table if not exists _po_lines (
    product_id uuid, qty numeric, unit_cost numeric, sale_price numeric, line_total numeric) on commit drop;
  delete from _po_lines where true;
  insert into _po_lines(product_id, qty, unit_cost, sale_price, line_total)
  select case
           when trim(coalesce(x.product_id,'')) = '' then null
           when trim(coalesce(x.product_id,'')) !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then null
           else trim(x.product_id)::uuid
         end,
         x.qty, x.unit_cost, x.sale_price, round(x.qty * x.unit_cost, 2)
    from jsonb_to_recordset(v_items) as x(product_id text, qty numeric, unit_cost numeric, sale_price numeric);

  v_subtotal := (select coalesce(sum(line_total),0) from _po_lines);
  v_total := round(v_subtotal - v_disc + v_tax, 2);

  insert into public.purchase_orders(po_no, supplier_id, supplier_name, status, order_date, expected_date,
    received_at, received_by, subtotal, discount, tax_amount, total, paid_amount, payment_method, invoice_ref, note, created_by)
  values (v_po_no, v_supplier.id, v_supplier.name, 'received',
          public.fx_date(p,'order_date', current_date),
          public.fx_date(p,'expected_date'), now(), auth.uid(),
          v_subtotal, v_disc, v_tax, v_total, public.fx_num(p,'paid_amount',0), 
          coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
          public.fx_txt(p,'invoice_ref'), public.fx_txt(p,'note'), auth.uid())
  returning * into v_po;

  if exists (select 1 from _po_lines where qty is null or qty <= 0 or product_id is null) then
    perform public.fx_fail('BAD_QTY','Every purchase line needs a product and a quantity greater than zero.');
  end if;

  -- item rows + stock-in movements
  insert into public.purchase_items(purchase_id, product_id, name_snapshot, qty_ordered, qty_received, unit_cost, line_total)
  select v_po.id, l.product_id, pr.name, l.qty, l.qty, l.unit_cost, l.line_total
    from _po_lines l join public.products pr on pr.id = l.product_id;

  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, reference_id,
                                         unit_cost, note, device_name, created_by)
  select l.product_id, l.qty, 'purchase', 'purchase_order', v_po.id, l.unit_cost,
         'PO ' || v_po_no, p_device, auth.uid()
    from _po_lines l;

  -- weighted-average cost, and optional new retail price
  update public.products pr set
    cost_price = case
      when pr.stock_qty - l.qty > 0
        then round(((pr.cost_price * (pr.stock_qty - l.qty)) + (l.unit_cost * l.qty)) / pr.stock_qty, 2)
      else l.unit_cost end,
    sale_price = coalesce(l.sale_price, pr.sale_price),
    supplier_id = coalesce(v_supplier.id, pr.supplier_id),
    updated_by = auth.uid()
    from _po_lines l
   where pr.id = l.product_id;

  perform public.fx_audit('purchase.receive','purchase_orders', v_po.id::text,
    jsonb_build_object('po_no', v_po_no, 'supplier', v_supplier.name, 'total', v_total), p_device);

  return jsonb_build_object('purchase_id', v_po.id, 'po_no', v_po_no, 'supplier_name', v_supplier.name,
    'subtotal', v_subtotal, 'discount', v_disc, 'tax_amount', v_tax, 'total', v_total,
    'item_count', (select count(*) from _po_lines), 'unpaid', round(v_total - public.fx_num(p,'paid_amount',0), 2));
end $$;

-- =====================================================================
--  9b. PURCHASE ORDER LIST  (the read side of receive_purchase)
--      The till must not read purchase_orders directly: this returns the
--      supplier name, how many items were booked in and what is still
--      unpaid, already filtered by role.
-- =====================================================================
create or replace function public.purchases(p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id',            po.id,
               'po_no',         po.po_no,
               'supplier_name', po.supplier_name,
               'status',        po.status,
               'order_date',    po.order_date,
               'created_at',    po.created_at,
               'subtotal',      po.subtotal,
               'discount',      po.discount,
               'tax_amount',    po.tax_amount,
               'total',         po.total,
               'paid_amount',   po.paid_amount,
               'unpaid',        round(po.total - po.paid_amount, 2),
               'item_count',    (select count(*) from public.purchase_items pi where pi.purchase_id = po.id)
             ) as x
        from public.purchase_orders po
       order by po.created_at desc
       limit greatest(1, least(coalesce(p_limit, 200), 1000))
    ) s;

  return v_rows;
end $$;

-- =====================================================================
--  10. EXPENSES
-- =====================================================================
create or replace function public.save_expense(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.expenses; v_amount numeric := public.fx_num(p,'amount',0);
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_amount <= 0 then perform public.fx_fail('BAD_AMOUNT','Expense amount must be greater than zero.'); end if;

  insert into public.expenses(category, description, amount, payment_method, shift_id, reference_no, created_by)
  values (coalesce(public.fx_txt(p,'category'),'General'), public.fx_txt(p,'description'), v_amount,
          coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
          public.fx_uuid(p,'shift_id'), public.fx_txt(p,'reference_no'), auth.uid())
  returning * into v_row;

  perform public.fx_audit('expense.save','expenses', v_row.id::text,
    jsonb_build_object('category', v_row.category, 'amount', v_row.amount), p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  11. EMPLOYEES / STAFF  (Super Admin only)
-- =====================================================================
create or replace function public.save_employee(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.profiles;
  v_role public.user_role := coalesce(public.fx_txt(p,'role'),'cashier')::public.user_role;
  v_me uuid := auth.uid();
begin
  perform public.fx_require_role(array['super_admin']);
  if v_id is null then
    perform public.fx_fail('NEED_LOGIN',
      'Create the login first (Admin > Employees > Add login), then set the job details here.');
  end if;

  -- never let the last super admin lock everyone out
  if v_id = v_me and (v_role <> 'super_admin' or public.fx_bool(p,'is_active',true) = false) then
    perform public.fx_fail('LAST_ADMIN','You cannot remove your own Super Admin access.');
  end if;

  update public.profiles set
    full_name = coalesce(public.fx_txt(p,'full_name'), full_name),
    phone = public.fx_txt(p,'phone'),
    username = coalesce(public.fx_txt(p,'username'), username),
    role = v_role,
    is_active = public.fx_bool(p,'is_active',true),
    max_discount_percent = coalesce(nullif(public.fx_txt(p,'max_discount_percent'),'')::numeric,
                                    max_discount_percent),
    hired_on = public.fx_date(p,'hired_on'),
    salary = nullif(public.fx_txt(p,'salary'),'')::numeric,
    emergency_contact = public.fx_txt(p,'emergency_contact'),
    notes = public.fx_txt(p,'notes')
   where id = v_id
  returning * into v_row;

  if not found then perform public.fx_fail('NOT_FOUND','Employee not found.'); end if;

  perform public.fx_audit('employee.save','profiles', v_id::text,
    jsonb_build_object('role', v_row.role, 'active', v_row.is_active, 'max_discount', v_row.max_discount_percent), p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  12. STORE SETTINGS  (Super Admin only)
-- =====================================================================
create or replace function public.save_store_settings(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.stores; v_id uuid := public.fx_uuid(p,'id');
begin
  perform public.fx_require_role(array['super_admin']);

  if v_id is null then
    select id into v_id
      from public.stores
     where is_default = true
     order by created_at desc
     limit 1;
  end if;
  if v_id is null then
    select id into v_id from public.stores order by created_at desc limit 1;
  end if;
  if v_id is null then perform public.fx_fail('NOT_FOUND','Store settings not found.'); end if;

  update public.stores set
    name = coalesce(public.fx_txt(p,'name'), name),
    legal_name = public.fx_txt(p,'legal_name'),
    address = public.fx_txt(p,'address'),
    phone = public.fx_txt(p,'phone'),
    email = public.fx_txt(p,'email'),
    ntn = public.fx_txt(p,'ntn'),
    currency_code = coalesce(public.fx_txt(p,'currency_code'), currency_code),
    currency_symbol = coalesce(public.fx_txt(p,'currency_symbol'), currency_symbol),
    tax_percent = public.fx_num(p,'tax_percent', tax_percent),
    tax_inclusive = public.fx_bool(p,'tax_inclusive', tax_inclusive),
    tax_label = coalesce(public.fx_txt(p,'tax_label'), tax_label),
    invoice_prefix = coalesce(public.fx_txt(p,'invoice_prefix'), invoice_prefix),
    po_prefix = coalesce(public.fx_txt(p,'po_prefix'), po_prefix),
    return_prefix = coalesce(public.fx_txt(p,'return_prefix'), return_prefix),
    receipt_header = public.fx_txt(p,'receipt_header'),
    receipt_footer = coalesce(public.fx_txt(p,'receipt_footer'), receipt_footer),
    receipt_paper_mm = coalesce(nullif(public.fx_txt(p,'receipt_paper_mm'),'')::int, receipt_paper_mm),
    print_logo = public.fx_bool(p,'print_logo', print_logo),
    max_cashier_discount_percent = public.fx_num(p,'max_cashier_discount_percent', max_cashier_discount_percent),
    allow_price_override = public.fx_bool(p,'allow_price_override', allow_price_override),
    allow_negative_stock = public.fx_bool(p,'allow_negative_stock', allow_negative_stock),
    loyalty_points_per_100 = public.fx_num(p,'loyalty_points_per_100', loyalty_points_per_100)
   where id = v_id
  returning * into v_row;

  perform public.fx_audit('store.settings','stores', v_row.id::text, to_jsonb(v_row), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.reset_demo_data(p_confirm text, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.fx_require_role(array['super_admin']);
  if p_confirm <> 'DELETE-ALL-SALES' then
    perform public.fx_fail('BAD_CONFIRM','Type DELETE-ALL-SALES exactly to confirm.');
  end if;
  delete from public.return_items; delete from public.returns;
  delete from public.sale_items;  delete from public.sales;
  delete from public.inventory_movements where movement_type <> 'opening';
  delete from public.expenses; delete from public.shifts;
  perform public.fx_audit('data.reset','all', null, '{}'::jsonb, p_device);
  return jsonb_build_object('ok', true);
end $$;

-- =====================================================================
--  13. DASHBOARD + REPORTS
-- =====================================================================
create or replace function public.dashboard_stats(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_today date := current_date;
  v_store public.stores;
  v_res jsonb;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select * into v_store from public.stores order by is_default desc, created_at limit 1;

  select jsonb_build_object(
    'role', public.fx_role(),
    'today', coalesce((select to_jsonb(x) from (
        select count(*) as invoice_count, coalesce(sum(total),0) as sales,
               coalesce(sum(profit),0) as profit, coalesce(sum(item_count),0) as items,
               coalesce(sum(case when payment_method='cash' then total else 0 end),0) as cash,
               coalesce(sum(refunded_amount),0) as refunds
          from public.sales where status <> 'void' and created_at::date = v_today) x),
      jsonb_build_object('invoice_count',0,'sales',0,'profit',0,'items',0,'cash',0,'refunds',0)),
    'month', coalesce((select to_jsonb(x) from (
        select count(*) as invoice_count, coalesce(sum(total),0) as sales,
               coalesce(sum(profit),0) as profit
          from public.sales where status <> 'void' and created_at >= date_trunc('month', now())) x),
      jsonb_build_object('invoice_count',0,'sales',0,'profit',0)),
    'expenses_today', coalesce((select sum(amount) from public.expenses where spent_at::date = v_today), 0),
    'stock_value', coalesce((select sum(stock_qty * cost_price) from public.products where is_deleted = false), 0),
    'stock_retail', coalesce((select sum(stock_qty * sale_price) from public.products where is_deleted = false), 0),
    'product_count', (select count(*) from public.products where is_deleted = false and is_active),
    'low_stock_count', (select count(*) from public.products where is_deleted = false and is_active and stock_qty <= reorder_level),
    'out_of_stock_count', (select count(*) from public.products where is_deleted = false and is_active and stock_qty <= 0),
    'customer_debt', coalesce((select sum(balance) from public.customers where balance > 0), 0),
    'cashier_today', coalesce((select to_jsonb(x) from (
        select coalesce(sum(total),0) as sales, count(*) as invoices
          from public.sales where cashier_id = auth.uid() and status <> 'void' and created_at::date = v_today) x),
      jsonb_build_object('sales',0,'invoices',0)),
    'open_shifts', coalesce((select jsonb_agg(jsonb_build_object(
        'shift_no', s.shift_no, 'cashier', p.full_name, 'device', s.device_name, 'opened_at', s.opened_at))
        from public.shifts s join public.profiles p on p.id = s.cashier_id
        where s.status = 'open'
          and (public.fx_is_manager() or s.cashier_id = auth.uid())), '[]'::jsonb),
    'devices', coalesce((select jsonb_agg(jsonb_build_object(
        'name', d.name, 'terminal_no', d.terminal_no, 'last_seen', d.last_seen,
        'minutes_ago', round(extract(epoch from (now() - d.last_seen))/60)))
        from public.devices d where d.is_active), '[]'::jsonb),
    'sales_series', coalesce((select jsonb_agg(jsonb_build_object('d', d::date, 'sales', coalesce(v,0)))
        from generate_series(v_today - (p_days - 1), v_today, interval '1 day') d
        left join (select created_at::date as dd, sum(total) as v from public.sales
                    where status <> 'void' and created_at >= v_today - (p_days - 1)
                      and (public.fx_is_manager() or cashier_id = auth.uid())
                    group by 1) s on s.dd = d::date), '[]'::jsonb),
    'top_products_today', coalesce((select jsonb_agg(t) from (
        select si.name_snapshot as name, sum(si.qty) as qty, sum(si.line_total) as amount
          from public.sale_items si join public.sales s on s.id = si.sale_id
         where s.status <> 'void' and s.created_at::date = v_today
           and (public.fx_is_manager() or s.cashier_id = auth.uid())
         group by 1 order by 3 desc limit 5) t), '[]'::jsonb),
    'recent_sales', coalesce((select jsonb_agg(t) from (
        select s.invoice_no, s.created_at, s.total, s.payment_method, s.cashier_name, s.status
          from public.sales s
         where (public.fx_is_manager() or s.cashier_id = auth.uid())
         order by s.created_at desc limit 8) t), '[]'::jsonb),
    'low_stock_sample', coalesce((select jsonb_agg(t) from (
        select p.name, p.stock_qty, p.reorder_level, p.unit
          from public.products p
         where p.is_deleted = false and p.is_active and p.stock_qty <= p.reorder_level
         order by p.stock_qty asc limit 8) t), '[]'::jsonb),
    'store_name', v_store.name,
    'currency_symbol', v_store.currency_symbol
  ) into v_res;

  return v_res;
end $$;

create or replace function public.sales_report(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  return jsonb_build_object(
    'from', p_from, 'to', p_to,

    'totals', coalesce((select to_jsonb(x) from (
        select count(*) as invoice_count, coalesce(sum(total),0) as sales,
               coalesce(sum(line_discount_total + invoice_discount_amount),0) as discounts,
               coalesce(sum(tax_amount),0) as tax, coalesce(sum(cost_total),0) as cost,
               coalesce(sum(profit),0) as profit, coalesce(sum(refunded_amount),0) as refunds,
               coalesce(round(avg(total),2),0) as avg_basket
          from public.sales where status <> 'void' and created_at::date between p_from and p_to) x),
      jsonb_build_object('invoice_count',0,'sales',0,'discounts',0,'tax',0,'cost',0,
                         'profit',0,'refunds',0,'avg_basket',0)),

    'daily', coalesce((select jsonb_agg(jsonb_build_object(
                 'day', d, 'sales', s, 'profit', pf, 'invoices', c, 'items', it) order by d) from (
        select created_at::date as d, sum(total) as s, sum(profit) as pf,
               count(*) as c, sum(item_count) as it
          from public.sales where status <> 'void' and created_at::date between p_from and p_to
         group by created_at::date) t), '[]'::jsonb),

    'by_payment', coalesce((select jsonb_agg(jsonb_build_object(
                 'method', m, 'amount', amt, 'invoices', c) order by amt desc) from (
        select payment_method as m, sum(total) as amt, count(*) as c
          from public.sales where status <> 'void' and created_at::date between p_from and p_to
         group by payment_method) t), '[]'::jsonb),

    'by_cashier', coalesce((select jsonb_agg(jsonb_build_object(
                 'cashier', csh, 'sales', amt, 'invoices', c, 'profit', pf) order by amt desc) from (
        select cashier_name as csh, sum(total) as amt, count(*) as c, sum(profit) as pf
          from public.sales where status <> 'void' and created_at::date between p_from and p_to
         group by cashier_name) t), '[]'::jsonb),

    'by_device', coalesce((select jsonb_agg(jsonb_build_object(
                 'device', dev, 'sales', amt, 'invoices', c) order by amt desc) from (
        select coalesce(device_name,'(unassigned)') as dev, sum(total) as amt, count(*) as c
          from public.sales where status <> 'void' and created_at::date between p_from and p_to
         group by 1) t), '[]'::jsonb),

    'top_products', coalesce((select jsonb_agg(jsonb_build_object(
                 'name', nm, 'qty', q, 'amount', amt, 'profit', pf) order by amt desc) from (
        select si.name_snapshot as nm, sum(si.qty) as q, sum(si.line_total) as amt,
               sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end) as pf
          from public.sale_items si join public.sales s on s.id = si.sale_id
         where s.status <> 'void' and s.created_at::date between p_from and p_to
         group by si.name_snapshot
         order by sum(si.line_total) desc limit 25) t), '[]'::jsonb),

    'by_category', coalesce((select jsonb_agg(jsonb_build_object(
                 'category', cat, 'amount', amt, 'qty', q) order by amt desc) from (
        select coalesce(c.name,'Uncategorised') as cat, sum(si.line_total) as amt, sum(si.qty) as q
          from public.sale_items si
          join public.sales s on s.id = si.sale_id
          left join public.products p on p.id = si.product_id
          left join public.categories c on c.id = p.category_id
         where s.status <> 'void' and s.created_at::date between p_from and p_to
         group by 1) t), '[]'::jsonb),

    'inventory', coalesce((select to_jsonb(x) from (
        select coalesce(sum(stock_qty * cost_price),0) as stock_at_cost,
               coalesce(sum(stock_qty * sale_price),0) as stock_at_retail,
               count(*) filter (where stock_qty <= reorder_level) as low_stock,
               count(*) filter (where stock_qty <= 0) as out_of_stock
          from public.products where is_deleted = false) x),
      jsonb_build_object('stock_at_cost',0,'stock_at_retail',0,'low_stock',0,'out_of_stock',0)),

    'hourly', coalesce((select jsonb_agg(jsonb_build_object('hour', h, 'sales', amt) order by h) from (
        select extract(hour from created_at)::int as h, sum(total) as amt
          from public.sales where status <> 'void' and created_at::date between p_from and p_to
         group by 1) t), '[]'::jsonb),

    'refunds', coalesce((select jsonb_agg(jsonb_build_object(
                 'return_no', r.return_no, 'invoice_no', r.invoice_no, 'amount', r.refund_amount,
                 'reason', r.reason, 'at', r.created_at) order by r.created_at desc) from (
        select * from public.returns where created_at::date between p_from and p_to limit 50) r), '[]'::jsonb));
end $$;

-- =====================================================================
--  SECTION: 04_rls_policies.sql
-- =====================================================================
-- =====================================================================
--  SUPERMART POS  --  04 : ROW LEVEL SECURITY
--  Run AFTER 03_rpc_api.sql
--
--  Design:  the app has SELECT access only. Every INSERT / UPDATE / DELETE
--  happens inside a SECURITY DEFINER function that checked the caller's role
--  first. So even if someone got hold of your anon key, they could not change
--  a price, delete an invoice or edit stock. RLS then decides which ROWS each
--  signed-in PC is allowed to read.
-- =====================================================================

-- ---------------------------------------------------------------------
--  Keep everything in the realtime publication so the 4 PCs update live
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['stock_levels','products','sales','sale_items','devices','shifts',
                           'discounts','customers','inventory_movements','purchase_orders','returns','categories',
                           'price_tiers']
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
               when undefined_object then null;
               when undefined_table then null;
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  Turn RLS on everywhere
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['stores','profiles','devices','categories','suppliers','customers','products',
                           'stock_levels','inventory_movements','shifts','sales','sale_items',
                           'purchase_orders','purchase_items','returns','return_items','discounts',
                           'expenses','audit_logs','app_settings','price_tiers']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  Helper to (re)create a policy without errors on re-run
-- ---------------------------------------------------------------------
create or replace function public.fx_drop_policy(p_table text, p_policy text)
returns void language plpgsql as $$
begin
  execute format('drop policy if exists %I on public.%I', p_policy, p_table);
end $$;

-- =======================  READ POLICIES  =============================

-- STORE SETTINGS: every signed-in till may read (receipt needs the name/address)
select public.fx_drop_policy('stores','stores_read');
create policy stores_read on public.stores for select to authenticated
  using (public.fx_is_staff());

-- STAFF DIRECTORY: your own row, or everything if you are an admin
select public.fx_drop_policy('profiles','profiles_read');
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.fx_is_admin());

-- DEVICES: everyone sees which tills are online
select public.fx_drop_policy('devices','devices_read');
create policy devices_read on public.devices for select to authenticated
  using (public.fx_is_staff());

-- CATEGORIES: everyone (the POS groups items by category)
select public.fx_drop_policy('categories','categories_read');
create policy categories_read on public.categories for select to authenticated
  using (public.fx_is_staff());

-- STOCK MIRROR: the one catalogue table a cashier may read.
-- It stays cost-free for the generic POS catalogue, while product-level reads can
-- include cost_price for cashier profit visibility in the cart.
select public.fx_drop_policy('stock_levels','stock_levels_read');
create policy stock_levels_read on public.stock_levels for select to authenticated
  using (public.fx_is_staff());

-- PRODUCTS: staff can read the full product row, including cost price,
-- so cashier carts can show actual cost and profit on hover.
select public.fx_drop_policy('products','products_read_managers');
create policy products_read_managers on public.products for select to authenticated
  using (public.fx_is_staff());

-- PRICE TIERS: signed-in staff need to see quantity discount rules in the app and POS
select public.fx_drop_policy('price_tiers','price_tiers_read');
create policy price_tiers_read on public.price_tiers for select to authenticated
  using (public.fx_is_staff());

-- CUSTOMERS: cashiers need them for udhaar / loyalty
select public.fx_drop_policy('customers','customers_read');
create policy customers_read on public.customers for select to authenticated
  using (public.fx_is_staff());

-- SUPPLIERS: managers and above
select public.fx_drop_policy('suppliers','suppliers_read');
create policy suppliers_read on public.suppliers for select to authenticated
  using (public.fx_is_manager());

-- DISCOUNTS: the POS may see the ones live right now; admins see all
select public.fx_drop_policy('discounts','discounts_read_live');
create policy discounts_read_live on public.discounts for select to authenticated
  using (public.fx_is_staff() and is_active
         and starts_at <= now() and (ends_at is null or ends_at >= now()));

select public.fx_drop_policy('discounts','discounts_read_admin');
create policy discounts_read_admin on public.discounts for select to authenticated
  using (public.fx_is_admin());

-- SHIFTS: your own shift, or all of them if you are a manager
select public.fx_drop_policy('shifts','shifts_read');
create policy shifts_read on public.shifts for select to authenticated
  using (cashier_id = auth.uid() or public.fx_is_manager());

-- SALES: a cashier sees their own receipts; managers see everything
select public.fx_drop_policy('sales','sales_read');
create policy sales_read on public.sales for select to authenticated
  using (cashier_id = auth.uid() or public.fx_is_manager());

select public.fx_drop_policy('sale_items','sale_items_read');
create policy sale_items_read on public.sale_items for select to authenticated
  using (exists (select 1 from public.sales s where s.id = sale_id
                  and (s.cashier_id = auth.uid() or public.fx_is_manager())));

-- INVENTORY MOVEMENTS: managers, plus your own entries
select public.fx_drop_policy('inventory_movements','movements_read');
create policy movements_read on public.inventory_movements for select to authenticated
  using (public.fx_is_manager() or created_by = auth.uid());

-- PURCHASING / RETURNS / EXPENSES: managers and above
select public.fx_drop_policy('purchase_orders','po_read');
create policy po_read on public.purchase_orders for select to authenticated
  using (public.fx_is_manager());

select public.fx_drop_policy('purchase_items','po_items_read');
create policy po_items_read on public.purchase_items for select to authenticated
  using (public.fx_is_manager());

select public.fx_drop_policy('returns','returns_read');
create policy returns_read on public.returns for select to authenticated
  using (public.fx_is_manager());

select public.fx_drop_policy('return_items','return_items_read');
create policy return_items_read on public.return_items for select to authenticated
  using (public.fx_is_manager());

select public.fx_drop_policy('expenses','expenses_read');
create policy expenses_read on public.expenses for select to authenticated
  using (public.fx_is_manager());

-- AUDIT LOG: admins only -- this is the record of who did what
select public.fx_drop_policy('audit_logs','audit_read');
create policy audit_read on public.audit_logs for select to authenticated
  using (public.fx_is_admin());

select public.fx_drop_policy('app_settings','app_settings_read');
create policy app_settings_read on public.app_settings for select to authenticated
  using (public.fx_is_admin());

-- =====================================================================
--  NO INSERT / UPDATE / DELETE POLICIES ON PURPOSE.
--  With RLS enabled and no write policy, direct writes are refused for
--  every client role. The RPCs (SECURITY DEFINER) are the only way in.
-- =====================================================================

-- =====================================================================
--  GRANTS
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['stores','profiles','devices','categories','suppliers','customers','products',
                           'stock_levels','inventory_movements','shifts','sales','sale_items',
                           'purchase_orders','purchase_items','returns','return_items','discounts',
                           'expenses','audit_logs','app_settings','price_tiers',
                           'v_products_pos','v_products_admin','v_low_stock','v_sales_list',
                           'v_daily_sales','v_stock_valuation','v_stock_movements','v_returns_list']
  loop
    execute format('revoke all on public.%I from anon', t);
    begin
      execute format('grant select on public.%I to authenticated', t);
    exception when undefined_table then null;
    end;
    begin
      execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated', t);
    exception when undefined_table then null; when wrong_object_type then null;
    end;
  end loop;
end $$;

-- functions: signed-in staff only, never the anonymous role
revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
grant execute on all functions in schema public to authenticated;

-- future objects created on the Supabase project inherit the same rules
alter default privileges in schema public grant select on tables to authenticated;
alter default privileges in schema public grant execute on functions to authenticated;

-- realtime needs the subscription to be allowed to read the row it broadcasts
grant select on public.stock_levels, public.sales, public.sale_items, public.devices,
                 public.shifts, public.discounts, public.customers, public.products,
                 public.inventory_movements, public.categories, public.price_tiers to authenticated;

-- =====================================================================
--  SECTION: your real shop (NO demo products)
-- =====================================================================
--  >>> EDIT THESE 5 LINES to your real shop details before running, or change
--  >>> them later in the app: Super Admin > Settings.
insert into public.stores (is_default, name, legal_name, address, phone, currency_code, currency_symbol,
                           tax_percent, tax_label, receipt_footer, allow_negative_stock)
select true, 'My Supermart', 'My Supermart', 'My Shop Address, City', '0300-0000000', 'PKR', 'Rs',
       0, 'GST', 'Thank you for shopping with us!  Please come again.', false
where not exists (select 1 from public.stores);

-- Create a minimal empty category template so the app has a valid hierarchy
-- before the Excel import fills in real categories/subcategories.
-- The actual category and subcategory rows are still populated from the Excel
-- data during import, but the database starts with a clean empty structure.
do $$
begin
  if not exists (select 1 from public.categories where lower(trim(name)) = 'template' and parent_id is null) then
    insert into public.categories(name, description, parent_id, sort_order, is_active)
    values ('Template', 'Empty template category for Excel import.', null, 1, true);
  end if;

  if not exists (
    select 1
    from public.categories c
    where lower(trim(c.name)) = 'template'
      and c.parent_id is not null
  ) then
    insert into public.categories(name, description, parent_id, sort_order, is_active)
    select 'Template', 'Empty template subcategory for Excel import.', c.id, 1, true
    from public.categories c
    where lower(trim(c.name)) = 'template' and c.parent_id is null
    limit 1;
  end if;
end $$;

-- App settings (safe defaults, same shape the app already uses)
insert into public.app_settings(key, value) values
  ('pos', '{"receipt_copies":1,"auto_print":true,"barcode_beep":true,"quick_cash":[100,500,1000,5000]}'::jsonb),
  ('low_stock_alert', '{"enabled":true,"notify_managers":true}'::jsonb)
on conflict (key) do nothing;

-- #####################################################################
--  OPTIONAL CLEAN RESET (only when you want to wipe the app before install)
--  Run this block in Supabase SQL Editor before the main setup file if you
--  want a completely clean database. Do NOT use DROP SCHEMA PUBLIC CASCADE.
-- #####################################################################
-- do $$
-- declare
--   r record;
-- begin
--   for r in
--     select table_schema, table_name
--     from information_schema.tables
--     where table_schema = 'public'
--       and table_type = 'BASE TABLE'
--   loop
--     execute format('truncate table %I.%I restart identity cascade', r.table_schema, r.table_name);
--   end loop;
-- end $$;
--
-- delete from auth.users;
-- delete from storage.objects;
-- delete from storage.buckets;
-- #####################################################################

-- #####################################################################
--  PART 7 of 7 - BIG SUPERMARKET MODULE
--  Batches & expiry dates, quantity price tiers, buy-X-get-Y offers,
--  gift vouchers / store credit, returns to supplier, and the owner
--  reports (profit per product, cashier scoreboard, dead stock).
--  Safe to run again: every statement checks before it changes anything.
-- #####################################################################

-- #####################################################################
--  SUPERMART POS  --  SECTION 07: SUPERMARKET MODULE
--
--  The "big store" layer on top of 00-06. Everything here is additive and
--  safe to run on an existing shop (run it AFTER 06_operations.sql):
--
--    * batch + expiry tracking (goods received with a batch and an expiry date,
--      first-expire-first-out, expiry report, write-off of damaged/expired stock)
--    * quantity price tiers  (3 kg retail price vs 25 kg sack price)
--    * offers                (buy X get Y free, per product or per category)
--    * gift vouchers / store credit  (issue, redeem at the till, cancel)
--    * purchase returns to supplier  (damaged/expired goods back, payable down)
--    * buyer reports         (profit per product, cashier performance, dead stock)
--
--  Nothing that already worked is removed: the functions below are the same
--  proven ones from 03/06 with fields and branches added.
--  Safe to run more than once.
--  #####################################################################

-- a movement type for goods going back to the supplier (added to the enum;
-- harmless when the shop was installed from 00 of this version already)
do $$ begin
  alter type public.movement_type add value if not exists 'return_supplier';
exception when others then null; end $$;

-- =====================================================================
--  1. SCHEMA - new columns (all optional, so an existing shop keeps working)
-- =====================================================================
alter table public.products   add column if not exists wholesale_min_qty numeric(12,3) not null default 0;
alter table public.products   add column if not exists plu_code          text;
alter table public.products   add column if not exists is_expiry_tracked boolean not null default false;
alter table public.products   add column if not exists last_cost         numeric(12,2);
alter table public.products   add column if not exists last_sold_at      timestamptz;
alter table public.products   add column if not exists country_of_origin text;

alter table public.customers  add column if not exists cnic              text;
alter table public.customers  add column if not exists card_no           text;
alter table public.customers  add column if not exists area              text;

alter table public.profiles   add column if not exists cnic              text;
alter table public.profiles   add column if not exists address           text;
alter table public.profiles   add column if not exists designation       text;

alter table public.suppliers  add column if not exists credit_days       int not null default 0;
alter table public.suppliers  add column if not exists bank_name         text;
alter table public.suppliers  add column if not exists bank_account      text;
alter table public.suppliers  add column if not exists supplier_code     text;

alter table public.stores     add column if not exists expiry_alert_days int not null default 30;
alter table public.stores     add column if not exists block_expired_sales boolean not null default false;
alter table public.stores     add column if not exists enable_batches    boolean not null default true;
alter table public.stores     add column if not exists require_expiry    boolean not null default false;
alter table public.stores     add column if not exists enable_tiers      boolean not null default true;
alter table public.stores     add column if not exists enable_offers     boolean not null default true;
alter table public.stores     add column if not exists enable_vouchers   boolean not null default true;
alter table public.stores     add column if not exists invoice_note      text;
alter table public.stores     add column if not exists terms_and_conditions text;

alter table public.sales      add column if not exists voucher_code      text;
alter table public.sales      add column if not exists voucher_amount    numeric(12,2) not null default 0;

-- =====================================================================
--  2. SCHEMA - new tables
-- =====================================================================

-- Every delivery can arrive in batches, each with its own expiry date. The
-- shop sells from the batch that expires first (first-expire-first-out) and can
-- see what is about to go out of date before it is too late.
create table if not exists public.product_batches (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products(id) on delete cascade,
  batch_no     text,
  mfg_date     date,
  expiry_date  date,
  qty_received numeric(12,3) not null default 0,
  qty_remaining numeric(12,3) not null default 0,
  unit_cost    numeric(12,2) not null default 0,
  supplier_id  uuid references public.suppliers(id) on delete set null,
  purchase_id  uuid references public.purchase_orders(id) on delete set null,
  note         text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index if not exists product_batches_product_idx on public.product_batches(product_id);
create index if not exists product_batches_expiry_idx  on public.product_batches(expiry_date);
create index if not exists product_batches_open_idx    on public.product_batches(product_id, expiry_date)
  where qty_remaining > 0;

-- buy X get Y free, per product or per whole category
create table if not exists public.offers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  product_id  uuid references public.products(id) on delete cascade,
  category_id uuid references public.categories(id) on delete cascade,
  buy_qty     numeric(12,3) not null default 1,
  free_qty    numeric(12,3) not null default 1,
  starts_on   date,
  ends_on     date,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists offers_active_idx on public.offers(is_active, starts_on, ends_on);

-- gift vouchers / store credit: money the shop already holds
create table if not exists public.vouchers (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  kind         text not null default 'gift',           -- gift | store_credit
  value        numeric(12,2) not null default 0,
  balance      numeric(12,2) not null default 0,
  customer_id  uuid references public.customers(id) on delete set null,
  issued_to    text,
  phone        text,
  reason       text,
  expires_on   date,
  is_active    boolean not null default true,
  last_used_at timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid
);

create table if not exists public.voucher_redemptions (
  id         uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.vouchers(id) on delete cascade,
  sale_id    uuid references public.sales(id) on delete set null,
  return_id  uuid,
  invoice_no text,
  amount     numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid
);

-- goods going back to the supplier (damaged, expired, wrong item)
create table if not exists public.purchase_returns (
  id            uuid primary key default gen_random_uuid(),
  return_no     text not null unique,
  supplier_id   uuid references public.suppliers(id) on delete set null,
  supplier_name text,
  purchase_id   uuid references public.purchase_orders(id) on delete set null,
  reason        text,
  note          text,
  total         numeric(12,2) not null default 0,
  settled_by    text not null default 'payable',    -- payable | cash | replacement
  created_at    timestamptz not null default now(),
  created_by    uuid
);

create table if not exists public.purchase_return_items (
  id            uuid primary key default gen_random_uuid(),
  return_id     uuid not null references public.purchase_returns(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete cascade,
  name_snapshot text,
  batch_id      uuid references public.product_batches(id) on delete set null,
  expiry_date   date,
  qty           numeric(12,3) not null default 0,
  unit_cost     numeric(12,2) not null default 0,
  line_total    numeric(12,2) not null default 0,
  reason        text
);
create index if not exists purchase_return_items_ret_idx on public.purchase_return_items(return_id);

-- =====================================================================
--  3. PRODUCTS, CUSTOMERS, SUPPLIERS, EMPLOYEES - extra fields on save
--     (same proven functions, just more columns understood)
-- =====================================================================
create or replace function public.save_product(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.products;
  v_barcode text := public.fx_txt(p,'barcode');
  v_sku text := public.fx_txt(p,'sku');
  v_opening numeric := public.fx_num(p,'opening_stock',0);
  v_expiry date := public.fx_date(p,'expiry_date');
  v_mfg date := public.fx_date(p,'mfg_date');
  v_batch text := nullif(public.fx_txt(p,'batch_no'), '');
  v_category_name text := trim(public.fx_txt(p,'category_name'));
  v_subcategory_name text := trim(public.fx_txt(p,'subcategory_name'));
  v_supplier_name text := trim(public.fx_txt(p,'supplier_name'));
  v_category_id uuid := public.fx_uuid(p,'category_id');
  v_supplier_id uuid := public.fx_uuid(p,'supplier_id');
  v_parent_id uuid := null;
  v_subcategory_id uuid := null;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  if v_category_name is not null and v_category_name <> '' then
    select c.id into v_parent_id
    from public.categories c
    where lower(trim(c.name)) = lower(v_category_name) and c.parent_id is null
    limit 1;

    if v_parent_id is null then
      insert into public.categories(name, description, parent_id, sort_order, is_active)
      values (v_category_name, public.fx_txt(p,'category_description'), null, 0, true)
      returning id into v_parent_id;
    end if;
  end if;

  if v_subcategory_name is not null and v_subcategory_name <> '' then
    if v_category_name is not null and v_category_name <> '' then
      select c.id into v_subcategory_id
      from public.categories c
      where lower(trim(c.name)) = lower(v_subcategory_name)
        and c.parent_id = v_parent_id
      limit 1;
    else
      select c.id into v_subcategory_id
      from public.categories c
      where lower(trim(c.name)) = lower(v_subcategory_name)
        and c.parent_id is null
      limit 1;
    end if;

    if v_subcategory_id is null then
      insert into public.categories(name, description, parent_id, sort_order, is_active)
      values (v_subcategory_name, public.fx_txt(p,'subcategory_description'), v_parent_id, 0, true)
      returning id into v_subcategory_id;
    end if;

    v_category_id := v_subcategory_id;
  elsif v_category_id is null and v_category_name is not null and v_category_name <> '' then
    v_category_id := v_parent_id;
  end if;

  if v_supplier_id is null and v_supplier_name is not null and v_supplier_name <> '' then
    select s.id into v_supplier_id
    from public.suppliers s
    where lower(trim(s.name)) = lower(v_supplier_name)
    limit 1;

    if v_supplier_id is null then
      insert into public.suppliers(name, is_active)
      values (v_supplier_name, true)
      returning id into v_supplier_id;
    end if;
  end if;

  if public.fx_txt(p,'name') is null then
    perform public.fx_fail('NAME_REQUIRED','Product name is required.');
  end if;
  if v_mfg is not null and v_expiry is not null and v_expiry < v_mfg then
    perform public.fx_fail('BAD_DATES','The expiry date cannot be before the manufacturing date.');
  end if;
  if v_expiry is not null and v_expiry < current_date - interval '30 days' then
    perform public.fx_fail('BAD_DATES','That expiry date is already in the past — please check it.');
  end if;
  if public.fx_num(p,'sale_price',0) < 0 or public.fx_num(p,'cost_price',0) < 0 then
    perform public.fx_fail('BAD_PRICE','Prices cannot be negative.');
  end if;
  if public.fx_num(p,'wholesale_price',0) > 0
     and public.fx_num(p,'wholesale_min_qty',0) <= 0 then
    perform public.fx_fail('NEED_TIER_QTY',
      'A wholesale price needs the quantity from which it applies (e.g. from 12 pcs).');
  end if;
  if v_barcode is not null and exists (select 1 from public.products x where x.barcode = v_barcode and x.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_BARCODE','Barcode ' || v_barcode || ' is already used by another product.');
  end if;
  if v_sku is not null and exists (select 1 from public.products x where x.sku = v_sku and x.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_SKU','SKU ' || v_sku || ' is already used by another product.');
  end if;

  if v_id is null then
    insert into public.products (
      sku, barcode, name, brand, category_id, supplier_id, unit, pack_size,
      cost_price, sale_price, wholesale_price, wholesale_min_qty, tax_percent, reorder_level,
      shelf_location, expiry_date, plu_code, is_weighed, is_expiry_tracked, country_of_origin,
      is_active, created_by, updated_by)
    values (
      v_sku, v_barcode, public.fx_txt(p,'name'), public.fx_txt(p,'brand'),
      v_category_id, v_supplier_id,
      coalesce(public.fx_txt(p,'unit'),'pcs'), public.fx_txt(p,'pack_size'),
      public.fx_num(p,'cost_price',0), public.fx_num(p,'sale_price',0),
      nullif(public.fx_txt(p,'wholesale_price'),'')::numeric,
      public.fx_num(p,'wholesale_min_qty',0),
      nullif(public.fx_txt(p,'tax_percent'),'')::numeric,
      public.fx_num(p,'reorder_level',5), public.fx_txt(p,'shelf_location'),
      v_expiry, public.fx_txt(p,'plu_code'),
      public.fx_bool(p,'is_weighed',false), public.fx_bool(p,'is_expiry_tracked', v_expiry is not null),
      public.fx_txt(p,'country_of_origin'),
      public.fx_bool(p,'is_active',true), auth.uid(), auth.uid())
    returning * into v_row;

    if v_opening <> 0 then
      insert into public.inventory_movements(product_id, qty_change, movement_type, note, device_name, created_by)
      values (v_row.id, v_opening, 'opening', 'Opening stock', p_device, auth.uid());

      if v_expiry is not null or v_batch is not null then
        insert into public.product_batches(product_id, batch_no, mfg_date, expiry_date,
                                           qty_received, qty_remaining,
                                           unit_cost, note, created_by)
        values (v_row.id, coalesce(v_batch,'OPENING'), v_mfg, v_expiry, v_opening,
                greatest(v_opening,0),
                public.fx_num(p,'cost_price',0), 'Opening stock', auth.uid());
      end if;
    end if;
  else
    update public.products set
      sku = v_sku, barcode = v_barcode, name = public.fx_txt(p,'name'),
      brand = public.fx_txt(p,'brand'),
      category_id = v_category_id,
      supplier_id = v_supplier_id,
      unit = coalesce(public.fx_txt(p,'unit'),'pcs'),
      pack_size = public.fx_txt(p,'pack_size'),
      cost_price = public.fx_num(p,'cost_price',0),
      sale_price = public.fx_num(p,'sale_price',0),
      wholesale_price = nullif(public.fx_txt(p,'wholesale_price'),'')::numeric,
      wholesale_min_qty = public.fx_num(p,'wholesale_min_qty',0),
      tax_percent = nullif(public.fx_txt(p,'tax_percent'),'')::numeric,
      reorder_level = public.fx_num(p,'reorder_level',5),
      shelf_location = public.fx_txt(p,'shelf_location'),
      expiry_date = v_expiry,
      plu_code = public.fx_txt(p,'plu_code'),
      is_weighed = public.fx_bool(p,'is_weighed',false),
      is_expiry_tracked = public.fx_bool(p,'is_expiry_tracked', v_expiry is not null),
      country_of_origin = public.fx_txt(p,'country_of_origin'),
      is_active = public.fx_bool(p,'is_active',true),
      updated_by = auth.uid()
    where id = v_id
    returning * into v_row;

    if not found then
      perform public.fx_fail('NOT_FOUND','Product not found.');
    end if;
  end if;

  perform public.fx_audit(case when v_id is null then 'product.create' else 'product.update' end,
    'products', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'barcode', v_row.barcode,
                       'category_id', v_row.category_id,
                       'sale_price', v_row.sale_price, 'expiry', v_row.expiry_date,
                       'weighed', v_row.is_weighed), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_customer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.customers; v_phone text := public.fx_txt(p,'phone');
        v_card text := public.fx_txt(p,'card_no');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Customer name is required.'); end if;
  if v_phone is not null and exists (select 1 from public.customers c where c.phone = v_phone and c.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_PHONE','Another customer already uses phone ' || v_phone || '.');
  end if;
  if v_card is not null and exists (select 1 from public.customers c where c.card_no = v_card and c.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_CARD','Membership card ' || v_card || ' is already given to someone else.');
  end if;

  if v_id is null then
    insert into public.customers(name, phone, email, address, area, cnic, card_no, credit_limit, notes, created_by)
    values (public.fx_txt(p,'name'), v_phone, public.fx_txt(p,'email'), public.fx_txt(p,'address'),
            public.fx_txt(p,'area'), public.fx_txt(p,'cnic'), v_card,
            public.fx_num(p,'credit_limit',0), public.fx_txt(p,'notes'), auth.uid())
    returning * into v_row;
  else
    update public.customers set name = public.fx_txt(p,'name'), phone = v_phone, email = public.fx_txt(p,'email'),
      address = public.fx_txt(p,'address'), area = public.fx_txt(p,'area'), cnic = public.fx_txt(p,'cnic'),
      card_no = v_card, credit_limit = public.fx_num(p,'credit_limit',0),
      notes = public.fx_txt(p,'notes'), is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('customer.save','customers', v_row.id::text, jsonb_build_object('name', v_row.name), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_supplier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.suppliers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Supplier name is required.'); end if;

  if v_id is null then
    insert into public.suppliers(name, contact_person, phone, email, address, city, ntn, supplier_code,
                                 bank_name, bank_account, credit_days, opening_balance, notes, is_active)
    values (public.fx_txt(p,'name'), public.fx_txt(p,'contact_person'), public.fx_txt(p,'phone'),
            public.fx_txt(p,'email'), public.fx_txt(p,'address'), public.fx_txt(p,'city'),
            public.fx_txt(p,'ntn'), public.fx_txt(p,'supplier_code'), public.fx_txt(p,'bank_name'),
            public.fx_txt(p,'bank_account'), coalesce(public.fx_num(p,'credit_days',0),0)::int,
            public.fx_num(p,'opening_balance',0), public.fx_txt(p,'notes'),
            public.fx_bool(p,'is_active',true))
    returning * into v_row;
  else
    update public.suppliers set name = public.fx_txt(p,'name'), contact_person = public.fx_txt(p,'contact_person'),
      phone = public.fx_txt(p,'phone'), email = public.fx_txt(p,'email'), address = public.fx_txt(p,'address'),
      city = public.fx_txt(p,'city'), ntn = public.fx_txt(p,'ntn'),
      supplier_code = public.fx_txt(p,'supplier_code'), bank_name = public.fx_txt(p,'bank_name'),
      bank_account = public.fx_txt(p,'bank_account'),
      credit_days = coalesce(public.fx_num(p,'credit_days',0),0)::int,
      opening_balance = public.fx_num(p,'opening_balance',0), notes = public.fx_txt(p,'notes'),
      is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('supplier.save','suppliers', v_row.id::text, jsonb_build_object('name', v_row.name), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_employee(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.profiles;
  v_role public.user_role := coalesce(public.fx_txt(p,'role'),'cashier')::public.user_role;
  v_me uuid := auth.uid();
begin
  perform public.fx_require_role(array['super_admin']);
  if v_id is null then
    perform public.fx_fail('NEED_LOGIN',
      'Create the login first (Admin > Employees > Add login), then set the job details here.');
  end if;
  if v_id = v_me and (v_role <> 'super_admin' or public.fx_bool(p,'is_active',true) = false) then
    perform public.fx_fail('LAST_ADMIN','You cannot remove your own Super Admin access.');
  end if;

  update public.profiles set
    full_name = coalesce(public.fx_txt(p,'full_name'), full_name),
    phone = public.fx_txt(p,'phone'),
    username = coalesce(public.fx_txt(p,'username'), username),
    role = v_role,
    is_active = public.fx_bool(p,'is_active',true),
    max_discount_percent = coalesce(nullif(public.fx_txt(p,'max_discount_percent'),'')::numeric,
                                    max_discount_percent),
    hired_on = public.fx_date(p,'hired_on'),
    salary = nullif(public.fx_txt(p,'salary'),'')::numeric,
    emergency_contact = public.fx_txt(p,'emergency_contact'),
    cnic = public.fx_txt(p,'cnic'),
    address = public.fx_txt(p,'address'),
    designation = public.fx_txt(p,'designation'),
    notes = public.fx_txt(p,'notes')
   where id = v_id
  returning * into v_row;

  if not found then perform public.fx_fail('NOT_FOUND','Employee not found.'); end if;

  perform public.fx_audit('employee.save','profiles', v_id::text,
    jsonb_build_object('role', v_row.role, 'active', v_row.is_active, 'max_discount', v_row.max_discount_percent), p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  2. THE TILL'S MONEY PATH, EXTENDED (create_sale + offers + vouchers + tiers)
--      Generated from 03_rpc_api.sql with three additions, nothing removed:
--        * quantity price tiers (bulk/wholesale price by how many are bought)
--        * buy-X-get-Y-free offers, charged as an automatic line discount that
--          never counts against a cashier's manual discount limit
--        * gift vouchers / store credit, taken as a part-payment so the cash
--          drawer and the shift cash-up stay exact
--      Callers keep using pos_sale (which handles the manager PIN).
-- =====================================================================
create or replace function public.create_sale(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_store public.stores;
  v_cuuid text := public.fx_txt(p,'client_uuid');
  v_exist public.sales;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_lines jsonb := '[]'::jsonb;
  v_line record;        -- rows from the staged cart
  v_prod public.products;
  v_qty numeric; v_price numeric; v_line_disc numeric; v_sell numeric;
  v_tax_pct numeric; v_tax numeric; v_line_total numeric; v_line_base numeric;
  v_subtotal numeric := 0; v_line_disc_total numeric := 0; v_tax_total numeric := 0;
  v_cost_total numeric := 0; v_profit_total numeric := 0; v_item_count int := 0;
  v_inv_type public.invoice_discount_type := 'none';
  v_inv_value numeric := 0; v_inv_amount numeric := 0;
  v_code text := upper(public.fx_txt(p,'discount_code'));
  v_disc public.discounts;
  v_total numeric := 0; v_paid numeric := 0; v_change numeric := 0;
  v_method public.payment_method;
  v_customer public.customers;
  v_customer_id uuid := public.fx_uuid(p,'customer_id');
  v_sale_id uuid; v_invoice_no text; v_shift_id uuid := public.fx_uuid(p,'shift_id');
  v_role text := public.fx_role();
  v_max_disc numeric;
  v_disc_percent numeric := 0;
  v_device text := coalesce(p_device, public.fx_txt(p,'device_name'));
  v_bad record;
  v_allow_negative boolean := public.fx_allow_negative_stock();
  v_auto_disc public.discounts;
  -- added by 07: automatic offers, gift vouchers, price tiers
  v_offer public.offers; v_offer_total numeric := 0; v_offer_disc numeric := 0; v_free numeric := 0;
  v_voucher public.vouchers; v_vcode text := upper(coalesce(public.fx_txt(p,'voucher_code'),''));
  v_voucher_amount numeric := 0; v_due numeric := 0; v_tier public.price_tiers; v_tier_price numeric;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);

  -- ---- idempotency: an offline sale replayed twice must not double-bill --
  if v_cuuid is not null then
    select * into v_exist from public.sales where client_uuid = v_cuuid;
    if found then
      return jsonb_build_object('sale_id', v_exist.id, 'invoice_no', v_exist.invoice_no,
        'total', v_exist.total, 'duplicate', true, 'created_at', v_exist.created_at);
    end if;
  end if;

  select * into v_profile from public.profiles where id = v_uid;
  select * into v_store from public.stores order by is_default desc, created_at limit 1;
  v_max_disc := coalesce(v_profile.max_discount_percent, v_store.max_cashier_discount_percent, 0);

  if jsonb_array_length(v_items) = 0 then
    perform public.fx_fail('EMPTY_CART','The cart is empty.');
  end if;

  -- ---- shift: attach to the cashier's open shift, or auto-open one ------
  if v_shift_id is null then
    select id into v_shift_id from public.shifts
     where cashier_id = v_uid and status = 'open' order by opened_at desc limit 1;
  end if;
  if v_shift_id is null then
    insert into public.shifts(shift_no, cashier_id, device_name, opening_float)
    values (public.fx_next_no('SHF','public.shift_seq',5), v_uid, v_device, 0)
    returning id into v_shift_id;
  end if;

  -- ---- stage the cart (set-based, deadlock-free) -----------------------
  create temp table if not exists _pos_lines (
    product_id uuid, qty numeric, unit_price numeric, line_discount numeric,
    name_snapshot text, barcode_snapshot text, unit text, cost_price numeric, tax_percent numeric
  ) on commit drop;
  delete from _pos_lines where true;

  insert into _pos_lines(product_id, qty, unit_price, line_discount, name_snapshot, barcode_snapshot, unit, cost_price, tax_percent)
  select nullif(trim(coalesce(x.product_id,'')),'')::uuid, x.qty, x.unit_price, coalesce(x.line_discount,0),
         nullif(trim(coalesce(x.name_snapshot,'')),'') ,
         nullif(trim(coalesce(x.barcode_snapshot,'')),'') ,
         nullif(trim(coalesce(x.unit,'')),'') ,
         coalesce(x.cost_price,0), coalesce(x.tax_percent,0)
    from jsonb_to_recordset(v_items) as x(
      product_id text, qty numeric, unit_price numeric, line_discount numeric,
      name_snapshot text, barcode_snapshot text, unit text, cost_price numeric, tax_percent numeric
    );

  if exists (select 1 from _pos_lines where qty is null or qty <= 0) then
    perform public.fx_fail('BAD_LINE','Every sale line needs a quantity greater than zero.');
  end if;

  -- lock every product row in a deterministic order: two tills selling at the
  -- same instant queue up here instead of deadlocking
  perform 1 from public.products pr
     join (select product_id, sum(qty) as q from _pos_lines where product_id is not null group by product_id) g on g.product_id = pr.id
    order by pr.id
      for update of pr;

  -- validate the cart against live data
  for v_bad in
    select pr.id, pr.name, pr.unit, pr.stock_qty, g.q as want, pr.is_active, pr.is_deleted, pr.sale_price, pr.cost_price
      from public.products pr
      join (select product_id, sum(qty) as q from _pos_lines where product_id is not null group by product_id) g on g.product_id = pr.id
  loop
    if v_bad.is_deleted or not v_bad.is_active then
      perform public.fx_fail('PRODUCT_INACTIVE', v_bad.name || ' is no longer for sale. Remove it from the cart.');
    end if;
    if not v_allow_negative and v_bad.stock_qty < v_bad.want then
      perform public.fx_fail('INSUFFICIENT_STOCK',
        v_bad.name || ' — only ' || trim(to_char(v_bad.stock_qty,'FM999999990.###')) || ' ' || v_bad.unit ||
        ' in stock, the cart needs ' || trim(to_char(v_bad.want,'FM999999990.###')));
    end if;
  end loop;

  -- price the cart from the live database (never trust the till's own numbers)
  for v_line in
    select l.product_id, l.qty, l.unit_price, l.line_discount, l.name_snapshot, l.barcode_snapshot, l.unit, l.cost_price, l.tax_percent,
           pr.name, pr.barcode, pr.unit as product_unit, pr.sale_price, pr.cost_price as product_cost_price, pr.tax_percent as product_tax_percent,
           pr.category_id, pr.is_active, pr.is_deleted
      from _pos_lines l
      left join public.products pr on pr.id = l.product_id
  loop
    v_qty := v_line.qty;
    v_price := coalesce(nullif(v_line.unit_price,0), coalesce(v_line.sale_price,0));

    if v_line.product_id is not null then
      -- quantity pricing (wholesale / bulk): the shop's own rule wins over the
      -- shelf price, so a 10-kg buyer is charged the tier they qualify for
      v_tier_price := null;
      if coalesce(v_store.enable_tiers, true) then
        select * into v_tier from public.price_tiers t
         where t.product_id = v_line.product_id and t.is_active and v_qty >= t.min_qty
         order by t.min_qty desc limit 1;
        if found and v_tier.price < v_price then
          v_price := v_tier.price;
        end if;
      end if;

      -- a till may charge less than the shelf price, but never more, unless a
      -- manager is signed in or the store allows price override
      if v_price > v_line.sale_price and not public.fx_is_manager() and not v_store.allow_price_override then
        perform public.fx_fail('PRICE_OVERRIDE_NOT_ALLOWED',
          'Price of ' || v_line.name || ' was changed from ' || to_char(v_line.sale_price,'FM999999990.00') ||
          '. Only a manager can override prices.');
      end if;

      -- automatic "buy X get Y free" offer (a shop rule, not a manual discount,
      -- so it is never counted against the cashier's discount limit)
      v_offer_disc := 0;
      v_offer := null;
      select * into v_offer from public.offers o
       where coalesce(v_store.enable_offers, true)
         and o.is_active
         and (o.starts_on is null or o.starts_on <= current_date)
         and (o.ends_on   is null or o.ends_on   >= current_date)
         and o.buy_qty > 0 and o.free_qty > 0
         and ((o.product_id is not null and o.product_id = v_line.product_id)
              or (o.category_id is not null and o.category_id = v_line.category_id))
         and v_qty >= (o.buy_qty + o.free_qty)
       order by (case when o.product_id is not null then 0 else 1 end), o.free_qty desc
       limit 1;
      if found then
        v_free := floor(v_qty / (v_offer.buy_qty + v_offer.free_qty)) * v_offer.free_qty;
        v_offer_disc := least(round(v_free * v_price, 2), round(v_price * v_qty, 2));
      end if;
    else
      v_offer_disc := 0;
    end if;

    v_line_disc := least(coalesce(v_line.line_discount,0), v_price * v_qty);
    v_line_disc := least(v_line_disc + v_offer_disc, v_price * v_qty);
    v_line_base := v_price * v_qty;
    v_sell := v_line_base - v_line_disc;

    v_tax_pct := coalesce(v_line.tax_percent, v_line.product_tax_percent,
                          case when v_store.tax_inclusive then 0 else v_store.tax_percent end, 0);
    v_tax := round(v_sell * v_tax_pct / 100.0, 2);
    if v_store.tax_inclusive then
      v_tax := round(v_sell - (v_sell / (1 + v_tax_pct/100.0)), 2);
      v_line_total := round(v_sell, 2);
    else
      v_line_total := round(v_sell + v_tax, 2);
    end if;

    v_subtotal := v_subtotal + round(v_sell, 2);
    v_line_disc_total := v_line_disc_total + v_line_disc;
    v_tax_total := v_tax_total + v_tax;
    if v_line.product_id is not null then
      v_cost_total := v_cost_total + round(coalesce(v_line.product_cost_price, v_line.cost_price, 0) * v_qty, 2);
    end if;
    v_offer_total := v_offer_total + v_offer_disc;
    v_item_count := v_item_count + 1;

    v_lines := v_lines || jsonb_build_object(
      'product_id', v_line.product_id,
      'name_snapshot', coalesce(v_line.name, v_line.name_snapshot, 'Custom item'),
      'barcode_snapshot', coalesce(v_line.barcode, v_line.barcode_snapshot),
      'unit', coalesce(v_line.product_unit, v_line.unit, 'pcs'),
      'qty', v_qty,
      'unit_price', v_price,
      'cost_price', coalesce(v_line.product_cost_price, v_line.cost_price, 0),
      'line_discount', v_line_disc,
      'tax_percent', v_tax_pct,
      'tax_amount', v_tax,
      'line_total', v_line_total);
  end loop;

  -- ---- invoice-level discount -----------------------------------------
  v_inv_type := coalesce(public.fx_txt(p,'invoice_discount_type'),'none')::public.invoice_discount_type;
  v_inv_value := public.fx_num(p,'invoice_discount_value',0);

  if v_code is not null then
    select * into v_disc from public.discounts
     where upper(coalesce(code,'')) = v_code and is_active
       and starts_at <= now() and (ends_at is null or ends_at >= now()) limit 1;
    if not found then
      perform public.fx_fail('CODE_INVALID','Discount code ' || v_code || ' is not valid or has expired.');
    end if;
    if v_disc.min_subtotal > 0 and v_subtotal < v_disc.min_subtotal then
      perform public.fx_fail('CODE_MIN_SUBTOTAL','Code ' || v_code || ' needs a minimum bill of ' || to_char(v_disc.min_subtotal,'FM999999990.00'));
    end if;
    if v_disc.max_uses is not null and v_disc.used_count >= v_disc.max_uses then
      perform public.fx_fail('CODE_EXHAUSTED','That discount code has been fully used.');
    end if;
    if v_disc.requires_manager and not public.fx_is_manager() then
      perform public.fx_fail('CODE_NEEDS_MANAGER','Code ' || v_code || ' needs a manager to authorise it.');
    end if;

    v_inv_type := 'code';
    v_inv_value := v_disc.value;
    if v_disc.kind = 'percent' then
      v_inv_amount := round(v_subtotal * v_disc.value / 100.0, 2);
    else
      v_inv_amount := v_disc.value;
    end if;
    if v_disc.max_discount is not null then v_inv_amount := least(v_inv_amount, v_disc.max_discount); end if;
    v_inv_amount := least(v_inv_amount, v_subtotal);

    update public.discounts set used_count = used_count + 1 where id = v_disc.id;
  elsif v_inv_type = 'percent' then
    if v_inv_value < 0 or v_inv_value > 100 then
      perform public.fx_fail('BAD_DISCOUNT','Discount percent must be between 0 and 100.');
    end if;
    v_inv_amount := round(v_subtotal * v_inv_value / 100.0, 2);
  elsif v_inv_type = 'amount' then
    if v_inv_value < 0 then perform public.fx_fail('BAD_DISCOUNT','Discount cannot be negative.'); end if;
    v_inv_amount := least(v_inv_value, v_subtotal);
  else
    -- automatic store-wide promotions the Super Admin switched on
    select * into v_auto_disc from public.discounts
     where is_active and applies_automatically and scope = 'all'
       and starts_at <= now() and (ends_at is null or ends_at >= now())
       and min_subtotal <= v_subtotal
       and (max_uses is null or used_count < max_uses)
     order by (case when kind = 'percent' then value else (value / greatest(v_subtotal,1) * 100) end) desc
     limit 1;
    if found then
      v_inv_type := 'code';
      v_code := v_auto_disc.code;
      v_inv_value := v_auto_disc.value;
      v_inv_amount := case when v_auto_disc.kind = 'percent'
                           then round(v_subtotal * v_auto_disc.value / 100.0, 2) else v_auto_disc.value end;
      if v_auto_disc.max_discount is not null then v_inv_amount := least(v_inv_amount, v_auto_disc.max_discount); end if;
      v_inv_amount := least(v_inv_amount, v_subtotal);
      update public.discounts set used_count = used_count + 1 where id = v_auto_disc.id;
    end if;
  end if;

  -- ---- cashier discount ceiling ---------------------------------------
  -- measured against the GROSS bill (before any line discounts), so a cashier
  -- giving exactly their limit is not refused for "rounding" reasons
  if v_role = 'cashier' and (v_subtotal + v_line_disc_total) > 0 then
    v_disc_percent := round(((v_line_disc_total - v_offer_total) + v_inv_amount) /
                            (v_subtotal + v_line_disc_total) * 100, 2);
    if v_disc_percent > v_max_disc then
      perform public.fx_fail('DISCOUNT_LIMIT',
        'That is a ' || trim(to_char(v_disc_percent,'FM990.0')) || '% discount but your limit is ' ||
        trim(to_char(v_max_disc,'FM990.0')) || '%. Ask a manager to authorise it.');
    end if;
  end if;

  v_total := round(greatest(v_subtotal - v_inv_amount, 0), 2);

  -- ---- payment ---------------------------------------------------------
  v_method := coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method;

  -- ---- gift voucher / store credit -------------------------------------
  -- Vouchers are money the shop already holds, so they act like a part-payment
  -- (never a discount): the drawer only takes the rest in cash.
  if v_vcode <> '' and not coalesce(v_store.enable_vouchers, true) then
    perform public.fx_fail('VOUCHERS_OFF',
      'Gift vouchers are switched off in Settings. Switch them on to accept a voucher.');
  end if;
  if v_vcode <> '' then
    select * into v_voucher from public.vouchers where upper(code) = v_vcode for update;
    if not found then
      perform public.fx_fail('VOUCHER_INVALID','Voucher ' || v_vcode || ' was not found.');
    end if;
    if not v_voucher.is_active then
      perform public.fx_fail('VOUCHER_INACTIVE','That voucher has been cancelled.');
    end if;
    if v_voucher.expires_on is not null and v_voucher.expires_on < current_date then
      perform public.fx_fail('VOUCHER_EXPIRED',
        'That voucher expired on ' || to_char(v_voucher.expires_on,'DD-Mon-YYYY') || '.');
    end if;
    if coalesce(v_voucher.balance,0) <= 0 then
      perform public.fx_fail('VOUCHER_EMPTY','That voucher has no balance left.');
    end if;
    if v_method = 'credit' then
      perform public.fx_fail('VOUCHER_WITH_CREDIT','A voucher cannot be used on an udhaar (credit) sale.');
    end if;
    v_voucher_amount := least(v_voucher.balance, v_total);
  end if;

  if v_customer_id is not null then
    select * into v_customer from public.customers where id = v_customer_id;
    if not found then perform public.fx_fail('NOT_FOUND','Customer not found.'); end if;
  end if;

  if v_method = 'credit' then
    if v_customer_id is null then
      perform public.fx_fail('CREDIT_NEEDS_CUSTOMER','Choose a customer account for a credit (udhaar) sale.');
    end if;
    if v_customer.credit_limit > 0 and (v_customer.balance + v_total) > v_customer.credit_limit then
      perform public.fx_fail('CREDIT_LIMIT',
        v_customer.name || ' already owes ' || to_char(v_customer.balance,'FM999999990.00') ||
        ' and the credit limit is ' || to_char(v_customer.credit_limit,'FM999999990.00') || '.');
    end if;
    v_paid := 0;
    update public.customers set balance = balance + v_total where id = v_customer_id;
  else
    v_due := round(greatest(v_total - v_voucher_amount, 0), 2);
    v_paid := coalesce(nullif(public.fx_num(p,'paid_amount',0),0), v_due);
    if v_method <> 'cash' then v_paid := greatest(v_paid, v_due); end if;
    if v_method = 'cash' and v_paid < v_due then
      perform public.fx_fail('INSUFFICIENT_PAYMENT',
        'Cash received (' || to_char(v_paid,'FM999999990.00') || ') is less than the amount due (' || to_char(v_due,'FM999999990.00') || ').');
    end if;
    v_change := greatest(round(v_paid - v_due, 2), 0);
  end if;

  -- ---- write the invoice ----------------------------------------------
  v_invoice_no := public.fx_next_no(coalesce(v_store.invoice_prefix,'INV'), 'public.invoice_seq', 6);

  insert into public.sales (
    client_uuid, invoice_no, store_id, cashier_id, cashier_name, shift_id, customer_id, customer_name,
    device_name, item_count, subtotal, line_discount_total, invoice_discount_type, invoice_discount_value,
    invoice_discount_amount, discount_code, tax_amount, total, cost_total, profit, paid_amount, change_amount,
    payment_method, payment_ref, status, note, offline_created, voucher_code, voucher_amount)
  values (
    v_cuuid, v_invoice_no, v_store.id, v_uid, coalesce(v_profile.full_name, v_profile.username), v_shift_id,
    v_customer_id, v_customer.name, v_device, v_item_count, round(v_subtotal,2), round(v_line_disc_total,2),
    v_inv_type, v_inv_value, round(v_inv_amount,2), v_code, round(v_tax_total,2), v_total,
    round(v_cost_total,2), round(v_profit_total,2), round(v_paid,2), v_change,
    v_method, public.fx_txt(p,'payment_ref'), 'completed', public.fx_txt(p,'note'),
    public.fx_bool(p,'offline_created',false), nullif(v_vcode,''), round(v_voucher_amount,2))
  returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, product_id, name_snapshot, barcode_snapshot, unit, qty, unit_price, cost_price,
    line_discount, tax_percent, tax_amount, line_total)
    select v_sale_id,
      public.fx_uuid(jsonb_build_object('product_id', l->>'product_id'),'product_id'), l->>'name_snapshot', l->>'barcode_snapshot', l->>'unit',
         public.fx_num(jsonb_build_object('qty', l->>'qty'), 'qty', 0),
         public.fx_num(jsonb_build_object('unit_price', l->>'unit_price'), 'unit_price', 0),
         public.fx_num(jsonb_build_object('cost_price', l->>'cost_price'), 'cost_price', 0),
         public.fx_num(jsonb_build_object('line_discount', l->>'line_discount'), 'line_discount', 0),
         public.fx_num(jsonb_build_object('tax_percent', l->>'tax_percent'), 'tax_percent', 0),
         public.fx_num(jsonb_build_object('tax_amount', l->>'tax_amount'), 'tax_amount', 0),
         public.fx_num(jsonb_build_object('line_total', l->>'line_total'), 'line_total', 0)
    from jsonb_array_elements(v_lines) l
    where l->>'product_id' is not null and trim(l->>'product_id') <> '';

  -- every product-backed line writes an inventory movement; custom misc items are
  -- not stocked and therefore do not touch the stock ledger.
  insert into public.inventory_movements (
    product_id, qty_change, movement_type, reference_type, reference_id, unit_cost, note, device_name, created_by)
  select public.fx_uuid(jsonb_build_object('product_id', l->>'product_id'),'product_id'),
         -(public.fx_num(jsonb_build_object('qty', l->>'qty'), 'qty', 0)), 'sale', 'sale', v_sale_id,
         public.fx_num(jsonb_build_object('cost_price', l->>'cost_price'), 'cost_price', 0), v_invoice_no, v_device, v_uid
    from jsonb_array_elements(v_lines) l
    where l->>'product_id' is not null and trim(l->>'product_id') <> '';

  -- spend the voucher and keep the paper trail
  if v_voucher_amount > 0 then
    update public.vouchers
       set balance = round(balance - v_voucher_amount, 2), last_used_at = now()
     where id = v_voucher.id;
    insert into public.voucher_redemptions(voucher_id, sale_id, invoice_no, amount, created_by)
    values (v_voucher.id, v_sale_id, v_invoice_no, round(v_voucher_amount,2), v_uid);
  end if;

  -- loyalty points
  if v_customer_id is not null and coalesce(v_store.loyalty_points_per_100,0) > 0 then
    update public.customers
       set loyalty_points = loyalty_points + floor(v_total / 100.0 * v_store.loyalty_points_per_100)::int
     where id = v_customer_id;
  end if;

  perform public.fx_audit('sale.create','sales', v_sale_id::text,
    jsonb_build_object('invoice_no', v_invoice_no, 'total', v_total, 'items', v_item_count,
                       'payment_method', v_method, 'discount', v_inv_amount + v_line_disc_total,
                       'offer_discount', v_offer_total,
                       'voucher', nullif(v_vcode,''), 'voucher_amount', v_voucher_amount), v_device);

  if v_offer_total > 0 then
    perform public.fx_audit('offer.applied','sales', v_sale_id::text,
      jsonb_build_object('invoice_no', v_invoice_no, 'free_value', v_offer_total,
                         'offer_id', v_offer.id, 'offer_name', v_offer.name), v_device);
  end if;

  return jsonb_build_object(
    'sale_id', v_sale_id, 'invoice_no', v_invoice_no, 'created_at', now(),
    'item_count', v_item_count, 'subtotal', round(v_subtotal,2),
    'line_discount_total', round(v_line_disc_total,2), 'invoice_discount_amount', round(v_inv_amount,2),
    'discount_code', v_code, 'tax_amount', round(v_tax_total,2), 'total', v_total,
    'paid_amount', round(v_paid,2), 'change_amount', v_change,
    'voucher_code', nullif(v_vcode,''), 'voucher_amount', round(v_voucher_amount,2),
    'offer_discount', round(v_offer_total,2), 'amount_due', round(v_due,2),
    'payment_method', v_method, 'profit', round(v_profit_total, 2),
    'cashier_name', coalesce(v_profile.full_name, v_profile.username),
    'customer_name', v_customer.name, 'device_name', v_device,
    'shift_id', v_shift_id,
    'customer_balance', v_customer.balance,
    'duplicate', false,
    'lines', v_lines,
    'store', to_jsonb(v_store));
end $$;

-- =====================================================================
--  4. RECEIVING (purchase) with batches and expiry dates
--     Same proven function as 06, plus: every line may carry a batch number,
--     a manufacturing date and an expiry date. Those lines create a batch row,
--     and the product's "earliest expiry" is kept up to date.
-- =====================================================================


-- =====================================================================
--  5. BATCHES + EXPIRY
-- =====================================================================
create or replace function public.list_batches(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_pid uuid := public.fx_uuid(p,'product_id');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'expiry_date') nulls last, x->>'product_name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', b.id, 'product_id', b.product_id, 'product_name', coalesce(pr.name,''),
               'barcode', pr.barcode, 'unit', pr.unit,
               'batch_no', b.batch_no, 'mfg_date', b.mfg_date, 'expiry_date', b.expiry_date,
               'qty_received', b.qty_received, 'qty_remaining', b.qty_remaining,
               'unit_cost', b.unit_cost, 'value', round(b.qty_remaining * b.unit_cost, 2),
               'supplier_name', s.name, 'po_no', po.po_no,
               'days_left', case when b.expiry_date is null then null else (b.expiry_date - current_date) end,
               'status', case when b.expiry_date is null then 'no-expiry'
                              when b.expiry_date < current_date then 'expired'
                              when (b.expiry_date - current_date) <= (select expiry_alert_days from public.stores order by is_default desc, created_at limit 1) then 'expiring'
                              else 'fresh' end
             ) as x
        from public.product_batches b
        join public.products pr on pr.id = b.product_id
        left join public.suppliers s on s.id = b.supplier_id
        left join public.purchase_orders po on po.id = b.purchase_id
       where b.is_active and b.qty_remaining > 0
         and (v_pid is null or b.product_id = v_pid)
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

create or replace function public.expiring_stock(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_days int := coalesce(public.fx_num(p,'days',30),30)::int;
  v_rows jsonb; v_expired jsonb; v_expiring jsonb; v_value numeric := 0;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'expiry_date'), x->>'product_name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', b.id, 'product_id', b.product_id, 'product_name', pr.name, 'barcode', pr.barcode,
               'unit', pr.unit, 'batch_no', b.batch_no, 'expiry_date', b.expiry_date,
               'qty_remaining', b.qty_remaining, 'unit_cost', b.unit_cost,
               'value', round(b.qty_remaining * b.unit_cost, 2),
               'days_left', (b.expiry_date - current_date),
               'supplier_name', s.name,
               'status', case when b.expiry_date < current_date then 'expired'
                              when (b.expiry_date - current_date) <= v_days then 'expiring'
                              else 'fresh' end
             ) as x
        from public.product_batches b
        join public.products pr on pr.id = b.product_id
        left join public.suppliers s on s.id = b.supplier_id
       where b.is_active and b.qty_remaining > 0 and b.expiry_date is not null
         and b.expiry_date <= current_date + v_days
    ) t;
  select
    coalesce(jsonb_agg(x) filter (where x->>'status' = 'expired'), '[]'::jsonb),
    coalesce(jsonb_agg(x) filter (where x->>'status' = 'expiring'), '[]'::jsonb),
    coalesce(sum((x->>'value')::numeric) filter (where x->>'status' <> 'fresh'), 0)
  into v_expired, v_expiring, v_value
  from jsonb_array_elements(v_rows) x;
  return jsonb_build_object('rows', v_rows, 'expired', v_expired, 'expiring', v_expiring,
                            'at_risk_value', v_value, 'days', v_days);
end $$;

-- Write off stock: damaged, expired, stolen, or a simple correction. Always
-- asks for a reason and always leaves a movement with the employee's name.
create or replace function public.write_off_stock(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_batch_id uuid := public.fx_uuid(p,'batch_id');
  v_prod_id  uuid := public.fx_uuid(p,'product_id');
  v_qty      numeric := public.fx_num(p,'qty',0);
  v_reason   text := coalesce(public.fx_txt(p,'reason'),'adjustment');
  v_note     text := public.fx_txt(p,'note');
  v_b public.product_batches; v_pr public.products;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_qty <= 0 then perform public.fx_fail('BAD_AMOUNT','Enter how many units to write off.'); end if;
  if v_reason not in ('expired','damaged','theft','lost','sample','adjustment','other') then
    perform public.fx_fail('BAD_REASON','Choose a write-off reason: expired, damaged, theft, lost, sample or other.');
  end if;

  if v_batch_id is not null then
    select * into v_b from public.product_batches where id = v_batch_id for update;
    if not found then perform public.fx_fail('NOT_FOUND','That batch was not found.'); end if;
    if v_qty > v_b.qty_remaining then
      perform public.fx_fail('QTY_TOO_BIG','Only ' || trim(to_char(v_b.qty_remaining,'FM999999990.###')) ||
        ' left in that batch.');
    end if;
    v_prod_id := v_b.product_id;
    update public.product_batches set qty_remaining = qty_remaining - v_qty where id = v_batch_id;
  end if;

  select * into v_pr from public.products where id = v_prod_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;
  if v_qty > v_pr.stock_qty then
    perform public.fx_fail('QTY_TOO_BIG', v_pr.name || ' only has ' ||
      trim(to_char(v_pr.stock_qty,'FM999999990.###')) || ' ' || v_pr.unit || ' in stock.');
  end if;

  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, unit_cost,
                                         note, device_name, created_by)
  values (v_prod_id, -v_qty, 'adjustment', 'write_off', v_pr.cost_price,
          'Write-off (' || v_reason || ')' || coalesce(' - ' || v_note,''), p_device, auth.uid());

  -- roll the product's earliest expiry forward once the batch is used up
  if v_batch_id is not null then
    update public.products p set expiry_date = (
      select min(b.expiry_date) from public.product_batches b
       where b.product_id = p.id and b.qty_remaining > 0 and b.expiry_date is not null)
      where p.id = v_prod_id;
  end if;

  perform public.fx_audit('stock.writeoff','products', v_prod_id::text,
    jsonb_build_object('product', v_pr.name, 'qty', v_qty, 'reason', v_reason,
                       'value', round(v_qty * v_pr.cost_price, 2), 'note', v_note,
                       'batch', v_b.batch_no), p_device);

  return jsonb_build_object('product', v_pr.name, 'qty', v_qty, 'reason', v_reason,
                            'value_lost', round(v_qty * v_pr.cost_price, 2),
                            'stock_left', v_pr.stock_qty - v_qty);
end $$;

-- =====================================================================
--  5a. STORE SETTINGS - the new big-shop switches
--      (expiry warnings, blocked expired sales, offers/vouchers on or off,
--      the note and terms printed on a proper invoice)
-- =====================================================================


-- =====================================================================
--  5b. FIRST-EXPIRE-FIRST-OUT
--      Whenever stock leaves the shop (a sale, a refund's stock going back out,
--      a write-off, a return to the supplier), the quantity is taken off the
--      batches that expire first. Products with no batches are untouched.
-- =====================================================================
create or replace function public.fx_consume_batches()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_left numeric := -new.qty_change;   -- only called for stock going OUT
  v_b public.product_batches;
begin
  if new.qty_change >= 0 then return new; end if;
  if new.movement_type = 'purchase' then return new; end if;
  if not exists (select 1 from public.product_batches b
                  where b.product_id = new.product_id and b.qty_remaining > 0) then
    return new;
  end if;

  for v_b in
    select * from public.product_batches b
     where b.product_id = new.product_id and b.qty_remaining > 0
     order by (b.expiry_date is null), b.expiry_date, b.created_at
       for update
  loop
    exit when v_left <= 0;
    if v_b.qty_remaining >= v_left then
      update public.product_batches set qty_remaining = qty_remaining - v_left where id = v_b.id;
      v_left := 0;
    else
      update public.product_batches set qty_remaining = 0 where id = v_b.id;
      v_left := v_left - v_b.qty_remaining;
    end if;
  end loop;

  -- the product's "expires on" follows the oldest batch still on the shelf
  if v_left < -new.qty_change then
    update public.products p set expiry_date = (
      select min(b.expiry_date) from public.product_batches b
       where b.product_id = p.id and b.qty_remaining > 0 and b.expiry_date is not null)
     where p.id = new.product_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_consume_batches on public.inventory_movements;
create trigger trg_consume_batches
  after insert on public.inventory_movements
  for each row execute function public.fx_consume_batches();

-- An expired batch must never leave the till as a normal sale when the owner
-- has switched that guard on (Settings > stock rules).
create or replace function public.fx_block_expired_sale()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_block boolean := (public.fx_store()).block_expired_sales; v_b public.product_batches;
begin
  if not coalesce(v_block,false) or new.qty_change >= 0 or new.movement_type <> 'sale' then
    return new;
  end if;
  select * into v_b from public.product_batches b
   where b.product_id = new.product_id and b.qty_remaining > 0
     and b.expiry_date is not null and b.expiry_date < current_date
   order by b.expiry_date limit 1;
  if found then
    perform public.fx_fail('BATCH_EXPIRED',
      'This stock is past its expiry date (' || to_char(v_b.expiry_date,'DD-Mon-YYYY') ||
      '). Take it off the shelf, or write it off from the Expiry screen.');
  end if;
  return new;
end $$;

drop trigger if exists trg_block_expired_sale on public.inventory_movements;
create trigger trg_block_expired_sale
  before insert on public.inventory_movements
  for each row execute function public.fx_block_expired_sale();

-- =====================================================================
--  5c. PRICE TIERS - saving them (the app can only write through functions)
-- =====================================================================
create or replace function public.save_price_tier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_pid uuid := public.fx_uuid(p,'product_id');
  v_min numeric := public.fx_num(p,'min_qty',0);
  v_price numeric := public.fx_num(p,'price',0);
  v_row public.price_tiers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_pid is null then perform public.fx_fail('NEED_PRODUCT','Choose the product this price applies to.'); end if;
  if v_min <= 0 then perform public.fx_fail('BAD_QTY','Say how many units get this price (e.g. from 12).'); end if;
  if v_price <= 0 then perform public.fx_fail('BAD_PRICE','The tier price must be above zero.'); end if;

  if exists (select 1 from public.price_tiers t
              where t.product_id = v_pid and t.min_qty = v_min and t.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_TIER','There is already a price for that quantity. Edit that one instead.');
  end if;

  if v_id is null then
    insert into public.price_tiers(product_id, min_qty, price, label, is_active, created_by)
    values (v_pid, v_min, v_price, nullif(public.fx_txt(p,'label'),''),
            public.fx_bool(p,'is_active',true), auth.uid())
    returning * into v_row;
  else
    update public.price_tiers set min_qty = v_min, price = v_price,
           label = nullif(public.fx_txt(p,'label'),''), is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
    if not found then perform public.fx_fail('NOT_FOUND','Price tier not found.'); end if;
  end if;

  perform public.fx_audit('tier.save','price_tiers', v_row.id::text,
    jsonb_build_object('product_id', v_row.product_id, 'from_qty', v_row.min_qty, 'price', v_row.price),
    p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_price_tier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.price_tiers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_row from public.price_tiers where id = v_id;
  if not found then perform public.fx_fail('NOT_FOUND','Price tier not found.'); end if;
  delete from public.price_tiers where id = v_id;
  perform public.fx_audit('tier.delete','price_tiers', v_id::text,
    jsonb_build_object('product_id', v_row.product_id, 'from_qty', v_row.min_qty), p_device);
  return jsonb_build_object('deleted', true);
end $$;

-- =====================================================================
--  6. PURCHASE RETURNS (goods back to the supplier)
-- =====================================================================
create or replace function public.create_purchase_return(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_supplier public.suppliers;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_return_no text;
  v_id uuid;
  v_total numeric := 0;
  v_settled text := coalesce(public.fx_txt(p,'settled_by'),'payable');
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if jsonb_array_length(v_items) = 0 then
    perform public.fx_fail('EMPTY_RETURN','Add at least one item to send back.');
  end if;

  select * into v_supplier from public.suppliers where id = public.fx_uuid(p,'supplier_id');
  if not found then perform public.fx_fail('NOT_FOUND','Supplier not found.'); end if;

  create temp table if not exists _pr_lines (
    product_id uuid, qty numeric, unit_cost numeric, batch_id uuid, expiry_date date, reason text) on commit drop;
  delete from _pr_lines where true;
  insert into _pr_lines(product_id, qty, unit_cost, batch_id, expiry_date, reason)
  select x.product_id, x.qty, x.unit_cost, x.batch_id, x.expiry_date, x.reason
    from jsonb_to_recordset(v_items) as x(product_id uuid, qty numeric, unit_cost numeric, batch_id uuid,
                                          expiry_date date, reason text);

  if exists (select 1 from _pr_lines where product_id is null or qty is null or qty <= 0) then
    perform public.fx_fail('BAD_QTY','Every returned line needs a product and a quantity greater than zero.');
  end if;
  if exists (select 1 from _pr_lines l join public.products pr on pr.id = l.product_id where l.qty > pr.stock_qty) then
    perform public.fx_fail('QTY_TOO_BIG','You cannot send back more than you have in stock.');
  end if;

  v_return_no := public.fx_next_no('PRT','public.purchase_return_seq',5);

  insert into public.purchase_returns(return_no, supplier_id, supplier_name, purchase_id, reason, note,
                                      total, settled_by, created_by)
  values (v_return_no, v_supplier.id, v_supplier.name, public.fx_uuid(p,'purchase_id'),
          public.fx_txt(p,'reason'), public.fx_txt(p,'note'), 0, v_settled, auth.uid())
  returning id into v_id;

  insert into public.purchase_return_items(return_id, product_id, name_snapshot, batch_id, expiry_date,
                                           qty, unit_cost, line_total, reason)
  select v_id, l.product_id, pr.name, l.batch_id, l.expiry_date, l.qty, l.unit_cost,
         round(l.qty * l.unit_cost, 2), l.reason
    from _pr_lines l join public.products pr on pr.id = l.product_id;

  select coalesce(sum(line_total),0) into v_total from public.purchase_return_items where return_id = v_id;

  -- stock leaves the shop
  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, reference_id,
                                         unit_cost, note, device_name, created_by)
  select l.product_id, -l.qty, 'return_supplier', 'purchase_return', v_id, l.unit_cost,
         'Return ' || v_return_no, p_device, auth.uid()
    from _pr_lines l;

  -- and comes out of the batch it was bought in
  update public.product_batches b set qty_remaining = greatest(b.qty_remaining - l.qty, 0)
    from _pr_lines l
   where b.id = l.batch_id;

  update public.products p set expiry_date = (
      select min(b.expiry_date) from public.product_batches b
       where b.product_id = p.id and b.qty_remaining > 0 and b.expiry_date is not null)
   where p.id in (select distinct product_id from _pr_lines);

  update public.purchase_returns set total = v_total where id = v_id;

  -- a return reduces what the shop owes the supplier (or was paid straight back)
  if v_settled = 'payable' and v_total > 0 then
    insert into public.supplier_payments(payment_no, supplier_id, supplier_name, amount,
                                         payment_method, reference_no, note, created_by)
    values (public.fx_next_no('PAY','public.payment_seq',5), v_supplier.id, v_supplier.name, -v_total,
            'cash', v_return_no, 'Goods returned to supplier (' || v_return_no || ')', auth.uid());
  end if;

  perform public.fx_audit('purchase.return','purchase_returns', v_id::text,
    jsonb_build_object('return_no', v_return_no, 'supplier', v_supplier.name, 'total', v_total,
                       'items', jsonb_array_length(v_items), 'settled_by', v_settled), p_device);

  return jsonb_build_object('id', v_id, 'return_no', v_return_no, 'total', v_total,
                            'supplier_name', v_supplier.name);
end $$;

create or replace function public.list_purchase_returns(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', r.id, 'return_no', r.return_no, 'supplier_name', r.supplier_name,
               'reason', r.reason, 'note', r.note, 'total', r.total, 'settled_by', r.settled_by,
               'created_at', r.created_at,
               'item_count', (select count(*) from public.purchase_return_items i where i.return_id = r.id),
               'items', (select coalesce(jsonb_agg(jsonb_build_object(
                          'name', i.name_snapshot, 'qty', i.qty, 'unit_cost', i.unit_cost,
                          'line_total', i.line_total, 'expiry_date', i.expiry_date)), '[]'::jsonb)
                         from public.purchase_return_items i where i.return_id = r.id)
             ) as x
        from public.purchase_returns r
       order by r.created_at desc
       limit coalesce(public.fx_num(p,'limit',200),200)::int
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

-- =====================================================================
--  7. GIFT VOUCHERS / STORE CREDIT
-- =====================================================================
create or replace function public.issue_voucher(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_value numeric := public.fx_num(p,'value',0);
  v_kind text := coalesce(public.fx_txt(p,'kind'),'gift');
  v_code text := upper(public.fx_txt(p,'code'));
  v_row public.vouchers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_value <= 0 then perform public.fx_fail('BAD_AMOUNT','A voucher needs a value above zero.'); end if;
  if v_kind not in ('gift','store_credit') then
    perform public.fx_fail('BAD_KIND','Voucher kind must be gift or store_credit.');
  end if;

  if v_code is null then
    -- 12 characters, no confusing letters, e.g. GC-7F3K9Q2M
    loop
      v_code := 'GC-' || upper(substr(translate(encode(gen_random_bytes(9),'base64'),'+/=lIO01',''),1,8));
      exit when not exists (select 1 from public.vouchers where code = v_code);
    end loop;
  end if;

  insert into public.vouchers(code, kind, value, balance, customer_id, issued_to, phone, reason,
                              expires_on, created_by)
  values (v_code, v_kind, v_value, v_value, public.fx_uuid(p,'customer_id'), public.fx_txt(p,'issued_to'),
          public.fx_txt(p,'phone'), public.fx_txt(p,'reason'),
          public.fx_date(p,'expires_on'), auth.uid())
  returning * into v_row;

  perform public.fx_audit('voucher.issue','vouchers', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'value', v_row.value, 'kind', v_row.kind,
                       'issued_to', v_row.issued_to), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.list_vouchers(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_q text := nullif(trim(coalesce(public.fx_txt(p,'q'),'')),'');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', v.id, 'code', v.code, 'kind', v.kind, 'value', v.value, 'balance', v.balance,
               'issued_to', v.issued_to, 'phone', v.phone, 'reason', v.reason,
               'expires_on', v.expires_on, 'is_active', v.is_active, 'created_at', v.created_at,
               'used', round(v.value - v.balance, 2),
               'customer_name', c.name,
               'status', case when not v.is_active then 'cancelled'
                              when v.balance <= 0 then 'used'
                              when v.expires_on is not null and v.expires_on < current_date then 'expired'
                              else 'active' end
             ) as x
        from public.vouchers v
        left join public.customers c on c.id = v.customer_id
       where (v_q is null or v.code ilike '%' || v_q || '%' or coalesce(v.issued_to,'') ilike '%' || v_q || '%'
              or coalesce(v.phone,'') like '%' || v_q || '%')
       order by v.created_at desc
       limit coalesce(public.fx_num(p,'limit',300),300)::int
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

create or replace function public.voucher_balance(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text := upper(trim(coalesce(public.fx_txt(p,'code'),''))); v_row public.vouchers;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if v_code = '' then perform public.fx_fail('MISSING_CODE','Type the voucher code.'); end if;
  select * into v_row from public.vouchers where upper(code) = v_code;
  if not found then perform public.fx_fail('VOUCHER_INVALID','Voucher ' || v_code || ' was not found.'); end if;
  if not v_row.is_active then perform public.fx_fail('VOUCHER_INACTIVE','That voucher has been cancelled.'); end if;
  if v_row.expires_on is not null and v_row.expires_on < current_date then
    perform public.fx_fail('VOUCHER_EXPIRED','That voucher expired on ' || to_char(v_row.expires_on,'DD-Mon-YYYY') || '.');
  end if;
  return jsonb_build_object('code', v_row.code, 'balance', v_row.balance, 'value', v_row.value,
                            'kind', v_row.kind, 'customer_name',
                            (select name from public.customers where id = v_row.customer_id),
                            'expires_on', v_row.expires_on);
end $$;

create or replace function public.cancel_voucher(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.vouchers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  update public.vouchers set is_active = false where id = v_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','Voucher not found.'); end if;
  perform public.fx_audit('voucher.cancel','vouchers', v_id::text,
    jsonb_build_object('code', v_row.code, 'balance_lost', v_row.balance), p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  8. OFFERS (buy X get Y free)
-- =====================================================================
create or replace function public.save_offer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.offers;
  v_buy numeric := public.fx_num(p,'buy_qty',0);
  v_free numeric := public.fx_num(p,'free_qty',0);
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Give the offer a name.'); end if;
  if v_buy <= 0 or v_free <= 0 then
    perform public.fx_fail('BAD_OFFER','An offer needs both a "buy" and a "get free" quantity above zero.');
  end if;
  if public.fx_uuid(p,'product_id') is null and public.fx_uuid(p,'category_id') is null then
    perform public.fx_fail('NEED_TARGET','Choose either a product or a whole category for this offer.');
  end if;
  if public.fx_uuid(p,'product_id') is not null and public.fx_uuid(p,'category_id') is not null then
    perform public.fx_fail('ONE_TARGET','Choose a product or a category, not both.');
  end if;

  if v_id is null then
    insert into public.offers(name, product_id, category_id, buy_qty, free_qty, starts_on, ends_on, is_active, created_by)
    values (public.fx_txt(p,'name'), public.fx_uuid(p,'product_id'), public.fx_uuid(p,'category_id'),
            v_buy, v_free, public.fx_date(p,'starts_on'),
            public.fx_date(p,'ends_on'), public.fx_bool(p,'is_active',true), auth.uid())
    returning * into v_row;
  else
    update public.offers set name = public.fx_txt(p,'name'),
      product_id = public.fx_uuid(p,'product_id'), category_id = public.fx_uuid(p,'category_id'),
      buy_qty = v_buy, free_qty = v_free,
      starts_on = public.fx_date(p,'starts_on'),
      ends_on = public.fx_date(p,'ends_on'),
      is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
    if not found then perform public.fx_fail('NOT_FOUND','Offer not found.'); end if;
  end if;

  perform public.fx_audit('offer.save','offers', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'buy', v_row.buy_qty, 'free', v_row.free_qty), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_offer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.offers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_row from public.offers where id = v_id;
  if not found then perform public.fx_fail('NOT_FOUND','Offer not found.'); end if;
  delete from public.offers where id = v_id;
  perform public.fx_audit('offer.delete','offers', v_id::text, jsonb_build_object('name', v_row.name), p_device);
  return jsonb_build_object('deleted', true);
end $$;

create or replace function public.list_offers()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', o.id, 'name', o.name, 'product_id', o.product_id, 'category_id', o.category_id,
               'buy_qty', o.buy_qty, 'free_qty', o.free_qty, 'starts_on', o.starts_on, 'ends_on', o.ends_on,
               'is_active', o.is_active, 'created_at', o.created_at,
               'product_name', pr.name, 'category_name', c.name,
               'target', coalesce(pr.name, c.name, 'all'),
               'running', (o.is_active and (o.starts_on is null or o.starts_on <= current_date)
                           and (o.ends_on is null or o.ends_on >= current_date)),
               'times_used', (select count(*) from public.audit_logs a
                               where a.action = 'offer.applied' and a.details->>'offer_id' = o.id::text),
               'free_value_given', (select coalesce(sum((a.details->>'free_value')::numeric),0)
                                      from public.audit_logs a
                                     where a.action = 'offer.applied' and a.details->>'offer_id' = o.id::text)
             ) as x
        from public.offers o
        left join public.products pr on pr.id = o.product_id
        left join public.categories c on c.id = o.category_id
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

-- =====================================================================
--  9. BUYER / OWNER REPORTS  (profit per product, cashier scoreboard, dead stock)
-- =====================================================================
create or replace function public.profit_by_product(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := public.fx_date(p,'from', current_date - 30);
  v_to   date := public.fx_date(p,'to', current_date);
  v_limit int := coalesce(public.fx_num(p,'limit',200),200)::int;
  v_order text := case when public.fx_txt(p,'order') = 'qty' then 'qty_sold' else 'profit' end;
  v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>v_order)::numeric desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'product_id', si.product_id, 'name', si.name_snapshot, 'unit', si.unit,
               'qty_sold', sum(si.qty),
               'gross', round(sum(si.line_total), 2),
               'discount', round(sum(si.line_discount), 2),
               'cost', round(sum(si.cost_price * si.qty), 2),
               'profit', round(sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end), 2),
               'margin', case when sum(si.line_total) > 0
                    then round(sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end) / sum(si.line_total) * 100, 1)
                    else 0 end,
               'invoices', count(distinct si.sale_id)
             ) as x
        from public.sale_items si
        join public.sales s on s.id = si.sale_id
       where s.status = 'completed' and s.created_at::date between v_from and v_to
       group by si.product_id, si.name_snapshot, si.unit
       order by sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end) desc
       limit v_limit
    ) t;
  return jsonb_build_object('rows', v_rows, 'from', v_from, 'to', v_to);
end $$;

create or replace function public.cashier_performance(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := public.fx_date(p,'from', current_date - 30);
  v_to   date := public.fx_date(p,'to', current_date);
  v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'sales')::numeric desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'cashier_id', s.cashier_id, 'cashier', s.cashier_name,
               'sales', round(sum(s.total), 2), 'invoices', count(*), 'items', sum(s.item_count),
               'discounts_given', round(sum(s.line_discount_total + s.invoice_discount_amount), 2),
               'average_bill', round(avg(s.total), 2),
               'voids', (select count(*) from public.sales v where v.status = 'void' and v.cashier_id = s.cashier_id
                          and v.created_at::date between v_from and v_to),
               'refunds', (select coalesce(sum(r.refund_amount),0) from public.returns r
                            where r.created_by = s.cashier_id and r.created_at::date between v_from and v_to),
               'profit', round(sum(s.profit), 2)
             ) as x
        from public.sales s
       where s.status = 'completed' and s.created_at::date between v_from and v_to
       group by s.cashier_id, s.cashier_name
    ) t;
  return jsonb_build_object('rows', v_rows, 'from', v_from, 'to', v_to);
end $$;

create or replace function public.dead_stock(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_days int := coalesce(public.fx_num(p,'days',60),60)::int;
  v_rows jsonb; v_value numeric := 0;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'value')::numeric desc), '[]'::jsonb),
         coalesce(sum((x->>'value')::numeric), 0)
    into v_rows, v_value
    from (
      select jsonb_build_object(
               'id', pr.id, 'name', pr.name, 'barcode', pr.barcode, 'unit', pr.unit,
               'category_name', c.name, 'stock_qty', pr.stock_qty, 'cost_price', pr.cost_price,
               'value', round(pr.stock_qty * pr.cost_price, 2),
               'sale_price', pr.sale_price,
               'last_sold_at', (select max(s.created_at) from public.sale_items si
                                  join public.sales s on s.id = si.sale_id
                                 where si.product_id = pr.id and s.status = 'completed'),
               'days_idle', coalesce((select (current_date - max(s.created_at)::date) from public.sale_items si
                                  join public.sales s on s.id = si.sale_id
                                 where si.product_id = pr.id and s.status = 'completed'), 9999),
               'expiry_date', pr.expiry_date
             ) as x
        from public.products pr
        left join public.categories c on c.id = pr.category_id
       where pr.is_active and not pr.is_deleted and pr.stock_qty > 0
         and not exists (select 1 from public.sale_items si join public.sales s on s.id = si.sale_id
                          where si.product_id = pr.id and s.status = 'completed'
                            and s.created_at::date > current_date - v_days)
    ) t;
  return jsonb_build_object('rows', v_rows, 'value_tied_up', v_value, 'days', v_days);
end $$;

-- =====================================================================
--  10. WHAT THE TILL SEES (view updated with the new product fields)
-- =====================================================================
drop view if exists public.v_products_pos;
create view public.v_products_pos with (security_invoker = true) as
  select sl.product_id as id, sl.barcode, sl.name, sl.unit, sl.sale_price, sl.tax_percent,
         sl.stock_qty, sl.reorder_level, sl.category_id, sl.category_name,
         sl.is_active, sl.expiry_date, sl.shelf_location, sl.is_weighed, sl.updated_at,
         (sl.stock_qty <= sl.reorder_level) as is_low_stock,
         p.wholesale_price, p.wholesale_min_qty, p.plu_code, p.is_expiry_tracked,
         p.brand, p.pack_size, p.cost_price
    from public.stock_levels sl
    join public.products p on p.id = sl.product_id;
grant select on public.v_products_pos to authenticated;

-- the batches the till should warn about (expired or nearly expired)
drop view if exists public.v_expiring_stock;
create view public.v_expiring_stock with (security_invoker = true) as
  select b.id, b.product_id, pr.name as product_name, pr.barcode, pr.unit, b.batch_no,
         b.expiry_date, b.qty_remaining,
         (b.expiry_date - current_date) as days_left,
         case when b.expiry_date < current_date then 'expired' else 'expiring' end as status
    from public.product_batches b
    join public.products pr on pr.id = b.product_id
   where b.is_active and b.qty_remaining > 0 and b.expiry_date is not null
     and b.expiry_date <= current_date + 30;
grant select on public.v_expiring_stock to authenticated;

-- =====================================================================
--  11. LOCATION / SAFETY NETS
-- =====================================================================
-- sequences used above
create sequence if not exists public.purchase_return_seq;

-- row level security on every new table (reads only; writes go through RPCs)
do $$
declare t text;
begin
  foreach t in array array['product_batches','price_tiers','offers','vouchers',
                           'voucher_redemptions','purchase_returns','purchase_return_items'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

grant select on public.product_batches, public.price_tiers, public.offers, public.vouchers,
                public.voucher_redemptions, public.purchase_returns, public.purchase_return_items
  to authenticated;

revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
grant execute on all functions in schema public to authenticated;
grant select on all tables in schema public to authenticated;

-- make sure the new sequence can be used by the invoice-number helpers
grant usage, select on all sequences in schema public to authenticated;

-- =====================================================================
--  SECTION: 06_operations.sql
-- =====================================================================
-- =====================================================================
--  SUPERMART POS  --  06 : SHOP OPERATIONS (run AFTER 05)
--
--  Adds: manager PIN override, expenses, activity log, supplier payables,
--        stock take, reorder-to-purchase-order, shop backup, weighed items.
--  Everything here is safe to run twice and safe to run on a live database.
-- =====================================================================

-- =====================================================================
--  1. NEW COLUMNS AND TABLES
-- =====================================================================
alter table public.profiles add column if not exists manager_pin_hash text;
alter table public.profiles add column if not exists pin_updated_at    timestamptz;

-- Weighing scale settings: how a scale barcode is laid out.
--   scale_barcode_prefix : the leading digits your scale prints (usually 22 or 27)
--   scale_barcode_mode   : 'weight' = the rest encodes grams, 'price' = encodes rupees
alter table public.stores   add column if not exists scale_barcode_prefix text    not null default '';
alter table public.stores   add column if not exists scale_barcode_mode   text    not null default 'weight';
alter table public.stores   add column if not exists loyalty_point_value  numeric(8,2) not null default 0;

-- Loose goods sold by weight (atta, rice, sugar, fresh produce)
alter table public.products      add column if not exists is_weighed boolean not null default false;
alter table public.stock_levels  add column if not exists is_weighed boolean not null default false;

-- Money paid out to suppliers. Kept separate from purchase_orders so the
-- paper trail stays clean: a purchase is what came in, a payment is what left.
create table if not exists public.supplier_payments (
  id             uuid primary key default gen_random_uuid(),
  payment_no     text unique not null,
  supplier_id    uuid not null references public.suppliers(id) on delete restrict,
  supplier_name  text,
  amount         numeric(14,2) not null default 0,
  payment_method public.payment_method not null default 'cash',
  reference_no   text,
  note           text,
  paid_at        timestamptz not null default now(),
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists supplier_payments_supplier_idx on public.supplier_payments(supplier_id, paid_at desc);

-- Stock take: count the shelves, let the system work out the difference.
create table if not exists public.stock_takes (
  id            uuid primary key default gen_random_uuid(),
  take_no       text unique not null,
  status        text not null default 'open',          -- open | completed | cancelled
  note          text,
  expected_rows int  not null default 0,
  counted_rows  int  not null default 0,
  variance_value numeric(14,2) not null default 0,
  started_by    uuid references public.profiles(id) on delete set null,
  started_at    timestamptz not null default now(),
  completed_by  uuid references public.profiles(id) on delete set null,
  completed_at  timestamptz
);
create index if not exists stock_takes_status_idx on public.stock_takes(status, started_at desc);

create table if not exists public.stock_take_items (
  id           uuid primary key default gen_random_uuid(),
  take_id      uuid not null references public.stock_takes(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete cascade,
  name_snapshot text,
  barcode      text,
  expected_qty numeric(12,3) not null default 0,
  counted_qty  numeric(12,3),
  variance     numeric(12,3),
  counted_at   timestamptz,
  counted_by   uuid references public.profiles(id) on delete set null,
  unique (take_id, product_id)
);
create index if not exists stock_take_items_take_idx on public.stock_take_items(take_id);

create sequence if not exists public.stock_take_seq start 1000;
create sequence if not exists public.payment_seq    start 1000;

-- ---- security on the new tables (same rules as everything else) ------
do $$ begin
  alter table public.supplier_payments enable row level security;
  alter table public.stock_takes       enable row level security;
  alter table public.stock_take_items  enable row level security;
exception when others then null; end $$;

select public.fx_drop_policy('supplier_payments','supplier_payments_read');
create policy supplier_payments_read on public.supplier_payments for select to authenticated
  using (public.fx_is_manager());

select public.fx_drop_policy('stock_takes','stock_takes_read');
create policy stock_takes_read on public.stock_takes for select to authenticated
  using (public.fx_is_manager());

select public.fx_drop_policy('stock_take_items','stock_take_items_read');
create policy stock_take_items_read on public.stock_take_items for select to authenticated
  using (public.fx_is_manager());

do $$ begin
  execute 'revoke all on public.supplier_payments from anon';
  execute 'revoke all on public.stock_takes from anon';
  execute 'revoke all on public.stock_take_items from anon';
  execute 'grant select on public.supplier_payments, public.stock_takes, public.stock_take_items to authenticated';
  execute 'revoke insert, update, delete, truncate, references, trigger on public.supplier_payments from authenticated';
  execute 'revoke insert, update, delete, truncate, references, trigger on public.stock_takes from authenticated';
  execute 'revoke insert, update, delete, truncate, references, trigger on public.stock_take_items from authenticated';
exception when others then null; end $$;

-- =====================================================================
--  2. KEEP THE CASHIER MIRROR UP TO DATE (now carries is_weighed)
-- =====================================================================
create or replace function public.fx_sync_stock_levels()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_category text;
begin
  if tg_op = 'DELETE' then
    delete from public.stock_levels where product_id = old.id;
    return old;
  end if;

  select c.name into v_category from public.categories c where c.id = new.category_id;

  insert into public.stock_levels (
    product_id, barcode, name, unit, sale_price, tax_percent, stock_qty, reorder_level,
    category_id, category_name, is_active, is_deleted, expiry_date, shelf_location,
    is_weighed, updated_at)
  values (
    new.id, new.barcode, new.name, new.unit, new.sale_price, new.tax_percent, new.stock_qty,
    new.reorder_level, new.category_id, v_category, new.is_active, new.is_deleted,
    new.expiry_date, new.shelf_location, coalesce(new.is_weighed,false), now())
  on conflict (product_id) do update set
    barcode = excluded.barcode, name = excluded.name, unit = excluded.unit,
    sale_price = excluded.sale_price, tax_percent = excluded.tax_percent,
    stock_qty = excluded.stock_qty, reorder_level = excluded.reorder_level,
    category_id = excluded.category_id, category_name = excluded.category_name,
    is_active = excluded.is_active, is_deleted = excluded.is_deleted,
    expiry_date = excluded.expiry_date, shelf_location = excluded.shelf_location,
    is_weighed = excluded.is_weighed,
    updated_at = now();
  return new;
end $$;

-- backfill the mirror for products that already exist
update public.stock_levels sl
   set is_weighed = p.is_weighed
  from public.products p
 where p.id = sl.product_id and sl.is_weighed is distinct from p.is_weighed;

-- views that expose the new flag
-- (recreated rather than replaced: the new column changes the view's shape)
drop view if exists public.v_products_pos;
create view public.v_products_pos with (security_invoker = true) as
  select sl.product_id as id, sl.barcode, sl.name, sl.unit, sl.sale_price, sl.tax_percent,
         sl.stock_qty, sl.reorder_level, sl.category_id, sl.category_name,
         sl.is_active, sl.expiry_date, sl.shelf_location, sl.is_weighed, sl.updated_at,
         (sl.stock_qty <= sl.reorder_level) as is_low_stock
    from public.stock_levels sl;
grant select on public.v_products_pos to authenticated;

create or replace function public.set_product_weighed(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_flag boolean := public.fx_bool(p,'is_weighed',false); v_row public.products;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  update public.products set is_weighed = v_flag, updated_by = auth.uid()
   where id = v_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;
  perform public.fx_audit('product.weighed','products', v_id::text,
    jsonb_build_object('name', v_row.name, 'is_weighed', v_flag), p_device);
  return to_jsonb(v_row);
end $$;

-- scale settings on the store (plus the loyalty rate, which the till can now show)
create or replace function public.save_scale_settings(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_store public.stores; v_prefix text := coalesce(public.fx_txt(p,'scale_barcode_prefix'),'');
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_prefix <> '' and v_prefix !~ '^[0-9]{1,3}$' then
    perform public.fx_fail('BAD_PREFIX','The scale barcode prefix must be 1 to 3 digits (usually 22 or 27).');
  end if;

  update public.stores set
    scale_barcode_prefix = v_prefix,
    scale_barcode_mode   = case when public.fx_txt(p,'scale_barcode_mode') = 'price' then 'price' else 'weight' end,
    loyalty_point_value  = coalesce(public.fx_num(p,'loyalty_point_value', loyalty_point_value), loyalty_point_value)
   where is_default
  returning * into v_store;

  perform public.fx_audit('settings.scale','stores', v_store.id::text,
    jsonb_build_object('prefix', v_store.scale_barcode_prefix, 'mode', v_store.scale_barcode_mode,
                       'point_value', v_store.loyalty_point_value), p_device);
  return to_jsonb(v_store);
end $$;

-- =====================================================================
--  3. MANAGER PIN OVERRIDE
--     A cashier can finish a sale that needs approval (a discount above
--     their limit, a void, a refund) by typing the manager's 4-6 digit PIN
--     AT THE TILL -- the manager does not have to sign in and lose the cart.
--
--     How it stays safe: the PIN is only ever checked on the server, and the
--     sale is then run AS THE MANAGER for that one call, so every existing
--     rule (role gates, discount ceilings, audit trail) still applies.
-- =====================================================================
create or replace function public.set_manager_pin(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_pin   text := trim(coalesce(p->>'pin',''));
  v_who   uuid := coalesce(public.fx_uuid(p,'profile_id'), auth.uid());
  v_me    public.profiles;
  v_row   public.profiles;
begin
  if length(v_pin) < 4 or length(v_pin) > 8 or v_pin !~ '^[0-9]+$' then
    perform public.fx_fail('BAD_PIN','Choose a PIN of 4 to 8 digits.');
  end if;

  select * into v_me from public.profiles where id = auth.uid();
  if not found then perform public.fx_fail('NO_PROFILE','You are not signed in properly.'); end if;

  -- you may always set your own PIN; only the Super Admin may set someone else's
  if v_who <> auth.uid() and v_me.role <> 'super_admin' then
    perform public.fx_fail('NOT_ALLOWED','Only the Super Admin can set another person''s PIN.');
  end if;

  update public.profiles
     set manager_pin_hash = crypt(v_pin, gen_salt('bf')),
         pin_updated_at   = now()
   where id = v_who and is_active
  returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','That staff member was not found.'); end if;

  perform public.fx_audit('staff.pin_set','profiles', v_who::text,
    jsonb_build_object('by', v_me.username, 'for', v_row.username, 'role', v_row.role), p_device);
  return jsonb_build_object('ok', true, 'profile_id', v_who, 'changed_at', v_row.pin_updated_at);
end $$;

create or replace function public.clear_manager_pin(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_who uuid := coalesce(public.fx_uuid(p,'profile_id'), auth.uid());
  v_me  public.profiles;
begin
  select * into v_me from public.profiles where id = auth.uid();
  if v_who <> auth.uid() and coalesce(v_me.role::text,'') <> 'super_admin' then
    perform public.fx_fail('NOT_ALLOWED','Only the Super Admin can remove another person''s PIN.');
  end if;
  update public.profiles set manager_pin_hash = null, pin_updated_at = now() where id = v_who;
  perform public.fx_audit('staff.pin_clear','profiles', v_who::text, '{}'::jsonb, p_device);
  return jsonb_build_object('ok', true);
end $$;

-- Does ANY manager/admin have a PIN? The till uses this to decide whether to
-- offer the "manager PIN" box at all.
create or replace function public.pin_ready()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.profiles
     where is_active and manager_pin_hash is not null
       and role in ('manager','admin','super_admin'));
$$;

-- internal: find the manager behind a PIN (never returns anything to the client)
create or replace function public.fx_pin_manager(p_pin text)
returns uuid language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if p_pin is null or length(trim(p_pin)) < 4 then return null; end if;
  select id into v_id from public.profiles
   where is_active
     and manager_pin_hash is not null
     and role in ('manager','admin','super_admin')
     and manager_pin_hash = crypt(trim(p_pin), manager_pin_hash)
   limit 1;
  return v_id;
end $$;

-- internal: run the rest of THIS transaction as that manager
create or replace function public.fx_elevate(p_pin text, p_about text default 'override')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_mgr uuid := public.fx_pin_manager(p_pin); v_cashier uuid := auth.uid();
begin
  if v_mgr is null then
    perform public.fx_fail('PIN_WRONG','That manager PIN is not correct. Ask the manager to type it again.');
  end if;
  if v_mgr = v_cashier then return v_mgr; end if;

  -- Superabase reads request.jwt.claim.sub, the local test shim reads jwt.claim.sub
  perform set_config('jwt.claim.sub',         v_mgr::text, true);
  perform set_config('request.jwt.claim.sub', v_mgr::text, true);
  perform set_config('request.jwt.claims',
    (coalesce(nullif(current_setting('request.jwt.claims', true),''),'{}')::jsonb
      || jsonb_build_object('sub', v_mgr::text))::text, true);

  -- leave a trail: who approved, for whom, what for (this is your theft alarm).
  -- Written AFTER the elevation so the manager is recorded as the approver,
  -- with the cashier named in the details.
  perform public.fx_audit('override.pin', 'sales', null,
    jsonb_build_object('approved_for', v_cashier, 'for_user',
      (select coalesce(username, full_name, 'cashier') from public.profiles where id = v_cashier),
      'about', p_about), null);

  return v_mgr;
end $$;

-- the till now rings sales through this wrapper (identical to create_sale, just
-- with the optional PIN). Safe for ordinary sales: no PIN means no elevation.
create or replace function public.pos_sale(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pin text := nullif(trim(coalesce(p->>'manager_pin','')), '');
begin
  if v_pin is not null then
    perform public.fx_elevate(v_pin, 'sale');
  end if;
  return public.create_sale(p - 'manager_pin', p_device);
end $$;

create or replace function public.pos_void_sale(p_sale_id uuid, p_reason text default null,
                                                p_pin text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pin text := nullif(trim(coalesce(p_pin,'')), '');
begin
  if v_pin is not null then perform public.fx_elevate(v_pin, 'void sale'); end if;
  return public.void_sale(p_sale_id, p_reason, p_device);
end $$;

create or replace function public.pos_create_return(p jsonb, p_pin text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pin text := nullif(trim(coalesce(p_pin,'')), '');
begin
  if v_pin is not null then perform public.fx_elevate(v_pin, 'refund'); end if;
  return public.create_return(p, p_device);
end $$;

-- =====================================================================
--  4. EXPENSES  (the till could already SAVE them - now the shop can SEE them)
-- =====================================================================
create or replace function public.list_expenses(p_from date default null, p_to date default null,
                                                p_limit int default 300)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_from timestamptz; v_to timestamptz;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  v_from := coalesce(p_from, current_date - 30)::timestamptz;
  v_to   := (coalesce(p_to, current_date) + 1)::timestamptz;

  select coalesce(jsonb_agg(x order by x->>'spent_at' desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', e.id, 'category', e.category, 'description', e.description,
               'amount', e.amount, 'payment_method', e.payment_method,
               'reference_no', e.reference_no, 'spent_at', e.spent_at,
               'by_name', coalesce(pr.full_name, pr.username)) as x
        from public.expenses e
        left join public.profiles pr on pr.id = e.created_by
       where e.spent_at >= v_from and e.spent_at < v_to
       order by e.spent_at desc
       limit greatest(1, least(coalesce(p_limit,300), 2000))) s;

  return jsonb_build_object('rows', v_rows,
    'total', coalesce((select sum(e.amount) from public.expenses e
                        where e.spent_at >= v_from and e.spent_at < v_to), 0));
end $$;

create or replace function public.delete_expense(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.expenses;
begin
  perform public.fx_require_role(array['admin','super_admin']);
  delete from public.expenses where id = p_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','That expense was not found.'); end if;
  perform public.fx_audit('expense.delete','expenses', p_id::text,
    jsonb_build_object('category', v_row.category, 'amount', v_row.amount), p_device);
  return jsonb_build_object('ok', true);
end $$;

-- =====================================================================
--  5. ACTIVITY LOG  (every RPC already writes here - now you can read it)
-- =====================================================================
create or replace function public.list_activity(p_limit int default 300, p_from date default null,
                                                p_to date default null, p_actor uuid default null,
                                                p_action text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_from timestamptz; v_to timestamptz;
begin
  perform public.fx_require_role(array['admin','super_admin']);
  v_from := coalesce(p_from, current_date - 30)::timestamptz;
  v_to   := (coalesce(p_to, current_date) + 1)::timestamptz;

  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', a.id, 'at', a.created_at, 'action', a.action,
               'entity', a.entity, 'entity_id', a.entity_id,
               'actor_id', a.actor_id,
               'actor_name', coalesce(a.actor_name, pr.full_name, pr.username, 'system'),
               'actor_role', coalesce(a.actor_role::text, pr.role::text, '-'),
               'device_name', a.device_name, 'detail', coalesce(a.details, '{}'::jsonb)) as x
        from public.audit_logs a
        left join public.profiles pr on pr.id = a.actor_id
       where a.created_at >= v_from and a.created_at < v_to
         and (p_actor is null or a.actor_id = p_actor)
         and (p_action is null or a.action = p_action)
       order by a.created_at desc
       limit greatest(1, least(coalesce(p_limit,300), 3000))) s;

  return jsonb_build_object('rows', v_rows);
end $$;

-- =====================================================================
--  6. SUPPLIER PAYABLES  ("who do I owe, and how much?")
-- =====================================================================
create or replace function public.supplier_payables()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'supplier_id', s.id,
               'name', s.name,
               'phone', s.phone,
               'city', s.city,
               'purchases', coalesce(po.total, 0),
               'paid', coalesce(po.paid, 0),
               'outstanding', coalesce(po.total, 0) - coalesce(po.paid, 0),
               'last_purchase_at', po.last_at,
               'unpaid_orders', coalesce(po.unpaid_count, 0)) as x
        from public.suppliers s
        left join (
          select supplier_id,
                 sum(total) as total,
                 sum(paid_amount) as paid,
                 max(coalesce(received_at, created_at)) as last_at,
                 count(*) filter (where total > paid_amount) as unpaid_count
            from public.purchase_orders
           where status = 'received'          -- only goods that actually arrived
           group by supplier_id
        ) po on po.supplier_id = s.id
       where coalesce(po.total, 0) - coalesce(po.paid, 0) > 0.009
          or coalesce(po.total, 0) > 0) s;

  return jsonb_build_object('rows', v_rows,
    'total_outstanding', coalesce((select sum(total - paid_amount) from public.purchase_orders
                                    where status = 'received' and total > paid_amount), 0));
end $$;

-- pay a supplier: the money is recorded, then applied to their oldest unpaid
-- purchases first, so the "unpaid" figure on each order stays truthful.
create or replace function public.pay_supplier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_supplier public.suppliers;
  v_amount   numeric := round(coalesce(public.fx_num(p,'amount',0),0), 2);
  v_left     numeric;
  v_po       record;
  v_apply    numeric;
  v_pay      public.supplier_payments;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_amount <= 0 then perform public.fx_fail('BAD_AMOUNT','Enter how much you are paying.'); end if;

  select * into v_supplier from public.suppliers where id = public.fx_uuid(p,'supplier_id');
  if not found then perform public.fx_fail('NOT_FOUND','Choose the supplier you paid.'); end if;

  insert into public.supplier_payments(payment_no, supplier_id, supplier_name, amount,
        payment_method, reference_no, note, created_by)
  values (public.fx_next_no('PAY','public.payment_seq',5), v_supplier.id, v_supplier.name, v_amount,
        coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
        public.fx_txt(p,'reference_no'), public.fx_txt(p,'note'), auth.uid())
  returning * into v_pay;

  v_left := v_amount;
  for v_po in
    select id, total, paid_amount from public.purchase_orders
     where supplier_id = v_supplier.id and total > paid_amount
     order by coalesce(received_at, created_at) asc
  loop
    exit when v_left <= 0;
    v_apply := least(v_left, v_po.total - v_po.paid_amount);
    update public.purchase_orders
       set paid_amount = paid_amount + v_apply,
           status = case when status = 'draft' then 'received' else status end
     where id = v_po.id;
    v_left := v_left - v_apply;
  end loop;

  perform public.fx_audit('supplier.paid','supplier_payments', v_pay.id::text,
    jsonb_build_object('supplier', v_supplier.name, 'amount', v_amount,
                       'unapplied', round(v_left,2)), p_device);

  return jsonb_build_object('payment_id', v_pay.id, 'payment_no', v_pay.payment_no,
    'supplier_name', v_supplier.name, 'amount', v_amount,
    'unapplied', round(v_left,2),
    'outstanding', coalesce((select sum(total - paid_amount) from public.purchase_orders
                              where supplier_id = v_supplier.id), 0));
end $$;

create or replace function public.supplier_ledger(p_supplier_id uuid, p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_supplier public.suppliers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_supplier from public.suppliers where id = p_supplier_id;
  if not found then perform public.fx_fail('NOT_FOUND','Supplier not found.'); end if;

  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into v_rows
    from (
      select * from (
        select jsonb_build_object('at', coalesce(po.received_at, po.created_at), 'kind', 'purchase',
                 'ref', po.po_no, 'debit', 0, 'credit', po.total, 'note', po.invoice_ref) as x
          from public.purchase_orders po where po.supplier_id = p_supplier_id
         union all
        select jsonb_build_object('at', sp.paid_at, 'kind', 'payment',
                 'ref', sp.payment_no, 'debit', sp.amount, 'credit', 0, 'note', sp.note) as x
          from public.supplier_payments sp where sp.supplier_id = p_supplier_id
      ) u
      order by x->>'at' desc
      limit greatest(1, least(coalesce(p_limit,200), 1000))
    ) s;

  return jsonb_build_object('supplier', jsonb_build_object('id', v_supplier.id, 'name', v_supplier.name,
           'phone', v_supplier.phone, 'city', v_supplier.city),
    'rows', v_rows,
    'purchased', coalesce((select sum(total) from public.purchase_orders where supplier_id = p_supplier_id),0),
    'paid', coalesce((select sum(amount) from public.supplier_payments where supplier_id = p_supplier_id),0));
end $$;

-- =====================================================================
--  7. STOCK TAKE  (count the shelf, let the system post the difference)
-- =====================================================================
create or replace function public.start_stock_take(p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.stock_takes;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  select * into v_row from public.stock_takes where status = 'open' order by started_at desc limit 1;
  if found then return to_jsonb(v_row); end if;   -- one open count at a time

  insert into public.stock_takes(take_no, note, started_by)
  values (public.fx_next_no('STK','public.stock_take_seq',5), p_note, auth.uid())
  returning * into v_row;

  perform public.fx_audit('stocktake.start','stock_takes', v_row.id::text,
    jsonb_build_object('take_no', v_row.take_no), null);
  return to_jsonb(v_row);
end $$;

create or replace function public.current_stock_take()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.stock_takes;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_row from public.stock_takes where status = 'open' order by started_at desc limit 1;
  return case when found then to_jsonb(v_row) else null end;
end $$;

-- Count one item: scan its barcode (or pass the product id) and type the real qty.
create or replace function public.stock_take_count(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_take   uuid := public.fx_uuid(p,'take_id');
  v_qty    numeric := public.fx_num(p,'qty',0);
  v_bc     text := public.fx_txt(p,'barcode');
  v_prod   uuid := public.fx_uuid(p,'product_id');
  v_p      public.products;
  v_item   public.stock_take_items;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if not exists (select 1 from public.stock_takes where id = v_take and status = 'open') then
    perform public.fx_fail('NO_TAKE','Start a stock take first.');
  end if;

  if v_prod is null and v_bc is not null then
    select id into v_prod from public.products
     where (barcode = v_bc or barcode = regexp_replace(v_bc,'^0+','')) and is_deleted = false
     limit 1;
  end if;
  if v_prod is null then perform public.fx_fail('NOT_FOUND','No product matches that barcode.'); end if;

  select * into v_p from public.products where id = v_prod;

  insert into public.stock_take_items(take_id, product_id, name_snapshot, barcode,
        expected_qty, counted_qty, variance, counted_at, counted_by)
  values (v_take, v_p.id, v_p.name, v_p.barcode, v_p.stock_qty, v_qty, v_qty - v_p.stock_qty,
          now(), auth.uid())
  on conflict (take_id, product_id) do update set
    counted_qty = excluded.counted_qty,
    variance    = excluded.counted_qty - public.stock_take_items.expected_qty,
    counted_at  = now(),
    counted_by  = auth.uid()
  returning * into v_item;

  update public.stock_takes t
     set counted_rows = (select count(*) from public.stock_take_items i
                          where i.take_id = v_take and i.counted_qty is not null)
   where t.id = v_take;

  return jsonb_build_object('product', v_p.name, 'barcode', v_p.barcode,
    'expected', v_item.expected_qty, 'counted', v_item.counted_qty, 'variance', v_item.variance);
end $$;

create or replace function public.stock_take_detail(p_take_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_take public.stock_takes;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_take from public.stock_takes where id = p_take_id;
  if not found then perform public.fx_fail('NOT_FOUND','Stock take not found.'); end if;

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object('product_id', i.product_id, 'name', i.name_snapshot,
               'barcode', i.barcode, 'expected', i.expected_qty, 'counted', i.counted_qty,
               'variance', i.variance, 'counted_at', i.counted_at) as x
        from public.stock_take_items i where i.take_id = p_take_id) s;

  return jsonb_build_object('take', to_jsonb(v_take), 'rows', v_rows);
end $$;

-- Finish: post every difference to the ledger (so stock history explains itself)
create or replace function public.complete_stock_take(p_take_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_take public.stock_takes;
  v_rec  record;
  v_rows int := 0;
  v_value numeric := 0;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  select * into v_take from public.stock_takes where id = p_take_id and status = 'open';
  if not found then perform public.fx_fail('NOT_FOUND','That stock take is not open.'); end if;

  for v_rec in
    select i.product_id, i.variance, pr.cost_price, pr.name
      from public.stock_take_items i
      join public.products pr on pr.id = i.product_id
     where i.take_id = p_take_id and coalesce(i.variance,0) <> 0
  loop
    insert into public.inventory_movements(product_id, qty_change, movement_type, note, created_by)
    values (v_rec.product_id, v_rec.variance, 'adjustment',
            'Stock take ' || v_take.take_no, auth.uid());
    v_rows := v_rows + 1;
    v_value := v_value + (v_rec.variance * coalesce(v_rec.cost_price,0));
  end loop;

  update public.stock_takes
     set status = 'completed', completed_by = auth.uid(), completed_at = now(),
         variance_value = round(v_value, 2)
   where id = p_take_id returning * into v_take;

  perform public.fx_audit('stocktake.complete','stock_takes', p_take_id::text,
    jsonb_build_object('take_no', v_take.take_no, 'adjusted_items', v_rows,
                       'variance_value', v_take.variance_value), p_device);

  return jsonb_build_object('take_no', v_take.take_no, 'adjusted_items', v_rows,
    'variance_value', v_take.variance_value);
end $$;

create or replace function public.cancel_stock_take(p_take_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  update public.stock_takes set status = 'cancelled', completed_at = now(), completed_by = auth.uid()
   where id = p_take_id and status = 'open';
  if not found then perform public.fx_fail('NOT_FOUND','That stock take is not open.'); end if;
  perform public.fx_audit('stocktake.cancel','stock_takes', p_take_id::text, '{}'::jsonb, p_device);
  return jsonb_build_object('ok', true);
end $$;

-- =====================================================================
--  8. REORDER  ->  PURCHASE ORDER  (draft, then receive when it arrives)
-- =====================================================================
create or replace function public.reorder_list()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(to_jsonb(v) order by v.name), '[]'::jsonb) into v_rows from public.v_low_stock v;
  return jsonb_build_object('rows', v_rows);
end $$;

create or replace function public.create_purchase_order(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_supplier public.suppliers;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_po public.purchase_orders;
  v_subtotal numeric := 0;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if jsonb_array_length(v_items) = 0 then perform public.fx_fail('EMPTY_PO','Add at least one item.'); end if;

  select * into v_supplier from public.suppliers where id = public.fx_uuid(p,'supplier_id');
  if not found then perform public.fx_fail('NOT_FOUND','Choose a supplier for this order.'); end if;

  select coalesce(sum(round((x.qty) * (x.unit_cost), 2)), 0) into v_subtotal
    from jsonb_to_recordset(v_items) as x(product_id uuid, qty numeric, unit_cost numeric);

  insert into public.purchase_orders(po_no, supplier_id, supplier_name, status, order_date,
        expected_date, subtotal, total, note, created_by)
  values (public.fx_next_no(coalesce((select po_prefix from public.stores order by is_default desc, created_at limit 1),'PO'),
                            'public.po_seq', 5),
          v_supplier.id, v_supplier.name, 'draft',
          public.fx_date(p,'order_date', current_date),
          public.fx_date(p,'expected_date'),
          v_subtotal, v_subtotal, public.fx_txt(p,'note'), auth.uid())
  returning * into v_po;

  insert into public.purchase_items(purchase_id, product_id, name_snapshot, qty_ordered, qty_received, unit_cost, line_total)
  select v_po.id, x.product_id, pr.name, x.qty, 0, x.unit_cost, round(x.qty * x.unit_cost, 2)
    from jsonb_to_recordset(v_items) as x(product_id uuid, qty numeric, unit_cost numeric)
    join public.products pr on pr.id = x.product_id;

  perform public.fx_audit('purchase.create','purchase_orders', v_po.id::text,
    jsonb_build_object('po_no', v_po.po_no, 'supplier', v_supplier.name, 'total', v_subtotal), p_device);

  return jsonb_build_object('purchase_id', v_po.id, 'po_no', v_po.po_no, 'supplier_name', v_supplier.name,
    'items', jsonb_array_length(v_items), 'total', v_subtotal, 'status', 'draft');
end $$;

create or replace function public.draft_purchases()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object('id', po.id, 'po_no', po.po_no, 'supplier_id', po.supplier_id,
               'supplier_name', po.supplier_name, 'status', po.status, 'order_date', po.order_date,
               'expected_date', po.expected_date, 'created_at', po.created_at, 'total', po.total,
               'note', po.note,
               'item_count', (select count(*) from public.purchase_items pi where pi.purchase_id = po.id),
               'items', (select coalesce(jsonb_agg(jsonb_build_object(
                            'product_id', pi.product_id, 'name', pi.name_snapshot,
                            'qty', pi.qty_ordered, 'unit_cost', pi.unit_cost)), '[]'::jsonb)
                           from public.purchase_items pi where pi.purchase_id = po.id)) as x
        from public.purchase_orders po
       where po.status = 'draft') s;
  return jsonb_build_object('rows', v_rows);
end $$;

create or replace function public.delete_purchase(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_po public.purchase_orders;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_po from public.purchase_orders where id = p_id and status = 'draft';
  if not found then
    perform public.fx_fail('NOT_ALLOWED','Only a draft order can be deleted. Received orders are your stock history.');
  end if;
  delete from public.purchase_orders where id = p_id;
  perform public.fx_audit('purchase.delete','purchase_orders', p_id::text,
    jsonb_build_object('po_no', v_po.po_no), p_device);
  return jsonb_build_object('ok', true);
end $$;

-- =====================================================================
--  9. SHOP BACKUP  (free plan has no automatic backups - this is yours)
-- =====================================================================
create or replace function public.backup_bundle(p_from date default null, p_to date default null,
                                                p_row_limit int default 20000)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from timestamptz := coalesce(p_from, current_date - 365)::timestamptz;
  v_to   timestamptz := (coalesce(p_to, current_date) + 1)::timestamptz;
  v_cap  int := greatest(100, least(coalesce(p_row_limit,20000), 100000));
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  return jsonb_build_object(
    'generated_at', now(),
    'from', v_from, 'to', v_to,
    'store',        (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from public.stores s),
    'products',     (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', p.id, 'barcode', p.barcode, 'sku', p.sku, 'name', p.name, 'unit', p.unit,
                          'cost_price', p.cost_price, 'sale_price', p.sale_price, 'stock_qty', p.stock_qty,
                          'reorder_level', p.reorder_level, 'is_weighed', p.is_weighed,
                          'is_active', p.is_active, 'created_at', p.created_at)), '[]'::jsonb)
                     from public.products p where p.is_deleted = false limit v_cap),
    'customers',    (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', c.id, 'name', c.name, 'phone', c.phone, 'address', c.address,
                          'credit_limit', c.credit_limit, 'balance', c.balance,
                          'loyalty_points', c.loyalty_points, 'created_at', c.created_at)), '[]'::jsonb)
                     from public.customers c limit v_cap),
    'suppliers',    (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from public.suppliers s),
    'sales',        (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', s.id, 'invoice_no', s.invoice_no, 'created_at', s.created_at,
                          'cashier_name', s.cashier_name, 'customer_name', s.customer_name,
                          'device_name', s.device_name, 'item_count', s.item_count,
                          'payment_method', s.payment_method, 'subtotal', s.subtotal,
                          'line_discount_total', s.line_discount_total,
                          'invoice_discount_amount', s.invoice_discount_amount,
                          'discount_code', s.discount_code,
                          'tax_amount', s.tax_amount, 'total', s.total, 'cost_total', s.cost_total,
                          'profit', s.profit, 'paid_amount', s.paid_amount,
                          'change_amount', s.change_amount,
                          'refunded_amount', s.refunded_amount, 'status', s.status)), '[]'::jsonb)
                     from (select * from public.sales
                            where created_at >= v_from and created_at < v_to
                            order by created_at limit v_cap) s),
    'sale_items',   (select coalesce(jsonb_agg(jsonb_build_object(
                          'sale_id', si.sale_id, 'name_snapshot', si.name_snapshot,
                          'barcode_snapshot', si.barcode_snapshot, 'unit', si.unit,
                          'qty', si.qty, 'unit_price', si.unit_price, 'cost_price', si.cost_price,
                          'line_discount', si.line_discount, 'tax_amount', si.tax_amount,
                          'line_total', si.line_total, 'refunded_qty', si.refunded_qty)), '[]'::jsonb)
                     from public.sale_items si
                     join public.sales s2 on s2.id = si.sale_id
                    where s2.created_at >= v_from and s2.created_at < v_to limit (v_cap * 5)),
    'movements',    (select coalesce(jsonb_agg(jsonb_build_object(
                          'product_id', m.product_id, 'qty_change', m.qty_change,
                          'balance_after', m.balance_after, 'movement_type', m.movement_type,
                          'unit_cost', m.unit_cost, 'note', m.note,
                          'device_name', m.device_name, 'created_at', m.created_at)), '[]'::jsonb)
                     from (select * from public.inventory_movements
                            where created_at >= v_from and created_at < v_to
                            order by created_at limit (v_cap * 2)) m),
    'purchases',    (select coalesce(jsonb_agg(jsonb_build_object(
                          'id', po.id, 'po_no', po.po_no, 'supplier_name', po.supplier_name,
                          'status', po.status, 'total', po.total, 'paid_amount', po.paid_amount,
                          'created_at', po.created_at)), '[]'::jsonb)
                     from public.purchase_orders po
                    where po.created_at >= v_from and po.created_at < v_to limit v_cap),
    'supplier_payments', (select coalesce(jsonb_agg(to_jsonb(sp)), '[]'::jsonb)
                     from public.supplier_payments sp
                    where sp.paid_at >= v_from and sp.paid_at < v_to limit v_cap),
    'expenses',     (select coalesce(jsonb_agg(jsonb_build_object(
                          'category', e.category, 'description', e.description, 'amount', e.amount,
                          'payment_method', e.payment_method, 'spent_at', e.spent_at)), '[]'::jsonb)
                     from public.expenses e
                    where e.spent_at >= v_from and e.spent_at < v_to limit v_cap),
    'shifts',       (select coalesce(jsonb_agg(jsonb_build_object(
                          'shift_no', sh.shift_no, 'device_name', sh.device_name,
                          'opened_at', sh.opened_at, 'closed_at', sh.closed_at,
                          'opening_float', sh.opening_float, 'counted_cash', sh.counted_cash,
                          'expected_cash', sh.expected_cash, 'difference', sh.difference,
                          'total_sales', sh.total_sales, 'invoice_count', sh.invoice_count,
                          'status', sh.status)), '[]'::jsonb)
                     from public.shifts sh
                    where sh.opened_at >= v_from and sh.opened_at < v_to limit v_cap)
  );
end $$;

-- =====================================================================
--  10. LOYALTY REDEMPTION  (points were already being awarded on every sale)
-- =====================================================================
create or replace function public.loyalty_balance(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_c public.customers; v_rate numeric;
begin
  select * into v_c from public.customers where id = p_customer_id;
  if not found then perform public.fx_fail('NOT_FOUND','Customer not found.'); end if;
  select loyalty_point_value into v_rate from public.stores order by is_default desc, created_at limit 1;
  return jsonb_build_object('customer_id', v_c.id, 'name', v_c.name,
    'points', v_c.loyalty_points, 'point_value', coalesce(v_rate,0),
    'value', round(coalesce(v_c.loyalty_points,0) * coalesce(v_rate,0), 2));
end $$;

-- Redeem points against the current bill. Returns the rupee value so the till
-- can show it as a bill discount; the points are deducted straight away.
create or replace function public.redeem_loyalty_points(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id     uuid := public.fx_uuid(p,'customer_id');
  v_points int  := greatest(0, coalesce(public.fx_num(p,'points',0),0)::int);
  v_c      public.customers;
  v_rate   numeric;
  v_value  numeric;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if v_points <= 0 then perform public.fx_fail('BAD_AMOUNT','Enter how many points to use.'); end if;

  select * into v_c from public.customers where id = v_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','Attach a customer to the bill first.'); end if;
  if coalesce(v_c.loyalty_points,0) < v_points then
    perform public.fx_fail('NOT_ENOUGH_POINTS',
      v_c.name || ' only has ' || coalesce(v_c.loyalty_points,0) || ' points.');
  end if;

  select coalesce(loyalty_point_value,0) into v_rate
    from public.stores order by is_default desc, created_at limit 1;
  if coalesce(v_rate,0) <= 0 then
    perform public.fx_fail('NOT_ALLOWED','Set the loyalty point value in Settings before redeeming points.');
  end if;

  v_value := round(v_points * v_rate, 2);

  update public.customers set loyalty_points = loyalty_points - v_points where id = v_id;

  perform public.fx_audit('loyalty.redeem','customers', v_id::text,
    jsonb_build_object('points', v_points, 'value', v_value), p_device);

  return jsonb_build_object('customer_id', v_id, 'name', v_c.name, 'points_used', v_points,
    'value', v_value, 'points_left', coalesce(v_c.loyalty_points,0) - v_points);
end $$;

-- =====================================================================
--  11. GRANTS
-- =====================================================================
revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
grant execute on all functions in schema public to authenticated;
grant select on public.supplier_payments, public.stock_takes, public.stock_take_items to authenticated;

-- =====================================================================
--  8b. RECEIVE A SAVED ORDER
--      Same proven function as before, with one addition: if the till sends
--      the id of an existing draft order, that order is updated to 'received'
--      instead of a duplicate being created. (Generated from 03_rpc_api.sql
--      with only that branch added - the stock/ledger/cost logic is unchanged.)
-- =====================================================================
create or replace function public.receive_purchase(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_po_id uuid := public.fx_uuid(p,'id');
  v_po public.purchase_orders;
  v_supplier public.suppliers;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_subtotal numeric := 0; v_total numeric := 0; v_disc numeric := public.fx_num(p,'discount',0);
  v_tax numeric := public.fx_num(p,'tax_amount',0);
  v_qty numeric; v_cost numeric; v_sale numeric; v_new_cost numeric;
  v_po_no text;
  v_draft boolean := false;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  if jsonb_array_length(v_items) = 0 then perform public.fx_fail('EMPTY_PO','Add at least one item to the purchase.'); end if;

  -- Receiving a saved order (from the Reorder list or a draft PO)? Then we
  -- update that very order instead of creating a second one, so the shop has
  -- one paper trail per delivery: draft -> received.
  if v_po_id is not null then
    select * into v_po from public.purchase_orders
     where id = v_po_id and status in ('draft','ordered');
    if found then
      v_draft := true;
      v_po_no := v_po.po_no;
    end if;
  end if;

  select * into v_supplier from public.suppliers
   where id = coalesce(public.fx_uuid(p,'supplier_id'), case when v_draft then v_po.supplier_id end);
  if not found then perform public.fx_fail('NOT_FOUND','Supplier not found.'); end if;

  v_po_no := coalesce(public.fx_txt(p,'po_no'),
    public.fx_next_no(coalesce((select po_prefix from public.stores order by is_default desc, created_at limit 1),'PO'),
                      'public.po_seq', 5));

  create temp table if not exists _po_lines (
    product_id uuid, qty numeric, unit_cost numeric, sale_price numeric, line_total numeric) on commit drop;
  delete from _po_lines where true;
  insert into _po_lines(product_id, qty, unit_cost, sale_price, line_total)
  select x.product_id, x.qty, x.unit_cost, x.sale_price, round(x.qty * x.unit_cost, 2)
    from jsonb_to_recordset(v_items) as x(product_id uuid, qty numeric, unit_cost numeric, sale_price numeric);

  v_subtotal := (select coalesce(sum(line_total),0) from _po_lines);
  v_total := round(v_subtotal - v_disc + v_tax, 2);

  if v_draft then
    -- the delivery arrived: fill in what actually came and close the order
    delete from public.purchase_items where purchase_id = v_po.id;
    update public.purchase_orders set
      supplier_id    = v_supplier.id,
      supplier_name  = v_supplier.name,
      status         = 'received',
      received_at    = now(),
      received_by    = auth.uid(),
      subtotal       = v_subtotal,
      discount       = v_disc,
      tax_amount     = v_tax,
      total          = v_total,
      paid_amount    = coalesce(paid_amount,0) + public.fx_num(p,'paid_amount',0),
      payment_method = coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
      invoice_ref    = coalesce(public.fx_txt(p,'invoice_ref'), invoice_ref),
      note           = coalesce(public.fx_txt(p,'note'), note)
     where id = v_po.id
    returning * into v_po;
  else
    insert into public.purchase_orders(po_no, supplier_id, supplier_name, status, order_date, expected_date,
      received_at, received_by, subtotal, discount, tax_amount, total, paid_amount, payment_method, invoice_ref, note, created_by)
    values (v_po_no, v_supplier.id, v_supplier.name, 'received',
            public.fx_date(p,'order_date', current_date),
            public.fx_date(p,'expected_date'), now(), auth.uid(),
            v_subtotal, v_disc, v_tax, v_total, public.fx_num(p,'paid_amount',0), 
            coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
            public.fx_txt(p,'invoice_ref'), public.fx_txt(p,'note'), auth.uid())
    returning * into v_po;
  end if;

  if exists (select 1 from _po_lines where qty is null or qty <= 0 or product_id is null) then
    perform public.fx_fail('BAD_QTY','Every purchase line needs a product and a quantity greater than zero.');
  end if;

  -- item rows + stock-in movements
  insert into public.purchase_items(purchase_id, product_id, name_snapshot, qty_ordered, qty_received, unit_cost, line_total)
  select v_po.id, l.product_id, pr.name, l.qty, l.qty, l.unit_cost, l.line_total
    from _po_lines l join public.products pr on pr.id = l.product_id;

  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, reference_id,
                                         unit_cost, note, device_name, created_by)
  select l.product_id, l.qty, 'purchase', 'purchase_order', v_po.id, l.unit_cost,
         'PO ' || v_po_no, p_device, auth.uid()
    from _po_lines l;

  -- weighted-average cost, and optional new retail price
  update public.products pr set
    cost_price = case
      when pr.stock_qty - l.qty > 0
        then round(((pr.cost_price * (pr.stock_qty - l.qty)) + (l.unit_cost * l.qty)) / pr.stock_qty, 2)
      else l.unit_cost end,
    sale_price = coalesce(l.sale_price, pr.sale_price),
    supplier_id = coalesce(v_supplier.id, pr.supplier_id),
    updated_by = auth.uid()
    from _po_lines l
   where pr.id = l.product_id;

  perform public.fx_audit('purchase.receive','purchase_orders', v_po.id::text,
    jsonb_build_object('po_no', v_po_no, 'supplier', v_supplier.name, 'total', v_total), p_device);

  return jsonb_build_object('purchase_id', v_po.id, 'po_no', v_po_no, 'supplier_name', v_supplier.name,
    'subtotal', v_subtotal, 'discount', v_disc, 'tax_amount', v_tax, 'total', v_total,
    'item_count', (select count(*) from _po_lines), 'unpaid', round(v_total - public.fx_num(p,'paid_amount',0), 2));
end $$;

-- =====================================================================
--  SECTION: 07_supermarket.sql
-- =====================================================================
-- #####################################################################
--  SUPERMART POS  --  SECTION 07: SUPERMARKET MODULE
--
--  The "big store" layer on top of 00-06. Everything here is additive and
--  safe to run on an existing shop (run it AFTER 06_operations.sql):
--
--    * batch + expiry tracking (goods received with a batch and an expiry date,
--      first-expire-first-out, expiry report, write-off of damaged/expired stock)
--    * quantity price tiers  (3 kg retail price vs 25 kg sack price)
--    * offers                (buy X get Y free, per product or per category)
--    * gift vouchers / store credit  (issue, redeem at the till, cancel)
--    * purchase returns to supplier  (damaged/expired goods back, payable down)
--    * buyer reports         (profit per product, cashier performance, dead stock)
--
--  Nothing that already worked is removed: the functions below are the same
--  proven ones from 03/06 with fields and branches added.
--  Safe to run more than once.
--  #####################################################################

-- a movement type for goods going back to the supplier (added to the enum;
-- harmless when the shop was installed from 00 of this version already)
do $$ begin
  alter type public.movement_type add value if not exists 'return_supplier';
exception when others then null; end $$;

-- =====================================================================
--  1. SCHEMA - new columns (all optional, so an existing shop keeps working)
-- =====================================================================
alter table public.products   add column if not exists wholesale_min_qty numeric(12,3) not null default 0;
alter table public.products   add column if not exists plu_code          text;
alter table public.products   add column if not exists is_expiry_tracked boolean not null default false;
alter table public.products   add column if not exists last_cost         numeric(12,2);
alter table public.products   add column if not exists last_sold_at      timestamptz;
alter table public.products   add column if not exists country_of_origin text;

alter table public.customers  add column if not exists cnic              text;
alter table public.customers  add column if not exists card_no           text;
alter table public.customers  add column if not exists area              text;

alter table public.profiles   add column if not exists cnic              text;
alter table public.profiles   add column if not exists address           text;
alter table public.profiles   add column if not exists designation       text;

alter table public.suppliers  add column if not exists credit_days       int not null default 0;
alter table public.suppliers  add column if not exists bank_name         text;
alter table public.suppliers  add column if not exists bank_account      text;
alter table public.suppliers  add column if not exists supplier_code     text;

alter table public.stores     add column if not exists expiry_alert_days int not null default 30;
alter table public.stores     add column if not exists block_expired_sales boolean not null default false;
alter table public.stores     add column if not exists enable_batches    boolean not null default true;
alter table public.stores     add column if not exists require_expiry    boolean not null default false;
alter table public.stores     add column if not exists enable_tiers      boolean not null default true;
alter table public.stores     add column if not exists enable_offers     boolean not null default true;
alter table public.stores     add column if not exists enable_vouchers   boolean not null default true;
alter table public.stores     add column if not exists invoice_note      text;
alter table public.stores     add column if not exists terms_and_conditions text;

alter table public.sales      add column if not exists voucher_code      text;
alter table public.sales      add column if not exists voucher_amount    numeric(12,2) not null default 0;

-- =====================================================================
--  2. SCHEMA - new tables
-- =====================================================================

-- Every delivery can arrive in batches, each with its own expiry date. The
-- shop sells from the batch that expires first (first-expire-first-out) and can
-- see what is about to go out of date before it is too late.
create table if not exists public.product_batches (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products(id) on delete cascade,
  batch_no     text,
  mfg_date     date,
  expiry_date  date,
  qty_received numeric(12,3) not null default 0,
  qty_remaining numeric(12,3) not null default 0,
  unit_cost    numeric(12,2) not null default 0,
  supplier_id  uuid references public.suppliers(id) on delete set null,
  purchase_id  uuid references public.purchase_orders(id) on delete set null,
  note         text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index if not exists product_batches_product_idx on public.product_batches(product_id);
create index if not exists product_batches_expiry_idx  on public.product_batches(expiry_date);
create index if not exists product_batches_open_idx    on public.product_batches(product_id, expiry_date)
  where qty_remaining > 0;

-- quantity pricing: "from 12 pcs, Rs 45 each"
create table if not exists public.price_tiers (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  min_qty    numeric(12,3) not null,
  price      numeric(12,2) not null,
  label      text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid
);
create index if not exists price_tiers_product_idx on public.price_tiers(product_id, min_qty);

-- buy X get Y free, per product or per whole category
create table if not exists public.offers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  product_id  uuid references public.products(id) on delete cascade,
  category_id uuid references public.categories(id) on delete cascade,
  buy_qty     numeric(12,3) not null default 1,
  free_qty    numeric(12,3) not null default 1,
  starts_on   date,
  ends_on     date,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists offers_active_idx on public.offers(is_active, starts_on, ends_on);

-- gift vouchers / store credit: money the shop already holds
create table if not exists public.vouchers (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  kind         text not null default 'gift',           -- gift | store_credit
  value        numeric(12,2) not null default 0,
  balance      numeric(12,2) not null default 0,
  customer_id  uuid references public.customers(id) on delete set null,
  issued_to    text,
  phone        text,
  reason       text,
  expires_on   date,
  is_active    boolean not null default true,
  last_used_at timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid
);

create table if not exists public.voucher_redemptions (
  id         uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.vouchers(id) on delete cascade,
  sale_id    uuid references public.sales(id) on delete set null,
  return_id  uuid,
  invoice_no text,
  amount     numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid
);

-- goods going back to the supplier (damaged, expired, wrong item)
create table if not exists public.purchase_returns (
  id            uuid primary key default gen_random_uuid(),
  return_no     text not null unique,
  supplier_id   uuid references public.suppliers(id) on delete set null,
  supplier_name text,
  purchase_id   uuid references public.purchase_orders(id) on delete set null,
  reason        text,
  note          text,
  total         numeric(12,2) not null default 0,
  settled_by    text not null default 'payable',    -- payable | cash | replacement
  created_at    timestamptz not null default now(),
  created_by    uuid
);

create table if not exists public.purchase_return_items (
  id            uuid primary key default gen_random_uuid(),
  return_id     uuid not null references public.purchase_returns(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete cascade,
  name_snapshot text,
  batch_id      uuid references public.product_batches(id) on delete set null,
  expiry_date   date,
  qty           numeric(12,3) not null default 0,
  unit_cost     numeric(12,2) not null default 0,
  line_total    numeric(12,2) not null default 0,
  reason        text
);
create index if not exists purchase_return_items_ret_idx on public.purchase_return_items(return_id);

-- =====================================================================
--  3. PRODUCTS, CUSTOMERS, SUPPLIERS, EMPLOYEES - extra fields on save
--     (same proven functions, just more columns understood)
-- =====================================================================
create or replace function public.save_product(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.products;
  v_barcode text := public.fx_txt(p,'barcode');
  v_sku text := public.fx_txt(p,'sku');
  v_opening numeric := public.fx_num(p,'opening_stock',0);
  v_expiry date := public.fx_date(p,'expiry_date');
  v_mfg date := public.fx_date(p,'mfg_date');
  v_batch text := nullif(public.fx_txt(p,'batch_no'), '');
  v_category_name text := trim(public.fx_txt(p,'category_name'));
  v_subcategory_name text := trim(public.fx_txt(p,'subcategory_name'));
  v_supplier_name text := trim(public.fx_txt(p,'supplier_name'));
  v_category_id uuid := public.fx_uuid(p,'category_id');
  v_supplier_id uuid := public.fx_uuid(p,'supplier_id');
  v_parent_id uuid := null;
  v_subcategory_id uuid := null;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  if v_category_name is not null and v_category_name <> '' then
    select c.id into v_parent_id
    from public.categories c
    where lower(trim(c.name)) = lower(v_category_name) and c.parent_id is null
    limit 1;

    if v_parent_id is null then
      insert into public.categories(name, description, parent_id, sort_order, is_active)
      values (v_category_name, public.fx_txt(p,'category_description'), null, 0, true)
      returning id into v_parent_id;
    end if;
  end if;

  if v_subcategory_name is not null and v_subcategory_name <> '' then
    if v_category_name is not null and v_category_name <> '' then
      select c.id into v_subcategory_id
      from public.categories c
      where lower(trim(c.name)) = lower(v_subcategory_name)
        and c.parent_id = v_parent_id
      limit 1;
    else
      select c.id into v_subcategory_id
      from public.categories c
      where lower(trim(c.name)) = lower(v_subcategory_name)
        and c.parent_id is null
      limit 1;
    end if;

    if v_subcategory_id is null then
      insert into public.categories(name, description, parent_id, sort_order, is_active)
      values (v_subcategory_name, public.fx_txt(p,'subcategory_description'), v_parent_id, 0, true)
      returning id into v_subcategory_id;
    end if;

    v_category_id := v_subcategory_id;
  elsif v_category_id is null and v_category_name is not null and v_category_name <> '' then
    v_category_id := v_parent_id;
  end if;

  if v_supplier_id is null and v_supplier_name is not null and v_supplier_name <> '' then
    select s.id into v_supplier_id
    from public.suppliers s
    where lower(trim(s.name)) = lower(v_supplier_name)
    limit 1;

    if v_supplier_id is null then
      insert into public.suppliers(name, is_active)
      values (v_supplier_name, true)
      returning id into v_supplier_id;
    end if;
  end if;

  if public.fx_txt(p,'name') is null then
    perform public.fx_fail('NAME_REQUIRED','Product name is required.');
  end if;
  if v_mfg is not null and v_expiry is not null and v_expiry < v_mfg then
    perform public.fx_fail('BAD_DATES','The expiry date cannot be before the manufacturing date.');
  end if;
  if v_expiry is not null and v_expiry < current_date - interval '30 days' then
    perform public.fx_fail('BAD_DATES','That expiry date is already in the past — please check it.');
  end if;
  if public.fx_num(p,'sale_price',0) < 0 or public.fx_num(p,'cost_price',0) < 0 then
    perform public.fx_fail('BAD_PRICE','Prices cannot be negative.');
  end if;
  if public.fx_num(p,'wholesale_price',0) > 0
     and public.fx_num(p,'wholesale_min_qty',0) <= 0 then
    perform public.fx_fail('NEED_TIER_QTY',
      'A wholesale price needs the quantity from which it applies (e.g. from 12 pcs).');
  end if;
  if v_barcode is not null and exists (select 1 from public.products x where x.barcode = v_barcode and x.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_BARCODE','Barcode ' || v_barcode || ' is already used by another product.');
  end if;
  if v_sku is not null and exists (select 1 from public.products x where x.sku = v_sku and x.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_SKU','SKU ' || v_sku || ' is already used by another product.');
  end if;

  if v_id is null then
    insert into public.products (
      sku, barcode, name, brand, category_id, supplier_id, unit, pack_size,
      cost_price, sale_price, wholesale_price, wholesale_min_qty, tax_percent, reorder_level,
      shelf_location, expiry_date, plu_code, is_weighed, is_expiry_tracked, country_of_origin,
      is_active, created_by, updated_by)
    values (
      v_sku, v_barcode, public.fx_txt(p,'name'), public.fx_txt(p,'brand'),
      v_category_id, v_supplier_id,
      coalesce(public.fx_txt(p,'unit'),'pcs'), public.fx_txt(p,'pack_size'),
      public.fx_num(p,'cost_price',0), public.fx_num(p,'sale_price',0),
      nullif(public.fx_txt(p,'wholesale_price'),'')::numeric,
      public.fx_num(p,'wholesale_min_qty',0),
      nullif(public.fx_txt(p,'tax_percent'),'')::numeric,
      public.fx_num(p,'reorder_level',5), public.fx_txt(p,'shelf_location'),
      v_expiry, public.fx_txt(p,'plu_code'),
      public.fx_bool(p,'is_weighed',false), public.fx_bool(p,'is_expiry_tracked', v_expiry is not null),
      public.fx_txt(p,'country_of_origin'),
      public.fx_bool(p,'is_active',true), auth.uid(), auth.uid())
    returning * into v_row;

    if v_opening <> 0 then
      insert into public.inventory_movements(product_id, qty_change, movement_type, note, device_name, created_by)
      values (v_row.id, v_opening, 'opening', 'Opening stock', p_device, auth.uid());

      if v_expiry is not null or v_batch is not null then
        insert into public.product_batches(product_id, batch_no, mfg_date, expiry_date,
                                           qty_received, qty_remaining,
                                           unit_cost, note, created_by)
        values (v_row.id, coalesce(v_batch,'OPENING'), v_mfg, v_expiry, v_opening,
                greatest(v_opening,0),
                public.fx_num(p,'cost_price',0), 'Opening stock', auth.uid());
      end if;
    end if;
  else
    update public.products set
      sku = v_sku, barcode = v_barcode, name = public.fx_txt(p,'name'),
      brand = public.fx_txt(p,'brand'),
      category_id = v_category_id,
      supplier_id = v_supplier_id,
      unit = coalesce(public.fx_txt(p,'unit'),'pcs'),
      pack_size = public.fx_txt(p,'pack_size'),
      cost_price = public.fx_num(p,'cost_price',0),
      sale_price = public.fx_num(p,'sale_price',0),
      wholesale_price = nullif(public.fx_txt(p,'wholesale_price'),'')::numeric,
      wholesale_min_qty = public.fx_num(p,'wholesale_min_qty',0),
      tax_percent = nullif(public.fx_txt(p,'tax_percent'),'')::numeric,
      reorder_level = public.fx_num(p,'reorder_level',5),
      shelf_location = public.fx_txt(p,'shelf_location'),
      expiry_date = v_expiry,
      plu_code = public.fx_txt(p,'plu_code'),
      is_weighed = public.fx_bool(p,'is_weighed',false),
      is_expiry_tracked = public.fx_bool(p,'is_expiry_tracked', v_expiry is not null),
      country_of_origin = public.fx_txt(p,'country_of_origin'),
      is_active = public.fx_bool(p,'is_active',true),
      updated_by = auth.uid()
    where id = v_id
    returning * into v_row;

    if not found then
      perform public.fx_fail('NOT_FOUND','Product not found.');
    end if;
  end if;

  perform public.fx_audit(case when v_id is null then 'product.create' else 'product.update' end,
    'products', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'barcode', v_row.barcode,
                       'category_id', v_row.category_id,
                       'sale_price', v_row.sale_price, 'expiry', v_row.expiry_date,
                       'weighed', v_row.is_weighed), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_customer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.customers; v_phone text := public.fx_txt(p,'phone');
        v_card text := public.fx_txt(p,'card_no');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Customer name is required.'); end if;
  if v_phone is not null and exists (select 1 from public.customers c where c.phone = v_phone and c.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_PHONE','Another customer already uses phone ' || v_phone || '.');
  end if;
  if v_card is not null and exists (select 1 from public.customers c where c.card_no = v_card and c.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_CARD','Membership card ' || v_card || ' is already given to someone else.');
  end if;

  if v_id is null then
    insert into public.customers(name, phone, email, address, area, cnic, card_no, credit_limit, notes, created_by)
    values (public.fx_txt(p,'name'), v_phone, public.fx_txt(p,'email'), public.fx_txt(p,'address'),
            public.fx_txt(p,'area'), public.fx_txt(p,'cnic'), v_card,
            public.fx_num(p,'credit_limit',0), public.fx_txt(p,'notes'), auth.uid())
    returning * into v_row;
  else
    update public.customers set name = public.fx_txt(p,'name'), phone = v_phone, email = public.fx_txt(p,'email'),
      address = public.fx_txt(p,'address'), area = public.fx_txt(p,'area'), cnic = public.fx_txt(p,'cnic'),
      card_no = v_card, credit_limit = public.fx_num(p,'credit_limit',0),
      notes = public.fx_txt(p,'notes'), is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('customer.save','customers', v_row.id::text, jsonb_build_object('name', v_row.name), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_supplier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.suppliers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Supplier name is required.'); end if;

  if v_id is null then
    insert into public.suppliers(name, contact_person, phone, email, address, city, ntn, supplier_code,
                                 bank_name, bank_account, credit_days, opening_balance, notes, is_active)
    values (public.fx_txt(p,'name'), public.fx_txt(p,'contact_person'), public.fx_txt(p,'phone'),
            public.fx_txt(p,'email'), public.fx_txt(p,'address'), public.fx_txt(p,'city'),
            public.fx_txt(p,'ntn'), public.fx_txt(p,'supplier_code'), public.fx_txt(p,'bank_name'),
            public.fx_txt(p,'bank_account'), coalesce(public.fx_num(p,'credit_days',0),0)::int,
            public.fx_num(p,'opening_balance',0), public.fx_txt(p,'notes'),
            public.fx_bool(p,'is_active',true))
    returning * into v_row;
  else
    update public.suppliers set name = public.fx_txt(p,'name'), contact_person = public.fx_txt(p,'contact_person'),
      phone = public.fx_txt(p,'phone'), email = public.fx_txt(p,'email'), address = public.fx_txt(p,'address'),
      city = public.fx_txt(p,'city'), ntn = public.fx_txt(p,'ntn'),
      supplier_code = public.fx_txt(p,'supplier_code'), bank_name = public.fx_txt(p,'bank_name'),
      bank_account = public.fx_txt(p,'bank_account'),
      credit_days = coalesce(public.fx_num(p,'credit_days',0),0)::int,
      opening_balance = public.fx_num(p,'opening_balance',0), notes = public.fx_txt(p,'notes'),
      is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
  end if;
  perform public.fx_audit('supplier.save','suppliers', v_row.id::text, jsonb_build_object('name', v_row.name), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.save_employee(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.profiles;
  v_role public.user_role := coalesce(public.fx_txt(p,'role'),'cashier')::public.user_role;
  v_me uuid := auth.uid();
begin
  perform public.fx_require_role(array['super_admin']);
  if v_id is null then
    perform public.fx_fail('NEED_LOGIN',
      'Create the login first (Admin > Employees > Add login), then set the job details here.');
  end if;
  if v_id = v_me and (v_role <> 'super_admin' or public.fx_bool(p,'is_active',true) = false) then
    perform public.fx_fail('LAST_ADMIN','You cannot remove your own Super Admin access.');
  end if;

  update public.profiles set
    full_name = coalesce(public.fx_txt(p,'full_name'), full_name),
    phone = public.fx_txt(p,'phone'),
    username = coalesce(public.fx_txt(p,'username'), username),
    role = v_role,
    is_active = public.fx_bool(p,'is_active',true),
    max_discount_percent = coalesce(nullif(public.fx_txt(p,'max_discount_percent'),'')::numeric,
                                    max_discount_percent),
    hired_on = public.fx_date(p,'hired_on'),
    salary = nullif(public.fx_txt(p,'salary'),'')::numeric,
    emergency_contact = public.fx_txt(p,'emergency_contact'),
    cnic = public.fx_txt(p,'cnic'),
    address = public.fx_txt(p,'address'),
    designation = public.fx_txt(p,'designation'),
    notes = public.fx_txt(p,'notes')
   where id = v_id
  returning * into v_row;

  if not found then perform public.fx_fail('NOT_FOUND','Employee not found.'); end if;

  perform public.fx_audit('employee.save','profiles', v_id::text,
    jsonb_build_object('role', v_row.role, 'active', v_row.is_active, 'max_discount', v_row.max_discount_percent), p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  2. THE TILL'S MONEY PATH, EXTENDED (create_sale + offers + vouchers + tiers)
--      Generated from 03_rpc_api.sql with three additions, nothing removed:
--        * quantity price tiers (bulk/wholesale price by how many are bought)
--        * buy-X-get-Y-free offers, charged as an automatic line discount that
--          never counts against a cashier's manual discount limit
--        * gift vouchers / store credit, taken as a part-payment so the cash
--          drawer and the shift cash-up stay exact
--      Callers keep using pos_sale (which handles the manager PIN).
-- =====================================================================
create or replace function public.create_sale(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_store public.stores;
  v_cuuid text := public.fx_txt(p,'client_uuid');
  v_exist public.sales;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_lines jsonb := '[]'::jsonb;
  v_line record;        -- rows from the staged cart
  v_prod public.products;
  v_qty numeric; v_price numeric; v_line_disc numeric; v_sell numeric;
  v_tax_pct numeric; v_tax numeric; v_line_total numeric; v_line_base numeric;
  v_subtotal numeric := 0; v_line_disc_total numeric := 0; v_tax_total numeric := 0;
  v_cost_total numeric := 0; v_profit_total numeric := 0; v_item_count int := 0;
  v_inv_type public.invoice_discount_type := 'none';
  v_inv_value numeric := 0; v_inv_amount numeric := 0;
  v_code text := upper(public.fx_txt(p,'discount_code'));
  v_disc public.discounts;
  v_total numeric := 0; v_paid numeric := 0; v_change numeric := 0;
  v_method public.payment_method;
  v_customer public.customers;
  v_customer_id uuid := public.fx_uuid(p,'customer_id');
  v_sale_id uuid; v_invoice_no text; v_shift_id uuid := public.fx_uuid(p,'shift_id');
  v_role text := public.fx_role();
  v_max_disc numeric;
  v_disc_percent numeric := 0;
  v_device text := coalesce(p_device, public.fx_txt(p,'device_name'));
  v_bad record;
  v_allow_negative boolean := public.fx_allow_negative_stock();
  v_auto_disc public.discounts;
  -- added by 07: automatic offers, gift vouchers, price tiers
  v_offer public.offers; v_offer_total numeric := 0; v_offer_disc numeric := 0; v_free numeric := 0;
  v_voucher public.vouchers; v_vcode text := upper(coalesce(public.fx_txt(p,'voucher_code'),''));
  v_voucher_amount numeric := 0; v_due numeric := 0; v_tier public.price_tiers; v_tier_price numeric;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);

  -- ---- idempotency: an offline sale replayed twice must not double-bill --
  if v_cuuid is not null then
    select * into v_exist from public.sales where client_uuid = v_cuuid;
    if found then
      return jsonb_build_object('sale_id', v_exist.id, 'invoice_no', v_exist.invoice_no,
        'total', v_exist.total, 'duplicate', true, 'created_at', v_exist.created_at);
    end if;
  end if;

  select * into v_profile from public.profiles where id = v_uid;
  select * into v_store from public.stores order by is_default desc, created_at limit 1;
  v_max_disc := coalesce(v_profile.max_discount_percent, v_store.max_cashier_discount_percent, 0);

  if jsonb_array_length(v_items) = 0 then
    perform public.fx_fail('EMPTY_CART','The cart is empty.');
  end if;

  -- ---- shift: attach to the cashier's open shift, or auto-open one ------
  if v_shift_id is null then
    select id into v_shift_id from public.shifts
     where cashier_id = v_uid and status = 'open' order by opened_at desc limit 1;
  end if;
  if v_shift_id is null then
    insert into public.shifts(shift_no, cashier_id, device_name, opening_float)
    values (public.fx_next_no('SHF','public.shift_seq',5), v_uid, v_device, 0)
    returning id into v_shift_id;
  end if;

  -- ---- stage the cart (set-based, deadlock-free) -----------------------
  create temp table if not exists _pos_lines (
    product_id uuid, qty numeric, unit_price numeric, line_discount numeric,
    name_snapshot text, barcode_snapshot text, unit text, cost_price numeric, tax_percent numeric
  ) on commit drop;
  delete from _pos_lines where true;

  insert into _pos_lines(product_id, qty, unit_price, line_discount, name_snapshot, barcode_snapshot, unit, cost_price, tax_percent)
  select nullif(trim(coalesce(x.product_id,'')),'')::uuid, x.qty, x.unit_price, coalesce(x.line_discount,0),
         nullif(trim(coalesce(x.name_snapshot,'')),'') ,
         nullif(trim(coalesce(x.barcode_snapshot,'')),'') ,
         nullif(trim(coalesce(x.unit,'')),'') ,
         coalesce(x.cost_price,0), coalesce(x.tax_percent,0)
    from jsonb_to_recordset(v_items) as x(
      product_id text, qty numeric, unit_price numeric, line_discount numeric,
      name_snapshot text, barcode_snapshot text, unit text, cost_price numeric, tax_percent numeric
    );

  if exists (select 1 from _pos_lines where qty is null or qty <= 0) then
    perform public.fx_fail('BAD_LINE','Every sale line needs a quantity greater than zero.');
  end if;

  -- lock every product row in a deterministic order: two tills selling at the
  -- same instant queue up here instead of deadlocking
  perform 1 from public.products pr
     join (select product_id, sum(qty) as q from _pos_lines where product_id is not null group by product_id) g on g.product_id = pr.id
    order by pr.id
      for update of pr;

  -- validate the cart against live data
  for v_bad in
    select pr.id, pr.name, pr.unit, pr.stock_qty, g.q as want, pr.is_active, pr.is_deleted, pr.sale_price, pr.cost_price
      from public.products pr
      join (select product_id, sum(qty) as q from _pos_lines where product_id is not null group by product_id) g on g.product_id = pr.id
  loop
    if v_bad.is_deleted or not v_bad.is_active then
      perform public.fx_fail('PRODUCT_INACTIVE', v_bad.name || ' is no longer for sale. Remove it from the cart.');
    end if;
    if not v_allow_negative and v_bad.stock_qty < v_bad.want then
      perform public.fx_fail('INSUFFICIENT_STOCK',
        v_bad.name || ' — only ' || trim(to_char(v_bad.stock_qty,'FM999999990.###')) || ' ' || v_bad.unit ||
        ' in stock, the cart needs ' || trim(to_char(v_bad.want,'FM999999990.###')));
    end if;
  end loop;

  -- price the cart from the live database (never trust the till's own numbers)
  for v_line in
    select l.product_id, l.qty, l.unit_price, l.line_discount, l.name_snapshot, l.barcode_snapshot, l.unit, l.cost_price, l.tax_percent,
           pr.name, pr.barcode, pr.unit as product_unit, pr.sale_price, pr.cost_price as product_cost_price, pr.tax_percent as product_tax_percent,
           pr.category_id, pr.is_active, pr.is_deleted
      from _pos_lines l
      left join public.products pr on pr.id = l.product_id
  loop
    v_qty := v_line.qty;
    v_price := coalesce(nullif(v_line.unit_price,0), coalesce(v_line.sale_price,0));

    if v_line.product_id is not null then
      -- quantity pricing (wholesale / bulk): the shop's own rule wins over the
      -- shelf price, so a 10-kg buyer is charged the tier they qualify for
      v_tier_price := null;
      if coalesce(v_store.enable_tiers, true) then
        select * into v_tier from public.price_tiers t
         where t.product_id = v_line.product_id and t.is_active and v_qty >= t.min_qty
         order by t.min_qty desc limit 1;
        if found and v_tier.price < v_price then
          v_price := v_tier.price;
        end if;
      end if;

      -- a till may charge less than the shelf price, but never more, unless a
      -- manager is signed in or the store allows price override
      if v_price > v_line.sale_price and not public.fx_is_manager() and not v_store.allow_price_override then
        perform public.fx_fail('PRICE_OVERRIDE_NOT_ALLOWED',
          'Price of ' || v_line.name || ' was changed from ' || to_char(v_line.sale_price,'FM999999990.00') ||
          '. Only a manager can override prices.');
      end if;

      -- automatic "buy X get Y free" offer (a shop rule, not a manual discount,
      -- so it is never counted against the cashier's discount limit)
      v_offer_disc := 0;
      v_offer := null;
      select * into v_offer from public.offers o
       where coalesce(v_store.enable_offers, true)
         and o.is_active
         and (o.starts_on is null or o.starts_on <= current_date)
         and (o.ends_on   is null or o.ends_on   >= current_date)
         and o.buy_qty > 0 and o.free_qty > 0
         and ((o.product_id is not null and o.product_id = v_line.product_id)
              or (o.category_id is not null and o.category_id = v_line.category_id))
         and v_qty >= (o.buy_qty + o.free_qty)
       order by (case when o.product_id is not null then 0 else 1 end), o.free_qty desc
       limit 1;
      if found then
        v_free := floor(v_qty / (v_offer.buy_qty + v_offer.free_qty)) * v_offer.free_qty;
        v_offer_disc := least(round(v_free * v_price, 2), round(v_price * v_qty, 2));
      end if;
    else
      v_offer_disc := 0;
    end if;

    v_line_disc := least(coalesce(v_line.line_discount,0), v_price * v_qty);
    v_line_disc := least(v_line_disc + v_offer_disc, v_price * v_qty);
    v_line_base := v_price * v_qty;
    v_sell := v_line_base - v_line_disc;

    v_tax_pct := coalesce(v_line.tax_percent, v_line.product_tax_percent,
                          case when v_store.tax_inclusive then 0 else v_store.tax_percent end, 0);
    v_tax := round(v_sell * v_tax_pct / 100.0, 2);
    if v_store.tax_inclusive then
      v_tax := round(v_sell - (v_sell / (1 + v_tax_pct/100.0)), 2);
      v_line_total := round(v_sell, 2);
    else
      v_line_total := round(v_sell + v_tax, 2);
    end if;

    v_subtotal := v_subtotal + round(v_sell, 2);
    v_line_disc_total := v_line_disc_total + v_line_disc;
    v_tax_total := v_tax_total + v_tax;
    if v_line.product_id is not null then
      v_cost_total := v_cost_total + round(coalesce(v_line.product_cost_price, v_line.cost_price, 0) * v_qty, 2);
    end if;
    v_offer_total := v_offer_total + v_offer_disc;
    v_item_count := v_item_count + 1;

    v_lines := v_lines || jsonb_build_object(
      'product_id', v_line.product_id,
      'name_snapshot', coalesce(v_line.name, v_line.name_snapshot, 'Custom item'),
      'barcode_snapshot', coalesce(v_line.barcode, v_line.barcode_snapshot),
      'unit', coalesce(v_line.product_unit, v_line.unit, 'pcs'),
      'qty', v_qty,
      'unit_price', v_price,
      'cost_price', coalesce(v_line.product_cost_price, v_line.cost_price, 0),
      'line_discount', v_line_disc,
      'tax_percent', v_tax_pct,
      'tax_amount', v_tax,
      'line_total', v_line_total);
  end loop;

  -- ---- invoice-level discount -----------------------------------------
  v_inv_type := coalesce(public.fx_txt(p,'invoice_discount_type'),'none')::public.invoice_discount_type;
  v_inv_value := public.fx_num(p,'invoice_discount_value',0);

  if v_code is not null then
    select * into v_disc from public.discounts
     where upper(coalesce(code,'')) = v_code and is_active
       and starts_at <= now() and (ends_at is null or ends_at >= now()) limit 1;
    if not found then
      perform public.fx_fail('CODE_INVALID','Discount code ' || v_code || ' is not valid or has expired.');
    end if;
    if v_disc.min_subtotal > 0 and v_subtotal < v_disc.min_subtotal then
      perform public.fx_fail('CODE_MIN_SUBTOTAL','Code ' || v_code || ' needs a minimum bill of ' || to_char(v_disc.min_subtotal,'FM999999990.00'));
    end if;
    if v_disc.max_uses is not null and v_disc.used_count >= v_disc.max_uses then
      perform public.fx_fail('CODE_EXHAUSTED','That discount code has been fully used.');
    end if;
    if v_disc.requires_manager and not public.fx_is_manager() then
      perform public.fx_fail('CODE_NEEDS_MANAGER','Code ' || v_code || ' needs a manager to authorise it.');
    end if;

    v_inv_type := 'code';
    v_inv_value := v_disc.value;
    if v_disc.kind = 'percent' then
      v_inv_amount := round(v_subtotal * v_disc.value / 100.0, 2);
    else
      v_inv_amount := v_disc.value;
    end if;
    if v_disc.max_discount is not null then v_inv_amount := least(v_inv_amount, v_disc.max_discount); end if;
    v_inv_amount := least(v_inv_amount, v_subtotal);

    update public.discounts set used_count = used_count + 1 where id = v_disc.id;
  elsif v_inv_type = 'percent' then
    if v_inv_value < 0 or v_inv_value > 100 then
      perform public.fx_fail('BAD_DISCOUNT','Discount percent must be between 0 and 100.');
    end if;
    v_inv_amount := round(v_subtotal * v_inv_value / 100.0, 2);
  elsif v_inv_type = 'amount' then
    if v_inv_value < 0 then perform public.fx_fail('BAD_DISCOUNT','Discount cannot be negative.'); end if;
    v_inv_amount := least(v_inv_value, v_subtotal);
  else
    -- automatic store-wide promotions the Super Admin switched on
    select * into v_auto_disc from public.discounts
     where is_active and applies_automatically and scope = 'all'
       and starts_at <= now() and (ends_at is null or ends_at >= now())
       and min_subtotal <= v_subtotal
       and (max_uses is null or used_count < max_uses)
     order by (case when kind = 'percent' then value else (value / greatest(v_subtotal,1) * 100) end) desc
     limit 1;
    if found then
      v_inv_type := 'code';
      v_code := v_auto_disc.code;
      v_inv_value := v_auto_disc.value;
      v_inv_amount := case when v_auto_disc.kind = 'percent'
                           then round(v_subtotal * v_auto_disc.value / 100.0, 2) else v_auto_disc.value end;
      if v_auto_disc.max_discount is not null then v_inv_amount := least(v_inv_amount, v_auto_disc.max_discount); end if;
      v_inv_amount := least(v_inv_amount, v_subtotal);
      update public.discounts set used_count = used_count + 1 where id = v_auto_disc.id;
    end if;
  end if;

  -- ---- cashier discount ceiling ---------------------------------------
  -- measured against the GROSS bill (before any line discounts), so a cashier
  -- giving exactly their limit is not refused for "rounding" reasons
  if v_role = 'cashier' and (v_subtotal + v_line_disc_total) > 0 then
    v_disc_percent := round(((v_line_disc_total - v_offer_total) + v_inv_amount) /
                            (v_subtotal + v_line_disc_total) * 100, 2);
    if v_disc_percent > v_max_disc then
      perform public.fx_fail('DISCOUNT_LIMIT',
        'That is a ' || trim(to_char(v_disc_percent,'FM990.0')) || '% discount but your limit is ' ||
        trim(to_char(v_max_disc,'FM990.0')) || '%. Ask a manager to authorise it.');
    end if;
  end if;

  v_total := round(greatest(v_subtotal - v_inv_amount, 0), 2);

  -- ---- payment ---------------------------------------------------------
  v_method := coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method;

  -- ---- gift voucher / store credit -------------------------------------
  -- Vouchers are money the shop already holds, so they act like a part-payment
  -- (never a discount): the drawer only takes the rest in cash.
  if v_vcode <> '' and not coalesce(v_store.enable_vouchers, true) then
    perform public.fx_fail('VOUCHERS_OFF',
      'Gift vouchers are switched off in Settings. Switch them on to accept a voucher.');
  end if;
  if v_vcode <> '' then
    select * into v_voucher from public.vouchers where upper(code) = v_vcode for update;
    if not found then
      perform public.fx_fail('VOUCHER_INVALID','Voucher ' || v_vcode || ' was not found.');
    end if;
    if not v_voucher.is_active then
      perform public.fx_fail('VOUCHER_INACTIVE','That voucher has been cancelled.');
    end if;
    if v_voucher.expires_on is not null and v_voucher.expires_on < current_date then
      perform public.fx_fail('VOUCHER_EXPIRED',
        'That voucher expired on ' || to_char(v_voucher.expires_on,'DD-Mon-YYYY') || '.');
    end if;
    if coalesce(v_voucher.balance,0) <= 0 then
      perform public.fx_fail('VOUCHER_EMPTY','That voucher has no balance left.');
    end if;
    if v_method = 'credit' then
      perform public.fx_fail('VOUCHER_WITH_CREDIT','A voucher cannot be used on an udhaar (credit) sale.');
    end if;
    v_voucher_amount := least(v_voucher.balance, v_total);
  end if;

  if v_customer_id is not null then
    select * into v_customer from public.customers where id = v_customer_id;
    if not found then perform public.fx_fail('NOT_FOUND','Customer not found.'); end if;
  end if;

  if v_method = 'credit' then
    if v_customer_id is null then
      perform public.fx_fail('CREDIT_NEEDS_CUSTOMER','Choose a customer account for a credit (udhaar) sale.');
    end if;
    if v_customer.credit_limit > 0 and (v_customer.balance + v_total) > v_customer.credit_limit then
      perform public.fx_fail('CREDIT_LIMIT',
        v_customer.name || ' already owes ' || to_char(v_customer.balance,'FM999999990.00') ||
        ' and the credit limit is ' || to_char(v_customer.credit_limit,'FM999999990.00') || '.');
    end if;
    v_paid := 0;
    update public.customers set balance = balance + v_total where id = v_customer_id;
  else
    v_due := round(greatest(v_total - v_voucher_amount, 0), 2);
    v_paid := coalesce(nullif(public.fx_num(p,'paid_amount',0),0), v_due);
    if v_method <> 'cash' then v_paid := greatest(v_paid, v_due); end if;
    if v_method = 'cash' and v_paid < v_due then
      perform public.fx_fail('INSUFFICIENT_PAYMENT',
        'Cash received (' || to_char(v_paid,'FM999999990.00') || ') is less than the amount due (' || to_char(v_due,'FM999999990.00') || ').');
    end if;
    v_change := greatest(round(v_paid - v_due, 2), 0);
  end if;

  -- ---- write the invoice ----------------------------------------------
  v_invoice_no := public.fx_next_no(coalesce(v_store.invoice_prefix,'INV'), 'public.invoice_seq', 6);

  insert into public.sales (
    client_uuid, invoice_no, store_id, cashier_id, cashier_name, shift_id, customer_id, customer_name,
    device_name, item_count, subtotal, line_discount_total, invoice_discount_type, invoice_discount_value,
    invoice_discount_amount, discount_code, tax_amount, total, cost_total, profit, paid_amount, change_amount,
    payment_method, payment_ref, status, note, offline_created, voucher_code, voucher_amount)
  values (
    v_cuuid, v_invoice_no, v_store.id, v_uid, coalesce(v_profile.full_name, v_profile.username), v_shift_id,
    v_customer_id, v_customer.name, v_device, v_item_count, round(v_subtotal,2), round(v_line_disc_total,2),
    v_inv_type, v_inv_value, round(v_inv_amount,2), v_code, round(v_tax_total,2), v_total,
    round(v_cost_total,2), round(v_profit_total,2), round(v_paid,2), v_change,
    v_method, public.fx_txt(p,'payment_ref'), 'completed', public.fx_txt(p,'note'),
    public.fx_bool(p,'offline_created',false), nullif(v_vcode,''), round(v_voucher_amount,2))
  returning id into v_sale_id;

  insert into public.sale_items (
    sale_id, product_id, name_snapshot, barcode_snapshot, unit, qty, unit_price, cost_price,
    line_discount, tax_percent, tax_amount, line_total)
    select v_sale_id,
      public.fx_uuid(jsonb_build_object('product_id', l->>'product_id'),'product_id'), l->>'name_snapshot', l->>'barcode_snapshot', l->>'unit',
         public.fx_num(jsonb_build_object('qty', l->>'qty'), 'qty', 0),
         public.fx_num(jsonb_build_object('unit_price', l->>'unit_price'), 'unit_price', 0),
         public.fx_num(jsonb_build_object('cost_price', l->>'cost_price'), 'cost_price', 0),
         public.fx_num(jsonb_build_object('line_discount', l->>'line_discount'), 'line_discount', 0),
         public.fx_num(jsonb_build_object('tax_percent', l->>'tax_percent'), 'tax_percent', 0),
         public.fx_num(jsonb_build_object('tax_amount', l->>'tax_amount'), 'tax_amount', 0),
         public.fx_num(jsonb_build_object('line_total', l->>'line_total'), 'line_total', 0)
    from jsonb_array_elements(v_lines) l
    where l->>'product_id' is not null and trim(l->>'product_id') <> '';

  -- every product-backed line writes an inventory movement; custom misc items are
  -- not stocked and therefore do not touch the stock ledger.
  insert into public.inventory_movements (
    product_id, qty_change, movement_type, reference_type, reference_id, unit_cost, note, device_name, created_by)
  select public.fx_uuid(jsonb_build_object('product_id', l->>'product_id'),'product_id'),
         -(public.fx_num(jsonb_build_object('qty', l->>'qty'), 'qty', 0)), 'sale', 'sale', v_sale_id,
         public.fx_num(jsonb_build_object('cost_price', l->>'cost_price'), 'cost_price', 0), v_invoice_no, v_device, v_uid
    from jsonb_array_elements(v_lines) l
    where l->>'product_id' is not null and trim(l->>'product_id') <> '';

  -- spend the voucher and keep the paper trail
  if v_voucher_amount > 0 then
    update public.vouchers
       set balance = round(balance - v_voucher_amount, 2), last_used_at = now()
     where id = v_voucher.id;
    insert into public.voucher_redemptions(voucher_id, sale_id, invoice_no, amount, created_by)
    values (v_voucher.id, v_sale_id, v_invoice_no, round(v_voucher_amount,2), v_uid);
  end if;

  -- loyalty points
  if v_customer_id is not null and coalesce(v_store.loyalty_points_per_100,0) > 0 then
    update public.customers
       set loyalty_points = loyalty_points + floor(v_total / 100.0 * v_store.loyalty_points_per_100)::int
     where id = v_customer_id;
  end if;

  perform public.fx_audit('sale.create','sales', v_sale_id::text,
    jsonb_build_object('invoice_no', v_invoice_no, 'total', v_total, 'items', v_item_count,
                       'payment_method', v_method, 'discount', v_inv_amount + v_line_disc_total,
                       'offer_discount', v_offer_total,
                       'voucher', nullif(v_vcode,''), 'voucher_amount', v_voucher_amount), v_device);

  if v_offer_total > 0 then
    perform public.fx_audit('offer.applied','sales', v_sale_id::text,
      jsonb_build_object('invoice_no', v_invoice_no, 'free_value', v_offer_total,
                         'offer_id', v_offer.id, 'offer_name', v_offer.name), v_device);
  end if;

  return jsonb_build_object(
    'sale_id', v_sale_id, 'invoice_no', v_invoice_no, 'created_at', now(),
    'item_count', v_item_count, 'subtotal', round(v_subtotal,2),
    'line_discount_total', round(v_line_disc_total,2), 'invoice_discount_amount', round(v_inv_amount,2),
    'discount_code', v_code, 'tax_amount', round(v_tax_total,2), 'total', v_total,
    'paid_amount', round(v_paid,2), 'change_amount', v_change,
    'voucher_code', nullif(v_vcode,''), 'voucher_amount', round(v_voucher_amount,2),
    'offer_discount', round(v_offer_total,2), 'amount_due', round(v_due,2),
    'payment_method', v_method, 'profit', round(v_profit_total, 2),
    'cashier_name', coalesce(v_profile.full_name, v_profile.username),
    'customer_name', v_customer.name, 'device_name', v_device,
    'shift_id', v_shift_id,
    'customer_balance', v_customer.balance,
    'duplicate', false,
    'lines', v_lines,
    'store', to_jsonb(v_store));
end $$;

-- =====================================================================
--  4. RECEIVING (purchase) with batches and expiry dates
--     Same proven function as 06, plus: every line may carry a batch number,
--     a manufacturing date and an expiry date. Those lines create a batch row,
--     and the product's "earliest expiry" is kept up to date.
-- =====================================================================
create or replace function public.receive_purchase(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_po_id uuid := public.fx_uuid(p,'id');
  v_po public.purchase_orders;
  v_supplier public.suppliers;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_subtotal numeric := 0; v_total numeric := 0; v_disc numeric := public.fx_num(p,'discount',0);
  v_tax numeric := public.fx_num(p,'tax_amount',0);
  v_po_no text;
  v_draft boolean := false;
  v_require_expiry boolean := (public.fx_store()).require_expiry;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);

  if jsonb_array_length(v_items) = 0 then perform public.fx_fail('EMPTY_PO','Add at least one item to the purchase.'); end if;

  -- Receiving a saved order (from the Reorder list or a draft PO)? Then we
  -- update that very order instead of creating a second one, so the shop has
  -- one paper trail per delivery: draft -> received.
  if v_po_id is not null then
    select * into v_po from public.purchase_orders
     where id = v_po_id and status in ('draft','ordered');
    if found then
      v_draft := true;
      v_po_no := v_po.po_no;
    end if;
  end if;

  select * into v_supplier from public.suppliers
   where id = coalesce(public.fx_uuid(p,'supplier_id'), case when v_draft then v_po.supplier_id end);
  if not found then perform public.fx_fail('NOT_FOUND','Supplier not found.'); end if;

  v_po_no := coalesce(public.fx_txt(p,'po_no'),
    public.fx_next_no(coalesce((select po_prefix from public.stores order by is_default desc, created_at limit 1),'PO'),
                      'public.po_seq', 5));

  create temp table if not exists _po_lines (
    product_id uuid, qty numeric, unit_cost numeric, sale_price numeric, line_total numeric,
    batch_no text, mfg_date date, expiry_date date) on commit drop;
  delete from _po_lines where true;
  insert into _po_lines(product_id, qty, unit_cost, sale_price, line_total, batch_no, mfg_date, expiry_date)
  select x.product_id, x.qty, x.unit_cost, x.sale_price, round(x.qty * x.unit_cost, 2),
         nullif(trim(coalesce(x.batch_no,'')),''), x.mfg_date, x.expiry_date
    from jsonb_to_recordset(v_items) as x(product_id uuid, qty numeric, unit_cost numeric, sale_price numeric,
                                          batch_no text, mfg_date date, expiry_date date);

  if exists (select 1 from _po_lines where qty is null or qty <= 0 or product_id is null) then
    perform public.fx_fail('BAD_QTY','Every purchase line needs a product and a quantity greater than zero.');
  end if;
  if v_require_expiry and exists (select 1 from _po_lines l join public.products pr on pr.id = l.product_id
                                   where pr.is_expiry_tracked and l.expiry_date is null) then
    perform public.fx_fail('EXPIRY_REQUIRED',
      'This store is set to record an expiry date for goods that go out of date. Fill it in for every such line.');
  end if;
  if exists (select 1 from _po_lines where expiry_date is not null and mfg_date is not null and expiry_date < mfg_date) then
    perform public.fx_fail('BAD_EXPIRY','An expiry date cannot be before the manufacturing date.');
  end if;

  v_subtotal := (select coalesce(sum(line_total),0) from _po_lines);
  v_total := round(v_subtotal - v_disc + v_tax, 2);

  if v_draft then
    delete from public.purchase_items where purchase_id = v_po.id;
    update public.purchase_orders set
      supplier_id    = v_supplier.id,
      supplier_name  = v_supplier.name,
      status         = 'received',
      received_at    = now(),
      received_by    = auth.uid(),
      subtotal       = v_subtotal,
      discount       = v_disc,
      tax_amount     = v_tax,
      total          = v_total,
      paid_amount    = coalesce(paid_amount,0) + public.fx_num(p,'paid_amount',0),
      payment_method = coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
      invoice_ref    = coalesce(public.fx_txt(p,'invoice_ref'), invoice_ref),
      note           = coalesce(public.fx_txt(p,'note'), note)
     where id = v_po.id
    returning * into v_po;
  else
    insert into public.purchase_orders(po_no, supplier_id, supplier_name, status, order_date, expected_date,
      received_at, received_by, subtotal, discount, tax_amount, total, paid_amount, payment_method, invoice_ref, note, created_by)
    values (v_po_no, v_supplier.id, v_supplier.name, 'received',
            public.fx_date(p,'order_date', current_date),
            public.fx_date(p,'expected_date'), now(), auth.uid(),
            v_subtotal, v_disc, v_tax, v_total, public.fx_num(p,'paid_amount',0),
            coalesce(public.fx_txt(p,'payment_method'),'cash')::public.payment_method,
            public.fx_txt(p,'invoice_ref'), public.fx_txt(p,'note'), auth.uid())
    returning * into v_po;
  end if;

  insert into public.purchase_items(purchase_id, product_id, name_snapshot, qty_ordered, qty_received, unit_cost, line_total)
  select v_po.id, l.product_id, pr.name, l.qty, l.qty, l.unit_cost, l.line_total
    from _po_lines l join public.products pr on pr.id = l.product_id;

  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, reference_id,
                                         unit_cost, note, device_name, created_by)
  select l.product_id, l.qty, 'purchase', 'purchase_order', v_po.id, l.unit_cost,
         'PO ' || v_po_no, p_device, auth.uid()
    from _po_lines l;

  -- weighted-average cost, retail price if the buyer changed it, last cost
  update public.products pr set
    cost_price = case
      when pr.stock_qty > 0 then round(((pr.stock_qty * pr.cost_price) + (l.qty * l.unit_cost)) / (pr.stock_qty + l.qty), 2)
      else l.unit_cost end,
    sale_price = case when coalesce(l.sale_price,0) > 0 then l.sale_price else pr.sale_price end,
    last_cost  = l.unit_cost,
    is_expiry_tracked = pr.is_expiry_tracked or l.expiry_date is not null,
    expiry_date = case
      when l.expiry_date is null then pr.expiry_date
      when pr.expiry_date is null then l.expiry_date
      else least(pr.expiry_date, l.expiry_date) end,
    updated_by = auth.uid()
    from _po_lines l
   where pr.id = l.product_id;

  -- the batches themselves
  insert into public.product_batches(product_id, batch_no, mfg_date, expiry_date, qty_received, qty_remaining,
                                     unit_cost, supplier_id, purchase_id, note, created_by)
  select l.product_id, l.batch_no, l.mfg_date, l.expiry_date, l.qty, l.qty,
         l.unit_cost, v_supplier.id, v_po.id, 'PO ' || v_po_no, auth.uid()
    from _po_lines l
   where l.expiry_date is not null or l.batch_no is not null;

  perform public.fx_audit('purchase.receive','purchase_orders', v_po.id::text,
    jsonb_build_object('po_no', v_po_no, 'supplier', v_supplier.name, 'total', v_total,
                       'items', jsonb_array_length(v_items),
                       'batches', (select count(*) from _po_lines where expiry_date is not null or batch_no is not null)),
    p_device);

  -- Same shape the rest of the system (and the reports) expect, plus the new
  -- batch information. `unpaid` is what is still owed to the supplier.
  return jsonb_build_object(
    'purchase_id', v_po.id,
    'po_no', v_po_no,
    'supplier_name', v_supplier.name,
    'status', v_po.status,
    'subtotal', round(v_subtotal, 2),
    'discount', round(v_disc, 2),
    'tax_amount', round(v_tax, 2),
    'total', round(v_total, 2),
    'paid_amount', round(public.fx_num(p,'paid_amount',0), 2),
    'item_count', jsonb_array_length(v_items),
    'unpaid', round(greatest(v_total - public.fx_num(p,'paid_amount',0), 0), 2),
    'batch_count', (select count(*) from _po_lines
                     where expiry_date is not null or batch_no is not null));
end $$;

-- =====================================================================
--  5. BATCHES + EXPIRY
-- =====================================================================
create or replace function public.list_batches(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_pid uuid := public.fx_uuid(p,'product_id');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'expiry_date') nulls last, x->>'product_name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', b.id, 'product_id', b.product_id, 'product_name', coalesce(pr.name,''),
               'barcode', pr.barcode, 'unit', pr.unit,
               'batch_no', b.batch_no, 'mfg_date', b.mfg_date, 'expiry_date', b.expiry_date,
               'qty_received', b.qty_received, 'qty_remaining', b.qty_remaining,
               'unit_cost', b.unit_cost, 'value', round(b.qty_remaining * b.unit_cost, 2),
               'supplier_name', s.name, 'po_no', po.po_no,
               'days_left', case when b.expiry_date is null then null else (b.expiry_date - current_date) end,
               'status', case when b.expiry_date is null then 'no-expiry'
                              when b.expiry_date < current_date then 'expired'
                              when (b.expiry_date - current_date) <= (select expiry_alert_days from public.stores order by is_default desc, created_at limit 1) then 'expiring'
                              else 'fresh' end
             ) as x
        from public.product_batches b
        join public.products pr on pr.id = b.product_id
        left join public.suppliers s on s.id = b.supplier_id
        left join public.purchase_orders po on po.id = b.purchase_id
       where b.is_active and b.qty_remaining > 0
         and (v_pid is null or b.product_id = v_pid)
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

create or replace function public.expiring_stock(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_days int := coalesce(public.fx_num(p,'days',30),30)::int;
  v_rows jsonb; v_expired jsonb; v_expiring jsonb; v_value numeric := 0;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'expiry_date'), x->>'product_name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', b.id, 'product_id', b.product_id, 'product_name', pr.name, 'barcode', pr.barcode,
               'unit', pr.unit, 'batch_no', b.batch_no, 'expiry_date', b.expiry_date,
               'qty_remaining', b.qty_remaining, 'unit_cost', b.unit_cost,
               'value', round(b.qty_remaining * b.unit_cost, 2),
               'days_left', (b.expiry_date - current_date),
               'supplier_name', s.name,
               'status', case when b.expiry_date < current_date then 'expired'
                              when (b.expiry_date - current_date) <= v_days then 'expiring'
                              else 'fresh' end
             ) as x
        from public.product_batches b
        join public.products pr on pr.id = b.product_id
        left join public.suppliers s on s.id = b.supplier_id
       where b.is_active and b.qty_remaining > 0 and b.expiry_date is not null
         and b.expiry_date <= current_date + v_days
    ) t;
  select
    coalesce(jsonb_agg(x) filter (where x->>'status' = 'expired'), '[]'::jsonb),
    coalesce(jsonb_agg(x) filter (where x->>'status' = 'expiring'), '[]'::jsonb),
    coalesce(sum((x->>'value')::numeric) filter (where x->>'status' <> 'fresh'), 0)
  into v_expired, v_expiring, v_value
  from jsonb_array_elements(v_rows) x;
  return jsonb_build_object('rows', v_rows, 'expired', v_expired, 'expiring', v_expiring,
                            'at_risk_value', v_value, 'days', v_days);
end $$;

-- Write off stock: damaged, expired, stolen, or a simple correction. Always
-- asks for a reason and always leaves a movement with the employee's name.
create or replace function public.write_off_stock(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_batch_id uuid := public.fx_uuid(p,'batch_id');
  v_prod_id  uuid := public.fx_uuid(p,'product_id');
  v_qty      numeric := public.fx_num(p,'qty',0);
  v_reason   text := coalesce(public.fx_txt(p,'reason'),'adjustment');
  v_note     text := public.fx_txt(p,'note');
  v_b public.product_batches; v_pr public.products;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_qty <= 0 then perform public.fx_fail('BAD_AMOUNT','Enter how many units to write off.'); end if;
  if v_reason not in ('expired','damaged','theft','lost','sample','adjustment','other') then
    perform public.fx_fail('BAD_REASON','Choose a write-off reason: expired, damaged, theft, lost, sample or other.');
  end if;

  if v_batch_id is not null then
    select * into v_b from public.product_batches where id = v_batch_id for update;
    if not found then perform public.fx_fail('NOT_FOUND','That batch was not found.'); end if;
    if v_qty > v_b.qty_remaining then
      perform public.fx_fail('QTY_TOO_BIG','Only ' || trim(to_char(v_b.qty_remaining,'FM999999990.###')) ||
        ' left in that batch.');
    end if;
    v_prod_id := v_b.product_id;
    update public.product_batches set qty_remaining = qty_remaining - v_qty where id = v_batch_id;
  end if;

  select * into v_pr from public.products where id = v_prod_id for update;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;
  if v_qty > v_pr.stock_qty then
    perform public.fx_fail('QTY_TOO_BIG', v_pr.name || ' only has ' ||
      trim(to_char(v_pr.stock_qty,'FM999999990.###')) || ' ' || v_pr.unit || ' in stock.');
  end if;

  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, unit_cost,
                                         note, device_name, created_by)
  values (v_prod_id, -v_qty, 'adjustment', 'write_off', v_pr.cost_price,
          'Write-off (' || v_reason || ')' || coalesce(' - ' || v_note,''), p_device, auth.uid());

  -- roll the product's earliest expiry forward once the batch is used up
  if v_batch_id is not null then
    update public.products p set expiry_date = (
      select min(b.expiry_date) from public.product_batches b
       where b.product_id = p.id and b.qty_remaining > 0 and b.expiry_date is not null)
      where p.id = v_prod_id;
  end if;

  perform public.fx_audit('stock.writeoff','products', v_prod_id::text,
    jsonb_build_object('product', v_pr.name, 'qty', v_qty, 'reason', v_reason,
                       'value', round(v_qty * v_pr.cost_price, 2), 'note', v_note,
                       'batch', v_b.batch_no), p_device);

  return jsonb_build_object('product', v_pr.name, 'qty', v_qty, 'reason', v_reason,
                            'value_lost', round(v_qty * v_pr.cost_price, 2),
                            'stock_left', v_pr.stock_qty - v_qty);
end $$;

-- =====================================================================
--  5a. STORE SETTINGS - the new big-shop switches
--      (expiry warnings, blocked expired sales, offers/vouchers on or off,
--      the note and terms printed on a proper invoice)
-- =====================================================================
create or replace function public.save_store_settings(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.stores; v_id uuid := public.fx_uuid(p,'id');
begin
  perform public.fx_require_role(array['admin','super_admin']);

  update public.stores set
    name = coalesce(public.fx_txt(p,'name'), name),
    legal_name = public.fx_txt(p,'legal_name'),
    address = public.fx_txt(p,'address'),
    phone = public.fx_txt(p,'phone'),
    email = public.fx_txt(p,'email'),
    ntn = public.fx_txt(p,'ntn'),
    currency_code = coalesce(public.fx_txt(p,'currency_code'), currency_code),
    currency_symbol = coalesce(public.fx_txt(p,'currency_symbol'), currency_symbol),
    tax_percent = public.fx_num(p,'tax_percent', tax_percent),
    tax_inclusive = public.fx_bool(p,'tax_inclusive', tax_inclusive),
    tax_label = coalesce(public.fx_txt(p,'tax_label'), tax_label),
    invoice_prefix = coalesce(public.fx_txt(p,'invoice_prefix'), invoice_prefix),
    po_prefix = coalesce(public.fx_txt(p,'po_prefix'), po_prefix),
    return_prefix = coalesce(public.fx_txt(p,'return_prefix'), return_prefix),
    receipt_header = public.fx_txt(p,'receipt_header'),
    receipt_footer = coalesce(public.fx_txt(p,'receipt_footer'), receipt_footer),
    receipt_paper_mm = coalesce(nullif(public.fx_txt(p,'receipt_paper_mm'),'')::int, receipt_paper_mm),
    print_logo = public.fx_bool(p,'print_logo', print_logo),
    max_cashier_discount_percent = public.fx_num(p,'max_cashier_discount_percent',
                                                  max_cashier_discount_percent),
    allow_price_override = public.fx_bool(p,'allow_price_override', allow_price_override),
    allow_negative_stock = public.fx_bool(p,'allow_negative_stock', allow_negative_stock),
    loyalty_points_per_100 = public.fx_num(p,'loyalty_points_per_100', loyalty_points_per_100),
    -- new in the big-shop module
    expiry_alert_days = coalesce(nullif(public.fx_txt(p,'expiry_alert_days'),'')::int, expiry_alert_days),
    block_expired_sales = public.fx_bool(p,'block_expired_sales', block_expired_sales),
    require_expiry = public.fx_bool(p,'require_expiry', require_expiry),
    enable_batches = public.fx_bool(p,'enable_batches', enable_batches),
    enable_tiers = public.fx_bool(p,'enable_tiers', enable_tiers),
    enable_offers = public.fx_bool(p,'enable_offers', enable_offers),
    enable_vouchers = public.fx_bool(p,'enable_vouchers', enable_vouchers),
    invoice_note = public.fx_txt(p,'invoice_note'),
    terms_and_conditions = public.fx_txt(p,'terms_and_conditions')
  where id = coalesce(v_id, (select id from public.stores order by is_default desc, created_at limit 1))
  returning * into v_row;

  if not found then
    perform public.fx_fail('NOT_FOUND','Store settings not found.');
  end if;

  perform public.fx_audit('store.settings','stores', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'expiry_alert_days', v_row.expiry_alert_days,
      'block_expired_sales', v_row.block_expired_sales, 'require_expiry', v_row.require_expiry,
      'offers', v_row.enable_offers, 'vouchers', v_row.enable_vouchers, 'tiers', v_row.enable_tiers),
    p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  5b. FIRST-EXPIRE-FIRST-OUT
--      Whenever stock leaves the shop (a sale, a refund's stock going back out,
--      a write-off, a return to the supplier), the quantity is taken off the
--      batches that expire first. Products with no batches are untouched.
-- =====================================================================
create or replace function public.fx_consume_batches()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_left numeric := -new.qty_change;   -- only called for stock going OUT
  v_b public.product_batches;
begin
  if new.qty_change >= 0 then return new; end if;
  if new.movement_type = 'purchase' then return new; end if;
  if not exists (select 1 from public.product_batches b
                  where b.product_id = new.product_id and b.qty_remaining > 0) then
    return new;
  end if;

  for v_b in
    select * from public.product_batches b
     where b.product_id = new.product_id and b.qty_remaining > 0
     order by (b.expiry_date is null), b.expiry_date, b.created_at
       for update
  loop
    exit when v_left <= 0;
    if v_b.qty_remaining >= v_left then
      update public.product_batches set qty_remaining = qty_remaining - v_left where id = v_b.id;
      v_left := 0;
    else
      update public.product_batches set qty_remaining = 0 where id = v_b.id;
      v_left := v_left - v_b.qty_remaining;
    end if;
  end loop;

  -- the product's "expires on" follows the oldest batch still on the shelf
  if v_left < -new.qty_change then
    update public.products p set expiry_date = (
      select min(b.expiry_date) from public.product_batches b
       where b.product_id = p.id and b.qty_remaining > 0 and b.expiry_date is not null)
     where p.id = new.product_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_consume_batches on public.inventory_movements;
create trigger trg_consume_batches
  after insert on public.inventory_movements
  for each row execute function public.fx_consume_batches();

-- An expired batch must never leave the till as a normal sale when the owner
-- has switched that guard on (Settings > stock rules).
create or replace function public.fx_block_expired_sale()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_block boolean := (public.fx_store()).block_expired_sales; v_b public.product_batches;
begin
  if not coalesce(v_block,false) or new.qty_change >= 0 or new.movement_type <> 'sale' then
    return new;
  end if;
  select * into v_b from public.product_batches b
   where b.product_id = new.product_id and b.qty_remaining > 0
     and b.expiry_date is not null and b.expiry_date < current_date
   order by b.expiry_date limit 1;
  if found then
    perform public.fx_fail('BATCH_EXPIRED',
      'This stock is past its expiry date (' || to_char(v_b.expiry_date,'DD-Mon-YYYY') ||
      '). Take it off the shelf, or write it off from the Expiry screen.');
  end if;
  return new;
end $$;

drop trigger if exists trg_block_expired_sale on public.inventory_movements;
create trigger trg_block_expired_sale
  before insert on public.inventory_movements
  for each row execute function public.fx_block_expired_sale();

-- =====================================================================
--  5c. PRICE TIERS - saving them (the app can only write through functions)
-- =====================================================================
create or replace function public.save_price_tier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_pid uuid := public.fx_uuid(p,'product_id');
  v_min numeric := public.fx_num(p,'min_qty',0);
  v_price numeric := public.fx_num(p,'price',0);
  v_row public.price_tiers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_pid is null then perform public.fx_fail('NEED_PRODUCT','Choose the product this price applies to.'); end if;
  if v_min <= 0 then perform public.fx_fail('BAD_QTY','Say how many units get this price (e.g. from 12).'); end if;
  if v_price <= 0 then perform public.fx_fail('BAD_PRICE','The tier price must be above zero.'); end if;

  if exists (select 1 from public.price_tiers t
              where t.product_id = v_pid and t.min_qty = v_min and t.id is distinct from v_id) then
    perform public.fx_fail('DUPLICATE_TIER','There is already a price for that quantity. Edit that one instead.');
  end if;

  if v_id is null then
    insert into public.price_tiers(product_id, min_qty, price, label, is_active, created_by)
    values (v_pid, v_min, v_price, nullif(public.fx_txt(p,'label'),''),
            public.fx_bool(p,'is_active',true), auth.uid())
    returning * into v_row;
  else
    update public.price_tiers set min_qty = v_min, price = v_price,
           label = nullif(public.fx_txt(p,'label'),''), is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
    if not found then perform public.fx_fail('NOT_FOUND','Price tier not found.'); end if;
  end if;

  perform public.fx_audit('tier.save','price_tiers', v_row.id::text,
    jsonb_build_object('product_id', v_row.product_id, 'from_qty', v_row.min_qty, 'price', v_row.price),
    p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_price_tier(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.price_tiers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_row from public.price_tiers where id = v_id;
  if not found then perform public.fx_fail('NOT_FOUND','Price tier not found.'); end if;
  delete from public.price_tiers where id = v_id;
  perform public.fx_audit('tier.delete','price_tiers', v_id::text,
    jsonb_build_object('product_id', v_row.product_id, 'from_qty', v_row.min_qty), p_device);
  return jsonb_build_object('deleted', true);
end $$;

-- =====================================================================
--  6. PURCHASE RETURNS (goods back to the supplier)
-- =====================================================================
create or replace function public.create_purchase_return(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_supplier public.suppliers;
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_return_no text;
  v_id uuid;
  v_total numeric := 0;
  v_settled text := coalesce(public.fx_txt(p,'settled_by'),'payable');
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if jsonb_array_length(v_items) = 0 then
    perform public.fx_fail('EMPTY_RETURN','Add at least one item to send back.');
  end if;

  select * into v_supplier from public.suppliers where id = public.fx_uuid(p,'supplier_id');
  if not found then perform public.fx_fail('NOT_FOUND','Supplier not found.'); end if;

  create temp table if not exists _pr_lines (
    product_id uuid, qty numeric, unit_cost numeric, batch_id uuid, expiry_date date, reason text) on commit drop;
  delete from _pr_lines where true;
  insert into _pr_lines(product_id, qty, unit_cost, batch_id, expiry_date, reason)
  select x.product_id, x.qty, x.unit_cost, x.batch_id, x.expiry_date, x.reason
    from jsonb_to_recordset(v_items) as x(product_id uuid, qty numeric, unit_cost numeric, batch_id uuid,
                                          expiry_date date, reason text);

  if exists (select 1 from _pr_lines where product_id is null or qty is null or qty <= 0) then
    perform public.fx_fail('BAD_QTY','Every returned line needs a product and a quantity greater than zero.');
  end if;
  if exists (select 1 from _pr_lines l join public.products pr on pr.id = l.product_id where l.qty > pr.stock_qty) then
    perform public.fx_fail('QTY_TOO_BIG','You cannot send back more than you have in stock.');
  end if;

  v_return_no := public.fx_next_no('PRT','public.purchase_return_seq',5);

  insert into public.purchase_returns(return_no, supplier_id, supplier_name, purchase_id, reason, note,
                                      total, settled_by, created_by)
  values (v_return_no, v_supplier.id, v_supplier.name, public.fx_uuid(p,'purchase_id'),
          public.fx_txt(p,'reason'), public.fx_txt(p,'note'), 0, v_settled, auth.uid())
  returning id into v_id;

  insert into public.purchase_return_items(return_id, product_id, name_snapshot, batch_id, expiry_date,
                                           qty, unit_cost, line_total, reason)
  select v_id, l.product_id, pr.name, l.batch_id, l.expiry_date, l.qty, l.unit_cost,
         round(l.qty * l.unit_cost, 2), l.reason
    from _pr_lines l join public.products pr on pr.id = l.product_id;

  select coalesce(sum(line_total),0) into v_total from public.purchase_return_items where return_id = v_id;

  -- stock leaves the shop
  insert into public.inventory_movements(product_id, qty_change, movement_type, reference_type, reference_id,
                                         unit_cost, note, device_name, created_by)
  select l.product_id, -l.qty, 'return_supplier', 'purchase_return', v_id, l.unit_cost,
         'Return ' || v_return_no, p_device, auth.uid()
    from _pr_lines l;

  -- and comes out of the batch it was bought in
  update public.product_batches b set qty_remaining = greatest(b.qty_remaining - l.qty, 0)
    from _pr_lines l
   where b.id = l.batch_id;

  update public.products p set expiry_date = (
      select min(b.expiry_date) from public.product_batches b
       where b.product_id = p.id and b.qty_remaining > 0 and b.expiry_date is not null)
   where p.id in (select distinct product_id from _pr_lines);

  update public.purchase_returns set total = v_total where id = v_id;

  -- a return reduces what the shop owes the supplier (or was paid straight back)
  if v_settled = 'payable' and v_total > 0 then
    insert into public.supplier_payments(payment_no, supplier_id, supplier_name, amount,
                                         payment_method, reference_no, note, created_by)
    values (public.fx_next_no('PAY','public.payment_seq',5), v_supplier.id, v_supplier.name, -v_total,
            'cash', v_return_no, 'Goods returned to supplier (' || v_return_no || ')', auth.uid());
  end if;

  perform public.fx_audit('purchase.return','purchase_returns', v_id::text,
    jsonb_build_object('return_no', v_return_no, 'supplier', v_supplier.name, 'total', v_total,
                       'items', jsonb_array_length(v_items), 'settled_by', v_settled), p_device);

  return jsonb_build_object('id', v_id, 'return_no', v_return_no, 'total', v_total,
                            'supplier_name', v_supplier.name);
end $$;

create or replace function public.list_purchase_returns(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', r.id, 'return_no', r.return_no, 'supplier_name', r.supplier_name,
               'reason', r.reason, 'note', r.note, 'total', r.total, 'settled_by', r.settled_by,
               'created_at', r.created_at,
               'item_count', (select count(*) from public.purchase_return_items i where i.return_id = r.id),
               'items', (select coalesce(jsonb_agg(jsonb_build_object(
                          'name', i.name_snapshot, 'qty', i.qty, 'unit_cost', i.unit_cost,
                          'line_total', i.line_total, 'expiry_date', i.expiry_date)), '[]'::jsonb)
                         from public.purchase_return_items i where i.return_id = r.id)
             ) as x
        from public.purchase_returns r
       order by r.created_at desc
       limit coalesce(public.fx_num(p,'limit',200),200)::int
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

-- =====================================================================
--  7. GIFT VOUCHERS / STORE CREDIT
-- =====================================================================
create or replace function public.issue_voucher(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_value numeric := public.fx_num(p,'value',0);
  v_kind text := coalesce(public.fx_txt(p,'kind'),'gift');
  v_code text := upper(public.fx_txt(p,'code'));
  v_row public.vouchers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if v_value <= 0 then perform public.fx_fail('BAD_AMOUNT','A voucher needs a value above zero.'); end if;
  if v_kind not in ('gift','store_credit') then
    perform public.fx_fail('BAD_KIND','Voucher kind must be gift or store_credit.');
  end if;

  if v_code is null then
    -- 12 characters, no confusing letters, e.g. GC-7F3K9Q2M
    loop
      v_code := 'GC-' || upper(substr(translate(encode(gen_random_bytes(9),'base64'),'+/=lIO01',''),1,8));
      exit when not exists (select 1 from public.vouchers where code = v_code);
    end loop;
  end if;

  insert into public.vouchers(code, kind, value, balance, customer_id, issued_to, phone, reason,
                              expires_on, created_by)
  values (v_code, v_kind, v_value, v_value, public.fx_uuid(p,'customer_id'), public.fx_txt(p,'issued_to'),
          public.fx_txt(p,'phone'), public.fx_txt(p,'reason'),
          public.fx_date(p,'expires_on'), auth.uid())
  returning * into v_row;

  perform public.fx_audit('voucher.issue','vouchers', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'value', v_row.value, 'kind', v_row.kind,
                       'issued_to', v_row.issued_to), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.list_vouchers(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb; v_q text := nullif(trim(coalesce(public.fx_txt(p,'q'),'')),'');
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', v.id, 'code', v.code, 'kind', v.kind, 'value', v.value, 'balance', v.balance,
               'issued_to', v.issued_to, 'phone', v.phone, 'reason', v.reason,
               'expires_on', v.expires_on, 'is_active', v.is_active, 'created_at', v.created_at,
               'used', round(v.value - v.balance, 2),
               'customer_name', c.name,
               'status', case when not v.is_active then 'cancelled'
                              when v.balance <= 0 then 'used'
                              when v.expires_on is not null and v.expires_on < current_date then 'expired'
                              else 'active' end
             ) as x
        from public.vouchers v
        left join public.customers c on c.id = v.customer_id
       where (v_q is null or v.code ilike '%' || v_q || '%' or coalesce(v.issued_to,'') ilike '%' || v_q || '%'
              or coalesce(v.phone,'') like '%' || v_q || '%')
       order by v.created_at desc
       limit coalesce(public.fx_num(p,'limit',300),300)::int
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

create or replace function public.voucher_balance(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text := upper(trim(coalesce(public.fx_txt(p,'code'),''))); v_row public.vouchers;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  if v_code = '' then perform public.fx_fail('MISSING_CODE','Type the voucher code.'); end if;
  select * into v_row from public.vouchers where upper(code) = v_code;
  if not found then perform public.fx_fail('VOUCHER_INVALID','Voucher ' || v_code || ' was not found.'); end if;
  if not v_row.is_active then perform public.fx_fail('VOUCHER_INACTIVE','That voucher has been cancelled.'); end if;
  if v_row.expires_on is not null and v_row.expires_on < current_date then
    perform public.fx_fail('VOUCHER_EXPIRED','That voucher expired on ' || to_char(v_row.expires_on,'DD-Mon-YYYY') || '.');
  end if;
  return jsonb_build_object('code', v_row.code, 'balance', v_row.balance, 'value', v_row.value,
                            'kind', v_row.kind, 'customer_name',
                            (select name from public.customers where id = v_row.customer_id),
                            'expires_on', v_row.expires_on);
end $$;

create or replace function public.cancel_voucher(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.vouchers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  update public.vouchers set is_active = false where id = v_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','Voucher not found.'); end if;
  perform public.fx_audit('voucher.cancel','vouchers', v_id::text,
    jsonb_build_object('code', v_row.code, 'balance_lost', v_row.balance), p_device);
  return to_jsonb(v_row);
end $$;

-- =====================================================================
--  8. OFFERS (buy X get Y free)
-- =====================================================================
create or replace function public.save_offer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := public.fx_uuid(p,'id');
  v_row public.offers;
  v_buy numeric := public.fx_num(p,'buy_qty',0);
  v_free numeric := public.fx_num(p,'free_qty',0);
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  if public.fx_txt(p,'name') is null then perform public.fx_fail('NAME_REQUIRED','Give the offer a name.'); end if;
  if v_buy <= 0 or v_free <= 0 then
    perform public.fx_fail('BAD_OFFER','An offer needs both a "buy" and a "get free" quantity above zero.');
  end if;
  if public.fx_uuid(p,'product_id') is null and public.fx_uuid(p,'category_id') is null then
    perform public.fx_fail('NEED_TARGET','Choose either a product or a whole category for this offer.');
  end if;
  if public.fx_uuid(p,'product_id') is not null and public.fx_uuid(p,'category_id') is not null then
    perform public.fx_fail('ONE_TARGET','Choose a product or a category, not both.');
  end if;

  if v_id is null then
    insert into public.offers(name, product_id, category_id, buy_qty, free_qty, starts_on, ends_on, is_active, created_by)
    values (public.fx_txt(p,'name'), public.fx_uuid(p,'product_id'), public.fx_uuid(p,'category_id'),
            v_buy, v_free, public.fx_date(p,'starts_on'),
            public.fx_date(p,'ends_on'), public.fx_bool(p,'is_active',true), auth.uid())
    returning * into v_row;
  else
    update public.offers set name = public.fx_txt(p,'name'),
      product_id = public.fx_uuid(p,'product_id'), category_id = public.fx_uuid(p,'category_id'),
      buy_qty = v_buy, free_qty = v_free,
      starts_on = public.fx_date(p,'starts_on'),
      ends_on = public.fx_date(p,'ends_on'),
      is_active = public.fx_bool(p,'is_active',true)
     where id = v_id returning * into v_row;
    if not found then perform public.fx_fail('NOT_FOUND','Offer not found.'); end if;
  end if;

  perform public.fx_audit('offer.save','offers', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'buy', v_row.buy_qty, 'free', v_row.free_qty), p_device);
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_offer(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := public.fx_uuid(p,'id'); v_row public.offers;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select * into v_row from public.offers where id = v_id;
  if not found then perform public.fx_fail('NOT_FOUND','Offer not found.'); end if;
  delete from public.offers where id = v_id;
  perform public.fx_audit('offer.delete','offers', v_id::text, jsonb_build_object('name', v_row.name), p_device);
  return jsonb_build_object('deleted', true);
end $$;

create or replace function public.list_offers()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  perform public.fx_require_role(array['cashier','manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'id', o.id, 'name', o.name, 'product_id', o.product_id, 'category_id', o.category_id,
               'buy_qty', o.buy_qty, 'free_qty', o.free_qty, 'starts_on', o.starts_on, 'ends_on', o.ends_on,
               'is_active', o.is_active, 'created_at', o.created_at,
               'product_name', pr.name, 'category_name', c.name,
               'target', coalesce(pr.name, c.name, 'all'),
               'running', (o.is_active and (o.starts_on is null or o.starts_on <= current_date)
                           and (o.ends_on is null or o.ends_on >= current_date)),
               'times_used', (select count(*) from public.audit_logs a
                               where a.action = 'offer.applied' and a.details->>'offer_id' = o.id::text),
               'free_value_given', (select coalesce(sum((a.details->>'free_value')::numeric),0)
                                      from public.audit_logs a
                                     where a.action = 'offer.applied' and a.details->>'offer_id' = o.id::text)
             ) as x
        from public.offers o
        left join public.products pr on pr.id = o.product_id
        left join public.categories c on c.id = o.category_id
    ) t;
  return jsonb_build_object('rows', v_rows);
end $$;

-- =====================================================================
--  9. BUYER / OWNER REPORTS  (profit per product, cashier scoreboard, dead stock)
-- =====================================================================
create or replace function public.profit_by_product(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := public.fx_date(p,'from', current_date - 30);
  v_to   date := public.fx_date(p,'to', current_date);
  v_limit int := coalesce(public.fx_num(p,'limit',200),200)::int;
  v_order text := case when public.fx_txt(p,'order') = 'qty' then 'qty_sold' else 'profit' end;
  v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>v_order)::numeric desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'product_id', si.product_id, 'name', si.name_snapshot, 'unit', si.unit,
               'qty_sold', sum(si.qty),
               'gross', round(sum(si.line_total), 2),
               'discount', round(sum(si.line_discount), 2),
               'cost', round(sum(si.cost_price * si.qty), 2),
               'profit', round(sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end), 2),
               'margin', case when sum(si.line_total) > 0
                    then round(sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end) / sum(si.line_total) * 100, 1)
                    else 0 end,
               'invoices', count(distinct si.sale_id)
             ) as x
        from public.sale_items si
        join public.sales s on s.id = si.sale_id
       where s.status = 'completed' and s.created_at::date between v_from and v_to
       group by si.product_id, si.name_snapshot, si.unit
       order by sum(case when si.product_id is not null then si.line_total - si.tax_amount - (si.cost_price * si.qty) else 0 end) desc
       limit v_limit
    ) t;
  return jsonb_build_object('rows', v_rows, 'from', v_from, 'to', v_to);
end $$;

create or replace function public.cashier_performance(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_from date := public.fx_date(p,'from', current_date - 30);
  v_to   date := public.fx_date(p,'to', current_date);
  v_rows jsonb;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'sales')::numeric desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'cashier_id', s.cashier_id, 'cashier', s.cashier_name,
               'sales', round(sum(s.total), 2), 'invoices', count(*), 'items', sum(s.item_count),
               'discounts_given', round(sum(s.line_discount_total + s.invoice_discount_amount), 2),
               'average_bill', round(avg(s.total), 2),
               'voids', (select count(*) from public.sales v where v.status = 'void' and v.cashier_id = s.cashier_id
                          and v.created_at::date between v_from and v_to),
               'refunds', (select coalesce(sum(r.refund_amount),0) from public.returns r
                            where r.created_by = s.cashier_id and r.created_at::date between v_from and v_to),
               'profit', round(sum(s.profit), 2)
             ) as x
        from public.sales s
       where s.status = 'completed' and s.created_at::date between v_from and v_to
       group by s.cashier_id, s.cashier_name
    ) t;
  return jsonb_build_object('rows', v_rows, 'from', v_from, 'to', v_to);
end $$;

create or replace function public.dead_stock(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_days int := coalesce(public.fx_num(p,'days',60),60)::int;
  v_rows jsonb; v_value numeric := 0;
begin
  perform public.fx_require_role(array['manager','admin','super_admin']);
  select coalesce(jsonb_agg(x order by (x->>'value')::numeric desc), '[]'::jsonb),
         coalesce(sum((x->>'value')::numeric), 0)
    into v_rows, v_value
    from (
      select jsonb_build_object(
               'id', pr.id, 'name', pr.name, 'barcode', pr.barcode, 'unit', pr.unit,
               'category_name', c.name, 'stock_qty', pr.stock_qty, 'cost_price', pr.cost_price,
               'value', round(pr.stock_qty * pr.cost_price, 2),
               'sale_price', pr.sale_price,
               'last_sold_at', (select max(s.created_at) from public.sale_items si
                                  join public.sales s on s.id = si.sale_id
                                 where si.product_id = pr.id and s.status = 'completed'),
               'days_idle', coalesce((select (current_date - max(s.created_at)::date) from public.sale_items si
                                  join public.sales s on s.id = si.sale_id
                                 where si.product_id = pr.id and s.status = 'completed'), 9999),
               'expiry_date', pr.expiry_date
             ) as x
        from public.products pr
        left join public.categories c on c.id = pr.category_id
       where pr.is_active and not pr.is_deleted and pr.stock_qty > 0
         and not exists (select 1 from public.sale_items si join public.sales s on s.id = si.sale_id
                          where si.product_id = pr.id and s.status = 'completed'
                            and s.created_at::date > current_date - v_days)
    ) t;
  return jsonb_build_object('rows', v_rows, 'value_tied_up', v_value, 'days', v_days);
end $$;

-- =====================================================================
--  10. WHAT THE TILL SEES (view updated with the new product fields)
-- =====================================================================
drop view if exists public.v_products_pos;
create view public.v_products_pos with (security_invoker = true) as
  select sl.product_id as id, sl.barcode, sl.name, sl.unit, sl.sale_price, sl.tax_percent,
         sl.stock_qty, sl.reorder_level, sl.category_id, sl.category_name,
         sl.is_active, sl.expiry_date, sl.shelf_location, sl.is_weighed, sl.updated_at,
         (sl.stock_qty <= sl.reorder_level) as is_low_stock,
         p.wholesale_price, p.wholesale_min_qty, p.plu_code, p.is_expiry_tracked,
         p.brand, p.pack_size, p.cost_price
    from public.stock_levels sl
    join public.products p on p.id = sl.product_id
   where sl.is_deleted = false and sl.is_active = true and p.is_deleted = false and p.is_active = true;
grant select on public.v_products_pos to authenticated;

-- the batches the till should warn about (expired or nearly expired)
drop view if exists public.v_expiring_stock;
create view public.v_expiring_stock with (security_invoker = true) as
  select b.id, b.product_id, pr.name as product_name, pr.barcode, pr.unit, b.batch_no,
         b.expiry_date, b.qty_remaining,
         (b.expiry_date - current_date) as days_left,
         case when b.expiry_date < current_date then 'expired' else 'expiring' end as status
    from public.product_batches b
    join public.products pr on pr.id = b.product_id
   where b.is_active and b.qty_remaining > 0 and b.expiry_date is not null
     and b.expiry_date <= current_date + 30;
grant select on public.v_expiring_stock to authenticated;

-- =====================================================================
--  11. LOCATION / SAFETY NETS
-- =====================================================================
-- sequences used above
create sequence if not exists public.purchase_return_seq;

-- row level security on every new table (reads only; writes go through RPCs)
do $$
declare t text;
begin
  foreach t in array array['product_batches','price_tiers','offers','vouchers',
                           'voucher_redemptions','purchase_returns','purchase_return_items'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

grant select on public.product_batches, public.price_tiers, public.offers, public.vouchers,
                public.voucher_redemptions, public.purchase_returns, public.purchase_return_items
  to authenticated;

revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
grant execute on all functions in schema public to authenticated;
grant select on all tables in schema public to authenticated;

-- make sure the new sequence can be used by the invoice-number helpers
grant usage, select on all sequences in schema public to authenticated;

-- =====================================================================
--  SECTION: 08_performance_indexes.sql
-- =====================================================================
-- =====================================================================
--  08. PERFORMANCE INDEXES  (run once, after the main setup)
--  Safe to re-run: every statement is "if not exists".
--
--  Why: the till and the product screen search with ilike '%text%'.
--  A normal btree index cannot serve a leading wildcard, so every search
--  scanned the whole products table. A trigram (pg_trgm) index can.
--  The customer ledger filters sales by customer id and date; this index
--  lets Postgres do that without reading every sale.
-- =====================================================================

create extension if not exists pg_trgm;

create index if not exists products_name_trgm_idx
  on public.products using gin (name gin_trgm_ops);

create index if not exists products_barcode_trgm_idx
  on public.products using gin (barcode gin_trgm_ops);

create index if not exists products_sku_trgm_idx
  on public.products using gin (sku gin_trgm_ops);

create index if not exists sales_customer_created_idx
  on public.sales(customer_id, created_at desc);

analyze public.products;
analyze public.sales;

-- =====================================================================
--  SECTION: 09_security_hardening.sql
-- =====================================================================
-- =====================================================================
--  09. SECURITY HARDENING  (run after the main setup; safe to re-run)
--
--  1. Manager PIN attempt limit.
--     A cashier who types wrong manager PINs five times in 15 minutes is
--     locked out of PIN approvals for 15 minutes. Every attempt made through
--     verify_manager_pin is recorded, right or wrong.
--
--     Why a separate verify call: a PostgreSQL error rolls back the whole
--     transaction, so a failed attempt logged inside the sale or refund call
--     would be lost. verify_manager_pin returns normally, so its log is kept.
--     The till always verifies first, then sends the approved PIN with the
--     action. fx_elevate also refuses while the cashier is locked out.
--
--  2. Every approval is still audited (override.pin) by fx_elevate.
-- =====================================================================

create table if not exists public.pin_attempts (
  id           bigserial primary key,
  cashier_id   uuid,
  device_name  text,
  succeeded    boolean not null,
  attempted_at timestamptz not null default now()
);
create index if not exists pin_attempts_recent_idx
  on public.pin_attempts(cashier_id, attempted_at desc);

-- Staff only through the functions below; nobody reads or writes the table directly.
alter table public.pin_attempts enable row level security;
revoke all on public.pin_attempts from anon, authenticated;

-- Failed attempts allowed in the window before a lockout, and the lockout length.
create or replace function public.fx_pin_max_failures() returns int
language sql immutable as $$ select 5 $$;

create or replace function public.fx_pin_window() returns interval
language sql immutable as $$ select interval '15 minutes' $$;

-- When the lockout ends for this cashier, or null when they are not locked out.
create or replace function public.fx_pin_locked_until(p_cashier uuid)
returns timestamptz language sql stable security definer set search_path = public, pg_temp as $$
  select case when count(*) >= public.fx_pin_max_failures()
              then max(attempted_at) + public.fx_pin_window() end
    from public.pin_attempts
   where cashier_id = p_cashier
     and succeeded = false
     and attempted_at > now() - public.fx_pin_window();
$$;

-- The till calls this first. It records the attempt and never raises for a wrong PIN.
create or replace function public.verify_manager_pin(p jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_pin   text := trim(coalesce(p->>'pin',''));
  v_me    uuid := auth.uid();
  v_until timestamptz;
  v_mgr   uuid;
  v_used  int;
begin
  if not public.fx_is_staff() then
    perform public.fx_fail('NOT_ALLOWED','Sign in as a staff member first.');
  end if;

  v_until := public.fx_pin_locked_until(v_me);
  if v_until is not null and v_until > now() then
    return jsonb_build_object('ok', false, 'locked', true, 'locked_until', v_until,
      'message', 'Too many wrong PINs. Wait a few minutes before trying again.');
  end if;

  v_mgr := public.fx_pin_manager(v_pin);
  insert into public.pin_attempts(cashier_id, device_name, succeeded)
  values (v_me, p_device, v_mgr is not null);

  if v_mgr is not null then
    return jsonb_build_object('ok', true, 'locked', false);
  end if;

  select count(*) into v_used from public.pin_attempts
   where cashier_id = v_me and succeeded = false
     and attempted_at > now() - public.fx_pin_window();
  return jsonb_build_object('ok', false, 'locked', v_used >= public.fx_pin_max_failures(),
    'attempts_left', greatest(public.fx_pin_max_failures() - v_used, 0),
    'message', 'That manager PIN is not correct.');
end $$;
grant execute on function public.verify_manager_pin(jsonb, text) to authenticated;

-- fx_elevate, now refusing while the cashier is locked out.
create or replace function public.fx_elevate(p_pin text, p_about text default 'override')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_mgr     uuid := public.fx_pin_manager(p_pin);
  v_cashier uuid := auth.uid();
  v_until   timestamptz;
begin
  v_until := public.fx_pin_locked_until(v_cashier);
  if v_until is not null and v_until > now() then
    perform public.fx_fail('PIN_LOCKED','Too many wrong PINs. Wait a few minutes before trying again.');
  end if;

  if v_mgr is null then
    perform public.fx_fail('PIN_WRONG','That manager PIN is not correct. Ask the manager to type it again.');
  end if;
  if v_mgr = v_cashier then return v_mgr; end if;

  -- Supabase reads request.jwt.claim.sub, the local test shim reads jwt.claim.sub
  perform set_config('jwt.claim.sub',         v_mgr::text, true);
  perform set_config('request.jwt.claim.sub', v_mgr::text, true);
  perform set_config('request.jwt.claims',
    (coalesce(nullif(current_setting('request.jwt.claims', true),''),'{}')::jsonb
      || jsonb_build_object('sub', v_mgr::text))::text, true);

  perform public.fx_audit('override.pin', 'sales', null,
    jsonb_build_object('approved_for', v_cashier, 'for_user',
      (select coalesce(username, full_name, 'cashier') from public.profiles where id = v_cashier),
      'about', p_about), null);

  return v_mgr;
end $$;

-- =====================================================================
--  SECTION: 10_delete_all_products.sql
-- =====================================================================
-- Owner only: PERMANENTLY empties the store so the till starts fresh, ready to import a
-- new product list. This cannot be undone. Take a backup first.
--
-- Deleted (every row):
--   products, with their stock, stock movements, price tiers, batches, offers
--   categories and subcategories, suppliers
--   discounts and vouchers (and their redemptions)
--   all sales (invoices) and their items, all returns and their items
--   all purchase orders and their items, supplier payments, purchase returns and their items
--   stock takes, expenses, shifts
--
-- Reset, not deleted:
--   customers: the list is kept, but balance and loyalty points go back to 0
--
-- Kept, so the app still works:
--   stores and store settings, app_settings, profiles (staff logins), devices (tills),
--   pin_attempts, audit_logs (this delete is written there as a record)
--
-- The whole reset runs in one transaction: if any step fails, nothing changes.
-- The app asks for the owner's password before it calls this function.
--
-- Run once in the Supabase SQL editor. Replaces the earlier version of this function.

create or replace function public.delete_all_products(p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_products  integer;
  v_sales     integer;
  v_purchases integer;
  v_customers integer;
begin
  perform public.fx_require_role(array['super_admin']);

  select count(*) into v_products  from public.products;
  select count(*) into v_sales     from public.sales;
  select count(*) into v_purchases from public.purchase_orders;

  -- children first: anything that refers to a sale, purchase, shift or product
  delete from public.return_items where true;
  delete from public.returns where true;
  delete from public.purchase_return_items where true;
  delete from public.purchase_returns where true;
  delete from public.sale_items where true;
  delete from public.sales where true;
  delete from public.voucher_redemptions where true;
  delete from public.vouchers where true;
  delete from public.purchase_items where true;
  delete from public.purchase_orders where true;
  delete from public.supplier_payments where true;
  delete from public.stock_take_items where true;
  delete from public.stock_takes where true;
  delete from public.expenses where true;
  delete from public.shifts where true;

  -- products take stock_levels, inventory_movements, price_tiers, product_batches,
  -- offers with them (on delete cascade)
  delete from public.products where true;
  delete from public.discounts where true;
  delete from public.categories where true;
  delete from public.suppliers where true;

  -- customers stay; their money and points start again from zero
  update public.customers
     set balance = 0, loyalty_points = 0, updated_at = now()
   where balance <> 0 or loyalty_points <> 0;
  get diagnostics v_customers = row_count;

  perform public.fx_audit('store.reset_for_import', 'products', null,
    jsonb_build_object(
      'products', v_products, 'sales', v_sales, 'purchase_orders', v_purchases,
      'customers_reset', v_customers),
    p_device);

  return jsonb_build_object(
    'ok', true,
    'products', v_products,
    'sales', v_sales,
    'purchase_orders', v_purchases,
    'customers_reset', v_customers
  );
end $$;

grant execute on function public.delete_all_products(text) to authenticated;

-- =====================================================================
--  SECTION: 10_delete_frees_barcode.sql
-- =====================================================================
-- =====================================================================
--  SUPERMART POS  --  10 : deleting a product frees its barcode and SKU
--  Run AFTER 09_security_hardening.sql (safe to run more than once)
--
--  Products are soft-deleted (the row stays so old invoices still point at
--  something). The barcode and SKU columns are unique, so a deleted product
--  kept its barcode and blocked any new product from using it.
--  Now delete_product clears both, and this file cleans up products that were
--  deleted before this change.
-- =====================================================================

create or replace function public.delete_product(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.products;
begin
  perform public.fx_require_role(array['admin','super_admin']);
  update public.products set is_deleted = true, is_active = false, barcode = null, sku = null,
         updated_by = auth.uid()
   where id = p_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;
  perform public.fx_audit('product.delete','products', p_id::text, jsonb_build_object('name', v_row.name), p_device);
  return jsonb_build_object('ok', true);
end $$;

-- Free the codes held by products that were deleted before this fix.
-- Sales keep their own barcode_snapshot, so history is unchanged.
update public.products
   set barcode = null, sku = null
 where is_deleted = true and (barcode is not null or sku is not null);

-- =====================================================================
--  OWNER LOGIN  (the last step)
--  1. Authentication -> Users -> Add user, tick "Auto Confirm User".
--  2. Replace the email below with that owner's email, then run this
--     statement once. It makes that account the Super Admin.
--  Until step 2 matches a user, this statement changes nothing, so it is
--  safe to run with the file.
-- =====================================================================
update public.profiles
   set role = 'super_admin'
 where email = 'you@example.com';
