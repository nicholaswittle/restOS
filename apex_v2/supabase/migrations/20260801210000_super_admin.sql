-- Apex v2 — Super admin command console
--
-- WHY: Fleet operator needs cross-org visibility and tier/module control without
-- opening the Supabase dashboard. SECURITY DEFINER RPCs gate every mutation.

alter table profiles
  add column if not exists is_super_admin boolean not null default false;

create index if not exists profiles_is_super_admin_idx
  on profiles (is_super_admin)
  where is_super_admin;

create or replace function is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select p.is_super_admin from profiles p where p.id = auth.uid()),
    false
  );
$$;

revoke all on function is_super_admin() from public;
grant execute on function is_super_admin() to authenticated;

-- Cross-org read for the console.
drop policy if exists "orgs super admin read" on organizations;
create policy "orgs super admin read"
  on organizations for select
  using (is_super_admin());

drop policy if exists "orgs super admin update" on organizations;
create policy "orgs super admin update"
  on organizations for update
  using (is_super_admin())
  with check (is_super_admin());

drop policy if exists "profiles super admin read" on profiles;
create policy "profiles super admin read"
  on profiles for select
  using (is_super_admin());

-- Bootstrap: known operator + first-owner lockout prevention on signup.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_name text;
  v_invite text;
  v_name text;
  v_org uuid;
  v_role text := 'Owner';
  inv organization_invites%rowtype;
  v_found_invite boolean := false;
  v_super_count int;
  v_make_super boolean := false;
begin
  v_org_name := nullif(trim(coalesce(NEW.raw_user_meta_data->>'org_name', '')), '');
  v_invite := upper(nullif(trim(coalesce(NEW.raw_user_meta_data->>'invite_code', '')), ''));
  v_name := coalesce(
    nullif(trim(NEW.raw_user_meta_data->>'name'), ''),
    nullif(trim(NEW.raw_user_meta_data->>'full_name'), ''),
    split_part(coalesce(NEW.email, 'Owner'), '@', 1)
  );

  if v_invite is not null then
    select * into inv
    from organization_invites
    where code = v_invite
      and used_at is null
      and (expires_at is null or expires_at > now());
    if found then
      v_found_invite := true;
      v_org := inv.organization_id;
      v_role := coalesce(nullif(trim(inv.role), ''), 'Staff');
    end if;
  end if;

  if v_org is null and v_org_name is not null then
    insert into organizations (name, tier, enabled_modules, disabled_modules)
    values (v_org_name, 'free', '{}', '{}')
    returning id into v_org;
    v_role := 'Owner';
  end if;

  if v_org is null then
    insert into organizations (name, tier, enabled_modules, disabled_modules)
    values (
      split_part(coalesce(NEW.email, 'My Restaurant'), '@', 1) || '''s Restaurant',
      'free', '{}', '{}'
    )
    returning id into v_org;
    v_role := 'Owner';
  end if;

  if lower(coalesce(NEW.email, '')) in (
       'nicholaswittle@wisensellc.com',
       'nicholaswittle@gmail.com'
     ) then
    v_make_super := true;
  elsif lower(v_role) = 'owner' then
    select count(*)::int into v_super_count
    from profiles where is_super_admin;
    if v_super_count = 0 then
      v_make_super := true;
    end if;
  end if;

  insert into profiles (
    id, email, name, role, organization_id, first_time_login, is_super_admin
  ) values (
    NEW.id, NEW.email, v_name, v_role, v_org, true, v_make_super
  )
  on conflict (id) do update set
    email = excluded.email,
    name = coalesce(nullif(trim(profiles.name), ''), excluded.name),
    organization_id = coalesce(profiles.organization_id, excluded.organization_id),
    role = case
      when lower(coalesce(profiles.role, '')) = 'owner' then profiles.role
      else excluded.role
    end,
    is_super_admin = profiles.is_super_admin or excluded.is_super_admin;

  if v_found_invite then
    update organization_invites
    set used_at = now(), used_by = NEW.id
    where id = inv.id and used_at is null;
  end if;

  return NEW;
end;
$$;

create or replace function admin_list_orgs()
returns table (
  id uuid,
  name text,
  tier text,
  staff_count bigint,
  shift_count_week bigint,
  last_active timestamptz,
  enabled_modules text[],
  disabled_modules text[]
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_super_admin() then
    raise exception 'super_admin_required';
  end if;

  return query
  select
    o.id,
    o.name,
    coalesce(o.tier, 'free') as tier,
    (select count(*) from profiles p where p.organization_id = o.id) as staff_count,
    (select count(*) from shifts s
      where s.organization_id = o.id
        and s.shift_date >= (current_date - extract(dow from current_date)::int)
        and s.shift_date < (current_date - extract(dow from current_date)::int + 7)
    ) as shift_count_week,
    (
      select max(x.ts) from (
        select max(s2.created_at) as ts from shifts s2 where s2.organization_id = o.id
        union all
        select max(p2.created_at) from profiles p2 where p2.organization_id = o.id
        union all
        select o.created_at
      ) x
    ) as last_active,
    coalesce(o.enabled_modules, '{}') as enabled_modules,
    coalesce(o.disabled_modules, '{}') as disabled_modules
  from organizations o
  order by o.name;
end;
$$;

revoke all on function admin_list_orgs() from public;
grant execute on function admin_list_orgs() to authenticated;

create or replace function admin_set_tier(p_org_id uuid, new_tier text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tier text := lower(trim(new_tier));
begin
  if not is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  if v_tier not in ('free', 'pro', 'os', 'multi') then
    raise exception 'invalid_tier';
  end if;
  update organizations set tier = v_tier where id = p_org_id;
  if not found then
    raise exception 'org_not_found';
  end if;
end;
$$;

revoke all on function admin_set_tier(uuid, text) from public;
grant execute on function admin_set_tier(uuid, text) to authenticated;

create or replace function admin_toggle_module(
  p_org_id uuid,
  module_name text,
  enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mod text := trim(module_name);
  v_enabled text[];
  v_disabled text[];
begin
  if not is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  if v_mod is null or v_mod = '' then
    raise exception 'module_required';
  end if;

  select coalesce(enabled_modules, '{}'), coalesce(disabled_modules, '{}')
  into v_enabled, v_disabled
  from organizations where id = p_org_id;
  if not found then
    raise exception 'org_not_found';
  end if;

  if enabled then
    v_disabled := array_remove(v_disabled, v_mod);
    if not (v_mod = any (v_enabled)) then
      v_enabled := array_append(v_enabled, v_mod);
    end if;
  else
    v_enabled := array_remove(v_enabled, v_mod);
    if not (v_mod = any (v_disabled)) then
      v_disabled := array_append(v_disabled, v_mod);
    end if;
  end if;

  update organizations
  set enabled_modules = v_enabled,
      disabled_modules = v_disabled
  where id = p_org_id;
end;
$$;

revoke all on function admin_toggle_module(uuid, text, boolean) from public;
grant execute on function admin_toggle_module(uuid, text, boolean) to authenticated;

create or replace function admin_create_org(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := nullif(trim(p_name), '');
  v_id uuid;
begin
  if not is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  if v_name is null then
    raise exception 'name_required';
  end if;

  insert into organizations (name, tier, enabled_modules, disabled_modules)
  values (v_name, 'free', '{}', '{}')
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function admin_create_org(text) from public;
grant execute on function admin_create_org(text) to authenticated;

create or replace function admin_list_users(p_org_id uuid)
returns table (
  id uuid,
  name text,
  email text,
  role text,
  last_sign_in_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_super_admin() then
    raise exception 'super_admin_required';
  end if;

  return query
  select
    p.id,
    p.name,
    p.email,
    p.role,
    u.last_sign_in_at
  from profiles p
  left join auth.users u on u.id = p.id
  where p.organization_id = p_org_id
  order by p.name;
end;
$$;

revoke all on function admin_list_users(uuid) from public;
grant execute on function admin_list_users(uuid) to authenticated;

-- Allow super admin to mint invites for any org (console "Generate invite").
create or replace function admin_generate_invite(p_org_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_attempts int := 0;
begin
  if not is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  if p_org_id is null then
    raise exception 'org_required';
  end if;
  if not exists (select 1 from organizations where id = p_org_id) then
    raise exception 'org_not_found';
  end if;

  loop
    v_attempts := v_attempts + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (
      select 1 from organization_invites where code = v_code
    );
    if v_attempts > 12 then
      raise exception 'invite_code_generation_failed';
    end if;
  end loop;

  insert into organization_invites (
    organization_id, code, role, created_by, expires_at
  ) values (
    p_org_id, v_code, 'Owner', auth.uid(), now() + interval '7 days'
  );

  return v_code;
end;
$$;

revoke all on function admin_generate_invite(uuid) from public;
grant execute on function admin_generate_invite(uuid) to authenticated;

-- One-time: promote known operator if the account already exists.
update profiles
set is_super_admin = true
where lower(email) in (
  'nicholaswittle@wisensellc.com',
  'nicholaswittle@gmail.com'
);
