-- =====================================================================
--  08. PERFORMANCE INDEXES  (run once, after the main setup)
--  Safe to re-run: every statement is "if not exists".
--
--  Why: the till and the product screen search with ilike '%text%'.
--  A normal btree index cannot serve a leading wildcard, so every search
--  scanned the whole products table. A trigram (pg_trgm) index can.
--  The customer ledger filters sales by customer id and date; this index
--  lets Postgres do that without reading every sale.
-- =====================================================================

create extension if not exists pg_trgm;

create index if not exists products_name_trgm_idx
  on public.products using gin (name gin_trgm_ops);

create index if not exists products_barcode_trgm_idx
  on public.products using gin (barcode gin_trgm_ops);

create index if not exists products_sku_trgm_idx
  on public.products using gin (sku gin_trgm_ops);

create index if not exists sales_customer_created_idx
  on public.sales(customer_id, created_at desc);

analyze public.products;
analyze public.sales;
