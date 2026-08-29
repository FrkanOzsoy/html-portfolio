-- "Ürün Satışları" — full product sales report for an arbitrary date range.
-- Returns every catalog product with its aggregated sales in the range,
-- plus all-time last-sale info from the full PSD window (~450 days).
create or replace function public.kasa_product_sales_report(
  p_from           date,
  p_to             date,
  p_depno          text     default null,
  p_include_unsold boolean  default true,
  p_limit          integer  default 1000
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
    group by psd.barcode
  ),
  ever_sold as (
    select
      barcode,
      max(last_sold_at) as last_sold_at
    from public.kasa_product_sales_daily
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
  order by coalesce(ra.revenue, 0) desc
  limit p_limit;
$$;

grant execute on function public.kasa_product_sales_report(date, date, text, boolean, integer) to authenticated, service_role;
