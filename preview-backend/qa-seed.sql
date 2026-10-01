-- Two fictional QA businesses for the private App Preview only.
-- Run with: supabase db query --linked --project-ref sgjpbknrmlacheilutej --file qa-seed.sql
-- This invokes the same validated import function as the operator panel and
-- does not grant anyone operator access.
begin;

select set_config(
  'request.jwt.claim.sub',
  (select user_id::text from public.preview_operators order by created_at limit 1),
  true
);

select public.preview_import_business($manifest$
{
  "slug": "juniper-demo",
  "display_name": "Juniper Coffee",
  "tagline": "Slow mornings, good coffee.",
  "logo_url": null,
  "hero_image_url": null,
  "font_preset": "editorial",
  "colors": {"background":"#F5F2EA","surface":"#FFFFFF","text":"#252C23","muted":"#6F756D","accent":"#315E45","accentText":"#FFFFFF"},
  "categories": [{"key":"coffee","label":"Coffee"},{"key":"food","label":"Bakery"}],
  "reward_title": "A coffee on us",
  "reward_threshold": 8,
  "source_url": null,
  "status": "draft",
  "menu": [
    {"category_key":"coffee","section":"Espresso bar","title":"Honey oat latte","description":"Espresso, oat milk, local honey","price_cents":625},
    {"category_key":"coffee","section":"Espresso bar","title":"Cappuccino","description":"Double espresso, steamed milk","price_cents":525},
    {"category_key":"food","section":"From the case","title":"Almond croissant","description":"Baked fresh every morning","price_cents":475}
  ]
}
$manifest$::jsonb);

select public.preview_import_business($manifest$
{
  "slug": "canyon-demo",
  "display_name": "Canyon Kitchen",
  "tagline": "Made for the good part of the day.",
  "logo_url": null,
  "hero_image_url": null,
  "font_preset": "rounded",
  "colors": {"background":"#FFF7EF","surface":"#FFFFFF","text":"#2E241F","muted":"#796E66","accent":"#B84D30","accentText":"#FFFFFF"},
  "categories": [{"key":"plates","label":"Plates"},{"key":"drinks","label":"Drinks"}],
  "reward_title": "A treat on us",
  "reward_threshold": 6,
  "source_url": null,
  "status": "draft",
  "menu": [
    {"category_key":"plates","section":"Lunch","title":"Crispy chicken sandwich","description":"Pickles, house sauce, soft bun","price_cents":1395},
    {"category_key":"plates","section":"Lunch","title":"Garden bowl","description":"Seasonal greens, grains, lemon","price_cents":1250},
    {"category_key":"drinks","section":"Sips","title":"Fresh lemonade","description":"Made in house","price_cents":425}
  ]
}
$manifest$::jsonb);

commit;
