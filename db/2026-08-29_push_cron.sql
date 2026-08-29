-- Schedule the nightly Günlük Özet push. 20:30 UTC = 23:30 Türkiye (fixed
-- UTC+3, no DST). The cron secret lives in Vault (name 'push_cron_secret');
-- the edge function checks it against its PUSH_CRON_SECRET env.
select cron.unschedule('daily-summary-push')
where exists (select 1 from cron.job where jobname = 'daily-summary-push');

select cron.schedule(
  'daily-summary-push',
  '30 20 * * *',
  $$
  select net.http_post(
    url     := 'https://ioguubjvmpfaqshwrkvd.supabase.co/functions/v1/daily-summary-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000
  );
  $$
);
