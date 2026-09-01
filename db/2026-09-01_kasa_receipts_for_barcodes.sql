-- Receipts that contain at least one line matching a given barcode set --
-- powers the scoped "Son İşlemler"/"İptaller" views inside the Kasap/Manav
-- sections. Whole receipt rows are returned (not just the matching lines):
-- a receipt with both a scoped item and something else still shows in full,
-- same approximation the rest of the scoped-summary metrics make.
create or replace function public.kasa_receipts_for_barcodes(
  p_barcodes text[],
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_void_only boolean default false,
  p_limit integer default 60
)
returns setof kasa_receipts
language sql
stable
security definer
set search_path = public
as $$
  select r.*
  from public.kasa_receipts r
  where exists (
    select 1 from public.kasa_receipt_lines l
    where l.receipt_id = r.id and l.barcode = any(p_barcodes)
  )
    and (p_from is null or r.sold_at >= p_from)
    and (p_to is null or r.sold_at < p_to)
    and (not p_void_only or r.is_void = true)
    and r.receipt_type = 'FIS'
  order by r.sold_at desc
  limit p_limit;
$$;

grant execute on function public.kasa_receipts_for_barcodes(text[], timestamptz, timestamptz, boolean, integer) to authenticated, service_role;
