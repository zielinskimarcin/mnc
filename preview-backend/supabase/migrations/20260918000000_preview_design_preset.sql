-- App Preview only: a business selects a shipped layout independently of its brand.
alter table public.preview_businesses
  add column design_preset text not null default 'mnc'
  check (design_preset in ('mnc', 'normal', 'chatchat'));

update public.preview_businesses set design_preset = 'normal'
where slug = 'normal-ice-cream-slc';

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
    design_preset, colors, categories, reward_title, reward_threshold, source_url, status
  ) values (
    v_slug, v_name, coalesce(p_manifest->>'tagline', ''),
    nullif(p_manifest->>'logo_url', ''), nullif(p_manifest->>'hero_image_url', ''),
    coalesce(p_manifest->>'font_preset', 'modern'),
    coalesce(p_manifest->>'design_preset', 'mnc'),
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
    design_preset = excluded.design_preset,
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
