-- 0052: when the customer types the location instead of sharing a GPS pin, they confirm it and add a landmark.
-- The confirmation travels with the order so staff know they do not need to call to double-check.
alter table public.customer_addresses add column if not exists location_confirmed boolean not null default false;

create or replace function public._orders_add_location() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.customer_addresses%rowtype;
begin
  if new.delivery_address is null or new.delivery_address ? 'latitude' or new.delivery_address ? 'location_note' then
    return new;
  end if;
  select * into a from public.customer_addresses
   where user_id = new.customer_id
     and governorate = new.delivery_address->>'governorate'
     and city = new.delivery_address->>'city'
     and street = new.delivery_address->>'street'
   order by updated_at desc limit 1;
  if found and (a.latitude is not null or a.location_note is not null) then
    new.delivery_address := new.delivery_address || jsonb_strip_nulls(jsonb_build_object(
      'latitude', a.latitude, 'longitude', a.longitude, 'location_note', a.location_note,
      'location_confirmed', a.location_confirmed));
  end if;
  return new;
end $$;
