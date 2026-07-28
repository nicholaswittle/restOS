-- Audit fix: tighten server_tips + daily_revenue insert policies.
-- WHY: prior policies allowed inserts without org membership / manager checks.

drop policy if exists server_tips_insert on server_tips;
create policy server_tips_insert on server_tips
  for insert to authenticated
  with check (user_id = auth.uid() and is_member(organization_id));

drop policy if exists daily_revenue_insert on daily_revenue;
create policy daily_revenue_insert on daily_revenue
  for insert to authenticated
  with check (has_role(organization_id, 'manager'));

comment on table server_tips is
  'Self-reported daily tips. Insert requires is_member + user_id match. Audit compare vs tip_pool allocations.';
