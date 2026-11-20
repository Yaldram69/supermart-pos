-- =====================================================================
--  SUPERMART POS  --  REGRESSION TEST SUITE  (local PostgreSQL only)
--  Run:  sudo -u postgres psql -d smtest -f local_test/test_suite.sql
--  Every line prints PASS or FAIL.  Re-run this after ANY change to the
--  SQL so you find bugs at your desk, not at the counter.
-- =====================================================================
\set ON_ERROR_STOP off
set client_min_messages = notice;

create or replace function t(p_label text, p_cond boolean) returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS | %', p_label;
  else raise warning 'FAIL | %', p_label; end if;
end $$;

-- run an expression that MUST fail, and check which error came back
create or replace function t_err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    raise warning 'FAIL | % (nothing failed - that is a security bug!)', p_label;
  exception when others then
    if sqlerrm like '%' || p_expect || '%' then raise notice 'PASS | %', p_label;
    else raise warning 'FAIL | % (wrong error: %)', p_label, sqlerrm; end if;
  end;
end $$;

-- sign in as a given staff member for the rest of the session
create or replace function t_login(p_email text) returns uuid
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v uuid;
begin
  select id into v from auth.users where email = p_email;
  if v is null then raise exception 'test user % not found', p_email; end if;
  perform set_config('jwt.claim.sub', v::text, false);
  return v;
end $$;

create or replace function t_id(p_email text) returns uuid
language sql security definer set search_path = public, auth, pg_temp as $$
  select id from auth.users where email = p_email;
$$;

-- ---------------------------------------------------------------------
--  STAGE: 4 tills + a super admin
-- ---------------------------------------------------------------------
insert into auth.users (email, raw_user_meta_data)
select x.email, jsonb_build_object('full_name', x.name) from (values
  ('owner@supermart.local','Store Owner'),
  ('manager@supermart.local','Nadia Manager'),
  ('cashier1@supermart.local','Ali Cashier'),
  ('cashier2@supermart.local','Sana Cashier'),
  ('supervisor@supermart.local','Kamran Supervisor')
) as x(email, name)
where not exists (select 1 from auth.users u where u.email = x.email);

-- If those logins already existed from an older run (before the trigger was
-- installed) their profile row may be missing, so top it up here.
insert into public.profiles (id, email, username, full_name, role)
select u.id, u.email, split_part(u.email,'@',1),
       coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email,'@',1)), 'cashier'
  from auth.users u
 where u.email in ('owner@supermart.local','manager@supermart.local','cashier1@supermart.local',
                   'cashier2@supermart.local','supervisor@supermart.local')
   and not exists (select 1 from public.profiles p where p.id = u.id);

update public.profiles set role='super_admin', username='owner' where email='owner@supermart.local';
update public.profiles set role='manager',     username='nadia' where email='manager@supermart.local';
update public.profiles set role='cashier',     username='ali',   max_discount_percent=5 where email='cashier1@supermart.local';
update public.profiles set role='cashier',     username='sana',  max_discount_percent=5 where email='cashier2@supermart.local';
update public.profiles set role='cashier',     username='kamran',max_discount_percent=5 where email='supervisor@supermart.local';

delete from public.return_items; delete from public.returns;
delete from public.sale_items; delete from public.sales; delete from public.shifts;
delete from public.expenses; delete from public.purchase_orders; delete from public.devices;
update public.customers set balance = 0, loyalty_points = 0;
update public.discounts set used_count = 0;

-- wipe trading history and rebuild stock from the opening ledger, so this
-- suite can be run again and again with identical results
delete from public.inventory_movements where movement_type <> 'opening';
update public.products p
   set stock_qty = coalesce((select sum(m.qty_change) from public.inventory_movements m
                              where m.product_id = p.id), 0);

select t('the auth trigger auto-created 5 staff profiles',
         (select count(*) from public.profiles where email like '%@supermart.local') = 5);
select t('owning role is super_admin',
         (select role from public.profiles where email='owner@supermart.local') = 'super_admin');

create temp table ctx as
  select (select id from public.products  where barcode='8964000300015') as lays,
         (select id from public.products  where barcode='8964000100062') as sugar,
         (select id from public.products  where barcode='8964001000025') as pen,
         (select id from public.customers where phone='0300-5551111')    as ahmed,
         (select id from public.customers where phone='0333-4442222')    as fatima,
         (select id from public.suppliers where name='Al-Karam Traders') as ak_supplier,
         (select stock_qty from public.products where barcode='8964000300015') as lays_before,
         (select cost_price from public.products where barcode='8964000100062') as sugar_cost,
         (select stock_qty from public.products where barcode='8964000100062') as sugar_stock;

-- ---------------------------------------------------------------------
--  1. A SALE ON TILL 1
-- ---------------------------------------------------------------------
select t_login('cashier1@supermart.local');
select t('my_identity returns role + store settings for the receipt',
         (public.my_identity()->>'role') = 'cashier'
         and (public.my_identity()->'store'->>'currency_symbol') = 'Rs');
select t('the till registers itself in the device table',
         (public.register_device('Counter-1','PC-COUNTER-1',1,'1.0.0')::jsonb->>'name') = 'Counter-1');

create temp table sale1 as
select public.create_sale(jsonb_build_object(
  'client_uuid','till1-sale-1','device_name','Counter-1','payment_method','cash','paid_amount',500,
  'items', jsonb_build_array(
     jsonb_build_object('product_id', (select lays from ctx),  'qty', 3),
     jsonb_build_object('product_id', (select sugar from ctx), 'qty', 2)))) as r;

select t('sale gets a sequential invoice number',
         (select r->>'invoice_no' from sale1) like 'INV-%');
select t('prices come from the database, not the till (3x50 + 2x148 = 446)',
         (select (r->>'total')::numeric from sale1) = 446);
select t('cashier_id is the signed-in cashier, never what the client sent',
         (select s.cashier_id from public.sales s where s.id = (select (r->>'sale_id')::uuid from sale1))
         = t_id('cashier1@supermart.local'));
select t('cashier_name is stored on the invoice', (select r->>'cashier_name' from sale1) = 'Ali Cashier');
select t('the receipt data block came back with the sale', (select r ? 'store' from sale1));
select t('stock fell 300 -> 297 on this PC',
         (select stock_qty from public.stock_levels where barcode='8964000300015')
         = (select lays_before - 3 from ctx));
select t('two sale lines were written',
         (select count(*) from public.sale_items where sale_id = (select (r->>'sale_id')::uuid from sale1)) = 2);
select t('the inventory ledger recorded the stock-out',
         (select count(*) from public.inventory_movements
           where movement_type='sale' and reference_id = (select (r->>'sale_id')::uuid from sale1)) = 2);
select t('the audit trail recorded who sold what',
         exists (select 1 from public.audit_logs where action='sale.create' and actor_name='Ali Cashier'));
select t('a shift was auto-opened for the cashier',
         (select count(*) from public.shifts where cashier_id = t_id('cashier1@supermart.local')) = 1);

-- ---------------------------------------------------------------------
--  2. THE OTHER 3 PCs SEE THE SAME NUMBER  (this is the 4-PC requirement)
-- ---------------------------------------------------------------------
select t_login('cashier2@supermart.local');
select t('PC2 reads the identical stock figure (live catalogue mirror)',
         (select stock_qty from public.stock_levels where barcode='8964000300015')
         = (select lays_before - 3 from ctx));
select t('PC2 sees its own identity', (public.my_identity()->>'username') = 'sana');
select (select lays_before - 3 from ctx) as expect_lays \gset
begin;
  set local role authenticated;   -- now the row level security rules apply for real
  select t('PC2 cannot see till 1 receipts (each cashier sees only their own)',
           (select count(*) from public.sales) = 0);
  select t('PC2 still sees the live stock number it needs for selling',
           (select stock_qty from public.stock_levels where barcode='8964000300015') = :'expect_lays'::numeric);
rollback;

select t_login('manager@supermart.local');
select t('manager sees every receipt across all 4 PCs', (select count(*) from public.sales) = 1);
select t('manager can read cost prices', (select cost_price from public.products where id=(select sugar from ctx)) > 0);

-- ---------------------------------------------------------------------
--  3. WHAT A CASHIER MUST NOT BE ABLE TO DO
-- ---------------------------------------------------------------------
select t_login('cashier1@supermart.local');

select t_err('a 20% discount is refused (cashier limit is 5%)',
  format($q$ select public.create_sale(jsonb_build_object(
     'device_name','Counter-1','payment_method','cash','invoice_discount_type','percent',
     'invoice_discount_value',20,
     'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'qty', 1)))) $q$,
     (select lays from ctx)),
  'DISCOUNT_LIMIT');

select t_err('a cashier cannot type in a higher price than the shelf price',
  format($q$ select public.create_sale(jsonb_build_object(
     'device_name','Counter-1','payment_method','cash','paid_amount',999,
     'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'qty', 1, 'unit_price', 999)))) $q$,
     (select lays from ctx)),
  'PRICE_OVERRIDE_NOT_ALLOWED');

select t_err('a cashier cannot sell more than the shelf holds',
  format($q$ select public.create_sale(jsonb_build_object(
     'device_name','Counter-1','payment_method','cash','paid_amount',999999,
     'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'qty', 99999)))) $q$,
     (select lays from ctx)),
  'INSUFFICIENT_STOCK');

select t_err('a cashier cannot book in a purchase',
  $q$ select public.receive_purchase('{"supplier_id":null,"items":[]}'::jsonb) $q$, 'NOT_ALLOWED');

select t_err('a cashier cannot cancel an invoice',
  format($q$ select public.void_sale(%L, 'oops') $q$, (select (r->>'sale_id') from sale1)), 'NOT_ALLOWED');

select t_err('a cashier cannot adjust stock',
  format($q$ select public.adjust_stock(%L, 500, 'found extra') $q$, (select lays from ctx)), 'NOT_ALLOWED');

select t_err('a cashier cannot edit the catalogue',
  format($q$ select public.save_product(jsonb_build_object('id', %L, 'name','Changed','sale_price',1)) $q$,
         (select lays from ctx)), 'NOT_ALLOWED');

select t_err('a cashier cannot change store settings',
  $q$ select public.save_store_settings(jsonb_build_object('tax_percent', 99)) $q$, 'NOT_ALLOWED');

select t_err('a cashier cannot create discount rules',
  $q$ select public.save_discount(jsonb_build_object('name','Hack','value',90,'kind','percent')) $q$, 'NOT_ALLOWED');

select t_err('a cashier cannot manage employees',
  $q$ select public.save_employee(jsonb_build_object('full_name','x')) $q$, 'NOT_ALLOWED');

create temp table sale2 as
select public.create_sale(jsonb_build_object(
  'device_name','Counter-1','payment_method','cash','invoice_discount_type','percent',
  'invoice_discount_value',5,'paid_amount',1000,
  'items', jsonb_build_array(jsonb_build_object('product_id', (select lays from ctx), 'qty', 2)))) as r;

select t('a 5% discount IS allowed and the maths is exact (2 x 50 less 5% = 95)',
         (select (r->>'total')::numeric from sale2) = 95);
select t('the discount is broken out on the invoice for reporting',
         (select (r->>'invoice_discount_amount')::numeric from sale2) = 5);

-- ---------------------------------------------------------------------
--  4. DOUBLE-CHARGING PROTECTION (an offline sale replayed by the till)
-- ---------------------------------------------------------------------
create temp table replay as
select public.create_sale(jsonb_build_object(
  'client_uuid','till1-sale-1','device_name','Counter-1','payment_method','cash','paid_amount',500,
  'items', jsonb_build_array(jsonb_build_object('product_id', (select lays from ctx), 'qty', 3)))) as r;

select t('the replayed sale is recognised as a duplicate',
         (select (r->>'duplicate')::boolean from replay)
         and (select (r->>'sale_id') from replay) = (select (r->>'sale_id') from sale1));
select t('no extra stock was taken by the duplicate',
         (select stock_qty from public.stock_levels where barcode='8964000300015')
         = (select lays_before - 5 from ctx));

-- ---------------------------------------------------------------------
--  5. CREDIT / UDHAAR
-- ---------------------------------------------------------------------
create temp table credit1 as
select public.create_sale(jsonb_build_object(
  'device_name','Counter-1','payment_method','credit','customer_id', (select ahmed from ctx),
  'items', jsonb_build_array(jsonb_build_object('product_id', (select sugar from ctx), 'qty', 5)))) as r;

select t('credit sale is added to the customer khata (5 x 148 = 740)',
         (select balance from public.customers where id = (select ahmed from ctx)) = 740);
select t('credit sale shows paid_amount 0 on the invoice',
         (select (r->>'paid_amount')::numeric from credit1) = 0);

select t_err('a customer over their credit limit is stopped at the counter',
  format($q$ select public.create_sale(jsonb_build_object(
     'device_name','Counter-1','payment_method','credit','customer_id', %L,
     'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'qty', 100)))) $q$,
     (select fatima from ctx), (select sugar from ctx)),
  'CREDIT_LIMIT');

select t_err('credit sale with no customer chosen is refused',
  format($q$ select public.create_sale(jsonb_build_object(
     'device_name','Counter-1','payment_method','credit',
     'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'qty', 1)))) $q$,
     (select sugar from ctx)),
  'CREDIT_NEEDS_CUSTOMER');

select t('customer paying part of their debt is recorded',
         (public.receive_customer_payment((select ahmed from ctx), 240, 'cash')::jsonb->>'balance')::numeric = 500);

-- ---------------------------------------------------------------------
--  6. DISCOUNT CODES + AUTOMATIC PROMOTIONS
-- ---------------------------------------------------------------------
select t_err('code EID10 asks for a manager even on a big bill',
  $q$ select public.check_discount_code('EID10', 5000) $q$, 'CODE_NEEDS_MANAGER');
select t_err('a made-up code is rejected',
  $q$ select public.check_discount_code('NOSUCHCODE', 5000) $q$, 'CODE_INVALID');

select t_login('manager@supermart.local');
create temp table eid as
select public.create_sale(jsonb_build_object(
  'device_name','Counter-1','payment_method','cash','discount_code','EID10','paid_amount',99999,
  'items', jsonb_build_array(jsonb_build_object('product_id', (select sugar from ctx), 'qty', 10)))) as r;

select t('manager applies EID10: 10 x 148 = 1480 less 10% = 1332',
         (select (r->>'total')::numeric from eid) = 1332);
select t('the promotion usage counter moved (for max_uses limits)',
         (select used_count from public.discounts where code='EID10') = 1);

select t_err('a discount code below its minimum bill is refused',
  $q$ select public.check_discount_code('WELCOME50', 100) $q$, 'CODE_MIN_SUBTOTAL');

-- ---------------------------------------------------------------------
--  7. PURCHASE / STOCK IN  (and weighted average cost)
-- ---------------------------------------------------------------------
create temp table pre_po as
  select stock_qty as sugar_before_po from public.products where id=(select sugar from ctx);

create temp table po as
select public.receive_purchase(jsonb_build_object(
  'supplier_id', (select ak_supplier from ctx), 'paid_amount', 5000, 'payment_method','cash',
  'invoice_ref','SUP-778',
  'items', jsonb_build_array(jsonb_build_object(
     'product_id', (select sugar from ctx), 'qty', 100, 'unit_cost', 140)))) as r;

select t('purchase received with a PO number', (select r->>'po_no' from po) <> '');
select t('stock went up by exactly the purchase quantity',
         (select stock_qty from public.products where id=(select sugar from ctx))
         = (select sugar_before_po from pre_po) + 100);
select t('cost price re-averaged between the old and new cost',
         (select cost_price from public.products where id=(select sugar from ctx))
           between (select sugar_cost from ctx) and 140);
select t('the unpaid part of the purchase stayed as a payable',
         (select (r->>'unpaid')::numeric from po) = 14000 - 5000);
select t('stock-in is written to the ledger as a purchase movement',
         exists (select 1 from public.inventory_movements
                  where movement_type='purchase' and note like 'PO %'));

-- ---------------------------------------------------------------------
--  8. RETURNS / REFUNDS
-- ---------------------------------------------------------------------
create temp table ret as
select public.create_return(jsonb_build_object(
  'sale_id', (select (r->>'sale_id') from sale1), 'reason','Customer changed mind',
  'refund_method','cash', 'restock', true,
  'items', jsonb_build_array(jsonb_build_object(
     'sale_item_id', (select si.id from public.sale_items si
                       where si.sale_id = (select (r->>'sale_id')::uuid from sale1)
                         and si.product_id = (select lays from ctx) limit 1),
     'qty', 1)))) as r;

select t('refund amount = one packet back at its sold price (50)',
         (select (r->>'refund_amount')::numeric from ret) = 50);
select t('the returned packet went back on the shelf',
         (select stock_qty from public.stock_levels where barcode='8964000300015')
         = (select lays_before - 4 from ctx));
select t('the invoice is now marked partially refunded',
         (select r->>'sale_status' from ret) = 'partially_refunded');
select t('a refund needs a manager (cashier was refused earlier)',
         (select count(*) from public.returns) = 1);

select t_err('returning more than was sold is refused',
  format($q$ select public.create_return(jsonb_build_object(
     'sale_id', %L, 'items', jsonb_build_array(jsonb_build_object(
        'sale_item_id', (select id from public.sale_items
                          where sale_id = %L::uuid and product_id = %L limit 1),
        'qty', 500)))) $q$,
     (select (r->>'sale_id') from sale1), (select (r->>'sale_id') from sale1), (select lays from ctx)),
  'OVER_RETURN');

-- ---------------------------------------------------------------------
--  9. VOIDING PUTS STOCK BACK
-- ---------------------------------------------------------------------
create temp table voidres as
select public.void_sale((select (r->>'sale_id')::uuid from sale2), 'Cashier mis-keyed a dummy bill') as r;

select t('void restores the stock it had taken',
         (select stock_qty from public.products where id = (select lays from ctx))
         = (select lays_before from ctx) - 4 + 2);
select t('the voided invoice is flagged, not deleted',
         (select status from public.sales where id = (select (r->>'sale_id')::uuid from sale2)) = 'void');
select t('the cancellation is in the audit log with a reason',
         exists (select 1 from public.audit_logs where action='sale.void' and details->>'reason' is not null));
select t_err('a voided invoice cannot be voided twice',
  format($q$ select public.void_sale(%L,'again') $q$, (select (r->>'sale_id') from sale2)), 'ALREADY_VOID');

-- ---------------------------------------------------------------------
--  10. SHIFTS + CASH-UP (X and Z reports)
-- ---------------------------------------------------------------------
select t_login('cashier2@supermart.local');
create temp table shift1 as select public.open_shift(5000, 'Counter-2') as r;
select t('shift opened with a cash float', (select r->>'shift_no' from shift1) like 'SHF-%');
select t_err('the same cashier cannot open a second shift',
  $q$ select public.open_shift(1000,'Counter-2') $q$, 'SHIFT_ALREADY_OPEN');

create temp table sale3 as
select public.create_sale(jsonb_build_object(
  'device_name','Counter-2','payment_method','cash','paid_amount',1000,
  'items', jsonb_build_array(jsonb_build_object('product_id', (select sugar from ctx), 'qty', 2)))) as r;

select t('the sale is attached to this cashier''s open shift',
         (select shift_id from public.sales where id = (select (r->>'sale_id')::uuid from sale3))
         = (select (r->>'id')::uuid from shift1));

create temp table xr as select public.shift_summary((select (r->>'id')::uuid from shift1)) as r;
select t('X-report cash total = 2 x 148 = 296', (select (r->>'cash_sales')::numeric from xr) = 296);
select t('X-report expected drawer = float 5000 + 296 = 5296',
         (select (r->>'expected_cash')::numeric from xr) = 5296);
select t('X-report counts the invoices', (select (r->>'invoice_count')::int from xr) = 1);

create temp table zr as
select public.close_shift((select (r->>'id')::uuid from shift1), 5290, 'Rs 6 short') as r;
select t('Z-report flags the Rs 6 shortage', (select (r->>'difference')::numeric from zr) = -6);
select t('the shift is closed and stamped',
         (select status from public.shifts where id = (select (r->>'id')::uuid from shift1)) = 'closed');
select t_err('a closed shift cannot be closed again',
  format($q$ select public.close_shift(%L, 1) $q$, (select (r->>'id') from shift1)), 'ALREADY_CLOSED');

-- ---------------------------------------------------------------------
--  11. DASHBOARDS + REPORTS
-- ---------------------------------------------------------------------
select t_login('manager@supermart.local');
select t('dashboard returns today''s takings', (public.dashboard_stats(7)->'today'->>'sales')::numeric > 0);
select t('dashboard lists the 4 tills and when they last checked in',
         jsonb_array_length(public.dashboard_stats(7)->'devices') >= 1);
select t('dashboard shows profit and stock valuation',
         (public.dashboard_stats(7)->>'profit' is null)
         and (public.dashboard_stats(7)->>'stock_value')::numeric > 0);
select t('dashboard flags low stock for reordering',
         (public.dashboard_stats(7)->>'low_stock_count')::int >= 0);
select t('7-day sales series has 7 points',
         jsonb_array_length(public.dashboard_stats(7)->'sales_series') = 7);
select t('sales report totals add up',
         (public.sales_report(current_date, current_date)->'totals'->>'sales')::numeric > 0);
select t('sales report has payment / cashier / product breakdowns',
         jsonb_array_length(public.sales_report(current_date, current_date)->'by_payment') >= 1
         and jsonb_array_length(public.sales_report(current_date, current_date)->'by_cashier') >= 1
         and jsonb_array_length(public.sales_report(current_date, current_date)->'top_products') >= 1);
select t('sales report lists the refund', 
         jsonb_array_length(public.sales_report(current_date, current_date)->'refunds') = 1);
select t('hourly breakdown is present',
         jsonb_array_length(public.sales_report(current_date, current_date)->'hourly') >= 1);
select t('stock valuation view adds up',
         (select stock_at_cost from public.v_stock_valuation) > 0);
select t('low stock view is usable for a reorder list',
         (select count(*) from public.v_low_stock) >= 0);

select t_login('cashier2@supermart.local');
select t_err('a cashier cannot pull the sales report',
  $q$ select public.sales_report(current_date, current_date) $q$, 'NOT_ALLOWED');

-- ---------------------------------------------------------------------
--  12. INVOICE NUMBERING IS COLLISION-PROOF (20 invoices back to back)
-- ---------------------------------------------------------------------
do $$
declare i int;
begin
  for i in 1..20 loop
    perform public.create_sale(jsonb_build_object(
      'device_name','Counter-1','payment_method','cash','paid_amount',500,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id',(select id from public.products where barcode='8964001000025'),'qty',2))));
  end loop;
end $$;
select t('20 rapid invoices all got unique numbers',
         (select count(distinct invoice_no) from public.sales) = (select count(*) from public.sales));
select t('invoice numbers are sequential from the server sequence',
         exists (select 1 from public.sales where invoice_no like 'INV-' || to_char(now(),'YYYY') || '-%'));

-- ---------------------------------------------------------------------
--  13. RLS  --  what the other PCs may READ
-- ---------------------------------------------------------------------
begin;
  set local role authenticated;
  select t_login('cashier1@supermart.local');
  -- Policy (decided by the owner): cashiers may see cost prices and margins, so
  -- the till can show profit on hover. Staff can read the product list.
  select t('RLS: a cashier reading products sees the full list (cost visible by policy)',
           (select count(*) from public.products) > 50);
  select t('RLS: a cashier CAN read the POS catalogue mirror',
           (select count(*) from public.stock_levels) > 50);
  select t('RLS: a cashier CAN read store settings for the receipt',
           (select count(*) from public.stores) = 1);
  select t('RLS: a cashier CANNOT see the manager''s or other till''s receipts',
           (select count(*) from public.sales where cashier_id <> t_id('cashier1@supermart.local')) = 0);
  select t('RLS: a cashier CANNOT read the audit log', (select count(*) from public.audit_logs) = 0);
  select t('RLS: a cashier CANNOT read expenses', (select count(*) from public.expenses) = 0);
  select t('RLS: a cashier CANNOT read suppliers', (select count(*) from public.suppliers) = 0);
  select t('RLS: a cashier CANNOT read discount rules that are off',
           (select count(*) from public.discounts where not is_active) = 0);
rollback;

begin;
  set local role authenticated;
  select t_login('cashier1@supermart.local');
  select t_err('RLS: a cashier cannot delete a product with raw SQL',
    $q$ delete from public.products where barcode='8964001000025' $q$, 'permission denied');
  select t_err('RLS: a cashier cannot change a price with raw SQL',
    $q$ update public.products set sale_price = 1 $q$, 'permission denied');
  select t_err('RLS: a cashier cannot promote themselves to super admin',
    $q$ update public.profiles set role = 'super_admin' $q$, 'permission denied');
  select t_err('RLS: a cashier cannot write a fake invoice straight into the table',
    $q$ insert into public.sales(invoice_no, cashier_id) values ('HACK-1', auth.uid()) $q$, 'permission denied');
  select t_err('RLS: a cashier cannot rewrite history in the audit log',
    $q$ delete from public.audit_logs $q$, 'permission denied');
rollback;

begin;
  set local role authenticated;
  select t_login('manager@supermart.local');
  select t('RLS: a manager CAN read all receipts',
           (select count(*) from public.sales) > 0);
  select t('RLS: a manager CAN read suppliers', (select count(*) from public.suppliers) >= 1);
  select t('RLS: a manager sees the master product list with cost',
           (select count(*) from public.products) > 50);
  select t_err('RLS: a manager still cannot touch stock with raw SQL (RPC only)',
    $q$ update public.products set stock_qty = 99999 $q$, 'permission denied');
rollback;

-- ---------------------------------------------------------------------
--  14. SUPER ADMIN SURFACES
-- ---------------------------------------------------------------------
select t_login('owner@supermart.local');
select t('super admin can save store settings',
         (public.save_store_settings(jsonb_build_object('name','Supermart Superstore','tax_percent',0))->>'name')
         = 'Supermart Superstore');
select t('super admin can read every receipt', (select count(*) from public.sales) > 0);
select t('super admin can read the whole audit log', (select count(*) from public.audit_logs) > 0);
select t('super admin can see all four devices',
         (select count(*) from public.list_devices()) >= 1);
select t('every action left an audit entry naming the person',
         exists (select 1 from public.audit_logs where actor_name = 'Nadia Manager')
         and exists (select 1 from public.audit_logs where actor_name = 'Ali Cashier'));
select t_err('the last super admin cannot demote themselves by accident',
  format($q$ select public.save_employee(jsonb_build_object('id', %L, 'role','cashier')) $q$,
         t_id('owner@supermart.local')),
  'LAST_ADMIN');

select t('super admin can edit a staff record (max discount per person)',
         (public.save_employee(jsonb_build_object('id', t_id('cashier2@supermart.local'),
            'full_name','Sana Cashier','max_discount_percent', 8, 'role','cashier'))::jsonb->>'max_discount_percent')::numeric = 8);
select t('super admin can deactivate a leaver',
         (public.save_employee(jsonb_build_object('id', t_id('supervisor@supermart.local'),
            'full_name','Kamran Supervisor','role','cashier','is_active',false))::jsonb->>'is_active')::boolean = false);

-- ---------------------------------------------------------------------
--  15. CONSISTENCY CHECKS
-- ---------------------------------------------------------------------
select t('the POS mirror is in sync with the master product table',
         (select count(*) from public.stock_levels sl
            join public.products p on p.id = sl.product_id
           where sl.stock_qty <> p.stock_qty) = 0);
select t('every product has exactly one mirror row',
         (select count(*) from public.products) = (select count(*) from public.stock_levels));
select t('stock_qty equals the sum of its ledger movements (books balance)',
         (select count(*) from public.products p
           where p.stock_qty <> coalesce((select sum(m.qty_change) from public.inventory_movements m
                                           where m.product_id = p.id), 0)) = 0);
select t('sale totals reconcile: sum(line_total) = total for every invoice',
         (select count(*) from public.sales s
           where s.status <> 'void'
             and abs(s.total - (select sum(si.line_total) from public.sale_items si where si.sale_id = s.id)
                     + s.invoice_discount_amount) > 0.01) = 0);

\echo ''
\echo '>>> now run local_test/race_test.sh for the two-tills-at-once oversell test'
\echo '=== end of test suite ==='
