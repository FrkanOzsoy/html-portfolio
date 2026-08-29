-- Helper routines the kasa daemon calls each tick.

-- Rebuild the last N days of kasa_product_sales_daily straight from
-- kasa_receipt_lines (SAT lines only). Always-correct for the recent window;
-- older rows are left frozen as historical data (receipt lines are pruned at
-- ~100 days, PSD is kept ~450 for the "dead stock" view).
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
  where l.line_type = 'SAT'
    and l.barcode is not null
    and l.sold_at >= ((current_date - p_days)::timestamp at time zone 'Europe/Istanbul')
  group by 1, 2;
$$;

-- One-off / occasional: full rebuild across the whole retained line window
-- (used right after the first-run backfill).
create or replace function public.rebuild_kasa_psd_all()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.kasa_product_sales_daily;

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
  where l.line_type = 'SAT' and l.barcode is not null
  group by 1, 2;
$$;

-- Retention prune. Keeps kasa_receipts/lines/payments ~100 days, PSD ~450,
-- resolved mismatches ~30 days past resolution. Z reports are never pruned.
create or replace function public.prune_kasa(
  p_tx_days   integer default 100,
  p_psd_days  integer default 450
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.kasa_payments
   where receipt_id in (select id from public.kasa_receipts
                        where sold_at < now() - make_interval(days => p_tx_days));
  delete from public.kasa_receipt_lines
   where sold_at < now() - make_interval(days => p_tx_days);
  delete from public.kasa_receipts
   where sold_at < now() - make_interval(days => p_tx_days);
  delete from public.kasa_product_sales_daily
   where sale_date < current_date - p_psd_days;
  delete from public.kasa_price_mismatches
   where resolved and detected_at < now() - interval '30 days';
end $$;

grant execute on function public.rebuild_kasa_psd(integer)      to service_role;
grant execute on function public.rebuild_kasa_psd_all()         to service_role;
grant execute on function public.prune_kasa(integer, integer)   to service_role;
