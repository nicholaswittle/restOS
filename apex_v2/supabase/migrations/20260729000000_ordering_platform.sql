-- Apex v2 — Online ordering platform (Jigsy menu port)
--
-- Brings the ordering vertical onto the same Apex Supabase project as
-- scheduling. One org_id, one RLS model, one app — no separate ordering DB.
--
-- Schema follows docs/Restaurant OS Unified Build Plan 2026-07-27.md Phases 1–2,
-- with organization_id denormalized onto tables the Flutter screens query
-- directly (same pattern as time_entries in the foundation migration). Child
-- rows (order_items, modifiers) stay scoped via their parent.
--
-- restaurants.public_token is the customer entry key: menu + cart work without
-- auth; staff console requires is_member(). online_orders.public_token is the
-- short confirmation code shown after place-order (generated client-side so
-- anon never needs a SELECT policy that would expose other customers).

-- ─── Phase 1: restaurant + menu ─────────────────────────────────────────────

create table if not exists restaurants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  name text not null,
  -- Unguessable slug customers use to open the menu without signing in.
  public_token text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists restaurants_org_idx on restaurants (organization_id);

create table if not exists restaurant_settings (
  restaurant_id uuid primary key references restaurants(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  paused boolean not null default false,
  prep_minutes int not null default 30 check (prep_minutes > 0),
  fee_cents int not null default 0 check (fee_cents >= 0),
  tax_rate real not null default 0.06 check (tax_rate >= 0),
  payment_mode text not null default 'manual'
);

create table if not exists restaurant_locations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  address text,
  city text,
  state text default 'PA',
  postcode text,
  lat real,
  lon real,
  phone text,
  hours_json jsonb
);

create table if not exists menu_categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  name text not null,
  sort_order int not null default 0
);

create index if not exists menu_categories_rest_idx
  on menu_categories (restaurant_id, sort_order);

create table if not exists menu_items (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  category_id uuid not null references menu_categories(id) on delete cascade,
  name text not null,
  description text,
  price_cents int not null check (price_cents >= 0),
  available boolean not null default true,
  sort_order int not null default 0
);

create index if not exists menu_items_rest_idx
  on menu_items (restaurant_id, category_id, sort_order);
create index if not exists menu_items_org_idx on menu_items (organization_id);

-- Attached to a single menu item (Phase 1 shape). Shared/reusable groups use
-- menu_item_modifier_groups below when the same crust/sauce set is linked to
-- many items without duplicating options.
create table if not exists modifier_groups (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid references menu_items(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  name text not null,
  required boolean not null default false,
  min_select int default 0,
  max_select int default 1
);

create table if not exists modifier_options (
  id uuid primary key default gen_random_uuid(),
  modifier_group_id uuid not null references modifier_groups(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  name text not null,
  price_delta_cents int not null default 0
);

-- ─── Phase 2: junction + orders ─────────────────────────────────────────────

create table if not exists menu_item_modifier_groups (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references menu_items(id) on delete cascade,
  modifier_group_id uuid not null references modifier_groups(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  required boolean,
  min_select int,
  max_select int,
  unique (menu_item_id, modifier_group_id)
);

create table if not exists online_orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants(id),
  organization_id uuid not null references organizations(id),
  public_token text unique not null,
  status text not null default 'waiting',
  submitted_at timestamptz not null default now(),
  accepted_at timestamptz,
  rejected_at timestamptz,
  completed_at timestamptz,
  reject_reason text,
  pickup_minutes int not null default 30,
  customer_json jsonb not null,
  notes text not null default '',
  subtotal_cents int not null check (subtotal_cents >= 0),
  fee_cents int not null default 0 check (fee_cents >= 0),
  tax_cents int not null default 0 check (tax_cents >= 0),
  total_cents int not null check (total_cents >= 0),
  payment_mode text not null default 'manual',
  payment_status text not null default 'pending'
);

create index if not exists online_orders_org_status_idx
  on online_orders (organization_id, status, submitted_at desc);
create index if not exists online_orders_rest_idx
  on online_orders (restaurant_id, submitted_at desc);

create table if not exists order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references online_orders(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  menu_item_id uuid references menu_items(id) on delete set null,
  name text not null,
  price_cents int not null,
  quantity int not null default 1 check (quantity > 0),
  notes text
);

create index if not exists order_items_order_idx on order_items (order_id);

create table if not exists order_item_modifiers (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references order_items(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  modifier_option_id uuid references modifier_options(id) on delete set null,
  name text not null,
  price_delta_cents int not null default 0
);

-- ─── RLS ────────────────────────────────────────────────────────────────────

alter table restaurants enable row level security;
alter table restaurant_settings enable row level security;
alter table restaurant_locations enable row level security;
alter table menu_categories enable row level security;
alter table menu_items enable row level security;
alter table modifier_groups enable row level security;
alter table modifier_options enable row level security;
alter table menu_item_modifier_groups enable row level security;
alter table online_orders enable row level security;
alter table order_items enable row level security;
alter table order_item_modifiers enable row level security;

-- Restaurant directory: members manage theirs; anyone may look up by
-- public_token so the customer menu loads without a session.
drop policy if exists restaurants_member_all on restaurants;
create policy restaurants_member_all on restaurants
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists restaurants_public_select on restaurants;
create policy restaurants_public_select on restaurants
  for select using (true);

drop policy if exists restaurant_settings_member on restaurant_settings;
create policy restaurant_settings_member on restaurant_settings
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists restaurant_settings_public_select on restaurant_settings;
create policy restaurant_settings_public_select on restaurant_settings
  for select using (true);

drop policy if exists restaurant_locations_member on restaurant_locations;
create policy restaurant_locations_member on restaurant_locations
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists restaurant_locations_public_select on restaurant_locations;
create policy restaurant_locations_public_select on restaurant_locations
  for select using (true);

drop policy if exists menu_categories_member on menu_categories;
create policy menu_categories_member on menu_categories
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists menu_categories_public_select on menu_categories;
create policy menu_categories_public_select on menu_categories
  for select using (true);

drop policy if exists menu_items_member on menu_items;
create policy menu_items_member on menu_items
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists menu_items_public_select on menu_items;
create policy menu_items_public_select on menu_items
  for select using (true);

drop policy if exists modifier_groups_member on modifier_groups;
create policy modifier_groups_member on modifier_groups
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists modifier_groups_public_select on modifier_groups;
create policy modifier_groups_public_select on modifier_groups
  for select using (true);

drop policy if exists modifier_options_member on modifier_options;
create policy modifier_options_member on modifier_options
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists modifier_options_public_select on modifier_options;
create policy modifier_options_public_select on modifier_options
  for select using (true);

drop policy if exists menu_item_modifier_groups_member on menu_item_modifier_groups;
create policy menu_item_modifier_groups_member on menu_item_modifier_groups
  for all using (is_member(organization_id))
  with check (has_role(organization_id, 'manager'));

drop policy if exists menu_item_modifier_groups_public_select on menu_item_modifier_groups;
create policy menu_item_modifier_groups_public_select on menu_item_modifier_groups
  for select using (true);

-- Orders: staff see everything for their venue. Anon may INSERT only (place
-- order); they never get a blanket SELECT — confirmation uses the token the
-- client already generated. Staff update status (accept / reject / complete).
drop policy if exists online_orders_member_select on online_orders;
create policy online_orders_member_select on online_orders
  for select using (is_member(organization_id));

drop policy if exists online_orders_member_update on online_orders;
create policy online_orders_member_update on online_orders
  for update using (is_member(organization_id))
  with check (is_member(organization_id));

drop policy if exists online_orders_insert on online_orders;
create policy online_orders_insert on online_orders
  for insert with check (
    exists (
      select 1 from restaurant_settings s
      where s.restaurant_id = online_orders.restaurant_id
        and s.paused = false
    )
  );

drop policy if exists order_items_member_select on order_items;
create policy order_items_member_select on order_items
  for select using (is_member(organization_id));

drop policy if exists order_items_insert on order_items;
create policy order_items_insert on order_items
  for insert with check (
    exists (select 1 from online_orders o where o.id = order_items.order_id)
  );

drop policy if exists order_item_modifiers_member_select on order_item_modifiers;
create policy order_item_modifiers_member_select on order_item_modifiers
  for select using (is_member(organization_id));

drop policy if exists order_item_modifiers_insert on order_item_modifiers;
create policy order_item_modifiers_insert on order_item_modifiers
  for insert with check (
    exists (select 1 from order_items i where i.id = order_item_modifiers.order_item_id)
  );

-- ─── Realtime ───────────────────────────────────────────────────────────────

do $$
begin
  begin
    alter publication supabase_realtime add table menu_items;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table restaurant_settings;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table online_orders;
  exception when duplicate_object then null;
  end;
end $$;

-- ─── Seed: Jigsy menu (19 items across 5 categories) ────────────────────────
-- Fixed UUIDs so re-runs are idempotent. Targets the jigsys org when present,
-- otherwise the first organization row.

do $$
declare
  v_org uuid;
  v_rest uuid := 'a1000000-0000-4000-8000-000000000001';
  v_cat_pizza uuid := 'a2000000-0000-4000-8000-000000000001';
  v_cat_wings uuid := 'a2000000-0000-4000-8000-000000000002';
  v_cat_subs uuid := 'a2000000-0000-4000-8000-000000000003';
  v_cat_apps uuid := 'a2000000-0000-4000-8000-000000000004';
  v_cat_brews uuid := 'a2000000-0000-4000-8000-000000000005';
  -- pizza items
  v_p1 uuid := 'a3000000-0000-4000-8000-000000000001';
  v_p2 uuid := 'a3000000-0000-4000-8000-000000000002';
  v_p3 uuid := 'a3000000-0000-4000-8000-000000000003';
  v_p4 uuid := 'a3000000-0000-4000-8000-000000000004';
  v_p5 uuid := 'a3000000-0000-4000-8000-000000000005';
  -- wings
  v_w1 uuid := 'a3000000-0000-4000-8000-000000000011';
  v_w2 uuid := 'a3000000-0000-4000-8000-000000000012';
  v_w3 uuid := 'a3000000-0000-4000-8000-000000000013';
  -- subs
  v_s1 uuid := 'a3000000-0000-4000-8000-000000000021';
  v_s2 uuid := 'a3000000-0000-4000-8000-000000000022';
  v_s3 uuid := 'a3000000-0000-4000-8000-000000000023';
  v_s4 uuid := 'a3000000-0000-4000-8000-000000000024';
  -- appetizers
  v_a1 uuid := 'a3000000-0000-4000-8000-000000000031';
  v_a2 uuid := 'a3000000-0000-4000-8000-000000000032';
  v_a3 uuid := 'a3000000-0000-4000-8000-000000000033';
  v_a4 uuid := 'a3000000-0000-4000-8000-000000000034';
  -- brews
  v_b1 uuid := 'a3000000-0000-4000-8000-000000000041';
  v_b2 uuid := 'a3000000-0000-4000-8000-000000000042';
  v_b3 uuid := 'a3000000-0000-4000-8000-000000000043';
  v_item uuid;
  v_grp uuid;
  v_crust text[] := array[
    'Traditional Old Forge Thick-Crust',
    'Thin & Crispy Tavern Crust',
    'Double-Crust Stuffed Crust'
  ];
  v_sauce text[] := array[
    'House Mild Sauce',
    'Signature Fire Hot',
    'Garlic Parmesan Crust Glaze',
    'Sweet Smokey BBQ'
  ];
  i int;
  opt text;
begin
  select id into v_org from organizations where lower(name) = 'jigsys' limit 1;
  if v_org is null then
    select id into v_org from organizations order by created_at nulls last limit 1;
  end if;
  if v_org is null then
    raise notice 'ordering seed skipped — no organizations row';
    return;
  end if;

  insert into restaurants (id, organization_id, name, public_token)
  values (v_rest, v_org, 'Jigsy''s Brewpub', 'jigsys')
  on conflict (id) do nothing;

  insert into restaurant_settings (
    restaurant_id, organization_id, paused, prep_minutes, fee_cents, tax_rate, payment_mode
  ) values (v_rest, v_org, false, 30, 0, 0.06, 'manual')
  on conflict (restaurant_id) do nothing;

  insert into restaurant_locations (
    id, restaurant_id, organization_id, address, city, state, postcode, phone
  ) values (
    'a1100000-0000-4000-8000-000000000001',
    v_rest, v_org,
    '225 N Enola Rd', 'Enola', 'PA', '17025', '(717) 732-6808'
  ) on conflict (id) do nothing;

  insert into menu_categories (id, restaurant_id, organization_id, name, sort_order) values
    (v_cat_pizza, v_rest, v_org, 'Old Forge Pizza Trays', 1),
    (v_cat_wings, v_rest, v_org, 'Award-Winning Wings', 2),
    (v_cat_subs,  v_rest, v_org, 'Specialty Subs', 3),
    (v_cat_apps,  v_rest, v_org, 'Starters & Sides', 4),
    (v_cat_brews, v_rest, v_org, 'House Brews To-Go', 5)
  on conflict (id) do nothing;

  insert into menu_items (id, restaurant_id, organization_id, category_id, name, description, price_cents, sort_order) values
    (v_p1, v_rest, v_org, v_cat_pizza, 'Old Forge Red Tray (12 Cuts)', 'Signature rectangular thick-crust. Crispy bottom, pillowy center, secret blend of cheeses.', 1850, 1),
    (v_p2, v_rest, v_org, v_cat_pizza, 'Old Forge White Tray (12 Cuts)', 'Double-crust pizza stuffed with a savory herb and cheese blend, topped with rosemary and sea salt.', 2100, 2),
    (v_p3, v_rest, v_org, v_cat_pizza, 'The Enola Special Tray', 'Red tray loaded with house-roasted porketta, green peppers, and sharp onions.', 2350, 3),
    (v_p4, v_rest, v_org, v_cat_pizza, 'Personal Red Pizza (4 Cuts)', 'Smaller 4-cut version of our famous rectangular Old Forge style red tray.', 850, 4),
    (v_p5, v_rest, v_org, v_cat_pizza, 'The Meat Tray', 'Red tray loaded with pepperoni, sausage, bacon, and ham.', 2450, 5),
    (v_w1, v_rest, v_org, v_cat_wings, 'Jumbo Wings (10 Count)', 'Fresh, never frozen. Crisp fried and tossed in your custom signature house flavor.', 1495, 1),
    (v_w2, v_rest, v_org, v_cat_wings, 'Jumbo Wings (20 Count)', 'Perfect for sharing. Choose up to two custom signature wing sauces.', 2850, 2),
    (v_w3, v_rest, v_org, v_cat_wings, 'Boneless Wing Platter', 'All-white meat breast chunks breaded, fried golden, and tossed in your favorite sauce.', 1250, 3),
    (v_s1, v_rest, v_org, v_cat_subs, 'Famous Italian Porketta Sub', 'Slow-roasted seasoned pork, shredded and topped with melted provolone on a toasted roll.', 1200, 1),
    (v_s2, v_rest, v_org, v_cat_subs, 'Classic Italian Hoagie', 'Ham, capicola, salami, provolone, lettuce, tomato, onion, and house vinaigrette.', 1150, 2),
    (v_s3, v_rest, v_org, v_cat_subs, 'Meatball Parm Sub', 'House-made Italian meatballs smothered in marinara and melted mozzarella.', 1200, 3),
    (v_s4, v_rest, v_org, v_cat_subs, 'Chicken Cheesesteak', 'Finely chopped chicken breast with melted American cheese, onions, and sauce.', 1250, 4),
    (v_a1, v_rest, v_org, v_cat_apps, 'Jigsy Fries', 'Crispy golden fries tossed in our custom house seasoning blend.', 650, 1),
    (v_a2, v_rest, v_org, v_cat_apps, 'Mozzarella Sticks (6 Count)', 'Battered mozzarella sticks fried crisp, served with a side of warm marinara.', 800, 2),
    (v_a3, v_rest, v_org, v_cat_apps, 'Onion Rings', 'Thick-cut, beer-battered onion rings served with Texas petal dipping sauce.', 750, 3),
    (v_a4, v_rest, v_org, v_cat_apps, 'Pierogies (4 Count)', 'Classic PA coal-country style pierogies sautéed with butter and sweet onions.', 700, 4),
    (v_b1, v_rest, v_org, v_cat_brews, 'Big J Double IPA (4-Pack To-Go)', '8.2% ABV. Heavy citrus and pine hop profile with a smooth, malty backbone.', 1600, 1),
    (v_b2, v_rest, v_org, v_cat_brews, 'Citra Wheat Ale (4-Pack To-Go)', '5.4% ABV. Crisp, refreshing American wheat beer bursting with bright tropical notes.', 1400, 2),
    (v_b3, v_rest, v_org, v_cat_brews, 'Enola Amber Lager (4-Pack To-Go)', '5.0% ABV. Smooth, toasted malt character with a clean, classic finish.', 1400, 3)
  on conflict (id) do nothing;

  -- Crust group per pizza (required, pick 1). Default = Traditional Old Forge Thick-Crust.
  foreach v_item in array array[v_p1, v_p2, v_p3, v_p4, v_p5]
  loop
    v_grp := md5(v_item::text || '-crust')::uuid;
    insert into modifier_groups (id, menu_item_id, organization_id, name, required, min_select, max_select)
    values (v_grp, v_item, v_org, 'Crust', true, 1, 1)
    on conflict (id) do nothing;

    insert into menu_item_modifier_groups (id, menu_item_id, modifier_group_id, organization_id, required, min_select, max_select)
    values (md5(v_item::text || '-crust-j')::uuid, v_item, v_grp, v_org, true, 1, 1)
    on conflict (menu_item_id, modifier_group_id) do nothing;

    i := 0;
    foreach opt in array v_crust
    loop
      i := i + 1;
      insert into modifier_options (id, modifier_group_id, organization_id, name, price_delta_cents)
      values (md5(v_grp::text || opt)::uuid, v_grp, v_org, opt, 0)
      on conflict (id) do nothing;
    end loop;
  end loop;

  -- Sauce group per wing item.
  foreach v_item in array array[v_w1, v_w2, v_w3]
  loop
    v_grp := md5(v_item::text || '-sauce')::uuid;
    insert into modifier_groups (id, menu_item_id, organization_id, name, required, min_select, max_select)
    values (v_grp, v_item, v_org, 'Sauce', true, 1, 1)
    on conflict (id) do nothing;

    insert into menu_item_modifier_groups (id, menu_item_id, modifier_group_id, organization_id, required, min_select, max_select)
    values (md5(v_item::text || '-sauce-j')::uuid, v_item, v_grp, v_org, true, 1, 1)
    on conflict (menu_item_id, modifier_group_id) do nothing;

    foreach opt in array v_sauce
    loop
      insert into modifier_options (id, modifier_group_id, organization_id, name, price_delta_cents)
      values (md5(v_grp::text || opt)::uuid, v_grp, v_org, opt, 0)
      on conflict (id) do nothing;
    end loop;
  end loop;
end $$;
