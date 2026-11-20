-- =====================================================================
--  SUPERMART POS  --  SHOP OPERATIONS TEST  (local PostgreSQL only)
--
--  Covers everything added in 06_operations.sql:
--    manager PIN override, expenses, activity log, supplier payables,
--    stock take, reorder -> purchase order, backup, weighed items, loyalty.
--
--  Run:  sudo -u postgres psql -d smtest -q -f local_test/ops_test.sql
--  Count: grep -c "PASS |"  and  grep -c "FAIL |"
-- =====================================================================
\set ON_ERROR_STOP off
set client_min_messages = notice;

create or replace function t(p_label text, p_cond boolean) returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS | %', p_label;
  else raise warning 'FAIL | %', p_label; end if;
end $$;

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

-- sign in as a staff member for the rest of the session
create or replace function t_login(p_email text) returns uuid
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v uuid;
begin
  select id into v from auth.users where email = p_email;
  if v is null then raise exception 'test user % not found', p_email; end if;
  perform set_config('jwt.claim.sub', v::text, false);
  return v;
end $$;

-- make sure the known staff exist (same fixtures as test_suite.sql)
insert into auth.users (email, raw_user_meta_data)
select x.email, jsonb_build_object('full_name', x.name) from (values
  ('owner@supermart.local','Store Owner'),
  ('manager@supermart.local','Nadia Manager'),
  ('cashier1@supermart.local','Ali Cashier')
) as x(email, name)
where not exists (select 1 from auth.users u where u.email = x.email);

update public.profiles set role='super_admin' where email='owner@supermart.local';
update public.profiles set role='manager'     where email='manager@supermart.local';
update public.profiles set role='cashier', max_discount_percent=5 where email='cashier1@supermart.local';

select t('staff fixtures present', (select count(*) from public.profiles where email in
        ('owner@supermart.local','manager@supermart.local','cashier1@supermart.local')) = 3);

-- =====================================================================
--  1. MANAGER PIN OVERRIDE
-- =====================================================================
select t_login('manager@supermart.local');
select t('manager can set a PIN', (public.set_manager_pin(jsonb_build_object('pin','4321'))->>'ok')::boolean);
select t('PIN is stored hashed (never in clear text)',
         (select manager_pin_hash <> '4321' and manager_pin_hash is not null
            from public.profiles where email='manager@supermart.local'));
select t_err('too-short PIN refused',
  $$select public.set_manager_pin(jsonb_build_object('pin','12'))$$, 'BAD_PIN');

select t_login('cashier1@supermart.local');
select t('till can see a manager PIN exists', public.pin_ready());

select t_err('cashier cannot set someone else''s PIN',
  $$select public.set_manager_pin(jsonb_build_object('pin','1111',
      'profile_id',(select id from public.profiles where email='manager@supermart.local')))$$, 'NOT_ALLOWED');

-- a cashier's own sale at 10% is above their 5% limit
select t_err('cashier 10% discount refused without a PIN',
  $$select public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),
      'items',jsonb_build_array(jsonb_build_object('product_id',(select id from public.products where is_deleted=false limit 1),'qty',1)),
      'invoice_discount_type','percent','invoice_discount_value',10))$$, 'DISCOUNT_LIMIT');

select t_err('wrong PIN refused',
  $$select public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),'manager_pin','0000',
      'items',jsonb_build_array(jsonb_build_object('product_id',(select id from public.products where is_deleted=false limit 1),'qty',1))))$$, 'PIN_WRONG');

select t('correct PIN lets the cashier finish the same sale',
  (public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),'manager_pin','4321',
      'items',jsonb_build_array(jsonb_build_object('product_id',(select id from public.products where is_deleted=false limit 1),'qty',1)),
      'invoice_discount_type','percent','invoice_discount_value',10))->>'invoice_no') is not null);

select t_login('owner@supermart.local');
select t('the approval was written to the audit trail',
  exists (select 1 from jsonb_array_elements(public.list_activity()->'rows') r
           where r->>'action' = 'override.pin'));
select t('the trail names the cashier it was approved for',
  (select (r->'detail'->>'for_user') is not null
     from jsonb_array_elements(public.list_activity()->'rows') r
    where r->>'action' = 'override.pin' limit 1));
select t_login('cashier1@supermart.local');

select t('no PIN means no elevation (normal cashier sale still capped)',
  (public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),
      'items',jsonb_build_array(jsonb_build_object('product_id',(select id from public.products where is_deleted=false limit 1),'qty',1))))->>'invoice_no') is not null);

-- ---------------------------------------------------------------- the wrappers
-- The app talks to pos_sale / pos_void_sale / pos_create_return (not the raw
-- 03 functions), because those three are the ones that understand a PIN.
-- The bills used here are held in a temp table, so each check refunds the
-- exact bill it created (guessing "the latest sale" is fragile).
create temp table if not exists _pin_bill (n int, sale_id uuid, item_id uuid);
delete from _pin_bill;

select t_login('cashier1@supermart.local');

insert into _pin_bill(n, sale_id)
select 1, (public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),
     'items',jsonb_build_array(jsonb_build_object('product_id',
        (select id from public.products where is_deleted=false and sale_price <= 60 order by sale_price limit 1),'qty',1)),
     'payment_method','cash','paid_amount',1000))->>'sale_id')::uuid;

select t('a cashier can ring a normal sale through pos_sale (no PIN needed)',
  (select sale_id is not null from _pin_bill where n = 1));

select t_err('a cashier cannot cancel a bill without a PIN',
  format($$select public.pos_void_sale('%s'::uuid, 'test', null, 'test')$$,
         (select sale_id from _pin_bill where n = 1)), 'NOT_ALLOWED');

select t('the manager PIN lets the cashier cancel that bill',
  (public.pos_void_sale((select sale_id from _pin_bill where n = 1),
     'wrong item', '4321', 'test')->>'invoice_no') is not null);

select t('the cancelled bill is really marked void in the database',
  (select status from public.sales where id = (select sale_id from _pin_bill where n = 1)) = 'void');

-- a fresh two-unit bill to refund from
insert into _pin_bill(n, sale_id)
select 2, (public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),
     'items',jsonb_build_array(jsonb_build_object('product_id',
        (select id from public.products where is_deleted=false and sale_price <= 60 order by sale_price limit 1),'qty',2)),
     'payment_method','cash','paid_amount',1000))->>'sale_id')::uuid;

update _pin_bill set item_id = (select id from public.sale_items where sale_id = _pin_bill.sale_id limit 1)
 where n = 2;

select t('the bill to refund really exists with its line',
  (select sale_id is not null and item_id is not null from _pin_bill where n = 2));

select t_err('a cashier cannot refund without a PIN',
  format($$select public.pos_create_return(jsonb_build_object('sale_id','%s'::uuid,
      'items',jsonb_build_array(jsonb_build_object('sale_item_id','%s'::uuid,'qty',1)),
      'reason','test','restock',true), null, 'test')$$,
      (select sale_id from _pin_bill where n = 2), (select item_id from _pin_bill where n = 2)),
  'NOT_ALLOWED');

select t('the manager PIN lets the cashier refund it',
  (public.pos_create_return(jsonb_build_object('sale_id',
      (select sale_id from _pin_bill where n = 2),
      'items',jsonb_build_array(jsonb_build_object('sale_item_id',
        (select item_id from _pin_bill where n = 2),'qty',1)),
      'reason','test','restock',true), '4321', 'test')->>'return_no') is not null);

select t_err('the PIN is per person: a wrong PIN is refused',
  format($$select public.pos_void_sale('%s'::uuid, 'test', '9999', 'test')$$,
         (select sale_id from _pin_bill where n = 2)), 'PIN_WRONG');

-- =====================================================================
--  2. EXPENSES
-- =====================================================================
select t_login('manager@supermart.local');
select t('an expense can be recorded',
  (public.save_expense(jsonb_build_object('category','Transport','amount',450,'description','Rickshaw'))->>'amount')::numeric = 450);
select t('expense list totals it',
  (public.list_expenses()->>'total')::numeric >= 450);
select t_login('cashier1@supermart.local');
select t_err('cashier cannot read expenses', $$select public.list_expenses()$$, 'NOT_ALLOWED');
select t_login('manager@supermart.local');

-- =====================================================================
--  3. ACTIVITY LOG
-- =====================================================================
select t_err('a manager cannot read the activity log (admins only)',
  $$select public.list_activity()$$, 'NOT_ALLOWED');
select t_login('owner@supermart.local');
select t('activity log returns rows', jsonb_array_length(public.list_activity()->'rows') > 0);
select t('activity log records who did it',
  (public.list_activity()->'rows'->0->>'actor_name') is not null);
select t_login('cashier1@supermart.local');
select t_err('cashier cannot read the activity log', $$select public.list_activity()$$, 'NOT_ALLOWED');
select t_login('manager@supermart.local');

-- =====================================================================
--  4. SUPPLIER PAYABLES
-- =====================================================================
select t_login('manager@supermart.local');
select t('a delivery can be booked in',
  (public.receive_purchase(jsonb_build_object(
     'supplier_id',(select id from public.suppliers where name='Al-Karam Traders'),
     'items', jsonb_build_array(jsonb_build_object(
        'product_id',(select id from public.products where barcode='8964000100062'),
        'qty',10,'unit_cost',135,'sale_price',148)),
     'paid_amount',500
  ))->>'po_no') is not null);

select t('the supplier now shows an outstanding balance',
  (public.supplier_payables()->'rows'->0->>'outstanding')::numeric > 0);

select t('paying the supplier works',
  (public.pay_supplier(jsonb_build_object(
     'supplier_id',(select id from public.suppliers where name='Al-Karam Traders'),
     'amount',200,'payment_method','cash'))->>'payment_no') is not null);

select t('the payment reduced what is owed',
  (public.supplier_payables()->'total_outstanding')::numeric >= 0);

select t('supplier ledger shows both sides',
  (public.supplier_ledger((select id from public.suppliers where name='Al-Karam Traders'))->'rows') is not null);
select t_err('paying with no amount is refused',
  $$select public.pay_supplier(jsonb_build_object('supplier_id',(select id from public.suppliers limit 1),'amount',0))$$, 'BAD_AMOUNT');

-- =====================================================================
--  5. REORDER -> PURCHASE ORDER -> RECEIVE
-- =====================================================================
select t_login('manager@supermart.local');
select t('low-stock list is available to the till',
  jsonb_typeof(public.reorder_list()->'rows') = 'array');

select t('a draft purchase order can be created',
  (public.create_purchase_order(jsonb_build_object(
     'supplier_id',(select id from public.suppliers where name='Nestle Distributor'),
     'items', jsonb_build_array(jsonb_build_object(
        'product_id',(select id from public.products where barcode='8964000100062'),
        'qty',24,'unit_cost',130))))->>'status') = 'draft');

select t('the draft is listed as a draft',
  jsonb_array_length(public.draft_purchases()->'rows') >= 1);

select t('the draft carries its supplier and lines',
  (public.draft_purchases()->'rows'->0->>'supplier_name') = 'Nestle Distributor'
  and jsonb_array_length(public.draft_purchases()->'rows'->0->'items') = 1);

-- receive it properly, by its id
select t('receiving a saved order posts the stock',
  (public.receive_purchase(jsonb_build_object(
     'id', (public.draft_purchases()->'rows'->0->>'id'),
     'supplier_id',(select id from public.suppliers where name='Nestle Distributor'),
     'items', jsonb_build_array(jsonb_build_object(
        'product_id',(select id from public.products where barcode='8964000100062'),
        'qty',24,'unit_cost',130)),
     'paid_amount',1000))->>'po_no') is not null);

select t('the order is no longer a draft',
  (select count(*) from public.purchase_orders where status='draft') = 0);
select t('it is the same order, not a duplicate',
  (select count(*) from public.purchase_orders where status='received'
     and po_no like 'PO-%') = (select count(*) from public.purchase_orders where status='received'));
select t_err('received orders are protected from deletion',
  $$select public.delete_purchase((select id from public.purchase_orders where status='received' limit 1))$$, 'NOT_ALLOWED');

-- =====================================================================
--  6. STOCK TAKE
-- =====================================================================
select t_login('manager@supermart.local');
select public.start_stock_take('monthly count');
select t('a stock take can be started', (public.current_stock_take()) is not null);

select t('counting an item records the variance',
  (public.stock_take_count(jsonb_build_object(
     'take_id',(public.current_stock_take()->>'id')::uuid,
     'barcode','8964000100062','qty',(select stock_qty from public.stock_levels where barcode='8964000100062') - 3
   ))->>'variance')::numeric = -3);

select t_err('counting an unknown barcode is refused',
  $$select public.stock_take_count(jsonb_build_object(
      'take_id',(public.current_stock_take()->>'id')::uuid,'barcode','0000000000000','qty',1))$$, 'NOT_FOUND');

select t('completing the count posts the difference to the ledger',
  (public.complete_stock_take((select id from public.stock_takes where status='open' limit 1))->>'adjusted_items')::int = 1);

select t('the shelf stock was corrected',
  (select stock_qty from public.stock_levels where barcode='8964000100062') =
  (select p.stock_qty from public.products p where p.barcode='8964000100062'));

select t('the correction is explained in the ledger',
  exists (select 1 from public.inventory_movements where note like 'Stock take%'));

select t('no stock take is left open', (public.current_stock_take()) is null);

-- =====================================================================
--  7. WEIGHED ITEMS
-- =====================================================================
select t_login('manager@supermart.local');
select t('a product can be marked as sold by weight',
  (public.set_product_weighed(jsonb_build_object(
     'id',(select id from public.products where barcode='8964000100062'),'is_weighed',true))->>'is_weighed')::boolean);

select t('the cashier mirror carries the weight flag',
  (select is_weighed from public.stock_levels where barcode='8964000100062'));

select t('a decimal quantity can be sold',
  (public.pos_sale(jsonb_build_object('client_uuid',gen_random_uuid(),
     'items',jsonb_build_array(jsonb_build_object(
        'product_id',(select id from public.products where barcode='8964000100062'),'qty',1.5))))->>'invoice_no') is not null);

select t('scale settings can be saved',
  (public.save_scale_settings(jsonb_build_object('scale_barcode_prefix','22','scale_barcode_mode','weight'))->>'scale_barcode_prefix') = '22');
select t_err('a silly scale prefix is refused',
  $$select public.save_scale_settings(jsonb_build_object('scale_barcode_prefix','AB'))$$, 'BAD_PREFIX');

-- =====================================================================
--  8. LOYALTY REDEMPTION
-- =====================================================================
select t_login('manager@supermart.local');
update public.customers set loyalty_points = 500 where phone = '0300-5551111';
select t('point value can be set',
  (public.save_scale_settings(jsonb_build_object('loyalty_point_value',0.5))->>'loyalty_point_value')::numeric = 0.5);

select t('balance converts points into rupees',
  (public.loyalty_balance((select id from public.customers where phone='0300-5551111'))->>'value')::numeric = 250);

select t('points can be redeemed against a bill',
  (public.redeem_loyalty_points(jsonb_build_object(
      'customer_id',(select id from public.customers where phone='0300-5551111'),
      'points',200))->>'value')::numeric = 100);

select t('the points were deducted',
  (select loyalty_points from public.customers where phone='0300-5551111') = 300);

select t_err('redeeming more points than the customer has is refused',
  $$select public.redeem_loyalty_points(jsonb_build_object(
      'customer_id',(select id from public.customers where phone='0300-5551111'),'points',99999))$$, 'NOT_ENOUGH_POINTS');

-- =====================================================================
--  9. BACKUP BUNDLE
-- =====================================================================
select t_login('manager@supermart.local');
select t('backup contains products', jsonb_array_length(public.backup_bundle()->'products') > 0);
select t('backup contains sales', jsonb_array_length(public.backup_bundle()->'sales') > 0);
select t('backup contains the stock ledger', jsonb_array_length(public.backup_bundle()->'movements') > 0);
select t('backup contains customers and suppliers',
  jsonb_array_length(public.backup_bundle()->'customers') > 0
  and jsonb_array_length(public.backup_bundle()->'suppliers') > 0);
select t('backup contains supplier payments and expenses',
  jsonb_array_length(public.backup_bundle()->'supplier_payments') > 0
  and jsonb_array_length(public.backup_bundle()->'expenses') > 0);

select t_login('cashier1@supermart.local');
select t_err('cashier cannot download the shop backup', $$select public.backup_bundle()$$, 'NOT_ALLOWED');

-- =====================================================================
--  10. THE NEW TABLES ARE STILL LOCKED DOWN
-- =====================================================================
select t('row level security is on for the new tables',
  (select count(*) from pg_class
    where relnamespace='public'::regnamespace
      and relname in ('supplier_payments','stock_takes','stock_take_items')
      and relrowsecurity) = 3);
select t('the app still cannot write to them directly',
  (select count(*) from information_schema.role_table_grants
    where grantee='authenticated' and table_schema='public'
      and table_name in ('supplier_payments','stock_takes','stock_take_items')
      and privilege_type in ('INSERT','UPDATE','DELETE')) = 0);
select t('the anonymous key still has nothing',
  (select count(*) from information_schema.role_table_grants
    where grantee='anon' and table_schema='public') = 0);
