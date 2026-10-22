\set ON_ERROR_STOP 1
\echo 'W01 email worker: claim, fail with backoff, retry, succeed; never duplicates'
do $$ declare r record; n int; begin
  perform t.reset();
  select count(*) into n from public.claim_email_batch(50);
  if n < 3 then raise exception 'W01 expected queued emails, got %', n; end if;
  for r in select * from public.email_outbox where status = 'sending' loop
    perform public.complete_email(r.id, false, null, 'smtp down');
  end loop;
  if exists (select 1 from public.claim_email_batch(50)) then raise exception 'W01 retried before backoff'; end if;
  update public.email_outbox set next_attempt_at = now() - interval '1 second';
  for r in select * from public.claim_email_batch(50) loop
    perform public.complete_email(r.id, true, 'prov-' || r.id, null);
  end loop;
  if exists (select 1 from public.email_outbox where status <> 'sent') then raise exception 'W01 not all sent'; end if;
  if (select count(*) from public.email_outbox) <> (select count(distinct (kind, related_id)) from public.email_outbox) then raise exception 'W01 dup'; end if;
end $$;
\echo 'W02 render data for order and repair emails'
do $$ declare j jsonb; begin
  j := public.email_render_data('order_new', jsonb_build_object('order_id', (select v from t.ids where k='order1')));
  if jsonb_array_length(j->'items') <> 2 or j->>'reference' is null then raise exception 'W02 order'; end if;
  j := public.email_render_data('repair_new', jsonb_build_object('repair_id', (select v from t.ids where k='repair1')));
  if j->>'reference' not like 'MY-HATO%' or j ? 'internal_notes' then raise exception 'W02 repair'; end if;
end $$;
\echo 'W03 worker functions not callable by customers'
do $$ begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  begin perform public.claim_email_batch(1); raise exception 'W03';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;
\echo 'ALL WORKER TESTS PASSED'
