-- Jigsy online extras: tray toppings, wing sides, sub fries, salad dressings.
-- WHY: Board advertises toppings/sides; guest modal only had wing sauce + fries add-ons.
-- Prices: board lists toppings without $ — tier by cut size (3/6/12). Confirm with kitchen later.

do $$
declare
  v_org uuid;
  v_rest uuid := 'a1000000-0000-4000-8000-000000000001';
  r record;
  v_grp uuid;
  topping text;
  toppings text[] := array[
    'Pepperoni','Sausage','Ham','Green peppers','Sweet peppers','Hot peppers',
    'Onion','Tomato','Mushrooms','Broccoli','Bacon','Chicken','Pineapple',
    'Spinach','Garlic'
  ];
  v_delta int;
  dressing text;
  dressings text[] := array[
    'House Italian','House Ranch','House Bleu Cheese','Thousand Island','Caesar'
  ];
  side text;
  sides text[] := array['Celery','Ranch','Bleu cheese'];
begin
  select organization_id into v_org from restaurants where id = v_rest;
  if v_org is null then
    raise exception 'jigsys restaurant missing';
  end if;

  -- Wipe prior extras pass (idempotent re-run). Keep wing Sauce + Fries Add-ons from board menu seed.
  delete from modifier_options
  where modifier_group_id in (
    select id from modifier_groups
    where organization_id = v_org
      and name in ('Add toppings', 'Sides', 'Dressing')
  );
  delete from modifier_groups
  where organization_id = v_org
    and name in ('Add toppings', 'Sides', 'Dressing');
  -- Sub add-ons only (not Fries cheese/bacon group named Add-ons on fries item).
  delete from modifier_options
  where modifier_group_id in (
    select mg.id from modifier_groups mg
    join menu_items mi on mi.id = mg.menu_item_id
    where mg.organization_id = v_org
      and mg.name = 'Add-ons'
      and mi.name in ('Italian Sub', 'Meatball & Cheese Sub', 'Cheesesteak Sub')
  );
  delete from modifier_groups mg
  using menu_items mi
  where mg.menu_item_id = mi.id
    and mg.organization_id = v_org
    and mg.name = 'Add-ons'
    and mi.name in ('Italian Sub', 'Meatball & Cheese Sub', 'Cheesesteak Sub');

  -- ── Tray toppings (house / specialty / gourmet cut SKUs) ─────────────────
  for r in
    select id, name
    from menu_items
    where restaurant_id = v_rest
      and available = true
      and id::text like 'a4000001-%'
      and (
        name like '%· 3 cuts'
        or name like '%· 6 cuts'
        or name like '%· 12 cuts'
      )
  loop
    if r.name like '%· 3 cuts' then
      v_delta := 150;
    elsif r.name like '%· 6 cuts' then
      v_delta := 200;
    else
      v_delta := 250;
    end if;

    v_grp := md5(r.id::text || '|toppings')::uuid;

    insert into modifier_groups (
      id, menu_item_id, organization_id, name, required, min_select, max_select
    ) values (
      v_grp, r.id, v_org, 'Add toppings', false, 0, 15
    );

    foreach topping in array toppings
    loop
      insert into modifier_options (
        id, modifier_group_id, organization_id, name, price_delta_cents
      ) values (
        md5(v_grp::text || '|' || topping)::uuid,
        v_grp, v_org, topping, v_delta
      );
    end loop;
  end loop;

  -- ── Wing sides (+$1 each) ────────────────────────────────────────────────
  for r in
    select id
    from menu_items
    where restaurant_id = v_rest
      and available = true
      and id in (
        'a4000001-0000-4000-8000-000000000101',
        'a4000001-0000-4000-8000-000000000102',
        'a4000001-0000-4000-8000-000000000103',
        'a4000001-0000-4000-8000-000000000104',
        'a4000001-0000-4000-8000-000000000105'
      )
  loop
    v_grp := md5(r.id::text || '|sides')::uuid;
    insert into modifier_groups (
      id, menu_item_id, organization_id, name, required, min_select, max_select
    ) values (
      v_grp, r.id, v_org, 'Sides', false, 0, 3
    );
    foreach side in array sides
    loop
      insert into modifier_options (
        id, modifier_group_id, organization_id, name, price_delta_cents
      ) values (
        md5(v_grp::text || '|' || side)::uuid,
        v_grp, v_org, side, 100
      );
    end loop;
  end loop;

  -- ── Sub add fries ────────────────────────────────────────────────────────
  for r in
    select id
    from menu_items
    where restaurant_id = v_rest
      and available = true
      and id in (
        'a4000001-0000-4000-8000-000000000401',
        'a4000001-0000-4000-8000-000000000402',
        'a4000001-0000-4000-8000-000000000403'
      )
  loop
    v_grp := md5(r.id::text || '|sub-addons')::uuid;
    insert into modifier_groups (
      id, menu_item_id, organization_id, name, required, min_select, max_select
    ) values (
      v_grp, r.id, v_org, 'Add-ons', false, 0, 1
    );
    insert into modifier_options (
      id, modifier_group_id, organization_id, name, price_delta_cents
    ) values (
      md5(v_grp::text || '|fries')::uuid,
      v_grp, v_org, 'Add fries', 200
    );
  end loop;

  -- ── Salad dressings (required) ───────────────────────────────────────────
  for r in
    select id
    from menu_items
    where restaurant_id = v_rest
      and available = true
      and category_id = 'a2000001-0000-4000-8000-000000000007'
  loop
    v_grp := md5(r.id::text || '|dressing')::uuid;
    insert into modifier_groups (
      id, menu_item_id, organization_id, name, required, min_select, max_select
    ) values (
      v_grp, r.id, v_org, 'Dressing', true, 1, 1
    );
    foreach dressing in array dressings
    loop
      insert into modifier_options (
        id, modifier_group_id, organization_id, name, price_delta_cents
      ) values (
        md5(v_grp::text || '|' || dressing)::uuid,
        v_grp, v_org, dressing, 0
      );
    end loop;
  end loop;
end $$;
