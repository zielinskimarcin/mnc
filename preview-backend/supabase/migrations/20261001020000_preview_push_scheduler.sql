-- App Preview project only. The scheduler uses a project JWT and a separate
-- secret, both stored in Supabase Vault (never in this migration or the client).
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'app-preview-scheduled-push',
  '* * * * *',
  $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'preview_push_project_url') || '/functions/v1/preview_run_scheduled_push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'preview_push_anon_jwt'),
        'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'preview_push_anon_jwt'),
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'preview_push_cron_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 5000
    );
  $job$
);
