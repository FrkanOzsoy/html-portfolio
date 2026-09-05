-- Kasap/Manav Özet's "İptal" card summed the *whole* fiş total for a voided
-- receipt that merely contained a scoped item, instead of just the scoped
-- portion -- e.g. a cancelled 500 TL mixed cart with one 20 TL Kasap item
-- showed as "500 TL cancelled" on the Kasap tab. Exactly the bug
-- kasa_receipt_scoped_subtotals (2026-09-04) already fixed for the
-- per-receipt "Kasap Tutarı" column on Son İşlemler/İptaller -- just never
-- applied to this aggregate card too. Same signature, so this is a
-- drop-in replace; Fiş/Nakit/Kart/İndirim stay the existing documented
-- whole-fiş approximation (see 2026-09-01_kasa_scoped_summary.sql), only
-- iptal_deger changes.
create or replace function public.kasa_receipts_summary_for_barcodes(
  p_barcodes text[],
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns table (
  fis_sayisi   bigint,
  toplam       numeric,
  nakit        numeric,
  kart         numeric,
  indirim      numeric,
  iptal_sayisi bigint,
  iptal_deger  numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with matching as (
    select r.id, r.total, r.cash_total, r.card_total, r.discount_total, r.is_void
    from public.kasa_receipts r
    where exists (
        select 1 from public.kasa_receipt_lines l
        where l.receipt_id = r.id and l.barcode = any(p_barcodes)
      )
      and (p_from is null or r.sold_at >= p_from)
      and (p_to is null or r.sold_at < p_to)
      and r.receipt_type = 'FIS'
  ),
  void_scoped as (
    select l.receipt_id, sum(l.line_total) as subtotal
    from public.kasa_receipt_lines l
    join matching m on m.id = l.receipt_id and m.is_void
    where l.barcode = any(p_barcodes)
    group by l.receipt_id
  )
  select
    count(*) filter (where not coalesce(m.is_void, false))                           as fis_sayisi,
    coalesce(sum(m.total) filter (where not coalesce(m.is_void, false)), 0)          as toplam,
    coalesce(sum(m.cash_total) filter (where not coalesce(m.is_void, false)), 0)     as nakit,
    coalesce(sum(m.card_total) filter (where not coalesce(m.is_void, false)), 0)     as kart,
    coalesce(sum(m.discount_total) filter (where not coalesce(m.is_void, false)), 0) as indirim,
    count(*) filter (where coalesce(m.is_void, false))                               as iptal_sayisi,
    coalesce((select sum(subtotal) from void_scoped), 0)                             as iptal_deger
  from matching m;
$$;

grant execute on function public.kasa_receipts_summary_for_barcodes(text[], timestamptz, timestamptz) to authenticated, service_role;
