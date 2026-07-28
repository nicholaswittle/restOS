-- Apex v2 — place_order RPC
--
-- WHY: Anon customers can INSERT online_orders but not order_items — the
-- order_items policy does EXISTS(online_orders...) and Postgres re-applies
-- online_orders RLS inside that subquery; anon has no SELECT, so EXISTS is
-- always false and checkout dies after the parent row. Also, client-sent
-- totals were trusted (a tampered client could pay $0.01 for a $24 tray).
--
-- SECURITY DEFINER inserts the order graph atomically and recomputes money
-- from menu_items / modifier_options / restaurant_settings. Callers may only
-- send ids + quantities — never prices.

create or replace function place_order(
  p_restaurant_id uuid,
  p_public_token text,
  p_customer_name text,
  p_customer_phone text,
  p_notes text,
  p_pickup_minutes int,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_rest_token text;
  v_paused boolean;
  v_fee int;
  v_tax_rate real;
  v_payment_mode text;
  v_prep int;
  v_waiting int;
  v_order_id uuid;
  v_token text;
  v_subtotal int := 0;
  v_tax int;
  v_total int;
  v_item jsonb;
  v_mod jsonb;
  v_menu_id uuid;
  v_qty int;
  v_item_name text;
  v_item_price int;
  v_item_available boolean;
  v_line_price int;
  v_line_id uuid;
  v_opt_id uuid;
  v_opt_name text;
  v_opt_delta int;
  v_opt_group uuid;
  v_attempts int := 0;
begin
  if p_customer_name is null or length(trim(p_customer_name)) = 0 then
    raise exception 'customer_name_required';
  end if;
  if p_customer_phone is null or length(trim(p_customer_phone)) = 0 then
    raise exception 'customer_phone_required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items_required';
  end if;

  select r.organization_id, r.public_token, s.paused, s.fee_cents, s.tax_rate,
         s.payment_mode, s.prep_minutes
    into v_org, v_rest_token, v_paused, v_fee, v_tax_rate, v_payment_mode, v_prep
  from restaurants r
  join restaurant_settings s on s.restaurant_id = r.id
  where r.id = p_restaurant_id;

  if v_org is null then
    raise exception 'restaurant_not_found';
  end if;
  if v_rest_token is distinct from p_public_token then
    raise exception 'invalid_public_token';
  end if;
  if v_paused then
    raise exception 'ordering_paused';
  end if;

  select count(*)::int into v_waiting
  from online_orders
  where restaurant_id = p_restaurant_id
    and status = 'waiting';
  if v_waiting >= 50 then
    raise exception 'too_many_open_orders';
  end if;

  -- Pre-validate lines + accumulate subtotal from server prices only.
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := coalesce((v_item->>'quantity')::int, 0);
    if v_menu_id is null or v_qty <= 0 then
      raise exception 'invalid_item';
    end if;

    select name, price_cents, available
      into v_item_name, v_item_price, v_item_available
    from menu_items
    where id = v_menu_id
      and restaurant_id = p_restaurant_id
      and organization_id = v_org;

    if v_item_name is null then
      raise exception 'unknown_menu_item';
    end if;
    if not v_item_available then
      raise exception 'item_unavailable';
    end if;

    v_line_price := v_item_price;

    if v_item ? 'modifiers' and jsonb_typeof(v_item->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_item->'modifiers')
      loop
        v_opt_id := (v_mod->>'option_id')::uuid;
        if v_opt_id is null then
          raise exception 'invalid_modifier';
        end if;

        select o.name, o.price_delta_cents, o.modifier_group_id
          into v_opt_name, v_opt_delta, v_opt_group
        from modifier_options o
        where o.id = v_opt_id
          and o.organization_id = v_org;

        if v_opt_name is null then
          raise exception 'unknown_modifier';
        end if;

        -- Option must belong to a group attached to this menu item.
        if not exists (
          select 1
          from modifier_groups g
          where g.id = v_opt_group
            and (
              g.menu_item_id = v_menu_id
              or exists (
                select 1 from menu_item_modifier_groups j
                where j.modifier_group_id = g.id
                  and j.menu_item_id = v_menu_id
              )
            )
        ) then
          raise exception 'modifier_not_for_item';
        end if;

        v_line_price := v_line_price + coalesce(v_opt_delta, 0);
      end loop;
    end if;

    v_subtotal := v_subtotal + (v_line_price * v_qty);
  end loop;

  v_fee := coalesce(v_fee, 0);
  v_tax := round(v_subtotal * coalesce(v_tax_rate, 0))::int;
  v_total := v_subtotal + v_fee + v_tax;

  -- Short readable pickup code; retry on the rare unique collision.
  loop
    v_attempts := v_attempts + 1;
    v_token := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (
      select 1 from online_orders where public_token = v_token
    );
    if v_attempts > 8 then
      raise exception 'token_generation_failed';
    end if;
  end loop;

  v_order_id := gen_random_uuid();

  insert into online_orders (
    id, restaurant_id, organization_id, public_token, status,
    pickup_minutes, customer_json, notes,
    subtotal_cents, fee_cents, tax_cents, total_cents,
    payment_mode, payment_status
  ) values (
    v_order_id, p_restaurant_id, v_org, v_token, 'waiting',
    coalesce(nullif(p_pickup_minutes, 0), v_prep, 30),
    jsonb_build_object(
      'name', trim(p_customer_name),
      'phone', trim(p_customer_phone)
    ),
    coalesce(p_notes, ''),
    v_subtotal, v_fee, v_tax, v_total,
    coalesce(v_payment_mode, 'manual'), 'pending'
  );

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := (v_item->>'quantity')::int;

    select name, price_cents
      into v_item_name, v_item_price
    from menu_items
    where id = v_menu_id;

    v_line_price := v_item_price;
    if v_item ? 'modifiers' and jsonb_typeof(v_item->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_item->'modifiers')
      loop
        select o.price_delta_cents into v_opt_delta
        from modifier_options o
        where o.id = (v_mod->>'option_id')::uuid;
        v_line_price := v_line_price + coalesce(v_opt_delta, 0);
      end loop;
    end if;

    v_line_id := gen_random_uuid();
    insert into order_items (
      id, order_id, organization_id, menu_item_id, name, price_cents, quantity, notes
    ) values (
      v_line_id, v_order_id, v_org, v_menu_id, v_item_name, v_line_price, v_qty,
      (
        select string_agg(x.name, '; ')
        from (
          select o.name
          from jsonb_array_elements(coalesce(v_item->'modifiers', '[]'::jsonb)) m
          join modifier_options o on o.id = (m->>'option_id')::uuid
        ) x
      )
    );

    if v_item ? 'modifiers' and jsonb_typeof(v_item->'modifiers') = 'array' then
      for v_mod in select * from jsonb_array_elements(v_item->'modifiers')
      loop
        v_opt_id := (v_mod->>'option_id')::uuid;
        select o.name, o.price_delta_cents
          into v_opt_name, v_opt_delta
        from modifier_options o
        where o.id = v_opt_id;

        insert into order_item_modifiers (
          order_item_id, organization_id, modifier_option_id, name, price_delta_cents
        ) values (
          v_line_id, v_org, v_opt_id, v_opt_name, coalesce(v_opt_delta, 0)
        );
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'id', v_order_id,
    'public_token', v_token,
    'total_cents', v_total,
    'status', 'waiting'
  );
end;
$$;

revoke all on function place_order(uuid, text, text, text, text, int, jsonb) from public;
grant execute on function place_order(uuid, text, text, text, text, int, jsonb) to anon, authenticated;

comment on function place_order(uuid, text, text, text, text, int, jsonb) is
  'Atomic guest checkout. Recomputes prices server-side; bypasses broken anon order_items RLS.';

-- WHY: CapacityEngine.check() reads time_entries + online_orders which anon
-- customers cannot SELECT. Guest menu still needs kitchen load for wait banners.
create or replace function capacity_snapshot(p_restaurant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_paused boolean;
  v_auto boolean;
  v_threshold int;
  v_max_per_hour int;
  v_staff int;
  v_orders int;
  v_max_cap int;
  v_uses_kitchen boolean;
  v_state text;
begin
  select r.organization_id, s.paused, s.auto_pause_enabled, s.auto_pause_threshold,
         s.max_orders_per_hour
    into v_org, v_paused, v_auto, v_threshold, v_max_per_hour
  from restaurants r
  join restaurant_settings s on s.restaurant_id = r.id
  where r.id = p_restaurant_id;

  if v_org is null then
    return jsonb_build_object(
      'staff_on_shift', 0,
      'orders_last_hour', 0,
      'max_capacity', 0,
      'state', 'unknown'
    );
  end if;

  -- capacity = kitchen staff × max_orders_per_hour. Servers don't cook.
  select exists (
    select 1 from profiles p
    where p.organization_id = v_org
      and (
        lower(coalesce(p.role, '')) in ('kitchen', 'cook', 'chef', 'line cook', 'line_cook')
        or lower(coalesce(p.role, '')) like '%cook%'
        or lower(coalesce(p.role, '')) like '%kitchen%'
        or lower(coalesce(p.role, '')) like '%chef%'
      )
  ) into v_uses_kitchen;

  if v_uses_kitchen then
    select count(*)::int into v_staff
    from time_entries t
    join profiles p on p.id = t.user_id
    where t.organization_id = v_org
      and t.clock_out is null
      and (
        lower(coalesce(p.role, '')) in ('kitchen', 'cook', 'chef', 'line cook', 'line_cook')
        or lower(coalesce(p.role, '')) like '%cook%'
        or lower(coalesce(p.role, '')) like '%kitchen%'
        or lower(coalesce(p.role, '')) like '%chef%'
      );
  else
    select count(*)::int into v_staff
    from time_entries t
    where t.organization_id = v_org
      and t.clock_out is null;
  end if;

  select count(*)::int into v_orders
  from online_orders o
  where o.organization_id = v_org
    and o.restaurant_id = p_restaurant_id
    and o.status = 'waiting'
    and o.submitted_at >= now() - interval '1 hour';

  v_max_cap := v_staff * coalesce(v_max_per_hour, 15);

  if coalesce(v_auto, true) and v_staff < coalesce(v_threshold, 1) then
    v_state := 'autoPaused';
  elsif v_paused then
    v_state := 'manuallyPaused';
  elsif v_max_cap > 0 and v_orders >= v_max_cap then
    v_state := 'atCapacity';
  elsif v_max_cap > 0 and v_orders >= round(v_max_cap * 0.8) then
    v_state := 'nearCapacity';
  else
    v_state := 'open';
  end if;

  return jsonb_build_object(
    'staff_on_shift', v_staff,
    'orders_last_hour', v_orders,
    'max_capacity', v_max_cap,
    'state', v_state
  );
end;
$$;

revoke all on function capacity_snapshot(uuid) from public;
grant execute on function capacity_snapshot(uuid) to anon, authenticated;
