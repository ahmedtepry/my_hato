-- 0074: the owner sets an employee's monthly target from the account's permission screen; the employee is told at once
-- (a notification), and his own target page already shows the new number.

create or replace function public.targets_get_user(p_user uuid) returns bigint
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('targets.manage');
  return coalesce((select monthly_minor from public.user_targets where user_id = p_user), 0);
end $$;
revoke all on function public.targets_get_user(uuid) from public, anon;
grant execute on function public.targets_get_user(uuid) to authenticated;

create or replace function public.targets_set_user(p_user uuid, p_monthly_minor bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_old bigint; v_new bigint := coalesce(p_monthly_minor, 0); v_txt text;
begin
  perform public.require_permission('targets.manage');
  if not exists (select 1 from public.user_roles where user_id = p_user) then raise exception 'NOT_FOUND'; end if;
  select monthly_minor into v_old from public.user_targets where user_id = p_user;
  if v_new = 0 then
    delete from public.user_targets where user_id = p_user;
  else
    if v_new < 0 or v_new > 100000000000 then raise exception 'INVALID_INPUT'; end if;
    insert into public.user_targets (user_id, monthly_minor, updated_by) values (p_user, v_new, auth.uid())
    on conflict (user_id) do update set monthly_minor = excluded.monthly_minor, updated_by = auth.uid(), updated_at = now();
  end if;
  perform public.audit_write('target.user', 'user', p_user::text, jsonb_build_object('monthly_minor', v_new));
  if coalesce(v_old, 0) <> v_new then
    v_txt := trim(to_char(v_new / 100.0, 'FM999,999,999,990.##'));
    if v_new = 0 then
      perform public.notify_user(p_user, '🎯 اتشال التارجت الشهري', '🎯 Monthly target removed',
        'الإدارة شالت تارجتك الشهري.', 'Management removed your monthly target.', 'system', null, null, '/');
    else
      perform public.notify_user(p_user, '🎯 تارجت جديد ليك', '🎯 You have a new target',
        'تارجتك الشهري بقى ' || v_txt || ' ج.م. تابع نسبتك وعمولتك من «تارجتي وعمولتي».',
        'Your monthly target is now ' || v_txt || ' EGP. Follow your progress and commission in "My target".', 'system', null, null, '/');
    end if;
  end if;
end $$;
revoke all on function public.targets_set_user(uuid, bigint) from public, anon;
grant execute on function public.targets_set_user(uuid, bigint) to authenticated;
