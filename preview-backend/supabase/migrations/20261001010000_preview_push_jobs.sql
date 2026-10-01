-- App Preview project only. Apply after 20261001000000_preview_dashboard.sql.
create table public.preview_push_jobs (
  id uuid primary key default gen_random_uuid(),
  business_slug text not null references public.preview_businesses(slug) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 100),
  body text not null check (length(btrim(body)) between 1 and 240),
  status text not null default 'scheduled' check (status in ('scheduled', 'processing', 'sent', 'cancelled')),
  send_at timestamptz not null,
  next_run_at timestamptz,
  repeat_cron text,
  time_zone text not null default 'America/Denver',
  operator_id uuid not null references auth.users(id),
  last_run_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint preview_push_jobs_repeat_check check (
    repeat_cron is null or repeat_cron ~ '^[0-5]?[0-9] ([01]?[0-9]|2[0-3]) \* \* (\*|[0-6])$'
  )
);

create index preview_push_jobs_due_idx on public.preview_push_jobs (next_run_at)
  where status = 'scheduled';

alter table public.preview_push_jobs enable row level security;
create policy "preview push jobs operator access" on public.preview_push_jobs
  for all to authenticated using ((select public.preview_is_operator()))
  with check ((select public.preview_is_operator()));

revoke all on public.preview_push_jobs from anon, authenticated;
grant select, insert, update on public.preview_push_jobs to authenticated;
