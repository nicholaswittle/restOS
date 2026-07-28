-- Apex v2 — Self-service auth (org creation + invites + role promotion)
--
-- WHY: Venues must onboard without opening the Supabase dashboard. Signup
-- metadata drives org creation or invite join; owners promote staff in-app.

-- Allow managers (not only owners) to mint invites; 6-char codes; 7-day TTL.
create or replace function apex_generate_invite(p_org_id uuid default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_code text;
  v_attempts int := 0;
begin
  v_org := coalesce(p_org_id, apex_current_org_id());
  if v_org is null then
    raise exception 'not_in_organization';
  end if;
  if not has_role(v_org, 'manager') then
    raise exception 'manager_required';
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
    v_org, v_code, 'Staff', auth.uid(), now() + interval '7 days'
  );

  return v_code;
end;
$$;

revoke all on function apex_generate_invite(uuid) from public;
grant execute on function apex_generate_invite(uuid) to authenticated;

-- Keep the v1 name working for existing Team screen calls.
create or replace function apex_create_invite(invite_role text default 'Staff')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := apex_current_org_id();
  v_code text;
  v_role text := coalesce(nullif(trim(invite_role), ''), 'Staff');
  v_attempts int := 0;
begin
  if v_org is null then
    raise exception 'not_in_organization';
  end if;
  if not has_role(v_org, 'manager') then
    raise exception 'manager_required';
  end if;
  if v_role not in ('Staff', 'Server', 'Kitchen', 'Manager', 'Owner') then
    raise exception 'invalid_invite_role';
  end if;
  -- Only owners may mint Owner invites (has_role('owner') also matches managers).
  if v_role = 'Owner' and lower(coalesce(apex_current_role(), '')) <> 'owner' then
    raise exception 'owner_required_for_owner_invite';
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
    v_org, v_code, v_role, auth.uid(), now() + interval '7 days'
  );

  return v_code;
end;
$$;

-- Owner promotes/demotes teammates inside the same org.
create or replace function apex_set_role(target_user_id uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_org uuid;
  v_caller_role text;
  v_target_org uuid;
  v_target_role text;
  v_role text := trim(new_role);
  v_owner_count int;
begin
  if v_caller is null then
    raise exception 'not_authenticated';
  end if;
  if target_user_id is null then
    raise exception 'target_required';
  end if;
  if v_role not in ('Owner', 'Manager', 'Server', 'Kitchen', 'Staff') then
    raise exception 'invalid_role';
  end if;

  select organization_id, role into v_org, v_caller_role
  from profiles where id = v_caller;
  if v_org is null or lower(coalesce(v_caller_role, '')) <> 'owner' then
    raise exception 'owner_required';
  end if;

  select organization_id, role into v_target_org, v_target_role
  from profiles where id = target_user_id;
  if v_target_org is distinct from v_org then
    raise exception 'different_organization';
  end if;

  -- Can't leave the venue with zero Owners.
  if target_user_id = v_caller
     and lower(coalesce(v_target_role, '')) = 'owner'
     and lower(v_role) <> 'owner' then
    select count(*)::int into v_owner_count
    from profiles
    where organization_id = v_org and lower(role) = 'owner';
    if v_owner_count <= 1 then
      raise exception 'cannot_demote_last_owner';
    end if;
  end if;

  if lower(coalesce(v_target_role, '')) = 'owner'
     and lower(v_role) <> 'owner'
     and target_user_id <> v_caller then
    select count(*)::int into v_owner_count
    from profiles
    where organization_id = v_org and lower(role) = 'owner';
    if v_owner_count <= 1 then
      raise exception 'cannot_demote_last_owner';
    end if;
  end if;

  update profiles
  set role = v_role
  where id = target_user_id
    and organization_id = v_org;
end;
$$;

revoke all on function apex_set_role(uuid, text) from public;
grant execute on function apex_set_role(uuid, text) to authenticated;

-- Signup trigger: org_name → new venue Owner; invite_code → join; else solo org.
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

  -- Solo signup with no invite and no restaurant name → personal free org.
  if v_org is null then
    insert into organizations (name, tier, enabled_modules, disabled_modules)
    values (
      coalesce(v_org_name, split_part(coalesce(NEW.email, 'My Restaurant'), '@', 1) || '''s Restaurant'),
      'free', '{}', '{}'
    )
    returning id into v_org;
    v_role := 'Owner';
  end if;

  insert into profiles (id, email, name, role, organization_id, first_time_login)
  values (NEW.id, NEW.email, v_name, v_role, v_org, true)
  on conflict (id) do update set
    email = excluded.email,
    name = coalesce(nullif(trim(profiles.name), ''), excluded.name),
    organization_id = coalesce(profiles.organization_id, excluded.organization_id),
    role = case
      when lower(coalesce(profiles.role, '')) = 'owner' then profiles.role
      else excluded.role
    end;

  if v_found_invite then
    update organization_invites
    set used_at = now(), used_by = NEW.id
    where id = inv.id and used_at is null;
  end if;

  return NEW;
end;
$$;

-- Ensure the auth trigger still points at handle_new_user.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();
