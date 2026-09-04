-- Fires an FCM push (via the mismatch-push edge function) to Furkan/Ahmet's
-- registered Android devices whenever a new row lands in
-- kasa_price_mismatches. Same net.http_post + service-role-key-in-header
-- pattern already used by the daily-summary-push cron job (see
-- docs/daily-summary-push.md) -- just event-triggered here instead of
-- scheduled. AFTER INSERT only: an UPDATE (e.g. resolved flipping) never
-- re-notifies.

select vault.create_secret('3965aad1c112cb7e3e2f9be8d2ab78d8c7be01f40861d2334ddca3f734d5f01c', 'mismatch_push_secret')
where not exists (select 1 from vault.secrets where name = 'mismatch_push_secret');

create or replace function public.mismatch_push_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://ioguubjvmpfaqshwrkvd.supabase.co/functions/v1/mismatch-push',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'mismatch_push_secret'),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'barcode', new.barcode,
      'name', new.name,
      'till_price', new.till_price,
      'catalog_price', new.catalog_price
    )
  );
  return new;
end;
$$;

drop trigger if exists mismatch_push_tg on public.kasa_price_mismatches;
create trigger mismatch_push_tg
  after insert on public.kasa_price_mismatches
  for each row execute function public.mismatch_push_notify();
