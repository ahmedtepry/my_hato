-- 0048: the rewards page shows the customer's level journey instead of the box.
-- loyalty_dashboard now also returns 'levels': every level with its state (passed / current / locked).
-- Names are sent only for levels already reached, so the next levels and all point thresholds stay secret.
-- (The box and its points keep working in the database but the app no longer shows them.)

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
    -- the journey: names appear only for the levels already reached; the next ones stay hidden (no names, no points)
    'levels', (select coalesce(jsonb_agg(jsonb_build_object('sort', l.sort,
                  'state', case when l.min_points > p.points then 'locked'
                                when l.sort = (select max(x.sort) from public.loyalty_levels x where x.min_points <= p.points) then 'current' else 'passed' end,
                  'name_ar', case when l.min_points <= p.points then l.name_ar end,
                  'name_en', case when l.min_points <= p.points then l.name_en end) order by l.sort), '[]')
               from public.loyalty_levels l),
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('level_sort', a.level_sort, 'name_ar', l.name_ar, 'name_en', l.name_en,
                  'code', a.code, 'awarded_at', a.awarded_at, 'new', a.seen_at is null, 'status', a.status, 'delivered', a.status = 'delivered',
                  'status_ar', coalesce(a.status_note_ar, t.ar), 'status_en', coalesce(a.status_note_en, a.status_note_ar, t.en),
                  'prize_ar', case when a.revealed_at is not null then a.prize_ar end, 'prize_en', case when a.revealed_at is not null then a.prize_en end)
                  order by a.level_sort), '[]')
               from public.loyalty_awards a join public.loyalty_levels l on l.sort = a.level_sort
               join public.loyalty_gift_status t on t.key = a.status where a.user_id = u),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'title_ar', m.title_ar, 'title_en', m.title_en,
                     'desc_ar', public._loy_text(m.desc_ar, m.points), 'desc_en', public._loy_text(m.desc_en, m.points), 'icon', m.icon, 'points', public._loy_scale(m.points),
                     'repeat', m.repeat,
                     'kind', m.kind,
                     'status', case when m.kind = 'review' then 'auto' when exists (select 1 from public.loyalty_claims c where c.user_id = u and c.mission_key = m.key and c.period_key = public._loy_period(m.repeat))
                                    then 'claimed' when public._loy_cond(u, m.kind, m.repeat) then 'ready' else 'todo' end) order by m.sort), '[]')
                 from public.loyalty_missions m where m.is_active),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('points', l.points, 'at', l.created_at) order by l.created_at desc), '[]')
                from (select points, created_at from public.loyalty_ledger where user_id = u and kind = 'vault_reward'
                      order by created_at desc limit 30) l));
end $$;
revoke all on function public.loyalty_dashboard() from public, anon;
grant execute on function public.loyalty_dashboard() to authenticated;
