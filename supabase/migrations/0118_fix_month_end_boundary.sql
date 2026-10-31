-- 0118: the monthly reports (accountant month files and the Online report) cut the LAST DAY of every month: "first of month (Cairo) + 1 month" was computed in the UTC session
-- zone. Now the end of the month is the first of the next month at 00:00 Cairo.
do $$
declare f text; d text; old text := 'v_to := v_from + interval ''1 month'';';
  new text := 'v_to := make_timestamptz(extract(year from ((v_from at time zone ''Africa/Cairo'') + interval ''1 month''))::int, extract(month from ((v_from at time zone ''Africa/Cairo'') + interval ''1 month''))::int, 1, 0, 0, 0, ''Africa/Cairo'');';
begin
  foreach f in array array['public.assistant_month_report(integer, integer)', 'public.online_report(integer, integer)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position(old in d) = 0 then raise exception 'pattern not found in %', f; end if;
    execute replace(d, old, new);
  end loop;
end $$;
