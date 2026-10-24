-- 0053: new permission orders.address, "sees the delivery address of orders" (address, location pin, landmark, map).
-- The owner has it; the owner can give it to a role or to one account from the permissions screen.
-- To avoid cutting anyone off by surprise, every role that can already view orders keeps seeing addresses until the owner removes it.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('orders.address', 'orders', 'يشوف عنوان الطلبات', 'See order addresses',
        'يشوف عنوان التوصيل وموقع العميل والعلامة المميزة وزرار الخريطة جوه الطلب',
        'Sees the delivery address, the customer''s location, the landmark and the map button inside an order', true, false, 11)
on conflict (permission) do nothing;

insert into public.role_permissions (role, permission)
select role, 'orders.address' from public.role_permissions where permission = 'orders.view'
on conflict do nothing;
insert into public.role_permissions (role, permission) values ('owner', 'orders.address') on conflict do nothing;
