-- ============================================================
-- 0010 — Live chat: customer <-> customer service only
-- Writes go through SECURITY DEFINER RPCs; tables are read-only via RLS.
-- Already applied to the live project (migration "support_live_chat_schema").
-- ============================================================

create table public.support_conversations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references auth.users(id) on delete cascade,
  subject text not null check (char_length(subject) between 3 and 200),
  status text not null default 'open' check (status in ('open','closed')),
  assigned_to uuid references auth.users(id) on delete set null,
  last_message_at timestamptz not null default now(),
  last_message_preview text,
  customer_unread integer not null default 0 check (customer_unread >= 0),
  staff_unread integer not null default 0 check (staff_unread >= 0),
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  close_reason text check (close_reason is null or char_length(close_reason) <= 300),
  rating smallint check (rating between 1 and 5),
  rating_comment text check (rating_comment is null or char_length(rating_comment) <= 500),
  rated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index support_conversations_one_open_per_customer
  on public.support_conversations (customer_id) where status = 'open';
create index support_conversations_customer_idx
  on public.support_conversations (customer_id, created_at desc);
create index support_conversations_inbox_idx
  on public.support_conversations (status, last_message_at desc);
create index support_conversations_assigned_idx
  on public.support_conversations (assigned_to) where assigned_to is not null;
create index support_conversations_closed_by_idx
  on public.support_conversations (closed_by) where closed_by is not null;

create trigger support_conversations_updated_at
  before update on public.support_conversations
  for each row execute function public.set_updated_at();

create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.support_conversations(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  sender_role text not null check (sender_role in ('customer','staff','system')),
  body text not null default '' check (char_length(body) <= 4000),
  attachment_path text,
  attachment_name text check (attachment_name is null or char_length(attachment_name) <= 200),
  attachment_mime text,
  attachment_size integer check (attachment_size is null or attachment_size between 1 and 10485760),
  client_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint support_messages_has_content check (
    char_length(btrim(body)) > 0 or attachment_path is not null or sender_role = 'system')
);

create index support_messages_conv_idx on public.support_messages (conversation_id, created_at);
create index support_messages_sender_idx on public.support_messages (sender_id) where sender_id is not null;
create unique index support_messages_client_dedupe
  on public.support_messages (conversation_id, client_id) where client_id is not null;

alter table public.support_conversations enable row level security;
alter table public.support_messages enable row level security;

revoke all on public.support_conversations, public.support_messages from anon, authenticated;
grant select on public.support_conversations, public.support_messages to authenticated;

-- ---------- access helpers ----------
create or replace function public.support_can_access(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.support_conversations c
    where c.id = p_conv
      and (c.customer_id = auth.uid() or public.has_permission('support.manage'))
  )
$$;

create or replace function public.support_can_access_text(p_id text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  begin v := p_id::uuid; exception when others then return false; end;
  return public.support_can_access(v);
end $$;

create or replace function public.support_can_access_topic(p_topic text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_topic is null or p_topic !~ '^support:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return public.support_can_access(substr(p_topic, 9)::uuid);
end $$;

create or replace function public.support_can_access_path(p_name text)
returns boolean language sql stable security definer set search_path = public, storage as $$
  select public.support_can_access_text((storage.foldername(p_name))[1])
$$;

-- ---------- RLS (read only) ----------
create policy support_conversations_read on public.support_conversations
  for select to authenticated
  using (customer_id = (select auth.uid()) or public.has_permission('support.manage'));

create policy support_messages_read on public.support_messages
  for select to authenticated
  using (public.support_can_access(conversation_id));

-- ---------- internal poster ----------
create or replace function public._support_post(
  p_conv uuid, p_sender uuid, p_role text, p_body text,
  p_att_path text, p_att_name text, p_att_mime text, p_att_size integer, p_client uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_conv public.support_conversations%rowtype;
  v_preview text;
  v_preview_en text;
  v_prev integer;
begin
  select * into v_conv from public.support_conversations where id = p_conv for update;
  if not found then raise exception 'conversation_not_found'; end if;

  insert into public.support_messages
    (conversation_id, sender_id, sender_role, body, attachment_path, attachment_name,
     attachment_mime, attachment_size, client_id)
  values (p_conv, p_sender, p_role, coalesce(btrim(p_body), ''), p_att_path, p_att_name,
          p_att_mime, p_att_size, p_client)
  on conflict (conversation_id, client_id) where client_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.support_messages
     where conversation_id = p_conv and client_id = p_client;
    return v_id;
  end if;

  if btrim(coalesce(p_body, '')) <> '' then
    v_preview := left(regexp_replace(btrim(p_body), '\s+', ' ', 'g'), 120);
    v_preview_en := v_preview;
  else
    v_preview := 'أرسل مرفقاً';
    v_preview_en := 'Sent an attachment';
  end if;

  if p_role = 'customer' then
    v_prev := v_conv.staff_unread;
    update public.support_conversations
       set staff_unread = staff_unread + 1, last_message_at = now(), last_message_preview = v_preview
     where id = p_conv;
    if v_prev = 0 then
      perform public._notify_staff('support.manage', 'رسالة جديدة من عميل', 'New customer message',
                                   v_preview, v_preview_en, left(v_conv.subject, 60));
    end if;
  elsif p_role = 'staff' then
    v_prev := v_conv.customer_unread;
    update public.support_conversations
       set customer_unread = customer_unread + 1, last_message_at = now(), last_message_preview = v_preview
     where id = p_conv;
    if v_prev = 0 then
      perform public.notify_user(v_conv.customer_id, 'رد جديد من خدمة العملاء',
        'New reply from Customer Support', v_preview, v_preview_en, 'system', p_conv,
        left(v_conv.subject, 60), '/support/chat/' || p_conv::text);
    end if;
  else
    update public.support_conversations set last_message_at = now() where id = p_conv;
  end if;

  return v_id;
end $$;

revoke all on function public._support_post(uuid, uuid, text, text, text, text, text, integer, uuid) from public, anon, authenticated;

-- ---------- public RPCs ----------
create or replace function public.support_start_conversation(
  p_subject text, p_message text, p_client_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_conv uuid; v_subject text := btrim(coalesce(p_subject, ''));
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if char_length(v_subject) < 3 or char_length(v_subject) > 200 then raise exception 'invalid_subject'; end if;
  if char_length(btrim(coalesce(p_message, ''))) < 1 or char_length(p_message) > 4000 then
    raise exception 'invalid_message';
  end if;

  select id into v_conv from public.support_conversations
   where customer_id = v_uid and status = 'open';

  if v_conv is null then
    begin
      insert into public.support_conversations (customer_id, subject)
      values (v_uid, v_subject) returning id into v_conv;
    exception when unique_violation then
      select id into v_conv from public.support_conversations
       where customer_id = v_uid and status = 'open';
    end;
  end if;

  perform public._support_post(v_conv, v_uid, 'customer', p_message, null, null, null, null, p_client_id);
  return v_conv;
end $$;

create or replace function public.support_send_message(
  p_conversation_id uuid, p_body text, p_client_id uuid default null,
  p_attachment_path text default null, p_attachment_name text default null,
  p_attachment_mime text default null, p_attachment_size integer default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_conv public.support_conversations%rowtype;
  v_role text;
  v_body text := btrim(coalesce(p_body, ''));
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;

  select * into v_conv from public.support_conversations where id = p_conversation_id;
  if not found then raise exception 'conversation_not_found'; end if;

  if v_conv.customer_id = v_uid then v_role := 'customer';
  elsif public.has_permission('support.manage') then v_role := 'staff';
  else raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_conv.status <> 'open' then raise exception 'conversation_closed'; end if;
  if char_length(v_body) > 4000 then raise exception 'message_too_long'; end if;
  if v_body = '' and p_attachment_path is null then raise exception 'empty_message'; end if;

  if (select count(*) from public.support_messages
       where sender_id = v_uid and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'rate_limited';
  end if;

  if p_attachment_path is not null then
    if p_attachment_path not like (p_conversation_id::text || '/%') then raise exception 'invalid_attachment'; end if;
    if coalesce(p_attachment_mime, '') not in
       ('image/jpeg','image/png','image/webp','image/heic','application/pdf') then
      raise exception 'invalid_attachment_type';
    end if;
    if not exists (select 1 from storage.objects
                    where bucket_id = 'support-chat' and name = p_attachment_path) then
      raise exception 'attachment_not_found';
    end if;
  end if;

  if v_role = 'staff' and v_conv.assigned_to is null then
    update public.support_conversations set assigned_to = v_uid where id = v_conv.id;
  end if;

  return public._support_post(v_conv.id, v_uid, v_role, v_body, p_attachment_path,
                              left(p_attachment_name, 200), p_attachment_mime, p_attachment_size, p_client_id);
end $$;

create or replace function public.support_mark_read(p_conversation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_conv public.support_conversations%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into v_conv from public.support_conversations where id = p_conversation_id;
  if not found then raise exception 'conversation_not_found'; end if;

  if v_conv.customer_id = v_uid then
    update public.support_messages set read_at = now()
     where conversation_id = v_conv.id and sender_role = 'staff' and read_at is null;
    update public.support_conversations set customer_unread = 0
     where id = v_conv.id and customer_unread <> 0;
  elsif public.has_permission('support.manage') then
    update public.support_messages set read_at = now()
     where conversation_id = v_conv.id and sender_role = 'customer' and read_at is null;
    update public.support_conversations set staff_unread = 0
     where id = v_conv.id and staff_unread <> 0;
  else
    raise exception 'forbidden' using errcode = '42501';
  end if;
end $$;

create or replace function public.support_close_conversation(
  p_conversation_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_conv public.support_conversations%rowtype; v_is_staff boolean;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into v_conv from public.support_conversations where id = p_conversation_id for update;
  if not found then raise exception 'conversation_not_found'; end if;

  v_is_staff := v_conv.customer_id <> v_uid and public.has_permission('support.manage');
  if v_conv.customer_id <> v_uid and not v_is_staff then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_conv.status = 'closed' then return; end if;

  update public.support_conversations
     set status = 'closed', closed_at = now(), closed_by = v_uid,
         close_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300)
   where id = v_conv.id;

  perform public._support_post(v_conv.id, null, 'system',
    case when v_is_staff then 'تم إغلاق المحادثة من خدمة العملاء' else 'تم إغلاق المحادثة' end,
    null, null, null, null, null);

  if v_is_staff then
    perform public.audit_write('support.close', 'support_conversation', v_conv.id::text, '{}'::jsonb);
    perform public.notify_user(v_conv.customer_id, 'تم إغلاق محادثتك',
      'Your chat was closed', 'قيّم تجربتك مع خدمة العملاء', 'Rate your support experience',
      'system', v_conv.id, left(v_conv.subject, 60), '/support/chat/' || v_conv.id::text);
  end if;
end $$;

create or replace function public.support_rate_conversation(
  p_conversation_id uuid, p_rating integer, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_conv public.support_conversations%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'invalid_rating'; end if;
  select * into v_conv from public.support_conversations where id = p_conversation_id for update;
  if not found or v_conv.customer_id <> v_uid then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_conv.status <> 'closed' then raise exception 'conversation_not_closed'; end if;
  if v_conv.rating is not null then raise exception 'already_rated'; end if;

  update public.support_conversations
     set rating = p_rating::smallint,
         rating_comment = left(nullif(btrim(coalesce(p_comment, '')), ''), 500),
         rated_at = now()
   where id = v_conv.id;
end $$;

create or replace function public.support_inbox(p_status text default 'open', p_limit integer default 100)
returns table (
  id uuid, subject text, status text, customer_id uuid, customer_name text, customer_phone text,
  customer_code text, assigned_to uuid, assigned_name text, last_message_at timestamptz,
  last_message_preview text, staff_unread integer, created_at timestamptz, rating smallint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.has_permission('support.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select c.id, c.subject, c.status, c.customer_id,
         coalesce(cu.full_name, pr.full_name, 'عميل'), coalesce(cu.phone, pr.phone), cu.customer_code,
         c.assigned_to, apr.full_name, c.last_message_at, c.last_message_preview,
         c.staff_unread, c.created_at, c.rating
    from public.support_conversations c
    left join public.customers cu on cu.user_id = c.customer_id
    left join public.profiles pr on pr.id = c.customer_id
    left join public.profiles apr on apr.id = c.assigned_to
   where p_status = 'all' or c.status = p_status
   order by (c.staff_unread > 0) desc, c.last_message_at desc
   limit least(greatest(p_limit, 1), 200);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'support_start_conversation(text,text,uuid)',
    'support_send_message(uuid,text,uuid,text,text,text,integer)',
    'support_mark_read(uuid)',
    'support_close_conversation(uuid,text)',
    'support_rate_conversation(uuid,integer,text)',
    'support_inbox(text,integer)',
    'support_can_access(uuid)',
    'support_can_access_text(text)',
    'support_can_access_topic(text)',
    'support_can_access_path(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------- realtime ----------
alter publication supabase_realtime add table public.support_conversations, public.support_messages;

-- typing indicator = private Broadcast channel "support:<conversation_id>"
do $$
begin
  if to_regclass('realtime.messages') is not null then
    execute $p$create policy support_chat_broadcast_read on realtime.messages
      for select to authenticated
      using (realtime.messages.extension = 'broadcast' and public.support_can_access_topic((select realtime.topic())))$p$;
    execute $p$create policy support_chat_broadcast_write on realtime.messages
      for insert to authenticated
      with check (realtime.messages.extension = 'broadcast' and public.support_can_access_topic((select realtime.topic())))$p$;
  end if;
end $$;

-- ---------- attachments ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('support-chat', 'support-chat', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do nothing;

create policy "support chat attachments read" on storage.objects
  for select to authenticated
  using (bucket_id = 'support-chat' and public.support_can_access_path(name));

create policy "support chat attachments upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'support-chat' and public.support_can_access_path(name));
