-- 0035 Read receipts for staff: when a customer opens a notification about an order or repair
-- (notifications.read_at), the team sees it on that order/repair ("seen ✓✓" with the time).
create or replace function public.staff_entity_seen(p_type text, p_id uuid)
returns table (title_ar text, title_en text, created_at timestamptz, read_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  return query
    select n.title_ar, n.title_en, n.created_at, n.read_at
      from public.notifications n
     where n.entity_type = p_type and n.entity_id = p_id
     order by n.created_at desc
     limit 5;
end $$;
revoke all on function public.staff_entity_seen(text, uuid) from public, anon;
grant execute on function public.staff_entity_seen(text, uuid) to authenticated;
