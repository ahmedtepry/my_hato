-- Security advisor fixes (Nov 2026): the staff-code trigger function is not callable by clients, and four helper
-- functions get a fixed search_path. Applied live.
revoke all on function public._team_member_code() from public, anon, authenticated;
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p where p.pronamespace = 'public'::regnamespace
             and p.proname in ('_new_barcode', '_products_barcode_fill', '_cairo_day', '_warranty_months') loop
    execute format('alter function %s set search_path = public, extensions', r.sig);
  end loop;
end $$;
