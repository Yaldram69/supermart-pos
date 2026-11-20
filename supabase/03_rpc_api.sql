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
