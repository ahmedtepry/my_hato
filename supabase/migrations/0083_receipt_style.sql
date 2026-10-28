-- 0083: the invoice look is one setting for the whole shop (clean | banner | cards), changed by whoever has receipt.style (owner by default).
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('receipt.style', 'pos', 'يغيّر شكل الفاتورة', 'Change the invoice look',
  'يختار شكل الفاتورة المطبوعة والظاهرة على الشاشة لكل الكاشيرات (نظيف / الشريط / بطاقات)', 'Chooses the invoice look, printed and on screen, for every cashier (clean / banner / cards)', false, false, 97)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'receipt.style') on conflict do nothing;

insert into public.application_settings (key, value, description) values
  ('receipt_style', '"clean"', 'Invoice look: clean | banner | cards')
on conflict (key) do nothing;

create or replace function public.receipt_style_get() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.is_staff() or public.has_permission('receipt.style')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select value #>> '{}' from public.application_settings where key = 'receipt_style'), 'clean');
end $$;

create or replace function public.receipt_style_set(p_style text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('receipt.style');
  if p_style not in ('clean', 'banner', 'cards') then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at) values ('receipt_style', to_jsonb(p_style), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('receipt.style', 'settings', 'receipt', jsonb_build_object('style', p_style));
end $$;
revoke all on function public.receipt_style_get(), public.receipt_style_set(text) from public, anon;
grant execute on function public.receipt_style_get(), public.receipt_style_set(text) to authenticated;
