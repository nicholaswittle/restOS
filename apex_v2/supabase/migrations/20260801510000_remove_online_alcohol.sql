-- No alcohol for online / to-go ordering.
-- House brew packs were seed stubs; PA to-go alcohol is not offered via Apex.

delete from menu_items
where restaurant_id = 'a1000000-0000-4000-8000-000000000001'
  and id in (
    'a3000000-0000-4000-8000-000000000041',
    'a3000000-0000-4000-8000-000000000042',
    'a3000000-0000-4000-8000-000000000043'
  );

delete from menu_categories
where id = 'a2000000-0000-4000-8000-000000000005'
  and restaurant_id = 'a1000000-0000-4000-8000-000000000001';
