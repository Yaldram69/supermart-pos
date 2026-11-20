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
