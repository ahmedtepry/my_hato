-- 0143: the look of the Windows team console (glass or classic). Per device by default; whoever holds appearance.look
-- (owner by default) can set it for the whole team and lock it so members cannot switch.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('appearance.look', 'system', 'شكل واجهة الويندوز (زجاجي / كلاسيك)', 'Windows console look (glass / classic)',
        'يغيّر شكل واجهة برنامج الويندوز لكل الفريق ويقدر يقفل التبديل', 'Sets the Windows console look for the whole team and can lock switching', false, false, 50)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'appearance.look') on conflict do nothing;

create or replace function public.console_look_set(p_look text, p_locked boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('appearance.look');
  if p_look not in ('classic','glass','midnight','aurora','ember','neon','royal') then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at)
  values ('console_look', jsonb_build_object('look', p_look, 'locked', coalesce(p_locked, false)), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('appearance.look', 'setting', 'console_look', jsonb_build_object('look', p_look, 'locked', coalesce(p_locked, false)));
end $$;
revoke all on function public.console_look_set(text, boolean) from public, anon;
grant execute on function public.console_look_set(text, boolean) to authenticated;
