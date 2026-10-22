-- 0014 Customer registry and sign-in with email, mobile number or username.
--
-- public.customers is the customer register: every account gets a system ID (MHC-100001, ...)
-- that links its email, mobile number, username and auth user. Rows are written only by
-- triggers and security-definer functions.
--
-- Sign-in: the app sends the identifier + password to login_email_for(). It checks the password
-- against Supabase Auth's bcrypt hash and returns the account email ONLY when the password is
-- right, so usernames/phones cannot be used to discover emails. The app then signs in normally
-- with Supabase Auth (email + password), which issues the session and applies its own limits.

create sequence if not exists public.customer_code_seq start 100001;

-- Egyptian mobile in E.164 (+201XXXXXXXXX) or null
create or replace function public.normalize_eg_mobile(p text)
returns text language plpgsql immutable set search_path = public as $$
declare d text;
begin
  if p is null then return null; end if;
  d := translate(p, '٠١٢٣٤٥٦٧٨٩', '0123456789');
  d := regexp_replace(d, '[^0-9]', '', 'g');
  if d like '0020%' then d := substr(d, 3); end if;
  if d like '01%' and length(d) = 11 then d := '2' || d; end if;
  if d ~ '^201[0125][0-9]{8}$' then return '+' || d; end if;
  return null;
end $$;

create table public.customers (
  customer_code text primary key default ('MHC-' || nextval('public.customer_code_seq')),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  username text unique check (username is null or username ~ '^[a-z0-9_.]{3,20}$'),
  email text unique check (email is null or email = lower(email)),
  phone text unique check (phone is null or phone ~ '^\+201[0125][0-9]{8}$'),
  full_name text,
  email_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger customers_updated before update on public.customers
  for each row execute function public.set_updated_at();
alter table public.customers enable row level security;
grant select on public.customers to authenticated;
create policy customers_select on public.customers for select to authenticated
  using (user_id = auth.uid() or public.has_permission('customers.view'));

-- usernames/phones held by sign-ups that were never confirmed are released after 24 hours
create or replace function public._release_stale_identifiers(p_username text, p_phone text)
returns void language sql security definer set search_path = public as $$
  update public.customers c
     set username = case when c.username = p_username then null else c.username end,
         phone    = case when c.phone = p_phone then null else c.phone end
   where (c.username = p_username or c.phone = p_phone)
     and exists (select 1 from auth.users u where u.id = c.user_id
                  and u.email_confirmed_at is null and u.phone_confirmed_at is null
                  and u.created_at < now() - interval '24 hours');
$$;

-- profile + customer row for every new auth user (sign-up metadata: full_name, username, phone)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_username text := nullif(lower(trim(new.raw_user_meta_data ->> 'username')), '');
  v_phone text := public.normalize_eg_mobile(new.raw_user_meta_data ->> 'phone');
  v_name text := coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name');
begin
  if v_username is not null and v_username !~ '^[a-z0-9_.]{3,20}$' then
    raise exception 'INVALID_USERNAME';
  end if;
  if (new.raw_user_meta_data ->> 'phone') is not null and v_phone is null then
    raise exception 'INVALID_PHONE';
  end if;
  perform public._release_stale_identifiers(v_username, v_phone);
  if v_username is not null and exists (select 1 from public.customers where username = v_username) then
    raise exception 'USERNAME_TAKEN';
  end if;
  if v_phone is not null and exists (select 1 from public.customers where phone = v_phone) then
    raise exception 'PHONE_TAKEN';
  end if;

  insert into public.profiles (id, full_name, phone, phone_verified, email, email_verified, contact_phone)
  values (new.id, v_name, nullif(new.phone, ''), new.phone_confirmed_at is not null,
          nullif(new.email, ''), new.email_confirmed_at is not null, v_phone)
  on conflict (id) do nothing;

  insert into public.customers (user_id, username, email, phone, full_name, email_verified)
  values (new.id, v_username, lower(nullif(new.email, '')), v_phone, v_name, new.email_confirmed_at is not null)
  on conflict (user_id) do nothing;
  return new;
end $$;

-- auth.users changes (email, confirmation) -> profile + customer
create or replace function public.sync_profile_from_auth()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
     set phone = coalesce(nullif(new.phone, ''), phone),
         phone_verified = (new.phone_confirmed_at is not null),
         email = coalesce(nullif(new.email, ''), email),
         email_verified = (new.email_confirmed_at is not null)
   where id = new.id;
  update public.customers
     set email = coalesce(lower(nullif(new.email, '')), email),
         email_verified = (new.email_confirmed_at is not null)
   where user_id = new.id;
  return new;
end $$;

-- customer edits their name / contact phone in the app -> customer register
create or replace function public.sync_customer_from_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.contact_phone is not null and exists
     (select 1 from public.customers where phone = new.contact_phone and user_id <> new.id) then
    raise exception 'PHONE_TAKEN';
  end if;
  update public.customers set phone = new.contact_phone, full_name = new.full_name where user_id = new.id;
  return new;
end $$;
create trigger profiles_sync_customer after update of contact_phone, full_name on public.profiles
  for each row execute function public.sync_customer_from_profile();

-- existing accounts get their customer IDs
insert into public.customers (user_id, email, phone, full_name, email_verified)
select p.id, lower(p.email), p.contact_phone, p.full_name, p.email_verified
  from public.profiles p
 where not exists (select 1 from public.customers c where c.user_id = p.id)
 order by p.created_at;

-- ---------- sign-up availability ----------
create or replace function public.signup_check(p_username text, p_phone text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_u text := nullif(lower(trim(p_username)), '');
  v_p text := public.normalize_eg_mobile(p_phone);
  stale constant text := '24 hours';
begin
  return jsonb_build_object(
    'username_valid', v_u is not null and v_u ~ '^[a-z0-9_.]{3,20}$',
    'username_available', v_u is not null and not exists (
      select 1 from public.customers c join auth.users u on u.id = c.user_id
       where c.username = v_u
         and (u.email_confirmed_at is not null or u.phone_confirmed_at is not null or u.created_at > now() - stale::interval)),
    'phone_valid', v_p is not null,
    'phone_available', v_p is not null and not exists (
      select 1 from public.customers c join auth.users u on u.id = c.user_id
       where c.phone = v_p
         and (u.email_confirmed_at is not null or u.phone_confirmed_at is not null or u.created_at > now() - stale::interval)),
    'phone', v_p);
end $$;

-- ---------- sign-in with email / mobile / username ----------
create table public.auth_login_attempts (
  id bigint generated always as identity primary key,
  key text not null,
  ok boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create index auth_login_attempts_key_idx on public.auth_login_attempts(key, created_at desc);
alter table public.auth_login_attempts enable row level security;

-- Returns the account email when identifier + password are correct, otherwise null.
-- More than 8 wrong attempts for one identifier within 15 minutes (since its last successful
-- sign-in) -> RATE_LIMITED. Attempts are only appended, never deleted.
create or replace function public.login_email_for(p_identifier text, p_password text)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_id text := lower(trim(coalesce(p_identifier, '')));
  v_phone text;
  v_key text;
  v_uid uuid;
  v_hash text;
  v_email text;
  v_since timestamptz;
begin
  if v_id = '' or p_password is null or length(v_id) > 254 or length(p_password) > 200 then
    return null;
  end if;
  v_phone := public.normalize_eg_mobile(v_id);
  v_key := case when position('@' in v_id) > 0 then 'e:' || v_id
                when v_phone is not null then 'p:' || v_phone
                else 'u:' || v_id end;

  select greatest(now() - interval '15 minutes', coalesce(max(created_at) filter (where ok), '-infinity'))
    into v_since from public.auth_login_attempts where key = v_key;
  if (select count(*) from public.auth_login_attempts
       where key = v_key and not ok and created_at > coalesce(v_since, now() - interval '15 minutes')) >= 8 then
    raise exception 'RATE_LIMITED';
  end if;

  select c.user_id into v_uid from public.customers c
   where case left(v_key, 2) when 'e:' then c.email = v_id
                             when 'p:' then c.phone = v_phone
                             else c.username = v_id end
   limit 1;
  if v_uid is not null then
    select encrypted_password, email into v_hash, v_email from auth.users where id = v_uid;
  end if;

  if v_hash is not null and v_hash <> '' and v_hash = extensions.crypt(p_password, v_hash) then
    insert into public.auth_login_attempts(key, ok) values (v_key, true);
    return v_email;
  end if;

  if v_hash is null or v_hash = '' then
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));  -- same cost whether or not the account exists
  end if;
  insert into public.auth_login_attempts(key, ok) values (v_key, false);
  return null;
end $$;

grant execute on function public.signup_check(text, text) to anon, authenticated;
grant execute on function public.login_email_for(text, text) to anon, authenticated;
grant execute on function public.normalize_eg_mobile(text) to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.customers from anon, authenticated;
revoke select on public.customers from anon;
revoke all on public.auth_login_attempts from anon, authenticated;
revoke execute on function public._release_stale_identifiers(text, text) from public, anon, authenticated;
revoke execute on function public.sync_customer_from_profile() from public, anon, authenticated;
