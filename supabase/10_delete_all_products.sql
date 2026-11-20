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
