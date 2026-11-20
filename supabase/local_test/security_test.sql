-- =====================================================================
--  SECURITY HARDENING TESTS  (run after SUPERMART_SETUP.sql and 09_security_hardening.sql)
--  Every line prints PASS or FAIL.
--    psql -d supermart -f local_test/security_test.sql
-- =====================================================================
\set ON_ERROR_STOP off

-- ---------- setup: owner sets a known manager PIN, cashier signs in
select t_login('owner@supermart.local');
select t('owner sets the manager PIN 4321', (public.set_manager_pin(jsonb_build_object('pin','4321'))->>'ok')::boolean);

select t_login('cashier1@supermart.local');
delete from public.pin_attempts where cashier_id = auth.uid();

-- ---------- 1. verify_manager_pin accepts the right PIN and records it
select t('correct PIN verifies', (public.verify_manager_pin(jsonb_build_object('pin','4321'),'Counter-1')->>'ok')::boolean);
select t('the correct attempt is recorded as a success',
  (select count(*) from public.pin_attempts where cashier_id = auth.uid() and succeeded) = 1);

-- ---------- 2. wrong PINs are recorded and counted down
select t('wrong PIN is refused, 4 attempts left',
  (public.verify_manager_pin(jsonb_build_object('pin','0000'),'Counter-1')->>'attempts_left')::int = 4);
select t('wrong PIN is refused, 3 attempts left',
  (public.verify_manager_pin(jsonb_build_object('pin','0001'),'Counter-1')->>'attempts_left')::int = 3);
select t('wrong PIN is refused, 2 attempts left',
  (public.verify_manager_pin(jsonb_build_object('pin','0002'),'Counter-1')->>'attempts_left')::int = 2);
select t('wrong PIN is refused, 1 attempt left',
  (public.verify_manager_pin(jsonb_build_object('pin','0003'),'Counter-1')->>'attempts_left')::int = 1);
select t('fifth wrong PIN locks the cashier out',
  (public.verify_manager_pin(jsonb_build_object('pin','0004'),'Counter-1')->>'locked')::boolean);
select t('failed attempts are kept (not rolled back)',
  (select count(*) from public.pin_attempts where cashier_id = auth.uid() and not succeeded) = 5);

-- ---------- 3. while locked, even the correct PIN is refused and nothing is logged
select t('locked cashier is refused even with the right PIN',
  (public.verify_manager_pin(jsonb_build_object('pin','4321'),'Counter-1')->>'locked')::boolean
  and not (public.verify_manager_pin(jsonb_build_object('pin','4321'),'Counter-1')->>'ok')::boolean);
select t('a refused lockout attempt is not logged again',
  (select count(*) from public.pin_attempts where cashier_id = auth.uid()) = 6);

-- ---------- 4. the approval path itself refuses while locked
select t_err('approval (fx_elevate) refused while locked out',
  $$select public.fx_elevate('4321','test')$$, 'PIN_LOCKED');

-- ---------- 5. another cashier is not affected by this cashier's lockout
select t_login('cashier2@supermart.local');
select t('a different cashier is not locked out',
  not coalesce((public.verify_manager_pin(jsonb_build_object('pin','4321'),'Counter-2')->>'locked')::boolean, false)
  and (public.verify_manager_pin(jsonb_build_object('pin','4321'),'Counter-2')->>'ok')::boolean);

-- ---------- 6. after the window passes, the cashier can approve again
select t_login('cashier1@supermart.local');
update public.pin_attempts set attempted_at = now() - interval '16 minutes'
 where cashier_id = auth.uid() and not succeeded;
select t('after 15 minutes the correct PIN works again',
  (public.verify_manager_pin(jsonb_build_object('pin','4321'),'Counter-1')->>'ok')::boolean);
select t('the lockout clears once the window has passed',
  public.fx_pin_locked_until(auth.uid()) is null);

-- ---------- 7. the attempt log is private to the server functions
-- the session is the database owner by default, which ignores grants; test as the app role
begin;
  set local role authenticated;
  select t_login('cashier1@supermart.local');
  select t_err('a cashier cannot read the PIN attempt log directly',
    $$select count(*) from public.pin_attempts$$, 'permission denied');
rollback;

-- ---------- 8. only signed-in staff can check a PIN at all
select t_login('owner@supermart.local');
select set_config('jwt.claim.sub', '', false);
select t_err('no login means no PIN check',
  $$select public.verify_manager_pin(jsonb_build_object('pin','4321'),'x')$$, 'Sign in as a staff member');

\echo '=== end of security tests ==='
