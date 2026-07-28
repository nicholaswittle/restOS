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