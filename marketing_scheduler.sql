-- Scheduler seguro do worker Meta Ads + Google Ads.
-- Rode somente depois de cadastrar no Supabase Vault:
--   marketing_project_url   = https://SEU-PROJETO.supabase.co
--   marketing_worker_secret = o mesmo MARKETING_WORKER_SECRET da Edge Function

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists(select 1 from vault.decrypted_secrets where name='marketing_project_url' and length(decrypted_secret)>20) then
    raise exception 'Crie o segredo marketing_project_url no Supabase Vault antes de agendar.';
  end if;
  if not exists(select 1 from vault.decrypted_secrets where name='marketing_worker_secret' and length(decrypted_secret)>=32) then
    raise exception 'Crie o segredo marketing_worker_secret no Supabase Vault antes de agendar.';
  end if;
end $$;

select cron.unschedule(jobid)
from cron.job
where jobname in ('marketing-worker-30-seconds','marketing-worker-2-minutes');

select cron.schedule(
  'marketing-worker-2-minutes',
  '*/2 * * * *',
  $worker_job$
  select net.http_post(
    url := rtrim((
      select decrypted_secret from vault.decrypted_secrets
      where name='marketing_project_url'
    ), '/') || '/functions/v1/marketing-worker',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'x-worker-secret',(
        select decrypted_secret from vault.decrypted_secrets
        where name='marketing_worker_secret'
      )
    ),
    body := '{"sync_limit":1,"conversion_limit":5,"diagnostic_limit":5}'::jsonb,
    timeout_milliseconds := 55000
  );
  $worker_job$
);

-- Diagnostico opcional:
-- select jobid,jobname,schedule,active from cron.job where jobname='marketing-worker-2-minutes';
-- select id,status_code,created from net._http_response order by created desc limit 10;
