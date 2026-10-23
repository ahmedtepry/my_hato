-- 0041: the next reward box starts again from 0% after one is opened, and the app gets the number of boxes opened
-- (the phone on screen changes its look with each box). Delta on top of 0040.
create or replace function public.loyalty_dashboard() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); p public.loyalty_profiles%rowtype; v_req int := public._loy_num('loyalty_vault_required', 100)::int;
begin
  perform public._loy_ensure(u);
  perform public._loy_sync_orders(u);
  select * into p from public.loyalty_profiles where user_id = u;
  insert into public.loyalty_awards (user_id, level_sort, code)
    select u, l.sort, public._loy_gift_code()
      from public.loyalty_levels l where l.min_points <= p.points and l.sort > 1
    on conflict do nothing;
  return jsonb_build_object(
    'points', p.points, 'streak', p.streak, 'boxes_opened', (select count(*) from public.loyalty_ledger where user_id = u and kind = 'vault_reward'), 'vault_progress', p.vault_progress, 'vault_required', v_req,
    'level', (select jsonb_build_object('sort', l.sort, 'name_ar', l.name_ar, 'name_en', l.name_en) from public.loyalty_levels l where l.min_points <= p.points order by l.sort desc limit 1),
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('level_sort', a.level_sort, 'name_ar', l.name_ar, 'name_en', l.name_en,
                  'code', a.code, 'awarded_at', a.awarded_at, 'new', a.seen_at is null, 'delivered', a.delivered_at is not null,
                  'prize_ar', case when a.revealed_at is not null then a.prize_ar end, 'prize_en', case when a.revealed_at is not null then a.prize_en end)
                  order by a.level_sort), '[]')
               from public.loyalty_awards a join public.loyalty_levels l on l.sort = a.level_sort where a.user_id = u),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'title_ar', m.title_ar, 'title_en', m.title_en,
                     'desc_ar', m.desc_ar, 'desc_en', m.desc_en, 'icon', m.icon, 'points', m.points,
                     'repeat', m.repeat,
                     'kind', m.kind,
                     'status', case when m.kind = 'review' then 'auto' when exists (select 1 from public.loyalty_claims c where c.user_id = u and c.mission_key = m.key and c.period_key = public._loy_period(m.repeat))
                                    then 'claimed' when public._loy_cond(u, m.kind, m.repeat) then 'ready' else 'todo' end) order by m.sort), '[]')
                 from public.loyalty_missions m where m.is_active),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('points', l.points, 'at', l.created_at) order by l.created_at desc), '[]')
                from (select points, created_at from public.loyalty_ledger where user_id = u and kind = 'vault_reward'
                      order by created_at desc limit 30) l));
end $$;

create or replace function public.loyalty_open_vault() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); p public.loyalty_profiles%rowtype; v_req int := public._loy_num('loyalty_vault_required', 100)::int;
        r public.loyalty_rewards%rowtype; v_ref text := gen_random_uuid()::text;
begin
  perform public._loy_ensure(u);
  select * into p from public.loyalty_profiles where user_id = u for update;      -- a second tap waits here, then sees the lower progress
  if p.vault_progress < v_req then raise exception 'VAULT_NOT_READY'; end if;
  select * into r from public.loyalty_rewards where is_active and (stock is null or stock > 0)
    order by -ln(greatest(random(), 1e-12)) / weight limit 1 for update skip locked;
  if not found then raise exception 'REWARD_UNAVAILABLE'; end if;                 -- progress is kept
  if r.stock is not null then update public.loyalty_rewards set stock = stock - 1 where id = r.id; end if;
  perform public._loy_grant(u, 'vault_reward', v_ref, r.points, -p.vault_progress);   -- the next box starts again from 0%
  return jsonb_build_object('points', r.points);
end $$;

revoke all on function public.loyalty_dashboard(), public.loyalty_open_vault() from public, anon;
grant execute on function public.loyalty_dashboard(), public.loyalty_open_vault() to authenticated;
