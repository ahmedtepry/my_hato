-- Keeps the project inside the Free plan for good (500 MB database, 1 GB files):
--   * daily usage snapshot + an alert to the owner at 70% / 90% of either limit
--   * old photos are listed here and deleted by the "maintenance" Edge Function through the Storage API
--     (deleting storage.objects rows with SQL leaves the files behind and they keep counting)
--   * old log rows are pruned
-- Retention: repair photos 90 days after the repair is closed, transfer proofs 60 days, support attachments 180 days,
-- replaced avatars and files nothing points to after 7 days.

create table if not exists public.usage_snapshots (
  day date primary key,
  db_bytes bigint not null,
  storage_bytes bigint not null,
  buckets jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.usage_snapshots enable row level security;

create table if not exists public.maintenance_runs (
  id bigint generated always as identity primary key,
  ran_at timestamptz not null default now(),
  files_removed int not null default 0,
  bytes_freed bigint not null default 0,
  rows_pruned int not null default 0,
  details jsonb not null default '{}'::jsonb
);
alter table public.maintenance_runs enable row level security;

create or replace function public._usage_limits() returns jsonb language sql immutable as $$
  select jsonb_build_object('db', 500::bigint * 1024 * 1024, 'storage', 1024::bigint * 1024 * 1024)
$$;

-- Files that can go. Called by the maintenance Edge Function (service role only).
create or replace function public.storage_cleanup_candidates(p_limit int default 500)
returns table(bucket text, path text, bytes bigint, reason text)
language sql security definer set search_path = public, storage as $$
  with c as (
    -- photos of repairs closed more than 90 days ago
    select 'repair-photos'::text b, a.storage_path p, 'repair_closed_90d'::text r
      from public.repair_attachments a join public.repair_requests q on q.id = a.repair_id
     where q.status::text in ('delivered', 'cancelled', 'unrepairable')
       and coalesce(q.closed_at, q.updated_at) < now() - interval '90 days'
    union all
    -- wallet transfer screenshots after 60 days
    select 'transfer-proofs', t.proof_path, 'proof_60d'
      from public.order_wallet_transfers t
     where t.proof_path is not null and coalesce(t.confirmed_at, t.created_at) < now() - interval '60 days'
    union all
    -- support chat attachments after 180 days
    select 'support-chat', m.attachment_path, 'support_180d'
      from public.support_messages m
     where m.attachment_path is not null and m.created_at < now() - interval '180 days'
    union all
    -- files nothing points to any more (replaced avatars, removed product pictures, abandoned uploads)
    select o.bucket_id, o.name, 'orphan_7d'
      from storage.objects o
     where o.created_at < now() - interval '7 days'
       and (
         (o.bucket_id = 'repair-photos' and not exists (select 1 from public.repair_attachments a where a.storage_path = o.name))
      or (o.bucket_id = 'transfer-proofs' and not exists (select 1 from public.order_wallet_transfers t where t.proof_path = o.name))
      or (o.bucket_id = 'avatars' and not exists (select 1 from public.profiles pr where pr.avatar_path = o.name))
      or (o.bucket_id = 'product-images' and not exists (select 1 from public.product_images pi where pi.storage_path = o.name))
       )
  )
  select c.b, c.p, coalesce((o.metadata->>'size')::bigint, 0), c.r
    from c join storage.objects o on o.bucket_id = c.b and o.name = c.p
   limit greatest(1, least(p_limit, 2000));
$$;

-- After the Edge Function removed the files: drop what pointed to them.
create or replace function public.storage_cleanup_done(p_bucket text, p_paths text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_bucket = 'repair-photos' then
    delete from public.repair_attachments where storage_path = any(p_paths);
  elsif p_bucket = 'transfer-proofs' then
    update public.order_wallet_transfers set proof_path = null where proof_path = any(p_paths);
  elsif p_bucket = 'support-chat' then
    update public.support_messages set attachment_path = null where attachment_path = any(p_paths);
  end if;
end $$;

-- Old log rows (nothing a person needs to look back at).
create or replace function public.prune_logs() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; k int;
begin
  delete from public.auth_login_attempts where created_at < now() - interval '30 days'; get diagnostics k = row_count; n := n + k;
  delete from public.notification_delivery_logs where created_at < now() - interval '90 days'; get diagnostics k = row_count; n := n + k;
  delete from public.rate_limits where window_start < now() - interval '2 days'; get diagnostics k = row_count; n := n + k;
  delete from public.client_errors where created_at < now() - interval '60 days'; get diagnostics k = row_count; n := n + k;
  delete from public.repair_lookup_challenges where created_at < now() - interval '7 days'; get diagnostics k = row_count; n := n + k;
  delete from public.notifications where (cleared_at is not null and cleared_at < now() - interval '30 days')
                                        or (expires_at is not null and expires_at < now() - interval '30 days')
                                        or created_at < now() - interval '365 days'; get diagnostics k = row_count; n := n + k;
  delete from public.usage_snapshots where day < current_date - 400; get diagnostics k = row_count; n := n + k;
  delete from public.maintenance_runs where ran_at < now() - interval '400 days'; get diagnostics k = row_count; n := n + k;
  return n;
end $$;

-- Daily snapshot + owner alert at 70% and 90%.
create or replace function public.usage_check() returns jsonb
language plpgsql security definer set search_path = public, storage as $$
declare v_db bigint; v_st bigint; v_b jsonb; lim jsonb := public._usage_limits(); p_db numeric; p_st numeric; v_top numeric; v_lvl int; v_prev int;
begin
  v_db := pg_database_size(current_database());
  select coalesce(sum((metadata->>'size')::bigint), 0) into v_st from storage.objects;
  select coalesce(jsonb_object_agg(bucket_id, s), '{}'::jsonb) into v_b
    from (select bucket_id, sum((metadata->>'size')::bigint) s from storage.objects group by 1) x;
  insert into public.usage_snapshots(day, db_bytes, storage_bytes, buckets) values (current_date, v_db, v_st, v_b)
    on conflict (day) do update set db_bytes = excluded.db_bytes, storage_bytes = excluded.storage_bytes, buckets = excluded.buckets, created_at = now();
  p_db := round(100.0 * v_db / (lim->>'db')::bigint, 1);
  p_st := round(100.0 * v_st / (lim->>'storage')::bigint, 1);
  v_top := greatest(p_db, p_st);
  v_lvl := case when v_top >= 90 then 90 when v_top >= 70 then 70 else 0 end;
  -- alert once per level per week
  select coalesce(max((details->>'alert_level')::int), 0) into v_prev from public.maintenance_runs
   where ran_at > now() - interval '7 days' and details ? 'alert_level';
  if v_lvl > 0 and v_lvl > v_prev then
    perform public._notify_staff('staff.manage',
      'تنبيه مساحة السيرفر ' || v_lvl || '٪',
      'Server space at ' || v_lvl || '%',
      'قاعدة البيانات ' || p_db || '٪ · الملفات ' || p_st || '٪ من الحد المجاني. افتح «استهلاك السيرفر» في البرنامج.',
      'Database ' || p_db || '% · files ' || p_st || '% of the free plan. Open "Server usage" in the app.',
      null);
    insert into public.maintenance_runs(details) values (jsonb_build_object('alert_level', v_lvl, 'db_pct', p_db, 'storage_pct', p_st));
  end if;
  return jsonb_build_object('db_bytes', v_db, 'storage_bytes', v_st, 'db_pct', p_db, 'storage_pct', p_st);
end $$;

-- For the owner's "Server usage" card in the Windows app.
create or replace function public.server_usage() returns jsonb
language plpgsql stable security definer set search_path = public, storage as $$
declare lim jsonb := public._usage_limits(); v_db bigint; v_st bigint; v_b jsonb;
begin
  if not public.has_permission('staff.manage') then raise exception 'FORBIDDEN'; end if;
  v_db := pg_database_size(current_database());
  select coalesce(sum((metadata->>'size')::bigint), 0) into v_st from storage.objects;
  select coalesce(jsonb_object_agg(bucket_id, s), '{}'::jsonb) into v_b
    from (select bucket_id, sum((metadata->>'size')::bigint) s from storage.objects group by 1) x;
  return jsonb_build_object(
    'db_bytes', v_db, 'db_limit', (lim->>'db')::bigint,
    'storage_bytes', v_st, 'storage_limit', (lim->>'storage')::bigint,
    'buckets', v_b,
    'history', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'db', db_bytes, 'storage', storage_bytes) order by day)
                           from public.usage_snapshots where day > current_date - 60), '[]'::jsonb),
    'last_cleanup', (select jsonb_build_object('at', ran_at, 'files', files_removed, 'bytes', bytes_freed, 'rows', rows_pruned)
                       from public.maintenance_runs where not (details ? 'alert_level') order by ran_at desc limit 1));
end $$;

-- Written by the maintenance Edge Function at the end of each run.
create or replace function public.maintenance_record(p_files int, p_bytes bigint, p_rows int, p_details jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.maintenance_runs(files_removed, bytes_freed, rows_pruned, details) values (p_files, p_bytes, p_rows, coalesce(p_details, '{}'::jsonb));
$$;

revoke all on function public.storage_cleanup_candidates(int) from public, anon, authenticated;
revoke all on function public.storage_cleanup_done(text, text[]) from public, anon, authenticated;
revoke all on function public.prune_logs() from public, anon, authenticated;
revoke all on function public.usage_check() from public, anon, authenticated;
revoke all on function public.maintenance_record(int, bigint, int, jsonb) from public, anon, authenticated;
revoke all on function public._usage_limits() from public, anon, authenticated;
grant execute on function public.storage_cleanup_candidates(int), public.storage_cleanup_done(text, text[]), public.prune_logs(),
  public.usage_check(), public.maintenance_record(int, bigint, int, jsonb) to service_role;
revoke all on function public.server_usage() from public, anon;
grant execute on function public.server_usage() to authenticated;

-- The nightly cron calls the maintenance Edge Function with a random key kept in Vault; the function asks this to check it.
create or replace function public.maintenance_key_ok(p_key text) returns boolean
language sql stable security definer set search_path = public, vault as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'maintenance_key' and decrypted_secret = p_key and length(p_key) >= 32)
$$;
revoke all on function public.maintenance_key_ok(text) from public, anon, authenticated;
grant execute on function public.maintenance_key_ok(text) to service_role;
