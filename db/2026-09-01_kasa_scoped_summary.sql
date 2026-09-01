-- Exact, unlimited aggregates for the Kasap/Manav "Özet" tab and the
-- header line on their Son İşlemler/İptaller tabs. Replaces summing a
-- capped (limit 200/500) row fetch client-side, which silently understated
-- Fiş/Nakit/Kart/İndirim/İptal on any date range with more matching
-- receipts than the cap -- Ciro (from kasa_product_sales_report, always
-- unlimited) stayed correct while these went quietly wrong, causing the
-- numbers to visibly not add up on busier ranges (e.g. Son 30/90 gün).
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
  select
    count(*) filter (where not coalesce(r.is_void, false))                                  as fis_sayisi,
    coalesce(sum(r.total) filter (where not coalesce(r.is_void, false)), 0)                  as toplam,
    coalesce(sum(r.cash_total) filter (where not coalesce(r.is_void, false)), 0)             as nakit,
    coalesce(sum(r.card_total) filter (where not coalesce(r.is_void, false)), 0)             as kart,
    coalesce(sum(r.discount_total) filter (where not coalesce(r.is_void, false)), 0)         as indirim,
    count(*) filter (where coalesce(r.is_void, false))                                       as iptal_sayisi,
    coalesce(sum(r.total) filter (where coalesce(r.is_void, false)), 0)                      as iptal_deger
  from public.kasa_receipts r
  where exists (
      select 1 from public.kasa_receipt_lines l
      where l.receipt_id = r.id and l.barcode = any(p_barcodes)
    )
    and (p_from is null or r.sold_at >= p_from)
    and (p_to is null or r.sold_at < p_to)
    and r.receipt_type = 'FIS';
$$;

grant execute on function public.kasa_receipts_summary_for_barcodes(text[], timestamptz, timestamptz) to authenticated, service_role;

-- Hourly revenue for a single day, scoped to a barcode set -- line-level
-- (not whole-receipt), so a receipt with both a scoped item and something
-- else only counts the scoped portion. Powers Kasap/Manav's Özet chart
-- when the selected range is exactly one day (otherwise the daily trend,
-- already covered by kasa_product_sales_daily, is used instead).
create or replace function public.kasa_hourly_sales_for_barcodes(
  p_barcodes text[],
  p_day date
)
returns table (hour integer, revenue numeric)
language sql
stable
security definer
set search_path = public
as $$
  select
    extract(hour from (l.sold_at at time zone 'Europe/Istanbul'))::int as hour,
    coalesce(sum(l.line_total), 0) as revenue
  from public.kasa_receipt_lines l
  join public.kasa_receipts r on r.id = l.receipt_id
  where l.barcode = any(p_barcodes)
    and l.line_type = 'SAT'
    and coalesce(r.is_void, false) = false
    and (l.sold_at at time zone 'Europe/Istanbul')::date = p_day
  group by 1;
$$;

grant execute on function public.kasa_hourly_sales_for_barcodes(text[], date) to authenticated, service_role;
