-- App Preview only. Production-like dashboard data stays isolated from client production projects.

create table public.preview_customers (
  id uuid primary key default gen_random_uuid(),
  business_slug text not null references public.preview_businesses(slug) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  email text not null,
  short_code text not null check (short_code ~ '^\d{3}$'),
  points integer not null default 0 check (points between 0 and 100000),
  visits integer not null default 0 check (visits between 0 and 100000),
  role text not null default 'customer' check (role in ('customer', 'staff', 'manager')),
  push_enabled boolean not null default true,
  joined_at timestamptz not null default now(),
  last_visit_at timestamptz,
  unique (business_slug, email),
  unique (business_slug, short_code)
);

alter table public.preview_point_events
  add column customer_id uuid references public.preview_customers(id) on delete set null;

create table public.preview_push_opens (
  id uuid primary key default gen_random_uuid(),
  push_log_id uuid not null references public.preview_push_log(id) on delete cascade,
  business_slug text not null references public.preview_businesses(slug) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  opened_at timestamptz not null default now(),
  unique (push_log_id, user_id)
);

create index preview_customers_business_idx on public.preview_customers (business_slug, joined_at desc);
create index preview_push_opens_business_idx on public.preview_push_opens (business_slug, opened_at desc);

alter table public.preview_customers enable row level security;
alter table public.preview_push_opens enable row level security;

create policy "preview customer operator read" on public.preview_customers
  for select to authenticated using ((select public.preview_is_operator()));
create policy "preview push opens operator read" on public.preview_push_opens
  for select to authenticated using ((select public.preview_is_operator()));

revoke all on public.preview_customers, public.preview_push_opens from anon, authenticated;
grant select on public.preview_customers, public.preview_push_opens to authenticated;

create or replace function public.preview_seed_customers(p_business_slug text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.preview_customers (
    business_slug, name, email, short_code, points, visits, role, push_enabled, joined_at, last_visit_at
  ) values
    (p_business_slug, 'Demo Customer', 'demo+' || p_business_slug || '@example.invalid', '123', 4, 4, 'customer', true, now() - interval '48 days', now() - interval '1 day'),
    (p_business_slug, 'Taylor Reed', 'taylor+' || p_business_slug || '@example.invalid', '287', 8, 13, 'customer', true, now() - interval '112 days', now() - interval '3 days'),
    (p_business_slug, 'Jordan Kim', 'jordan+' || p_business_slug || '@example.invalid', '451', 2, 6, 'staff', true, now() - interval '76 days', now() - interval '8 days'),
    (p_business_slug, 'Store Manager', 'manager+' || p_business_slug || '@example.invalid', '900', 0, 0, 'manager', false, now() - interval '160 days', null)
  on conflict (business_slug, short_code) do nothing;

  update public.preview_customers as customer
  set points = balance.points
  from public.preview_balances as balance
  where customer.business_slug = p_business_slug
    and customer.business_slug = balance.business_slug
    and customer.short_code = '123';
end;
$$;

revoke all on function public.preview_seed_customers(text) from public;

create or replace function public.preview_seed_customers_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.preview_seed_customers(new.slug);
  return new;
end;
$$;

create trigger preview_seed_customers_after_business
after insert or update on public.preview_businesses
for each row execute function public.preview_seed_customers_trigger();

select public.preview_seed_customers(slug) from public.preview_businesses;

update public.preview_point_events as event
set customer_id = customer.id
from public.preview_customers as customer
where event.business_slug = customer.business_slug
  and customer.short_code = '123'
  and event.customer_id is null;

create or replace function public.preview_adjust_points_by_code(
  p_business_slug text, p_short_code text, p_delta integer
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid;
  v_points integer;
begin
  if not (select public.preview_is_operator()) then
    raise exception 'Operator access required' using errcode = '42501';
  end if;
  if p_delta is null or p_delta < -20 or p_delta > 20 or p_delta = 0 then
    raise exception 'Point adjustment must be between -20 and 20 and nonzero';
  end if;

  select id into v_customer_id from public.preview_customers
  where business_slug = p_business_slug and short_code = p_short_code
  for update;
  if v_customer_id is null then raise exception 'Customer not found'; end if;

  update public.preview_customers
  set points = greatest(0, least(100000, points + p_delta)),
      visits = visits + case when p_delta > 0 then 1 else 0 end,
      last_visit_at = case when p_delta > 0 then now() else last_visit_at end
  where id = v_customer_id
  returning points into v_points;

  if p_short_code = '123' then
    insert into public.preview_balances (business_slug, points, updated_at)
    values (p_business_slug, v_points, now())
    on conflict (business_slug) do update set points = excluded.points, updated_at = now();
  end if;

  insert into public.preview_point_events (business_slug, customer_id, delta, points_after, operator_id)
  values (p_business_slug, v_customer_id, p_delta, v_points, (select auth.uid()));
  return v_points;
end;
$$;

revoke all on function public.preview_adjust_points_by_code(text, text, integer) from public;
grant execute on function public.preview_adjust_points_by_code(text, text, integer) to authenticated;

create or replace function public.preview_redeem_reward_by_code(
  p_business_slug text, p_short_code text
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid;
  v_points integer;
  v_threshold integer;
begin
  if not (select public.preview_is_operator()) then
    raise exception 'Operator access required' using errcode = '42501';
  end if;
  select reward_threshold into v_threshold from public.preview_businesses where slug = p_business_slug;
  select id, points into v_customer_id, v_points from public.preview_customers
  where business_slug = p_business_slug and short_code = p_short_code for update;
  if v_customer_id is null then raise exception 'Customer not found'; end if;
  if v_points < v_threshold then raise exception 'Not enough points to redeem the reward'; end if;

  v_points := v_points - v_threshold;
  update public.preview_customers set points = v_points where id = v_customer_id;
  if p_short_code = '123' then
    update public.preview_balances set points = v_points, updated_at = now() where business_slug = p_business_slug;
  end if;
  insert into public.preview_point_events (business_slug, customer_id, delta, points_after, operator_id)
  values (p_business_slug, v_customer_id, -v_threshold, v_points, (select auth.uid()));
  return v_points;
end;
$$;

revoke all on function public.preview_redeem_reward_by_code(text, text) from public;
grant execute on function public.preview_redeem_reward_by_code(text, text) to authenticated;

create or replace function public.preview_set_customer_role(
  p_business_slug text, p_customer_id uuid, p_role text
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_current_role text;
begin
  if not (select public.preview_is_operator()) then raise exception 'Operator access required' using errcode = '42501'; end if;
  if p_role not in ('customer', 'staff', 'manager') then raise exception 'Unsupported role'; end if;
  select role into v_current_role from public.preview_customers where id = p_customer_id and business_slug = p_business_slug;
  if v_current_role is null then raise exception 'Customer not found'; end if;
  if v_current_role = 'manager' and p_role <> 'manager' and
    (select count(*) from public.preview_customers where business_slug = p_business_slug and role = 'manager') <= 1 then
    raise exception 'Keep at least one manager';
  end if;
  update public.preview_customers set role = p_role where id = p_customer_id and business_slug = p_business_slug;
end;
$$;

revoke all on function public.preview_set_customer_role(text, uuid, text) from public;
grant execute on function public.preview_set_customer_role(text, uuid, text) to authenticated;

create or replace function public.preview_delete_customer(
  p_business_slug text, p_customer_id uuid
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.preview_is_operator()) then raise exception 'Operator access required' using errcode = '42501'; end if;
  if exists (select 1 from public.preview_customers where id = p_customer_id and business_slug = p_business_slug and role = 'manager') then
    raise exception 'Manager accounts cannot be deleted';
  end if;
  delete from public.preview_customers where id = p_customer_id and business_slug = p_business_slug;
  if not found then raise exception 'Customer not found'; end if;
end;
$$;

revoke all on function public.preview_delete_customer(text, uuid) from public;
grant execute on function public.preview_delete_customer(text, uuid) to authenticated;

create or replace function public.preview_track_push_open(p_push_log_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_business_slug text;
begin
  if (select auth.uid()) is null then raise exception 'Sign in before tracking an open' using errcode = '42501'; end if;
  select business_slug into v_business_slug from public.preview_push_log where id = p_push_log_id;
  if v_business_slug is null then raise exception 'Unknown preview message'; end if;
  if not exists (
    select 1 from public.preview_devices
    where user_id = (select auth.uid()) and active_business_slug = v_business_slug and approved = true
  ) then raise exception 'Approved preview device required' using errcode = '42501'; end if;
  insert into public.preview_push_opens (push_log_id, business_slug, user_id)
  values (p_push_log_id, v_business_slug, (select auth.uid()))
  on conflict (push_log_id, user_id) do nothing;
end;
$$;

revoke all on function public.preview_track_push_open(uuid) from public;
grant execute on function public.preview_track_push_open(uuid) to authenticated;
