import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "../..");
const out = path.join(root, "preview-backend/supabase/migrations/20260916001000_reference_brands.sql");
const quoted = (value) => `'${JSON.stringify(value).replaceAll("'", "''")}'::jsonb`;
const lines = [
  "-- Private preview only: snapshots of the repository's MNC and Mozzi brand/menu seeds.",
  "-- Existing preview edits are preserved on repeat deployment.",
];

for (const slug of ["mnc", "mozzi"]) {
  const config = JSON.parse(fs.readFileSync(path.join(root, `clients/${slug}/client.config.json`), "utf8"));
  const seed = JSON.parse(fs.readFileSync(path.join(root, `clients/${slug}/seed.json`), "utf8"));
  const business = {
    slug,
    display_name: config.displayName,
    tagline: "",
    font_preset: "modern",
    colors: {
      background: config.theme.colors.background,
      surface: config.theme.colors.surface,
      text: config.theme.colors.text,
      muted: config.theme.colors.muted,
      accent: config.theme.colors.primary,
      accentText: config.theme.colors.primaryText,
    },
    categories: config.menuCategories.map((item) => ({ key: item.key, label: item.label.pl })),
    reward_title: config.loyalty.copy.en.rewardReadyText,
    reward_threshold: config.loyalty.maxPoints,
    status: "ready",
  };
  const menu = seed.menuItems.filter((item) => item.isActive !== false).map((item) => ({
    category_key: item.category,
    section: item.section,
    title: item.title,
    description: item.description ?? null,
    price_cents: item.price,
    position: item.orderIndex,
  }));
  lines.push(`\ninsert into public.preview_businesses (slug, display_name, tagline, font_preset, colors, categories, reward_title, reward_threshold, status)
select b->>'slug', b->>'display_name', b->>'tagline', b->>'font_preset', b->'colors', b->'categories', b->>'reward_title', (b->>'reward_threshold')::integer, b->>'status'
from (select ${quoted(business)} as b) x
on conflict (slug) do nothing;

insert into public.preview_balances (business_slug, points) values ('${slug}', 0) on conflict do nothing;

insert into public.preview_menu_items (business_slug, category_key, section, title, description, price_cents, position)
select '${slug}', item->>'category_key', item->>'section', item->>'title', item->>'description', (item->>'price_cents')::integer, (item->>'position')::integer
from jsonb_array_elements(${quoted(menu)}) as rows(item)
where not exists (select 1 from public.preview_menu_items where business_slug = '${slug}');`);
}

fs.writeFileSync(out, lines.join("\n") + "\n");
process.stdout.write(`Generated ${out}\n`);
