-- 0090: on/off switches for customer-facing features ("النقاط" and "عجلة الحظ"). Permission features.manage (owner by default).
-- Turning one OFF removes it from the customers completely (the screens disappear and the server refuses every customer call: nothing can be earned or
-- claimed, so fake accounts cannot farm gifts). Team members still see it in the console. The data is kept, so turning it back ON restores everything.
-- Turning OFF must be confirmed (p_confirm = true), the server enforces that too.

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('features.manage', 'team', 'يتحكم في تشغيل المزايا', 'Switch features on/off',
  'يشغّل ويقفل النقاط وعجلة الحظ للعملا. لما يتقفل البرنامج بيختفي من عندهم ومحدّش يقدر يكسب منه حاجة',
  'Turns points and the lucky wheel on or off for customers. When off it disappears and nobody can earn from it', true, false, 99)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'features.manage') on conflict do nothing;

create table if not exists public.feature_switches (
  key text primary key check (key in ('points', 'wheel')),
  enabled boolean not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
alter table public.feature_switches enable row level security;   -- no policies: only the functions below touch it
insert into public.feature_switches (key, enabled) values ('points', true), ('wheel', false) on conflict (key) do nothing;

create or replace function public._feature_on(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select enabled from public.feature_switches where key = p_key), false)
$$;
revoke all on function public._feature_on(text) from public, anon, authenticated;

-- what the app asks at start-up: customers get false for a switched-off feature; team members always get true (they manage it)
create or replace function public.feature_flags() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'points', public._feature_on('points') or coalesce(public.is_staff(), false),
    'wheel',  public._feature_on('wheel')  or coalesce(public.is_staff(), false),
    'points_enabled', public._feature_on('points'),
    'wheel_enabled',  public._feature_on('wheel'))
$$;
revoke all on function public.feature_flags() from public;
grant execute on function public.feature_flags() to anon, authenticated;

create or replace function public.feature_set(p_key text, p_enabled boolean, p_confirm boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('features.manage');
  if p_key not in ('points', 'wheel') then raise exception 'INVALID_INPUT'; end if;
  if not p_enabled and coalesce(p_confirm, false) is not true then raise exception 'CONFIRM_REQUIRED'; end if;
  update public.feature_switches set enabled = p_enabled, updated_at = now(), updated_by = auth.uid() where key = p_key;
  perform public.audit_write('feature.switch', 'feature', p_key, jsonb_build_object('enabled', p_enabled));
end $$;
revoke all on function public.feature_set(text, boolean, boolean) from public, anon;
grant execute on function public.feature_set(text, boolean, boolean) to authenticated;

-- ---- points: nothing is earned while the switch is off (admin adjustments by the owner still work) ----
alter function public._loy_grant(uuid, text, text, int, int) rename to _loy_grant_impl;
create or replace function public._loy_grant(p_user uuid, p_kind text, p_ref text, p_points int, p_vault int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_kind <> 'admin_adjust' and not public._feature_on('points') then return false; end if;
  return public._loy_grant_impl(p_user, p_kind, p_ref, p_points, p_vault);
end $$;
revoke all on function public._loy_grant_impl(uuid, text, text, int, int) from public, anon, authenticated;
revoke all on function public._loy_grant(uuid, text, text, int, int) from public, anon, authenticated;

-- the customer-facing calls refuse while it is off (the team can still open them to look)

alter function public.loyalty_dashboard() rename to _loyalty_dashboard_impl;
create or replace function public.loyalty_dashboard() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._feature_on('points') and not coalesce(public.is_staff(), false) then raise exception 'FEATURE_OFF'; end if;
  return public._loyalty_dashboard_impl();
end $$;
alter function public.loyalty_claim(text) rename to _loyalty_claim_impl;
create or replace function public.loyalty_claim(p_mission text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._feature_on('points') then raise exception 'FEATURE_OFF'; end if;
  return public._loyalty_claim_impl(p_mission);
end $$;
alter function public.loyalty_open_vault() rename to _loyalty_open_vault_impl;
create or replace function public.loyalty_open_vault() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._feature_on('points') then raise exception 'FEATURE_OFF'; end if;
  return public._loyalty_open_vault_impl();
end $$;
revoke all on function public._loyalty_dashboard_impl() from public, anon, authenticated;
revoke all on function public._loyalty_claim_impl(text) from public, anon, authenticated;
revoke all on function public._loyalty_open_vault_impl() from public, anon, authenticated;
revoke all on function public.loyalty_dashboard() from public, anon;
revoke all on function public.loyalty_claim(text) from public, anon;
revoke all on function public.loyalty_open_vault() from public, anon;
grant execute on function public.loyalty_dashboard() to authenticated;
grant execute on function public.loyalty_claim(text) to authenticated;
grant execute on function public.loyalty_open_vault() to authenticated;
