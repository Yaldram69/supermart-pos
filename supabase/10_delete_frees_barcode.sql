-- =====================================================================
--  SUPERMART POS  --  10 : deleting a product frees its barcode and SKU
--  Run AFTER 09_security_hardening.sql (safe to run more than once)
--
--  Products are soft-deleted (the row stays so old invoices still point at
--  something). The barcode and SKU columns are unique, so a deleted product
--  kept its barcode and blocked any new product from using it.
--  Now delete_product clears both, and this file cleans up products that were
--  deleted before this change.
-- =====================================================================

create or replace function public.delete_product(p_id uuid, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_row public.products;
begin
  perform public.fx_require_role(array['admin','super_admin']);
  update public.products set is_deleted = true, is_active = false, barcode = null, sku = null,
         updated_by = auth.uid()
   where id = p_id returning * into v_row;
  if not found then perform public.fx_fail('NOT_FOUND','Product not found.'); end if;
  perform public.fx_audit('product.delete','products', p_id::text, jsonb_build_object('name', v_row.name), p_device);
  return jsonb_build_object('ok', true);
end $$;

-- Free the codes held by products that were deleted before this fix.
-- Sales keep their own barcode_snapshot, so history is unchanged.
update public.products
   set barcode = null, sku = null
 where is_deleted = true and (barcode is not null or sku is not null);
