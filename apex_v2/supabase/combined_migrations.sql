-- ============================================================
-- Apex v2 — Combined Migration Script
-- Paste this entire script into the Supabase SQL Editor and run.
-- All migrations are idempotent — safe to re-run if some already applied.
-- Target database: pqkremkwfkudrhtxasdj (Apex Supabase)
-- ============================================================


-- ======================================================================
-- 20260727000000_apex_v2_foundation.sql
-- ======================================================================

-- Apex v2 — Restaurant OS foundation
--
-- Runs against the EXISTING Apex Supabase database (the plan is one backend for
-- every restaurant feature, org-scoped from day one), so every statement here is
-- idempotent and non-destructive. Safe to re-run.
--
-- Covers three things:
--   1. The tables the shipped v2 screens already query but that do not exist yet
--      (shift_notes, tip_pools, tip_allocations, messages) — without these the
--      log book and tip management cannot run at all.
--   2. Columns v2 expects on existing tables (shifts.start_time/end_time/role,
--      time_entries.organization_id).
--   3. Tier + module entitlements, so an owner can buy the whole OS or plug in
--      only the pieces they want.
--
-- MEMBERSHIP MODEL — deliberate deviation from the build plan.
-- The plan's RLS helpers query `organization_members`, but that table is never
-- defined anywhere in the docs, does not exist in Apex v1, and all three shipped
-- v2 screens read role from `profiles`. Inventing a second membership table
-- would mean rewriting verified code and migrating live data for no gain today.
-- So membership stays on `profiles` (organization_id + role), and the helpers
-- below are written against it. If a user ever needs to belong to several orgs
-- (multi-location, Tier 4), introduce `organization_members` then and repoint
-- these two functions — nothing else has to change.

-- ─── Enums / reference ──────────────────────────────────────────────────────

-- Role hierarchy from the build plan: owner > manager > server / kitchen > readonly.
-- Kept as TEXT (not an enum) to match v1's existing profiles.role values.

-- ─── Entitlements: tier + per-org module overrides ──────────────────────────

alter table organizations
  add column if not exists tier text not null default 'free';

-- Modules explicitly switched on beyond what the tier grants. This is the
-- "plug in only the pieces they want" lever: a free-tier venue can still be
-- given, say, the log book without being upsold the whole OS.
alter table organizations
  add column if not exists enabled_modules text[] not null default '{}';

-- Modules explicitly switched off despite the tier granting them (trial
-- clawback, a venue that does not want ordering, etc.).
alter table organizations
  add column if not exists disabled_modules text[] not null default '{}';

comment on column organizations.tier is
  'free | pro | os | multi — see lib/core/entitlements.dart for the module each grants';

-- ─── Columns v2 expects on existing tables ──────────────────────────────────

-- v1 stored shift hours as a formatted string in `notes` ("Shift: 9:00 AM - 5:00 PM").
-- v2 reads real start/end columns. Added nullable so existing rows stay valid;
-- backfill separately if v1 data needs to render in v2.
alter table shifts
  add column if not exists start_time text,
  add column if not exists end_time text,
  add column if not exists role text;

-- v2 scopes time entries by org directly rather than joining through shifts.
alter table time_entries
  add column if not exists organization_id uuid references organizations(id);

update time_entries te
  set organization_id = p.organization_id
  from profiles p
  where te.organization_id is null
    and te.user_id = p.id;

-- ─── Manager log book ───────────────────────────────────────────────────────

create table if not exists shift_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  author_id uuid not null references profiles(id),
  shift_date date not null,
  note text not null,
  photo_url text,
  created_at timestamptz not null default now()
);

create index if not exists shift_notes_org_date_idx
  on shift_notes (organization_id, shift_date desc, created_at desc);

-- ─── Tip management ─────────────────────────────────────────────────────────

create table if not exists tip_pools (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  shift_date date not null,
  total_cents int not null check (total_cents >= 0),
  split_method text not null default 'hours',
  created_at timestamptz not null default now()
);

-- One pool per venue per day. The tip screen checks for an existing pool before
-- allowing a new one; this makes that guarantee real even if two managers hit
-- save at the same moment, which would otherwise pay the night out twice.
create unique index if not exists tip_pools_org_date_key
  on tip_pools (organization_id, shift_date);

create table if not exists tip_allocations (
  id uuid primary key default gen_random_uuid(),
  tip_pool_id uuid not null references tip_pools(id) on delete cascade,
  user_id uuid not null references profiles(id),
  hours_worked real not null check (hours_worked >= 0),
  amount_cents int not null check (amount_cents >= 0)
);

-- The app deletes allocations before the pool; ON DELETE CASCADE above means a
-- pool removed any other way cannot strand orphaned payouts.
create index if not exists tip_allocations_pool_idx on tip_allocations (tip_pool_id);
create index if not exists tip_allocations_user_idx on tip_allocations (user_id);

-- ─── Team chat ──────────────────────────────────────────────────────────────

create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  user_id uuid references profiles(id),
  shift_id uuid references shifts(id) on delete set null,
  text text not null,
  photo_url text,
  pinned boolean not null default false,
  system_generated boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists messages_org_created_idx
  on messages (organization_id, created_at desc);

-- ─── RLS helpers ────────────────────────────────────────────────────────────

-- SECURITY DEFINER so the policy can read profiles without the caller needing
-- their own select policy on it (which would recurse).
create or replace function is_member(org_uuid uuid)
returns boolean as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and organization_id = org_uuid
  );
$$ language sql security definer stable;

-- Role hierarchy: manager and owner satisfy any lower requirement.
create or replace function has_role(org_uuid uuid, required_role text)
returns boolean as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and organization_id = org_uuid
      and lower(role) in (lower(required_role), 'manager', 'owner')
  );
$$ language sql security definer stable;

revoke all on function is_member(uuid) from public;
revoke all on function has_role(uuid, text) from public;
grant execute on function is_member(uuid) to authenticated;
grant execute on function has_role(uuid, text) to authenticated;

-- ─── RLS policies ───────────────────────────────────────────────────────────

alter table shift_notes enable row level security;
alter table tip_pools enable row level security;
alter table tip_allocations enable row level security;
alter table messages enable row level security;

-- Log book: any member reads; per the role table, servers may write notes too.
-- Authors may remove their own note (the screen offers exactly that); managers
-- and owners may remove any.
drop policy if exists shift_notes_select on shift_notes;
create policy shift_notes_select on shift_notes
  for select using (is_member(organization_id));

drop policy if exists shift_notes_insert on shift_notes;
create policy shift_notes_insert on shift_notes
  for insert with check (
    is_member(organization_id) and author_id = auth.uid()
  );

drop policy if exists shift_notes_delete on shift_notes;
create policy shift_notes_delete on shift_notes
  for delete using (
    author_id = auth.uid() or has_role(organization_id, 'manager')
  );

-- Tips: everyone sees the pool for their venue; only managers/owners create or
-- remove one. Money is written by management, read by staff.
drop policy if exists tip_pools_select on tip_pools;
create policy tip_pools_select on tip_pools
  for select using (is_member(organization_id));

drop policy if exists tip_pools_write on tip_pools;
create policy tip_pools_write on tip_pools
  for all using (has_role(organization_id, 'manager'))
  with check (has_role(organization_id, 'manager'));

-- Allocations carry no organization_id of their own, so they are scoped through
-- their parent pool. A staff member sees only their own line; management sees
-- the whole split.
drop policy if exists tip_allocations_select on tip_allocations;
create policy tip_allocations_select on tip_allocations
  for select using (
    exists (
      select 1 from tip_pools p
      where p.id = tip_allocations.tip_pool_id
        and is_member(p.organization_id)
        and (tip_allocations.user_id = auth.uid() or has_role(p.organization_id, 'manager'))
    )
  );

drop policy if exists tip_allocations_write on tip_allocations;
create policy tip_allocations_write on tip_allocations
  for all using (
    exists (
      select 1 from tip_pools p
      where p.id = tip_allocations.tip_pool_id
        and has_role(p.organization_id, 'manager')
    )
  )
  with check (
    exists (
      select 1 from tip_pools p
      where p.id = tip_allocations.tip_pool_id
        and has_role(p.organization_id, 'manager')
    )
  );

-- Chat: members read and post; authors edit or delete their own, managers any.
drop policy if exists messages_select on messages;
create policy messages_select on messages
  for select using (is_member(organization_id));

drop policy if exists messages_insert on messages;
create policy messages_insert on messages
  for insert with check (
    is_member(organization_id) and (user_id = auth.uid() or system_generated)
  );

drop policy if exists messages_update on messages;
create policy messages_update on messages
  for update using (
    user_id = auth.uid() or has_role(organization_id, 'manager')
  );

drop policy if exists messages_delete on messages;
create policy messages_delete on messages
  for delete using (
    user_id = auth.uid() or has_role(organization_id, 'manager')
  );

-- ─── Realtime ───────────────────────────────────────────────────────────────

-- The v2 screens subscribe to these; without publication membership the streams
-- connect but never fire.
do $$
begin
  begin
    alter publication supabase_realtime add table shift_notes;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table tip_pools;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table messages;
  exception when duplicate_object then null;
  end;
end $$;


-- ======================================================================
-- 20260728000000_notification_routing.sql
-- ======================================================================

-- Smart notification routing (plan #6)
-- Prefs + delivery log. Push uses existing send-push-notification; SMS via
-- route-notification edge function when Twilio secrets are configured.

alter table profiles
  add column if not exists phone text;

create table if not exists notification_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  organization_id uuid not null references organizations (id) on delete cascade,
  my_shifts boolean not null default true,
  shift_changes boolean not null default true,
  swap_opportunities boolean not null default true,
  team_messages boolean not null default false,
  schedule_published boolean not null default true,
  push_enabled boolean not null default true,
  sms_fallback boolean not null default true,
  quiet_start time not null default '23:00',
  quiet_end time not null default '07:00',
  critical_bypass_quiet boolean not null default true,
  updated_at timestamptz not null default now()
);

create index if not exists notification_preferences_org_idx
  on notification_preferences (organization_id);

alter table notification_preferences enable row level security;

drop policy if exists notification_preferences_select on notification_preferences;
create policy notification_preferences_select on notification_preferences
  for select using (
    user_id = auth.uid()
    or has_role(organization_id, 'manager')
  );

drop policy if exists notification_preferences_upsert on notification_preferences;
create policy notification_preferences_upsert on notification_preferences
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Delivery attempts for push → SMS routing visibility.
create table if not exists notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid references notifications (id) on delete set null,
  user_id uuid not null references auth.users (id) on delete cascade,
  organization_id uuid not null references organizations (id) on delete cascade,
  channel text not null, -- push | sms | in_app
  status text not null,  -- sent | failed | skipped | queued
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists notification_deliveries_user_idx
  on notification_deliveries (user_id, created_at desc);

alter table notification_deliveries enable row level security;

drop policy if exists notification_deliveries_select on notification_deliveries;
create policy notification_deliveries_select on notification_deliveries
  for select using (
    user_id = auth.uid()
    or has_role(organization_id, 'manager')
  );

-- Service role / edge function writes deliveries; no insert policy for clients.


-- ======================================================================
-- 20260728010000_labor_guardrails_dob.sql
-- ======================================================================

-- Labor guardrails: optional DOB for minor-hour checks (plan #9).
alter table profiles
  add column if not exists date_of_birth date;

comment on column profiles.date_of_birth is
  'Optional. Used only for minor labor-hour warnings; never shown to other staff.';


-- ======================================================================
-- 20260729000000_ordering_platform.sql
-- ======================================================================

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


-- ======================================================================
-- 20260730000000_no_show_callout.sql
-- ======================================================================

-- Apex v2 — No-show call-out engine
--
-- When someone cannot work a shift, eligible coworkers are notified and the
-- first in-app claim fills it. SMS via route-callout is best-effort: the open
-- call-out still works if Twilio is not configured.

create table if not exists call_outs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  shift_id uuid references shifts(id) on delete set null,
  shift_date date not null,
  start_time text,
  end_time text,
  staff_name text not null,
  staff_user_id uuid references profiles(id) on delete set null,
  staff_role text,
  reason text,
  status text not null default 'open'
    check (status in ('open', 'filled', 'expired', 'cancelled')),
  filled_by text,
  filled_by_user_id uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  filled_at timestamptz,
  -- Auto-expire at shift start so stale opens do not linger after the meal.
  expires_at timestamptz
);

create index if not exists call_outs_org_status_idx
  on call_outs (organization_id, status, created_at desc);

-- One open call-out per shift — two "can't make it" taps must not fan-out twice.
create unique index if not exists call_outs_one_open_per_shift
  on call_outs (shift_id)
  where status = 'open' and shift_id is not null;

create table if not exists call_out_notifications (
  id uuid primary key default gen_random_uuid(),
  call_out_id uuid not null references call_outs(id) on delete cascade,
  organization_id uuid not null references organizations(id),
  user_id uuid not null references profiles(id) on delete cascade,
  staff_name text not null,
  phone text,
  notified_at timestamptz not null default now(),
  responded_at timestamptz,
  response text
    check (response is null or response in ('accepted', 'declined'))
);

create index if not exists call_out_notifications_call_out_idx
  on call_out_notifications (call_out_id);

create index if not exists call_out_notifications_org_idx
  on call_out_notifications (organization_id, user_id);

alter table call_outs enable row level security;
alter table call_out_notifications enable row level security;

drop policy if exists call_outs_select on call_outs;
create policy call_outs_select on call_outs
  for select using (is_member(organization_id));

drop policy if exists call_outs_insert on call_outs;
create policy call_outs_insert on call_outs
  for insert with check (
    is_member(organization_id)
    and (staff_user_id = auth.uid() or has_role(organization_id, 'manager'))
  );

drop policy if exists call_outs_update on call_outs;
create policy call_outs_update on call_outs
  for update using (is_member(organization_id))
  with check (is_member(organization_id));

drop policy if exists call_out_notifications_select on call_out_notifications;
create policy call_out_notifications_select on call_out_notifications
  for select using (is_member(organization_id));

-- Edge function (service role) inserts these; members may mark their response.
drop policy if exists call_out_notifications_insert on call_out_notifications;
create policy call_out_notifications_insert on call_out_notifications
  for insert with check (
    has_role(organization_id, 'manager') or is_member(organization_id)
  );

drop policy if exists call_out_notifications_update on call_out_notifications;
create policy call_out_notifications_update on call_out_notifications
  for update using (
    user_id = auth.uid() or has_role(organization_id, 'manager')
  )
  with check (
    user_id = auth.uid() or has_role(organization_id, 'manager')
  );

do $$
begin
  begin
    alter publication supabase_realtime add table call_outs;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table call_out_notifications;
  exception when duplicate_object then null;
  end;
end $$;


-- ======================================================================
-- 20260731000000_smart_capacity.sql
-- ======================================================================

-- Apex v2 — Smart ordering capacity
--
-- When the kitchen is understaffed, ordering auto-pauses or warns customers
-- about longer wait times. When staff clock in, capacity recalculates.
--
-- Adds capacity columns to restaurant_settings and a log table for audit.

alter table restaurant_settings
  add column if not exists max_orders_per_hour int not null default 15
    check (max_orders_per_hour > 0),
  add column if not exists auto_pause_enabled boolean not null default true,
  add column if not exists auto_pause_threshold int not null default 1
    check (auto_pause_threshold >= 0);
-- auto_pause_threshold = min staff on shift to keep ordering open. 0 = never auto-pause.

comment on column restaurant_settings.max_orders_per_hour is
  'Max orders per cook on shift per hour. Total capacity = cooks × this value.';
comment on column restaurant_settings.auto_pause_enabled is
  'When true, ordering auto-pauses if staff on shift drops below auto_pause_threshold.';
comment on column restaurant_settings.auto_pause_threshold is
  'Minimum staff clocked in to keep ordering open. 0 disables auto-pause.';

-- Audit log for capacity events (auto-pause, auto-resume, manual override).
create table if not exists capacity_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  restaurant_id uuid not null references restaurants(id) on delete cascade,
  event text not null check (event in ('auto_pause', 'auto_resume', 'manual_pause', 'manual_resume', 'capacity_warning')),
  staff_on_shift int not null default 0,
  orders_last_hour int not null default 0,
  max_capacity int not null default 0,
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists capacity_events_org_idx
  on capacity_events (organization_id, created_at desc);
create index if not exists capacity_events_rest_idx
  on capacity_events (restaurant_id, created_at desc);

alter table capacity_events enable row level security;

drop policy if exists capacity_events_member on capacity_events;
create policy capacity_events_member on capacity_events
  for all to authenticated
  using (is_member(organization_id))
  with check (is_member(organization_id));

drop policy if exists capacity_events_insert_service on capacity_events;
create policy capacity_events_insert_service on capacity_events
  for insert to authenticated
  with check (is_member(organization_id));

-- ======================================================================
-- 20260801000000_place_order_rpc.sql
-- ======================================================================

-- Apex v2 — place_order RPC
--
-- WHY: Anon customers can INSERT online_orders but not order_items — the
-- order_items policy does EXISTS(online_orders...) and Postgres re-applies
-- online_orders RLS inside that subquery; anon has no SELECT, so EXISTS is
-- always false and checkout dies after the parent row. Also, client-sent
-- totals were trusted (a tampered client could pay $0.01 for a $24 tray).
--
-- SECURITY DEFINER inserts the order graph atomically and recomputes money
-- from menu_items / modifier_options / restaurant_settings. Callers may only
-- send ids + quantities — never prices.

create or replace function place_order(
  p_restaurant_id uuid,
  p_public_token text,
  p_customer_name text,
  p_customer_phone text,
  p_notes text,
  p_pickup_minutes int,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_rest_token text;
  v_paused boolean;
  v_fee int;
  v_tax_rate real;
  v_payment_mode text;
  v_prep int;
  v_waiting int;
  v_order_id uuid;
  v_token text;
  v_subtotal int := 0;
  v_tax int;
  v_total int;
  v_item jsonb;
  v_mod jsonb;
  v_menu_id uuid;
  v_qty int;
  v_item_name text;
  v_item_price int;
  v_item_available boolean;
  v_line_price int;
  v_line_id uuid;
  v_opt_id uuid;
  v_opt_name text;
  v_opt_delta int;
  v_opt_group uuid;
  v_attempts int := 0;
begin
  if p_customer_name is null or length(trim(p_customer_name)) = 0 then
    raise exception 'customer_name_required';
  end if;
  if p_customer_phone is null or length(trim(p_customer_phone)) = 0 then
    raise exception 'customer_phone_required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items_required';
  end if;

  select r.organization_id, r.public_token, s.paused, s.fee_cents, s.tax_rate,
         s.payment_mode, s.prep_minutes
    into v_org, v_rest_token, v_paused, v_fee, v_tax_rate, v_payment_mode, v_prep
  from restaurants r
  join restaurant_settings s on s.restaurant_id = r.id
  where r.id = p_restaurant_id;

  if v_org is null then
    raise exception 'restaurant_not_found';
  end if;
  if v_rest_token is distinct from p_public_token then
    raise exception 'invalid_public_token';
  end if;
  if v_paused then
    raise exception 'ordering_paused';
  end if;

  select count(*)::int into v_waiting
  from online_orders
  where restaurant_id = p_restaurant_id
    and status = 'waiting';
  if v_waiting >= 50 then
    raise exception 'too_many_open_orders';
  end if;

  -- Pre-validate lines + accumulate subtotal from server prices only.
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := coalesce((v_item->>'quantity')::int, 0);
    if v_menu_id is null or v_qty <= 0 then
      raise exception 'invalid_item';
    end if;

    select name, price_cents, available
      into v_item_name, v_item_price, v_item_available
    from menu_items
    where id = v_menu_id
      and restaurant_id = p_restaurant_id
      and organization_id = v_org;

    if v_item_name is null then
      raise exception 'unknown_menu_item';
    end if;
    if not v_item_available then
      raise exception 'item_unavailable';
    end if;

    v_line_price := v_item_price;

    if v_item ? 'modifiers' and jsonb_typeof(v_item->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_item->'modifiers')
      loop
        v_opt_id := (v_mod->>'option_id')::uuid;
        if v_opt_id is null then
          raise exception 'invalid_modifier';
        end if;

        select o.name, o.price_delta_cents, o.modifier_group_id
          into v_opt_name, v_opt_delta, v_opt_group
        from modifier_options o
        where o.id = v_opt_id
          and o.organization_id = v_org;

        if v_opt_name is null then
          raise exception 'unknown_modifier';
        end if;

        -- Option must belong to a group attached to this menu item.
        if not exists (
          select 1
          from modifier_groups g
          where g.id = v_opt_group
            and (
              g.menu_item_id = v_menu_id
              or exists (
                select 1 from menu_item_modifier_groups j
                where j.modifier_group_id = g.id
                  and j.menu_item_id = v_menu_id
              )
            )
        ) then
          raise exception 'modifier_not_for_item';
        end if;

        v_line_price := v_line_price + coalesce(v_opt_delta, 0);
      end loop;
    end if;

    v_subtotal := v_subtotal + (v_line_price * v_qty);
  end loop;

  v_fee := coalesce(v_fee, 0);
  v_tax := round(v_subtotal * coalesce(v_tax_rate, 0))::int;
  v_total := v_subtotal + v_fee + v_tax;

  -- Short readable pickup code; retry on the rare unique collision.
  loop
    v_attempts := v_attempts + 1;
    v_token := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (
      select 1 from online_orders where public_token = v_token
    );
    if v_attempts > 8 then
      raise exception 'token_generation_failed';
    end if;
  end loop;

  v_order_id := gen_random_uuid();

  insert into online_orders (
    id, restaurant_id, organization_id, public_token, status,
    pickup_minutes, customer_json, notes,
    subtotal_cents, fee_cents, tax_cents, total_cents,
    payment_mode, payment_status
  ) values (
    v_order_id, p_restaurant_id, v_org, v_token, 'waiting',
    coalesce(nullif(p_pickup_minutes, 0), v_prep, 30),
    jsonb_build_object(
      'name', trim(p_customer_name),
      'phone', trim(p_customer_phone)
    ),
    coalesce(p_notes, ''),
    v_subtotal, v_fee, v_tax, v_total,
    coalesce(v_payment_mode, 'manual'), 'pending'
  );

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := (v_item->>'quantity')::int;

    select name, price_cents
      into v_item_name, v_item_price
    from menu_items
    where id = v_menu_id;

    v_line_price := v_item_price;
    if v_item ? 'modifiers' and jsonb_typeof(v_item->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_item->'modifiers')
      loop
        select o.price_delta_cents into v_opt_delta
        from modifier_options o
        where o.id = (v_mod->>'option_id')::uuid;
        v_line_price := v_line_price + coalesce(v_opt_delta, 0);
      end loop;
    end if;

    v_line_id := gen_random_uuid();
    insert into order_items (
      id, order_id, organization_id, menu_item_id, name, price_cents, quantity, notes
    ) values (
      v_line_id, v_order_id, v_org, v_menu_id, v_item_name, v_line_price, v_qty,
      (
        select string_agg(x.name, '; ')
        from (
          select o.name
          from jsonb_array_elements(coalesce(v_item->'modifiers', '[]'::jsonb)) m
          join modifier_options o on o.id = (m->>'option_id')::uuid
        ) x
      )
    );

    if v_item ? 'modifiers' and jsonb_typeof(v_item->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_item->'modifiers')
      loop
        v_opt_id := (v_mod->>'option_id')::uuid;
        select o.name, o.price_delta_cents
          into v_opt_name, v_opt_delta
        from modifier_options o
        where o.id = v_opt_id;

        insert into order_item_modifiers (
          order_item_id, organization_id, modifier_option_id, name, price_delta_cents
        ) values (
          v_line_id, v_org, v_opt_id, v_opt_name, coalesce(v_opt_delta, 0)
        );
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'id', v_order_id,
    'public_token', v_token,
    'total_cents', v_total,
    'status', 'waiting'
  );
end;
$$;

revoke all on function place_order(uuid, text, text, text, text, int, jsonb) from public;
grant execute on function place_order(uuid, text, text, text, text, int, jsonb) to anon, authenticated;

comment on function place_order(uuid, text, text, text, text, int, jsonb) is
  'Atomic guest checkout. Recomputes prices server-side; bypasses broken anon order_items RLS.';

-- WHY: CapacityEngine.check() reads time_entries + online_orders which anon
-- customers cannot SELECT. Guest menu still needs kitchen load for wait banners.
create or replace function capacity_snapshot(p_restaurant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_paused boolean;
  v_auto boolean;
  v_threshold int;
  v_max_per_hour int;
  v_staff int;
  v_orders int;
  v_max_cap int;
  v_uses_kitchen boolean;
  v_state text;
begin
  select r.organization_id, s.paused, s.auto_pause_enabled, s.auto_pause_threshold,
         s.max_orders_per_hour
    into v_org, v_paused, v_auto, v_threshold, v_max_per_hour
  from restaurants r
  join restaurant_settings s on s.restaurant_id = r.id
  where r.id = p_restaurant_id;

  if v_org is null then
    return jsonb_build_object(
      'staff_on_shift', 0,
      'orders_last_hour', 0,
      'max_capacity', 0,
      'state', 'unknown'
    );
  end if;

  -- capacity = kitchen staff × max_orders_per_hour. Servers don't cook.
  select exists (
    select 1 from profiles p
    where p.organization_id = v_org
      and (
        lower(coalesce(p.role, '')) in ('kitchen', 'cook', 'chef', 'line cook', 'line_cook')
        or lower(coalesce(p.role, '')) like '%cook%'
        or lower(coalesce(p.role, '')) like '%kitchen%'
        or lower(coalesce(p.role, '')) like '%chef%'
      )
  ) into v_uses_kitchen;

  if v_uses_kitchen then
    select count(*)::int into v_staff
    from time_entries t
    join profiles p on p.id = t.user_id
    where t.organization_id = v_org
      and t.clock_out is null
      and (
        lower(coalesce(p.role, '')) in ('kitchen', 'cook', 'chef', 'line cook', 'line_cook')
        or lower(coalesce(p.role, '')) like '%cook%'
        or lower(coalesce(p.role, '')) like '%kitchen%'
        or lower(coalesce(p.role, '')) like '%chef%'
      );
  else
    select count(*)::int into v_staff
    from time_entries t
    where t.organization_id = v_org
      and t.clock_out is null;
  end if;

  select count(*)::int into v_orders
  from online_orders o
  where o.organization_id = v_org
    and o.restaurant_id = p_restaurant_id
    and o.status = 'waiting'
    and o.submitted_at >= now() - interval '1 hour';

  v_max_cap := v_staff * coalesce(v_max_per_hour, 15);

  if coalesce(v_auto, true) and v_staff < coalesce(v_threshold, 1) then
    v_state := 'autoPaused';
  elsif v_paused then
    v_state := 'manuallyPaused';
  elsif v_max_cap > 0 and v_orders >= v_max_cap then
    v_state := 'atCapacity';
  elsif v_max_cap > 0 and v_orders >= round(v_max_cap * 0.8) then
    v_state := 'nearCapacity';
  else
    v_state := 'open';
  end if;

  return jsonb_build_object(
    'staff_on_shift', v_staff,
    'orders_last_hour', v_orders,
    'max_capacity', v_max_cap,
    'state', v_state
  );
end;
$$;

revoke all on function capacity_snapshot(uuid) from public;
grant execute on function capacity_snapshot(uuid) to anon, authenticated;


-- ======================================================================
-- 20260801010000_daily_revenue.sql
-- ======================================================================

-- Apex v2 — Manual daily revenue (POS / cash / estimated sales)
--
-- WHY: Labor % against online_orders alone is misleading when most sales are
-- walk-in / POS. Owners need a daily total so labor vs revenue is real.

create table if not exists daily_revenue (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  restaurant_id uuid references restaurants(id) on delete set null,
  revenue_date date not null,
  total_cents int not null check (total_cents >= 0),
  source text not null default 'manual',
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (organization_id, revenue_date)
);

create index if not exists daily_revenue_org_date_idx
  on daily_revenue (organization_id, revenue_date);

alter table daily_revenue enable row level security;

drop policy if exists daily_revenue_select on daily_revenue;
create policy daily_revenue_select on daily_revenue
  for select using (is_member(organization_id));

drop policy if exists daily_revenue_insert on daily_revenue;
create policy daily_revenue_insert on daily_revenue
  for insert with check (
    is_member(organization_id)
    and created_by = auth.uid()
  );

-- Upsert path used by "Enter today's sales" (unique on org + date).
drop policy if exists daily_revenue_update on daily_revenue;
create policy daily_revenue_update on daily_revenue
  for update using (has_role(organization_id, 'manager'))
  with check (has_role(organization_id, 'manager'));

drop policy if exists daily_revenue_delete on daily_revenue;
create policy daily_revenue_delete on daily_revenue
  for delete using (has_role(organization_id, 'manager'));

do $$
begin
  begin
    alter publication supabase_realtime add table daily_revenue;
  exception when duplicate_object then null;
  end;
end $$;


-- ======================================================================
-- 20260801020000_check_capacity_cron.sql
-- ======================================================================

-- Apex v2 — check-capacity cron documentation
--
-- The edge function `check-capacity` is the server-side counterpart of
-- CapacityEngine.autoAdjust(). It must run on a schedule — client screens only
-- call CapacityEngine.check() for display, never autoAdjust().
--
-- Setup (Dashboard → Edge Functions → Schedules, or SQL with pg_cron + pg_net):
--
--   Every 2 minutes, POST to:
--     ${SUPABASE_URL}/functions/v1/check-capacity
--   Headers:
--     Authorization: Bearer ${SERVICE_ROLE_KEY}
--     Content-Type: application/json
--   Body: {}
--
-- Example pg_cron (requires extensions pg_cron + pg_net):
--
--   select cron.schedule(
--     'apex-check-capacity',
--     '*/2 * * * *',
--     $$
--     select net.http_post(
--       url := current_setting('app.settings.supabase_url') || '/functions/v1/check-capacity',
--       headers := jsonb_build_object(
--         'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
--         'Content-Type', 'application/json'
--       ),
--       body := '{}'::jsonb
--     );
--     $$
--   );
--
-- Verify: select * from cron.job where jobname = 'apex-check-capacity';
--
-- No schema changes here — capacity_events + restaurant_settings columns already
-- exist from 20260731000000_smart_capacity.sql.

select 1;

