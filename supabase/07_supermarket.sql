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
