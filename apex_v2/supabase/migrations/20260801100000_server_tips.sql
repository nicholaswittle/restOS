-- Apex v2 — Server-declared tips (self-reported daily tip log)
--
-- Servers enter what they actually made each shift. Owners compare
-- declared tips vs the tip-pool split to catch discrepancies.

create table if not exists server_tips (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  user_id uuid not null references auth.users(id) on delete cascade,
  staff_name text not null,
  shift_date date not null,
  cash_tips_cents int not null default 0 check (cash_tips_cents >= 0),
  card_tips_cents int not null default 0 check (card_tips_cents >= 0),
  total_cents int generated always as (cash_tips_cents + card_tips_cents) stored,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id, shift_date)
);

create index if not exists server_tips_org_date_idx
  on server_tips (organization_id, shift_date desc);
create index if not exists server_tips_user_idx
  on server_tips (user_id, shift_date desc);

alter table server_tips enable row level security;

drop policy if exists server_tips_select on server_tips;
create policy server_tips_select on server_tips
  for select to authenticated
  using (is_member(organization_id));

drop policy if exists server_tips_insert on server_tips;
create policy server_tips_insert on server_tips
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists server_tips_update on server_tips;
create policy server_tips_update on server_tips
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists server_tips_delete on server_tips;
create policy server_tips_delete on server_tips
  for delete to authenticated
  using (user_id = auth.uid());

comment on table server_tips is
  'Self-reported daily tips entered by servers. Compared against tip_pool allocations for audit.';