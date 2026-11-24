-- STEP 1 of 3 (accounts, content, lock, manual grants). Run in Supabase: SQL Editor -> paste -> Run.
-- Step 2 (payments, Paymob) = 002_payments.sql, step 3 (storages / R2) = 003_storages.sql  (NOT written yet).
-- The lock lives HERE (row level security + functions), not in the app screens.

-- ---------- profiles (one row per auth user) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'student' check (role in ('student','teacher','admin')),
  full_name text not null default '',
  phone text not null default '',
  grade text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Every new user is a student. The role is NEVER taken from what the app sends.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, full_name, phone, grade)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name',''),
          coalesce(new.raw_user_meta_data->>'phone',''),
          coalesce(new.raw_user_meta_data->>'grade',''));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_role(r text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.role = r and p.active from public.profiles p where p.id = auth.uid()), false)
$$;
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.role in ('teacher','admin') and p.active from public.profiles p where p.id = auth.uid()), false)
$$;

-- ---------- teacher registration codes (server side: each code works ONCE, anywhere) ----------
create table if not exists public.teacher_codes (
  code text primary key,
  used_by uuid references public.profiles(id),
  used_at timestamptz
);
create or replace function public.claim_teacher(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
declare c text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  update public.teacher_codes t set used_by = auth.uid(), used_at = now()
   where upper(regexp_replace(t.code, '[^A-Za-z0-9]', '', 'g')) = c and t.used_by is null;
  if not found then return false; end if;
  update public.profiles set role = 'teacher' where id = auth.uid() and role = 'student';
  return true;
end $$;

-- ---------- content ----------
create table if not exists public.chapters (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id),
  title text not null,
  price int not null default 0 check (price >= 0),   -- EGP, 0 = free
  created_at timestamptz not null default now()
);
create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id),
  chapter_id uuid references public.chapters(id) on delete cascade,  -- null = stand-alone video
  title text not null,
  src text not null check (src in ('yt','up')),
  price int not null default 0 check (price >= 0),
  published boolean not null default true,
  yt_title text not null default '',
  yt_thumb text not null default '',
  created_at timestamptz not null default now()
);
-- The video source is in its OWN table: a student can read it only if can_view_lesson() says yes.
create table if not exists public.lesson_sources (
  lesson_id uuid primary key references public.lessons(id) on delete cascade,
  yt_id text not null default '',
  storage_id text,     -- step 3: which storage (R2 account) holds the file
  storage_key text     -- step 3: object key inside that storage
);

-- ---------- grants (cash / free / online) + permanent log ----------
create table if not exists public.grants (
  id uuid primary key default gen_random_uuid(),
  student uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('lesson','chapter')),
  target_id uuid not null,
  mode text not null check (mode in ('online','cash','free')),
  granted_by uuid references public.profiles(id),     -- null = payment webhook (step 2)
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create unique index if not exists grants_one_active
  on public.grants(student, target_type, target_id) where revoked_at is null;

create table if not exists public.grant_log (            -- append only, never edited or deleted
  id bigint generated always as identity primary key,
  student uuid not null,
  target_type text not null,
  target_id uuid not null,
  mode text not null,
  action text not null check (action in ('grant','revoke')),
  by_user uuid,
  at timestamptz not null default now()
);

-- ---------- the ONE decision function ----------
create or replace function public.can_view_lesson(p_lesson uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.lessons l
    left join public.chapters c on c.id = l.chapter_id
    where l.id = p_lesson and (
      l.owner = auth.uid() or public.is_role('admin')
      or (public.is_role('student') and l.published and (
            (l.price = 0 and coalesce(c.price,0) = 0)
            or exists (select 1 from public.grants g
                        where g.student = auth.uid() and g.revoked_at is null
                          and ((g.target_type = 'lesson'  and g.target_id = l.id)
                            or (g.target_type = 'chapter' and g.target_id = l.chapter_id)))
      ))
    )
  )
$$;

create or replace function public.access_lesson(p_lesson uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare l public.lessons; cp int; shown int; ok boolean;
begin
  select * into l from public.lessons where id = p_lesson;
  if not found then return json_build_object('allowed', false, 'reason', 'missing', 'price', 0); end if;
  select coalesce(price,0) into cp from public.chapters where id = l.chapter_id;
  shown := case when l.price > 0 then l.price else coalesce(cp,0) end;
  ok := public.can_view_lesson(p_lesson);
  return json_build_object('allowed', ok,
    'reason', case when ok and shown = 0 then 'free' when ok then 'granted' else 'locked' end,
    'price', shown);
end $$;

-- The player gets the source ONLY here. Locked = error 42501 (the app shows "locked").
create or replace function public.play_source(p_lesson uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare s public.lesson_sources; l public.lessons;
begin
  if not public.can_view_lesson(p_lesson) then raise exception 'locked' using errcode = '42501'; end if;
  select * into l from public.lessons where id = p_lesson;
  select * into s from public.lesson_sources where lesson_id = p_lesson;
  return json_build_object('src', l.src, 'ytId', coalesce(s.yt_id,''),
                           'storageId', s.storage_id, 'storageKey', s.storage_key);
end $$;

-- ---------- teacher: open / close for any student (the manual cash / free opening) ----------
create or replace function public.teacher_grant(p_student uuid, p_type text, p_target uuid, p_mode text) returns uuid
language plpgsql security definer set search_path = public as $$
declare gid uuid; owned boolean;
begin
  if not public.is_staff() then raise exception 'teachers only' using errcode = '42501'; end if;
  if p_mode not in ('cash','free') then raise exception 'mode must be cash or free'; end if;
  if p_type not in ('lesson','chapter') then raise exception 'bad target type'; end if;
  owned := case p_type
    when 'lesson'  then exists (select 1 from public.lessons  where id = p_target and (owner = auth.uid() or public.is_role('admin')))
    else               exists (select 1 from public.chapters where id = p_target and (owner = auth.uid() or public.is_role('admin'))) end;
  if not owned then raise exception 'not your content' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_student and role = 'student') then
    raise exception 'unknown student'; end if;
  select id into gid from public.grants
   where student = p_student and target_type = p_type and target_id = p_target and revoked_at is null;
  if gid is null then
    insert into public.grants(student, target_type, target_id, mode, granted_by)
    values (p_student, p_type, p_target, p_mode, auth.uid()) returning id into gid;
    insert into public.grant_log(student, target_type, target_id, mode, action, by_user)
    values (p_student, p_type, p_target, p_mode, 'grant', auth.uid());
  end if;
  return gid;
end $$;

create or replace function public.teacher_revoke(p_grant uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare g public.grants;
begin
  if not public.is_staff() then raise exception 'teachers only' using errcode = '42501'; end if;
  update public.grants set revoked_at = now() where id = p_grant and revoked_at is null returning * into g;
  if not found then return false; end if;
  insert into public.grant_log(student, target_type, target_id, mode, action, by_user)
  values (g.student, g.target_type, g.target_id, g.mode, 'revoke', auth.uid());   -- the old grant line stays in the log
  return true;
end $$;

create or replace function public.set_student_active(p_student uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'teachers only' using errcode = '42501'; end if;
  update public.profiles set active = p_active where id = p_student and role = 'student';
end $$;

-- ---------- row level security ----------
alter table public.profiles       enable row level security;
alter table public.teacher_codes  enable row level security;
alter table public.chapters       enable row level security;
alter table public.lessons        enable row level security;
alter table public.lesson_sources enable row level security;
alter table public.grants         enable row level security;
alter table public.grant_log      enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant update (full_name, phone, grade) on public.profiles to authenticated;   -- never role / active

-- teacher_codes: no policy = nobody reads it from the app (only claim_teacher and the dashboard).

drop policy if exists chapters_read on public.chapters;
create policy chapters_read on public.chapters for select to authenticated using (true);
drop policy if exists chapters_write on public.chapters;
create policy chapters_write on public.chapters for all to authenticated
  using (public.is_staff() and owner = auth.uid()) with check (public.is_staff() and owner = auth.uid());

drop policy if exists lessons_read on public.lessons;
create policy lessons_read on public.lessons for select to authenticated
  using (published or owner = auth.uid() or public.is_role('admin'));      -- metadata only: no source here
drop policy if exists lessons_write on public.lessons;
create policy lessons_write on public.lessons for all to authenticated      -- includes DELETE: owner teacher only
  using (public.is_staff() and owner = auth.uid()) with check (public.is_staff() and owner = auth.uid());

drop policy if exists sources_read on public.lesson_sources;
create policy sources_read on public.lesson_sources for select to authenticated
  using (public.can_view_lesson(lesson_id));
drop policy if exists sources_write on public.lesson_sources;
create policy sources_write on public.lesson_sources for all to authenticated
  using (exists (select 1 from public.lessons l where l.id = lesson_id and l.owner = auth.uid() and public.is_staff()))
  with check (exists (select 1 from public.lessons l where l.id = lesson_id and l.owner = auth.uid() and public.is_staff()));

drop policy if exists grants_read on public.grants;
create policy grants_read on public.grants for select to authenticated
  using (student = auth.uid() or public.is_staff());
-- no insert / update / delete policy on grants: only the functions above (and the payment webhook in step 2) write.
drop policy if exists log_read on public.grant_log;
create policy log_read on public.grant_log for select to authenticated using (public.is_staff());

revoke insert, update, delete on public.grants, public.grant_log from authenticated, anon;
revoke all on public.teacher_codes from authenticated, anon;
grant execute on function public.access_lesson(uuid), public.play_source(uuid),
  public.teacher_grant(uuid,text,uuid,text), public.teacher_revoke(uuid),
  public.set_student_active(uuid,boolean), public.claim_teacher(text) to authenticated;
