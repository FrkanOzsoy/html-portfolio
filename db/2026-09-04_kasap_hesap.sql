-- Ramazan's "Hesap" tab (Kasap's 5th section, mobile: Ramazan/Ahmet/Furkan
-- only, desktop: unrestricted like the rest of Kasap) -- he's a contractor
-- who settles up based on his own Kasap sales and used to calculate that by
-- hand. Two pieces:
--
-- 1. kasap_manual_sales: a sale he made that isn't (or shouldn't be) counted
--    from the real POS data -- entered by hand (item, weight or price,
--    a date, an optional note).
-- 2. kasap_hesap_excluded_receipts: marks a real POS fiş as excluded from
--    *his calculation specifically* -- it still shows normally on the
--    regular Son İşlemler/İptaller tabs (the general store view), this only
--    hides it from the Hesap running total/list.

create table if not exists public.kasap_manual_sales (
  id uuid primary key default gen_random_uuid(),
  barcode text not null,
  stockname text not null,
  sale_date date not null,
  weight numeric,
  price numeric not null,
  note text,
  created_by text,
  created_at timestamptz not null default now()
);

create index if not exists kasap_manual_sales_sale_date_idx on public.kasap_manual_sales (sale_date);

alter table public.kasap_manual_sales enable row level security;
drop policy if exists kasap_manual_sales_all_authenticated on public.kasap_manual_sales;
create policy kasap_manual_sales_all_authenticated on public.kasap_manual_sales
  for all to authenticated using (true) with check (true);

create table if not exists public.kasap_hesap_excluded_receipts (
  receipt_id bigint primary key references public.kasa_receipts(id) on delete cascade,
  reason text,
  excluded_by text,
  excluded_at timestamptz not null default now()
);

alter table public.kasap_hesap_excluded_receipts enable row level security;
drop policy if exists kasap_hesap_excluded_receipts_all_authenticated on public.kasap_hesap_excluded_receipts;
create policy kasap_hesap_excluded_receipts_all_authenticated on public.kasap_hesap_excluded_receipts
  for all to authenticated using (true) with check (true);

-- Per-receipt subtotal of just the scoped (Kasap) lines, for a given set of
-- receipt ids -- powers both the Hesap tab's per-fiş amount and the new
-- "Kasap Tutarı" column on Son İşlemler/İptaller (the fiş's own `total`
-- column is the *whole* receipt, which can include non-Kasap items in a
-- mixed cart).
create or replace function public.kasa_receipt_scoped_subtotals(
  p_receipt_ids bigint[],
  p_barcodes text[]
)
returns table(receipt_id bigint, subtotal numeric)
language sql
stable
security definer
set search_path = public
as $$
  select l.receipt_id, sum(l.line_total) as subtotal
  from public.kasa_receipt_lines l
  where l.receipt_id = any(p_receipt_ids) and l.barcode = any(p_barcodes)
  group by l.receipt_id;
$$;

grant execute on function public.kasa_receipt_scoped_subtotals(bigint[], text[]) to authenticated, service_role;
