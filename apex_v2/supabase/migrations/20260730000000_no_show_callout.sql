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
