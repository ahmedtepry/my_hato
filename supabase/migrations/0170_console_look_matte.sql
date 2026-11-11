-- 0170: the matte black console look ("matte") is a valid choice for console_look_set.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.console_look_set(text,boolean)'::regprocedure);
  if position($q$'royal')$q$ in d) = 0 then raise exception 'patch miss'; end if;
  execute replace(d, $q$'royal')$q$, $q$'royal','matte')$q$);
end $$;
