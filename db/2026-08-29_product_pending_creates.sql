-- Staging table for new-product creation, so a new product stays local /
-- shared-pending until it's explicitly sent from the Kasaya Gönder tab
-- (mirrors product_pending_changes for field edits). "Sending" moves it
-- into product_create_requests, which the till-PC actually processes.
create table if not exists public.product_pending_creates (
  id           text primary key,                 -- client-generated uuid
  barcode      text not null,
  stockname    text not null,
  price        numeric not null,
  kasadepid    integer references public.kdv_departments(kasadepid),
  kdv_rate     numeric,
  stockunit    text,
  reyon        text,
  requested_by text,
  created_at   timestamptz not null default now()
);

alter table public.product_pending_creates enable row level security;

drop policy if exists product_pending_creates_all_authenticated on public.product_pending_creates;
create policy product_pending_creates_all_authenticated
  on public.product_pending_creates for all to authenticated
  using (true) with check (true);

do $$
begin
  alter publication supabase_realtime add table public.product_pending_creates;
exception when duplicate_object then null;
end $$;
