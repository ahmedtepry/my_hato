-- Defence in depth. RLS already blocks these, but the grants should not exist at all.
-- 1) the public (not-logged-in) role never writes tables directly: all its writes go through SECURITY DEFINER functions
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','v','m','p','f') loop
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from anon', r.relname);
    execute format('revoke truncate, references, trigger on public.%I from authenticated', r.relname);
  end loop;
  -- anon may READ only tables that have an anon-readable policy (catalogue) and views; nothing else
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p')
              and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname and 'anon' = any(p.roles)) loop
    execute format('revoke select on public.%I from anon', r.relname);
  end loop;
end $$;
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from anon;
