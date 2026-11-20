-- =====================================================================
--  SUPERMART POS  --  BIG SUPERMARKET MODULE TEST  (local PostgreSQL only)
--
--  Proves the part 7 features work on a real database:
--    quantity price tiers, buy-X-get-Y offers, gift vouchers / store credit,
--    batch + expiry tracking, write-offs, returns to supplier, owner reports,
--    and the on/off switches in Settings.
--
--  Run:  sudo -u postgres psql -d smtest -q -f local_test/market_test.sql
--  Count: grep -c "PASS |"  and  grep -c "FAIL |"
--
--  Needs any database built by SUPERMART_SETUP.sql (the demo one is fine) or
--  by 00..07 in order. It creates its own products, tiers, offers and a
--  second shop user, so it does not depend on your own data.
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
    raise warning 'FAIL | % (nothing failed - that is a bug!)', p_label;
  exception when others then
    if sqlerrm like '%' || p_expect || '%' then raise notice 'PASS | %', p_label;
    else raise warning 'FAIL | % (wrong error: %)', p_label, sqlerrm; end if;
  end;
end $$;

create or replace function t_login(p_email text) returns uuid
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v uuid;
begin
  select id into v from auth.users where email = p_email;
  if v is null then raise exception 'test user % not found', p_email; end if;
  perform set_config('jwt.claim.sub', v::text, false);
  return v;
end $$;

-- ---------------------------------------------------------------- fixtures
-- A manager to create things and a cashier to ring them up.
do $$
declare v_mgr uuid; v_cash uuid; v_store uuid;
begin
  select id into v_store from public.stores order by is_default desc, created_at limit 1;

  -- The suite always uses its OWN two logins (never yours), so it can be run
  -- again and again on the same database without touching real staff.
  select id into v_mgr from public.profiles where email = 'market.mgr@supermart.local';
  if v_mgr is null then
    insert into auth.users(id, email, raw_user_meta_data)
    values (gen_random_uuid(), 'market.mgr@supermart.local',
            jsonb_build_object('full_name','Market Manager'));
    select id into v_mgr from public.profiles where email = 'market.mgr@supermart.local';
  end if;
  update public.profiles set role = 'manager', is_active = true where id = v_mgr;

  select id into v_cash from public.profiles where email = 'market.cash@supermart.local';
  if v_cash is null then
    insert into auth.users(id, email, raw_user_meta_data)
    values (gen_random_uuid(), 'market.cash@supermart.local',
            jsonb_build_object('full_name','Market Cashier'));
    select id into v_cash from public.profiles where email = 'market.cash@supermart.local';
  end if;
  update public.profiles set role = 'cashier', max_discount_percent = 5, is_active = true where id = v_cash;

  -- fresh switches, fresh fixtures
  update public.stores set enable_tiers = true, enable_offers = true,
         enable_vouchers = true, block_expired_sales = false, require_expiry = false
   where id = v_store;
  delete from public.price_tiers where product_id in
    (select id from public.products where barcode in ('MKT-TIER-1','MKT-OFFER-1','MKT-BATCH-1'));
  delete from public.offers where name like 'MKT %';
  delete from public.product_batches where product_id in
    (select id from public.products where barcode in ('MKT-TIER-1','MKT-OFFER-1','MKT-BATCH-1'));
  delete from public.inventory_movements where product_id in
    (select id from public.products where barcode in ('MKT-TIER-1','MKT-OFFER-1','MKT-BATCH-1'))
    and movement_type in ('opening','adjustment');

  insert into public.products(name, barcode, unit, cost_price, sale_price, stock_qty, is_active)
  values
    ('MKT Rice 5kg',  'MKT-TIER-1',  'bag', 900, 1000, 100, true),
    ('MKT Juice 1ltr','MKT-OFFER-1', 'pcs', 60,  100,  100, true),
    ('MKT Yoghurt',   'MKT-BATCH-1', 'pcs', 40,   60,   50, true)
  on conflict (barcode) do update set stock_qty = excluded.stock_qty,
        cost_price = excluded.cost_price, sale_price = excluded.sale_price, is_active = true;

  -- the till mirror (products -> stock_levels) is kept by a trigger, but a
  -- direct insert may have skipped it on odd installs, so top it up:
  insert into public.stock_levels(product_id, barcode, name, unit, sale_price, tax_percent,
                                  stock_qty, reorder_level, category_id, category_name, is_active)
  select p.id, p.barcode, p.name, p.unit, p.sale_price, p.tax_percent, p.stock_qty,
         p.reorder_level, p.category_id, c.name, p.is_active
    from public.products p left join public.categories c on c.id = p.category_id
   where p.barcode in ('MKT-TIER-1','MKT-OFFER-1','MKT-BATCH-1')
  on conflict (product_id) do update set stock_qty = excluded.stock_qty,
        sale_price = excluded.sale_price, is_active = true;
end $$;

select public.t_login('market.mgr@supermart.local');

-- ------------------------------------------------------- 1. QUANTITY TIERS
do $$
declare v_p uuid; v_ok boolean;
begin
  select id into v_p from public.products where barcode = 'MKT-TIER-1';
  perform public.save_price_tier(jsonb_build_object('product_id', v_p, 'min_qty', 10, 'price', 900,
                                                    'label', 'carton rate'));
  select count(*) = 1 into v_ok from public.price_tiers where product_id = v_p and min_qty = 10;
  perform public.t('a price break can be saved for a product ("10+ at 900")', v_ok);

  perform public.t_err('a price break refuses a silly quantity (0 and below)',
    format('select public.save_price_tier(%L::jsonb)',
      jsonb_build_object('product_id', v_p, 'min_qty', 0, 'price', 900)),
    'BAD_QTY');

  perform public.t_err('a price break refuses a price of zero',
    format('select public.save_price_tier(%L::jsonb)',
      jsonb_build_object('product_id', v_p, 'min_qty', 5, 'price', 0)),
    'BAD_PRICE');

  perform public.t_err('the same quantity cannot be priced twice',
    format('select public.save_price_tier(%L::jsonb)',
      jsonb_build_object('product_id', v_p, 'min_qty', 10, 'price', 850)),
    'DUPLICATE_TIER');
end $$;

select public.t_login('market.cash@supermart.local');

do $$
declare v_p uuid; v_res jsonb; v_q numeric;
begin
  select id into v_p from public.products where barcode = 'MKT-TIER-1';

  v_res := public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 10)),
    'payment_method','cash','paid_amount',20000));
  perform public.t('10 bags are charged the 10+ price: 10 x 900 = 9000 on the line',
    (v_res->'lines'->0->>'unit_price')::numeric = 900
    and (v_res->'lines'->0->>'line_total')::numeric = 9000);

  v_res := public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 9)),
    'payment_method','cash','paid_amount',20000));
  perform public.t('9 bags still pay the shelf price: 9 x 1000 = 9000 on the line',
    (v_res->'lines'->0->>'line_total')::numeric = 9000);

  update public.stores set enable_tiers = false;
  v_res := public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 10)),
    'payment_method','cash','paid_amount',20000));
  perform public.t('switching price tiers OFF makes the till ignore them (10 x 1000 = 10000)',
    (v_res->'lines'->0->>'line_total')::numeric = 10000);
  update public.stores set enable_tiers = true;
end $$;

-- ------------------------------------------------------------ 2. OFFERS
do $$
declare v_p uuid; v_res jsonb; v_used int; v_free numeric;
begin
  select id into v_p from public.products where barcode = 'MKT-OFFER-1';
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);
  perform public.save_offer(jsonb_build_object('name','MKT buy 2 get 1','product_id', v_p,
                                               'buy_qty', 2, 'free_qty', 1, 'is_active', true));
  perform public.t('an offer can be created ("buy 2 get 1 free")',
    (select count(*) = 1 from public.offers where name = 'MKT buy 2 get 1' and is_active));

  perform public.t_err('an offer needs a real buy and get quantity',
    format('select public.save_offer(%L::jsonb)',
      jsonb_build_object('name','MKT silly','product_id', v_p,'buy_qty',0,'free_qty',1)),
    'BAD_OFFER');

  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.cash@supermart.local'), false);
  v_res := public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 3)),
    'payment_method','cash','paid_amount',20000));
  perform public.t('3 bottles of a buy-2-get-1 item cost 2: total 200',
    (v_res->>'total')::numeric = 200);
  select count(*), coalesce(sum((details->>'free_value')::numeric),0) into v_used, v_free
    from public.audit_logs
   where action = 'offer.applied' and details->>'invoice_no' = v_res->>'invoice_no';
  perform public.t('the offer was written into the audit trail with the free value (100)',
    v_used = 1 and v_free = 100);

  update public.stores set enable_offers = false;
  v_res := public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 3)),
    'payment_method','cash','paid_amount',20000));
  perform public.t('switching offers OFF stops the free item (3 x 100 = 300)',
    (v_res->>'total')::numeric = 300);
  update public.stores set enable_offers = true;
end $$;

-- ----------------------------------------------------------- 3. VOUCHERS
do $$
declare v_res jsonb; v_bal numeric; v_iss jsonb; v_code text; v_p uuid;
begin
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);
  v_iss := public.issue_voucher(jsonb_build_object('kind','gift','value',500,
        'issued_to','Test Customer','phone','03001234567','reason','test'));
  v_code := v_iss->>'code';
  perform public.t('a gift voucher can be issued and gets a code', length(v_code) > 4);

  v_bal := (public.voucher_balance(jsonb_build_object('code', v_code)))::jsonb->>'balance';
  perform public.t('the voucher shows its full balance (500)', v_bal = 500);

  select id into v_p from public.products where barcode = 'MKT-TIER-1';
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.cash@supermart.local'), false);
  v_res := public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 1)),
    'payment_method','cash','paid_amount',2000, 'voucher_code', v_code));
  perform public.t('the voucher paid part of the bill: 1000 bill, 0 cash needed',
    (v_res->>'voucher_amount')::numeric = 500 and (v_res->>'total')::numeric = 1000);
  v_bal := (public.voucher_balance(jsonb_build_object('code', v_code)))::jsonb->>'balance';
  perform public.t('the voucher balance went down to 0 after use', v_bal = 0);

  perform public.t_err('a used-up voucher is refused',
    format('select public.pos_sale(%L::jsonb)',
      jsonb_build_object('client_uuid', gen_random_uuid(),
        'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 1)),
        'payment_method','cash','paid_amount',2000, 'voucher_code', v_code)),
    'VOUCHER_EMPTY');

  perform public.t_err('a made-up voucher code is refused',
    format('select public.pos_sale(%L::jsonb)',
      jsonb_build_object('client_uuid', gen_random_uuid(),
        'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 1)),
        'payment_method','cash','paid_amount',2000, 'voucher_code','GV-NOPE99')),
    'VOUCHER_INVALID');

  update public.stores set enable_vouchers = false;
  perform public.t_err('switching vouchers OFF refuses them at the till',
    format('select public.pos_sale(%L::jsonb)',
      jsonb_build_object('client_uuid', gen_random_uuid(),
        'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 1)),
        'payment_method','cash','paid_amount',2000, 'voucher_code','GV-NOPE99')),
    'VOUCHERS_OFF');
  update public.stores set enable_vouchers = true;
end $$;

-- ------------------------------------------------- 4. BATCHES AND EXPIRY
do $$
declare v_p uuid; v_sup uuid; v_res jsonb; v_b public.product_batches;
        v_cnt int; v_risk numeric; v_stock numeric; v_stock2 numeric; v_qty0 numeric;
begin
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);
  select id into v_p from public.products where barcode = 'MKT-BATCH-1';
  select id into v_sup from public.suppliers order by created_at limit 1;
  if v_sup is null then
    insert into public.suppliers(name) values ('MKT Supplier') returning id into v_sup;
  end if;

  v_res := public.receive_purchase(jsonb_build_object(
    'supplier_id', v_sup, 'payment_method','cash', 'paid_amount', 0,
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 40,
      'unit_cost', 40, 'sale_price', 60, 'batch_no','YO-4471',
      'mfg_date', (current_date - 5)::text,
      'expiry_date', (current_date + 20)::text))));
  perform public.t('a delivery booked in with a batch number and expiry date is accepted',
    (v_res->>'po_no') is not null);

  select count(*) into v_cnt from public.product_batches where product_id = v_p and batch_no = 'YO-4471';
  perform public.t('the delivery created a batch that can be followed later', v_cnt = 1);

  select * into v_b from public.product_batches where product_id = v_p and batch_no = 'YO-4471';
  perform public.t('the batch remembers its expiry date and 40 units',
    v_b.expiry_date = current_date + 20 and v_b.qty_remaining = 40);

  perform public.t('the product now shows an expiry date for the shelf',
    (select expiry_date from public.products where id = v_p) = current_date + 20);

  select count(*) into v_cnt
    from jsonb_array_elements(public.expiring_stock(jsonb_build_object('days', 30)) -> 'rows') a
   where (a->>'product_id')::uuid = v_p;
  perform public.t('the batch appears on the expiry report (within 30 days)', v_cnt = 1);

  v_risk := ((public.expiring_stock(jsonb_build_object('days', 30)))::jsonb->>'at_risk_value')::numeric;
  perform public.t('the report values the money at risk', v_risk > 0);

  -- selling takes it off the batch first (first expire, first out)
  select stock_qty into v_stock from public.products where id = v_p;
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.cash@supermart.local'), false);
  perform public.pos_sale(jsonb_build_object('client_uuid', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 5)),
    'payment_method','cash','paid_amount',2000));
  select qty_remaining into v_qty0 from public.product_batches where id = v_b.id;
  perform public.t('selling 5 takes 5 off the batch (40 -> 35), so the expiry report stays true',
    v_qty0 = 35);

  -- an expired batch cannot be sold when the shop switches the guard on
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);
  update public.product_batches set expiry_date = current_date - 2 where id = v_b.id;
  update public.stores set block_expired_sales = true;
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.cash@supermart.local'), false);
  perform public.t_err('out-of-date stock cannot be sold while the guard is on',
    format('select public.pos_sale(%L::jsonb)',
      jsonb_build_object('client_uuid', gen_random_uuid(),
        'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 1)),
        'payment_method','cash','paid_amount',2000)),
    'BATCH_EXPIRED');
  update public.stores set block_expired_sales = false;

  -- write it off instead
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);
  select stock_qty into v_stock from public.products where id = v_p;
  v_res := public.write_off_stock(jsonb_build_object('batch_id', v_b.id, 'product_id', v_p,
    'qty', 35, 'reason','expired', 'note','test'));
  select stock_qty into v_stock2 from public.products where id = v_p;
  select qty_remaining into v_qty0 from public.product_batches where id = v_b.id;
  perform public.t('writing off the expired batch clears the batch and the stock',
    v_qty0 = 0 and v_stock2 = v_stock - 35);

  perform public.t_err('a write-off needs a real reason',
    format('select public.write_off_stock(%L::jsonb)',
      jsonb_build_object('product_id', v_p, 'qty', 1, 'reason','because')),
    'BAD_REASON');
end $$;

-- ------------------------------------------- 5. RETURNS TO THE SUPPLIER
do $$
declare v_p uuid; v_sup uuid; v_res jsonb; v_before numeric; v_after numeric;
begin
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);
  select id into v_p from public.products where barcode = 'MKT-OFFER-1';
  select id into v_sup from public.suppliers order by created_at limit 1;

  select coalesce(sum(amount),0) into v_before from public.supplier_payments where supplier_id = v_sup;
  v_res := public.create_purchase_return(jsonb_build_object('supplier_id', v_sup,
    'reason','damaged in transit', 'settled_by','payable',
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p, 'qty', 6, 'unit_cost', 60))));
  select coalesce(sum(amount),0) into v_after from public.supplier_payments where supplier_id = v_sup;

  perform public.t('a return note to the supplier is saved with a number',
    (v_res->>'return_no') like 'PRT-%');
  perform public.t('the return is credited off what we owe that supplier (360)',
    (v_before - v_after) = 360);
  perform public.t('the return shows up in the returns list',
    jsonb_array_length((public.list_purchase_returns(jsonb_build_object('limit',50)))->'rows') >= 1);
end $$;

-- ------------------------------------------------------- 6. OWNER REPORTS
do $$
declare v jsonb;
begin
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.mgr@supermart.local'), false);

  v := public.profit_by_product(jsonb_build_object('from', (current_date - 1)::text,
        'to', (current_date + 1)::text, 'limit', 50, 'order','profit'));
  perform public.t('profit per product returns rows for today''s sales',
    jsonb_array_length(v->'rows') >= 1 and (v->'rows'->0 ? 'profit'));

  v := public.cashier_performance(jsonb_build_object('from', (current_date - 1)::text,
        'to', (current_date + 1)::text));
  perform public.t('the cashier scoreboard shows today''s tills',
    jsonb_array_length(v->'rows') >= 1 and (v->'rows'->0 ? 'discounts_given'));

  v := public.dead_stock(jsonb_build_object('days', 60));
  perform public.t('dead stock lists what is sitting on the shelf and what it ties up',
    (v->>'rows') is not null and (v->>'value_tied_up')::numeric >= 0);

  v := public.list_vouchers(jsonb_build_object());
  perform public.t('the voucher register lists issued vouchers',
    jsonb_array_length(v->'rows') >= 1);

  v := public.list_offers();
  perform public.t('the offer list shows whether each offer is running',
    jsonb_array_length(v->'rows') >= 1 and (v->'rows'->0 ? 'running'));
end $$;

-- --------------------------------------------------- 7. WHO MAY DO WHAT
do $$
begin
  perform set_config('jwt.claim.sub',
    (select id::text from public.profiles where email = 'market.cash@supermart.local'), false);
  perform public.t_err('a cashier cannot create price breaks',
    format('select public.save_price_tier(%L::jsonb)',
      jsonb_build_object('min_qty', 5, 'price', 10)), 'NOT_ALLOWED');
  perform public.t_err('a cashier cannot issue vouchers',
    format('select public.issue_voucher(%L::jsonb)', jsonb_build_object('value', 100)), 'NOT_ALLOWED');
  perform public.t_err('a cashier cannot receive a delivery',
    format('select public.receive_purchase(%L::jsonb)', jsonb_build_object('supplier_id', null)), 'NOT_ALLOWED');
  perform public.t('a cashier CAN read the expiry list for the shelf',
    (select count(*) >= 0 from public.expiring_stock(jsonb_build_object('days', 30))));
end $$;

do $$
declare v_bad text;
begin
  -- The test session itself is the database owner, which can do anything, so
  -- ask the catalogue what the app's own login role is allowed to do instead.
  select string_agg(t, ', ') into v_bad
    from unnest(array['vouchers','offers','price_tiers','product_batches','voucher_redemptions',
                       'purchase_returns','purchase_return_items']) t
   where has_table_privilege('authenticated', 'public.' || t, 'INSERT')
      or has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
      or has_table_privilege('authenticated', 'public.' || t, 'DELETE');
  perform public.t('the app login cannot write straight into the new tables (functions only)',
    coalesce(v_bad,'') = '');

  select string_agg(c.relname, ', ') into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not c.relrowsecurity
     and c.relname in ('vouchers','offers','price_tiers','product_batches','voucher_redemptions',
                       'purchase_returns','purchase_return_items');
  perform public.t('row level security is switched on for every new table', coalesce(v_bad,'') = '');

  perform public.t('the anonymous key (the public web key) can read nothing new',
    not has_table_privilege('anon','public.vouchers','SELECT')
    and not has_table_privilege('anon','public.product_batches','SELECT'));
end $$;

\echo ''
\echo '=== end of big supermarket module test ==='
\echo ''
