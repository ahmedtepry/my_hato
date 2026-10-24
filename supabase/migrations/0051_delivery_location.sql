-- 0051: a delivery address can carry the customer's location: a GPS pin, a typed description, or both.
-- The app requires one of them before a delivery order (device or accessories) can be placed.
alter table public.customer_addresses
  add column if not exists latitude  double precision check (latitude  between -90  and 90),
  add column if not exists longitude double precision check (longitude between -180 and 180),
  add column if not exists location_note text check (char_length(location_note) <= 500);

-- the order keeps a snapshot of the address; add the location to that snapshot so staff and the courier see it.
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
      'latitude', a.latitude, 'longitude', a.longitude, 'location_note', a.location_note));
  end if;
  return new;
end $$;

drop trigger if exists orders_add_location on public.orders;
create trigger orders_add_location before insert on public.orders
  for each row execute function public._orders_add_location();
