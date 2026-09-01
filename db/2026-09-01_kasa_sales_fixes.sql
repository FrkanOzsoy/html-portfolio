-- Fix: kasa_product_sales_daily (and everything derived from it -- Ürün
-- Satışları, Top Products, Dead Stock) counted lines from fully-voided
-- receipts (kasa_receipts.is_void = true) as real sales. Only line_type
-- was filtered, never is_void -- a whole-receipt cancellation still leaves
-- its lines as line_type='SAT'. Confirmed live: 15,097 voided-receipt
-- lines / ₺1,950,745 were being counted as sold, vs 87,760 / ₺8.7M
-- genuinely valid. Günlük Özet's own totals are unaffected -- it already
-- excludes voids directly off kasa_receipts, not through this table.
create or replace function public.rebuild_kasa_psd(p_days integer default 3)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.kasa_product_sales_daily
  where sale_date >= (current_date - p_days);

  insert into public.kasa_product_sales_daily
    (sale_date, barcode, qty, revenue, line_count, last_sold_at)
  select
    (l.sold_at at time zone 'Europe/Istanbul')::date as sale_date,
    l.barcode,
    coalesce(sum(l.qty), 0),
    coalesce(sum(l.line_total), 0),
    count(*),
    max(l.sold_at)
  from public.kasa_receipt_lines l
  join public.kasa_receipts r on r.id = l.receipt_id
  where l.line_type = 'SAT'
    and coalesce(r.is_void, false) = false
    and l.barcode is not null
    and l.sold_at >= ((current_date - p_days)::timestamp at time zone 'Europe/Istanbul')
  group by 1, 2;
$$;

create or replace function public.rebuild_kasa_psd_all()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.kasa_product_sales_daily where sale_date is not null;

  insert into public.kasa_product_sales_daily
    (sale_date, barcode, qty, revenue, line_count, last_sold_at)
  select
    (l.sold_at at time zone 'Europe/Istanbul')::date as sale_date,
    l.barcode,
    coalesce(sum(l.qty), 0),
    coalesce(sum(l.line_total), 0),
    count(*),
    max(l.sold_at)
  from public.kasa_receipt_lines l
  join public.kasa_receipts r on r.id = l.receipt_id
  where l.line_type = 'SAT'
    and coalesce(r.is_void, false) = false
    and l.barcode is not null
  group by 1, 2;
$$;

grant execute on function public.rebuild_kasa_psd(integer) to service_role;
grant execute on function public.rebuild_kasa_psd_all()    to service_role;

-- kasa_product_sales_report gains an optional barcode-set filter, so the
-- new "Kasap" İstatistik subsection can reuse this same RPC (with its
-- existing products join + all-time last-sold-at logic) instead of
-- duplicating the aggregation client-side. Backward compatible: existing
-- callers (Ürün Satışları) never set p_barcodes, so p_barcodes is null
-- and every "and (p_barcodes is null or ...)" clause is a no-op filter.
create or replace function public.kasa_product_sales_report(
  p_from           date,
  p_to             date,
  p_depno          text     default null,
  p_include_unsold boolean  default true,
  p_limit          integer  default 1000,
  p_barcodes       text[]   default null
)
returns table (
  barcode      text,
  stockname    text,
  price        numeric,
  depno        text,
  stockunit    text,
  kdv_rate     numeric,
  qty          numeric,
  revenue      numeric,
  line_count   bigint,
  last_sold_at timestamptz,
  days_since   integer
)
language sql
stable
security definer
set search_path = public
as $$
  with range_agg as (
    select
      psd.barcode,
      sum(psd.qty)                 as qty,
      sum(psd.revenue)             as revenue,
      sum(psd.line_count)::bigint  as line_count
    from public.kasa_product_sales_daily psd
    where psd.sale_date between p_from and p_to
      and (p_barcodes is null or psd.barcode = any(p_barcodes))
    group by psd.barcode
  ),
  ever_sold as (
    select
      barcode,
      max(last_sold_at) as last_sold_at
    from public.kasa_product_sales_daily
    where (p_barcodes is null or barcode = any(p_barcodes))
    group by barcode
  )
  select
    p.barcode,
    p.stockname,
    p.price,
    p.depno,
    p.stockunit,
    p.kdv_rate,
    coalesce(ra.qty, 0)                as qty,
    coalesce(ra.revenue, 0)            as revenue,
    coalesce(ra.line_count, 0)::bigint as line_count,
    es.last_sold_at,
    case when es.last_sold_at is null then null
         else (current_date - es.last_sold_at::date) end as days_since
  from public.products p
  left join range_agg ra on ra.barcode = p.barcode
  left join ever_sold es on es.barcode = p.barcode
  where (p_depno is null or p.depno = p_depno)
    and (p_include_unsold or ra.barcode is not null)
    and (p_barcodes is null or p.barcode = any(p_barcodes))
  order by coalesce(ra.revenue, 0) desc
  limit p_limit;
$$;

grant execute on function public.kasa_product_sales_report(date, date, text, boolean, integer, text[]) to authenticated, service_role;

-- Sold vs. iptal (cancelled) breakdown for one product over a date range --
-- drives the drill-down shown when a Ürün Satışları / Kasap row is tapped.
-- "iptal" here covers both dimensions of cancellation in this data: a
-- whole receipt voided (kasa_receipts.is_void) and an individual line
-- reversal within an otherwise-valid receipt (line_type = 'IPT').
create or replace function public.kasa_product_sales_void_breakdown(
  p_barcode text,
  p_from    date,
  p_to      date
)
returns table (
  sold_qty      numeric,
  sold_revenue  numeric,
  sold_count    bigint,
  void_qty      numeric,
  void_revenue  numeric,
  void_count    bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(sum(l.qty) filter (where not coalesce(r.is_void, false) and l.line_type = 'SAT'), 0),
    coalesce(sum(l.line_total) filter (where not coalesce(r.is_void, false) and l.line_type = 'SAT'), 0),
    count(*) filter (where not coalesce(r.is_void, false) and l.line_type = 'SAT'),
    coalesce(sum(l.qty) filter (where coalesce(r.is_void, false) or l.line_type = 'IPT'), 0),
    coalesce(sum(l.line_total) filter (where coalesce(r.is_void, false) or l.line_type = 'IPT'), 0),
    count(*) filter (where coalesce(r.is_void, false) or l.line_type = 'IPT')
  from public.kasa_receipt_lines l
  join public.kasa_receipts r on r.id = l.receipt_id
  where l.barcode = p_barcode
    and (l.sold_at at time zone 'Europe/Istanbul')::date between p_from and p_to;
$$;

grant execute on function public.kasa_product_sales_void_breakdown(text, date, date) to authenticated, service_role;
