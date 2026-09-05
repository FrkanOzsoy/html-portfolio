-- Push Ramazan an FCM notification every time a Kasap (SARKUTERI, PLU
-- 50-100) item is sold at the till, naming only that item. Same
-- net.http_post + vault-secret + edge-function pattern as
-- 2026-09-04_mismatch_push.sql, just triggered off kasa_receipt_lines
-- instead of kasa_price_mismatches.

-- Ramazan's devices were never auto-enabled -- push_notify_names only had
-- Furkan/Ahmet (see 2026-08-30_push_auto_enable.sql). Add him so a future
-- token re-registration/refresh keeps his device enabled, and flip his
-- existing (currently disabled) rows on now.
insert into public.push_notify_names (name) values ('Ramazan')
  on conflict do nothing;

update public.push_devices set enabled = true where staff_name = 'Ramazan';

select vault.create_secret('632f68b2e9eb33f6b7c2d05b5191777b7c146b08abb9d122108700230ac430a1', 'kasap_sale_push_secret')
where not exists (select 1 from vault.secrets where name = 'kasap_sale_push_secret');

create or replace function public.kasap_sale_push_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if new.line_type <> 'SAT' or new.barcode is null then
    return new;
  end if;

  -- Kasap barcode set: SARKUTERI list_items with custom_data.plu in
  -- [50,100] -- same convention as DataRepo.getKasapBarcodes (Dart side),
  -- kept in sync manually since there's no shared source of truth.
  if not exists (
    select 1
    from public.list_items li
    join public.lists l on l.id = li.list_id
    where l.name = 'SARKUTERI'
      and li.barcode = new.barcode
      and li.custom_data->>'plu' ~ '^[0-9]+$'
      and (li.custom_data->>'plu')::int between 50 and 100
  ) then
    return new;
  end if;

  select p.stockname into v_name from public.products p where p.barcode = new.barcode;

  perform net.http_post(
    url := 'https://ioguubjvmpfaqshwrkvd.supabase.co/functions/v1/kasap-sale-push',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'kasap_sale_push_secret'),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'barcode', new.barcode,
      'name', coalesce(v_name, new.barcode),
      'qty', new.qty,
      'unit_price', new.unit_price,
      'line_total', new.line_total,
      'receipt_id', new.receipt_id
    )
  );
  return new;
end;
$$;

drop trigger if exists kasap_sale_push_tg on public.kasa_receipt_lines;
create trigger kasap_sale_push_tg
  after insert on public.kasa_receipt_lines
  for each row execute function public.kasap_sale_push_notify();
