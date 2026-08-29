-- Kasa (INTER_BOS POS) mirror -- read-only in the app.
--
-- The till-PC daemon (C:\Digisoft\SupabaseSync) polls INTER_BOS
-- (SERVER\SQLEXPRESS) BELGE / HAREKET / ODEME / SERVER_ZREPORT by
-- high-water-mark id and upserts here with the service_role key (bypasses
-- RLS). Every app client gets SELECT only -- there is no path from the app
-- back to the till for this data.
--
-- Volume context: single store, single register, ~350 receipts + ~1000
-- line items per day. The daemon seeds ~90 days on first run and prunes
-- receipts/lines/payments older than 100 days; kasa_product_sales_daily is
-- kept ~450 days (feeds "dead stock"); zreports kept forever (tiny).

-- ---------------------------------------------------------------------------
-- receipt headers  (BELGE)
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_receipts (
  id              bigint primary key,               -- BELGE.ID (monotonic)
  belge_id        text not null,                    -- BELGE.Belge_ID (links lines/payments)
  register_no     smallint,                         -- Kasa_No
  cashier_no      integer,                          -- Kasiyer_No
  receipt_type    text,                             -- Belge_Tipi: FIS / ZRP / XRP
  receipt_no      integer,                          -- Belge_No (resets daily)
  sold_at         timestamptz not null,             -- Tarih
  closed_at       timestamptz,                      -- Kapanis
  z_no            smallint,                         -- Z_No
  subtotal        numeric(12,2),                    -- Matrah
  vat_total       numeric(12,2),                    -- Kdv
  total           numeric(12,2),                    -- Toplam
  cash_total      numeric(12,2),                    -- CASHTOTAL
  card_total      numeric(12,2),                    -- CREDITTOTAL
  discount_total  numeric(12,2),                    -- DISCOUNTTOTAL
  cancel_total    numeric(12,2),                    -- CANCELTOTAL
  is_void         boolean not null default false,   -- Iptal <> 0
  void_state      smallint,                         -- Iptal (raw)
  note            text,                             -- Notlar
  line_count      integer,
  synced_at       timestamptz not null default now()
);
create index if not exists kasa_receipts_sold_at_idx    on public.kasa_receipts (sold_at desc);
create index if not exists kasa_receipts_void_idx        on public.kasa_receipts (sold_at desc) where is_void;
create index if not exists kasa_receipts_z_no_idx        on public.kasa_receipts (z_no);
create index if not exists kasa_receipts_type_idx        on public.kasa_receipts (receipt_type);

-- ---------------------------------------------------------------------------
-- receipt lines  (HAREKET)
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_receipt_lines (
  hareket_id       bigint primary key,              -- HAREKET.HAREKETID
  receipt_id       bigint,                          -- -> kasa_receipts.id (may arrive before header; not FK)
  belge_id         text not null,
  line_no          integer,                         -- Satir
  line_type        text,                            -- Tip: SAT (sale) / IPT (void)
  barcode          text,
  stock_code       text,                            -- Stok_Kodu
  pluno            integer,
  name             text,                            -- Urun_Adi (usually null in source)
  qty              numeric(12,3),                   -- Adet
  unit_price       numeric(12,2),                   -- Fiyat (price actually charged)
  line_total       numeric(12,2),                   -- Tutar
  vat_rate         numeric(5,2),                    -- Kdv
  discount_amount  numeric(12,2),                   -- Ind_Miktar
  sold_at          timestamptz,                     -- Tarih
  synced_at        timestamptz not null default now()
);
create index if not exists kasa_receipt_lines_receipt_idx on public.kasa_receipt_lines (receipt_id);
create index if not exists kasa_receipt_lines_belge_idx   on public.kasa_receipt_lines (belge_id);
create index if not exists kasa_receipt_lines_barcode_idx on public.kasa_receipt_lines (barcode);
create index if not exists kasa_receipt_lines_sold_at_idx on public.kasa_receipt_lines (sold_at desc);

-- ---------------------------------------------------------------------------
-- payments  (ODEME)
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_payments (
  odeme_id     bigint primary key,                  -- ODEME.ODEMEID
  receipt_id   bigint,                              -- -> kasa_receipts.id (not FK, see above)
  belge_id     text not null,
  line_no      integer,                             -- Satir
  tender_key   integer,                             -- Tus_No
  card_type    smallint,                            -- Kart_Tipi
  method       text,                                -- derived: nakit / kart / diger
  amount       numeric(12,2),                       -- Tutar
  paid_amount  numeric(12,2),                       -- Odeme_Miktari
  synced_at    timestamptz not null default now()
);
create index if not exists kasa_payments_receipt_idx on public.kasa_payments (receipt_id);
create index if not exists kasa_payments_belge_idx   on public.kasa_payments (belge_id);

-- ---------------------------------------------------------------------------
-- Z reports  (SERVER_ZREPORT)
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_zreports (
  id            integer primary key,                -- SERVERZREPORTID
  z_no          smallint,
  z_date        timestamptz,                        -- ZDATE
  turnover      numeric(14,2),                      -- GIRO
  gps_turnover  numeric(14,2),                      -- GPSGIRO
  info          text,                               -- INFO (ntext)
  synced_at     timestamptz not null default now()
);
create index if not exists kasa_zreports_z_no_idx  on public.kasa_zreports (z_no desc);
create index if not exists kasa_zreports_date_idx  on public.kasa_zreports (z_date desc);

-- ---------------------------------------------------------------------------
-- rolled-up daily per-product sales  (feeds "top products" + "dead stock")
-- daemon upserts this incrementally as receipt lines arrive
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_product_sales_daily (
  sale_date      date not null,
  barcode        text not null,
  qty            numeric(14,3) not null default 0,
  revenue        numeric(14,2) not null default 0,
  line_count     integer not null default 0,
  last_sold_at   timestamptz,
  primary key (sale_date, barcode)
);
create index if not exists kasa_psd_date_idx    on public.kasa_product_sales_daily (sale_date desc);
create index if not exists kasa_psd_barcode_idx on public.kasa_product_sales_daily (barcode);

-- ---------------------------------------------------------------------------
-- price mismatches: till charged a price != catalog price for that barcode
-- daemon computes on each new SAT line against public.products.price
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_price_mismatches (
  id             bigint generated always as identity primary key,
  hareket_id     bigint not null unique,
  belge_id       text,
  barcode        text not null,
  name           text,
  till_price     numeric(12,2) not null,            -- charged at the till
  catalog_price  numeric(12,2) not null,            -- products.price at detection time
  diff           numeric(12,2) not null,            -- till_price - catalog_price
  sold_at        timestamptz not null,
  receipt_no     integer,
  resolved       boolean not null default false,    -- app can flip this (see policy below)
  detected_at    timestamptz not null default now()
);
create index if not exists kasa_pm_sold_at_idx  on public.kasa_price_mismatches (sold_at desc);
create index if not exists kasa_pm_open_idx     on public.kasa_price_mismatches (sold_at desc) where not resolved;
create index if not exists kasa_pm_barcode_idx  on public.kasa_price_mismatches (barcode);

-- ---------------------------------------------------------------------------
-- daemon high-water marks
-- ---------------------------------------------------------------------------
create table if not exists public.kasa_sync_state (
  key    text primary key,
  value  bigint not null
);

-- ---------------------------------------------------------------------------
-- RLS: authenticated app clients get SELECT only. The daemon uses
-- service_role, which bypasses RLS entirely. The single exception is
-- kasa_price_mismatches.resolved, which staff can toggle from the app.
-- ---------------------------------------------------------------------------
alter table public.kasa_receipts            enable row level security;
alter table public.kasa_receipt_lines       enable row level security;
alter table public.kasa_payments            enable row level security;
alter table public.kasa_zreports            enable row level security;
alter table public.kasa_product_sales_daily enable row level security;
alter table public.kasa_price_mismatches    enable row level security;
alter table public.kasa_sync_state          enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'kasa_receipts','kasa_receipt_lines','kasa_payments','kasa_zreports',
    'kasa_product_sales_daily','kasa_price_mismatches','kasa_sync_state'
  ]
  loop
    execute format(
      'drop policy if exists %I on public.%I', t || '_select_authenticated', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_select_authenticated', t);
  end loop;
end $$;

-- staff may mark a mismatch resolved/unresolved (only that column matters;
-- a broader UPDATE policy is fine since the row is daemon-owned reference data)
drop policy if exists kasa_price_mismatches_update_authenticated on public.kasa_price_mismatches;
create policy kasa_price_mismatches_update_authenticated
  on public.kasa_price_mismatches for update to authenticated
  using (true) with check (true);

-- ---------------------------------------------------------------------------
-- realtime: the live receipt feed and the mismatch alarm badge
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.kasa_receipts;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.kasa_price_mismatches;
  exception when duplicate_object then null;
  end;
end $$;
