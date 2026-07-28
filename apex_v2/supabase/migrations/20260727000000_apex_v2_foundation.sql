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
