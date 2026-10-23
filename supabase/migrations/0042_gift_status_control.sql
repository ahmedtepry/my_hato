-- 0042: the owner controls each gift code from the app: status the customer sees
-- (waiting -> code received -> we are preparing it -> ready -> delivered), an optional custom message, and WHO may do it
-- (new permission gifts.manage: the owner has it and can give it to a role or one account from the permissions screen).
-- The customer gets an in-app notification whenever the status changes.

insert into public.role_permissions (role, permission) values ('owner', 'gifts.manage') on conflict do nothing;
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('gifts.manage', 'system', 'يدير هدايا المكافآت', 'Manage reward gifts', 'يشوف كودات الهدايا ويغيّر حالتها ويسلّمها للعملاء', 'Sees gift codes, changes their status and hands them over', false, false, 45)
on conflict (permission) do nothing;

create table if not exists public.loyalty_gift_status (        -- wording the customer sees; edit any time
  key text primary key, ar text not null, en text not null, sort int not null
);
alter table public.loyalty_gift_status enable row level security;
revoke all on public.loyalty_gift_status from anon, authenticated;
insert into public.loyalty_gift_status (key, ar, en, sort) values
 ('new','انسخ الكود وابعتهولنا واكتب: «اسأل عن هديتي»','Copy the code, send it to us and write: "asking about my gift"',1),
 ('code_received','وصلنا الكود بتاعك ✅','We received your code ✅',2),
 ('preparing','هنجهزلك هديتك 🎁','We are preparing your gift 🎁',3),
 ('ready','هديتك جاهزة، تعالى استلمها 🎉','Your gift is ready, come and collect it 🎉',4),
 ('delivered','تم استلام الهدية ✅','Gift received ✅',5)
on conflict (key) do nothing;

alter table public.loyalty_awards add column if not exists status text not null default 'new' references public.loyalty_gift_status(key);
alter table public.loyalty_awards add column if not exists status_note_ar text, add column if not exists status_note_en text;
update public.loyalty_awards set status = 'delivered' where delivered_at is not null and status = 'new';

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
                  'code', a.code, 'awarded_at', a.awarded_at, 'new', a.seen_at is null, 'status', a.status, 'delivered', a.status = 'delivered',
                  'status_ar', coalesce(a.status_note_ar, t.ar), 'status_en', coalesce(a.status_note_en, a.status_note_ar, t.en),
                  'prize_ar', case when a.revealed_at is not null then a.prize_ar end, 'prize_en', case when a.revealed_at is not null then a.prize_en end)
                  order by a.level_sort), '[]')
               from public.loyalty_awards a join public.loyalty_levels l on l.sort = a.level_sort
               join public.loyalty_gift_status t on t.key = a.status where a.user_id = u),
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

create or replace function public.owner_loyalty_overview() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('gifts.manage');
  return jsonb_build_object(
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'level_sort', a.level_sort, 'level_ar', l.name_ar, 'level_en', l.name_en,
                  'plan_ar', l.plan_ar, 'customer', coalesce(nullif(pr.full_name, ''), pr.email), 'email', pr.email, 'points', lp.points,
                  'awarded_at', a.awarded_at, 'prize_ar', a.prize_ar, 'prize_en', a.prize_en, 'revealed', a.revealed_at is not null,
                  'status', a.status, 'note_ar', a.status_note_ar, 'note_en', a.status_note_en, 'delivered', a.status = 'delivered')
                  order by a.status = 'delivered', a.awarded_at desc), '[]')
               from (select * from public.loyalty_awards order by awarded_at desc limit 300) a
               join public.loyalty_levels l on l.sort = a.level_sort
               left join public.profiles pr on pr.id = a.user_id left join public.loyalty_profiles lp on lp.user_id = a.user_id),
    'statuses', (select coalesce(jsonb_agg(to_jsonb(t) order by t.sort), '[]') from public.loyalty_gift_status t),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('customer', coalesce(nullif(pr.full_name, ''), pr.email), 'email', pr.email, 'points', lp.points,
                  'level_ar', (select name_ar from public.loyalty_levels x where x.min_points <= lp.points order by x.sort desc limit 1)) order by lp.points desc), '[]')
               from (select * from public.loyalty_profiles order by points desc limit 100) lp left join public.profiles pr on pr.id = lp.user_id),
    -- thresholds stay with the real owner only
    'levels', case when public.has_permission('permissions.manage')
                   then (select coalesce(jsonb_agg(to_jsonb(l) order by l.sort), '[]') from public.loyalty_levels l) else '[]'::jsonb end);
end $$;

drop function if exists public.owner_loyalty_set_award(text, text, text, boolean, boolean);
create or replace function public.owner_loyalty_set_award(p_code text, p_prize_ar text, p_prize_en text, p_reveal boolean,
                                                          p_status text, p_note_ar text, p_note_en text)
returns void language plpgsql security definer set search_path = public as $$
declare a public.loyalty_awards%rowtype; v_msg_ar text; v_msg_en text;
begin
  perform public.require_permission('gifts.manage');
  select * into a from public.loyalty_awards where code = upper(trim(p_code)) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.status = 'delivered' then raise exception 'ALREADY_DELIVERED'; end if;   -- a code works once: after delivery it is locked for good
  if not exists (select 1 from public.loyalty_gift_status where key = p_status) then raise exception 'INVALID_INPUT'; end if;
  if length(coalesce(p_prize_ar, '')) > 120 or length(coalesce(p_prize_en, '')) > 120
     or length(coalesce(p_note_ar, '')) > 200 or length(coalesce(p_note_en, '')) > 200 then raise exception 'INVALID_INPUT'; end if;
  if p_reveal and nullif(trim(coalesce(p_prize_ar, '')), '') is null then raise exception 'INVALID_INPUT'; end if;
  update public.loyalty_awards set
    prize_ar = nullif(trim(coalesce(p_prize_ar, '')), ''), prize_en = nullif(trim(coalesce(p_prize_en, '')), ''),
    revealed_at = case when p_reveal then coalesce(revealed_at, now()) else null end,
    status = p_status,
    status_note_ar = nullif(trim(coalesce(p_note_ar, '')), ''), status_note_en = nullif(trim(coalesce(p_note_en, '')), ''),
    delivered_at = case when p_status = 'delivered' then coalesce(delivered_at, now()) else null end
   where code = a.code;
  if p_status <> a.status and p_status <> 'new' then       -- tell the customer when the status moves
    select coalesce(nullif(trim(coalesce(p_note_ar, '')), ''), t.ar), coalesce(nullif(trim(coalesce(p_note_en, '')), ''), t.en)
      into v_msg_ar, v_msg_en from public.loyalty_gift_status t where t.key = p_status;
    perform public.notify_user(a.user_id, 'هديتك 🎁', 'Your gift 🎁', v_msg_ar, v_msg_en, 'promo', null, a.code, '/loyalty');
  end if;
  perform public.audit_write('loyalty.award', 'loyalty_award', a.code,
    jsonb_build_object('level', a.level_sort, 'status', p_status, 'revealed', p_reveal, 'prize', p_prize_ar));
end $$;

-- Codes: one per customer per level, never reused, drawn from the database's strong random source (19^12 combinations),
-- readable only by their owner and by people holding gifts.manage. There is no lookup endpoint, so codes cannot be guessed or probed.
create or replace function public._loy_gift_code() returns text language plpgsql volatile as $$
declare a constant text := 'BCDFGHJKMNPQRSTVWXZ'; c text; b bytea;
begin
  loop
    b := decode(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'hex');   -- 32 strong random bytes
    c := '';
    for i in 0..11 loop
      c := c || substr(a, 1 + (get_byte(b, i) % length(a)), 1);
      if i in (3, 7) then c := c || '-'; end if;
    end loop;
    exit when not exists (select 1 from public.loyalty_awards where code = c);
  end loop;
  return c;
end $$;
revoke all on function public._loy_gift_code() from public, anon, authenticated;
alter policy own_read on public.loyalty_awards using (user_id = auth.uid() or public.has_permission('gifts.manage'));

revoke all on function public.loyalty_dashboard(), public.owner_loyalty_overview(),
  public.owner_loyalty_set_award(text, text, text, boolean, text, text, text) from public, anon;
grant execute on function public.loyalty_dashboard(), public.owner_loyalty_overview(),
  public.owner_loyalty_set_award(text, text, text, boolean, text, text, text) to authenticated;
