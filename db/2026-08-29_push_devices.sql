-- Devices that can receive the nightly "Günlük Özet" push. Every phone that
-- runs the app auto-upserts its FCM token here; the owner turns `enabled` on
-- for the (few) devices that should actually get the push, from the desktop
-- Ayarlar → Bildirimler list.
create table if not exists public.push_devices (
  fcm_token    text primary key,
  staff_name   text,
  platform     text default 'android',
  enabled      boolean not null default false,
  last_seen_at timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create index if not exists push_devices_enabled_idx on public.push_devices (enabled) where enabled;

alter table public.push_devices enable row level security;

-- Any signed-in staff device may register/refresh its own token and read the
-- list (the desktop Ayarlar screen shows every device). Toggling `enabled` is
-- also allowed for authenticated -- it is owner-facing UI, not device data.
drop policy if exists push_devices_all_authenticated on public.push_devices;
create policy push_devices_all_authenticated
  on public.push_devices for all to authenticated
  using (true) with check (true);

-- ---------------------------------------------------------------------------
-- One day's summary as JSON -- the edge function formats this into the push
-- text, and the app could reuse it later. p_day is a Türkiye-local date.
-- ---------------------------------------------------------------------------
create or replace function public.kasa_day_summary_json(p_day date default current_date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      (p_day::timestamp at time zone 'Europe/Istanbul') as lo,
      ((p_day + 1)::timestamp at time zone 'Europe/Istanbul') as hi
  ),
  r as (
    select * from public.kasa_receipts, bounds
    where receipt_type = 'FIS' and sold_at >= bounds.lo and sold_at < bounds.hi
  ),
  agg as (
    select
      count(*) filter (where not is_void)                              as fis,
      coalesce(sum(total) filter (where not is_void), 0)                as ciro,
      coalesce(sum(cash_total) filter (where not is_void), 0)           as nakit,
      coalesce(sum(card_total) filter (where not is_void), 0)           as kart,
      coalesce(sum(discount_total) filter (where not is_void), 0)       as indirim,
      coalesce(sum(line_count) filter (where not is_void), 0)           as urun,
      count(*) filter (where is_void)                                   as iptal_adet,
      coalesce(sum(total) filter (where is_void), 0)                    as iptal_tutar
    from r
  ),
  brands as (
    select jsonb_object_agg(card_brand, tot) as by_brand
    from (
      select coalesce(card_brand, 'Kart') as card_brand, sum(card_total) as tot
      from r where not is_void and card_total > 0
      group by 1
    ) b
  ),
  hours as (
    select extract(hour from (sold_at at time zone 'Europe/Istanbul'))::int as h, sum(total) as t
    from r where not is_void group by 1 order by t desc limit 1
  ),
  top as (
    select jsonb_agg(jsonb_build_object('barcode', d.barcode, 'name', p.stockname,
                                        'qty', d.qty, 'revenue', d.revenue)
                     order by d.revenue desc) as items
    from (
      select barcode, qty, revenue from public.kasa_product_sales_daily
      where sale_date = p_day order by revenue desc limit 5
    ) d
    left join public.products p on p.barcode = d.barcode
  ),
  mismatch as (
    select count(*) as open_count from public.kasa_price_mismatches where not resolved
  ),
  prev as ( -- same weekday, previous week
    select coalesce(sum(total), 0) as ciro
    from public.kasa_receipts, bounds
    where receipt_type = 'FIS' and not is_void
      and sold_at >= bounds.lo - interval '7 days'
      and sold_at <  bounds.hi - interval '7 days'
  )
  select jsonb_build_object(
    'day', p_day,
    'fis', agg.fis,
    'ciro', agg.ciro,
    'nakit', agg.nakit,
    'kart', agg.kart,
    'indirim', agg.indirim,
    'urun', agg.urun,
    'sepet', case when agg.fis > 0 then round(agg.ciro / agg.fis, 2) else 0 end,
    'iptal_adet', agg.iptal_adet,
    'iptal_tutar', agg.iptal_tutar,
    'kart_marka', coalesce(brands.by_brand, '{}'::jsonb),
    'yogun_saat', (select h from hours),
    'yogun_saat_tutar', (select t from hours),
    'en_cok_satan', coalesce(top.items, '[]'::jsonb),
    'acik_uyusmazlik', mismatch.open_count,
    'gecen_hafta_ciro', prev.ciro
  )
  from agg, brands, top, mismatch, prev;
$$;

grant execute on function public.kasa_day_summary_json(date) to authenticated, service_role;
