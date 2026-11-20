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
