-- 0179: closing a shift by face. A successful "is this really me" face check stands in for the password once
-- (see 0180 for the time window). The match threshold is set for the SFace model (cosine distance 0.52 = similarity 0.48).
-- _face_match now records whom it matched (staff_face_tries.target); pos_close_shift accepts an empty password
-- only when _face_recent_self() finds (and uses up) such a self-match.
alter table public.staff_face_tries add column if not exists target uuid;
-- _face_match: as in 0177, plus: insert into public.staff_face_tries (caller, ok, target) values (p_caller, true, v_user);
--              and a default threshold of 0.52. (Applied live; see the function in the database.)
do $$
declare d text;
begin
  d := pg_get_functiondef('public._face_match(uuid,text,text,uuid[])'::regprocedure);
  d := replace(d, 'insert into public.staff_face_tries (caller, ok) values (p_caller, true);', 'insert into public.staff_face_tries (caller, ok, target) values (p_caller, true, v_user);');
  d := replace(d, '''face_match''), 0.40)', '''face_match''), 0.52)');
  execute d;
  d := pg_get_functiondef('public.pos_close_shift(uuid,bigint,text,text,text,bigint,bigint)'::regprocedure);
  if position('_face_recent_self' in d) = 0 then
    d := replace(d, 'if not public._confirm_my_password(p_password) then',
                    'if not (public._confirm_my_password(p_password) or (coalesce(p_password, '''') = '''' and public._face_recent_self())) then');
    execute d;
  end if;
end $$;
insert into public.application_settings (key, value, updated_at) values ('face_match', '{"threshold": 0.52}', now()) on conflict (key) do nothing;
