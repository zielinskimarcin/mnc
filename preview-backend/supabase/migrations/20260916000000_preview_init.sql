-- App Preview only. Never apply this migration to the production MNC project.
create extension if not exists pgcrypto with schema extensions;

create table public.preview_operators (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.preview_businesses (
  slug text primary key check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}$'),
  display_name text not null check (length(btrim(display_name)) between 1 and 80),
  tagline text not null default '',
  logo_url text,
  hero_image_url text,
  font_preset text not null default 'modern' check (font_preset in ('modern', 'editorial', 'rounded')),
  colors jsonb not null default '{"background":"#F8F7F3","surface":"#FFFFFF","text":"#20251F","muted":"#6D746D","accent":"#295C44","accentText":"#FFFFFF"}'::jsonb,
  categories jsonb not null default '[]'::jsonb check (jsonb_typeof(categories) = 'array'),
  reward_title text not null default 'Your reward',
  reward_threshold integer not null default 10 check (reward_threshold between 1 and 20),
  source_url text,
  status text not null default 'draft' check (status in ('draft', 'ready')),
  updated_at timestamptz not null default now()
);

create table public.preview_menu_items (
  id uuid primary key default gen_random_uuid(),
  business_slug text not null references public.preview_businesses(slug) on delete cascade,
  category_key text not null,
  section text not null default 'Menu',
  title text not null check (length(btrim(title)) between 1 and 120),
  description text,
  price_cents integer not null check (price_cents between 0 and 1000000),
  position integer not null default 0,
  created_at timestamptz not null default now()
);
create index preview_menu_business_position_idx on public.preview_menu_items (business_slug, category_key, position);

create table public.preview_balances (
  business_slug text primary key references public.preview_businesses(slug) on delete cascade,
  points integer not null default 0 check (points between 0 and 100000),
  updated_at timestamptz not null default now()
);

create table public.preview_point_events (
  id uuid primary key default gen_random_uuid(),
  business_slug text not null references public.preview_businesses(slug) on delete cascade,
  delta integer not null,
  points_after integer not null,
  operator_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.preview_devices (
  expo_token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  active_business_slug text not null references public.preview_businesses(slug) on delete cascade,
  device_name text not null default 'iPhone',
  approved boolean not null default false,
  updated_at timestamptz not null default now()
);
create index preview_devices_active_idx on public.preview_devices (active_business_slug, approved);

create table public.preview_push_log (
  id uuid primary key default gen_random_uuid(),
  business_slug text not null references public.preview_businesses(slug) on delete cascade,
  title text not null,
  body text not null,
  operator_id uuid not null references auth.users(id),
  recipients integer not null default 0,
  accepted integer not null default 0,
  expo_response jsonb,
  created_at timestamptz not null default now()
);

alter table public.preview_operators enable row level security;
alter table public.preview_businesses enable row level security;
alter table public.preview_menu_items enable row level security;
alter table public.preview_balances enable row level security;
alter table public.preview_point_events enable row level security;
alter table public.preview_devices enable row level security;
alter table public.preview_push_log enable row level security;

create or replace function public.preview_is_operator()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.preview_operators where user_id = (select auth.uid()));
$$;
revoke all on function public.preview_is_operator() from public;
grant execute on function public.preview_is_operator() to authenticated;

create policy "preview operator identity" on public.preview_operators
  for select to authenticated using (user_id = (select auth.uid()));
create policy "preview business read" on public.preview_businesses
  for select to anon, authenticated using (true);
create policy "preview business write" on public.preview_businesses
  for all to authenticated using ((select public.preview_is_operator()))
  with check ((select public.preview_is_operator()));
create policy "preview menu read" on public.preview_menu_items
  for select to anon, authenticated using (true);
create policy "preview menu write" on public.preview_menu_items
  for all to authenticated using ((select public.preview_is_operator()))
  with check ((select public.preview_is_operator()));
create policy "preview balances read" on public.preview_balances
  for select to anon, authenticated using (true);
create policy "preview point event admin read" on public.preview_point_events
  for select to authenticated using ((select public.preview_is_operator()));
create policy "preview device admin read" on public.preview_devices
  for select to authenticated using ((select public.preview_is_operator()));
create policy "preview push log admin read" on public.preview_push_log
  for select to authenticated using ((select public.preview_is_operator()));

revoke all on public.preview_operators, public.preview_businesses, public.preview_menu_items,
  public.preview_balances, public.preview_point_events, public.preview_devices,
  public.preview_push_log from anon, authenticated;
grant select on public.preview_businesses, public.preview_menu_items, public.preview_balances to anon, authenticated;
grant select on public.preview_operators, public.preview_point_events,
  public.preview_devices, public.preview_push_log to authenticated;
grant insert, update, delete on public.preview_businesses, public.preview_menu_items to authenticated;

create or replace function public.preview_register_device(
  p_token text, p_business_slug text, p_device_name text
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in anonymously before registering a device' using errcode = '42501';
  end if;
  if p_token !~ '^(Expo|Exponent)PushToken\[[^]]+\]$' or length(p_token) > 256 then
    raise exception 'Invalid Expo push token';
  end if;
  if not exists (select 1 from public.preview_businesses where slug = p_business_slug) then
    raise exception 'Unknown preview business';
  end if;
  if exists (select 1 from public.preview_devices where expo_token = p_token and user_id <> (select auth.uid())) then
    raise exception 'Device token belongs to a different demo session' using errcode = '42501';
  end if;
  insert into public.preview_devices (expo_token, user_id, active_business_slug, device_name)
  values (p_token, (select auth.uid()), p_business_slug, left(coalesce(p_device_name, 'iPhone'), 80))
  on conflict (expo_token) do update set
    active_business_slug = excluded.active_business_slug,
    device_name = excluded.device_name,
    updated_at = now();
end;
$$;
revoke all on function public.preview_register_device(text, text, text) from public;
grant execute on function public.preview_register_device(text, text, text) to authenticated;

create or replace function public.preview_set_device_approval(p_token text, p_approved boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.preview_is_operator()) then
    raise exception 'Operator access required' using errcode = '42501';
  end if;
  update public.preview_devices set approved = p_approved, updated_at = now()
  where expo_token = p_token;
  if not found then raise exception 'Device not found'; end if;
end;
$$;
revoke all on function public.preview_set_device_approval(text, boolean) from public;
grant execute on function public.preview_set_device_approval(text, boolean) to authenticated;

create or replace function public.preview_adjust_points(p_business_slug text, p_delta integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare next_points integer;
begin
  if not (select public.preview_is_operator()) then
    raise exception 'Operator access required' using errcode = '42501';
  end if;
  if p_delta is null or p_delta < -20 or p_delta > 20 or p_delta = 0 then
    raise exception 'Point adjustment must be between -20 and 20 and nonzero';
  end if;
  insert into public.preview_balances (business_slug, points)
  values (p_business_slug, greatest(0, p_delta))
  on conflict (business_slug) do update set
    points = greatest(0, least(100000, public.preview_balances.points + p_delta)),
    updated_at = now()
  returning points into next_points;
  insert into public.preview_point_events (business_slug, delta, points_after, operator_id)
  values (p_business_slug, p_delta, next_points, (select auth.uid()));
  return next_points;
end;
$$;
revoke all on function public.preview_adjust_points(text, integer) from public;
grant execute on function public.preview_adjust_points(text, integer) to authenticated;

-- A single transactional import is the fast path for one prospect: brand + full menu.
create or replace function public.preview_import_business(p_manifest jsonb)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_slug text := p_manifest->>'slug';
  v_name text := btrim(coalesce(p_manifest->>'display_name', ''));
  v_categories jsonb := p_manifest->'categories';
  v_items jsonb := p_manifest->'menu';
begin
  if not (select public.preview_is_operator()) then
    raise exception 'Operator access required' using errcode = '42501';
  end if;
  if v_slug is null or v_slug !~ '^[a-z0-9][a-z0-9-]{1,48}$' or length(v_name) < 1 or length(v_name) > 80 then
    raise exception 'Invalid business slug or name';
  end if;
  if v_categories is null or jsonb_typeof(v_categories) <> 'array' or jsonb_array_length(v_categories) < 1 or jsonb_array_length(v_categories) > 10 then
    raise exception 'Manifest needs 1–10 categories';
  end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) > 200 then
    raise exception 'Manifest menu must contain at most 200 items';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_items) as menu_item(value)
    where not exists (
      select 1 from jsonb_array_elements(v_categories) as category(value)
      where category.value->>'key' = menu_item.value->>'category_key'
    )
  ) then
    raise exception 'Menu item category does not exist in categories';
  end if;
  insert into public.preview_businesses (
    slug, display_name, tagline, logo_url, hero_image_url, font_preset,
    colors, categories, reward_title, reward_threshold, source_url, status
  ) values (
    v_slug, v_name, coalesce(p_manifest->>'tagline', ''),
    nullif(p_manifest->>'logo_url', ''), nullif(p_manifest->>'hero_image_url', ''),
    coalesce(p_manifest->>'font_preset', 'modern'),
    coalesce(p_manifest->'colors', '{}'::jsonb), v_categories,
    coalesce(p_manifest->>'reward_title', 'Your reward'),
    coalesce((p_manifest->>'reward_threshold')::integer, 10),
    nullif(p_manifest->>'source_url', ''), coalesce(p_manifest->>'status', 'draft')
  ) on conflict (slug) do update set
    display_name = excluded.display_name,
    tagline = excluded.tagline,
    logo_url = excluded.logo_url,
    hero_image_url = excluded.hero_image_url,
    font_preset = excluded.font_preset,
    colors = excluded.colors,
    categories = excluded.categories,
    reward_title = excluded.reward_title,
    reward_threshold = excluded.reward_threshold,
    source_url = excluded.source_url,
    status = excluded.status,
    updated_at = now();

  insert into public.preview_balances (business_slug, points)
  values (v_slug, 0) on conflict (business_slug) do nothing;
  delete from public.preview_menu_items where business_slug = v_slug;
  insert into public.preview_menu_items (
    business_slug, category_key, section, title, description, price_cents, position
  )
  select v_slug,
    item->>'category_key',
    coalesce(nullif(item->>'section', ''), 'Menu'),
    item->>'title',
    nullif(item->>'description', ''),
    (item->>'price_cents')::integer,
    ordinal::integer
  from jsonb_array_elements(v_items) with ordinality as menu_rows(item, ordinal);
  return v_slug;
end;
$$;
revoke all on function public.preview_import_business(jsonb) from public;
grant execute on function public.preview_import_business(jsonb) to authenticated;

insert into storage.buckets (id, name, public)
values ('preview-assets', 'preview-assets', true)
on conflict (id) do nothing;

create policy "preview assets public read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'preview-assets');
create policy "preview assets operator upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'preview-assets' and (select public.preview_is_operator()));
create policy "preview assets operator update" on storage.objects
  for update to authenticated using (bucket_id = 'preview-assets' and (select public.preview_is_operator()))
  with check (bucket_id = 'preview-assets' and (select public.preview_is_operator()));
