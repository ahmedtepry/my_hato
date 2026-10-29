-- 0089: the winners of a contest. The owner (contest.manage) sees who they are (phone, email, their score) and what they have bought from the shop
-- (online orders and counter sales linked to their account), and sends each winner a direct notification: "come and take your gift" or "we will send it".

-- the contests list also shows how many winners each one has
create or replace function public.contest_admin_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('contest.manage');
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select c.id, c.title, c.audience, c.status, c.duration_minutes, c.answer_seconds, c.winners_count, c.prize, c.starts_at, c.ends_at, c.announced_at, c.created_at,
      case when c.status = 'live' and now() < c.ends_at then 'running' when c.status = 'live' then 'ended' else c.status end as state,
      (select count(*) from public.contest_questions q where q.contest_id = c.id) as questions,
      (select count(*) from public.contest_entries e where e.contest_id = c.id) as entries,
      (select count(*) from public.contest_entries e where e.contest_id = c.id and e.submitted_at is not null) as submitted,
      (select count(*) from public.contest_entries e where e.contest_id = c.id and e.is_winner) as winners
    from public.contests c order by c.created_at desc limit 100) x), '[]'::jsonb);
end $$;
revoke all on function public.contest_admin_list() from public, anon;
grant execute on function public.contest_admin_list() to authenticated;

create or replace function public.contest_winners(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.require_permission('contest.manage');
  if not exists (select 1 from public.contests where id = p_id) then raise exception 'NOT_FOUND'; end if;
  select coalesce(jsonb_agg(x order by x.correct_count desc, x.seconds asc nulls last), '[]'::jsonb) into v from (
    select e.id as entry_id, e.user_id,
           coalesce(nullif(btrim(p.full_name), ''), p.email, p.phone, 'عميل') as name, p.phone, p.email,
           public._contest_is_team(e.user_id) as is_team, e.correct_count, e.graded_total, e.answers,
           case when e.submitted_at is not null then extract(epoch from (e.submitted_at - e.started_at))::int end as seconds,
           (select count(*) from public.orders o where o.customer_id = e.user_id and o.status <> 'cancelled') as orders_count,
           (select coalesce(sum(o.total_minor), 0) from public.orders o where o.customer_id = e.user_id and o.status <> 'cancelled') as orders_total_minor,
           (select count(*) from public.pos_sales s where s.customer_id = e.user_id) as shop_count,
           (select coalesce(sum(s.total_minor - s.refunded_minor), 0) from public.pos_sales s where s.customer_id = e.user_id) as shop_total_minor,
           (select jsonb_agg(t order by t.when_at desc) from (
              select 'online' as kind, o.reference as ref, o.status::text as status, o.total_minor as amount_minor, o.created_at as when_at
                from public.orders o where o.customer_id = e.user_id
              union all
              select 'shop', s.number, case when s.refunded_minor > 0 then 'partly_refunded' else 'paid' end, s.total_minor - s.refunded_minor, s.created_at
                from public.pos_sales s where s.customer_id = e.user_id
              order by when_at desc limit 15) t) as recent
      from public.contest_entries e left join public.profiles p on p.id = e.user_id
     where e.contest_id = p_id and e.is_winner) x;
  return v;
end $$;
revoke all on function public.contest_winners(uuid) from public, anon;
grant execute on function public.contest_winners(uuid) to authenticated;

-- a direct notification to one winner. p_mode: 'pickup' (come and take it from the shop), 'delivery' (we will send it) or 'custom' (p_text only).
-- p_text is extra text added after the standard sentence (or the whole message for 'custom').
create or replace function public.contest_message_winner(p_entry uuid, p_mode text, p_text text default null) returns void
language plpgsql security definer set search_path = public as $$
declare e public.contest_entries; c public.contests; v_prize text; v_body text; v_extra text := nullif(btrim(coalesce(p_text, '')), '');
begin
  perform public.require_permission('contest.manage');
  if p_mode not in ('pickup', 'delivery', 'custom') or (v_extra is not null and char_length(v_extra) > 400) or (p_mode = 'custom' and v_extra is null) then
    raise exception 'INVALID_INPUT';
  end if;
  select * into e from public.contest_entries where id = p_entry;
  if not found or not e.is_winner then raise exception 'NOT_FOUND'; end if;
  select * into c from public.contests where id = e.contest_id;
  if (select count(*) from public.audit_logs where action = 'contest.message' and entity_id = p_entry::text and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'RATE_LIMITED';
  end if;
  v_prize := coalesce(c.prize, 'جايزة المسابقة');
  v_body := case p_mode
    when 'pickup' then 'مبروك! كسبت ' || v_prize || ' في مسابقة «' || c.title || '». تعالى استلمها من المحل في أي وقت.'
    when 'delivery' then 'مبروك! كسبت ' || v_prize || ' في مسابقة «' || c.title || '». هنبعتهالك ونكلّمك قبل ما توصلك.'
    else v_extra end;
  if p_mode <> 'custom' and v_extra is not null then v_body := v_body || ' ' || v_extra; end if;
  perform public.notify_user(e.user_id, '🏆 رسالة عن جايزتك', '🏆 About your prize', v_body, v_body, 'system', null, null, '/');
  perform public.audit_write('contest.message', 'contest_entry', p_entry::text, jsonb_build_object('mode', p_mode, 'contest', c.id));
end $$;
revoke all on function public.contest_message_winner(uuid, text, text) from public, anon;
grant execute on function public.contest_message_winner(uuid, text, text) to authenticated;
