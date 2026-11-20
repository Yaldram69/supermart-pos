-- =====================================================================
--  SUPERMART POS  --  00 : EXTENSIONS + ENUM TYPES
--  Run this FIRST in the Supabase SQL Editor.
--  Safe to re-run.
-- =====================================================================

create extension if not exists pgcrypto;      -- gen_random_uuid()
create extension if not exists "uuid-ossp";   -- uuid_generate_v4() (legacy safety)

-- ---------------------------------------------------------------------
-- ENUMS (wrapped so the file can be re-run without errors)
-- ---------------------------------------------------------------------
do $$ begin
  create type public.user_role as enum ('cashier','manager','admin','super_admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_method as enum
    ('cash','card','jazzcash','easypaisa','bank_transfer','credit');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.sale_status as enum
    ('completed','void','partially_refunded','refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.movement_type as enum
    ('opening','purchase','sale','sale_void','refund','adjustment','damage','transfer_in','transfer_out','return_supplier');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.discount_scope as enum ('all','category','product');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.discount_kind as enum ('percent','amount');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.po_status as enum ('draft','ordered','received','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.shift_status as enum ('open','closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.invoice_discount_type as enum ('none','percent','amount','code');
exception when duplicate_object then null; end $$;
