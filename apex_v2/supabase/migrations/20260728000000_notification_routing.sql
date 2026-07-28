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
