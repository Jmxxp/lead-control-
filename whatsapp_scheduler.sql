-- Scheduler seguro do worker WhatsApp.
-- Pre-requisitos no Supabase Vault:
--   whatsapp_project_url
--   whatsapp_worker_secret

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Permite reaplicar este arquivo sem duplicar o job.
select cron.unschedule(jobid)
from cron.job
where jobname = 'whatsapp-worker-10-seconds';

select cron.schedule(
  'whatsapp-worker-10-seconds',
  '10 seconds',
  $worker_job$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'whatsapp_project_url'
    ) || '/functions/v1/whatsapp-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-worker-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'whatsapp_worker_secret'
      )
    ),
    body := '{"limit":25}'::jsonb,
    timeout_milliseconds := 20000
  );
  $worker_job$
);
