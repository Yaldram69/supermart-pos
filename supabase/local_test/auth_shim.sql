-- =====================================================================
--  LOCAL TESTING ONLY -- DO NOT RUN THIS ON SUPABASE
--  Supabase already has the `auth` schema, `auth.users` and `auth.uid()`.
--  This file recreates the bare minimum of them so you can run the whole
--  schema on a plain PostgreSQL server (or on your own PC) to try things out:
--
--    createdb supermart
--    psql -d supermart -f local_test/auth_shim.sql
--    psql -d supermart -f 00_extensions_and_enums.sql
--    psql -d supermart -f 01_tables.sql
--    psql -d supermart -f 02_functions_triggers_views.sql
--    psql -d supermart -f 03_rpc_api.sql
--    psql -d supermart -f 04_rls_policies.sql
--    psql -d supermart -f 05_seed.sql
-- =====================================================================
create schema if not exists auth;

create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text unique,
  encrypted_password  text,
  raw_user_meta_data  jsonb default '{}'::jsonb,
  raw_app_meta_data   jsonb default '{}'::jsonb,
  created_at          timestamptz not null default now()
);

-- same shape as Supabase's auth.uid(): reads the JWT subject claim
create or replace function auth.uid()
returns uuid language sql stable as $$
  select nullif(current_setting('jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role()
returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon');
$$;

do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
