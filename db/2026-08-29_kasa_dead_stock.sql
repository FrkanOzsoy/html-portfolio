-- "Olu Stok" -- catalog products with no till sale in the last p_days.
-- Ordered by how recently they last sold (most-recently-stopped first);
-- p_require_history=true limits to products that DID sell at some point in
-- the mirror window (the actionable "was moving, now stalled" list).
create or replace function public.kasa_dead_stock(
  p_days            integer default 30,
  p_limit           integer default 500,
  p_require_history boolean default true
)
returns table (
  barcode      text,
  stockname    text,
  price        numeric,
  depno        text,
  stockunit    text,
  last_sold_at timestamptz,
  days_since   integer,
  qty_window   numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with sold_recently as (
    select distinct barcode
    from public.kasa_product_sales_daily
    where sale_date >= current_date - p_days
  ),
  agg as (
    select barcode,
           max(last_sold_at) as last_sold_at,
           sum(qty)          as qty_window
    from public.kasa_product_sales_daily
    group by barcode
  )
  select
    p.barcode,
    p.stockname,
    p.price,
    p.depno,
    p.stockunit,
    a.last_sold_at,
    case when a.last_sold_at is null then null
         else (current_date - a.last_sold_at::date) end as days_since,
    coalesce(a.qty_window, 0) as qty_window
  from public.products p
  left join agg a on a.barcode = p.barcode
  where p.barcode not in (select barcode from sold_recently)
    and (not p_require_history or a.last_sold_at is not null)
  order by a.last_sold_at desc nulls last, p.price desc nulls last
  limit p_limit;
$$;

grant execute on function public.kasa_dead_stock(integer, integer, boolean) to authenticated, service_role;

-- Per-barcode sales totals over an arbitrary date range -- "en cok satanlar"
-- for a week / month, not just one day (the app filters one day client-side
-- straight off kasa_product_sales_daily).
create or replace function public.kasa_top_products(
  p_from  date,
  p_to    date,
  p_limit integer default 50
)
returns table (
  barcode      text,
  qty          numeric,
  revenue      numeric,
  line_count   bigint,
  last_sold_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    barcode,
    sum(qty)            as qty,
    sum(revenue)        as revenue,
    sum(line_count)::bigint as line_count,
    max(last_sold_at)   as last_sold_at
  from public.kasa_product_sales_daily
  where sale_date between p_from and p_to
  group by barcode
  order by sum(revenue) desc
  limit p_limit;
$$;

grant execute on function public.kasa_top_products(date, date, integer) to authenticated, service_role;
