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
