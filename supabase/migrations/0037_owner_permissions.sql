-- 0037: owner-controlled permissions.
-- The owner decides what each role may do and can add / take away a single permission for one account.
--   * public.user_permission_overrides   per-account grant / deny
--   * _user_has_permission()             one place that answers "does this user have this permission"
--   * has_permission / my_staff_context / _notify_staff now honour overrides (identical result while the table is empty)
--   * staff_permissions_overview, staff_set_role_permission, staff_set_user_permission   owner-only tools (permissions.manage)
-- Safe to re-run.

-- ---------------------------------------------------------------- 1) overrides table
create table if not exists public.user_permission_overrides (
  user_id uuid not null references auth.users(id) on delete cascade,
  permission text not null check (permission ~ '^[a-z_]+\.[a-z_]+$'),
  effect text not null check (effect in ('grant','deny')),
  note text,
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (user_id, permission)
);
alter table public.user_permission_overrides enable row level security;
drop policy if exists upo_select on public.user_permission_overrides;
create policy upo_select on public.user_permission_overrides for select to authenticated
  using (user_id = auth.uid() or public.has_permission('staff.manage'));
revoke all on public.user_permission_overrides from anon;
revoke insert, update, delete on public.user_permission_overrides from authenticated;

-- ---------------------------------------------------------------- 2) single source of truth
create or replace function public._user_has_permission(p_user uuid, p_permission text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.user_roles where user_id = p_user)
     and (
       exists (select 1 from public.user_permission_overrides o
                where o.user_id = p_user and o.permission = p_permission and o.effect = 'grant')
       or (
         exists (select 1 from public.user_roles ur join public.role_permissions rp on rp.role = ur.role
                  where ur.user_id = p_user and rp.permission = p_permission)
         and not exists (select 1 from public.user_permission_overrides o
                          where o.user_id = p_user and o.permission = p_permission and o.effect = 'deny')
       )
     )
$$;
revoke all on function public._user_has_permission(uuid, text) from public, anon, authenticated;

create or replace function public.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public._user_has_permission(auth.uid(), p_permission)
     and not exists (select 1 from public.team_members tm where tm.user_id = auth.uid() and tm.suspended_at is not null)
$$;

create or replace function public.my_staff_context()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when exists (select 1 from public.team_members where user_id = auth.uid() and suspended_at is not null)
    then jsonb_build_object('roles', '[]'::jsonb, 'permissions', '[]'::jsonb, 'suspended', true)
    else jsonb_build_object(
      'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = auth.uid()), '[]'),
      'permissions', coalesce((
        select jsonb_agg(distinct x.perm) from (
          select rp.permission as perm from public.user_roles ur
            join public.role_permissions rp on rp.role = ur.role where ur.user_id = auth.uid()
          union
          select o.permission from public.user_permission_overrides o
           where o.user_id = auth.uid() and o.effect = 'grant'
             and exists (select 1 from public.user_roles where user_id = auth.uid())
        ) x
        where x.perm not in (select permission from public.user_permission_overrides
                              where user_id = auth.uid() and effect = 'deny')
      ), '[]'))
  end
$$;

create or replace function public._notify_staff(p_permission text, p_title_ar text, p_title_en text, p_body_ar text, p_body_en text, p_reference text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  for r in select distinct ur.user_id from public.user_roles ur
            where public._user_has_permission(ur.user_id, p_permission) loop
    perform public.notify_user(r.user_id, p_title_ar, p_title_en, p_body_ar, p_body_en, 'system', null, p_reference, '/hato-console');
  end loop;
exception when others then
  null;
end $$;

-- ---------------------------------------------------------------- 3) catalog: new permissions (owner only until a role is given them)
-- Names are reserved for upcoming enforcement; nothing checks them yet except permissions.manage.
insert into public.role_permissions (role, permission) values
  ('owner','customers.review'), ('owner','coupons.manage'), ('owner','payments.manage'),
  ('owner','roles.assign'), ('owner','cancel_requests.decide'), ('owner','reviews.moderate'),
  ('owner','branches.manage'), ('owner','audit.export'), ('owner','notifications.broadcast'),
  ('owner','permissions.manage')
on conflict do nothing;

-- ---------------------------------------------------------------- 4) owner tools
create or replace function public.staff_permissions_overview()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_permission('permissions.manage');
  return jsonb_build_object(
    'permissions', (select coalesce(jsonb_agg(p order by p), '[]') from (select distinct permission as p from public.role_permissions) s),
    'roles', (select coalesce(jsonb_object_agg(role, perms), '{}') from (
                select role::text as role, jsonb_agg(permission order by permission) as perms
                  from public.role_permissions group by role) r),
    'overrides', (select coalesce(jsonb_agg(jsonb_build_object(
                    'user_id', o.user_id, 'name', coalesce(nullif(p.full_name,''), p.email),
                    'permission', o.permission, 'effect', o.effect, 'note', o.note, 'created_at', o.created_at)
                    order by o.created_at), '[]')
                    from public.user_permission_overrides o left join public.profiles p on p.id = o.user_id)
  );
end $$;

create or replace function public.staff_set_role_permission(p_role app_role, p_permission text, p_grant boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.require_permission('permissions.manage');
  if p_role = 'owner' then raise exception 'OWNER_FIXED'; end if;
  if not exists (select 1 from public.role_permissions where permission = p_permission) then raise exception 'UNKNOWN_PERMISSION'; end if;
  if p_permission = 'permissions.manage' then raise exception 'NOT_DELEGABLE'; end if;
  if p_grant then
    insert into public.role_permissions(role, permission) values (p_role, p_permission) on conflict do nothing;
  else
    delete from public.role_permissions where role = p_role and permission = p_permission;
  end if;
  perform public.audit_write(case when p_grant then 'permission.role_grant' else 'permission.role_revoke' end,
    'role', p_role::text, jsonb_build_object('permission', p_permission));
end $$;

create or replace function public.staff_set_user_permission(p_user_id uuid, p_permission text, p_effect text, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.require_permission('permissions.manage');
  if p_effect not in ('grant','deny','clear') then raise exception 'INVALID_INPUT'; end if;
  if p_user_id = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  if not exists (select 1 from public.user_roles where user_id = p_user_id) then raise exception 'NOT_STAFF'; end if;
  if exists (select 1 from public.user_roles where user_id = p_user_id and role = 'owner') then raise exception 'OWNER_FIXED'; end if;
  if not exists (select 1 from public.role_permissions where permission = p_permission) then raise exception 'UNKNOWN_PERMISSION'; end if;
  if p_permission = 'permissions.manage' and p_effect = 'grant' then raise exception 'NOT_DELEGABLE'; end if;
  if p_effect = 'clear' then
    delete from public.user_permission_overrides where user_id = p_user_id and permission = p_permission;
  else
    insert into public.user_permission_overrides(user_id, permission, effect, note, granted_by)
    values (p_user_id, p_permission, p_effect, left(nullif(trim(coalesce(p_note,'')),''), 200), auth.uid())
    on conflict (user_id, permission) do update
      set effect = excluded.effect, note = excluded.note, granted_by = excluded.granted_by, created_at = now();
  end if;
  perform public.audit_write('permission.user_' || p_effect, 'user', p_user_id::text, jsonb_build_object('permission', p_permission));
end $$;

revoke all on function public.staff_permissions_overview() from public, anon;
revoke all on function public.staff_set_role_permission(app_role, text, boolean) from public, anon;
revoke all on function public.staff_set_user_permission(uuid, text, text, text) from public, anon;
grant execute on function public.staff_permissions_overview() to authenticated;
grant execute on function public.staff_set_role_permission(app_role, text, boolean) to authenticated;
grant execute on function public.staff_set_user_permission(uuid, text, text, text) to authenticated;
