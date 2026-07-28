-- Allow any org member (including Staff) to 86 / re-stock items for online
-- ordering without granting full menu edit (price/name) via RLS UPDATE.

create or replace function public.apex_set_menu_item_available(
  p_item_id uuid,
  p_available boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select organization_id into v_org
  from menu_items
  where id = p_item_id;

  if v_org is null then
    raise exception 'item_not_found';
  end if;

  if not is_member(v_org) then
    raise exception 'not_a_member';
  end if;

  update menu_items
  set available = coalesce(p_available, false)
  where id = p_item_id;
end;
$$;

revoke all on function public.apex_set_menu_item_available(uuid, boolean) from public;
grant execute on function public.apex_set_menu_item_available(uuid, boolean) to authenticated;
