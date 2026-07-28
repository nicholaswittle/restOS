-- Jigsy's full Nov 2025 board → online menu
-- WHY: Order Online was seeded with a 19-item stub; the public site board is the
-- source of truth for guest ordering until staff manage the catalog in-app.

do $$
declare
  v_org uuid;
  v_rest uuid := 'a1000000-0000-4000-8000-000000000001';
  -- categories
  c_house uuid := 'a2000001-0000-4000-8000-000000000001';
  c_spec  uuid := 'a2000001-0000-4000-8000-000000000002';
  c_gour  uuid := 'a2000001-0000-4000-8000-000000000003';
  c_wing  uuid := 'a2000001-0000-4000-8000-000000000004';
  c_strom uuid := 'a2000001-0000-4000-8000-000000000005';
  c_start uuid := 'a2000001-0000-4000-8000-000000000006';
  c_salad uuid := 'a2000001-0000-4000-8000-000000000007';
  c_subs  uuid := 'a2000001-0000-4000-8000-000000000008';
  c_dess  uuid := 'a2000001-0000-4000-8000-000000000009';
  -- legacy brew category (removed from online; kept only for migration cleanup)
  c_brew  uuid := 'a2000000-0000-4000-8000-000000000005';
  -- wing sauce groups
  g_w5  uuid := 'a5000001-0000-4000-8000-000000000001';
  g_w10 uuid := 'a5000001-0000-4000-8000-000000000002';
  g_w20 uuid := 'a5000001-0000-4000-8000-000000000003';
  g_w30 uuid := 'a5000001-0000-4000-8000-000000000004';
  g_bone uuid := 'a5000001-0000-4000-8000-000000000005';
  g_fries uuid := 'a5000001-0000-4000-8000-000000000006';
  -- wing items
  i_w5  uuid := 'a4000001-0000-4000-8000-000000000101';
  i_w10 uuid := 'a4000001-0000-4000-8000-000000000102';
  i_w20 uuid := 'a4000001-0000-4000-8000-000000000103';
  i_w30 uuid := 'a4000001-0000-4000-8000-000000000104';
  i_bone uuid := 'a4000001-0000-4000-8000-000000000105';
  i_fries uuid := 'a4000001-0000-4000-8000-000000000206';
  sauce text;
  sauces text[] := array[
    'Hot','Mild','BBQ','Old Bay','Honey BBQ','Teriyaki',
    'Classic Buffalo','Garlic Parm','Spicy Bleu Cheese','Spicy Ranch',
    'Chicken Bacon Ranch','Salt & Vinegar','Buffalo Bay','Hot Garlic','Sweet Heat'
  ];
  grp uuid;
  item uuid;
begin
  select organization_id into v_org from restaurants where id = v_rest;
  if v_org is null then
    raise exception 'jigsys restaurant missing';
  end if;

  -- Keep historical order FKs; hide the stub catalog from guests.
  update menu_items
  set available = false
  where restaurant_id = v_rest
    and id::text like 'a3000000-%';

  insert into menu_categories (id, restaurant_id, organization_id, name, sort_order) values
    (c_house, v_rest, v_org, 'Old Forge trays', 1),
    (c_spec,  v_rest, v_org, 'Specialty trays', 2),
    (c_gour,  v_rest, v_org, 'Gourmet trays', 3),
    (c_wing,  v_rest, v_org, 'Wings', 4),
    (c_strom, v_rest, v_org, 'Stromboli & flatbreads', 5),
    (c_start, v_rest, v_org, 'Starters', 6),
    (c_salad, v_rest, v_org, 'Salads', 7),
    (c_subs,  v_rest, v_org, 'Subs & platters', 8),
    (c_dess,  v_rest, v_org, 'Dessert', 9)
  on conflict (id) do update set
    name = excluded.name,
    sort_order = excluded.sort_order;

  update menu_categories
  set name = 'House Brews To-Go', sort_order = 10
  where id = c_brew;

  -- Alcohol is not sold online / to-go via Apex. Keep any leftover brew SKUs off.
  update menu_items
  set available = false
  where id in (
    'a3000000-0000-4000-8000-000000000041',
    'a3000000-0000-4000-8000-000000000042',
    'a3000000-0000-4000-8000-000000000043'
  );

  -- Clear prior full-board insert if re-run.
  delete from modifier_options
  where modifier_group_id in (
    select id from modifier_groups
    where organization_id = v_org
      and id::text like 'a5000001-%'
  );
  delete from modifier_groups
  where organization_id = v_org
    and id::text like 'a5000001-%';
  delete from menu_items
  where restaurant_id = v_rest
    and id::text like 'a4000001-%';

  insert into menu_items (
    id, restaurant_id, organization_id, category_id, name, description, price_cents, available, sort_order
  ) values
    -- House trays
    ('a4000001-0000-4000-8000-000000000001', v_rest, v_org, c_house, 'Traditional Red · 3 cuts', 'Sauce, cheese. Square cuts.', 749, true, 1),
    ('a4000001-0000-4000-8000-000000000002', v_rest, v_org, c_house, 'Traditional Red · 6 cuts', 'Sauce, cheese. Square cuts.', 1499, true, 2),
    ('a4000001-0000-4000-8000-000000000003', v_rest, v_org, c_house, 'Traditional Red · 12 cuts', 'Sauce, cheese. Square cuts.', 1899, true, 3),
    ('a4000001-0000-4000-8000-000000000004', v_rest, v_org, c_house, 'Single White · 3 cuts', 'Single crust, cheese.', 849, true, 4),
    ('a4000001-0000-4000-8000-000000000005', v_rest, v_org, c_house, 'Single White · 6 cuts', 'Single crust, cheese.', 1599, true, 5),
    ('a4000001-0000-4000-8000-000000000006', v_rest, v_org, c_house, 'Single White · 12 cuts', 'Single crust, cheese.', 2099, true, 6),
    ('a4000001-0000-4000-8000-000000000007', v_rest, v_org, c_house, 'Double White · 6 cuts', 'Double crust, cheese.', 1899, true, 7),
    ('a4000001-0000-4000-8000-000000000008', v_rest, v_org, c_house, 'Double White · 12 cuts', 'Double crust, cheese.', 2699, true, 8),

    -- Specialty trays (3 / 6 / 12)
    ('a4000001-0000-4000-8000-000000000011', v_rest, v_org, c_spec, 'Tomato & Garlic · 3 cuts', 'Cheese, tomato, fresh garlic.', 1099, true, 1),
    ('a4000001-0000-4000-8000-000000000012', v_rest, v_org, c_spec, 'Tomato & Garlic · 6 cuts', 'Cheese, tomato, fresh garlic.', 1649, true, 2),
    ('a4000001-0000-4000-8000-000000000013', v_rest, v_org, c_spec, 'Tomato & Garlic · 12 cuts', 'Cheese, tomato, fresh garlic.', 2499, true, 3),
    ('a4000001-0000-4000-8000-000000000014', v_rest, v_org, c_spec, 'Chick Fil “J” · 3 cuts', 'Buttery garlic sauce, crispy chicken, sliced pickles, cheese.', 1199, true, 4),
    ('a4000001-0000-4000-8000-000000000015', v_rest, v_org, c_spec, 'Chick Fil “J” · 6 cuts', 'Buttery garlic sauce, crispy chicken, sliced pickles, cheese.', 1849, true, 5),
    ('a4000001-0000-4000-8000-000000000016', v_rest, v_org, c_spec, 'Chick Fil “J” · 12 cuts', 'Buttery garlic sauce, crispy chicken, sliced pickles, cheese.', 2799, true, 6),
    ('a4000001-0000-4000-8000-000000000017', v_rest, v_org, c_spec, 'Chicken Bacon Ranch · 3 cuts', 'Cheese, house ranch, grilled chicken, crispy bacon.', 1099, true, 7),
    ('a4000001-0000-4000-8000-000000000018', v_rest, v_org, c_spec, 'Chicken Bacon Ranch · 6 cuts', 'Cheese, house ranch, grilled chicken, crispy bacon.', 1749, true, 8),
    ('a4000001-0000-4000-8000-000000000019', v_rest, v_org, c_spec, 'Chicken Bacon Ranch · 12 cuts', 'Cheese, house ranch, grilled chicken, crispy bacon.', 2699, true, 9),
    ('a4000001-0000-4000-8000-000000000020', v_rest, v_org, c_spec, 'Buffalo Chicken · 3 cuts', 'Hot sauce, cheese, crispy chicken.', 1099, true, 10),
    ('a4000001-0000-4000-8000-000000000021', v_rest, v_org, c_spec, 'Buffalo Chicken · 6 cuts', 'Hot sauce, cheese, crispy chicken.', 1749, true, 11),
    ('a4000001-0000-4000-8000-000000000022', v_rest, v_org, c_spec, 'Buffalo Chicken · 12 cuts', 'Hot sauce, cheese, crispy chicken.', 2699, true, 12),
    ('a4000001-0000-4000-8000-000000000023', v_rest, v_org, c_spec, 'Meatlovers · 3 cuts', 'Sauce, cheese, ham, pepperoni, sausage, bacon.', 1099, true, 13),
    ('a4000001-0000-4000-8000-000000000024', v_rest, v_org, c_spec, 'Meatlovers · 6 cuts', 'Sauce, cheese, ham, pepperoni, sausage, bacon.', 1749, true, 14),
    ('a4000001-0000-4000-8000-000000000025', v_rest, v_org, c_spec, 'Meatlovers · 12 cuts', 'Sauce, cheese, ham, pepperoni, sausage, bacon.', 2699, true, 15),
    ('a4000001-0000-4000-8000-000000000026', v_rest, v_org, c_spec, 'Spinach & Tomato · 3 cuts', 'Cheese, spinach, tomato.', 1099, true, 16),
    ('a4000001-0000-4000-8000-000000000027', v_rest, v_org, c_spec, 'Spinach & Tomato · 6 cuts', 'Cheese, spinach, tomato.', 1649, true, 17),
    ('a4000001-0000-4000-8000-000000000028', v_rest, v_org, c_spec, 'Spinach & Tomato · 12 cuts', 'Cheese, spinach, tomato.', 2499, true, 18),
    ('a4000001-0000-4000-8000-000000000029', v_rest, v_org, c_spec, 'Meatball · 3 cuts', 'Sauce, cheese, house meatballs, fresh parmesan.', 1199, true, 19),
    ('a4000001-0000-4000-8000-000000000030', v_rest, v_org, c_spec, 'Meatball · 6 cuts', 'Sauce, cheese, house meatballs, fresh parmesan.', 1899, true, 20),
    ('a4000001-0000-4000-8000-000000000031', v_rest, v_org, c_spec, 'Meatball · 12 cuts', 'Sauce, cheese, house meatballs, fresh parmesan.', 2899, true, 21),
    ('a4000001-0000-4000-8000-000000000032', v_rest, v_org, c_spec, 'Chicken Bruschetta · 3 cuts', 'Light sauce, cheese, chicken, tomato, spinach, red onion, garlic.', 1099, true, 22),
    ('a4000001-0000-4000-8000-000000000033', v_rest, v_org, c_spec, 'Chicken Bruschetta · 6 cuts', 'Light sauce, cheese, chicken, tomato, spinach, red onion, garlic.', 1749, true, 23),
    ('a4000001-0000-4000-8000-000000000034', v_rest, v_org, c_spec, 'Chicken Bruschetta · 12 cuts', 'Light sauce, cheese, chicken, tomato, spinach, red onion, garlic.', 2699, true, 24),
    ('a4000001-0000-4000-8000-000000000035', v_rest, v_org, c_spec, 'Hot Oil Pepperoni · 3 cuts', 'Sauce, cheese, pepperoni, Calabrian pepper oil.', 1099, true, 25),
    ('a4000001-0000-4000-8000-000000000036', v_rest, v_org, c_spec, 'Hot Oil Pepperoni · 6 cuts', 'Sauce, cheese, pepperoni, Calabrian pepper oil.', 1749, true, 26),
    ('a4000001-0000-4000-8000-000000000037', v_rest, v_org, c_spec, 'Hot Oil Pepperoni · 12 cuts', 'Sauce, cheese, pepperoni, Calabrian pepper oil.', 2699, true, 27),
    ('a4000001-0000-4000-8000-000000000038', v_rest, v_org, c_spec, 'Rustico · 3 cuts', 'Cheese, pepperoni, sausage, green pepper, mushroom, onion.', 1099, true, 28),
    ('a4000001-0000-4000-8000-000000000039', v_rest, v_org, c_spec, 'Rustico · 6 cuts', 'Cheese, pepperoni, sausage, green pepper, mushroom, onion.', 1749, true, 29),
    ('a4000001-0000-4000-8000-000000000040', v_rest, v_org, c_spec, 'Rustico · 12 cuts', 'Cheese, pepperoni, sausage, green pepper, mushroom, onion.', 2699, true, 30),
    ('a4000001-0000-4000-8000-000000000041', v_rest, v_org, c_spec, 'Hawaiian · 3 cuts', 'Cheese, ham, pineapple.', 1099, true, 31),
    ('a4000001-0000-4000-8000-000000000042', v_rest, v_org, c_spec, 'Hawaiian · 6 cuts', 'Cheese, ham, pineapple.', 1749, true, 32),
    ('a4000001-0000-4000-8000-000000000043', v_rest, v_org, c_spec, 'Hawaiian · 12 cuts', 'Cheese, ham, pineapple.', 2699, true, 33),

    -- Gourmet (6 / 12)
    ('a4000001-0000-4000-8000-000000000051', v_rest, v_org, c_gour, 'Gourmet Buffalo Chicken · 6 cuts', 'Hot sauce, crispy chicken, cheese. Double crust.', 2049, true, 1),
    ('a4000001-0000-4000-8000-000000000052', v_rest, v_org, c_gour, 'Gourmet Buffalo Chicken · 12 cuts', 'Hot sauce, crispy chicken, cheese. Double crust.', 3099, true, 2),
    ('a4000001-0000-4000-8000-000000000053', v_rest, v_org, c_gour, 'Gourmet Rustico · 6 cuts', 'Cheese, pepperoni, sausage, green pepper, mushroom, onion. Double crust.', 2049, true, 3),
    ('a4000001-0000-4000-8000-000000000054', v_rest, v_org, c_gour, 'Gourmet Rustico · 12 cuts', 'Cheese, pepperoni, sausage, green pepper, mushroom, onion. Double crust.', 3099, true, 4),
    ('a4000001-0000-4000-8000-000000000055', v_rest, v_org, c_gour, 'Gourmet Tomato & Garlic · 6 cuts', 'Cheese, tomato, garlic. Double crust.', 1949, true, 5),
    ('a4000001-0000-4000-8000-000000000056', v_rest, v_org, c_gour, 'Gourmet Tomato & Garlic · 12 cuts', 'Cheese, tomato, garlic. Double crust.', 2999, true, 6),
    ('a4000001-0000-4000-8000-000000000057', v_rest, v_org, c_gour, 'Gourmet Broccoli · 6 cuts', 'Cheese, broccoli. Double crust.', 1949, true, 7),
    ('a4000001-0000-4000-8000-000000000058', v_rest, v_org, c_gour, 'Gourmet Broccoli · 12 cuts', 'Cheese, broccoli. Double crust.', 2999, true, 8),
    ('a4000001-0000-4000-8000-000000000059', v_rest, v_org, c_gour, 'Gourmet Pierogi · 6 cuts', 'Cheese, pierogi, butter, onion. Double crust.', 2049, true, 9),
    ('a4000001-0000-4000-8000-000000000060', v_rest, v_org, c_gour, 'Gourmet Pierogi · 12 cuts', 'Cheese, pierogi, butter, onion. Double crust.', 3099, true, 10),

    -- Wings
    (i_w5,  v_rest, v_org, c_wing, 'Jumbo Wings · 5', 'Fresh jumbo wings. Pick a sauce. Celery/ranch/bleu +$1 in notes.', 799, true, 1),
    (i_w10, v_rest, v_org, c_wing, 'Jumbo Wings · 10', 'Fresh jumbo wings. Pick a sauce. Celery/ranch/bleu +$1 in notes.', 1299, true, 2),
    (i_w20, v_rest, v_org, c_wing, 'Jumbo Wings · 20', 'Fresh jumbo wings. Pick a sauce. Celery/ranch/bleu +$1 in notes.', 2599, true, 3),
    (i_w30, v_rest, v_org, c_wing, 'Jumbo Wings · 30', 'Fresh jumbo wings. Pick a sauce. Celery/ranch/bleu +$1 in notes.', 3499, true, 4),
    (i_bone, v_rest, v_org, c_start, 'Boneless Wings', 'Any sauce · celery, ranch, bleu cheese +$1.00 in notes if needed.', 1099, true, 0),

    -- Stromboli & flatbreads
    ('a4000001-0000-4000-8000-000000000111', v_rest, v_org, c_strom, 'Traditional Stromboli', 'Ham, pepperoni, sausage, onion, mushroom, green & sweet peppers, hot peppers.', 1899, true, 1),
    ('a4000001-0000-4000-8000-000000000112', v_rest, v_org, c_strom, 'Cheesesteak Stromboli', 'Cheesesteak, onion, mushroom, green peppers.', 1999, true, 2),
    ('a4000001-0000-4000-8000-000000000113', v_rest, v_org, c_strom, 'Buffalo Chicken Stromboli', 'Crispy chicken, hot sauce, cheese.', 1999, true, 3),
    ('a4000001-0000-4000-8000-000000000114', v_rest, v_org, c_strom, 'Veggie Stromboli', 'Tomato, spinach, garlic, cheese.', 1899, true, 4),
    ('a4000001-0000-4000-8000-000000000115', v_rest, v_org, c_strom, 'Traditional Red Flatbread', 'Sauce, cheese.', 1099, true, 5),
    ('a4000001-0000-4000-8000-000000000116', v_rest, v_org, c_strom, 'BBQ Chicken Flatbread', 'BBQ sauce, cheese, grilled chicken, red onion, ranch.', 1249, true, 6),
    ('a4000001-0000-4000-8000-000000000117', v_rest, v_org, c_strom, 'Chicken Bruschetta Flatbread', 'Light sauce, chicken, cheese, tomato, spinach, red onion, garlic.', 1249, true, 7),
    ('a4000001-0000-4000-8000-000000000118', v_rest, v_org, c_strom, 'Veggie Flatbread', 'Spinach, tomato, garlic, cheese.', 1149, true, 8),

    -- Starters
    ('a4000001-0000-4000-8000-000000000201', v_rest, v_org, c_start, 'Antipasto', 'Lettuce, ham, salami, cheese, pepperoni, tomato, onion, hot & sweet peppers, black olive.', 1799, true, 1),
    ('a4000001-0000-4000-8000-000000000202', v_rest, v_org, c_start, 'House-Made Meatballs', 'Hand-rolled with sauce, cheese and a side of bread.', 1199, true, 2),
    ('a4000001-0000-4000-8000-000000000203', v_rest, v_org, c_start, 'Pepperoni Bread', 'Stuffed with pepperoni, cheese, side of sauce.', 1299, true, 3),
    ('a4000001-0000-4000-8000-000000000204', v_rest, v_org, c_start, 'Cheesy Bread', 'Cheese, fresh garlic, seasonings, side of sauce.', 999, true, 4),
    ('a4000001-0000-4000-8000-000000000205', v_rest, v_org, c_start, 'Buffalo Chicken Cheese Fries', 'Crispy buffalo chicken, cheese, celery & house bleu cheese.', 1299, true, 5),
    (i_fries, v_rest, v_org, c_start, 'Fries', 'Add cheese or bacon.', 799, true, 6),
    ('a4000001-0000-4000-8000-000000000207', v_rest, v_org, c_start, 'Fried Pickles', 'Crispy fried pickle chips with house ranch.', 999, true, 7),
    ('a4000001-0000-4000-8000-000000000208', v_rest, v_org, c_start, 'Mozzarella Sticks', 'Side of sauce.', 899, true, 8),
    ('a4000001-0000-4000-8000-000000000209', v_rest, v_org, c_start, 'Potato & Cheese Pierogi (6)', 'Butter and onions.', 899, true, 9),

    -- Salads
    ('a4000001-0000-4000-8000-000000000301', v_rest, v_org, c_salad, 'Italian Chopped', 'Lettuce, salami, pepperoni, cheese, chickpeas, carrot.', 1499, true, 1),
    ('a4000001-0000-4000-8000-000000000302', v_rest, v_org, c_salad, 'Antipasto Salad', 'Lettuce, ham, salami, cheese, pepperoni, tomato, onion, hot & sweet peppers, black olive.', 1799, true, 2),
    ('a4000001-0000-4000-8000-000000000303', v_rest, v_org, c_salad, 'Caesar', 'Lettuce, fresh grated parmesan, house croutons.', 1499, true, 3),
    ('a4000001-0000-4000-8000-000000000304', v_rest, v_org, c_salad, 'Chicken Bacon Ranch Salad', 'Lettuce, chicken, bacon, tomato, cheese, egg.', 1499, true, 4),
    ('a4000001-0000-4000-8000-000000000305', v_rest, v_org, c_salad, 'Greek', 'Lettuce, tomato, cucumber, black olive, onion, feta.', 1499, true, 5),
    ('a4000001-0000-4000-8000-000000000306', v_rest, v_org, c_salad, 'Grilled Chicken Salad', 'Lettuce, chicken, cheese, tomato, cucumber, onion.', 1499, true, 6),
    ('a4000001-0000-4000-8000-000000000307', v_rest, v_org, c_salad, 'Summer (Seasonal)', 'Lettuce, pineapple, orange, strawberry, blueberry, walnut, chicken.', 1599, true, 7),
    ('a4000001-0000-4000-8000-000000000308', v_rest, v_org, c_salad, 'Tossed', 'Lettuce, tomato, onion, cucumber, black olive, cheese.', 799, true, 8),

    -- Subs & platters
    ('a4000001-0000-4000-8000-000000000401', v_rest, v_org, c_subs, 'Italian Sub', 'Ham, salami, provolone, lettuce, tomato, onion, hot & sweet peppers, oil & vinegar.', 1299, true, 1),
    ('a4000001-0000-4000-8000-000000000402', v_rest, v_org, c_subs, 'Meatball & Cheese Sub', 'House meatballs, sauce, cheese.', 1499, true, 2),
    ('a4000001-0000-4000-8000-000000000403', v_rest, v_org, c_subs, 'Cheesesteak Sub', 'Sliced ribeye, cheese.', 1499, true, 3),
    ('a4000001-0000-4000-8000-000000000404', v_rest, v_org, c_subs, 'Kids Chicken & Fries', 'Chicken strips (2), fries.', 899, true, 4),
    ('a4000001-0000-4000-8000-000000000405', v_rest, v_org, c_subs, 'Chicken Strips & Fries', 'Chicken strips (4), fries.', 1299, true, 5),
    ('a4000001-0000-4000-8000-000000000406', v_rest, v_org, c_subs, 'Soup of the Day · Cup', 'Ask kitchen for today''s soup.', 599, true, 6),
    ('a4000001-0000-4000-8000-000000000407', v_rest, v_org, c_subs, 'Soup of the Day · Bowl', 'Ask kitchen for today''s soup.', 799, true, 7),

    -- Dessert
    ('a4000001-0000-4000-8000-000000000501', v_rest, v_org, c_dess, 'Peanut Butter Pie (slice)', 'Rich, cold house dessert — by the slice.', 599, true, 1);

  -- Wing sauce picker (required) for each wing SKU.
  for item, grp in
    select * from (values
      (i_w5, g_w5),
      (i_w10, g_w10),
      (i_w20, g_w20),
      (i_w30, g_w30),
      (i_bone, g_bone)
    ) as t(item_id, group_id)
  loop
    insert into modifier_groups (
      id, menu_item_id, organization_id, name, required, min_select, max_select
    ) values (
      grp, item, v_org, 'Sauce', true, 1, 1
    );

    foreach sauce in array sauces
    loop
      insert into modifier_options (
        id, modifier_group_id, organization_id, name, price_delta_cents
      ) values (
        gen_random_uuid(), grp, v_org, sauce, 0
      );
    end loop;
  end loop;

  -- Fries add-ons
  insert into modifier_groups (
    id, menu_item_id, organization_id, name, required, min_select, max_select
  ) values (
    g_fries, i_fries, v_org, 'Add-ons', false, 0, 2
  );
  insert into modifier_options (id, modifier_group_id, organization_id, name, price_delta_cents) values
    (gen_random_uuid(), g_fries, v_org, 'Add cheese', 250),
    (gen_random_uuid(), g_fries, v_org, 'Add bacon', 250);
end $$;
