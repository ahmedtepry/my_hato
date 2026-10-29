-- 0104: "طريقة عرض الواجهة". The owner picks how products are laid out on the customers' home screen; it applies to every customer at once.
-- Permission storefront.layout (owner by default). Customers only READ the choice (storefront_layout_get); only the owner changes it.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('storefront.layout', 'extras', 'يغيّر طريقة عرض واجهة التطبيق', 'Change the storefront layout',
  'يختار شكل عرض المنتجات في الصفحة الرئيسية للعملا، ويتطبق على الكل', 'Picks how products are shown on the customers home screen; it applies to everyone', true, false, 40)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'storefront.layout') on conflict do nothing;

create table if not exists public.store_layout (
  key text primary key check (key = 'home_products'),
  value text not null check (value in ('current', 'compact', 'list', 'tri', 'stagger', 'rails', 'hero', 'shop', 'toggle')),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
alter table public.store_layout enable row level security;   -- no policies: only the functions below touch it
revoke all on public.store_layout from anon, authenticated;
insert into public.store_layout (key, value) values ('home_products', 'current') on conflict (key) do nothing;

create or replace function public.storefront_layout_get() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.store_layout where key = 'home_products'), 'current')
$$;
revoke all on function public.storefront_layout_get() from public;
grant execute on function public.storefront_layout_get() to anon, authenticated;

create or replace function public.storefront_layout_set(p_layout text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('storefront.layout');
  if p_layout is null or p_layout not in ('current', 'compact', 'list', 'tri', 'stagger', 'rails', 'hero', 'shop', 'toggle') then raise exception 'INVALID_INPUT'; end if;
  insert into public.store_layout (key, value, updated_by) values ('home_products', p_layout, auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
  perform public.audit_write('storefront.layout', 'store_layout', 'home_products', jsonb_build_object('layout', p_layout));
end $$;
revoke all on function public.storefront_layout_set(text) from public, anon;
grant execute on function public.storefront_layout_set(text) to authenticated;
