-- STEP 4 (release 54): admin control. Run in Supabase: SQL Editor -> paste -> Run (after 001..003).
-- 1) the FIRST admin is the MAIN admin  2) an admin can remove a teacher; only the main admin can remove another admin
-- 3) the main admin gets an alert every time a teacher or an admin signs up / signs in.
-- A removed account keeps its row (history stays) but loses every right at once: is_role / is_staff already test `active`.

-- ---------- profiles: email, main admin flag, removal trail ----------
alter table public.profiles add column if not exists email text not null default '';
alter table public.profiles add column if not exists is_main_admin boolean not null default false;
alter table public.profiles add column if not exists removed_at timestamptz;
alter table public.profiles add column if not exists removed_by uuid references public.profiles(id);
alter table public.profiles add column if not exists removed_reason text not null default '';

-- only ONE main admin can ever exist
create unique index if not exists profiles_one_main_admin on public.profiles ((true)) where is_main_admin;

-- new users also store their email (so the admin screen can show who is who)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, full_name, phone, grade, email)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name',''),
          coalesce(new.raw_user_meta_data->>'phone',''),
          coalesce(new.raw_user_meta_data->>'grade',''),
          coalesce(new.email,''));
  return new;
end $$;

-- existing rows: fill the email; if an admin was promoted by hand before, the OLDEST one becomes the main admin
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email = '';
update public.profiles set is_main_admin = true
 where id = (select id from public.profiles where role = 'admin' and removed_at is null order by created_at, id limit 1)
   and not exists (select 1 from public.profiles where is_main_admin);

-- the app can never write these columns (it already can only update name / phone / grade)
revoke update on public.profiles from authenticated;
grant update (full_name, phone, grade) on public.profiles to authenticated;

create or replace function public.is_main_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.role = 'admin' and p.is_main_admin and p.active and p.removed_at is null
                     from public.profiles p where p.id = auth.uid()), false)
$$;

-- ---------- alerts for the main admin ----------
create table if not exists public.security_events (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('signup','signin','removed')),
  role text not null,
  user_id uuid not null,
  email text not null default '',
  name text not null default '',
  by_user uuid,                       -- 'removed': who removed
  at timestamptz not null default now(),
  seen boolean not null default false
);
alter table public.security_events enable row level security;
drop policy if exists events_read on public.security_events;
create policy events_read on public.security_events for select to authenticated using (public.is_main_admin());
revoke insert, update, delete on public.security_events from authenticated, anon;   -- only the functions below write

-- ---------- admin sign-up: the first one becomes the main admin ----------
create or replace function public.register_admin() returns json
language plpgsql security definer set search_path = public as $$
declare me public.profiles; first_one boolean;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(54001);                       -- two people at once: one wins
  select * into me from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile' using errcode = '42501'; end if;
  if me.removed_at is not null or not me.active and me.role <> 'student' then
    raise exception 'removed' using errcode = '42501';
  end if;
  if me.role = 'admin' then
    return json_build_object('role','admin','main', me.is_main_admin);
  end if;
  if me.role = 'teacher' then raise exception 'teacher account' using errcode = '42501'; end if;
  first_one := not exists (select 1 from public.profiles where role = 'admin' and is_main_admin and removed_at is null);
  update public.profiles set role = 'admin', active = true, is_main_admin = first_one where id = auth.uid();
  if not first_one then
    insert into public.security_events(kind, role, user_id, email, name)
    values ('signup', 'admin', me.id, me.email, me.full_name);
  end if;
  return json_build_object('role','admin','main', first_one);
end $$;

-- ---------- the app reports "I signed in" (role / email come from the profile, never from the app) ----------
create or replace function public.log_entry(p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if p_kind not in ('signup','signin') then raise exception 'bad kind'; end if;
  select * into me from public.profiles where id = auth.uid();
  if not found or me.role not in ('teacher','admin') or me.is_main_admin or me.removed_at is not null then return; end if;
  -- a sign-in that repeats within 30 minutes is not a new alert
  if p_kind = 'signin' and exists (select 1 from public.security_events
        where user_id = me.id and kind in ('signin','signup') and at > now() - interval '30 minutes') then return; end if;
  insert into public.security_events(kind, role, user_id, email, name) values (p_kind, me.role, me.id, me.email, me.full_name);
end $$;

-- ---------- my own status (the app asks this at start: a removed account is signed out) ----------
create or replace function public.my_status() returns json
language sql stable security definer set search_path = public as $$
  select coalesce((select json_build_object('role', p.role, 'main', p.is_main_admin,
                                            'removed', p.removed_at is not null, 'reason', p.removed_reason)
                     from public.profiles p where p.id = auth.uid()),
                  json_build_object('role','', 'main', false, 'removed', false, 'reason', ''))
$$;

-- ---------- remove an account (teacher: any admin; admin: only the main admin; never yourself, never the main admin) ----------
create or replace function public.remove_account(p_user uuid, p_reason text default '') returns boolean
language plpgsql security definer set search_path = public as $$
declare t public.profiles;
begin
  if not public.is_role('admin') then raise exception 'admins only' using errcode = '42501'; end if;
  select * into t from public.profiles where id = p_user for update;
  if not found or t.removed_at is not null then return false; end if;
  if t.id = auth.uid() then raise exception 'not yourself' using errcode = '42501'; end if;
  if t.role = 'teacher' then null;
  elsif t.role = 'admin' then
    if t.is_main_admin then raise exception 'main admin cannot be removed' using errcode = '42501'; end if;
    if not public.is_main_admin() then raise exception 'only the main admin removes an admin' using errcode = '42501'; end if;
  else raise exception 'teachers and admins only' using errcode = '42501'; end if;

  update public.profiles
     set active = false, removed_at = now(), removed_by = auth.uid(), removed_reason = left(coalesce(p_reason,''), 200)
   where id = t.id;
  update public.security_events set seen = true where user_id = t.id and not seen;   -- its old alerts are done
  insert into public.security_events(kind, role, user_id, email, name, by_user, seen)
  values ('removed', t.role, t.id, t.email, t.full_name, auth.uid(), true);
  -- The session is NOT deleted on purpose: the rights are already gone (active = false) and the removed app must still be able
  -- to ask my_status() to learn it was removed (a dead session would look like "no answer").
  return true;
end $$;

-- the main admin marks the alerts as read
create or replace function public.mark_events_seen() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_main_admin() then raise exception 'main admin only' using errcode = '42501'; end if;
  update public.security_events set seen = true where not seen;
end $$;

-- ---------- list of teachers / admins for the admin screen (includes removed ones, newest first) ----------
create or replace function public.staff_list() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_role('admin') then raise exception 'admins only' using errcode = '42501'; end if;
  return coalesce((select json_agg(json_build_object(
            'id', p.id, 'role', p.role, 'name', p.full_name, 'email', p.email, 'phone', p.phone, 'main', p.is_main_admin,
            'removed', p.removed_at is not null, 'at', p.created_at) order by p.created_at desc)
          from public.profiles p where p.role in ('teacher','admin')), '[]'::json);
end $$;

revoke execute on function public.register_admin(), public.log_entry(text), public.my_status(), public.remove_account(uuid,text),
  public.mark_events_seen(), public.staff_list(), public.is_main_admin() from public, anon;
grant execute on function public.register_admin(), public.log_entry(text), public.my_status(), public.remove_account(uuid,text),
  public.mark_events_seen(), public.staff_list(), public.is_main_admin() to authenticated;
