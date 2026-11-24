-- STEP 4b (release 57): ADMIN ACTIVATION CODE. Run in Supabase: SQL Editor -> paste -> Run (after 001..004).
-- DO NOT run 004 again after this file: it would bring back the old register_admin() with no code (two functions with that name = a clash).
-- Rule: the FIRST admin ever is the main admin and needs no code (so the owner must be the first to register, right after running this).
--       Every later admin account stays a plain (limited) account until it types a ONE-TIME code made by the main admin.
--       A code works once, for one account, and expires after 7 days. 5 wrong codes lock the attempts for 1 hour.
-- The main admin can still remove any admin (remove_account from 004 is unchanged).

-- ---------- codes (only the hash is stored; nobody can read this table from the app) ----------
create table if not exists public.admin_codes (
  id bigint generated always as identity primary key,
  code_hash text not null unique,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  used_by uuid references public.profiles(id),
  used_at timestamptz
);
alter table public.admin_codes enable row level security;     -- no policy at all: only the functions below touch it
revoke all on public.admin_codes from anon, authenticated;

alter table public.profiles add column if not exists admin_code_fails integer not null default 0;
alter table public.profiles add column if not exists admin_code_last timestamptz;

-- ---------- the main admin makes a code (answer = the code, shown once, XXXXXX-YYYYYY) ----------
create or replace function public.new_admin_code() returns text
language plpgsql security definer set search_path = public as $$
declare
  alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- 32 letters / digits, no 0 O 1 I
  b bytea; c text := ''; i int;
  idx int[] := array[0,1,2,3,4,5,9,10,11,12,13,14];            -- bytes 6 and 8 of a uuid carry fixed version bits: skipped
begin
  if not public.is_main_admin() then raise exception 'main admin only' using errcode = '42501'; end if;
  delete from public.admin_codes where used_at is null and expires_at < now();
  b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');   -- 16 random bytes; 256 mod 32 = 0 so no bias
  for i in 1..12 loop c := c || substr(alpha, 1 + (get_byte(b, idx[i]) % 32), 1); end loop;
  c := substr(c, 1, 6) || '-' || substr(c, 7, 6);
  insert into public.admin_codes(code_hash, created_by) values (encode(sha256(convert_to(c, 'utf8')), 'hex'), auth.uid());
  return c;
end $$;

-- ---------- admin sign-up: the first one = main admin (no code); the others need a valid code ----------
-- Answer: {ok:true, role:'admin', main:bool}  or  {ok:false, reason:'code' | 'locked', role:<current role>, main:false}
-- (a wrong code is an ANSWER, not an error, so the counter of wrong tries is saved)
drop function if exists public.register_admin();
create or replace function public.register_admin(p_code text default '') returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles; first_one boolean; raw text; norm text; h text; c public.admin_codes; fails int;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(54001);                       -- same lock as 004: two people at once, one wins
  select * into me from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'no profile' using errcode = '42501'; end if;
  if me.removed_at is not null or (not me.active and me.role <> 'student') then
    raise exception 'removed' using errcode = '42501';
  end if;
  if me.role = 'admin' then
    return json_build_object('ok', true, 'role', 'admin', 'main', me.is_main_admin);
  end if;
  if me.role = 'teacher' then raise exception 'teacher account' using errcode = '42501'; end if;

  first_one := not exists (select 1 from public.profiles where role = 'admin' and is_main_admin and removed_at is null);
  if not first_one then
    fails := case when me.admin_code_last is null or me.admin_code_last < now() - interval '1 hour' then 0 else me.admin_code_fails end;
    if fails >= 5 then
      return json_build_object('ok', false, 'reason', 'locked', 'role', me.role, 'main', false);
    end if;
    raw := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
    if raw = '' then                                           -- no code typed (e.g. a normal sign-in): an answer, not a wrong try
      return json_build_object('ok', false, 'reason', 'code', 'role', me.role, 'main', false);
    end if;
    norm := case when length(raw) = 12 then substr(raw, 1, 6) || '-' || substr(raw, 7, 6) else raw end;
    h := encode(sha256(convert_to(norm, 'utf8')), 'hex');
    select * into c from public.admin_codes where code_hash = h and used_at is null and expires_at > now() for update;
    if not found then
      update public.profiles set admin_code_fails = fails + 1, admin_code_last = now() where id = me.id;
      return json_build_object('ok', false, 'reason', 'code', 'role', me.role, 'main', false);
    end if;
    update public.admin_codes set used_by = me.id, used_at = now() where id = c.id;
  end if;

  update public.profiles set role = 'admin', active = true, is_main_admin = first_one, admin_code_fails = 0, admin_code_last = null
   where id = me.id;
  if not first_one then
    insert into public.security_events(kind, role, user_id, email, name) values ('signup', 'admin', me.id, me.email, me.full_name);
  end if;
  return json_build_object('ok', true, 'role', 'admin', 'main', first_one);
end $$;

revoke execute on function public.register_admin(text), public.new_admin_code() from public, anon;
grant execute on function public.register_admin(text), public.new_admin_code() to authenticated;
