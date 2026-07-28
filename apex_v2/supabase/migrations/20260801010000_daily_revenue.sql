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
