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
